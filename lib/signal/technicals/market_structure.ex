defmodule Signal.Technicals.MarketStructure do
  @moduledoc """
  Ecto schema for market structure data.

  Stores swing points, break of structure (BOS), and change of character (ChoCh)
  detections for different timeframes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          symbol: String.t(),
          timeframe: String.t(),
          bar_time: DateTime.t(),
          trend: String.t() | nil,
          swing_type: String.t() | nil,
          swing_price: Decimal.t() | nil,
          bos_detected: boolean(),
          choch_detected: boolean()
        }

  @primary_key false
  schema "market_structure" do
    field :symbol, :string, primary_key: true
    field :timeframe, :string, primary_key: true
    field :bar_time, :utc_datetime_usec, primary_key: true
    field :trend, :string
    field :swing_type, :string
    field :swing_price, :decimal
    field :bos_detected, :boolean, default: false
    field :choch_detected, :boolean, default: false
  end

  @doc """
  Creates a changeset for market structure.

  ## Validations

    * symbol, timeframe, and bar_time are required
    * trend must be one of: "bullish", "bearish", "ranging" (if present)
    * swing_type must be one of: "high", "low" (if present)
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(market_structure, attrs) do
    market_structure
    |> cast(attrs, [
      :symbol,
      :timeframe,
      :bar_time,
      :trend,
      :swing_type,
      :swing_price,
      :bos_detected,
      :choch_detected
    ])
    |> validate_required([:symbol, :timeframe, :bar_time])
    |> validate_inclusion(:trend, ["bullish", "bearish", "ranging"])
    |> validate_inclusion(:swing_type, ["high", "low"])
  end
end
