defmodule Signal.Backtest.FillSimulator do
  @moduledoc """
  Simulates order fills during backtests.

  Provides configurable fill assumptions for realistic trade execution simulation:

  - **Signal Price**: Fill at the exact signal price (optimistic)
  - **Next Bar Open**: Fill at the next bar's open price (more realistic)
  - **With Slippage**: Add random or fixed slippage to fills

  ## Gap Detection

  Detects when price gaps through a stop loss, simulating real-world slippage
  in fast markets. When a gap occurs, the fill is at the gap price, not the
  stop price.

  ## Example

      # Configure the fill simulator
      config = FillSimulator.new(:next_bar_open, slippage: :random, max_slippage_pct: 0.001)

      # Get entry fill price
      {:ok, fill_price} = FillSimulator.entry_fill(config, signal_price, next_bar)

      # Check for stop hit with gap
      case FillSimulator.check_stop(config, trade, current_bar) do
        {:stopped, fill_price} -> # Stop was hit, possibly with gap
        :ok -> # Stop not hit
      end
  """

  defstruct [
    :fill_type,
    :slippage_type,
    :fixed_slippage,
    :max_slippage_pct
  ]

  @type fill_type :: :signal_price | :next_bar_open | :vwap
  @type slippage_type :: :none | :fixed | :random

  @type t :: %__MODULE__{
          fill_type: fill_type(),
          slippage_type: slippage_type(),
          fixed_slippage: Decimal.t() | nil,
          max_slippage_pct: float() | nil
        }

  @doc """
  Creates a new fill simulator configuration.

  ## Options

    * `:fill_type` - How to determine fill price:
      * `:signal_price` - Fill at signal's entry price (default)
      * `:next_bar_open` - Fill at next bar's open
      * `:vwap` - Fill at bar's VWAP

    * `:slippage` - Slippage model:
      * `:none` - No slippage (default)
      * `:fixed` - Fixed amount per share
      * `:random` - Random up to max percentage

    * `:fixed_slippage` - Fixed slippage amount (when slippage: :fixed)
    * `:max_slippage_pct` - Maximum slippage percentage (when slippage: :random)
  """
  @spec new(fill_type(), keyword()) :: t()
  def new(fill_type \\ :signal_price, opts \\ []) do
    %__MODULE__{
      fill_type: fill_type,
      slippage_type: Keyword.get(opts, :slippage, :none),
      fixed_slippage: Keyword.get(opts, :fixed_slippage),
      max_slippage_pct: Keyword.get(opts, :max_slippage_pct, 0.001)
    }
  end

  @doc """
  Calculates the entry fill price for a trade.

  ## Parameters

    * `config` - Fill simulator configuration
    * `signal_price` - Original signal price
    * `direction` - `:long` or `:short`
    * `next_bar` - The bar after the signal (optional, for :next_bar_open)

  ## Returns

    * `{:ok, fill_price, slippage}` - Successful fill
    * `{:error, :no_bar}` - No bar available for next_bar_open fill type
  """
  @spec entry_fill(t(), Decimal.t(), atom(), map() | nil) ::
          {:ok, Decimal.t(), Decimal.t()} | {:error, atom()}
  def entry_fill(config, signal_price, direction, next_bar \\ nil) do
    base_price =
      case config.fill_type do
        :signal_price ->
          signal_price

        :next_bar_open ->
          if next_bar do
            next_bar.open
          else
            signal_price
          end

        :vwap ->
          if next_bar && next_bar.vwap do
            next_bar.vwap
          else
            signal_price
          end
      end

    {slippage, fill_price} = apply_slippage(config, base_price, direction, :entry)

    {:ok, fill_price, slippage}
  end

  @doc """
  Checks if a stop loss has been hit and calculates the exit price.

  Handles gap scenarios where price gaps through the stop.

  ## Parameters

    * `config` - Fill simulator configuration
    * `trade` - The open trade
    * `bar` - Current bar to check

  ## Returns

    * `:ok` - Stop not hit
    * `{:stopped, fill_price, gap?}` - Stop hit, with gap indicator
  """
  @spec check_stop(t(), map(), map()) :: :ok | {:stopped, Decimal.t(), boolean()}
  def check_stop(_config, trade, bar) do
    case trade.direction do
      :long ->
        if Decimal.compare(bar.low, trade.stop_loss) in [:lt, :eq] do
          # Check for gap through stop
          gap? = Decimal.compare(bar.open, trade.stop_loss) == :lt
          fill_price = if gap?, do: bar.open, else: trade.stop_loss
          {:stopped, fill_price, gap?}
        else
          :ok
        end

      :short ->
        if Decimal.compare(bar.high, trade.stop_loss) in [:gt, :eq] do
          # Check for gap through stop
          gap? = Decimal.compare(bar.open, trade.stop_loss) == :gt
          fill_price = if gap?, do: bar.open, else: trade.stop_loss
          {:stopped, fill_price, gap?}
        else
          :ok
        end
    end
  end

  @doc """
  Checks if a take profit target has been hit.

  ## Parameters

    * `config` - Fill simulator configuration
    * `trade` - The open trade
    * `bar` - Current bar to check

  ## Returns

    * `:ok` - Target not hit
    * `{:target_hit, fill_price}` - Target hit
  """
  @spec check_target(t(), map(), map()) :: :ok | {:target_hit, Decimal.t()}
  def check_target(_config, trade, bar) do
    case trade.take_profit do
      nil ->
        :ok

      target ->
        case trade.direction do
          :long ->
            if Decimal.compare(bar.high, target) in [:gt, :eq] do
              {:target_hit, target}
            else
              :ok
            end

          :short ->
            if Decimal.compare(bar.low, target) in [:lt, :eq] do
              {:target_hit, target}
            else
              :ok
            end
        end
    end
  end

  @doc """
  Calculates exit fill price for manual or time-based exits.

  Uses the bar's close price with slippage applied.
  """
  @spec exit_fill(t(), map(), atom()) :: {:ok, Decimal.t(), Decimal.t()}
  def exit_fill(config, bar, direction) do
    base_price = bar.close
    {slippage, fill_price} = apply_slippage(config, base_price, direction, :exit)
    {:ok, fill_price, slippage}
  end

  # Private Functions

  defp apply_slippage(config, base_price, direction, order_type) do
    case config.slippage_type do
      :none ->
        {Decimal.new(0), base_price}

      :fixed ->
        slippage = config.fixed_slippage || Decimal.new(0)
        fill_price = apply_slippage_direction(base_price, slippage, direction, order_type)
        {slippage, fill_price}

      :random ->
        max_pct = config.max_slippage_pct || 0.001
        random_pct = :rand.uniform() * max_pct
        slippage = Decimal.mult(base_price, Decimal.from_float(random_pct))
        fill_price = apply_slippage_direction(base_price, slippage, direction, order_type)
        {Decimal.round(slippage, 4), fill_price}
    end
  end

  # For entries: slippage works against us (buy higher, sell lower)
  # For exits: slippage works against us (sell lower, buy higher)
  defp apply_slippage_direction(price, slippage, direction, order_type) do
    case {direction, order_type} do
      {:long, :entry} -> Decimal.add(price, slippage)
      {:long, :exit} -> Decimal.sub(price, slippage)
      {:short, :entry} -> Decimal.sub(price, slippage)
      {:short, :exit} -> Decimal.add(price, slippage)
    end
  end
end
