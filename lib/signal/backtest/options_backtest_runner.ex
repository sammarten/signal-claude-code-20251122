defmodule Signal.Backtest.OptionsBacktestRunner do
  @moduledoc """
  Runs backtests with options trading integration.

  This module provides a high-level interface for running backtests that trade
  options instead of (or in addition to) equities. It coordinates:

  - Signal generation from strategies
  - Contract resolution via Instruments.Resolver
  - Price lookup from historical options data
  - Position sizing and trade execution
  - Exit condition monitoring
  - P&L calculation and trade persistence

  ## Usage

      # Configure for options trading
      config = Config.options(
        expiration_preference: :weekly,
        strike_selection: :atm
      )

      # Run backtest
      {:ok, results} = OptionsBacktestRunner.run(
        symbol: "AAPL",
        start_date: ~D[2024-03-01],
        end_date: ~D[2024-03-31],
        config: config,
        initial_capital: Decimal.new("100000")
      )

  ## Data Requirements

  Before running an options backtest, ensure:
  1. Options contracts are synced via `ContractDiscovery.sync_contracts/2`
  2. Options bars are loaded for the relevant contract/date range
  3. Underlying equity bars are available for signal generation

  ## Limitations

  - Only supports long calls and long puts (no spreads, no short options)
  - Uses historical bar data for price simulation (no Greeks/theoretical pricing)
  - Requires pre-synced contract and bar data
  """

  require Logger

  alias Signal.Backtest.OptionsTradeSimulator
  alias Signal.Backtest.SimulatedTrade
  alias Signal.Backtest.BacktestRun
  alias Signal.Instruments.Config
  alias Signal.Options.PriceLookup
  alias Signal.MarketData.Bar, as: EquityBar
  alias Signal.Repo

  import Ecto.Query

  @doc """
  Runs an options backtest for the given parameters.

  ## Parameters

    * `opts` - Keyword options:
      - `:symbol` - Underlying symbol to trade (required)
      - `:start_date` - Start date for backtest (required)
      - `:end_date` - End date for backtest (required)
      - `:signals` - List of pre-generated signals (required)
      - `:config` - Instruments Config (default: options with weekly/ATM)
      - `:initial_capital` - Starting capital (default: $100,000)
      - `:risk_per_trade` - Risk percentage per trade (default: 1%)
      - `:persist` - Whether to persist trades to database (default: true)
      - `:backtest_run_id` - Existing backtest run ID (optional)

  ## Returns

    * `{:ok, results}` - Backtest completed successfully with results map
    * `{:error, reason}` - Backtest failed
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def run(opts) do
    with {:ok, params} <- validate_params(opts),
         {:ok, backtest_run} <- get_or_create_backtest_run(params),
         {:ok, results} <- execute_backtest(params, backtest_run) do
      {:ok, results}
    end
  end

  @doc """
  Runs a single signal through the options trading flow.

  Useful for testing or step-by-step execution.

  ## Parameters

    * `simulator` - OptionsTradeSimulator instance
    * `signal` - Trade signal
    * `underlying_bars` - List of underlying bars for the trade period
    * `get_options_bar` - Function to get options bar: fn(contract_symbol, datetime) -> bar

  ## Returns

    * `{:ok, updated_simulator, trade_result}` - Signal processed
    * `{:error, reason}` - Failed to process signal
  """
  @spec run_signal(OptionsTradeSimulator.t(), map(), [map()], function()) ::
          {:ok, OptionsTradeSimulator.t(), map()} | {:error, atom()}
  def run_signal(simulator, signal, underlying_bars, get_options_bar) do
    [entry_bar | rest_bars] = underlying_bars

    # Get entry options bar
    case OptionsTradeSimulator.execute_signal(simulator, signal, entry_bar, nil) do
      {:ok, sim_with_trade, trade} ->
        # Process remaining bars looking for exit
        {final_sim, trade_result} =
          process_bars_until_exit(sim_with_trade, trade.id, rest_bars, get_options_bar)

        {:ok, final_sim, trade_result}

      {:error, _} = error ->
        error
    end
  end

  # Private Functions

  defp validate_params(opts) do
    required = [:symbol, :start_date, :end_date, :signals]
    missing = Enum.filter(required, &(!Keyword.has_key?(opts, &1)))

    if Enum.empty?(missing) do
      params = %{
        symbol: Keyword.fetch!(opts, :symbol),
        start_date: Keyword.fetch!(opts, :start_date),
        end_date: Keyword.fetch!(opts, :end_date),
        signals: Keyword.fetch!(opts, :signals),
        config: Keyword.get(opts, :config, Config.options()),
        initial_capital: Keyword.get(opts, :initial_capital, Decimal.new("100000")),
        risk_per_trade: Keyword.get(opts, :risk_per_trade, Decimal.new("0.01")),
        persist: Keyword.get(opts, :persist, true),
        backtest_run_id: Keyword.get(opts, :backtest_run_id)
      }

      {:ok, params}
    else
      {:error, {:missing_params, missing}}
    end
  end

  defp get_or_create_backtest_run(%{backtest_run_id: id}) when not is_nil(id) do
    case Repo.get(BacktestRun, id) do
      nil -> {:error, :backtest_run_not_found}
      run -> {:ok, run}
    end
  end

  defp get_or_create_backtest_run(params) do
    attrs = %{
      name: "Options Backtest - #{params.symbol}",
      strategy: "options_backtest",
      symbols: [params.symbol],
      start_date: params.start_date,
      end_date: params.end_date,
      initial_capital: params.initial_capital,
      risk_per_trade: params.risk_per_trade,
      status: :running,
      config: %{
        instrument_type: "options",
        expiration_preference: Atom.to_string(params.config.expiration_preference),
        strike_selection: Atom.to_string(params.config.strike_selection)
      }
    }

    case %BacktestRun{}
         |> BacktestRun.changeset(attrs)
         |> Repo.insert() do
      {:ok, run} -> {:ok, run}
      {:error, changeset} -> {:error, {:db_error, changeset}}
    end
  end

  defp execute_backtest(params, backtest_run) do
    # Initialize simulator
    account = %{
      current_equity: params.initial_capital,
      risk_per_trade: params.risk_per_trade,
      cash: params.initial_capital
    }

    simulator =
      OptionsTradeSimulator.new(
        account: account,
        config: params.config
      )

    # Load underlying bars for the period
    underlying_bars = load_underlying_bars(params.symbol, params.start_date, params.end_date)

    # Group signals by date for processing
    signals_by_date = group_signals_by_date(params.signals)

    # Process each day
    {final_simulator, processed_signals} =
      process_trading_days(simulator, underlying_bars, signals_by_date, params)

    # Persist trades if enabled
    if params.persist do
      persist_trades(final_simulator.closed_trades, backtest_run.id)
    end

    # Update backtest run status
    update_backtest_run_status(backtest_run, final_simulator)

    # Build results
    results = build_results(final_simulator, backtest_run, processed_signals)

    {:ok, results}
  end

  defp load_underlying_bars(symbol, start_date, end_date) do
    start_time = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    end_time = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")

    from(b in EquityBar,
      where:
        b.symbol == ^symbol and
          b.bar_time >= ^start_time and
          b.bar_time <= ^end_time,
      order_by: [asc: b.bar_time]
    )
    |> Repo.all()
  end

  defp group_signals_by_date(signals) do
    Enum.group_by(signals, fn signal ->
      signal.generated_at
      |> DateTime.to_date()
    end)
  end

  defp process_trading_days(simulator, bars, signals_by_date, params) do
    # Group bars by date
    bars_by_date = Enum.group_by(bars, &DateTime.to_date(&1.bar_time))

    processed_signals = []

    {final_sim, final_processed} =
      Enum.reduce(bars_by_date, {simulator, processed_signals}, fn {date, day_bars},
                                                                   {sim, processed} ->
        # Get signals for this day
        day_signals = Map.get(signals_by_date, date, [])

        # Sort bars by time
        sorted_bars = Enum.sort_by(day_bars, & &1.bar_time, DateTime)

        # Process each bar
        {updated_sim, new_processed} =
          process_day_bars(sim, sorted_bars, day_signals, params)

        {updated_sim, processed ++ new_processed}
      end)

    {final_sim, final_processed}
  end

  defp process_day_bars(simulator, bars, signals, params) do
    pending_signals = signals
    processed = []

    {final_sim, final_processed, _remaining} =
      Enum.reduce(bars, {simulator, processed, pending_signals}, fn bar, {sim, proc, pending} ->
        # Check exits for open positions
        sim = check_all_exits(sim, bar, params.symbol)

        # Try to execute any pending signals on this bar
        {sim, proc, remaining} =
          Enum.reduce(pending, {sim, proc, []}, fn signal, {s, p, r} ->
            # Check if this bar's time is at or after signal time
            if DateTime.compare(bar.bar_time, signal.generated_at) in [:eq, :gt] do
              case OptionsTradeSimulator.execute_signal(s, signal, bar, nil) do
                {:ok, updated_sim, trade} ->
                  {updated_sim, [{:opened, signal, trade} | p], r}

                {:error, reason} ->
                  Logger.warning(
                    "[OptionsBacktestRunner] Failed to execute signal: #{inspect(reason)}"
                  )

                  {s, [{:failed, signal, reason} | p], r}
              end
            else
              # Signal not yet ready
              {s, p, [signal | r]}
            end
          end)

        {sim, proc, remaining}
      end)

    {final_sim, final_processed}
  end

  defp check_all_exits(simulator, underlying_bar, symbol) do
    # For each open position, load its options bar and check exit
    Enum.reduce(simulator.open_positions, simulator, fn {trade_id, trade}, acc_sim ->
      if trade.underlying_symbol == symbol do
        # Try to get options bar for this contract at this time
        case PriceLookup.get_bar_at(trade.contract_symbol, underlying_bar.bar_time) do
          {:ok, options_bar} ->
            case OptionsTradeSimulator.check_exit(acc_sim, trade_id, underlying_bar, options_bar) do
              {:exit, reason, exit_premium, _} ->
                {:ok, updated_sim, _} =
                  OptionsTradeSimulator.close_position(
                    acc_sim,
                    trade_id,
                    exit_premium,
                    underlying_bar.bar_time,
                    reason
                  )

                updated_sim

              {:hold, _} ->
                acc_sim

              {:error, _} ->
                acc_sim
            end

          {:error, :no_data} ->
            # No options data - can't check exit
            acc_sim
        end
      else
        acc_sim
      end
    end)
  end

  defp process_bars_until_exit(simulator, trade_id, bars, get_options_bar) do
    Enum.reduce_while(bars, {simulator, nil}, fn bar, {sim, _result} ->
      trade = Map.get(sim.open_positions, trade_id)

      if trade do
        options_bar = get_options_bar.(trade.contract_symbol, bar.bar_time)

        if options_bar do
          case OptionsTradeSimulator.check_exit(sim, trade_id, bar, options_bar) do
            {:exit, reason, exit_premium, _} ->
              {:ok, updated_sim, closed_trade} =
                OptionsTradeSimulator.close_position(
                  sim,
                  trade_id,
                  exit_premium,
                  bar.bar_time,
                  reason
                )

              {:halt, {updated_sim, {:closed, closed_trade}}}

            {:hold, _} ->
              {:cont, {sim, nil}}

            {:error, _} ->
              {:cont, {sim, nil}}
          end
        else
          {:cont, {sim, nil}}
        end
      else
        # Trade already closed
        {:halt, {sim, {:already_closed, trade_id}}}
      end
    end)
  end

  defp persist_trades(trades, backtest_run_id) do
    Enum.each(trades, fn trade ->
      attrs = OptionsTradeSimulator.trade_to_attrs(trade, backtest_run_id)

      case %SimulatedTrade{}
           |> SimulatedTrade.changeset(attrs)
           |> Repo.insert() do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.error(
            "[OptionsBacktestRunner] Failed to persist trade: #{inspect(changeset.errors)}"
          )
      end
    end)
  end

  defp update_backtest_run_status(backtest_run, simulator) do
    summary = OptionsTradeSimulator.summary(simulator)

    attrs = %{
      status: :completed,
      final_equity: simulator.account.current_equity,
      total_trades: summary.total_trades,
      winning_trades: summary.winners,
      losing_trades: summary.losers,
      total_pnl: summary.total_pnl
    }

    backtest_run
    |> BacktestRun.changeset(attrs)
    |> Repo.update()
  end

  defp build_results(simulator, backtest_run, processed_signals) do
    summary = OptionsTradeSimulator.summary(simulator)

    %{
      backtest_run_id: backtest_run.id,
      summary: summary,
      closed_trades: simulator.closed_trades,
      open_positions: simulator.open_positions,
      processed_signals: length(processed_signals),
      account: simulator.account
    }
  end
end
