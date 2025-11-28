defmodule Signal.Optimization.Validation do
  @moduledoc """
  Validates optimization results and detects overfitting.

  This module analyzes the relationship between in-sample (training) and
  out-of-sample (testing) performance to identify parameter combinations
  that may be overfit to historical data.

  ## Overfitting Detection

  A parameter set is flagged as potentially overfit when:
  - Performance degrades more than 30% from in-sample to out-of-sample
  - Walk-forward efficiency is below 50%

  ## Walk-Forward Efficiency

  Measures how well optimized parameters perform out-of-sample:

      efficiency = OOS_profit / IS_profit

  An efficiency of 0.70 means out-of-sample profits were 70% of in-sample.
  Values above 0.50 are generally acceptable.

  ## Usage

      # Analyze walk-forward results
      validation_results = Validation.analyze_walk_forward(window_results, :profit_factor)

      # Get best non-overfit params
      best_params = Validation.best_params(validation_results)

      # Check single result
      {:ok, validation} = Validation.validate_result(training_metrics, oos_metrics)
  """

  @overfit_threshold 0.30
  @min_efficiency 0.50

  @type validation_result :: %{
          params: map(),
          in_sample_metric: Decimal.t() | nil,
          out_of_sample_metric: Decimal.t() | nil,
          degradation_pct: Decimal.t() | nil,
          walk_forward_efficiency: Decimal.t() | nil,
          is_overfit: boolean(),
          oos_profit_factor: Decimal.t() | nil,
          oos_net_profit: Decimal.t() | nil,
          oos_win_rate: Decimal.t() | nil,
          oos_total_trades: non_neg_integer()
        }

  @doc """
  Analyzes walk-forward results to detect overfitting.

  Takes the results from all walk-forward windows and calculates
  aggregate out-of-sample performance for each unique parameter set.

  ## Parameters

    * `window_results` - List of window result maps from Runner
    * `metric` - The optimization metric to analyze

  ## Returns

    * List of validation result maps
  """
  @spec analyze_walk_forward([map()], atom()) :: [validation_result()]
  def analyze_walk_forward(window_results, metric \\ :profit_factor) do
    # Group results by parameter set
    by_params =
      window_results
      |> Enum.filter(fn wr -> wr.best_training != nil end)
      |> Enum.group_by(fn wr -> wr.best_training.parameters end)

    # Calculate aggregated metrics for each param set
    Enum.map(by_params, fn {params, windows} ->
      analyze_param_set(params, windows, metric)
    end)
    |> Enum.sort_by(fn v -> decimal_to_float(v.oos_profit_factor) end, :desc)
  end

  @doc """
  Validates a single parameter set's in-sample vs out-of-sample performance.

  ## Parameters

    * `in_sample` - Training period metrics (map or struct)
    * `out_of_sample` - Testing period metrics (map or struct)
    * `metric` - The metric to compare (default: :profit_factor)

  ## Returns

    * `{:ok, validation}` - Validation result
  """
  @spec validate_result(map(), map(), atom()) :: {:ok, map()}
  def validate_result(in_sample, out_of_sample, metric \\ :profit_factor) do
    is_value = get_metric(in_sample, metric)
    oos_value = get_metric(out_of_sample, metric)

    {degradation, efficiency} = calculate_metrics(is_value, oos_value)
    is_overfit = check_overfit(degradation, efficiency)

    {:ok,
     %{
       in_sample_metric: is_value,
       out_of_sample_metric: oos_value,
       degradation_pct: degradation,
       walk_forward_efficiency: efficiency,
       is_overfit: is_overfit
     }}
  end

  @doc """
  Calculates performance degradation between in-sample and out-of-sample.

  Degradation = (IS - OOS) / IS * 100

  A positive value indicates OOS underperformed IS.
  """
  @spec calculate_degradation(Decimal.t() | number(), Decimal.t() | number()) :: Decimal.t() | nil
  def calculate_degradation(in_sample, out_of_sample) do
    is_val = to_decimal(in_sample)
    oos_val = to_decimal(out_of_sample)

    cond do
      is_nil(is_val) or is_nil(oos_val) ->
        nil

      Decimal.compare(is_val, Decimal.new(0)) == :eq ->
        nil

      true ->
        diff = Decimal.sub(is_val, oos_val)
        Decimal.div(diff, is_val) |> Decimal.mult(Decimal.new(100)) |> Decimal.round(2)
    end
  end

  @doc """
  Calculates walk-forward efficiency.

  Efficiency = OOS / IS

  Values closer to 1.0 indicate parameters generalize well.
  """
  @spec calculate_efficiency(Decimal.t() | number(), Decimal.t() | number()) :: Decimal.t() | nil
  def calculate_efficiency(in_sample, out_of_sample) do
    is_val = to_decimal(in_sample)
    oos_val = to_decimal(out_of_sample)

    cond do
      is_nil(is_val) or is_nil(oos_val) ->
        nil

      Decimal.compare(is_val, Decimal.new(0)) == :eq ->
        nil

      Decimal.compare(is_val, Decimal.new(0)) == :lt ->
        # Negative IS - if OOS is also negative, calculate normally
        Decimal.div(oos_val, is_val) |> Decimal.round(2)

      true ->
        Decimal.div(oos_val, is_val) |> Decimal.round(2)
    end
  end

  @doc """
  Returns the best parameters based on out-of-sample performance.

  Filters out overfit parameters and returns the params with the
  highest OOS profit factor.
  """
  @spec best_params([validation_result()]) :: map() | nil
  def best_params(validation_results) do
    validation_results
    |> Enum.reject(& &1.is_overfit)
    |> Enum.max_by(fn v -> decimal_to_float(v.oos_profit_factor) end, fn -> nil end)
    |> case do
      nil -> nil
      v -> v.params
    end
  end

  @doc """
  Returns the best non-overfit validation result.
  """
  @spec best_result([validation_result()]) :: validation_result() | nil
  def best_result(validation_results) do
    validation_results
    |> Enum.reject(& &1.is_overfit)
    |> Enum.max_by(fn v -> decimal_to_float(v.oos_profit_factor) end, fn -> nil end)
  end

  @doc """
  Filters validation results to only non-overfit parameter sets.
  """
  @spec filter_valid([validation_result()]) :: [validation_result()]
  def filter_valid(validation_results) do
    Enum.reject(validation_results, & &1.is_overfit)
  end

  @doc """
  Returns the overfit threshold (30% degradation).
  """
  @spec overfit_threshold() :: float()
  def overfit_threshold, do: @overfit_threshold

  @doc """
  Returns the minimum acceptable efficiency (50%).
  """
  @spec min_efficiency() :: float()
  def min_efficiency, do: @min_efficiency

  # Private Functions

  defp analyze_param_set(params, windows, metric) do
    # Aggregate in-sample metrics
    is_metrics = Enum.map(windows, fn w -> w.best_training end) |> Enum.reject(&is_nil/1)

    # Aggregate out-of-sample metrics
    oos_metrics = Enum.map(windows, fn w -> w.oos_result end) |> Enum.reject(&is_nil/1)

    # Calculate aggregate values
    is_metric_values = Enum.map(is_metrics, &get_metric(&1, metric)) |> Enum.reject(&is_nil/1)
    oos_metric_values = Enum.map(oos_metrics, &get_metric(&1, metric)) |> Enum.reject(&is_nil/1)

    avg_is = average_decimals(is_metric_values)
    avg_oos = average_decimals(oos_metric_values)

    {degradation, efficiency} = calculate_metrics(avg_is, avg_oos)
    is_overfit = check_overfit(degradation, efficiency)

    # Aggregate OOS performance metrics
    oos_profit_factors =
      Enum.map(oos_metrics, &get_metric(&1, :profit_factor)) |> Enum.reject(&is_nil/1)

    oos_net_profits =
      Enum.map(oos_metrics, &get_metric(&1, :net_profit)) |> Enum.reject(&is_nil/1)

    oos_win_rates = Enum.map(oos_metrics, &get_metric(&1, :win_rate)) |> Enum.reject(&is_nil/1)
    oos_trades = Enum.map(oos_metrics, &(get_metric(&1, :total_trades) || 0)) |> Enum.sum()

    %{
      params: params,
      in_sample_metric: avg_is,
      out_of_sample_metric: avg_oos,
      degradation_pct: degradation,
      walk_forward_efficiency: efficiency,
      is_overfit: is_overfit,
      oos_profit_factor: average_decimals(oos_profit_factors),
      oos_net_profit: sum_decimals(oos_net_profits),
      oos_win_rate: average_decimals(oos_win_rates),
      oos_total_trades: oos_trades
    }
  end

  defp calculate_metrics(is_value, oos_value) do
    degradation = calculate_degradation(is_value, oos_value)
    efficiency = calculate_efficiency(is_value, oos_value)
    {degradation, efficiency}
  end

  defp check_overfit(degradation, efficiency) do
    degradation_check =
      case degradation do
        nil -> false
        d -> Decimal.compare(d, Decimal.from_float(@overfit_threshold * 100)) == :gt
      end

    efficiency_check =
      case efficiency do
        nil -> false
        e -> Decimal.compare(e, Decimal.from_float(@min_efficiency)) == :lt
      end

    degradation_check or efficiency_check
  end

  defp get_metric(nil, _key), do: nil

  defp get_metric(%{__struct__: _} = struct, key) do
    Map.get(struct, key)
  end

  defp get_metric(map, key) when is_map(map) do
    Map.get(map, key)
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(f) when is_float(f), do: Decimal.from_float(f)
  defp to_decimal(i) when is_integer(i), do: Decimal.new(i)

  defp decimal_to_float(nil), do: 0.0
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(f) when is_float(f), do: f
  defp decimal_to_float(i) when is_integer(i), do: i / 1

  defp average_decimals([]), do: nil

  defp average_decimals(values) do
    sum = Enum.reduce(values, Decimal.new(0), &Decimal.add/2)
    Decimal.div(sum, Decimal.new(length(values))) |> Decimal.round(2)
  end

  defp sum_decimals([]), do: nil

  defp sum_decimals(values) do
    Enum.reduce(values, Decimal.new(0), &Decimal.add/2) |> Decimal.round(2)
  end
end
