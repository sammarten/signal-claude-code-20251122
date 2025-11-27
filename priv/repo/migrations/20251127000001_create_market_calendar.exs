defmodule Signal.Repo.Migrations.CreateMarketCalendar do
  use Ecto.Migration

  def change do
    create table(:market_calendar, primary_key: false) do
      add :date, :date, primary_key: true
      add :open, :time, null: false
      add :close, :time, null: false
    end

    create index(:market_calendar, [:date])
  end
end
