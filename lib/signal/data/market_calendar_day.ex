defmodule Signal.Data.MarketCalendarDay do
  @moduledoc """
  Ecto schema for a single trading day in the market calendar.

  Stores market open/close times for each trading day, fetched from
  the Alpaca Calendar API. Non-trading days (weekends, holidays) are
  not stored - their absence indicates the market was closed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:date, :date, autogenerate: false}

  schema "market_calendar" do
    field :open, :time
    field :close, :time
  end

  @doc """
  Creates a changeset for a market calendar day.
  """
  def changeset(calendar_day, attrs) do
    calendar_day
    |> cast(attrs, [:date, :open, :close])
    |> validate_required([:date, :open, :close])
  end

  @doc """
  Returns true if this is an early close day (market closes before 16:00).
  """
  def early_close?(%__MODULE__{close: close}) do
    Time.compare(close, ~T[16:00:00]) == :lt
  end
end
