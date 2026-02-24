defmodule GtfsPlanner.Repo.Migrations.CreateOtpGtfsArtifacts do
  use Ecto.Migration

  def change do
    create table(:otp_gtfs_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :zip_path, :string, null: false
      add :content_hash, :string, null: false
      add :file_size_bytes, :integer, null: false
      add :manifest_json, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:otp_gtfs_artifacts, [:organization_id, :gtfs_version_id],
             name: :otp_gtfs_artifacts_org_version_unique_index
           )
  end
end
