defmodule GtfsPlanner.Repo.Migrations.CreateRoutePatterns do
  use Ecto.Migration

  def up do
    create table(:route_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :route_pattern_id, :string, null: false
      add :route_id, :string, null: false
      add :direction_id, :integer, null: false
      add :route_pattern_name, :string
      add :route_pattern_time_desc, :string
      add :route_pattern_typicality, :integer, default: 0
      add :route_pattern_sort_order, :integer
      add :representative_trip_id, :string
      add :canonical_route_pattern, :integer, default: 0
      add :active, :boolean, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:route_patterns, [:organization_id, :gtfs_version_id, :route_pattern_id])
    create index(:route_patterns, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:route_patterns)
  end
end
