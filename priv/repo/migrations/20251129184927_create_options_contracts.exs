defmodule Signal.Repo.Migrations.CreateOptionsContracts do
  use Ecto.Migration

  def change do
    create table(:options_contracts, primary_key: false) do
      add :symbol, :string, primary_key: true
      add :underlying_symbol, :string, null: false
      add :expiration_date, :date, null: false
      add :strike_price, :decimal, null: false
      add :contract_type, :string, null: false
      add :status, :string, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:options_contracts, [:underlying_symbol, :expiration_date])
    create index(:options_contracts, [:underlying_symbol, :contract_type, :expiration_date])
    create index(:options_contracts, [:expiration_date])
  end
end
