defmodule GtfsPlanner.Repo.Migrations.CreateShapes do
  use Ecto.Migration

  def up do
    create table(:shapes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :shape_id, :string, null: false
      add :shape_pt_lat, :decimal, null: false
      add :shape_pt_lon, :decimal, null: false
      add :shape_pt_sequence, :integer, null: false
      add :shape_dist_traveled, :decimal

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:shapes, [:organization_id, :gtfs_version_id, :shape_id, :shape_pt_sequence],
             name: :shapes_organization_id_gtfs_version_id_shape_id_shape_pt_sequence_index
           )

    create index(:shapes, [:organization_id, :gtfs_version_id])
    create index(:shapes, [:organization_id, :gtfs_version_id, :shape_id])
  end

  def down do
    drop table(:shapes)
  end
end