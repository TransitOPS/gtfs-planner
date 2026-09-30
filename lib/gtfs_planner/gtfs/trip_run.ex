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
  #
  # This applies to `unique_constraint/3` only. A writer using
  # `Repo.insert_all` passes `conflict_target:` the four **columns**;
  # PostgreSQL's `ON CONFLICT (...)` resolves the index itself and does not
  # accept an index name there.
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
  Changeset for a run ID, with no row behind it.

  Renaming a run does not create or fetch a `TripRun` row — it changes the
  `run_id` of every row carrying the old one — so this is a schemaless
  changeset over one field, used by `GtfsPlanner.Gtfs.Runs.rename_run/5` to
  answer a rename form. Keeping the format here rather than in the writer means
  the regex that `changeset/2` checks a row against is the same one a rename is
  checked against, and cannot drift.

  The "already used in this day type" error is **not** here: whether an ID is
  taken is a fact about the rows, so the writer adds that error after reading
  them.
  """
  @spec change_run_id(map()) :: Ecto.Changeset.t()
  def change_run_id(attrs) do
    # The `{data, types}` form: a schemaless changeset still declares that
    # `run_id` is a string, so a non-string parameter is cast rather than stored.
    cast({%{}, %{run_id: :string}}, attrs, [:run_id])
    |> validate_run_id_format()
  end

  defp validate_run_id_format(changeset) do
    case fetch_change(changeset, :run_id) do
      {:ok, _run_id} ->
        validate_format(changeset, :run_id, @run_id_format,
          message: "must be one to eight letters, digits or hyphens"
        )

      # A field that was not submitted has nothing to check yet, and
      # `validate_format/4` raises rather than skipping on a missing value.
      :error ->
        changeset
    end
  end

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
