defmodule Signal.Repo.Migrations.AddExpiresAtIndexToTradeSignals do
  use Ecto.Migration

  def change do
    # Index for expire_old_signals query: WHERE status = 'active' AND expires_at < now
    create index(:trade_signals, [:status, :expires_at])

    # Index for queries filtering by just expires_at
    create index(:trade_signals, [:expires_at])
  end
end
