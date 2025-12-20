defmodule Signal.Technicals.KeyLevels do
  @moduledoc """
  Ecto schema for daily key levels.

  Stores daily reference levels used for trading strategies including previous day
  high/low, premarket high/low, and opening range high/low.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          symbol: String.t(),
          date: Date.t(),
          previous_day_high: Decimal.t() | nil,
          previous_day_low: Decimal.t() | nil,
          previous_day_open: Decimal.t() | nil,
          previous_day_close: Decimal.t() | nil,
          premarket_high: Decimal.t() | nil,
          premarket_low: Decimal.t() | nil,
          opening_range_5m_high: Decimal.t() | nil,
          opening_range_5m_low: Decimal.t() | nil,
          opening_range_15m_high: Decimal.t() | nil,
          opening_range_15m_low: Decimal.t() | nil,
          last_week_high: Decimal.t() | nil,
          last_week_low: Decimal.t() | nil,
          last_week_close: Decimal.t() | nil,
          equilibrium: Decimal.t() | nil,
          all_time_high: Decimal.t() | nil
        }

  @primary_key false
  schema "key_levels" do
    field :symbol, :string, primary_key: true
    field :date, :date, primary_key: true
    field :previous_day_high, :decimal
    field :previous_day_low, :decimal
    field :previous_day_open, :decimal
    field :previous_day_close, :decimal
    field :premarket_high, :decimal
    field :premarket_low, :decimal
    field :opening_range_5m_high, :decimal
    field :opening_range_5m_low, :decimal
    field :opening_range_15m_high, :decimal
    field :opening_range_15m_low, :decimal
    field :last_week_high, :decimal
    field :last_week_low, :decimal
    field :last_week_close, :decimal
    field :equilibrium, :decimal
    field :all_time_high, :decimal
  end

  @doc """
  Creates a changeset for key levels.

  ## Validations

    * symbol and date are required
    * previous_day_high must be >= previous_day_low (if both present)
    * premarket_high must be >= premarket_low (if both present)
    * opening_range_5m_high must be >= opening_range_5m_low (if both present)
    * opening_range_15m_high must be >= opening_range_15m_low (if both present)
    * last_week_high must be >= last_week_low (if both present)
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(key_levels, attrs) do
    key_levels
    |> cast(attrs, [
      :symbol,
      :date,
      :previous_day_high,
      :previous_day_low,
      :previous_day_open,
      :previous_day_close,
      :premarket_high,
      :premarket_low,
      :opening_range_5m_high,
      :opening_range_5m_low,
      :opening_range_15m_high,
      :opening_range_15m_low,
      :last_week_high,
      :last_week_low,
      :last_week_close,
      :equilibrium,
      :all_time_high
    ])
    |> validate_required([:symbol, :date])
    |> validate_high_low_relationship(:previous_day_high, :previous_day_low)
    |> validate_high_low_relationship(:premarket_high, :premarket_low)
    |> validate_high_low_relationship(:opening_range_5m_high, :opening_range_5m_low)
    |> validate_high_low_relationship(:opening_range_15m_high, :opening_range_15m_low)
    |> validate_high_low_relationship(:last_week_high, :last_week_low)
  end

  defp validate_high_low_relationship(changeset, high_field, low_field) do
    high = get_field(changeset, high_field)
    low = get_field(changeset, low_field)

    if high && low && Decimal.compare(high, low) == :lt do
      add_error(changeset, high_field, "must be greater than or equal to #{low_field}")
    else
      changeset
    end
  end
end
