defmodule Signal.Strategies.SetupTest do
  use ExUnit.Case, async: true

  alias Signal.Strategies.Setup

  describe "new/1" do
    test "creates setup with calculated risk/reward" do
      setup =
        Setup.new(%{
          symbol: "AAPL",
          strategy: :break_and_retest,
          direction: :long,
          entry_price: Decimal.new("100.00"),
          stop_loss: Decimal.new("99.00"),
          take_profit: Decimal.new("102.00")
        })

      assert setup.symbol == "AAPL"
      assert setup.strategy == :break_and_retest
      assert setup.direction == :long
      assert Decimal.equal?(setup.risk_reward, Decimal.new("2.0"))
    end

    test "sets default timestamp" do
      setup = Setup.new(%{symbol: "AAPL", strategy: :break_and_retest, direction: :long})

      assert setup.timestamp != nil
      assert DateTime.diff(DateTime.utc_now(), setup.timestamp) < 5
    end

    test "sets default status to pending" do
      setup = Setup.new(%{symbol: "AAPL", strategy: :break_and_retest, direction: :long})

      assert setup.status == :pending
    end

    test "sets default expiry to 30 minutes from timestamp" do
      setup = Setup.new(%{symbol: "AAPL", strategy: :break_and_retest, direction: :long})

      assert setup.expires_at != nil
      # Should be approximately 30 minutes later
      diff = DateTime.diff(setup.expires_at, setup.timestamp)
      assert diff == 30 * 60
    end

    test "preserves custom timestamp if provided" do
      custom_time = ~U[2024-01-15 10:00:00Z]

      setup =
        Setup.new(%{
          symbol: "AAPL",
          strategy: :break_and_retest,
          direction: :long,
          timestamp: custom_time
        })

      assert setup.timestamp == custom_time
    end
  end

  describe "calculate_risk_reward/1" do
    test "calculates correct R:R for long setup" do
      setup = %Setup{
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("98.00"),
        take_profit: Decimal.new("104.00")
      }

      result = Setup.calculate_risk_reward(setup)

      # Risk = 100 - 98 = 2, Reward = 104 - 100 = 4, R:R = 4/2 = 2.0
      assert Decimal.equal?(result.risk_reward, Decimal.new("2.0"))
    end

    test "calculates correct R:R for short setup" do
      setup = %Setup{
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("102.00"),
        take_profit: Decimal.new("96.00")
      }

      result = Setup.calculate_risk_reward(setup)

      # Risk = 102 - 100 = 2, Reward = 100 - 96 = 4, R:R = 4/2 = 2.0
      assert Decimal.equal?(result.risk_reward, Decimal.new("2.0"))
    end

    test "handles zero risk" do
      setup = %Setup{
        entry_price: Decimal.new("100.00"),
        stop_loss: Decimal.new("100.00"),
        take_profit: Decimal.new("102.00")
      }

      result = Setup.calculate_risk_reward(setup)

      assert Decimal.equal?(result.risk_reward, Decimal.new("0"))
    end

    test "handles missing prices" do
      setup = %Setup{entry_price: Decimal.new("100.00")}

      result = Setup.calculate_risk_reward(setup)

      assert result.risk_reward == nil
    end
  end

  describe "meets_risk_reward?/2" do
    test "returns true when R:R meets minimum" do
      setup = %Setup{risk_reward: Decimal.new("2.5")}

      assert Setup.meets_risk_reward?(setup, Decimal.new("2.0")) == true
    end

    test "returns true when R:R equals minimum" do
      setup = %Setup{risk_reward: Decimal.new("2.0")}

      assert Setup.meets_risk_reward?(setup, Decimal.new("2.0")) == true
    end

    test "returns false when R:R below minimum" do
      setup = %Setup{risk_reward: Decimal.new("1.5")}

      assert Setup.meets_risk_reward?(setup, Decimal.new("2.0")) == false
    end

    test "uses default minimum of 2.0" do
      setup_good = %Setup{risk_reward: Decimal.new("2.0")}
      setup_bad = %Setup{risk_reward: Decimal.new("1.9")}

      assert Setup.meets_risk_reward?(setup_good) == true
      assert Setup.meets_risk_reward?(setup_bad) == false
    end
  end

  describe "within_trading_window?/2" do
    test "returns true for time within window" do
      # 10:00 AM ET is within 9:30-11:00 window
      timestamp = DateTime.new!(~D[2024-01-15], ~T[15:00:00], "Etc/UTC")
      setup = %Setup{timestamp: timestamp}

      assert Setup.within_trading_window?(setup) == true
    end

    test "returns false for time before window" do
      # 9:00 AM ET (14:00 UTC) is before 9:30 window
      timestamp = DateTime.new!(~D[2024-01-15], ~T[14:00:00], "Etc/UTC")
      setup = %Setup{timestamp: timestamp}

      assert Setup.within_trading_window?(setup) == false
    end

    test "returns false for time after window" do
      # 12:00 PM ET (17:00 UTC) is after 11:00 window
      timestamp = DateTime.new!(~D[2024-01-15], ~T[17:00:00], "Etc/UTC")
      setup = %Setup{timestamp: timestamp}

      assert Setup.within_trading_window?(setup) == false
    end

    test "respects custom window times" do
      timestamp = DateTime.new!(~D[2024-01-15], ~T[17:00:00], "Etc/UTC")
      setup = %Setup{timestamp: timestamp}

      # 12:00 PM ET would be within an extended window
      opts = [start_time: ~T[09:30:00], end_time: ~T[13:00:00]]
      assert Setup.within_trading_window?(setup, opts) == true
    end
  end

  describe "expired?/1" do
    test "returns false when expires_at is nil" do
      setup = %Setup{expires_at: nil}

      assert Setup.expired?(setup) == false
    end

    test "returns false when not yet expired" do
      setup = %Setup{expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)}

      assert Setup.expired?(setup) == false
    end

    test "returns true when past expiry" do
      setup = %Setup{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}

      assert Setup.expired?(setup) == true
    end
  end

  describe "expire/1" do
    test "sets status to expired" do
      setup = %Setup{status: :pending}

      result = Setup.expire(setup)

      assert result.status == :expired
    end
  end

  describe "invalidate/1" do
    test "sets status to invalidated" do
      setup = %Setup{status: :pending}

      result = Setup.invalidate(setup)

      assert result.status == :invalidated
    end
  end

  describe "valid?/1" do
    test "returns true for pending setup not expired" do
      setup = %Setup{
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Setup.valid?(setup) == true
    end

    test "returns true for active setup not expired" do
      setup = %Setup{
        status: :active,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Setup.valid?(setup) == true
    end

    test "returns false for expired setup" do
      setup = %Setup{
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      assert Setup.valid?(setup) == false
    end

    test "returns false for filled setup" do
      setup = %Setup{
        status: :filled,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Setup.valid?(setup) == false
    end

    test "returns false for invalidated setup" do
      setup = %Setup{
        status: :invalidated,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert Setup.valid?(setup) == false
    end
  end
end
