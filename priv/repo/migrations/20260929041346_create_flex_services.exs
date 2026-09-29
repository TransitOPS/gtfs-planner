defmodule GtfsPlanner.Repo.Migrations.CreateFlexServices do
  use Ecto.Migration

  def change do
    create table(:flex_services, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id, :binary_id, null: false

      add :key, :string, null: false
      add :name, :string, null: false
      add :kind, :string, null: false
      add :active, :boolean, null: false, default: true
      add :agency_id, :string
      add :riders, :string, null: false, default: "anyone"
      add :eligibility, :string
      add :include_registered, :boolean, null: false, default: false
      add :phone, :string
      add :phone_hours, :map
      add :booking_url, :string
      add :info_url, :string
      add :note, :string
      add :hours, {:array, :map}, null: false, default: []
      add :booking_rules, {:array, :map}, null: false, default: []
      add :hub_stop_ids, {:array, :string}, null: false, default: []
      add :route_id, :string
      add :distance_m, :integer
      add :wording, :string
      add :measure, :string, null: false, default: "route"
      add :first_stop_id, :string
      add :last_stop_id, :string
      add :dropoffs, :string, null: false, default: "tell_driver"
      add :ada_only, :boolean, null: false, default: false
      add :band_start, :string
      add :band_end, :string
      add :calendar_service_ids, {:array, :string}, null: false, default: []
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flex_services, [:organization_id, :gtfs_version_id, :key])

    create constraint(:flex_services, :kind, check: "kind IN ('area', 'detour')")
    create constraint(:flex_services, :riders, check: "riders IN ('anyone', 'registered')")
    create constraint(:flex_services, :measure, check: "measure IN ('route', 'stops')")

    create constraint(:flex_services, :dropoffs,
             check: "dropoffs IN ('tell_driver', 'book', 'dropoff_only')"
           )
  end
end
