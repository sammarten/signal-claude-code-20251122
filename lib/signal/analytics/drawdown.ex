defmodule Signal.Analytics.Drawdown do
  @moduledoc """
  Calculates drawdown and streak metrics from equity curves and trades.

  ## Metrics Calculated

  - **Max Drawdown**: Largest peak-to-trough decline (% and $)
  - **Drawdown Duration**: How long the max drawdown lasted
  - **Current Drawdown**: Current decline from peak
  - **Consecutive Streaks**: Max wins/losses in a row
  - **Recovery Factor**: Net profit / max drawdown

  ## Usage

      equity_curve = account.equity_curve
      trades = account.closed_trades
      initial_capital = Decimal.new("100000")

      {:ok, analysis} = Drawdown.calculate(equity_curve, trades, initial_capital)

      analysis.max_drawdown_pct  # => Decimal.new("8.50")
      analysis.max_consecutive_losses  # => 5
  """

  defstruct [
    :max_drawdown_pct,
    :max_drawdown_dollars,
    :max_drawdown_start,
    :max_drawdown_end,
    :max_drawdown_peak,
    :max_drawdown_trough,
    :max_drawdown_duration_days,
    :current_drawdown_pct,
    :current_drawdown_dollars,
    :max_consecutive_losses,
    :max_consecutive_wins,
    :current_streak,
    :current_streak_type,
    :recovery_factor,
    :avg_drawdown_pct,
    :drawdown_count
  ]

  @type t :: %__MODULE__{
          max_drawdown_pct: Decimal.t(),
          max_drawdown_dollars: Decimal.t(),
          max_drawdown_start: DateTime.t() | nil,
          max_drawdown_end: DateTime.t() | nil,
          max_drawdown_peak: Decimal.t() | nil,
          max_drawdown_trough: Decimal.t() | nil,
          max_drawdown_duration_days: non_neg_integer() | nil,
          current_drawdown_pct: Decimal.t(),
          current_drawdown_dollars: Decimal.t(),
          max_consecutive_losses: non_neg_integer(),
          max_consecutive_wins: non_neg_integer(),
          current_streak: non_neg_integer(),
          current_streak_type: :wins | :losses | :none,
          recovery_factor: Decimal.t() | nil,
          avg_drawdown_pct: Decimal.t(),
          drawdown_count: non_neg_integer()
        }

  @zero Decimal.new(0)
  @hundred Decimal.new(100)

  @doc """
  Calculates drawdown analysis from equity curve and trades.

  ## Parameters

    * `equity_curve` - List of `{DateTime.t(), Decimal.t()}` tuples (timestamp, equity)
    * `trades` - List of trade maps with `:pnl` field
    * `initial_capital` - Starting capital as Decimal

  ## Returns

    * `{:ok, %Drawdown{}}` - Analysis completed
    * `{:error, reason}` - Analysis failed
  """
  @spec calculate(list({DateTime.t(), Decimal.t()}), list(map()), Decimal.t()) ::
          {:ok, t()} | {:error, term()}
  def calculate(equity_curve, trades, initial_capital) do
    # Reverse equity curve if stored newest-first (VirtualAccount stores newest-first)
    sorted_curve = sort_equity_curve(equity_curve)

    # Calculate drawdown metrics from equity curve
    drawdown_data = analyze_equity_curve(sorted_curve, initial_capital)

    # Calculate streak metrics from trades
    streak_data = analyze_streaks(trades)

    # Calculate net profit for recovery factor
    net_profit = calculate_net_profit(trades)

    # Calculate recovery factor
    recovery = recovery_factor(net_profit, drawdown_data.max_drawdown_dollars)

    {:ok,
     %__MODULE__{
       max_drawdown_pct: drawdown_data.max_drawdown_pct,
       max_drawdown_dollars: drawdown_data.max_drawdown_dollars,
       max_drawdown_start: drawdown_data.max_drawdown_start,
       max_drawdown_end: drawdown_data.max_drawdown_end,
       max_drawdown_peak: drawdown_data.max_drawdown_peak,
       max_drawdown_trough: drawdown_data.max_drawdown_trough,
       max_drawdown_duration_days: drawdown_data.max_drawdown_duration_days,
       current_drawdown_pct: drawdown_data.current_drawdown_pct,
       current_drawdown_dollars: drawdown_data.current_drawdown_dollars,
       max_consecutive_losses: streak_data.max_losses,
       max_consecutive_wins: streak_data.max_wins,
       current_streak: streak_data.current_streak,
       current_streak_type: streak_data.current_type,
       recovery_factor: recovery,
       avg_drawdown_pct: drawdown_data.avg_drawdown_pct,
       drawdown_count: drawdown_data.drawdown_count
     }}
  end

  @doc """
  Finds the maximum drawdown from an equity curve.

  Returns `{max_dd_pct, max_dd_dollars, peak_time, trough_time}`.
  """
  @spec find_max_drawdown(list({DateTime.t(), Decimal.t()})) ::
          {Decimal.t(), Decimal.t(), DateTime.t() | nil, DateTime.t() | nil}
  def find_max_drawdown([]), do: {@zero, @zero, nil, nil}

  def find_max_drawdown(equity_curve) do
    sorted = sort_equity_curve(equity_curve)

    {_peak, _peak_time, max_dd_pct, max_dd_dollars, dd_start, dd_end} =
      Enum.reduce(sorted, {nil, nil, @zero, @zero, nil, nil}, fn
        {time, equity}, {nil, nil, _, _, _, _} ->
          {equity, time, @zero, @zero, nil, nil}

        {time, equity}, {peak, peak_time, max_dd_pct, max_dd_dollars, dd_start, dd_end} ->
          if Decimal.compare(equity, peak) == :gt do
            # New peak
            {equity, time, max_dd_pct, max_dd_dollars, dd_start, dd_end}
          else
            # Calculate drawdown from peak
            dd_dollars = Decimal.sub(peak, equity)
            dd_pct = Decimal.div(dd_dollars, peak) |> Decimal.mult(@hundred)

            if Decimal.compare(dd_pct, max_dd_pct) == :gt do
              {peak, peak_time, dd_pct, dd_dollars, peak_time, time}
            else
              {peak, peak_time, max_dd_pct, max_dd_dollars, dd_start, dd_end}
            end
          end
      end)

    {Decimal.round(max_dd_pct, 2), Decimal.round(max_dd_dollars, 2), dd_start, dd_end}
  end

  @doc """
  Calculates consecutive win/loss streaks from trades.

  Returns `{max_wins, max_losses, current_streak, current_type}`.
  """
  @spec calculate_streaks(list(map())) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), :wins | :losses | :none}
  def calculate_streaks([]), do: {0, 0, 0, :none}

  def calculate_streaks(trades) do
    streak_data = analyze_streaks(trades)

    {streak_data.max_wins, streak_data.max_losses, streak_data.current_streak,
     streak_data.current_type}
  end

  @doc """
  Calculates recovery factor (net profit / max drawdown).

  A higher recovery factor indicates the strategy recovers well from drawdowns.
  """
  @spec recovery_factor(Decimal.t(), Decimal.t()) :: Decimal.t() | nil
  def recovery_factor(_net_profit, max_dd) when max_dd == @zero, do: nil

  def recovery_factor(net_profit, max_drawdown) do
    if Decimal.compare(max_drawdown, @zero) == :gt do
      Decimal.div(net_profit, max_drawdown) |> Decimal.round(2)
    else
      nil
    end
  end

  # Private Functions

  defp sort_equity_curve(equity_curve) do
    equity_curve
    |> Enum.sort_by(fn {time, _equity} -> DateTime.to_unix(time) end)
  end

  defp analyze_equity_curve([], _initial_capital) do
    %{
      max_drawdown_pct: @zero,
      max_drawdown_dollars: @zero,
      max_drawdown_start: nil,
      max_drawdown_end: nil,
      max_drawdown_peak: nil,
      max_drawdown_trough: nil,
      max_drawdown_duration_days: nil,
      current_drawdown_pct: @zero,
      current_drawdown_dollars: @zero,
      avg_drawdown_pct: @zero,
      drawdown_count: 0
    }
  end

  defp analyze_equity_curve(equity_curve, initial_capital) do
    # Track all drawdowns
    {drawdowns, final_state} = track_drawdowns(equity_curve, initial_capital)

    # Include ongoing drawdown if still in one
    all_drawdowns =
      if final_state.in_drawdown && final_state.current_trough do
        ongoing_dd = %{
          pct: calculate_dd_pct(final_state.peak, final_state.current_trough),
          dollars: Decimal.sub(final_state.peak, final_state.current_trough),
          start_time: final_state.current_dd_start,
          end_time: final_state.current_trough_time,
          peak: final_state.peak,
          trough: final_state.current_trough
        }

        [ongoing_dd | drawdowns]
      else
        drawdowns
      end

    # Find max drawdown
    max_dd =
      if Enum.empty?(all_drawdowns) do
        %{
          pct: @zero,
          dollars: @zero,
          start_time: nil,
          end_time: nil,
          peak: nil,
          trough: nil
        }
      else
        Enum.max_by(all_drawdowns, fn dd -> Decimal.to_float(dd.pct) end)
      end

    # Calculate duration
    duration =
      if max_dd.start_time && max_dd.end_time do
        days = DateTime.diff(max_dd.end_time, max_dd.start_time, :day)
        max(days, 0)
      else
        nil
      end

    # Calculate current drawdown
    {current_dd_pct, current_dd_dollars} = calculate_current_drawdown(final_state)

    # Calculate average drawdown
    avg_dd =
      if Enum.empty?(all_drawdowns) do
        @zero
      else
        total = Enum.reduce(all_drawdowns, @zero, fn dd, acc -> Decimal.add(acc, dd.pct) end)
        Decimal.div(total, Decimal.new(length(all_drawdowns))) |> Decimal.round(2)
      end

    %{
      max_drawdown_pct: Decimal.round(max_dd.pct, 2),
      max_drawdown_dollars: Decimal.round(max_dd.dollars, 2),
      max_drawdown_start: max_dd.start_time,
      max_drawdown_end: max_dd.end_time,
      max_drawdown_peak: max_dd.peak,
      max_drawdown_trough: max_dd.trough,
      max_drawdown_duration_days: duration,
      current_drawdown_pct: current_dd_pct,
      current_drawdown_dollars: current_dd_dollars,
      avg_drawdown_pct: avg_dd,
      drawdown_count: length(all_drawdowns)
    }
  end

  defp track_drawdowns(equity_curve, initial_capital) do
    initial_state = %{
      peak: initial_capital,
      peak_time: nil,
      in_drawdown: false,
      current_dd_start: nil,
      current_trough: nil,
      current_trough_time: nil
    }

    {drawdowns, final_state} =
      Enum.reduce(equity_curve, {[], initial_state}, fn {time, equity}, {dds, state} ->
        if Decimal.compare(equity, state.peak) != :lt do
          # At or above peak - end drawdown if in one
          new_dds =
            if state.in_drawdown && state.current_trough do
              dd = %{
                pct: calculate_dd_pct(state.peak, state.current_trough),
                dollars: Decimal.sub(state.peak, state.current_trough),
                start_time: state.current_dd_start,
                end_time: time,
                peak: state.peak,
                trough: state.current_trough
              }

              [dd | dds]
            else
              dds
            end

          new_state = %{
            state
            | peak: equity,
              peak_time: time,
              in_drawdown: false,
              current_dd_start: nil,
              current_trough: nil,
              current_trough_time: nil
          }

          {new_dds, new_state}
        else
          # Below peak - in drawdown
          new_state =
            if state.in_drawdown do
              # Continue drawdown, update trough if lower
              if is_nil(state.current_trough) ||
                   Decimal.compare(equity, state.current_trough) == :lt do
                %{state | current_trough: equity, current_trough_time: time}
              else
                state
              end
            else
              # Start new drawdown
              %{
                state
                | in_drawdown: true,
                  current_dd_start: state.peak_time || time,
                  current_trough: equity,
                  current_trough_time: time
              }
            end

          {dds, new_state}
        end
      end)

    {Enum.reverse(drawdowns), final_state}
  end

  defp calculate_dd_pct(peak, trough) do
    if Decimal.compare(peak, @zero) == :gt do
      Decimal.sub(peak, trough)
      |> Decimal.div(peak)
      |> Decimal.mult(@hundred)
    else
      @zero
    end
  end

  defp calculate_current_drawdown(%{in_drawdown: false}), do: {@zero, @zero}

  defp calculate_current_drawdown(%{peak: _peak, current_trough: nil}), do: {@zero, @zero}

  defp calculate_current_drawdown(%{peak: peak, current_trough: trough}) do
    dollars = Decimal.sub(peak, trough)
    pct = calculate_dd_pct(peak, trough) |> Decimal.round(2)
    {pct, Decimal.round(dollars, 2)}
  end

  defp analyze_streaks([]) do
    %{max_wins: 0, max_losses: 0, current_streak: 0, current_type: :none}
  end

  defp analyze_streaks(trades) do
    # Sort trades by exit time to ensure correct order
    sorted_trades =
      trades
      |> Enum.filter(&Map.has_key?(&1, :exit_time))
      |> Enum.sort_by(fn trade ->
        case Map.get(trade, :exit_time) do
          nil -> 0
          time -> DateTime.to_unix(time)
        end
      end)

    initial_state = %{
      max_wins: 0,
      max_losses: 0,
      current_streak: 0,
      current_type: :none
    }

    Enum.reduce(sorted_trades, initial_state, fn trade, state ->
      pnl = Map.get(trade, :pnl, @zero) || @zero
      is_win = Decimal.compare(pnl, @zero) == :gt
      is_loss = Decimal.compare(pnl, @zero) == :lt

      cond do
        is_win && state.current_type == :wins ->
          new_streak = state.current_streak + 1

          %{
            state
            | current_streak: new_streak,
              max_wins: max(state.max_wins, new_streak)
          }

        is_win ->
          %{
            state
            | current_streak: 1,
              current_type: :wins,
              max_wins: max(state.max_wins, 1)
          }

        is_loss && state.current_type == :losses ->
          new_streak = state.current_streak + 1

          %{
            state
            | current_streak: new_streak,
              max_losses: max(state.max_losses, new_streak)
          }

        is_loss ->
          %{
            state
            | current_streak: 1,
              current_type: :losses,
              max_losses: max(state.max_losses, 1)
          }

        true ->
          # Breakeven - reset streak
          %{state | current_streak: 0, current_type: :none}
      end
    end)
  end

  defp calculate_net_profit(trades) do
    Enum.reduce(trades, @zero, fn trade, acc ->
      pnl = Map.get(trade, :pnl, @zero) || @zero
      Decimal.add(acc, pnl)
    end)
  end
end
