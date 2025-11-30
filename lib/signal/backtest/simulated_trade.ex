defmodule Signal.Backtest.SimulatedTrade do
  @moduledoc """
  Schema for simulated trades during backtests.

  A SimulatedTrade represents a complete trade lifecycle from entry to exit,
  including position sizing, stop loss, take profit, and P&L calculations.

  ## Trade Lifecycle

  1. Signal is generated → Trade opened with status `:open`
  2. Price hits stop loss → Trade closed with status `:stopped_out`
  3. Price hits take profit → Trade closed with status `:target_hit`
  4. Time limit reached → Trade closed with status `:time_exit`
  5. Manual intervention → Trade closed with status `:manual_exit`

  ## P&L Calculation

  - `pnl` - Absolute profit/loss in dollars
  - `pnl_pct` - Percentage return on position
  - `r_multiple` - Return as multiple of risk (e.g., 2R = 2x risk amount profit)

  ## Exit Strategy Tracking

  - `exit_strategy_type` - Type of exit strategy used ("fixed", "trailing", "scaled", etc.)
  - `stop_moved_to_breakeven` - Whether stop was moved to breakeven during trade
  - `final_stop` - The final stop price at exit (may differ from initial stop_loss)
  - `max_favorable_r` - Maximum favorable excursion in R multiples (best potential profit)
  - `max_adverse_r` - Maximum adverse excursion in R multiples (worst drawdown)
  - `partial_exit_count` - Number of partial exits (for scaled strategies)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "simulated_trades" do
    belongs_to :backtest_run, Signal.Backtest.BacktestRun

    field :signal_id, :binary_id

    # Trade identification
    field :symbol, :string
    field :direction, Ecto.Enum, values: [:long, :short]

    # Entry details
    field :entry_price, :decimal
    field :entry_time, :utc_datetime_usec
    field :position_size, :integer
    field :risk_amount, :decimal

    # Stop/target levels
    field :stop_loss, :decimal
    field :take_profit, :decimal

    # Exit details
    field :status, Ecto.Enum,
      values: [:open, :stopped_out, :target_hit, :time_exit, :manual_exit],
      default: :open

    field :exit_price, :decimal
    field :exit_time, :utc_datetime_usec

    # P&L
    field :pnl, :decimal
    field :pnl_pct, :decimal
    field :r_multiple, :decimal

    # Exit strategy tracking
    field :exit_strategy_type, :string, default: "fixed"
    field :stop_moved_to_breakeven, :boolean, default: false
    field :final_stop, :decimal
    field :max_favorable_r, :decimal
    field :max_adverse_r, :decimal
    field :partial_exit_count, :integer, default: 0

    # Partial exits for scaled strategies
    has_many :partial_exits, Signal.Backtest.PartialExit, foreign_key: :trade_id

    # Metadata
    field :fill_type, :string, default: "signal_price"
    field :slippage, :decimal, default: Decimal.new(0)
    field :notes, :string

    # Options-specific fields
    field :instrument_type, :string, default: "equity"
    field :contract_symbol, :string
    field :underlying_symbol, :string
    field :contract_type, :string
    field :strike, :decimal
    field :expiration_date, :date
    field :entry_premium, :decimal
    field :exit_premium, :decimal
    field :num_contracts, :integer
    field :options_exit_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :backtest_run_id,
    :symbol,
    :direction,
    :entry_price,
    :entry_time,
    :position_size,
    :risk_amount,
    :stop_loss
  ]

  @optional_fields [
    :signal_id,
    :take_profit,
    :status,
    :exit_price,
    :exit_time,
    :pnl,
    :pnl_pct,
    :r_multiple,
    :exit_strategy_type,
    :stop_moved_to_breakeven,
    :final_stop,
    :max_favorable_r,
    :max_adverse_r,
    :partial_exit_count,
    :fill_type,
    :slippage,
    :notes,
    # Options-specific fields
    :instrument_type,
    :contract_symbol,
    :underlying_symbol,
    :contract_type,
    :strike,
    :expiration_date,
    :entry_premium,
    :exit_premium,
    :num_contracts,
    :options_exit_reason
  ]

  @doc """
  Creates a changeset for a new trade.
  """
  def changeset(trade, attrs) do
    trade
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:entry_price, greater_than: 0)
    |> validate_number(:stop_loss, greater_than: 0)
    |> validate_number(:position_size, greater_than: 0)
    |> validate_number(:risk_amount, greater_than: 0)
    |> foreign_key_constraint(:backtest_run_id)
  end

  @doc """
  Creates a changeset for closing a trade.
  """
  def close_changeset(trade, attrs) do
    close_fields = [
      :status,
      :exit_price,
      :exit_time,
      :pnl,
      :pnl_pct,
      :r_multiple,
      :final_stop,
      :stop_moved_to_breakeven,
      :max_favorable_r,
      :max_adverse_r,
      :partial_exit_count,
      :notes
    ]

    trade
    |> cast(attrs, close_fields)
    |> validate_required([:status, :exit_price, :exit_time])
    |> validate_inclusion(:status, [:stopped_out, :target_hit, :time_exit, :manual_exit])
  end

  @doc """
  Calculates P&L for a trade given an exit price.

  Returns a map with :pnl, :pnl_pct, and :r_multiple.
  """
  def calculate_pnl(trade, exit_price) do
    entry = trade.entry_price
    size = trade.position_size
    risk = trade.risk_amount

    # Calculate raw P&L based on direction
    pnl =
      case trade.direction do
        :long ->
          Decimal.mult(Decimal.sub(exit_price, entry), Decimal.new(size))

        :short ->
          Decimal.mult(Decimal.sub(entry, exit_price), Decimal.new(size))
      end

    # Calculate percentage return
    position_value = Decimal.mult(entry, Decimal.new(size))

    pnl_pct =
      if Decimal.compare(position_value, Decimal.new(0)) == :gt do
        Decimal.div(pnl, position_value)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(2)
      else
        Decimal.new(0)
      end

    # Calculate R-multiple
    r_multiple =
      if Decimal.compare(risk, Decimal.new(0)) == :gt do
        Decimal.div(pnl, risk) |> Decimal.round(2)
      else
        Decimal.new(0)
      end

    %{
      pnl: Decimal.round(pnl, 2),
      pnl_pct: pnl_pct,
      r_multiple: r_multiple
    }
  end

  @doc """
  Checks if the current price has hit the stop loss.
  """
  def stop_hit?(trade, current_price) do
    case trade.direction do
      :long ->
        Decimal.compare(current_price, trade.stop_loss) in [:lt, :eq]

      :short ->
        Decimal.compare(current_price, trade.stop_loss) in [:gt, :eq]
    end
  end

  @doc """
  Checks if the current price has hit the take profit target.
  """
  def target_hit?(trade, current_price) do
    case trade.take_profit do
      nil ->
        false

      target ->
        case trade.direction do
          :long ->
            Decimal.compare(current_price, target) in [:gt, :eq]

          :short ->
            Decimal.compare(current_price, target) in [:lt, :eq]
        end
    end
  end
end
