defmodule GtfsPlanner.Repo.Migrations.CreateGtfsImportRuns do
  use Ecto.Migration

  @state_check "gtfs_import_runs_state_check"
  @lease_check "gtfs_import_runs_lease_check"
  @finished_check "gtfs_import_runs_finished_at_check"
  @cleanup_started_check "gtfs_import_runs_cleanup_started_at_check"
  @cleanup_finished_check "gtfs_import_runs_cleanup_finished_at_check"
  @failed_row_check "gtfs_import_runs_failed_row_check"

  def change do
    create table(:gtfs_import_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Raw target identity (no FK) so the immutable audit receipt survives
      # cleanup of the owning gtfs_versions row.
      add :gtfs_version_id, :binary_id, null: false
      add :version_name, :string, null: false

      add :state, :string, null: false, default: "pending"
      add :phase, :string

      # Bounded JSON detail. Only the allowed count keys may appear.
      add :committed_counts, :map, null: false, default: %{}
      add :counts_complete, :boolean, null: false, default: false

      # Sanitized failure receipt (no source row contents / raw errors).
      add :failed_file, :string
      add :failed_row, :integer
      add :reason_code, :string

      # Lease ownership. Both must be present together or both nil.
      add :lease_token, :binary_id
      add :lease_expires_at, :utc_datetime_usec

      # Workflow timestamps.
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :cleanup_started_at, :utc_datetime_usec
      add :cleanup_finished_at, :utc_datetime_usec

      # Actor snapshots retained after target deletion.
      add :actor_id, :binary_id
      add :actor_email, :string
      add :cleanup_actor_id, :binary_id
      add :cleanup_actor_email, :string

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gtfs_import_runs, [:gtfs_version_id],
             name: :gtfs_import_runs_gtfs_version_id_index
           )

    create index(:gtfs_import_runs, [:organization_id, :state, :updated_at],
             name: :gtfs_import_runs_org_state_updated_at_index
           )

    create constraint(:gtfs_import_runs, @state_check,
             check:
               "state = ANY(ARRAY['pending','running','failed','partial','interrupted','publication_failed','published','cleaning','cleanup_failed','cleaned']::text[])",
             comment: "run state must be one of the documented import-run states"
           )

    # Paired lease: both lease_token and lease_expires_at present for the active
    # lease states (pending/running/cleaning); both nil for every other state.
    create constraint(:gtfs_import_runs, @lease_check,
             check: """
             (
               (state IN ('pending','running','cleaning') AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
               OR
               (state NOT IN ('pending','running','cleaning') AND lease_token IS NULL AND lease_expires_at IS NULL)
             )
             """,
             comment: "active states require a lease; terminal/idle states must not carry one"
           )

    # finished_at required for every terminal import outcome (i.e. every state
    # except the in-flight pending/running/cleaning states).
    create constraint(:gtfs_import_runs, @finished_check,
             check: """
             (
               (state IN ('pending','running','cleaning') AND finished_at IS NULL)
               OR
               (state NOT IN ('pending','running','cleaning') AND finished_at IS NOT NULL)
             )
             """,
             comment: "finished_at is required for terminal import outcomes only"
           )

    # cleanup_started_at required for the cleanup states (cleaning, cleanup_failed,
    # cleaned); nil for every other state.
    create constraint(:gtfs_import_runs, @cleanup_started_check,
             check: """
             (
               (state IN ('cleaning','cleanup_failed','cleaned') AND cleanup_started_at IS NOT NULL)
               OR
               (state NOT IN ('cleaning','cleanup_failed','cleaned') AND cleanup_started_at IS NULL)
             )
             """,
             comment: "cleanup_started_at is required for cleanup states only"
           )

    # Only the cleaned terminal state may carry cleanup_finished_at.
    create constraint(:gtfs_import_runs, @cleanup_finished_check,
             check: """
             (
               (state = 'cleaned' AND cleanup_finished_at IS NOT NULL)
               OR
               (state <> 'cleaned' AND cleanup_finished_at IS NULL)
             )
             """,
             comment: "cleanup_finished_at is allowed only on the cleaned state"
           )

    # committed_counts non-negativity and failed_row positivity are enforced by
    # the Run schema changeset serializer (and context tests). PostgreSQL cannot
    # walk a JSON map inside a CHECK constraint, so value bounds are validated in
    # Elixir; the column itself is NOT NULL with a %{} default at the table level.
    create constraint(:gtfs_import_runs, @failed_row_check,
             check: "failed_row IS NULL OR failed_row > 0",
             comment: "failed_row, when present, must be a positive integer"
           )
  end
end
