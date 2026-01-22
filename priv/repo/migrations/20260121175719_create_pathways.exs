defmodule GtfsPlanner.Repo.Migrations.CreatePathways do
  use Ecto.Migration

  def up do
    create table(:pathways, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :gtfs_version_id, :binary_id, null: false
      add :pathway_id, :string, null: false
      add :from_stop_id, :binary_id, null: false
      add :to_stop_id, :binary_id, null: false
      add :pathway_mode, :integer, null: false
      add :is_bidirectional, :boolean, null: false, default: true
      add :traversal_time, :integer
      add :length, :decimal
      add :stair_count, :integer
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pathways, [:organization_id, :gtfs_version_id, :pathway_id], name: :pathways_organization_id_gtfs_version_id_pathway_id_index)
    create index(:pathways, [:organization_id, :gtfs_version_id])
    create index(:pathways, [:organization_id, :gtfs_version_id, :from_stop_id])
    create index(:pathways, [:organization_id, :gtfs_version_id, :to_stop_id])

    alter table(:pathways) do
      modify :gtfs_version_id,
        references(:gtfs_versions,
          column: :id,
          with: [organization_id: :organization_id],
          match: :simple,
          type: :binary_id
        )

      modify :from_stop_id,
        references(:stops,
          column: :id,
          with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
          match: :simple,
          type: :binary_id
        )

      modify :to_stop_id,
        references(:stops,
          column: :id,
          with: [organization_id: :organization_id, gtfs_version_id: :gtfs_version_id],
          match: :simple,
          type: :binary_id
        )
    end
  end

  def down do
    drop table(:pathways)
  end
end
