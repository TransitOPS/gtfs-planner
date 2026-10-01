defmodule GtfsPlanner.Gtfs.Level do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          lock_version: pos_integer(),
          level_id: String.t(),
          level_index: float(),
          level_name: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "levels" do
    field :lock_version, :integer, default: 1, read_after_writes: true
    field :level_id, :string
    field :level_index, :float
    field :level_name, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    has_many :stop_levels, GtfsPlanner.Gtfs.StopLevel

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Creates a changeset for a level."
  def changeset(level, attrs) do
    level
    |> cast(attrs, [
      :level_id,
      :level_index,
      :level_name,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([:level_id, :level_index, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :level_id],
      name: :levels_organization_id_gtfs_version_id_level_id_index
    )
    |> foreign_key_constraint(:organization_id)
  end

  @doc "Changes editable fields without accepting ownership or revision from a form."
  def editor_changeset(level, attrs) do
    level
    |> cast(attrs, [:level_id, :level_index, :level_name])
    |> trim_string_fields()
    |> validate_required([:level_id, :level_index, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :level_id],
      name: :levels_organization_id_gtfs_version_id_level_id_index
    )
  end
end
