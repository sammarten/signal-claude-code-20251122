defmodule Mix.Tasks.Signal.Preview do
  @moduledoc """
  Generate a daily market preview.

  ## Usage

      # Generate preview for today
      mix signal.preview

      # Generate preview for a specific date
      mix signal.preview --date 2024-12-13

      # Generate preview with custom symbols
      mix signal.preview --symbols AAPL,TSLA,NVDA

      # Output as JSON instead of markdown
      mix signal.preview --format json

      # Use partial mode (continues even if some data sources fail)
      mix signal.preview --partial

  ## Options

    * `--date` - Date to generate preview for in YYYY-MM-DD format (default: today)
    * `--symbols` - Comma-separated list of symbols (default: configured symbols)
    * `--format` - Output format: markdown or json (default: markdown)
    * `--partial` - Use partial mode to continue even if some data sources fail

  ## Requirements

  The preview generator requires historical data to be loaded. If you see errors
  about insufficient data, run:

      mix signal.load_data --symbols SPY,QQQ,DIA --year 2024
      mix signal.calculate_levels

  ## Output

  The preview includes:
  - Index divergence analysis (SPY/QQQ/DIA)
  - Market regime detection
  - Key levels and scenarios for SPY and QQQ
  - Watchlist with high conviction, monitoring, and avoid categories
  - Relative strength leaders and laggards
  - Game plan with stance, position size, and risk notes
  """

  use Mix.Task
  alias Signal.Preview.{Generator, Formatter}

  @shortdoc "Generate a daily market preview"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _args, _} =
      OptionParser.parse(args,
        strict: [date: :string, symbols: :string, format: :string, partial: :boolean],
        aliases: [d: :date, s: :symbols, f: :format, p: :partial]
      )

    date = parse_date(opts)
    symbols = parse_symbols(opts)
    format = Keyword.get(opts, :format, "markdown")
    partial = Keyword.get(opts, :partial, false)

    Mix.shell().info("\n📊 Generating Daily Market Preview")
    Mix.shell().info("   Date: #{date}")
    Mix.shell().info("   Symbols: #{length(symbols)} configured")
    Mix.shell().info("   Format: #{format}")
    Mix.shell().info("   Mode: #{if partial, do: "partial", else: "full"}\n")

    generator_opts = [date: date, symbols: symbols]

    result =
      if partial do
        Generator.generate_partial(generator_opts)
      else
        Generator.generate(generator_opts)
      end

    case result do
      {:ok, preview} ->
        output = format_output(preview, format)
        Mix.shell().info("\n" <> output)

      {:error, reason} ->
        Mix.shell().error("❌ Failed to generate preview: #{inspect(reason)}")
        Mix.shell().info("\nTry running with --partial to see partial results.")
        Mix.shell().info("Or ensure historical data is loaded:")
        Mix.shell().info("  mix signal.load_data --symbols SPY,QQQ,DIA")
        Mix.shell().info("  mix signal.calculate_levels")
        System.halt(1)
    end
  end

  defp parse_date(opts) do
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
  end

  defp parse_symbols(opts) do
    case Keyword.get(opts, :symbols) do
      nil ->
        # Use configured symbols or defaults
        Application.get_env(:signal, :symbols, [])
        |> Enum.map(&String.to_atom/1)
        |> case do
          [] -> default_symbols()
          symbols -> symbols
        end

      symbols_str ->
        symbols_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.upcase/1)
        |> Enum.map(&String.to_atom/1)
    end
  end

  defp default_symbols do
    [
      :SPY,
      :QQQ,
      :DIA,
      :IWM,
      :AAPL,
      :MSFT,
      :GOOGL,
      :AMZN,
      :NVDA,
      :META,
      :TSLA,
      :AMD,
      :AVGO,
      :MU,
      :GLD,
      :SLV
    ]
  end

  defp format_output(preview, "json") do
    Formatter.to_json(preview)
  end

  defp format_output(preview, _) do
    Formatter.to_markdown(preview)
  end
end
