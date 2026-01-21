defmodule GtfsPlanner.Gtfs.Stop do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          stop_id: String.t(),
          stop_name: String.t() | nil,
          stop_lat: Decimal.t() | nil,
          stop_lon: Decimal.t() | nil,
          location_type: integer(),
          wheelchair_boarding: integer() | nil,
          parent_station_id: Ecto.UUID.t() | nil,
          level_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stops" do
    field :stop_id, :string
    field :stop_name, :string
    field :stop_lat, :decimal
    field :stop_lon, :decimal
    field :location_type, :integer, default: 0
    field :wheelchair_boarding, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    belongs_to :level, GtfsPlanner.Gtfs.Level
    belongs_to :parent_station, __MODULE__,
      foreign_key: :parent_station_id

    has_many :child_stops, __MODULE__,
      foreign_key: :parent_station_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Creates a changeset for a stop."
  def changeset(stop, attrs) do
    stop
    |> cast(attrs, [:stop_id, :stop_name, :stop_lat, :stop_lon, :location_type, :wheelchair_boarding, :organization_id, :gtfs_version_id, :parent_station_id, :level_id])
    |> validate_required([:stop_id, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:location_type, 0..4)
    |> validate_inclusion(:wheelchair_boarding, 0..2)
    |> unique_constraint([:organization_id, :gtfs_version_id, :stop_id])
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
    |> foreign_key_constraint(:parent_station_id)
    |> foreign_key_constraint(:level_id)
  end
end
