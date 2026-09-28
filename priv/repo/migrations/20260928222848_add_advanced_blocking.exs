defmodule GtfsPlanner.Repo.Migrations.AddAdvancedBlocking do
  use Ecto.Migration

  def change do
    alter table(:blocking_settings) do
      add :max_block_minutes, :integer
      add :pull_out_buffer_minutes, :integer, null: false, default: 0
      add :interlining, :string, null: false, default: "any"
      add :default_garage_id, references(:garages, type: :binary_id, on_delete: :nilify_all)
      add :deadhead_speed_kmh, :integer, null: false, default: 30
      add :deadhead_circuity, :decimal, null: false, default: 1.3
      add :max_piece_minutes, :integer
    end

    create constraint(:blocking_settings, :interlining_values,
             check: "interlining IN ('any','same_stop','none')"
           )

    create constraint(:blocking_settings, :max_block_minutes_range,
             check: "max_block_minutes IS NULL OR max_block_minutes BETWEEN 60 AND 1440"
           )

    create constraint(:blocking_settings, :pull_out_buffer_range,
             check: "pull_out_buffer_minutes BETWEEN 0 AND 60"
           )

    create constraint(:blocking_settings, :deadhead_speed_range,
             check: "deadhead_speed_kmh BETWEEN 5 AND 120"
           )

    create constraint(:blocking_settings, :deadhead_circuity_range,
             check: "deadhead_circuity BETWEEN 1.0 AND 3.0"
           )

    create constraint(:blocking_settings, :max_piece_minutes_range,
             check: "max_piece_minutes IS NULL OR max_piece_minutes BETWEEN 60 AND 720"
           )

    create table(:block_attributes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :service_id, :string, null: false
      add :block_id, :string, null: false

      # NO ACTION so deleting a referenced garage or type fails closed behind the
      # in-use guard, matching spec 06's vehicles FKs.
      add :garage_id, references(:garages, type: :binary_id, on_delete: :nothing)

      add :vehicle_type_id, references(:vehicle_types, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:block_attributes, [
             :organization_id,
             :gtfs_version_id,
             :service_id,
             :block_id
           ])

    create table(:route_operating_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :route_id, :string, null: false

      add :garage_id, references(:garages, type: :binary_id, on_delete: :nothing)

      add :required_vehicle_type_id,
          references(:vehicle_types, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:route_operating_settings, [:organization_id, :gtfs_version_id, :route_id])

    create table(:deadhead_times, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :from_ref, :string, null: false
      add :to_ref, :string, null: false
      add :minutes, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:deadhead_times, [:organization_id, :gtfs_version_id, :from_ref, :to_ref])

    create constraint(:deadhead_times, :minutes_range, check: "minutes BETWEEN 0 AND 600")

    create table(:relief_points, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :stop_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:relief_points, [:organization_id, :gtfs_version_id, :stop_id])
  end
end
