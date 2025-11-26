defmodule Signal.Repo.Migrations.CreatePdArrays do
  use Ecto.Migration

  def change do
    create table(:pd_arrays, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :symbol, :string, null: false
      add :type, :string, null: false
      add :direction, :string, null: false
      add :top, :decimal, null: false
      add :bottom, :decimal, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :mitigated, :boolean, default: false, null: false
      add :mitigated_at, :utc_datetime_usec
      add :quality_score, :integer
      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:pd_arrays, [:symbol, :type, :mitigated])
    create index(:pd_arrays, [:symbol, :direction])
    create index(:pd_arrays, [:created_at])

    create constraint(:pd_arrays, :valid_type, check: "type IN ('order_block', 'fvg')")
    create constraint(:pd_arrays, :valid_direction, check: "direction IN ('bullish', 'bearish')")
    create constraint(:pd_arrays, :top_above_bottom, check: "top >= bottom")
  end
end
