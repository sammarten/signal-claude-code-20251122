defmodule Signal.AnalyticsTest do
  use Signal.DataCase, async: true

  alias Signal.Analytics
  alias Signal.Backtest.BacktestRun

  describe "analyze_backtest/2" do
    test "calculates comprehensive analytics from backtest data" do
      trades = [
        %{
          pnl: Decimal.new("200"),
          r_multiple: Decimal.new("2.0"),
          entry_time: ~U[2024-01-15 14:30:00Z],
          exit_time: ~U[2024-01-15 14:45:00Z],
          symbol: "AAPL",
          direction: :long,
          status: :target_hit
        },
        %{
          pnl: Decimal.new("-100"),
          r_multiple: Decimal.new("-1.0"),
          entry_time: ~U[2024-01-15 15:00:00Z],
          exit_time: ~U[2024-01-15 15:15:00Z],
          symbol: "AAPL",
          direction: :long,
          status: :stopped_out
        },
        %{
          pnl: Decimal.new("150"),
          r_multiple: Decimal.new("1.5"),
          entry_time: ~U[2024-01-16 14:30:00Z],
          exit_time: ~U[2024-01-16 14:45:00Z],
          symbol: "TSLA",
          direction: :short,
          status: :target_hit
        }
      ]

      equity_curve = [
        {~U[2024-01-15 14:30:00Z], Decimal.new("100000")},
        {~U[2024-01-15 14:45:00Z], Decimal.new("100200")},
        {~U[2024-01-15 15:15:00Z], Decimal.new("100100")},
        {~U[2024-01-16 14:45:00Z], Decimal.new("100250")}
      ]

      backtest_data = %{
        closed_trades: trades,
        equity_curve: equity_curve,
        initial_capital: Decimal.new("100000")
      }

      {:ok, analytics} = Analytics.analyze_backtest(backtest_data)

      # Verify trade metrics
      assert analytics.trade_metrics.total_trades == 3
      assert analytics.trade_metrics.winners == 2
      assert analytics.trade_metrics.losers == 1
      assert Decimal.compare(analytics.trade_metrics.win_rate, Decimal.new(0)) == :gt

      # Verify drawdown analysis
      assert analytics.drawdown != nil
      assert analytics.drawdown.max_consecutive_wins >= 0
      assert analytics.drawdown.max_consecutive_losses >= 0

      # Verify equity curve analysis
      assert analytics.equity_curve != nil
      assert Decimal.equal?(analytics.equity_curve.initial_equity, Decimal.new("100000"))

      # Verify time analysis
      assert analytics.time_analysis != nil
      assert is_map(analytics.time_analysis.by_time_slot)

      # Verify signal analysis
      assert analytics.signal_analysis != nil
      assert map_size(analytics.signal_analysis.by_symbol) == 2

      # Verify summary
      assert analytics.summary != nil
      assert Map.has_key?(analytics.summary, :total_trades)
      assert Map.has_key?(analytics.summary, :win_rate)
    end

    test "handles empty trades" do
      backtest_data = %{
        closed_trades: [],
        equity_curve: [],
        initial_capital: Decimal.new("100000")
      }

      {:ok, analytics} = Analytics.analyze_backtest(backtest_data)

      assert analytics.trade_metrics.total_trades == 0
      assert Decimal.equal?(analytics.trade_metrics.net_profit, Decimal.new(0))
    end

    test "infers initial capital from equity curve when not provided" do
      equity_curve = [
        {~U[2024-01-15 14:30:00Z], Decimal.new("50000")},
        {~U[2024-01-15 15:00:00Z], Decimal.new("51000")}
      ]

      backtest_data = %{
        closed_trades: [],
        equity_curve: equity_curve
      }

      {:ok, analytics} = Analytics.analyze_backtest(backtest_data)

      assert Decimal.equal?(analytics.equity_curve.initial_equity, Decimal.new("50000"))
    end
  end

  describe "persist_results/2" do
    test "persists analytics to database" do
      # Create a backtest run first
      {:ok, run} =
        %BacktestRun{}
        |> BacktestRun.changeset(%{
          symbols: ["AAPL"],
          start_date: ~D[2024-01-01],
          end_date: ~D[2024-01-31],
          strategies: ["break_and_retest"],
          initial_capital: Decimal.new("100000"),
          risk_per_trade: Decimal.new("0.01")
        })
        |> Repo.insert()

      # Create analytics
      backtest_data = %{
        closed_trades: [
          %{
            pnl: Decimal.new("200"),
            r_multiple: Decimal.new("2.0"),
            entry_time: ~U[2024-01-15 14:30:00Z],
            exit_time: ~U[2024-01-15 14:45:00Z],
            symbol: "AAPL",
            direction: :long,
            status: :target_hit
          }
        ],
        equity_curve: [
          {~U[2024-01-15 14:30:00Z], Decimal.new("100000")},
          {~U[2024-01-15 14:45:00Z], Decimal.new("100200")}
        ],
        initial_capital: Decimal.new("100000")
      }

      {:ok, analytics} = Analytics.analyze_backtest(backtest_data)

      # Persist
      {:ok, result} = Analytics.persist_results(run.id, analytics)

      assert result.backtest_run_id == run.id
      assert result.total_trades == 1
      assert result.winners == 1
      assert Decimal.equal?(result.net_profit, Decimal.new("200"))
    end

    test "prevents duplicate results for same run" do
      # Create a backtest run
      {:ok, run} =
        %BacktestRun{}
        |> BacktestRun.changeset(%{
          symbols: ["AAPL"],
          start_date: ~D[2024-01-01],
          end_date: ~D[2024-01-31],
          strategies: ["break_and_retest"],
          initial_capital: Decimal.new("100000"),
          risk_per_trade: Decimal.new("0.01")
        })
        |> Repo.insert()

      backtest_data = %{
        closed_trades: [],
        equity_curve: [],
        initial_capital: Decimal.new("100000")
      }

      {:ok, analytics} = Analytics.analyze_backtest(backtest_data)

      # First persist succeeds
      {:ok, _} = Analytics.persist_results(run.id, analytics)

      # Second persist fails due to unique constraint
      {:error, changeset} = Analytics.persist_results(run.id, analytics)
      assert changeset.errors[:backtest_run_id] != nil
    end
  end

  describe "load_results/1" do
    test "loads persisted results" do
      # Create a backtest run
      {:ok, run} =
        %BacktestRun{}
        |> BacktestRun.changeset(%{
          symbols: ["AAPL"],
          start_date: ~D[2024-01-01],
          end_date: ~D[2024-01-31],
          strategies: ["break_and_retest"],
          initial_capital: Decimal.new("100000"),
          risk_per_trade: Decimal.new("0.01")
        })
        |> Repo.insert()

      # Persist analytics
      backtest_data = %{
        closed_trades: [],
        equity_curve: [],
        initial_capital: Decimal.new("100000")
      }

      {:ok, analytics} = Analytics.analyze_backtest(backtest_data)
      {:ok, _} = Analytics.persist_results(run.id, analytics)

      # Load results
      {:ok, result} = Analytics.load_results(run.id)

      assert result.backtest_run_id == run.id
      assert result.total_trades == 0
    end

    test "returns error for non-existent run" do
      {:error, :not_found} = Analytics.load_results(Ecto.UUID.generate())
    end
  end

  describe "summary/1" do
    test "returns condensed summary" do
      backtest_data = %{
        closed_trades: [
          %{pnl: Decimal.new("100"), r_multiple: Decimal.new("1.0")}
        ],
        equity_curve: [],
        initial_capital: Decimal.new("100000")
      }

      {:ok, analytics} = Analytics.analyze_backtest(backtest_data)
      summary = Analytics.summary(analytics)

      assert Map.has_key?(summary, :total_trades)
      assert Map.has_key?(summary, :win_rate)
      assert Map.has_key?(summary, :profit_factor)
      assert Map.has_key?(summary, :net_profit)
      assert Map.has_key?(summary, :max_drawdown_pct)
      assert Map.has_key?(summary, :sharpe_ratio)
    end
  end

  describe "to_report/1" do
    test "generates text report" do
      backtest_data = %{
        closed_trades: [
          %{
            pnl: Decimal.new("200"),
            r_multiple: Decimal.new("2.0"),
            entry_time: ~U[2024-01-15 14:30:00Z],
            exit_time: ~U[2024-01-15 14:45:00Z]
          },
          %{
            pnl: Decimal.new("-100"),
            r_multiple: Decimal.new("-1.0"),
            entry_time: ~U[2024-01-15 15:00:00Z],
            exit_time: ~U[2024-01-15 15:15:00Z]
          }
        ],
        equity_curve: [
          {~U[2024-01-15 14:30:00Z], Decimal.new("100000")},
          {~U[2024-01-15 14:45:00Z], Decimal.new("100200")},
          {~U[2024-01-15 15:15:00Z], Decimal.new("100100")}
        ],
        initial_capital: Decimal.new("100000")
      }

      {:ok, analytics} = Analytics.analyze_backtest(backtest_data)
      report = Analytics.to_report(analytics)

      assert is_binary(report)
      assert String.contains?(report, "BACKTEST PERFORMANCE REPORT")
      assert String.contains?(report, "Total Trades:")
      assert String.contains?(report, "Winners:")
      assert String.contains?(report, "DRAWDOWN ANALYSIS")
    end
  end
end
