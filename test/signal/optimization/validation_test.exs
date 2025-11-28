defmodule Signal.Optimization.ValidationTest do
  use ExUnit.Case, async: true

  alias Signal.Optimization.Validation

  describe "calculate_degradation/2" do
    test "calculates positive degradation when OOS underperforms" do
      in_sample = Decimal.new("2.5")
      out_of_sample = Decimal.new("2.0")

      degradation = Validation.calculate_degradation(in_sample, out_of_sample)

      # (2.5 - 2.0) / 2.5 * 100 = 20%
      assert Decimal.compare(degradation, Decimal.new("20")) == :eq
    end

    test "calculates negative degradation when OOS outperforms" do
      in_sample = Decimal.new("2.0")
      out_of_sample = Decimal.new("2.5")

      degradation = Validation.calculate_degradation(in_sample, out_of_sample)

      # (2.0 - 2.5) / 2.0 * 100 = -25%
      assert Decimal.compare(degradation, Decimal.new("-25")) == :eq
    end

    test "returns nil for nil inputs" do
      assert Validation.calculate_degradation(nil, Decimal.new("2.0")) == nil
      assert Validation.calculate_degradation(Decimal.new("2.0"), nil) == nil
    end

    test "returns nil when in_sample is zero" do
      assert Validation.calculate_degradation(Decimal.new("0"), Decimal.new("2.0")) == nil
    end

    test "handles float inputs" do
      degradation = Validation.calculate_degradation(2.5, 2.0)
      assert Decimal.compare(degradation, Decimal.new("20")) == :eq
    end

    test "handles integer inputs" do
      degradation = Validation.calculate_degradation(100, 80)
      assert Decimal.compare(degradation, Decimal.new("20")) == :eq
    end
  end

  describe "calculate_efficiency/2" do
    test "calculates efficiency correctly" do
      in_sample = Decimal.new("2.0")
      out_of_sample = Decimal.new("1.5")

      efficiency = Validation.calculate_efficiency(in_sample, out_of_sample)

      # 1.5 / 2.0 = 0.75
      assert Decimal.compare(efficiency, Decimal.new("0.75")) == :eq
    end

    test "returns 1.0 when OOS equals IS" do
      value = Decimal.new("2.0")
      efficiency = Validation.calculate_efficiency(value, value)
      assert Decimal.compare(efficiency, Decimal.new("1")) == :eq
    end

    test "returns > 1 when OOS outperforms IS" do
      in_sample = Decimal.new("2.0")
      out_of_sample = Decimal.new("2.5")

      efficiency = Validation.calculate_efficiency(in_sample, out_of_sample)
      assert Decimal.compare(efficiency, Decimal.new("1")) == :gt
    end

    test "returns nil for nil inputs" do
      assert Validation.calculate_efficiency(nil, Decimal.new("2.0")) == nil
    end

    test "returns nil when in_sample is zero" do
      assert Validation.calculate_efficiency(Decimal.new("0"), Decimal.new("2.0")) == nil
    end
  end

  describe "validate_result/3" do
    test "validates non-overfit result" do
      in_sample = %{profit_factor: Decimal.new("2.5")}
      out_of_sample = %{profit_factor: Decimal.new("2.2")}

      {:ok, validation} = Validation.validate_result(in_sample, out_of_sample)

      # 12% degradation - not overfit
      assert validation.is_overfit == false
      assert Decimal.compare(validation.degradation_pct, Decimal.new("12")) == :eq
    end

    test "flags overfit result with high degradation" do
      in_sample = %{profit_factor: Decimal.new("3.0")}
      out_of_sample = %{profit_factor: Decimal.new("1.5")}

      {:ok, validation} = Validation.validate_result(in_sample, out_of_sample)

      # 50% degradation - overfit
      assert validation.is_overfit == true
      assert Decimal.compare(validation.degradation_pct, Decimal.new("50")) == :eq
    end

    test "flags overfit result with low efficiency" do
      in_sample = %{profit_factor: Decimal.new("3.0")}
      out_of_sample = %{profit_factor: Decimal.new("1.2")}

      {:ok, validation} = Validation.validate_result(in_sample, out_of_sample)

      # Efficiency = 1.2/3.0 = 0.4 < 0.5 threshold
      assert validation.is_overfit == true
      assert Decimal.compare(validation.walk_forward_efficiency, Decimal.new("0.4")) == :eq
    end

    test "uses custom metric" do
      in_sample = %{sharpe_ratio: Decimal.new("1.8")}
      out_of_sample = %{sharpe_ratio: Decimal.new("1.5")}

      {:ok, validation} = Validation.validate_result(in_sample, out_of_sample, :sharpe_ratio)

      assert validation.in_sample_metric == Decimal.new("1.8")
      assert validation.out_of_sample_metric == Decimal.new("1.5")
    end
  end

  describe "analyze_walk_forward/2" do
    test "analyzes window results" do
      window_results = [
        %{
          best_training: %{
            parameters: %{min_confluence: 7},
            profit_factor: Decimal.new("2.5"),
            net_profit: Decimal.new("5000"),
            win_rate: Decimal.new("65"),
            total_trades: 50
          },
          oos_result: %{
            parameters: %{min_confluence: 7},
            profit_factor: Decimal.new("2.2"),
            net_profit: Decimal.new("4000"),
            win_rate: Decimal.new("62"),
            total_trades: 40
          }
        },
        %{
          best_training: %{
            parameters: %{min_confluence: 7},
            profit_factor: Decimal.new("2.3"),
            net_profit: Decimal.new("4500"),
            win_rate: Decimal.new("63"),
            total_trades: 45
          },
          oos_result: %{
            parameters: %{min_confluence: 7},
            profit_factor: Decimal.new("2.0"),
            net_profit: Decimal.new("3500"),
            win_rate: Decimal.new("60"),
            total_trades: 35
          }
        }
      ]

      results = Validation.analyze_walk_forward(window_results, :profit_factor)

      assert length(results) == 1
      [result] = results

      assert result.params == %{min_confluence: 7}
      assert result.oos_total_trades == 75
      refute is_nil(result.oos_profit_factor)
      refute is_nil(result.oos_net_profit)
    end

    test "filters out windows with nil best_training" do
      window_results = [
        %{best_training: nil, oos_result: nil},
        %{
          best_training: %{
            parameters: %{a: 1},
            profit_factor: Decimal.new("2.0"),
            total_trades: 30
          },
          oos_result: %{
            profit_factor: Decimal.new("1.8"),
            total_trades: 25
          }
        }
      ]

      results = Validation.analyze_walk_forward(window_results)
      assert length(results) == 1
    end
  end

  describe "best_params/1" do
    test "returns best non-overfit params" do
      validation_results = [
        %{
          params: %{a: 1},
          is_overfit: true,
          oos_profit_factor: Decimal.new("3.0")
        },
        %{
          params: %{a: 2},
          is_overfit: false,
          oos_profit_factor: Decimal.new("2.5")
        },
        %{
          params: %{a: 3},
          is_overfit: false,
          oos_profit_factor: Decimal.new("2.0")
        }
      ]

      best = Validation.best_params(validation_results)

      # Should return params with highest OOS profit_factor that's not overfit
      assert best == %{a: 2}
    end

    test "returns nil when all results are overfit" do
      validation_results = [
        %{params: %{a: 1}, is_overfit: true, oos_profit_factor: Decimal.new("3.0")},
        %{params: %{a: 2}, is_overfit: true, oos_profit_factor: Decimal.new("2.5")}
      ]

      assert Validation.best_params(validation_results) == nil
    end

    test "returns nil for empty results" do
      assert Validation.best_params([]) == nil
    end
  end

  describe "best_result/1" do
    test "returns the full validation result" do
      validation_results = [
        %{
          params: %{a: 1},
          is_overfit: false,
          oos_profit_factor: Decimal.new("2.5"),
          degradation_pct: Decimal.new("15")
        },
        %{
          params: %{a: 2},
          is_overfit: false,
          oos_profit_factor: Decimal.new("2.0"),
          degradation_pct: Decimal.new("10")
        }
      ]

      result = Validation.best_result(validation_results)

      assert result.params == %{a: 1}
      assert result.degradation_pct == Decimal.new("15")
    end
  end

  describe "filter_valid/1" do
    test "filters out overfit results" do
      validation_results = [
        %{params: %{a: 1}, is_overfit: true},
        %{params: %{a: 2}, is_overfit: false},
        %{params: %{a: 3}, is_overfit: true},
        %{params: %{a: 4}, is_overfit: false}
      ]

      valid = Validation.filter_valid(validation_results)

      assert length(valid) == 2
      assert Enum.all?(valid, &(!&1.is_overfit))
    end
  end

  describe "overfit_threshold/0" do
    test "returns the threshold value" do
      threshold = Validation.overfit_threshold()
      assert threshold == 0.30
    end
  end

  describe "min_efficiency/0" do
    test "returns the minimum efficiency value" do
      min_eff = Validation.min_efficiency()
      assert min_eff == 0.50
    end
  end
end
