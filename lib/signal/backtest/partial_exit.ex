defmodule Signal.Backtest.PartialExit do
  @moduledoc """
  Schema for partial exits during scaled exit strategies.

  A PartialExit records a single exit transaction when a position is scaled out
  in multiple parts. This allows tracking P&L at each target level and provides
  detailed analytics on exit strategy effectiveness.

  ## Exit Reasons

  - `"target_1"`, `"target_2"`, `"target_3"` - Hit a predefined take profit target
  - `"trailing_stop"` - Hit by trailing stop
  - `"breakeven_stop"` - Hit after stop moved to breakeven
  - `"time_exit"` - Time-based exit
  - `"manual_exit"` - Manual/forced exit

  ## Example

  A scaled exit strategy with 50%/50% targets would create two PartialExit records:

      # First partial at T1
      %PartialExit{
        trade_id: "abc123",
        exit_time: ~U[2024-01-15 10:00:00Z],
        exit_price: Decimal.new("176.00"),
        shares_exited: 50,
        remaining_shares: 50,
        exit_reason: "target_1",
        target_index: 0,
        pnl: Decimal.new("50.00"),
        r_multiple: Decimal.new("1.0")
      }

      # Second partial at T2
      %PartialExit{
        trade_id: "abc123",
        exit_time: ~U[2024-01-15 10:30:00Z],
        exit_price: Decimal.new("178.00"),
        shares_exited: 50,
        remaining_shares: 0,
        exit_reason: "target_2",
        target_index: 1,
        pnl: Decimal.new("150.00"),
        r_multiple: Decimal.new("3.0")
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "partial_exits" do
    belongs_to :trade, Signal.Backtest.SimulatedTrade

    # Exit details
    field :exit_time, :utc_datetime_usec
    field :exit_price, :decimal
    field :shares_exited, :integer
    field :remaining_shares, :integer

    # Exit reason and target tracking
    field :exit_reason, :string
    field :target_index, :integer

    # P&L for this partial
    field :pnl, :decimal
    field :pnl_pct, :decimal
    field :r_multiple, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :trade_id,
    :exit_time,
    :exit_price,
    :shares_exited,
    :remaining_shares,
    :exit_reason
  ]

  @optional_fields [
    :target_index,
    :pnl,
    :pnl_pct,
    :r_multiple
  ]

  @valid_exit_reasons ~w[
    target_1 target_2 target_3 target_4
    trailing_stop breakeven_stop
    time_exit manual_exit stopped_out
  ]

  @doc """
  Creates a changeset for a new partial exit record.
  """
  def changeset(partial_exit, attrs) do
    partial_exit
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:exit_price, greater_than: 0)
    |> validate_number(:shares_exited, greater_than: 0)
    |> validate_number(:remaining_shares, greater_than_or_equal_to: 0)
    |> validate_inclusion(:exit_reason, @valid_exit_reasons)
    |> validate_target_index()
    |> foreign_key_constraint(:trade_id)
  end

  @doc """
  Creates a partial exit from a PositionState partial exit record.

  This converts the internal map format used by PositionState into
  the format needed for database persistence.
  """
  @spec from_position_state(String.t(), map()) :: map()
  def from_position_state(trade_id, partial_record) do
    %{
      trade_id: trade_id,
      exit_time: partial_record.exit_time,
      exit_price: partial_record.exit_price,
      shares_exited: partial_record.shares_exited,
      remaining_shares: Map.get(partial_record, :remaining_shares, 0),
      exit_reason: format_exit_reason(partial_record.reason),
      target_index: partial_record[:target_index],
      pnl: partial_record.pnl,
      pnl_pct: Map.get(partial_record, :pnl_pct),
      r_multiple: partial_record.r_multiple
    }
  end

  # Private functions

  defp validate_target_index(changeset) do
    exit_reason = get_field(changeset, :exit_reason)
    target_index = get_field(changeset, :target_index)

    # If exit_reason is a target exit, target_index should be set
    if exit_reason && String.starts_with?(exit_reason, "target_") && is_nil(target_index) do
      add_error(changeset, :target_index, "is required for target exits")
    else
      changeset
    end
  end

  defp format_exit_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_exit_reason(reason) when is_binary(reason), do: reason
end
