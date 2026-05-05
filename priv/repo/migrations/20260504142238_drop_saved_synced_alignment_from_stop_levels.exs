defmodule GtfsPlanner.Repo.Migrations.DropSavedSyncedAlignmentFromStopLevels do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE stop_levels DROP COLUMN IF EXISTS saved_synced_alignment")
  end

  def down do
    execute("ALTER TABLE stop_levels ADD COLUMN IF NOT EXISTS saved_synced_alignment boolean DEFAULT false NOT NULL")
  end
end
