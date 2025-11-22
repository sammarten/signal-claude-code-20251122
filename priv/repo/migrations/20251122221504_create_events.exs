defmodule Signal.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def up do
    create table(:events) do
      add :stream_id, :string, null: false
      add :event_type, :string, null: false
      add :payload, :jsonb, null: false, default: "{}"
      add :version, :integer, null: false
      add :timestamp, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    # Index for reading events from a stream in order
    create index(:events, [:stream_id, :version])

    # Index for querying by event type
    create index(:events, [:event_type])

    # Index for time-based queries
    create index(:events, [:timestamp])

    # Unique constraint for optimistic locking
    create unique_index(:events, [:stream_id, :version],
             name: :events_stream_version_unique
           )
  end

  def down do
    drop table(:events)
  end
end
