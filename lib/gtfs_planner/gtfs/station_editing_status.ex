defmodule GtfsPlanner.Gtfs.StationEditingStatus do
  @moduledoc """
  Persisted signal that a user is actively editing a station.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          station_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          started_at: DateTime.t(),
          inserted_at: DateTime.t()
        }

  schema "station_editing_statuses" do
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    belongs_to :station, GtfsPlanner.Gtfs.Stop
    belongs_to :user, GtfsPlanner.Accounts.User

    field :started_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(status, attrs) do
    status
    |> cast(attrs, [:organization_id, :gtfs_version_id, :station_id, :user_id, :started_at])
    |> validate_required([:organization_id, :gtfs_version_id, :station_id, :user_id, :started_at])
    |> unique_constraint([:organization_id, :gtfs_version_id, :station_id],
      name: :station_editing_statuses_station_scope_index
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
    |> foreign_key_constraint(:station_id)
    |> foreign_key_constraint(:user_id)
  end
end
