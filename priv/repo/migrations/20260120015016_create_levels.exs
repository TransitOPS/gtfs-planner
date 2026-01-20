defmodule GtfsPlanner.Repo.Migrations.CreateLevels do
  use Ecto.Migration

  def up do
    create table(:levels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :gtfs_version_id, :binary_id, null: false
      add :level_id, :string, null: false
      add :level_index, :float, null: false
      add :level_name, :string
      timestamps()
    end

    create unique_index(:levels, [:organization_id, :gtfs_version_id, :level_id], name: :levels_organization_id_gtfs_version_id_level_id_index)
    create unique_index(:levels, [:id, :organization_id, :gtfs_version_id])

    alter table(:levels) do
      modify :gtfs_version_id,
        references(:gtfs_versions,
          column: :id,
          with: [organization_id: :organization_id],
          match: :full,
          type: :binary_id
        )
    end
  end

  def down do
    drop table(:levels)
  end
end
