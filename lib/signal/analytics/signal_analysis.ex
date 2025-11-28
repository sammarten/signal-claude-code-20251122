defmodule Signal.Analytics.SignalAnalysis do
  @moduledoc """
  Analyzes trading performance by signal characteristics.

  ## Metrics Calculated

  - **By Grade**: Performance by signal quality grade (A, B, C, D, F)
  - **By Strategy**: Performance by trading strategy
  - **By Symbol**: Performance by trading symbol
  - **By Direction**: Long vs short performance
  - **By Exit Type**: Performance by how trades were closed

  ## Usage

      trades = account.closed_trades
      {:ok, analysis} = SignalAnalysis.calculate(trades)

      analysis.by_grade["A"].win_rate  # => Decimal.new("78.00")
      analysis.by_strategy["break_and_retest"].profit_factor  # => Decimal.new("2.80")
  """

  defmodule GradeStats do
    @moduledoc "Statistics for a specific signal grade."
    defstruct [
      :grade,
      :count,
      :winners,
      :losers,
      :win_rate,
      :profit_factor,
      :net_pnl,
      :avg_r,
      :avg_pnl,
      :total_r
    ]

    @type t :: %__MODULE__{
            grade: String.t(),
            count: non_neg_integer(),
            winners: non_neg_integer(),
            losers: non_neg_integer(),
            win_rate: Decimal.t(),
            profit_factor: Decimal.t() | nil,
            net_pnl: Decimal.t(),
            avg_r: Decimal.t() | nil,
            avg_pnl: Decimal.t(),
            total_r: Decimal.t()
          }
  end

  defmodule StrategyStats do
    @moduledoc "Statistics for a specific strategy."
    defstruct [
      :strategy,
      :count,
      :winners,
      :losers,
      :win_rate,
      :profit_factor,
      :net_pnl,
      :avg_r,
      :avg_pnl,
      :total_r
    ]

    @type t :: %__MODULE__{
            strategy: String.t(),
            count: non_neg_integer(),
            winners: non_neg_integer(),
            losers: non_neg_integer(),
            win_rate: Decimal.t(),
            profit_factor: Decimal.t() | nil,
            net_pnl: Decimal.t(),
            avg_r: Decimal.t() | nil,
            avg_pnl: Decimal.t(),
            total_r: Decimal.t()
          }
  end

  defmodule SymbolStats do
    @moduledoc "Statistics for a specific symbol."
    defstruct [
      :symbol,
      :count,
      :winners,
      :losers,
      :win_rate,
      :profit_factor,
      :net_pnl,
      :avg_r,
      :avg_pnl,
      :total_r
    ]

    @type t :: %__MODULE__{
            symbol: String.t(),
            count: non_neg_integer(),
            winners: non_neg_integer(),
            losers: non_neg_integer(),
            win_rate: Decimal.t(),
            profit_factor: Decimal.t() | nil,
            net_pnl: Decimal.t(),
            avg_r: Decimal.t() | nil,
            avg_pnl: Decimal.t(),
            total_r: Decimal.t()
          }
  end

  defmodule DirectionStats do
    @moduledoc "Statistics for a trade direction."
    defstruct [
      :direction,
      :count,
      :winners,
      :losers,
      :win_rate,
      :profit_factor,
      :net_pnl,
      :avg_r,
      :avg_pnl,
      :total_r
    ]

    @type t :: %__MODULE__{
            direction: atom(),
            count: non_neg_integer(),
            winners: non_neg_integer(),
            losers: non_neg_integer(),
            win_rate: Decimal.t(),
            profit_factor: Decimal.t() | nil,
            net_pnl: Decimal.t(),
            avg_r: Decimal.t() | nil,
            avg_pnl: Decimal.t(),
            total_r: Decimal.t()
          }
  end

  defmodule ExitStats do
    @moduledoc "Statistics for an exit type."
    defstruct [
      :exit_type,
      :count,
      :winners,
      :losers,
      :win_rate,
      :profit_factor,
      :net_pnl,
      :avg_r,
      :avg_pnl,
      :total_r
    ]

    @type t :: %__MODULE__{
            exit_type: atom(),
            count: non_neg_integer(),
            winners: non_neg_integer(),
            losers: non_neg_integer(),
            win_rate: Decimal.t(),
            profit_factor: Decimal.t() | nil,
            net_pnl: Decimal.t(),
            avg_r: Decimal.t() | nil,
            avg_pnl: Decimal.t(),
            total_r: Decimal.t()
          }
  end

  defstruct [
    :by_grade,
    :by_strategy,
    :by_symbol,
    :by_direction,
    :by_exit_type,
    :best_grade,
    :worst_grade,
    :best_strategy,
    :worst_strategy,
    :best_symbol,
    :worst_symbol
  ]

  @type t :: %__MODULE__{
          by_grade: %{String.t() => GradeStats.t()},
          by_strategy: %{String.t() => StrategyStats.t()},
          by_symbol: %{String.t() => SymbolStats.t()},
          by_direction: %{atom() => DirectionStats.t()},
          by_exit_type: %{atom() => ExitStats.t()},
          best_grade: String.t() | nil,
          worst_grade: String.t() | nil,
          best_strategy: String.t() | nil,
          worst_strategy: String.t() | nil,
          best_symbol: String.t() | nil,
          worst_symbol: String.t() | nil
        }

  @zero Decimal.new(0)
  @min_trades_for_ranking 5

  @doc """
  Calculates signal-based performance analysis.

  ## Parameters

    * `trades` - List of trade maps with signal metadata

  Trade maps should contain:
    * `:pnl` - Profit/loss
    * `:r_multiple` - R-multiple
    * `:symbol` - Trading symbol
    * `:direction` - `:long` or `:short`
    * `:status` - Exit type (`:stopped_out`, `:target_hit`, `:time_exit`, etc.)
    * `:quality_grade` - Signal grade (optional, from signal data)
    * `:strategy` - Strategy name (optional, from signal data)

  ## Returns

    * `{:ok, %SignalAnalysis{}}` - Analysis completed
    * `{:error, reason}` - Analysis failed
  """
  @spec calculate(list(map())) :: {:ok, t()} | {:error, term()}
  def calculate(trades) when is_list(trades) do
    grade_stats = by_grade(trades)
    strategy_stats = by_strategy(trades)
    symbol_stats = by_symbol(trades)
    direction_stats = by_direction(trades)
    exit_stats = by_exit_type(trades)

    {best_grade, worst_grade} = find_best_worst(grade_stats, :grade)
    {best_strategy, worst_strategy} = find_best_worst(strategy_stats, :strategy)
    {best_symbol, worst_symbol} = find_best_worst(symbol_stats, :symbol)

    {:ok,
     %__MODULE__{
       by_grade: grade_stats,
       by_strategy: strategy_stats,
       by_symbol: symbol_stats,
       by_direction: direction_stats,
       by_exit_type: exit_stats,
       best_grade: best_grade,
       worst_grade: worst_grade,
       best_strategy: best_strategy,
       worst_strategy: worst_strategy,
       best_symbol: best_symbol,
       worst_symbol: worst_symbol
     }}
  end

  @doc """
  Groups trades by signal quality grade and calculates stats.
  """
  @spec by_grade(list(map())) :: %{String.t() => GradeStats.t()}
  def by_grade(trades) do
    trades
    |> Enum.group_by(&get_grade/1)
    |> Enum.reject(fn {grade, _} -> is_nil(grade) end)
    |> Enum.map(fn {grade, grade_trades} ->
      stats = calculate_base_stats(grade_trades)

      grade_stats = %GradeStats{
        grade: grade,
        count: stats.count,
        winners: stats.winners,
        losers: stats.losers,
        win_rate: stats.win_rate,
        profit_factor: stats.profit_factor,
        net_pnl: stats.net_pnl,
        avg_r: stats.avg_r,
        avg_pnl: stats.avg_pnl,
        total_r: stats.total_r
      }

      {grade, grade_stats}
    end)
    |> Map.new()
  end

  @doc """
  Groups trades by strategy and calculates stats.
  """
  @spec by_strategy(list(map())) :: %{String.t() => StrategyStats.t()}
  def by_strategy(trades) do
    trades
    |> Enum.group_by(&get_strategy/1)
    |> Enum.reject(fn {strategy, _} -> is_nil(strategy) end)
    |> Enum.map(fn {strategy, strategy_trades} ->
      stats = calculate_base_stats(strategy_trades)

      strategy_stats = %StrategyStats{
        strategy: strategy,
        count: stats.count,
        winners: stats.winners,
        losers: stats.losers,
        win_rate: stats.win_rate,
        profit_factor: stats.profit_factor,
        net_pnl: stats.net_pnl,
        avg_r: stats.avg_r,
        avg_pnl: stats.avg_pnl,
        total_r: stats.total_r
      }

      {strategy, strategy_stats}
    end)
    |> Map.new()
  end

  @doc """
  Groups trades by symbol and calculates stats.
  """
  @spec by_symbol(list(map())) :: %{String.t() => SymbolStats.t()}
  def by_symbol(trades) do
    trades
    |> Enum.group_by(&Map.get(&1, :symbol))
    |> Enum.reject(fn {symbol, _} -> is_nil(symbol) end)
    |> Enum.map(fn {symbol, symbol_trades} ->
      stats = calculate_base_stats(symbol_trades)

      symbol_stats = %SymbolStats{
        symbol: symbol,
        count: stats.count,
        winners: stats.winners,
        losers: stats.losers,
        win_rate: stats.win_rate,
        profit_factor: stats.profit_factor,
        net_pnl: stats.net_pnl,
        avg_r: stats.avg_r,
        avg_pnl: stats.avg_pnl,
        total_r: stats.total_r
      }

      {symbol, symbol_stats}
    end)
    |> Map.new()
  end

  @doc """
  Groups trades by direction (long/short) and calculates stats.
  """
  @spec by_direction(list(map())) :: %{atom() => DirectionStats.t()}
  def by_direction(trades) do
    trades
    |> Enum.group_by(&Map.get(&1, :direction))
    |> Enum.reject(fn {direction, _} -> is_nil(direction) end)
    |> Enum.map(fn {direction, direction_trades} ->
      stats = calculate_base_stats(direction_trades)

      direction_stats = %DirectionStats{
        direction: direction,
        count: stats.count,
        winners: stats.winners,
        losers: stats.losers,
        win_rate: stats.win_rate,
        profit_factor: stats.profit_factor,
        net_pnl: stats.net_pnl,
        avg_r: stats.avg_r,
        avg_pnl: stats.avg_pnl,
        total_r: stats.total_r
      }

      {direction, direction_stats}
    end)
    |> Map.new()
  end

  @doc """
  Groups trades by exit type and calculates stats.
  """
  @spec by_exit_type(list(map())) :: %{atom() => ExitStats.t()}
  def by_exit_type(trades) do
    trades
    |> Enum.group_by(&Map.get(&1, :status))
    |> Enum.reject(fn {status, _} -> is_nil(status) end)
    |> Enum.map(fn {exit_type, exit_trades} ->
      stats = calculate_base_stats(exit_trades)

      exit_stats = %ExitStats{
        exit_type: exit_type,
        count: stats.count,
        winners: stats.winners,
        losers: stats.losers,
        win_rate: stats.win_rate,
        profit_factor: stats.profit_factor,
        net_pnl: stats.net_pnl,
        avg_r: stats.avg_r,
        avg_pnl: stats.avg_pnl,
        total_r: stats.total_r
      }

      {exit_type, exit_stats}
    end)
    |> Map.new()
  end

  # Private Functions

  defp get_grade(trade) do
    # Try multiple possible field names
    Map.get(trade, :quality_grade) ||
      Map.get(trade, :grade) ||
      Map.get(trade, :signal_grade)
  end

  defp get_strategy(trade) do
    strategy =
      Map.get(trade, :strategy) ||
        Map.get(trade, :signal_strategy)

    # Convert atom to string if needed
    case strategy do
      nil -> nil
      s when is_atom(s) -> Atom.to_string(s)
      s when is_binary(s) -> s
    end
  end

  defp calculate_base_stats(trades) do
    count = length(trades)

    {winners, losers} =
      Enum.reduce(trades, {0, 0}, fn trade, {w, l} ->
        pnl = Map.get(trade, :pnl, @zero) || @zero

        case Decimal.compare(pnl, @zero) do
          :gt -> {w + 1, l}
          :lt -> {w, l + 1}
          :eq -> {w, l}
        end
      end)

    win_rate =
      if count > 0 do
        Decimal.div(Decimal.new(winners * 100), Decimal.new(count))
        |> Decimal.round(2)
      else
        @zero
      end

    # Calculate gross profit and loss
    {gross_profit, gross_loss} =
      Enum.reduce(trades, {@zero, @zero}, fn trade, {gp, gl} ->
        pnl = Map.get(trade, :pnl, @zero) || @zero

        case Decimal.compare(pnl, @zero) do
          :gt -> {Decimal.add(gp, pnl), gl}
          :lt -> {gp, Decimal.add(gl, Decimal.abs(pnl))}
          :eq -> {gp, gl}
        end
      end)

    net_pnl = Decimal.sub(gross_profit, gross_loss)

    profit_factor =
      if Decimal.compare(gross_loss, @zero) == :gt do
        Decimal.div(gross_profit, gross_loss) |> Decimal.round(2)
      else
        nil
      end

    # Calculate R-multiple stats
    r_multiples =
      trades
      |> Enum.map(&Map.get(&1, :r_multiple))
      |> Enum.reject(&is_nil/1)

    total_r =
      if Enum.empty?(r_multiples) do
        @zero
      else
        Enum.reduce(r_multiples, @zero, &Decimal.add/2) |> Decimal.round(2)
      end

    avg_r =
      if Enum.empty?(r_multiples) do
        nil
      else
        Decimal.div(total_r, Decimal.new(length(r_multiples))) |> Decimal.round(2)
      end

    avg_pnl =
      if count > 0 do
        Decimal.div(net_pnl, Decimal.new(count)) |> Decimal.round(2)
      else
        @zero
      end

    %{
      count: count,
      winners: winners,
      losers: losers,
      win_rate: win_rate,
      profit_factor: profit_factor,
      net_pnl: net_pnl,
      avg_r: avg_r,
      avg_pnl: avg_pnl,
      total_r: total_r
    }
  end

  defp find_best_worst(stats_map, _key_field) do
    qualified =
      stats_map
      |> Enum.filter(fn {_key, stats} ->
        stats.count >= @min_trades_for_ranking && stats.profit_factor != nil
      end)
      |> Enum.sort_by(fn {_key, stats} ->
        Decimal.to_float(stats.profit_factor)
      end)

    case qualified do
      [] ->
        {nil, nil}

      [{worst_key, _} | _] = sorted ->
        {best_key, _} = List.last(sorted)
        {best_key, worst_key}
    end
  end
end
