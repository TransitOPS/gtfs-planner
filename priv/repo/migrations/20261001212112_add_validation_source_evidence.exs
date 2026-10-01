defmodule GtfsPlanner.Repo.Migrations.AddValidationSourceEvidence do
  use Ecto.Migration

  # All three provenance columns are nullable with no default, so the add is a
  # catalog-only change: retained rows and their stored report JSON are left byte
  # identical with unknown provenance, and nothing is backfilled.
  def change do
    alter table(:gtfs_validation_runs) do
      add :checked_zip_sha256, :string
      add :checked_export_profile, :map
      add :validator_version, :string
    end
  end
end
