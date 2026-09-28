defmodule GtfsPlanner.Gtfs.RoutePattern do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "route_patterns" do
    field :route_pattern_id, :string
    field :route_id, :string
    field :headsign, :string
    field :derivation_key, :string
    field :direction_id, :integer
    field :route_pattern_name, :string
    field :route_pattern_time_desc, :string
    field :route_pattern_typicality, :integer, default: 0
    field :route_pattern_sort_order, :integer
    field :representative_trip_id, :string
    field :canonical_route_pattern, :integer, default: 0
    field :active, :boolean, default: true
    field :shape_id, :string
    field :alignment_digest, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          route_pattern_id: String.t(),
          route_id: String.t(),
          headsign: String.t() | nil,
          derivation_key: String.t() | nil,
          direction_id: integer(),
          route_pattern_name: String.t() | nil,
          route_pattern_time_desc: String.t() | nil,
          route_pattern_typicality: integer(),
          route_pattern_sort_order: integer() | nil,
          representative_trip_id: String.t() | nil,
          canonical_route_pattern: integer(),
          active: boolean(),
          shape_id: String.t() | nil,
          alignment_digest: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a route pattern."
  def changeset(route_pattern, attrs) do
    route_pattern
    |> cast(attrs, [
      :route_pattern_id,
      :route_id,
      :headsign,
      :derivation_key,
      :direction_id,
      :route_pattern_name,
      :route_pattern_time_desc,
      :route_pattern_typicality,
      :route_pattern_sort_order,
      :representative_trip_id,
      :canonical_route_pattern,
      :active,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :route_pattern_id,
      :route_id,
      :direction_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_inclusion(:direction_id, [0, 1])
    |> validate_inclusion(:route_pattern_typicality, 0..5)
    |> validate_inclusion(:canonical_route_pattern, 0..2)
    |> validate_number(:route_pattern_sort_order, greater_than_or_equal_to: 0)
    |> unique_constraint([:organization_id, :gtfs_version_id, :route_pattern_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :route_id, :derivation_key],
      name: :route_patterns_scoped_derivation_key_index
    )
    |> foreign_key_constraint(:organization_id)
  end

  @doc "Returns human-readable label for route_pattern_typicality."
  def typicality_label(0), do: "Not defined"
  def typicality_label(1), do: "Typical"
  def typicality_label(2), do: "Deviation"
  def typicality_label(3), do: "Atypical"
  def typicality_label(4), do: "Diversion"
  def typicality_label(5), do: "Canonical reference"
  def typicality_label(_), do: "Unknown"

  @doc """
  Returns the label for a GTFS direction value.

  A GTFS direction value is not inherently inbound or outbound, so the default
  label is neutral. A route-specific label may be supplied by the caller; it
  replaces, and never reinterprets, the numeric value.
  """
  def direction_label(direction_id, route_label \\ nil)
  def direction_label(0, nil), do: "Direction 0"
  def direction_label(1, nil), do: "Direction 1"

  def direction_label(_direction_id, route_label)
      when is_binary(route_label) and route_label != "",
      do: route_label

  def direction_label(_direction_id, _route_label), do: "Direction unknown"

  @doc "Returns the selectable labels for the supported direction values."
  def direction_options do
    for direction_id <- [0, 1], do: {direction_label(direction_id), direction_id}
  end

  @doc "Returns the selectable labels for the typicality values 0 through 5."
  def typicality_options do
    for typicality <- 0..5, do: {typicality_label(typicality), typicality}
  end
end
