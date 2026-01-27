defmodule GtfsPlanner.Repo.Migrations.FixGtfsReferenceFieldsToStrings do
  use Ecto.Migration

  def up do
    # Drop existing foreign key constraints
    execute "ALTER TABLE stops DROP CONSTRAINT IF EXISTS stops_parent_station_id_fkey"
    execute "ALTER TABLE stops DROP CONSTRAINT IF EXISTS stops_level_id_fkey"
    execute "ALTER TABLE pathways DROP CONSTRAINT IF EXISTS pathways_from_stop_id_fkey"
    execute "ALTER TABLE pathways DROP CONSTRAINT IF EXISTS pathways_to_stop_id_fkey"

    # Truncate tables (test data only)
    execute "TRUNCATE TABLE pathways CASCADE"
    execute "TRUNCATE TABLE stops CASCADE"

    # Stops: rename parent_station_id to parent_station and change type
    rename table(:stops), :parent_station_id, to: :parent_station

    alter table(:stops) do
      modify :parent_station, :string, from: :binary_id
      modify :level_id, :string, from: :binary_id
    end

    # Pathways: change from_stop_id and to_stop_id to string
    alter table(:pathways) do
      modify :from_stop_id, :string, null: false, from: {:binary_id, null: false}
      modify :to_stop_id, :string, null: false, from: {:binary_id, null: false}
    end

    # Add indexes for string columns
    create index(:stops, [:organization_id, :gtfs_version_id, :parent_station])
    create index(:stops, [:organization_id, :gtfs_version_id, :level_id])
    create index(:pathways, [:organization_id, :gtfs_version_id, :from_stop_id])
    create index(:pathways, [:organization_id, :gtfs_version_id, :to_stop_id])
  end

  def down do
    drop_if_exists index(:pathways, [:organization_id, :gtfs_version_id, :to_stop_id])
    drop_if_exists index(:pathways, [:organization_id, :gtfs_version_id, :from_stop_id])
    drop_if_exists index(:stops, [:organization_id, :gtfs_version_id, :level_id])
    drop_if_exists index(:stops, [:organization_id, :gtfs_version_id, :parent_station])

    alter table(:pathways) do
      modify :from_stop_id, :binary_id, null: false
      modify :to_stop_id, :binary_id, null: false
    end

    alter table(:stops) do
      modify :level_id, :binary_id
      modify :parent_station, :binary_id
    end

    rename table(:stops), :parent_station, to: :parent_station_id
  end
end
