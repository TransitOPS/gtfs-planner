defmodule GtfsPlanner.Integrity.OwnershipAuditTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Integrity.OwnershipAudit
  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.VersionsFixtures

  @organization_parents [
    {"block_attributes", "garage_id", "garages"},
    {"block_attributes", "vehicle_type_id", "vehicle_types"},
    {"route_operating_settings", "garage_id", "garages"},
    {"route_operating_settings", "required_vehicle_type_id", "vehicle_types"},
    {"blocking_settings", "default_garage_id", "garages"},
    {"vehicles", "garage_id", "garages"},
    {"vehicles", "vehicle_type_id", "vehicle_types"},
    {"roster_lines", "operator_id", "operators"}
  ]

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
             insert_stop_level(%{
               organization_id: org.id,
               gtfs_version_id: version.id,
               stop_id: station.id,
               level_id: level.id
             })

    route = route_fixture(org.id, version.id)
    route_pattern_fixture(org.id, version.id, %{route_id: route.route_id})
    trip = trip_fixture(org.id, version.id, route.route_id)
    insert_trip_run!(org.id, version.id, trip.id, "R1")
    insert_roster_day!(insert_roster_line!(org.id, version.id, insert_operator!(org.id).id))

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
             insert_stop_level(%{
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

  test "trip assignments report version ownership and UUID trip scope independently" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    other_version = gtfs_version_fixture(org.id)
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)
    other_route = route_fixture(org.id, other_version.id)
    foreign_route = route_fixture(foreign_org.id, foreign_version.id)
    other_trip = trip_fixture(org.id, other_version.id, other_route.route_id)
    foreign_trip = trip_fixture(foreign_org.id, foreign_version.id, foreign_route.route_id)

    Repo.query!("ALTER TABLE trip_runs DROP CONSTRAINT trip_runs_version_owner_fkey")
    Repo.query!("ALTER TABLE trip_runs DROP CONSTRAINT trip_runs_trips_owner_fkey")

    wrong_trip_id = insert_trip_run!(org.id, version.id, other_trip.id, "R1")
    wrong_owner_id = insert_trip_run!(org.id, foreign_version.id, foreign_trip.id, "R2")
    before = fingerprint("trip_runs")
    report = OwnershipAudit.run()

    version_link = Enum.find(report.relationships, &(&1.name == "trip_runs→gtfs_versions"))
    trip_link = Enum.find(report.relationships, &(&1.name == "trip_runs.trip_id→trips"))

    assert version_link.kind == :version_owner
    assert version_link.anomalies == 1
    assert version_link.samples == [wrong_owner_id]
    assert trip_link.kind == :containment
    assert trip_link.anomalies == 2
    assert Enum.sort(trip_link.samples) == Enum.sort([wrong_trip_id, wrong_owner_id])
    assert fingerprint("trip_runs") == before

    bounded = OwnershipAudit.run(sample_limit: 0)
    assert Enum.find(bounded.relationships, &(&1.name == trip_link.name)).samples == []
    assert fingerprint("trip_runs") == before
  end

  test "roster day containment detects a line of another version" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    other_version = gtfs_version_fixture(org.id)
    line = insert_roster_line!(org.id, other_version.id, nil)

    Repo.query!(
      "ALTER TABLE roster_line_days DROP CONSTRAINT roster_line_days_roster_lines_owner_fkey"
    )

    day = insert_roster_day!(%{line | gtfs_version_id: version.id})

    relationship =
      OwnershipAudit.run().relationships
      |> Enum.find(&(&1.name == "roster_line_days.roster_line_id→roster_lines"))

    assert relationship.kind == :containment
    assert relationship.anomalies == 1
    assert relationship.samples == [day.id]
  end

  test "all organization-only parent links report foreign assets and ignore nulls" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    foreign_org = organization_fixture()

    foreign_parents = %{
      "garages" => garage_fixture(foreign_org.id).id,
      "vehicle_types" => vehicle_type_fixture(foreign_org.id).id,
      "operators" => insert_operator!(foreign_org.id).id
    }

    for {table, column, parent} <- @organization_parents do
      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{table}_#{column}_owner_fkey")
      parent_id = Map.fetch!(foreign_parents, parent)
      foreign_id = insert_asset_link!(table, column, org.id, version.id, parent_id)

      nullable_version =
        if table == "blocking_settings", do: gtfs_version_fixture(org.id), else: version

      insert_asset_link!(table, column, org.id, nullable_version.id, nil)

      relationship =
        OwnershipAudit.run().relationships
        |> Enum.find(&(&1.name == "#{table}.#{column}→#{parent}"))

      assert relationship.kind == :organization_containment
      assert relationship.anomalies == 1
      assert relationship.samples == [foreign_id]
    end
  end

  test "a missing non-null asset parent is also an ownership anomaly" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    Repo.query!("ALTER TABLE vehicles DROP CONSTRAINT vehicles_garage_id_owner_fkey")
    Repo.query!("ALTER TABLE vehicles DROP CONSTRAINT vehicles_garage_id_fkey")

    id = insert_asset_link!("vehicles", "garage_id", org.id, version.id, Ecto.UUID.generate())

    relationship =
      OwnershipAudit.run().relationships
      |> Enum.find(&(&1.name == "vehicles.garage_id→garages"))

    assert relationship.anomalies == 1
    assert relationship.samples == [id]
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

    tables =
      OwnershipAudit.version_owner_tables() ++
        ["gtfs_import_runs", "garages", "vehicle_types", "vehicles"]

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

  defp insert_operator!(org_id) do
    Repo.insert!(%Operator{
      organization_id: org_id,
      employee_id: "E#{System.unique_integer([:positive])}",
      display_name: "Operator"
    })
  end

  defp insert_roster_line!(org_id, version_id, operator_id) do
    Repo.insert!(%RosterLine{
      organization_id: org_id,
      gtfs_version_id: version_id,
      line_number: System.unique_integer([:positive]),
      operator_id: operator_id
    })
  end

  defp insert_roster_day!(line) do
    Repo.insert!(%RosterLineDay{
      roster_line_id: line.id,
      organization_id: line.organization_id,
      gtfs_version_id: line.gtfs_version_id,
      weekday: 1,
      day_type_key: "WK",
      run_id: "R1",
      run_sign_on_secs: 0,
      run_sign_off_secs: 3600
    })
  end

  defp insert_trip_run!(org_id, version_id, trip_id, run_id) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    assert {1, _} =
             Repo.insert_all(TripRun, [
               %{
                 id: id,
                 organization_id: org_id,
                 gtfs_version_id: version_id,
                 trip_id: trip_id,
                 day_type_key: "WK",
                 run_id: run_id,
                 inserted_at: now,
                 updated_at: now
               }
             ])

    id
  end

  defp insert_asset_link!(table, column, org_id, version_id, parent_id) do
    id = Ecto.UUID.generate()
    base = [Ecto.UUID.dump!(id), Ecto.UUID.dump!(org_id)]
    asset = if parent_id, do: Ecto.UUID.dump!(parent_id), else: nil

    case table do
      "block_attributes" ->
        Repo.query!(
          """
          INSERT INTO block_attributes
            (id, organization_id, gtfs_version_id, service_id, block_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, 'SERVICE', $4, $5, now(), now())
          """,
          base ++ [Ecto.UUID.dump!(version_id), "BLOCK_#{id}", asset]
        )

      "route_operating_settings" ->
        Repo.query!(
          """
          INSERT INTO route_operating_settings
            (id, organization_id, gtfs_version_id, route_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, now(), now())
          """,
          base ++ [Ecto.UUID.dump!(version_id), "ROUTE_#{id}", asset]
        )

      "blocking_settings" ->
        Repo.query!(
          """
          INSERT INTO blocking_settings
            (id, organization_id, gtfs_version_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, now(), now())
          """,
          base ++ [Ecto.UUID.dump!(version_id), asset]
        )

      "vehicles" ->
        Repo.query!(
          """
          INSERT INTO vehicles
            (id, organization_id, vehicle_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, now(), now())
          """,
          base ++ ["VEHICLE_#{id}", asset]
        )

      "roster_lines" ->
        Repo.query!(
          """
          INSERT INTO roster_lines
            (id, organization_id, gtfs_version_id, line_number, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, now(), now())
          """,
          base ++ [Ecto.UUID.dump!(version_id), System.unique_integer([:positive]), asset]
        )
    end

    id
  end
end
