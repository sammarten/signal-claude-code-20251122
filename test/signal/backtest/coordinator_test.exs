defmodule Signal.Backtest.CoordinatorTest do
  use Signal.DataCase, async: true

  alias Signal.Backtest.Coordinator
  alias Signal.Backtest.BacktestRun

  describe "validate_config (via run/1)" do
    test "returns error for missing required fields" do
      config = %{symbols: ["AAPL"]}

      assert {:error, {:missing_required_fields, missing}} = Coordinator.run(config)
      assert :start_date in missing
      assert :end_date in missing
      assert :strategies in missing
      assert :initial_capital in missing
      assert :risk_per_trade in missing
    end
  end

  describe "get_status/1" do
    test "returns error for unknown run" do
      assert {:error, :not_found} = Coordinator.get_status(Ecto.UUID.generate())
    end

    test "returns status for existing run" do
      # Create a run directly
      {:ok, run} =
        %BacktestRun{}
        |> BacktestRun.changeset(%{
          symbols: ["AAPL"],
          start_date: ~D[2024-01-01],
          end_date: ~D[2024-01-31],
          strategies: ["break_and_retest"],
          initial_capital: Decimal.new("100000"),
          risk_per_trade: Decimal.new("0.01")
        })
        |> Signal.Repo.insert()

      {:ok, status} = Coordinator.get_status(run.id)

      assert status.run_id == run.id
      assert status.status == :pending
      assert status.progress_pct == Decimal.new(0)
    end
  end

  describe "cancel/1" do
    test "returns error for unknown run" do
      assert {:error, :not_found} = Coordinator.cancel(Ecto.UUID.generate())
    end

    test "cancels an existing run" do
      # Create a run directly
      {:ok, run} =
        %BacktestRun{}
        |> BacktestRun.changeset(%{
          symbols: ["AAPL"],
          start_date: ~D[2024-01-01],
          end_date: ~D[2024-01-31],
          strategies: ["break_and_retest"],
          initial_capital: Decimal.new("100000"),
          risk_per_trade: Decimal.new("0.01")
        })
        |> Signal.Repo.insert()

      assert :ok = Coordinator.cancel(run.id)

      # Verify status was updated
      updated_run = Signal.Repo.get!(BacktestRun, run.id)
      assert updated_run.status == :cancelled
      assert updated_run.completed_at != nil
    end
  end
end
