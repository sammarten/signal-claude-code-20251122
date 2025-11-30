defmodule Signal.Instruments.Config do
  @moduledoc """
  Configuration for instrument selection and options parameters.

  This struct contains all configurable parameters for the instrument
  abstraction layer, controlling whether to trade equity or options
  and how options contracts are selected.

  ## Fields

  ### Instrument Selection
    * `:instrument_type` - `:equity` or `:options` (default: `:options`)

  ### Options Contract Selection
    * `:expiration_preference` - `:weekly` or `:zero_dte` (default: `:weekly`)
    * `:strike_selection` - `:atm`, `:one_otm`, or `:two_otm` (default: `:atm`)

  ### Position Sizing
    * `:risk_percentage` - Percentage of portfolio to risk per trade (default: 0.01 = 1%)

  ### Simulation Parameters
    * `:slippage_pct` - Slippage percentage for options fills (default: 0.01 = 1%)
    * `:use_bar_open_for_entry` - Use bar open price for entry simulation (default: true)
    * `:use_bar_close_for_exit` - Use bar close price for exit simulation (default: true)

  ## Examples

      # Default configuration (options with weekly expiration, ATM strike)
      config = Config.new()

      # Equity-only configuration
      config = Config.new(instrument_type: :equity)

      # Options with 0DTE and 1 strike OTM
      config = Config.new(
        instrument_type: :options,
        expiration_preference: :zero_dte,
        strike_selection: :one_otm
      )

      # Custom risk and slippage
      config = Config.new(
        risk_percentage: Decimal.new("0.02"),
        slippage_pct: Decimal.new("0.005")
      )
  """

  @type instrument_type :: :equity | :options
  @type expiration_preference :: :weekly | :zero_dte
  @type strike_selection :: :atm | :one_otm | :two_otm

  @type t :: %__MODULE__{
          instrument_type: instrument_type(),
          expiration_preference: expiration_preference(),
          strike_selection: strike_selection(),
          risk_percentage: Decimal.t(),
          slippage_pct: Decimal.t(),
          use_bar_open_for_entry: boolean(),
          use_bar_close_for_exit: boolean()
        }

  @enforce_keys []
  defstruct instrument_type: :options,
            expiration_preference: :weekly,
            strike_selection: :atm,
            risk_percentage: Decimal.new("0.01"),
            slippage_pct: Decimal.new("0.01"),
            use_bar_open_for_entry: true,
            use_bar_close_for_exit: true

  @valid_instrument_types [:equity, :options]
  @valid_expiration_preferences [:weekly, :zero_dte]
  @valid_strike_selections [:atm, :one_otm, :two_otm]

  @doc """
  Creates a new configuration with the given options.

  ## Parameters

    * `opts` - Keyword list of configuration options

  ## Returns

    * `%Config{}` struct with validated options

  ## Examples

      config = Config.new(instrument_type: :equity)
      config = Config.new(expiration_preference: :zero_dte, strike_selection: :one_otm)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      instrument_type: validate_option(opts, :instrument_type, @valid_instrument_types, :options),
      expiration_preference:
        validate_option(opts, :expiration_preference, @valid_expiration_preferences, :weekly),
      strike_selection: validate_option(opts, :strike_selection, @valid_strike_selections, :atm),
      risk_percentage: get_decimal_option(opts, :risk_percentage, Decimal.new("0.01")),
      slippage_pct: get_decimal_option(opts, :slippage_pct, Decimal.new("0.01")),
      use_bar_open_for_entry: Keyword.get(opts, :use_bar_open_for_entry, true),
      use_bar_close_for_exit: Keyword.get(opts, :use_bar_close_for_exit, true)
    }
  end

  @doc """
  Creates a configuration for equity-only trading.

  This is a convenience function that returns a config with
  `instrument_type: :equity`.
  """
  @spec equity() :: t()
  def equity do
    new(instrument_type: :equity)
  end

  @doc """
  Creates a configuration for options trading with default settings.

  Default: weekly expiration, ATM strike, 1% risk, 1% slippage.
  """
  @spec options() :: t()
  def options do
    new(instrument_type: :options)
  end

  @doc """
  Creates a configuration for 0DTE options trading.

  Sets expiration_preference to :zero_dte with other defaults.
  """
  @spec zero_dte(keyword()) :: t()
  def zero_dte(opts \\ []) do
    opts
    |> Keyword.put(:instrument_type, :options)
    |> Keyword.put(:expiration_preference, :zero_dte)
    |> new()
  end

  @doc """
  Returns true if the config is for options trading.
  """
  @spec options?(t()) :: boolean()
  def options?(%__MODULE__{instrument_type: :options}), do: true
  def options?(_), do: false

  @doc """
  Returns true if the config is for equity trading.
  """
  @spec equity?(t()) :: boolean()
  def equity?(%__MODULE__{instrument_type: :equity}), do: true
  def equity?(_), do: false

  @doc """
  Returns true if 0DTE expiration is preferred.
  """
  @spec zero_dte?(t()) :: boolean()
  def zero_dte?(%__MODULE__{expiration_preference: :zero_dte}), do: true
  def zero_dte?(_), do: false

  @doc """
  Converts the config to a map for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      instrument_type: config.instrument_type,
      expiration_preference: config.expiration_preference,
      strike_selection: config.strike_selection,
      risk_percentage: Decimal.to_string(config.risk_percentage),
      slippage_pct: Decimal.to_string(config.slippage_pct),
      use_bar_open_for_entry: config.use_bar_open_for_entry,
      use_bar_close_for_exit: config.use_bar_close_for_exit
    }
  end

  @doc """
  Creates a config from a map (e.g., from JSON).
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    new(
      instrument_type: parse_atom(map, "instrument_type", :instrument_type),
      expiration_preference: parse_atom(map, "expiration_preference", :expiration_preference),
      strike_selection: parse_atom(map, "strike_selection", :strike_selection),
      risk_percentage: parse_decimal(map, "risk_percentage", :risk_percentage),
      slippage_pct: parse_decimal(map, "slippage_pct", :slippage_pct),
      use_bar_open_for_entry: parse_bool(map, "use_bar_open_for_entry", :use_bar_open_for_entry),
      use_bar_close_for_exit: parse_bool(map, "use_bar_close_for_exit", :use_bar_close_for_exit)
    )
  end

  # Private helpers

  defp validate_option(opts, key, valid_values, default) do
    value = Keyword.get(opts, key, default)

    if value in valid_values do
      value
    else
      raise ArgumentError,
            "Invalid #{key}: #{inspect(value)}. Must be one of #{inspect(valid_values)}"
    end
  end

  defp get_decimal_option(opts, key, default) do
    case Keyword.get(opts, key) do
      nil -> default
      %Decimal{} = d -> d
      n when is_number(n) -> Decimal.new(to_string(n))
      s when is_binary(s) -> Decimal.new(s)
    end
  end

  defp parse_atom(map, string_key, atom_key) do
    case Map.get(map, string_key) || Map.get(map, atom_key) do
      nil -> nil
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_existing_atom(value)
    end
  end

  defp parse_decimal(map, string_key, atom_key) do
    case Map.get(map, string_key) || Map.get(map, atom_key) do
      nil -> nil
      %Decimal{} = d -> d
      n when is_number(n) -> Decimal.new(to_string(n))
      s when is_binary(s) -> Decimal.new(s)
    end
  end

  defp parse_bool(map, string_key, atom_key) do
    case Map.get(map, string_key) || Map.get(map, atom_key) do
      nil -> nil
      b when is_boolean(b) -> b
      "true" -> true
      "false" -> false
    end
  end
end
