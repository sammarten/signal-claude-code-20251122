defmodule Signal.Repo.Migrations.CreateHistoricalFetchJobs do
  use Ecto.Migration

  def change do
    create table(:historical_fetch_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :symbol, :string, null: false
      add :start_date, :date, null: false
      add :end_date, :date, null: false
      add :status, :string, null: false, default: "pending"
      add :bars_loaded, :integer, default: 0
      add :last_bar_time, :utc_datetime_usec
      add :error_message, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps()
    end

    create index(:historical_fetch_jobs, [:symbol])
    create index(:historical_fetch_jobs, [:status])
    create unique_index(:historical_fetch_jobs, [:symbol, :start_date, :end_date])
  end
end
