defmodule Mix.Tasks.Signal.SyncCalendar do
  @moduledoc """
  Mix task to sync market calendar from Alpaca API.

  Downloads trading days (dates with market open/close times) from Alpaca
  and stores them in the local database. This data is used for gap validation
  and backtesting to correctly identify market hours.

  By default, fetches the full available range (2019-01-01 through 2029-12-31),
  which is a one-time operation that includes all future trading days.

  ## Usage

      # Sync full calendar (2019 through 2029) - recommended one-time setup
      mix signal.sync_calendar

      # Sync last N years only
      mix signal.sync_calendar --years 5

      # Sync specific date range
      mix signal.sync_calendar --start 2020-01-01 --end 2024-12-31

      # Check existing calendar coverage
      mix signal.sync_calendar --check-only

  ## Options

      --years N           Sync the last N years from today
      --start YYYY-MM-DD  Start date for sync range (default: 2019-01-01)
      --end YYYY-MM-DD    End date for sync range (default: 2029-12-31)
      --check-only        Show calendar coverage without syncing

  ## Examples

      # Sync all trading days since 2019
      mix signal.sync_calendar

      # Sync only the last 2 years
      mix signal.sync_calendar --years 2

      # Check how many trading days are stored
      mix signal.sync_calendar --check-only
  """

  use Mix.Task
  require Logger

  alias Signal.Data.MarketCalendar

  @shortdoc "Sync market calendar from Alpaca API"

  # Alpaca provides calendar data through 2029
  @default_start_date ~D[2019-01-01]
  @default_end_date ~D[2029-12-31]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          years: :integer,
          start: :string,
          end: :string,
          check_only: :boolean
        ]
      )

    if opts[:check_only] do
      check_coverage()
    else
      sync_calendar(opts)
    end
  end

  defp sync_calendar(opts) do
    {start_date, end_date} = parse_date_range(opts)

    Mix.shell().info([
      :bright,
      "\nSyncing market calendar",
      :normal,
      "\n"
    ])

    Mix.shell().info("Date range: #{start_date} to #{end_date}")
    Mix.shell().info("Fetching from Alpaca API...\n")

    case MarketCalendar.sync_calendar(start_date: start_date, end_date: end_date) do
      {:ok, count} ->
        Mix.shell().info([
          :green,
          "✓ Successfully synced #{count} trading days",
          :normal,
          "\n"
        ])

        print_summary(start_date, end_date)

      {:error, reason} ->
        Mix.shell().error("✗ Failed to sync calendar: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp check_coverage do
    Mix.shell().info([
      :bright,
      "\nMarket Calendar Coverage",
      :normal,
      "\n"
    ])

    # Check for any data
    start_date = ~D[2019-01-01]
    end_date = Date.utc_today()

    if MarketCalendar.has_calendar_data?(start_date, end_date) do
      print_summary(start_date, end_date)
    else
      Mix.shell().info([
        :yellow,
        "No calendar data found. Run 'mix signal.sync_calendar' to sync.",
        :normal,
        "\n"
      ])
    end
  end

  defp print_summary(start_date, end_date) do
    total_days = MarketCalendar.trading_days_count(start_date, end_date)
    total_minutes = MarketCalendar.total_expected_minutes(start_date, end_date)

    # Count early close days
    trading_days = MarketCalendar.trading_days_between(start_date, end_date)

    early_close_count =
      trading_days
      |> Enum.count(&MarketCalendar.early_close?/1)

    Mix.shell().info("Summary:")
    Mix.shell().info("  Total trading days: #{total_days}")
    Mix.shell().info("  Early close days: #{early_close_count}")
    Mix.shell().info("  Total market minutes: #{format_minutes(total_minutes)}")

    if length(trading_days) > 0 do
      first = List.first(trading_days)
      last = List.last(trading_days)
      Mix.shell().info("  Date range: #{first} to #{last}")
    end

    Mix.shell().info("")
  end

  defp parse_date_range(opts) do
    end_date =
      case opts[:end] do
        nil -> @default_end_date
        date_string -> Date.from_iso8601!(date_string)
      end

    start_date =
      cond do
        opts[:start] ->
          Date.from_iso8601!(opts[:start])

        opts[:years] ->
          # When using --years, count back from today (not 2029)
          Date.add(Date.utc_today(), -opts[:years] * 365)

        true ->
          @default_start_date
      end

    {start_date, end_date}
  end

  defp format_minutes(minutes) when minutes < 60 do
    "#{minutes} minutes"
  end

  defp format_minutes(minutes) when minutes < 1440 do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    "#{hours}h #{mins}m"
  end

  defp format_minutes(minutes) do
    hours = div(minutes, 60)
    formatted = hours |> Integer.to_string() |> add_thousands_separator()
    "#{formatted} hours"
  end

  defp add_thousands_separator(number_string) do
    number_string
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
