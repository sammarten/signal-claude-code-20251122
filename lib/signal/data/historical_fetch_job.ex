defmodule Signal.Data.HistoricalFetchJob do
  @moduledoc """
  Ecto schema for tracking historical data fetch jobs.

  Enables resume capability for long-running data fetches by tracking:
  - Job status (pending, running, completed, failed)
  - Progress via last_bar_time and bars_loaded count
  - Error messages for failed jobs

  Jobs are uniquely identified by (symbol, start_date, end_date).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w[pending running completed failed]

  schema "historical_fetch_jobs" do
    field :symbol, :string
    field :start_date, :date
    field :end_date, :date
    field :status, :string, default: "pending"
    field :bars_loaded, :integer, default: 0
    field :last_bar_time, :utc_datetime_usec
    field :error_message, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Creates a changeset for a new job.
  """
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :symbol,
      :start_date,
      :end_date,
      :status,
      :bars_loaded,
      :last_bar_time,
      :error_message,
      :started_at,
      :completed_at
    ])
    |> validate_required([:symbol, :start_date, :end_date])
    |> validate_inclusion(:status, @statuses)
    |> validate_date_range()
    |> unique_constraint([:symbol, :start_date, :end_date])
  end

  @doc """
  Changeset for updating job progress.
  """
  def progress_changeset(job, attrs) do
    job
    |> cast(attrs, [:last_bar_time, :bars_loaded, :status])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Changeset for marking a job as complete.
  """
  def complete_changeset(job, total_bars) do
    job
    |> change(%{
      status: "completed",
      bars_loaded: total_bars,
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Changeset for marking a job as failed.
  """
  def fail_changeset(job, error_message) do
    job
    |> change(%{
      status: "failed",
      error_message: error_message
    })
  end

  @doc """
  Changeset for starting a job.
  """
  def start_changeset(job) do
    job
    |> change(%{
      status: "running",
      started_at: DateTime.utc_now()
    })
  end

  defp validate_date_range(changeset) do
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date)

    if start_date && end_date && Date.compare(start_date, end_date) == :gt do
      add_error(changeset, :end_date, "must be after or equal to start_date")
    else
      changeset
    end
  end
end
