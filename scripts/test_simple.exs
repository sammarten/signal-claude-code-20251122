# Simple test - just use StreamHandler directly without the Agent

defmodule SimpleHandler do
  @behaviour Signal.Alpaca.Stream

  @impl Signal.Alpaca.Stream
  def handle_message(message, state) do
    IO.puts("Received: #{inspect(message)}")
    {:ok, state}
  end
end

IO.puts("Starting simple test...")
IO.puts("Connecting to test stream...")

# Override config temporarily
config = Application.get_env(:signal, Signal.Alpaca, [])
Application.put_env(:signal, Signal.Alpaca,
  Keyword.put(config, :ws_url, "wss://stream.data.alpaca.markets/v2/test"))

{:ok, pid} = Signal.Alpaca.Stream.start_link(
  callback_module: SimpleHandler,
  callback_state: %{},
  initial_subscriptions: %{
    bars: ["FAKEPACA"],
    quotes: ["FAKEPACA"]
  },
  name: :simple_test
)

IO.puts("Stream started: #{inspect(pid)}")
IO.puts("Waiting for messages...")
Process.sleep(10_000)

# Stop the stream
GenServer.stop(:simple_test)

# Restore config
Application.put_env(:signal, Signal.Alpaca, config)

IO.puts("Test complete")
