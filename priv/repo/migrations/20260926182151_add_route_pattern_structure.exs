defmodule GtfsPlanner.Repo.Migrations.AddRoutePatternStructure do
  use Ecto.Migration

  @timing_name_index :timed_patterns_route_pattern_id_lower_name_index
  @pattern_derivation_index :route_patterns_scoped_derivation_key_index
  @timing_derivation_index :timed_patterns_route_pattern_id_derivation_key_index

  def up do
    alter table(:route_patterns) do
      add :headsign, :string
      add :derivation_key, :string
    end

    create unique_index(
             :route_patterns,
             [:organization_id, :gtfs_version_id, :route_id, :derivation_key],
             name: @pattern_derivation_index,
             where: "derivation_key IS NOT NULL"
           )

    create table(:route_pattern_stops, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :route_pattern_id,
          references(:route_patterns, type: :binary_id, on_delete: :delete_all), null: false

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :stop_id, :string, null: false
      add :position, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:route_pattern_stops, :route_pattern_stops_position_must_be_positive,
             check: "position > 0"
           )

    create unique_index(:route_pattern_stops, [:route_pattern_id, :position],
             name: :route_pattern_stops_route_pattern_id_position_index
           )

    create index(:route_pattern_stops, [:organization_id, :gtfs_version_id, :route_pattern_id])

    create table(:timed_patterns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :route_pattern_id,
          references(:route_patterns, type: :binary_id, on_delete: :delete_all), null: false

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :name, :string, null: false
      add :headsign, :string
      add :derivation_key, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:timed_patterns, [:route_pattern_id, "lower(name)"],
             name: @timing_name_index
           )

    create unique_index(:timed_patterns, [:route_pattern_id, :derivation_key],
             name: @timing_derivation_index,
             where: "derivation_key IS NOT NULL"
           )

    create index(:timed_patterns, [:organization_id, :gtfs_version_id, :route_pattern_id])

    create table(:timed_pattern_stops, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :timed_pattern_id,
          references(:timed_patterns, type: :binary_id, on_delete: :delete_all),
          null: false

      add :route_pattern_stop_id,
          references(:route_pattern_stops, type: :binary_id, on_delete: :restrict),
          null: false

      add :arrival_offset, :integer, null: false
      add :departure_offset, :integer, null: false
      add :timepoint, :integer
      add :pickup_type, :integer
      add :drop_off_type, :integer
      add :stop_headsign, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:timed_pattern_stops, [:timed_pattern_id, :route_pattern_stop_id],
             name: :timed_pattern_stops_timed_pattern_id_occurrence_id_index
           )

    create index(:timed_pattern_stops, [:route_pattern_stop_id])

    alter table(:trips) do
      add :route_pattern_id, :string

      add :timed_pattern_id,
          references(:timed_patterns, type: :binary_id, on_delete: :restrict)

      add :pattern_derivation_state, :string, null: false, default: "pending"
      add :pattern_derivation_reason, :string, size: 80
    end

    create constraint(:trips, :trips_pattern_derivation_state_check,
             check:
               "(pattern_derivation_state = 'pending' AND timed_pattern_id IS NULL) OR " <>
                 "(pattern_derivation_state = 'linked' AND timed_pattern_id IS NOT NULL AND pattern_derivation_reason IS NULL) OR " <>
                 "(pattern_derivation_state = 'custom' AND timed_pattern_id IS NULL AND pattern_derivation_reason IS NOT NULL)"
           )

    create index(:trips, [:organization_id, :gtfs_version_id, :route_pattern_id],
             name: :trips_scoped_route_pattern_id_index
           )

    create index(:trips, [:timed_pattern_id], name: :trips_timed_pattern_id_index)

    create index(:trips, [:organization_id, :gtfs_version_id, :route_id],
             name: :trips_pending_pattern_derivation_index,
             where: "pattern_derivation_state = 'pending'"
           )

    alter table(:routes) do
      add :pattern_derivation_error, :string, size: 80
    end
  end

  def down do
    alter table(:routes), do: remove(:pattern_derivation_error)

    drop index(:trips, [], name: :trips_pending_pattern_derivation_index)
    drop index(:trips, [], name: :trips_timed_pattern_id_index)
    drop index(:trips, [], name: :trips_scoped_route_pattern_id_index)
    drop constraint(:trips, :trips_pattern_derivation_state_check)

    alter table(:trips) do
      remove :pattern_derivation_reason
      remove :pattern_derivation_state
      remove :timed_pattern_id
      remove :route_pattern_id
    end

    drop table(:timed_pattern_stops)
    drop table(:timed_patterns)
    drop table(:route_pattern_stops)
    drop index(:route_patterns, [], name: @pattern_derivation_index)

    alter table(:route_patterns) do
      remove :derivation_key
      remove :headsign
    end
  end
end
