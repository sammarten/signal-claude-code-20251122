defmodule Signal.Alpaca.StreamHandler do
  @moduledoc """
  Callback handler for Alpaca WebSocket stream.

  Processes incoming market data messages by:
  - Updating BarCache with latest data
  - Publishing to Phoenix.PubSub for real-time distribution
  - Deduplicating quotes (skip if bid/ask unchanged)
  - Tracking metrics via Monitor
  - Periodic throughput logging

  ## State

  The handler maintains state for deduplication and logging:

      %{
        last_quotes: %{"AAPL" => %{bid_price: Decimal.t(), ask_price: Decimal.t()}},
        counters: %{quotes: 0, bars: 0, trades: 0, statuses: 0},
        last_log: DateTime.utc_now()
      }

  ## PubSub Topics

  Messages are broadcast to:
  - `"quotes:{symbol}"` - Quote updates (only if price changed)
  - `"bars:{symbol}"` - Bar updates (always)
  - `"trades:{symbol}"` - Trade updates
  - `"statuses:{symbol}"` - Status changes (halts, resumes)
  - `"alpaca:connection"` - Connection events
  """

  @behaviour Signal.Alpaca.Stream

  alias Signal.MarketData.Bar
  alias Signal.Repo

  require Logger

  @log_interval_seconds 60

  @doc """
  Handle incoming messages from Alpaca stream.

  Implements the callback required by Signal.Alpaca.Stream behaviour.

  ## Parameters

    - `message` - Normalized message map from stream
    - `state` - Handler state with last_quotes, counters, last_log

  ## Returns

    - `{:ok, new_state}`
  """
  @impl Signal.Alpaca.Stream
  def handle_message(message, state)

  # Quote messages - with deduplication
  def handle_message(%{type: :quote} = quote, state) do
    symbol = quote.symbol
    last_quotes = state.last_quotes
    last_quote = Map.get(last_quotes, symbol)

    # Check if price changed
    if quote_changed?(quote, last_quote) do
      # Update BarCache
      Signal.BarCache.update_quote(String.to_atom(symbol), quote)

      # Broadcast to PubSub
      Phoenix.PubSub.broadcast(
        Signal.PubSub,
        "quotes:#{symbol}",
        {:quote, symbol, quote}
      )

      # Track metric
      Signal.Monitor.track_message(:quote)

      # Update state
      new_last_quotes =
        Map.put(last_quotes, symbol, %{
          bid_price: quote.bid_price,
          ask_price: quote.ask_price
        })

      new_counters = Map.update(state.counters, :quotes, 1, &(&1 + 1))

      new_state = %{
        state
        | last_quotes: new_last_quotes,
          counters: new_counters
      }

      maybe_log_stats(new_state)
    else
      # Quote unchanged, skip processing
      {:ok, state}
    end
  end

  # Bar messages
  def handle_message(%{type: :bar} = bar, state) do
    symbol = bar.symbol

    # Update BarCache
    Signal.BarCache.update_bar(String.to_atom(symbol), bar)

    # Persist to database (upsert to handle duplicates)
    persist_bar(symbol, bar)

    # Broadcast to PubSub
    Phoenix.PubSub.broadcast(Signal.PubSub, "bars:#{symbol}", {:bar, symbol, bar})

    # Track metric
    Signal.Monitor.track_message(:bar)

    # Update counters
    new_counters = Map.update(state.counters, :bars, 1, &(&1 + 1))
    new_state = %{state | counters: new_counters}

    maybe_log_stats(new_state)
  end

  # Trade messages
  def handle_message(%{type: :trade} = trade, state) do
    symbol = trade.symbol

    # Broadcast to PubSub
    Phoenix.PubSub.broadcast(Signal.PubSub, "trades:#{symbol}", {:trade, symbol, trade})

    # Track metric
    Signal.Monitor.track_message(:trade)

    # Update counters
    new_counters = Map.update(state.counters, :trades, 1, &(&1 + 1))
    new_state = %{state | counters: new_counters}

    maybe_log_stats(new_state)
  end

  # Status messages
  def handle_message(%{type: :status} = status, state) do
    symbol = status.symbol

    # Broadcast to PubSub
    Phoenix.PubSub.broadcast(
      Signal.PubSub,
      "statuses:#{symbol}",
      {:status, symbol, status}
    )

    # Log important status changes (halts/resumes)
    if status.status_code in ["H", "P", "T"] do
      Logger.warning(
        "Trading status change for #{symbol}: #{status.status_message} (#{status.status_code})"
      )
    end

    # Update counters
    new_counters = Map.update(state.counters, :statuses, 1, &(&1 + 1))
    new_state = %{state | counters: new_counters}

    maybe_log_stats(new_state)
  end

  # Connection events
  def handle_message(%{type: :connection} = conn_event, state) do
    # Broadcast to PubSub
    Phoenix.PubSub.broadcast(
      Signal.PubSub,
      "alpaca:connection",
      {:connection, conn_event.status, Map.drop(conn_event, [:type, :status])}
    )

    # Track connection status
    Signal.Monitor.track_connection(conn_event.status)

    # Log connection status
    Logger.info("AlpacaStream connection status: #{conn_event.status}")

    # Reset counters on successful connection
    new_state =
      if conn_event.status == :connected do
        %{
          state
          | counters: %{quotes: 0, bars: 0, trades: 0, statuses: 0},
            last_log: DateTime.utc_now()
        }
      else
        state
      end

    {:ok, new_state}
  end

  # Unknown message type
  def handle_message(message, state) do
    Logger.debug("StreamHandler received unknown message: #{inspect(message)}")
    {:ok, state}
  end

  # Private helpers

  defp quote_changed?(_quote, nil), do: true

  defp quote_changed?(quote, last_quote) do
    not (Decimal.equal?(quote.bid_price, last_quote.bid_price) and
           Decimal.equal?(quote.ask_price, last_quote.ask_price))
  end

  defp maybe_log_stats(state) do
    now = DateTime.utc_now()
    elapsed_seconds = DateTime.diff(now, state.last_log, :second)

    if elapsed_seconds >= @log_interval_seconds do
      log_stats(state, elapsed_seconds)

      # Reset counters and update last_log
      new_state = %{
        state
        | counters: %{quotes: 0, bars: 0, trades: 0, statuses: 0},
          last_log: now
      }

      {:ok, new_state}
    else
      {:ok, state}
    end
  end

  defp log_stats(state, elapsed_seconds) do
    counters = state.counters

    Logger.info(
      "StreamHandler stats (#{elapsed_seconds}s): " <>
        "quotes=#{counters.quotes}, " <>
        "bars=#{counters.bars}, " <>
        "trades=#{counters.trades}, " <>
        "statuses=#{counters.statuses}"
    )
  end

  # Persist bar to database using upsert (insert or update on conflict)
  defp persist_bar(symbol, bar_data) do
    bar = Bar.from_alpaca(symbol, bar_data)

    Repo.insert(bar,
      on_conflict: {:replace, [:open, :high, :low, :close, :volume, :vwap, :trade_count]},
      conflict_target: [:symbol, :bar_time]
    )
  rescue
    error ->
      Logger.error("Failed to persist bar for #{symbol}: #{inspect(error)}")
      {:error, error}
  end
end
