defmodule Signal.MarketData.Verifier do
  @moduledoc """
  Verifies data quality and integrity of historical market bars.

  Provides functions to check for:
  - OHLC relationship violations (high < open/close, low > open/close)
  - Gaps in data during market hours
  - Duplicate bars (should be prevented by primary key)
  - Data statistics and coverage

  ## Examples

      # Verify a single symbol
      {:ok, report} = Verifier.verify_symbol("AAPL")

      # Verify all configured symbols
      {:ok, reports} = Verifier.verify_all()
  """

  require Logger
  alias Signal.MarketData.Bar
  alias Signal.Repo

  import Ecto.Query

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
  @spec verify_symbol(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_symbol(symbol) do
    Logger.info("[Verifier] Verifying #{symbol}...")

    with {:ok, stats} <- get_statistics(symbol),
         {:ok, ohlc_issues} <- check_ohlc_violations(symbol),
         {:ok, gap_issues} <- check_gaps(symbol),
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
    symbols =
      Application.get_env(:signal, :symbols, [])
      |> Enum.map(&Atom.to_string/1)

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

        {:ok,
         %{
           total_bars: total,
           earliest_date: DateTime.to_date(earliest),
           latest_date: DateTime.to_date(latest),
           avg_volume: if(avg_vol, do: Decimal.new(avg_vol) |> Decimal.round(0), else: 0),
           trading_days: trading_days
         }}

      nil ->
        {:ok,
         %{
           total_bars: 0,
           earliest_date: nil,
           latest_date: nil,
           avg_volume: 0,
           trading_days: 0
         }}
    end
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

  defp check_gaps(symbol) do
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
    LIMIT 10
    """

    case Ecto.Adapters.SQL.query(Repo, query, [symbol]) do
      {:ok, %{rows: rows, num_rows: count}} when count > 0 ->
        gaps =
          rows
          |> Enum.map(fn [bar_time, next_bar, gap_minutes] ->
            %{
              start: bar_time,
              end: next_bar,
              missing_minutes: trunc(gap_minutes)
            }
          end)

        largest_gap = List.first(gaps)

        {:ok,
         %{
           type: :gaps,
           count: count,
           severity: if(count > 50, do: :medium, else: :low),
           largest: largest_gap,
           examples: Enum.take(gaps, 5)
         }}

      {:ok, %{num_rows: 0}} ->
        {:ok, nil}

      {:error, reason} ->
        Logger.error("[Verifier] Gap check failed: #{inspect(reason)}")
        {:ok, nil}
    end
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
