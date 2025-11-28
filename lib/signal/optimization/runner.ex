defmodule Signal.Optimization.Runner do
  @moduledoc """
  Executes optimization runs across parameter combinations.

  The Runner orchestrates the execution of backtests across all parameter
  combinations in a grid, optionally using walk-forward analysis for
  out-of-sample validation.

  ## Usage

  ### Simple Grid Search

      {:ok, result} = Runner.run(%{
        symbols: ["AAPL", "TSLA"],
        start_date: ~D[2023-01-01],
        end_date: ~D[2024-12-31],
        strategies: [:break_and_retest],
        initial_capital: Decimal.new("100000"),
        base_risk_per_trade: Decimal.new("0.01"),
        parameter_grid: %{
          min_confluence_score: [6, 7, 8],
          min_rr: [2.0, 2.5, 3.0]
        }
      })

  ### Walk-Forward Optimization

      {:ok, result} = Runner.run(%{
        symbols: ["AAPL", "TSLA"],
        start_date: ~D[2020-01-01],
        end_date: ~D[2024-12-31],
        strategies: [:break_and_retest],
        initial_capital: Decimal.new("100000"),
        base_risk_per_trade: Decimal.new("0.01"),
        parameter_grid: %{
          min_confluence_score: [6, 7, 8],
          min_rr: [2.0, 2.5, 3.0]
        },
        walk_forward_config: %{
          training_months: 12,
          testing_months: 3,
          step_months: 3
        }
      })

  ## Parallel Execution

  By default, backtests run in parallel using all available CPU cores.
  Control concurrency with the `:max_concurrency` option.
  """

  require Logger

  alias Signal.Backtest.Coordinator
  alias Signal.Optimization.ParameterGrid
  alias Signal.Optimization.WalkForward
  alias Signal.Optimization.OptimizationRun
  alias Signal.Optimization.OptimizationResult
  alias Signal.Optimization.Validation
  alias Signal.Repo

  import Ecto.Query

  @default_max_concurrency System.schedulers_online()

  @doc """
  Runs an optimization with the given configuration.

  ## Parameters

    * `config` - Map with optimization configuration:
      * `:symbols` - List of symbols to test (required)
      * `:start_date` - Start date for data (required)
      * `:end_date` - End date for data (required)
      * `:strategies` - List of strategy atoms (required)
      * `:initial_capital` - Starting capital as Decimal (required)
      * `:base_risk_per_trade` - Base risk per trade (required)
      * `:parameter_grid` - Map of parameter ranges (required)
      * `:walk_forward_config` - Walk-forward settings (optional)
      * `:optimization_metric` - Metric to optimize (default: :profit_factor)
      * `:min_trades` - Minimum trades for valid results (default: 30)
      * `:max_concurrency` - Max parallel backtests (default: CPU count)
      * `:name` - Name for this optimization run (optional)

    * `progress_callback` - Optional function called with progress updates

  ## Returns

    * `{:ok, result}` - Optimization completed successfully
    * `{:error, reason}` - Optimization failed
  """
  @spec run(map(), function() | nil) :: {:ok, map()} | {:error, term()}
  def run(config, progress_callback \\ nil) do
    with {:ok, config} <- validate_config(config),
         {:ok, grid} <- ParameterGrid.new(config.parameter_grid),
         {:ok, wf_config} <- maybe_create_walk_forward(config),
         {:ok, run} <- create_run(config, grid, wf_config) do
      execute_optimization(run, config, grid, wf_config, progress_callback)
    end
  end

  @doc """
  Runs an optimization asynchronously.

  Returns immediately with the run ID. Use `get_status/1` to check progress.
  """
  @spec run_async(map(), function() | nil) :: {:ok, String.t()} | {:error, term()}
  def run_async(config, progress_callback \\ nil) do
    with {:ok, config} <- validate_config(config),
         {:ok, grid} <- ParameterGrid.new(config.parameter_grid),
         {:ok, wf_config} <- maybe_create_walk_forward(config),
         {:ok, run} <- create_run(config, grid, wf_config) do
      Task.start(fn ->
        execute_optimization(run, config, grid, wf_config, progress_callback)
      end)

      {:ok, run.id}
    end
  end

  @doc """
  Gets the status of an optimization run.
  """
  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(run_id) do
    case Repo.get(OptimizationRun, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        {:ok,
         %{
           run_id: run.id,
           name: run.name,
           status: run.status,
           progress_pct: run.progress_pct,
           total_combinations: run.total_combinations,
           completed_combinations: run.completed_combinations,
           started_at: run.started_at,
           completed_at: run.completed_at,
           best_params: run.best_params,
           error_message: run.error_message
         }}
    end
  end

  @doc """
  Cancels a running optimization.
  """
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(run_id) do
    case Repo.get(OptimizationRun, run_id) do
      nil ->
        {:error, :not_found}

      run ->
        run
        |> OptimizationRun.cancel_changeset()
        |> Repo.update()

        :ok
    end
  end

  @doc """
  Gets results for an optimization run, sorted by the optimization metric.
  """
  @spec get_results(String.t(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def get_results(run_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    metric = Keyword.get(opts, :metric, :profit_factor)
    training_only = Keyword.get(opts, :training_only, true)

    query =
      from(r in OptimizationResult,
        where: r.optimization_run_id == ^run_id,
        order_by: [desc_nulls_last: field(r, ^metric)],
        limit: ^limit
      )

    query =
      if training_only do
        from(r in query, where: r.is_training == true)
      else
        query
      end

    results = Repo.all(query)
    {:ok, results}
  end

  # Private Functions

  defp validate_config(config) do
    required_keys = [
      :symbols,
      :start_date,
      :end_date,
      :strategies,
      :initial_capital,
      :base_risk_per_trade,
      :parameter_grid
    ]

    missing_keys = Enum.filter(required_keys, &(!Map.has_key?(config, &1)))

    if Enum.empty?(missing_keys) do
      {:ok, config}
    else
      {:error, {:missing_required_fields, missing_keys}}
    end
  end

  defp maybe_create_walk_forward(%{walk_forward_config: wf_config}) when is_map(wf_config) do
    WalkForward.new(wf_config)
  end

  defp maybe_create_walk_forward(_), do: {:ok, nil}

  defp create_run(config, grid, wf_config) do
    attrs = %{
      name: Map.get(config, :name),
      symbols: config.symbols,
      start_date: config.start_date,
      end_date: config.end_date,
      strategies: Enum.map(config.strategies, &to_string/1),
      initial_capital: config.initial_capital,
      base_risk_per_trade: config.base_risk_per_trade,
      parameter_grid: ParameterGrid.to_map(grid),
      walk_forward_config: if(wf_config, do: WalkForward.to_map(wf_config), else: %{}),
      optimization_metric: to_string(Map.get(config, :optimization_metric, :profit_factor)),
      min_trades: Map.get(config, :min_trades, 30),
      total_combinations: ParameterGrid.count(grid)
    }

    %OptimizationRun{}
    |> OptimizationRun.changeset(attrs)
    |> Repo.insert()
  end

  defp execute_optimization(run, config, grid, wf_config, progress_callback) do
    run_id = run.id
    start_time = System.monotonic_time(:second)

    Logger.info("[Optimization] Starting optimization #{run_id}")

    try do
      # Mark as running
      run
      |> OptimizationRun.start_changeset()
      |> Repo.update!()

      # Execute based on whether we have walk-forward config
      result =
        if wf_config do
          run_walk_forward(run, config, grid, wf_config, progress_callback)
        else
          run_grid_search(run, config, grid, progress_callback)
        end

      duration = System.monotonic_time(:second) - start_time
      Logger.info("[Optimization] Optimization #{run_id} completed in #{duration}s")

      result
    rescue
      error ->
        Logger.error("[Optimization] Optimization #{run_id} failed: #{inspect(error)}")

        case Repo.get(OptimizationRun, run_id) do
          nil -> :ok
          run -> run |> OptimizationRun.fail_changeset(Exception.message(error)) |> Repo.update()
        end

        {:error, error}
    end
  end

  defp run_grid_search(run, config, grid, progress_callback) do
    run_id = run.id
    combinations = ParameterGrid.combinations(grid)
    total = length(combinations)
    max_concurrency = Map.get(config, :max_concurrency, @default_max_concurrency)
    min_trades = Map.get(config, :min_trades, 30)

    Logger.info("[Optimization] Running grid search with #{total} combinations")

    # Run all backtests in parallel
    results =
      combinations
      |> Task.async_stream(
        fn params ->
          run_single_backtest(run_id, config, params, nil)
        end,
        max_concurrency: max_concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Stream.with_index(1)
      |> Enum.map(fn {{:ok, result}, index} ->
        # Update progress
        update_progress(run_id, index, total, progress_callback)
        result
      end)

    # Find best result
    metric = Map.get(config, :optimization_metric, :profit_factor)
    best = find_best_result(results, metric, min_trades)

    # Mark as completed
    run = Repo.get!(OptimizationRun, run_id)

    run
    |> OptimizationRun.complete_changeset(best && best.parameters)
    |> Repo.update!()

    {:ok,
     %{
       run_id: run_id,
       status: :completed,
       total_combinations: total,
       best_params: best && best.parameters,
       best_metrics: best && extract_metrics(best)
     }}
  end

  defp run_walk_forward(run, config, grid, wf_config, progress_callback) do
    run_id = run.id
    combinations = ParameterGrid.combinations(grid)
    windows = WalkForward.generate_windows(wf_config, config.start_date, config.end_date)
    total_backtests = length(combinations) * length(windows) * 2
    max_concurrency = Map.get(config, :max_concurrency, @default_max_concurrency)
    min_trades = Map.get(config, :min_trades, 30)
    metric = Map.get(config, :optimization_metric, :profit_factor)

    Logger.info(
      "[Optimization] Running walk-forward with #{length(combinations)} combinations " <>
        "across #{length(windows)} windows (#{total_backtests} total backtests)"
    )

    completed_count = :counters.new(1, [:atomics])

    # For each window, find the best params on training, then test on OOS
    window_results =
      Enum.map(windows, fn window ->
        Logger.debug("[Optimization] Processing window #{window.index}")

        # Run training backtests for all params
        training_results =
          combinations
          |> Task.async_stream(
            fn params ->
              result =
                run_single_backtest(
                  run_id,
                  config,
                  params,
                  window,
                  true
                )

              :counters.add(completed_count, 1, 1)
              count = :counters.get(completed_count, 1)
              update_progress(run_id, count, total_backtests, progress_callback)
              result
            end,
            max_concurrency: max_concurrency,
            timeout: :infinity,
            ordered: false
          )
          |> Enum.map(fn {:ok, result} -> result end)

        # Find best params from training
        best_training = find_best_result(training_results, metric, min_trades)

        # Run OOS test with best params
        oos_result =
          if best_training do
            result =
              run_single_backtest(
                run_id,
                config,
                best_training.parameters,
                window,
                false
              )

            :counters.add(completed_count, 1, 1)
            count = :counters.get(completed_count, 1)
            update_progress(run_id, count, total_backtests, progress_callback)
            result
          else
            nil
          end

        %{
          window: window,
          best_training: best_training,
          oos_result: oos_result
        }
      end)

    # Aggregate OOS results and run validation
    validation_results = Validation.analyze_walk_forward(window_results, metric)

    # Find best overall params based on aggregated OOS performance
    best_params = Validation.best_params(validation_results)

    # Update optimization results with validation metrics
    update_validation_metrics(run_id, validation_results)

    # Mark as completed
    run = Repo.get!(OptimizationRun, run_id)

    run
    |> OptimizationRun.complete_changeset(best_params)
    |> Repo.update!()

    {:ok,
     %{
       run_id: run_id,
       status: :completed,
       total_combinations: length(combinations),
       windows: length(windows),
       best_params: best_params,
       validation_results: validation_results
     }}
  end

  defp run_single_backtest(run_id, config, params, window, is_training \\ true) do
    # Determine date range
    {start_date, end_date} =
      if window do
        if is_training do
          window.training
        else
          window.testing
        end
      else
        {config.start_date, config.end_date}
      end

    # Build backtest config
    backtest_config = %{
      symbols: config.symbols,
      start_date: start_date,
      end_date: end_date,
      strategies: config.strategies,
      initial_capital: config.initial_capital,
      risk_per_trade: Map.get(params, :risk_per_trade, config.base_risk_per_trade),
      parameters: params,
      speed: :instant
    }

    # Run backtest
    case Coordinator.run(backtest_config) do
      {:ok, backtest_result} ->
        # Persist optimization result
        result_attrs =
          build_result_attrs(
            run_id,
            backtest_result,
            params,
            window,
            is_training
          )

        {:ok, opt_result} =
          %OptimizationResult{}
          |> OptimizationResult.changeset(result_attrs)
          |> Repo.insert()

        opt_result

      {:error, reason} ->
        Logger.warning(
          "[Optimization] Backtest failed for params #{inspect(params)}: #{inspect(reason)}"
        )

        # Still record the failed attempt
        result_attrs = %{
          optimization_run_id: run_id,
          parameters: serialize_params(params),
          window_index: window && window.index,
          window_start_date:
            window && elem(if(is_training, do: window.training, else: window.testing), 0),
          window_end_date:
            window && elem(if(is_training, do: window.training, else: window.testing), 1),
          is_training: is_training,
          total_trades: 0
        }

        {:ok, opt_result} =
          %OptimizationResult{}
          |> OptimizationResult.changeset(result_attrs)
          |> Repo.insert()

        opt_result
    end
  end

  defp build_result_attrs(run_id, backtest_result, params, window, is_training) do
    analytics = backtest_result.analytics || %{}
    metrics = OptimizationResult.from_backtest_analytics(analytics)

    base_attrs = %{
      optimization_run_id: run_id,
      backtest_run_id: backtest_result.run_id,
      parameters: serialize_params(params),
      is_training: is_training
    }

    window_attrs =
      if window do
        {start_date, end_date} =
          if is_training, do: window.training, else: window.testing

        %{
          window_index: window.index,
          window_start_date: start_date,
          window_end_date: end_date
        }
      else
        %{}
      end

    base_attrs
    |> Map.merge(window_attrs)
    |> Map.merge(metrics)
  end

  defp serialize_params(params) do
    params
    |> Enum.map(fn {key, value} ->
      serialized_value =
        case value do
          %Decimal{} = d -> Decimal.to_string(d)
          atom when is_atom(atom) -> Atom.to_string(atom)
          other -> other
        end

      {to_string(key), serialized_value}
    end)
    |> Map.new()
  end

  defp find_best_result(results, metric, min_trades) do
    results
    |> Enum.filter(fn r -> (r.total_trades || 0) >= min_trades end)
    |> Enum.max_by(
      fn r -> Map.get(r, metric) |> decimal_to_float() end,
      fn -> nil end
    )
  end

  defp decimal_to_float(nil), do: 0.0
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(f) when is_float(f), do: f
  defp decimal_to_float(i) when is_integer(i), do: i / 1

  defp extract_metrics(result) do
    %{
      profit_factor: result.profit_factor,
      net_profit: result.net_profit,
      win_rate: result.win_rate,
      total_trades: result.total_trades,
      sharpe_ratio: result.sharpe_ratio,
      max_drawdown_pct: result.max_drawdown_pct
    }
  end

  defp update_progress(run_id, completed, total, callback) do
    pct = completed / total * 100

    case Repo.get(OptimizationRun, run_id) do
      nil ->
        :ok

      run ->
        run
        |> OptimizationRun.progress_changeset(%{
          completed_combinations: completed,
          progress_pct: Decimal.from_float(pct)
        })
        |> Repo.update()
    end

    if callback do
      callback.(%{
        completed: completed,
        total: total,
        pct_complete: pct
      })
    end
  end

  defp update_validation_metrics(run_id, validation_results) do
    Enum.each(validation_results, fn validation ->
      # Find the training result for these params
      query =
        from(r in OptimizationResult,
          where: r.optimization_run_id == ^run_id,
          where: r.parameters == ^validation.params,
          where: r.is_training == true,
          where: is_nil(r.window_index)
        )

      case Repo.one(query) do
        nil ->
          :ok

        result ->
          result
          |> OptimizationResult.validation_changeset(%{
            degradation_pct: validation.degradation_pct,
            walk_forward_efficiency: validation.walk_forward_efficiency,
            is_overfit: validation.is_overfit,
            oos_profit_factor: validation.oos_profit_factor,
            oos_net_profit: validation.oos_net_profit,
            oos_win_rate: validation.oos_win_rate,
            oos_total_trades: validation.oos_total_trades
          })
          |> Repo.update()
      end
    end)
  end
end
