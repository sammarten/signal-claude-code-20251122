defmodule Signal.Backtest.VirtualAccountTest do
  use ExUnit.Case, async: true

  alias Signal.Backtest.VirtualAccount

  describe "new/2" do
    test "creates account with initial values" do
      account = VirtualAccount.new(Decimal.new("100000"), Decimal.new("0.01"))

      assert account.initial_capital == Decimal.new("100000")
      assert account.current_equity == Decimal.new("100000")
      assert account.cash == Decimal.new("100000")
      assert account.risk_per_trade == Decimal.new("0.01")
      assert account.open_positions == %{}
      assert account.closed_trades == []
      assert account.trade_count == 0
    end

    test "uses default risk_per_trade of 1%" do
      account = VirtualAccount.new(Decimal.new("100000"))
      assert account.risk_per_trade == Decimal.new("0.01")
    end
  end

  describe "open_position/2" do
    setup do
      account = VirtualAccount.new(Decimal.new("100000"), Decimal.new("0.01"))
      %{account: account}
    end

    test "opens a long position with correct sizing", %{account: account} do
      params = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("99.00"),
        take_profit: Decimal.new("103.00"),
        entry_time: ~U[2024-01-15 14:30:00Z]
      }

      {:ok, updated_account, trade} = VirtualAccount.open_position(account, params)

      # Risk is 1% of 100000 = 1000
      # Price risk is 100 - 99 = 1
      # Position size = 1000 / 1 = 1000 shares
      assert trade.position_size == 1000
      assert trade.risk_amount == Decimal.new("1000.00")
      assert trade.symbol == "AAPL"
      assert trade.direction == :long
      assert trade.status == :open

      # Cash reduced by position value (1000 shares * $100)
      assert Decimal.compare(updated_account.cash, Decimal.new("0.00")) == :eq
      assert updated_account.trade_count == 1
    end

    test "opens a short position", %{account: account} do
      params = %{
        symbol: "AAPL",
        direction: :short,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("101.00"),
        entry_time: ~U[2024-01-15 14:30:00Z]
      }

      {:ok, _updated_account, trade} = VirtualAccount.open_position(account, params)

      assert trade.direction == :short
      assert trade.position_size == 1000
    end

    test "limits position size to available cash", %{account: account} do
      # Try to open a position that would require more cash than available
      params = %{
        symbol: "EXPENSIVE",
        direction: :long,
        entry_price: Decimal.new("500.00"),
        stop_loss: Decimal.new("499.00"),
        entry_time: ~U[2024-01-15 14:30:00Z]
      }

      {:ok, updated_account, trade} = VirtualAccount.open_position(account, params)

      # Max shares = 100000 / 500 = 200 shares
      assert trade.position_size == 200
      assert Decimal.compare(updated_account.cash, Decimal.new("0.00")) == :eq
    end

    test "returns error for missing params" do
      account = VirtualAccount.new(Decimal.new("100000"))

      result = VirtualAccount.open_position(account, %{symbol: "AAPL"})

      assert {:error, {:missing_params, missing}} = result
      assert :direction in missing
      assert :entry_price in missing
    end

    test "returns error for invalid stop loss", %{account: account} do
      # Long with stop above entry
      params = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("101.00"),
        entry_time: ~U[2024-01-15 14:30:00Z]
      }

      assert {:error, :invalid_stop_loss} = VirtualAccount.open_position(account, params)
    end
  end

  describe "close_position/3" do
    setup do
      account = VirtualAccount.new(Decimal.new("100000"), Decimal.new("0.01"))

      params = %{
        symbol: "AAPL",
        direction: :long,
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("99.00"),
        take_profit: Decimal.new("102.00"),
        entry_time: ~U[2024-01-15 14:30:00Z]
      }

      {:ok, account_with_position, trade} = VirtualAccount.open_position(account, params)
      %{account: account_with_position, trade: trade}
    end

    test "closes position with profit", %{account: account, trade: trade} do
      close_params = %{
        exit_price: Decimal.new("102.00"),
        exit_time: ~U[2024-01-15 15:00:00Z],
        status: :target_hit
      }

      {:ok, updated_account, closed_trade} =
        VirtualAccount.close_position(account, trade.id, close_params)

      # Profit = (102 - 100) * 1000 = 2000
      assert Decimal.compare(closed_trade.pnl, Decimal.new("2000.00")) == :eq
      assert closed_trade.status == :target_hit

      # R-multiple = 2000 / 1000 = 2
      assert Decimal.compare(closed_trade.r_multiple, Decimal.new("2.00")) == :eq

      # Equity increased by profit
      assert Decimal.compare(updated_account.current_equity, Decimal.new("102000.00")) == :eq

      # Position removed from open, added to closed
      assert updated_account.open_positions == %{}
      assert length(updated_account.closed_trades) == 1
    end

    test "closes position with loss", %{account: account, trade: trade} do
      close_params = %{
        exit_price: Decimal.new("99.00"),
        exit_time: ~U[2024-01-15 15:00:00Z],
        status: :stopped_out
      }

      {:ok, updated_account, closed_trade} =
        VirtualAccount.close_position(account, trade.id, close_params)

      # Loss = (99 - 100) * 1000 = -1000
      assert Decimal.compare(closed_trade.pnl, Decimal.new("-1000.00")) == :eq
      assert closed_trade.status == :stopped_out

      # R-multiple = -1000 / 1000 = -1
      assert Decimal.compare(closed_trade.r_multiple, Decimal.new("-1.00")) == :eq

      # Equity decreased by loss
      assert Decimal.compare(updated_account.current_equity, Decimal.new("99000.00")) == :eq
    end

    test "returns error for non-existent trade", %{account: account} do
      close_params = %{
        exit_price: Decimal.new("102.00"),
        exit_time: ~U[2024-01-15 15:00:00Z],
        status: :target_hit
      }

      assert {:error, :not_found} =
               VirtualAccount.close_position(account, "non-existent-id", close_params)
    end
  end

  describe "summary/1" do
    test "returns correct statistics after trades" do
      account = VirtualAccount.new(Decimal.new("100000"), Decimal.new("0.01"))

      # Open and close a winning trade
      {:ok, account, trade1} =
        VirtualAccount.open_position(account, %{
          symbol: "AAPL",
          direction: :long,
          entry_price: Decimal.new("100.00"),
          stop_loss: Decimal.new("99.00"),
          entry_time: ~U[2024-01-15 14:30:00Z]
        })

      {:ok, account, _} =
        VirtualAccount.close_position(account, trade1.id, %{
          exit_price: Decimal.new("102.00"),
          exit_time: ~U[2024-01-15 15:00:00Z],
          status: :target_hit
        })

      # Open and close a losing trade
      {:ok, account, trade2} =
        VirtualAccount.open_position(account, %{
          symbol: "TSLA",
          direction: :long,
          entry_price: Decimal.new("200.00"),
          stop_loss: Decimal.new("198.00"),
          entry_time: ~U[2024-01-16 14:30:00Z]
        })

      {:ok, account, _} =
        VirtualAccount.close_position(account, trade2.id, %{
          exit_price: Decimal.new("198.00"),
          exit_time: ~U[2024-01-16 15:00:00Z],
          status: :stopped_out
        })

      summary = VirtualAccount.summary(account)

      assert summary.total_trades == 2
      assert summary.winners == 1
      assert summary.losers == 1
      assert summary.win_rate == 50.0
    end
  end
end
