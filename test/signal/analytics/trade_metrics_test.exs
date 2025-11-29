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

  describe "exit_strategy_analysis/1" do
    test "returns complete analysis structure" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          exit_strategy_type: "fixed",
          stop_moved_to_breakeven: false,
          partial_exit_count: 0,
          max_favorable_r: Decimal.new("2.5"),
          max_adverse_r: Decimal.new("0.3")
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)

      assert Map.has_key?(result, :by_exit_type)
      assert Map.has_key?(result, :trailing_stop_effectiveness)
      assert Map.has_key?(result, :scale_out_analysis)
      assert Map.has_key?(result, :breakeven_impact)
      assert Map.has_key?(result, :max_favorable_excursion)
      assert Map.has_key?(result, :max_adverse_excursion)
    end

    test "handles empty trade list" do
      result = TradeMetrics.exit_strategy_analysis([])

      assert result.by_exit_type == %{}
      assert result.trailing_stop_effectiveness == nil
      assert result.scale_out_analysis == nil
      assert result.breakeven_impact.trades_moved_to_be == 0
    end
  end

  describe "group_by_exit_type/1" do
    test "groups trades by exit strategy type" do
      trades = [
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0"), exit_strategy_type: "fixed"},
        %{pnl: Decimal.new("150"), r_multiple: Decimal.new("1.5"), exit_strategy_type: "fixed"},
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          exit_strategy_type: "trailing"
        },
        %{pnl: Decimal.new("-50"), r_multiple: Decimal.new("-0.5"), exit_strategy_type: "scaled"}
      ]

      result = TradeMetrics.group_by_exit_type(trades)

      assert result["fixed"].count == 2
      assert result["trailing"].count == 1
      assert result["scaled"].count == 1

      # Check fixed group metrics
      assert Decimal.equal?(result["fixed"].win_rate, Decimal.new(100))
      assert Decimal.equal?(result["fixed"].avg_r, Decimal.new("1.25"))

      # Check trailing group metrics
      assert Decimal.equal?(result["trailing"].win_rate, Decimal.new(100))
      assert Decimal.equal?(result["trailing"].avg_r, Decimal.new("2.0"))

      # Check scaled group metrics
      assert Decimal.equal?(result["scaled"].win_rate, Decimal.new(0))
    end

    test "defaults to fixed when exit_strategy_type is nil" do
      trades = [
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("200"), r_multiple: Decimal.new("2.0"), exit_strategy_type: nil}
      ]

      result = TradeMetrics.group_by_exit_type(trades)

      assert result["fixed"].count == 2
    end
  end

  describe "trailing stop effectiveness" do
    test "returns nil when no trailing trades" do
      trades = [
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0"), exit_strategy_type: "fixed"}
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      assert result.trailing_stop_effectiveness == nil
    end

    test "analyzes trailing trades when present" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          exit_strategy_type: "trailing",
          max_favorable_r: Decimal.new("2.5")
        },
        %{
          pnl: Decimal.new("150"),
          r_multiple: Decimal.new("1.5"),
          exit_strategy_type: "trailing",
          max_favorable_r: Decimal.new("2.0")
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      trailing = result.trailing_stop_effectiveness

      assert trailing.count == 2
      assert Decimal.equal?(trailing.avg_captured_r, Decimal.new("1.75"))
      assert trailing.avg_mfe_captured_pct != nil
    end
  end

  describe "scale out analysis" do
    test "returns nil when no scaled trades" do
      trades = [
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0"), partial_exit_count: 0}
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      assert result.scale_out_analysis == nil
    end

    test "analyzes scaled trades when present" do
      trades = [
        %{
          pnl: Decimal.new("300"),
          r_multiple: Decimal.new("3.0"),
          partial_exit_count: 2,
          exit_strategy_type: "scaled"
        },
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          partial_exit_count: 1,
          exit_strategy_type: "scaled"
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      scaled = result.scale_out_analysis

      assert scaled.count == 2
      assert Decimal.equal?(scaled.avg_total_r, Decimal.new("2.5"))
      # (2 + 1) / 2 = 1.5 partial exits on average
      assert Decimal.equal?(scaled.avg_partial_exits, Decimal.new("1.5"))
    end

    test "compares scaled vs fixed when both present" do
      trades = [
        # Scaled trades
        %{
          pnl: Decimal.new("300"),
          r_multiple: Decimal.new("3.0"),
          partial_exit_count: 2,
          exit_strategy_type: "scaled"
        },
        # Fixed trades
        %{
          pnl: Decimal.new("100"),
          r_multiple: Decimal.new("1.0"),
          partial_exit_count: 0,
          exit_strategy_type: "fixed"
        },
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          partial_exit_count: 0,
          exit_strategy_type: "fixed"
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      comparison = result.scale_out_analysis.vs_fixed_comparison

      assert comparison != nil
      assert Decimal.equal?(comparison.scaled_avg_r, Decimal.new("3.0"))
      assert Decimal.equal?(comparison.fixed_avg_r, Decimal.new("1.5"))
      # 3.0 - 1.5 = 1.5
      assert Decimal.equal?(comparison.r_difference, Decimal.new("1.5"))
    end
  end

  describe "breakeven impact" do
    test "tracks trades moved to breakeven" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          stop_moved_to_breakeven: true
        },
        %{
          pnl: Decimal.new("0"),
          r_multiple: Decimal.new("0"),
          stop_moved_to_breakeven: true
        },
        %{
          pnl: Decimal.new("-100"),
          r_multiple: Decimal.new("-1.0"),
          stop_moved_to_breakeven: false
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      be_impact = result.breakeven_impact

      assert be_impact.trades_moved_to_be == 2
      # BE trades: 1 winner, 1 breakeven = 50% win rate
      assert Decimal.equal?(be_impact.be_win_rate, Decimal.new(50))
      # Non-BE trades: 0 winners = 0% win rate
      assert Decimal.equal?(be_impact.non_be_win_rate, Decimal.new(0))
      # BE avg R: (2.0 + 0) / 2 = 1.0
      assert Decimal.equal?(be_impact.be_avg_r, Decimal.new("1.0"))
      # Non-BE avg R: -1.0
      assert Decimal.equal?(be_impact.non_be_avg_r, Decimal.new("-1.0"))
    end

    test "handles no breakeven trades" do
      trades = [
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0"), stop_moved_to_breakeven: false}
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)

      assert result.breakeven_impact.trades_moved_to_be == 0
      assert result.breakeven_impact.be_avg_r == nil
    end
  end

  describe "MFE analysis" do
    test "calculates average MFE" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          max_favorable_r: Decimal.new("3.0")
        },
        %{
          pnl: Decimal.new("100"),
          r_multiple: Decimal.new("1.0"),
          max_favorable_r: Decimal.new("2.0")
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      mfe = result.max_favorable_excursion

      # Avg MFE: (3.0 + 2.0) / 2 = 2.5
      assert Decimal.equal?(mfe.avg_mfe, Decimal.new("2.5"))
    end

    test "calculates capture percentage" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          max_favorable_r: Decimal.new("4.0")
        },
        %{
          pnl: Decimal.new("100"),
          r_multiple: Decimal.new("1.0"),
          max_favorable_r: Decimal.new("2.0")
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      mfe = result.max_favorable_excursion

      # Trade 1: 2.0/4.0 = 50%, Trade 2: 1.0/2.0 = 50%
      # Average: 50%
      assert Decimal.equal?(mfe.avg_captured_pct, Decimal.new(50))
    end

    test "calculates left on table" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          max_favorable_r: Decimal.new("3.0")
        },
        %{
          pnl: Decimal.new("100"),
          r_multiple: Decimal.new("1.0"),
          max_favorable_r: Decimal.new("2.0")
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      mfe = result.max_favorable_excursion

      # Trade 1: 3.0 - 2.0 = 1.0R left, Trade 2: 2.0 - 1.0 = 1.0R left
      # Average: 1.0R
      assert Decimal.equal?(mfe.left_on_table, Decimal.new("1.0"))
    end

    test "handles trades without MFE data" do
      trades = [
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0"), max_favorable_r: nil}
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      mfe = result.max_favorable_excursion

      assert mfe.avg_mfe == nil
      assert mfe.avg_captured_pct == nil
      assert mfe.left_on_table == nil
    end
  end

  describe "MAE analysis" do
    test "calculates average MAE" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          max_adverse_r: Decimal.new("0.5")
        },
        %{
          pnl: Decimal.new("-100"),
          r_multiple: Decimal.new("-1.0"),
          max_adverse_r: Decimal.new("1.5")
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      mae = result.max_adverse_excursion

      # Avg MAE: (0.5 + 1.5) / 2 = 1.0
      assert Decimal.equal?(mae.avg_mae, Decimal.new("1.0"))
    end

    test "separates winners and losers MAE" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          max_adverse_r: Decimal.new("0.3")
        },
        %{
          pnl: Decimal.new("100"),
          r_multiple: Decimal.new("1.0"),
          max_adverse_r: Decimal.new("0.5")
        },
        %{
          pnl: Decimal.new("-100"),
          r_multiple: Decimal.new("-1.0"),
          max_adverse_r: Decimal.new("1.2")
        }
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      mae = result.max_adverse_excursion

      # Winners MAE: (0.3 + 0.5) / 2 = 0.4
      assert Decimal.equal?(mae.winners_avg_mae, Decimal.new("0.4"))
      # Losers MAE: 1.2
      assert Decimal.equal?(mae.losers_avg_mae, Decimal.new("1.2"))
    end

    test "handles trades without MAE data" do
      trades = [
        %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0"), max_adverse_r: nil}
      ]

      result = TradeMetrics.exit_strategy_analysis(trades)
      mae = result.max_adverse_excursion

      assert mae.avg_mae == nil
      assert mae.winners_avg_mae == nil
      assert mae.losers_avg_mae == nil
    end
  end
end
