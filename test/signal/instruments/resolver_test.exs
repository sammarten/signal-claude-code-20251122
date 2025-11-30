defmodule Signal.Instruments.ResolverTest do
  use Signal.DataCase, async: true

  alias Signal.Instruments.Resolver
  alias Signal.Instruments.Config
  alias Signal.Instruments.Equity
  alias Signal.Instruments.OptionsContract
  alias Signal.Options.Contract

  describe "resolve/2 with equity config" do
    test "resolves signal to equity instrument" do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        take_profit: Decimal.new("160.00")
      }

      config = Config.equity()

      assert {:ok, %Equity{} = equity} = Resolver.resolve(signal, config)
      assert equity.symbol == "AAPL"
      assert equity.direction == :long
      assert Decimal.equal?(equity.entry_price, Decimal.new("150.00"))
    end

    test "returns error for missing symbol" do
      signal = %{
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      config = Config.equity()

      assert {:error, {:missing_field, :symbol}} = Resolver.resolve(signal, config)
    end

    test "returns error for missing direction" do
      signal = %{
        symbol: "AAPL",
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      config = Config.equity()

      assert {:error, {:missing_field, :direction}} = Resolver.resolve(signal, config)
    end
  end

  describe "resolve/2 with options config" do
    setup do
      # Find next Friday for expiration (find_nearest_weekly only looks for Fridays)
      today = Date.utc_today()
      days_until_friday = rem(5 - Date.day_of_week(today) + 7, 7)
      days_until_friday = if days_until_friday == 0, do: 7, else: days_until_friday
      expiration = Date.add(today, days_until_friday)

      {:ok, call_contract} =
        %Contract{}
        |> Contract.changeset(%{
          symbol: "AAPL#{Calendar.strftime(expiration, "%y%m%d")}C00150000",
          underlying_symbol: "AAPL",
          contract_type: "call",
          expiration_date: expiration,
          strike_price: Decimal.new("150.00"),
          status: "active"
        })
        |> Repo.insert()

      {:ok, put_contract} =
        %Contract{}
        |> Contract.changeset(%{
          symbol: "AAPL#{Calendar.strftime(expiration, "%y%m%d")}P00150000",
          underlying_symbol: "AAPL",
          contract_type: "put",
          expiration_date: expiration,
          strike_price: Decimal.new("150.00"),
          status: "active"
        })
        |> Repo.insert()

      {:ok, expiration: expiration, call_contract: call_contract, put_contract: put_contract}
    end

    test "resolves long signal to call option", %{expiration: expiration} do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        generated_at: DateTime.utc_now()
      }

      config = Config.options()

      assert {:ok, %OptionsContract{} = option} = Resolver.resolve(signal, config)
      assert option.underlying_symbol == "AAPL"
      assert option.contract_type == :call
      assert option.expiration == expiration
      assert Decimal.equal?(option.strike, Decimal.new("150.00"))
    end

    test "resolves short signal to put option", %{expiration: expiration} do
      signal = %{
        symbol: "AAPL",
        direction: :short,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("155.00"),
        generated_at: DateTime.utc_now()
      }

      config = Config.options()

      assert {:ok, %OptionsContract{} = option} = Resolver.resolve(signal, config)
      assert option.underlying_symbol == "AAPL"
      assert option.contract_type == :put
      assert option.expiration == expiration
    end

    test "returns error when no contract found" do
      signal = %{
        symbol: "UNKNOWN",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        generated_at: DateTime.utc_now()
      }

      config = Config.options()

      assert {:error, :no_expiration_found} = Resolver.resolve(signal, config)
    end
  end

  describe "resolve_equity/1" do
    test "resolves signal to equity" do
      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00")
      }

      assert {:ok, %Equity{} = equity} = Resolver.resolve_equity(signal)
      assert equity.symbol == "AAPL"
    end
  end

  describe "direction_to_contract_type/1" do
    test "long direction maps to call" do
      assert Resolver.direction_to_contract_type(:long) == :call
    end

    test "short direction maps to put" do
      assert Resolver.direction_to_contract_type(:short) == :put
    end
  end

  describe "select_strike/3" do
    test "ATM strike selection" do
      config = Config.new(strike_selection: :atm)

      assert {:ok, strike} = Resolver.select_strike(Decimal.new("152.00"), :call, config)
      assert Decimal.equal?(strike, Decimal.new("150"))
    end

    test "one OTM strike for call" do
      config = Config.new(strike_selection: :one_otm)

      assert {:ok, strike} = Resolver.select_strike(Decimal.new("152.00"), :call, config)
      # ATM is 150, 1 OTM call is 155
      assert Decimal.equal?(strike, Decimal.new("155"))
    end

    test "one OTM strike for put" do
      config = Config.new(strike_selection: :one_otm)

      assert {:ok, strike} = Resolver.select_strike(Decimal.new("152.00"), :put, config)
      # ATM is 150, 1 OTM put is 145
      assert Decimal.equal?(strike, Decimal.new("145"))
    end

    test "two OTM strike for call" do
      config = Config.new(strike_selection: :two_otm)

      assert {:ok, strike} = Resolver.select_strike(Decimal.new("152.00"), :call, config)
      # ATM is 150, 2 OTM call is 160
      assert Decimal.equal?(strike, Decimal.new("160"))
    end

    test "two OTM strike for put" do
      config = Config.new(strike_selection: :two_otm)

      assert {:ok, strike} = Resolver.select_strike(Decimal.new("152.00"), :put, config)
      # ATM is 150, 2 OTM put is 140
      assert Decimal.equal?(strike, Decimal.new("140"))
    end
  end

  describe "round_to_nearest_strike/1" do
    test "rounds to $1 increment under $50" do
      assert Decimal.equal?(
               Resolver.round_to_nearest_strike(Decimal.new("23.45")),
               Decimal.new("23")
             )

      assert Decimal.equal?(
               Resolver.round_to_nearest_strike(Decimal.new("23.65")),
               Decimal.new("24")
             )
    end

    test "rounds to $5 increment between $50 and $200" do
      assert Decimal.equal?(
               Resolver.round_to_nearest_strike(Decimal.new("152.00")),
               Decimal.new("150")
             )

      assert Decimal.equal?(
               Resolver.round_to_nearest_strike(Decimal.new("153.00")),
               Decimal.new("155")
             )

      assert Decimal.equal?(
               Resolver.round_to_nearest_strike(Decimal.new("157.50")),
               Decimal.new("160")
             )
    end

    test "rounds to $10 increment over $200" do
      assert Decimal.equal?(
               Resolver.round_to_nearest_strike(Decimal.new("234.00")),
               Decimal.new("230")
             )

      assert Decimal.equal?(
               Resolver.round_to_nearest_strike(Decimal.new("236.00")),
               Decimal.new("240")
             )
    end
  end

  describe "strike_increment/1" do
    test "returns $1 for prices under $50" do
      assert Decimal.equal?(Resolver.strike_increment(Decimal.new("25.00")), Decimal.new("1"))
      assert Decimal.equal?(Resolver.strike_increment(Decimal.new("49.99")), Decimal.new("1"))
    end

    test "returns $5 for prices between $50 and $200" do
      assert Decimal.equal?(Resolver.strike_increment(Decimal.new("50.00")), Decimal.new("5"))
      assert Decimal.equal?(Resolver.strike_increment(Decimal.new("150.00")), Decimal.new("5"))
      assert Decimal.equal?(Resolver.strike_increment(Decimal.new("199.99")), Decimal.new("5"))
    end

    test "returns $10 for prices over $200" do
      assert Decimal.equal?(Resolver.strike_increment(Decimal.new("200.00")), Decimal.new("10"))
      assert Decimal.equal?(Resolver.strike_increment(Decimal.new("500.00")), Decimal.new("10"))
    end
  end
end
