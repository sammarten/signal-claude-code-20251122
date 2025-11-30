defmodule Signal.Repo.Migrations.AddOptionsFieldsToSimulatedTrades do
  use Ecto.Migration

  def change do
    alter table(:simulated_trades) do
      # Instrument type to distinguish equity vs options trades
      add :instrument_type, :string, default: "equity"

      # Options-specific fields
      add :contract_symbol, :string
      add :underlying_symbol, :string
      # "call" or "put"
      add :contract_type, :string
      add :strike, :decimal
      add :expiration_date, :date
      add :entry_premium, :decimal
      add :exit_premium, :decimal
      add :num_contracts, :integer

      # Exit reason for options (expiration, premium_target, etc.)
      add :options_exit_reason, :string
    end

    # Index for querying options trades
    create index(:simulated_trades, [:instrument_type])
    create index(:simulated_trades, [:contract_symbol])
    create index(:simulated_trades, [:underlying_symbol])
  end
end
