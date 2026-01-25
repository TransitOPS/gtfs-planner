defmodule GtfsPlanner.Gtfs.StopTime do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stop_times" do
    field :trip_id, :string
    field :stop_id, :string
    field :stop_sequence, :integer
    field :arrival_time, :string
    field :departure_time, :string
    field :stop_headsign, :string
    field :pickup_type, :integer
    field :drop_off_type, :integer
    field :continuous_pickup, :integer
    field :continuous_drop_off, :integer
    field :shape_dist_traveled, :decimal
    field :timepoint, :integer

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
          stop_id: String.t(),
          stop_sequence: integer(),
          arrival_time: String.t() | nil,
          departure_time: String.t() | nil,
          stop_headsign: String.t() | nil,
          pickup_type: integer() | nil,
          drop_off_type: integer() | nil,
          continuous_pickup: integer() | nil,
          continuous_drop_off: integer() | nil,
          shape_dist_traveled: Decimal.t() | nil,
          timepoint: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a stop time."
  def changeset(stop_time, attrs) do
    stop_time
    |> cast(attrs, [
      :trip_id,
      :stop_id,
      :stop_sequence,
      :arrival_time,
      :departure_time,
      :stop_headsign,
      :pickup_type,
      :drop_off_type,
      :continuous_pickup,
      :continuous_drop_off,
      :shape_dist_traveled,
      :timepoint,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([
      :trip_id,
      :stop_id,
      :stop_sequence,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_number(:stop_sequence, greater_than_or_equal_to: 0)
    |> validate_inclusion(:pickup_type, 0..3)
    |> validate_inclusion(:drop_off_type, 0..3)
    |> validate_inclusion(:continuous_pickup, 0..3)
    |> validate_inclusion(:continuous_drop_off, 0..3)
    |> validate_inclusion(:timepoint, 0..1)
    |> validate_number(:shape_dist_traveled, greater_than_or_equal_to: 0)
    |> unique_constraint([:organization_id, :gtfs_version_id, :trip_id, :stop_sequence])
    |> foreign_key_constraint(:organization_id)
  end

  @doc "Returns human-readable label for pickup_type."
  def pickup_type_label(pickup_type) do
    case pickup_type do
      0 -> "Regularly scheduled"
      1 -> "No pickup available"
      2 -> "Must phone agency"
      3 -> "Must coordinate with driver"
      _ -> "Unknown"
    end
  end

  @doc "Returns human-readable label for drop_off_type."
  def drop_off_type_label(drop_off_type) do
    case drop_off_type do
      0 -> "Regularly scheduled"
      1 -> "No drop off available"
      2 -> "Must phone agency"
      3 -> "Must coordinate with driver"
      _ -> "Unknown"
    end
  end
end