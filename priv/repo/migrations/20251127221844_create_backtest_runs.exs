defmodule Signal.Repo.Migrations.CreateBacktestRuns do
  use Ecto.Migration

  def change do
    # Status enum for backtest runs
    execute(
      "CREATE TYPE backtest_status AS ENUM ('pending', 'running', 'completed', 'failed', 'cancelled')",
      "DROP TYPE backtest_status"
    )

    create table(:backtest_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Configuration
      add :symbols, {:array, :string}, null: false
      add :start_date, :date, null: false
      add :end_date, :date, null: false
      add :strategies, {:array, :string}, null: false
      add :parameters, :map, null: false, default: %{}

      # Capital and risk settings
      add :initial_capital, :decimal, null: false
      add :risk_per_trade, :decimal, null: false

      # Execution state
      add :status, :backtest_status, null: false, default: "pending"
      add :progress_pct, :decimal, default: 0
      add :current_date, :date
      add :bars_processed, :bigint, default: 0
      add :signals_generated, :integer, default: 0

      # Timing
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      # Error tracking
      add :error_message, :text

      timestamps()
    end

    create index(:backtest_runs, [:status])
    create index(:backtest_runs, [:inserted_at])
  end
end
