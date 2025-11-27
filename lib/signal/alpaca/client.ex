defmodule Signal.Alpaca.Client do
  @moduledoc """
  HTTP client for Alpaca REST API for historical data and trading operations.

  Uses the Req library for HTTP requests with automatic retry on rate limiting,
  pagination handling, and response parsing to Elixir data structures.

  ## Rate Limiting

  Alpaca free tier limits:
  - REST API: 200 requests/minute
  - Each pagination request counts separately
  - Client automatically retries on 429 (rate limited) with exponential backoff

  ## Examples

      iex> Signal.Alpaca.Client.get_latest_bar("AAPL")
      {:ok, %{
        timestamp: ~U[2024-11-15 14:30:00Z],
        open: Decimal.new("185.20"),
        high: Decimal.new("185.60"),
        low: Decimal.new("184.90"),
        close: Decimal.new("185.45"),
        volume: 2_300_000
      }}

      iex> Signal.Alpaca.Client.get_bars(["AAPL"], start: ~U[2024-01-01 00:00:00Z], end: ~U[2024-01-02 00:00:00Z])
      {:ok, %{"AAPL" => [%{timestamp: ~U[...], open: Decimal.new("185.20"), ...}]}}
  """

  require Logger
  alias Signal.Alpaca.Config

  @max_pagination_pages 100
  @retry_delays [1000, 2000, 4000]

  # Market Data API

  @doc """
  Get historical bars for one or more symbols.

  Automatically handles pagination (up to 100 pages) and converts responses
  to Elixir data structures with DateTime and Decimal types.

  ## Parameters

    - `symbols` - String or list of strings (symbol tickers)
    - `opts` - Keyword list with options:
      - `:start` (required) - DateTime for start of range
      - `:end` (required) - DateTime for end of range
      - `:timeframe` - String, default "1Min"
      - `:limit` - Integer, max 10000 per page
      - `:adjustment` - String, default "raw"

  ## Returns

    - `{:ok, %{symbol => [bar_map]}}` - Map of symbols to list of bars
    - `{:error, reason}` - Error details

  ## Examples

      iex> Signal.Alpaca.Client.get_bars(
      ...>   ["AAPL", "TSLA"],
      ...>   start: ~U[2024-01-01 00:00:00Z],
      ...>   end: ~U[2024-01-02 00:00:00Z]
      ...> )
      {:ok, %{
        "AAPL" => [%{timestamp: ~U[...], open: Decimal.new("185.20"), ...}],
        "TSLA" => [%{timestamp: ~U[...], open: Decimal.new("245.30"), ...}]
      }}
  """
  @spec get_bars(String.t() | [String.t()], keyword()) ::
          {:ok, %{String.t() => [map()]}} | {:error, any()}
  def get_bars(symbols, opts) when is_list(symbols) do
    symbols_param = Enum.join(symbols, ",")
    get_bars(symbols_param, opts)
  end

  def get_bars(symbols, opts) when is_binary(symbols) do
    start_time = Keyword.fetch!(opts, :start)
    end_time = Keyword.fetch!(opts, :end)
    timeframe = Keyword.get(opts, :timeframe, "1Min")
    limit = Keyword.get(opts, :limit, 10000)
    adjustment = Keyword.get(opts, :adjustment, "raw")

    params = %{
      symbols: symbols,
      start: format_datetime(start_time),
      end: format_datetime(end_time),
      timeframe: timeframe,
      limit: limit,
      adjustment: adjustment
    }

    fetch_bars_with_pagination("/v2/stocks/bars", params)
  end

  @doc """
  Get most recent bar for a symbol.

  ## Parameters

    - `symbol` - String symbol ticker

  ## Returns

    - `{:ok, bar_map}` - Bar data with DateTime and Decimal types
    - `{:error, reason}` - Error details

  ## Examples

      iex> Signal.Alpaca.Client.get_latest_bar("AAPL")
      {:ok, %{timestamp: ~U[...], open: Decimal.new("185.20"), ...}}
  """
  @spec get_latest_bar(String.t()) :: {:ok, map()} | {:error, any()}
  def get_latest_bar(symbol) do
    case data_get("/v2/stocks/#{symbol}/bars/latest") do
      {:ok, %{"bar" => bar_data}} ->
        {:ok, parse_bar(bar_data)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get most recent quote for a symbol.

  ## Parameters

    - `symbol` - String symbol ticker

  ## Returns

    - `{:ok, quote_map}` - Quote data with DateTime and Decimal types
    - `{:error, reason}` - Error details
  """
  @spec get_latest_quote(String.t()) :: {:ok, map()} | {:error, any()}
  def get_latest_quote(symbol) do
    case data_get("/v2/stocks/#{symbol}/quotes/latest") do
      {:ok, %{"quote" => quote_data}} ->
        {:ok, parse_quote(quote_data)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get most recent trade for a symbol.

  ## Parameters

    - `symbol` - String symbol ticker

  ## Returns

    - `{:ok, trade_map}` - Trade data with DateTime and Decimal types
    - `{:error, reason}` - Error details
  """
  @spec get_latest_trade(String.t()) :: {:ok, map()} | {:error, any()}
  def get_latest_trade(symbol) do
    case data_get("/v2/stocks/#{symbol}/trades/latest") do
      {:ok, %{"trade" => trade_data}} ->
        {:ok, parse_trade(trade_data)}

      {:error, _} = error ->
        error
    end
  end

  # Calendar API

  @doc """
  Get market calendar for a date range.

  Returns trading days with market open/close times. Non-trading days
  (weekends, holidays) are not included in the response.

  ## Parameters

    - `opts` - Keyword list with options:
      - `:start` - Date for start of range (optional)
      - `:end` - Date for end of range (optional)

  ## Returns

    - `{:ok, [calendar_day]}` - List of trading days
    - `{:error, reason}` - Error details

  ## Examples

      iex> Signal.Alpaca.Client.get_calendar(start: ~D[2024-01-01], end: ~D[2024-01-31])
      {:ok, [
        %{date: ~D[2024-01-02], open: ~T[09:30:00], close: ~T[16:00:00]},
        %{date: ~D[2024-01-03], open: ~T[09:30:00], close: ~T[16:00:00]},
        ...
      ]}
  """
  @spec get_calendar(keyword()) :: {:ok, [map()]} | {:error, any()}
  def get_calendar(opts \\ []) do
    params =
      opts
      |> Keyword.take([:start, :end])
      |> Enum.map(fn
        {:start, %Date{} = date} -> {:start, Date.to_iso8601(date)}
        {:end, %Date{} = date} -> {:end, Date.to_iso8601(date)}
        other -> other
      end)
      |> Map.new()

    case get("/v2/calendar", params) do
      {:ok, calendar_data} when is_list(calendar_data) ->
        {:ok, Enum.map(calendar_data, &parse_calendar_day/1)}

      {:error, _} = error ->
        error
    end
  end

  defp parse_calendar_day(day_data) do
    %{
      date: Date.from_iso8601!(day_data["date"]),
      open: Time.from_iso8601!(day_data["open"] <> ":00"),
      close: Time.from_iso8601!(day_data["close"] <> ":00")
    }
  end

  # Account API

  @doc """
  Get account information.

  ## Returns

    - `{:ok, account_map}` - Account details
    - `{:error, reason}` - Error details
  """
  @spec get_account() :: {:ok, map()} | {:error, any()}
  def get_account do
    get("/v2/account")
  end

  @doc """
  Get all open positions.

  ## Returns

    - `{:ok, [position_map]}` - List of positions
    - `{:error, reason}` - Error details
  """
  @spec get_positions() :: {:ok, [map()]} | {:error, any()}
  def get_positions do
    get("/v2/positions")
  end

  @doc """
  Get position for specific symbol.

  ## Parameters

    - `symbol` - String symbol ticker

  ## Returns

    - `{:ok, position_map}` - Position details
    - `{:error, reason}` - Error details (including :not_found if no position)
  """
  @spec get_position(String.t()) :: {:ok, map()} | {:error, any()}
  def get_position(symbol) do
    get("/v2/positions/#{symbol}")
  end

  # Orders API

  @doc """
  Get orders with optional filters.

  ## Parameters

    - `opts` - Keyword list with options:
      - `:status` - "open", "closed", or "all"
      - `:limit` - Integer (max 500)
      - `:symbols` - List of strings

  ## Returns

    - `{:ok, [order_map]}` - List of orders
    - `{:error, reason}` - Error details
  """
  @spec list_orders(keyword()) :: {:ok, [map()]} | {:error, any()}
  def list_orders(opts \\ []) do
    params =
      opts
      |> Enum.into(%{})
      |> Map.update(:symbols, nil, fn symbols ->
        if symbols, do: Enum.join(symbols, ","), else: nil
      end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    get("/v2/orders", params)
  end

  @doc """
  Get specific order by ID.

  ## Parameters

    - `order_id` - String order ID

  ## Returns

    - `{:ok, order_map}` - Order details
    - `{:error, reason}` - Error details
  """
  @spec get_order(String.t()) :: {:ok, map()} | {:error, any()}
  def get_order(order_id) do
    get("/v2/orders/#{order_id}")
  end

  @doc """
  Submit new order.

  ## Parameters

    - `order` - Map with required keys:
      - `:symbol` - String
      - `:qty` - Integer
      - `:side` - "buy" or "sell"
      - `:type` - "market", "limit", "stop", etc.
      - `:time_in_force` - "day", "gtc", etc.

  ## Returns

    - `{:ok, order_map}` - Created order details
    - `{:error, reason}` - Error details
  """
  @spec place_order(map()) :: {:ok, map()} | {:error, any()}
  def place_order(order) do
    post("/v2/orders", order)
  end

  @doc """
  Cancel order by ID.

  ## Parameters

    - `order_id` - String order ID

  ## Returns

    - `{:ok, %{}}` - Success
    - `{:error, reason}` - Error details
  """
  @spec cancel_order(String.t()) :: {:ok, map()} | {:error, any()}
  def cancel_order(order_id) do
    delete("/v2/orders/#{order_id}")
  end

  @doc """
  Cancel all open orders.

  ## Returns

    - `{:ok, [order_map]}` - List of canceled orders
    - `{:error, reason}` - Error details
  """
  @spec cancel_all_orders() :: {:ok, [map()]} | {:error, any()}
  def cancel_all_orders do
    delete("/v2/orders")
  end

  # Private HTTP functions

  defp fetch_bars_with_pagination(path, params, page \\ 0, accumulated \\ %{}) do
    if page >= @max_pagination_pages do
      Logger.warning(
        "Hit maximum pagination limit (#{@max_pagination_pages} pages) for bars request"
      )

      {:ok, accumulated}
    else
      case data_get(path, params) do
        {:ok, response} ->
          bars = parse_bars_response(response)
          merged = deep_merge_bars(accumulated, bars)

          case response["next_page_token"] do
            nil ->
              {:ok, merged}

            "" ->
              {:ok, merged}

            token ->
              new_params = Map.put(params, :page_token, token)
              fetch_bars_with_pagination(path, new_params, page + 1, merged)
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp get(path, params \\ %{}) do
    request(:get, path, params: params)
  end

  defp post(path, body) do
    request(:post, path, json: body)
  end

  defp delete(path) do
    request(:delete, path)
  end

  defp data_get(path, params \\ %{}) do
    data_request(:get, path, params: params)
  end

  defp request(method, path, opts \\ []) do
    url = build_url(path)

    req_opts =
      [
        method: method,
        url: url,
        headers: build_headers(),
        retry: :transient,
        max_retries: 3,
        retry_delay: fn attempt -> Enum.at(@retry_delays, attempt - 1, 4000) end
      ] ++ opts

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, {:unprocessable, body}}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        {:error, {:server_error, %{status: status, body: body}}}

      {:error, error} ->
        {:error, {:network_error, error}}
    end
  rescue
    error ->
      {:error, {:invalid_response, error}}
  end

  # Market data request - uses data.alpaca.markets
  defp data_request(method, path, opts) do
    url = build_data_url(path)

    req_opts =
      [
        method: method,
        url: url,
        headers: build_headers(),
        retry: :transient,
        max_retries: 3,
        retry_delay: fn attempt -> Enum.at(@retry_delays, attempt - 1, 4000) end
      ] ++ opts

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, {:unprocessable, body}}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} when status >= 500 ->
        {:error, {:server_error, %{status: status, body: body}}}

      {:error, error} ->
        {:error, {:network_error, error}}
    end
  rescue
    error ->
      {:error, {:invalid_response, error}}
  end

  defp build_url(path) do
    base = Config.base_url()
    base <> path
  end

  defp build_data_url(path) do
    base = Config.data_url()
    base <> path
  end

  defp build_headers do
    [
      {"APCA-API-KEY-ID", Config.api_key!()},
      {"APCA-API-SECRET-KEY", Config.api_secret!()},
      {"Content-Type", "application/json"}
    ]
  end

  # Response parsing

  defp parse_bars_response(%{"bars" => bars_map}) when is_map(bars_map) do
    Map.new(bars_map, fn {symbol, bars} ->
      {symbol, Enum.map(bars, &parse_bar/1)}
    end)
  end

  defp parse_bars_response(_), do: %{}

  defp parse_bar(bar_data) do
    %{
      timestamp: parse_datetime!(bar_data["t"]),
      open: parse_decimal(bar_data["o"]),
      high: parse_decimal(bar_data["h"]),
      low: parse_decimal(bar_data["l"]),
      close: parse_decimal(bar_data["c"]),
      volume: bar_data["v"],
      vwap: parse_decimal(bar_data["vw"]),
      trade_count: bar_data["n"]
    }
  end

  defp parse_quote(quote_data) do
    %{
      bid_price: parse_decimal(quote_data["bp"]),
      bid_size: quote_data["bs"],
      ask_price: parse_decimal(quote_data["ap"]),
      ask_size: quote_data["as"],
      timestamp: parse_datetime!(quote_data["t"])
    }
  end

  defp parse_trade(trade_data) do
    %{
      price: parse_decimal(trade_data["p"]),
      size: trade_data["s"],
      timestamp: parse_datetime!(trade_data["t"])
    }
  end

  defp parse_datetime!(nil), do: nil

  defp parse_datetime!(iso8601_string) do
    case DateTime.from_iso8601(iso8601_string) do
      {:ok, datetime, _offset} ->
        # Ensure microsecond precision for :utc_datetime_usec fields
        # Alpaca returns timestamps like "2025-01-01T00:03:00Z" without microseconds
        # Add microseconds if missing by setting precision to 6 digits
        %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

      {:error, _} ->
        nil
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(value) when is_number(value), do: Decimal.new(to_string(value))
  defp parse_decimal(value) when is_binary(value), do: Decimal.new(value)

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp deep_merge_bars(map1, map2) do
    Map.merge(map1, map2, fn _k, v1, v2 -> v1 ++ v2 end)
  end
end
