defmodule Signal.Repo.Migrations.CreateOptimizationResults do
  use Ecto.Migration

  def change do
    create table(:optimization_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Foreign keys
      add :optimization_run_id,
          references(:optimization_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :backtest_run_id, references(:backtest_runs, type: :binary_id, on_delete: :nilify_all)

      # The specific parameter combination tested (JSONB)
      add :parameters, :map, null: false

      # Walk-forward window info
      add :window_index, :integer
      add :window_start_date, :date
      add :window_end_date, :date
      add :is_training, :boolean, default: true

      # Key performance metrics for ranking
      add :profit_factor, :decimal
      add :net_profit, :decimal
      add :win_rate, :decimal
      add :total_trades, :integer, default: 0
      add :sharpe_ratio, :decimal
      add :sortino_ratio, :decimal
      add :max_drawdown_pct, :decimal
      add :expectancy, :decimal
      add :avg_r_multiple, :decimal

      # Validation metrics (populated after walk-forward analysis)
      add :degradation_pct, :decimal
      add :walk_forward_efficiency, :decimal
      add :is_overfit, :boolean

      # Aggregated out-of-sample metrics (for walk-forward summary)
      add :oos_profit_factor, :decimal
      add :oos_net_profit, :decimal
      add :oos_win_rate, :decimal
      add :oos_total_trades, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:optimization_results, [:optimization_run_id])
    create index(:optimization_results, [:backtest_run_id])
    create index(:optimization_results, [:optimization_run_id, :is_training])
    create index(:optimization_results, [:optimization_run_id, :window_index])

    # Composite index for finding best params
    create index(:optimization_results, [:optimization_run_id, :profit_factor])
  end
end
