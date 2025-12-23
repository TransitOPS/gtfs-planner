defmodule GtfsPlanner.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :description, :string, null: false
      add :roles, {:array, :string}, default: "{}"
      add :version, :integer, default: 1
      add :secret_hash, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
