defmodule GtfsPlanner.Gtfs.TimedPattern do
  @moduledoc "A named service timing associated with a route pattern."

  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "timed_patterns" do
    # The parent's GTFS `route_pattern_id`, scoped by this row's organization and
    # version. `route_pattern` is the loaded parent the changeset checks that
    # scope against; it is never a single-column association.
    field :route_pattern_id, :string
    field :route_pattern, :any, virtual: true
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    field :name, :string
    field :headsign, :string
    field :derivation_key, :string

    has_many :timed_pattern_stops, GtfsPlanner.Gtfs.TimedPatternStop

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          route_pattern_id: String.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          name: String.t(),
          headsign: String.t() | nil,
          derivation_key: String.t() | nil,
          timed_pattern_stops: [GtfsPlanner.Gtfs.TimedPatternStop.t()],
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  def changeset(timed_pattern, attrs) do
    timed_pattern
    |> cast(attrs, [
      :route_pattern_id,
      :organization_id,
      :gtfs_version_id,
      :name,
      :headsign,
      :derivation_key
    ])
    |> put_loaded_route_pattern(Map.get(attrs, :route_pattern))
    |> trim_string_fields()
    |> validate_required([:route_pattern_id, :organization_id, :gtfs_version_id, :name])
    |> validate_length(:name, min: 1)
    |> unique_constraint([:route_pattern_id, :name],
      name: :timed_patterns_route_pattern_id_lower_name_index
    )
    |> unique_constraint([:route_pattern_id, :derivation_key],
      name: :timed_patterns_route_pattern_id_derivation_key_index
    )
    |> foreign_key_constraint(:route_pattern_id, name: :timed_patterns_route_patterns_owner_fkey)
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
