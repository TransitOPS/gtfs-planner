defmodule GtfsPlanner.Gtfs.RosterLineDay do
  @moduledoc """
  One day of a roster line working one run.

  A row says "on this weekday of this version, this line works run `run_id` of
  this day type", and stores the run's sign-on and sign-off as they were when
  the slot was set. Those stored times are what the rest and hours checks read;
  a mismatch with the run derived today marks the slot stale rather than
  rewriting it (INV-13).

  `roster_line_id`, `organization_id`, `gtfs_version_id`, `weekday` and
  `day_type_key` are set by the writer, not cast. `run_id` and the two times are
  the only cast fields, because they are the only ones a caller names.

  A run sits on at most one line per weekday across the organization and
  version, and a line has at most one row per weekday; both are database
  indexes, declared here so the refusal arrives on a field.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Gtfs.Runs.Numbering

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          roster_line_id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          weekday: 1..7,
          day_type_key: String.t(),
          run_id: String.t(),
          run_sign_on_secs: integer(),
          run_sign_off_secs: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "roster_line_days" do
    field :weekday, :integer
    field :day_type_key, :string
    field :run_id, :string
    field :run_sign_on_secs, :integer
    field :run_sign_off_secs, :integer

    belongs_to :roster_line, GtfsPlanner.Gtfs.RosterLine
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for one run-day.

  Casts and requires `run_id`, `run_sign_on_secs` and `run_sign_off_secs`, and
  checks the run ID with `Runs.Numbering.valid_run_id?/1` — the same predicate
  the numbering rules use, so a slot cannot store an ID a run could never have.
  The two unique constraints and the two check constraints are the database's
  own rules, declared so a rejection comes back on `:run_id` or `:weekday`
  rather than as a raised constraint error.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(roster_line_day, attrs) do
    roster_line_day
    |> cast(attrs, [:run_id, :run_sign_on_secs, :run_sign_off_secs])
    |> validate_required([:run_id, :run_sign_on_secs, :run_sign_off_secs])
    |> validate_change(:run_id, fn :run_id, run_id ->
      if Numbering.valid_run_id?(run_id) do
        []
      else
        [run_id: "must be one to eight letters, digits or hyphens"]
      end
    end)
    |> unique_constraint(:run_id, name: :roster_line_days_run_once_per_weekday)
    |> unique_constraint(:weekday, name: :roster_line_days_roster_line_id_weekday_index)
    |> check_constraint(:weekday, name: :weekday_range)
    |> check_constraint(:run_id, name: :run_id_format)
  end
end
