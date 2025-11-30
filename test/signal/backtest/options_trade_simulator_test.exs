defmodule Signal.Backtest.OptionsTradeSimulatorTest do
  use Signal.DataCase, async: true

  alias Signal.Backtest.OptionsTradeSimulator
  alias Signal.Instruments.Config
  alias Signal.Options.Contract

  describe "new/1" do
    test "creates simulator with defaults" do
      simulator = OptionsTradeSimulator.new()

      assert simulator.open_positions == %{}
      assert simulator.closed_trades == []
      assert Decimal.equal?(simulator.account.current_equity, Decimal.new("100000"))
      assert Decimal.equal?(simulator.account.risk_per_trade, Decimal.new("0.01"))
    end

    test "creates simulator with custom account" do
      account = %{
        current_equity: Decimal.new("50000"),
        risk_per_trade: Decimal.new("0.02"),
        cash: Decimal.new("50000")
      }

      simulator = OptionsTradeSimulator.new(account: account)

      assert Decimal.equal?(simulator.account.current_equity, Decimal.new("50000"))
      assert Decimal.equal?(simulator.account.risk_per_trade, Decimal.new("0.02"))
    end

    test "creates simulator with custom config" do
      config = Config.new(instrument_type: :options, strike_selection: :one_otm)
      simulator = OptionsTradeSimulator.new(config: config)

      assert simulator.config.strike_selection == :one_otm
    end
  end

  describe "execute_signal/4" do
    setup do
      # Create a test contract in the database
      expiration = find_next_friday()

      {:ok, contract} =
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

      # Create options bar for the contract
      bar_time = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _options_bar} =
        %Signal.Options.Bar{}
        |> Signal.Options.Bar.changeset(%{
          symbol: contract.symbol,
          bar_time: bar_time,
          open: Decimal.new("5.00"),
          high: Decimal.new("5.50"),
          low: Decimal.new("4.50"),
          close: Decimal.new("5.25"),
          volume: 1000,
          trade_count: 50,
          vwap: Decimal.new("5.10")
        })
        |> Repo.insert()

      underlying_bar = %{
        symbol: "AAPL",
        bar_time: bar_time,
        open: Decimal.new("150.00"),
        high: Decimal.new("152.00"),
        low: Decimal.new("148.00"),
        close: Decimal.new("151.00")
      }

      options_bar = %{
        symbol: contract.symbol,
        bar_time: bar_time,
        open: Decimal.new("5.00"),
        high: Decimal.new("5.50"),
        low: Decimal.new("4.50"),
        close: Decimal.new("5.25")
      }

      {:ok,
       contract: contract,
       expiration: expiration,
       underlying_bar: underlying_bar,
       options_bar: options_bar}
    end

    test "executes long signal to buy call", %{
      underlying_bar: underlying_bar,
      options_bar: options_bar,
      expiration: expiration
    } do
      simulator = OptionsTradeSimulator.new()

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        take_profit: Decimal.new("160.00"),
        generated_at: underlying_bar.bar_time
      }

      assert {:ok, updated_sim, trade} =
               OptionsTradeSimulator.execute_signal(
                 simulator,
                 signal,
                 underlying_bar,
                 options_bar
               )

      assert trade.contract_type == :call
      assert trade.direction == :long
      assert Decimal.equal?(trade.entry_premium, Decimal.new("5.00"))
      assert trade.num_contracts > 0
      assert trade.expiration == expiration
      assert Map.has_key?(updated_sim.open_positions, trade.id)
    end

    test "executes short signal to buy put", %{
      underlying_bar: underlying_bar,
      options_bar: options_bar
    } do
      # Need to create a put contract
      expiration = find_next_friday()

      {:ok, _put_contract} =
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

      simulator = OptionsTradeSimulator.new()

      signal = %{
        symbol: "AAPL",
        direction: :short,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("155.00"),
        take_profit: Decimal.new("140.00"),
        generated_at: underlying_bar.bar_time
      }

      # Use options bar for the put
      put_options_bar = %{
        options_bar
        | symbol: "AAPL#{Calendar.strftime(expiration, "%y%m%d")}P00150000"
      }

      assert {:ok, _updated_sim, trade} =
               OptionsTradeSimulator.execute_signal(
                 simulator,
                 signal,
                 underlying_bar,
                 put_options_bar
               )

      assert trade.contract_type == :put
      assert trade.direction == :short
    end

    test "deducts cash from account", %{
      underlying_bar: underlying_bar,
      options_bar: options_bar
    } do
      simulator = OptionsTradeSimulator.new()
      initial_cash = simulator.account.cash

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        generated_at: underlying_bar.bar_time
      }

      {:ok, updated_sim, trade} =
        OptionsTradeSimulator.execute_signal(
          simulator,
          signal,
          underlying_bar,
          options_bar
        )

      assert Decimal.lt?(updated_sim.account.cash, initial_cash)

      assert Decimal.equal?(
               Decimal.sub(initial_cash, updated_sim.account.cash),
               trade.total_cost
             )
    end
  end

  describe "close_position/5" do
    setup do
      # Create simulator with an open position
      expiration = find_next_friday()

      {:ok, contract} =
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

      bar_time = DateTime.utc_now() |> DateTime.truncate(:second)

      # Create bar data in database
      {:ok, _options_bar} =
        %Signal.Options.Bar{}
        |> Signal.Options.Bar.changeset(%{
          symbol: contract.symbol,
          bar_time: bar_time,
          open: Decimal.new("5.00"),
          high: Decimal.new("5.50"),
          low: Decimal.new("4.50"),
          close: Decimal.new("5.25"),
          volume: 1000,
          trade_count: 50,
          vwap: Decimal.new("5.10")
        })
        |> Repo.insert()

      simulator = OptionsTradeSimulator.new()

      underlying_bar = %{
        symbol: "AAPL",
        bar_time: bar_time,
        open: Decimal.new("150.00"),
        high: Decimal.new("152.00"),
        low: Decimal.new("148.00"),
        close: Decimal.new("151.00")
      }

      options_bar = %{
        symbol: contract.symbol,
        bar_time: bar_time,
        open: Decimal.new("5.00"),
        high: Decimal.new("5.50"),
        low: Decimal.new("4.50"),
        close: Decimal.new("5.25")
      }

      signal = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("150.00"),
        stop_loss: Decimal.new("145.00"),
        generated_at: bar_time
      }

      {:ok, sim_with_trade, trade} =
        OptionsTradeSimulator.execute_signal(simulator, signal, underlying_bar, options_bar)

      {:ok, simulator: sim_with_trade, trade: trade}
    end

    test "closes position with profit", %{simulator: simulator, trade: trade} do
      exit_time = DateTime.add(DateTime.utc_now(), 3600, :second)
      # Exit at higher premium = profit
      exit_premium = Decimal.new("6.00")

      assert {:ok, updated_sim, closed_trade} =
               OptionsTradeSimulator.close_position(
                 simulator,
                 trade.id,
                 exit_premium,
                 exit_time,
                 :target_hit
               )

      assert closed_trade.status == :target_hit
      assert Decimal.equal?(closed_trade.exit_premium, exit_premium)
      assert Decimal.gt?(closed_trade.pnl, Decimal.new(0))
      refute Map.has_key?(updated_sim.open_positions, trade.id)
      assert length(updated_sim.closed_trades) == 1
    end

    test "closes position with loss", %{simulator: simulator, trade: trade} do
      exit_time = DateTime.add(DateTime.utc_now(), 3600, :second)
      # Exit at lower premium = loss
      exit_premium = Decimal.new("3.00")

      assert {:ok, _updated_sim, closed_trade} =
               OptionsTradeSimulator.close_position(
                 simulator,
                 trade.id,
                 exit_premium,
                 exit_time,
                 :stopped_out
               )

      assert Decimal.lt?(closed_trade.pnl, Decimal.new(0))
    end

    test "returns error for unknown trade" do
      simulator = OptionsTradeSimulator.new()

      assert {:error, :not_found} =
               OptionsTradeSimulator.close_position(
                 simulator,
                 "unknown-id",
                 Decimal.new("5.00"),
                 DateTime.utc_now(),
                 :manual_exit
               )
    end
  end

  describe "summary/1" do
    test "returns empty summary for new simulator" do
      simulator = OptionsTradeSimulator.new()
      summary = OptionsTradeSimulator.summary(simulator)

      assert summary.total_trades == 0
      assert summary.open_positions == 0
      assert summary.winners == 0
      assert summary.losers == 0
      assert summary.win_rate == 0.0
    end
  end

  describe "trade_to_attrs/2" do
    test "converts trade to attributes for persistence" do
      trade = %{
        id: Ecto.UUID.generate(),
        signal_id: Ecto.UUID.generate(),
        contract_symbol: "AAPL250117C00150000",
        underlying_symbol: "AAPL",
        contract_type: :call,
        strike: Decimal.new("150.00"),
        expiration: ~D[2025-01-17],
        entry_premium: Decimal.new("5.00"),
        exit_premium: Decimal.new("6.00"),
        num_contracts: 2,
        direction: :long,
        stop_loss: Decimal.new("145.00"),
        take_profit: Decimal.new("160.00"),
        entry_time: ~U[2024-06-15 14:30:00Z],
        exit_time: ~U[2024-06-15 15:30:00Z],
        status: :target_hit,
        risk_amount: Decimal.new("1000"),
        pnl: Decimal.new("200"),
        pnl_pct: Decimal.new("20"),
        r_multiple: Decimal.new("0.2"),
        options_exit_reason: "target_hit"
      }

      backtest_run_id = Ecto.UUID.generate()
      attrs = OptionsTradeSimulator.trade_to_attrs(trade, backtest_run_id)

      assert attrs.backtest_run_id == backtest_run_id
      assert attrs.instrument_type == "options"
      assert attrs.contract_symbol == "AAPL250117C00150000"
      assert attrs.contract_type == "call"
      assert attrs.num_contracts == 2
    end
  end

  # Helper functions

  defp find_next_friday do
    today = Date.utc_today()
    days_until_friday = rem(5 - Date.day_of_week(today) + 7, 7)
    days_until_friday = if days_until_friday == 0, do: 7, else: days_until_friday
    Date.add(today, days_until_friday)
  end
end
