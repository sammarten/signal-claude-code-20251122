defmodule Signal.Repo.Migrations.CreateTradeSignals do
  use Ecto.Migration

  def change do
    create table(:trade_signals, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :symbol, :text, null: false
      add :strategy, :text, null: false
      add :direction, :text, null: false
      add :entry_price, :decimal, null: false
      add :stop_loss, :decimal, null: false
      add :take_profit, :decimal, null: false
      add :risk_reward, :decimal, null: false
      add :confluence_score, :integer, null: false
      add :quality_grade, :text, null: false
      add :confluence_factors, :map
      add :status, :text, null: false, default: "active"
      add :generated_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :filled_at, :utc_datetime_usec
      add :exit_price, :decimal
      add :pnl, :decimal

      # Setup reference data
      add :level_type, :text
      add :level_price, :decimal
      add :retest_bar_time, :utc_datetime_usec
      add :break_bar_time, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Add check constraints
    create constraint(:trade_signals, :valid_direction, check: "direction IN ('long', 'short')")

    create constraint(:trade_signals, :valid_status,
             check: "status IN ('active', 'filled', 'expired', 'invalidated', 'cancelled')"
           )

    create constraint(:trade_signals, :valid_quality_grade,
             check: "quality_grade IN ('A', 'B', 'C', 'D', 'F')"
           )

    create constraint(:trade_signals, :valid_strategy,
             check:
               "strategy IN ('break_and_retest', 'opening_range_breakout', 'one_candle_rule', 'premarket_breakout')"
           )

    # Indexes
    create index(:trade_signals, [:symbol, :status])
    create index(:trade_signals, [:generated_at])
    create index(:trade_signals, [:quality_grade, :confluence_score])
    create index(:trade_signals, [:symbol, :generated_at])
  end
end
