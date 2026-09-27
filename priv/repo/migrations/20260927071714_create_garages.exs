defmodule GtfsPlanner.Repo.Migrations.CreateGarages do
  use Ecto.Migration

  def change do
    create table(:garages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :garage_id, :string, null: false
      add :name, :string, null: false
      add :address, :string
      add :lat, :decimal, null: false
      add :lon, :decimal, null: false
      add :updated_by_id, :binary_id
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:garages, [:organization_id, :garage_id])
  end
end
