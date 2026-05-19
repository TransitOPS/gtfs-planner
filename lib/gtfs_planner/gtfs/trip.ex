defmodule GtfsPlanner.Gtfs.Trip do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "trips" do
    field :trip_id, :string
    field :route_id, :string
    field :service_id, :string
    field :trip_headsign, :string
    field :trip_short_name, :string
    field :direction_id, :integer
    field :block_id, :string
    field :shape_id, :string
    field :wheelchair_accessible, :integer
    field :bikes_allowed, :integer
    field :cars_allowed, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          trip_id: String.t(),
          route_id: String.t(),
          service_id: String.t(),
          trip_headsign: String.t() | nil,
          trip_short_name: String.t() | nil,
          direction_id: integer() | nil,
          block_id: String.t() | nil,
          shape_id: String.t() | nil,
          wheelchair_accessible: integer() | nil,
          bikes_allowed: integer() | nil,
          cars_allowed: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a trip."
  def changeset(trip, attrs) do
    trip
    |> cast(attrs, [
      :trip_id,
      :route_id,
      :service_id,
      :trip_headsign,
      :trip_short_name,
      :direction_id,
      :block_id,
      :shape_id,
      :wheelchair_accessible,
      :bikes_allowed,
      :cars_allowed,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :trip_id,
      :route_id,
      :service_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_inclusion(:direction_id, [0, 1])
    |> validate_inclusion(:wheelchair_accessible, 0..2)
    |> validate_inclusion(:bikes_allowed, 0..2)
    |> validate_inclusion(:cars_allowed, 0..2)
    |> unique_constraint([:organization_id, :gtfs_version_id, :trip_id])
    |> foreign_key_constraint(:organization_id)
  end

  @doc "Returns human-readable label for direction_id."
  def direction_label(direction_id) do
    case direction_id do
      0 -> "Outbound"
      1 -> "Inbound"
      _ -> "Unknown"
    end
  end

  @doc "Returns human-readable label for wheelchair_accessible."
  def wheelchair_label(wheelchair_accessible) do
    case wheelchair_accessible do
      0 -> "No information"
      1 -> "Accessible"
      2 -> "Not accessible"
      _ -> "Unknown"
    end
  end

  @doc "Returns human-readable label for bikes_allowed."
  def bikes_label(bikes_allowed) do
    case bikes_allowed do
      0 -> "No information"
      1 -> "Allowed"
      2 -> "Not allowed"
      _ -> "Unknown"
    end
  end

  @doc "Returns human-readable label for cars_allowed."
  def cars_label(cars_allowed) do
    case cars_allowed do
      0 -> "No information"
      1 -> "Allowed"
      2 -> "Not allowed"
      _ -> "Unknown"
    end
  end
end
