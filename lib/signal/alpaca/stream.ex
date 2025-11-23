defmodule Signal.Alpaca.Stream do
  @moduledoc """
  WebSocket client for real-time market data streaming from Alpaca.

  Manages a persistent WebSocket connection with automatic reconnection,
  handles authentication and subscriptions, and delivers normalized messages
  to a callback module.

  ## Alpaca WebSocket Protocol

  1. Connect to ws_url
  2. Receive: `[{"T":"success","msg":"connected"}]`
  3. Send: `{"action":"auth","key":"KEY","secret":"SECRET"}`
  4. Receive: `[{"T":"success","msg":"authenticated"}]`
  5. Send: `{"action":"subscribe","bars":["AAPL"],"quotes":["AAPL"]}`
  6. Receive: `[{"T":"subscription",...}]`
  7. Receive data: `[{"T":"q",...},{"T":"b",...}]`

  ## Callback Module

  The callback module must implement:

      @callback handle_message(message :: map(), state :: any()) :: {:ok, new_state}

  ## Examples

      {:ok, pid} = Signal.Alpaca.Stream.start_link(
        callback_module: MyHandler,
        callback_state: %{},
        initial_subscriptions: %{
          bars: ["AAPL", "TSLA"],
          quotes: ["AAPL", "TSLA"]
        }
      )

      Signal.Alpaca.Stream.status(pid)
      #=> :subscribed
  """

  use WebSockex
  require Logger
  alias Signal.Alpaca.Config

  @behaviour Access

  @callback handle_message(message :: map(), state :: any()) :: {:ok, any()}

  # State structure
  defstruct [
    :ws_conn,
    :status,
    :subscriptions,
    :pending_subscriptions,
    :reconnect_attempt,
    :reconnect_timer,
    :callback_module,
    :callback_state
  ]

  # Public API

  @doc """
  Start the stream GenServer.

  ## Parameters

    - `opts` - Keyword list with:
      - `:callback_module` (required) - Module implementing handle_message/2
      - `:callback_state` (optional) - Initial state for callback, default: %{}
      - `:initial_subscriptions` (optional) - Map like %{bars: ["AAPL"], quotes: ["AAPL"]}
      - `:name` (optional) - GenServer registration name

  ## Returns

    - `{:ok, pid}` on success
    - `{:error, reason}` on failure
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, any()}
  def start_link(opts) do
    callback_module = Keyword.fetch!(opts, :callback_module)
    callback_state = Keyword.get(opts, :callback_state, %{})
    initial_subscriptions = Keyword.get(opts, :initial_subscriptions, %{})
    name = Keyword.get(opts, :name)

    state = %__MODULE__{
      status: :disconnected,
      subscriptions: %{bars: [], quotes: [], trades: [], statuses: []},
      pending_subscriptions: initial_subscriptions,
      reconnect_attempt: 0,
      reconnect_timer: nil,
      callback_module: callback_module,
      callback_state: callback_state
    }

    ws_opts =
      if name do
        [name: name, async: true]
      else
        [async: true]
      end

    url = Config.ws_url()
    WebSockex.start_link(url, __MODULE__, state, ws_opts)
  end

  @doc """
  Add subscriptions dynamically.

  ## Parameters

    - `server` - PID or registered name
    - `subscriptions` - Map like %{bars: ["AAPL"], quotes: ["AAPL"]}

  ## Returns

    - `:ok`
  """
  @spec subscribe(GenServer.server(), map()) :: :ok
  def subscribe(server, subscriptions) do
    WebSockex.cast(server, {:subscribe, subscriptions})
  end

  @doc """
  Remove subscriptions.

  ## Parameters

    - `server` - PID or registered name
    - `subscriptions` - Map like %{bars: ["AAPL"]}

  ## Returns

    - `:ok`
  """
  @spec unsubscribe(GenServer.server(), map()) :: :ok
  def unsubscribe(server, subscriptions) do
    WebSockex.cast(server, {:unsubscribe, subscriptions})
  end

  @doc """
  Get connection status.

  ## Parameters

    - `server` - PID or registered name

  ## Returns

    - `:disconnected` | `:connecting` | `:connected` | `:authenticated` | `:subscribed`
  """
  @spec status(GenServer.server()) :: atom()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Get active subscriptions.

  ## Parameters

    - `server` - PID or registered name

  ## Returns

    - Map with keys: :bars, :quotes, :trades, :statuses
  """
  @spec subscriptions(GenServer.server()) :: map()
  def subscriptions(server) do
    GenServer.call(server, :subscriptions)
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.info("AlpacaStream connected to #{Config.ws_url()}")
    deliver_callback_message(%{type: :connection, status: :connected, attempt: 0}, state)
    {:ok, %{state | status: :connected, reconnect_attempt: 0}}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    try do
      case Jason.decode(msg) do
        {:ok, messages} when is_list(messages) ->
          new_state = Enum.reduce(messages, state, &process_message/2)
          {:ok, new_state}

        {:ok, single_message} when is_map(single_message) ->
          # Handle single message (not in array)
          new_state = process_message(single_message, state)
          {:ok, new_state}

        {:ok, other} ->
          Logger.warning("Unexpected JSON structure: #{inspect(other)}")
          {:ok, state}

        {:error, error} ->
          Logger.warning("Failed to parse WebSocket message: #{inspect(error)}")
          {:ok, state}
      end
    rescue
      error ->
        Logger.error(
          "Error in handle_frame: #{inspect(error)}\n" <>
            "Raw message: #{inspect(msg)}\n" <>
            "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        {:ok, state}
    end
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl WebSockex
  def handle_cast({:subscribe, new_subs}, state) do
    if state.status == :authenticated or state.status == :subscribed do
      send(self(), {:send_subscription, new_subs})
      updated_subs = merge_subscriptions(state.subscriptions, new_subs)
      {:ok, %{state | subscriptions: updated_subs}}
    else
      # Queue for later
      pending = merge_subscriptions(state.pending_subscriptions, new_subs)
      {:ok, %{state | pending_subscriptions: pending}}
    end
  end

  def handle_cast({:unsubscribe, remove_subs}, state) do
    if state.status == :authenticated or state.status == :subscribed do
      send(self(), {:send_unsubscription, remove_subs})
      updated_subs = remove_subscriptions(state.subscriptions, remove_subs)
      {:ok, %{state | subscriptions: updated_subs}}
    else
      {:ok, state}
    end
  end

  # GenServer callbacks (WebSockex supports these but doesn't define them in @behaviour)
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  # Handle info callbacks for sending frames (can't call send_frame from other callbacks)
  @impl WebSockex
  def handle_info(:authenticate, state) do
    auth_msg =
      Jason.encode!(%{
        action: "auth",
        key: Config.api_key!(),
        secret: Config.api_secret!()
      })

    {:reply, {:text, auth_msg}, state}
  end

  def handle_info({:send_subscription, subs}, state) do
    if map_size(subs) == 0 do
      {:ok, state}
    else
      msg =
        Jason.encode!(%{
          action: "subscribe",
          bars: Map.get(subs, :bars, []),
          quotes: Map.get(subs, :quotes, []),
          trades: Map.get(subs, :trades, []),
          statuses: Map.get(subs, :statuses, [])
        })

      {:reply, {:text, msg}, state}
    end
  end

  def handle_info({:send_unsubscription, subs}, state) do
    if map_size(subs) == 0 do
      {:ok, state}
    else
      msg =
        Jason.encode!(%{
          action: "unsubscribe",
          bars: Map.get(subs, :bars, []),
          quotes: Map.get(subs, :quotes, []),
          trades: Map.get(subs, :trades, []),
          statuses: Map.get(subs, :statuses, [])
        })

      {:reply, {:text, msg}, state}
    end
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("AlpacaStream disconnected: #{inspect(reason)}")

    deliver_callback_message(
      %{type: :connection, status: :disconnected, reason: reason},
      state
    )

    # Schedule reconnect
    attempt = state.reconnect_attempt + 1
    delay = calculate_backoff(attempt)

    Logger.info(
      "AlpacaStream reconnecting in #{div(delay, 1000)}s (attempt #{attempt})"
    )

    {:reconnect, delay, %{state | status: :disconnected, reconnect_attempt: attempt}}
  end

  @impl WebSockex
  def terminate(reason, state) do
    Logger.info("AlpacaStream terminating: #{inspect(reason)}")
    deliver_callback_message(%{type: :connection, status: :disconnected, reason: reason}, state)
    :ok
  end

  # Message Processing

  defp process_message(%{"T" => "success", "msg" => "connected"}, state) do
    Logger.debug("AlpacaStream received connection confirmation")
    # Send message to self to authenticate (can't call send_frame from callback)
    send(self(), :authenticate)
    state
  end

  defp process_message(%{"T" => "success", "msg" => "authenticated"}, state) do
    Logger.info("AlpacaStream authenticated")
    new_state = %{state | status: :authenticated}

    # Send pending subscriptions
    if map_size(state.pending_subscriptions) > 0 do
      # Send message to self to subscribe (can't call send_frame from callback)
      send(self(), {:send_subscription, state.pending_subscriptions})
      updated_subs = merge_subscriptions(state.subscriptions, state.pending_subscriptions)

      %{
        new_state
        | subscriptions: updated_subs,
          pending_subscriptions: %{bars: [], quotes: [], trades: [], statuses: []}
      }
    else
      new_state
    end
  end

  defp process_message(%{"T" => "subscription"} = msg, state) do
    Logger.info(
      "AlpacaStream subscribed to bars: #{inspect(msg["bars"])}, " <>
        "quotes: #{inspect(msg["quotes"])}, trades: #{inspect(msg["trades"])}, " <>
        "statuses: #{inspect(msg["statuses"])}"
    )

    %{state | status: :subscribed}
  end

  defp process_message(%{"T" => "error", "msg" => error_msg} = msg, state) do
    Logger.error("AlpacaStream error: #{error_msg}, code: #{inspect(msg["code"])}")
    state
  end

  # Data messages
  defp process_message(%{"T" => "q"} = msg, state) do
    try do
      quote = normalize_quote(msg)
      deliver_callback_message(quote, state)
    rescue
      error ->
        Logger.error(
          "Error normalizing quote: #{inspect(error)}\n" <>
            "Message: #{inspect(msg)}\n" <>
            "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        state
    end
  end

  defp process_message(%{"T" => "b"} = msg, state) do
    try do
      bar = normalize_bar(msg)
      deliver_callback_message(bar, state)
    rescue
      error ->
        Logger.error(
          "Error normalizing bar: #{inspect(error)}\n" <>
            "Message: #{inspect(msg)}\n" <>
            "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        state
    end
  end

  defp process_message(%{"T" => "t"} = msg, state) do
    try do
      trade = normalize_trade(msg)
      deliver_callback_message(trade, state)
    rescue
      error ->
        Logger.error(
          "Error normalizing trade: #{inspect(error)}\n" <>
            "Message: #{inspect(msg)}\n" <>
            "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        state
    end
  end

  defp process_message(%{"T" => "s"} = msg, state) do
    try do
      status = normalize_status(msg)
      deliver_callback_message(status, state)
    rescue
      error ->
        Logger.error(
          "Error normalizing status: #{inspect(error)}\n" <>
            "Message: #{inspect(msg)}\n" <>
            "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        state
    end
  end

  defp process_message(msg, state) do
    Logger.debug("AlpacaStream received unknown message type: #{inspect(msg)}")
    state
  end

  # Message Normalization

  defp normalize_quote(msg) do
    %{
      type: :quote,
      symbol: msg["S"],
      bid_price: parse_decimal(msg["bp"]),
      bid_size: msg["bs"],
      ask_price: parse_decimal(msg["ap"]),
      ask_size: msg["as"],
      timestamp: parse_datetime!(msg["t"])
    }
  end

  defp normalize_bar(msg) do
    %{
      type: :bar,
      symbol: msg["S"],
      open: parse_decimal(msg["o"]),
      high: parse_decimal(msg["h"]),
      low: parse_decimal(msg["l"]),
      close: parse_decimal(msg["c"]),
      volume: msg["v"],
      timestamp: parse_datetime!(msg["t"]),
      vwap: parse_decimal(msg["vw"]),
      trade_count: msg["n"]
    }
  end

  defp normalize_trade(msg) do
    %{
      type: :trade,
      symbol: msg["S"],
      price: parse_decimal(msg["p"]),
      size: msg["s"],
      timestamp: parse_datetime!(msg["t"])
    }
  end

  defp normalize_status(msg) do
    %{
      type: :status,
      symbol: msg["S"],
      status_code: msg["sc"],
      status_message: msg["sm"],
      timestamp: parse_datetime!(msg["t"])
    }
  end

  # Helpers

  defp parse_datetime!(nil), do: nil

  defp parse_datetime!(iso8601_string) when is_binary(iso8601_string) do
    case DateTime.from_iso8601(iso8601_string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime!(value) do
    Logger.warning("Unexpected value type in parse_datetime!: #{inspect(value)}")
    nil
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(value) when is_number(value), do: Decimal.new(to_string(value))
  defp parse_decimal(value) when is_binary(value), do: Decimal.new(value)

  defp parse_decimal(value) do
    Logger.warning("Unexpected value type in parse_decimal: #{inspect(value)}")
    nil
  end

  defp calculate_backoff(attempt) do
    # Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, max 60s
    min(trunc(:math.pow(2, attempt - 1) * 1000), 60_000)
  end

  defp merge_subscriptions(existing, new) do
    Map.merge(existing, new, fn _k, v1, v2 ->
      (v1 ++ v2) |> Enum.uniq()
    end)
  end

  defp remove_subscriptions(existing, to_remove) do
    Map.merge(existing, to_remove, fn _k, v1, v2 ->
      v1 -- v2
    end)
  end

  defp deliver_callback_message(message, state) do
    try do
      case state.callback_module.handle_message(message, state.callback_state) do
        {:ok, new_callback_state} ->
          %{state | callback_state: new_callback_state}

        other ->
          Logger.warning(
            "Callback module #{state.callback_module} returned invalid response: #{inspect(other)}"
          )

          state
      end
    rescue
      error ->
        Logger.error(
          "Error in callback module #{state.callback_module}: #{inspect(error)}\n" <>
            "Message: #{inspect(message)}\n" <>
            "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        state
    end
  end

  # Access behaviour for compatibility
  @impl Access
  def fetch(term, key), do: Map.fetch(term, key)

  @impl Access
  def get_and_update(data, key, function), do: Map.get_and_update(data, key, function)

  @impl Access
  def pop(data, key), do: Map.pop(data, key)
end
