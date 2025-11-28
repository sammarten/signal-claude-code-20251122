defmodule Signal.Repo.Migrations.ChangeOptimizationRunsErrorMessageToText do
  use Ecto.Migration

  def change do
    alter table(:optimization_runs) do
      modify :error_message, :text, from: :string
    end
  end
end
