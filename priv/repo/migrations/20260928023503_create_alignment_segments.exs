defmodule GtfsPlanner.Repo.Migrations.CreateAlignmentSegments do
  use Ecto.Migration

  def change do
    create table(:alignment_segments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :from_stop_id, :string, null: false
      add :to_stop_id, :string, null: false

      add :from_occurrence_id,
          references(:route_pattern_stops, type: :binary_id, on_delete: :delete_all)

      add :points, {:array, {:array, :float}}, null: false, default: fragment("'{}'")
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :alignment_segments,
             [:organization_id, :gtfs_version_id, :from_stop_id, :to_stop_id],
             name: :alignment_segments_shared_pair_index,
             where: "from_occurrence_id IS NULL"
           )

    create unique_index(
             :alignment_segments,
             [:from_occurrence_id, :to_stop_id],
             name: :alignment_segments_override_visit_index,
             where: "from_occurrence_id IS NOT NULL"
           )

    create index(:alignment_segments, [:organization_id, :gtfs_version_id])

    alter table(:route_patterns) do
      add :shape_id, :string
      add :alignment_digest, :string
    end

    create unique_index(
             :route_patterns,
             [:organization_id, :gtfs_version_id, :shape_id],
             name: :route_patterns_owned_shape_index,
             where: "shape_id IS NOT NULL"
           )

    alter table(:route_pattern_stops) do
      add :shape_dist_traveled, :decimal
    end
  end
end
