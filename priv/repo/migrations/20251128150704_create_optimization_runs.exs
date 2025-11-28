defmodule Signal.Repo.Migrations.CreateOptimizationRuns do
  use Ecto.Migration

  def change do
    create table(:optimization_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Configuration
      add :name, :string
      add :symbols, {:array, :string}, null: false
      add :start_date, :date, null: false
      add :end_date, :date, null: false
      add :strategies, {:array, :string}, null: false
      add :initial_capital, :decimal, null: false
      add :base_risk_per_trade, :decimal, null: false

      # Parameter grid configuration (JSONB)
      add :parameter_grid, :map, null: false, default: %{}

      # Walk-forward configuration (JSONB)
      add :walk_forward_config, :map, default: %{}

      # Optimization settings
      add :optimization_metric, :string, null: false, default: "profit_factor"
      add :min_trades, :integer, default: 30

      # Execution state
      add :status, :string, null: false, default: "pending"
      add :total_combinations, :integer, default: 0
      add :completed_combinations, :integer, default: 0
      add :progress_pct, :decimal, default: 0

      # Timing
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      # Error tracking
      add :error_message, :string

      # Best result reference (populated after completion)
      add :best_params, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:optimization_runs, [:status])
    create index(:optimization_runs, [:inserted_at])
  end
end
