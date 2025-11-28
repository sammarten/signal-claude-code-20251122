defmodule Signal.Optimization.OptimizationRun do
  @moduledoc """
  Ecto schema for optimization run configuration and state.

  Stores the configuration, progress, and summary results of an optimization run.
  Individual parameter results are stored in OptimizationResult.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Signal.Optimization.OptimizationResult

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :running, :completed, :failed, :cancelled]

  schema "optimization_runs" do
    # Configuration
    field :name, :string
    field :symbols, {:array, :string}
    field :start_date, :date
    field :end_date, :date
    field :strategies, {:array, :string}
    field :initial_capital, :decimal
    field :base_risk_per_trade, :decimal

    # Parameter grid configuration (JSONB)
    field :parameter_grid, :map, default: %{}

    # Walk-forward configuration (JSONB)
    field :walk_forward_config, :map, default: %{}

    # Optimization settings
    field :optimization_metric, :string, default: "profit_factor"
    field :min_trades, :integer, default: 30

    # Execution state
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :total_combinations, :integer, default: 0
    field :completed_combinations, :integer, default: 0
    field :progress_pct, :decimal, default: Decimal.new(0)

    # Timing
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    # Error tracking
    field :error_message, :string

    # Best result (populated after completion)
    field :best_params, :map

    # Associations
    has_many :results, OptimizationResult

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :symbols,
    :start_date,
    :end_date,
    :strategies,
    :initial_capital,
    :base_risk_per_trade,
    :parameter_grid
  ]

  @optional_fields [
    :name,
    :walk_forward_config,
    :optimization_metric,
    :min_trades,
    :status,
    :total_combinations,
    :completed_combinations,
    :progress_pct,
    :started_at,
    :completed_at,
    :error_message,
    :best_params
  ]

  @doc """
  Creates a changeset for a new optimization run.
  """
  def changeset(run, attrs) do
    run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:symbols, min: 1)
    |> validate_length(:strategies, min: 1)
    |> validate_number(:initial_capital, greater_than: 0)
    |> validate_number(:base_risk_per_trade, greater_than: 0, less_than_or_equal_to: 1)
    |> validate_number(:min_trades, greater_than_or_equal_to: 0)
    |> validate_date_range()
  end

  @doc """
  Creates a changeset for updating progress.
  """
  def progress_changeset(run, attrs) do
    run
    |> cast(attrs, [:completed_combinations, :progress_pct])
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
  def complete_changeset(run, best_params \\ nil) do
    changes = %{
      status: :completed,
      completed_at: DateTime.utc_now(),
      progress_pct: Decimal.new(100)
    }

    changes = if best_params, do: Map.put(changes, :best_params, best_params), else: changes

    run
    |> change(changes)
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

  @doc """
  Creates a changeset for marking the run as cancelled.
  """
  def cancel_changeset(run) do
    run
    |> change(%{
      status: :cancelled,
      completed_at: DateTime.utc_now()
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
