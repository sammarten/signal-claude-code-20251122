defmodule Signal.Backtest.BarReplayer do
  @moduledoc """
  Streams historical bars chronologically to PubSub topics.

  The BarReplayer queries historical bars from the database and broadcasts
  them to the same PubSub topics used by live streaming. This allows Phase 2
  modules (OpeningRangeCalculator, signal generators, etc.) to receive bars
  unchanged during backtests.

  ## Features

    * Multi-symbol synchronization by timestamp
    * Speed control (`:instant` for optimization, `:realtime` for visualization)
    * Progress callbacks for UI updates
    * Session filtering (regular hours only, or include extended hours)

  ## Usage

      {:ok, replayer} = BarReplayer.start_link(
        run_id: "abc123",
        symbols: ["AAPL", "TSLA"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-01-31],
        clock: clock_pid,
        speed: :instant
      )

      # Start replaying
      BarReplayer.start_replay(replayer)

      # Or with a callback for progress
      BarReplayer.start_replay(replayer, fn progress ->
        IO.puts("Progress: \#{progress.bars_processed}/\#{progress.total_bars}")
      end)
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias Signal.MarketData.Bar
  alias Signal.Repo
  alias Signal.Backtest.VirtualClock

  @batch_size 1000
  @progress_interval 1000

  # Client API

  @doc """
  Starts a BarReplayer for a backtest run.

  ## Options

    * `:run_id` - The backtest run ID (required)
    * `:symbols` - List of symbols to replay (required)
    * `:start_date` - Start date for replay (required)
    * `:end_date` - End date for replay (required)
    * `:clock` - VirtualClock server (required)
    * `:speed` - `:instant` or `:realtime` (default: `:instant`)
    * `:session_filter` - `:all` or `:regular` (default: `:regular`)
    * `:name` - Optional GenServer name
  """
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    name = Keyword.get(opts, :name, via_tuple(run_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts the bar replay process.

  Optionally accepts a progress callback function that receives a map with:
    * `:bars_processed` - Number of bars processed so far
    * `:total_bars` - Total bars to process
    * `:current_time` - Current simulated time
    * `:pct_complete` - Percentage complete (0-100)
  """
  @spec start_replay(GenServer.server(), function() | nil) :: :ok
  def start_replay(replayer, progress_callback \\ nil) do
    GenServer.cast(replayer, {:start_replay, progress_callback})
  end

  @doc """
  Pauses the replay.
  """
  @spec pause(GenServer.server()) :: :ok
  def pause(replayer) do
    GenServer.cast(replayer, :pause)
  end

  @doc """
  Resumes a paused replay.
  """
  @spec resume(GenServer.server()) :: :ok
  def resume(replayer) do
    GenServer.cast(replayer, :resume)
  end

  @doc """
  Stops the replayer.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(replayer) do
    GenServer.stop(replayer, :normal)
  end

  @doc """
  Returns the current replay status.
  """
  @spec status(GenServer.server()) :: map()
  def status(replayer) do
    GenServer.call(replayer, :status)
  end

  @doc """
  Returns the Registry via tuple for a run_id.
  """
  def via_tuple(run_id) do
    {:via, Registry, {Signal.Backtest.Registry, {:replayer, run_id}}}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    symbols = Keyword.fetch!(opts, :symbols)
    start_date = Keyword.fetch!(opts, :start_date)
    end_date = Keyword.fetch!(opts, :end_date)
    clock = Keyword.fetch!(opts, :clock)
    speed = Keyword.get(opts, :speed, :instant)
    session_filter = Keyword.get(opts, :session_filter, :regular)

    state = %{
      run_id: run_id,
      symbols: symbols,
      start_date: start_date,
      end_date: end_date,
      clock: clock,
      speed: speed,
      session_filter: session_filter,
      status: :idle,
      bars_processed: 0,
      total_bars: nil,
      progress_callback: nil,
      current_time: nil
    }

    Logger.debug("[BarReplayer] Started for run #{run_id}, symbols: #{inspect(symbols)}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:start_replay, progress_callback}, state) do
    # Count total bars for progress tracking
    total_bars = count_bars(state)

    new_state = %{
      state
      | status: :running,
        total_bars: total_bars,
        progress_callback: progress_callback,
        bars_processed: 0
    }

    Logger.info(
      "[BarReplayer] Starting replay of #{total_bars} bars for #{length(state.symbols)} symbols"
    )

    # Start the replay in a separate process to not block the GenServer
    send(self(), :replay_batch)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:pause, state) do
    {:noreply, %{state | status: :paused}}
  end

  @impl true
  def handle_cast(:resume, %{status: :paused} = state) do
    send(self(), :replay_batch)
    {:noreply, %{state | status: :running}}
  end

  @impl true
  def handle_cast(:resume, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      status: state.status,
      bars_processed: state.bars_processed,
      total_bars: state.total_bars,
      current_time: state.current_time,
      pct_complete: calculate_progress(state)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:replay_batch, %{status: :paused} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:replay_batch, %{status: :running} = state) do
    # Get the next batch of bars
    offset = state.bars_processed

    bars =
      query_bars(state, offset, @batch_size)
      |> Repo.all()

    if Enum.empty?(bars) do
      # Replay complete
      Logger.info("[BarReplayer] Replay complete. Processed #{state.bars_processed} bars.")

      notify_progress(state)
      {:noreply, %{state | status: :completed}}
    else
      # Process this batch
      new_state = process_batch(bars, state)

      # Schedule next batch
      send(self(), :replay_batch)

      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:replay_batch, state) do
    {:noreply, state}
  end

  # Private Functions

  defp count_bars(state) do
    query =
      from b in Bar,
        where: b.symbol in ^state.symbols,
        where: b.date >= ^state.start_date,
        where: b.date <= ^state.end_date,
        select: count(b.bar_time)

    # Filter by session if requested
    query =
      case state.session_filter do
        :regular -> where(query, [b], b.session == :regular)
        :all -> query
      end

    Repo.one(query)
  end

  defp query_bars(state, query_offset, query_limit) do
    query =
      from b in Bar,
        where: b.symbol in ^state.symbols,
        where: b.date >= ^state.start_date,
        where: b.date <= ^state.end_date,
        order_by: [asc: b.bar_time, asc: b.symbol]

    # Filter by session if requested
    query =
      case state.session_filter do
        :regular -> where(query, [b], b.session == :regular)
        :all -> query
      end

    # Apply offset and limit
    query = offset(query, ^query_offset)

    if query_limit do
      limit(query, ^query_limit)
    else
      query
    end
  end

  defp process_batch(bars, state) do
    # Group bars by timestamp for synchronized replay
    bars_by_time =
      bars
      |> Enum.group_by(& &1.bar_time)
      |> Enum.sort_by(fn {time, _} -> time end, DateTime)

    # Process each timestamp group
    Enum.reduce(bars_by_time, state, fn {timestamp, bars_at_time}, acc_state ->
      # Advance the virtual clock
      VirtualClock.advance(state.clock, timestamp)

      # Broadcast each bar to PubSub
      Enum.each(bars_at_time, fn bar ->
        broadcast_bar(bar)
      end)

      # Update processed count
      new_processed = acc_state.bars_processed + length(bars_at_time)

      # Maybe notify progress
      new_state = %{
        acc_state
        | bars_processed: new_processed,
          current_time: timestamp
      }

      if rem(new_processed, @progress_interval) == 0 do
        notify_progress(new_state)
      end

      new_state
    end)
  end

  defp broadcast_bar(bar) do
    # Convert bar to the format expected by subscribers
    bar_data = %{
      symbol: bar.symbol,
      timestamp: bar.bar_time,
      open: bar.open,
      high: bar.high,
      low: bar.low,
      close: bar.close,
      volume: bar.volume,
      vwap: bar.vwap,
      trade_count: bar.trade_count
    }

    # Broadcast to the same topic used by live streaming
    Phoenix.PubSub.broadcast(
      Signal.PubSub,
      "bars:#{bar.symbol}",
      {:bar, bar.symbol, bar_data}
    )
  end

  defp notify_progress(%{progress_callback: nil}), do: :ok

  defp notify_progress(state) do
    if state.progress_callback do
      progress = %{
        bars_processed: state.bars_processed,
        total_bars: state.total_bars,
        current_time: state.current_time,
        pct_complete: calculate_progress(state)
      }

      state.progress_callback.(progress)
    end
  end

  defp calculate_progress(%{total_bars: nil}), do: 0.0
  defp calculate_progress(%{total_bars: 0}), do: 100.0

  defp calculate_progress(%{bars_processed: processed, total_bars: total}) do
    Float.round(processed / total * 100, 2)
  end
end
