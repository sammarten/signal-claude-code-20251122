defmodule Signal.Backtest.BarReplayerTest do
  use ExUnit.Case, async: false

  alias Signal.Backtest.BarReplayer
  alias Signal.Backtest.VirtualClock

  setup do
    run_id = Ecto.UUID.generate()
    {:ok, clock} = VirtualClock.start_link(run_id: run_id, name: nil)

    on_exit(fn ->
      if Process.alive?(clock), do: VirtualClock.stop(clock)
    end)

    %{run_id: run_id, clock: clock}
  end

  describe "start_link/1" do
    test "starts with required options", %{run_id: run_id, clock: clock} do
      opts = [
        run_id: run_id,
        symbols: ["AAPL"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-01-31],
        clock: clock
      ]

      {:ok, replayer} = BarReplayer.start_link(opts)
      assert Process.alive?(replayer)

      BarReplayer.stop(replayer)
    end

    test "initializes with idle status", %{run_id: run_id, clock: clock} do
      opts = [
        run_id: run_id,
        symbols: ["AAPL", "TSLA"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-01-31],
        clock: clock
      ]

      {:ok, replayer} = BarReplayer.start_link(opts)

      status = BarReplayer.status(replayer)
      assert status.status == :idle
      assert status.bars_processed == 0
      assert status.pct_complete == 0

      BarReplayer.stop(replayer)
    end
  end

  describe "status/1" do
    test "returns current replayer status", %{run_id: run_id, clock: clock} do
      opts = [
        run_id: run_id,
        symbols: ["AAPL"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-01-31],
        clock: clock,
        speed: :instant,
        session_filter: :all
      ]

      {:ok, replayer} = BarReplayer.start_link(opts)

      status = BarReplayer.status(replayer)
      assert status.status == :idle
      assert status.bars_processed == 0
      assert status.current_time == nil
      assert status.pct_complete == 0
      assert status.total_bars == nil

      BarReplayer.stop(replayer)
    end
  end

  describe "stop/1" do
    test "stops the replayer gracefully", %{run_id: run_id, clock: clock} do
      opts = [
        run_id: run_id,
        symbols: ["AAPL"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-01-31],
        clock: clock
      ]

      {:ok, replayer} = BarReplayer.start_link(opts)
      assert Process.alive?(replayer)

      :ok = BarReplayer.stop(replayer)
      refute Process.alive?(replayer)
    end
  end

  describe "via_tuple/1" do
    test "returns a via tuple for registry lookup" do
      run_id = "test-123"
      via = BarReplayer.via_tuple(run_id)
      assert {:via, Registry, {Signal.Backtest.Registry, {:replayer, "test-123"}}} = via
    end
  end
end
