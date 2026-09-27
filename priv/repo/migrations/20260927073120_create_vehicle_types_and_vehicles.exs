defmodule GtfsPlanner.Repo.Migrations.CreateVehicleTypesAndVehicles do
  use Ecto.Migration

  def change do
    create table(:vehicle_types, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :max_out_minutes, :integer
      add :updated_by_id, :binary_id
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vehicle_types, [:organization_id, "lower(name)"],
             name: :vehicle_types_organization_id_lower_name_index
           )

    create table(:vehicles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :vehicle_id, :string, null: false
      add :vehicle_label, :string
      add :license_plate, :string

      # NO ACTION so deleting a referenced garage or type fails closed while the
      # organization cascade still reaches these rows. `:nilify_all` would silently
      # clear assignments and `:restrict` would block `delete_organization/1`.
      add :vehicle_type_id,
          references(:vehicle_types, type: :binary_id, on_delete: :nothing)

      add :garage_id, references(:garages, type: :binary_id, on_delete: :nothing)

      add :updated_by_id, :binary_id
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vehicles, [:organization_id, :vehicle_id])
    create index(:vehicles, [:organization_id, :garage_id, :vehicle_type_id])
    create index(:vehicles, [:vehicle_type_id])
  end
end
