defmodule Signal.Instruments.ConfigTest do
  use ExUnit.Case, async: true

  alias Signal.Instruments.Config

  describe "new/1" do
    test "creates config with defaults" do
      config = Config.new()

      assert config.instrument_type == :options
      assert config.expiration_preference == :weekly
      assert config.strike_selection == :atm
      assert Decimal.equal?(config.risk_percentage, Decimal.new("0.01"))
      assert Decimal.equal?(config.slippage_pct, Decimal.new("0.01"))
      assert config.use_bar_open_for_entry == true
      assert config.use_bar_close_for_exit == true
    end

    test "creates config with custom instrument_type" do
      config = Config.new(instrument_type: :equity)
      assert config.instrument_type == :equity
    end

    test "creates config with custom expiration_preference" do
      config = Config.new(expiration_preference: :zero_dte)
      assert config.expiration_preference == :zero_dte
    end

    test "creates config with custom strike_selection" do
      config = Config.new(strike_selection: :one_otm)
      assert config.strike_selection == :one_otm

      config = Config.new(strike_selection: :two_otm)
      assert config.strike_selection == :two_otm
    end

    test "creates config with custom risk_percentage as Decimal" do
      config = Config.new(risk_percentage: Decimal.new("0.02"))
      assert Decimal.equal?(config.risk_percentage, Decimal.new("0.02"))
    end

    test "creates config with custom risk_percentage as number" do
      config = Config.new(risk_percentage: 0.02)
      assert Decimal.equal?(config.risk_percentage, Decimal.new("0.02"))
    end

    test "creates config with custom risk_percentage as string" do
      config = Config.new(risk_percentage: "0.02")
      assert Decimal.equal?(config.risk_percentage, Decimal.new("0.02"))
    end

    test "creates config with custom slippage_pct" do
      config = Config.new(slippage_pct: Decimal.new("0.005"))
      assert Decimal.equal?(config.slippage_pct, Decimal.new("0.005"))
    end

    test "creates config with custom bar entry/exit settings" do
      config = Config.new(use_bar_open_for_entry: false, use_bar_close_for_exit: false)
      assert config.use_bar_open_for_entry == false
      assert config.use_bar_close_for_exit == false
    end

    test "raises for invalid instrument_type" do
      assert_raise ArgumentError, fn ->
        Config.new(instrument_type: :invalid)
      end
    end

    test "raises for invalid expiration_preference" do
      assert_raise ArgumentError, fn ->
        Config.new(expiration_preference: :invalid)
      end
    end

    test "raises for invalid strike_selection" do
      assert_raise ArgumentError, fn ->
        Config.new(strike_selection: :invalid)
      end
    end
  end

  describe "equity/0" do
    test "creates equity config" do
      config = Config.equity()
      assert config.instrument_type == :equity
    end
  end

  describe "options/0" do
    test "creates options config with defaults" do
      config = Config.options()
      assert config.instrument_type == :options
      assert config.expiration_preference == :weekly
      assert config.strike_selection == :atm
    end
  end

  describe "zero_dte/1" do
    test "creates 0DTE config" do
      config = Config.zero_dte()
      assert config.instrument_type == :options
      assert config.expiration_preference == :zero_dte
    end

    test "allows custom options" do
      config = Config.zero_dte(strike_selection: :one_otm)
      assert config.expiration_preference == :zero_dte
      assert config.strike_selection == :one_otm
    end
  end

  describe "options?/1" do
    test "returns true for options config" do
      assert Config.options?(Config.options())
    end

    test "returns false for equity config" do
      refute Config.options?(Config.equity())
    end
  end

  describe "equity?/1" do
    test "returns true for equity config" do
      assert Config.equity?(Config.equity())
    end

    test "returns false for options config" do
      refute Config.equity?(Config.options())
    end
  end

  describe "zero_dte?/1" do
    test "returns true for zero_dte config" do
      assert Config.zero_dte?(Config.zero_dte())
    end

    test "returns false for weekly config" do
      refute Config.zero_dte?(Config.options())
    end
  end

  describe "to_map/1" do
    test "converts config to map" do
      config =
        Config.new(
          instrument_type: :options,
          expiration_preference: :zero_dte,
          strike_selection: :one_otm,
          risk_percentage: Decimal.new("0.02"),
          slippage_pct: Decimal.new("0.005")
        )

      map = Config.to_map(config)

      assert map.instrument_type == :options
      assert map.expiration_preference == :zero_dte
      assert map.strike_selection == :one_otm
      assert map.risk_percentage == "0.02"
      assert map.slippage_pct == "0.005"
      assert map.use_bar_open_for_entry == true
      assert map.use_bar_close_for_exit == true
    end
  end

  describe "from_map/1" do
    test "creates config from map with string keys" do
      map = %{
        "instrument_type" => "options",
        "expiration_preference" => "zero_dte",
        "strike_selection" => "one_otm",
        "risk_percentage" => "0.02",
        "slippage_pct" => "0.005",
        "use_bar_open_for_entry" => "false",
        "use_bar_close_for_exit" => "true"
      }

      config = Config.from_map(map)

      assert config.instrument_type == :options
      assert config.expiration_preference == :zero_dte
      assert config.strike_selection == :one_otm
      assert Decimal.equal?(config.risk_percentage, Decimal.new("0.02"))
      assert Decimal.equal?(config.slippage_pct, Decimal.new("0.005"))
      assert config.use_bar_open_for_entry == false
      assert config.use_bar_close_for_exit == true
    end

    test "creates config from map with atom keys" do
      map = %{
        instrument_type: :equity,
        expiration_preference: :weekly,
        strike_selection: :atm
      }

      config = Config.from_map(map)

      assert config.instrument_type == :equity
      assert config.expiration_preference == :weekly
      assert config.strike_selection == :atm
    end

    test "raises for empty map" do
      # Empty map has nil values which fail validation
      assert_raise ArgumentError, fn ->
        Config.from_map(%{})
      end
    end
  end
end
