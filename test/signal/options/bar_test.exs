defmodule Signal.Options.BarTest do
  use ExUnit.Case, async: true

  alias Signal.Options.Bar

  describe "changeset/2" do
    test "valid changeset with all fields" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        bar_time: ~U[2024-11-15 14:30:00.000000Z],
        open: Decimal.new("5.20"),
        high: Decimal.new("5.60"),
        low: Decimal.new("4.90"),
        close: Decimal.new("5.45"),
        volume: 2300,
        trade_count: 50
      }

      changeset = Bar.changeset(%Bar{}, attrs)
      assert changeset.valid?
    end

    test "valid changeset with only required fields" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        bar_time: ~U[2024-11-15 14:30:00.000000Z]
      }

      changeset = Bar.changeset(%Bar{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Bar.changeset(%Bar{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset).symbol
      assert "can't be blank" in errors_on(changeset).bar_time
    end

    test "invalid with high < open" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        bar_time: ~U[2024-11-15 14:30:00.000000Z],
        open: Decimal.new("5.50"),
        high: Decimal.new("5.00"),
        low: Decimal.new("4.90"),
        close: Decimal.new("5.20")
      }

      changeset = Bar.changeset(%Bar{}, attrs)
      refute changeset.valid?
      assert "must be >= open and close" in errors_on(changeset).high
    end

    test "invalid with low > open" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        bar_time: ~U[2024-11-15 14:30:00.000000Z],
        open: Decimal.new("5.00"),
        high: Decimal.new("5.50"),
        low: Decimal.new("5.20"),
        close: Decimal.new("5.10")
      }

      changeset = Bar.changeset(%Bar{}, attrs)
      refute changeset.valid?
      assert "must be <= open and close" in errors_on(changeset).low
    end

    test "invalid negative volume" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        bar_time: ~U[2024-11-15 14:30:00.000000Z],
        volume: -100
      }

      changeset = Bar.changeset(%Bar{}, attrs)
      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).volume
    end

    test "skips OHLC validation if any price is nil" do
      attrs = %{
        symbol: "AAPL251017C00150000",
        bar_time: ~U[2024-11-15 14:30:00.000000Z],
        open: Decimal.new("5.00"),
        high: Decimal.new("5.50")
        # low and close are nil
      }

      changeset = Bar.changeset(%Bar{}, attrs)
      assert changeset.valid?
    end
  end

  describe "from_alpaca/2" do
    test "converts Alpaca API response to Bar struct" do
      alpaca_bar = %{
        timestamp: ~U[2024-11-15 14:30:00Z],
        open: Decimal.new("5.20"),
        high: Decimal.new("5.60"),
        low: Decimal.new("4.90"),
        close: Decimal.new("5.45"),
        volume: 2300,
        vwap: Decimal.new("5.35"),
        trade_count: 50
      }

      bar = Bar.from_alpaca("AAPL251017C00150000", alpaca_bar)

      assert bar.symbol == "AAPL251017C00150000"
      assert bar.bar_time.microsecond == {0, 6}
      assert Decimal.equal?(bar.open, Decimal.new("5.20"))
      assert Decimal.equal?(bar.high, Decimal.new("5.60"))
      assert Decimal.equal?(bar.low, Decimal.new("4.90"))
      assert Decimal.equal?(bar.close, Decimal.new("5.45"))
      assert bar.volume == 2300
      assert Decimal.equal?(bar.vwap, Decimal.new("5.35"))
      assert bar.trade_count == 50
    end

    test "handles missing optional fields" do
      alpaca_bar = %{
        timestamp: ~U[2024-11-15 14:30:00Z],
        open: Decimal.new("5.20"),
        high: Decimal.new("5.60"),
        low: Decimal.new("4.90"),
        close: Decimal.new("5.45"),
        volume: 2300
      }

      bar = Bar.from_alpaca("AAPL251017C00150000", alpaca_bar)

      assert bar.vwap == nil
      assert bar.trade_count == nil
    end
  end

  describe "data_start_date/0" do
    test "returns February 1, 2024" do
      assert Bar.data_start_date() == ~D[2024-02-01]
    end
  end

  describe "data_available?/1" do
    test "returns true for dates on or after February 2024" do
      assert Bar.data_available?(~D[2024-02-01])
      assert Bar.data_available?(~D[2024-06-15])
      assert Bar.data_available?(~D[2025-01-01])
    end

    test "returns false for dates before February 2024" do
      refute Bar.data_available?(~D[2024-01-31])
      refute Bar.data_available?(~D[2023-12-01])
      refute Bar.data_available?(~D[2020-01-01])
    end
  end

  describe "data_available_at?/1" do
    test "returns true for datetimes on or after February 2024" do
      assert Bar.data_available_at?(~U[2024-02-01 09:30:00Z])
      assert Bar.data_available_at?(~U[2024-06-15 14:30:00Z])
    end

    test "returns false for datetimes before February 2024" do
      refute Bar.data_available_at?(~U[2024-01-31 23:59:59Z])
      refute Bar.data_available_at?(~U[2023-06-15 14:30:00Z])
    end
  end

  describe "contract_value/1" do
    test "calculates contract value from premium" do
      result = Bar.contract_value(Decimal.new("5.25"))
      assert Decimal.equal?(result, Decimal.new("525"))
    end

    test "handles decimal precision" do
      result = Bar.contract_value(Decimal.new("0.15"))
      assert Decimal.equal?(result, Decimal.new("15"))
    end
  end

  describe "to_map/1" do
    test "converts bar to map without meta field" do
      bar = %Bar{
        symbol: "AAPL251017C00150000",
        bar_time: ~U[2024-11-15 14:30:00.000000Z],
        open: Decimal.new("5.20"),
        close: Decimal.new("5.45")
      }

      result = Bar.to_map(bar)

      assert result.symbol == "AAPL251017C00150000"
      assert result.bar_time == ~U[2024-11-15 14:30:00.000000Z]
      refute Map.has_key?(result, :__meta__)
    end
  end

  # Helper to extract error messages from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
