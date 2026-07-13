defmodule GtfsPlanner.Repo.Migrations.CreateJournalEntries do
  use Ecto.Migration

  def change do
    create table(:journal_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :gtfs_version_id,
          references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :station_id, references(:stops, type: :binary_id, on_delete: :delete_all), null: false
      add :author_id, :binary_id, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id
      add :stop_level_id, :binary_id
      add :diagram_x, :float
      add :diagram_y, :float
      add :body, :text
      add :captured_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :closed_by, :binary_id
      add :lat, :float
      add :lon, :float

      timestamps(type: :utc_datetime_usec)
    end

    create index(:journal_entries, [:organization_id, :gtfs_version_id, :station_id],
             name: :journal_entries_station_scope_index
           )

    create index(:journal_entries, [:station_id, :target_type, :target_id],
             name: :journal_entries_target_index
           )

    create index(:journal_entries, [:station_id, :stop_level_id],
             name: :journal_entries_stop_level_index
           )

    create constraint(:journal_entries, :journal_entries_target_shape_ck,
             check: """
             (target_type = 'station' AND target_id IS NULL AND stop_level_id IS NULL AND diagram_x IS NULL AND diagram_y IS NULL)
             OR (target_type IN ('node', 'pathway') AND target_id IS NOT NULL AND stop_level_id IS NULL AND diagram_x IS NULL AND diagram_y IS NULL)
             OR (target_type = 'pin' AND target_id IS NULL AND stop_level_id IS NOT NULL
                 AND diagram_x IS NOT NULL AND diagram_y IS NOT NULL
                 AND diagram_x >= 0 AND diagram_y >= 0
                 AND diagram_x <> 'NaN'::double precision AND diagram_y <> 'NaN'::double precision
                 AND diagram_x <> 'Infinity'::double precision AND diagram_y <> 'Infinity'::double precision)
             """
           )

    create constraint(:journal_entries, :journal_entries_closure_pair_ck,
             check: "(closed_at IS NULL) = (closed_by IS NULL)"
           )
  end
end
