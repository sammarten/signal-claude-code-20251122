defmodule Signal.Backtest.VirtualClockTest do
  use ExUnit.Case, async: true

  alias Signal.Backtest.VirtualClock

  setup do
    run_id = Ecto.UUID.generate()
    {:ok, clock} = VirtualClock.start_link(run_id: run_id, name: nil)
    on_exit(fn -> if Process.alive?(clock), do: VirtualClock.stop(clock) end)
    %{clock: clock, run_id: run_id}
  end

  describe "now/1" do
    test "returns nil when no time has been set", %{clock: clock} do
      assert VirtualClock.now(clock) == nil
    end

    test "returns the current simulated time after advance", %{clock: clock} do
      time = ~U[2024-01-15 14:30:00Z]
      VirtualClock.advance(clock, time)

      # Give the cast time to process
      Process.sleep(10)

      assert VirtualClock.now(clock) == time
    end
  end

  describe "advance/2" do
    test "updates the current time", %{clock: clock} do
      time1 = ~U[2024-01-15 14:30:00Z]
      time2 = ~U[2024-01-15 14:31:00Z]

      VirtualClock.advance(clock, time1)
      Process.sleep(10)
      assert VirtualClock.now(clock) == time1

      VirtualClock.advance(clock, time2)
      Process.sleep(10)
      assert VirtualClock.now(clock) == time2
    end
  end

  describe "today/1" do
    test "returns nil when no time set", %{clock: clock} do
      assert VirtualClock.today(clock) == nil
    end

    test "returns the date portion of current time", %{clock: clock} do
      VirtualClock.advance(clock, ~U[2024-01-15 14:30:00Z])
      Process.sleep(10)
      assert VirtualClock.today(clock) == ~D[2024-01-15]
    end
  end

  describe "today_et/1" do
    test "returns the date in Eastern Time", %{clock: clock} do
      # 3 AM UTC on Jan 16 is 10 PM ET on Jan 15
      VirtualClock.advance(clock, ~U[2024-01-16 03:00:00Z])
      Process.sleep(10)
      assert VirtualClock.today_et(clock) == ~D[2024-01-15]
    end
  end

  describe "market_open?/1" do
    test "returns false when no time set", %{clock: clock} do
      refute VirtualClock.market_open?(clock)
    end

    test "returns true during regular market hours", %{clock: clock} do
      # 2:30 PM UTC = 9:30 AM ET (market open)
      VirtualClock.advance(clock, ~U[2024-01-15 14:30:00Z])
      Process.sleep(10)
      assert VirtualClock.market_open?(clock)

      # 8 PM UTC = 3:00 PM ET (still open)
      VirtualClock.advance(clock, ~U[2024-01-15 20:00:00Z])
      Process.sleep(10)
      assert VirtualClock.market_open?(clock)
    end

    test "returns false during pre-market", %{clock: clock} do
      # 12 PM UTC = 7:00 AM ET (pre-market)
      VirtualClock.advance(clock, ~U[2024-01-15 12:00:00Z])
      Process.sleep(10)
      refute VirtualClock.market_open?(clock)
    end

    test "returns false during after-hours", %{clock: clock} do
      # 9:30 PM UTC = 4:30 PM ET (after-hours)
      VirtualClock.advance(clock, ~U[2024-01-15 21:30:00Z])
      Process.sleep(10)
      refute VirtualClock.market_open?(clock)
    end
  end

  describe "reset/1" do
    test "clears the current time", %{clock: clock} do
      VirtualClock.advance(clock, ~U[2024-01-15 14:30:00Z])
      Process.sleep(10)
      assert VirtualClock.now(clock) != nil

      VirtualClock.reset(clock)
      Process.sleep(10)
      assert VirtualClock.now(clock) == nil
    end
  end

  describe "via_tuple/1" do
    test "returns a via tuple for registry lookup" do
      run_id = "test-123"
      via = VirtualClock.via_tuple(run_id)
      assert {:via, Registry, {Signal.Backtest.Registry, {:clock, "test-123"}}} = via
    end
  end
end
