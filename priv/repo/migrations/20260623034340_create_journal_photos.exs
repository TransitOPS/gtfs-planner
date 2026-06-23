defmodule GtfsPlanner.Repo.Migrations.CreateJournalPhotos do
  use Ecto.Migration

  def change do
    create table(:journal_photos, primary_key: false) do
      # Client-generated UUID — the upload idempotency key.
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id,
          references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :journal_entry_id,
          references(:journal_entries, type: :binary_id, on_delete: :delete_all),
          null: false

      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer
      add :width, :integer
      add :height, :integer
      add :captured_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:journal_photos, [:journal_entry_id])
    create index(:journal_photos, [:organization_id, :gtfs_version_id])
  end
end
