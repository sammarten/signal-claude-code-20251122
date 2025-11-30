defmodule Signal.Analytics.OptionsReportTest do
  use ExUnit.Case, async: true

  alias Signal.Analytics.OptionsReport

  # Helper to create a mock equity trade
  defp equity_trade(opts) do
    base_time = ~U[2024-06-15 14:30:00Z]

    %{
      instrument_type: "equity",
      symbol: Keyword.get(opts, :symbol, "AAPL"),
      direction: Keyword.get(opts, :direction, :long),
      entry_price: Keyword.get(opts, :entry_price, Decimal.new("150.00")),
      entry_time: Keyword.get(opts, :entry_time, base_time),
      exit_time: Keyword.get(opts, :exit_time, DateTime.add(base_time, 3600, :second)),
      pnl: Keyword.get(opts, :pnl, Decimal.new("100.00")),
      r_multiple: Keyword.get(opts, :r_multiple, Decimal.new("1.00"))
    }
  end

  # Helper to create a mock options trade
  defp options_trade(opts) do
    base_time = ~U[2024-06-15 14:30:00Z]

    %{
      instrument_type: "options",
      symbol: Keyword.get(opts, :symbol, "AAPL"),
      direction: Keyword.get(opts, :direction, :long),
      entry_price: Keyword.get(opts, :entry_price, Decimal.new("150.00")),
      entry_time: Keyword.get(opts, :entry_time, base_time),
      exit_time: Keyword.get(opts, :exit_time, DateTime.add(base_time, 3600, :second)),
      pnl: Keyword.get(opts, :pnl, Decimal.new("150.00")),
      r_multiple: Keyword.get(opts, :r_multiple, Decimal.new("1.50")),
      entry_premium: Keyword.get(opts, :entry_premium, Decimal.new("5.00")),
      exit_premium: Keyword.get(opts, :exit_premium, Decimal.new("7.50")),
      num_contracts: Keyword.get(opts, :num_contracts, 1),
      contract_type: Keyword.get(opts, :contract_type, "call"),
      strike: Keyword.get(opts, :strike, Decimal.new("150.00")),
      expiration_date: Keyword.get(opts, :expiration_date, ~D[2024-06-21]),
      options_exit_reason: Keyword.get(opts, :options_exit_reason, "premium_target")
    }
  end

  describe "comparison_report/2" do
    test "generates comparison report from equity and options trades" do
      equity_trades = [
        equity_trade(pnl: Decimal.new("100.00"), r_multiple: Decimal.new("1.00")),
        equity_trade(pnl: Decimal.new("50.00"), r_multiple: Decimal.new("0.50")),
        equity_trade(pnl: Decimal.new("-25.00"), r_multiple: Decimal.new("-0.25"))
      ]

      options_trades = [
        options_trade(pnl: Decimal.new("150.00"), r_multiple: Decimal.new("1.50")),
        options_trade(pnl: Decimal.new("75.00"), r_multiple: Decimal.new("0.75")),
        options_trade(pnl: Decimal.new("-50.00"), r_multiple: Decimal.new("-0.50"))
      ]

      {:ok, report} = OptionsReport.comparison_report(equity_trades, options_trades)

      assert Map.has_key?(report, :equity)
      assert Map.has_key?(report, :options)
      assert Map.has_key?(report, :comparison)
      assert Map.has_key?(report, :recommendation)
    end

    test "includes equity metrics summary" do
      equity_trades = [
        equity_trade(pnl: Decimal.new("100.00")),
        equity_trade(pnl: Decimal.new("50.00"))
      ]

      {:ok, report} = OptionsReport.comparison_report(equity_trades, [])

      assert report.equity.total_trades == 2
      assert report.equity.net_profit != nil
    end

    test "includes options metrics summary" do
      options_trades = [
        options_trade(
          entry_premium: Decimal.new("5.00"),
          exit_premium: Decimal.new("10.00"),
          num_contracts: 2
        )
      ]

      {:ok, report} = OptionsReport.comparison_report([], options_trades)

      assert report.options.total_contracts == 2
      assert report.options.avg_entry_premium != nil
    end

    test "comparison shows return advantage" do
      equity_trades = [
        equity_trade(pnl: Decimal.new("100.00"))
      ]

      options_trades = [
        options_trade(pnl: Decimal.new("200.00"))
      ]

      {:ok, report} = OptionsReport.comparison_report(equity_trades, options_trades)

      assert report.comparison.return_advantage =~ "Options"
    end

    test "comparison shows equity advantage when equity performs better" do
      equity_trades = [
        equity_trade(pnl: Decimal.new("200.00"))
      ]

      options_trades = [
        options_trade(pnl: Decimal.new("100.00"))
      ]

      {:ok, report} = OptionsReport.comparison_report(equity_trades, options_trades)

      assert report.comparison.return_advantage =~ "Equity"
    end
  end

  describe "configuration_report/1" do
    test "generates configuration breakdown report" do
      base_time = ~U[2024-06-15 14:30:00Z]

      options_trades = [
        # 0DTE call ATM
        options_trade(
          entry_time: base_time,
          expiration_date: ~D[2024-06-15],
          contract_type: "call",
          strike: Decimal.new("150.00"),
          entry_price: Decimal.new("150.00"),
          options_exit_reason: "premium_target",
          pnl: Decimal.new("100.00"),
          r_multiple: Decimal.new("1.00")
        ),
        # Weekly put OTM
        options_trade(
          entry_time: base_time,
          expiration_date: ~D[2024-06-21],
          contract_type: "put",
          strike: Decimal.new("145.00"),
          entry_price: Decimal.new("150.00"),
          options_exit_reason: "expiration",
          pnl: Decimal.new("-50.00"),
          r_multiple: Decimal.new("-0.50")
        ),
        # Weekly call ATM
        options_trade(
          entry_time: base_time,
          expiration_date: ~D[2024-06-21],
          contract_type: "call",
          strike: Decimal.new("150.00"),
          entry_price: Decimal.new("150.00"),
          options_exit_reason: "premium_target",
          pnl: Decimal.new("75.00"),
          r_multiple: Decimal.new("0.75")
        )
      ]

      {:ok, report} = OptionsReport.configuration_report(options_trades)

      assert Map.has_key?(report, :by_expiration_type)
      assert Map.has_key?(report, :by_strike_distance)
      assert Map.has_key?(report, :by_contract_type)
      assert Map.has_key?(report, :by_exit_reason)
      assert Map.has_key?(report, :best_configuration)
      assert Map.has_key?(report, :worst_configuration)
    end

    test "expiration type breakdown shows 0dte and weekly" do
      base_time = ~U[2024-06-15 14:30:00Z]

      options_trades = [
        options_trade(entry_time: base_time, expiration_date: ~D[2024-06-15]),
        options_trade(entry_time: base_time, expiration_date: ~D[2024-06-21])
      ]

      {:ok, report} = OptionsReport.configuration_report(options_trades)

      assert Map.has_key?(report.by_expiration_type, "0dte")
      assert Map.has_key?(report.by_expiration_type, "weekly")
    end

    test "contract type breakdown shows calls and puts" do
      options_trades = [
        options_trade(contract_type: "call"),
        options_trade(contract_type: "put")
      ]

      {:ok, report} = OptionsReport.configuration_report(options_trades)

      assert Map.has_key?(report.by_contract_type, "call")
      assert Map.has_key?(report.by_contract_type, "put")
    end
  end

  describe "to_text/1" do
    test "generates readable text report" do
      equity_trades = [
        equity_trade(pnl: Decimal.new("100.00"), r_multiple: Decimal.new("1.00"))
      ]

      options_trades = [
        options_trade(pnl: Decimal.new("150.00"), r_multiple: Decimal.new("1.50"))
      ]

      {:ok, report} = OptionsReport.comparison_report(equity_trades, options_trades)

      text = OptionsReport.to_text(report)

      assert text =~ "OPTIONS VS EQUITY COMPARISON REPORT"
      assert text =~ "SUMMARY METRICS"
      assert text =~ "COMPARISON"
      assert text =~ "RECOMMENDATION"
    end
  end

  describe "configuration_to_text/1" do
    test "generates readable configuration breakdown" do
      options_trades = [
        options_trade(
          contract_type: "call",
          options_exit_reason: "premium_target",
          pnl: Decimal.new("100.00")
        )
      ]

      {:ok, report} = OptionsReport.configuration_report(options_trades)

      text = OptionsReport.configuration_to_text(report)

      assert text =~ "OPTIONS CONFIGURATION BREAKDOWN"
      assert text =~ "BY EXPIRATION TYPE"
      assert text =~ "BY STRIKE DISTANCE"
      assert text =~ "BY CONTRACT TYPE"
    end
  end

  describe "recommendation generation" do
    test "strong recommendation when options outperform on all metrics" do
      # Equity: 2 wins, 2 losses -> 50% win rate
      equity_trades = [
        equity_trade(pnl: Decimal.new("50.00"), r_multiple: Decimal.new("0.50")),
        equity_trade(pnl: Decimal.new("30.00"), r_multiple: Decimal.new("0.30")),
        equity_trade(pnl: Decimal.new("-25.00"), r_multiple: Decimal.new("-0.25")),
        equity_trade(pnl: Decimal.new("-20.00"), r_multiple: Decimal.new("-0.20"))
      ]

      # Options: 3 wins, 1 loss -> 75% win rate, better profit factor, positive net
      options_trades = [
        options_trade(pnl: Decimal.new("150.00"), r_multiple: Decimal.new("1.50")),
        options_trade(pnl: Decimal.new("100.00"), r_multiple: Decimal.new("1.00")),
        options_trade(pnl: Decimal.new("80.00"), r_multiple: Decimal.new("0.80")),
        options_trade(pnl: Decimal.new("-30.00"), r_multiple: Decimal.new("-0.30"))
      ]

      {:ok, report} = OptionsReport.comparison_report(equity_trades, options_trades)

      assert report.recommendation =~ "STRONG"
    end

    test "caution recommendation when equity outperforms" do
      equity_trades = [
        equity_trade(pnl: Decimal.new("200.00"), r_multiple: Decimal.new("2.00")),
        equity_trade(pnl: Decimal.new("150.00"), r_multiple: Decimal.new("1.50"))
      ]

      options_trades = [
        options_trade(pnl: Decimal.new("-50.00"), r_multiple: Decimal.new("-0.50")),
        options_trade(pnl: Decimal.new("-25.00"), r_multiple: Decimal.new("-0.25"))
      ]

      {:ok, report} = OptionsReport.comparison_report(equity_trades, options_trades)

      assert report.recommendation =~ "CAUTION"
    end
  end

  describe "edge cases" do
    test "handles empty trade lists" do
      {:ok, report} = OptionsReport.comparison_report([], [])

      assert report.equity.total_trades == 0
      assert report.options.total_trades == 0
    end

    test "handles options trades without premium data" do
      trades = [
        %{
          instrument_type: "options",
          pnl: Decimal.new("100.00"),
          r_multiple: Decimal.new("1.00"),
          contract_type: "call",
          entry_time: ~U[2024-06-15 14:30:00Z],
          exit_time: ~U[2024-06-15 15:30:00Z]
        }
      ]

      {:ok, report} = OptionsReport.configuration_report(trades)

      # Should still work without premium data
      assert Map.has_key?(report, :by_contract_type)
    end
  end
end
