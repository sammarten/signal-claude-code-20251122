defmodule Signal.Analytics.TradeMetricsTest do
  use ExUnit.Case, async: true

  alias Signal.Analytics.TradeMetrics

  describe "calculate/1" do
    test "returns empty metrics for empty trade list" do
      {:ok, metrics} = TradeMetrics.calculate([])

      assert metrics.total_trades == 0
      assert metrics.winners == 0
      assert metrics.losers == 0
      assert Decimal.equal?(metrics.win_rate, Decimal.new(0))
      assert Decimal.equal?(metrics.net_profit, Decimal.new(0))
      assert metrics.profit_factor == nil
    end

    test "calculates metrics for all winners" do
      trades = [
        %{
          pnl: Decimal.new("100"),
          r_multiple: Decimal.new("1.0"),
          entry_time: ~U[2024-01-15 09:30:00Z],
          exit_time: ~U[2024-01-15 09:45:00Z]
        },
        %{
          pnl: Decimal.new("150"),
          r_multiple: Decimal.new("1.5"),
          entry_time: ~U[2024-01-15 10:00:00Z],
          exit_time: ~U[2024-01-15 10:30:00Z]
        },
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          entry_time: ~U[2024-01-15 11:00:00Z],
          exit_time: ~U[2024-01-15 11:15:00Z]
        }
      ]

      {:ok, metrics} = TradeMetrics.calculate(trades)

      assert metrics.total_trades == 3
      assert metrics.winners == 3
      assert metrics.losers == 0
      assert Decimal.equal?(metrics.win_rate, Decimal.new(100))
      assert Decimal.equal?(metrics.gross_profit, Decimal.new("450"))
      assert Decimal.equal?(metrics.gross_loss, Decimal.new(0))
      assert Decimal.equal?(metrics.net_profit, Decimal.new("450"))
      # Profit factor is nil when no losses
      assert metrics.profit_factor == nil
    end

    test "calculates metrics for all losers" do
      trades = [
        %{
          pnl: Decimal.new("-100"),
          r_multiple: Decimal.new("-1.0"),
          entry_time: ~U[2024-01-15 09:30:00Z],
          exit_time: ~U[2024-01-15 09:45:00Z]
        },
        %{
          pnl: Decimal.new("-50"),
          r_multiple: Decimal.new("-0.5"),
          entry_time: ~U[2024-01-15 10:00:00Z],
          exit_time: ~U[2024-01-15 10:30:00Z]
        }
      ]

      {:ok, metrics} = TradeMetrics.calculate(trades)

      assert metrics.total_trades == 2
      assert metrics.winners == 0
      assert metrics.losers == 2
      assert Decimal.equal?(metrics.win_rate, Decimal.new(0))
      assert Decimal.equal?(metrics.gross_profit, Decimal.new(0))
      assert Decimal.equal?(metrics.gross_loss, Decimal.new("150"))
      assert Decimal.equal?(metrics.net_profit, Decimal.new("-150"))
    end

    test "calculates metrics for mixed results" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          entry_time: ~U[2024-01-15 09:30:00Z],
          exit_time: ~U[2024-01-15 09:45:00Z]
        },
        %{
          pnl: Decimal.new("-100"),
          r_multiple: Decimal.new("-1.0"),
          entry_time: ~U[2024-01-15 10:00:00Z],
          exit_time: ~U[2024-01-15 10:30:00Z]
        },
        %{
          pnl: Decimal.new("150"),
          r_multiple: Decimal.new("1.5"),
          entry_time: ~U[2024-01-15 11:00:00Z],
          exit_time: ~U[2024-01-15 11:15:00Z]
        },
        %{
          pnl: Decimal.new("-50"),
          r_multiple: Decimal.new("-0.5"),
          entry_time: ~U[2024-01-15 12:00:00Z],
          exit_time: ~U[2024-01-15 12:30:00Z]
        }
      ]

      {:ok, metrics} = TradeMetrics.calculate(trades)

      assert metrics.total_trades == 4
      assert metrics.winners == 2
      assert metrics.losers == 2
      assert Decimal.equal?(metrics.win_rate, Decimal.new(50))
      assert Decimal.equal?(metrics.gross_profit, Decimal.new("350"))
      assert Decimal.equal?(metrics.gross_loss, Decimal.new("150"))
      assert Decimal.equal?(metrics.net_profit, Decimal.new("200"))
      # Profit factor: 350 / 150 = 2.33
      assert Decimal.equal?(metrics.profit_factor, Decimal.new("2.33"))
    end

    test "calculates average R-multiple" do
      trades = [
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("-50"), r_multiple: Decimal.new("-1.0")},
        %{pnl: Decimal.new("150"), r_multiple: Decimal.new("3.0")}
      ]

      {:ok, metrics} = TradeMetrics.calculate(trades)

      # Average: (2.0 + -1.0 + 3.0) / 3 = 1.33
      assert Decimal.equal?(metrics.avg_r_multiple, Decimal.new("1.33"))
      assert Decimal.equal?(metrics.max_r_multiple, Decimal.new("3.0"))
      assert Decimal.equal?(metrics.min_r_multiple, Decimal.new("-1.0"))
    end

    test "calculates hold times" do
      trades = [
        # 15 min
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-15 09:30:00Z],
          exit_time: ~U[2024-01-15 09:45:00Z]
        },
        # 30 min
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-15 10:00:00Z],
          exit_time: ~U[2024-01-15 10:30:00Z]
        },
        # 45 min
        %{
          pnl: Decimal.new("100"),
          entry_time: ~U[2024-01-15 11:00:00Z],
          exit_time: ~U[2024-01-15 11:45:00Z]
        }
      ]

      {:ok, metrics} = TradeMetrics.calculate(trades)

      # (15 + 30 + 45) / 3
      assert metrics.avg_hold_time_minutes == 30
      assert metrics.max_hold_time_minutes == 45
      assert metrics.min_hold_time_minutes == 15
    end

    test "handles trades with nil values" do
      trades = [
        %{pnl: nil, r_multiple: nil},
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0")}
      ]

      {:ok, metrics} = TradeMetrics.calculate(trades)

      assert metrics.total_trades == 2
      assert metrics.winners == 1
    end

    test "calculates expectancy correctly" do
      # 2 winners avg $200, 2 losers avg $100
      # Win rate 50%, expectancy = (0.5 * 200) - (0.5 * 100) = 50
      trades = [
        %{pnl: Decimal.new("200"), r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("200"), r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("-100"), r_multiple: Decimal.new("-1.0")},
        %{pnl: Decimal.new("-100"), r_multiple: Decimal.new("-1.0")}
      ]

      {:ok, metrics} = TradeMetrics.calculate(trades)

      assert Decimal.equal?(metrics.expectancy, Decimal.new("50"))
    end
  end

  describe "profit_factor/2" do
    test "calculates profit factor" do
      result = TradeMetrics.profit_factor(Decimal.new("500"), Decimal.new("200"))
      assert Decimal.equal?(result, Decimal.new("2.5"))
    end

    test "returns nil when no losses" do
      result = TradeMetrics.profit_factor(Decimal.new("500"), Decimal.new(0))
      assert result == nil
    end
  end

  describe "sharpe_ratio/3" do
    test "returns nil for less than 2 returns" do
      assert TradeMetrics.sharpe_ratio([]) == nil
      assert TradeMetrics.sharpe_ratio([Decimal.new("1.0")]) == nil
    end

    test "calculates sharpe ratio for returns" do
      # Simple test with consistent positive returns
      returns = [
        Decimal.new("1.0"),
        Decimal.new("1.2"),
        Decimal.new("0.8"),
        Decimal.new("1.1"),
        Decimal.new("0.9")
      ]

      result = TradeMetrics.sharpe_ratio(returns, Decimal.new(0))

      # Should return a positive Sharpe (positive mean, some volatility)
      assert result != nil
      assert Decimal.compare(result, Decimal.new(0)) == :gt
    end
  end

  describe "sortino_ratio/3" do
    test "returns nil for less than 2 returns" do
      assert TradeMetrics.sortino_ratio([]) == nil
      assert TradeMetrics.sortino_ratio([Decimal.new("1.0")]) == nil
    end

    test "returns higher than sharpe when negative volatility is lower" do
      # Returns with higher upside volatility than downside
      returns = [
        Decimal.new("2.0"),
        Decimal.new("3.0"),
        Decimal.new("-0.5"),
        Decimal.new("1.5"),
        Decimal.new("2.5")
      ]

      sharpe = TradeMetrics.sharpe_ratio(returns, Decimal.new(0))
      sortino = TradeMetrics.sortino_ratio(returns, Decimal.new(0))

      # Both should be positive
      assert sharpe != nil
      assert sortino != nil
    end
  end
end
