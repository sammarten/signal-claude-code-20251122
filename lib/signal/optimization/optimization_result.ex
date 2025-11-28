defmodule Signal.Optimization.OptimizationResult do
  @moduledoc """
  Ecto schema for individual optimization result records.

  Each record represents the performance of a specific parameter combination,
  optionally within a specific walk-forward window.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Signal.Optimization.OptimizationRun
  alias Signal.Backtest.BacktestRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "optimization_results" do
    belongs_to :optimization_run, OptimizationRun
    belongs_to :backtest_run, BacktestRun

    # The specific parameter combination tested (JSONB)
    field :parameters, :map

    # Walk-forward window info
    field :window_index, :integer
    field :window_start_date, :date
    field :window_end_date, :date
    field :is_training, :boolean, default: true

    # Key performance metrics for ranking
    field :profit_factor, :decimal
    field :net_profit, :decimal
    field :win_rate, :decimal
    field :total_trades, :integer, default: 0
    field :sharpe_ratio, :decimal
    field :sortino_ratio, :decimal
    field :max_drawdown_pct, :decimal
    field :expectancy, :decimal
    field :avg_r_multiple, :decimal

    # Validation metrics (populated after walk-forward analysis)
    field :degradation_pct, :decimal
    field :walk_forward_efficiency, :decimal
    field :is_overfit, :boolean

    # Aggregated out-of-sample metrics (for walk-forward summary)
    field :oos_profit_factor, :decimal
    field :oos_net_profit, :decimal
    field :oos_win_rate, :decimal
    field :oos_total_trades, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:optimization_run_id, :parameters]

  @optional_fields [
    :backtest_run_id,
    :window_index,
    :window_start_date,
    :window_end_date,
    :is_training,
    :profit_factor,
    :net_profit,
    :win_rate,
    :total_trades,
    :sharpe_ratio,
    :sortino_ratio,
    :max_drawdown_pct,
    :expectancy,
    :avg_r_multiple,
    :degradation_pct,
    :walk_forward_efficiency,
    :is_overfit,
    :oos_profit_factor,
    :oos_net_profit,
    :oos_win_rate,
    :oos_total_trades
  ]

  @doc """
  Creates a changeset for a new optimization result.
  """
  def changeset(result, attrs) do
    result
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:optimization_run_id)
    |> foreign_key_constraint(:backtest_run_id)
  end

  @doc """
  Creates a changeset for updating validation metrics.
  """
  def validation_changeset(result, attrs) do
    result
    |> cast(attrs, [
      :degradation_pct,
      :walk_forward_efficiency,
      :is_overfit,
      :oos_profit_factor,
      :oos_net_profit,
      :oos_win_rate,
      :oos_total_trades
    ])
  end

  @doc """
  Builds attributes from backtest analytics.

  Extracts relevant metrics from backtest results to populate
  the optimization result record.
  """
  @spec from_backtest_analytics(map()) :: map()
  def from_backtest_analytics(analytics) when is_map(analytics) do
    trade_metrics = Map.get(analytics, :trade_metrics, %{})
    drawdown = Map.get(analytics, :drawdown, %{})
    equity_curve = Map.get(analytics, :equity_curve, %{})

    %{
      profit_factor: get_metric(trade_metrics, :profit_factor),
      net_profit: get_metric(trade_metrics, :net_profit),
      win_rate: get_metric(trade_metrics, :win_rate),
      total_trades: get_metric(trade_metrics, :total_trades, 0),
      sharpe_ratio: get_metric(equity_curve, :sharpe_ratio),
      sortino_ratio: get_metric(equity_curve, :sortino_ratio),
      max_drawdown_pct: get_metric(drawdown, :max_drawdown_pct),
      expectancy: get_metric(trade_metrics, :expectancy),
      avg_r_multiple: get_metric(trade_metrics, :avg_r_multiple)
    }
  end

  defp get_metric(source, key, default \\ nil)

  defp get_metric(%{__struct__: _} = struct, key, default) do
    Map.get(struct, key, default)
  end

  defp get_metric(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  defp get_metric(_, _key, default), do: default
end
