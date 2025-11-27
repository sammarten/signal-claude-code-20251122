defmodule Signal.Backtest.StateManager do
  @moduledoc """
  Manages isolated state for backtest runs.

  The StateManager creates and manages isolated instances of stateful modules
  during backtests, ensuring that backtest state doesn't interfere with live
  state and that parallel backtests are properly isolated.

  ## Isolation Strategy

  During backtests, we need to isolate:

  1. **OpeningRangeCalculator** - Tracks bar counts per symbol for OR5/OR15
     calculation. Each backtest gets its own GenServer instance.

  2. **BarCache** (optional) - For price lookups during trade simulation.
     Each backtest can have its own ETS table.

  3. **Database writes** - Scoped via `backtest_run_id` in records.

  ## Usage

      # Initialize state for a backtest
      {:ok, state} = StateManager.init_backtest(run_id, symbols)

      # Get the isolated OpeningRangeCalculator for this run
      or_calc = StateManager.get_opening_range_calculator(run_id)

      # Cleanup after backtest
      StateManager.cleanup(run_id)
  """

  use GenServer
  require Logger

  alias Signal.Backtest.VirtualClock
  alias Signal.Backtest.BarReplayer

  # Client API

  @doc """
  Starts the StateManager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initializes isolated state for a backtest run.

  Creates:
  - VirtualClock instance
  - OpeningRangeCalculator instance (if available)
  - BarCache ETS table (optional)

  ## Parameters

    * `run_id` - Unique identifier for the backtest run
    * `symbols` - List of symbols being backtested
    * `opts` - Options:
      * `:with_bar_cache` - Create isolated BarCache (default: false)

  ## Returns

    * `{:ok, state_info}` on success
    * `{:error, reason}` on failure
  """
  @spec init_backtest(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def init_backtest(run_id, symbols, opts \\ []) do
    GenServer.call(__MODULE__, {:init_backtest, run_id, symbols, opts})
  end

  @doc """
  Cleans up all state for a backtest run.

  Stops GenServers and deletes ETS tables.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(run_id) do
    GenServer.call(__MODULE__, {:cleanup, run_id})
  end

  @doc """
  Gets the VirtualClock for a backtest run.
  """
  @spec get_clock(String.t()) :: GenServer.server() | nil
  def get_clock(run_id) do
    lookup_process(run_id, :clock)
  end

  @doc """
  Gets the BarReplayer for a backtest run.
  """
  @spec get_replayer(String.t()) :: GenServer.server() | nil
  def get_replayer(run_id) do
    lookup_process(run_id, :replayer)
  end

  @doc """
  Gets the OpeningRangeCalculator for a backtest run.
  """
  @spec get_opening_range_calculator(String.t()) :: GenServer.server() | nil
  def get_opening_range_calculator(run_id) do
    lookup_process(run_id, :opening_range_calc)
  end

  @doc """
  Gets the BarCache ETS table name for a backtest run.
  """
  @spec get_bar_cache_table(String.t()) :: atom() | nil
  def get_bar_cache_table(run_id) do
    GenServer.call(__MODULE__, {:get_bar_cache_table, run_id})
  end

  @doc """
  Returns all active backtest run IDs.
  """
  @spec active_runs() :: [String.t()]
  def active_runs do
    GenServer.call(__MODULE__, :active_runs)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # State tracks all active backtest runs
    state = %{
      runs: %{}
    }

    Logger.info("[StateManager] Started")
    {:ok, state}
  end

  @impl true
  def handle_call({:init_backtest, run_id, symbols, opts}, _from, state) do
    if Map.has_key?(state.runs, run_id) do
      {:reply, {:error, :already_exists}, state}
    else
      case do_init_backtest(run_id, symbols, opts) do
        {:ok, run_state} ->
          new_state = put_in(state, [:runs, run_id], run_state)
          {:reply, {:ok, run_state}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:cleanup, run_id}, _from, state) do
    case Map.get(state.runs, run_id) do
      nil ->
        {:reply, :ok, state}

      run_state ->
        do_cleanup(run_id, run_state)
        new_state = update_in(state, [:runs], &Map.delete(&1, run_id))
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:get_bar_cache_table, run_id}, _from, state) do
    table =
      case Map.get(state.runs, run_id) do
        %{bar_cache_table: table} -> table
        _ -> nil
      end

    {:reply, table, state}
  end

  @impl true
  def handle_call(:active_runs, _from, state) do
    {:reply, Map.keys(state.runs), state}
  end

  # Private Functions

  defp do_init_backtest(run_id, symbols, opts) do
    with_bar_cache = Keyword.get(opts, :with_bar_cache, false)

    Logger.info("[StateManager] Initializing backtest #{run_id} for #{length(symbols)} symbols")

    run_state = %{
      run_id: run_id,
      symbols: symbols,
      started_at: DateTime.utc_now(),
      clock_started: false,
      replayer_started: false,
      opening_range_calc_started: false,
      bar_cache_table: nil
    }

    # Start VirtualClock
    clock_name = VirtualClock.via_tuple(run_id)

    case VirtualClock.start_link(run_id: run_id, name: clock_name) do
      {:ok, _pid} ->
        run_state = %{run_state | clock_started: true}

        # Optionally create isolated BarCache ETS table
        run_state =
          if with_bar_cache do
            table_name = :"bar_cache_backtest_#{run_id}"

            :ets.new(table_name, [
              :named_table,
              :public,
              :set,
              read_concurrency: true
            ])

            %{run_state | bar_cache_table: table_name}
          else
            run_state
          end

        # Start isolated OpeningRangeCalculator if the module exists
        run_state = maybe_start_opening_range_calculator(run_id, symbols, run_state)

        {:ok, run_state}

      {:error, reason} ->
        Logger.error("[StateManager] Failed to start VirtualClock: #{inspect(reason)}")
        {:error, {:clock_start_failed, reason}}
    end
  end

  defp maybe_start_opening_range_calculator(run_id, symbols, run_state) do
    # Check if OpeningRangeCalculator module exists and has start_link
    if Code.ensure_loaded?(Signal.Technicals.OpeningRangeCalculator) do
      name = {:via, Registry, {Signal.Backtest.Registry, {:opening_range_calc, run_id}}}

      case Signal.Technicals.OpeningRangeCalculator.start_link(
             symbols: symbols,
             name: name
           ) do
        {:ok, _pid} ->
          Logger.debug("[StateManager] Started OpeningRangeCalculator for #{run_id}")
          %{run_state | opening_range_calc_started: true}

        {:error, reason} ->
          Logger.warning(
            "[StateManager] Could not start OpeningRangeCalculator: #{inspect(reason)}"
          )

          run_state
      end
    else
      Logger.debug("[StateManager] OpeningRangeCalculator module not available")
      run_state
    end
  end

  defp do_cleanup(run_id, run_state) do
    Logger.info("[StateManager] Cleaning up backtest #{run_id}")

    # Stop VirtualClock
    if run_state.clock_started do
      case lookup_process(run_id, :clock) do
        nil -> :ok
        clock -> VirtualClock.stop(clock)
      end
    end

    # Stop BarReplayer if running
    if run_state.replayer_started do
      case lookup_process(run_id, :replayer) do
        nil -> :ok
        replayer -> BarReplayer.stop(replayer)
      end
    end

    # Stop OpeningRangeCalculator
    if run_state.opening_range_calc_started do
      case lookup_process(run_id, :opening_range_calc) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end
    end

    # Delete BarCache ETS table
    if run_state.bar_cache_table do
      try do
        :ets.delete(run_state.bar_cache_table)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp lookup_process(run_id, type) do
    case Registry.lookup(Signal.Backtest.Registry, {type, run_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
