defmodule GtfsPlanner.Repo.Migrations.CreateAlertSettings do
  use Ecto.Migration

  def change do
    create table(:alert_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :guidelines, :text
      add :revision, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:alert_settings, [:organization_id])
  end
end
