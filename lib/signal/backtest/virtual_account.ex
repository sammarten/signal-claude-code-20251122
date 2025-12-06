defmodule Signal.Backtest.VirtualAccount do
  @moduledoc """
  Tracks account state during backtests.

  The VirtualAccount manages:
  - Cash balance and equity
  - Open positions
  - Closed trades history
  - Equity curve over time

  ## Position Sizing

  Uses a fixed-risk model where each trade risks a percentage of current equity.
  Default is 1% risk per trade.

  ## Example

      account = VirtualAccount.new(Decimal.new("100000"), Decimal.new("0.01"))

      # Open a position
      {:ok, account, trade} = VirtualAccount.open_position(account, %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("175.50"),
        stop_loss: Decimal.new("174.50"),
        take_profit: Decimal.new("177.50"),
        entry_time: ~U[2024-01-15 09:45:00Z]
      })

      # Close the position
      {:ok, account, trade} = VirtualAccount.close_position(account, trade.id, %{
        exit_price: Decimal.new("177.00"),
        exit_time: ~U[2024-01-15 10:30:00Z],
        status: :target_hit
      })
  """

  defstruct [
    :initial_capital,
    :risk_per_trade,
    :current_equity,
    :cash,
    :open_positions,
    :closed_trades,
    :equity_curve,
    :trade_count,
    :unlimited_capital
  ]

  @type t :: %__MODULE__{
          initial_capital: Decimal.t(),
          risk_per_trade: Decimal.t(),
          current_equity: Decimal.t(),
          cash: Decimal.t(),
          open_positions: %{String.t() => map()},
          closed_trades: [map()],
          equity_curve: [{DateTime.t(), Decimal.t()}],
          trade_count: integer(),
          unlimited_capital: boolean()
        }

  @doc """
  Creates a new virtual account with initial capital.

  ## Parameters

    * `initial_capital` - Starting balance as Decimal
    * `risk_per_trade` - Fraction of equity to risk per trade (e.g., 0.01 for 1%)
    * `opts` - Keyword list of options:
      * `:unlimited_capital` - When true, executes every signal regardless of capital (signal evaluation mode)
  """
  @spec new(Decimal.t(), Decimal.t(), keyword()) :: t()
  def new(initial_capital, risk_per_trade \\ Decimal.new("0.01"), opts \\ []) do
    %__MODULE__{
      initial_capital: initial_capital,
      risk_per_trade: risk_per_trade,
      current_equity: initial_capital,
      cash: initial_capital,
      open_positions: %{},
      closed_trades: [],
      equity_curve: [],
      trade_count: 0,
      unlimited_capital: Keyword.get(opts, :unlimited_capital, false)
    }
  end

  @doc """
  Opens a new position based on a signal.

  Calculates position size based on risk parameters and available capital.

  ## Parameters

    * `account` - Current account state
    * `params` - Map with:
      * `:symbol` - Symbol to trade
      * `:direction` - `:long` or `:short`
      * `:entry_price` - Entry price
      * `:stop_loss` - Stop loss price
      * `:take_profit` - Take profit price (optional)
      * `:entry_time` - Entry timestamp
      * `:signal_id` - Original signal ID (optional)

  ## Returns

    * `{:ok, updated_account, trade}` - Position opened successfully
    * `{:error, reason}` - Failed to open position
  """
  @spec open_position(t(), map()) :: {:ok, t(), map()} | {:error, atom()}
  def open_position(account, params) do
    with :ok <- validate_open_params(params),
         {:ok, position_size, risk_amount} <- calculate_position_size(account, params) do
      trade_id = Ecto.UUID.generate()

      trade = %{
        id: trade_id,
        signal_id: Map.get(params, :signal_id),
        symbol: params.symbol,
        direction: params.direction,
        entry_price: params.entry_price,
        entry_time: params.entry_time,
        position_size: position_size,
        risk_amount: risk_amount,
        stop_loss: params.stop_loss,
        take_profit: Map.get(params, :take_profit),
        status: :open,
        exit_price: nil,
        exit_time: nil,
        pnl: nil,
        pnl_pct: nil,
        r_multiple: nil
      }

      # Calculate position value
      position_value = Decimal.mult(params.entry_price, Decimal.new(position_size))

      # Update account
      updated_account = %{
        account
        | cash: Decimal.sub(account.cash, position_value),
          open_positions: Map.put(account.open_positions, trade_id, trade),
          trade_count: account.trade_count + 1
      }

      {:ok, updated_account, trade}
    end
  end

  @doc """
  Closes an open position.

  ## Parameters

    * `account` - Current account state
    * `trade_id` - ID of the trade to close
    * `params` - Map with:
      * `:exit_price` - Exit price
      * `:exit_time` - Exit timestamp
      * `:status` - Exit reason (`:stopped_out`, `:target_hit`, `:time_exit`, `:manual_exit`)

  ## Returns

    * `{:ok, updated_account, closed_trade}` - Position closed successfully
    * `{:error, :not_found}` - Trade not found
  """
  @spec close_position(t(), String.t(), map()) :: {:ok, t(), map()} | {:error, :not_found}
  def close_position(account, trade_id, params) do
    case Map.get(account.open_positions, trade_id) do
      nil ->
        {:error, :not_found}

      trade ->
        # Calculate P&L
        pnl_data = calculate_trade_pnl(trade, params.exit_price)

        # Create closed trade record
        closed_trade =
          Map.merge(trade, %{
            status: params.status,
            exit_price: params.exit_price,
            exit_time: params.exit_time,
            pnl: pnl_data.pnl,
            pnl_pct: pnl_data.pnl_pct,
            r_multiple: pnl_data.r_multiple
          })

        # Calculate position value returned to cash
        exit_value = Decimal.mult(params.exit_price, Decimal.new(trade.position_size))

        # Update account
        updated_account = %{
          account
          | cash: Decimal.add(account.cash, exit_value),
            current_equity: Decimal.add(account.current_equity, pnl_data.pnl),
            open_positions: Map.delete(account.open_positions, trade_id),
            closed_trades: [closed_trade | account.closed_trades]
        }

        {:ok, updated_account, closed_trade}
    end
  end

  @doc """
  Partially closes an open position, exiting a subset of shares.

  Used for scaled exit strategies where a position is closed in multiple
  tranches at different price targets.

  ## Parameters

    * `account` - Current account state
    * `trade_id` - ID of the trade to partially close
    * `params` - Map with:
      * `:exit_price` - Exit price for this partial
      * `:exit_time` - Exit timestamp
      * `:shares_to_exit` - Number of shares to exit
      * `:reason` - Exit reason (e.g., "target_1", "trailing_stop")
      * `:target_index` - Optional index of target hit (for scaled exits)

  ## Returns

    * `{:ok, updated_account, partial_exit_record}` - Partial close successful
    * `{:error, :not_found}` - Trade not found
    * `{:error, :insufficient_shares}` - Not enough shares remaining
    * `{:error, :invalid_shares}` - shares_to_exit must be positive

  ## Example

      {:ok, account, partial} = VirtualAccount.partial_close(account, trade_id, %{
        exit_price: Decimal.new("176.00"),
        exit_time: ~U[2024-01-15 10:00:00Z],
        shares_to_exit: 50,
        reason: "target_1",
        target_index: 0
      })
  """
  @spec partial_close(t(), String.t(), map()) :: {:ok, t(), map()} | {:error, atom()}
  def partial_close(account, trade_id, params) do
    with :ok <- validate_partial_close_params(params),
         {:ok, trade} <- get_open_position(account, trade_id),
         :ok <- validate_shares_available(trade, params.shares_to_exit) do
      # Calculate P&L for this partial exit
      pnl_per_share =
        case trade.direction do
          :long -> Decimal.sub(params.exit_price, trade.entry_price)
          :short -> Decimal.sub(trade.entry_price, params.exit_price)
        end

      partial_pnl =
        Decimal.mult(pnl_per_share, Decimal.new(params.shares_to_exit))
        |> Decimal.round(2)

      remaining_shares = trade.position_size - params.shares_to_exit

      # Calculate R-multiple for this partial
      r_multiple = calculate_partial_r(trade, partial_pnl, params.shares_to_exit)

      # Calculate P&L percentage based on position value of exited shares
      partial_position_value =
        Decimal.mult(trade.entry_price, Decimal.new(params.shares_to_exit))

      pnl_pct =
        if Decimal.compare(partial_position_value, Decimal.new(0)) == :gt do
          Decimal.div(partial_pnl, partial_position_value)
          |> Decimal.mult(Decimal.new(100))
          |> Decimal.round(2)
        else
          Decimal.new(0)
        end

      # Create partial exit record
      partial_exit = %{
        trade_id: trade_id,
        exit_time: params.exit_time,
        exit_price: params.exit_price,
        shares_exited: params.shares_to_exit,
        remaining_shares: remaining_shares,
        exit_reason: format_exit_reason(params.reason),
        target_index: Map.get(params, :target_index),
        pnl: partial_pnl,
        pnl_pct: pnl_pct,
        r_multiple: r_multiple
      }

      # Calculate cash returned from exited shares
      exit_value = Decimal.mult(params.exit_price, Decimal.new(params.shares_to_exit))

      # Update the trade with reduced position size
      updated_trade = %{trade | position_size: remaining_shares}

      # Update account state
      updated_account =
        if remaining_shares == 0 do
          # Position fully closed - move to closed trades
          closed_trade = finalize_closed_trade(trade, params, partial_pnl, pnl_pct, r_multiple)

          %{
            account
            | cash: Decimal.add(account.cash, exit_value),
              current_equity: Decimal.add(account.current_equity, partial_pnl),
              open_positions: Map.delete(account.open_positions, trade_id),
              closed_trades: [closed_trade | account.closed_trades]
          }
        else
          # Position still open with reduced size
          %{
            account
            | cash: Decimal.add(account.cash, exit_value),
              current_equity: Decimal.add(account.current_equity, partial_pnl),
              open_positions: Map.put(account.open_positions, trade_id, updated_trade)
          }
        end

      {:ok, updated_account, partial_exit}
    end
  end

  @doc """
  Updates an open position's stop loss price.

  Used when trailing stops or breakeven management moves the stop.

  ## Parameters

    * `account` - Current account state
    * `trade_id` - ID of the trade to update
    * `new_stop` - New stop loss price

  ## Returns

    * `{:ok, updated_account}` - Stop updated successfully
    * `{:error, :not_found}` - Trade not found
  """
  @spec update_stop(t(), String.t(), Decimal.t()) :: {:ok, t()} | {:error, :not_found}
  def update_stop(account, trade_id, new_stop) do
    case Map.get(account.open_positions, trade_id) do
      nil ->
        {:error, :not_found}

      trade ->
        updated_trade = %{trade | stop_loss: new_stop}

        updated_account = %{
          account
          | open_positions: Map.put(account.open_positions, trade_id, updated_trade)
        }

        {:ok, updated_account}
    end
  end

  @doc """
  Updates the equity curve with current equity value.
  """
  @spec record_equity(t(), DateTime.t()) :: t()
  def record_equity(account, timestamp) do
    equity = calculate_current_equity(account)
    point = {timestamp, equity}

    %{account | equity_curve: [point | account.equity_curve]}
  end

  @doc """
  Calculates current equity including unrealized P&L from open positions.
  """
  @spec calculate_current_equity(t()) :: Decimal.t()
  def calculate_current_equity(account) do
    # For now, just return current_equity (updated on close)
    # In a more complete implementation, we'd mark-to-market open positions
    account.current_equity
  end

  @doc """
  Returns summary statistics for the account.
  """
  @spec summary(t()) :: map()
  def summary(account) do
    closed = account.closed_trades

    winners = Enum.filter(closed, &(Decimal.compare(&1.pnl, Decimal.new(0)) == :gt))
    losers = Enum.filter(closed, &(Decimal.compare(&1.pnl, Decimal.new(0)) == :lt))

    total_pnl =
      Enum.reduce(closed, Decimal.new(0), fn trade, acc ->
        Decimal.add(acc, trade.pnl || Decimal.new(0))
      end)

    %{
      initial_capital: account.initial_capital,
      current_equity: account.current_equity,
      total_pnl: total_pnl,
      total_pnl_pct:
        Decimal.div(total_pnl, account.initial_capital)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(2),
      total_trades: length(closed),
      open_positions: map_size(account.open_positions),
      winners: length(winners),
      losers: length(losers),
      win_rate:
        if(length(closed) > 0,
          do: Float.round(length(winners) / length(closed) * 100, 1),
          else: 0.0
        )
    }
  end

  # Private Functions

  defp validate_open_params(params) do
    required = [:symbol, :direction, :entry_price, :stop_loss, :entry_time]
    missing = Enum.filter(required, &(!Map.has_key?(params, &1)))

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_params, missing}}
    end
  end

  defp calculate_position_size(account, params) do
    # Calculate price risk per share
    price_risk =
      case params.direction do
        :long ->
          Decimal.sub(params.entry_price, params.stop_loss)

        :short ->
          Decimal.sub(params.stop_loss, params.entry_price)
      end

    # Ensure positive price risk
    if Decimal.compare(price_risk, Decimal.new(0)) != :gt do
      {:error, :invalid_stop_loss}
    else
      # In signal evaluation mode (unlimited capital), use position_size=1
      # R-multiple is calculated purely from price movement, position size is irrelevant
      if account.unlimited_capital do
        # risk_amount = price_risk (for 1 share), used for R-multiple calculation
        {:ok, 1, price_risk}
      else
        # Normal mode: calculate position size based on risk percentage
        risk_amount = Decimal.mult(account.current_equity, account.risk_per_trade)

        position_size =
          Decimal.div(risk_amount, price_risk)
          |> Decimal.round(0, :floor)
          |> Decimal.to_integer()

        # Ensure at least 1 share
        position_size = max(position_size, 1)

        # Check if we have enough cash
        position_value = Decimal.mult(params.entry_price, Decimal.new(position_size))

        if Decimal.compare(position_value, account.cash) == :gt do
          # Reduce position size to fit available cash
          max_shares =
            Decimal.div(account.cash, params.entry_price)
            |> Decimal.round(0, :floor)
            |> Decimal.to_integer()

          if max_shares < 1 do
            {:error, :insufficient_funds}
          else
            adjusted_risk = Decimal.mult(price_risk, Decimal.new(max_shares))
            {:ok, max_shares, adjusted_risk}
          end
        else
          {:ok, position_size, risk_amount}
        end
      end
    end
  end

  defp calculate_trade_pnl(trade, exit_price) do
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

  # Partial close helper functions

  defp validate_partial_close_params(params) do
    required = [:exit_price, :exit_time, :shares_to_exit, :reason]
    missing = Enum.filter(required, &(!Map.has_key?(params, &1)))

    cond do
      not Enum.empty?(missing) ->
        {:error, {:missing_params, missing}}

      not is_integer(params.shares_to_exit) or params.shares_to_exit <= 0 ->
        {:error, :invalid_shares}

      true ->
        :ok
    end
  end

  defp get_open_position(account, trade_id) do
    case Map.get(account.open_positions, trade_id) do
      nil -> {:error, :not_found}
      trade -> {:ok, trade}
    end
  end

  defp validate_shares_available(trade, shares_to_exit) do
    if trade.position_size >= shares_to_exit do
      :ok
    else
      {:error, :insufficient_shares}
    end
  end

  defp calculate_partial_r(trade, pnl, shares_exited) do
    # Calculate risk per share
    risk_per_share =
      case trade.direction do
        :long -> Decimal.sub(trade.entry_price, trade.stop_loss)
        :short -> Decimal.sub(trade.stop_loss, trade.entry_price)
      end
      |> Decimal.abs()

    # Calculate total risk for exited shares
    partial_risk = Decimal.mult(risk_per_share, Decimal.new(shares_exited))

    if Decimal.compare(partial_risk, Decimal.new(0)) == :gt do
      Decimal.div(pnl, partial_risk) |> Decimal.round(2)
    else
      Decimal.new(0)
    end
  end

  defp format_exit_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_exit_reason(reason) when is_binary(reason), do: reason

  defp finalize_closed_trade(trade, params, pnl, pnl_pct, r_multiple) do
    Map.merge(trade, %{
      status: format_exit_status(params.reason),
      exit_price: params.exit_price,
      exit_time: params.exit_time,
      pnl: pnl,
      pnl_pct: pnl_pct,
      r_multiple: r_multiple
    })
  end

  defp format_exit_status(reason) when is_atom(reason), do: reason

  defp format_exit_status(reason) when is_binary(reason) do
    case reason do
      "target_" <> _ -> :target_hit
      "trailing_stop" -> :trailing_stopped
      "breakeven_stop" -> :stopped_out
      "stopped_out" -> :stopped_out
      "time_exit" -> :time_exit
      "manual_exit" -> :manual_exit
      _ -> :closed
    end
  end
end
