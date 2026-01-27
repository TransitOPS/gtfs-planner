defmodule GtfsPlanner.Gtfs.StopLevel do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          stop_id: Ecto.UUID.t(),
          level_id: Ecto.UUID.t(),
          diagram_filename: String.t() | nil,
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stop_levels" do
    field :diagram_filename, :string

    belongs_to :stop, GtfsPlanner.Gtfs.Stop
    belongs_to :level, GtfsPlanner.Gtfs.Level
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(stop_level, attrs) do
    stop_level
    |> cast(attrs, [
      :stop_id,
      :level_id,
      :diagram_filename,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:stop_id, :level_id, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :stop_id, :level_id])
  end
end
