defmodule Signal.Backtest.TradeSimulator do
  @moduledoc """
  Executes simulated trades during backtests.

  The TradeSimulator subscribes to signals and bar updates during a backtest,
  opening positions on signals and managing them through to exit.

  ## Trade Lifecycle

  1. Signal received → Evaluate entry criteria
  2. Entry criteria met → Open position via VirtualAccount
  3. Each bar → Check stop loss and take profit
  4. Exit condition met → Close position, record trade

  ## Exit Conditions

  - **Stop Loss Hit**: Price touches or gaps through stop
  - **Target Hit**: Price reaches take profit level
  - **Time Exit**: Position held past cutoff time (e.g., 11:00 AM ET)
  - **End of Day**: Forced exit at market close

  ## Usage

      {:ok, simulator} = TradeSimulator.start_link(
        run_id: "abc123",
        account: virtual_account,
        fill_config: FillSimulator.new(:next_bar_open),
        time_exit: ~T[11:00:00]
      )

      # Simulator subscribes to PubSub and manages trades automatically
  """

  use GenServer
  require Logger

  alias Signal.Backtest.VirtualAccount
  alias Signal.Backtest.FillSimulator
  alias Signal.Backtest.SimulatedTrade
  alias Signal.Backtest.VirtualClock
  alias Signal.Repo

  @time_exit_default ~T[11:00:00]
  @timezone "America/New_York"

  defstruct [
    :run_id,
    :backtest_run_id,
    :account,
    :fill_config,
    :clock,
    :time_exit,
    :symbols,
    :pending_signals,
    :persist_trades
  ]

  # Client API

  @doc """
  Starts the trade simulator.

  ## Options

    * `:run_id` - Backtest run ID (required)
    * `:backtest_run_id` - Database ID for persisting trades (required)
    * `:account` - VirtualAccount instance (required)
    * `:clock` - VirtualClock server (required)
    * `:symbols` - List of symbols to trade (required)
    * `:fill_config` - FillSimulator config (default: signal price, no slippage)
    * `:time_exit` - Time to exit all positions (default: 11:00 AM ET)
    * `:persist_trades` - Whether to persist trades to database (default: true)
    * `:name` - Optional GenServer name
  """
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    name = Keyword.get(opts, :name, via_tuple(run_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submits a signal for potential trade execution.

  The signal will be evaluated and a position opened if criteria are met.
  """
  @spec submit_signal(GenServer.server(), map()) :: :ok
  def submit_signal(simulator, signal) do
    GenServer.cast(simulator, {:signal, signal})
  end

  @doc """
  Processes a new bar, checking for exits on open positions.
  """
  @spec process_bar(GenServer.server(), map()) :: :ok
  def process_bar(simulator, bar) do
    GenServer.cast(simulator, {:bar, bar})
  end

  @doc """
  Forces exit of all open positions.
  """
  @spec exit_all(GenServer.server(), map()) :: :ok
  def exit_all(simulator, bar) do
    GenServer.cast(simulator, {:exit_all, bar})
  end

  @doc """
  Returns the current account state.
  """
  @spec get_account(GenServer.server()) :: VirtualAccount.t()
  def get_account(simulator) do
    GenServer.call(simulator, :get_account)
  end

  @doc """
  Returns summary statistics.
  """
  @spec get_summary(GenServer.server()) :: map()
  def get_summary(simulator) do
    GenServer.call(simulator, :get_summary)
  end

  @doc """
  Stops the simulator.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(simulator) do
    GenServer.stop(simulator, :normal)
  end

  @doc """
  Returns the Registry via tuple for a run_id.
  """
  def via_tuple(run_id) do
    {:via, Registry, {Signal.Backtest.Registry, {:trade_simulator, run_id}}}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    backtest_run_id = Keyword.fetch!(opts, :backtest_run_id)
    account = Keyword.fetch!(opts, :account)
    clock = Keyword.fetch!(opts, :clock)
    symbols = Keyword.fetch!(opts, :symbols)

    fill_config = Keyword.get(opts, :fill_config, FillSimulator.new())
    time_exit = Keyword.get(opts, :time_exit, @time_exit_default)
    persist_trades = Keyword.get(opts, :persist_trades, true)

    state = %__MODULE__{
      run_id: run_id,
      backtest_run_id: backtest_run_id,
      account: account,
      fill_config: fill_config,
      clock: clock,
      time_exit: time_exit,
      symbols: symbols,
      pending_signals: [],
      persist_trades: persist_trades
    }

    Logger.debug("[TradeSimulator] Started for run #{run_id}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:signal, signal}, state) do
    # Queue signal for execution on next bar
    new_state = %{state | pending_signals: [signal | state.pending_signals]}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:bar, bar}, state) do
    # Only process bars for our symbols
    if bar.symbol in state.symbols do
      state
      |> check_time_exit(bar)
      |> check_exits(bar)
      |> process_pending_signals(bar)
      |> then(&{:noreply, &1})
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:exit_all, bar}, state) do
    new_state = force_exit_all(state, bar, :manual_exit)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_account, _from, state) do
    {:reply, state.account, state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    summary = VirtualAccount.summary(state.account)
    {:reply, summary, state}
  end

  # Private Functions

  defp check_time_exit(state, bar) do
    current_time = VirtualClock.now(state.clock)

    if current_time && past_time_exit?(current_time, state.time_exit) do
      # Exit all positions for this symbol
      force_exit_symbol(state, bar.symbol, bar, :time_exit)
    else
      state
    end
  end

  defp past_time_exit?(current_time, time_exit) do
    et_time =
      current_time
      |> DateTime.shift_zone!(@timezone)
      |> DateTime.to_time()

    Time.compare(et_time, time_exit) in [:gt, :eq]
  end

  defp check_exits(state, bar) do
    # Find open positions for this symbol
    open_for_symbol =
      state.account.open_positions
      |> Enum.filter(fn {_id, trade} -> trade.symbol == bar.symbol end)

    Enum.reduce(open_for_symbol, state, fn {trade_id, trade}, acc_state ->
      check_trade_exit(acc_state, trade_id, trade, bar)
    end)
  end

  defp check_trade_exit(state, trade_id, trade, bar) do
    # Check stop first (stops have priority)
    case FillSimulator.check_stop(state.fill_config, trade, bar) do
      {:stopped, fill_price, gap?} ->
        close_trade(state, trade_id, fill_price, bar.bar_time, :stopped_out, gap?)

      :ok ->
        # Check target
        case FillSimulator.check_target(state.fill_config, trade, bar) do
          {:target_hit, fill_price} ->
            close_trade(state, trade_id, fill_price, bar.bar_time, :target_hit, false)

          :ok ->
            state
        end
    end
  end

  defp close_trade(state, trade_id, exit_price, exit_time, status, gap?) do
    case VirtualAccount.close_position(state.account, trade_id, %{
           exit_price: exit_price,
           exit_time: exit_time,
           status: status
         }) do
      {:ok, updated_account, closed_trade} ->
        if gap? do
          Logger.debug(
            "[TradeSimulator] #{closed_trade.symbol} gapped through stop, filled at #{exit_price}"
          )
        end

        Logger.debug(
          "[TradeSimulator] Closed #{closed_trade.symbol} #{status}, P&L: #{closed_trade.pnl} (#{closed_trade.r_multiple}R)"
        )

        # Persist to database if enabled
        if state.persist_trades do
          persist_trade(state.backtest_run_id, closed_trade)
        end

        %{state | account: updated_account}

      {:error, :not_found} ->
        state
    end
  end

  defp process_pending_signals(state, bar) do
    # Filter signals for this symbol
    {signals_for_bar, remaining} =
      Enum.split_with(state.pending_signals, fn signal ->
        signal.symbol == bar.symbol
      end)

    # Execute each signal
    new_state =
      Enum.reduce(signals_for_bar, state, fn signal, acc_state ->
        execute_signal(acc_state, signal, bar)
      end)

    %{new_state | pending_signals: remaining}
  end

  defp execute_signal(state, signal, bar) do
    # Calculate entry price
    {:ok, entry_price, _slippage} =
      FillSimulator.entry_fill(
        state.fill_config,
        signal.entry_price,
        signal.direction,
        bar
      )

    # Open position
    params = %{
      symbol: signal.symbol,
      direction: signal.direction,
      entry_price: entry_price,
      stop_loss: signal.stop_loss,
      take_profit: Map.get(signal, :take_profit),
      entry_time: bar.bar_time,
      signal_id: Map.get(signal, :id)
    }

    case VirtualAccount.open_position(state.account, params) do
      {:ok, updated_account, trade} ->
        Logger.debug(
          "[TradeSimulator] Opened #{trade.symbol} #{trade.direction} at #{entry_price}, " <>
            "size: #{trade.position_size}, risk: #{trade.risk_amount}"
        )

        %{state | account: updated_account}

      {:error, reason} ->
        Logger.warning("[TradeSimulator] Failed to open position: #{inspect(reason)}")
        state
    end
  end

  defp force_exit_symbol(state, symbol, bar, status) do
    open_for_symbol =
      state.account.open_positions
      |> Enum.filter(fn {_id, trade} -> trade.symbol == symbol end)

    {:ok, exit_price, _slippage} =
      FillSimulator.exit_fill(state.fill_config, bar, :long)

    Enum.reduce(open_for_symbol, state, fn {trade_id, _trade}, acc_state ->
      close_trade(acc_state, trade_id, exit_price, bar.bar_time, status, false)
    end)
  end

  defp force_exit_all(state, bar, status) do
    {:ok, exit_price, _slippage} =
      FillSimulator.exit_fill(state.fill_config, bar, :long)

    Enum.reduce(state.account.open_positions, state, fn {trade_id, _trade}, acc_state ->
      close_trade(acc_state, trade_id, exit_price, bar.bar_time, status, false)
    end)
  end

  defp persist_trade(backtest_run_id, trade) do
    attrs = %{
      backtest_run_id: backtest_run_id,
      signal_id: trade.signal_id,
      symbol: trade.symbol,
      direction: trade.direction,
      entry_price: trade.entry_price,
      entry_time: trade.entry_time,
      position_size: trade.position_size,
      risk_amount: trade.risk_amount,
      stop_loss: trade.stop_loss,
      take_profit: trade.take_profit,
      status: trade.status,
      exit_price: trade.exit_price,
      exit_time: trade.exit_time,
      pnl: trade.pnl,
      pnl_pct: trade.pnl_pct,
      r_multiple: trade.r_multiple
    }

    case %SimulatedTrade{}
         |> SimulatedTrade.changeset(attrs)
         |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error("[TradeSimulator] Failed to persist trade: #{inspect(changeset.errors)}")
        :error
    end
  end
end
