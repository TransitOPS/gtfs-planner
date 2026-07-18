defmodule GtfsPlanner.Gtfs.Import.Run do
  @moduledoc """
  Durable, organization-scoped import-run audit row.

  A run outlives the `gtfs_versions` row it was created for: it retains a
  sanitized audit receipt (target identity, actor snapshot, committed counts,
  terminal outcome) even after the failed version is deleted during cleanup.
  `gtfs_version_id` is stored as a raw UUID (not a foreign key) so the immutable
  target identity survives cleanup, while `organization_id` keeps a foreign key
  with `on_delete: :delete_all` so removing a tenant removes its audit history.

  Lifecycle, lease, and timestamp fields are system-owned. They are never cast
  from user parameters; the `ImportRuns` context sets them explicitly. The only
  user-influenced surface is `committed_counts`, which is validated against a
  fixed allowlist of count keys and value constraints.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Gtfs.Import

  @states ~w(
    pending running failed partial interrupted publication_failed published
    cleaning cleanup_failed cleaned
  )

  @recoverable_states ~w(failed partial interrupted publication_failed cleaning cleanup_failed)
  @active_states ~w(pending running cleaning)

  @count_allowlist Import.supported_count_keys() ++
                    [
                      :extensions_stop_coordinates,
                      :extensions_stop_levels,
                      :extensions_route_flags,
                      :extensions_images
                    ]

  @state_check "gtfs_import_runs_state_check"
  @lease_check "gtfs_import_runs_lease_check"
  @finished_check "gtfs_import_runs_finished_at_check"
  @cleanup_started_check "gtfs_import_runs_cleanup_started_at_check"
  @cleanup_finished_check "gtfs_import_runs_cleanup_finished_at_check"
  @failed_row_check "gtfs_import_runs_failed_row_check"

  @version_name_max 255
  @reason_code_max 64
  @actor_email_max 255
  @phase_max 32

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          version_name: String.t(),
          state: String.t(),
          phase: String.t() | nil,
          committed_counts: map(),
          counts_complete: boolean(),
          failed_file: String.t() | nil,
          failed_row: integer() | nil,
          reason_code: String.t() | nil,
          lease_token: Ecto.UUID.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          cleanup_started_at: DateTime.t() | nil,
          cleanup_finished_at: DateTime.t() | nil,
          actor_id: Ecto.UUID.t() | nil,
          actor_email: String.t() | nil,
          cleanup_actor_id: Ecto.UUID.t() | nil,
          cleanup_actor_email: String.t() | nil,
          organization_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "gtfs_import_runs" do
    field :gtfs_version_id, :binary_id
    field :version_name, :string
    field :state, :string
    field :phase, :string
    field :committed_counts, :map, default: %{}
    field :counts_complete, :boolean, default: false
    field :failed_file, :string
    field :failed_row, :integer
    field :reason_code, :string
    field :lease_token, :binary_id
    field :lease_expires_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :cleanup_started_at, :utc_datetime_usec
    field :cleanup_finished_at, :utc_datetime_usec
    field :actor_id, :binary_id
    field :actor_email, :string
    field :cleanup_actor_id, :binary_id
    field :cleanup_actor_email, :string
    belongs_to :organization, Organization

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns all import-run states.
  """
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  Returns the states that remain recoverable (not yet terminally resolved).
  """
  @spec recoverable_states() :: [String.t()]
  def recoverable_states, do: @recoverable_states

  @doc """
  Returns the in-flight states that hold an active lease.
  """
  @spec active_states() :: [String.t()]
  def active_states, do: @active_states

  @doc """
  A system-owned changeset used by the `ImportRuns` context to set lifecycle,
  lease, and timestamp fields directly. User params are ignored for those
  columns; only `committed_counts` may be influenced by caller-supplied data,
  and it is validated against the fixed allowlist and value constraints.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :committed_counts,
      :counts_complete,
      :failed_file,
      :failed_row,
      :reason_code,
      :phase,
      :actor_email,
      :cleanup_actor_email
    ])
    |> validate_committed_counts()
    |> validate_length(:failed_file, max: @version_name_max)
    |> validate_failed_row()
    |> validate_length(:reason_code, max: @reason_code_max)
    |> validate_length(:phase, max: @phase_max)
    |> validate_length(:actor_email, max: @actor_email_max)
    |> validate_length(:cleanup_actor_email, max: @actor_email_max)
    |> check_constraint(:state, name: @state_check, message: "is not a valid import-run state")
    |> check_constraint(:lease_token,
      name: @lease_check,
      message: "lease must be present for active states and absent otherwise"
    )
    |> check_constraint(:finished_at,
      name: @finished_check,
      message: "finished_at is required for terminal import outcomes only"
    )
    |> check_constraint(:cleanup_started_at,
      name: @cleanup_started_check,
      message: "cleanup_started_at is required for cleanup states only"
    )
    |> check_constraint(:cleanup_finished_at,
      name: @cleanup_finished_check,
      message: "cleanup_finished_at is allowed only on the cleaned state"
    )
    |> check_constraint(:failed_row,
      name: @failed_row_check,
      message: "failed_row, when present, must be positive"
    )
  end

  @doc """
  The fully system-owned changeset used by `ImportRuns` for every coupled
  transition. It casts the lifecycle/lease/timestamp/actor fields directly
  (these are never user-cast) alongside the caller-influenced count/audit
  fields, and re-applies every database check constraint so an invalid state /
  lease / timestamp pairing is rejected at the serializer rather than only at
  the database.
  """
  @spec system_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def system_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :state,
      :phase,
      :committed_counts,
      :counts_complete,
      :failed_file,
      :failed_row,
      :reason_code,
      :lease_token,
      :lease_expires_at,
      :started_at,
      :finished_at,
      :cleanup_started_at,
      :cleanup_finished_at,
      :actor_id,
      :actor_email,
      :cleanup_actor_id,
      :cleanup_actor_email
    ])
    |> validate_committed_counts()
    |> validate_length(:failed_file, max: @version_name_max)
    |> validate_failed_row()
    |> validate_length(:reason_code, max: @reason_code_max)
    |> validate_length(:phase, max: @phase_max)
    |> validate_length(:actor_email, max: @actor_email_max)
    |> validate_length(:cleanup_actor_email, max: @actor_email_max)
    |> check_constraint(:state, name: @state_check, message: "is not a valid import-run state")
    |> check_constraint(:lease_token,
      name: @lease_check,
      message: "lease must be present for active states and absent otherwise"
    )
    |> check_constraint(:finished_at,
      name: @finished_check,
      message: "finished_at is required for terminal import outcomes only"
    )
    |> check_constraint(:cleanup_started_at,
      name: @cleanup_started_check,
      message: "cleanup_started_at is required for cleanup states only"
    )
    |> check_constraint(:cleanup_finished_at,
      name: @cleanup_finished_check,
      message: "cleanup_finished_at is allowed only on the cleaned state"
    )
    |> check_constraint(:failed_row,
      name: @failed_row_check,
      message: "failed_row, when present, must be positive"
    )
  end

  defp validate_failed_row(changeset) do
    case get_change(changeset, :failed_row) do
      nil -> changeset
      row when is_integer(row) and row > 0 -> changeset
      row when is_integer(row) -> add_error(changeset, :failed_row, "must be positive")
      _other -> add_error(changeset, :failed_row, "must be an integer")
    end
  end

  defp validate_committed_counts(changeset) do
    case get_change(changeset, :committed_counts) do
      nil ->
        changeset

      counts when is_map(counts) ->
        counts = normalize_count_keys(counts)

        changeset
        |> validate_count_keys(counts)
        |> validate_count_values(counts)

      _other ->
        add_error(changeset, :committed_counts, "must be a map")
    end
  end

  # PostgreSQL JSONB round-trips atom keys back as strings. Normalize any
  # string key that matches an allowlisted atom key back to its atom form so a
  # reloaded run (with string-key counts) still validates and persists cleanly.
  defp normalize_count_keys(counts) do
    Enum.reduce(counts, %{}, fn
      {key, value}, acc when is_binary(key) ->
        case Enum.find(@count_allowlist, &Atom.to_string(&1) == key) do
          nil -> Map.put(acc, key, value)
          atom_key -> Map.put(acc, atom_key, value)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp validate_count_keys(changeset, counts) do
    invalid =
      counts
      |> Map.keys()
      |> Enum.reject(&(&1 in @count_allowlist))

    case invalid do
      [] -> changeset
      _ -> add_error(changeset, :committed_counts, "contains unsupported key(s)")
    end
  end

  defp validate_count_values(changeset, counts) do
    negative =
      Enum.any?(counts, fn {_k, v} -> not is_integer(v) or v < 0 end)

    if negative do
      add_error(changeset, :committed_counts, "values must be non-negative integers")
    else
      changeset
    end
  end
end
