defmodule Signal.Repo.Migrations.CreateOptionsBars do
  use Ecto.Migration

  def up do
    # Create table with composite primary key
    create table(:options_bars, primary_key: false) do
      add :symbol, :text, null: false
      add :bar_time, :timestamptz, null: false
      add :open, :decimal, precision: 10, scale: 4
      add :high, :decimal, precision: 10, scale: 4
      add :low, :decimal, precision: 10, scale: 4
      add :close, :decimal, precision: 10, scale: 4
      add :volume, :bigint
      add :vwap, :decimal, precision: 10, scale: 4
      add :trade_count, :integer
    end

    # Add composite primary key
    execute """
    ALTER TABLE options_bars
    ADD PRIMARY KEY (symbol, bar_time)
    """

    # Convert to TimescaleDB hypertable
    execute """
    SELECT create_hypertable(
      'options_bars',
      'bar_time',
      chunk_time_interval => INTERVAL '1 day'
    )
    """

    # Create index for efficient symbol queries
    create index(:options_bars, [:symbol, :bar_time])

    # Enable compression
    execute """
    ALTER TABLE options_bars SET (
      timescaledb.compress,
      timescaledb.compress_segmentby = 'symbol'
    )
    """

    # Add compression policy (compress chunks older than 7 days)
    execute """
    SELECT add_compression_policy('options_bars', INTERVAL '7 days')
    """

    # Add retention policy (keep data for 3 years - less than equity since options expire)
    execute """
    SELECT add_retention_policy('options_bars', INTERVAL '3 years')
    """
  end

  def down do
    # Remove policies first
    execute """
    SELECT remove_compression_policy('options_bars')
    """

    execute """
    SELECT remove_retention_policy('options_bars')
    """

    # Drop the table (hypertable drops automatically)
    drop table(:options_bars)
  end
end
