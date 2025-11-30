defmodule Signal.Analytics.OptionsMetricsTest do
  use ExUnit.Case, async: true

  alias Signal.Analytics.OptionsMetrics

  # Helper to create a mock options trade
  defp options_trade(opts \\ []) do
    base_time = ~U[2024-06-15 14:30:00Z]

    %{
      instrument_type: "options",
      symbol: Keyword.get(opts, :symbol, "AAPL"),
      direction: Keyword.get(opts, :direction, :long),
      entry_price: Keyword.get(opts, :entry_price, Decimal.new("150.00")),
      entry_time: Keyword.get(opts, :entry_time, base_time),
      exit_time: Keyword.get(opts, :exit_time, DateTime.add(base_time, 3600, :second)),
      pnl: Keyword.get(opts, :pnl, Decimal.new("100.00")),
      r_multiple: Keyword.get(opts, :r_multiple, Decimal.new("1.00")),
      entry_premium: Keyword.get(opts, :entry_premium, Decimal.new("5.00")),
      exit_premium: Keyword.get(opts, :exit_premium, Decimal.new("7.00")),
      num_contracts: Keyword.get(opts, :num_contracts, 1),
      contract_type: Keyword.get(opts, :contract_type, "call"),
      strike: Keyword.get(opts, :strike, Decimal.new("150.00")),
      expiration_date: Keyword.get(opts, :expiration_date, ~D[2024-06-21]),
      options_exit_reason: Keyword.get(opts, :options_exit_reason, "premium_target")
    }
  end

  describe "calculate/1" do
    test "returns empty metrics for empty list" do
      {:ok, metrics} = OptionsMetrics.calculate([])

      assert metrics.total_contracts == 0
      assert metrics.avg_entry_premium == nil
      assert metrics.by_exit_reason == %{}
    end

    test "filters to only options trades" do
      trades = [
        options_trade(),
        %{instrument_type: "equity", pnl: Decimal.new("50.00")}
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      assert metrics.base_metrics.total_trades == 1
    end

    test "calculates basic metrics from options trades" do
      trades = [
        options_trade(pnl: Decimal.new("100.00"), r_multiple: Decimal.new("1.00")),
        options_trade(pnl: Decimal.new("200.00"), r_multiple: Decimal.new("2.00")),
        options_trade(pnl: Decimal.new("-50.00"), r_multiple: Decimal.new("-0.50"))
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      assert metrics.base_metrics.total_trades == 3
      assert metrics.base_metrics.winners == 2
      assert metrics.base_metrics.losers == 1
    end

    test "calculates premium statistics" do
      trades = [
        options_trade(entry_premium: Decimal.new("5.00"), exit_premium: Decimal.new("7.50")),
        options_trade(entry_premium: Decimal.new("4.00"), exit_premium: Decimal.new("6.00"))
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      assert Decimal.equal?(metrics.avg_entry_premium, Decimal.new("4.5"))
      assert Decimal.equal?(metrics.avg_exit_premium, Decimal.new("6.75"))
      assert Decimal.equal?(metrics.avg_premium_change, Decimal.new("2.25"))
    end

    test "calculates premium capture multiple" do
      trades = [
        options_trade(entry_premium: Decimal.new("5.00"), exit_premium: Decimal.new("10.00"))
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      # 10 / 5 = 2.0
      assert Decimal.equal?(metrics.avg_premium_capture_multiple, Decimal.new("2.0"))
    end

    test "calculates contract statistics" do
      trades = [
        options_trade(num_contracts: 2),
        options_trade(num_contracts: 3),
        options_trade(num_contracts: 5)
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      assert metrics.total_contracts == 10
      assert Decimal.equal?(metrics.avg_contracts_per_trade, Decimal.new("3.33"))
    end
  end

  describe "by_exit_reason breakdown" do
    test "groups trades by exit reason" do
      trades = [
        options_trade(
          options_exit_reason: "premium_target",
          pnl: Decimal.new("100.00"),
          r_multiple: Decimal.new("1.00")
        ),
        options_trade(
          options_exit_reason: "premium_target",
          pnl: Decimal.new("150.00"),
          r_multiple: Decimal.new("1.50")
        ),
        options_trade(
          options_exit_reason: "expiration",
          pnl: Decimal.new("-50.00"),
          r_multiple: Decimal.new("-0.50")
        ),
        options_trade(
          options_exit_reason: "underlying_stop",
          pnl: Decimal.new("-100.00"),
          r_multiple: Decimal.new("-1.00")
        )
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      assert Map.has_key?(metrics.by_exit_reason, "premium_target")
      assert Map.has_key?(metrics.by_exit_reason, "expiration")
      assert Map.has_key?(metrics.by_exit_reason, "underlying_stop")

      premium_target = metrics.by_exit_reason["premium_target"]
      assert premium_target.count == 2
      assert Decimal.equal?(premium_target.win_rate, Decimal.new("100.0"))
    end
  end

  describe "by_contract_type breakdown" do
    test "groups trades by call and put" do
      trades = [
        options_trade(
          contract_type: "call",
          pnl: Decimal.new("100.00"),
          r_multiple: Decimal.new("1.00")
        ),
        options_trade(
          contract_type: "call",
          pnl: Decimal.new("-50.00"),
          r_multiple: Decimal.new("-0.50")
        ),
        options_trade(
          contract_type: "put",
          pnl: Decimal.new("75.00"),
          r_multiple: Decimal.new("0.75")
        )
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      assert Map.has_key?(metrics.by_contract_type, "call")
      assert Map.has_key?(metrics.by_contract_type, "put")

      calls = metrics.by_contract_type["call"]
      assert calls.count == 2
      assert Decimal.equal?(calls.win_rate, Decimal.new("50.0"))

      puts = metrics.by_contract_type["put"]
      assert puts.count == 1
      assert Decimal.equal?(puts.win_rate, Decimal.new("100.0"))
    end
  end

  describe "by_expiration_type breakdown" do
    test "categorizes by DTE" do
      base_time = ~U[2024-06-15 14:30:00Z]

      trades = [
        # 0DTE
        options_trade(
          entry_time: base_time,
          expiration_date: ~D[2024-06-15],
          pnl: Decimal.new("50.00")
        ),
        # Weekly (6 days)
        options_trade(
          entry_time: base_time,
          expiration_date: ~D[2024-06-21],
          pnl: Decimal.new("100.00")
        ),
        # Monthly (20 days)
        options_trade(
          entry_time: base_time,
          expiration_date: ~D[2024-07-05],
          pnl: Decimal.new("150.00")
        )
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      assert Map.has_key?(metrics.by_expiration_type, "0dte")
      assert Map.has_key?(metrics.by_expiration_type, "weekly")
      assert Map.has_key?(metrics.by_expiration_type, "monthly")

      assert metrics.by_expiration_type["0dte"].count == 1
      assert metrics.by_expiration_type["weekly"].count == 1
      assert metrics.by_expiration_type["monthly"].count == 1
    end
  end

  describe "by_strike_distance breakdown" do
    test "categorizes ATM vs OTM strikes" do
      trades = [
        # ATM (strike = entry price)
        options_trade(
          entry_price: Decimal.new("150.00"),
          strike: Decimal.new("150.00"),
          contract_type: "call",
          pnl: Decimal.new("100.00")
        ),
        # 1 OTM call (strike ~3% above entry)
        options_trade(
          entry_price: Decimal.new("150.00"),
          strike: Decimal.new("154.00"),
          contract_type: "call",
          pnl: Decimal.new("75.00")
        ),
        # 2 OTM put (strike ~4% below entry)
        options_trade(
          entry_price: Decimal.new("150.00"),
          strike: Decimal.new("144.00"),
          contract_type: "put",
          pnl: Decimal.new("50.00")
        )
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      assert Map.has_key?(metrics.by_strike_distance, "atm")
      assert Map.has_key?(metrics.by_strike_distance, "1_otm")
      assert Map.has_key?(metrics.by_strike_distance, "2_otm")
    end
  end

  describe "avg_dte_at_entry" do
    test "calculates average DTE" do
      base_time = ~U[2024-06-15 14:30:00Z]

      trades = [
        options_trade(entry_time: base_time, expiration_date: ~D[2024-06-21]),
        options_trade(entry_time: base_time, expiration_date: ~D[2024-06-22]),
        options_trade(entry_time: base_time, expiration_date: ~D[2024-06-20])
      ]

      {:ok, metrics} = OptionsMetrics.calculate(trades)

      # (6 + 7 + 5) / 3 = 6
      assert metrics.avg_dte_at_entry == 6
    end
  end

  describe "metrics_for_exit_reason/2" do
    test "returns metrics for specific exit reason" do
      trades = [
        options_trade(
          options_exit_reason: "premium_target",
          pnl: Decimal.new("100.00"),
          num_contracts: 2
        ),
        options_trade(
          options_exit_reason: "premium_target",
          pnl: Decimal.new("150.00"),
          num_contracts: 3
        ),
        options_trade(options_exit_reason: "expiration", pnl: Decimal.new("-50.00"))
      ]

      metrics = OptionsMetrics.metrics_for_exit_reason(trades, "premium_target")

      assert metrics.count == 2
      assert Decimal.equal?(metrics.total_pnl, Decimal.new("250.00"))
      assert metrics.total_contracts == 5
    end
  end

  describe "metrics_for_contract_type/2" do
    test "returns metrics for specific contract type" do
      trades = [
        options_trade(contract_type: "call", pnl: Decimal.new("100.00")),
        options_trade(contract_type: "call", pnl: Decimal.new("-25.00")),
        options_trade(contract_type: "put", pnl: Decimal.new("50.00"))
      ]

      call_metrics = OptionsMetrics.metrics_for_contract_type(trades, "call")
      put_metrics = OptionsMetrics.metrics_for_contract_type(trades, "put")

      assert call_metrics.count == 2
      assert put_metrics.count == 1
    end
  end
end
