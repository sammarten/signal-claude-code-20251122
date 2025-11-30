defmodule Signal.Optimization.ParameterGrid do
  @moduledoc """
  Defines and generates parameter combinations for optimization.

  The ParameterGrid allows you to define ranges of values for each parameter
  you want to optimize. It then generates all possible combinations (cartesian product)
  of these parameters for testing.

  ## Usage

      grid = ParameterGrid.new(%{
        min_confluence_score: [5, 6, 7, 8, 9],
        min_risk_reward: [1.5, 2.0, 2.5, 3.0],
        signal_grade_filter: [:all, :c_and_above, :b_and_above, :a_only],
        risk_per_trade: [0.01, 0.015, 0.02]
      })

      ParameterGrid.count(grid)  # => 60

      combinations = ParameterGrid.combinations(grid)
      # => [%{min_confluence_score: 5, min_risk_reward: 1.5, ...}, ...]

  ## Supported Parameters

  - `min_confluence_score` - Minimum confluence score to take a signal (1-10)
  - `min_risk_reward` - Minimum risk/reward ratio (e.g., 2.0 = 2:1)
  - `signal_grade_filter` - Filter signals by grade (:all, :c_and_above, :b_and_above, :a_only)
  - `entry_model` - Entry timing (:conservative, :aggressive)
  - `risk_per_trade` - Percentage of equity to risk per trade (0.01 = 1%)
  - `time_exit_hour` - Hour (ET) to force exit open positions (e.g., 11 for 11:00 AM)
  - `max_daily_trades` - Maximum trades per day per symbol
  """

  defstruct [
    :parameters,
    :param_names,
    :total_combinations
  ]

  @type t :: %__MODULE__{
          parameters: %{atom() => list()},
          param_names: [atom()],
          total_combinations: non_neg_integer()
        }

  @valid_params [
    # Strategy parameters
    :min_confluence_score,
    :min_risk_reward,
    :signal_grade_filter,
    :entry_model,
    :risk_per_trade,
    :time_exit_hour,
    :max_daily_trades,
    :min_rr,
    # Options parameters
    :instrument_type,
    :expiration_preference,
    :strike_selection,
    :slippage_pct,
    :premium_target_multiple,
    :premium_floor_pct
  ]

  @doc """
  Creates a new parameter grid from a map of parameter ranges.

  ## Parameters

    * `params` - Map where keys are parameter names and values are lists of values to test

  ## Returns

    * `{:ok, %ParameterGrid{}}` - Grid created successfully
    * `{:error, reason}` - Invalid parameters
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(params) when is_map(params) do
    with :ok <- validate_params(params) do
      param_names = Map.keys(params) |> Enum.sort()
      total = calculate_combinations(params)

      {:ok,
       %__MODULE__{
         parameters: params,
         param_names: param_names,
         total_combinations: total
       }}
    end
  end

  @doc """
  Creates a new parameter grid, raising on error.
  """
  @spec new!(map()) :: t()
  def new!(params) do
    case new(params) do
      {:ok, grid} -> grid
      {:error, reason} -> raise ArgumentError, "Invalid parameter grid: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the total number of parameter combinations in the grid.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{total_combinations: total}), do: total

  @doc """
  Generates all parameter combinations as a list of maps.

  Each map contains one complete set of parameters to test.

  ## Options

    * `:shuffle` - If true, randomize the order of combinations (default: false)
    * `:limit` - Maximum number of combinations to return (default: all)

  ## Returns

    * List of parameter maps
  """
  @spec combinations(t(), keyword()) :: [map()]
  def combinations(%__MODULE__{parameters: params, param_names: names}, opts \\ []) do
    shuffle = Keyword.get(opts, :shuffle, false)
    limit = Keyword.get(opts, :limit, nil)

    # Generate cartesian product
    combos = cartesian_product(params, names)

    # Optionally shuffle
    combos = if shuffle, do: Enum.shuffle(combos), else: combos

    # Optionally limit
    if limit, do: Enum.take(combos, limit), else: combos
  end

  @doc """
  Returns a stream of parameter combinations for memory efficiency.

  Useful when dealing with very large parameter spaces.
  """
  @spec stream(t()) :: Enumerable.t()
  def stream(%__MODULE__{parameters: params, param_names: names}) do
    stream_cartesian_product(params, names)
  end

  @doc """
  Gets the value ranges for a specific parameter.
  """
  @spec get_values(t(), atom()) :: list() | nil
  def get_values(%__MODULE__{parameters: params}, param_name) do
    Map.get(params, param_name)
  end

  @doc """
  Adds or updates a parameter range in the grid.
  """
  @spec put_param(t(), atom(), list()) :: {:ok, t()} | {:error, term()}
  def put_param(%__MODULE__{parameters: params} = grid, name, values) when is_list(values) do
    new_params = Map.put(params, name, values)

    with :ok <- validate_params(new_params) do
      {:ok,
       %{
         grid
         | parameters: new_params,
           param_names: Map.keys(new_params) |> Enum.sort(),
           total_combinations: calculate_combinations(new_params)
       }}
    end
  end

  @doc """
  Removes a parameter from the grid.
  """
  @spec remove_param(t(), atom()) :: t()
  def remove_param(%__MODULE__{parameters: params} = grid, name) do
    new_params = Map.delete(params, name)

    %{
      grid
      | parameters: new_params,
        param_names: Map.keys(new_params) |> Enum.sort(),
        total_combinations: calculate_combinations(new_params)
    }
  end

  @doc """
  Converts the grid to a serializable map (for database storage).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{parameters: params}) do
    params
    |> Enum.map(fn {key, values} ->
      {Atom.to_string(key), serialize_values(values)}
    end)
    |> Map.new()
  end

  @doc """
  Creates a grid from a serialized map (from database).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    params =
      map
      |> Enum.map(fn {key, values} ->
        atom_key = if is_binary(key), do: String.to_existing_atom(key), else: key
        {atom_key, deserialize_values(values)}
      end)
      |> Map.new()

    new(params)
  end

  @doc """
  Creates a default parameter grid with common optimization ranges.
  """
  @spec default() :: t()
  def default do
    new!(%{
      min_confluence_score: [5, 6, 7, 8, 9],
      min_rr: [Decimal.new("1.5"), Decimal.new("2.0"), Decimal.new("2.5"), Decimal.new("3.0")],
      signal_grade_filter: [:all, :c_and_above, :b_and_above, :a_only],
      risk_per_trade: [Decimal.new("0.01"), Decimal.new("0.015"), Decimal.new("0.02")]
    })
  end

  @doc """
  Lists all valid parameter names.
  """
  @spec valid_params() :: [atom()]
  def valid_params, do: @valid_params

  # Private Functions

  defp validate_params(params) when map_size(params) == 0 do
    {:error, :empty_grid}
  end

  defp validate_params(params) do
    Enum.reduce_while(params, :ok, fn {key, values}, :ok ->
      cond do
        not is_atom(key) ->
          {:halt, {:error, {:invalid_param_name, key}}}

        not is_list(values) ->
          {:halt, {:error, {:invalid_values, key, "must be a list"}}}

        Enum.empty?(values) ->
          {:halt, {:error, {:empty_values, key}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp calculate_combinations(params) when map_size(params) == 0, do: 0

  defp calculate_combinations(params) do
    params
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.product()
  end

  defp cartesian_product(params, names) do
    names
    |> Enum.map(fn name -> Map.get(params, name) end)
    |> cartesian_product_lists()
    |> Enum.map(fn values ->
      Enum.zip(names, values) |> Map.new()
    end)
  end

  defp cartesian_product_lists([]), do: [[]]

  defp cartesian_product_lists([head | tail]) do
    tail_product = cartesian_product_lists(tail)

    for x <- head, y <- tail_product do
      [x | y]
    end
  end

  defp stream_cartesian_product(params, names) do
    value_lists = Enum.map(names, fn name -> Map.get(params, name) end)

    Stream.unfold(
      initial_indices(value_lists),
      fn indices ->
        if indices == :done do
          nil
        else
          values = get_values_at_indices(value_lists, indices)
          combo = Enum.zip(names, values) |> Map.new()
          next_indices = increment_indices(indices, value_lists)
          {combo, next_indices}
        end
      end
    )
  end

  defp initial_indices(value_lists) do
    if Enum.any?(value_lists, &Enum.empty?/1) do
      :done
    else
      List.duplicate(0, length(value_lists))
    end
  end

  defp get_values_at_indices(value_lists, indices) do
    Enum.zip(value_lists, indices)
    |> Enum.map(fn {list, idx} -> Enum.at(list, idx) end)
  end

  defp increment_indices(indices, value_lists) do
    do_increment(Enum.reverse(indices), Enum.reverse(value_lists), [])
  end

  defp do_increment([], [], _acc), do: :done

  defp do_increment([idx | rest_idx], [list | rest_lists], acc) do
    if idx + 1 < length(list) do
      Enum.reverse(rest_idx) ++ [idx + 1 | acc]
    else
      do_increment(rest_idx, rest_lists, [0 | acc])
    end
  end

  defp serialize_values(values) do
    Enum.map(values, fn
      %Decimal{} = d -> %{"_type" => "decimal", "value" => Decimal.to_string(d)}
      atom when is_atom(atom) -> %{"_type" => "atom", "value" => Atom.to_string(atom)}
      other -> other
    end)
  end

  defp deserialize_values(values) do
    Enum.map(values, fn
      %{"_type" => "decimal", "value" => v} -> Decimal.new(v)
      %{"_type" => "atom", "value" => v} -> String.to_existing_atom(v)
      other -> other
    end)
  end
end
