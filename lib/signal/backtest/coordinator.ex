defmodule Signal.Backtest.Coordinator do
  @moduledoc """
  Orchestrates complete backtest runs.

  The Coordinator is the main entry point for running backtests. It:
  1. Creates and persists a BacktestRun record
  2. Initializes isolated state via StateManager
  3. Starts the BarReplayer to stream historical data
  4. Collects signals generated during replay
  5. Cleans up state after completion

  ## Usage

      {:ok, result} = Signal.Backtest.Coordinator.run(%{
        symbols: ["AAPL", "TSLA"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-03-31],
        strategies: [:break_and_retest],
        parameters: %{min_confluence: 7},
        initial_capital: Decimal.new("100000"),
        risk_per_trade: Decimal.new("0.01")
      })

  ## Progress Tracking

  The coordinator can report progress via a callback:

      Coordinator.run(config, fn progress ->
        IO.puts("Progress: \#{progress.pct_complete}%")
      end)

  ## Result

  On completion, returns:

      %{
        run_id: "uuid",
        status: :completed,
        bars_processed: 50000,
        signals_generated: 150,
        duration_seconds: 45,
        ...
      }
  """

  require Logger

  alias Signal.Analytics
  alias Signal.Backtest.BacktestRun
  alias Signal.Backtest.StateManager
  alias Signal.Backtest.BarReplayer
  alias Signal.Backtest.VirtualAccount
  alias Signal.Backtest.TradeSimulator
  alias Signal.Backtest.SignalCollector
  alias Signal.Backtest.FillSimulator
  alias Signal.Repo

  @doc """
  Runs a complete backtest with the given configuration.

  ## Parameters

    * `config` - Map with backtest configuration:
      * `:symbols` - List of symbols to backtest (required)
      * `:start_date` - Start date (required)
      * `:end_date` - End date (required)
      * `:strategies` - List of strategy atoms (required)
      * `:initial_capital` - Starting capital as Decimal (required)
      * `:risk_per_trade` - Risk per trade as Decimal, e.g., 0.01 for 1% (required)
      * `:parameters` - Strategy parameters map (optional)
      * `:speed` - `:instant` or `:realtime` (default: `:instant`)
      * `:session_filter` - `:regular` or `:all` (default: `:regular`)
      * `:unlimited_capital` - When true, executes every signal regardless of capital (signal evaluation mode)

    * `progress_callback` - Optional function called with progress updates

  ## Returns

    * `{:ok, result}` - Backtest completed successfully
    * `{:error, reason}` - Backtest failed
  """
  @spec run(map(), function() | nil) :: {:ok, map()} | {:error, term()}
  def run(config, progress_callback \\ nil) do
    with {:ok, config} <- validate_config(config),
         {:ok, run} <- create_run(config),
         {:ok, result} <- execute_backtest(run, config, progress_callback) do
      {:ok, result}
    else
      {:error, {:missing_required_fields, _}} = error ->
        # Validation errors are expected, don't log as errors
        error

      {:error, %Ecto.Changeset{}} = error ->
        # Changeset validation errors are expected, don't log as errors
        error

      {:error, reason} = error ->
        Logger.error("[Coordinator] Backtest failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Runs a backtest asynchronously, returning immediately with the run_id.

  The backtest executes in a separate process. Use `get_status/1` to check progress.

  ## Returns

    * `{:ok, run_id}` - Backtest started
    * `{:error, reason}` - Failed to start
  """
  @spec run_async(map(), function() | nil) :: {:ok, String.t()} | {:error, term()}
  def run_async(config, progress_callback \\ nil) do
    with {:ok, config} <- validate_config(config),
         {:ok, run} <- create_run(config) do
      # Start backtest in a separate process
      Task.start(fn ->
        execute_backtest(run, config, progress_callback)
      end)

      {:ok, run.id}
    end
  end

  @doc """
  Gets the status of a backtest run.
  """
  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(run_id) do
    case Repo.get(BacktestRun, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        {:ok,
         %{
           run_id: run.id,
           status: run.status,
           progress_pct: run.progress_pct,
           current_date: run.current_date,
           bars_processed: run.bars_processed,
           signals_generated: run.signals_generated,
           started_at: run.started_at,
           completed_at: run.completed_at,
           error_message: run.error_message
         }}
    end
  end

  @doc """
  Cancels a running backtest.
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(run_id) do
    # Stop the replayer if running
    case StateManager.get_replayer(run_id) do
      nil -> :ok
      replayer -> BarReplayer.stop(replayer)
    end

    # Cleanup state
    StateManager.cleanup(run_id)

    # Update run status
    case Repo.get(BacktestRun, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        run
        |> BacktestRun.changeset(%{status: :cancelled, completed_at: DateTime.utc_now()})
        |> Repo.update()

        :ok
    end
  end

  # Private Functions

  defp validate_config(config) do
    required_keys = [
      :symbols,
      :start_date,
      :end_date,
      :strategies,
      :initial_capital,
      :risk_per_trade
    ]

    missing_keys = Enum.filter(required_keys, &(!Map.has_key?(config, &1)))

    if Enum.empty?(missing_keys) do
      {:ok, config}
    else
      {:error, {:missing_required_fields, missing_keys}}
    end
  end

  defp create_run(config) do
    attrs = %{
      symbols: config.symbols,
      start_date: config.start_date,
      end_date: config.end_date,
      strategies: Enum.map(config.strategies, &to_string/1),
      parameters: Map.get(config, :parameters, %{}),
      initial_capital: config.initial_capital,
      risk_per_trade: config.risk_per_trade
    }

    %BacktestRun{}
    |> BacktestRun.changeset(attrs)
    |> Repo.insert()
  end

  defp execute_backtest(run, config, progress_callback) do
    run_id = run.id
    start_time = System.monotonic_time(:second)

    Logger.info("[Coordinator] Starting backtest #{run_id}")

    try do
      # Mark as running
      run
      |> BacktestRun.start_changeset()
      |> Repo.update!()

      # Initialize isolated state
      {:ok, _state} = StateManager.init_backtest(run_id, config.symbols)

      # Get the clock
      clock = StateManager.get_clock(run_id)

      # Create virtual account for trade simulation
      # Pass unlimited_capital option for signal evaluation mode
      signal_eval_mode = Map.get(config, :unlimited_capital, false)

      account_opts =
        if signal_eval_mode do
          [unlimited_capital: true]
        else
          []
        end

      account = VirtualAccount.new(config.initial_capital, config.risk_per_trade, account_opts)

      # Create fill simulator config
      # In signal evaluation mode, use bar_close to get actual market price at signal time
      # In normal mode, use signal_price (calculated entry levels)
      fill_type = if signal_eval_mode, do: :bar_close, else: :signal_price
      fill_config = FillSimulator.new(fill_type)

      # Start trade simulator
      trade_simulator_opts = [
        run_id: run_id,
        backtest_run_id: run_id,
        account: account,
        fill_config: fill_config,
        clock: clock,
        symbols: config.symbols,
        persist_trades: true
      ]

      {:ok, trade_simulator} = TradeSimulator.start_link(trade_simulator_opts)

      # Start signal collector
      signal_collector_opts = [
        run_id: run_id,
        symbols: config.symbols,
        strategies: config.strategies,
        trade_simulator: trade_simulator,
        clock: clock,
        min_rr: Map.get(config, :parameters, %{}) |> Map.get(:min_rr, Decimal.new("2.0"))
      ]

      {:ok, signal_collector} = SignalCollector.start_link(signal_collector_opts)

      # Create bar callback that forwards bars to signal collector and trade simulator
      bar_callback = fn bar ->
        SignalCollector.process_bar(signal_collector, bar)
        TradeSimulator.process_bar(trade_simulator, bar)
      end

      # Start the bar replayer with bar callback
      replayer_opts = [
        run_id: run_id,
        symbols: config.symbols,
        start_date: config.start_date,
        end_date: config.end_date,
        clock: clock,
        speed: Map.get(config, :speed, :instant),
        session_filter: Map.get(config, :session_filter, :regular),
        bar_callback: bar_callback
      ]

      {:ok, replayer} = BarReplayer.start_link(replayer_opts)

      # Create progress handler that updates the database
      db_progress_callback = fn progress ->
        update_progress(run_id, progress)

        if progress_callback do
          progress_callback.(progress)
        end
      end

      # Start replay and wait for completion
      BarReplayer.start_replay(replayer, db_progress_callback)

      # Wait for replay to complete
      wait_for_completion(replayer)

      # Get final status from all components
      final_status = BarReplayer.status(replayer)
      signals_count = SignalCollector.signals_count(signal_collector)
      final_account = TradeSimulator.get_account(trade_simulator)

      # Stop the trade simulator and signal collector
      TradeSimulator.stop(trade_simulator)
      SignalCollector.stop(signal_collector)

      # Cleanup state
      StateManager.cleanup(run_id)

      # Calculate duration
      duration = System.monotonic_time(:second) - start_time

      # Calculate trade stats
      total_trades = final_account.trade_count

      winning_trades =
        Enum.count(final_account.closed_trades, fn t -> Decimal.positive?(t.pnl) end)

      losing_trades =
        Enum.count(final_account.closed_trades, fn t -> Decimal.negative?(t.pnl) end)

      total_pnl =
        Enum.reduce(final_account.closed_trades, Decimal.new(0), fn t, acc ->
          Decimal.add(acc, t.pnl || Decimal.new(0))
        end)

      # Calculate comprehensive analytics
      backtest_data = %{
        closed_trades: final_account.closed_trades,
        equity_curve: final_account.equity_curve,
        initial_capital: config.initial_capital
      }

      analytics =
        case Analytics.analyze_backtest(backtest_data) do
          {:ok, analytics} ->
            # Persist analytics results
            case Analytics.persist_results(run_id, analytics) do
              {:ok, _result} ->
                Logger.debug("[Coordinator] Analytics persisted for run #{run_id}")

              {:error, reason} ->
                Logger.warning("[Coordinator] Failed to persist analytics: #{inspect(reason)}")
            end

            analytics

          {:error, reason} ->
            Logger.warning("[Coordinator] Failed to calculate analytics: #{inspect(reason)}")
            nil
        end

      # Mark as completed
      run = Repo.get!(BacktestRun, run_id)

      run
      |> BacktestRun.complete_changeset()
      |> BacktestRun.changeset(%{
        bars_processed: final_status.bars_processed,
        signals_generated: signals_count
      })
      |> Repo.update!()

      Logger.info(
        "[Coordinator] Backtest #{run_id} completed in #{duration}s, " <>
          "processed #{final_status.bars_processed} bars, " <>
          "generated #{signals_count} signals, executed #{total_trades} trades"
      )

      {:ok,
       %{
         run_id: run_id,
         status: :completed,
         bars_processed: final_status.bars_processed,
         signals_generated: signals_count,
         duration_seconds: duration,
         # Trade stats
         total_trades: total_trades,
         winning_trades: winning_trades,
         losing_trades: losing_trades,
         win_rate: if(total_trades > 0, do: winning_trades / total_trades * 100, else: 0.0),
         total_pnl: total_pnl,
         final_equity: final_account.current_equity,
         # Analytics
         analytics: analytics,
         # Detailed data
         closed_trades: final_account.closed_trades,
         equity_curve: final_account.equity_curve
       }}
    rescue
      error ->
        Logger.error("[Coordinator] Backtest #{run_id} failed: #{inspect(error)}")

        # Cleanup on error
        StateManager.cleanup(run_id)

        # Mark as failed
        case Repo.get(BacktestRun, run_id) do
          nil ->
            :ok

          run ->
            run
            |> BacktestRun.fail_changeset(Exception.message(error))
            |> Repo.update()
        end

        {:error, error}
    end
  end

  defp update_progress(run_id, progress) do
    case Repo.get(BacktestRun, run_id) do
      nil ->
        :ok

      run ->
        current_date =
          if progress.current_time do
            DateTime.to_date(progress.current_time)
          else
            nil
          end

        run
        |> BacktestRun.progress_changeset(%{
          progress_pct: Decimal.from_float(progress.pct_complete),
          current_date: current_date,
          bars_processed: progress.bars_processed
        })
        |> Repo.update()
    end
  end

  defp wait_for_completion(replayer) do
    case BarReplayer.status(replayer) do
      %{status: :completed} ->
        :ok

      %{status: :failed} ->
        :ok

      _ ->
        Process.sleep(100)
        wait_for_completion(replayer)
    end
  end
end
