# Signal Scripts

This directory contains utility scripts for testing and interacting with the Signal trading system.

## test_alpaca_stream.exs

Test the Alpaca WebSocket connection using the test stream endpoint.

### Usage

1. **Set your Alpaca credentials** (required even for test stream):
   ```bash
   export ALPACA_API_KEY="your_key_here"
   export ALPACA_API_SECRET="your_secret_here"
   ```

   Or use the `.env` file:
   ```bash
   source .env
   ```

2. **Start IEx**:
   ```bash
   iex -S mix
   ```

3. **Run the script**:
   ```elixir
   Code.eval_file("scripts/test_alpaca_stream.exs")
   ```

### What It Does

- Connects to the Alpaca test WebSocket stream (`wss://stream.data.alpaca.markets/v2/test`)
- Subscribes to the `FAKEPACA` symbol (test symbol that always has data)
- Displays real-time messages in color-coded format:
  - 🟢 **Green** - Quotes (bid/ask prices)
  - 🔵 **Blue** - Bars (OHLCV data)
  - 🟡 **Yellow** - Trades
  - 🟣 **Magenta** - Status changes
  - 🔵 **Cyan** - Connection events

### Available Commands

Once the script is running, you can use these commands in IEx:

```elixir
# Check how many messages received
TestStreamHandler.message_count()

# Get all received messages
TestStreamHandler.get_messages()

# Clear message history
TestStreamHandler.clear_messages()

# Check connection status
Signal.Alpaca.Stream.status(:test_stream)

# View active subscriptions
Signal.Alpaca.Stream.subscriptions(:test_stream)

# Stop the test stream
GenServer.stop(:test_stream)
```

### Example Output

```
================================================================================
  Alpaca Test Stream Connection Script
================================================================================

This script will connect to the Alpaca test WebSocket stream and subscribe
to the FAKEPACA symbol. You should start seeing messages within a few seconds.

✓ Alpaca credentials configured

Starting WebSocket connection to test stream...
URL: wss://stream.data.alpaca.markets/v2/test
✓ Stream started successfully (PID: #PID<0.456.0>)
Connection status: connected

Waiting for messages...
(Messages will appear below as they arrive)

[1] CONNECTION: connected
[2] QUOTE: FAKEPACA - Bid: $100.25 (100) | Ask: $100.27 (200)
[3] BAR: FAKEPACA - O: $100.20 H: $100.30 L: $100.15 C: $100.25 V: 15000
[4] TRADE: FAKEPACA - Price: $100.26 Size: 50
```

### Troubleshooting

**"Alpaca credentials NOT configured"**
- Make sure you've set `ALPACA_API_KEY` and `ALPACA_API_SECRET` environment variables
- Get free credentials at https://alpaca.markets/
- Restart IEx after setting credentials: `source .env && iex -S mix`

**"Stream already running"**
- Stop the existing stream: `GenServer.stop(:test_stream)`
- Run the script again

**No messages appearing**
- Wait 10-30 seconds (sometimes takes a moment to start)
- Check status: `Signal.Alpaca.Stream.status(:test_stream)`
- Should see status change: `:connecting` → `:connected` → `:authenticated` → `:subscribed`

### Notes

- The test stream is available 24/7, even outside market hours
- Only use the `FAKEPACA` symbol with the test stream
- Real market data requires the production stream endpoint
- The script temporarily overrides the WebSocket URL configuration to use the test endpoint
