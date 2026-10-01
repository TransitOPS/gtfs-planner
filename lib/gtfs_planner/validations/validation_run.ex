defmodule GtfsPlanner.Validations.ValidationRun do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @run_types ["mobility_data", "mobility_data_flex", "pathways_tests", "station_reachability"]
  @statuses ["pending", "started", "running", "completed", "failed"]

  @changeset_fields [
    :run_type,
    :status,
    :engine,
    :result_schema_version,
    :errors_count,
    :warnings_count,
    :infos_count,
    :duration_ms,
    :result_json,
    :error_details,
    :started_at,
    :completed_at
  ]
  @lease_fields [:lease_token, :lease_expires_at]

  @type run_type :: String.t()
  @type status :: String.t()

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          run_type: run_type(),
          status: status(),
          engine: String.t() | nil,
          result_schema_version: integer() | nil,
          errors_count: integer(),
          warnings_count: integer(),
          infos_count: integer(),
          duration_ms: integer() | nil,
          result_json: map() | nil,
          error_details: String.t() | nil,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          lease_token: Ecto.UUID.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "gtfs_validation_runs" do
    field :run_type, :string
    field :status, :string
    field :engine, :string
    field :result_schema_version, :integer
    field :errors_count, :integer, default: 0
    field :warnings_count, :integer, default: 0
    field :infos_count, :integer, default: 0
    field :duration_ms, :integer
    field :result_json, :map
    field :error_details, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :lease_token, :binary_id
    field :lease_expires_at, :utc_datetime_usec

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    has_many :walkability_test_run_results, GtfsPlanner.Validations.WalkabilityTestRunResult,
      foreign_key: :validation_run_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for validation runs.
  Note: organization_id and gtfs_version_id must be set programmatically, not cast.
  The lease fields are system-owned and are never cast here; use `system_changeset/2`.
  """
  def changeset(validation_run, attrs) do
    build_changeset(validation_run, attrs, @changeset_fields)
  end

  @doc """
  Changeset for server-side lifecycle transitions.

  Casts every field `changeset/2` casts plus `lease_token` and `lease_expires_at`.
  Pass only server-derived values; never pass request params.
  """
  @spec system_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def system_changeset(validation_run, attrs) do
    build_changeset(validation_run, attrs, @changeset_fields ++ @lease_fields)
  end

  defp build_changeset(validation_run, attrs, fields) do
    validation_run
    |> cast(attrs, fields)
    |> trim_string_fields()
    |> validate_required([:run_type, :status, :started_at])
    |> validate_inclusion(:run_type, @run_types)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:result_json,
      name: :gtfs_validation_runs_active_station_reachability_index
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
  end
end
