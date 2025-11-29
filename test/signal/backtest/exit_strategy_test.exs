defmodule Signal.Backtest.ExitStrategyTest do
  use ExUnit.Case, async: true

  alias Signal.Backtest.ExitStrategy

  describe "fixed/2" do
    test "creates a fixed strategy with stop and target" do
      strategy = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))

      assert strategy.type == :fixed
      assert strategy.initial_stop == Decimal.new("174.50")
      assert length(strategy.targets) == 1

      [target] = strategy.targets
      assert target.price == Decimal.new("177.50")
      assert target.exit_percent == 100
      assert target.move_stop_to == nil
    end

    test "creates a fixed strategy with stop only (no target)" do
      strategy = ExitStrategy.fixed(Decimal.new("174.50"))

      assert strategy.type == :fixed
      assert strategy.initial_stop == Decimal.new("174.50")
      assert strategy.targets == nil
    end

    test "has no trailing config" do
      strategy = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      assert strategy.trailing_config == nil
    end

    test "has no breakeven config" do
      strategy = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      assert strategy.breakeven_config == nil
    end
  end

  describe "trailing/2" do
    test "creates a trailing strategy with fixed distance" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )

      assert strategy.type == :trailing
      assert strategy.initial_stop == Decimal.new("174.50")
      assert strategy.trailing_config.type == :fixed_distance
      assert strategy.trailing_config.value == Decimal.new("0.50")
      assert strategy.trailing_config.activation_r == nil
    end

    test "creates a trailing strategy with ATR multiple" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :atr_multiple,
          value: Decimal.new("2.0")
        )

      assert strategy.trailing_config.type == :atr_multiple
      assert strategy.trailing_config.value == Decimal.new("2.0")
    end

    test "creates a trailing strategy with percent" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :percent,
          value: Decimal.new("0.01")
        )

      assert strategy.trailing_config.type == :percent
      assert strategy.trailing_config.value == Decimal.new("0.01")
    end

    test "supports activation_r threshold" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0.50"),
          activation_r: Decimal.new("1.0")
        )

      assert strategy.trailing_config.activation_r == Decimal.new("1.0")
    end

    test "supports optional take_profit" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0.50"),
          take_profit: Decimal.new("180.00")
        )

      assert length(strategy.targets) == 1
      assert hd(strategy.targets).price == Decimal.new("180.00")
    end

    test "raises on invalid trailing type" do
      assert_raise ArgumentError, ~r/Invalid trailing type/, fn ->
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :invalid,
          value: Decimal.new("0.50")
        )
      end
    end

    test "raises on non-positive value" do
      assert_raise ArgumentError, ~r/must be a positive Decimal/, fn ->
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0")
        )
      end

      assert_raise ArgumentError, ~r/must be a positive Decimal/, fn ->
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("-0.50")
        )
      end
    end

    test "raises on negative activation_r" do
      assert_raise ArgumentError, ~r/must be a non-negative Decimal/, fn ->
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0.50"),
          activation_r: Decimal.new("-1.0")
        )
      end
    end

    test "allows zero activation_r (immediate trailing)" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0.50"),
          activation_r: Decimal.new("0")
        )

      assert strategy.trailing_config.activation_r == Decimal.new("0")
    end
  end

  describe "scaled/2" do
    test "creates a scaled strategy with two targets" do
      strategy =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      assert strategy.type == :scaled
      assert strategy.initial_stop == Decimal.new("174.50")
      assert length(strategy.targets) == 2

      [t1, t2] = strategy.targets
      assert t1.price == Decimal.new("176.00")
      assert t1.exit_percent == 50
      assert t1.move_stop_to == :breakeven

      assert t2.price == Decimal.new("178.00")
      assert t2.exit_percent == 50
      assert t2.move_stop_to == nil
    end

    test "creates a scaled strategy with three targets" do
      strategy =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("175.50"), exit_percent: 33, move_stop_to: :breakeven},
          %{price: Decimal.new("176.50"), exit_percent: 33, move_stop_to: :entry},
          %{price: Decimal.new("178.00"), exit_percent: 34, move_stop_to: nil}
        ])

      assert length(strategy.targets) == 3
      assert Enum.sum(Enum.map(strategy.targets, & &1.exit_percent)) == 100
    end

    test "supports {:price, Decimal} stop adjustment" do
      strategy =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{
            price: Decimal.new("176.00"),
            exit_percent: 50,
            move_stop_to: {:price, Decimal.new("175.00")}
          },
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      [t1, _t2] = strategy.targets
      assert t1.move_stop_to == {:price, Decimal.new("175.00")}
    end

    test "raises when targets don't sum to 100" do
      assert_raise ArgumentError, ~r/must sum to 100/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("178.00"), exit_percent: 40, move_stop_to: nil}
        ])
      end
    end

    test "raises when targets sum to more than 100" do
      assert_raise ArgumentError, ~r/must sum to 100/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 60, move_stop_to: nil},
          %{price: Decimal.new("178.00"), exit_percent: 60, move_stop_to: nil}
        ])
      end
    end

    test "raises on empty targets list" do
      assert_raise ArgumentError, ~r/cannot be empty/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [])
      end
    end

    test "raises when target missing price" do
      assert_raise ArgumentError, ~r/must have a :price field/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{exit_percent: 100, move_stop_to: nil}
        ])
      end
    end

    test "raises when target missing exit_percent" do
      assert_raise ArgumentError, ~r/must have an :exit_percent field/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), move_stop_to: nil}
        ])
      end
    end

    test "raises on invalid exit_percent" do
      assert_raise ArgumentError, ~r/must be an integer between 1 and 100/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 0, move_stop_to: nil}
        ])
      end

      assert_raise ArgumentError, ~r/must be an integer between 1 and 100/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 101, move_stop_to: nil}
        ])
      end

      assert_raise ArgumentError, ~r/must be an integer between 1 and 100/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 50.5, move_stop_to: nil}
        ])
      end
    end

    test "raises on invalid move_stop_to value" do
      assert_raise ArgumentError, ~r/invalid move_stop_to value/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: :invalid}
        ])
      end
    end

    test "raises when {:price, value} has non-Decimal value" do
      assert_raise ArgumentError, ~r/requires a Decimal/, fn ->
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: {:price, 175.00}}
        ])
      end
    end
  end

  describe "with_breakeven/3" do
    test "adds breakeven config to fixed strategy" do
      strategy =
        ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"))

      assert strategy.type == :breakeven
      assert strategy.breakeven_config.trigger_r == Decimal.new("1.0")
      assert strategy.breakeven_config.buffer == Decimal.new("0.05")
    end

    test "uses custom buffer" do
      strategy =
        ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"), Decimal.new("0.10"))

      assert strategy.breakeven_config.buffer == Decimal.new("0.10")
    end

    test "changes trailing strategy to combined" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )
        |> ExitStrategy.with_breakeven(Decimal.new("0.5"))

      assert strategy.type == :combined
      assert is_map(strategy.trailing_config)
      assert is_map(strategy.breakeven_config)
    end

    test "changes scaled strategy to combined" do
      strategy =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: nil}
        ])
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"))

      assert strategy.type == :combined
    end

    test "raises on non-positive trigger_r" do
      assert_raise ArgumentError, ~r/must be a positive Decimal/, fn ->
        ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
        |> ExitStrategy.with_breakeven(Decimal.new("0"))
      end
    end

    test "raises on negative buffer" do
      assert_raise ArgumentError, ~r/must be a non-negative Decimal/, fn ->
        ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"), Decimal.new("-0.05"))
      end
    end

    test "allows zero buffer" do
      strategy =
        ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"), Decimal.new("0"))

      assert strategy.breakeven_config.buffer == Decimal.new("0")
    end
  end

  describe "with_trailing/2" do
    test "adds trailing config to scaled strategy" do
      strategy =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])
        |> ExitStrategy.with_trailing(type: :fixed_distance, value: Decimal.new("0.50"))

      assert strategy.type == :combined
      assert strategy.trailing_config.type == :fixed_distance
      assert strategy.trailing_config.value == Decimal.new("0.50")
      assert length(strategy.targets) == 2
    end

    test "supports activation_r" do
      strategy =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: nil}
        ])
        |> ExitStrategy.with_trailing(
          type: :atr_multiple,
          value: Decimal.new("2.0"),
          activation_r: Decimal.new("1.5")
        )

      assert strategy.trailing_config.activation_r == Decimal.new("1.5")
    end

    test "raises on invalid trailing type" do
      assert_raise ArgumentError, ~r/Invalid trailing type/, fn ->
        ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
        |> ExitStrategy.with_trailing(type: :bad_type, value: Decimal.new("0.50"))
      end
    end
  end

  describe "query functions" do
    test "trailing?/1" do
      fixed = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      refute ExitStrategy.trailing?(fixed)

      trailing =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )

      assert ExitStrategy.trailing?(trailing)

      combined =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: nil}
        ])
        |> ExitStrategy.with_trailing(type: :fixed_distance, value: Decimal.new("0.50"))

      assert ExitStrategy.trailing?(combined)
    end

    test "scaled?/1" do
      fixed = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      refute ExitStrategy.scaled?(fixed)

      single_target =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: nil}
        ])

      refute ExitStrategy.scaled?(single_target)

      multi_target =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      assert ExitStrategy.scaled?(multi_target)
    end

    test "has_breakeven?/1" do
      fixed = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      refute ExitStrategy.has_breakeven?(fixed)

      with_be =
        ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"))

      assert ExitStrategy.has_breakeven?(with_be)
    end

    test "target_count/1" do
      no_target = ExitStrategy.fixed(Decimal.new("174.50"))
      assert ExitStrategy.target_count(no_target) == 0

      one_target = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      assert ExitStrategy.target_count(one_target) == 1

      three_targets =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("175.50"), exit_percent: 33, move_stop_to: nil},
          %{price: Decimal.new("176.50"), exit_percent: 33, move_stop_to: nil},
          %{price: Decimal.new("178.00"), exit_percent: 34, move_stop_to: nil}
        ])

      assert ExitStrategy.target_count(three_targets) == 3
    end

    test "first_target_price/1" do
      no_target = ExitStrategy.fixed(Decimal.new("174.50"))
      assert ExitStrategy.first_target_price(no_target) == nil

      with_target = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      assert ExitStrategy.first_target_price(with_target) == Decimal.new("177.50")

      scaled =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      assert ExitStrategy.first_target_price(scaled) == Decimal.new("176.00")
    end

    test "final_target_price/1" do
      no_target = ExitStrategy.fixed(Decimal.new("174.50"))
      assert ExitStrategy.final_target_price(no_target) == nil

      with_target = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      assert ExitStrategy.final_target_price(with_target) == Decimal.new("177.50")

      scaled =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: nil},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])

      assert ExitStrategy.final_target_price(scaled) == Decimal.new("178.00")
    end

    test "type_string/1" do
      fixed = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      assert ExitStrategy.type_string(fixed) == "fixed"

      trailing =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :fixed_distance,
          value: Decimal.new("0.50")
        )

      assert ExitStrategy.type_string(trailing) == "trailing"

      scaled =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: nil}
        ])

      assert ExitStrategy.type_string(scaled) == "scaled"

      breakeven =
        ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
        |> ExitStrategy.with_breakeven(Decimal.new("1.0"))

      assert ExitStrategy.type_string(breakeven) == "breakeven"

      combined =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 100, move_stop_to: nil}
        ])
        |> ExitStrategy.with_trailing(type: :fixed_distance, value: Decimal.new("0.50"))

      assert ExitStrategy.type_string(combined) == "combined"
    end
  end

  describe "complex combinations" do
    test "scaled with breakeven and trailing" do
      strategy =
        ExitStrategy.scaled(Decimal.new("174.50"), [
          %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven},
          %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
        ])
        |> ExitStrategy.with_breakeven(Decimal.new("0.5"))
        |> ExitStrategy.with_trailing(type: :fixed_distance, value: Decimal.new("0.50"))

      assert strategy.type == :combined
      assert length(strategy.targets) == 2
      assert strategy.breakeven_config.trigger_r == Decimal.new("0.5")
      assert strategy.trailing_config.type == :fixed_distance
    end

    test "trailing with breakeven" do
      strategy =
        ExitStrategy.trailing(
          Decimal.new("174.50"),
          type: :atr_multiple,
          value: Decimal.new("2.0"),
          activation_r: Decimal.new("1.0")
        )
        |> ExitStrategy.with_breakeven(Decimal.new("0.5"))

      assert strategy.type == :combined
      assert strategy.trailing_config.type == :atr_multiple
      assert strategy.breakeven_config.trigger_r == Decimal.new("0.5")
    end
  end
end
