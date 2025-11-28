defmodule Signal.Optimization.WalkForward do
  @moduledoc """
  Walk-forward optimization engine for parameter validation.

  Walk-forward analysis splits historical data into rolling training and testing
  windows to validate that optimized parameters perform well out-of-sample,
  helping to detect and prevent overfitting.

  ## How It Works

  1. Data is split into overlapping windows
  2. For each window:
     - Optimize parameters on the training period (in-sample)
     - Validate best params on the test period (out-of-sample)
  3. Aggregate out-of-sample results across all windows
  4. Compare in-sample vs out-of-sample performance

  ## Example

      config = WalkForward.new(%{
        training_months: 12,
        testing_months: 3,
        step_months: 3,
        optimization_metric: :profit_factor,
        min_trades: 30
      })

      windows = WalkForward.generate_windows(config, ~D[2020-01-01], ~D[2024-12-31])
      # => [
      #   %{training: {~D[2020-01-01], ~D[2020-12-31]}, testing: {~D[2021-01-01], ~D[2021-03-31]}, index: 0},
      #   %{training: {~D[2020-04-01], ~D[2021-03-31]}, testing: {~D[2021-04-01], ~D[2021-06-30]}, index: 1},
      #   ...
      # ]
  """

  defstruct [
    :training_months,
    :testing_months,
    :step_months,
    :optimization_metric,
    :min_trades,
    :anchored
  ]

  @type t :: %__MODULE__{
          training_months: pos_integer(),
          testing_months: pos_integer(),
          step_months: pos_integer(),
          optimization_metric: atom(),
          min_trades: non_neg_integer(),
          anchored: boolean()
        }

  @type window :: %{
          training: {Date.t(), Date.t()},
          testing: {Date.t(), Date.t()},
          index: non_neg_integer()
        }

  @valid_metrics [
    :profit_factor,
    :net_profit,
    :sharpe_ratio,
    :sortino_ratio,
    :win_rate,
    :expectancy,
    :calmar_ratio
  ]

  @doc """
  Creates a new walk-forward configuration.

  ## Parameters

    * `config` - Map with configuration options:
      * `:training_months` - Number of months for training period (default: 12)
      * `:testing_months` - Number of months for testing period (default: 3)
      * `:step_months` - Months to advance between windows (default: 3)
      * `:optimization_metric` - Metric to optimize (default: :profit_factor)
      * `:min_trades` - Minimum trades required for valid results (default: 30)
      * `:anchored` - If true, training always starts from beginning (default: false)

  ## Returns

    * `{:ok, %WalkForward{}}` - Configuration created
    * `{:error, reason}` - Invalid configuration
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(config \\ %{}) do
    with {:ok, training} <-
           validate_positive(:training_months, Map.get(config, :training_months, 12)),
         {:ok, testing} <-
           validate_positive(:testing_months, Map.get(config, :testing_months, 3)),
         {:ok, step} <- validate_positive(:step_months, Map.get(config, :step_months, 3)),
         {:ok, metric} <- validate_metric(Map.get(config, :optimization_metric, :profit_factor)),
         {:ok, min_trades} <- validate_non_negative(:min_trades, Map.get(config, :min_trades, 30)) do
      {:ok,
       %__MODULE__{
         training_months: training,
         testing_months: testing,
         step_months: step,
         optimization_metric: metric,
         min_trades: min_trades,
         anchored: Map.get(config, :anchored, false)
       }}
    end
  end

  @doc """
  Creates a new walk-forward configuration, raising on error.
  """
  @spec new!(map()) :: t()
  def new!(config \\ %{}) do
    case new(config) do
      {:ok, wf} -> wf
      {:error, reason} -> raise ArgumentError, "Invalid walk-forward config: #{inspect(reason)}"
    end
  end

  @doc """
  Generates all walk-forward windows for a date range.

  ## Parameters

    * `config` - WalkForward configuration
    * `start_date` - Overall start date
    * `end_date` - Overall end date

  ## Returns

    * List of window maps with :training and :testing date tuples
  """
  @spec generate_windows(t(), Date.t(), Date.t()) :: [window()]
  def generate_windows(%__MODULE__{} = config, start_date, end_date) do
    do_generate_windows(config, start_date, end_date, 0, [])
    |> Enum.reverse()
  end

  @doc """
  Returns the number of windows that will be generated.
  """
  @spec window_count(t(), Date.t(), Date.t()) :: non_neg_integer()
  def window_count(%__MODULE__{} = config, start_date, end_date) do
    generate_windows(config, start_date, end_date) |> length()
  end

  @doc """
  Validates that a window has sufficient data.

  Returns true if the window's training and testing periods
  are both valid (non-empty date ranges).
  """
  @spec valid_window?(window()) :: boolean()
  def valid_window?(%{training: {train_start, train_end}, testing: {test_start, test_end}}) do
    Date.compare(train_start, train_end) == :lt and
      Date.compare(test_start, test_end) == :lt and
      Date.compare(train_end, test_start) == :lt
  end

  @doc """
  Converts the configuration to a serializable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      "training_months" => config.training_months,
      "testing_months" => config.testing_months,
      "step_months" => config.step_months,
      "optimization_metric" => Atom.to_string(config.optimization_metric),
      "min_trades" => config.min_trades,
      "anchored" => config.anchored
    }
  end

  @doc """
  Creates a configuration from a serialized map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    metric =
      case Map.get(map, "optimization_metric") do
        nil -> :profit_factor
        m when is_binary(m) -> String.to_existing_atom(m)
        m when is_atom(m) -> m
      end

    new(%{
      training_months: Map.get(map, "training_months", 12),
      testing_months: Map.get(map, "testing_months", 3),
      step_months: Map.get(map, "step_months", 3),
      optimization_metric: metric,
      min_trades: Map.get(map, "min_trades", 30),
      anchored: Map.get(map, "anchored", false)
    })
  end

  @doc """
  Returns the list of valid optimization metrics.
  """
  @spec valid_metrics() :: [atom()]
  def valid_metrics, do: @valid_metrics

  @doc """
  Creates a default configuration with standard values.
  """
  @spec default() :: t()
  def default, do: new!()

  @doc """
  Calculates the minimum data requirement in months.

  Returns the minimum number of months of historical data
  required to run at least one walk-forward window.
  """
  @spec min_data_months(t()) :: pos_integer()
  def min_data_months(%__MODULE__{training_months: train, testing_months: test}) do
    train + test
  end

  # Private Functions

  defp do_generate_windows(config, start_date, end_date, index, acc) do
    {train_start, train_end, test_start, test_end} =
      calculate_window_dates(config, start_date, index)

    # Check if test period extends beyond end_date
    if Date.compare(test_end, end_date) == :gt do
      acc
    else
      window = %{
        training: {train_start, train_end},
        testing: {test_start, test_end},
        index: index
      }

      do_generate_windows(config, start_date, end_date, index + 1, [window | acc])
    end
  end

  defp calculate_window_dates(
         %__MODULE__{
           training_months: train_months,
           testing_months: test_months,
           step_months: step_months,
           anchored: anchored
         },
         start_date,
         index
       ) do
    # Calculate training start
    train_start =
      if anchored do
        start_date
      else
        add_months(start_date, index * step_months)
      end

    # Training period length grows if anchored
    actual_train_months =
      if anchored do
        train_months + index * step_months
      else
        train_months
      end

    # Calculate training end (last day of the training period)
    train_end =
      train_start
      |> add_months(actual_train_months)
      |> Date.add(-1)

    # Testing starts day after training ends
    test_start = Date.add(train_end, 1)

    # Testing end
    test_end =
      test_start
      |> add_months(test_months)
      |> Date.add(-1)

    {train_start, train_end, test_start, test_end}
  end

  defp add_months(date, months) do
    # Add months, handling month-end edge cases
    year = date.year + div(date.month + months - 1, 12)
    month = rem(date.month + months - 1, 12) + 1

    # Ensure valid day for the target month
    max_day = Calendar.ISO.days_in_month(year, month)
    day = min(date.day, max_day)

    Date.new!(year, month, day)
  end

  defp validate_positive(_field, value) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp validate_positive(field, value) do
    {:error, {field, "must be a positive integer, got: #{inspect(value)}"}}
  end

  defp validate_non_negative(_field, value) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp validate_non_negative(field, value) do
    {:error, {field, "must be a non-negative integer, got: #{inspect(value)}"}}
  end

  defp validate_metric(metric) when metric in @valid_metrics do
    {:ok, metric}
  end

  defp validate_metric(metric) do
    {:error,
     {:optimization_metric, "must be one of #{inspect(@valid_metrics)}, got: #{inspect(metric)}"}}
  end
end
