defmodule Signal.Options.OSI do
  @moduledoc """
  OSI (Options Symbology Initiative) symbol parser and generator.

  The OSI format is the standard for options contract symbols:

  Format: `{underlying}{YYMMDD}{C|P}{strike*1000 padded to 8 digits}`

  Examples:
  - `AAPL251017C00150000` = AAPL October 17, 2025 $150.00 Call
  - `SPY240315P00500000` = SPY March 15, 2024 $500.00 Put
  - `TSLA250110C00250500` = TSLA January 10, 2025 $250.50 Call

  The strike price is multiplied by 1000 and padded to 8 digits to handle
  strikes with decimals (e.g., $250.50 becomes "00250500").
  """

  @type contract_type :: :call | :put
  @type parsed_symbol :: %{
          underlying: String.t(),
          expiration: Date.t(),
          contract_type: contract_type(),
          strike: Decimal.t()
        }

  @doc """
  Build an OSI symbol from components.

  ## Parameters

    - `underlying` - The underlying symbol (e.g., "AAPL")
    - `expiration` - The expiration date as a Date
    - `contract_type` - Either `:call` or `:put`
    - `strike` - The strike price as a Decimal or number

  ## Examples

      iex> Signal.Options.OSI.build("AAPL", ~D[2025-10-17], :call, Decimal.new("150"))
      "AAPL251017C00150000"

      iex> Signal.Options.OSI.build("SPY", ~D[2024-03-15], :put, 500)
      "SPY240315P00500000"

      iex> Signal.Options.OSI.build("TSLA", ~D[2025-01-10], :call, Decimal.new("250.50"))
      "TSLA250110C00250500"
  """
  @spec build(String.t(), Date.t(), contract_type(), Decimal.t() | number()) :: String.t()
  def build(underlying, %Date{} = expiration, contract_type, strike) do
    type_char = type_to_char(contract_type)
    date_str = format_date(expiration)
    strike_str = format_strike(strike)

    "#{underlying}#{date_str}#{type_char}#{strike_str}"
  end

  @doc """
  Parse an OSI symbol into its components.

  ## Parameters

    - `symbol` - The OSI symbol string

  ## Returns

    - `{:ok, map}` with parsed components
    - `{:error, reason}` if the symbol is invalid

  ## Examples

      iex> Signal.Options.OSI.parse("AAPL251017C00150000")
      {:ok, %{underlying: "AAPL", expiration: ~D[2025-10-17], contract_type: :call, strike: Decimal.new("150.000")}}

      iex> Signal.Options.OSI.parse("invalid")
      {:error, :invalid_format}
  """
  @spec parse(String.t()) :: {:ok, parsed_symbol()} | {:error, atom()}
  def parse(symbol) when is_binary(symbol) do
    # OSI symbols have the format: UNDERLYING + YYMMDD + C/P + 8-digit strike
    # Underlying can be 1-6 characters
    # We need to find where the date portion starts (6 digits before C or P)
    case extract_components(symbol) do
      {:ok, underlying, date_str, type_char, strike_str} ->
        with {:ok, expiration} <- parse_date(date_str),
             {:ok, contract_type} <- char_to_type(type_char),
             {:ok, strike} <- parse_strike(strike_str) do
          {:ok,
           %{
             underlying: underlying,
             expiration: expiration,
             contract_type: contract_type,
             strike: strike
           }}
        end

      :error ->
        {:error, :invalid_format}
    end
  end

  def parse(_), do: {:error, :invalid_format}

  @doc """
  Parse an OSI symbol, raising on error.

  ## Examples

      iex> Signal.Options.OSI.parse!("AAPL251017C00150000")
      %{underlying: "AAPL", expiration: ~D[2025-10-17], contract_type: :call, strike: Decimal.new("150.000")}
  """
  @spec parse!(String.t()) :: parsed_symbol()
  def parse!(symbol) do
    case parse(symbol) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "Invalid OSI symbol: #{reason}"
    end
  end

  @doc """
  Extract the underlying symbol from an OSI symbol.

  ## Examples

      iex> Signal.Options.OSI.underlying("AAPL251017C00150000")
      {:ok, "AAPL"}
  """
  @spec underlying(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def underlying(symbol) do
    case parse(symbol) do
      {:ok, %{underlying: underlying}} -> {:ok, underlying}
      error -> error
    end
  end

  @doc """
  Extract the expiration date from an OSI symbol.

  ## Examples

      iex> Signal.Options.OSI.expiration("AAPL251017C00150000")
      {:ok, ~D[2025-10-17]}
  """
  @spec expiration(String.t()) :: {:ok, Date.t()} | {:error, atom()}
  def expiration(symbol) do
    case parse(symbol) do
      {:ok, %{expiration: expiration}} -> {:ok, expiration}
      error -> error
    end
  end

  @doc """
  Extract the strike price from an OSI symbol.

  ## Examples

      iex> Signal.Options.OSI.strike("AAPL251017C00150000")
      {:ok, Decimal.new("150.000")}
  """
  @spec strike(String.t()) :: {:ok, Decimal.t()} | {:error, atom()}
  def strike(symbol) do
    case parse(symbol) do
      {:ok, %{strike: strike}} -> {:ok, strike}
      error -> error
    end
  end

  @doc """
  Extract the contract type from an OSI symbol.

  ## Examples

      iex> Signal.Options.OSI.contract_type("AAPL251017C00150000")
      {:ok, :call}

      iex> Signal.Options.OSI.contract_type("SPY240315P00500000")
      {:ok, :put}
  """
  @spec contract_type(String.t()) :: {:ok, contract_type()} | {:error, atom()}
  def contract_type(symbol) do
    case parse(symbol) do
      {:ok, %{contract_type: contract_type}} -> {:ok, contract_type}
      error -> error
    end
  end

  @doc """
  Check if a symbol is a valid OSI format.

  ## Examples

      iex> Signal.Options.OSI.valid?("AAPL251017C00150000")
      true

      iex> Signal.Options.OSI.valid?("AAPL")
      false
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(symbol) do
    case parse(symbol) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # Private Functions

  defp extract_components(symbol) when byte_size(symbol) < 15 do
    :error
  end

  defp extract_components(symbol) do
    # Work backwards from the end:
    # - Last 8 chars are strike
    # - 1 char before that is C/P
    # - 6 chars before that are YYMMDD
    # - Everything before that is underlying

    len = String.length(symbol)
    strike_str = String.slice(symbol, (len - 8)..(len - 1))
    type_char = String.at(symbol, len - 9)
    date_str = String.slice(symbol, (len - 15)..(len - 10))
    underlying = String.slice(symbol, 0..(len - 16))

    if String.length(underlying) >= 1 and String.length(underlying) <= 6 do
      {:ok, underlying, date_str, type_char, strike_str}
    else
      :error
    end
  end

  defp format_date(%Date{year: year, month: month, day: day}) do
    yy = rem(year, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    mm = Integer.to_string(month) |> String.pad_leading(2, "0")
    dd = Integer.to_string(day) |> String.pad_leading(2, "0")
    "#{yy}#{mm}#{dd}"
  end

  defp parse_date(<<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2)>>) do
    with {year_2digit, ""} <- Integer.parse(yy),
         {month, ""} <- Integer.parse(mm),
         {day, ""} <- Integer.parse(dd) do
      # Assume 2000s for 2-digit years
      year = 2000 + year_2digit
      Date.new(year, month, day)
    else
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date(_), do: {:error, :invalid_date}

  defp format_strike(strike) when is_number(strike) do
    format_strike(Decimal.new(to_string(strike)))
  end

  defp format_strike(%Decimal{} = strike) do
    # Multiply by 1000 and format as 8-digit integer
    strike_1000 =
      strike
      |> Decimal.mult(Decimal.new(1000))
      |> Decimal.round(0)
      |> Decimal.to_integer()

    Integer.to_string(strike_1000) |> String.pad_leading(8, "0")
  end

  defp parse_strike(strike_str) when byte_size(strike_str) == 8 do
    case Integer.parse(strike_str) do
      {strike_1000, ""} ->
        strike = Decimal.div(Decimal.new(strike_1000), Decimal.new(1000))
        {:ok, strike}

      _ ->
        {:error, :invalid_strike}
    end
  end

  defp parse_strike(_), do: {:error, :invalid_strike}

  defp type_to_char(:call), do: "C"
  defp type_to_char(:put), do: "P"

  defp char_to_type("C"), do: {:ok, :call}
  defp char_to_type("c"), do: {:ok, :call}
  defp char_to_type("P"), do: {:ok, :put}
  defp char_to_type("p"), do: {:ok, :put}
  defp char_to_type(_), do: {:error, :invalid_contract_type}
end
