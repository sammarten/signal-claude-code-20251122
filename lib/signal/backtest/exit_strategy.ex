defmodule Signal.Backtest.ExitStrategy do
  @moduledoc """
  Configures exit behavior for trade management.

  An ExitStrategy defines how a position should be managed from entry to exit,
  including stop loss placement, take profit targets, trailing behavior, and
  breakeven management.

  ## Strategy Types

  - `:fixed` - Traditional fixed stop and single target (default, backwards compatible)
  - `:trailing` - Stop follows price at fixed distance, ATR multiple, or percentage
  - `:scaled` - Multiple targets with partial exits at each level
  - `:breakeven` - Fixed stop/target with breakeven management
  - `:combined` - Mix of trailing, scaling, and breakeven features

  ## Examples

      # Simple fixed strategy (current behavior)
      ExitStrategy.fixed(
        Decimal.new("174.50"),  # stop loss
        Decimal.new("177.50")   # take profit
      )

      # Trailing stop with $0.50 trail distance
      ExitStrategy.trailing(
        Decimal.new("174.50"),
        type: :fixed_distance,
        value: Decimal.new("0.50")
      )

      # Scale out: 50% at T1, 50% at T2
      ExitStrategy.scaled(Decimal.new("174.50"), [
        %{price: Decimal.new("176.50"), exit_percent: 50, move_stop_to: :breakeven},
        %{price: Decimal.new("178.50"), exit_percent: 50, move_stop_to: nil}
      ])

      # Add breakeven management to any strategy
      ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      |> ExitStrategy.with_breakeven(Decimal.new("1.0"))  # Move to BE after 1R
  """

  @type trailing_type :: :fixed_distance | :atr_multiple | :percent
  @type strategy_type :: :fixed | :trailing | :scaled | :breakeven | :combined

  @type trailing_config :: %{
          type: trailing_type(),
          value: Decimal.t(),
          activation_r: Decimal.t() | nil
        }

  @type stop_adjustment :: :breakeven | :entry | {:price, Decimal.t()} | nil

  @type target :: %{
          price: Decimal.t(),
          exit_percent: pos_integer(),
          move_stop_to: stop_adjustment()
        }

  @type breakeven_config :: %{
          trigger_r: Decimal.t(),
          buffer: Decimal.t()
        }

  @type t :: %__MODULE__{
          type: strategy_type(),
          initial_stop: Decimal.t(),
          trailing_config: trailing_config() | nil,
          targets: [target()] | nil,
          breakeven_config: breakeven_config() | nil
        }

  @enforce_keys [:type, :initial_stop]
  defstruct [
    :type,
    :initial_stop,
    :trailing_config,
    :targets,
    :breakeven_config
  ]

  # ============================================================================
  # Strategy Constructors
  # ============================================================================

  @doc """
  Creates a fixed stop/target strategy.

  This is the default strategy type, providing backwards compatibility with
  the existing trade simulation behavior.

  ## Parameters

    * `stop_loss` - The stop loss price
    * `take_profit` - The take profit target (optional)

  ## Examples

      iex> strategy = ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      iex> strategy.type
      :fixed
      iex> strategy.initial_stop
      Decimal.new("174.50")
  """
  @spec fixed(Decimal.t(), Decimal.t() | nil) :: t()
  def fixed(stop_loss, take_profit \\ nil) do
    targets =
      if take_profit do
        [%{price: take_profit, exit_percent: 100, move_stop_to: nil}]
      else
        nil
      end

    %__MODULE__{
      type: :fixed,
      initial_stop: stop_loss,
      targets: targets
    }
  end

  @doc """
  Creates a trailing stop strategy.

  The stop will follow the price at a specified distance once activated.
  The stop only moves in the favorable direction (up for longs, down for shorts).

  ## Parameters

    * `stop_loss` - The initial stop loss price
    * `opts` - Keyword list of options:
      * `:type` - Trail type: `:fixed_distance`, `:atr_multiple`, or `:percent` (required)
      * `:value` - Trail distance/multiplier as Decimal (required)
      * `:activation_r` - Only start trailing after reaching this R multiple (optional)
      * `:take_profit` - Optional fixed take profit target

  ## Examples

      # Trail $0.50 behind the high (for longs)
      ExitStrategy.trailing(
        Decimal.new("174.50"),
        type: :fixed_distance,
        value: Decimal.new("0.50")
      )

      # Trail 2x ATR, activate after 1R profit
      ExitStrategy.trailing(
        Decimal.new("174.50"),
        type: :atr_multiple,
        value: Decimal.new("2.0"),
        activation_r: Decimal.new("1.0")
      )

      # Trail 1% behind price
      ExitStrategy.trailing(
        Decimal.new("174.50"),
        type: :percent,
        value: Decimal.new("0.01")
      )
  """
  @spec trailing(Decimal.t(), keyword()) :: t()
  def trailing(stop_loss, opts) do
    trail_type = Keyword.fetch!(opts, :type)
    trail_value = Keyword.fetch!(opts, :value)
    activation_r = Keyword.get(opts, :activation_r)
    take_profit = Keyword.get(opts, :take_profit)

    validate_trailing_type!(trail_type)
    validate_positive_decimal!(trail_value, :value)

    if activation_r do
      validate_non_negative_decimal!(activation_r, :activation_r)
    end

    targets =
      if take_profit do
        [%{price: take_profit, exit_percent: 100, move_stop_to: nil}]
      else
        nil
      end

    %__MODULE__{
      type: :trailing,
      initial_stop: stop_loss,
      trailing_config: %{
        type: trail_type,
        value: trail_value,
        activation_r: activation_r
      },
      targets: targets
    }
  end

  @doc """
  Creates a scaled exit strategy with multiple take profit targets.

  Each target specifies a price level, the percentage of the position to exit,
  and optionally how to adjust the stop after hitting that target.

  ## Parameters

    * `stop_loss` - The initial stop loss price
    * `targets` - List of target maps, each with:
      * `:price` - Target price (required)
      * `:exit_percent` - Percentage of position to exit, 1-100 (required)
      * `:move_stop_to` - Stop adjustment after hitting target (optional):
        * `:breakeven` - Move stop to entry price + small buffer
        * `:entry` - Move stop to exact entry price
        * `{:price, Decimal.t()}` - Move stop to specific price
        * `nil` - Don't adjust stop

  ## Examples

      # Exit 50% at each of two targets
      ExitStrategy.scaled(Decimal.new("174.50"), [
        %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven},
        %{price: Decimal.new("178.00"), exit_percent: 50, move_stop_to: nil}
      ])

      # Three targets: 33% each
      ExitStrategy.scaled(Decimal.new("174.50"), [
        %{price: Decimal.new("175.50"), exit_percent: 33, move_stop_to: :breakeven},
        %{price: Decimal.new("176.50"), exit_percent: 33, move_stop_to: nil},
        %{price: Decimal.new("178.00"), exit_percent: 34, move_stop_to: nil}
      ])

  ## Raises

    * `ArgumentError` if target percentages don't sum to 100
    * `ArgumentError` if targets list is empty
  """
  @spec scaled(Decimal.t(), [target()]) :: t()
  def scaled(stop_loss, targets) when is_list(targets) do
    validate_targets!(targets)

    %__MODULE__{
      type: :scaled,
      initial_stop: stop_loss,
      targets: targets
    }
  end

  # ============================================================================
  # Strategy Modifiers
  # ============================================================================

  @doc """
  Adds breakeven management to an existing strategy.

  When the position reaches the specified R multiple in profit, the stop
  will be moved to the entry price plus a small buffer.

  ## Parameters

    * `strategy` - The base exit strategy
    * `trigger_r` - R multiple at which to move stop to breakeven
    * `buffer` - Small buffer above/below entry (default: 0.05)

  ## Examples

      # Move to breakeven after 1R profit
      ExitStrategy.fixed(Decimal.new("174.50"), Decimal.new("177.50"))
      |> ExitStrategy.with_breakeven(Decimal.new("1.0"))

      # With custom buffer
      ExitStrategy.trailing(Decimal.new("174.50"), type: :fixed_distance, value: Decimal.new("0.50"))
      |> ExitStrategy.with_breakeven(Decimal.new("0.5"), Decimal.new("0.10"))
  """
  @spec with_breakeven(t(), Decimal.t(), Decimal.t()) :: t()
  def with_breakeven(strategy, trigger_r, buffer \\ Decimal.new("0.05")) do
    validate_positive_decimal!(trigger_r, :trigger_r)
    validate_non_negative_decimal!(buffer, :buffer)

    new_type =
      case strategy.type do
        :fixed -> :breakeven
        _other -> :combined
      end

    %{
      strategy
      | type: new_type,
        breakeven_config: %{
          trigger_r: trigger_r,
          buffer: buffer
        }
    }
  end

  @doc """
  Adds trailing stop behavior to an existing strategy.

  Useful for combining scaled exits with trailing on the remaining position.

  ## Parameters

    * `strategy` - The base exit strategy
    * `opts` - Trailing options (same as `trailing/2`)

  ## Examples

      # Scale out 50% at T1, trail the remaining 50%
      ExitStrategy.scaled(Decimal.new("174.50"), [
        %{price: Decimal.new("176.00"), exit_percent: 50, move_stop_to: :breakeven}
      ])
      |> ExitStrategy.with_trailing(type: :fixed_distance, value: Decimal.new("0.50"))
  """
  @spec with_trailing(t(), keyword()) :: t()
  def with_trailing(strategy, opts) do
    trail_type = Keyword.fetch!(opts, :type)
    trail_value = Keyword.fetch!(opts, :value)
    activation_r = Keyword.get(opts, :activation_r)

    validate_trailing_type!(trail_type)
    validate_positive_decimal!(trail_value, :value)

    if activation_r do
      validate_non_negative_decimal!(activation_r, :activation_r)
    end

    %{
      strategy
      | type: :combined,
        trailing_config: %{
          type: trail_type,
          value: trail_value,
          activation_r: activation_r
        }
    }
  end

  # ============================================================================
  # Query Functions
  # ============================================================================

  @doc """
  Returns true if the strategy uses trailing stops.
  """
  @spec trailing?(t()) :: boolean()
  def trailing?(%__MODULE__{trailing_config: nil}), do: false
  def trailing?(%__MODULE__{}), do: true

  @doc """
  Returns true if the strategy uses scaled exits.
  """
  @spec scaled?(t()) :: boolean()
  def scaled?(%__MODULE__{targets: nil}), do: false
  def scaled?(%__MODULE__{targets: [_]}), do: false
  def scaled?(%__MODULE__{targets: targets}) when length(targets) > 1, do: true

  @doc """
  Returns true if the strategy has breakeven management.
  """
  @spec has_breakeven?(t()) :: boolean()
  def has_breakeven?(%__MODULE__{breakeven_config: nil}), do: false
  def has_breakeven?(%__MODULE__{}), do: true

  @doc """
  Returns the number of take profit targets.
  """
  @spec target_count(t()) :: non_neg_integer()
  def target_count(%__MODULE__{targets: nil}), do: 0
  def target_count(%__MODULE__{targets: targets}), do: length(targets)

  @doc """
  Returns the first take profit price, if any.
  """
  @spec first_target_price(t()) :: Decimal.t() | nil
  def first_target_price(%__MODULE__{targets: nil}), do: nil
  def first_target_price(%__MODULE__{targets: []}), do: nil
  def first_target_price(%__MODULE__{targets: [first | _]}), do: first.price

  @doc """
  Returns the final take profit price (last target), if any.
  """
  @spec final_target_price(t()) :: Decimal.t() | nil
  def final_target_price(%__MODULE__{targets: nil}), do: nil
  def final_target_price(%__MODULE__{targets: []}), do: nil
  def final_target_price(%__MODULE__{targets: targets}), do: List.last(targets).price

  @doc """
  Returns the strategy type as a string for persistence.
  """
  @spec type_string(t()) :: String.t()
  def type_string(%__MODULE__{type: type}), do: Atom.to_string(type)

  # ============================================================================
  # Validation Helpers
  # ============================================================================

  defp validate_trailing_type!(type) when type in [:fixed_distance, :atr_multiple, :percent] do
    :ok
  end

  defp validate_trailing_type!(type) do
    raise ArgumentError,
          "Invalid trailing type: #{inspect(type)}. " <>
            "Must be :fixed_distance, :atr_multiple, or :percent"
  end

  defp validate_positive_decimal!(value, field) do
    if Decimal.compare(value, Decimal.new(0)) != :gt do
      raise ArgumentError, "#{field} must be a positive Decimal, got: #{inspect(value)}"
    end

    :ok
  end

  defp validate_non_negative_decimal!(value, field) do
    if Decimal.compare(value, Decimal.new(0)) == :lt do
      raise ArgumentError, "#{field} must be a non-negative Decimal, got: #{inspect(value)}"
    end

    :ok
  end

  defp validate_targets!([]) do
    raise ArgumentError, "targets list cannot be empty"
  end

  defp validate_targets!(targets) do
    # Validate each target has required fields
    Enum.each(targets, fn target ->
      unless Map.has_key?(target, :price) do
        raise ArgumentError, "each target must have a :price field"
      end

      unless Map.has_key?(target, :exit_percent) do
        raise ArgumentError, "each target must have an :exit_percent field"
      end

      unless is_integer(target.exit_percent) and target.exit_percent > 0 and
               target.exit_percent <= 100 do
        raise ArgumentError,
              "exit_percent must be an integer between 1 and 100, got: #{inspect(target.exit_percent)}"
      end

      validate_stop_adjustment!(target[:move_stop_to])
    end)

    # Validate percentages sum to 100
    total = Enum.sum(Enum.map(targets, & &1.exit_percent))

    unless total == 100 do
      raise ArgumentError,
            "target exit_percent values must sum to 100, got: #{total}"
    end

    :ok
  end

  defp validate_stop_adjustment!(nil), do: :ok
  defp validate_stop_adjustment!(:breakeven), do: :ok
  defp validate_stop_adjustment!(:entry), do: :ok

  defp validate_stop_adjustment!({:price, %Decimal{} = _price}), do: :ok

  defp validate_stop_adjustment!({:price, price}) do
    raise ArgumentError,
          "stop adjustment {:price, value} requires a Decimal, got: #{inspect(price)}"
  end

  defp validate_stop_adjustment!(other) do
    raise ArgumentError,
          "invalid move_stop_to value: #{inspect(other)}. " <>
            "Must be :breakeven, :entry, {:price, Decimal.t()}, or nil"
  end
end
