defmodule Signal.Repo.Migrations.AddExitStrategyFields do
  use Ecto.Migration

  def change do
    # Add new fields to simulated_trades for exit strategy tracking
    alter table(:simulated_trades) do
      # Exit strategy configuration
      add :exit_strategy_type, :string, default: "fixed"

      # Stop management tracking
      add :stop_moved_to_breakeven, :boolean, default: false
      add :final_stop, :decimal

      # Maximum favorable/adverse excursion (MFE/MAE) in R multiples
      add :max_favorable_r, :decimal
      add :max_adverse_r, :decimal

      # Partial exit tracking
      add :partial_exit_count, :integer, default: 0
    end

    # Create partial_exits table for tracking scale-out transactions
    create table(:partial_exits, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :trade_id,
          references(:simulated_trades, type: :binary_id, on_delete: :delete_all),
          null: false

      # Exit details
      add :exit_time, :utc_datetime_usec, null: false
      add :exit_price, :decimal, null: false
      add :shares_exited, :integer, null: false
      add :remaining_shares, :integer, null: false

      # Exit reason: "target_1", "target_2", "target_3", "trailing_stop", "breakeven_stop"
      add :exit_reason, :string, null: false

      # Target index if this was a target exit (0, 1, 2, etc.)
      add :target_index, :integer

      # P&L for this partial exit
      add :pnl, :decimal
      add :pnl_pct, :decimal
      add :r_multiple, :decimal

      timestamps(type: :utc_datetime_usec)
    end

    create index(:partial_exits, [:trade_id])
    create index(:partial_exits, [:exit_time])
  end
end
