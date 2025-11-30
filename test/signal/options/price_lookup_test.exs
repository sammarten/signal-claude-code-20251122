defmodule Signal.Options.PriceLookupTest do
  use Signal.DataCase, async: true

  alias Signal.Options.PriceLookup
  alias Signal.Options.Bar

  describe "get_entry_price/3" do
    setup do
      bar_time = ~U[2024-06-15 14:30:00Z]

      {:ok, bar} =
        %Bar{}
        |> Bar.changeset(%{
          symbol: "AAPL240621C00150000",
          bar_time: bar_time,
          open: Decimal.new("5.25"),
          high: Decimal.new("5.50"),
          low: Decimal.new("5.10"),
          close: Decimal.new("5.40"),
          volume: 1000,
          trade_count: 50,
          vwap: Decimal.new("5.30")
        })
        |> Repo.insert()

      {:ok, bar: bar, bar_time: bar_time}
    end

    test "returns open price by default", %{bar_time: bar_time} do
      assert {:ok, price} =
               PriceLookup.get_entry_price("AAPL240621C00150000", bar_time)

      assert Decimal.equal?(price, Decimal.new("5.25"))
    end

    test "returns specified price field", %{bar_time: bar_time} do
      assert {:ok, price} =
               PriceLookup.get_entry_price("AAPL240621C00150000", bar_time, price_field: :high)

      assert Decimal.equal?(price, Decimal.new("5.50"))
    end

    test "returns error when no data", %{bar_time: bar_time} do
      assert {:error, :no_data} =
               PriceLookup.get_entry_price("UNKNOWN", bar_time)
    end
  end

  describe "get_exit_price/3" do
    setup do
      bar_time = ~U[2024-06-15 14:30:00Z]

      {:ok, bar} =
        %Bar{}
        |> Bar.changeset(%{
          symbol: "AAPL240621C00150000",
          bar_time: bar_time,
          open: Decimal.new("5.25"),
          high: Decimal.new("5.50"),
          low: Decimal.new("5.10"),
          close: Decimal.new("5.40"),
          volume: 1000,
          trade_count: 50,
          vwap: Decimal.new("5.30")
        })
        |> Repo.insert()

      {:ok, bar: bar, bar_time: bar_time}
    end

    test "returns close price by default", %{bar_time: bar_time} do
      assert {:ok, price} =
               PriceLookup.get_exit_price("AAPL240621C00150000", bar_time)

      assert Decimal.equal?(price, Decimal.new("5.40"))
    end

    test "returns specified price field", %{bar_time: bar_time} do
      assert {:ok, price} =
               PriceLookup.get_exit_price("AAPL240621C00150000", bar_time, price_field: :low)

      assert Decimal.equal?(price, Decimal.new("5.10"))
    end
  end

  describe "get_bar_at/3" do
    setup do
      bar_time = ~U[2024-06-15 14:30:00Z]

      {:ok, bar} =
        %Bar{}
        |> Bar.changeset(%{
          symbol: "AAPL240621C00150000",
          bar_time: bar_time,
          open: Decimal.new("5.25"),
          high: Decimal.new("5.50"),
          low: Decimal.new("5.10"),
          close: Decimal.new("5.40"),
          volume: 1000,
          trade_count: 50,
          vwap: Decimal.new("5.30")
        })
        |> Repo.insert()

      {:ok, bar: bar, bar_time: bar_time}
    end

    test "returns exact bar match", %{bar: expected_bar, bar_time: bar_time} do
      assert {:ok, bar} = PriceLookup.get_bar_at("AAPL240621C00150000", bar_time)
      assert bar.symbol == expected_bar.symbol
      assert Decimal.equal?(bar.open, expected_bar.open)
    end

    test "returns nearest bar within window", %{bar: expected_bar} do
      # Query 2 minutes after bar time
      query_time = ~U[2024-06-15 14:32:00Z]

      assert {:ok, bar} = PriceLookup.get_bar_at("AAPL240621C00150000", query_time)
      assert bar.symbol == expected_bar.symbol
    end

    test "returns error when no bar in window" do
      # Query far from any bar
      query_time = ~U[2024-06-15 10:00:00Z]

      assert {:error, :no_data} =
               PriceLookup.get_bar_at("AAPL240621C00150000", query_time)
    end
  end

  describe "get_bars_in_range/3" do
    setup do
      # Create multiple bars
      bars_data = [
        {~U[2024-06-15 14:30:00Z], "5.25"},
        {~U[2024-06-15 14:31:00Z], "5.30"},
        {~U[2024-06-15 14:32:00Z], "5.35"},
        {~U[2024-06-15 14:33:00Z], "5.40"}
      ]

      bars =
        for {bar_time, open} <- bars_data do
          {:ok, bar} =
            %Bar{}
            |> Bar.changeset(%{
              symbol: "AAPL240621C00150000",
              bar_time: bar_time,
              open: Decimal.new(open),
              high: Decimal.new("5.50"),
              low: Decimal.new("5.10"),
              close: Decimal.new("5.40"),
              volume: 1000,
              trade_count: 50,
              vwap: Decimal.new("5.30")
            })
            |> Repo.insert()

          bar
        end

      {:ok, bars: bars}
    end

    test "returns bars within range" do
      start_time = ~U[2024-06-15 14:30:00Z]
      end_time = ~U[2024-06-15 14:32:00Z]

      bars = PriceLookup.get_bars_in_range("AAPL240621C00150000", start_time, end_time)

      assert length(bars) == 3
      assert Enum.all?(bars, &(&1.symbol == "AAPL240621C00150000"))
    end

    test "returns empty list when no bars in range" do
      start_time = ~U[2024-06-15 10:00:00Z]
      end_time = ~U[2024-06-15 11:00:00Z]

      bars = PriceLookup.get_bars_in_range("AAPL240621C00150000", start_time, end_time)

      assert bars == []
    end
  end

  describe "data_available?/2" do
    setup do
      bar_time = ~U[2024-06-15 14:30:00Z]

      {:ok, _bar} =
        %Bar{}
        |> Bar.changeset(%{
          symbol: "AAPL240621C00150000",
          bar_time: bar_time,
          open: Decimal.new("5.25"),
          high: Decimal.new("5.50"),
          low: Decimal.new("5.10"),
          close: Decimal.new("5.40"),
          volume: 1000,
          trade_count: 50,
          vwap: Decimal.new("5.30")
        })
        |> Repo.insert()

      {:ok, bar_time: bar_time}
    end

    test "returns true when data exists", %{bar_time: bar_time} do
      assert PriceLookup.data_available?("AAPL240621C00150000", bar_time)
    end

    test "returns false when no data" do
      refute PriceLookup.data_available?("UNKNOWN", ~U[2024-06-15 14:30:00Z])
    end
  end

  describe "get_day_range/2" do
    setup do
      # Create multiple bars for a day with varying highs/lows
      bars_data = [
        {~U[2024-06-15 09:30:00Z], "5.50", "5.00"},
        {~U[2024-06-15 10:30:00Z], "5.75", "5.20"},
        {~U[2024-06-15 11:30:00Z], "6.00", "5.10"},
        {~U[2024-06-15 12:30:00Z], "5.60", "4.90"}
      ]

      for {bar_time, high, low} <- bars_data do
        {:ok, _bar} =
          %Bar{}
          |> Bar.changeset(%{
            symbol: "AAPL240621C00150000",
            bar_time: bar_time,
            open: Decimal.new("5.25"),
            high: Decimal.new(high),
            low: Decimal.new(low),
            close: Decimal.new("5.40"),
            volume: 1000,
            trade_count: 50,
            vwap: Decimal.new("5.30")
          })
          |> Repo.insert()
      end

      :ok
    end

    test "returns day's high and low" do
      assert {:ok, range} = PriceLookup.get_day_range("AAPL240621C00150000", ~D[2024-06-15])

      # High should be max of all highs: 6.00
      assert Decimal.equal?(range.high, Decimal.new("6.00"))
      # Low should be min of all lows: 4.90
      assert Decimal.equal?(range.low, Decimal.new("4.90"))
    end

    test "returns error for day with no data" do
      assert {:error, :no_data} =
               PriceLookup.get_day_range("AAPL240621C00150000", ~D[2024-06-20])
    end
  end
end
