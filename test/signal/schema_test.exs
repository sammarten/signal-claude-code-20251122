defmodule Signal.SchemaTest do
  use Signal.DataCase, async: false

  @moduletag :database

  describe "market_bars table" do
    test "has correct schema with all required columns" do
      query = """
      SELECT column_name, data_type, is_nullable
      FROM information_schema.columns
      WHERE table_name = 'market_bars'
      ORDER BY column_name
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)
      columns = Enum.map(result.rows, fn [name, type, nullable] -> {name, type, nullable} end)

      # Verify all expected columns exist
      assert {"bar_time", "timestamp with time zone", "NO"} in columns
      assert {"close", "numeric", "NO"} in columns
      assert {"high", "numeric", "NO"} in columns
      assert {"low", "numeric", "NO"} in columns
      assert {"open", "numeric", "NO"} in columns
      assert {"symbol", "text", "NO"} in columns
      assert {"trade_count", "integer", "YES"} in columns
      assert {"volume", "bigint", "NO"} in columns
      assert {"vwap", "numeric", "YES"} in columns
    end

    test "has composite primary key on (symbol, bar_time)" do
      query = """
      SELECT a.attname
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE i.indrelid = 'market_bars'::regclass AND i.indisprimary
      ORDER BY a.attname
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)
      pk_columns = Enum.map(result.rows, fn [name] -> name end)

      assert "bar_time" in pk_columns
      assert "symbol" in pk_columns
      assert length(pk_columns) == 2
    end

    test "has index on (symbol, bar_time)" do
      query = """
      SELECT indexname
      FROM pg_indexes
      WHERE tablename = 'market_bars'
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)
      indexes = Enum.map(result.rows, fn [name] -> name end)

      # Should have an index containing symbol and bar_time
      assert Enum.any?(indexes, fn idx ->
               String.contains?(idx, "symbol") or String.contains?(idx, "bar_time")
             end)
    end

    test "is a TimescaleDB hypertable" do
      query = """
      SELECT hypertable_name
      FROM timescaledb_information.hypertables
      WHERE hypertable_name = 'market_bars'
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)

      assert length(result.rows) == 1
      assert [["market_bars"]] = result.rows
    end

    test "has compression enabled" do
      query = """
      SELECT compression_enabled
      FROM timescaledb_information.hypertables
      WHERE hypertable_name = 'market_bars'
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)

      assert [[true]] = result.rows
    end

    test "has compression policy configured" do
      query = """
      SELECT COUNT(*)
      FROM timescaledb_information.jobs
      WHERE hypertable_name = 'market_bars'
        AND proc_name = 'policy_compression'
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)

      # Should have at least one compression policy
      assert [[count]] = result.rows
      assert count >= 1
    end

    test "can insert and query a bar" do
      # Insert test data
      bar_time = DateTime.truncate(DateTime.utc_now(), :second)

      insert_query = """
      INSERT INTO market_bars (symbol, bar_time, open, high, low, close, volume, vwap, trade_count, session, date)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """

      {:ok, _} =
        Ecto.Adapters.SQL.query(Repo, insert_query, [
          "TEST",
          bar_time,
          Decimal.new("100.00"),
          Decimal.new("101.00"),
          Decimal.new("99.00"),
          Decimal.new("100.50"),
          1_000_000,
          Decimal.new("100.25"),
          500,
          "regular",
          Date.utc_today()
        ])

      # Query it back
      select_query = """
      SELECT symbol, open, high, low, close, volume
      FROM market_bars
      WHERE symbol = $1 AND bar_time = $2
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, select_query, ["TEST", bar_time])

      assert [[symbol, open, high, low, close, volume]] = result.rows
      assert symbol == "TEST"
      assert Decimal.equal?(open, Decimal.new("100.00"))
      assert Decimal.equal?(high, Decimal.new("101.00"))
      assert Decimal.equal?(low, Decimal.new("99.00"))
      assert Decimal.equal?(close, Decimal.new("100.50"))
      assert volume == 1_000_000

      # Cleanup
      Ecto.Adapters.SQL.query(Repo, "DELETE FROM market_bars WHERE symbol = 'TEST'")
    end

    test "enforces primary key constraint" do
      bar_time = DateTime.truncate(DateTime.utc_now(), :second)

      insert_query = """
      INSERT INTO market_bars (symbol, bar_time, open, high, low, close, volume, session, date)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """

      params = [
        "DUPE",
        bar_time,
        100.0,
        101.0,
        99.0,
        100.5,
        1_000_000,
        "regular",
        Date.utc_today()
      ]

      # First insert should succeed
      {:ok, _} = Ecto.Adapters.SQL.query(Repo, insert_query, params)

      # Second insert with same symbol and bar_time should fail
      assert {:error, error} = Ecto.Adapters.SQL.query(Repo, insert_query, params)
      assert error.postgres.code == :unique_violation

      # Cleanup
      Ecto.Adapters.SQL.query(Repo, "DELETE FROM market_bars WHERE symbol = 'DUPE'")
    end
  end

  describe "events table" do
    test "has correct schema with all required columns" do
      query = """
      SELECT column_name, data_type, is_nullable
      FROM information_schema.columns
      WHERE table_name = 'events'
      ORDER BY column_name
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)
      columns = Enum.map(result.rows, fn [name, type, nullable] -> {name, type, nullable} end)

      # Verify required columns
      assert {"event_type", "character varying", "NO"} in columns
      assert {"id", "bigint", "NO"} in columns
      assert {"payload", "jsonb", "NO"} in columns
      assert {"stream_id", "character varying", "NO"} in columns
      assert {"timestamp", "timestamp without time zone", "NO"} in columns
      assert {"version", "integer", "NO"} in columns
    end

    test "has auto-incrementing primary key" do
      query = """
      SELECT column_name
      FROM information_schema.columns
      WHERE table_name = 'events'
        AND column_name = 'id'
        AND column_default LIKE 'nextval%'
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)
      assert length(result.rows) == 1
    end

    test "has unique constraint on (stream_id, version)" do
      query = """
      SELECT indexname
      FROM pg_indexes
      WHERE tablename = 'events'
        AND indexname = 'events_stream_version_unique'
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)
      assert length(result.rows) == 1
    end

    test "has indexes on stream_id, event_type, and timestamp" do
      query = """
      SELECT indexname
      FROM pg_indexes
      WHERE tablename = 'events'
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, query)
      indexes = Enum.map(result.rows, fn [name] -> name end)

      # Should have indexes on these fields
      assert Enum.any?(indexes, fn idx -> String.contains?(idx, "stream_id") end)
      assert Enum.any?(indexes, fn idx -> String.contains?(idx, "event_type") end)
      assert Enum.any?(indexes, fn idx -> String.contains?(idx, "timestamp") end)
    end

    test "can insert and query events" do
      # Insert test event
      insert_query = """
      INSERT INTO events (stream_id, event_type, payload, version, timestamp)
      VALUES ($1, $2, $3, $4, $5)
      RETURNING id
      """

      timestamp = DateTime.truncate(DateTime.utc_now(), :microsecond)
      payload = %{"key" => "value", "amount" => 100}

      {:ok, result} =
        Ecto.Adapters.SQL.query(Repo, insert_query, [
          "test-stream-1",
          "TestEvent",
          payload,
          1,
          timestamp
        ])

      assert [[id]] = result.rows
      assert is_integer(id)

      # Query it back
      select_query = """
      SELECT stream_id, event_type, payload, version
      FROM events
      WHERE id = $1
      """

      {:ok, result} = Ecto.Adapters.SQL.query(Repo, select_query, [id])

      assert [[stream_id, event_type, returned_payload, version]] = result.rows
      assert stream_id == "test-stream-1"
      assert event_type == "TestEvent"
      assert returned_payload == payload
      assert version == 1

      # Cleanup
      Ecto.Adapters.SQL.query(Repo, "DELETE FROM events WHERE id = $1", [id])
    end

    test "enforces unique constraint on (stream_id, version)" do
      insert_query = """
      INSERT INTO events (stream_id, event_type, payload, version)
      VALUES ($1, $2, $3, $4)
      """

      params = ["stream-unique", "Event", %{}, 1]

      # First insert should succeed
      {:ok, _} = Ecto.Adapters.SQL.query(Repo, insert_query, params)

      # Second insert with same stream_id and version should fail
      assert {:error, error} = Ecto.Adapters.SQL.query(Repo, insert_query, params)
      assert error.postgres.code == :unique_violation

      # Cleanup
      Ecto.Adapters.SQL.query(Repo, "DELETE FROM events WHERE stream_id = 'stream-unique'")
    end

    test "allows multiple events for same stream with different versions" do
      insert_query = """
      INSERT INTO events (stream_id, event_type, payload, version)
      VALUES ($1, $2, $3, $4)
      """

      stream_id = "multi-version-stream"

      # Insert multiple versions
      {:ok, _} = Ecto.Adapters.SQL.query(Repo, insert_query, [stream_id, "Event", %{}, 1])
      {:ok, _} = Ecto.Adapters.SQL.query(Repo, insert_query, [stream_id, "Event", %{}, 2])
      {:ok, _} = Ecto.Adapters.SQL.query(Repo, insert_query, [stream_id, "Event", %{}, 3])

      # Query count
      count_query = "SELECT COUNT(*) FROM events WHERE stream_id = $1"
      {:ok, result} = Ecto.Adapters.SQL.query(Repo, count_query, [stream_id])

      assert [[3]] = result.rows

      # Cleanup
      Ecto.Adapters.SQL.query(Repo, "DELETE FROM events WHERE stream_id = $1", [stream_id])
    end
  end
end
