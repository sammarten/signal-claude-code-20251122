defmodule Signal.Optimization.WalkForwardTest do
  use ExUnit.Case, async: true

  alias Signal.Optimization.WalkForward

  describe "new/1" do
    test "creates config with default values" do
      {:ok, config} = WalkForward.new()

      assert config.training_months == 12
      assert config.testing_months == 3
      assert config.step_months == 3
      assert config.optimization_metric == :profit_factor
      assert config.min_trades == 30
      assert config.anchored == false
    end

    test "creates config with custom values" do
      {:ok, config} =
        WalkForward.new(%{
          training_months: 6,
          testing_months: 2,
          step_months: 2,
          optimization_metric: :sharpe_ratio,
          min_trades: 50,
          anchored: true
        })

      assert config.training_months == 6
      assert config.testing_months == 2
      assert config.step_months == 2
      assert config.optimization_metric == :sharpe_ratio
      assert config.min_trades == 50
      assert config.anchored == true
    end

    test "returns error for invalid training_months" do
      assert {:error, {:training_months, _}} = WalkForward.new(%{training_months: 0})
      assert {:error, {:training_months, _}} = WalkForward.new(%{training_months: -1})
    end

    test "returns error for invalid testing_months" do
      assert {:error, {:testing_months, _}} = WalkForward.new(%{testing_months: 0})
    end

    test "returns error for invalid optimization_metric" do
      assert {:error, {:optimization_metric, _}} =
               WalkForward.new(%{optimization_metric: :invalid})
    end
  end

  describe "new!/1" do
    test "creates config or raises" do
      config = WalkForward.new!(%{training_months: 6})
      assert config.training_months == 6
    end

    test "raises for invalid config" do
      assert_raise ArgumentError, fn ->
        WalkForward.new!(%{training_months: 0})
      end
    end
  end

  describe "generate_windows/3" do
    test "generates correct windows for simple case" do
      {:ok, config} =
        WalkForward.new(%{
          training_months: 12,
          testing_months: 3,
          step_months: 3
        })

      start_date = ~D[2020-01-01]
      end_date = ~D[2022-12-31]

      windows = WalkForward.generate_windows(config, start_date, end_date)

      assert length(windows) > 0

      # Check first window
      first = hd(windows)
      assert first.index == 0
      {train_start, train_end} = first.training
      {test_start, test_end} = first.testing

      assert train_start == ~D[2020-01-01]
      assert Date.compare(train_end, train_start) == :gt
      assert Date.compare(test_start, train_end) == :gt
      assert Date.compare(test_end, test_start) == :gt
    end

    test "windows do not extend past end_date" do
      {:ok, config} = WalkForward.new(%{training_months: 12, testing_months: 3})

      start_date = ~D[2020-01-01]
      end_date = ~D[2021-06-30]

      windows = WalkForward.generate_windows(config, start_date, end_date)

      Enum.each(windows, fn window ->
        {_, test_end} = window.testing
        assert Date.compare(test_end, end_date) != :gt
      end)
    end

    test "step_months controls window advancement" do
      {:ok, config} =
        WalkForward.new(%{
          training_months: 6,
          testing_months: 2,
          step_months: 2
        })

      start_date = ~D[2020-01-01]
      end_date = ~D[2022-12-31]

      windows = WalkForward.generate_windows(config, start_date, end_date)

      # Check that windows advance by step_months
      if length(windows) >= 2 do
        first = Enum.at(windows, 0)
        second = Enum.at(windows, 1)

        {first_train_start, _} = first.training
        {second_train_start, _} = second.training

        # Second window should start 2 months after first
        diff_months = date_diff_months(first_train_start, second_train_start)
        assert diff_months == 2
      end
    end

    test "anchored mode keeps training start fixed" do
      {:ok, config} =
        WalkForward.new(%{
          training_months: 6,
          testing_months: 2,
          step_months: 2,
          anchored: true
        })

      start_date = ~D[2020-01-01]
      end_date = ~D[2022-12-31]

      windows = WalkForward.generate_windows(config, start_date, end_date)

      # All windows should have the same training start
      Enum.each(windows, fn window ->
        {train_start, _} = window.training
        assert train_start == start_date
      end)
    end

    test "returns empty list when insufficient data" do
      {:ok, config} = WalkForward.new(%{training_months: 24, testing_months: 6})

      start_date = ~D[2020-01-01]
      end_date = ~D[2020-12-31]

      windows = WalkForward.generate_windows(config, start_date, end_date)
      assert windows == []
    end
  end

  describe "window_count/3" do
    test "returns the number of windows" do
      {:ok, config} = WalkForward.new()

      start_date = ~D[2020-01-01]
      end_date = ~D[2024-12-31]

      count = WalkForward.window_count(config, start_date, end_date)
      windows = WalkForward.generate_windows(config, start_date, end_date)

      assert count == length(windows)
    end
  end

  describe "valid_window?/1" do
    test "returns true for valid window" do
      window = %{
        training: {~D[2020-01-01], ~D[2020-12-31]},
        testing: {~D[2021-01-01], ~D[2021-03-31]},
        index: 0
      }

      assert WalkForward.valid_window?(window)
    end

    test "returns false when training dates are invalid" do
      window = %{
        training: {~D[2020-12-31], ~D[2020-01-01]},
        testing: {~D[2021-01-01], ~D[2021-03-31]},
        index: 0
      }

      refute WalkForward.valid_window?(window)
    end

    test "returns false when test starts before training ends" do
      window = %{
        training: {~D[2020-01-01], ~D[2021-06-30]},
        testing: {~D[2021-01-01], ~D[2021-03-31]},
        index: 0
      }

      refute WalkForward.valid_window?(window)
    end
  end

  describe "to_map/1 and from_map/1" do
    test "serializes and deserializes correctly" do
      {:ok, config} =
        WalkForward.new(%{
          training_months: 9,
          testing_months: 2,
          step_months: 2,
          optimization_metric: :sharpe_ratio,
          min_trades: 40,
          anchored: true
        })

      serialized = WalkForward.to_map(config)
      assert is_map(serialized)

      {:ok, restored} = WalkForward.from_map(serialized)
      assert restored.training_months == 9
      assert restored.testing_months == 2
      assert restored.step_months == 2
      assert restored.optimization_metric == :sharpe_ratio
      assert restored.min_trades == 40
      assert restored.anchored == true
    end
  end

  describe "valid_metrics/0" do
    test "returns list of valid metrics" do
      metrics = WalkForward.valid_metrics()
      assert is_list(metrics)
      assert :profit_factor in metrics
      assert :sharpe_ratio in metrics
      assert :net_profit in metrics
    end
  end

  describe "min_data_months/1" do
    test "returns minimum required data" do
      {:ok, config} = WalkForward.new(%{training_months: 12, testing_months: 3})
      assert WalkForward.min_data_months(config) == 15
    end
  end

  # Helper function
  defp date_diff_months(date1, date2) do
    date2.year * 12 + date2.month - (date1.year * 12 + date1.month)
  end
end
