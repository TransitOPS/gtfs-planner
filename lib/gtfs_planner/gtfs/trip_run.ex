defmodule GtfsPlanner.Gtfs.TripRun do
  @moduledoc """
  One trip's assignment to one run on one day type of one GTFS version.

  A row is the only stored fact about a run: which trips it holds on a day type.
  Pieces, work time and run types are derived from these rows and the day's blocks
  (INV-10), so a run exists only while its rows do.

  Rows are keyed by `(organization_id, gtfs_version_id, day_type_key, trip_id)`.
  `day_type_key`, `trip_id`, `organization_id` and `gtfs_version_id` are set on the
  struct by the caller and are never cast from submitted parameters; `run_id` is the
  only cast field, because it is the only one a user can name.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # A run ID is what an operator and a roster line call a run, so it is kept to
  # the characters a sign can carry: one to eight of letters, digits or a hyphen.
  @run_id_format ~r/^[A-Za-z0-9-]{1,8}$/

  # PostgreSQL truncates an identifier to 63 bytes, so the index Ecto names for
  # these four columns is stored as
  # `trip_runs_organization_id_gtfs_version_id_day_type_key_trip_id_` — the
  # trailing "index" is cut. The constraint is declared against the name the
  # database actually created, because Ecto matches a violation to a declaration
  # exactly and would otherwise raise instead of returning the changeset error.
  @day_type_index "trip_runs_organization_id_gtfs_version_id_day_type_key_trip_id_"

  schema "trip_runs" do
    field :day_type_key, :string
    field :run_id, :string

    belongs_to :trip, GtfsPlanner.Gtfs.Trip

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          trip_id: Ecto.UUID.t(),
          day_type_key: String.t(),
          run_id: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Changeset for a trip assignment.

  Only `run_id` is cast, so `organization_id`, `gtfs_version_id`, `trip_id` and
  `day_type_key` in submitted parameters are ignored; the caller sets those on the
  struct. The format is checked here and again by the named `run_id_format`
  constraint, and the day-type uniqueness is declared so a trip cannot sit in two
  runs on one day type.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(trip_run, attrs) do
    trip_run
    |> cast(attrs, [:run_id])
    |> validate_format(:run_id, @run_id_format,
      message: "must be one to eight letters, digits or hyphens"
    )
    |> unique_constraint([:organization_id, :gtfs_version_id, :day_type_key, :trip_id],
      name: @day_type_index
    )
    |> check_constraint(:run_id, name: :run_id_format)
  end
end
