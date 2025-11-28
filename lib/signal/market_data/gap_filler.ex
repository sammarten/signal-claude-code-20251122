defmodule Signal.MarketData.GapFiller do
  @moduledoc """
  Detects and fills gaps in market bar data.

  When the stream reconnects after a disconnection (e.g., computer sleep),
  this module detects missing bars and fetches them from Alpaca to ensure
  continuous data coverage.

  ## Features

    * Detects gaps by comparing last database bar to current time
    * Fetches missing bars from Alpaca REST API
    * Batch inserts for efficiency
    * Logs progress and results
    * Safe to run concurrently for multiple symbols

  ## Examples

      # Check and fill gaps for a single symbol
      {:ok, 15} = GapFiller.check_and_fill("AAPL")

      # Check and fill gaps for all configured symbols
      {:ok, stats} = GapFiller.check_and_fill_all()
  """

  require Logger
  alias Signal.MarketData.Bar
  alias Signal.Alpaca.Client
  alias Signal.Repo

  import Ecto.Query

  @batch_size 1000
  @max_retries 3
  @retry_delay 5000
  @max_days_per_request 30

  @doc """
  Checks for and fills data gaps for a single symbol.

  Scans the last N hours of data for gaps between consecutive bars and
  fetches any missing bars from Alpaca.

  ## Parameters

    * `symbol` - Symbol string (e.g., "AAPL")
    * `opts` - Options keyword list:
      - `:lookback_hours` - How far back to scan for gaps (default: 24)
      - `:max_gap_minutes` - Maximum single gap to fill (default: 1440)

  ## Returns

    * `{:ok, count}` - Number of bars filled
    * `{:error, reason}` - If filling fails
  """
  @spec check_and_fill(String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def check_and_fill(symbol, opts \\ []) do
    lookback_hours = Keyword.get(opts, :lookback_hours, 24)
    max_gap_minutes = Keyword.get(opts, :max_gap_minutes, 1440)

    case detect_gaps(symbol, lookback_hours) do
      {:ok, []} ->
        Logger.debug("[GapFiller] #{symbol}: No gaps detected")
        {:ok, 0}

      {:ok, gaps} ->
        Logger.info("[GapFiller] #{symbol}: Detected #{length(gaps)} gap(s)")

        # Filter out gaps that are too large or too small
        fillable_gaps =
          Enum.filter(gaps, fn {start_time, end_time} ->
            gap_minutes = DateTime.diff(end_time, start_time, :minute)
            gap_minutes > 1 and gap_minutes <= max_gap_minutes
          end)

        if Enum.empty?(fillable_gaps) do
          Logger.debug("[GapFiller] #{symbol}: No fillable gaps (all too small or too large)")
          {:ok, 0}
        else
          # Fill each gap
          total_filled =
            fillable_gaps
            |> Enum.map(fn {start_time, end_time} ->
              gap_minutes = DateTime.diff(end_time, start_time, :minute)

              Logger.info(
                "[GapFiller] #{symbol}: Filling #{gap_minutes}m gap from #{format_time(start_time)} to #{format_time(end_time)}"
              )

              case fill_gap(symbol, start_time, end_time) do
                {:ok, count} -> count
                {:error, _reason} -> 0
              end
            end)
            |> Enum.sum()

          {:ok, total_filled}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks and fills gaps for all configured symbols.

  Runs gap detection and filling for each symbol in parallel with controlled
  concurrency to respect API rate limits.

  ## Parameters

    * `opts` - Options passed to check_and_fill/2

  ## Returns

    * `{:ok, stats}` - Map of symbol => bars_filled
    * `{:error, reason}` - If operation fails
  """
  @spec check_and_fill_all(keyword()) :: {:ok, map()} | {:error, term()}
  def check_and_fill_all(opts \\ []) do
    symbols = Application.get_env(:signal, :symbols, [])

    if Enum.empty?(symbols) do
      Logger.debug("[GapFiller] No symbols configured")
      {:ok, %{}}
    else
      Logger.info("[GapFiller] Checking gaps for #{length(symbols)} symbols...")

      results =
        symbols
        |> Task.async_stream(
          fn symbol ->
            case check_and_fill(symbol, opts) do
              {:ok, count} -> {symbol, count}
              {:error, reason} -> {symbol, {:error, reason}}
            end
          end,
          max_concurrency: 5,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)
        |> Enum.into(%{})

      total_filled =
        results
        |> Map.values()
        |> Enum.filter(&is_integer/1)
        |> Enum.sum()

      if total_filled > 0 do
        Logger.info("[GapFiller] Complete - #{total_filled} total bars filled")
      end

      {:ok, results}
    end
  end

  @doc """
  Fills missing days for a symbol efficiently by batching contiguous date ranges.

  Takes a list of dates that are missing data and groups them into contiguous
  ranges, making one API call per range instead of per-day or per-gap.

  ## Parameters

    * `symbol` - Symbol string (e.g., "AAPL")
    * `missing_dates` - List of Date structs for days missing data
    * `opts` - Options keyword list:
      - `:progress_callback` - Optional function called with progress updates

  ## Returns

    * `{:ok, count}` - Number of bars filled
    * `{:error, reason}` - If filling fails

  ## Examples

      # Fill specific missing dates
      {:ok, count} = GapFiller.fill_missing_days("AAPL", [~D[2024-01-15], ~D[2024-01-16], ~D[2024-01-17]])

      # With progress callback
      {:ok, count} = GapFiller.fill_missing_days("AAPL", dates, progress_callback: fn p -> IO.inspect(p) end)
  """
  @spec fill_missing_days(String.t(), [Date.t()], keyword()) ::
          {:ok, integer()} | {:error, term()}
  def fill_missing_days(symbol, missing_dates, opts \\ []) do
    progress_callback = Keyword.get(opts, :progress_callback)

    if Enum.empty?(missing_dates) do
      {:ok, 0}
    else
      # Sort and group into contiguous ranges
      ranges = group_contiguous_dates(Enum.sort(missing_dates, Date))

      Logger.info(
        "[GapFiller] #{symbol}: Filling #{length(missing_dates)} missing days in #{length(ranges)} range(s)"
      )

      # Fill each range
      total_ranges = length(ranges)

      {total_filled, _} =
        ranges
        |> Enum.with_index(1)
        |> Enum.reduce({0, 0}, fn {{start_date, end_date}, range_idx}, {filled_acc, _} ->
          days_in_range = Date.diff(end_date, start_date) + 1

          Logger.info(
            "[GapFiller] #{symbol}: Range #{range_idx}/#{total_ranges}: #{start_date} to #{end_date} (#{days_in_range} days)"
          )

          # Split large ranges into chunks to respect API limits
          range_filled = fill_date_range(symbol, start_date, end_date)

          if progress_callback do
            progress_callback.(%{
              symbol: symbol,
              range: range_idx,
              total_ranges: total_ranges,
              bars_filled: filled_acc + range_filled
            })
          end

          {filled_acc + range_filled, range_idx}
        end)

      Logger.info(
        "[GapFiller] #{symbol}: Filled #{total_filled} bars across #{length(ranges)} range(s)"
      )

      {:ok, total_filled}
    end
  end

  @doc """
  Analyzes coverage data and fills all missing/partial days for a symbol.

  Takes coverage data (as returned by DataCoverageLive) and fills days
  that have less than the threshold percentage of data.

  ## Parameters

    * `symbol` - Symbol string
    * `coverage_data` - Map of date => %{coverage_pct: float, ...}
    * `opts` - Options:
      - `:threshold` - Fill days below this coverage % (default: 50)
      - `:progress_callback` - Optional progress function

  ## Returns

    * `{:ok, count}` - Number of bars filled
  """
  @spec fill_from_coverage(String.t(), map(), keyword()) :: {:ok, integer()} | {:error, term()}
  def fill_from_coverage(symbol, coverage_data, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 50)

    missing_dates =
      coverage_data
      |> Enum.filter(fn {_date, data} -> data.coverage_pct < threshold end)
      |> Enum.map(fn {date, _data} -> date end)

    fill_missing_days(symbol, missing_dates, opts)
  end

  # Private Functions

  defp group_contiguous_dates([]), do: []

  defp group_contiguous_dates([first | rest]) do
    {ranges, current_start, current_end} =
      Enum.reduce(rest, {[], first, first}, fn date, {ranges, start, prev_end} ->
        if Date.diff(date, prev_end) == 1 do
          # Contiguous - extend current range
          {ranges, start, date}
        else
          # Gap - close current range and start new one
          {[{start, prev_end} | ranges], date, date}
        end
      end)

    # Don't forget the last range
    [{current_start, current_end} | ranges]
    |> Enum.reverse()
  end

  defp fill_date_range(symbol, start_date, end_date) do
    # Split into chunks of @max_days_per_request to avoid API timeouts
    chunks = chunk_date_range(start_date, end_date, @max_days_per_request)

    chunks
    |> Enum.map(fn {chunk_start, chunk_end} ->
      fill_date_chunk(symbol, chunk_start, chunk_end)
    end)
    |> Enum.sum()
  end

  defp chunk_date_range(start_date, end_date, max_days) do
    total_days = Date.diff(end_date, start_date) + 1

    if total_days <= max_days do
      [{start_date, end_date}]
    else
      chunk_end = Date.add(start_date, max_days - 1)
      [{start_date, chunk_end} | chunk_date_range(Date.add(chunk_end, 1), end_date, max_days)]
    end
  end

  defp fill_date_chunk(symbol, start_date, end_date, attempt \\ 1) do
    # Convert dates to DateTimes for API call (market hours: 9:30 AM - 4:00 PM ET)
    start_dt = date_to_market_open(start_date)
    end_dt = date_to_market_close(end_date)

    case Client.get_bars(symbol, start: start_dt, end: end_dt, timeframe: "1Min") do
      {:ok, bars_by_symbol} ->
        bars = Map.get(bars_by_symbol, symbol, [])

        if Enum.empty?(bars) do
          Logger.debug("[GapFiller] #{symbol}: No bars returned for #{start_date} to #{end_date}")
          0
        else
          case store_bars(symbol, bars) do
            {:ok, count} -> count
            {:error, _} -> 0
          end
        end

      {:error, reason} when attempt < @max_retries ->
        Logger.warning(
          "[GapFiller] #{symbol}: Fetch failed for #{start_date}-#{end_date} (attempt #{attempt}/#{@max_retries}): #{inspect(reason)}"
        )

        Process.sleep(@retry_delay)
        fill_date_chunk(symbol, start_date, end_date, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "[GapFiller] #{symbol}: Failed to fetch #{start_date}-#{end_date} after #{@max_retries} attempts: #{inspect(reason)}"
        )

        0
    end
  end

  defp date_to_market_open(date) do
    # 9:30 AM ET = 14:30 UTC (during EST) or 13:30 UTC (during EDT)
    # Use 4:00 AM ET to be safe and catch pre-market if needed
    DateTime.new!(date, ~T[04:00:00], "America/New_York")
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp date_to_market_close(date) do
    # 4:00 PM ET = 21:00 UTC (during EST) or 20:00 UTC (during EDT)
    # Use 8:00 PM ET to be safe and catch after-hours if needed
    DateTime.new!(date, ~T[20:00:00], "America/New_York")
    |> DateTime.shift_zone!("Etc/UTC")
  end

  @doc false
  def detect_gaps(symbol, lookback_hours) do
    # Get bars from the lookback period, ordered by time
    cutoff = DateTime.add(DateTime.utc_now(), -lookback_hours * 3600, :second)

    bars =
      from(b in Bar,
        where: b.symbol == ^symbol,
        where: b.bar_time >= ^cutoff,
        order_by: [asc: b.bar_time],
        select: b.bar_time
      )
      |> Repo.all()

    case bars do
      [] ->
        # No bars in database for this period
        Logger.debug("[GapFiller] #{symbol}: No bars in database for lookback period")
        {:ok, []}

      [_single_bar] ->
        # Only one bar, check if there's a gap to now
        last_bar_time = List.first(bars)
        now = DateTime.utc_now()
        gap_minutes = DateTime.diff(now, last_bar_time, :minute)

        if gap_minutes > 1 do
          {:ok, [{last_bar_time, now}]}
        else
          {:ok, []}
        end

      bars ->
        # Check for gaps between consecutive bars AND gap to now
        gaps =
          bars
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.filter(fn [t1, t2] ->
            # Gap if more than 1 minute between bars
            DateTime.diff(t2, t1, :minute) > 1
          end)
          |> Enum.map(fn [t1, t2] -> {t1, t2} end)

        # Also check for gap from last bar to now
        last_bar_time = List.last(bars)
        now = DateTime.utc_now()
        gap_to_now_minutes = DateTime.diff(now, last_bar_time, :minute)

        final_gaps =
          if gap_to_now_minutes > 1 do
            gaps ++ [{last_bar_time, now}]
          else
            gaps
          end

        {:ok, final_gaps}
    end
  rescue
    error ->
      Logger.error("[GapFiller] #{symbol}: Error detecting gaps: #{inspect(error)}")
      {:error, error}
  end

  defp format_time(datetime) do
    datetime
    |> DateTime.shift_zone!("America/New_York")
    |> Calendar.strftime("%H:%M")
  end

  defp fill_gap(symbol, start_time, end_time, attempt \\ 1) do
    # Add 1 minute to start_time to avoid fetching the bar we already have
    adjusted_start = DateTime.add(start_time, 60, :second)

    case Client.get_bars(symbol, start: adjusted_start, end: end_time, timeframe: "1Min") do
      {:ok, bars_by_symbol} ->
        bars = Map.get(bars_by_symbol, symbol, [])

        if Enum.empty?(bars) do
          Logger.debug("[GapFiller] #{symbol}: No bars returned from API for gap period")
          {:ok, 0}
        else
          store_bars(symbol, bars)
        end

      {:error, reason} when attempt < @max_retries ->
        Logger.warning(
          "[GapFiller] #{symbol}: Fetch failed (attempt #{attempt}/#{@max_retries}): #{inspect(reason)}"
        )

        Process.sleep(@retry_delay)
        fill_gap(symbol, start_time, end_time, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "[GapFiller] #{symbol}: Failed after #{@max_retries} attempts: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp store_bars(symbol, bars) do
    bar_structs =
      bars
      |> Enum.map(&Bar.from_alpaca(symbol, &1))
      |> Enum.chunk_every(@batch_size)

    total_inserted =
      bar_structs
      |> Enum.map(fn batch ->
        case Repo.insert_all(Bar, Enum.map(batch, &Bar.to_map/1),
               on_conflict:
                 {:replace, [:open, :high, :low, :close, :volume, :vwap, :trade_count]},
               conflict_target: [:symbol, :bar_time]
             ) do
          {count, _} -> count
          _ -> 0
        end
      end)
      |> Enum.sum()

    Logger.info("[GapFiller] #{symbol}: Filled gap with #{total_inserted} bars")
    {:ok, total_inserted}
  rescue
    error ->
      Logger.error("[GapFiller] #{symbol}: Error storing bars: #{inspect(error)}")
      {:error, error}
  end
end
