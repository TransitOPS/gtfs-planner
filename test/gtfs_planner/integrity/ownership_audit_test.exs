defmodule GtfsPlanner.Integrity.OwnershipAuditTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Integrity.OwnershipAudit

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  test "version-owner catalog matches the database ownership columns" do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.table_name
      FROM information_schema.columns AS c
      JOIN information_schema.tables AS t
        ON t.table_schema = c.table_schema AND t.table_name = c.table_name
      WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
        AND c.column_name IN ('organization_id', 'gtfs_version_id')
      GROUP BY c.table_name
      HAVING count(DISTINCT c.column_name) = 2
      ORDER BY c.table_name
      """)

    expected = rows |> Enum.map(&hd/1) |> List.delete("gtfs_import_runs")
    assert Enum.sort(OwnershipAudit.version_owner_tables()) == expected
  end

  test "clean GTFS rows have no ownership anomalies" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    station = stop_fixture(org.id, version.id, %{location_type: 1})
    platform = stop_fixture(org.id, version.id)
    level = level_fixture(org.id, version.id)
    pathway_fixture(org.id, version.id, station.stop_id, platform.stop_id)

    assert {:ok, _} =
             Gtfs.create_stop_level(%{
               organization_id: org.id,
               gtfs_version_id: version.id,
               stop_id: station.id,
               level_id: level.id
             })

    route = route_fixture(org.id, version.id)
    route_pattern_fixture(org.id, version.id, %{route_id: route.route_id})

    report = OwnershipAudit.run()
    assert report.total == 0
    assert Enum.all?(report.relationships, &(&1.anomalies == 0 and &1.samples == []))
  end

  test "wrong-version route is counted and sampled" do
    org = organization_fixture()
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)
    id = Ecto.UUID.generate()

    # Step 8 adds this constraint. The test transaction rolls back its removal.
    Repo.query!("ALTER TABLE routes DROP CONSTRAINT IF EXISTS routes_version_owner_fkey")

    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Route, [
        %{
          id: id,
          route_id: "wrong_owner_#{System.unique_integer([:positive])}",
          route_type: 3,
          organization_id: org.id,
          gtfs_version_id: foreign_version.id,
          inserted_at: now,
          updated_at: now
        }
      ])

    relationship =
      OwnershipAudit.run().relationships |> Enum.find(&(&1.name == "routes→gtfs_versions"))

    assert relationship.anomalies == 1
    assert id in relationship.samples
  end

  test "stop-level containment detects a parent in another version" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    other_version = gtfs_version_fixture(org.id)
    stop = stop_fixture(org.id, version.id, %{location_type: 1})
    level = level_fixture(org.id, other_version.id)

    Repo.query!("ALTER TABLE stop_levels DROP CONSTRAINT IF EXISTS stop_levels_stops_owner_fkey")

    assert {:ok, stop_level} =
             Gtfs.create_stop_level(%{
               organization_id: org.id,
               gtfs_version_id: other_version.id,
               stop_id: stop.id,
               level_id: level.id
             })

    relationship =
      OwnershipAudit.run().relationships |> Enum.find(&(&1.name == "stop_levels→stops"))

    assert relationship.anomalies == 1
    assert stop_level.id in relationship.samples
  end

  test "cleaned import receipts keep deleted target identity; failed receipts are reported" do
    org = organization_fixture()
    now = DateTime.utc_now()
    cleaned_version_id = Ecto.UUID.generate()
    failed_version_id = Ecto.UUID.generate()

    cleaned_id = Ecto.UUID.generate()
    failed_id = Ecto.UUID.generate()

    {2, _} =
      Repo.insert_all(GtfsPlanner.Gtfs.Import.Run, [
        %{
          id: cleaned_id,
          organization_id: org.id,
          gtfs_version_id: cleaned_version_id,
          version_name: "Removed version",
          state: "cleaned",
          committed_counts: %{},
          counts_complete: false,
          finished_at: now,
          cleanup_started_at: now,
          cleanup_finished_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          id: failed_id,
          organization_id: org.id,
          gtfs_version_id: failed_version_id,
          version_name: "Removed version",
          state: "failed",
          committed_counts: %{},
          counts_complete: false,
          finished_at: now,
          cleanup_started_at: nil,
          cleanup_finished_at: nil,
          inserted_at: now,
          updated_at: now
        }
      ])

    relationship =
      OwnershipAudit.run().relationships
      |> Enum.find(&(&1.name == "gtfs_import_runs→gtfs_versions"))

    assert relationship.anomalies == 1
    assert relationship.samples == [failed_id]
    refute cleaned_id in relationship.samples
  end

  test "the audit leaves every audited table unchanged" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    route_fixture(org.id, version.id)

    tables = OwnershipAudit.version_owner_tables() ++ ["gtfs_import_runs"]
    before = Map.new(tables, &{&1, fingerprint(&1)})

    assert %{total: 0} = OwnershipAudit.run(sample_limit: 0)
    assert Map.new(tables, &{&1, fingerprint(&1)}) == before

    # The read-only setting must not leak into the surrounding sandbox transaction.
    route_fixture(org.id, version.id)
  end

  defp fingerprint(table) do
    %{rows: [[count, checksum]]} =
      Repo.query!("""
      SELECT count(*), md5(string_agg(row_to_json(t)::text, ',' ORDER BY id))
      FROM #{table} AS t
      """)

    {count, checksum}
  end
end
