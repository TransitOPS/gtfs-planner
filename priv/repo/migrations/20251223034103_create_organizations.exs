defmodule GtfsPlanner.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    # Enable citext extension for case-insensitive comparison
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :alias, :string, null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organizations, [:alias])
  end
end
