defmodule Signal.Analytics.TimeAnalysisTest do
  use ExUnit.Case, async: true

  alias Signal.Analytics.TimeAnalysis

  describe "calculate/1" do
    test "returns empty stats for empty trades" do
      {:ok, analysis} = TimeAnalysis.calculate([])

      assert analysis.by_time_slot == %{}
      assert analysis.by_weekday == %{}
      assert analysis.by_month == %{}
      assert analysis.best_time_slot == nil
      assert analysis.worst_time_slot == nil
    end

    test "groups trades by time slot" do
      # Entry times at 9:30 (ET) and 10:00 (ET)
      # Note: UTC is ET+5 in winter
      trades = [
        # 9:30 ET
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-15 14:30:00Z],
          r_multiple: Decimal.new("1.0")
        },
        # 9:35 ET (same slot)
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-15 14:35:00Z],
          r_multiple: Decimal.new("1.0")
        },
        # 10:00 ET
        %{
          pnl: Decimal.new("-50"),
          entry_time: ~U[2024-01-15 15:00:00Z],
          r_multiple: Decimal.new("-0.5")
        }
      ]

      {:ok, analysis} = TimeAnalysis.calculate(trades)

      # Should have 2 time slots
      assert map_size(analysis.by_time_slot) == 2

      # 9:30-9:45 slot should have 2 trades
      slot_0930 = analysis.by_time_slot["09:30-09:45"]
      assert slot_0930.trades == 2
      assert slot_0930.winners == 2
    end

    test "groups trades by weekday" do
      # Monday through Friday trades
      trades = [
        # Monday
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-15 14:30:00Z],
          r_multiple: Decimal.new("1.0")
        },
        # Tuesday
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-16 14:30:00Z],
          r_multiple: Decimal.new("1.0")
        },
        # Wednesday
        %{
          pnl: Decimal.new("-50"),
          entry_time: ~U[2024-01-17 14:30:00Z],
          r_multiple: Decimal.new("-0.5")
        }
      ]

      {:ok, analysis} = TimeAnalysis.calculate(trades)

      assert map_size(analysis.by_weekday) == 3
      assert Map.has_key?(analysis.by_weekday, :monday)
      assert Map.has_key?(analysis.by_weekday, :tuesday)
      assert Map.has_key?(analysis.by_weekday, :wednesday)
    end

    test "groups trades by month" do
      trades = [
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-15 14:30:00Z],
          r_multiple: Decimal.new("1.0")
        },
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-20 14:30:00Z],
          r_multiple: Decimal.new("1.0")
        },
        %{
          pnl: Decimal.new("-50"),
          entry_time: ~U[2024-02-15 14:30:00Z],
          r_multiple: Decimal.new("-0.5")
        }
      ]

      {:ok, analysis} = TimeAnalysis.calculate(trades)

      assert map_size(analysis.by_month) == 2
      assert Map.has_key?(analysis.by_month, "2024-01")
      assert Map.has_key?(analysis.by_month, "2024-02")

      jan = analysis.by_month["2024-01"]
      assert jan.trades == 2
      assert jan.winners == 2
    end

    test "calculates stats correctly for each grouping" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          entry_time: ~U[2024-01-15 14:30:00Z],
          r_multiple: Decimal.new("2.0")
        },
        %{
          pnl: Decimal.new("-100"),
          entry_time: ~U[2024-01-15 14:35:00Z],
          r_multiple: Decimal.new("-1.0")
        }
      ]

      {:ok, analysis} = TimeAnalysis.calculate(trades)

      slot = analysis.by_time_slot["09:30-09:45"]
      assert slot.trades == 2
      assert slot.winners == 1
      assert slot.losers == 1
      assert Decimal.equal?(slot.win_rate, Decimal.new(50))
      assert Decimal.equal?(slot.net_pnl, Decimal.new("100"))
      # Profit factor: 200 / 100 = 2.0
      assert Decimal.equal?(slot.profit_factor, Decimal.new("2"))
    end
  end

  describe "by_time_slot/2" do
    test "groups with custom interval" do
      trades = [
        %{pnl: Decimal.new("100"), entry_time: ~U[2024-01-15 14:30:00Z]},
        %{pnl: Decimal.new("100"), entry_time: ~U[2024-01-15 14:45:00Z]},
        %{pnl: Decimal.new("100"), entry_time: ~U[2024-01-15 15:00:00Z]}
      ]

      # Default 15-minute intervals
      result = TimeAnalysis.by_time_slot(trades, 15)

      assert map_size(result) == 3
    end

    test "handles trades without entry time" do
      trades = [
        %{pnl: Decimal.new("100"), entry_time: nil},
        %{pnl: Decimal.new("100"), entry_time: ~U[2024-01-15 14:30:00Z]}
      ]

      result = TimeAnalysis.by_time_slot(trades)

      # Should only have 1 slot (the trade with valid entry_time)
      assert map_size(result) == 1
    end
  end

  describe "by_weekday/1" do
    test "handles all weekdays" do
      # Create trades for all 5 weekdays
      trades =
        Enum.map(15..19, fn day ->
          %{
            pnl: Decimal.new("100"),
            entry_time: DateTime.new!(Date.new!(2024, 1, day), ~T[14:30:00], "Etc/UTC")
          }
        end)

      result = TimeAnalysis.by_weekday(trades)

      assert map_size(result) == 5
      assert Map.has_key?(result, :monday)
      assert Map.has_key?(result, :friday)
    end
  end

  describe "by_month/1" do
    test "handles multiple years" do
      trades = [
        %{pnl: Decimal.new("100"), entry_time: ~U[2023-12-15 14:30:00Z]},
        %{pnl: Decimal.new("100"), entry_time: ~U[2024-01-15 14:30:00Z]}
      ]

      result = TimeAnalysis.by_month(trades)

      assert map_size(result) == 2
      assert Map.has_key?(result, "2023-12")
      assert Map.has_key?(result, "2024-01")
    end
  end

  describe "find_best_worst_slot/1" do
    test "returns nil for empty stats" do
      {best, worst} = TimeAnalysis.find_best_worst_slot(%{})

      assert best == nil
      assert worst == nil
    end

    test "returns nil when not enough trades" do
      slot_stats = %{
        "09:30-09:45" => %Signal.Analytics.TimeAnalysis.TimeSlotStats{
          time_slot: "09:30-09:45",
          # Less than minimum
          trades: 3,
          profit_factor: Decimal.new("2.0")
        }
      }

      {best, worst} = TimeAnalysis.find_best_worst_slot(slot_stats)

      assert best == nil
      assert worst == nil
    end

    test "finds best and worst by profit factor" do
      slot_stats = %{
        "09:30-09:45" => %Signal.Analytics.TimeAnalysis.TimeSlotStats{
          time_slot: "09:30-09:45",
          trades: 10,
          profit_factor: Decimal.new("3.0")
        },
        "10:00-10:15" => %Signal.Analytics.TimeAnalysis.TimeSlotStats{
          time_slot: "10:00-10:15",
          trades: 10,
          profit_factor: Decimal.new("1.5")
        },
        "10:30-10:45" => %Signal.Analytics.TimeAnalysis.TimeSlotStats{
          time_slot: "10:30-10:45",
          trades: 10,
          profit_factor: Decimal.new("2.0")
        }
      }

      {best, worst} = TimeAnalysis.find_best_worst_slot(slot_stats)

      assert best == "09:30-09:45"
      assert worst == "10:00-10:15"
    end
  end
end
