defmodule Signal.Repo.Migrations.CreateSimulatedTrades do
  use Ecto.Migration

  def up do
    # Create enum for trade status
    execute """
    CREATE TYPE trade_status AS ENUM ('open', 'stopped_out', 'target_hit', 'time_exit', 'manual_exit')
    """

    # Create enum for trade direction
    execute """
    CREATE TYPE trade_direction AS ENUM ('long', 'short')
    """

    create table(:simulated_trades, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :backtest_run_id, references(:backtest_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :signal_id, :binary_id

      # Trade identification
      add :symbol, :string, null: false
      add :direction, :trade_direction, null: false

      # Entry details
      add :entry_price, :decimal, null: false
      add :entry_time, :utc_datetime_usec, null: false
      add :position_size, :integer, null: false
      add :risk_amount, :decimal, null: false

      # Stop/target levels
      add :stop_loss, :decimal, null: false
      add :take_profit, :decimal

      # Exit details
      add :status, :trade_status, null: false, default: "open"
      add :exit_price, :decimal
      add :exit_time, :utc_datetime_usec

      # P&L
      add :pnl, :decimal
      add :pnl_pct, :decimal
      add :r_multiple, :decimal

      # Metadata
      add :fill_type, :string, default: "signal_price"
      add :slippage, :decimal, default: 0
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:simulated_trades, [:backtest_run_id])
    create index(:simulated_trades, [:symbol])
    create index(:simulated_trades, [:status])
    create index(:simulated_trades, [:entry_time])
  end

  def down do
    drop table(:simulated_trades)
    execute "DROP TYPE trade_status"
    execute "DROP TYPE trade_direction"
  end
end
