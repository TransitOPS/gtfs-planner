defmodule GtfsPlanner.Repo.Migrations.CreateJournalEntries do
  use Ecto.Migration

  def change do
    create table(:journal_entries, primary_key: false) do
      # Client-generated UUID — stable across offline capture → sync, and the
      # upsert key (no autogenerate).
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id,
          references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      # The parent station the entry belongs to (every journal endpoint is
      # station-scoped); used to gather a station's journal for the bundle.
      add :station_id,
          references(:stops, type: :binary_id, on_delete: :delete_all),
          null: false

      # Polymorphic target (change_logs.entity_type/entity_id precedent):
      # "station" (target_id null) | "node" | "pathway". "pin" + its diagram
      # coordinate columns are added by a later migration.
      add :target_type, :string, null: false
      add :target_id, :binary_id

      add :body, :text
      # Author as a plain id (the change_logs.actor_id precedent) — no FK, so a
      # user deletion never cascades into or nulls journal history.
      add :author_id, :binary_id, null: false
      add :captured_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :closed_by, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    # Bundle gathers a station's entries by (org, version, station).
    create index(:journal_entries, [:organization_id, :gtfs_version_id, :station_id])
    # Group node/pathway entries onto their target during serialization.
    create index(:journal_entries, [:target_type, :target_id])
  end
end
