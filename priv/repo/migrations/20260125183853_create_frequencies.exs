defmodule GtfsPlanner.Repo.Migrations.CreateFrequencies do
  use Ecto.Migration

  def up do
    create table(:frequencies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false
      add :gtfs_version_id, :binary_id, null: false
      add :trip_id, :string, null: false
      add :start_time, :string, null: false
      add :end_time, :string, null: false
      add :headway_secs, :integer, null: false
      add :exact_times, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:frequencies, [:organization_id, :gtfs_version_id, :trip_id, :start_time],
             name: :frequencies_organization_id_gtfs_version_id_trip_id_start_time_index
           )

    create index(:frequencies, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:frequencies)
  end
end