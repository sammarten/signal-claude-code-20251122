defmodule Signal.MarketStatus do
  @moduledoc """
  Determines the current US stock market status based on Eastern Time.

  ## Market Sessions

  - `:pre_market` - 4:00 AM - 9:30 AM ET (Monday-Friday)
  - `:open` - 9:30 AM - 4:00 PM ET (Monday-Friday)
  - `:after_hours` - 4:00 PM - 8:00 PM ET (Monday-Friday)
  - `:closed` - 8:00 PM - 4:00 AM ET, and all day Saturday/Sunday

  ## Usage

      iex> Signal.MarketStatus.current()
      :open

      iex> Signal.MarketStatus.label(:pre_market)
      "Pre-Market"

  Note: This does not account for market holidays. For production use,
  consider integrating with a market calendar API.
  """

  @timezone "America/New_York"

  @pre_market_open ~T[04:00:00]
  @market_open ~T[09:30:00]
  @market_close ~T[16:00:00]
  @after_hours_close ~T[20:00:00]

  @type status :: :pre_market | :open | :after_hours | :closed

  @doc """
  Returns the current market status.

  ## Examples

      iex> Signal.MarketStatus.current()
      :open  # during regular trading hours
  """
  @spec current() :: status()
  def current do
    current(DateTime.utc_now())
  end

  @doc """
  Returns the market status for a given UTC datetime.

  ## Parameters

    - `utc_datetime` - DateTime in UTC

  ## Examples

      iex> Signal.MarketStatus.current(~U[2024-11-25 15:00:00Z])
      :open  # 10:00 AM ET on a Monday
  """
  @spec current(DateTime.t()) :: status()
  def current(utc_datetime) do
    case DateTime.shift_zone(utc_datetime, @timezone) do
      {:ok, et_datetime} ->
        determine_status(et_datetime)

      {:error, _} ->
        # Fallback if timezone conversion fails
        :closed
    end
  end

  @doc """
  Returns a human-readable label for the market status.

  ## Examples

      iex> Signal.MarketStatus.label(:pre_market)
      "Pre-Market"

      iex> Signal.MarketStatus.label(:open)
      "Open"
  """
  @spec label(status()) :: String.t()
  def label(:pre_market), do: "Pre-Market"
  def label(:open), do: "Open"
  def label(:after_hours), do: "After Hours"
  def label(:closed), do: "Closed"

  @doc """
  Returns the CSS color class for the market status.

  ## Examples

      iex> Signal.MarketStatus.color_class(:open)
      "text-green-400"
  """
  @spec color_class(status()) :: String.t()
  def color_class(:pre_market), do: "text-yellow-400"
  def color_class(:open), do: "text-green-400"
  def color_class(:after_hours), do: "text-blue-400"
  def color_class(:closed), do: "text-zinc-500"

  @doc """
  Returns the CSS background class for the market status badge.

  ## Examples

      iex> Signal.MarketStatus.badge_class(:open)
      "bg-green-500/20 text-green-400 border border-green-500/30"
  """
  @spec badge_class(status()) :: String.t()
  def badge_class(:pre_market), do: "bg-yellow-500/20 text-yellow-400 border border-yellow-500/30"
  def badge_class(:open), do: "bg-green-500/20 text-green-400 border border-green-500/30"
  def badge_class(:after_hours), do: "bg-blue-500/20 text-blue-400 border border-blue-500/30"
  def badge_class(:closed), do: "bg-zinc-800/50 text-zinc-400 border border-zinc-700"

  @doc """
  Returns true if the market is currently accepting trades (regular hours).

  ## Examples

      iex> Signal.MarketStatus.open?()
      true  # during 9:30 AM - 4:00 PM ET
  """
  @spec open?() :: boolean()
  def open?, do: current() == :open

  @doc """
  Returns true if extended hours trading is available (pre-market or after-hours).

  ## Examples

      iex> Signal.MarketStatus.extended_hours?()
      true  # during pre-market or after-hours
  """
  @spec extended_hours?() :: boolean()
  def extended_hours? do
    current() in [:pre_market, :after_hours]
  end

  @doc """
  Returns true if any trading session is active (regular or extended).

  ## Examples

      iex> Signal.MarketStatus.trading_active?()
      true  # during any trading session
  """
  @spec trading_active?() :: boolean()
  def trading_active? do
    current() in [:pre_market, :open, :after_hours]
  end

  # Private functions

  defp determine_status(et_datetime) do
    day_of_week = Date.day_of_week(DateTime.to_date(et_datetime))
    current_time = DateTime.to_time(et_datetime)

    cond do
      # Weekend - always closed
      day_of_week in [6, 7] ->
        :closed

      # Pre-market: 4:00 AM - 9:30 AM ET
      Time.compare(current_time, @pre_market_open) != :lt and
          Time.compare(current_time, @market_open) == :lt ->
        :pre_market

      # Regular hours: 9:30 AM - 4:00 PM ET
      Time.compare(current_time, @market_open) != :lt and
          Time.compare(current_time, @market_close) == :lt ->
        :open

      # After hours: 4:00 PM - 8:00 PM ET
      Time.compare(current_time, @market_close) != :lt and
          Time.compare(current_time, @after_hours_close) == :lt ->
        :after_hours

      # Closed: before 4:00 AM or after 8:00 PM
      true ->
        :closed
    end
  end
end
