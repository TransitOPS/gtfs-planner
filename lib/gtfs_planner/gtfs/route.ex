defmodule GtfsPlanner.Gtfs.Route do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "routes" do
    field :route_id, :string
    field :route_type, :integer
    field :route_short_name, :string
    field :route_long_name, :string
    field :agency_id, :string
    field :route_desc, :string
    field :route_url, :string
    field :route_color, :string, default: "FFFFFF"
    field :route_text_color, :string, default: "000000"
    field :route_sort_order, :integer
    field :continuous_pickup, :integer, default: 1
    field :continuous_drop_off, :integer, default: 1
    field :network_id, :string
    field :active, :boolean, default: true

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          route_id: String.t(),
          route_type: integer(),
          route_short_name: String.t() | nil,
          route_long_name: String.t() | nil,
          agency_id: String.t() | nil,
          route_desc: String.t() | nil,
          route_url: String.t() | nil,
          route_color: String.t(),
          route_text_color: String.t(),
          route_sort_order: integer() | nil,
          continuous_pickup: integer(),
          continuous_drop_off: integer(),
          network_id: String.t() | nil,
          active: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a route."
  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :route_id,
      :route_type,
      :route_short_name,
      :route_long_name,
      :agency_id,
      :route_desc,
      :route_url,
      :route_color,
      :route_text_color,
      :route_sort_order,
      :continuous_pickup,
      :continuous_drop_off,
      :network_id,
      :active,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([:route_id, :route_type, :organization_id, :gtfs_version_id])
    |> validate_route_name()
    |> validate_inclusion(:route_type, [0, 1, 2, 3, 4, 5, 6, 7, 11, 12])
    |> validate_inclusion(:continuous_pickup, 0..3)
    |> validate_inclusion(:continuous_drop_off, 0..3)
    |> validate_number(:route_sort_order, greater_than_or_equal_to: 0)
    |> validate_hex_color(:route_color)
    |> validate_hex_color(:route_text_color)
    |> unique_constraint([:organization_id, :gtfs_version_id, :route_id])
    |> foreign_key_constraint(:organization_id)
  end

  @doc "Returns human-readable label for route_type."
  def route_type_label(route_type) do
    case route_type do
      0 -> "Tram/Light Rail"
      1 -> "Subway/Metro"
      2 -> "Rail"
      3 -> "Bus"
      4 -> "Ferry"
      5 -> "Cable Tram"
      6 -> "Aerial Lift"
      7 -> "Funicular"
      11 -> "Trolleybus"
      12 -> "Monorail"
      _ -> "Unknown"
    end
  end

  # Private validation functions

  defp validate_route_name(changeset) do
    route_short_name = get_field(changeset, :route_short_name)
    route_long_name = get_field(changeset, :route_long_name)

    if is_nil(route_short_name) && is_nil(route_long_name) do
      add_error(
        changeset,
        :route_short_name,
        "at least one of route_short_name or route_long_name must be present"
      )
    else
      changeset
    end
  end

  defp validate_hex_color(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      _value ->
        validate_format(changeset, field, ~r/^[0-9A-Fa-f]{6}$/,
          message: "must be a valid 6-character hex color code"
        )
    end
  end
end
