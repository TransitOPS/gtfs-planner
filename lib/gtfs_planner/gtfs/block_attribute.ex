defmodule GtfsPlanner.Gtfs.BlockAttribute do
  @moduledoc """
  Planning attributes for one block on one service.

  Rows are keyed by `(organization_id, gtfs_version_id, service_id, block_id)`
  and carry the block's garage and required vehicle type. `service_id`,
  `block_id`, `organization_id` and `gtfs_version_id` are set on the struct by
  the caller and are never cast from submitted parameters.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "block_attributes" do
    field :service_id, :string
    field :block_id, :string

    belongs_to :garage, GtfsPlanner.Operations.Garage
    belongs_to :vehicle_type, GtfsPlanner.Operations.VehicleType

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          service_id: String.t(),
          block_id: String.t(),
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Changeset for a block's planning attributes.

  Casts only the user fields `garage_id` and `vehicle_type_id`; the scoping
  fields are assigned by the caller. One row exists per organization, version,
  service and block.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attribute, attrs) do
    attribute
    |> cast(attrs, [:garage_id, :vehicle_type_id])
    |> foreign_key_constraint(:garage_id)
    |> foreign_key_constraint(:vehicle_type_id)
    |> unique_constraint([:organization_id, :gtfs_version_id, :service_id, :block_id],
      name: "block_attributes_organization_id_gtfs_version_id_service_id_blo"
    )
  end
end
