defmodule GtfsPlanner.Repo.Migrations.CreateGtfsChangeRuns do
  use Ecto.Migration

  @state_check "gtfs_change_runs_state_check"
  @lease_check "gtfs_change_runs_lease_check"
  @timestamp_check "gtfs_change_runs_timestamp_check"
  @progress_check "gtfs_change_runs_progress_check"
  @organization_version_fkey "gtfs_change_runs_organization_version_fkey"
  @version_scope_index "gtfs_versions_organization_id_id_index"

  def up do
    create unique_index(:gtfs_versions, [:organization_id, :id], name: @version_scope_index)

    create table(:gtfs_change_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false, default: "station_diff"
      add :state, :string, null: false, default: "pending_compute"
      add :phase, :string
      add :progress_current, :integer
      add :progress_total, :integer
      add :summary, :map, null: false, default: %{}
      add :diagnostics, {:array, :map}, null: false, default: []
      add :source_manifest, :map, null: false, default: %{}
      add :serializer_version, :integer, null: false, default: 1
      add :lease_generation, :integer, null: false, default: 0
      add :lease_token, :binary_id
      add :lease_expires_at, :utc_datetime_usec
      add :cancel_requested_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :failure_code, :string
      add :actor_id, :binary_id
      add :actor_email, :string

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    ALTER TABLE #{qualified_table(:gtfs_change_runs)}
    ADD CONSTRAINT #{@organization_version_fkey}
    FOREIGN KEY (organization_id, gtfs_version_id)
    REFERENCES #{qualified_table(:gtfs_versions)} (organization_id, id)
    ON DELETE CASCADE
    """)

    create table(:gtfs_change_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :decision_id, :string, null: false
      add :entity_type, :string, null: false
      add :action, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :natural_key, :string, null: false
      add :current_values, :map, null: false, default: %{}
      add :uploaded_values, :map, null: false, default: %{}
      add :changed_fields, {:array, :map}, null: false, default: []
      add :dependency_keys, {:array, :string}, null: false, default: []
      add :current_fingerprint, :string
      add :user_edited, :boolean, null: false, default: false
      add :apply_failure_code, :string
      add :applied_at, :utc_datetime_usec

      add :change_run_id, references(:gtfs_change_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gtfs_change_runs, [:organization_id, :gtfs_version_id, :state],
             name: :gtfs_change_runs_org_version_state_index
           )

    create unique_index(:gtfs_change_runs, [:organization_id, :gtfs_version_id],
             where:
               "state NOT IN ('partial', 'completed', 'failed', 'interrupted', 'cancelled', 'expired')",
             name: :gtfs_change_runs_one_nonterminal_per_scope_index
           )

    create unique_index(:gtfs_change_decisions, [:change_run_id, :decision_id],
             name: :gtfs_change_decisions_change_run_decision_id_index
           )

    create index(:gtfs_change_decisions, [:change_run_id, :status, :action],
             name: :gtfs_change_decisions_run_status_action_index
           )

    create constraint(:gtfs_change_runs, @state_check,
             check:
               "kind = 'station_diff' AND state = ANY(ARRAY['pending_compute','computing','review','pending_apply','applying','partial','completed','failed','interrupted','cancelled','expired']::text[]) AND (phase IS NULL OR phase = ANY(ARRAY['staging','parsing','diffing','preflight','applying','cleanup']::text[]))"
           )

    create constraint(:gtfs_change_runs, @lease_check,
             check:
               "((state IN ('computing','applying') AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL) OR (state NOT IN ('computing','applying') AND lease_token IS NULL AND lease_expires_at IS NULL)) AND lease_generation >= 0"
           )

    create constraint(:gtfs_change_runs, @timestamp_check,
             check:
               "((state = 'pending_compute' AND started_at IS NULL AND finished_at IS NULL) OR (state IN ('computing','review','pending_apply','applying') AND started_at IS NOT NULL AND finished_at IS NULL) OR (state IN ('partial','completed','failed','interrupted','cancelled','expired') AND started_at IS NOT NULL AND finished_at IS NOT NULL))"
           )

    create constraint(:gtfs_change_runs, @progress_check,
             check:
               "(progress_current IS NULL AND progress_total IS NULL) OR (progress_current IS NOT NULL AND progress_total IS NOT NULL AND progress_current >= 0 AND progress_total >= 0 AND progress_current <= progress_total)"
           )
  end

  def down do
    drop table(:gtfs_change_decisions)
    drop table(:gtfs_change_runs)
    drop index(:gtfs_versions, [:organization_id, :id], name: @version_scope_index)
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{schema}".#{table})
    end
  end
end
