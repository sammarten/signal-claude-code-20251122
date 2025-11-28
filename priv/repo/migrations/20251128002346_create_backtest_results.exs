defmodule Signal.Repo.Migrations.CreateBacktestResults do
  use Ecto.Migration

  def change do
    create table(:backtest_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :backtest_run_id,
          references(:backtest_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      # Trade metrics
      add :total_trades, :integer, null: false, default: 0
      add :winners, :integer, null: false, default: 0
      add :losers, :integer, null: false, default: 0
      add :breakeven, :integer, null: false, default: 0
      add :win_rate, :decimal
      add :loss_rate, :decimal
      add :gross_profit, :decimal
      add :gross_loss, :decimal
      add :net_profit, :decimal
      add :profit_factor, :decimal
      add :expectancy, :decimal
      add :avg_win, :decimal
      add :avg_loss, :decimal
      add :avg_pnl, :decimal
      add :avg_r_multiple, :decimal
      add :max_r_multiple, :decimal
      add :min_r_multiple, :decimal
      add :avg_hold_time_minutes, :integer
      add :max_hold_time_minutes, :integer
      add :min_hold_time_minutes, :integer

      # Drawdown metrics
      add :max_drawdown_pct, :decimal
      add :max_drawdown_dollars, :decimal
      add :max_drawdown_duration_days, :integer
      add :max_consecutive_losses, :integer, default: 0
      add :max_consecutive_wins, :integer, default: 0
      add :recovery_factor, :decimal

      # Risk-adjusted returns
      add :sharpe_ratio, :decimal
      add :sortino_ratio, :decimal
      add :calmar_ratio, :decimal
      add :volatility, :decimal

      # Return metrics
      add :total_return_pct, :decimal
      add :total_return_dollars, :decimal
      add :annualized_return_pct, :decimal

      # Detailed breakdowns stored as JSONB
      add :time_analysis, :map, default: %{}
      add :signal_analysis, :map, default: %{}
      add :equity_curve_data, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:backtest_results, [:backtest_run_id])
  end
end
