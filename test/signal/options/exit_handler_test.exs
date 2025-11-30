defmodule Signal.Options.ExitHandlerTest do
  use ExUnit.Case, async: true

  alias Signal.Options.ExitHandler

  # Helper to create a mock option bar
  defp option_bar(opts \\ []) do
    %{
      bar_time: Keyword.get(opts, :bar_time, ~U[2024-06-15 14:30:00Z]),
      open: Keyword.get(opts, :open, Decimal.new("5.00")),
      high: Keyword.get(opts, :high, Decimal.new("5.50")),
      low: Keyword.get(opts, :low, Decimal.new("4.50")),
      close: Keyword.get(opts, :close, Decimal.new("5.25"))
    }
  end

  # Helper to create a mock underlying bar
  defp underlying_bar(opts \\ []) do
    %{
      bar_time: Keyword.get(opts, :bar_time, ~U[2024-06-15 14:30:00Z]),
      open: Keyword.get(opts, :open, Decimal.new("150.00")),
      high: Keyword.get(opts, :high, Decimal.new("152.00")),
      low: Keyword.get(opts, :low, Decimal.new("148.00")),
      close: Keyword.get(opts, :close, Decimal.new("151.00"))
    }
  end

  describe "check_expiration/3" do
    test "returns :hold when before expiration" do
      position = %{expiration: ~D[2024-06-21]}
      bar = option_bar(bar_time: ~U[2024-06-15 14:30:00Z])

      assert :hold = ExitHandler.check_expiration(position, bar)
    end

    test "returns exit when past expiration" do
      position = %{expiration: ~D[2024-06-14]}
      bar = option_bar(bar_time: ~U[2024-06-15 14:30:00Z])

      assert {:exit, :expiration, price} = ExitHandler.check_expiration(position, bar)
      assert Decimal.equal?(price, Decimal.new("5.25"))
    end

    test "returns exit on expiration day past exit time" do
      position = %{expiration: ~D[2024-06-15]}
      bar = option_bar(bar_time: ~U[2024-06-15 15:50:00Z])

      assert {:exit, :expiration_day_exit, _price} = ExitHandler.check_expiration(position, bar)
    end

    test "returns :hold on expiration day before exit time" do
      position = %{expiration: ~D[2024-06-15]}
      bar = option_bar(bar_time: ~U[2024-06-15 10:30:00Z])

      assert :hold = ExitHandler.check_expiration(position, bar)
    end

    test "respects exit_before_expiration option" do
      position = %{expiration: ~D[2024-06-15]}
      bar = option_bar(bar_time: ~U[2024-06-14 14:30:00Z])

      # Should exit 1 day before expiration
      assert {:exit, :expiration_day_exit, _price} =
               ExitHandler.check_expiration(position, bar, exit_before_expiration: 1)
    end

    test "respects custom expiration_exit_time" do
      position = %{expiration: ~D[2024-06-15]}
      bar = option_bar(bar_time: ~U[2024-06-15 11:00:00Z])

      # Default exit time is 15:45, so 11:00 should hold
      assert :hold = ExitHandler.check_expiration(position, bar)

      # With custom exit time of 10:30, should exit
      assert {:exit, :expiration_day_exit, _price} =
               ExitHandler.check_expiration(position, bar, expiration_exit_time: ~T[10:30:00])
    end
  end

  describe "check_premium_target/2" do
    test "returns :hold when no premium target set" do
      position = %{premium_target: nil}
      bar = option_bar()

      assert :hold = ExitHandler.check_premium_target(position, bar)
    end

    test "returns :hold when premium_target key missing" do
      position = %{}
      bar = option_bar()

      assert :hold = ExitHandler.check_premium_target(position, bar)
    end

    test "returns exit when high reaches target" do
      position = %{premium_target: Decimal.new("5.50")}
      bar = option_bar(high: Decimal.new("5.75"))

      assert {:exit, :premium_target, price} = ExitHandler.check_premium_target(position, bar)
      assert Decimal.equal?(price, Decimal.new("5.50"))
    end

    test "returns exit when high equals target" do
      position = %{premium_target: Decimal.new("5.50")}
      bar = option_bar(high: Decimal.new("5.50"))

      assert {:exit, :premium_target, _price} = ExitHandler.check_premium_target(position, bar)
    end

    test "returns :hold when high below target" do
      position = %{premium_target: Decimal.new("6.00")}
      bar = option_bar(high: Decimal.new("5.50"))

      assert :hold = ExitHandler.check_premium_target(position, bar)
    end
  end

  describe "check_premium_stop/2" do
    test "returns :hold when no premium floor set" do
      position = %{premium_floor: nil}
      bar = option_bar()

      assert :hold = ExitHandler.check_premium_stop(position, bar)
    end

    test "returns :hold when premium_floor key missing" do
      position = %{}
      bar = option_bar()

      assert :hold = ExitHandler.check_premium_stop(position, bar)
    end

    test "returns exit when low breaches floor" do
      position = %{premium_floor: Decimal.new("4.50")}
      bar = option_bar(low: Decimal.new("4.25"))

      assert {:exit, :premium_stop, price} = ExitHandler.check_premium_stop(position, bar)
      assert Decimal.equal?(price, Decimal.new("4.50"))
    end

    test "returns exit when low equals floor" do
      position = %{premium_floor: Decimal.new("4.50")}
      bar = option_bar(low: Decimal.new("4.50"))

      assert {:exit, :premium_stop, _price} = ExitHandler.check_premium_stop(position, bar)
    end

    test "returns :hold when low above floor" do
      position = %{premium_floor: Decimal.new("4.00")}
      bar = option_bar(low: Decimal.new("4.50"))

      assert :hold = ExitHandler.check_premium_stop(position, bar)
    end
  end

  describe "check_underlying_stop/2" do
    test "returns :hold when no stop loss set" do
      position = %{stop_loss: nil, direction: :long}
      bar = underlying_bar()

      assert :hold = ExitHandler.check_underlying_stop(position, bar)
    end

    test "returns exit for long direction when low breaches stop" do
      position = %{stop_loss: Decimal.new("149.00"), direction: :long}
      bar = underlying_bar(low: Decimal.new("148.50"))

      assert {:exit, :underlying_stop, price} = ExitHandler.check_underlying_stop(position, bar)
      assert Decimal.equal?(price, Decimal.new("149.00"))
    end

    test "returns :hold for long direction when low above stop" do
      position = %{stop_loss: Decimal.new("147.00"), direction: :long}
      bar = underlying_bar(low: Decimal.new("148.00"))

      assert :hold = ExitHandler.check_underlying_stop(position, bar)
    end

    test "returns exit for short direction when high breaches stop" do
      position = %{stop_loss: Decimal.new("151.00"), direction: :short}
      bar = underlying_bar(high: Decimal.new("152.00"))

      assert {:exit, :underlying_stop, price} = ExitHandler.check_underlying_stop(position, bar)
      assert Decimal.equal?(price, Decimal.new("151.00"))
    end

    test "returns :hold for short direction when high below stop" do
      position = %{stop_loss: Decimal.new("153.00"), direction: :short}
      bar = underlying_bar(high: Decimal.new("152.00"))

      assert :hold = ExitHandler.check_underlying_stop(position, bar)
    end
  end

  describe "check_underlying_target/2" do
    test "returns :hold when no take profit set" do
      position = %{take_profit: nil, direction: :long}
      bar = underlying_bar()

      assert :hold = ExitHandler.check_underlying_target(position, bar)
    end

    test "returns exit for long direction when high reaches target" do
      position = %{take_profit: Decimal.new("151.00"), direction: :long}
      bar = underlying_bar(high: Decimal.new("152.00"))

      assert {:exit, :underlying_target, price} =
               ExitHandler.check_underlying_target(position, bar)

      assert Decimal.equal?(price, Decimal.new("151.00"))
    end

    test "returns :hold for long direction when high below target" do
      position = %{take_profit: Decimal.new("155.00"), direction: :long}
      bar = underlying_bar(high: Decimal.new("152.00"))

      assert :hold = ExitHandler.check_underlying_target(position, bar)
    end

    test "returns exit for short direction when low reaches target" do
      position = %{take_profit: Decimal.new("149.00"), direction: :short}
      bar = underlying_bar(low: Decimal.new("148.00"))

      assert {:exit, :underlying_target, price} =
               ExitHandler.check_underlying_target(position, bar)

      assert Decimal.equal?(price, Decimal.new("149.00"))
    end

    test "returns :hold for short direction when low above target" do
      position = %{take_profit: Decimal.new("145.00"), direction: :short}
      bar = underlying_bar(low: Decimal.new("148.00"))

      assert :hold = ExitHandler.check_underlying_target(position, bar)
    end
  end

  describe "check_exit/4" do
    test "checks all conditions and returns first exit" do
      # Position that will hit expiration
      position = %{
        expiration: ~D[2024-06-14],
        premium_target: nil,
        premium_floor: nil,
        stop_loss: Decimal.new("140.00"),
        take_profit: Decimal.new("160.00"),
        direction: :long
      }

      opt_bar = option_bar(bar_time: ~U[2024-06-15 14:30:00Z])
      und_bar = underlying_bar()

      # Should exit on expiration (first check)
      assert {:exit, :expiration, _price} = ExitHandler.check_exit(position, opt_bar, und_bar)
    end

    test "returns :hold when no conditions met" do
      position = %{
        expiration: ~D[2024-06-21],
        premium_target: Decimal.new("10.00"),
        premium_floor: Decimal.new("2.00"),
        stop_loss: Decimal.new("140.00"),
        take_profit: Decimal.new("160.00"),
        direction: :long
      }

      opt_bar = option_bar()
      und_bar = underlying_bar()

      assert :hold = ExitHandler.check_exit(position, opt_bar, und_bar)
    end

    test "respects priority order of exit conditions" do
      # Position with multiple conditions that could trigger
      position = %{
        expiration: ~D[2024-06-21],
        premium_target: Decimal.new("5.00"),
        premium_floor: nil,
        stop_loss: Decimal.new("149.00"),
        take_profit: nil,
        direction: :long
      }

      # Bar where both premium target and underlying stop are hit
      opt_bar = option_bar(high: Decimal.new("6.00"))
      und_bar = underlying_bar(low: Decimal.new("148.00"))

      # Premium target is checked before underlying stop
      assert {:exit, :premium_target, _price} = ExitHandler.check_exit(position, opt_bar, und_bar)
    end
  end

  describe "premium_target_from_multiple/2" do
    test "calculates target from multiple" do
      # Entry $5.00, target 2x = $10.00
      target = ExitHandler.premium_target_from_multiple(Decimal.new("5.00"), 2.0)
      assert Decimal.equal?(target, Decimal.new("10.0"))
    end

    test "works with fractional multiples" do
      # Entry $5.00, target 1.5x = $7.50
      target = ExitHandler.premium_target_from_multiple(Decimal.new("5.00"), 1.5)
      assert Decimal.equal?(target, Decimal.new("7.5"))
    end
  end

  describe "premium_floor_from_percentage/2" do
    test "calculates floor from percentage" do
      # Entry $5.00, keep 50% = $2.50 floor
      floor = ExitHandler.premium_floor_from_percentage(Decimal.new("5.00"), 0.5)
      assert Decimal.equal?(floor, Decimal.new("2.5"))
    end

    test "works with small percentages" do
      # Entry $5.00, keep 25% = $1.25 floor
      floor = ExitHandler.premium_floor_from_percentage(Decimal.new("5.00"), 0.25)
      assert Decimal.equal?(floor, Decimal.new("1.25"))
    end
  end
end
