defmodule Signal.Analytics.TimeAnalysis do
  @moduledoc """
  Analyzes trading performance by time of day, day of week, and month.

  ## Metrics Calculated

  - **By Time Slot**: Performance in 15-minute intervals (9:30-9:45, etc.)
  - **By Weekday**: Performance by day of week
  - **By Month**: Performance by calendar month
  - **Best/Worst**: Identifies optimal and suboptimal trading periods

  ## Usage

      trades = account.closed_trades
      {:ok, analysis} = TimeAnalysis.calculate(trades)

      analysis.by_time_slot["09:30-09:45"].win_rate  # => Decimal.new("72.50")
      analysis.best_time_slot  # => "09:30-09:45"
  """

  defmodule TimeSlotStats do
    @moduledoc "Statistics for a specific time slot."
    defstruct [
      :time_slot,
      :trades,
      :winners,
      :losers,
      :win_rate,
      :profit_factor,
      :net_pnl,
      :avg_r,
      :avg_pnl
    ]

    @type t :: %__MODULE__{
            time_slot: String.t(),
            trades: non_neg_integer(),
            winners: non_neg_integer(),
            losers: non_neg_integer(),
            win_rate: Decimal.t(),
            profit_factor: Decimal.t() | nil,
            net_pnl: Decimal.t(),
            avg_r: Decimal.t() | nil,
            avg_pnl: Decimal.t()
          }
  end

  defmodule DayStats do
    @moduledoc "Statistics for a specific day of week."
    defstruct [
      :day,
      :trades,
      :winners,
      :losers,
      :win_rate,
      :profit_factor,
      :net_pnl,
      :avg_r,
      :avg_pnl
    ]

    @type t :: %__MODULE__{
            day: atom(),
            trades: non_neg_integer(),
            winners: non_neg_integer(),
            losers: non_neg_integer(),
            win_rate: Decimal.t(),
            profit_factor: Decimal.t() | nil,
            net_pnl: Decimal.t(),
            avg_r: Decimal.t() | nil,
            avg_pnl: Decimal.t()
          }
  end

  defmodule MonthStats do
    @moduledoc "Statistics for a specific month."
    defstruct [
      :month,
      :trades,
      :winners,
      :losers,
      :win_rate,
      :profit_factor,
      :net_pnl,
      :avg_r,
      :avg_pnl
    ]

    @type t :: %__MODULE__{
            month: String.t(),
            trades: non_neg_integer(),
            winners: non_neg_integer(),
            losers: non_neg_integer(),
            win_rate: Decimal.t(),
            profit_factor: Decimal.t() | nil,
            net_pnl: Decimal.t(),
            avg_r: Decimal.t() | nil,
            avg_pnl: Decimal.t()
          }
  end

  defstruct [
    :by_time_slot,
    :by_weekday,
    :by_month,
    :best_time_slot,
    :worst_time_slot,
    :best_weekday,
    :worst_weekday,
    :best_month,
    :worst_month
  ]

  @type t :: %__MODULE__{
          by_time_slot: %{String.t() => TimeSlotStats.t()},
          by_weekday: %{atom() => DayStats.t()},
          by_month: %{String.t() => MonthStats.t()},
          best_time_slot: String.t() | nil,
          worst_time_slot: String.t() | nil,
          best_weekday: atom() | nil,
          worst_weekday: atom() | nil,
          best_month: String.t() | nil,
          worst_month: String.t() | nil
        }

  @zero Decimal.new(0)
  @timezone "America/New_York"
  @min_trades_for_ranking 5

  @doc """
  Calculates time-based performance analysis.

  ## Parameters

    * `trades` - List of trade maps with `:entry_time`, `:pnl`, `:r_multiple`

  ## Returns

    * `{:ok, %TimeAnalysis{}}` - Analysis completed
    * `{:error, reason}` - Analysis failed
  """
  @spec calculate(list(map())) :: {:ok, t()} | {:error, term()}
  def calculate(trades) when is_list(trades) do
    time_slot_stats = by_time_slot(trades)
    weekday_stats = by_weekday(trades)
    month_stats = by_month(trades)

    {best_slot, worst_slot} = find_best_worst_slot(time_slot_stats)
    {best_day, worst_day} = find_best_worst_day(weekday_stats)
    {best_month, worst_month} = find_best_worst_month(month_stats)

    {:ok,
     %__MODULE__{
       by_time_slot: time_slot_stats,
       by_weekday: weekday_stats,
       by_month: month_stats,
       best_time_slot: best_slot,
       worst_time_slot: worst_slot,
       best_weekday: best_day,
       worst_weekday: worst_day,
       best_month: best_month,
       worst_month: worst_month
     }}
  end

  @doc """
  Groups trades by time slot and calculates stats for each.

  Uses 15-minute intervals from market open (9:30 AM ET).
  """
  @spec by_time_slot(list(map()), non_neg_integer()) :: %{String.t() => TimeSlotStats.t()}
  def by_time_slot(trades, interval_minutes \\ 15) do
    trades
    |> Enum.group_by(&get_time_slot(&1, interval_minutes))
    |> Enum.reject(fn {slot, _trades} -> is_nil(slot) end)
    |> Enum.map(fn {slot, slot_trades} ->
      {slot, calculate_slot_stats(slot, slot_trades)}
    end)
    |> Map.new()
  end

  @doc """
  Groups trades by day of week and calculates stats for each.
  """
  @spec by_weekday(list(map())) :: %{atom() => DayStats.t()}
  def by_weekday(trades) do
    trades
    |> Enum.group_by(&get_weekday/1)
    |> Enum.reject(fn {day, _trades} -> is_nil(day) end)
    |> Enum.map(fn {day, day_trades} ->
      {day, calculate_day_stats(day, day_trades)}
    end)
    |> Map.new()
  end

  @doc """
  Groups trades by calendar month and calculates stats for each.
  """
  @spec by_month(list(map())) :: %{String.t() => MonthStats.t()}
  def by_month(trades) do
    trades
    |> Enum.group_by(&get_month/1)
    |> Enum.reject(fn {month, _trades} -> is_nil(month) end)
    |> Enum.map(fn {month, month_trades} ->
      {month, calculate_month_stats(month, month_trades)}
    end)
    |> Map.new()
  end

  @doc """
  Finds the best and worst performing time slots.

  Ranks by profit factor, requires minimum trades.
  """
  @spec find_best_worst_slot(%{String.t() => TimeSlotStats.t()}) ::
          {String.t() | nil, String.t() | nil}
  def find_best_worst_slot(slot_stats) do
    qualified =
      slot_stats
      |> Enum.filter(fn {_slot, stats} ->
        stats.trades >= @min_trades_for_ranking && stats.profit_factor != nil
      end)
      |> Enum.sort_by(fn {_slot, stats} ->
        Decimal.to_float(stats.profit_factor)
      end)

    case qualified do
      [] ->
        {nil, nil}

      [{worst_slot, _} | _] = sorted ->
        {best_slot, _} = List.last(sorted)
        {best_slot, worst_slot}
    end
  end

  # Private Functions

  defp get_time_slot(trade, interval_minutes) do
    case Map.get(trade, :entry_time) do
      nil ->
        nil

      entry_time ->
        et_time = to_et_time(entry_time)
        slot_start = round_to_slot(et_time, interval_minutes)
        slot_end = Time.add(slot_start, interval_minutes * 60)

        format_time_slot(slot_start, slot_end)
    end
  end

  defp to_et_time(datetime) do
    datetime
    |> DateTime.shift_zone!(@timezone)
    |> DateTime.to_time()
  end

  defp round_to_slot(time, interval_minutes) do
    total_minutes = time.hour * 60 + time.minute
    slot_minutes = div(total_minutes, interval_minutes) * interval_minutes
    hour = div(slot_minutes, 60)
    minute = rem(slot_minutes, 60)

    Time.new!(hour, minute, 0)
  end

  defp format_time_slot(start_time, end_time) do
    start_str = format_time(start_time)
    end_str = format_time(end_time)
    "#{start_str}-#{end_str}"
  end

  defp format_time(time) do
    hour = String.pad_leading(Integer.to_string(time.hour), 2, "0")
    minute = String.pad_leading(Integer.to_string(time.minute), 2, "0")
    "#{hour}:#{minute}"
  end

  defp get_weekday(trade) do
    case Map.get(trade, :entry_time) do
      nil ->
        nil

      entry_time ->
        entry_time
        |> DateTime.shift_zone!(@timezone)
        |> DateTime.to_date()
        |> Date.day_of_week()
        |> day_number_to_atom()
    end
  end

  defp day_number_to_atom(1), do: :monday
  defp day_number_to_atom(2), do: :tuesday
  defp day_number_to_atom(3), do: :wednesday
  defp day_number_to_atom(4), do: :thursday
  defp day_number_to_atom(5), do: :friday
  defp day_number_to_atom(6), do: :saturday
  defp day_number_to_atom(7), do: :sunday

  defp get_month(trade) do
    case Map.get(trade, :entry_time) do
      nil ->
        nil

      entry_time ->
        date =
          entry_time
          |> DateTime.shift_zone!(@timezone)
          |> DateTime.to_date()

        year = Integer.to_string(date.year)
        month = String.pad_leading(Integer.to_string(date.month), 2, "0")
        "#{year}-#{month}"
    end
  end

  defp calculate_slot_stats(slot, trades) do
    base_stats = calculate_base_stats(trades)

    %TimeSlotStats{
      time_slot: slot,
      trades: base_stats.total,
      winners: base_stats.winners,
      losers: base_stats.losers,
      win_rate: base_stats.win_rate,
      profit_factor: base_stats.profit_factor,
      net_pnl: base_stats.net_pnl,
      avg_r: base_stats.avg_r,
      avg_pnl: base_stats.avg_pnl
    }
  end

  defp calculate_day_stats(day, trades) do
    base_stats = calculate_base_stats(trades)

    %DayStats{
      day: day,
      trades: base_stats.total,
      winners: base_stats.winners,
      losers: base_stats.losers,
      win_rate: base_stats.win_rate,
      profit_factor: base_stats.profit_factor,
      net_pnl: base_stats.net_pnl,
      avg_r: base_stats.avg_r,
      avg_pnl: base_stats.avg_pnl
    }
  end

  defp calculate_month_stats(month, trades) do
    base_stats = calculate_base_stats(trades)

    %MonthStats{
      month: month,
      trades: base_stats.total,
      winners: base_stats.winners,
      losers: base_stats.losers,
      win_rate: base_stats.win_rate,
      profit_factor: base_stats.profit_factor,
      net_pnl: base_stats.net_pnl,
      avg_r: base_stats.avg_r,
      avg_pnl: base_stats.avg_pnl
    }
  end

  defp calculate_base_stats(trades) do
    total = length(trades)

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
      if total > 0 do
        Decimal.div(Decimal.new(winners * 100), Decimal.new(total))
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

    # Calculate average R
    r_multiples =
      trades
      |> Enum.map(&Map.get(&1, :r_multiple))
      |> Enum.reject(&is_nil/1)

    avg_r =
      if Enum.empty?(r_multiples) do
        nil
      else
        sum = Enum.reduce(r_multiples, @zero, &Decimal.add/2)
        Decimal.div(sum, Decimal.new(length(r_multiples))) |> Decimal.round(2)
      end

    avg_pnl =
      if total > 0 do
        Decimal.div(net_pnl, Decimal.new(total)) |> Decimal.round(2)
      else
        @zero
      end

    %{
      total: total,
      winners: winners,
      losers: losers,
      win_rate: win_rate,
      profit_factor: profit_factor,
      net_pnl: net_pnl,
      avg_r: avg_r,
      avg_pnl: avg_pnl
    }
  end

  defp find_best_worst_day(day_stats) do
    qualified =
      day_stats
      |> Enum.filter(fn {_day, stats} ->
        stats.trades >= @min_trades_for_ranking && stats.profit_factor != nil
      end)
      |> Enum.sort_by(fn {_day, stats} ->
        Decimal.to_float(stats.profit_factor)
      end)

    case qualified do
      [] ->
        {nil, nil}

      [{worst_day, _} | _] = sorted ->
        {best_day, _} = List.last(sorted)
        {best_day, worst_day}
    end
  end

  defp find_best_worst_month(month_stats) do
    qualified =
      month_stats
      |> Enum.filter(fn {_month, stats} ->
        stats.trades >= @min_trades_for_ranking && stats.profit_factor != nil
      end)
      |> Enum.sort_by(fn {_month, stats} ->
        Decimal.to_float(stats.profit_factor)
      end)

    case qualified do
      [] ->
        {nil, nil}

      [{worst_month, _} | _] = sorted ->
        {best_month, _} = List.last(sorted)
        {best_month, worst_month}
    end
  end
end
