# Test Alpaca WebSocket Stream Connection
# Usage: In iex -S mix, run: Code.eval_file("scripts/test_alpaca_stream.exs")
#
# This script connects to the Alpaca test stream (wss://stream.data.alpaca.markets/v2/test)
# and subscribes to the FAKEPACA symbol to test the integration.

require Logger

defmodule TestStreamHandler do
  @moduledoc """
  Simple callback handler that logs all received messages.
  """
  @behaviour Signal.Alpaca.Stream

  def start_link do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @impl Signal.Alpaca.Stream
  def handle_message(message, state) do
    # Get current message count
    count = Agent.get_and_update(__MODULE__, fn messages ->
      new_messages = [message | messages]
      {length(new_messages), new_messages}
    end)

    # Log different message types with different colors
    case message.type do
      :quote ->
        IO.puts(IO.ANSI.green() <> "[#{count}] QUOTE: #{message.symbol} - " <>
          "Bid: $#{message.bid_price} (#{message.bid_size}) | " <>
          "Ask: $#{message.ask_price} (#{message.ask_size})" <> IO.ANSI.reset())

      :bar ->
        IO.puts(IO.ANSI.blue() <> "[#{count}] BAR: #{message.symbol} - " <>
          "O: $#{message.open} H: $#{message.high} L: $#{message.low} C: $#{message.close} " <>
          "V: #{message.volume}" <> IO.ANSI.reset())

      :trade ->
        IO.puts(IO.ANSI.yellow() <> "[#{count}] TRADE: #{message.symbol} - " <>
          "Price: $#{message.price} Size: #{message.size}" <> IO.ANSI.reset())

      :status ->
        IO.puts(IO.ANSI.magenta() <> "[#{count}] STATUS: #{message.symbol} - " <>
          "#{message.status_message} (#{message.status_code})" <> IO.ANSI.reset())

      :connection ->
        IO.puts(IO.ANSI.cyan() <> "[#{count}] CONNECTION: #{message.status}" <> IO.ANSI.reset())

      _ ->
        IO.puts("[#{count}] UNKNOWN: #{inspect(message)}")
    end

    {:ok, state}
  end

  def get_messages do
    Agent.get(__MODULE__, & &1) |> Enum.reverse()
  end

  def clear_messages do
    Agent.update(__MODULE__, fn _ -> [] end)
  end

  def message_count do
    Agent.get(__MODULE__, &length/1)
  end
end

# Start the test handler agent
{:ok, _pid} = TestStreamHandler.start_link()

IO.puts("\n" <> IO.ANSI.bright() <> IO.ANSI.cyan() <>
  "=" <> String.duplicate("=", 78) <> IO.ANSI.reset())
IO.puts(IO.ANSI.bright() <> "  Alpaca Test Stream Connection Script" <> IO.ANSI.reset())
IO.puts(IO.ANSI.cyan() <> String.duplicate("=", 80) <> IO.ANSI.reset() <> "\n")

IO.puts("This script will connect to the Alpaca test WebSocket stream and subscribe")
IO.puts("to the FAKEPACA symbol. You should start seeing messages within a few seconds.\n")

# Check if credentials are set (they're required even for test stream)
if Signal.Alpaca.Config.configured?() do
  IO.puts(IO.ANSI.green() <> "✓ Alpaca credentials configured" <> IO.ANSI.reset())
else
  IO.puts(IO.ANSI.red() <> "✗ Alpaca credentials NOT configured" <> IO.ANSI.reset())
  IO.puts("\nYou need to set ALPACA_API_KEY and ALPACA_API_SECRET environment variables")
  IO.puts("even for the test stream. You can get free credentials at:")
  IO.puts(IO.ANSI.blue() <> "  https://alpaca.markets/" <> IO.ANSI.reset())
  IO.puts("\nThen restart iex with: source .env && iex -S mix\n")
  :error
end

