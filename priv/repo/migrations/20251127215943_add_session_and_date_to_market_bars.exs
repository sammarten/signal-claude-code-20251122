defmodule Signal.Repo.Migrations.AddSessionAndDateToMarketBars do
  use Ecto.Migration

  def up do
    # Add session enum type
    execute """
    CREATE TYPE market_session AS ENUM ('pre_market', 'regular', 'after_hours')
    """

    # Add new columns with defaults (required for TimescaleDB hypertables with columnstore)
    # The defaults are placeholders - new data will have correct values computed by the app
    alter table(:market_bars) do
      add :session, :market_session, null: false, default: "regular"
      add :date, :date, null: false, default: "2020-01-01"
    end

    # Remove defaults after column creation (new inserts will provide values)
    execute "ALTER TABLE market_bars ALTER COLUMN session DROP DEFAULT"
    execute "ALTER TABLE market_bars ALTER COLUMN date DROP DEFAULT"

    # Create composite index for efficient queries by symbol, date, and session
    # This also covers queries on (symbol, date) due to leftmost prefix rule
    create index(:market_bars, [:symbol, :date, :session])
  end

  def down do
    drop index(:market_bars, [:symbol, :date, :session])

    alter table(:market_bars) do
      remove :session
      remove :date
    end

    execute "DROP TYPE market_session"
  end
end
