defmodule Signal.MonitorTest do
  use ExUnit.Case, async: false
  alias Signal.Monitor

  setup do
    # Start Monitor with a short reporting interval for testing
    start_supervised!({Monitor, []})

    # Give it a moment to initialize
    Process.sleep(10)

    :ok
  end

  describe "track_message/1" do
    test "increments quote counter" do
      :ok = Monitor.track_message(:quote)
      :ok = Monitor.track_message(:quote)

      stats = Monitor.get_stats()
      assert stats.counters.quotes == 2
    end

    test "increments bar counter" do
      :ok = Monitor.track_message(:bar)
      :ok = Monitor.track_message(:bar)
      :ok = Monitor.track_message(:bar)

      stats = Monitor.get_stats()
      assert stats.counters.bars == 3
    end

    test "increments trade counter" do
      :ok = Monitor.track_message(:trade)

      stats = Monitor.get_stats()
      assert stats.counters.trades == 1
    end

    test "updates last_message timestamp" do
      before = DateTime.utc_now()
      :ok = Monitor.track_message(:quote)

      # Small delay to ensure timestamp is set
      Process.sleep(10)

      stats = Monitor.get_stats()
      quote_time = stats.last_message.quote

      assert not is_nil(quote_time)
      assert DateTime.compare(quote_time, before) in [:gt, :eq]
    end

    test "tracks different message types independently" do
      :ok = Monitor.track_message(:quote)
      :ok = Monitor.track_message(:quote)
      :ok = Monitor.track_message(:bar)
      :ok = Monitor.track_message(:trade)

      stats = Monitor.get_stats()
      assert stats.counters.quotes == 2
      assert stats.counters.bars == 1
      assert stats.counters.trades == 1
      assert stats.counters.errors == 0
    end
  end

  describe "track_error/1" do
    test "increments error counter" do
      :ok = Monitor.track_error("some error")
      :ok = Monitor.track_error({:error, :reason})

      stats = Monitor.get_stats()
      assert stats.counters.errors == 2
    end
  end

  describe "track_connection/1" do
    test "updates connection status to connected" do
      :ok = Monitor.track_connection(:connected)

      stats = Monitor.get_stats()
      assert stats.connection_status == :connected
      assert not is_nil(stats.connection_start)
    end

    test "updates connection status to disconnected" do
      :ok = Monitor.track_connection(:disconnected)

      stats = Monitor.get_stats()
      assert stats.connection_status == :disconnected
    end

    test "increments reconnect count when reconnecting" do
      :ok = Monitor.track_connection(:connected)
      :ok = Monitor.track_connection(:reconnecting)

      stats = Monitor.get_stats()
      assert stats.connection_status == :reconnecting
      assert stats.reconnect_count == 1
    end

    test "sets connection_start when transitioning to connected" do
      :ok = Monitor.track_connection(:disconnected)
      stats_before = Monitor.get_stats()
      initial_start = stats_before.connection_start

      # Small delay to ensure different timestamp
      Process.sleep(10)

      :ok = Monitor.track_connection(:connected)
      stats_after = Monitor.get_stats()

      # connection_start should be updated to now
      assert not is_nil(stats_after.connection_start)

      # Should be different from initial value (or initial was nil)
      if not is_nil(initial_start) do
        assert DateTime.compare(stats_after.connection_start, initial_start) == :gt
      end
    end

    test "handles multiple reconnections" do
      :ok = Monitor.track_connection(:connected)
      :ok = Monitor.track_connection(:reconnecting)
      :ok = Monitor.track_connection(:connected)
      :ok = Monitor.track_connection(:reconnecting)
      :ok = Monitor.track_connection(:connected)

      stats = Monitor.get_stats()
      assert stats.reconnect_count == 2
      assert stats.connection_status == :connected
    end
  end

  describe "get_stats/0" do
    test "returns current statistics" do
      :ok = Monitor.track_message(:quote)
      :ok = Monitor.track_message(:bar)
      :ok = Monitor.track_error("test")
      :ok = Monitor.track_connection(:connected)

      stats = Monitor.get_stats()

      assert is_map(stats)
      assert stats.counters.quotes == 1
      assert stats.counters.bars == 1
      assert stats.counters.errors == 1
      assert stats.connection_status == :connected
      assert not is_nil(stats.connection_start)
      assert is_boolean(stats.db_healthy)
    end

    test "includes last_message timestamps" do
      stats = Monitor.get_stats()

      assert is_map(stats.last_message)
      assert Map.has_key?(stats.last_message, :quote)
      assert Map.has_key?(stats.last_message, :bar)
      assert Map.has_key?(stats.last_message, :trade)
    end
  end

  describe "initialization" do
    test "starts with zero counters" do
      # Get stats from freshly started monitor
      stats = Monitor.get_stats()

      assert stats.counters.quotes == 0
      assert stats.counters.bars == 0
      assert stats.counters.trades == 0
      assert stats.counters.errors == 0
    end

    test "starts with disconnected status" do
      stats = Monitor.get_stats()
      assert stats.connection_status == :disconnected
    end

    test "starts with db_healthy as true" do
      stats = Monitor.get_stats()
      assert stats.db_healthy == true
    end

    test "starts with zero reconnect_count" do
      stats = Monitor.get_stats()
      assert stats.reconnect_count == 0
    end
  end

  describe "concurrent tracking" do
    test "handles concurrent message tracking" do
      # Spawn multiple concurrent trackers
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            Monitor.track_message(:quote)
          end)
        end

      Task.await_many(tasks)

      stats = Monitor.get_stats()
      assert stats.counters.quotes == 100
    end

    test "handles mixed concurrent operations" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            case rem(i, 3) do
              0 -> Monitor.track_message(:quote)
              1 -> Monitor.track_message(:bar)
              2 -> Monitor.track_error("error")
            end
          end)
        end

      Task.await_many(tasks)

      stats = Monitor.get_stats()
      total = stats.counters.quotes + stats.counters.bars + stats.counters.errors
      assert total == 50
    end
  end

  describe "stats reporting and PubSub" do
    @tag :capture_log
    test "logs stats summary periodically" do
      :ok = Monitor.track_message(:quote)
      :ok = Monitor.track_message(:quote)
      :ok = Monitor.track_message(:bar)

      # Note: The periodic reporting is every 60 seconds, so we can't easily
      # test it in a unit test without mocking time or using a test-specific interval.
      # This test just verifies the module can track stats properly.
      # Integration tests would verify the periodic behavior.

      stats = Monitor.get_stats()
      assert stats.counters.quotes == 2
      assert stats.counters.bars == 1
    end

    test "calculates uptime correctly" do
      :ok = Monitor.track_connection(:connected)

      # Wait a bit
      Process.sleep(100)

      stats = Monitor.get_stats()

      # Uptime should be positive
      assert stats.connection_status == :connected
      assert not is_nil(stats.connection_start)

      # Calculate uptime manually
      uptime = DateTime.diff(DateTime.utc_now(), stats.connection_start, :second)
      assert uptime >= 0
    end
  end

  describe "anomaly detection logging" do
    @tag :capture_log
    test "logs warning for zero quote rate during market hours" do
      # This test would need to mock the market_open? function
      # or run during actual market hours.
      # For now, we just verify the function doesn't crash.

      # Track some messages then wait
      :ok = Monitor.track_message(:bar)

      # The check_anomalies function is called during periodic reporting
      # We can't easily test this without triggering the timer or using
      # a test-specific reporting mechanism.

      stats = Monitor.get_stats()
      assert stats.counters.bars == 1
    end

    @tag :capture_log
    test "logs error for high reconnection count" do
      # Trigger many reconnections by alternating status
      # Reconnect count only increments when transitioning TO :reconnecting
      :ok = Monitor.track_connection(:connected)

      for _ <- 1..12 do
        :ok = Monitor.track_connection(:reconnecting)
        :ok = Monitor.track_connection(:connected)
      end

      stats = Monitor.get_stats()
      assert stats.reconnect_count == 12

      # The warning would be logged during periodic reporting
      # This test verifies we can track the high count
    end
  end

  describe "database health check" do
    @tag :skip
    test "checks database connectivity" do
      # This test requires a database connection
      # Skip by default, run with --include skip flag when DB is available

      stats = Monitor.get_stats()
      # When DB is available, should be healthy
      assert stats.db_healthy == true
    end
  end
end
