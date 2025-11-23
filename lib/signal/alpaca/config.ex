defmodule Signal.Alpaca.Config do
  @moduledoc """
  Configuration management for Alpaca API credentials and endpoints.

  Reads configuration from application environment variables and provides
  helper functions for accessing API credentials and URLs.

  ## Configuration

  Expected configuration format (in config/dev.exs or config/runtime.exs):

      config :signal, Signal.Alpaca,
        api_key: System.get_env("ALPACA_API_KEY"),
        api_secret: System.get_env("ALPACA_API_SECRET"),
        base_url: "https://paper-api.alpaca.markets",
        ws_url: "wss://stream.data.alpaca.markets/v2/iex"

  ## Examples

      iex> Signal.Alpaca.Config.configured?()
      true

      iex> Signal.Alpaca.Config.data_feed()
      :iex
  """

  @doc """
  Get API key, raises if not configured.

  ## Returns

    - String with the API key

  ## Raises

    - RuntimeError if ALPACA_API_KEY is not configured

  ## Examples

      iex> Signal.Alpaca.Config.api_key!()
      "your_api_key"
  """
  @spec api_key!() :: String.t()
  def api_key! do
    case api_key() do
      nil ->
        raise "Alpaca API key not configured. Set ALPACA_API_KEY environment variable."

      "" ->
        raise "Alpaca API key not configured. Set ALPACA_API_KEY environment variable."

      key ->
        key
    end
  end

  @doc """
  Get API secret, raises if not configured.

  ## Returns

    - String with the API secret

  ## Raises

    - RuntimeError if ALPACA_API_SECRET is not configured

  ## Examples

      iex> Signal.Alpaca.Config.api_secret!()
      "your_api_secret"
  """
  @spec api_secret!() :: String.t()
  def api_secret! do
    case api_secret() do
      nil ->
        raise "Alpaca API secret not configured. Set ALPACA_API_SECRET environment variable."

      "" ->
        raise "Alpaca API secret not configured. Set ALPACA_API_SECRET environment variable."

      secret ->
        secret
    end
  end

  @doc """
  Get REST API base URL with default.

  ## Returns

    - String with the base URL (defaults to paper trading URL)

  ## Examples

      iex> Signal.Alpaca.Config.base_url()
      "https://paper-api.alpaca.markets"
  """
  @spec base_url() :: String.t()
  def base_url do
    config()
    |> Keyword.get(:base_url, "https://paper-api.alpaca.markets")
  end

  @doc """
  Get WebSocket URL with default.

  ## Returns

    - String with the WebSocket URL (defaults to IEX feed)

  ## Examples

      iex> Signal.Alpaca.Config.ws_url()
      "wss://stream.data.alpaca.markets/v2/iex"
  """
  @spec ws_url() :: String.t()
  def ws_url do
    config()
    |> Keyword.get(:ws_url, "wss://stream.data.alpaca.markets/v2/iex")
  end

  @doc """
  Extract feed type from ws_url.

  Parses the WebSocket URL to determine which data feed is being used.

  ## Returns

    - `:iex` for IEX feed (default free tier)
    - `:sip` for SIP feed (paid tier, more complete data)
    - `:test` for test feed (for integration testing)

  ## Examples

      iex> Signal.Alpaca.Config.data_feed()
      :iex
  """
  @spec data_feed() :: :iex | :sip | :test
  def data_feed do
    url = ws_url()

    cond do
      String.contains?(url, "/v2/iex") -> :iex
      String.contains?(url, "/v2/sip") -> :sip
      String.contains?(url, "/v2/test") -> :test
      true -> :iex
    end
  end

  @doc """
  Check if credentials are configured.

  ## Returns

    - `true` if both api_key and api_secret are set and non-empty
    - `false` otherwise

  ## Examples

      iex> Signal.Alpaca.Config.configured?()
      true
  """
  @spec configured?() :: boolean()
  def configured? do
    key = api_key()
    secret = api_secret()

    not is_nil(key) and key != "" and not is_nil(secret) and secret != ""
  end

  @doc """
  Check if using paper trading URL.

  ## Returns

    - `true` if base_url contains "paper"
    - `false` otherwise

  ## Examples

      iex> Signal.Alpaca.Config.paper_trading?()
      true
  """
  @spec paper_trading?() :: boolean()
  def paper_trading? do
    String.contains?(base_url(), "paper")
  end

  # Private functions

  defp config do
    Application.get_env(:signal, Signal.Alpaca, [])
  end

  defp api_key do
    config() |> Keyword.get(:api_key)
  end

  defp api_secret do
    config() |> Keyword.get(:api_secret)
  end
end
