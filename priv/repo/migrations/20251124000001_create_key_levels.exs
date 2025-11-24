defmodule Signal.Repo.Migrations.CreateKeyLevels do
  use Ecto.Migration

  def up do
    # Create table with composite primary key
    create table(:key_levels, primary_key: false) do
      add :symbol, :text, null: false
      add :date, :date, null: false
      add :previous_day_high, :decimal, precision: 10, scale: 2
      add :previous_day_low, :decimal, precision: 10, scale: 2
      add :premarket_high, :decimal, precision: 10, scale: 2
      add :premarket_low, :decimal, precision: 10, scale: 2
      add :opening_range_5m_high, :decimal, precision: 10, scale: 2
      add :opening_range_5m_low, :decimal, precision: 10, scale: 2
      add :opening_range_15m_high, :decimal, precision: 10, scale: 2
      add :opening_range_15m_low, :decimal, precision: 10, scale: 2
    end

    # Add composite primary key
    execute """
    ALTER TABLE key_levels
    ADD PRIMARY KEY (symbol, date)
    """

    # Convert to TimescaleDB hypertable (partitioned by date)
    execute """
    SELECT create_hypertable(
      'key_levels',
      'date',
      chunk_time_interval => INTERVAL '30 days'
    )
    """

    # Create index for efficient symbol queries
    create index(:key_levels, [:symbol, :date])

    # Create index for date-based queries
    create index(:key_levels, [:date])

    # Enable compression (segmented by symbol)
    execute """
    ALTER TABLE key_levels SET (
      timescaledb.compress,
      timescaledb.compress_segmentby = 'symbol'
    )
    """

    # Add compression policy (compress chunks older than 30 days)
    execute """
    SELECT add_compression_policy('key_levels', INTERVAL '30 days')
    """

    # Add retention policy (keep data for 6 years)
    execute """
    SELECT add_retention_policy('key_levels', INTERVAL '6 years')
    """
  end

  def down do
    # Remove policies first
    execute """
    SELECT remove_compression_policy('key_levels')
    """

    execute """
    SELECT remove_retention_policy('key_levels')
    """

    # Drop the table (hypertable drops automatically)
    drop table(:key_levels)
  end
end
