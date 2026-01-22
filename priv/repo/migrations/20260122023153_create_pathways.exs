defmodule GtfsPlanner.Repo.Migrations.CreatePathways do
  use Ecto.Migration

  def up do
    create table(:pathways, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pathway_id, :string, null: false
      add :pathway_mode, :integer, null: false
      add :is_bidirectional, :boolean, default: true, null: false
      add :traversal_time, :integer
      add :length, :decimal, precision: 10, scale: 2
      add :stair_count, :integer
      add :max_slope, :decimal, precision: 5, scale: 4
      add :min_width, :decimal, precision: 6, scale: 2
      add :signposted_as, :string
      add :reversed_signposted_as, :string

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all), null: false
      add :from_stop_id, references(:stops, type: :binary_id, on_delete: :delete_all), null: false
      add :to_stop_id, references(:stops, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pathways, [:organization_id, :gtfs_version_id, :pathway_id])
    create index(:pathways, [:organization_id, :gtfs_version_id])
    create index(:pathways, [:from_stop_id])
    create index(:pathways, [:to_stop_id])
  end

  def down do
    drop table(:pathways)
  end
end