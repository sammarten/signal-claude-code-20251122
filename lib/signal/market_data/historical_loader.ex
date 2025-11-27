defmodule Signal.MarketData.HistoricalLoader do
  @moduledoc """
  Downloads and stores historical market bar data from Alpaca Markets.

  Provides functions to download historical 1-minute bars from Alpaca's REST API
  and store them in TimescaleDB. Features incremental year-by-year loading for
  resumability, batch inserts for efficiency, and parallel loading for multiple symbols.

  ## Features

    * Year-by-year incremental loading (resumable if interrupted)
    * Automatic detection of already-loaded data
    * Batch inserts (1000 bars per insert) for efficiency
    * Parallel loading with rate limit respect (max 5 concurrent)
    * Comprehensive progress logging
    * Idempotent operations (safe to re-run)

  ## Examples

      # Load specific symbol for 5 years
      {:ok, stats} = HistoricalLoader.load_bars("AAPL", ~D[2019-01-01], ~D[2024-01-01])

      # Load all configured symbols
      {:ok, total} = HistoricalLoader.load_all(~D[2019-01-01], ~D[2024-01-01])

      # Check coverage for a symbol
      {:ok, report} = HistoricalLoader.check_coverage("AAPL", {~D[2019-01-01], ~D[2024-01-01]})
  """

  require Logger
  alias Signal.Data.HistoricalFetchJob
  alias Signal.MarketData.Bar
  alias Signal.Alpaca.Client
  alias Signal.Repo

  import Ecto.Query

  @batch_size 1000
  @max_retries 3
  @retry_delay 5000
  @max_concurrency 5

  # Job Management Functions

  @doc """
  Creates a new historical fetch job record.

  Jobs track progress for resume capability. Returns the job ID.

  ## Parameters

    * `symbol` - The symbol to fetch
    * `start_date` - Start date of the range
    * `end_date` - End date of the range

  ## Returns

    * `{:ok, job}` - The created job record
    * `{:error, changeset}` - If creation fails
  """
  @spec start_job(String.t(), Date.t(), Date.t()) ::
          {:ok, HistoricalFetchJob.t()} | {:error, Ecto.Changeset.t()}
  def start_job(symbol, start_date, end_date) do
    %HistoricalFetchJob{}
    |> HistoricalFetchJob.changeset(%{
      symbol: symbol,
      start_date: start_date,
      end_date: end_date,
      status: "pending"
    })
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :status,
           :bars_loaded,
           :last_bar_time,
           :error_message,
           :started_at,
           :completed_at,
           :updated_at
         ]},
      conflict_target: [:symbol, :start_date, :end_date],
      returning: true
    )
  end

  @doc """
  Updates job progress with the last processed bar time and count.

  Called periodically during data loading to enable resume from failure.

  ## Parameters

    * `job` - The job record to update
    * `last_bar_time` - DateTime of the last successfully stored bar
    * `bars_loaded` - Total bars loaded so far

  ## Returns

    * `{:ok, job}` - The updated job record
    * `{:error, changeset}` - If update fails
  """
  @spec update_job_progress(HistoricalFetchJob.t(), DateTime.t(), integer()) ::
          {:ok, HistoricalFetchJob.t()} | {:error, Ecto.Changeset.t()}
  def update_job_progress(job, last_bar_time, bars_loaded) do
    job
    |> HistoricalFetchJob.progress_changeset(%{
      last_bar_time: last_bar_time,
      bars_loaded: bars_loaded,
      status: "running"
    })
    |> Repo.update()
  end

  @doc """
  Marks a job as complete.

  ## Parameters

    * `job` - The job record to complete
    * `total_bars` - Final count of bars loaded

  ## Returns

    * `{:ok, job}` - The completed job record
  """
  @spec complete_job(HistoricalFetchJob.t(), integer()) ::
          {:ok, HistoricalFetchJob.t()} | {:error, Ecto.Changeset.t()}
  def complete_job(job, total_bars) do
    job
    |> HistoricalFetchJob.complete_changeset(total_bars)
    |> Repo.update()
  end

  @doc """
  Marks a job as failed with an error message.

  The last_bar_time is preserved for resume capability.

  ## Parameters

    * `job` - The job record to mark as failed
    * `error_message` - Description of the failure

  ## Returns

    * `{:ok, job}` - The failed job record
  """
  @spec fail_job(HistoricalFetchJob.t(), String.t()) ::
          {:ok, HistoricalFetchJob.t()} | {:error, Ecto.Changeset.t()}
  def fail_job(job, error_message) do
    job
    |> HistoricalFetchJob.fail_changeset(error_message)
    |> Repo.update()
  end

  @doc """
  Gets the status of a job for a specific symbol and date range.

  ## Parameters

    * `symbol` - The symbol
    * `start_date` - Start date
    * `end_date` - End date

  ## Returns

    * `{:ok, job}` - The job record if found
    * `{:error, :not_found}` - If no job exists
  """
  @spec get_job_status(String.t(), Date.t(), Date.t()) ::
          {:ok, HistoricalFetchJob.t()} | {:error, :not_found}
  def get_job_status(symbol, start_date, end_date) do
    query =
      from j in HistoricalFetchJob,
        where: j.symbol == ^symbol,
        where: j.start_date == ^start_date,
        where: j.end_date == ^end_date

    case Repo.one(query) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  @doc """
  Finds all incomplete jobs (running or failed) and returns them for resume.

  ## Returns

    * `{:ok, jobs}` - List of incomplete job records
  """
  @spec get_incomplete_jobs() :: {:ok, [HistoricalFetchJob.t()]}
  def get_incomplete_jobs do
    query =
      from j in HistoricalFetchJob,
        where: j.status in ["running", "failed", "pending"],
        order_by: [asc: j.symbol, asc: j.start_date]

    {:ok, Repo.all(query)}
  end

  @doc """
  Resumes all incomplete jobs.

  Finds jobs with status 'running' or 'failed' and resumes loading
  from the last_bar_time.

  ## Returns

    * `{:ok, results}` - Map of symbol => bars loaded for each resumed job
    * `{:error, reason}` - If resume fails
  """
  @spec resume_incomplete() :: {:ok, map()} | {:error, term()}
  def resume_incomplete do
    {:ok, jobs} = get_incomplete_jobs()

    if Enum.empty?(jobs) do
      Logger.info("[HistoricalLoader] No incomplete jobs to resume")
      {:ok, %{}}
    else
      Logger.info("[HistoricalLoader] Resuming #{length(jobs)} incomplete jobs")

      results =
        jobs
        |> Enum.map(&resume_job/1)
        |> Enum.into(%{})

      {:ok, results}
    end
  end

  defp resume_job(job) do
    Logger.info(
      "[HistoricalLoader] Resuming #{job.symbol} from #{job.last_bar_time || job.start_date}"
    )

    # Determine start point for resume
    resume_from =
      if job.last_bar_time do
        # Add 1 minute to avoid re-fetching the last bar
        DateTime.add(job.last_bar_time, 60, :second)
      else
        DateTime.new!(job.start_date, ~T[00:00:00], "Etc/UTC")
      end

    end_datetime = DateTime.new!(job.end_date, ~T[23:59:59], "Etc/UTC")

    # Mark as running
    {:ok, job} = Repo.update(HistoricalFetchJob.start_changeset(job))

    case fetch_and_store_bars_with_tracking(job, resume_from, end_datetime) do
      {:ok, count} ->
        {:ok, _} = complete_job(job, job.bars_loaded + count)

        Logger.info(
          "[HistoricalLoader] #{job.symbol}: Resume complete - #{count} additional bars"
        )

        {job.symbol, count}

      {:error, reason} ->
        {:ok, _} = fail_job(job, inspect(reason))
        Logger.error("[HistoricalLoader] #{job.symbol}: Resume failed - #{inspect(reason)}")
        {job.symbol, 0}
    end
  end

  defp fetch_and_store_bars_with_tracking(job, start_datetime, end_datetime, attempt \\ 1) do
    case Client.get_bars(job.symbol, start: start_datetime, end: end_datetime, timeframe: "1Min") do
      {:ok, bars_by_symbol} ->
        bars = Map.get(bars_by_symbol, job.symbol, [])

        if Enum.empty?(bars) do
          {:ok, 0}
        else
          # Convert to Bar structs
          bar_structs = Enum.map(bars, &Bar.from_alpaca(job.symbol, &1))

          # Batch insert with progress tracking
          count = batch_insert_bars_with_tracking(job, bar_structs)
          {:ok, count}
        end

      {:error, reason} when attempt < @max_retries ->
        Logger.warning(
          "[HistoricalLoader] #{job.symbol}: Fetch failed (attempt #{attempt}/#{@max_retries}), " <>
            "retrying in #{@retry_delay}ms: #{inspect(reason)}"
        )

        Process.sleep(@retry_delay)
        fetch_and_store_bars_with_tracking(job, start_datetime, end_datetime, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_insert_bars_with_tracking(job, bars) do
    bars
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, acc ->
      maps = Enum.map(batch, &Bar.to_map/1)

      {count, _} =
        Repo.insert_all(Bar, maps,
          on_conflict: :nothing,
          conflict_target: [:symbol, :bar_time]
        )

      new_total = acc + count

      # Update progress after each batch
      if last_bar = List.last(batch) do
        update_job_progress(job, last_bar.bar_time, job.bars_loaded + new_total)
      end

      new_total
    end)
  end

  @doc """
  Loads historical bars for one or more symbols within a date range.

  Downloads bars year-by-year to enable resumability. Checks for existing
  data before downloading to avoid duplicates. Logs progress for each year.

  ## Parameters

    * `symbols` - A single symbol string or list of symbol strings
    * `start_date` - Start date (Date or DateTime)
    * `end_date` - End date (Date or DateTime), defaults to today

  ## Returns

    * `{:ok, stats}` - Map of symbol => count of new bars loaded
    * `{:error, reason}` - If loading fails

  ## Examples

      # Single symbol
      {:ok, %{"AAPL" => 294_257}} = load_bars("AAPL", ~D[2019-01-01], ~D[2024-01-01])

      # Multiple symbols
      {:ok, stats} = load_bars(["AAPL", "TSLA"], ~D[2023-01-01], ~D[2024-01-01])
  """
  @spec load_bars(String.t() | [String.t()], Date.t() | DateTime.t(), Date.t() | DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def load_bars(symbols, start_date, end_date \\ Date.utc_today())

  def load_bars(symbol, start_date, end_date) when is_binary(symbol) do
    load_bars([symbol], start_date, end_date)
  end

  def load_bars(symbols, start_date, end_date) when is_list(symbols) do
    start_date = normalize_date(start_date)
    end_date = normalize_date(end_date)

    Logger.info(
      "[HistoricalLoader] Loading #{length(symbols)} symbols from #{start_date} to #{end_date}"
    )

    results =
      symbols
      |> Enum.map(&load_symbol_bars(&1, start_date, end_date))
      |> Enum.into(%{})

    total_bars = results |> Map.values() |> Enum.sum()
    Logger.info("[HistoricalLoader] Complete - #{total_bars} total bars loaded")

    {:ok, results}
  rescue
    error ->
      Logger.error("[HistoricalLoader] Load failed: #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Loads historical bars for all configured symbols.

  Retrieves the symbol list from application configuration and loads bars
  for each symbol in parallel (max 5 concurrent to respect rate limits).

  ## Parameters

    * `start_date` - Start date (Date or DateTime)
    * `end_date` - End date (Date or DateTime), defaults to today

  ## Returns

    * `{:ok, total_count}` - Total number of bars loaded across all symbols
    * `{:error, reason}` - If loading fails

  ## Examples

      {:ok, 4_234_567} = load_all(~D[2019-01-01], ~D[2024-01-01])
  """
  @spec load_all(Date.t() | DateTime.t(), Date.t() | DateTime.t()) ::
          {:ok, integer()} | {:error, term()}
  def load_all(start_date, end_date \\ Date.utc_today()) do
    symbols = Application.get_env(:signal, :symbols, [])

    if Enum.empty?(symbols) do
      Logger.warning("[HistoricalLoader] No symbols configured")
      {:ok, 0}
    else
      Logger.info(
        "[HistoricalLoader] Loading #{length(symbols)} symbols in parallel (max #{@max_concurrency} concurrent)"
      )

      start_time = System.monotonic_time(:second)

      results =
        symbols
        |> Task.async_stream(
          fn symbol ->
            load_symbol_bars(symbol, normalize_date(start_date), normalize_date(end_date))
          end,
          max_concurrency: @max_concurrency,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, {_symbol, count}} -> count end)
        |> Enum.sum()

      elapsed = System.monotonic_time(:second) - start_time
      rate = if elapsed > 0, do: div(results, elapsed), else: 0

      Logger.info(
        "[HistoricalLoader] Summary: #{results} total bars in #{format_duration(elapsed)}, avg #{rate} bars/sec"
      )

      {:ok, results}
    end
  end

  @doc """
  Checks data coverage for a symbol within a date range.

  Analyzes existing data in the database to determine which years have data,
  which are missing, and calculates coverage percentage.

  ## Parameters

    * `symbol` - The symbol to check as a string
    * `date_range` - Tuple of {start_date, end_date}

  ## Returns

    * `{:ok, report}` - Coverage report map with keys:
      - `:bars_count` - Total number of bars
      - `:years_with_data` - List of years that have data
      - `:missing_years` - List of years missing data
      - `:coverage_pct` - Percentage of expected years with data

  ## Examples

      {:ok, report} = check_coverage("AAPL", {~D[2019-01-01], ~D[2024-01-01]})
      # => %{bars_count: 487_234, years_with_data: [2022, 2023, 2024], missing_years: [2019, 2020, 2021], coverage_pct: 60.0}
  """
  @spec check_coverage(String.t(), {Date.t(), Date.t()}) :: {:ok, map()} | {:error, term()}
  def check_coverage(symbol, {start_date, end_date}) do
    start_date = normalize_date(start_date)
    end_date = normalize_date(end_date)

    query =
      from b in Bar,
        where: b.symbol == ^symbol,
        where: b.bar_time >= ^DateTime.new!(start_date, ~T[00:00:00]),
        where: b.bar_time <= ^DateTime.new!(end_date, ~T[23:59:59]),
        select: %{
          year: fragment("EXTRACT(YEAR FROM ?)", b.bar_time),
          count: count(b.bar_time)
        },
        group_by: fragment("EXTRACT(YEAR FROM ?)", b.bar_time),
        order_by: fragment("EXTRACT(YEAR FROM ?)", b.bar_time)

    years_with_data =
      Repo.all(query)
      |> Enum.map(fn %{year: year} ->
        cond do
          is_integer(year) -> year
          is_float(year) -> trunc(year)
          is_struct(year, Decimal) -> Decimal.to_integer(year)
          true -> year
        end
      end)

    total_bars =
      from(b in Bar,
        where: b.symbol == ^symbol,
        where: b.bar_time >= ^DateTime.new!(start_date, ~T[00:00:00]),
        where: b.bar_time <= ^DateTime.new!(end_date, ~T[23:59:59]),
        select: count(b.bar_time)
      )
      |> Repo.one()

    expected_years = start_date.year..end_date.year |> Enum.to_list()
    missing_years = expected_years -- years_with_data

    coverage_pct =
      if length(expected_years) > 0 do
        Float.round(length(years_with_data) / length(expected_years) * 100, 1)
      else
        0.0
      end

    {:ok,
     %{
       bars_count: total_bars || 0,
       years_with_data: years_with_data,
       missing_years: missing_years,
       coverage_pct: coverage_pct
     }}
  end

  # Private Functions

  defp load_symbol_bars(symbol, start_date, end_date) do
    Logger.info("[HistoricalLoader] Loading #{symbol} from #{start_date} to #{end_date}...")

    # Check existing coverage
    {:ok, coverage} = check_coverage(symbol, {start_date, end_date})

    if Enum.empty?(coverage.missing_years) do
      Logger.info("[HistoricalLoader] #{symbol}: Already complete (#{coverage.bars_count} bars)")
      {symbol, 0}
    else
      Logger.info(
        "[HistoricalLoader] #{symbol}: Found #{coverage.bars_count} bars (#{inspect(coverage.years_with_data)}), " <>
          "missing: #{inspect(coverage.missing_years)}"
      )

      total_loaded =
        coverage.missing_years
        |> Enum.map(&load_year(symbol, &1))
        |> Enum.sum()

      Logger.info("[HistoricalLoader] #{symbol}: Complete - #{total_loaded} new bars loaded")
      {symbol, total_loaded}
    end
  end

  defp load_year(symbol, year) do
    start_datetime = DateTime.new!(Date.new!(year, 1, 1), ~T[00:00:00], "Etc/UTC")

    end_datetime =
      if year == Date.utc_today().year do
        DateTime.utc_now()
      else
        DateTime.new!(Date.new!(year, 12, 31), ~T[23:59:59], "Etc/UTC")
      end

    year_start = System.monotonic_time(:millisecond)

    case fetch_and_store_bars(symbol, start_datetime, end_datetime) do
      {:ok, count} ->
        elapsed_ms = System.monotonic_time(:millisecond) - year_start
        elapsed_sec = Float.round(elapsed_ms / 1000, 1)

        Logger.info(
          "[HistoricalLoader] #{symbol}: #{year} complete (#{format_number(count)} bars, #{elapsed_sec}s)"
        )

        count

      {:error, reason} ->
        Logger.error("[HistoricalLoader] #{symbol}: #{year} failed - #{inspect(reason)}")
        0
    end
  end

  defp fetch_and_store_bars(symbol, start_datetime, end_datetime, attempt \\ 1) do
    case Client.get_bars(symbol, start: start_datetime, end: end_datetime, timeframe: "1Min") do
      {:ok, bars_by_symbol} ->
        bars = Map.get(bars_by_symbol, symbol, [])

        if Enum.empty?(bars) do
          {:ok, 0}
        else
          # Convert to Bar structs
          bar_structs = Enum.map(bars, &Bar.from_alpaca(symbol, &1))

          # Batch insert
          count = batch_insert_bars(bar_structs)
          {:ok, count}
        end

      {:error, reason} when attempt < @max_retries ->
        Logger.warning(
          "[HistoricalLoader] #{symbol}: Fetch failed (attempt #{attempt}/#{@max_retries}), " <>
            "retrying in #{@retry_delay}ms: #{inspect(reason)}"
        )

        Process.sleep(@retry_delay)
        fetch_and_store_bars(symbol, start_datetime, end_datetime, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_insert_bars(bars) do
    bars
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, acc ->
      maps = Enum.map(batch, &Bar.to_map/1)

      {count, _} =
        Repo.insert_all(Bar, maps,
          on_conflict: :nothing,
          conflict_target: [:symbol, :bar_time]
        )

      acc + count
    end)
  end

  defp normalize_date(%Date{} = date), do: date
  defp normalize_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  defp format_number(num), do: "#{num}"

  defp format_duration(seconds) when seconds >= 3600 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    "#{hours}h #{minutes}m #{secs}s"
  end

  defp format_duration(seconds) when seconds >= 60 do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration(seconds), do: "#{seconds}s"
end
