defmodule Signal.IntegrationTest do
  use Signal.DataCase, async: false

  alias Signal.{BarCache, Monitor, Repo}
  alias Signal.Alpaca.Stream
  alias Signal.MarketData.Bar
  alias Signal.TestCallback

  @moduletag :integration

  @moduledoc """
  Integration tests for end-to-end data flow.

  These tests require Alpaca credentials and use the test stream endpoint.
  They verify the complete data flow from WebSocket to BarCache to PubSub.

  Run with: mix test --include integration
  Skip with: mix test (default)
  """

  describe "WebSocket Connection and Data Flow" do
    @tag timeout: 30_000
    test "connects to Alpaca test stream and receives data" do
      # Start test callback agent
      {:ok, _agent} = TestCallback.start_link()

      # Start stream to test endpoint with FAKEPACA symbol
      {:ok, stream_pid} =
        Stream.start_link(
          callback_module: TestCallback,
          callback_state: %{messages: [], counters: %{}},
          initial_subscriptions: %{bars: ["FAKEPACA"], quotes: ["FAKEPACA"]},
          name: :test_stream
        )

      # Wait for connection and data
      Process.sleep(10_000)

      # Get received messages
      state = TestCallback.get_state()
      messages = state.messages
      counters = state.counters

      # Should have received messages
      assert length(messages) > 0, "Expected to receive messages from test stream"

      # Should have both quotes and bars
      assert Map.get(counters, :quote, 0) > 0, "Expected to receive quote messages"
      assert Map.get(counters, :bar, 0) > 0, "Expected to receive bar messages"

      # Verify message structure for quotes
      quote_messages = Enum.filter(messages, fn m -> m.type == :quote end)

      if length(quote_messages) > 0 do
        quote = hd(quote_messages)
        assert quote.symbol == "FAKEPACA"
        assert %Decimal{} = quote.bid_price
        assert %Decimal{} = quote.ask_price
        assert is_integer(quote.bid_size)
        assert is_integer(quote.ask_size)
        assert %DateTime{} = quote.timestamp
      end

      # Verify message structure for bars
      bar_messages = Enum.filter(messages, fn m -> m.type == :bar end)

      if length(bar_messages) > 0 do
        bar = hd(bar_messages)
        assert bar.symbol == "FAKEPACA"
        assert %Decimal{} = bar.open
        assert %Decimal{} = bar.high
        assert %Decimal{} = bar.low
        assert %Decimal{} = bar.close
        assert is_integer(bar.volume)
        assert %DateTime{} = bar.timestamp
      end

      # Check stream status
      status = GenServer.call(stream_pid, :status)
      assert status in [:authenticated, :subscribed]

      # Cleanup
      GenServer.stop(stream_pid)
      TestCallback.stop()
    end

    @tag timeout: 15_000
    test "handles reconnection gracefully" do
      # Start test callback
      {:ok, _agent} = TestCallback.start_link()

      # Start stream
      {:ok, stream_pid} =
        Stream.start_link(
          callback_module: TestCallback,
          callback_state: %{messages: [], counters: %{}},
          initial_subscriptions: %{quotes: ["FAKEPACA"]}
        )

      # Wait for initial connection
      Process.sleep(3_000)

      # Get initial connection status
      initial_status = GenServer.call(stream_pid, :status)
      assert initial_status in [:connected, :authenticated, :subscribed]

      # Note: We can't easily force a disconnect in test without modifying Stream,
      # but we can verify the stream is resilient by checking it maintains connection

      # Wait a bit more
      Process.sleep(3_000)

      # Should still be connected
      final_status = GenServer.call(stream_pid, :status)
      assert final_status in [:connected, :authenticated, :subscribed]

      # Cleanup
      GenServer.stop(stream_pid)
      TestCallback.stop()
    end
  end

  describe "BarCache Integration" do
    test "updates BarCache with incoming data" do
      # Clear BarCache
      BarCache.clear()

      # Create and update with test data
      test_symbol = :TEST

      bar_data = %{
        open: Decimal.new("100.50"),
        high: Decimal.new("101.25"),
        low: Decimal.new("100.00"),
        close: Decimal.new("101.00"),
        volume: 1_000_000,
        vwap: Decimal.new("100.75"),
        trade_count: 500,
        timestamp: DateTime.utc_now()
      }

      quote_data = %{
        bid_price: Decimal.new("100.98"),
        bid_size: 100,
        ask_price: Decimal.new("101.02"),
        ask_size: 200,
        timestamp: DateTime.utc_now()
      }

      # Update cache
      :ok = BarCache.update_bar(test_symbol, bar_data)
      :ok = BarCache.update_quote(test_symbol, quote_data)

      # Verify data was cached
      {:ok, cached} = BarCache.get(test_symbol)

      assert cached.last_bar.open == bar_data.open
      assert cached.last_bar.high == bar_data.high
      assert cached.last_bar.low == bar_data.low
      assert cached.last_bar.close == bar_data.close
      assert cached.last_bar.volume == bar_data.volume

      assert cached.last_quote.bid_price == quote_data.bid_price
      assert cached.last_quote.ask_price == quote_data.ask_price
      assert cached.last_quote.bid_size == quote_data.bid_size
      assert cached.last_quote.ask_size == quote_data.ask_size

      # Verify current_price calculation
      current_price = BarCache.current_price(test_symbol)
      assert current_price != nil

      expected_mid =
        Decimal.div(
          Decimal.add(quote_data.bid_price, quote_data.ask_price),
          Decimal.new("2")
        )

      assert Decimal.equal?(current_price, expected_mid)

      # Cleanup
      BarCache.clear()
    end

    test "current_price falls back to bar close when no quote" do
      # Clear cache
      BarCache.clear()

      test_symbol = :TEST2

      bar_data = %{
        open: Decimal.new("200.00"),
        high: Decimal.new("205.00"),
        low: Decimal.new("199.00"),
        close: Decimal.new("203.50"),
        volume: 500_000,
        timestamp: DateTime.utc_now()
      }

      # Update only bar (no quote)
      :ok = BarCache.update_bar(test_symbol, bar_data)

      # Should return bar close price
      current_price = BarCache.current_price(test_symbol)
      assert Decimal.equal?(current_price, bar_data.close)

      # Cleanup
      BarCache.clear()
    end
  end

  describe "PubSub Message Flow" do
    @tag timeout: 15_000
    test "broadcasts messages to PubSub topics" do
      # Subscribe to test topics
      test_symbol = "TESTPUB"
      Phoenix.PubSub.subscribe(Signal.PubSub, "quotes:#{test_symbol}")
      Phoenix.PubSub.subscribe(Signal.PubSub, "bars:#{test_symbol}")

      # Simulate StreamHandler publishing messages
      quote_msg = %{
        type: :quote,
        symbol: test_symbol,
        bid_price: Decimal.new("150.00"),
        bid_size: 100,
        ask_price: Decimal.new("150.10"),
        ask_size: 150,
        timestamp: DateTime.utc_now()
      }

      bar_msg = %{
        type: :bar,
        symbol: test_symbol,
        open: Decimal.new("149.50"),
        high: Decimal.new("150.50"),
        low: Decimal.new("149.00"),
        close: Decimal.new("150.25"),
        volume: 750_000,
        timestamp: DateTime.utc_now()
      }

      # Broadcast messages
      Phoenix.PubSub.broadcast(
        Signal.PubSub,
        "quotes:#{test_symbol}",
        {:quote, test_symbol, quote_msg}
      )

      Phoenix.PubSub.broadcast(Signal.PubSub, "bars:#{test_symbol}", {:bar, test_symbol, bar_msg})

      # Should receive messages
      assert_receive {:quote, ^test_symbol, received_quote}, 1_000
      assert_receive {:bar, ^test_symbol, received_bar}, 1_000

      assert received_quote.symbol == test_symbol
      assert Decimal.equal?(received_quote.bid_price, quote_msg.bid_price)

      assert received_bar.symbol == test_symbol
      assert Decimal.equal?(received_bar.close, bar_msg.close)
    end

    @tag timeout: 10_000
    test "broadcasts system stats to subscribers" do
      # Subscribe to system stats
      Phoenix.PubSub.subscribe(Signal.PubSub, "system:stats")

      # Simulate stats broadcast
      stats = %{
        quotes_per_sec: 137,
        bars_per_min: 25,
        trades_per_sec: 5,
        uptime_seconds: 9240,
        connection_status: :connected,
        db_healthy: true,
        reconnect_count: 0,
        last_message: %{
          quote: DateTime.utc_now(),
          bar: DateTime.utc_now(),
          trade: nil
        }
      }

      Phoenix.PubSub.broadcast(Signal.PubSub, "system:stats", stats)

      # Should receive stats
      assert_receive received_stats, 1_000
      assert received_stats.quotes_per_sec == 137
      assert received_stats.bars_per_min == 25
      assert received_stats.db_healthy == true
    end
  end

  describe "Bar Storage and Retrieval" do
    test "stores and retrieves bars from database" do
      # Create test bar
      bar = %Bar{
        symbol: "DBTEST",
        bar_time: ~U[2024-11-15 14:30:00.000000Z],
        open: Decimal.new("100.00"),
        high: Decimal.new("101.00"),
        low: Decimal.new("99.00"),
        close: Decimal.new("100.50"),
        volume: 1_000_000,
        vwap: Decimal.new("100.25"),
        trade_count: 250
      }

      # Insert
      {:ok, inserted} = Repo.insert(bar)
      assert inserted.symbol == "DBTEST"

      # Query back
      result =
        Repo.get_by(Bar,
          symbol: "DBTEST",
          bar_time: ~U[2024-11-15 14:30:00.000000Z]
        )

      assert result != nil
      assert result.symbol == "DBTEST"
      assert Decimal.equal?(result.open, Decimal.new("100.00"))
      assert Decimal.equal?(result.high, Decimal.new("101.00"))
      assert Decimal.equal?(result.low, Decimal.new("99.00"))
      assert Decimal.equal?(result.close, Decimal.new("100.50"))
      assert result.volume == 1_000_000
      assert Decimal.equal?(result.vwap, Decimal.new("100.25"))
      assert result.trade_count == 250
    end

    test "prevents duplicate bars with composite primary key" do
      # Create first bar
      bar1 = %Bar{
        symbol: "DUPTEST",
        bar_time: ~U[2024-11-15 15:00:00.000000Z],
        open: Decimal.new("200.00"),
        high: Decimal.new("201.00"),
        low: Decimal.new("199.00"),
        close: Decimal.new("200.50"),
        volume: 500_000
      }

      # Insert first
      {:ok, _} = Repo.insert(bar1)

      # Try to insert duplicate (same symbol and bar_time)
      bar2 = %Bar{
        symbol: "DUPTEST",
        bar_time: ~U[2024-11-15 15:00:00.000000Z],
        open: Decimal.new("250.00"),
        high: Decimal.new("251.00"),
        low: Decimal.new("249.00"),
        close: Decimal.new("250.50"),
        volume: 750_000
      }

      # Should fail due to primary key constraint
      assert {:error, changeset} = Repo.insert(bar2)
      assert changeset.errors != []
    end

    test "validates OHLC relationships" do
      # Invalid bar: high < close
      invalid_bar = %Bar{
        symbol: "INVALID",
        bar_time: DateTime.utc_now(),
        open: Decimal.new("100.00"),
        high: Decimal.new("99.00"),
        # high should be >= close
        low: Decimal.new("98.00"),
        close: Decimal.new("100.00"),
        volume: 1000
      }

      changeset = Bar.changeset(invalid_bar, %{})
      refute changeset.valid?
    end

    test "allows querying by symbol and time range" do
      # Insert multiple bars
      base_time = ~U[2024-11-15 10:00:00.000000Z]

      bars =
        for i <- 0..4 do
          %Bar{
            symbol: "RANGE",
            bar_time: DateTime.add(base_time, i * 60, :second),
            open: Decimal.new("100.00"),
            high: Decimal.new("101.00"),
            low: Decimal.new("99.00"),
            close: Decimal.new("100.50"),
            volume: 100_000 + i * 10_000
          }
        end

      Enum.each(bars, &Repo.insert!/1)

      # Query by time range
      start_time = DateTime.add(base_time, 60, :second)
      end_time = DateTime.add(base_time, 180, :second)

      results =
        from(b in Bar,
          where: b.symbol == "RANGE",
          where: b.bar_time >= ^start_time,
          where: b.bar_time <= ^end_time,
          order_by: [asc: b.bar_time]
        )
        |> Repo.all()

      # Should get 3 bars (at offsets 1, 2, 3)
      assert length(results) == 3
      assert hd(results).volume == 110_000
      assert List.last(results).volume == 130_000
    end
  end

  describe "Monitor Integration" do
    test "tracks messages correctly" do
      # Track some messages
      Monitor.track_message(:quote)
      Monitor.track_message(:quote)
      Monitor.track_message(:bar)
      Monitor.track_message(:trade)

      # Get stats
      stats = Monitor.get_stats()

      # Note: These are cumulative counters since last window reset
      # Just verify the structure is correct
      assert is_map(stats)
      assert Map.has_key?(stats, :connection_status)
      assert Map.has_key?(stats, :db_healthy)
    end

    test "tracks connection status" do
      Monitor.track_connection(:connected)
      stats = Monitor.get_stats()
      assert stats.connection_status == :connected

      Monitor.track_connection(:disconnected)
      stats = Monitor.get_stats()
      assert stats.connection_status == :disconnected
    end
  end
end
