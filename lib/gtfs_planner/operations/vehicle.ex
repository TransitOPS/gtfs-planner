defmodule GtfsPlanner.Operations.Vehicle do
  @moduledoc """
  An organization-wide vehicle.

  A vehicle belongs to exactly one organization and ignores GTFS versions. Its
  optional `vehicle_type_id` and `garage_id` reference organization-wide parents
  through `NO ACTION` foreign keys, so deleting a referenced parent fails closed
  while deleting the organization still cascades. `organization_id`,
  `vehicle_type_id`, `garage_id` and `updated_by_id` are set programmatically by
  `GtfsPlanner.Operations` after an ownership check and are never cast from user
  params.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          vehicle_id: String.t(),
          vehicle_label: String.t() | nil,
          license_plate: String.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          garage_id: Ecto.UUID.t() | nil,
          updated_by_id: Ecto.UUID.t() | nil,
          vehicle_type: GtfsPlanner.Operations.VehicleType.t() | Ecto.Association.NotLoaded.t(),
          garage: GtfsPlanner.Operations.Garage.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "vehicles" do
    field :vehicle_id, :string
    field :vehicle_label, :string
    field :license_plate, :string
    field :updated_by_id, :binary_id

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :vehicle_type, GtfsPlanner.Operations.VehicleType
    belongs_to :garage, GtfsPlanner.Operations.Garage

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for creating and updating a vehicle.

  Casts only the user-editable fields. `organization_id`, the assignment
  references and `updated_by_id` are assigned by `GtfsPlanner.Operations`.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(vehicle, attrs) do
    vehicle
    |> cast(attrs, [:vehicle_id, :vehicle_label, :license_plate])
    |> trim_string_fields()
    |> validate_required([:vehicle_id])
    |> validate_length(:vehicle_id, max: 255)
    |> validate_length(:vehicle_label, max: 255)
    |> validate_length(:license_plate, max: 255)
    |> unique_constraint(:vehicle_id, name: :vehicles_organization_id_vehicle_id_index)
    |> foreign_key_constraint(:vehicle_type_id, name: :vehicles_vehicle_type_id_fkey)
    |> foreign_key_constraint(:garage_id, name: :vehicles_garage_id_fkey)
  end
end
