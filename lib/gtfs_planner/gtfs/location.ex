defmodule GtfsPlanner.Gtfs.Location do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "locations" do
    field :location_id, :string
    field :location_name, :string
    field :location_lat, :decimal
    field :location_lon, :decimal

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          location_id: String.t(),
          location_name: String.t() | nil,
          location_lat: Decimal.t() | nil,
          location_lon: Decimal.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a location."
  def changeset(location, attrs) do
    location
    |> cast(attrs, [
      :location_id,
      :location_name,
      :location_lat,
      :location_lon,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:location_id, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :location_id])
    |> foreign_key_constraint(:organization_id)
  end
end
