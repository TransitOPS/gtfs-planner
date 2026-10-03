defmodule GtfsPlanner.Repo.Migrations.AddActiveGtfsVersionToOrganizations do
  use Ecto.Migration

  @moduledoc """
  Gives each organization one active authoring schedule.

  `active_gtfs_version_id` names a usable version of the same organization through
  the composite `(active_gtfs_version_id, id) -> gtfs_versions (id, organization_id)`
  key, so a pointer can never name another tenant's version. The key is `NO ACTION`,
  which PostgreSQL checks at the end of the statement: deleting the active version
  alone is refused, while deleting the organization (which deletes its versions in
  the same statement) still completes.

  `active_gtfs_version_revision` counts pointer changes and never decreases, so a
  token read before an A -> B -> A switch is still stale. `active_full_publication_sequence`
  is the newest confirmed full-GTFS receipt already applied to the selection.

  Existing organizations are initialized once, here:

    * the pointer is the source of the full channel's served manifest, but only when
      the frozen attempt or its surviving export run proves a published source;
    * otherwise it is the newest published version by
      `published_at DESC NULLS LAST, inserted_at DESC, id DESC`, or NULL when there is
      none. This only initializes authoring; it never claims the served artifact came
      from that version;
    * the receipt watermark is the served manifest sequence, so a receipt that was
      already served is not replayed over a later choice.

  `down` drops the derived selection; no other data depends on it.
  """

  def up do
    execute("""
    LOCK TABLE #{qualified(:organizations)}, #{qualified(:gtfs_versions)}
    IN SHARE ROW EXCLUSIVE MODE
    """)

    alter table(:organizations) do
      add :active_gtfs_version_id, :binary_id
      add :active_gtfs_version_revision, :bigint, null: false, default: 0
      add :active_full_publication_sequence, :bigint, null: false, default: 0
    end

    create constraint(:organizations, :organizations_active_selection_nonnegative,
             check: "active_gtfs_version_revision >= 0 AND active_full_publication_sequence >= 0"
           )

    execute(backfill_sql())

    execute("""
    ALTER TABLE #{qualified(:organizations)}
    ADD CONSTRAINT organizations_active_gtfs_version_owner_fkey
    FOREIGN KEY (active_gtfs_version_id, id)
    REFERENCES #{qualified(:gtfs_versions)} (id, organization_id)
    ON DELETE NO ACTION
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{qualified(:organizations)}
    DROP CONSTRAINT organizations_active_gtfs_version_owner_fkey
    """)

    drop constraint(:organizations, :organizations_active_selection_nonnegative)

    alter table(:organizations) do
      remove :active_gtfs_version_id
      remove :active_gtfs_version_revision
      remove :active_full_publication_sequence
    end
  end

  # A pointer change is a revision change, so an initialized organization starts at 1.
  # Run ids and frozen version ids are compared as text: a malformed value in an old
  # attempt must not abort the migration with a cast error.
  defp backfill_sql do
    """
    UPDATE #{qualified(:organizations)} AS o
    SET active_gtfs_version_id = s.version_id,
        active_gtfs_version_revision = CASE WHEN s.version_id IS NULL THEN 0 ELSE 1 END,
        active_full_publication_sequence = s.full_sequence
    FROM (
      SELECT org.id AS organization_id,
             COALESCE(
               (SELECT v.id
                  FROM #{qualified(:feed_publications)} p
                  JOIN #{qualified(:feed_publication_attempts)} a
                    ON a.publication_id = p.id
                   AND a.organization_id = p.organization_id
                   AND a.sequence = p.manifest_sequence
                  LEFT JOIN #{qualified(:gtfs_export_runs)} r
                    ON r.organization_id = org.id
                   AND r.id::text = a.private_snapshot -> 'source' ->> 'run_id'
                  JOIN #{qualified(:gtfs_versions)} v
                    ON v.organization_id = org.id
                   AND v.publication_status = 'published'
                   AND v.id::text = COALESCE(
                         a.private_snapshot -> 'source' ->> 'gtfs_version_id',
                         r.gtfs_version_id::text
                       )
                 WHERE p.organization_id = org.id AND p.channel = 'full'),
               (SELECT v.id
                  FROM #{qualified(:gtfs_versions)} v
                 WHERE v.organization_id = org.id AND v.publication_status = 'published'
                 ORDER BY v.published_at DESC NULLS LAST, v.inserted_at DESC, v.id DESC
                 LIMIT 1)
             ) AS version_id,
             COALESCE(
               (SELECT p.manifest_sequence
                  FROM #{qualified(:feed_publications)} p
                 WHERE p.organization_id = org.id AND p.channel = 'full'),
               0
             ) AS full_sequence
        FROM #{qualified(:organizations)} org
    ) AS s
    WHERE o.id = s.organization_id
    """
  end

  defp qualified(name) do
    case prefix() do
      nil -> Atom.to_string(name)
      schema -> ~s("#{String.replace(schema, "\"", "\"\"")}".#{name})
    end
  end
end
