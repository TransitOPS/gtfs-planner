defmodule GtfsPlanner.Repo.Migrations.AddPinTargetToJournalEntries do
  use Ecto.Migration

  def change do
    # A "pin" entry is anchored to an arbitrary point on a level (no separate
    # pin entity): its canonical anchor is the diagram coordinate (like a node's),
    # and lat/lon is optional enrichment imputed at level-alignment time (null on
    # unaligned levels).
    alter table(:journal_entries) do
      add :stop_level_id, references(:stop_levels, type: :binary_id, on_delete: :delete_all)
      add :diagram_x, :float
      add :diagram_y, :float
      add :lat, :float
      add :lon, :float
    end

    create index(:journal_entries, [:stop_level_id])
  end
end
