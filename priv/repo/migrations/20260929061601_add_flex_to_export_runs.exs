defmodule GtfsPlanner.Repo.Migrations.AddFlexToExportRuns do
  use Ecto.Migration

  def change do
    alter table(:gtfs_export_runs) do
      add :include_flex, :boolean, null: false, default: false
      add :flex_artifact_key, :string
      add :flex_artifact_filename, :string
      add :flex_artifact_sha256, :string
      add :flex_artifact_size_bytes, :integer
    end
  end
end
