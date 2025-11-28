defmodule SignalWeb.Live.Helpers.Formatters do
  @moduledoc """
  Shared formatting helpers for LiveView modules.

  Provides consistent formatting for:
  - Decimal values (prices, percentages, currency)
  - Dates and timestamps
  - Status badges and styling
  """

  @doc """
  Formats a Decimal to a string with 2 decimal places.
  Returns "-" for nil values.
  """
  def format_decimal(nil), do: "-"

  def format_decimal(%Decimal{} = decimal) do
    Decimal.round(decimal, 2) |> Decimal.to_string(:normal)
  end

  @doc """
  Formats a Decimal as a percentage string.
  Returns "-" for nil values.
  """
  def format_pct(nil), do: "-"

  def format_pct(%Decimal{} = decimal) do
    "#{format_decimal(decimal)}%"
  end

  @doc """
  Formats a Decimal as a currency string with $ prefix.
  Returns "-" for nil values.
  """
  def format_currency(nil), do: "-"

  def format_currency(%Decimal{} = decimal) do
    "$#{format_decimal(decimal)}"
  end

  @doc """
  Formats a Date as ISO8601 string.
  Returns "-" for nil values.
  """
  def format_date(nil), do: "-"
  def format_date(%Date{} = date), do: Date.to_iso8601(date)

  @doc """
  Formats a DateTime as "YYYY-MM-DD HH:MM" string.
  Returns "-" for nil values.
  """
  def format_datetime(nil), do: "-"

  def format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  @doc """
  Returns CSS classes for status badge styling.
  """
  def status_badge_class(status) do
    case status do
      :completed -> "bg-green-500/20 text-green-400"
      :running -> "bg-blue-500/20 text-blue-400"
      :failed -> "bg-red-500/20 text-red-400"
      :cancelled -> "bg-zinc-500/20 text-zinc-400"
      _ -> "bg-zinc-500/20 text-zinc-400"
    end
  end

  @doc """
  Returns CSS classes for P&L value styling (green for positive, red for negative).
  """
  def pnl_class(nil), do: "text-zinc-400"

  def pnl_class(%Decimal{} = pnl) do
    if Decimal.positive?(pnl), do: "text-green-400", else: "text-red-400"
  end

  @doc """
  Checks if a Decimal value is positive.
  Returns false for nil values.
  """
  def positive?(nil), do: false
  def positive?(%Decimal{} = d), do: Decimal.positive?(d)
end
