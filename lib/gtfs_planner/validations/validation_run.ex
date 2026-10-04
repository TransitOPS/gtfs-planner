defmodule GtfsPlanner.Validations.ValidationRun do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `mobility_data_artifact` is the MobilityData validator run over the exact
  # bytes of one selected export artifact, not over current database state, so it
  # is never a feed check of the version.
  @run_types [
    "mobility_data",
    "mobility_data_flex",
    "mobility_data_artifact",
    "pathways_tests",
    "station_reachability"
  ]
  @statuses ["pending", "started", "running", "completed", "failed"]
  @artifact_slots [:main, :flex]

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
  # Server-owned: written only by `Validations.start_artifact_run/3` from the
  # verified pin, never from request params.
  @artifact_fields [
    :artifact_sha256,
    :artifact_slot,
    :artifact_export_run_id,
    :artifact_pin_token
  ]

  # Server-owned provenance of the exact checked input. Cast only by system_changeset/2;
  # these stay nil for every run that did not capture them (all retained rows).
  @provenance_fields [:checked_zip_sha256, :checked_export_profile, :validator_version]

  @sha256_format ~r/^[0-9a-f]{64}$/
  @max_validator_version_bytes 128
  @profile_keys [:schema_version, :export_type, :include_flex, :artifact_kind, :estimate_method]
  @profile_export_types ["full", "pathways", "operations"]
  @profile_artifact_kinds ["primary", "flex"]
  @profile_estimate_methods [nil, "distance", "even"]

  @type run_type :: String.t()
  @type status :: String.t()
  @type artifact_slot :: :main | :flex

  @typedoc """
  The checked export the run was validated against, written with atom keys and
  read back from jsonb with the equivalent string keys. Unknown provenance is nil
  rather than a guessed profile.
  """
  @type checked_export_profile :: %{
          schema_version: 1,
          export_type: String.t(),
          include_flex: boolean(),
          artifact_kind: String.t(),
          estimate_method: String.t() | nil
        }

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
          artifact_sha256: String.t() | nil,
          artifact_slot: artifact_slot() | nil,
          artifact_export_run_id: Ecto.UUID.t() | nil,
          artifact_pin_token: Ecto.UUID.t() | nil,
          checked_zip_sha256: String.t() | nil,
          checked_export_profile: checked_export_profile() | nil,
          validator_version: String.t() | nil,
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
    field :artifact_sha256, :string
    field :artifact_slot, Ecto.Enum, values: @artifact_slots
    field :artifact_export_run_id, Ecto.UUID
    field :artifact_pin_token, Ecto.UUID
    field :checked_zip_sha256, :string
    field :checked_export_profile, :map
    field :validator_version, :string

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

  Casts every field `changeset/2` casts plus `lease_token`, `lease_expires_at`,
  the artifact binding and the checked-input provenance fields. Pass only
  server-derived values; never pass request params. Provenance is validated when
  present: a lowercase 64-character hex SHA-256 digest, a validator version of at
  most 128 UTF-8 bytes, and an export profile carrying exactly `schema_version`,
  `export_type`, `include_flex`, `artifact_kind` and `estimate_method`.
  """
  @spec system_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def system_changeset(validation_run, attrs) do
    build_changeset(
      validation_run,
      attrs,
      @changeset_fields ++ @lease_fields ++ @artifact_fields ++ @provenance_fields
    )
    |> validate_provenance()
  end

  @doc """
  Whether this run reviewed one selected export artifact rather than the version's
  current database state.
  """
  @spec artifact_run?(t()) :: boolean()
  def artifact_run?(%__MODULE__{artifact_export_run_id: nil}), do: false
  def artifact_run?(%__MODULE__{}), do: true

  defp build_changeset(validation_run, attrs, fields) do
    validation_run
    |> cast(attrs, fields)
    |> trim_string_fields()
    |> validate_required([:run_type, :status, :started_at])
    |> validate_inclusion(:run_type, @run_types)
    |> validate_inclusion(:status, @statuses)
    |> check_artifact_binding()
    |> unique_constraint(:result_json,
      name: :gtfs_validation_runs_active_station_reachability_index
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
    |> foreign_key_constraint(:artifact_export_run_id)
  end

  # The same all-or-nothing rule the migration's check constraint enforces, so a
  # partial binding is refused as a changeset rather than as a constraint error.
  defp check_artifact_binding(changeset) do
    bound =
      Enum.count(
        [
          get_field(changeset, :artifact_sha256),
          get_field(changeset, :artifact_slot),
          get_field(changeset, :artifact_export_run_id)
        ],
        &(not is_nil(&1))
      )

    if bound in [0, 3],
      do: changeset,
      else: add_error(changeset, :artifact_sha256, "incomplete artifact binding")
  end

  defp validate_provenance(changeset) do
    changeset
    |> validate_format(:checked_zip_sha256, @sha256_format,
      message: "must be a lowercase 64-character hex SHA-256 digest"
    )
    |> validate_change(:validator_version, fn :validator_version, value ->
      if byte_size(value) <= @max_validator_version_bytes,
        do: [],
        else: [validator_version: "must be at most 128 bytes"]
    end)
    |> validate_change(:checked_export_profile, fn :checked_export_profile, profile ->
      profile_errors(profile)
    end)
  end

  defp profile_errors(profile) when is_map(profile) and not is_struct(profile) do
    cond do
      Enum.sort(Map.keys(profile)) != Enum.sort(@profile_keys) ->
        [
          {:checked_export_profile,
           "must contain exactly schema_version, export_type, include_flex, artifact_kind and estimate_method"}
        ]

      profile.schema_version != 1 ->
        [{:checked_export_profile, "must record schema_version 1"}]

      profile.export_type not in @profile_export_types ->
        [{:checked_export_profile, "must record export_type full, pathways or operations"}]

      not is_boolean(profile.include_flex) ->
        [{:checked_export_profile, "must record include_flex as true or false"}]

      profile.artifact_kind not in @profile_artifact_kinds ->
        [{:checked_export_profile, "must record artifact_kind primary or flex"}]

      profile.estimate_method not in @profile_estimate_methods ->
        [{:checked_export_profile, "must record estimate_method nil, distance or even"}]

      true ->
        []
    end
  end

  defp profile_errors(_profile),
    do: [{:checked_export_profile, "must be a map of checked export settings"}]
end
