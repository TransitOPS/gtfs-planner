defmodule GtfsPlanner.Repo.Migrations.AddSavedSyncedAlignmentToStopLevels do
  use Ecto.Migration

  def change do
    alter table(:stop_levels) do
      add :saved_synced_alignment, :boolean, null: false, default: false
    end
  end
end
