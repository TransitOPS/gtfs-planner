defmodule GtfsPlanner.Gtfs.RosterLine do
  @moduledoc """
  One weekly bid line of one GTFS version.

  A line is one week that repeats: it has a `line_number` and, through
  `RosterLineDay` rows, at most one run per weekday. A day off is the absence of
  a day row, so there is nothing to store for one.

  `organization_id`, `gtfs_version_id`, `line_number` and `operator_id` are set
  by the writer — `GtfsPlanner.Gtfs.Rosters` — on the struct or with
  `Ecto.Changeset.change/3`, never from submitted parameters, so `changeset/2`
  casts nothing. What the changeset does declare is the database's own rules: a
  line number once per version, an operator holding at most one line per
  version, and an operator that exists in the line's organization. A line whose
  operator was deleted keeps its row with a nil `operator_id` and shows Open.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          line_number: pos_integer(),
          operator_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "roster_lines" do
    field :line_number, :integer

    belongs_to :operator, GtfsPlanner.Operations.Operator
    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    has_many :days, GtfsPlanner.Gtfs.RosterLineDay

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for a line, casting nothing.

  Every field is set programmatically by the writer, so there is nothing here to
  cast; the declarations map the database's rejections to fields, so
  `Rosters.create_line/1` and `Rosters.assign_operator/3` can read a refusal off
  the line it belongs to instead of reporting a bare constraint error.

  An operator foreign key can refuse under either of two names: the
  single-column key, and the organization-scoped one that also refuses another
  organization's operator. Both are declared because an operator deleted between
  a lookup and the write breaks both, and PostgreSQL reports whichever it checks
  first.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(roster_line, _attrs) do
    roster_line
    # `change/3` makes a struct and a changeset equally acceptable: there is
    # nothing to cast, so the caller's struct is already the row.
    |> change(%{})
    |> unique_constraint(:line_number,
      name: :roster_lines_organization_id_gtfs_version_id_line_number_index
    )
    |> unique_constraint(:operator_id, name: :roster_lines_one_line_per_operator)
    |> foreign_key_constraint(:operator_id)
    |> foreign_key_constraint(:operator_id, name: :roster_lines_operator_id_owner_fkey)
    |> check_constraint(:line_number, name: :line_number_positive)
  end
end
