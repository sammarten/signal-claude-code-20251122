defmodule Signal.Analytics.EquityCurveTest do
  use ExUnit.Case, async: true

  alias Signal.Analytics.EquityCurve

  describe "analyze/3" do
    test "returns empty analysis for empty curve" do
      {:ok, analysis} = EquityCurve.analyze([], Decimal.new("100000"))

      assert Decimal.equal?(analysis.initial_equity, Decimal.new("100000"))
      assert Decimal.equal?(analysis.final_equity, Decimal.new("100000"))
      assert Decimal.equal?(analysis.total_return_pct, Decimal.new(0))
      assert analysis.sharpe_ratio == nil
    end

    test "calculates total return correctly" do
      equity_curve = [
        {~U[2024-01-01 09:30:00Z], Decimal.new("100000")},
        {~U[2024-01-15 10:00:00Z], Decimal.new("110000")},
        {~U[2024-01-31 15:00:00Z], Decimal.new("120000")}
      ]

      {:ok, analysis} = EquityCurve.analyze(equity_curve, Decimal.new("100000"))

      assert Decimal.equal?(analysis.total_return_pct, Decimal.new("20"))
      assert Decimal.equal?(analysis.total_return_dollars, Decimal.new("20000"))
      assert Decimal.equal?(analysis.final_equity, Decimal.new("120000"))
    end

    test "tracks peak and trough" do
      equity_curve = [
        {~U[2024-01-01 09:30:00Z], Decimal.new("100000")},
        # Peak
        {~U[2024-01-15 10:00:00Z], Decimal.new("120000")},
        # Trough
        {~U[2024-01-20 10:00:00Z], Decimal.new("95000")},
        {~U[2024-01-31 15:00:00Z], Decimal.new("110000")}
      ]

      {:ok, analysis} = EquityCurve.analyze(equity_curve, Decimal.new("100000"))

      assert Decimal.equal?(analysis.peak_equity, Decimal.new("120000"))
      assert Decimal.equal?(analysis.trough_equity, Decimal.new("95000"))
    end

    test "builds data points with drawdown" do
      equity_curve = [
        {~U[2024-01-01 09:30:00Z], Decimal.new("100000")},
        {~U[2024-01-02 10:00:00Z], Decimal.new("110000")},
        {~U[2024-01-03 10:00:00Z], Decimal.new("99000")}
      ]

      {:ok, analysis} = EquityCurve.analyze(equity_curve, Decimal.new("100000"))

      assert length(analysis.data_points) == 3

      # First point should have 0% drawdown (no prior peak)
      first_point = Enum.at(analysis.data_points, 0)
      assert Decimal.equal?(first_point.drawdown_pct, Decimal.new(0))

      # Last point should have drawdown from peak of 110000
      last_point = Enum.at(analysis.data_points, 2)
      assert Decimal.compare(last_point.drawdown_pct, Decimal.new(0)) == :gt
    end
  end

  describe "calculate_returns/1" do
    test "returns empty for empty or single-point curve" do
      assert EquityCurve.calculate_returns([]) == []

      assert EquityCurve.calculate_returns([{~U[2024-01-01 09:30:00Z], Decimal.new("100000")}]) ==
               []
    end

    test "calculates period returns" do
      equity_curve = [
        {~U[2024-01-01 09:30:00Z], Decimal.new("100000")},
        # +5%
        {~U[2024-01-02 09:30:00Z], Decimal.new("105000")},
        # -5%
        {~U[2024-01-03 09:30:00Z], Decimal.new("99750")}
      ]

      returns = EquityCurve.calculate_returns(equity_curve)

      assert length(returns) == 2
      assert Decimal.equal?(Enum.at(returns, 0), Decimal.new("5"))
      assert Decimal.equal?(Enum.at(returns, 1), Decimal.new("-5"))
    end
  end

  describe "sharpe_ratio/2" do
    test "returns nil for less than 2 returns" do
      assert EquityCurve.sharpe_ratio([]) == nil
      assert EquityCurve.sharpe_ratio([Decimal.new("1.0")]) == nil
    end

    test "calculates sharpe for positive returns" do
      returns = [
        Decimal.new("1.0"),
        Decimal.new("0.5"),
        Decimal.new("0.8"),
        Decimal.new("1.2"),
        Decimal.new("0.7")
      ]

      result = EquityCurve.sharpe_ratio(returns)

      assert result != nil
      # Positive mean returns should give positive Sharpe
      assert Decimal.compare(result, Decimal.new(0)) == :gt
    end

    test "returns nil when standard deviation is zero" do
      # All same returns = zero std dev
      returns = [
        Decimal.new("1.0"),
        Decimal.new("1.0"),
        Decimal.new("1.0")
      ]

      result = EquityCurve.sharpe_ratio(returns)

      assert result == nil
    end
  end

  describe "sortino_ratio/2" do
    test "returns nil for less than 2 returns" do
      assert EquityCurve.sortino_ratio([]) == nil
      assert EquityCurve.sortino_ratio([Decimal.new("1.0")]) == nil
    end

    test "returns nil when no negative returns (downside deviation zero)" do
      returns = [
        Decimal.new("1.0"),
        Decimal.new("2.0"),
        Decimal.new("3.0")
      ]

      result = EquityCurve.sortino_ratio(returns)

      # Zero downside deviation should return nil
      assert result == nil
    end

    test "calculates sortino with mixed returns" do
      returns = [
        Decimal.new("2.0"),
        Decimal.new("-1.0"),
        Decimal.new("1.5"),
        Decimal.new("-0.5"),
        Decimal.new("1.0")
      ]

      result = EquityCurve.sortino_ratio(returns)

      assert result != nil
    end
  end

  describe "calmar_ratio/2" do
    test "returns nil when max drawdown is zero" do
      result = EquityCurve.calmar_ratio(Decimal.new("50"), Decimal.new(0))
      assert result == nil
    end

    test "calculates calmar ratio" do
      # 50% annualized return, 10% max drawdown = 5.0 Calmar
      result = EquityCurve.calmar_ratio(Decimal.new("50"), Decimal.new("10"))
      assert Decimal.equal?(result, Decimal.new("5"))
    end
  end

  describe "rolling_metrics/2" do
    test "returns empty for short curves" do
      equity_curve = [
        {~U[2024-01-01 09:30:00Z], Decimal.new("100000")},
        {~U[2024-01-02 09:30:00Z], Decimal.new("101000")}
      ]

      result = EquityCurve.rolling_metrics(equity_curve, 5)

      assert result == []
    end

    test "calculates rolling metrics" do
      equity_curve =
        Enum.map(1..10, fn day ->
          time =
            DateTime.new!(~D[2024-01-01], ~T[09:30:00], "Etc/UTC")
            |> DateTime.add(day * 24 * 60 * 60)

          equity = Decimal.add(Decimal.new("100000"), Decimal.new(day * 1000))
          {time, equity}
        end)

      result = EquityCurve.rolling_metrics(equity_curve, 5)

      # Should have (10 - 5 + 1) = 6 windows? No, chunk_every with discard
      # With 10 points and window 5, we get 6 chunks
      assert length(result) == 6

      # Each result should have timestamp and metrics
      {_time, metrics} = hd(result)
      assert Map.has_key?(metrics, :sharpe)
      assert Map.has_key?(metrics, :volatility)
      assert Map.has_key?(metrics, :return)
    end
  end

  describe "to_chart_data/1" do
    test "formats data for charting" do
      equity_curve = [
        {~U[2024-01-01 09:30:00Z], Decimal.new("100000")},
        {~U[2024-01-02 09:30:00Z], Decimal.new("105000")}
      ]

      {:ok, analysis} = EquityCurve.analyze(equity_curve, Decimal.new("100000"))

      chart_data = EquityCurve.to_chart_data(analysis)

      assert length(chart_data) == 2
      first = hd(chart_data)
      assert is_binary(first.timestamp)
      assert is_float(first.equity)
      assert is_float(first.drawdown_pct)
    end
  end
end
