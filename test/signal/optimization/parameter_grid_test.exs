defmodule Signal.Optimization.ParameterGridTest do
  use ExUnit.Case, async: true

  alias Signal.Optimization.ParameterGrid

  describe "new/1" do
    test "creates a grid from valid parameters" do
      params = %{
        min_confluence_score: [5, 6, 7],
        min_rr: [2.0, 2.5, 3.0]
      }

      assert {:ok, grid} = ParameterGrid.new(params)
      assert grid.total_combinations == 9
      assert length(grid.param_names) == 2
    end

    test "returns error for empty grid" do
      assert {:error, :empty_grid} = ParameterGrid.new(%{})
    end

    test "returns error for empty values list" do
      params = %{min_confluence_score: []}
      assert {:error, {:empty_values, :min_confluence_score}} = ParameterGrid.new(params)
    end

    test "returns error for non-list values" do
      params = %{min_confluence_score: 5}
      assert {:error, {:invalid_values, :min_confluence_score, _}} = ParameterGrid.new(params)
    end
  end

  describe "new!/1" do
    test "creates a grid or raises" do
      params = %{min_confluence_score: [5, 6, 7]}
      grid = ParameterGrid.new!(params)
      assert grid.total_combinations == 3
    end

    test "raises for invalid params" do
      assert_raise ArgumentError, fn ->
        ParameterGrid.new!(%{})
      end
    end
  end

  describe "count/1" do
    test "returns the total number of combinations" do
      params = %{
        a: [1, 2, 3],
        b: [4, 5],
        c: [6, 7, 8, 9]
      }

      {:ok, grid} = ParameterGrid.new(params)
      assert ParameterGrid.count(grid) == 3 * 2 * 4
    end

    test "returns correct count for single param" do
      {:ok, grid} = ParameterGrid.new(%{a: [1, 2, 3, 4, 5]})
      assert ParameterGrid.count(grid) == 5
    end
  end

  describe "combinations/1" do
    test "generates all combinations" do
      params = %{
        a: [1, 2],
        b: [:x, :y]
      }

      {:ok, grid} = ParameterGrid.new(params)
      combos = ParameterGrid.combinations(grid)

      assert length(combos) == 4

      assert %{a: 1, b: :x} in combos
      assert %{a: 1, b: :y} in combos
      assert %{a: 2, b: :x} in combos
      assert %{a: 2, b: :y} in combos
    end

    test "supports shuffle option" do
      params = %{a: Enum.to_list(1..10)}
      {:ok, grid} = ParameterGrid.new(params)

      combos1 = ParameterGrid.combinations(grid, shuffle: true)
      combos2 = ParameterGrid.combinations(grid, shuffle: true)

      # Shuffled lists should have same elements but likely different order
      assert MapSet.new(combos1) == MapSet.new(combos2)
    end

    test "supports limit option" do
      params = %{a: Enum.to_list(1..100)}
      {:ok, grid} = ParameterGrid.new(params)

      combos = ParameterGrid.combinations(grid, limit: 10)
      assert length(combos) == 10
    end
  end

  describe "stream/1" do
    test "returns a stream of combinations" do
      params = %{
        a: [1, 2, 3],
        b: [:x, :y]
      }

      {:ok, grid} = ParameterGrid.new(params)
      stream = ParameterGrid.stream(grid)

      # Stream.unfold returns an enumerable, not necessarily a Stream struct
      assert is_function(stream, 2) or is_struct(stream)

      combos = Enum.to_list(stream)
      assert length(combos) == 6
    end

    test "stream is memory efficient for large grids" do
      # Create a large grid
      params = %{
        a: Enum.to_list(1..100),
        b: Enum.to_list(1..100)
      }

      {:ok, grid} = ParameterGrid.new(params)

      # Stream should allow taking first N without generating all
      first_10 = grid |> ParameterGrid.stream() |> Enum.take(10)
      assert length(first_10) == 10
    end
  end

  describe "get_values/2" do
    test "returns values for a parameter" do
      params = %{a: [1, 2, 3], b: [:x, :y]}
      {:ok, grid} = ParameterGrid.new(params)

      assert ParameterGrid.get_values(grid, :a) == [1, 2, 3]
      assert ParameterGrid.get_values(grid, :b) == [:x, :y]
    end

    test "returns nil for unknown parameter" do
      {:ok, grid} = ParameterGrid.new(%{a: [1, 2, 3]})
      assert ParameterGrid.get_values(grid, :unknown) == nil
    end
  end

  describe "put_param/3" do
    test "adds a new parameter" do
      {:ok, grid} = ParameterGrid.new(%{a: [1, 2]})
      {:ok, updated} = ParameterGrid.put_param(grid, :b, [:x, :y, :z])

      assert ParameterGrid.count(updated) == 6
      assert ParameterGrid.get_values(updated, :b) == [:x, :y, :z]
    end

    test "updates an existing parameter" do
      {:ok, grid} = ParameterGrid.new(%{a: [1, 2]})
      {:ok, updated} = ParameterGrid.put_param(grid, :a, [1, 2, 3, 4])

      assert ParameterGrid.count(updated) == 4
    end
  end

  describe "remove_param/2" do
    test "removes a parameter" do
      {:ok, grid} = ParameterGrid.new(%{a: [1, 2], b: [:x, :y]})
      updated = ParameterGrid.remove_param(grid, :b)

      assert ParameterGrid.count(updated) == 2
      assert ParameterGrid.get_values(updated, :b) == nil
    end
  end

  describe "to_map/1 and from_map/1" do
    test "serializes and deserializes correctly" do
      params = %{
        min_confluence_score: [5, 6, 7],
        signal_grade_filter: [:all, :b_and_above, :a_only],
        risk_per_trade: [Decimal.new("0.01"), Decimal.new("0.02")]
      }

      {:ok, grid} = ParameterGrid.new(params)
      serialized = ParameterGrid.to_map(grid)

      assert is_map(serialized)
      assert is_binary(Map.keys(serialized) |> hd())

      {:ok, restored} = ParameterGrid.from_map(serialized)
      assert ParameterGrid.count(restored) == ParameterGrid.count(grid)
    end
  end

  describe "default/0" do
    test "creates a default grid" do
      grid = ParameterGrid.default()
      assert ParameterGrid.count(grid) > 0
      assert :min_confluence_score in grid.param_names
    end
  end

  describe "valid_params/0" do
    test "returns list of valid parameter names" do
      valid = ParameterGrid.valid_params()
      assert is_list(valid)
      assert :min_confluence_score in valid
      assert :risk_per_trade in valid
    end
  end
end
