defmodule Signal.SignalGeneratorTest do
  use Signal.DataCase, async: false

  alias Signal.SignalGenerator
  alias Signal.Signals.TradeSignal
  alias Signal.Strategies.Setup
  alias Signal.Repo

  describe "generate/3" do
    test "generates signal for setup meeting minimum grade" do
      setup = create_high_quality_setup()

      # Context that gives enough points for grade C (6+)
      context = %{
        higher_timeframe: %{trend: :bullish},
        market_structure: %{trend: :bullish}
      }

      assert {:ok, signal} =
               SignalGenerator.generate(setup, context, broadcast: false, skip_rate_limit: true)

      assert signal.symbol == "AAPL"
      assert signal.strategy == "break_and_retest"
      assert signal.direction == "long"
      assert signal.status == "active"
      assert signal.quality_grade in ["A", "B", "C"]
      assert signal.confluence_score >= 6
    end

    test "returns error when setup below minimum grade" do
      setup = create_setup(:long)

      # No context means low score
      assert {:error, :below_minimum_grade} =
               SignalGenerator.generate(setup, %{},
                 broadcast: false,
                 min_grade: :A,
                 skip_rate_limit: true
               )
    end

    test "sets correct expiry time" do
      setup = create_high_quality_setup()
      context = %{higher_timeframe: %{trend: :bullish}, market_structure: %{trend: :bullish}}

      {:ok, signal} =
        SignalGenerator.generate(setup, context,
          broadcast: false,
          expiry_minutes: 60,
          skip_rate_limit: true
        )

      # Expiry should be approximately 60 minutes from now
      diff = DateTime.diff(signal.expires_at, signal.generated_at)
      assert diff == 60 * 60
    end

    test "stores signal in database" do
      setup = create_high_quality_setup()
      context = %{higher_timeframe: %{trend: :bullish}, market_structure: %{trend: :bullish}}

      {:ok, signal} =
        SignalGenerator.generate(setup, context, broadcast: false, skip_rate_limit: true)

      # Verify it's in the database
      assert Repo.get(TradeSignal, signal.id) != nil
    end

    test "stores confluence factors in signal" do
      setup = create_high_quality_setup()
      context = %{higher_timeframe: %{trend: :bullish}, market_structure: %{trend: :bullish}}

      {:ok, signal} =
        SignalGenerator.generate(setup, context, broadcast: false, skip_rate_limit: true)

      assert is_map(signal.confluence_factors)
      assert Map.has_key?(signal.confluence_factors, "timeframe_alignment")
      assert Map.has_key?(signal.confluence_factors, "market_structure")
    end

    test "returns error when rate limited" do
      # Insert a recent signal for the same symbol
      insert_signal("AAPL", "active", generated_at: DateTime.utc_now())

      setup = create_high_quality_setup()
      context = %{higher_timeframe: %{trend: :bullish}, market_structure: %{trend: :bullish}}

      assert {:error, :rate_limited} =
               SignalGenerator.generate(setup, context, broadcast: false)
    end

    test "returns error when daily limit reached" do
      # Insert 2 signals for today (max per day), both more than 5 min ago to not trigger rate limit
      insert_signal("AAPL", "filled",
        generated_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      )

      insert_signal("AAPL", "expired",
        generated_at: DateTime.add(DateTime.utc_now(), -1800, :second)
      )

      setup = create_high_quality_setup()
      context = %{higher_timeframe: %{trend: :bullish}, market_structure: %{trend: :bullish}}

      # Most recent signal is 30 min ago, outside 5-min rate limit window
      # But daily limit of 2 signals should be reached
      assert {:error, :daily_limit_reached} =
               SignalGenerator.generate(setup, context, broadcast: false)
    end

    test "returns error when duplicate active signal exists" do
      # Insert an active signal for the same setup
      insert_signal("AAPL", "active",
        strategy: "break_and_retest",
        direction: "long",
        level_type: "pdh"
      )

      setup = create_high_quality_setup()
      context = %{higher_timeframe: %{trend: :bullish}, market_structure: %{trend: :bullish}}

      assert {:error, :duplicate_signal} =
               SignalGenerator.generate(setup, context, broadcast: false, skip_rate_limit: true)
    end

    test "allows signal when skip_rate_limit is true" do
      # Insert a recent signal
      insert_signal("AAPL", "active", generated_at: DateTime.utc_now())
      # Expire it so it's not a duplicate
      Repo.update_all(TradeSignal, set: [status: "expired"])

      setup = create_high_quality_setup()
      context = %{higher_timeframe: %{trend: :bullish}, market_structure: %{trend: :bullish}}

      assert {:ok, _signal} =
               SignalGenerator.generate(setup, context, broadcast: false, skip_rate_limit: true)
    end
  end

  describe "fill/2" do
    test "marks signal as filled" do
      signal = insert_active_signal()

      assert {:ok, updated} = SignalGenerator.fill(signal)

      assert updated.status == "filled"
      assert updated.filled_at != nil
    end

    test "sets fill price when provided" do
      signal = insert_active_signal()
      fill_price = Decimal.new("176.00")

      assert {:ok, updated} = SignalGenerator.fill(signal, fill_price)

      assert Decimal.equal?(updated.exit_price, fill_price)
    end
  end

  describe "expire/1" do
    test "marks signal as expired" do
      signal = insert_active_signal()

      assert {:ok, updated} = SignalGenerator.expire(signal)

      assert updated.status == "expired"
    end
  end

  describe "invalidate/1" do
    test "marks signal as invalidated" do
      signal = insert_active_signal()

      assert {:ok, updated} = SignalGenerator.invalidate(signal)

      assert updated.status == "invalidated"
    end
  end

  describe "get_active_signals/1" do
    test "returns only active signals for symbol" do
      insert_signal("AAPL", "active")
      insert_signal("AAPL", "active")
      insert_signal("AAPL", "expired")
      insert_signal("TSLA", "active")

      signals = SignalGenerator.get_active_signals("AAPL")

      assert length(signals) == 2
      assert Enum.all?(signals, &(&1.symbol == "AAPL"))
      assert Enum.all?(signals, &(&1.status == "active"))
    end

    test "excludes expired signals" do
      # Insert signal that has passed its expiry
      insert_signal("AAPL", "active", expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

      signals = SignalGenerator.get_active_signals("AAPL")

      assert signals == []
    end
  end

  describe "get_all_active_signals/0" do
    test "returns all active signals across symbols" do
      insert_signal("AAPL", "active")
      insert_signal("TSLA", "active")
      insert_signal("NVDA", "expired")

      signals = SignalGenerator.get_all_active_signals()

      assert length(signals) == 2
      symbols = Enum.map(signals, & &1.symbol)
      assert "AAPL" in symbols
      assert "TSLA" in symbols
    end
  end

  describe "get_signals_by_grade/2" do
    test "returns signals matching grade" do
      insert_signal("AAPL", "active", quality_grade: "A")
      insert_signal("AAPL", "active", quality_grade: "A")
      insert_signal("AAPL", "active", quality_grade: "B")

      signals = SignalGenerator.get_signals_by_grade(:A)

      assert length(signals) == 2
      assert Enum.all?(signals, &(&1.quality_grade == "A"))
    end

    test "filters by status when provided" do
      insert_signal("AAPL", "active", quality_grade: "A")
      insert_signal("AAPL", "filled", quality_grade: "A")

      signals = SignalGenerator.get_signals_by_grade(:A, status: :active)

      assert length(signals) == 1
      assert hd(signals).status == "active"
    end
  end

  describe "get_recent_signals/2" do
    test "returns recent signals for symbol" do
      insert_signal("AAPL", "active")
      insert_signal("AAPL", "filled")
      insert_signal("TSLA", "active")

      signals = SignalGenerator.get_recent_signals("AAPL")

      assert length(signals) == 2
      assert Enum.all?(signals, &(&1.symbol == "AAPL"))
    end

    test "respects limit option" do
      for _ <- 1..5, do: insert_signal("AAPL", "active")

      signals = SignalGenerator.get_recent_signals("AAPL", limit: 3)

      assert length(signals) == 3
    end
  end

  describe "expire_old_signals/0" do
    test "expires signals past their expiry time" do
      # Insert expired signal
      expired =
        insert_signal("AAPL", "active",
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      # Insert non-expired signal
      active =
        insert_signal("AAPL", "active",
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      assert {:ok, count} = SignalGenerator.expire_old_signals()

      assert count == 1

      # Verify the expired one is now expired
      assert Repo.get(TradeSignal, expired.id).status == "expired"
      # Verify the active one is still active
      assert Repo.get(TradeSignal, active.id).status == "active"
    end
  end

  describe "should_invalidate?/2" do
    test "returns true for long when price below stop" do
      signal = %TradeSignal{
        direction: "long",
        entry_price: Decimal.new("175.50"),
        stop_loss: Decimal.new("174.50")
      }

      assert SignalGenerator.should_invalidate?(signal, Decimal.new("174.00")) == true
      assert SignalGenerator.should_invalidate?(signal, Decimal.new("175.00")) == false
    end

    test "returns true for short when price above stop" do
      signal = %TradeSignal{
        direction: "short",
        entry_price: Decimal.new("175.50"),
        stop_loss: Decimal.new("176.50")
      }

      assert SignalGenerator.should_invalidate?(signal, Decimal.new("177.00")) == true
      assert SignalGenerator.should_invalidate?(signal, Decimal.new("176.00")) == false
    end
  end

  # Helper Functions

  defp create_setup(direction) do
    %Setup{
      symbol: "AAPL",
      strategy: :break_and_retest,
      direction: direction,
      level_type: :pdh,
      level_price: Decimal.new("175.00"),
      entry_price: Decimal.new("175.50"),
      stop_loss: Decimal.new("174.50"),
      take_profit: Decimal.new("177.50"),
      risk_reward: Decimal.new("2.0"),
      timestamp: DateTime.utc_now(),
      status: :pending,
      confluence: %{}
    }
  end

  defp create_high_quality_setup do
    setup = create_setup(:long)
    %{setup | confluence: %{strong_rejection: true}}
  end

  defp insert_active_signal do
    insert_signal("AAPL", "active")
  end

  defp insert_signal(symbol, status, opts \\ []) do
    now = DateTime.utc_now()
    generated_at = Keyword.get(opts, :generated_at, now)

    attrs = %{
      symbol: symbol,
      strategy: Keyword.get(opts, :strategy, "break_and_retest"),
      direction: Keyword.get(opts, :direction, "long"),
      level_type: Keyword.get(opts, :level_type),
      entry_price: Decimal.new("175.50"),
      stop_loss: Decimal.new("174.50"),
      take_profit: Decimal.new("177.50"),
      risk_reward: Decimal.new("2.0"),
      confluence_score: Keyword.get(opts, :confluence_score, 8),
      quality_grade: Keyword.get(opts, :quality_grade, "B"),
      confluence_factors: %{},
      status: status,
      generated_at: generated_at,
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(generated_at, 1800, :second))
    }

    {:ok, signal} =
      %TradeSignal{}
      |> TradeSignal.changeset(attrs)
      |> Repo.insert()

    signal
  end
end
