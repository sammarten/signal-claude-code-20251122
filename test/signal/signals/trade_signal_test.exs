defmodule Signal.Signals.TradeSignalTest do
  use ExUnit.Case, async: true

  alias Signal.Signals.TradeSignal

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      attrs = valid_attrs()

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = TradeSignal.changeset(%TradeSignal{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).symbol
      assert "can't be blank" in errors_on(changeset).strategy
      assert "can't be blank" in errors_on(changeset).direction
    end

    test "validates strategy is valid value" do
      attrs = Map.put(valid_attrs(), :strategy, "invalid_strategy")

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).strategy
    end

    test "validates direction is valid value" do
      attrs = Map.put(valid_attrs(), :direction, "sideways")

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).direction
    end

    test "validates status is valid value" do
      attrs = Map.put(valid_attrs(), :status, "unknown")

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "validates quality_grade is valid value" do
      attrs = Map.put(valid_attrs(), :quality_grade, "X")

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).quality_grade
    end

    test "validates confluence_score range" do
      attrs = Map.put(valid_attrs(), :confluence_score, 15)

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "must be less than or equal to 13" in errors_on(changeset).confluence_score
    end

    test "validates risk_reward is positive" do
      attrs = Map.put(valid_attrs(), :risk_reward, Decimal.new("-1.0"))

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).risk_reward
    end

    test "validates stop_loss below entry for long" do
      attrs =
        valid_attrs()
        |> Map.put(:direction, "long")
        |> Map.put(:entry_price, Decimal.new("100.00"))
        |> Map.put(:stop_loss, Decimal.new("101.00"))

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "must be below entry price for long positions" in errors_on(changeset).stop_loss
    end

    test "validates take_profit above entry for long" do
      attrs =
        valid_attrs()
        |> Map.put(:direction, "long")
        |> Map.put(:entry_price, Decimal.new("100.00"))
        |> Map.put(:take_profit, Decimal.new("99.00"))

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "must be above entry price for long positions" in errors_on(changeset).take_profit
    end

    test "validates stop_loss above entry for short" do
      attrs =
        valid_attrs()
        |> Map.put(:direction, "short")
        |> Map.put(:entry_price, Decimal.new("100.00"))
        |> Map.put(:stop_loss, Decimal.new("99.00"))
        |> Map.put(:take_profit, Decimal.new("98.00"))

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "must be above entry price for short positions" in errors_on(changeset).stop_loss
    end

    test "validates take_profit below entry for short" do
      attrs =
        valid_attrs()
        |> Map.put(:direction, "short")
        |> Map.put(:entry_price, Decimal.new("100.00"))
        |> Map.put(:stop_loss, Decimal.new("101.00"))
        |> Map.put(:take_profit, Decimal.new("102.00"))

      changeset = TradeSignal.changeset(%TradeSignal{}, attrs)

      refute changeset.valid?
      assert "must be below entry price for short positions" in errors_on(changeset).take_profit
    end

    test "accepts all valid strategies" do
      strategies = [
        "break_and_retest",
        "opening_range_breakout",
        "one_candle_rule",
        "premarket_breakout"
      ]

      for strategy <- strategies do
        attrs = Map.put(valid_attrs(), :strategy, strategy)
        changeset = TradeSignal.changeset(%TradeSignal{}, attrs)
        assert changeset.valid?, "Expected #{strategy} to be valid"
      end
    end

    test "accepts all valid grades" do
      grades = ["A", "B", "C", "D", "F"]

      for grade <- grades do
        attrs = Map.put(valid_attrs(), :quality_grade, grade)
        changeset = TradeSignal.changeset(%TradeSignal{}, attrs)
        assert changeset.valid?, "Expected grade #{grade} to be valid"
      end
    end
  end

  describe "status_changeset/2" do
    test "allows updating status" do
      signal = %TradeSignal{status: "active"}

      changeset = TradeSignal.status_changeset(signal, %{status: "filled"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == "filled"
    end

    test "allows setting filled_at" do
      signal = %TradeSignal{status: "active"}
      now = DateTime.utc_now()

      changeset = TradeSignal.status_changeset(signal, %{status: "filled", filled_at: now})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :filled_at) == now
    end

    test "validates status value" do
      signal = %TradeSignal{status: "active"}

      changeset = TradeSignal.status_changeset(signal, %{status: "invalid"})

      refute changeset.valid?
    end
  end

  # Helper Functions

  defp valid_attrs do
    %{
      symbol: "AAPL",
      strategy: "break_and_retest",
      direction: "long",
      entry_price: Decimal.new("175.50"),
      stop_loss: Decimal.new("174.50"),
      take_profit: Decimal.new("177.50"),
      risk_reward: Decimal.new("2.0"),
      confluence_score: 8,
      quality_grade: "B",
      generated_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 1800, :second)
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
