defmodule Signal.Backtest.BacktestRun do
  @moduledoc """
  Ecto schema for backtest run configuration and state.

  Stores the configuration, progress, and results of a backtest run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :running, :completed, :failed, :cancelled]

  schema "backtest_runs" do
    # Configuration
    field :symbols, {:array, :string}
    field :start_date, :date
    field :end_date, :date
    field :strategies, {:array, :string}
    field :parameters, :map, default: %{}

    # Capital and risk settings
    field :initial_capital, :decimal
    field :risk_per_trade, :decimal

    # Execution state
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :progress_pct, :decimal, default: Decimal.new(0)
    field :current_date, :date
    field :bars_processed, :integer, default: 0
    field :signals_generated, :integer, default: 0

    # Timing
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    # Error tracking
    field :error_message, :string

    timestamps()
  end

  @required_fields [
    :symbols,
    :start_date,
    :end_date,
    :strategies,
    :initial_capital,
    :risk_per_trade
  ]

  @optional_fields [
    :parameters,
    :status,
    :progress_pct,
    :current_date,
    :bars_processed,
    :signals_generated,
    :started_at,
    :completed_at,
    :error_message
  ]

  @doc """
  Creates a changeset for a new backtest run.
  """
  def changeset(run, attrs) do
    run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:symbols, min: 1)
    |> validate_length(:strategies, min: 1)
    |> validate_number(:initial_capital, greater_than: 0)
    |> validate_number(:risk_per_trade, greater_than: 0, less_than_or_equal_to: 1)
    |> validate_date_range()
  end

  @doc """
  Creates a changeset for updating progress.
  """
  def progress_changeset(run, attrs) do
    run
    |> cast(attrs, [:progress_pct, :current_date, :bars_processed, :signals_generated])
  end

  @doc """
  Creates a changeset for marking the run as started.
  """
  def start_changeset(run) do
    run
    |> change(%{status: :running, started_at: DateTime.utc_now()})
  end

  @doc """
  Creates a changeset for marking the run as completed.
  """
  def complete_changeset(run) do
    run
    |> change(%{
      status: :completed,
      completed_at: DateTime.utc_now(),
      progress_pct: Decimal.new(100)
    })
  end

  @doc """
  Creates a changeset for marking the run as failed.
  """
  def fail_changeset(run, error_message) do
    run
    |> change(%{
      status: :failed,
      completed_at: DateTime.utc_now(),
      error_message: error_message
    })
  end

  defp validate_date_range(changeset) do
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date)

    if start_date && end_date && Date.compare(start_date, end_date) == :gt do
      add_error(changeset, :end_date, "must be after start_date")
    else
      changeset
    end
  end
end
