defmodule Mix.Tasks.Signal.TestTechnicals do
  @moduledoc """
  Test the technical analysis modules with real data.

  ## Usage

      # Test all modules for a symbol
      mix signal.test_technicals AAPL

      # Test specific module
      mix signal.test_technicals AAPL --module swings
      mix signal.test_technicals AAPL --module structure
      mix signal.test_technicals AAPL --module levels

      # Customize time range
      mix signal.test_technicals AAPL --days 5

  ## Options

    * `--days` - Number of days to analyze (default: 3)
    * `--module` - Specific module to test: swings, structure, levels, or all (default: all)
    * `--lookback` - Swing lookback period (default: 2)
  """

  use Mix.Task
  alias Signal.Technicals.Inspector

  @shortdoc "Test technical analysis modules with real data"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, args, _} =
      OptionParser.parse(args,
        strict: [days: :integer, module: :string, lookback: :integer],
        aliases: [d: :days, m: :module, l: :lookback]
      )

    symbol =
      case args do
        [sym | _] -> String.to_atom(String.upcase(sym))
        [] -> :AAPL
      end

    days = Keyword.get(opts, :days, 3)
    module_name = Keyword.get(opts, :module, "all")
    lookback = Keyword.get(opts, :lookback, 2)

    case module_name do
      "swings" ->
        Inspector.inspect_swings(symbol, days: days, lookback: lookback)

      "structure" ->
        Inspector.inspect_structure(symbol, days: days, lookback: lookback)

      "levels" ->
        Inspector.inspect_levels(symbol)

      "all" ->
        Inspector.inspect_symbol(symbol, days: days)

      other ->
        Mix.shell().error("Unknown module: #{other}")
        Mix.shell().info("Valid modules: swings, structure, levels, all")
    end
  end
end
