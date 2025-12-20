defmodule Signal.Repo.Migrations.ExtendKeyLevelsForPreview do
  use Ecto.Migration

  def change do
    alter table(:key_levels) do
      # Previous day open/close for gap analysis
      add :previous_day_open, :decimal, precision: 10, scale: 2
      add :previous_day_close, :decimal, precision: 10, scale: 2

      # Weekly levels for range analysis
      add :last_week_high, :decimal, precision: 10, scale: 2
      add :last_week_low, :decimal, precision: 10, scale: 2
      add :last_week_close, :decimal, precision: 10, scale: 2

      # Derived levels
      add :equilibrium, :decimal, precision: 10, scale: 2

      # All-time high (cached for performance)
      add :all_time_high, :decimal, precision: 10, scale: 2
    end
  end
end
