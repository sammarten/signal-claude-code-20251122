defmodule Signal.Signals.TradeSignal do
  @moduledoc """
  Ecto schema for trade signals.

  A trade signal represents a detected trading opportunity with all the
  information needed to evaluate and potentially execute a trade.

  ## Fields

  * `symbol` - The trading symbol (e.g., "AAPL")
  * `strategy` - The strategy that generated this signal
  * `direction` - Trade direction ("long" or "short")
  * `entry_price` - Proposed entry price
  * `stop_loss` - Stop loss price
  * `take_profit` - Take profit target
  * `risk_reward` - Calculated risk/reward ratio
  * `confluence_score` - Total confluence score (0-13)
  * `quality_grade` - Letter grade ("A", "B", "C", "D", "F")
  * `confluence_factors` - Map of individual confluence factors
  * `status` - Current status
  * `generated_at` - When the signal was generated
  * `expires_at` - When the signal expires if not filled
  * `filled_at` - When the signal was filled (if applicable)
  * `exit_price` - Exit price (if filled)
  * `pnl` - Profit/loss (if closed)

  ## Status Values

  * `active` - Signal is currently valid and can be taken
  * `filled` - Signal was taken and position opened
  * `expired` - Signal expired without being taken
  * `invalidated` - Signal was invalidated (e.g., level reclaimed)
  * `cancelled` - Signal was manually cancelled
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type strategy ::
          :break_and_retest | :opening_range_breakout | :one_candle_rule | :premarket_breakout
  @type direction :: :long | :short
  @type status :: :active | :filled | :expired | :invalidated | :cancelled
  @type quality_grade :: :A | :B | :C | :D | :F

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          symbol: String.t(),
          strategy: String.t(),
          direction: String.t(),
          entry_price: Decimal.t(),
          stop_loss: Decimal.t(),
          take_profit: Decimal.t(),
          risk_reward: Decimal.t(),
          confluence_score: integer(),
          quality_grade: String.t(),
          confluence_factors: map(),
          status: String.t(),
          generated_at: DateTime.t(),
          expires_at: DateTime.t(),
          filled_at: DateTime.t() | nil,
          exit_price: Decimal.t() | nil,
          pnl: Decimal.t() | nil,
          level_type: String.t() | nil,
          level_price: Decimal.t() | nil,
          retest_bar_time: DateTime.t() | nil,
          break_bar_time: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "trade_signals" do
    field :symbol, :string
    field :strategy, :string
    field :direction, :string
    field :entry_price, :decimal
    field :stop_loss, :decimal
    field :take_profit, :decimal
    field :risk_reward, :decimal
    field :confluence_score, :integer
    field :quality_grade, :string
    field :confluence_factors, :map
    field :status, :string, default: "active"
    field :generated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :filled_at, :utc_datetime_usec
    field :exit_price, :decimal
    field :pnl, :decimal
    field :level_type, :string
    field :level_price, :decimal
    field :retest_bar_time, :utc_datetime_usec
    field :break_bar_time, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :symbol,
    :strategy,
    :direction,
    :entry_price,
    :stop_loss,
    :take_profit,
    :risk_reward,
    :confluence_score,
    :quality_grade,
    :generated_at,
    :expires_at
  ]

  @optional_fields [
    :confluence_factors,
    :status,
    :filled_at,
    :exit_price,
    :pnl,
    :level_type,
    :level_price,
    :retest_bar_time,
    :break_bar_time
  ]

  @valid_strategies [
    "break_and_retest",
    "opening_range_breakout",
    "one_candle_rule",
    "premarket_breakout"
  ]
  @valid_directions ["long", "short"]
  @valid_statuses ["active", "filled", "expired", "invalidated", "cancelled"]
  @valid_grades ["A", "B", "C", "D", "F"]

  @doc """
  Creates a changeset for a new trade signal.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = signal, attrs) do
    signal
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:strategy, @valid_strategies)
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:quality_grade, @valid_grades)
    |> validate_number(:confluence_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 13)
    |> validate_number(:risk_reward, greater_than: 0)
    |> validate_prices()
  end

  @doc """
  Creates a changeset for updating signal status.
  """
  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = signal, attrs) do
    signal
    |> cast(attrs, [:status, :filled_at, :exit_price, :pnl])
    |> validate_inclusion(:status, @valid_statuses)
  end

  # Validates that stop_loss and take_profit make sense for the direction
  defp validate_prices(changeset) do
    direction = get_field(changeset, :direction)
    entry = get_field(changeset, :entry_price)
    stop = get_field(changeset, :stop_loss)
    target = get_field(changeset, :take_profit)

    cond do
      is_nil(direction) or is_nil(entry) or is_nil(stop) or is_nil(target) ->
        changeset

      direction == "long" ->
        changeset
        |> validate_stop_below_entry(entry, stop)
        |> validate_target_above_entry(entry, target)

      direction == "short" ->
        changeset
        |> validate_stop_above_entry(entry, stop)
        |> validate_target_below_entry(entry, target)

      true ->
        changeset
    end
  end

  defp validate_stop_below_entry(changeset, entry, stop) do
    if Decimal.compare(stop, entry) != :lt do
      add_error(changeset, :stop_loss, "must be below entry price for long positions")
    else
      changeset
    end
  end

  defp validate_target_above_entry(changeset, entry, target) do
    if Decimal.compare(target, entry) != :gt do
      add_error(changeset, :take_profit, "must be above entry price for long positions")
    else
      changeset
    end
  end

  defp validate_stop_above_entry(changeset, entry, stop) do
    if Decimal.compare(stop, entry) != :gt do
      add_error(changeset, :stop_loss, "must be above entry price for short positions")
    else
      changeset
    end
  end

  defp validate_target_below_entry(changeset, entry, target) do
    if Decimal.compare(target, entry) != :lt do
      add_error(changeset, :take_profit, "must be below entry price for short positions")
    else
      changeset
    end
  end
end
