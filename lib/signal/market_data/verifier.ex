defmodule Signal.MarketData.Verifier do
  @moduledoc """
  Verifies data quality and integrity of historical market bars.

  Provides functions to check for:
  - OHLC relationship violations (high < open/close, low > open/close)
  - Gaps in data during market hours (with optional calendar filtering)
  - Duplicate bars (should be prevented by primary key)
  - Data statistics and coverage
  - Quality report with pass/fail/warn thresholds

  ## Options

  Most functions accept an options keyword list:
  - `:filter_market_hours` - Only count gaps during trading hours (default: true)
  - `:thresholds` - Custom pass/fail thresholds (see default_thresholds/0)

  ## Examples

      # Verify a single symbol
      {:ok, report} = Verifier.verify_symbol("AAPL")

      # Verify with market hours filtering
      {:ok, report} = Verifier.verify_symbol("AAPL", filter_market_hours: true)

      # Generate quality report with pass/fail status
      {:ok, report} = Verifier.generate_quality_report("AAPL")
  """

  require Logger
  alias Signal.Data.MarketCalendar
  alias Signal.MarketData.Bar
  alias Signal.Repo

  import Ecto.Query

  # Default thresholds for pass/fail/warn status
  @default_thresholds %{
    gap_pct_fail: 1.0,
    gap_pct_warn: 0.5,
    ohlc_violations_fail: 10,
    ohlc_violations_warn: 1
  }

  @doc """
  Returns the default thresholds for quality checks.
  """
  @spec default_thresholds() :: map()
  def default_thresholds, do: @default_thresholds

  @doc """
  Verifies data quality for a single symbol.

  Performs comprehensive checks on the data including OHLC relationship
  validation, gap detection, duplicate detection, and statistical analysis.

  ## Parameters

    * `symbol` - The symbol to verify as a string

  ## Returns

    * `{:ok, report}` - Verification report map
    * `{:error, reason}` - If verification fails

  The report includes:
  - `:symbol` - The symbol verified
  - `:total_bars` - Total number of bars
  - `:date_range` - Tuple of {earliest, latest} dates
  - `:issues` - List of issue maps
  - `:statistics` - Statistical summary

  ## Examples

      {:ok, report} = verify_symbol("AAPL")
      # => %{
      #   symbol: "AAPL",
      #   total_bars: 487_234,
      #   date_range: {~D[2019-11-15], ~D[2024-11-15]},
      #   issues: [...],
      #   statistics: %{...}
      # }
  """
  @spec verify_symbol(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_symbol(symbol, opts \\ []) do
    Logger.info("[Verifier] Verifying #{symbol}...")

    filter_market_hours = Keyword.get(opts, :filter_market_hours, true)

    with {:ok, stats} <- get_statistics(symbol),
         {:ok, ohlc_issues} <- check_ohlc_violations(symbol),
         {:ok, gap_issues} <- check_gaps(symbol, filter_market_hours),
         {:ok, duplicate_issues} <- check_duplicates(symbol) do
      issues =
        [ohlc_issues, gap_issues, duplicate_issues]
        |> Enum.reject(&is_nil/1)

      report = %{
        symbol: symbol,
        total_bars: stats.total_bars,
        date_range: {stats.earliest_date, stats.latest_date},
        issues: issues,
        statistics: stats
      }

      Logger.info("[Verifier] #{symbol}: Complete - #{length(issues)} issue types found")
      {:ok, report}
    end
  rescue
    error ->
      Logger.error("[Verifier] #{symbol}: Verification failed - #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Generates a quality report with pass/fail/warn status.

  This function provides a structured report suitable for automated checks
  and display, including expected vs actual bar counts and coverage percentage.

  ## Options

    * `:filter_market_hours` - Only count gaps during trading hours (default: true)
    * `:thresholds` - Custom thresholds (default: see default_thresholds/0)

  ## Returns

  A map containing:
  - `:symbol` - The symbol
  - `:total_bars` - Actual bar count
  - `:expected_bars` - Expected bars based on trading calendar
  - `:coverage_pct` - Percentage of expected bars present
  - `:gaps` - List of gap details
  - `:ohlc_violations` - Count of OHLC violations
  - `:status` - :pass, :warn, or :fail
  - `:issues` - List of human-readable issue descriptions
  """
  @spec generate_quality_report(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_quality_report(symbol, opts \\ []) do
    thresholds = Keyword.get(opts, :thresholds, @default_thresholds)
    filter_market_hours = Keyword.get(opts, :filter_market_hours, true)

    with {:ok, stats} <- get_statistics(symbol),
         {:ok, ohlc_issues} <- check_ohlc_violations(symbol),
         {:ok, gap_issues} <- check_gaps(symbol, filter_market_hours) do
      # Calculate expected bars from calendar
      expected_bars =
        if stats.earliest_date && stats.latest_date do
          MarketCalendar.total_expected_minutes(stats.earliest_date, stats.latest_date)
        else
          0
        end

      # Use regular_hours_bars for coverage calculation to exclude pre/post market
      regular_hours_bars = stats.regular_hours_bars

      # Calculate coverage percentage (using regular hours bars only)
      coverage_pct =
        if expected_bars > 0 do
          Float.round(regular_hours_bars / expected_bars * 100, 2)
        else
          0.0
        end

      # Get gap percentage
      gap_count = if gap_issues, do: gap_issues.count, else: 0

      missing_pct =
        if expected_bars > 0 do
          Float.round((expected_bars - regular_hours_bars) / expected_bars * 100, 2)
        else
          0.0
        end

      # Get OHLC violation count
      ohlc_count = if ohlc_issues, do: ohlc_issues.count, else: 0

      # Determine status based on thresholds
      {status, issues} = determine_status(missing_pct, ohlc_count, gap_issues, thresholds)

      report = %{
        symbol: symbol,
        total_bars: stats.total_bars,
        regular_hours_bars: regular_hours_bars,
        expected_bars: expected_bars,
        coverage_pct: coverage_pct,
        missing_pct: missing_pct,
        gaps: if(gap_issues, do: gap_issues.examples, else: []),
        gap_count: gap_count,
        ohlc_violations: ohlc_count,
        status: status,
        issues: issues,
        date_range: {stats.earliest_date, stats.latest_date}
      }

      {:ok, report}
    end
  rescue
    error ->
      Logger.error("[Verifier] #{symbol}: Quality report failed - #{inspect(error)}")
      {:error, error}
  end

  @doc """
  Generates quality reports for multiple symbols.

  ## Options

  Same as generate_quality_report/2

  ## Returns

  A list of quality report maps with an overall summary.
  """
  @spec generate_quality_reports([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def generate_quality_reports(symbols, opts \\ []) do
    reports =
      symbols
      |> Enum.map(fn symbol ->
        case generate_quality_report(symbol, opts) do
          {:ok, report} -> report
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    pass_count = Enum.count(reports, &(&1.status == :pass))
    warn_count = Enum.count(reports, &(&1.status == :warn))
    fail_count = Enum.count(reports, &(&1.status == :fail))

    overall_status =
      cond do
        fail_count > 0 -> :fail
        warn_count > 0 -> :warn
        true -> :pass
      end

    summary = %{
      reports: reports,
      summary: %{
        total_symbols: length(reports),
        pass: pass_count,
        warn: warn_count,
        fail: fail_count,
        overall_status: overall_status
      }
    }

    {:ok, summary}
  end

  defp determine_status(missing_pct, ohlc_count, gap_issues, thresholds) do
    issues = []

    # Check missing data percentage
    {data_status, issues} =
      cond do
        missing_pct >= thresholds.gap_pct_fail ->
          {:fail,
           [
             "Missing #{missing_pct}% of expected bars (threshold: #{thresholds.gap_pct_fail}%)"
             | issues
           ]}

        missing_pct >= thresholds.gap_pct_warn ->
          {:warn,
           [
             "Missing #{missing_pct}% of expected bars (threshold: #{thresholds.gap_pct_warn}%)"
             | issues
           ]}

        true ->
          {:pass, issues}
      end

    # Check OHLC violations
    {ohlc_status, issues} =
      cond do
        ohlc_count >= thresholds.ohlc_violations_fail ->
          {:fail,
           [
             "#{ohlc_count} OHLC violations (threshold: #{thresholds.ohlc_violations_fail})"
             | issues
           ]}

        ohlc_count >= thresholds.ohlc_violations_warn ->
          {:warn,
           [
             "#{ohlc_count} OHLC violations (threshold: #{thresholds.ohlc_violations_warn})"
             | issues
           ]}

        true ->
          {:pass, issues}
      end

    # Add gap summary if present
    issues =
      if gap_issues && gap_issues.count > 0 do
        largest = gap_issues.largest

        [
          "#{gap_issues.count} gaps detected, largest: #{largest.missing_minutes} minutes"
          | issues
        ]
      else
        issues
      end

    # Overall status is worst of individual statuses
    overall_status =
      cond do
        data_status == :fail or ohlc_status == :fail -> :fail
        data_status == :warn or ohlc_status == :warn -> :warn
        true -> :pass
      end

    {overall_status, Enum.reverse(issues)}
  end

  @doc """
  Verifies data quality for all configured symbols.

  Runs verification on all symbols configured in the application and
  returns a list of reports.

  ## Returns

    * `{:ok, reports}` - List of verification report maps
    * `{:error, reason}` - If verification fails

  ## Examples

      {:ok, reports} = verify_all()
      # Returns list of report maps, one per symbol
  """
  @spec verify_all() :: {:ok, [map()]} | {:error, term()}
  def verify_all do
    symbols = Application.get_env(:signal, :symbols, [])

    if Enum.empty?(symbols) do
      Logger.warning("[Verifier] No symbols configured")
      {:ok, []}
    else
      Logger.info("[Verifier] Verifying #{length(symbols)} symbols...")

      reports =
        symbols
        |> Enum.map(fn symbol ->
          case verify_symbol(symbol) do
            {:ok, report} -> report
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, reports}
    end
  end

  # Private Functions

  defp get_statistics(symbol) do
    query =
      from b in Bar,
        where: b.symbol == ^symbol,
        select: %{
          total_bars: count(b.bar_time),
          earliest: min(b.bar_time),
          latest: max(b.bar_time),
          avg_volume: avg(b.volume)
        }

    case Repo.one(query) do
      %{total_bars: 0} ->
        {:ok,
         %{
           total_bars: 0,
           regular_hours_bars: 0,
           earliest_date: nil,
           latest_date: nil,
           avg_volume: 0,
           trading_days: 0
         }}

      %{total_bars: total, earliest: earliest, latest: latest, avg_volume: avg_vol} ->
        # Count distinct trading days
        trading_days_query =
          from b in Bar,
            where: b.symbol == ^symbol,
            select: fragment("COUNT(DISTINCT DATE(?))", b.bar_time)

        trading_days = Repo.one(trading_days_query) || 0

        # Count bars during regular market hours only (9:30 AM - 4:00 PM ET)
        regular_hours_bars = count_regular_hours_bars(symbol)

        avg_volume =
          cond do
            is_nil(avg_vol) -> 0
            is_struct(avg_vol, Decimal) -> Decimal.round(avg_vol, 0)
            is_number(avg_vol) -> Decimal.new(avg_vol) |> Decimal.round(0)
            true -> 0
          end

        {:ok,
         %{
           total_bars: total,
           regular_hours_bars: regular_hours_bars,
           earliest_date: DateTime.to_date(earliest),
           latest_date: DateTime.to_date(latest),
           avg_volume: avg_volume,
           trading_days: trading_days
         }}

      nil ->
        {:ok,
         %{
           total_bars: 0,
           regular_hours_bars: 0,
           earliest_date: nil,
           latest_date: nil,
           avg_volume: 0,
           trading_days: 0
         }}
    end
  end

  # Count bars during regular market hours using the denormalized session field
  defp count_regular_hours_bars(symbol) do
    query =
      from b in Bar,
        where: b.symbol == ^symbol and b.session == :regular,
        select: count(b.bar_time)

    Repo.one(query) || 0
  end

  defp check_ohlc_violations(symbol) do
    query =
      from b in Bar,
        where: b.symbol == ^symbol,
        where:
          fragment("? < ?", b.high, b.open) or
            fragment("? < ?", b.high, b.close) or
            fragment("? > ?", b.low, b.open) or
            fragment("? > ?", b.low, b.close),
        select: %{
          bar_time: b.bar_time,
          open: b.open,
          high: b.high,
          low: b.low,
          close: b.close
        },
        limit: 5

    violations = Repo.all(query)

    count_query =
      from b in Bar,
        where: b.symbol == ^symbol,
        where:
          fragment("? < ?", b.high, b.open) or
            fragment("? < ?", b.high, b.close) or
            fragment("? > ?", b.low, b.open) or
            fragment("? > ?", b.low, b.close),
        select: count(b.bar_time)

    count = Repo.one(count_query) || 0

    if count > 0 do
      {:ok,
       %{
         type: :ohlc_violation,
         count: count,
         severity: :high,
         examples: violations
       }}
    else
      {:ok, nil}
    end
  end

  defp check_gaps(symbol, filter_market_hours) do
    # Query to find gaps larger than 1 minute
    # Use CTE to calculate gaps, then filter in WHERE clause
    query = """
    WITH gaps_cte AS (
      SELECT
        bar_time,
        LEAD(bar_time) OVER (ORDER BY bar_time) as next_bar,
        EXTRACT(EPOCH FROM (LEAD(bar_time) OVER (ORDER BY bar_time) - bar_time))/60 as gap_minutes
      FROM market_bars
      WHERE symbol = $1
    )
    SELECT bar_time, next_bar, gap_minutes
    FROM gaps_cte
    WHERE next_bar IS NOT NULL
      AND gap_minutes > 1
    ORDER BY gap_minutes DESC
    LIMIT 100
    """

    case Ecto.Adapters.SQL.query(Repo, query, [symbol]) do
      {:ok, %{rows: [_ | _] = rows}} ->
        gaps =
          rows
          |> Enum.map(fn [bar_time, next_bar, gap_minutes] ->
            # Convert gap_minutes to integer (PostgreSQL may return Decimal/float)
            minutes =
              cond do
                is_integer(gap_minutes) -> gap_minutes
                is_float(gap_minutes) -> trunc(gap_minutes)
                is_struct(gap_minutes, Decimal) -> Decimal.to_integer(gap_minutes)
                true -> 0
              end

            %{
              start: bar_time,
              end: next_bar,
              missing_minutes: minutes
            }
          end)

        # Filter out gaps that span non-trading hours if requested
        filtered_gaps =
          if filter_market_hours do
            filter_gaps_by_market_hours(gaps)
          else
            gaps
          end

        if Enum.empty?(filtered_gaps) do
          {:ok, nil}
        else
          largest_gap = Enum.max_by(filtered_gaps, & &1.missing_minutes)
          count = length(filtered_gaps)

          {:ok,
           %{
             type: :gaps,
             count: count,
             severity: if(count > 50, do: :medium, else: :low),
             largest: largest_gap,
             examples: Enum.take(filtered_gaps, 5)
           }}
        end

      {:ok, %{num_rows: 0}} ->
        {:ok, nil}

      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:error, reason} ->
        Logger.error("[Verifier] Gap check failed: #{inspect(reason)}")
        {:ok, nil}
    end
  end

  # Filter gaps to only include those that occur during market hours
  # Gaps that span overnight or across weekends/holidays are excluded
  defp filter_gaps_by_market_hours(gaps) do
    gaps
    |> Enum.filter(fn gap ->
      # Convert to Eastern Time to check market hours
      start_et = DateTime.shift_zone!(gap.start, "America/New_York")
      end_et = DateTime.shift_zone!(gap.end, "America/New_York")

      start_date = DateTime.to_date(start_et)
      end_date = DateTime.to_date(end_et)

      # If gap spans multiple days, it's likely an overnight/weekend gap
      if Date.compare(start_date, end_date) != :eq do
        false
      else
        # Check if both start and end are within market hours
        MarketCalendar.market_open?(gap.start) and MarketCalendar.market_open?(gap.end)
      end
    end)
  end

  defp check_duplicates(symbol) do
    query =
      from b in Bar,
        where: b.symbol == ^symbol,
        group_by: [b.symbol, b.bar_time],
        having: count(b.bar_time) > 1,
        select: %{
          symbol: b.symbol,
          bar_time: b.bar_time,
          count: count(b.bar_time)
        }

    duplicates = Repo.all(query)
    count = length(duplicates)

    if count > 0 do
      {:ok,
       %{
         type: :duplicate_bars,
         count: count,
         severity: :critical,
         examples: Enum.take(duplicates, 5)
       }}
    else
      {:ok, nil}
    end
  end
end
