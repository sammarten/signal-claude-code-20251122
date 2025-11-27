defmodule Signal.Config.Symbols do
  @moduledoc """
  Central symbol configuration module.

  Provides a programmatic API for accessing the configured symbols list.
  Symbols are defined in config files (e.g., config/dev.exs) and read
  at runtime via Application.get_env/3.

  ## Configuration

  In your config file:

      config :signal,
        symbols: ["AAPL", "TSLA", "NVDA", "SPY", "QQQ"]

  ## Usage

      Signal.Config.Symbols.list()
      #=> ["AAPL", "TSLA", "NVDA", "SPY", "QQQ"]

      Signal.Config.Symbols.member?("AAPL")
      #=> true
  """

  @default_symbols ~w[
    AAPL TSLA NVDA PLTR GOOGL MSFT AMZN META AMD NFLX CRM ADBE
    SPY QQQ SMH DIA IWM
  ]

  @doc """
  Returns the list of configured symbols.

  Falls back to default symbols if not configured.
  """
  @spec list() :: [String.t()]
  def list do
    Application.get_env(:signal, :symbols, @default_symbols)
  end

  @doc """
  Returns the default symbols list.
  """
  @spec default_list() :: [String.t()]
  def default_list, do: @default_symbols

  @doc """
  Returns the number of configured symbols.
  """
  @spec count() :: non_neg_integer()
  def count, do: length(list())

  @doc """
  Returns true if the given symbol is in the configured list.
  Accepts both string and atom symbols.
  """
  @spec member?(String.t() | atom()) :: boolean()
  def member?(symbol)

  def member?(symbol) when is_binary(symbol) do
    symbol in list()
  end

  def member?(symbol) when is_atom(symbol) do
    Atom.to_string(symbol) in list()
  end

  @doc """
  Validates a list of symbols, returning only those in the configured list.

  ## Examples

      iex> Signal.Config.Symbols.validate(["AAPL", "INVALID", "TSLA"])
      {:ok, ["AAPL", "TSLA"]}

      iex> Signal.Config.Symbols.validate(["INVALID"])
      {:error, :no_valid_symbols}
  """
  @spec validate([String.t()]) :: {:ok, [String.t()]} | {:error, :no_valid_symbols}
  def validate(symbols) when is_list(symbols) do
    configured = list()
    valid = Enum.filter(symbols, &(&1 in configured))

    case valid do
      [] -> {:error, :no_valid_symbols}
      symbols -> {:ok, symbols}
    end
  end

  @doc """
  Parses a comma-separated string of symbols into a list.
  Only returns symbols that are in the configured list.

  ## Examples

      iex> Signal.Config.Symbols.parse("AAPL,TSLA,INVALID")
      {:ok, ["AAPL", "TSLA"]}
  """
  @spec parse(String.t()) :: {:ok, [String.t()]} | {:error, :no_valid_symbols}
  def parse(symbols_string) when is_binary(symbols_string) do
    symbols_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.upcase/1)
    |> Enum.reject(&(&1 == ""))
    |> validate()
  end
end
