defmodule Signal.BarCacheTest do
  use ExUnit.Case, async: false
  alias Signal.BarCache

  setup do
    # Start a fresh BarCache for each test
    {:ok, pid} = start_supervised(BarCache)
    # Clear any existing data
    BarCache.clear()
    {:ok, cache_pid: pid}
  end

  describe "get/1" do
    test "returns error when symbol not found" do
      assert {:error, :not_found} = BarCache.get(:AAPL)
    end

    test "returns data after symbol is updated" do
      bar = sample_bar()
      :ok = BarCache.update_bar(:AAPL, bar)

      assert {:ok, %{last_bar: ^bar, last_quote: nil}} = BarCache.get(:AAPL)
    end
  end

  describe "get_bar/1" do
    test "returns nil when symbol not found" do
      assert nil == BarCache.get_bar(:AAPL)
    end

    test "returns bar after update" do
      bar = sample_bar()
      :ok = BarCache.update_bar(:AAPL, bar)

      assert ^bar = BarCache.get_bar(:AAPL)
    end

    test "returns nil when only quote is present" do
      quote = sample_quote()
      :ok = BarCache.update_quote(:AAPL, quote)

      assert nil == BarCache.get_bar(:AAPL)
    end
  end

  describe "get_quote/1" do
    test "returns nil when symbol not found" do
      assert nil == BarCache.get_quote(:AAPL)
    end

    test "returns quote after update" do
      quote = sample_quote()
      :ok = BarCache.update_quote(:AAPL, quote)

      assert ^quote = BarCache.get_quote(:AAPL)
    end

    test "returns nil when only bar is present" do
      bar = sample_bar()
      :ok = BarCache.update_bar(:AAPL, bar)

      assert nil == BarCache.get_quote(:AAPL)
    end
  end

  describe "current_price/1" do
    test "returns nil when symbol not found" do
      assert nil == BarCache.current_price(:AAPL)
    end

    test "calculates mid-point from quote when available" do
      quote = %{
        bid_price: Decimal.new("100.00"),
        bid_size: 100,
        ask_price: Decimal.new("100.10"),
        ask_size: 200,
        timestamp: DateTime.utc_now()
      }

      :ok = BarCache.update_quote(:AAPL, quote)

      price = BarCache.current_price(:AAPL)
      assert Decimal.equal?(price, Decimal.new("100.05"))
    end

    test "uses bar close when quote not available" do
      bar = %{
        open: Decimal.new("100.00"),
        high: Decimal.new("101.00"),
        low: Decimal.new("99.00"),
        close: Decimal.new("100.50"),
        volume: 1_000_000,
        vwap: Decimal.new("100.25"),
        trade_count: 500,
        timestamp: DateTime.utc_now()
      }

      :ok = BarCache.update_bar(:AAPL, bar)

      price = BarCache.current_price(:AAPL)
      assert Decimal.equal?(price, Decimal.new("100.50"))
    end

    test "prefers quote over bar when both available" do
      bar = %{
        open: Decimal.new("100.00"),
        high: Decimal.new("101.00"),
        low: Decimal.new("99.00"),
        close: Decimal.new("100.50"),
        volume: 1_000_000,
        timestamp: DateTime.utc_now()
      }

      quote = %{
        bid_price: Decimal.new("100.60"),
        ask_price: Decimal.new("100.70"),
        bid_size: 100,
        ask_size: 200,
        timestamp: DateTime.utc_now()
      }

      :ok = BarCache.update_bar(:AAPL, bar)
      :ok = BarCache.update_quote(:AAPL, quote)

      price = BarCache.current_price(:AAPL)
      # Should use quote mid-point (100.65), not bar close (100.50)
      assert Decimal.equal?(price, Decimal.new("100.65"))
    end
  end

  describe "update_bar/2" do
    test "stores new bar for symbol" do
      bar = sample_bar()
      assert :ok = BarCache.update_bar(:AAPL, bar)

      assert {:ok, %{last_bar: ^bar}} = BarCache.get(:AAPL)
    end

    test "updates existing bar without affecting quote" do
      bar1 = sample_bar(close: "100.00")
      quote = sample_quote()

      :ok = BarCache.update_bar(:AAPL, bar1)
      :ok = BarCache.update_quote(:AAPL, quote)

      bar2 = sample_bar(close: "101.00")
      :ok = BarCache.update_bar(:AAPL, bar2)

      assert {:ok, %{last_bar: ^bar2, last_quote: ^quote}} = BarCache.get(:AAPL)
    end

    test "works for multiple symbols independently" do
      bar_aapl = sample_bar(close: "185.00")
      bar_tsla = sample_bar(close: "250.00")

      :ok = BarCache.update_bar(:AAPL, bar_aapl)
      :ok = BarCache.update_bar(:TSLA, bar_tsla)

      assert {:ok, %{last_bar: ^bar_aapl}} = BarCache.get(:AAPL)
      assert {:ok, %{last_bar: ^bar_tsla}} = BarCache.get(:TSLA)
    end
  end

  describe "update_quote/2" do
    test "stores new quote for symbol" do
      quote = sample_quote()
      assert :ok = BarCache.update_quote(:AAPL, quote)

      assert {:ok, %{last_quote: ^quote}} = BarCache.get(:AAPL)
    end

    test "updates existing quote without affecting bar" do
      bar = sample_bar()
      quote1 = sample_quote(bid_price: "100.00", ask_price: "100.10")

      :ok = BarCache.update_bar(:AAPL, bar)
      :ok = BarCache.update_quote(:AAPL, quote1)

      quote2 = sample_quote(bid_price: "100.20", ask_price: "100.30")
      :ok = BarCache.update_quote(:AAPL, quote2)

      assert {:ok, %{last_bar: ^bar, last_quote: ^quote2}} = BarCache.get(:AAPL)
    end
  end

  describe "all_symbols/0" do
    test "returns empty list when no symbols cached" do
      assert [] = BarCache.all_symbols()
    end

    test "returns all cached symbols" do
      :ok = BarCache.update_bar(:AAPL, sample_bar())
      :ok = BarCache.update_bar(:TSLA, sample_bar())
      :ok = BarCache.update_quote(:NVDA, sample_quote())

      symbols = BarCache.all_symbols()
      assert length(symbols) == 3
      assert :AAPL in symbols
      assert :TSLA in symbols
      assert :NVDA in symbols
    end
  end

  describe "clear/0" do
    test "removes all cached data" do
      :ok = BarCache.update_bar(:AAPL, sample_bar())
      :ok = BarCache.update_bar(:TSLA, sample_bar())

      assert length(BarCache.all_symbols()) == 2

      :ok = BarCache.clear()

      assert [] = BarCache.all_symbols()
      assert {:error, :not_found} = BarCache.get(:AAPL)
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads without blocking" do
      bar = sample_bar()
      :ok = BarCache.update_bar(:AAPL, bar)

      # Spawn multiple concurrent readers
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            BarCache.get(:AAPL)
          end)
        end

      results = Task.await_many(tasks)

      # All reads should succeed
      assert Enum.all?(results, fn result ->
               match?({:ok, %{last_bar: ^bar}}, result)
             end)
    end

    test "handles concurrent writes correctly" do
      # Spawn multiple concurrent writers
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            bar = sample_bar(close: "#{100 + i}.00")
            BarCache.update_bar(:AAPL, bar)
          end)
        end

      Task.await_many(tasks)

      # Should have exactly one entry for AAPL (last write wins)
      assert {:ok, _data} = BarCache.get(:AAPL)
    end
  end

  # Test helpers

  defp sample_bar(opts \\ []) do
    %{
      open: Decimal.new(Keyword.get(opts, :open, "185.20")),
      high: Decimal.new(Keyword.get(opts, :high, "185.60")),
      low: Decimal.new(Keyword.get(opts, :low, "184.90")),
      close: Decimal.new(Keyword.get(opts, :close, "185.45")),
      volume: Keyword.get(opts, :volume, 2_300_000),
      vwap: Decimal.new(Keyword.get(opts, :vwap, "185.32")),
      trade_count: Keyword.get(opts, :trade_count, 150),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
    }
  end

  defp sample_quote(opts \\ []) do
    %{
      bid_price: Decimal.new(Keyword.get(opts, :bid_price, "185.48")),
      bid_size: Keyword.get(opts, :bid_size, 100),
      ask_price: Decimal.new(Keyword.get(opts, :ask_price, "185.52")),
      ask_size: Keyword.get(opts, :ask_size, 200),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
    }
  end
end
