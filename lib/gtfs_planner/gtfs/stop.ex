defmodule GtfsPlanner.Gtfs.Stop do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stops" do
    field :lock_version, :integer, default: 1, read_after_writes: true
    field :stop_id, :string
    field :stop_name, :string
    field :stop_desc, :string
    field :stop_lat, :decimal
    field :stop_lon, :decimal
    field :location_type, :integer, default: 0
    field :wheelchair_boarding, :integer
    field :platform_code, :string

    # Written only by the full importer (RowParser.stop_row_to_attrs/3) and
    # GtfsPlanner.Gtfs.FareZones. It is never cast, so a partial station-data file,
    # a stop form or a rollback cannot clear an assigned fare zone.
    field :zone_id, :string

    # stop_code, tts_stop_name, stop_url and stop_timezone follow the same rule:
    # the full importer is their only writer and none is ever cast, so a stop
    # form, a partial station-data file or a rollback cannot clear them.
    field :stop_code, :string
    field :tts_stop_name, :string
    field :stop_url, :string
    field :stop_timezone, :string
    field :diagram_coordinate, :map

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    field :parent_station, :string
    field :level_id, :string

    # `child_stops` was an automatic association on `parent_station`, which
    # joined every organization's rows sharing a feed ID. Child stops are read
    # through the scoped station readers in `Gtfs` instead.
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
          lock_version: pos_integer(),
          stop_id: String.t(),
          stop_name: String.t() | nil,
          stop_desc: String.t() | nil,
          stop_lat: Decimal.t() | nil,
          stop_lon: Decimal.t() | nil,
          location_type: integer(),
          wheelchair_boarding: integer() | nil,
          platform_code: String.t() | nil,
          zone_id: String.t() | nil,
          stop_code: String.t() | nil,
          tts_stop_name: String.t() | nil,
          stop_url: String.t() | nil,
          stop_timezone: String.t() | nil,
          diagram_coordinate: map() | nil,
          parent_station: String.t() | nil,
          level_id: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type accessibility_status :: :accessible | :not_accessible | :unknown
  @type accessibility_source :: :direct | :inherited | :missing

  # The editor's writable fields. `stop_code`, `tts_stop_name` and `stop_url`
  # join the upstream station-editor set because this run's stop editor writes
  # them; `organization_id` and `gtfs_version_id` are never cast here, so
  # ownership always comes from the server (`create_changeset/3`).
  @editor_fields [
    :stop_name,
    :stop_desc,
    :stop_lat,
    :stop_lon,
    :location_type,
    :wheelchair_boarding,
    :platform_code,
    :stop_code,
    :tts_stop_name,
    :stop_url,
    :diagram_coordinate,
    :parent_station,
    :level_id
  ]

  # GTFS requires a name and coordinates only where a rider can board: a stop, a
  # station or an entrance/exit (types 0-2). A node or a boarding area (3, 4) is
  # positioned by its parent, so the editor leaves those fields optional.
  @located_types [nil, 0, 1, 2]

  @doc """
  Validates fields that a stop editor may change.

  Requires a name and both coordinates for the located location types, refuses a
  station nested inside another station, and accepts only an absolute
  `http`/`https` `stop_url` with a host, so a `javascript:` or `data:` value gets
  a field error instead of reaching the exported feed.

  `level_id` stays optional here: GTFS needs it only for elevator pathways. The
  station diagram, whose own form always shows a level for a child stop, adds the
  requirement through `child_stop_changeset/2`.
  """
  def editor_changeset(stop, attrs) do
    stop
    |> cast(attrs, @editor_fields)
    |> validate_stop_fields()
    |> validate_editor_rules()
    |> validate_located_type_fields()
  end

  @doc "Creates an editor stop with ownership supplied by the server."
  def create_changeset(%__MODULE__{} = stop, attrs, %{
        organization_id: org_id,
        gtfs_version_id: version_id
      }) do
    %{stop | organization_id: org_id, gtfs_version_id: version_id}
    |> cast(attrs, [:stop_id | @editor_fields])
    |> validate_stop_fields()
    |> validate_editor_rules()
    |> validate_located_type_fields()
  end

  @doc "Creates a changeset for a stop."
  def changeset(stop, attrs) do
    stop
    |> base_changeset(attrs)
    |> validate_parent_rule()
  end

  # GTFS: only a stop that actually names a parent can be a station inside one.
  defp validate_parent_rule(changeset) do
    if get_field(changeset, :parent_station) in [nil, ""] do
      changeset
    else
      validate_station_has_no_parent(changeset)
    end
  end

  @doc "Creates an import changeset for a stop with permissive parent/level validation."
  def import_changeset(stop, attrs) do
    base_changeset(stop, attrs)
  end

  # GTFS needs level_id only for elevator pathways, so `Stop.editor_changeset/2`
  # leaves it optional and the map editor can move a stop between stations. The
  # station diagram's child-stop form always shows a level picker and requires one
  # there, so that form builds its changeset through these functions.
  @doc """
  Adds the station diagram's own rule: a child stop must name a level.

  `Stop.editor_changeset/2` is permissive about `level_id` so the map editor can
  move a stop between stations and so the importer keeps its permissive rules.
  """
  def child_stop_changeset(stop, attrs) do
    stop
    |> cast(attrs, @editor_fields)
    |> validate_stop_fields()
    |> validate_editor_rules()
    |> require_child_level()
  end

  @doc "Same rule as `child_stop_changeset/2`, for a stop being created."
  def child_stop_changeset(%__MODULE__{} = stop, attrs, audit) do
    %{stop | organization_id: audit.organization_id, gtfs_version_id: audit.gtfs_version_id}
    |> cast(attrs, [:stop_id | @editor_fields])
    |> validate_stop_fields()
    |> validate_editor_rules()
    |> require_child_level()
  end

  defp require_child_level(changeset) do
    if get_field(changeset, :parent_station) in [nil, ""] do
      changeset
    else
      validate_required(changeset, [:level_id])
    end
  end

  # The rules every stop-writing surface shares, so all of them refuse the same
  # nested station and the same unusable web address.
  defp validate_editor_rules(changeset) do
    changeset
    |> validate_parent_rule()
    |> validate_http_url(:stop_url)
  end

  # A name and both coordinates are required only where a rider can board. The
  # station diagram's own form does not ask for them: it positions a child stop
  # on the diagram, so `child_stop_changeset/2` leaves these fields optional.
  defp validate_located_type_fields(changeset) do
    if get_field(changeset, :location_type) in @located_types do
      validate_required(changeset, [:stop_name, :stop_lat, :stop_lon])
    else
      changeset
    end
  end

  # GTFS: a station (location_type=1) must not have a parent_station.
  defp validate_station_has_no_parent(changeset) do
    if get_field(changeset, :location_type) == 1 do
      add_error(
        changeset,
        :location_type,
        "A station can't be inside another station. Choose another type."
      )
    else
      changeset
    end
  end

  defp base_changeset(stop, attrs) do
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
    |> validate_stop_fields()
  end

  defp validate_stop_fields(changeset) do
    changeset
    |> trim_string_fields()
    |> validate_required([:stop_id, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:location_type, 0..4)
    |> validate_inclusion(:wheelchair_boarding, 0..2)
    |> validate_number(:stop_lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:stop_lon, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
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

  @doc "Returns human-readable label for wheelchair_boarding."
  def wheelchair_boarding_label(wheelchair_boarding) do
    case wheelchair_boarding do
      0 -> "No info"
      1 -> "Accessible"
      2 -> "Not accessible"
      _ -> nil
    end
  end

  @doc """
  Resolves the wheelchair boarding presentation for a stop.

  A direct value wins: `1` resolves to `:accessible` and `2` to `:not_accessible`,
  both with a `:direct` source. When the stop has no explicit value (`0` or `nil`),
  a known parent station carrying `1`/`2` supplies the same status with an
  `:inherited` source. Otherwise the status is `:unknown` with a `:missing` source.

  Pure: returns a presentation map and never mutates either input.
  """
  @spec resolve_wheelchair_boarding(t(), t() | nil) ::
          %{status: accessibility_status(), source: accessibility_source()}
  def resolve_wheelchair_boarding(%__MODULE__{wheelchair_boarding: 1}, _parent),
    do: %{status: :accessible, source: :direct}

  def resolve_wheelchair_boarding(%__MODULE__{wheelchair_boarding: 2}, _parent),
    do: %{status: :not_accessible, source: :direct}

  def resolve_wheelchair_boarding(%__MODULE__{}, %__MODULE__{wheelchair_boarding: 1}),
    do: %{status: :accessible, source: :inherited}

  def resolve_wheelchair_boarding(%__MODULE__{}, %__MODULE__{wheelchair_boarding: 2}),
    do: %{status: :not_accessible, source: :inherited}

  def resolve_wheelchair_boarding(%__MODULE__{}, _parent),
    do: %{status: :unknown, source: :missing}

  @doc "Returns slug prefix for location_type."
  def location_type_slug(location_type) do
    case location_type do
      0 -> "platform"
      1 -> "station"
      2 -> "entrance"
      3 -> "node"
      4 -> "boarding"
      _ -> "stop"
    end
  end

  @doc "Converts stop name text into a lowercase slug."
  def slugify(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.replace(~r/_{2,}/, "_")
    |> String.trim("_")
    |> String.slice(0, 64)
  end

  def slugify(_), do: ""

  @doc "Converts text into a lowercase kebab-case slug."
  def kebabify(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
    |> String.slice(0, 64)
  end

  def kebabify(_), do: ""

  @doc "Generates a stop_id from location type and stop name."
  def generate_stop_id(location_type, stop_name) when is_binary(stop_name) do
    case slugify(stop_name) do
      "" -> ""
      slug -> "#{location_type_slug(location_type)}_#{slug}"
    end
  end

  def generate_stop_id(_location_type, _stop_name), do: ""
end
