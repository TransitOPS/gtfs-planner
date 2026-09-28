defmodule GtfsPlanner.Gtfs.RouteOperatingSetting do
  @moduledoc """
  Operating constraints for one route in one GTFS version.

  Rows are keyed by `(organization_id, gtfs_version_id, route_id)` and carry the
  route's garage and required vehicle type. `route_id`, `organization_id` and
  `gtfs_version_id` are set on the struct by the caller and are never cast from
  submitted parameters.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "route_operating_settings" do
    field :route_id, :string

    belongs_to :garage, GtfsPlanner.Operations.Garage
    belongs_to :required_vehicle_type, GtfsPlanner.Operations.VehicleType

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          route_id: String.t(),
          garage_id: Ecto.UUID.t() | nil,
          required_vehicle_type_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Changeset for a route's operating settings.

  Casts only the user fields `garage_id` and `required_vehicle_type_id`; the
  scoping fields are assigned by the caller. One row exists per organization,
  version and route.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:garage_id, :required_vehicle_type_id])
    |> foreign_key_constraint(:garage_id)
    |> foreign_key_constraint(:required_vehicle_type_id)
    |> unique_constraint([:organization_id, :gtfs_version_id, :route_id],
      name: "route_operating_settings_organization_id_gtfs_version_id_route_"
    )
  end
end
