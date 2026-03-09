defmodule GtfsPlanner.Validations.ValidationRun do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @run_types ["mobility_data", "pathways_tests", "station_reachability"]
  @statuses ["pending", "started", "running", "completed", "failed"]

  @type run_type :: String.t()
  @type status :: String.t()

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          run_type: run_type(),
          status: status(),
          errors_count: integer(),
          warnings_count: integer(),
          infos_count: integer(),
          duration_ms: integer() | nil,
          result_json: map() | nil,
          error_details: String.t() | nil,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "gtfs_validation_runs" do
    field :run_type, :string
    field :status, :string
    field :errors_count, :integer, default: 0
    field :warnings_count, :integer, default: 0
    field :infos_count, :integer, default: 0
    field :duration_ms, :integer
    field :result_json, :map
    field :error_details, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    has_many :walkability_test_run_results, GtfsPlanner.Validations.WalkabilityTestRunResult,
      foreign_key: :validation_run_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for validation runs.
  Note: organization_id and gtfs_version_id must be set programmatically, not cast.
  """
  def changeset(validation_run, attrs) do
    validation_run
    |> cast(attrs, [
      :run_type,
      :status,
      :errors_count,
      :warnings_count,
      :infos_count,
      :duration_ms,
      :result_json,
      :error_details,
      :started_at,
      :completed_at
    ])
    |> validate_required([:run_type, :status, :started_at])
    |> validate_inclusion(:run_type, @run_types)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
  end
end
