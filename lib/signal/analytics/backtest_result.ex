defmodule Signal.Analytics.BacktestResult do
  @moduledoc """
  Ecto schema for persisted backtest analytics results.

  Stores comprehensive performance metrics calculated from a backtest run,
  including trade metrics, drawdown analysis, risk-adjusted returns, and
  detailed breakdowns by time, signal, and strategy.

  ## Usage

      # Results are typically created via Analytics.persist_results/2
      {:ok, result} = Analytics.persist_results(backtest_run, analytics)

      # Query results
      result = Repo.get_by(BacktestResult, backtest_run_id: run_id)
      result.profit_factor  # => Decimal.new("2.50")
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Signal.Backtest.BacktestRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "backtest_results" do
    belongs_to :backtest_run, BacktestRun

    # Trade metrics
    field :total_trades, :integer, default: 0
    field :winners, :integer, default: 0
    field :losers, :integer, default: 0
    field :breakeven, :integer, default: 0
    field :win_rate, :decimal
    field :loss_rate, :decimal
    field :gross_profit, :decimal
    field :gross_loss, :decimal
    field :net_profit, :decimal
    field :profit_factor, :decimal
    field :expectancy, :decimal
    field :avg_win, :decimal
    field :avg_loss, :decimal
    field :avg_pnl, :decimal
    field :avg_r_multiple, :decimal
    field :max_r_multiple, :decimal
    field :min_r_multiple, :decimal
    field :avg_hold_time_minutes, :integer
    field :max_hold_time_minutes, :integer
    field :min_hold_time_minutes, :integer

    # Drawdown metrics
    field :max_drawdown_pct, :decimal
    field :max_drawdown_dollars, :decimal
    field :max_drawdown_duration_days, :integer
    field :max_consecutive_losses, :integer, default: 0
    field :max_consecutive_wins, :integer, default: 0
    field :recovery_factor, :decimal

    # Risk-adjusted returns
    field :sharpe_ratio, :decimal
    field :sortino_ratio, :decimal
    field :calmar_ratio, :decimal
    field :volatility, :decimal

    # Return metrics
    field :total_return_pct, :decimal
    field :total_return_dollars, :decimal
    field :annualized_return_pct, :decimal

    # Detailed breakdowns (stored as JSONB)
    field :time_analysis, :map, default: %{}
    field :signal_analysis, :map, default: %{}
    field :equity_curve_data, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:backtest_run_id, :total_trades]

  @optional_fields [
    :winners,
    :losers,
    :breakeven,
    :win_rate,
    :loss_rate,
    :gross_profit,
    :gross_loss,
    :net_profit,
    :profit_factor,
    :expectancy,
    :avg_win,
    :avg_loss,
    :avg_pnl,
    :avg_r_multiple,
    :max_r_multiple,
    :min_r_multiple,
    :avg_hold_time_minutes,
    :max_hold_time_minutes,
    :min_hold_time_minutes,
    :max_drawdown_pct,
    :max_drawdown_dollars,
    :max_drawdown_duration_days,
    :max_consecutive_losses,
    :max_consecutive_wins,
    :recovery_factor,
    :sharpe_ratio,
    :sortino_ratio,
    :calmar_ratio,
    :volatility,
    :total_return_pct,
    :total_return_dollars,
    :annualized_return_pct,
    :time_analysis,
    :signal_analysis,
    :equity_curve_data
  ]

  @doc """
  Creates a changeset for a new backtest result.
  """
  def changeset(result, attrs) do
    result
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:total_trades, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:backtest_run_id)
    |> unique_constraint(:backtest_run_id)
  end

  @doc """
  Builds attributes map from analytics structs.

  Converts TradeMetrics, Drawdown, EquityCurve, TimeAnalysis, and SignalAnalysis
  into a flat map suitable for insertion.
  """
  @spec from_analytics(String.t(), map()) :: map()
  def from_analytics(backtest_run_id, analytics) do
    trade_metrics = Map.get(analytics, :trade_metrics, %{})
    drawdown = Map.get(analytics, :drawdown, %{})
    equity_curve = Map.get(analytics, :equity_curve, %{})
    time_analysis = Map.get(analytics, :time_analysis, %{})
    signal_analysis = Map.get(analytics, :signal_analysis, %{})

    %{
      backtest_run_id: backtest_run_id,

      # Trade metrics
      total_trades: get_value(trade_metrics, :total_trades, 0),
      winners: get_value(trade_metrics, :winners, 0),
      losers: get_value(trade_metrics, :losers, 0),
      breakeven: get_value(trade_metrics, :breakeven, 0),
      win_rate: get_value(trade_metrics, :win_rate),
      loss_rate: get_value(trade_metrics, :loss_rate),
      gross_profit: get_value(trade_metrics, :gross_profit),
      gross_loss: get_value(trade_metrics, :gross_loss),
      net_profit: get_value(trade_metrics, :net_profit),
      profit_factor: get_value(trade_metrics, :profit_factor),
      expectancy: get_value(trade_metrics, :expectancy),
      avg_win: get_value(trade_metrics, :avg_win),
      avg_loss: get_value(trade_metrics, :avg_loss),
      avg_pnl: get_value(trade_metrics, :avg_pnl),
      avg_r_multiple: get_value(trade_metrics, :avg_r_multiple),
      max_r_multiple: get_value(trade_metrics, :max_r_multiple),
      min_r_multiple: get_value(trade_metrics, :min_r_multiple),
      avg_hold_time_minutes: get_value(trade_metrics, :avg_hold_time_minutes),
      max_hold_time_minutes: get_value(trade_metrics, :max_hold_time_minutes),
      min_hold_time_minutes: get_value(trade_metrics, :min_hold_time_minutes),

      # Drawdown metrics
      max_drawdown_pct: get_value(drawdown, :max_drawdown_pct),
      max_drawdown_dollars: get_value(drawdown, :max_drawdown_dollars),
      max_drawdown_duration_days: get_value(drawdown, :max_drawdown_duration_days),
      max_consecutive_losses: get_value(drawdown, :max_consecutive_losses, 0),
      max_consecutive_wins: get_value(drawdown, :max_consecutive_wins, 0),
      recovery_factor: get_value(drawdown, :recovery_factor),

      # Risk-adjusted returns (from equity curve)
      sharpe_ratio: get_value(equity_curve, :sharpe_ratio),
      sortino_ratio: get_value(equity_curve, :sortino_ratio),
      calmar_ratio: get_value(equity_curve, :calmar_ratio),
      volatility: get_value(equity_curve, :volatility),

      # Return metrics
      total_return_pct: get_value(equity_curve, :total_return_pct),
      total_return_dollars: get_value(equity_curve, :total_return_dollars),
      annualized_return_pct: get_value(equity_curve, :annualized_return_pct),

      # Detailed breakdowns
      time_analysis: serialize_time_analysis(time_analysis),
      signal_analysis: serialize_signal_analysis(signal_analysis),
      equity_curve_data: serialize_equity_curve(equity_curve)
    }
  end

  # Private helpers

  defp get_value(struct_or_map, key, default \\ nil)

  defp get_value(%{__struct__: _} = struct, key, default) do
    Map.get(struct, key, default)
  end

  defp get_value(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  defp get_value(_, _key, default), do: default

  defp serialize_time_analysis(%{__struct__: _} = analysis) do
    %{
      by_time_slot: serialize_stats_map(analysis.by_time_slot),
      by_weekday: serialize_stats_map(analysis.by_weekday),
      by_month: serialize_stats_map(analysis.by_month),
      best_time_slot: analysis.best_time_slot,
      worst_time_slot: analysis.worst_time_slot,
      best_weekday: atom_to_string(analysis.best_weekday),
      worst_weekday: atom_to_string(analysis.worst_weekday),
      best_month: analysis.best_month,
      worst_month: analysis.worst_month
    }
  end

  defp serialize_time_analysis(_), do: %{}

  defp serialize_signal_analysis(%{__struct__: _} = analysis) do
    %{
      by_grade: serialize_stats_map(analysis.by_grade),
      by_strategy: serialize_stats_map(analysis.by_strategy),
      by_symbol: serialize_stats_map(analysis.by_symbol),
      by_direction: serialize_stats_map(analysis.by_direction),
      by_exit_type: serialize_stats_map(analysis.by_exit_type),
      best_grade: analysis.best_grade,
      worst_grade: analysis.worst_grade,
      best_strategy: analysis.best_strategy,
      worst_strategy: analysis.worst_strategy,
      best_symbol: analysis.best_symbol,
      worst_symbol: analysis.worst_symbol
    }
  end

  defp serialize_signal_analysis(_), do: %{}

  defp serialize_equity_curve(%{__struct__: _} = curve) do
    %{
      initial_equity: decimal_to_string(curve.initial_equity),
      final_equity: decimal_to_string(curve.final_equity),
      peak_equity: decimal_to_string(curve.peak_equity),
      trough_equity: decimal_to_string(curve.trough_equity),
      trading_days: curve.trading_days,
      first_date: date_to_string(curve.first_date),
      last_date: date_to_string(curve.last_date)
      # Note: Not storing full data_points to save space
    }
  end

  defp serialize_equity_curve(_), do: %{}

  defp serialize_stats_map(nil), do: %{}

  defp serialize_stats_map(stats_map) when is_map(stats_map) do
    stats_map
    |> Enum.map(fn {key, stats} ->
      key_str =
        case key do
          k when is_atom(k) -> Atom.to_string(k)
          k -> to_string(k)
        end

      {key_str, serialize_stats(stats)}
    end)
    |> Map.new()
  end

  defp serialize_stats(%{__struct__: _} = stats) do
    stats
    |> Map.from_struct()
    |> Enum.map(fn {k, v} ->
      serialized_value =
        cond do
          is_struct(v, Decimal) -> Decimal.to_string(v)
          is_atom(v) -> Atom.to_string(v)
          true -> v
        end

      {Atom.to_string(k), serialized_value}
    end)
    |> Map.new()
  end

  defp serialize_stats(other), do: other

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(other), do: to_string(other)

  defp date_to_string(nil), do: nil
  defp date_to_string(%Date{} = d), do: Date.to_iso8601(d)
  defp date_to_string(other), do: to_string(other)

  defp atom_to_string(nil), do: nil
  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string(other), do: to_string(other)
end
