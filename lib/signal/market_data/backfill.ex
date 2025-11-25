defmodule Signal.MarketData.Backfill do
  @moduledoc """
  Backfills missing market bars on application startup.

  Queries the database for the most recent bar for each symbol, then fetches
  any missing bars from the Alpaca API and persists them. This ensures data
  continuity when the application is restarted.

  ## Usage

  Called automatically by the StreamSupervisor on startup:

      Signal.MarketData.Backfill.run()

  Or for specific symbols:

      Signal.MarketData.Backfill.run(["AAPL", "TSLA"])
  """

  alias Signal.Alpaca.Client
  alias Signal.MarketData.Bar
  alias Signal.Repo

  import Ecto.Query

  require Logger

  @doc """
  Backfills missing bars for all configured symbols.

  Returns `{:ok, stats}` with counts of bars fetched per symbol.
  """
  @spec run() :: {:ok, map()} | {:error, any()}
  def run do
    symbols = Application.get_env(:signal, :symbols, [])
    run(symbols)
  end

  @doc """
  Backfills missing bars for the given symbols.

  For each symbol:
  1. Finds the most recent bar in the database
  2. Fetches bars from that time until now
  3. Persists new bars to the database

  ## Parameters

    - `symbols` - List of symbol strings to backfill

  ## Returns

    - `{:ok, %{"AAPL" => 42, "TSLA" => 38, ...}}` - Map of symbols to bar counts
    - `{:error, reason}` - If backfill fails
  """
  @spec run([String.t()]) :: {:ok, map()} | {:error, any()}
  def run([]), do: {:ok, %{}}

  def run(symbols) when is_list(symbols) do
    Logger.info("Starting bar backfill for #{length(symbols)} symbols")

    results =
      symbols
      |> Enum.map(&backfill_symbol/1)
      |> Map.new()

    total_bars = results |> Map.values() |> Enum.sum()
    Logger.info("Backfill complete: #{total_bars} total bars across #{length(symbols)} symbols")

    {:ok, results}
  end

  # Backfill a single symbol, returns {symbol, count}
  defp backfill_symbol(symbol) do
    case get_last_bar_time(symbol) do
      nil ->
        # No data at all - skip backfill (use historical loader for full loads)
        Logger.debug("No existing data for #{symbol}, skipping backfill")
        {symbol, 0}

      last_bar_time ->
        # Fetch bars from last_bar_time + 1 minute until now
        start_time = DateTime.add(last_bar_time, 60, :second)
        end_time = DateTime.utc_now()

        # Only backfill if there's a gap
        if DateTime.compare(start_time, end_time) == :lt do
          fetch_and_persist(symbol, start_time, end_time)
        else
          Logger.debug("#{symbol} is up to date")
          {symbol, 0}
        end
    end
  end

  # Get the most recent bar time for a symbol
  defp get_last_bar_time(symbol) do
    query =
      from b in Bar,
        where: b.symbol == ^symbol,
        order_by: [desc: b.bar_time],
        limit: 1,
        select: b.bar_time

    Repo.one(query)
  end

  # Fetch bars from Alpaca and persist to database
  defp fetch_and_persist(symbol, start_time, end_time) do
    Logger.info(
      "Backfilling #{symbol} from #{DateTime.to_iso8601(start_time)} to #{DateTime.to_iso8601(end_time)}"
    )

    case Client.get_bars([symbol], start: start_time, end: end_time, timeframe: "1Min") do
      {:ok, bars_map} ->
        bars = Map.get(bars_map, symbol, [])
        count = persist_bars(symbol, bars)
        Logger.info("Backfilled #{count} bars for #{symbol}")
        {symbol, count}

      {:error, reason} ->
        Logger.error("Failed to fetch bars for #{symbol}: #{inspect(reason)}")
        {symbol, 0}
    end
  end

  # Persist a list of bars to the database
  defp persist_bars(symbol, bars) do
    bars
    |> Enum.map(fn bar_data ->
      bar = Bar.from_alpaca(symbol, bar_data)

      case Repo.insert(bar,
             on_conflict: {:replace, [:open, :high, :low, :close, :volume, :vwap, :trade_count]},
             conflict_target: [:symbol, :bar_time]
           ) do
        {:ok, _} -> 1
        {:error, _} -> 0
      end
    end)
    |> Enum.sum()
  end
end
