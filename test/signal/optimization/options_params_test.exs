defmodule Signal.Optimization.OptionsParamsTest do
  use ExUnit.Case, async: true

  alias Signal.Optimization.OptionsParams
  alias Signal.Instruments.Config

  describe "default_grid/0" do
    test "returns a map with options parameters" do
      grid = OptionsParams.default_grid()

      assert is_map(grid)
      assert Map.has_key?(grid, :instrument_type)
      assert Map.has_key?(grid, :expiration_preference)
      assert Map.has_key?(grid, :strike_selection)
      assert Map.has_key?(grid, :slippage_pct)
      assert Map.has_key?(grid, :risk_per_trade)
    end

    test "instrument_type includes options" do
      grid = OptionsParams.default_grid()
      assert :options in grid.instrument_type
    end

    test "expiration_preference includes weekly and zero_dte" do
      grid = OptionsParams.default_grid()
      assert :weekly in grid.expiration_preference
      assert :zero_dte in grid.expiration_preference
    end

    test "strike_selection includes atm and one_otm" do
      grid = OptionsParams.default_grid()
      assert :atm in grid.strike_selection
      assert :one_otm in grid.strike_selection
    end
  end

  describe "comprehensive_grid/0" do
    test "includes both instrument types" do
      grid = OptionsParams.comprehensive_grid()
      assert :equity in grid.instrument_type
      assert :options in grid.instrument_type
    end

    test "includes all strike selections" do
      grid = OptionsParams.comprehensive_grid()
      assert :atm in grid.strike_selection
      assert :one_otm in grid.strike_selection
      assert :two_otm in grid.strike_selection
    end

    test "includes multiple slippage levels" do
      grid = OptionsParams.comprehensive_grid()
      assert length(grid.slippage_pct) >= 2
    end
  end

  describe "comparison_grid/0" do
    test "includes both equity and options" do
      grid = OptionsParams.comparison_grid()
      assert :equity in grid.instrument_type
      assert :options in grid.instrument_type
    end

    test "uses minimal other parameters for clean comparison" do
      grid = OptionsParams.comparison_grid()
      # Should be focused - single values for most params
      assert length(grid.expiration_preference) == 1
      assert length(grid.strike_selection) == 1
    end
  end

  describe "zero_dte_grid/0" do
    test "only includes zero_dte expiration" do
      grid = OptionsParams.zero_dte_grid()
      assert grid.expiration_preference == [:zero_dte]
    end

    test "includes options only" do
      grid = OptionsParams.zero_dte_grid()
      assert grid.instrument_type == [:options]
    end
  end

  describe "weekly_grid/0" do
    test "only includes weekly expiration" do
      grid = OptionsParams.weekly_grid()
      assert grid.expiration_preference == [:weekly]
    end

    test "includes all strike selections" do
      grid = OptionsParams.weekly_grid()
      assert :atm in grid.strike_selection
      assert :one_otm in grid.strike_selection
      assert :two_otm in grid.strike_selection
    end
  end

  describe "preset/1" do
    test "returns default grid for :default" do
      assert OptionsParams.preset(:default) == OptionsParams.default_grid()
    end

    test "returns comprehensive grid for :comprehensive" do
      assert OptionsParams.preset(:comprehensive) == OptionsParams.comprehensive_grid()
    end

    test "returns comparison grid for :comparison" do
      assert OptionsParams.preset(:comparison) == OptionsParams.comparison_grid()
    end

    test "returns zero_dte grid for :zero_dte" do
      assert OptionsParams.preset(:zero_dte) == OptionsParams.zero_dte_grid()
    end

    test "returns weekly grid for :weekly" do
      assert OptionsParams.preset(:weekly) == OptionsParams.weekly_grid()
    end

    test "conservative preset uses low risk" do
      grid = OptionsParams.preset(:conservative)
      risk_values = Enum.map(grid.risk_per_trade, &Decimal.to_float/1)
      assert Enum.all?(risk_values, &(&1 <= 0.01))
    end

    test "aggressive preset uses OTM strikes" do
      grid = OptionsParams.preset(:aggressive)
      refute :atm in grid.strike_selection
      assert :one_otm in grid.strike_selection or :two_otm in grid.strike_selection
    end
  end

  describe "custom_grid/1" do
    test "merges custom params with defaults" do
      custom =
        OptionsParams.custom_grid(%{
          expiration_preference: [:weekly]
        })

      assert custom.expiration_preference == [:weekly]
      # Should still have defaults for other params
      assert Map.has_key?(custom, :instrument_type)
      assert Map.has_key?(custom, :strike_selection)
    end

    test "custom params override defaults" do
      custom =
        OptionsParams.custom_grid(%{
          strike_selection: [:atm]
        })

      assert custom.strike_selection == [:atm]
    end
  end

  describe "to_config/1" do
    test "converts params to Config struct" do
      params = %{
        instrument_type: :options,
        expiration_preference: :weekly,
        strike_selection: :atm,
        slippage_pct: Decimal.new("0.01"),
        risk_per_trade: Decimal.new("0.01")
      }

      config = OptionsParams.to_config(params)

      assert %Config{} = config
      assert config.instrument_type == :options
      assert config.expiration_preference == :weekly
      assert config.strike_selection == :atm
    end

    test "uses defaults for missing params" do
      config = OptionsParams.to_config(%{})

      assert config.instrument_type == :options
      assert config.expiration_preference == :weekly
      assert config.strike_selection == :atm
    end

    test "handles string values for atoms" do
      params = %{
        instrument_type: "options",
        expiration_preference: "weekly",
        strike_selection: "atm"
      }

      config = OptionsParams.to_config(params)

      assert config.instrument_type == :options
      assert config.expiration_preference == :weekly
      assert config.strike_selection == :atm
    end
  end

  describe "valid_params/0" do
    test "returns list of valid parameter names" do
      params = OptionsParams.valid_params()

      assert is_list(params)
      assert :instrument_type in params
      assert :expiration_preference in params
      assert :strike_selection in params
      assert :slippage_pct in params
      assert :risk_per_trade in params
    end
  end

  describe "validate/1" do
    test "returns :ok for valid params" do
      params = %{
        instrument_type: [:options],
        expiration_preference: [:weekly]
      }

      assert :ok = OptionsParams.validate(params)
    end

    test "returns error for invalid params" do
      params = %{
        instrument_type: [:options],
        invalid_param: [:value]
      }

      assert {:error, {:invalid_params, [:invalid_param]}} = OptionsParams.validate(params)
    end
  end

  describe "combination_count/1" do
    test "calculates total combinations" do
      grid = %{
        instrument_type: [:equity, :options],
        expiration_preference: [:weekly, :zero_dte],
        strike_selection: [:atm, :one_otm, :two_otm]
      }

      # 2 * 2 * 3 = 12
      assert OptionsParams.combination_count(grid) == 12
    end

    test "handles single-value parameters" do
      grid = %{
        instrument_type: [:options],
        expiration_preference: [:weekly]
      }

      assert OptionsParams.combination_count(grid) == 1
    end
  end

  describe "grid_summary/1" do
    test "returns formatted summary string" do
      grid = %{
        instrument_type: [:options],
        expiration_preference: [:weekly]
      }

      summary = OptionsParams.grid_summary(grid)

      assert is_binary(summary)
      assert summary =~ "instrument_type"
      assert summary =~ "expiration_preference"
      assert summary =~ "Total combinations: 1"
    end
  end

  describe "merge_with_strategy/2" do
    test "merges options and strategy parameters" do
      options_grid = %{
        instrument_type: [:options],
        strike_selection: [:atm]
      }

      strategy_params = %{
        min_confluence_score: [6, 7, 8],
        min_rr: [Decimal.new("2.0"), Decimal.new("2.5")]
      }

      merged = OptionsParams.merge_with_strategy(options_grid, strategy_params)

      assert Map.has_key?(merged, :instrument_type)
      assert Map.has_key?(merged, :strike_selection)
      assert Map.has_key?(merged, :min_confluence_score)
      assert Map.has_key?(merged, :min_rr)
    end

    test "strategy params take precedence" do
      options_grid = %{
        risk_per_trade: [Decimal.new("0.01")]
      }

      strategy_params = %{
        risk_per_trade: [Decimal.new("0.02")]
      }

      merged = OptionsParams.merge_with_strategy(options_grid, strategy_params)

      assert merged.risk_per_trade == [Decimal.new("0.02")]
    end
  end
end
