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

  # =============================================================================
  # Options API
  # =============================================================================

  @doc """
  Get options contracts for one or more underlying symbols.

  Fetches available options contracts from Alpaca's options API with optional
  filtering by expiration date, strike price, and contract type.

  ## Parameters

    - `underlying_symbols` - String or list of underlying symbols (e.g., "AAPL" or ["AAPL", "SPY"])
    - `opts` - Keyword list with options:
      - `:expiration_date` - Specific expiration date (Date)
      - `:expiration_date_gte` - Expiration on or after date (Date)
      - `:expiration_date_lte` - Expiration on or before date (Date)
      - `:strike_price_gte` - Strike price >= value (Decimal or number)
      - `:strike_price_lte` - Strike price <= value (Decimal or number)
      - `:type` - Contract type: "call" or "put"
      - `:status` - Contract status: "active" (default) or "inactive"
      - `:limit` - Maximum number of results (default 100)

  ## Returns

    - `{:ok, [contract_map]}` - List of contract data maps
    - `{:error, reason}` - Error details

  ## Examples

      iex> Signal.Alpaca.Client.get_options_contracts("AAPL",
      ...>   expiration_date_gte: ~D[2025-01-01],
      ...>   expiration_date_lte: ~D[2025-01-31],
      ...>   type: "call"
      ...> )
      {:ok, [%{"symbol" => "AAPL250117C00150000", ...}]}
  """
  @spec get_options_contracts(String.t() | [String.t()], keyword()) ::
          {:ok, [map()]} | {:error, any()}
  def get_options_contracts(underlying_symbols, opts \\ []) do
    symbols =
      case underlying_symbols do
        list when is_list(list) -> list
        single -> [single]
      end

    params =
      %{underlying_symbols: Enum.join(symbols, ",")}
      |> maybe_add_option_contract_params(opts)

    case get("/v2/options/contracts", params) do
      {:ok, %{"option_contracts" => contracts}} when is_list(contracts) ->
        {:ok, contracts}

      {:ok, %{"option_contracts" => nil}} ->
        {:ok, []}

      {:ok, response} when is_list(response) ->
        {:ok, response}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get a single options contract by its symbol.

  ## Parameters

    - `symbol` - The OSI format contract symbol (e.g., "AAPL250117C00150000")

  ## Returns

    - `{:ok, contract_map}` - Contract data
    - `{:error, reason}` - Error details

  ## Examples

      iex> Signal.Alpaca.Client.get_options_contract("AAPL250117C00150000")
      {:ok, %{"symbol" => "AAPL250117C00150000", "underlying_symbol" => "AAPL", ...}}
  """
  @spec get_options_contract(String.t()) :: {:ok, map()} | {:error, any()}
  def get_options_contract(symbol) do
    get("/v2/options/contracts/#{symbol}")
  end

  @doc """
  Get historical bars for one or more options contracts.

  Similar to `get_bars/2` but for options contracts. Returns OHLCV data
  for the specified contract(s) and time range.

  Note: Options data is only available from February 2024 onward.

  ## Parameters

    - `symbols` - String or list of OSI format contract symbols
    - `opts` - Keyword list with options:
      - `:start` (required) - DateTime for start of range
      - `:end` (required) - DateTime for end of range
      - `:timeframe` - String, default "1Min"
      - `:limit` - Integer, max 10000 per page

  ## Returns

    - `{:ok, %{symbol => [bar_map]}}` - Map of symbols to list of bars
    - `{:error, reason}` - Error details

  ## Examples

      iex> Signal.Alpaca.Client.get_options_bars(
      ...>   "AAPL250117C00150000",
      ...>   start: ~U[2024-06-01 09:30:00Z],
      ...>   end: ~U[2024-06-01 16:00:00Z]
      ...> )
      {:ok, %{
        "AAPL250117C00150000" => [%{timestamp: ~U[...], open: Decimal.new("5.20"), ...}]
      }}
  """
  @spec get_options_bars(String.t() | [String.t()], keyword()) ::
          {:ok, %{String.t() => [map()]}} | {:error, any()}
  def get_options_bars(symbols, opts) when is_list(symbols) do
    symbols_param = Enum.join(symbols, ",")
    get_options_bars(symbols_param, opts)
  end

  def get_options_bars(symbols, opts) when is_binary(symbols) do
    start_time = Keyword.fetch!(opts, :start)
    end_time = Keyword.fetch!(opts, :end)
    timeframe = Keyword.get(opts, :timeframe, "1Min")
    limit = Keyword.get(opts, :limit, 10000)

    params = %{
      symbols: symbols,
      start: format_datetime(start_time),
      end: format_datetime(end_time),
      timeframe: timeframe,
      limit: limit
    }

    fetch_options_bars_with_pagination("/v1beta1/options/bars", params)
  end

  @doc """
  Get the latest snapshot for an options contract.

  Returns the most recent quote and trade data for the specified contract.

  ## Parameters

    - `symbol` - The OSI format contract symbol

  ## Returns

    - `{:ok, snapshot_map}` - Snapshot data with latest quote and trade
    - `{:error, reason}` - Error details

  ## Examples

      iex> Signal.Alpaca.Client.get_options_snapshot("AAPL250117C00150000")
      {:ok, %{
        symbol: "AAPL250117C00150000",
        latest_quote: %{bid_price: Decimal.new("5.10"), ...},
        latest_trade: %{price: Decimal.new("5.15"), ...}
      }}
  """
  @spec get_options_snapshot(String.t()) :: {:ok, map()} | {:error, any()}
  def get_options_snapshot(symbol) do
    case data_get("/v1beta1/options/snapshots/#{symbol}") do
      {:ok, response} ->
        {:ok, parse_options_snapshot(response)}

      {:error, _} = error ->
        error
    end
  end

  # Private helpers for options API

  defp maybe_add_option_contract_params(params, opts) do
    params
    |> maybe_add_date_param(:expiration_date, Keyword.get(opts, :expiration_date))
    |> maybe_add_date_param(:expiration_date_gte, Keyword.get(opts, :expiration_date_gte))
    |> maybe_add_date_param(:expiration_date_lte, Keyword.get(opts, :expiration_date_lte))
    |> maybe_add_decimal_param(:strike_price_gte, Keyword.get(opts, :strike_price_gte))
    |> maybe_add_decimal_param(:strike_price_lte, Keyword.get(opts, :strike_price_lte))
    |> maybe_add_param(:type, Keyword.get(opts, :type))
    |> maybe_add_param(:status, Keyword.get(opts, :status))
    |> maybe_add_param(:limit, Keyword.get(opts, :limit))
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Map.put(params, key, value)

  defp maybe_add_date_param(params, _key, nil), do: params

  defp maybe_add_date_param(params, key, %Date{} = date) do
    Map.put(params, key, Date.to_iso8601(date))
  end

  defp maybe_add_date_param(params, key, date_string) when is_binary(date_string) do
    Map.put(params, key, date_string)
  end

  defp maybe_add_decimal_param(params, _key, nil), do: params

  defp maybe_add_decimal_param(params, key, %Decimal{} = value) do
    Map.put(params, key, Decimal.to_string(value))
  end

  defp maybe_add_decimal_param(params, key, value) when is_number(value) do
    Map.put(params, key, to_string(value))
  end

  defp fetch_options_bars_with_pagination(path, params, page \\ 0, accumulated \\ %{}) do
    if page >= @max_pagination_pages do
      Logger.warning(
        "Hit maximum pagination limit (#{@max_pagination_pages} pages) for options bars request"
      )

      {:ok, accumulated}
    else
      case data_get(path, params) do
        {:ok, response} ->
          bars = parse_options_bars_response(response)
          merged = deep_merge_bars(accumulated, bars)

          case response["next_page_token"] do
            nil ->
              {:ok, merged}

            "" ->
              {:ok, merged}

            token ->
              new_params = Map.put(params, :page_token, token)
              fetch_options_bars_with_pagination(path, new_params, page + 1, merged)
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp parse_options_bars_response(%{"bars" => bars_map}) when is_map(bars_map) do
    Map.new(bars_map, fn {symbol, bars} ->
      {symbol, Enum.map(bars, &parse_bar/1)}
    end)
  end

  defp parse_options_bars_response(_), do: %{}

  defp parse_options_snapshot(response) do
    %{
      symbol: response["symbol"],
      latest_quote: parse_options_quote(response["latestQuote"]),
      latest_trade: parse_options_trade(response["latestTrade"]),
      implied_volatility: parse_decimal(response["impliedVolatility"]),
      greeks: parse_greeks(response["greeks"])
    }
  end

  defp parse_options_quote(nil), do: nil

  defp parse_options_quote(quote_data) do
    %{
      bid_price: parse_decimal(quote_data["bp"]),
      bid_size: quote_data["bs"],
      ask_price: parse_decimal(quote_data["ap"]),
      ask_size: quote_data["as"],
      bid_exchange: quote_data["bx"],
      ask_exchange: quote_data["ax"],
      timestamp: parse_datetime!(quote_data["t"])
    }
  end

  defp parse_options_trade(nil), do: nil

  defp parse_options_trade(trade_data) do
    %{
      price: parse_decimal(trade_data["p"]),
      size: trade_data["s"],
      exchange: trade_data["x"],
      timestamp: parse_datetime!(trade_data["t"])
    }
  end

  defp parse_greeks(nil), do: nil

  defp parse_greeks(greeks) do
    %{
      delta: parse_decimal(greeks["delta"]),
      gamma: parse_decimal(greeks["gamma"]),
      theta: parse_decimal(greeks["theta"]),
      vega: parse_decimal(greeks["vega"]),
      rho: parse_decimal(greeks["rho"])
    }
  end
end
