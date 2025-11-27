defmodule Signal.Backtest.BacktestRunTest do
  use Signal.DataCase, async: true

  alias Signal.Backtest.BacktestRun

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      attrs = %{
        symbols: ["AAPL", "TSLA"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-03-31],
        strategies: ["break_and_retest"],
        initial_capital: Decimal.new("100000"),
        risk_per_trade: Decimal.new("0.01")
      }

      changeset = BacktestRun.changeset(%BacktestRun{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = BacktestRun.changeset(%BacktestRun{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).symbols
      assert "can't be blank" in errors_on(changeset).start_date
      assert "can't be blank" in errors_on(changeset).end_date
      assert "can't be blank" in errors_on(changeset).strategies
      assert "can't be blank" in errors_on(changeset).initial_capital
      assert "can't be blank" in errors_on(changeset).risk_per_trade
    end

    test "invalid with empty symbols list" do
      attrs = %{
        symbols: [],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-03-31],
        strategies: ["break_and_retest"],
        initial_capital: Decimal.new("100000"),
        risk_per_trade: Decimal.new("0.01")
      }

      changeset = BacktestRun.changeset(%BacktestRun{}, attrs)
      refute changeset.valid?
      assert "should have at least 1 item(s)" in errors_on(changeset).symbols
    end

    test "invalid with empty strategies list" do
      attrs = %{
        symbols: ["AAPL"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-03-31],
        strategies: [],
        initial_capital: Decimal.new("100000"),
        risk_per_trade: Decimal.new("0.01")
      }

      changeset = BacktestRun.changeset(%BacktestRun{}, attrs)
      refute changeset.valid?
      assert "should have at least 1 item(s)" in errors_on(changeset).strategies
    end

    test "invalid with zero or negative initial_capital" do
      attrs = %{
        symbols: ["AAPL"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-03-31],
        strategies: ["break_and_retest"],
        initial_capital: Decimal.new("0"),
        risk_per_trade: Decimal.new("0.01")
      }

      changeset = BacktestRun.changeset(%BacktestRun{}, attrs)
      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).initial_capital
    end

    test "invalid with risk_per_trade > 1" do
      attrs = %{
        symbols: ["AAPL"],
        start_date: ~D[2024-01-01],
        end_date: ~D[2024-03-31],
        strategies: ["break_and_retest"],
        initial_capital: Decimal.new("100000"),
        risk_per_trade: Decimal.new("1.5")
      }

      changeset = BacktestRun.changeset(%BacktestRun{}, attrs)
      refute changeset.valid?
      assert "must be less than or equal to 1" in errors_on(changeset).risk_per_trade
    end

    test "invalid when end_date before start_date" do
      attrs = %{
        symbols: ["AAPL"],
        start_date: ~D[2024-03-31],
        end_date: ~D[2024-01-01],
        strategies: ["break_and_retest"],
        initial_capital: Decimal.new("100000"),
        risk_per_trade: Decimal.new("0.01")
      }

      changeset = BacktestRun.changeset(%BacktestRun{}, attrs)
      refute changeset.valid?
      assert "must be after start_date" in errors_on(changeset).end_date
    end
  end

  describe "start_changeset/1" do
    test "sets status to running and started_at" do
      run = %BacktestRun{status: :pending}
      changeset = BacktestRun.start_changeset(run)

      assert Ecto.Changeset.get_change(changeset, :status) == :running
      assert Ecto.Changeset.get_change(changeset, :started_at) != nil
    end
  end

  describe "complete_changeset/1" do
    test "sets status to completed and completed_at" do
      run = %BacktestRun{status: :running}
      changeset = BacktestRun.complete_changeset(run)

      assert Ecto.Changeset.get_change(changeset, :status) == :completed
      assert Ecto.Changeset.get_change(changeset, :completed_at) != nil
      assert Ecto.Changeset.get_change(changeset, :progress_pct) == Decimal.new(100)
    end
  end

  describe "fail_changeset/2" do
    test "sets status to failed with error message" do
      run = %BacktestRun{status: :running}
      changeset = BacktestRun.fail_changeset(run, "Something went wrong")

      assert Ecto.Changeset.get_change(changeset, :status) == :failed
      assert Ecto.Changeset.get_change(changeset, :completed_at) != nil
      assert Ecto.Changeset.get_change(changeset, :error_message) == "Something went wrong"
    end
  end

  describe "progress_changeset/2" do
    test "updates progress fields" do
      run = %BacktestRun{status: :running}

      changeset =
        BacktestRun.progress_changeset(run, %{
          progress_pct: Decimal.new("50.5"),
          current_date: ~D[2024-02-15],
          bars_processed: 25000
        })

      assert Ecto.Changeset.get_change(changeset, :progress_pct) == Decimal.new("50.5")
      assert Ecto.Changeset.get_change(changeset, :current_date) == ~D[2024-02-15]
      assert Ecto.Changeset.get_change(changeset, :bars_processed) == 25000
    end
  end
end
