defmodule Signal.Backtest.OptionsTradeSimulator do
  @moduledoc """
  Simulates options trades during backtests.

  This module extends the standard trade simulation to handle options-specific
  concerns like contract selection, premium-based P&L, and expiration handling.

  ## Trade Flow

  1. Signal received with underlying symbol and direction
  2. Resolve to options contract (call for long, put for short)
  3. Look up entry premium from historical options bars
  4. Calculate position size (number of contracts) based on risk
  5. On each bar: check exit conditions (underlying stop/target, premium, expiration)
  6. On exit: look up exit premium and calculate P&L

  ## Usage

      # Create simulator with configuration
      simulator = OptionsTradeSimulator.new(
        account: virtual_account,
        config: Config.options(strike_selection: :atm)
      )

      # Execute a signal
      {:ok, simulator, trade} = OptionsTradeSimulator.execute_signal(
        simulator,
        signal,
        underlying_bar,
        options_bar
      )

      # Check exit conditions
      {:exit, reason, simulator} = OptionsTradeSimulator.check_exit(
        simulator,
        trade_id,
        underlying_bar,
        options_bar
      )
  """

  require Logger

  alias Signal.Instruments.Config
  alias Signal.Instruments.Resolver
  alias Signal.Instruments.OptionsContract
  alias Signal.Options.PriceLookup
  alias Signal.Options.PositionSizer
  alias Signal.Options.ExitHandler

  defstruct [
    :account,
    :config,
    :open_positions,
    :closed_trades
  ]

  @type t :: %__MODULE__{
          account: map(),
          config: Config.t(),
          open_positions: %{String.t() => map()},
          closed_trades: [map()]
        }

  @doc """
  Creates a new options trade simulator.

  ## Parameters

    * `opts` - Keyword options:
      - `:account` - Virtual account state (map with :current_equity, :risk_per_trade, :cash)
      - `:config` - Instruments Config for options selection

  ## Returns

    * `%OptionsTradeSimulator{}` struct
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    account = Keyword.get(opts, :account, default_account())
    config = Keyword.get(opts, :config, Config.options())

    %__MODULE__{
      account: account,
      config: config,
      open_positions: %{},
      closed_trades: []
    }
  end

  @doc """
  Executes a signal by opening an options position.

  Resolves the signal to an options contract, looks up the entry premium,
  calculates position size, and opens the trade.

  ## Parameters

    * `simulator` - Current simulator state
    * `signal` - Trade signal with symbol, direction, stop_loss, etc.
    * `underlying_bar` - Current bar for the underlying symbol
    * `options_bar` - Current bar for the options contract (or nil to look up)

  ## Returns

    * `{:ok, updated_simulator, trade}` - Trade opened successfully
    * `{:error, reason}` - Failed to open trade
  """
  @spec execute_signal(t(), map(), map(), map() | nil) ::
          {:ok, t(), map()} | {:error, atom() | tuple()}
  def execute_signal(simulator, signal, underlying_bar, options_bar \\ nil) do
    with {:ok, contract} <- resolve_contract(signal, simulator.config),
         {:ok, entry_premium} <- get_entry_premium(contract, underlying_bar, options_bar),
         {:ok, num_contracts, total_cost} <- calculate_position(simulator, entry_premium) do
      trade =
        build_trade(signal, contract, entry_premium, num_contracts, total_cost, underlying_bar)

      # Update account cash
      updated_account = %{
        simulator.account
        | cash: Decimal.sub(simulator.account.cash, total_cost)
      }

      updated_simulator = %{
        simulator
        | account: updated_account,
          open_positions: Map.put(simulator.open_positions, trade.id, trade)
      }

      Logger.debug(
        "[OptionsTradeSimulator] Opened #{contract.contract_type} #{contract.contract_symbol} " <>
          "#{num_contracts} contracts at $#{entry_premium} premium, total cost: $#{total_cost}"
      )

      {:ok, updated_simulator, trade}
    end
  end

  @doc """
  Checks exit conditions for an open options position.

  Evaluates expiration, premium targets/stops, and underlying price levels.

  ## Parameters

    * `simulator` - Current simulator state
    * `trade_id` - ID of the trade to check
    * `underlying_bar` - Current bar for the underlying symbol
    * `options_bar` - Current bar for the options contract

  ## Returns

    * `{:exit, reason, exit_price, updated_simulator}` - Position should be closed
    * `{:hold, simulator}` - Position should be held
    * `{:error, :not_found}` - Trade not found
  """
  @spec check_exit(t(), String.t(), map(), map()) ::
          {:exit, atom(), Decimal.t(), t()} | {:hold, t()} | {:error, atom()}
  def check_exit(simulator, trade_id, underlying_bar, options_bar) do
    case Map.get(simulator.open_positions, trade_id) do
      nil ->
        {:error, :not_found}

      trade ->
        position = build_exit_position(trade)

        case ExitHandler.check_exit(position, options_bar, underlying_bar) do
          {:exit, reason, _trigger_price} ->
            # Get actual options exit price
            exit_premium = get_exit_premium_from_bar(options_bar, reason)

            {:exit, reason, exit_premium, simulator}

          :hold ->
            {:hold, simulator}
        end
    end
  end

  @doc """
  Closes an options position.

  ## Parameters

    * `simulator` - Current simulator state
    * `trade_id` - ID of the trade to close
    * `exit_premium` - Exit premium per share
    * `exit_time` - Exit timestamp
    * `exit_reason` - Reason for exit

  ## Returns

    * `{:ok, updated_simulator, closed_trade}` - Position closed successfully
    * `{:error, :not_found}` - Trade not found
  """
  @spec close_position(t(), String.t(), Decimal.t(), DateTime.t(), atom()) ::
          {:ok, t(), map()} | {:error, atom()}
  def close_position(simulator, trade_id, exit_premium, exit_time, exit_reason) do
    case Map.get(simulator.open_positions, trade_id) do
      nil ->
        {:error, :not_found}

      trade ->
        # Calculate P&L
        pnl_data = calculate_options_pnl(trade, exit_premium)

        # Calculate exit value (cash returned)
        exit_value =
          exit_premium
          |> Decimal.mult(Decimal.new(100))
          |> Decimal.mult(Decimal.new(trade.num_contracts))

        # Create closed trade record
        closed_trade =
          Map.merge(trade, %{
            status: exit_reason,
            exit_premium: exit_premium,
            exit_time: exit_time,
            pnl: pnl_data.pnl,
            pnl_pct: pnl_data.pnl_pct,
            r_multiple: pnl_data.r_multiple,
            options_exit_reason: Atom.to_string(exit_reason)
          })

        # Update account
        updated_account = %{
          simulator.account
          | cash: Decimal.add(simulator.account.cash, exit_value),
            current_equity: Decimal.add(simulator.account.current_equity, pnl_data.pnl)
        }

        updated_simulator = %{
          simulator
          | account: updated_account,
            open_positions: Map.delete(simulator.open_positions, trade_id),
            closed_trades: [closed_trade | simulator.closed_trades]
        }

        Logger.debug(
          "[OptionsTradeSimulator] Closed #{trade.contract_symbol} #{exit_reason}, " <>
            "P&L: $#{pnl_data.pnl} (#{pnl_data.r_multiple}R)"
        )

        {:ok, updated_simulator, closed_trade}
    end
  end

  @doc """
  Processes a bar update, checking all open positions for exits.

  ## Parameters

    * `simulator` - Current simulator state
    * `underlying_bar` - Current bar for the underlying
    * `options_bars` - Map of contract_symbol => options bar

  ## Returns

    * Updated simulator with any closed positions
  """
  @spec process_bars(t(), map(), map()) :: t()
  def process_bars(simulator, underlying_bar, options_bars) do
    Enum.reduce(simulator.open_positions, simulator, fn {trade_id, trade}, acc_sim ->
      options_bar = Map.get(options_bars, trade.contract_symbol)

      if options_bar do
        case check_exit(acc_sim, trade_id, underlying_bar, options_bar) do
          {:exit, reason, exit_premium, _} ->
            {:ok, updated_sim, _closed} =
              close_position(acc_sim, trade_id, exit_premium, underlying_bar.bar_time, reason)

            updated_sim

          {:hold, _} ->
            acc_sim

          {:error, _} ->
            acc_sim
        end
      else
        # No options bar available - skip this position
        acc_sim
      end
    end)
  end

  @doc """
  Returns summary statistics for the simulator.
  """
  @spec summary(t()) :: map()
  def summary(simulator) do
    closed = simulator.closed_trades

    winners = Enum.filter(closed, &(Decimal.compare(&1.pnl, Decimal.new(0)) == :gt))
    losers = Enum.filter(closed, &(Decimal.compare(&1.pnl, Decimal.new(0)) == :lt))

    total_pnl =
      Enum.reduce(closed, Decimal.new(0), fn trade, acc ->
        Decimal.add(acc, trade.pnl || Decimal.new(0))
      end)

    %{
      total_trades: length(closed),
      open_positions: map_size(simulator.open_positions),
      winners: length(winners),
      losers: length(losers),
      win_rate:
        if(length(closed) > 0,
          do: Float.round(length(winners) / length(closed) * 100, 1),
          else: 0.0
        ),
      total_pnl: total_pnl,
      current_equity: simulator.account.current_equity
    }
  end

  @doc """
  Converts a closed trade to attributes suitable for SimulatedTrade persistence.
  """
  @spec trade_to_attrs(map(), Ecto.UUID.t()) :: map()
  def trade_to_attrs(trade, backtest_run_id) do
    %{
      backtest_run_id: backtest_run_id,
      signal_id: trade.signal_id,
      symbol: trade.underlying_symbol,
      direction: trade.direction,
      entry_price: trade.entry_premium,
      entry_time: trade.entry_time,
      position_size: trade.num_contracts,
      risk_amount: trade.risk_amount,
      stop_loss: trade.stop_loss,
      take_profit: trade.take_profit,
      status: trade.status,
      exit_price: trade.exit_premium,
      exit_time: trade.exit_time,
      pnl: trade.pnl,
      pnl_pct: trade.pnl_pct,
      r_multiple: trade.r_multiple,
      # Options-specific fields
      instrument_type: "options",
      contract_symbol: trade.contract_symbol,
      underlying_symbol: trade.underlying_symbol,
      contract_type: Atom.to_string(trade.contract_type),
      strike: trade.strike,
      expiration_date: trade.expiration,
      entry_premium: trade.entry_premium,
      exit_premium: trade.exit_premium,
      num_contracts: trade.num_contracts,
      options_exit_reason: trade.options_exit_reason
    }
  end

  # Private Functions

  defp default_account do
    %{
      current_equity: Decimal.new("100000"),
      risk_per_trade: Decimal.new("0.01"),
      cash: Decimal.new("100000")
    }
  end

  defp resolve_contract(signal, config) do
    case Resolver.resolve(signal, config) do
      {:ok, %OptionsContract{} = contract} ->
        {:ok, contract}

      {:ok, _equity} ->
        {:error, :expected_options_contract}

      {:error, _} = error ->
        error
    end
  end

  defp get_entry_premium(contract, underlying_bar, nil) do
    # Look up premium from database
    PriceLookup.get_entry_price(contract.contract_symbol, underlying_bar.bar_time)
  end

  defp get_entry_premium(_contract, _underlying_bar, options_bar) do
    # Use provided bar
    {:ok, options_bar.open}
  end

  defp calculate_position(simulator, entry_premium) do
    PositionSizer.from_equity(
      account_equity: simulator.account.current_equity,
      risk_percentage: simulator.account.risk_per_trade,
      entry_premium: entry_premium,
      available_cash: simulator.account.cash
    )
  end

  defp build_trade(signal, contract, entry_premium, num_contracts, total_cost, bar) do
    %{
      id: Ecto.UUID.generate(),
      signal_id: Map.get(signal, :id),
      # Options-specific
      contract_symbol: contract.contract_symbol,
      underlying_symbol: contract.underlying_symbol,
      contract_type: contract.contract_type,
      strike: contract.strike,
      expiration: contract.expiration,
      entry_premium: entry_premium,
      num_contracts: num_contracts,
      total_cost: total_cost,
      # From signal
      direction: signal.direction,
      stop_loss: signal.stop_loss,
      take_profit: Map.get(signal, :take_profit),
      # Premium targets (optional)
      premium_target: Map.get(signal, :premium_target),
      premium_floor: Map.get(signal, :premium_floor),
      # Tracking
      entry_time: bar.bar_time,
      status: :open,
      risk_amount: total_cost,
      exit_premium: nil,
      exit_time: nil,
      pnl: nil,
      pnl_pct: nil,
      r_multiple: nil,
      options_exit_reason: nil
    }
  end

  defp build_exit_position(trade) do
    %{
      expiration: trade.expiration,
      direction: trade.direction,
      stop_loss: trade.stop_loss,
      take_profit: trade.take_profit,
      premium_target: trade.premium_target,
      premium_floor: trade.premium_floor,
      entry_premium: trade.entry_premium
    }
  end

  defp get_exit_premium_from_bar(options_bar, reason) do
    case reason do
      # For premium-based exits, use the trigger price
      :premium_target -> options_bar.high
      :premium_stop -> options_bar.low
      # For other exits, use the close
      _ -> options_bar.close
    end
  end

  defp calculate_options_pnl(trade, exit_premium) do
    entry_cost = trade.total_cost
    multiplier = 100

    # Exit value
    exit_value =
      exit_premium
      |> Decimal.mult(Decimal.new(multiplier))
      |> Decimal.mult(Decimal.new(trade.num_contracts))

    # P&L
    pnl = Decimal.sub(exit_value, entry_cost)

    # P&L percentage (based on cost)
    pnl_pct =
      if Decimal.compare(entry_cost, Decimal.new(0)) == :gt do
        pnl
        |> Decimal.div(entry_cost)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(2)
      else
        Decimal.new(0)
      end

    # R-multiple (P&L / risk amount)
    # For options, risk is the premium paid
    r_multiple =
      if Decimal.compare(trade.risk_amount, Decimal.new(0)) == :gt do
        Decimal.div(pnl, trade.risk_amount) |> Decimal.round(2)
      else
        Decimal.new(0)
      end

    %{
      pnl: Decimal.round(pnl, 2),
      pnl_pct: pnl_pct,
      r_multiple: r_multiple
    }
  end
end
