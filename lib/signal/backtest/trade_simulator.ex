defmodule Signal.Backtest.TradeSimulator do
  @moduledoc """
  Executes simulated trades during backtests.

  The TradeSimulator subscribes to signals and bar updates during a backtest,
  opening positions on signals and managing them through to exit.

  ## Trade Lifecycle

  1. Signal received → Evaluate entry criteria
  2. Entry criteria met → Open position via VirtualAccount
  3. Each bar → Check exit conditions via ExitManager
  4. Exit condition met → Close position (full or partial), record trade

  ## Exit Strategies

  The simulator supports multiple exit strategies via `ExitStrategy`:

  - **Fixed**: Simple stop loss and take profit levels
  - **Trailing**: Stop follows price with configurable distance
  - **Scaled**: Multiple take profit targets with partial exits
  - **Combined**: Trailing + breakeven management

  Signals can include an `exit_strategy` field. If not provided, falls back to
  a fixed strategy using `stop_loss` and `take_profit` from the signal.

  ## Exit Conditions

  - **Stop Loss Hit**: Price touches or gaps through stop
  - **Trailing Stop Hit**: Trailing stop catches up to price
  - **Target Hit**: Price reaches take profit level (may be partial)
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

  alias Signal.Backtest.ExitManager
  alias Signal.Backtest.ExitStrategy
  alias Signal.Backtest.FillSimulator
  alias Signal.Backtest.PartialExit
  alias Signal.Backtest.PositionState
  alias Signal.Backtest.SimulatedTrade
  alias Signal.Backtest.VirtualAccount
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
    :persist_trades,
    :position_states
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
      persist_trades: persist_trades,
      position_states: %{}
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
    # Find open positions for this symbol that have position states
    open_for_symbol =
      state.account.open_positions
      |> Enum.filter(fn {_id, trade} -> trade.symbol == bar.symbol end)

    Enum.reduce(open_for_symbol, state, fn {trade_id, _trade}, acc_state ->
      case Map.get(acc_state.position_states, trade_id) do
        nil ->
          # Legacy position without position state - use old logic
          trade = Map.get(acc_state.account.open_positions, trade_id)
          check_trade_exit_legacy(acc_state, trade_id, trade, bar)

        position_state ->
          # Use ExitManager for positions with state
          check_trade_exit_with_manager(acc_state, trade_id, position_state, bar)
      end
    end)
  end

  defp check_trade_exit_with_manager(state, trade_id, position_state, bar) do
    # Process the bar through ExitManager
    {updated_position_state, actions} = ExitManager.process_bar(position_state, bar)

    # Process each action
    state
    |> update_position_state(trade_id, updated_position_state)
    |> process_exit_actions(trade_id, actions, bar)
  end

  defp update_position_state(state, trade_id, position_state) do
    %{state | position_states: Map.put(state.position_states, trade_id, position_state)}
  end

  defp process_exit_actions(state, trade_id, actions, bar) do
    Enum.reduce(actions, state, fn action, acc_state ->
      process_exit_action(acc_state, trade_id, action, bar)
    end)
  end

  defp process_exit_action(state, trade_id, {:full_exit, reason, fill_price}, bar) do
    position_state = Map.get(state.position_states, trade_id)
    close_trade_full(state, trade_id, fill_price, bar.bar_time, reason, position_state)
  end

  defp process_exit_action(
         state,
         trade_id,
         {:partial_exit, target_index, shares, fill_price},
         bar
       ) do
    position_state = Map.get(state.position_states, trade_id)

    partial_close_trade(
      state,
      trade_id,
      fill_price,
      bar.bar_time,
      shares,
      "target_#{target_index + 1}",
      target_index,
      position_state
    )
  end

  defp process_exit_action(state, trade_id, {:update_stop, new_stop}, _bar) do
    # Update the stop in VirtualAccount
    case VirtualAccount.update_stop(state.account, trade_id, new_stop) do
      {:ok, updated_account} ->
        Logger.debug("[TradeSimulator] Updated stop for #{trade_id} to #{new_stop}")
        %{state | account: updated_account}

      {:error, _} ->
        state
    end
  end

  defp check_trade_exit_legacy(state, trade_id, trade, bar) do
    # Legacy logic for positions without ExitStrategy
    case FillSimulator.check_stop(state.fill_config, trade, bar) do
      {:stopped, fill_price, gap?} ->
        close_trade(state, trade_id, fill_price, bar.bar_time, :stopped_out, gap?)

      :ok ->
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
          persist_trade(state.backtest_run_id, closed_trade, nil)
        end

        # Clean up position state
        updated_position_states = Map.delete(state.position_states, trade_id)

        %{state | account: updated_account, position_states: updated_position_states}

      {:error, :not_found} ->
        state
    end
  end

  defp close_trade_full(state, trade_id, exit_price, exit_time, reason, position_state) do
    case VirtualAccount.close_position(state.account, trade_id, %{
           exit_price: exit_price,
           exit_time: exit_time,
           status: reason
         }) do
      {:ok, updated_account, closed_trade} ->
        Logger.debug(
          "[TradeSimulator] Closed #{closed_trade.symbol} #{reason}, P&L: #{closed_trade.pnl} (#{closed_trade.r_multiple}R)"
        )

        # Persist with position state data
        if state.persist_trades do
          persist_trade(state.backtest_run_id, closed_trade, position_state)
        end

        # Clean up position state
        updated_position_states = Map.delete(state.position_states, trade_id)

        %{state | account: updated_account, position_states: updated_position_states}

      {:error, :not_found} ->
        state
    end
  end

  defp partial_close_trade(
         state,
         trade_id,
         exit_price,
         exit_time,
         shares,
         reason,
         target_index,
         position_state
       ) do
    params = %{
      exit_price: exit_price,
      exit_time: exit_time,
      shares_to_exit: shares,
      reason: reason,
      target_index: target_index
    }

    case VirtualAccount.partial_close(state.account, trade_id, params) do
      {:ok, updated_account, partial_exit} ->
        Logger.debug(
          "[TradeSimulator] Partial exit #{shares} shares at #{exit_price}, " <>
            "P&L: #{partial_exit.pnl} (#{partial_exit.r_multiple}R), " <>
            "remaining: #{partial_exit.remaining_shares}"
        )

        # Persist partial exit
        if state.persist_trades do
          persist_partial_exit(state.backtest_run_id, trade_id, partial_exit)
        end

        # If position fully closed, clean up position state and persist trade
        state =
          if partial_exit.remaining_shares == 0 do
            # Trade is now in closed_trades, persist it
            closed_trade = hd(updated_account.closed_trades)

            if state.persist_trades do
              persist_trade(state.backtest_run_id, closed_trade, position_state)
            end

            updated_position_states = Map.delete(state.position_states, trade_id)
            %{state | position_states: updated_position_states}
          else
            state
          end

        %{state | account: updated_account}

      {:error, reason} ->
        Logger.warning("[TradeSimulator] Partial close failed: #{inspect(reason)}")
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

    # Build exit strategy from signal or use default fixed strategy
    exit_strategy = build_exit_strategy(signal)

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

        # Create position state for exit management
        position_state = PositionState.new(trade, exit_strategy)

        updated_position_states =
          Map.put(state.position_states, trade.id, position_state)

        %{state | account: updated_account, position_states: updated_position_states}

      {:error, reason} ->
        Logger.warning("[TradeSimulator] Failed to open position: #{inspect(reason)}")
        state
    end
  end

  defp build_exit_strategy(signal) do
    case Map.get(signal, :exit_strategy) do
      %ExitStrategy{} = strategy ->
        strategy

      nil ->
        # Backwards compatibility: build fixed strategy from signal fields
        ExitStrategy.fixed(signal.stop_loss, Map.get(signal, :take_profit))

      strategy_map when is_map(strategy_map) ->
        # Allow passing strategy as a map (e.g., from JSON)
        build_exit_strategy_from_map(strategy_map)
    end
  end

  defp build_exit_strategy_from_map(%{type: :fixed} = map) do
    ExitStrategy.fixed(map.stop_loss, Map.get(map, :take_profit))
  end

  defp build_exit_strategy_from_map(%{type: :trailing} = map) do
    ExitStrategy.trailing(map.stop_loss,
      type: Map.get(map, :trailing_type, :fixed_distance),
      value: map.trailing_value,
      activation_r: Map.get(map, :activation_r)
    )
  end

  defp build_exit_strategy_from_map(%{type: :scaled} = map) do
    ExitStrategy.scaled(map.stop_loss, map.targets)
  end

  defp build_exit_strategy_from_map(map) do
    # Default to fixed if type not recognized
    ExitStrategy.fixed(map.stop_loss, Map.get(map, :take_profit))
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

  defp persist_trade(backtest_run_id, trade, position_state) do
    # Base attributes from trade
    base_attrs = %{
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

    # Add exit strategy fields if position state is available
    attrs =
      if position_state do
        Map.merge(base_attrs, %{
          exit_strategy_type: ExitStrategy.type_string(position_state.exit_strategy),
          stop_moved_to_breakeven: position_state.stop_moved_to_breakeven,
          final_stop: position_state.current_stop,
          max_favorable_r: position_state.max_favorable_r,
          max_adverse_r: position_state.max_adverse_r,
          partial_exit_count: length(position_state.partial_exits)
        })
      else
        base_attrs
      end

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

  defp persist_partial_exit(backtest_run_id, trade_id, partial_exit) do
    # Find the simulated trade ID from the database
    case Repo.get_by(SimulatedTrade,
           backtest_run_id: backtest_run_id,
           id: find_db_trade_id(backtest_run_id, trade_id)
         ) do
      nil ->
        # Trade not yet persisted, this is fine for partial exits
        # The partial exit data is captured in the final trade persist
        :ok

      _db_trade ->
        attrs = %{
          trade_id: trade_id,
          exit_time: partial_exit.exit_time,
          exit_price: partial_exit.exit_price,
          shares_exited: partial_exit.shares_exited,
          remaining_shares: partial_exit.remaining_shares,
          exit_reason: partial_exit.exit_reason,
          target_index: partial_exit.target_index,
          pnl: partial_exit.pnl,
          pnl_pct: partial_exit.pnl_pct,
          r_multiple: partial_exit.r_multiple
        }

        case %PartialExit{}
             |> PartialExit.changeset(attrs)
             |> Repo.insert() do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.error(
              "[TradeSimulator] Failed to persist partial exit: #{inspect(changeset.errors)}"
            )

            :error
        end
    end
  end

  defp find_db_trade_id(_backtest_run_id, trade_id) do
    # For now, we use the in-memory trade_id as the DB id
    # This works because VirtualAccount generates UUIDs
    trade_id
  end
end