if Signal.Alpaca.Config.configured?() do
  IO.puts("\nStarting WebSocket connection to test stream...")
  IO.puts("URL: " <> IO.ANSI.blue() <> "wss://stream.data.alpaca.markets/v2/test" <> IO.ANSI.reset())

  # Override the ws_url in config temporarily for this test
  # We'll pass it directly to the stream
  test_stream_opts = [
    callback_module: TestStreamHandler,
    callback_state: %{},
    initial_subscriptions: %{
      bars: ["FAKEPACA"],
      quotes: ["FAKEPACA"],
      trades: ["FAKEPACA"],
      statuses: ["*"]
    },
    name: :test_stream
  ]

  # Start a custom stream process with the test URL
  # Note: We need to modify the stream to accept URL override, or we temporarily modify config
  original_ws_url = Application.get_env(:signal, Signal.Alpaca, [])[:ws_url]

  # Temporarily set the test URL
  current_config = Application.get_env(:signal, Signal.Alpaca, [])
  Application.put_env(:signal, Signal.Alpaca,
    Keyword.put(current_config, :ws_url, "wss://stream.data.alpaca.markets/v2/test"))

  case Signal.Alpaca.Stream.start_link(test_stream_opts) do
    {:ok, pid} ->
      IO.puts(IO.ANSI.green() <> "✓ Stream started successfully (PID: #{inspect(pid)})" <> IO.ANSI.reset())

      # Wait a moment for connection
      Process.sleep(2000)

      status = Signal.Alpaca.Stream.status(:test_stream)
      IO.puts("Connection status: " <> IO.ANSI.yellow() <> "#{status}" <> IO.ANSI.reset())

      IO.puts("\n" <> IO.ANSI.bright() <> "Waiting for messages..." <> IO.ANSI.reset())
      IO.puts("(Messages will appear below as they arrive)\n")

      # Restore original URL
      if original_ws_url do
        Application.put_env(:signal, Signal.Alpaca,
          Keyword.put(current_config, :ws_url, original_ws_url))
      end

      IO.puts("\n" <> IO.ANSI.cyan() <> String.duplicate("-", 80) <> IO.ANSI.reset())
      IO.puts(IO.ANSI.bright() <> "Available Commands:" <> IO.ANSI.reset())
      IO.puts("  " <> IO.ANSI.yellow() <> "TestStreamHandler.message_count()" <> IO.ANSI.reset() <>
        " - Get total message count")
      IO.puts("  " <> IO.ANSI.yellow() <> "TestStreamHandler.get_messages()" <> IO.ANSI.reset() <>
        " - Get all received messages")
      IO.puts("  " <> IO.ANSI.yellow() <> "TestStreamHandler.clear_messages()" <> IO.ANSI.reset() <>
        " - Clear message history")
      IO.puts("  " <> IO.ANSI.yellow() <> "Signal.Alpaca.Stream.status(:test_stream)" <> IO.ANSI.reset() <>
        " - Check connection status")
      IO.puts("  " <> IO.ANSI.yellow() <> "Signal.Alpaca.Stream.subscriptions(:test_stream)" <> IO.ANSI.reset() <>
        " - View active subscriptions")
      IO.puts("  " <> IO.ANSI.yellow() <> "GenServer.stop(:test_stream)" <> IO.ANSI.reset() <>
        " - Stop the test stream")
      IO.puts(IO.ANSI.cyan() <> String.duplicate("-", 80) <> IO.ANSI.reset() <> "\n")

      {:ok, pid}

    {:error, {:already_started, pid}} ->
      IO.puts(IO.ANSI.yellow() <> "⚠ Stream already running (PID: #{inspect(pid)})" <> IO.ANSI.reset())
      IO.puts("To restart, run: GenServer.stop(:test_stream)")
      IO.puts("Then run this script again.\n")
      {:error, :already_started}

    {:error, reason} ->
      IO.puts(IO.ANSI.red() <> "✗ Failed to start stream: #{inspect(reason)}" <> IO.ANSI.reset())

      # Restore original URL
      if original_ws_url do
        Application.put_env(:signal, Signal.Alpaca,
          Keyword.put(current_config, :ws_url, original_ws_url))
      end

      {:error, reason}
  end
end
