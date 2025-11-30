defmodule Signal.Optimization.OptionsParams do
  @moduledoc """
  Options-specific parameter definitions for optimization.

  Provides parameter grids and presets for optimizing options trading strategies.
  These parameters integrate with the existing optimization framework to enable
  comprehensive testing of options configurations.

  ## Parameters

  - `instrument_type` - Whether to trade equity or options (:equity, :options)
  - `expiration_preference` - Options expiration type (:weekly, :zero_dte)
  - `strike_selection` - Strike distance from ATM (:atm, :one_otm, :two_otm)
  - `slippage_pct` - Slippage percentage for options fills (0.005 to 0.02)
  - `premium_target_multiple` - Exit when premium reaches this multiple (1.5, 2.0, etc.)
  - `premium_floor_pct` - Exit when premium falls to this % of entry (0.25, 0.5)

  ## Usage

      # Get default options parameter grid
      grid = OptionsParams.default_grid()

      # Get a specific preset
      grid = OptionsParams.preset(:weekly_atm)

      # Custom options grid
      grid = OptionsParams.custom_grid(%{
        instrument_type: [:options],
        expiration_preference: [:weekly, :zero_dte],
        strike_selection: [:atm, :one_otm]
      })

  ## Integration with Optimizer

      {:ok, result} = Runner.run(%{
        symbols: ["SPY", "QQQ"],
        start_date: ~D[2024-03-01],
        end_date: ~D[2024-11-30],
        strategies: [:break_and_retest],
        initial_capital: Decimal.new("100000"),
        base_risk_per_trade: Decimal.new("0.01"),
        parameter_grid: OptionsParams.default_grid()
      })
  """

  alias Signal.Instruments.Config

  @doc """
  Returns the default parameter grid for options optimization.

  Tests the most common configurations:
  - Instrument type: options only (for options-specific optimization)
  - Expiration: weekly and 0DTE
  - Strike: ATM and 1 OTM
  - Slippage: 1% default
  """
  @spec default_grid() :: map()
  def default_grid do
    %{
      instrument_type: [:options],
      expiration_preference: [:weekly, :zero_dte],
      strike_selection: [:atm, :one_otm],
      slippage_pct: [Decimal.new("0.01")],
      risk_per_trade: [Decimal.new("0.01"), Decimal.new("0.015"), Decimal.new("0.02")]
    }
  end

  @doc """
  Returns a comprehensive parameter grid for thorough optimization.

  Tests all combinations including:
  - Both instrument types for comparison
  - All expiration preferences
  - All strike selections
  - Multiple slippage levels
  """
  @spec comprehensive_grid() :: map()
  def comprehensive_grid do
    %{
      instrument_type: [:equity, :options],
      expiration_preference: [:weekly, :zero_dte],
      strike_selection: [:atm, :one_otm, :two_otm],
      slippage_pct: [Decimal.new("0.005"), Decimal.new("0.01"), Decimal.new("0.02")],
      risk_per_trade: [Decimal.new("0.01"), Decimal.new("0.015"), Decimal.new("0.02")]
    }
  end

  @doc """
  Returns a comparison grid for equity vs options analysis.

  Tests identical signals through both execution paths to compare performance.
  """
  @spec comparison_grid() :: map()
  def comparison_grid do
    %{
      instrument_type: [:equity, :options],
      expiration_preference: [:weekly],
      strike_selection: [:atm],
      slippage_pct: [Decimal.new("0.01")],
      risk_per_trade: [Decimal.new("0.01")]
    }
  end

  @doc """
  Returns a 0DTE-focused parameter grid.

  For testing same-day expiration strategies on liquid underlyings (SPY, QQQ).
  """
  @spec zero_dte_grid() :: map()
  def zero_dte_grid do
    %{
      instrument_type: [:options],
      expiration_preference: [:zero_dte],
      strike_selection: [:atm, :one_otm, :two_otm],
      slippage_pct: [Decimal.new("0.01"), Decimal.new("0.02")],
      risk_per_trade: [Decimal.new("0.01"), Decimal.new("0.015")]
    }
  end

  @doc """
  Returns a weekly options focused parameter grid.

  For testing weekly expiration strategies across multiple strike distances.
  """
  @spec weekly_grid() :: map()
  def weekly_grid do
    %{
      instrument_type: [:options],
      expiration_preference: [:weekly],
      strike_selection: [:atm, :one_otm, :two_otm],
      slippage_pct: [Decimal.new("0.01")],
      risk_per_trade: [Decimal.new("0.01"), Decimal.new("0.015"), Decimal.new("0.02")]
    }
  end

  @doc """
  Returns a named preset parameter grid.

  ## Presets

  - `:default` - Standard options optimization
  - `:comprehensive` - All combinations for thorough testing
  - `:comparison` - Equity vs options comparison
  - `:zero_dte` - Same-day expiration focus
  - `:weekly` - Weekly expiration focus
  - `:conservative` - Low risk, ATM strikes
  - `:aggressive` - Higher risk, OTM strikes

  ## Examples

      grid = OptionsParams.preset(:conservative)
      grid = OptionsParams.preset(:aggressive)
  """
  @spec preset(atom()) :: map()
  def preset(:default), do: default_grid()
  def preset(:comprehensive), do: comprehensive_grid()
  def preset(:comparison), do: comparison_grid()
  def preset(:zero_dte), do: zero_dte_grid()
  def preset(:weekly), do: weekly_grid()

  def preset(:conservative) do
    %{
      instrument_type: [:options],
      expiration_preference: [:weekly],
      strike_selection: [:atm],
      slippage_pct: [Decimal.new("0.01")],
      risk_per_trade: [Decimal.new("0.005"), Decimal.new("0.01")]
    }
  end

  def preset(:aggressive) do
    %{
      instrument_type: [:options],
      expiration_preference: [:zero_dte, :weekly],
      strike_selection: [:one_otm, :two_otm],
      slippage_pct: [Decimal.new("0.01"), Decimal.new("0.02")],
      risk_per_trade: [Decimal.new("0.015"), Decimal.new("0.02")]
    }
  end

  @doc """
  Creates a custom parameter grid from a map of parameter ranges.

  ## Parameters

    * `params` - Map of parameter names to value lists

  ## Examples

      grid = OptionsParams.custom_grid(%{
        instrument_type: [:options],
        expiration_preference: [:weekly],
        strike_selection: [:atm, :one_otm],
        slippage_pct: [Decimal.new("0.01")]
      })
  """
  @spec custom_grid(map()) :: map()
  def custom_grid(params) when is_map(params) do
    default_grid()
    |> Map.merge(params)
  end

  @doc """
  Converts optimization parameters to an Instruments.Config struct.

  Used during backtest execution to create the appropriate configuration.

  ## Parameters

    * `params` - Map of parameter values from optimization

  ## Examples

      config = OptionsParams.to_config(%{
        instrument_type: :options,
        expiration_preference: :weekly,
        strike_selection: :atm,
        slippage_pct: Decimal.new("0.01"),
        risk_per_trade: Decimal.new("0.01")
      })
  """
  @spec to_config(map()) :: Config.t()
  def to_config(params) when is_map(params) do
    instrument_type = get_atom(params, :instrument_type, :options)
    expiration = get_atom(params, :expiration_preference, :weekly)
    strike = get_atom(params, :strike_selection, :atm)
    slippage = get_decimal(params, :slippage_pct, Decimal.new("0.01"))
    risk = get_decimal(params, :risk_per_trade, Decimal.new("0.01"))

    Config.new(
      instrument_type: instrument_type,
      expiration_preference: expiration,
      strike_selection: strike,
      slippage_pct: slippage,
      risk_percentage: risk
    )
  end

  @doc """
  Lists all valid options parameters.
  """
  @spec valid_params() :: [atom()]
  def valid_params do
    [
      :instrument_type,
      :expiration_preference,
      :strike_selection,
      :slippage_pct,
      :risk_per_trade,
      :premium_target_multiple,
      :premium_floor_pct
    ]
  end

  @doc """
  Validates that the given parameters are valid options parameters.

  ## Returns

    * `:ok` - All parameters valid
    * `{:error, {:invalid_params, list}}` - List of invalid parameter names
  """
  @spec validate(map()) :: :ok | {:error, {:invalid_params, [atom()]}}
  def validate(params) when is_map(params) do
    valid = valid_params()

    invalid =
      params
      |> Map.keys()
      |> Enum.reject(&(&1 in valid))

    if Enum.empty?(invalid) do
      :ok
    else
      {:error, {:invalid_params, invalid}}
    end
  end

  @doc """
  Returns the total number of combinations for a parameter grid.
  """
  @spec combination_count(map()) :: non_neg_integer()
  def combination_count(grid) when is_map(grid) do
    grid
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.product()
  end

  @doc """
  Returns a summary of the parameter grid for display.
  """
  @spec grid_summary(map()) :: String.t()
  def grid_summary(grid) when is_map(grid) do
    lines =
      grid
      |> Enum.map(fn {key, values} ->
        "  #{key}: #{inspect(values)}"
      end)
      |> Enum.join("\n")

    count = combination_count(grid)

    """
    Options Parameter Grid:
    #{lines}

    Total combinations: #{count}
    """
  end

  @doc """
  Merges options parameters with existing strategy parameters.

  Useful when you want to optimize both strategy and options parameters together.

  ## Examples

      strategy_params = %{
        min_confluence_score: [6, 7, 8],
        min_rr: [2.0, 2.5]
      }

      merged = OptionsParams.merge_with_strategy(
        OptionsParams.default_grid(),
        strategy_params
      )
  """
  @spec merge_with_strategy(map(), map()) :: map()
  def merge_with_strategy(options_grid, strategy_params) do
    Map.merge(options_grid, strategy_params)
  end

  # Private helpers

  defp get_atom(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_existing_atom(value)
      _ -> default
    end
  end

  defp get_decimal(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      %Decimal{} = d -> d
      value when is_binary(value) -> Decimal.new(value)
      value when is_number(value) -> Decimal.new(to_string(value))
      _ -> default
    end
  end
end
