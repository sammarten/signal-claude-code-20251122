defmodule Mix.Tasks.Signal.CalculateLevels do
  @moduledoc """
  Calculate and store key levels for configured symbols.

  ## Usage

      # Calculate levels for today for all configured symbols
      mix signal.calculate_levels

      # Calculate levels for specific symbols
      mix signal.calculate_levels --symbols AAPL,TSLA,NVDA

      # Calculate levels for a specific date
      mix signal.calculate_levels --date 2024-11-25

      # Recalculate even if levels already exist
      mix signal.calculate_levels --force

  ## Options

    * `--symbols` - Comma-separated list of symbols (default: all configured symbols)
    * `--date` - Date to calculate levels for in YYYY-MM-DD format (default: today)
    * `--force` - Recalculate even if levels already exist for the date

  ## Notes

  Key levels require historical data to be loaded first. If you see errors about
  missing data, run:

      mix signal.load_data --symbols AAPL --year 2024
  """

  use Mix.Task
  alias Signal.Technicals.Levels

  @shortdoc "Calculate key levels (PDH/PDL, PMH/PML, opening ranges)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _args, _} =
      OptionParser.parse(args,
        strict: [symbols: :string, date: :string, force: :boolean],
        aliases: [s: :symbols, d: :date, f: :force]
      )

    # Get symbols
    symbols =
      case Keyword.get(opts, :symbols) do
        nil ->
          Application.get_env(:signal, :symbols, [])

        symbols_str ->
          symbols_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.upcase/1)
      end

    # Get date
    date =
      case Keyword.get(opts, :date) do
        nil ->
          Date.utc_today()

        date_str ->
          case Date.from_iso8601(date_str) do
            {:ok, date} ->
              date

            {:error, _} ->
              Mix.shell().error("Invalid date format: #{date_str}. Use YYYY-MM-DD.")
              System.halt(1)
          end
      end

    force = Keyword.get(opts, :force, false)

    Mix.shell().info("\n📊 Calculating Key Levels")
    Mix.shell().info("   Date: #{date}")
    Mix.shell().info("   Symbols: #{Enum.join(symbols, ", ")}")
    Mix.shell().info("   Force recalculate: #{force}\n")

    # Calculate levels for each symbol
    results =
      Enum.map(symbols, fn symbol ->
        symbol_atom = String.to_atom(symbol)
        calculate_for_symbol(symbol_atom, date, force)
      end)

    # Summary
    successes = Enum.count(results, fn {status, _} -> status == :ok end)
    failures = Enum.count(results, fn {status, _} -> status == :error end)
    skipped = Enum.count(results, fn {status, _} -> status == :skipped end)

    Mix.shell().info("\n" <> String.duplicate("─", 50))
    Mix.shell().info("✅ Success: #{successes}  ⏭️  Skipped: #{skipped}  ❌ Failed: #{failures}")
    Mix.shell().info(String.duplicate("─", 50))
  end

  defp calculate_for_symbol(symbol, date, force) do
    # Check if levels already exist
    case Levels.get_current_levels(symbol) do
      {:ok, existing} when not force ->
        Mix.shell().info(
          "⏭️  #{symbol}: Levels already exist for #{date} (use --force to recalculate)"
        )

        print_levels_summary(existing)
        {:skipped, symbol}

      _ ->
        Mix.shell().info("🔄 #{symbol}: Calculating levels for #{date}...")

        case Levels.calculate_daily_levels(symbol, date) do
          {:ok, levels} ->
            # Also try to calculate opening ranges if we have historical data
            levels = maybe_update_opening_ranges(symbol, date, levels)
            Mix.shell().info("✅ #{symbol}: Levels calculated successfully")
            print_levels_summary(levels)
            {:ok, symbol}

          {:error, :no_previous_day_data} ->
            Mix.shell().error("❌ #{symbol}: No previous day data found")
            Mix.shell().info("   Run: mix signal.load_data --symbols #{symbol}")
            {:error, symbol}

          {:error, :not_a_trading_day} ->
            Mix.shell().error("❌ #{symbol}: #{date} is not a trading day (weekend/holiday)")
            {:error, symbol}

          {:error, reason} ->
            Mix.shell().error("❌ #{symbol}: Failed - #{inspect(reason)}")
            {:error, symbol}
        end
    end
  end

  defp maybe_update_opening_ranges(symbol, date, levels) do
    # Try to calculate 5-minute opening range
    levels =
      case Levels.update_opening_range(symbol, date, :five_min) do
        {:ok, updated} -> updated
        {:error, _} -> levels
      end

    # Try to calculate 15-minute opening range
    case Levels.update_opening_range(symbol, date, :fifteen_min) do
      {:ok, updated} -> updated
      {:error, _} -> levels
    end
  end

  defp print_levels_summary(levels) do
    if levels.previous_day_high do
      Mix.shell().info(
        "   PDH: $#{Decimal.round(levels.previous_day_high, 2)}  PDL: $#{Decimal.round(levels.previous_day_low, 2)}"
      )
    end

    if levels.premarket_high do
      Mix.shell().info(
        "   PMH: $#{Decimal.round(levels.premarket_high, 2)}  PML: $#{Decimal.round(levels.premarket_low, 2)}"
      )
    end

    if levels.opening_range_5m_high do
      Mix.shell().info(
        "   OR5: $#{Decimal.round(levels.opening_range_5m_high, 2)} - $#{Decimal.round(levels.opening_range_5m_low, 2)}"
      )
    end

    if levels.opening_range_15m_high do
      Mix.shell().info(
        "   OR15: $#{Decimal.round(levels.opening_range_15m_high, 2)} - $#{Decimal.round(levels.opening_range_15m_low, 2)}"
      )
    end

    Mix.shell().info("")
  end
end
