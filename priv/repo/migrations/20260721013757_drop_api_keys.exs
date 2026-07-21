defmodule GtfsPlanner.Repo.Migrations.DropApiKeys do
  @moduledoc """
  Drops the retired `api_keys` table after all runtime readers were removed.

  ## Release checkpoint (required before production `up`)

  1. Deploy reader-free application code (no `ApiKeyAuth`, org-key LiveView, or
     Organizations API-key context callers) and drain old BEAM tasks / release
     instances that still load the previous code, **or** stop all application
     tasks for a declared maintenance window so no process can call the retired
     API-key path during the migration.
  2. Take a pre-migration database backup if any historical key rows must remain
     recoverable as opaque data. This migration permanently deletes table rows.
  3. Run `GtfsPlanner.Release.migrate/0` (or the platform equivalent that invokes
     `Ecto.Migrator.run(repo, :up, all: true)`).

  ## Rollback semantics

  `down/0` recreates the historical empty table structure only. It does **not**
  restore rows, descriptions, secret hashes, roles, or usable credentials.
  """

  use Ecto.Migration

  def up do
    drop table(:api_keys)
  end

  def down do
    # Structural recreate matching 20251223034107_create_api_keys.exs.
    # Empty structure only — no data or credentials are restored.
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :description, :string, null: false
      add :roles, {:array, :string}, default: "{}"
      add :version, :integer, default: 1
      add :secret_hash, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
