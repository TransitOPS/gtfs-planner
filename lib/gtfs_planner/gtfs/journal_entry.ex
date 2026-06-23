defmodule GtfsPlanner.Gtfs.JournalEntry do
  @moduledoc """
  A station-journal entry: a field-collected note and/or photos, optionally
  anchored to a target within the station. See the companion app's
  `specs/api/station-journal.md`.

  The `id` is client-generated (stable across offline capture → sync) and is the
  upsert key. `target_type` is polymorphic over `station` (target_id null),
  `node`, and `pathway` (the `pin` target and its diagram coordinate columns are
  added by a later migration).
  """
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @target_types ~w(station node pathway)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          station_id: Ecto.UUID.t(),
          target_type: String.t(),
          target_id: Ecto.UUID.t() | nil,
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
    |> validate_target_id()
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
    |> foreign_key_constraint(:station_id)
  end

  # A node/pathway entry must name its target; a station entry must not.
  defp validate_target_id(changeset) do
    case get_field(changeset, :target_type) do
      type when type in ["node", "pathway"] ->
        if get_field(changeset, :target_id),
          do: changeset,
          else: add_error(changeset, :target_id, "is required for node and pathway targets")

      "station" ->
        if get_field(changeset, :target_id),
          do: add_error(changeset, :target_id, "must be blank for station targets"),
          else: changeset

      _ ->
        changeset
    end
  end
end
