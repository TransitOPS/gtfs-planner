defmodule GtfsPlanner.Gtfs.Stop do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stops" do
    field :stop_id, :string
    field :stop_name, :string
    field :stop_desc, :string
    field :stop_lat, :decimal
    field :stop_lon, :decimal
    field :location_type, :integer, default: 0
    field :wheelchair_boarding, :integer
    field :platform_code, :string
    field :diagram_coordinate, :map

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    field :parent_station, :string
    field :level_id, :string

    has_many :child_stops, __MODULE__, foreign_key: :parent_station
    has_many :stop_levels, GtfsPlanner.Gtfs.StopLevel
    many_to_many :levels, GtfsPlanner.Gtfs.Level, join_through: GtfsPlanner.Gtfs.StopLevel

    # Virtual field for preloaded level data (populated via select_merge in queries)
    field :level, :map, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          stop_id: String.t(),
          stop_name: String.t() | nil,
          stop_desc: String.t() | nil,
          stop_lat: Decimal.t() | nil,
          stop_lon: Decimal.t() | nil,
          location_type: integer(),
          wheelchair_boarding: integer() | nil,
          platform_code: String.t() | nil,
          diagram_coordinate: map() | nil,
          parent_station: String.t() | nil,
          level_id: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a stop."
  def changeset(stop, attrs) do
    stop
    |> cast(attrs, [
      :stop_id,
      :stop_name,
      :stop_desc,
      :stop_lat,
      :stop_lon,
      :location_type,
      :wheelchair_boarding,
      :platform_code,
      :diagram_coordinate,
      :organization_id,
      :gtfs_version_id,
      :parent_station,
      :level_id
    ])
    |> validate_required([:stop_id, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:location_type, 0..4)
    |> validate_inclusion(:wheelchair_boarding, 0..2)
    |> unique_constraint([:organization_id, :gtfs_version_id, :stop_id])
    |> foreign_key_constraint(:organization_id)
  end

  @doc "Returns human-readable label for location_type."
  def location_type_label(location_type) do
    case location_type do
      0 -> "Stop/Platform"
      1 -> "Station"
      2 -> "Entrance/Exit"
      3 -> "Generic Node"
      4 -> "Boarding Area"
      _ -> "Unknown"
    end
  end
end
