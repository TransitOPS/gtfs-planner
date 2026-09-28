defmodule GtfsPlanner.Gtfs.ReliefPoint do
  @moduledoc """
  A stop where relief (operator changes) may occur in one GTFS version.

  Rows are keyed by `(organization_id, gtfs_version_id, stop_id)`.
  `stop_id`, `organization_id` and `gtfs_version_id` are set on the struct by
  the caller and are never cast from submitted parameters.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "relief_points" do
    field :stop_id, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          stop_id: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Changeset for a relief point.

  The schema has no user-cast fields — the caller assigns `stop_id` and the
  scoping fields on the struct. The changeset exists so inserts surface the
  uniqueness rule as changeset errors.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(relief_point, attrs) do
    relief_point
    |> cast(attrs, [])
    |> unique_constraint([:organization_id, :gtfs_version_id, :stop_id],
      name: "relief_points_organization_id_gtfs_version_id_stop_id_index"
    )
  end
end
