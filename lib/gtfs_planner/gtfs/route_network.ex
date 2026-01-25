defmodule GtfsPlanner.Gtfs.RouteNetwork do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "route_networks" do
    field :network_id, :string
    field :route_id, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          network_id: String.t(),
          route_id: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a route network."
  def changeset(route_network, attrs) do
    route_network
    |> cast(attrs, [
      :network_id,
      :route_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:network_id, :route_id, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :network_id, :route_id])
    |> foreign_key_constraint(:organization_id)
  end
end
