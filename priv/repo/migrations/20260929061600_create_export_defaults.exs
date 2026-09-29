defmodule GtfsPlanner.Repo.Migrations.CreateExportDefaults do
  use Ecto.Migration

  def change do
    create table(:export_defaults, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :include_flex, :boolean, null: false, default: true
      add :realtime_source, :string, null: false, default: "unsure"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:export_defaults, [:organization_id])

    create constraint(:export_defaults, :realtime_source,
             check: "realtime_source IN ('main', 'flex', 'own', 'none', 'unsure')"
           )
  end
end
