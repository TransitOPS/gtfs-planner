defmodule GtfsPlanner.Repo.Migrations.MakeAlertsOrganizationOwned do
  use Ecto.Migration

  @moduledoc """
  Moves `service_alerts` from version-owned rows to organization-owned rows with
  retained provenance.

  A service alert outlives the GTFS version it was written against. Its
  `organization_id` is the owner that never changes; the version becomes
  optional provenance, so this migration replaces both old ownership keys:

    * `service_alerts_gtfs_version_id_fkey`, the single-column cascade that
      deleted an organization's own alerts with the version, and
    * `service_alerts_version_owner_fkey`, the composite NO ACTION key whose
      NO ACTION can no longer apply, because a NULL source is legitimate.

  The replacement keeps the same tenant-correct composite reference with
  `ON DELETE SET NULL (source_gtfs_version_id)`: deleting the source version
  clears only the provenance and never `organization_id`, so the organization
  that owns the alert keeps it. PostgreSQL 15 supports naming the columns a
  `SET NULL` action clears, which is what keeps the rest of the row intact.
  """

  def up do
    rename(table(:service_alerts), :gtfs_version_id, to: :source_gtfs_version_id)

    execute("""
    ALTER TABLE #{qualified_table(:service_alerts)}
    ALTER COLUMN source_gtfs_version_id DROP NOT NULL
    """)

    # The trusted public representation and the deletion state an organization
    # keeps after its source version is gone.
    alter table(:service_alerts) do
      add :target_reference, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime_usec
      add :public_entity_id, :uuid
      add :timezone, :string
    end

    # `alert_publications` may only name an alert of its own organization, so
    # the alert's `(id, organization_id)` pair becomes a referenced key.
    create unique_index(:service_alerts, [:id, :organization_id])

    # The public entity id is the stable identity a served feed keeps across
    # retargets and deletions, so two alerts may never share one.
    create unique_index(:service_alerts, [:public_entity_id],
             where: "public_entity_id IS NOT NULL",
             name: :service_alerts_public_entity_id_index
           )

    # Renaming the column leaves the old index name behind, and its columns no
    # longer match the version-scoped listing query.
    execute("DROP INDEX IF EXISTS service_alerts_organization_id_gtfs_version_id_last_date_index")

    create index(:service_alerts, [:organization_id, :source_gtfs_version_id, :last_date])

    execute("""
    ALTER TABLE #{qualified_table(:service_alerts)}
    DROP CONSTRAINT service_alerts_gtfs_version_id_fkey
    """)

    execute("""
    ALTER TABLE #{qualified_table(:service_alerts)}
    DROP CONSTRAINT service_alerts_version_owner_fkey
    """)

    # The local columns follow the referenced order: PostgreSQL validates a
    # `SET NULL` foreign key against the referenced key in this order, so a
    # reversed pair is refused even when every row is tenant-correct.
    execute("""
    ALTER TABLE #{qualified_table(:service_alerts)}
    ADD CONSTRAINT service_alerts_source_version_owner_fkey
    FOREIGN KEY (source_gtfs_version_id, organization_id)
    REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
    ON DELETE SET NULL (source_gtfs_version_id)
    """)

    # Capture what the old row only knew as row UUIDs, while the version that
    # can still resolve them is still referenced. Nothing here guesses: an ID
    # that does not resolve inside the alert's own organization is recorded as
    # unresolved, so the alert reads as Needs attention instead of gaining a
    # fabricated wire ID.
    execute(capture_target_references_sql())

    # The organization's own explicit alert zone. It is the answer for an alert
    # whose retained source had no single usable agency zone, and it stays NULL
    # until an organization states one: no alert inherits UTC by default.
    alter table(:alert_settings) do
      add :timezone, :string
    end

    create table(:alert_publications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :restrict),
        null: false

      # A plain column, because the tenant-correct composite key below is the
      # only ownership constraint this row needs.
      add :alert_id, :binary_id, null: false

      # The newest desired intent and the last content a served manifest
      # actually included. There is no public history here: one row per alert
      # keeps both, and step 12 owns every write.
      add :desired_revision, :bigint
      add :desired_snapshot, :map
      add :confirmed_revision, :bigint
      add :confirmed_snapshot, :map

      add :requested_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :requested_at, :utc_datetime_usec
      add :last_published_at, :utc_datetime_usec

      # `none` is a draft with no removal requested; `pending` is a confirmed
      # removal the served manifest has not applied yet.
      add :withdrawal, :string, null: false, default: "none"

      timestamps(type: :utc_datetime_usec)
    end

    # One publication row per alert of one organization: the last confirmed and
    # the newest desired intent, never a growing history.
    create unique_index(:alert_publications, [:alert_id, :organization_id])
    create unique_index(:alert_publications, [:id, :organization_id])
    create index(:alert_publications, [:organization_id])

    create constraint(:alert_publications, :alert_publications_withdrawal_known,
             check: "withdrawal IN ('none', 'pending')"
           )

    execute("""
    ALTER TABLE #{qualified_table(:alert_publications)}
    ADD CONSTRAINT alert_publications_alert_owner_fkey
    FOREIGN KEY (alert_id, organization_id)
    REFERENCES #{qualified_table(:service_alerts)} (id, organization_id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{qualified_table(:alert_publications)}
    DROP CONSTRAINT alert_publications_alert_owner_fkey
    """)

    drop table(:alert_publications)

    alter table(:alert_settings) do
      remove :timezone
    end

    execute("""
    ALTER TABLE #{qualified_table(:service_alerts)}
    DROP CONSTRAINT service_alerts_source_version_owner_fkey
    """)

    # An alert whose source version has since been deleted has no version to
    # restore, and the old shape required one. Rolling back would delete another
    # organization's retained alert, so it refuses instead and names the rows
    # that need a decision first.
    if retained_without_source() > 0 do
      raise """
      #{retained_without_source()} service_alerts rows have no source GTFS version, so \
      make_alerts_organization_owned cannot be rolled back without deleting them. Restore \
      a source_gtfs_version_id for each row, or delete the rows deliberately, before \
      running `mix ecto.rollback`.
      """
    end

    drop index(:service_alerts, [:public_entity_id], name: :service_alerts_public_entity_id_index)

    drop index(:service_alerts, [:organization_id, :source_gtfs_version_id, :last_date])

    execute("""
    ALTER TABLE #{qualified_table(:service_alerts)}
    ALTER COLUMN source_gtfs_version_id SET NOT NULL
    """)

    alter table(:service_alerts) do
      remove :target_reference
      remove :deleted_at
      remove :public_entity_id
      remove :timezone
    end

    drop index(:service_alerts, [:id, :organization_id])

    rename(table(:service_alerts), :source_gtfs_version_id, to: :gtfs_version_id)

    create index(:service_alerts, [:organization_id, :gtfs_version_id, :last_date])

    execute("""
    ALTER TABLE #{qualified_table(:service_alerts)}
    ADD CONSTRAINT service_alerts_gtfs_version_id_fkey
    FOREIGN KEY (gtfs_version_id) REFERENCES #{qualified_table(:gtfs_versions)} (id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE #{qualified_table(:service_alerts)}
    ADD CONSTRAINT service_alerts_version_owner_fkey
    FOREIGN KEY (gtfs_version_id, organization_id)
    REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
    ON DELETE NO ACTION
    """)
  end

  # The retained zone is the source version's single usable agency zone. When no
  # such zone exists the column stays NULL: publication and listing resolve an
  # explicit organization timezone instead of inheriting the display fallback
  # the old timing answer already discloses.
  defp capture_target_references_sql do
    """
    UPDATE #{qualified_table(:service_alerts)} AS a
    SET timezone = (
          SELECT min(btrim(ag.agency_timezone))
          FROM agencies AS ag
          WHERE ag.organization_id = a.organization_id
            AND ag.gtfs_version_id = a.source_gtfs_version_id
            AND NULLIF(btrim(ag.agency_timezone), '') IS NOT NULL
          HAVING count(DISTINCT btrim(ag.agency_timezone)) = 1
        ),
        target_reference = jsonb_build_object(
          'source_gtfs_version_id', a.source_gtfs_version_id::text,
          'timezone', (
            SELECT min(btrim(ag.agency_timezone))
            FROM agencies AS ag
            WHERE ag.organization_id = a.organization_id
              AND ag.gtfs_version_id = a.source_gtfs_version_id
              AND NULLIF(btrim(ag.agency_timezone), '') IS NOT NULL
            HAVING count(DISTINCT btrim(ag.agency_timezone)) = 1
          ),
          'selectors', jsonb_build_object(
            'shape', a.scope ->> 'shape',
            'mode_route_type', a.scope -> 'mode_route_type',
            'direction_id', a.scope -> 'direction_id',
            'routes', COALESCE((
              SELECT jsonb_agg(
                       jsonb_build_object(
                         'id', r.id::text,
                         'gtfs_id', r.route_id,
                         'label', COALESCE(NULLIF(r.route_long_name, ''), NULLIF(r.route_short_name, ''), r.route_id)
                       ) ORDER BY r.id
                     )
              FROM jsonb_array_elements_text(COALESCE(a.scope -> 'route_ids', '[]'::jsonb)) AS ref(id)
              JOIN routes AS r
                ON r.id::text = ref.id AND r.organization_id = a.organization_id
            ), '[]'::jsonb),
            'unresolved_routes', (
              SELECT COALESCE(jsonb_agg(DISTINCT ref.id), '[]'::jsonb)
              FROM jsonb_array_elements_text(COALESCE(a.scope -> 'route_ids', '[]'::jsonb)) AS ref(id)
              WHERE NOT EXISTS (
                SELECT 1 FROM routes AS r
                WHERE r.id::text = ref.id AND r.organization_id = a.organization_id
              )
            ),
            'stops', COALESCE((
              SELECT jsonb_agg(
                       jsonb_build_object(
                         'id', s.id::text,
                         'gtfs_id', s.stop_id,
                         'label', COALESCE(NULLIF(s.stop_name, ''), s.stop_id)
                       ) ORDER BY s.id
                     )
              FROM jsonb_array_elements_text(COALESCE(a.scope -> 'stop_ids', '[]'::jsonb)) AS ref(id)
              JOIN stops AS s
                ON s.id::text = ref.id AND s.organization_id = a.organization_id
            ), '[]'::jsonb),
            'unresolved_stops', (
              SELECT COALESCE(jsonb_agg(DISTINCT ref.id), '[]'::jsonb)
              FROM jsonb_array_elements_text(COALESCE(a.scope -> 'stop_ids', '[]'::jsonb)) AS ref(id)
              WHERE NOT EXISTS (
                SELECT 1 FROM stops AS s
                WHERE s.id::text = ref.id AND s.organization_id = a.organization_id
              )
            ),
            'route_stops', COALESCE((
              SELECT jsonb_agg(
                       jsonb_build_object(
                         'route_id', pair.value ->> 'route_id',
                         'route_gtfs_id', r.route_id,
                         'route_label', COALESCE(NULLIF(r.route_long_name, ''), NULLIF(r.route_short_name, ''), r.route_id),
                         'stop_id', pair.value ->> 'stop_id',
                         'stop_gtfs_id', s.stop_id,
                         'stop_label', COALESCE(NULLIF(s.stop_name, ''), s.stop_id),
                         'resolved', r.id IS NOT NULL AND s.id IS NOT NULL
                       )
                       ORDER BY pair.value ->> 'route_id', pair.value ->> 'stop_id'
                     )
              FROM jsonb_array_elements(COALESCE(a.scope -> 'route_stop_pairs', '[]'::jsonb)) AS pair(value)
              LEFT JOIN routes AS r
                ON r.id::text = pair.value ->> 'route_id' AND r.organization_id = a.organization_id
              LEFT JOIN stops AS s
                ON s.id::text = pair.value ->> 'stop_id' AND s.organization_id = a.organization_id
            ), '[]'::jsonb),
            'trips', COALESCE((
              SELECT jsonb_agg(
                       jsonb_build_object(
                         'id', t.id::text,
                         'gtfs_id', t.trip_id,
                         'service_id', t.service_id,
                         'service_date', trip.value ->> 'service_date',
                         'label', COALESCE(NULLIF(t.trip_headsign, ''), NULLIF(t.trip_short_name, ''), t.trip_id),
                         'resolved', t.id IS NOT NULL
                       )
                       ORDER BY t.id
                     )
              FROM jsonb_array_elements(COALESCE(a.scope -> 'trips', '[]'::jsonb)) AS trip(value)
              LEFT JOIN trips AS t
                ON t.id::text = trip.value ->> 'trip_id' AND t.organization_id = a.organization_id
            ), '[]'::jsonb),
            'agencies', CASE WHEN a.scope ->> 'shape' = 'system' THEN COALESCE((
              SELECT jsonb_agg(
                       jsonb_build_object(
                         'id', ag.id::text,
                         'gtfs_id', ag.agency_id,
                         'label', COALESCE(NULLIF(ag.agency_name, ''), ag.agency_id)
                       ) ORDER BY ag.id
                     )
              FROM agencies AS ag
              WHERE ag.organization_id = a.organization_id
                AND ag.gtfs_version_id = a.source_gtfs_version_id
            ), '[]'::jsonb) ELSE '[]'::jsonb END
          )
        )
    """
  end

  defp retained_without_source do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT count(*) FROM #{qualified_table(:service_alerts)} WHERE source_gtfs_version_id IS NULL"
      )

    count
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{String.replace(schema, "\"", "\"\"")}".#{table})
    end
  end
end
