defmodule Signal.Repo.Migrations.CreateMarketStructure do
  use Ecto.Migration

  def up do
    # Create table with composite primary key
    create table(:market_structure, primary_key: false) do
      add :symbol, :string, null: false
      add :timeframe, :string, null: false
      add :bar_time, :utc_datetime_usec, null: false
      add :trend, :string
      add :swing_type, :string
      add :swing_price, :decimal, precision: 10, scale: 2
      add :bos_detected, :boolean, default: false, null: false
      add :choch_detected, :boolean, default: false, null: false
    end

    # Add composite primary key
    execute """
    ALTER TABLE market_structure
    ADD PRIMARY KEY (symbol, timeframe, bar_time)
    """

    # Add check constraints for enum-like fields
    execute """
    ALTER TABLE market_structure
    ADD CONSTRAINT trend_values CHECK (trend IN ('bullish', 'bearish', 'ranging'))
    """

    execute """
    ALTER TABLE market_structure
    ADD CONSTRAINT swing_type_values CHECK (swing_type IN ('high', 'low'))
    """

    # Convert to TimescaleDB hypertable (partitioned by bar_time)
    execute """
    SELECT create_hypertable(
      'market_structure',
      'bar_time',
      chunk_time_interval => INTERVAL '7 days'
    )
    """

    # Create index for efficient symbol/timeframe queries
    create index(:market_structure, [:symbol, :timeframe, :bar_time])

    # Create index for swing queries
    create index(:market_structure, [:symbol, :swing_type, :bar_time])

    # Create index for BOS/ChoCh queries
    create index(:market_structure, [:symbol, :bos_detected, :bar_time])
    create index(:market_structure, [:symbol, :choch_detected, :bar_time])

    # Enable compression (segmented by symbol and timeframe)
    execute """
    ALTER TABLE market_structure SET (
      timescaledb.compress,
      timescaledb.compress_segmentby = 'symbol,timeframe'
    )
    """

    # Add compression policy (compress chunks older than 30 days)
    execute """
    SELECT add_compression_policy('market_structure', INTERVAL '30 days')
    """

    # Add retention policy (keep data for 6 years)
    execute """
    SELECT add_retention_policy('market_structure', INTERVAL '6 years')
    """
  end

  def down do
    # Remove policies first
    execute """
    SELECT remove_compression_policy('market_structure')
    """

    execute """
    SELECT remove_retention_policy('market_structure')
    """

    # Drop the table (hypertable drops automatically)
    drop table(:market_structure)
  end
end
