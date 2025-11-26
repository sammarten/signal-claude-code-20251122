defmodule Signal.Strategies.Setup do
  @moduledoc """
  Represents a trade setup detected by a strategy.

  A Setup contains all the information needed to evaluate and potentially
  execute a trade, including entry/exit prices, risk parameters, and
  confluence factors.

  ## Fields

  * `symbol` - The trading symbol (e.g., "AAPL")
  * `strategy` - The strategy that generated this setup
  * `direction` - Trade direction (:long or :short)
  * `level_type` - Type of level that was broken/retested
  * `level_price` - The price of the key level
  * `entry_price` - Proposed entry price
  * `stop_loss` - Stop loss price
  * `take_profit` - Take profit target
  * `risk_reward` - Calculated risk/reward ratio
  * `retest_bar` - The bar where retest occurred
  * `break_bar` - The bar where the break occurred
  * `confluence` - Map of confluence factors
  * `quality_score` - Overall quality score (0-10)
  * `timestamp` - When the setup was detected
  * `status` - Current status (:pending, :active, :filled, :expired, :invalidated)
  * `expires_at` - When the setup expires if not filled
  """

  alias Signal.MarketData.Bar

  @type level_type ::
          :pdh
          | :pdl
          | :pmh
          | :pml
          | :or5h
          | :or5l
          | :or15h
          | :or15l
          | :swing_high
          | :swing_low
          | :order_block
          | :fvg

  @type strategy_type ::
          :break_and_retest
          | :opening_range_breakout
          | :one_candle_rule
          | :premarket_breakout

  @type status :: :pending | :active | :filled | :expired | :invalidated

  @type t :: %__MODULE__{
          symbol: String.t(),
          strategy: strategy_type(),
          direction: :long | :short,
          level_type: level_type(),
          level_price: Decimal.t(),
          entry_price: Decimal.t(),
          stop_loss: Decimal.t(),
          take_profit: Decimal.t(),
          risk_reward: Decimal.t(),
          retest_bar: Bar.t() | nil,
          break_bar: Bar.t() | nil,
          confluence: map(),
          quality_score: integer(),
          timestamp: DateTime.t(),
          status: status(),
          expires_at: DateTime.t() | nil
        }

  defstruct [
    :symbol,
    :strategy,
    :direction,
    :level_type,
    :level_price,
    :entry_price,
    :stop_loss,
    :take_profit,
    :risk_reward,
    :retest_bar,
    :break_bar,
    :confluence,
    :quality_score,
    :timestamp,
    :status,
    :expires_at
  ]

  @doc """
  Creates a new Setup with calculated risk/reward ratio.

  ## Parameters

    * `attrs` - Map of setup attributes

  ## Returns

  A new Setup struct with calculated risk_reward.

  ## Examples

      iex> Setup.new(%{
      ...>   symbol: "AAPL",
      ...>   strategy: :break_and_retest,
      ...>   direction: :long,
      ...>   entry_price: Decimal.new("175.50"),
      ...>   stop_loss: Decimal.new("175.00"),
      ...>   take_profit: Decimal.new("176.50")
      ...> })
      %Setup{risk_reward: #Decimal<2.0>, ...}
  """
  @spec new(map()) :: t()
  def new(attrs) do
    setup = struct(__MODULE__, attrs)

    setup
    |> calculate_risk_reward()
    |> set_defaults()
  end

  @doc """
  Calculates the risk/reward ratio for a setup.

  ## Parameters

    * `setup` - The setup to calculate R:R for

  ## Returns

  Setup with updated risk_reward field.
  """
  @spec calculate_risk_reward(t()) :: t()
  def calculate_risk_reward(%__MODULE__{} = setup) do
    case {setup.entry_price, setup.stop_loss, setup.take_profit} do
      {entry, stop, target} when not is_nil(entry) and not is_nil(stop) and not is_nil(target) ->
        risk = Decimal.abs(Decimal.sub(entry, stop))
        reward = Decimal.abs(Decimal.sub(target, entry))

        rr =
          if Decimal.compare(risk, Decimal.new(0)) == :gt do
            Decimal.div(reward, risk) |> Decimal.round(2)
          else
            Decimal.new(0)
          end

        %{setup | risk_reward: rr}

      _ ->
        setup
    end
  end

  @doc """
  Checks if the setup meets minimum risk/reward requirements.

  ## Parameters

    * `setup` - The setup to check
    * `min_rr` - Minimum risk/reward ratio (default: 2.0)

  ## Returns

  Boolean indicating if R:R requirement is met.
  """
  @spec meets_risk_reward?(t(), Decimal.t()) :: boolean()
  def meets_risk_reward?(%__MODULE__{risk_reward: rr}, min_rr \\ Decimal.new("2.0")) do
    rr != nil and Decimal.compare(rr, min_rr) != :lt
  end

  @doc """
  Checks if the setup is within the valid trading window.

  Default trading window is 9:30 AM - 11:00 AM ET.

  ## Parameters

    * `setup` - The setup to check
    * `opts` - Options
      * `:start_time` - Window start time (default: ~T[09:30:00])
      * `:end_time` - Window end time (default: ~T[11:00:00])
      * `:timezone` - Timezone (default: "America/New_York")

  ## Returns

  Boolean indicating if setup is within trading window.
  """
  @spec within_trading_window?(t(), keyword()) :: boolean()
  def within_trading_window?(%__MODULE__{timestamp: timestamp}, opts \\ []) do
    start_time = Keyword.get(opts, :start_time, ~T[09:30:00])
    end_time = Keyword.get(opts, :end_time, ~T[11:00:00])
    timezone = Keyword.get(opts, :timezone, "America/New_York")

    case DateTime.shift_zone(timestamp, timezone) do
      {:ok, local_time} ->
        time = DateTime.to_time(local_time)
        Time.compare(time, start_time) != :lt and Time.compare(time, end_time) != :gt

      {:error, _reason} ->
        # If timezone conversion fails, conservatively return false
        # This can happen if tzdata is not configured
        false
    end
  end

  @doc """
  Checks if a setup has expired.

  ## Parameters

    * `setup` - The setup to check

  ## Returns

  Boolean indicating if the setup has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Marks a setup as expired.

  ## Parameters

    * `setup` - The setup to expire

  ## Returns

  Updated setup with status set to :expired.
  """
  @spec expire(t()) :: t()
  def expire(%__MODULE__{} = setup) do
    %{setup | status: :expired}
  end

  @doc """
  Marks a setup as invalidated (e.g., level was reclaimed).

  ## Parameters

    * `setup` - The setup to invalidate

  ## Returns

  Updated setup with status set to :invalidated.
  """
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{} = setup) do
    %{setup | status: :invalidated}
  end

  @doc """
  Checks if a setup is still valid (not expired or invalidated).

  ## Parameters

    * `setup` - The setup to check

  ## Returns

  Boolean indicating if the setup is still valid.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{status: status} = setup) do
    status in [:pending, :active] and not expired?(setup)
  end

  # Private Functions

  defp set_defaults(%__MODULE__{} = setup) do
    setup
    |> set_default_timestamp()
    |> set_default_status()
    |> set_default_expiry()
  end

  defp set_default_timestamp(%__MODULE__{timestamp: nil} = setup) do
    %{setup | timestamp: DateTime.utc_now()}
  end

  defp set_default_timestamp(setup), do: setup

  defp set_default_status(%__MODULE__{status: nil} = setup) do
    %{setup | status: :pending}
  end

  defp set_default_status(setup), do: setup

  defp set_default_expiry(%__MODULE__{expires_at: nil, timestamp: timestamp} = setup)
       when not is_nil(timestamp) do
    # Default expiry: 30 minutes from timestamp
    %{setup | expires_at: DateTime.add(timestamp, 30 * 60, :second)}
  end

  defp set_default_expiry(setup), do: setup
end
