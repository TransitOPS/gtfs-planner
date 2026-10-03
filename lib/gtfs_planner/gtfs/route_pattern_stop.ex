defmodule GtfsPlanner.Gtfs.RoutePatternStop do
  @moduledoc "An ordered occurrence of a stop in a route pattern."

  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "route_pattern_stops" do
    # The parent's GTFS `route_pattern_id`, scoped by this row's organization and
    # version. `route_pattern` is the loaded parent the changeset checks that
    # scope against; it is never a single-column association.
    field :route_pattern_id, :string
    field :route_pattern, :any, virtual: true
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    field :stop_id, :string
    field :position, :integer
    field :shape_dist_traveled, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          route_pattern_id: String.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          stop_id: String.t(),
          position: pos_integer(),
          shape_dist_traveled: Decimal.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def changeset(route_pattern_stop, attrs) do
    route_pattern_stop
    |> cast(attrs, [
      :route_pattern_id,
      :organization_id,
      :gtfs_version_id,
      :stop_id,
      :position
    ])
    |> put_loaded_route_pattern(Map.get(attrs, :route_pattern))
    |> trim_string_fields()
    |> validate_required([
      :route_pattern_id,
      :organization_id,
      :gtfs_version_id,
      :stop_id,
      :position
    ])
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint([:route_pattern_id, :position],
      name: :route_pattern_stops_route_pattern_id_position_index
    )
    |> foreign_key_constraint(:route_pattern_id,
      name: :route_pattern_stops_route_patterns_owner_fkey
    )
    |> foreign_key_constraint(:organization_id)
    |> validate_route_pattern_scope()
  end

  defp put_loaded_route_pattern(changeset, %GtfsPlanner.Gtfs.RoutePattern{} = route_pattern),
    do: put_change(changeset, :route_pattern, route_pattern)

  defp put_loaded_route_pattern(changeset, _route_pattern), do: changeset

  defp validate_route_pattern_scope(changeset) do
    case get_field(changeset, :route_pattern) do
      %GtfsPlanner.Gtfs.RoutePattern{} = route_pattern ->
        changeset
        |> validate_parent_scope(:organization_id, route_pattern.organization_id)
        |> validate_parent_scope(:gtfs_version_id, route_pattern.gtfs_version_id)
        |> validate_parent_scope(:route_pattern_id, route_pattern.route_pattern_id)

      _ ->
        add_error(changeset, :route_pattern_id, "must reference a loaded route pattern")
    end
  end

  defp validate_parent_scope(changeset, field, parent_id) do
    if get_field(changeset, field) == parent_id do
      changeset
    else
      add_error(changeset, field, "must match the route pattern scope")
    end
  end
end
