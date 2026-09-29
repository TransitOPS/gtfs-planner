defmodule GtfsPlanner.Gtfs.FlexArea do
  @moduledoc """
  One area of a flex service, scoped to one organization and version.

  `key` (`a1`, `a2`…) is stable within the service and is what the service's
  hours rows reference. `source` records how the polygon was chosen; the census
  provenance fields are set only for `:census` areas. A `:route_distance` area
  stores its buffer distance and no geometry, so which areas have geometry is a
  property of `geom`, not of the row.

  `geom` is deliberately not an Ecto field: geometry stays opaque and only
  `GtfsPlanner.Gtfs.Flex.Geometry` issues geometry SQL (R8, CR-1). Scope fields
  (`organization_id`, `gtfs_version_id`, `flex_service_id`) are set on the
  struct by callers and are never cast.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sources [:census, :route_distance, :drawn, :file]

  # A distance feeds `ST_Buffer(geography, m)`, whose cost grows with it. No
  # flex service reaches 50 km from its routes, so a larger value is refused
  # before PostGIS sees it.
  @max_distance_m 50_000
  @distance_message "Choose a distance of 50 km or less."

  schema "flex_areas" do
    field :key, :string
    field :position, :integer
    field :name, :string
    field :source, Ecto.Enum, values: @sources
    field :census_geoid, :string
    field :census_layer, :string
    field :census_vintage, :string
    field :route_ids, {:array, :string}, default: []
    field :distance_m, :integer

    belongs_to :flex_service, GtfsPlanner.Gtfs.FlexService
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          flex_service_id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          gtfs_version_id: Ecto.UUID.t() | nil,
          key: String.t() | nil,
          position: integer() | nil,
          name: String.t() | nil,
          source: :census | :route_distance | :drawn | :file | nil,
          census_geoid: String.t() | nil,
          census_layer: String.t() | nil,
          census_vintage: String.t() | nil,
          route_ids: [String.t()],
          distance_m: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Creates a changeset for one area.

  Requires the stable key, the list position, the rider-facing name and how the
  polygon was chosen. `geom` is not castable here; the context writes it through
  `GtfsPlanner.Gtfs.Flex.Geometry`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(area, attrs) do
    area
    |> cast(attrs, [
      :key,
      :position,
      :name,
      :source,
      :census_geoid,
      :census_layer,
      :census_vintage,
      :route_ids,
      :distance_m
    ])
    |> ChangesetHelpers.trim_string_fields()
    |> validate_required([:key, :position, :name, :source])
    |> validate_distance(:distance_m)
    |> unique_constraint([:flex_service_id, :key], error_key: :key)
  end

  @doc "The largest buffer distance, in metres, an area or a detour may use."
  @spec max_distance_m() :: pos_integer()
  def max_distance_m, do: @max_distance_m

  @doc """
  Validates a buffer distance field: a positive whole number of metres no
  larger than `max_distance_m/0`.
  """
  @spec validate_distance(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_distance(changeset, field) do
    changeset
    |> validate_number(field, greater_than: 0)
    |> validate_number(field, less_than_or_equal_to: @max_distance_m, message: @distance_message)
  end
end
