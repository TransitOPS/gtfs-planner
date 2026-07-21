defmodule GtfsPlanner.Repo.Migrations.CreateGtfsExportRuns do
  use Ecto.Migration

  @state_check "gtfs_export_runs_state_check"
  @lease_check "gtfs_export_runs_lease_check"
  @artifact_check "gtfs_export_runs_artifact_check"
  @timestamp_check "gtfs_export_runs_timestamp_check"
  @progress_check "gtfs_export_runs_progress_check"
  @download_claim_check "gtfs_export_runs_download_claim_check"
  @organization_version_fkey "gtfs_export_runs_organization_version_fkey"
  def up do
    create table(:gtfs_export_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :export_type, :string, null: false, default: "full"
      add :state, :string, null: false, default: "pending"
      add :phase, :string
      add :progress_current, :integer
      add :progress_total, :integer
      add :warnings, {:array, :map}, null: false, default: []
      add :failure_code, :string
      add :lease_generation, :integer, null: false, default: 0
      add :lease_token, :binary_id
      add :lease_expires_at, :utc_datetime_usec
      add :artifact_key, :string
      add :artifact_filename, :string
      add :artifact_sha256, :string
      add :artifact_size_bytes, :integer
      add :artifact_expires_at, :utc_datetime_usec
      add :download_claimed_until, :utc_datetime_usec
      add :download_count, :integer, null: false, default: 0
      add :last_downloaded_at, :utc_datetime_usec
      add :cancel_requested_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :actor_id, :binary_id
      add :actor_email, :string

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :version_name, :string
      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    ALTER TABLE #{qualified_table(:gtfs_export_runs)}
    ADD CONSTRAINT #{@organization_version_fkey}
    FOREIGN KEY (organization_id, gtfs_version_id)
    REFERENCES #{qualified_table(:gtfs_versions)} (organization_id, id)
    ON DELETE CASCADE
    """)

    create index(:gtfs_export_runs, [:organization_id, :gtfs_version_id, :state],
             name: :gtfs_export_runs_org_version_state_index
           )

    create unique_index(:gtfs_export_runs, [:organization_id, :gtfs_version_id, :export_type],
             where: "state IN ('pending', 'building')",
             name: :gtfs_export_runs_one_active_per_scope_type_index
           )

    create constraint(:gtfs_export_runs, @state_check,
             check:
               "export_type = ANY(ARRAY['full','pathways']::text[]) AND state = ANY(ARRAY['pending','building','ready','failed','interrupted','cancelled','expired']::text[]) AND (phase IS NULL OR phase = ANY(ARRAY['preflight','packaging','publishing','cleanup']::text[]))"
           )

    create constraint(:gtfs_export_runs, @lease_check,
             check:
               "((state = 'building' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL) OR (state <> 'building' AND lease_token IS NULL AND lease_expires_at IS NULL)) AND lease_generation >= 0"
           )

    create constraint(:gtfs_export_runs, @artifact_check,
             check:
               "(artifact_size_bytes IS NULL OR artifact_size_bytes >= 0) AND ((state = 'ready' AND artifact_key IS NOT NULL AND artifact_filename IS NOT NULL AND artifact_sha256 ~ '^[0-9a-f]{64}$' AND artifact_size_bytes IS NOT NULL AND artifact_expires_at IS NOT NULL) OR (state <> 'ready' AND artifact_key IS NULL AND artifact_filename IS NULL AND artifact_sha256 IS NULL AND artifact_size_bytes IS NULL AND artifact_expires_at IS NULL))"
           )

    create constraint(:gtfs_export_runs, @timestamp_check,
             check:
               "((state = 'pending' AND started_at IS NULL AND finished_at IS NULL) OR (state = 'building' AND started_at IS NOT NULL AND finished_at IS NULL) OR (state IN ('ready','failed','interrupted','cancelled','expired') AND started_at IS NOT NULL AND finished_at IS NOT NULL))"
           )

    create constraint(:gtfs_export_runs, @progress_check,
             check:
               "(progress_current IS NULL AND progress_total IS NULL) OR (progress_current IS NOT NULL AND progress_total IS NOT NULL AND progress_current >= 0 AND progress_total >= 0 AND progress_current <= progress_total)"
           )

    create constraint(:gtfs_export_runs, @download_claim_check,
             check:
               "download_count >= 0 AND (download_claimed_until IS NULL OR (state = 'ready' AND artifact_key IS NOT NULL AND artifact_expires_at IS NOT NULL))"
           )
  end

  def down do
    drop table(:gtfs_export_runs)
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{schema}".#{table})
    end
  end
end
