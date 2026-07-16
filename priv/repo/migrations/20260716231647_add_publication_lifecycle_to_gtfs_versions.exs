defmodule GtfsPlanner.Repo.Migrations.AddPublicationLifecycleToGtfsVersions do
  use Ecto.Migration

  @status_check "gtfs_versions_publication_status_check"
  @state_timestamp_check "gtfs_versions_publication_state_timestamp_check"
  @index_name "gtfs_versions_org_status_published_at_index"

  # This migration must stay compatible with the old release that keeps running
  # during a migrate-before-replace deployment. It expands the schema in a
  # backward-compatible order:
  #
  #   1. Add both lifecycle columns as nullable so the old release keeps working.
  #   2. Backfill existing rows to a valid published pair (published_at =
  #      inserted_at), preserving latest ordering.
  #   3. Install paired database defaults (published + CURRENT_TIMESTAMP) and the
  #      NOT NULL on the status, so an old-release insert that supplies only the
  #      pre-migration columns still produces a valid published row.
  #   4. Add the state/timestamp check constraints only after every row is valid.
  #   5. Add the organization/status/publication-time index.
  def up do
    alter table(:gtfs_versions) do
      add :publication_status, :string
      add :published_at, :utc_datetime_usec
    end

    flush()

    execute("""
    UPDATE #{qualified_table()}
    SET publication_status = 'published', published_at = inserted_at
    WHERE publication_status IS NULL
    """)

    execute(
      "ALTER TABLE #{qualified_table()} ALTER COLUMN publication_status SET DEFAULT 'published'"
    )

    execute(
      "ALTER TABLE #{qualified_table()} ALTER COLUMN publication_status SET NOT NULL"
    )

    execute(
      "ALTER TABLE #{qualified_table()} ALTER COLUMN published_at SET DEFAULT CURRENT_TIMESTAMP"
    )

    execute("""
    ALTER TABLE #{qualified_table()}
    ADD CONSTRAINT #{@status_check}
    CHECK (publication_status IN ('staging', 'importing', 'published', 'failed'))
    """)

    execute("""
    ALTER TABLE #{qualified_table()}
    ADD CONSTRAINT #{@state_timestamp_check}
    CHECK (
      (publication_status = 'published' AND published_at IS NOT NULL)
      OR (publication_status <> 'published' AND published_at IS NULL)
    )
    """)

    create index(:gtfs_versions, [:organization_id, :publication_status, :published_at],
             name: @index_name
           )
  end

  def down do
    drop index(:gtfs_versions, [:organization_id, :publication_status, :published_at],
           name: @index_name
         )

    execute("ALTER TABLE #{qualified_table()} DROP CONSTRAINT #{@state_timestamp_check}")
    execute("ALTER TABLE #{qualified_table()} DROP CONSTRAINT #{@status_check}")

    alter table(:gtfs_versions) do
      remove :published_at
      remove :publication_status
    end
  end

  # Raw `execute/1` statements are not prefix-aware, so qualify the table with
  # the migration prefix when one is set (e.g. isolated-schema tests).
  defp qualified_table do
    case prefix() do
      nil -> "gtfs_versions"
      schema -> ~s("#{schema}".gtfs_versions)
    end
  end
end
