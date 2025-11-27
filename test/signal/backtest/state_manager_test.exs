defmodule Signal.Backtest.StateManagerTest do
  use ExUnit.Case, async: false

  alias Signal.Backtest.StateManager
  alias Signal.Backtest.VirtualClock

  setup do
    run_id = Ecto.UUID.generate()
    symbols = ["AAPL", "TSLA"]

    on_exit(fn ->
      # Cleanup any state from the test
      StateManager.cleanup(run_id)
    end)

    %{run_id: run_id, symbols: symbols}
  end

  describe "init_backtest/3" do
    test "initializes state for a backtest run", %{run_id: run_id, symbols: symbols} do
      assert {:ok, state} = StateManager.init_backtest(run_id, symbols)

      assert state.run_id == run_id
      assert state.symbols == symbols
      assert state.clock_started == true
    end

    test "returns error if run already exists", %{run_id: run_id, symbols: symbols} do
      {:ok, _} = StateManager.init_backtest(run_id, symbols)

      assert {:error, :already_exists} = StateManager.init_backtest(run_id, symbols)
    end

    test "creates isolated BarCache when requested", %{run_id: run_id, symbols: symbols} do
      {:ok, state} = StateManager.init_backtest(run_id, symbols, with_bar_cache: true)

      assert state.bar_cache_table != nil
      assert state.bar_cache_table == :"bar_cache_backtest_#{run_id}"

      # Verify table exists
      assert :ets.info(state.bar_cache_table) != :undefined
    end
  end

  describe "get_clock/1" do
    test "returns the VirtualClock for a run", %{run_id: run_id, symbols: symbols} do
      {:ok, _} = StateManager.init_backtest(run_id, symbols)

      clock = StateManager.get_clock(run_id)
      assert clock != nil

      # Verify it's a working clock
      VirtualClock.advance(clock, ~U[2024-01-15 14:30:00Z])
      Process.sleep(10)
      assert VirtualClock.now(clock) == ~U[2024-01-15 14:30:00Z]
    end

    test "returns nil for unknown run" do
      assert StateManager.get_clock("unknown-run-id") == nil
    end
  end

  describe "get_bar_cache_table/1" do
    test "returns the ETS table name when created", %{run_id: run_id, symbols: symbols} do
      {:ok, _} = StateManager.init_backtest(run_id, symbols, with_bar_cache: true)

      table = StateManager.get_bar_cache_table(run_id)
      assert table == :"bar_cache_backtest_#{run_id}"
    end

    test "returns nil when bar cache not created", %{run_id: run_id, symbols: symbols} do
      {:ok, _} = StateManager.init_backtest(run_id, symbols, with_bar_cache: false)

      assert StateManager.get_bar_cache_table(run_id) == nil
    end
  end

  describe "cleanup/1" do
    test "stops the VirtualClock", %{run_id: run_id, symbols: symbols} do
      {:ok, _} = StateManager.init_backtest(run_id, symbols)
      clock = StateManager.get_clock(run_id)
      assert clock != nil
      assert Process.alive?(clock)

      StateManager.cleanup(run_id)

      # Clock process should no longer be alive
      refute Process.alive?(clock)
    end

    test "deletes the BarCache ETS table", %{run_id: run_id, symbols: symbols} do
      {:ok, state} = StateManager.init_backtest(run_id, symbols, with_bar_cache: true)
      table = state.bar_cache_table

      # Table exists
      assert :ets.info(table) != :undefined

      StateManager.cleanup(run_id)

      # Table should be deleted
      assert :ets.info(table) == :undefined
    end

    test "handles cleanup of non-existent run gracefully" do
      assert :ok = StateManager.cleanup("non-existent-run")
    end
  end

  describe "active_runs/0" do
    test "returns list of active run IDs", %{run_id: run_id, symbols: symbols} do
      {:ok, _} = StateManager.init_backtest(run_id, symbols)

      active = StateManager.active_runs()
      assert run_id in active
    end

    test "removes run from active list after cleanup", %{run_id: run_id, symbols: symbols} do
      {:ok, _} = StateManager.init_backtest(run_id, symbols)
      assert run_id in StateManager.active_runs()

      StateManager.cleanup(run_id)
      refute run_id in StateManager.active_runs()
    end
  end
end
