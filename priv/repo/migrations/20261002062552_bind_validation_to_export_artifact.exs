defmodule GtfsPlanner.Repo.Migrations.BindValidationToExportArtifact do
  use Ecto.Migration

  @binding_check "gtfs_validation_runs_artifact_binding_check"

  # A validation run that reviewed one selected export artifact records which
  # artifact it read: the verified SHA-256, the export run that produced the
  # bytes and the slot that named them. The binding is all-or-nothing, so a
  # database-export validation run keeps every column NULL and can never claim a
  # hash it did not compute.
  #
  # `artifact_export_run_id` is ON DELETE SET NULL on purpose. The reviewed hash
  # and the completed report stay on the row after the private source is removed,
  # so current status survives without a permanently restrictive source FK; only
  # the pointer to the private run is dropped.
  def change do
    alter table(:gtfs_validation_runs) do
      add :artifact_sha256, :string
      add :artifact_slot, :string
      # The lease credential this run holds on the private bytes, so a restart can
      # still renew or release the pin it acquired.
      add :artifact_pin_token, :binary_id

      add :artifact_export_run_id,
          references(:gtfs_export_runs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:gtfs_validation_runs, [:artifact_export_run_id])

    create constraint(:gtfs_validation_runs, @binding_check,
             check: """
             (artifact_sha256 IS NULL AND artifact_slot IS NULL AND artifact_export_run_id IS NULL)
             OR (artifact_sha256 IS NOT NULL
                 AND artifact_slot IN ('main', 'flex')
                 AND artifact_export_run_id IS NOT NULL)
             """
           )
  end
end
