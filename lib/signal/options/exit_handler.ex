defmodule Signal.Options.ExitHandler do
  @moduledoc """
  Handles options-specific exit conditions for backtesting.

  Options have unique exit considerations beyond standard equity exits:
  - Expiration: Must exit before or at expiration
  - Premium targets: Exit based on option price, not underlying
  - Time decay: May want to exit before significant theta decay

  ## Exit Types

  ### Expiration-Based
  - Force exit on expiration day (or day before)
  - Configurable exit time on expiration day

  ### Premium-Based
  - Exit when premium reaches a target multiple of entry
  - Exit when premium drops below a floor (stop loss on premium)

  ### Underlying-Based
  - Exit based on underlying price hitting stop/target levels
  - These work similarly to equity exits but trigger option exits

  ## Usage

      # Check if position should be exited
      case ExitHandler.check_exit(position, current_bar, underlying_bar) do
        {:exit, reason, exit_price} -> # Close position
        :hold -> # Continue holding
      end
  """

  alias Signal.Options.PriceLookup

  @type exit_reason ::
          :expiration
          | :expiration_day_exit
          | :premium_target
          | :premium_stop
          | :underlying_stop
          | :underlying_target
          | :time_exit

  @type exit_result :: {:exit, exit_reason(), Decimal.t()} | :hold

  @doc """
  Checks all exit conditions for an options position.

  ## Parameters

    * `position` - Map containing position details:
      - `:contract_symbol` - OSI format symbol
      - `:expiration` - Expiration Date
      - `:entry_premium` - Premium paid per share
      - `:direction` - :long (for the underlying direction)
      - `:stop_loss` - Stop loss on underlying price
      - `:take_profit` - Take profit on underlying price (optional)
      - `:premium_target` - Target premium for exit (optional)
      - `:premium_floor` - Stop loss on premium (optional)
    * `option_bar` - Current options bar (with premium OHLC)
    * `underlying_bar` - Current underlying bar (with underlying OHLC)
    * `opts` - Options:
      - `:exit_before_expiration` - Days before expiration to exit (default: 0)
      - `:expiration_exit_time` - Time to exit on expiration day (default: ~T[15:45:00])

  ## Returns

    * `{:exit, reason, exit_price}` - Position should be closed
    * `:hold` - Position should be held
  """
  @spec check_exit(map(), map(), map(), keyword()) :: exit_result()
  def check_exit(position, option_bar, underlying_bar, opts \\ []) do
    # Check conditions in priority order
    with :hold <- check_expiration(position, option_bar, opts),
         :hold <- check_premium_target(position, option_bar),
         :hold <- check_premium_stop(position, option_bar),
         :hold <- check_underlying_stop(position, underlying_bar),
         :hold <- check_underlying_target(position, underlying_bar) do
      :hold
    else
      {:exit, _reason, _price} = exit -> exit
    end
  end

  @doc """
  Checks if the option is at or past expiration.

  ## Parameters

    * `position` - Position with `:expiration` date
    * `option_bar` - Current bar for exit price
    * `opts` - Options:
      - `:exit_before_expiration` - Days before expiration to force exit
      - `:expiration_exit_time` - Time on expiration day to exit

  ## Returns

    * `{:exit, :expiration | :expiration_day_exit, premium}` if should exit
    * `:hold` if not at expiration
  """
  @spec check_expiration(map(), map(), keyword()) :: exit_result()
  def check_expiration(position, option_bar, opts \\ []) do
    exit_days_before = Keyword.get(opts, :exit_before_expiration, 0)
    expiration_exit_time = Keyword.get(opts, :expiration_exit_time, ~T[15:45:00])

    bar_date = DateTime.to_date(option_bar.bar_time)
    bar_time = DateTime.to_time(option_bar.bar_time)

    # Calculate the effective exit date
    exit_date = Date.add(position.expiration, -exit_days_before)

    cond do
      # Past expiration - force immediate exit
      Date.compare(bar_date, position.expiration) == :gt ->
        {:exit, :expiration, option_bar.close}

      # On expiration day, past exit time
      Date.compare(bar_date, position.expiration) == :eq and
          Time.compare(bar_time, expiration_exit_time) in [:gt, :eq] ->
        {:exit, :expiration_day_exit, option_bar.close}

      # On early exit date (if exit_days_before > 0)
      exit_days_before > 0 and Date.compare(bar_date, exit_date) in [:eq, :gt] ->
        {:exit, :expiration_day_exit, option_bar.close}

      true ->
        :hold
    end
  end

  @doc """
  Checks if the option premium has reached the target.

  ## Parameters

    * `position` - Position with optional `:premium_target`
    * `option_bar` - Current bar for premium prices

  ## Returns

    * `{:exit, :premium_target, premium}` if target hit
    * `:hold` if no target or not hit
  """
  @spec check_premium_target(map(), map()) :: exit_result()
  def check_premium_target(%{premium_target: nil}, _bar), do: :hold

  def check_premium_target(%{premium_target: target}, bar) when not is_nil(target) do
    # Check if high reached target (for long options)
    if Decimal.compare(bar.high, target) in [:gt, :eq] do
      # Use target price as fill (conservative)
      {:exit, :premium_target, target}
    else
      :hold
    end
  end

  def check_premium_target(_position, _bar), do: :hold

  @doc """
  Checks if the option premium has fallen below the stop floor.

  ## Parameters

    * `position` - Position with optional `:premium_floor`
    * `option_bar` - Current bar for premium prices

  ## Returns

    * `{:exit, :premium_stop, premium}` if floor breached
    * `:hold` if no floor or not breached
  """
  @spec check_premium_stop(map(), map()) :: exit_result()
  def check_premium_stop(%{premium_floor: nil}, _bar), do: :hold

  def check_premium_stop(%{premium_floor: floor}, bar) when not is_nil(floor) do
    # Check if low breached floor (for long options)
    if Decimal.compare(bar.low, floor) in [:lt, :eq] do
      {:exit, :premium_stop, floor}
    else
      :hold
    end
  end

  def check_premium_stop(_position, _bar), do: :hold

  @doc """
  Checks if the underlying price has hit the stop loss.

  For calls: stop is triggered when underlying falls below stop_loss
  For puts: stop is triggered when underlying rises above stop_loss

  ## Parameters

    * `position` - Position with `:stop_loss`, `:direction`, and `:contract_type`
    * `underlying_bar` - Current underlying bar

  ## Returns

    * `{:exit, :underlying_stop, underlying_price}` if stop hit
    * `:hold` if not hit
  """
  @spec check_underlying_stop(map(), map()) :: exit_result()
  def check_underlying_stop(%{stop_loss: nil}, _bar), do: :hold

  def check_underlying_stop(position, underlying_bar) do
    stop = position.stop_loss
    # For options, direction indicates bullish/bearish bias
    # :long direction = bought calls (bullish) - stop if underlying drops
    # :short direction = bought puts (bearish) - stop if underlying rises
    direction = Map.get(position, :direction, :long)

    stop_hit =
      case direction do
        :long ->
          # Bullish position (calls) - stop if underlying drops below stop
          Decimal.compare(underlying_bar.low, stop) in [:lt, :eq]

        :short ->
          # Bearish position (puts) - stop if underlying rises above stop
          Decimal.compare(underlying_bar.high, stop) in [:gt, :eq]
      end

    if stop_hit do
      # Return the stop price as the trigger (actual option exit price
      # should be looked up separately)
      {:exit, :underlying_stop, stop}
    else
      :hold
    end
  end

  @doc """
  Checks if the underlying price has hit the take profit target.

  For calls: target hit when underlying rises above take_profit
  For puts: target hit when underlying falls below take_profit

  ## Parameters

    * `position` - Position with `:take_profit` and `:direction`
    * `underlying_bar` - Current underlying bar

  ## Returns

    * `{:exit, :underlying_target, underlying_price}` if target hit
    * `:hold` if not hit
  """
  @spec check_underlying_target(map(), map()) :: exit_result()
  def check_underlying_target(%{take_profit: nil}, _bar), do: :hold

  def check_underlying_target(position, underlying_bar) do
    target = position.take_profit
    direction = Map.get(position, :direction, :long)

    target_hit =
      case direction do
        :long ->
          # Bullish position (calls) - target if underlying rises above target
          Decimal.compare(underlying_bar.high, target) in [:gt, :eq]

        :short ->
          # Bearish position (puts) - target if underlying falls below target
          Decimal.compare(underlying_bar.low, target) in [:lt, :eq]
      end

    if target_hit do
      {:exit, :underlying_target, target}
    else
      :hold
    end
  end

  @doc """
  Calculates a premium target based on a multiple of entry premium.

  ## Parameters

    * `entry_premium` - Premium paid at entry
    * `target_multiple` - Multiple of entry premium (e.g., 2.0 for 100% gain)

  ## Returns

    * Target premium as Decimal
  """
  @spec premium_target_from_multiple(Decimal.t(), number()) :: Decimal.t()
  def premium_target_from_multiple(entry_premium, target_multiple) do
    Decimal.mult(entry_premium, Decimal.from_float(target_multiple))
  end

  @doc """
  Calculates a premium floor based on a percentage of entry premium.

  ## Parameters

    * `entry_premium` - Premium paid at entry
    * `floor_percentage` - Percentage to keep (e.g., 0.5 for 50% loss stop)

  ## Returns

    * Floor premium as Decimal
  """
  @spec premium_floor_from_percentage(Decimal.t(), number()) :: Decimal.t()
  def premium_floor_from_percentage(entry_premium, floor_percentage) do
    Decimal.mult(entry_premium, Decimal.from_float(floor_percentage))
  end

  @doc """
  Gets the actual option exit price when an exit is triggered.

  Since underlying-based exits return the underlying price, this function
  looks up the actual option premium at the exit time.

  ## Parameters

    * `contract_symbol` - OSI format symbol
    * `exit_time` - DateTime of exit
    * `exit_reason` - The reason for exit
    * `trigger_price` - The price that triggered the exit

  ## Returns

    * `{:ok, option_premium}` - The actual option exit price
    * `{:error, reason}` - If price lookup failed
  """
  @spec get_option_exit_price(String.t(), DateTime.t(), exit_reason(), Decimal.t()) ::
          {:ok, Decimal.t()} | {:error, atom()}
  def get_option_exit_price(contract_symbol, exit_time, exit_reason, _trigger_price) do
    case exit_reason do
      # For premium-based exits, trigger price is the option price
      reason when reason in [:premium_target, :premium_stop, :expiration, :expiration_day_exit] ->
        PriceLookup.get_exit_price(contract_symbol, exit_time)

      # For underlying-based exits, need to look up option price
      reason when reason in [:underlying_stop, :underlying_target] ->
        PriceLookup.get_exit_price(contract_symbol, exit_time)

      _ ->
        PriceLookup.get_exit_price(contract_symbol, exit_time)
    end
  end
end
