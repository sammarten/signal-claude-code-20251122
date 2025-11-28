defmodule Signal.Analytics.SignalAnalysisTest do
  use ExUnit.Case, async: true

  alias Signal.Analytics.SignalAnalysis

  describe "calculate/1" do
    test "returns empty stats for empty trades" do
      {:ok, analysis} = SignalAnalysis.calculate([])

      assert analysis.by_grade == %{}
      assert analysis.by_strategy == %{}
      assert analysis.by_symbol == %{}
      assert analysis.by_direction == %{}
      assert analysis.by_exit_type == %{}
    end

    test "groups trades by symbol" do
      trades = [
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("-50"), symbol: "TSLA", r_multiple: Decimal.new("-0.5")}
      ]

      {:ok, analysis} = SignalAnalysis.calculate(trades)

      assert map_size(analysis.by_symbol) == 2
      assert analysis.by_symbol["AAPL"].count == 2
      assert analysis.by_symbol["TSLA"].count == 1
    end

    test "groups trades by direction" do
      trades = [
        %{pnl: Decimal.new("100"), direction: :long, r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), direction: :long, r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("-50"), direction: :short, r_multiple: Decimal.new("-0.5")}
      ]

      {:ok, analysis} = SignalAnalysis.calculate(trades)

      assert map_size(analysis.by_direction) == 2
      assert analysis.by_direction[:long].count == 2
      assert analysis.by_direction[:short].count == 1
    end

    test "groups trades by exit type" do
      trades = [
        %{pnl: Decimal.new("100"), status: :target_hit, r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("-50"), status: :stopped_out, r_multiple: Decimal.new("-1.0")},
        %{pnl: Decimal.new("30"), status: :time_exit, r_multiple: Decimal.new("0.3")}
      ]

      {:ok, analysis} = SignalAnalysis.calculate(trades)

      assert map_size(analysis.by_exit_type) == 3
      assert analysis.by_exit_type[:target_hit].count == 1
      assert analysis.by_exit_type[:stopped_out].count == 1
      assert analysis.by_exit_type[:time_exit].count == 1
    end

    test "calculates stats correctly" do
      trades = [
        %{pnl: Decimal.new("200"), symbol: "AAPL", r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("-100"), symbol: "AAPL", r_multiple: Decimal.new("-1.0")}
      ]

      {:ok, analysis} = SignalAnalysis.calculate(trades)

      aapl = analysis.by_symbol["AAPL"]
      assert aapl.count == 2
      assert aapl.winners == 1
      assert aapl.losers == 1
      assert Decimal.equal?(aapl.win_rate, Decimal.new(50))
      assert Decimal.equal?(aapl.net_pnl, Decimal.new("100"))
      assert Decimal.equal?(aapl.profit_factor, Decimal.new("2"))
      assert Decimal.equal?(aapl.avg_r, Decimal.new("0.5"))
    end
  end

  describe "by_grade/1" do
    test "groups by quality grade" do
      trades = [
        %{pnl: Decimal.new("100"), quality_grade: "A", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), quality_grade: "A", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("50"), quality_grade: "B", r_multiple: Decimal.new("0.5")},
        %{pnl: Decimal.new("-30"), quality_grade: "C", r_multiple: Decimal.new("-0.3")}
      ]

      result = SignalAnalysis.by_grade(trades)

      assert map_size(result) == 3
      assert result["A"].count == 2
      assert result["B"].count == 1
      assert result["C"].count == 1
    end

    test "handles trades without grade" do
      trades = [
        %{pnl: Decimal.new("100"), quality_grade: nil},
        %{pnl: Decimal.new("100"), quality_grade: "A"}
      ]

      result = SignalAnalysis.by_grade(trades)

      assert map_size(result) == 1
      assert result["A"].count == 1
    end

    test "tries alternative field names" do
      trades = [
        # Alternative field name
        %{pnl: Decimal.new("100"), grade: "A"},
        # Another alternative
        %{pnl: Decimal.new("100"), signal_grade: "B"}
      ]

      result = SignalAnalysis.by_grade(trades)

      assert map_size(result) == 2
    end
  end

  describe "by_strategy/1" do
    test "groups by strategy" do
      trades = [
        %{pnl: Decimal.new("100"), strategy: "break_and_retest", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), strategy: "break_and_retest", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("-50"), strategy: "opening_range", r_multiple: Decimal.new("-0.5")}
      ]

      result = SignalAnalysis.by_strategy(trades)

      assert map_size(result) == 2
      assert result["break_and_retest"].count == 2
      assert result["opening_range"].count == 1
    end

    test "converts atom strategies to strings" do
      trades = [
        %{pnl: Decimal.new("100"), strategy: :break_and_retest}
      ]

      result = SignalAnalysis.by_strategy(trades)

      assert Map.has_key?(result, "break_and_retest")
    end
  end

  describe "by_symbol/1" do
    test "groups by symbol" do
      trades = [
        %{pnl: Decimal.new("100"), symbol: "AAPL"},
        %{pnl: Decimal.new("100"), symbol: "AAPL"},
        %{pnl: Decimal.new("100"), symbol: "TSLA"},
        %{pnl: Decimal.new("100"), symbol: "NVDA"}
      ]

      result = SignalAnalysis.by_symbol(trades)

      assert map_size(result) == 3
      assert result["AAPL"].count == 2
      assert result["TSLA"].count == 1
      assert result["NVDA"].count == 1
    end
  end

  describe "by_direction/1" do
    test "groups by direction" do
      trades = [
        %{pnl: Decimal.new("100"), direction: :long},
        %{pnl: Decimal.new("100"), direction: :long},
        %{pnl: Decimal.new("-50"), direction: :short}
      ]

      result = SignalAnalysis.by_direction(trades)

      assert map_size(result) == 2
      assert result[:long].count == 2
      assert result[:short].count == 1
    end
  end

  describe "by_exit_type/1" do
    test "groups by exit status" do
      trades = [
        %{pnl: Decimal.new("100"), status: :target_hit},
        %{pnl: Decimal.new("-50"), status: :stopped_out},
        %{pnl: Decimal.new("-50"), status: :stopped_out},
        %{pnl: Decimal.new("20"), status: :time_exit}
      ]

      result = SignalAnalysis.by_exit_type(trades)

      assert map_size(result) == 3
      assert result[:target_hit].count == 1
      assert result[:stopped_out].count == 2
      assert result[:time_exit].count == 1
    end

    test "calculates correct average R for each exit type" do
      trades = [
        %{pnl: Decimal.new("100"), status: :target_hit, r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("150"), status: :target_hit, r_multiple: Decimal.new("3.0")},
        %{pnl: Decimal.new("-50"), status: :stopped_out, r_multiple: Decimal.new("-1.0")}
      ]

      result = SignalAnalysis.by_exit_type(trades)

      # Target hit average: (2.0 + 3.0) / 2 = 2.5
      assert Decimal.equal?(result[:target_hit].avg_r, Decimal.new("2.5"))
      # Stopped out average: -1.0
      assert Decimal.equal?(result[:stopped_out].avg_r, Decimal.new("-1"))
    end
  end

  describe "finding best/worst" do
    test "identifies best and worst performers" do
      trades = [
        # AAPL: 8 trades, all winners, PF = infinite (will be nil)
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},

        # TSLA: 6 trades, good PF
        %{pnl: Decimal.new("200"), symbol: "TSLA", r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("200"), symbol: "TSLA", r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("200"), symbol: "TSLA", r_multiple: Decimal.new("2.0")},
        %{pnl: Decimal.new("-100"), symbol: "TSLA", r_multiple: Decimal.new("-1.0")},
        %{pnl: Decimal.new("-100"), symbol: "TSLA", r_multiple: Decimal.new("-1.0")},
        %{pnl: Decimal.new("-100"), symbol: "TSLA", r_multiple: Decimal.new("-1.0")},

        # NVDA: 6 trades, worse PF
        %{pnl: Decimal.new("100"), symbol: "NVDA", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("100"), symbol: "NVDA", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("-100"), symbol: "NVDA", r_multiple: Decimal.new("-1.0")},
        %{pnl: Decimal.new("-100"), symbol: "NVDA", r_multiple: Decimal.new("-1.0")},
        %{pnl: Decimal.new("-100"), symbol: "NVDA", r_multiple: Decimal.new("-1.0")},
        %{pnl: Decimal.new("-100"), symbol: "NVDA", r_multiple: Decimal.new("-1.0")}
      ]

      {:ok, analysis} = SignalAnalysis.calculate(trades)

      # TSLA has PF 2.0, NVDA has PF 0.5
      assert analysis.best_symbol == "TSLA"
      assert analysis.worst_symbol == "NVDA"
    end

    test "returns nil when not enough trades" do
      trades = [
        %{pnl: Decimal.new("100"), symbol: "AAPL", r_multiple: Decimal.new("1.0")},
        %{pnl: Decimal.new("-50"), symbol: "AAPL", r_multiple: Decimal.new("-0.5")}
      ]

      {:ok, analysis} = SignalAnalysis.calculate(trades)

      # Only 2 trades, below minimum threshold
      assert analysis.best_symbol == nil
      assert analysis.worst_symbol == nil
    end
  end
end
