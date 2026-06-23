defmodule GtfsPlanner.Gtfs.JournalEntry do
  @moduledoc """
  A station-journal entry: a field-collected note and/or photos, optionally
  anchored to a target within the station. See the companion app's
  `specs/api/station-journal.md`.

  The `id` is client-generated (stable across offline capture → sync) and is the
  upsert key. `target_type` is polymorphic over `station` (target_id null),
  `node`, `pathway`, and `pin` (an arbitrary point on a level: `stop_level_id` +
  `diagram_x/y` as the canonical anchor — exactly like a node's diagram
  coordinate. `lat/lon` is optional enrichment imputed at level-alignment time,
  not at sync, and stays nil on unaligned levels).
  """
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @target_types ~w(station node pathway pin)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          station_id: Ecto.UUID.t(),
          target_type: String.t(),
          target_id: Ecto.UUID.t() | nil,
          stop_level_id: Ecto.UUID.t() | nil,
          diagram_x: float() | nil,
          diagram_y: float() | nil,
          lat: float() | nil,
          lon: float() | nil,
          body: String.t() | nil,
          author_id: Ecto.UUID.t(),
          captured_at: DateTime.t(),
          resolved_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "journal_entries" do
    field :target_type, :string
    field :target_id, :binary_id
    field :stop_level_id, :binary_id
    field :diagram_x, :float
    field :diagram_y, :float
    field :lat, :float
    field :lon, :float
    field :body, :string
    field :author_id, :binary_id
    field :captured_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :station_id, :binary_id

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  def target_types, do: @target_types

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :id,
      :organization_id,
      :gtfs_version_id,
      :station_id,
      :target_type,
      :target_id,
      :stop_level_id,
      :diagram_x,
      :diagram_y,
      :lat,
      :lon,
      :body,
      :author_id,
      :captured_at,
      :resolved_at
    ])
    |> trim_string_fields()
    |> validate_required([
      :id,
      :organization_id,
      :gtfs_version_id,
      :station_id,
      :target_type,
      :author_id,
      :captured_at
    ])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_target()
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
    |> foreign_key_constraint(:station_id)
    |> foreign_key_constraint(:stop_level_id)
  end

  # Target-shape rules by `target_type`:
  #   - node/pathway: `target_id` required (the node/pathway UUID).
  #   - station:      `target_id` must be blank.
  #   - pin:          no `target_id`; `stop_level_id` + `diagram_x/y` required
  #                   (the level + diagram-canvas point is the canonical anchor).
  #                   lat/lon are optional enrichment imputed at alignment time.
  defp validate_target(changeset) do
    case get_field(changeset, :target_type) do
      type when type in ["node", "pathway"] ->
        if get_field(changeset, :target_id),
          do: changeset,
          else: add_error(changeset, :target_id, "is required for node and pathway targets")

      "station" ->
        if get_field(changeset, :target_id),
          do: add_error(changeset, :target_id, "must be blank for station targets"),
          else: changeset

      "pin" ->
        changeset
        |> validate_pin_target_id()
        |> validate_required([:stop_level_id, :diagram_x, :diagram_y])

      _ ->
        changeset
    end
  end

  defp validate_pin_target_id(changeset) do
    if get_field(changeset, :target_id),
      do: add_error(changeset, :target_id, "must be blank for pin targets"),
      else: changeset
  end
end
