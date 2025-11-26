defmodule Signal.Technicals.PdArrays.PdArray do
  @moduledoc """
  Ecto schema for PD Arrays (Price Delivery Arrays).

  PD Arrays are premium/discount zones where institutional order flow is concentrated.
  This schema stores both Fair Value Gaps (FVG) and Order Blocks (OB).

  ## Types

  * `fvg` - Fair Value Gap: An imbalance in price where there's a gap between candles
  * `order_block` - Order Block: Last opposing candle(s) before a break of structure

  ## Directions

  * `bullish` - Indicates a zone likely to act as support
  * `bearish` - Indicates a zone likely to act as resistance

  ## Mitigation

  A PD Array is considered mitigated when price returns to and trades through the zone,
  filling the imbalance or tapping the order block.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          symbol: String.t(),
          type: String.t(),
          direction: String.t(),
          top: Decimal.t(),
          bottom: Decimal.t(),
          created_at: DateTime.t(),
          mitigated: boolean(),
          mitigated_at: DateTime.t() | nil,
          quality_score: integer() | nil,
          metadata: map() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "pd_arrays" do
    field :symbol, :string
    field :type, :string
    field :direction, :string
    field :top, :decimal
    field :bottom, :decimal
    field :created_at, :utc_datetime_usec
    field :mitigated, :boolean, default: false
    field :mitigated_at, :utc_datetime_usec
    field :quality_score, :integer
    field :metadata, :map

    timestamps(type: :utc_datetime_usec)
  end

  @valid_types ["order_block", "fvg"]
  @valid_directions ["bullish", "bearish"]

  @doc """
  Creates a changeset for a PD Array.

  ## Validations

    * symbol, type, direction, top, bottom, and created_at are required
    * type must be one of: "order_block", "fvg"
    * direction must be one of: "bullish", "bearish"
    * top must be >= bottom
    * mitigated_at is required if mitigated is true
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pd_array, attrs) do
    pd_array
    |> cast(attrs, [
      :symbol,
      :type,
      :direction,
      :top,
      :bottom,
      :created_at,
      :mitigated,
      :mitigated_at,
      :quality_score,
      :metadata
    ])
    |> validate_required([:symbol, :type, :direction, :top, :bottom, :created_at])
    |> validate_inclusion(:type, @valid_types)
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_top_above_bottom()
    |> validate_mitigation_timestamp()
  end

  defp validate_top_above_bottom(changeset) do
    top = get_field(changeset, :top)
    bottom = get_field(changeset, :bottom)

    if top && bottom && Decimal.compare(top, bottom) == :lt do
      add_error(changeset, :top, "must be greater than or equal to bottom")
    else
      changeset
    end
  end

  defp validate_mitigation_timestamp(changeset) do
    mitigated = get_field(changeset, :mitigated)
    mitigated_at = get_field(changeset, :mitigated_at)

    cond do
      mitigated && is_nil(mitigated_at) ->
        add_error(changeset, :mitigated_at, "is required when mitigated is true")

      !mitigated && !is_nil(mitigated_at) ->
        add_error(changeset, :mitigated_at, "should be nil when mitigated is false")

      true ->
        changeset
    end
  end
end
