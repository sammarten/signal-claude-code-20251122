defmodule Signal.Analytics.DrawdownTest do
  use ExUnit.Case, async: true

  alias Signal.Analytics.Drawdown

  describe "calculate/3" do
    test "returns zero drawdown for empty equity curve" do
      {:ok, analysis} = Drawdown.calculate([], [], Decimal.new("100000"))

      assert Decimal.equal?(analysis.max_drawdown_pct, Decimal.new(0))
      assert Decimal.equal?(analysis.max_drawdown_dollars, Decimal.new(0))
      assert analysis.max_drawdown_start == nil
      assert analysis.max_drawdown_end == nil
    end

    test "returns zero drawdown for monotonically increasing equity" do
      equity_curve = [
        {~U[2024-01-15 09:30:00Z], Decimal.new("100000")},
        {~U[2024-01-15 10:00:00Z], Decimal.new("101000")},
        {~U[2024-01-15 10:30:00Z], Decimal.new("102000")},
        {~U[2024-01-15 11:00:00Z], Decimal.new("103000")}
      ]

      {:ok, analysis} = Drawdown.calculate(equity_curve, [], Decimal.new("100000"))

      assert Decimal.equal?(analysis.max_drawdown_pct, Decimal.new(0))
      assert Decimal.equal?(analysis.max_drawdown_dollars, Decimal.new(0))
    end

    test "calculates max drawdown correctly" do
      equity_curve = [
        {~U[2024-01-15 09:30:00Z], Decimal.new("100000")},
        # Peak
        {~U[2024-01-15 10:00:00Z], Decimal.new("110000")},
        # Trough (10% DD)
        {~U[2024-01-15 10:30:00Z], Decimal.new("99000")},
        # Recovery
        {~U[2024-01-15 11:00:00Z], Decimal.new("105000")}
      ]

      {:ok, analysis} = Drawdown.calculate(equity_curve, [], Decimal.new("100000"))

      assert Decimal.equal?(analysis.max_drawdown_pct, Decimal.new("10"))
      assert Decimal.equal?(analysis.max_drawdown_dollars, Decimal.new("11000"))
    end

    test "tracks multiple drawdowns and finds the largest" do
      equity_curve = [
        {~U[2024-01-15 09:30:00Z], Decimal.new("100000")},
        # First peak
        {~U[2024-01-15 10:00:00Z], Decimal.new("105000")},
        # 5% DD
        {~U[2024-01-15 10:30:00Z], Decimal.new("100000")},
        # New peak
        {~U[2024-01-15 11:00:00Z], Decimal.new("110000")},
        # 14% DD (larger)
        {~U[2024-01-15 11:30:00Z], Decimal.new("94600")},
        # Recovery
        {~U[2024-01-15 12:00:00Z], Decimal.new("108000")}
      ]

      {:ok, analysis} = Drawdown.calculate(equity_curve, [], Decimal.new("100000"))

      # 14% DD is the largest
      assert Decimal.equal?(analysis.max_drawdown_pct, Decimal.new("14"))
      assert Decimal.equal?(analysis.max_drawdown_dollars, Decimal.new("15400"))
    end

    test "calculates current drawdown when still in drawdown" do
      equity_curve = [
        {~U[2024-01-15 09:30:00Z], Decimal.new("100000")},
        # Peak
        {~U[2024-01-15 10:00:00Z], Decimal.new("110000")},
        # Still in DD
        {~U[2024-01-15 10:30:00Z], Decimal.new("105000")}
      ]

      {:ok, analysis} = Drawdown.calculate(equity_curve, [], Decimal.new("100000"))

      # Current DD: (110000 - 105000) / 110000 = 4.55%
      assert Decimal.compare(analysis.current_drawdown_pct, Decimal.new(0)) == :gt
    end
  end

  describe "calculate_streaks/1" do
    test "returns zeros for empty trades" do
      {max_wins, max_losses, current, current_type} = Drawdown.calculate_streaks([])

      assert max_wins == 0
      assert max_losses == 0
      assert current == 0
      assert current_type == :none
    end

    test "calculates consecutive wins" do
      trades = [
        %{pnl: Decimal.new("100"), exit_time: ~U[2024-01-15 09:30:00Z]},
        %{pnl: Decimal.new("100"), exit_time: ~U[2024-01-15 10:00:00Z]},
        %{pnl: Decimal.new("100"), exit_time: ~U[2024-01-15 10:30:00Z]},
        %{pnl: Decimal.new("-50"), exit_time: ~U[2024-01-15 11:00:00Z]},
        %{pnl: Decimal.new("100"), exit_time: ~U[2024-01-15 11:30:00Z]}
      ]

      {max_wins, max_losses, current, current_type} = Drawdown.calculate_streaks(trades)

      assert max_wins == 3
      assert max_losses == 1
      assert current == 1
      assert current_type == :wins
    end

    test "calculates consecutive losses" do
      trades = [
        %{pnl: Decimal.new("100"), exit_time: ~U[2024-01-15 09:30:00Z]},
        %{pnl: Decimal.new("-50"), exit_time: ~U[2024-01-15 10:00:00Z]},
        %{pnl: Decimal.new("-50"), exit_time: ~U[2024-01-15 10:30:00Z]},
        %{pnl: Decimal.new("-50"), exit_time: ~U[2024-01-15 11:00:00Z]},
        %{pnl: Decimal.new("-50"), exit_time: ~U[2024-01-15 11:30:00Z]}
      ]

      {max_wins, max_losses, current, current_type} = Drawdown.calculate_streaks(trades)

      assert max_wins == 1
      assert max_losses == 4
      assert current == 4
      assert current_type == :losses
    end

    test "handles breakeven trades" do
      trades = [
        %{pnl: Decimal.new("100"), exit_time: ~U[2024-01-15 09:30:00Z]},
        %{pnl: Decimal.new("100"), exit_time: ~U[2024-01-15 10:00:00Z]},
        # Breakeven
        %{pnl: Decimal.new("0"), exit_time: ~U[2024-01-15 10:30:00Z]},
        %{pnl: Decimal.new("100"), exit_time: ~U[2024-01-15 11:00:00Z]}
      ]

      {max_wins, _max_losses, current, _current_type} = Drawdown.calculate_streaks(trades)

      # First two wins
      assert max_wins == 2
      # Only the last win after breakeven
      assert current == 1
    end
  end

  describe "recovery_factor/2" do
    test "calculates recovery factor" do
      result = Drawdown.recovery_factor(Decimal.new("10000"), Decimal.new("5000"))
      assert Decimal.equal?(result, Decimal.new("2"))
    end

    test "returns nil when max drawdown is zero" do
      result = Drawdown.recovery_factor(Decimal.new("10000"), Decimal.new(0))
      assert result == nil
    end

    test "handles negative net profit" do
      result = Drawdown.recovery_factor(Decimal.new("-5000"), Decimal.new("10000"))
      assert Decimal.equal?(result, Decimal.new("-0.5"))
    end
  end

  describe "find_max_drawdown/1" do
    test "returns zeros for empty curve" do
      {pct, dollars, start_time, end_time} = Drawdown.find_max_drawdown([])

      assert Decimal.equal?(pct, Decimal.new(0))
      assert Decimal.equal?(dollars, Decimal.new(0))
      assert start_time == nil
      assert end_time == nil
    end

    test "finds max drawdown with times" do
      equity_curve = [
        {~U[2024-01-15 09:30:00Z], Decimal.new("100000")},
        {~U[2024-01-16 10:00:00Z], Decimal.new("110000")},
        {~U[2024-01-17 10:30:00Z], Decimal.new("99000")},
        {~U[2024-01-18 11:00:00Z], Decimal.new("105000")}
      ]

      {pct, dollars, start_time, end_time} = Drawdown.find_max_drawdown(equity_curve)

      assert Decimal.equal?(pct, Decimal.new("10"))
      assert Decimal.equal?(dollars, Decimal.new("11000"))
      assert start_time == ~U[2024-01-16 10:00:00Z]
      assert end_time == ~U[2024-01-17 10:30:00Z]
    end
  end
end
