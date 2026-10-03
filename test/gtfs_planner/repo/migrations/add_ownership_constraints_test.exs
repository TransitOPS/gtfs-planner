defmodule GtfsPlanner.Repo.Migrations.AddOwnershipConstraintsTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.Recovery
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Integrity.OwnershipAudit
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.VersionsFixtures

  @containment [
    {"stop_levels", "stop_id", "stops"},
    {"stop_levels", "level_id", "levels"},
    {"trips", "timed_pattern_id", "timed_patterns"},
    {"alignment_segments", "from_occurrence_id", "route_pattern_stops"},
    {"flex_areas", "flex_service_id", "flex_services"},
    {"journal_entries", "station_id", "stops"},
    {"station_editing_statuses", "station_id", "stops"},
    {"trip_runs", "trip_id", "trips"}
  ]

  @organization_parents [
    {"block_attributes", "garage_id", "garages"},
    {"block_attributes", "vehicle_type_id", "vehicle_types"},
    {"route_operating_settings", "garage_id", "garages"},
    {"route_operating_settings", "required_vehicle_type_id", "vehicle_types"},
    {"blocking_settings", "default_garage_id", "garages"},
    {"vehicles", "garage_id", "garages"},
    {"vehicles", "vehicle_type_id", "vehicle_types"}
  ]

  @actor %{id: Ecto.UUID.generate(), email: "operator@example.com"}

  setup do
    previous = Application.get_env(:gtfs_planner, :uploads_path)
    root = Path.join(System.tmp_dir!(), "ownership_cleanup_#{System.unique_integer([:positive])}")
    Application.put_env(:gtfs_planner, :uploads_path, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous) do
        Application.delete_env(:gtfs_planner, :uploads_path)
      else
        Application.put_env(:gtfs_planner, :uploads_path, previous)
      end
    end)

    :ok
  end

  test "every live owner and UUID containment relationship has a scoped NO ACTION FK" do
    constraints = constraints()

    owner_tables =
      OwnershipAudit.version_owner_tables() -- ["gtfs_change_runs", "gtfs_export_runs"]

    for table <- owner_tables do
      name = "#{table}_version_owner_fkey"

      assert {^table, "gtfs_versions", definition, "a"} = Map.fetch!(constraints, name)
      assert definition =~ "FOREIGN KEY (gtfs_version_id, organization_id)"
      assert definition =~ "REFERENCES gtfs_versions(id, organization_id)"
    end

    for {child, foreign_key, parent} <- @containment do
      name = "#{child}_#{parent}_owner_fkey"

      assert {^child, ^parent, definition, "a"} = Map.fetch!(constraints, name)
      assert definition =~ "FOREIGN KEY (#{foreign_key}, organization_id, gtfs_version_id)"
      assert definition =~ "REFERENCES #{parent}(id, organization_id, gtfs_version_id)"
    end

    for {child, foreign_key, parent} <- @organization_parents do
      name = "#{child}_#{foreign_key}_owner_fkey"
      assert {^child, ^parent, definition, "a"} = Map.fetch!(constraints, name)
      assert definition =~ "FOREIGN KEY (#{foreign_key}, organization_id)"
      assert definition =~ "REFERENCES #{parent}(id, organization_id)"
    end

    # The pattern occurrences and timings store their parents' GTFS identifiers, so their
    # containment is a natural composite key that follows a parent rename and deletes with
    # the parent.
    for {child, parent, name, column} <- [
          {"route_pattern_stops", "route_patterns",
           "route_pattern_stops_route_patterns_owner_fkey", "route_pattern_id"},
          {"timed_patterns", "route_patterns", "timed_patterns_route_patterns_owner_fkey",
           "route_pattern_id"}
        ] do
      assert {^child, ^parent, definition, "c"} = Map.fetch!(constraints, name)

      assert definition =~ "FOREIGN KEY (organization_id, gtfs_version_id, #{column})"
      assert definition =~ "REFERENCES #{parent}(organization_id, gtfs_version_id, #{column})"
      assert definition =~ "ON UPDATE CASCADE ON DELETE CASCADE"
    end

    # A label is optional and blocks deleting its owner, so only the update follows.
    assert {"route_patterns", "route_patterns", label_definition, "r"} =
             Map.fetch!(constraints, "route_patterns_label_pattern_id_fkey")

    assert label_definition =~ "FOREIGN KEY (organization_id, gtfs_version_id, label_pattern_id)"

    assert label_definition =~
             "REFERENCES route_patterns(organization_id, gtfs_version_id, route_pattern_id)"

    assert label_definition =~ "ON UPDATE CASCADE ON DELETE RESTRICT"

    refute Enum.any?(constraints, fn {_name, {child, parent, _definition, _delete_rule}} ->
             child == "gtfs_import_runs" and parent == "gtfs_versions"
           end)

    assert {"journal_entries", "stops",
            "FOREIGN KEY (station_id) REFERENCES stops(id) ON DELETE CASCADE", "c"} =
             Map.fetch!(constraints, "journal_entries_station_id_fkey")

    assert {"blocking_settings", "garages", definition, "n"} =
             Map.fetch!(constraints, "blocking_settings_default_garage_id_fkey")

    assert definition =~ "ON DELETE SET NULL"

    for {child, column, parent} <- @organization_parents do
      assert {^child, ^parent, _definition, action} =
               Map.fetch!(constraints, "#{child}_#{column}_fkey")

      assert action == if(child == "blocking_settings", do: "n", else: "a")
    end

    for table <- ~w(route_patterns timed_patterns route_pattern_stops flex_services) do
      assert unique_scoped_index?(table)
    end

    for table <- ~w(garages vehicle_types) do
      assert unique_organization_index?(table)
    end

    assert unique_runs_trip_index?()

    for {column, parent} <- [
          {"organization_id", "organizations"},
          {"gtfs_version_id", "gtfs_versions"},
          {"trip_id", "trips"}
        ] do
      assert {"trip_runs", ^parent, definition, "c"} =
               Map.fetch!(constraints, "trip_runs_#{column}_fkey")

      assert definition =~ "ON DELETE CASCADE"
    end
  end

  test "every organization-only asset link rejects a foreign parent and accepts nil" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    other = organization_fixture()
    foreign_garage = garage_fixture(other.id)
    foreign_type = vehicle_type_fixture(other.id)

    for {child, column, parent} <- @organization_parents do
      parent_id = if parent == "garages", do: foreign_garage.id, else: foreign_type.id

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            insert_asset_link!(child, column, org.id, version.id, parent_id)
          end)
        end

      assert error.postgres.code == :foreign_key_violation
      assert error.postgres.constraint == "#{child}_#{column}_owner_fkey"
      assert is_binary(insert_asset_link!(child, column, org.id, version.id, nil))
    end
  end

  test "deleting a default garage still clears its nullable setting" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    garage = garage_fixture(org.id)

    id =
      insert_asset_link!("blocking_settings", "default_garage_id", org.id, version.id, garage.id)

    Repo.query!("DELETE FROM garages WHERE id = $1", [Ecto.UUID.dump!(garage.id)])

    assert %{rows: [[nil]]} =
             Repo.query!("SELECT default_garage_id FROM blocking_settings WHERE id = $1", [
               Ecto.UUID.dump!(id)
             ])
  end

  test "new writes reject a version from another organization" do
    org = organization_fixture()
    other = organization_fixture()
    other_version = gtfs_version_fixture(other.id)
    now = DateTime.utc_now()

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.insert_all(Route, [
            %{
              id: Ecto.UUID.generate(),
              route_id: "foreign",
              route_type: 3,
              organization_id: org.id,
              gtfs_version_id: other_version.id,
              inserted_at: now,
              updated_at: now
            }
          ])
        end)
      end

    assert error.postgres.code == :foreign_key_violation
    assert error.postgres.constraint == "routes_version_owner_fkey"
  end

  test "trip assignments reject a foreign version on insert and update" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    route = route_fixture(org.id, version.id)
    trip = trip_fixture(org.id, version.id, route.route_id)
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)

    # Isolate the version key from the separate trip-parent key.
    Repo.query!("ALTER TABLE trip_runs DROP CONSTRAINT trip_runs_trips_owner_fkey")

    assert_fk_violation!("trip_runs_version_owner_fkey", fn ->
      insert_trip_run!(org.id, foreign_version.id, trip.id, "R2")
    end)

    id = insert_trip_run!(org.id, version.id, trip.id, "R1")

    assert_fk_violation!("trip_runs_version_owner_fkey", fn ->
      Repo.query!("UPDATE trip_runs SET gtfs_version_id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(foreign_version.id),
        Ecto.UUID.dump!(id)
      ])
    end)

    assert Repo.get!(TripRun, id).gtfs_version_id == version.id
  end

  test "trip assignments reject same-organization cross-version and foreign-organization trips" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    other_version = gtfs_version_fixture(org.id)
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)
    route = route_fixture(org.id, version.id)
    other_route = route_fixture(org.id, other_version.id)
    foreign_route = route_fixture(foreign_org.id, foreign_version.id)
    trip = trip_fixture(org.id, version.id, route.route_id)
    other_trip = trip_fixture(org.id, other_version.id, other_route.route_id)
    foreign_trip = trip_fixture(foreign_org.id, foreign_version.id, foreign_route.route_id)

    for bad_trip <- [other_trip, foreign_trip] do
      assert_fk_violation!("trip_runs_trips_owner_fkey", fn ->
        insert_trip_run!(org.id, version.id, bad_trip.id, "R2")
      end)
    end

    id = insert_trip_run!(org.id, version.id, trip.id, "R1")

    for bad_trip <- [other_trip, foreign_trip] do
      assert_fk_violation!("trip_runs_trips_owner_fkey", fn ->
        Repo.query!("UPDATE trip_runs SET trip_id = $1 WHERE id = $2", [
          Ecto.UUID.dump!(bad_trip.id),
          Ecto.UUID.dump!(id)
        ])
      end)
    end

    assert Repo.get!(TripRun, id).trip_id == trip.id
  end

  test "trip deletion cascades and populated version deletion still refuses before and after scoped keys" do
    # Keep the named savepoint outside the Sandbox's per-query savepoint wrapper.
    Repo.query!("SAVEPOINT prior_runs_ownership", [], sandbox_subtransaction: false)
    Repo.query!("ALTER TABLE trip_runs DROP CONSTRAINT trip_runs_version_owner_fkey")
    Repo.query!("ALTER TABLE trip_runs DROP CONSTRAINT trip_runs_trips_owner_fkey")
    assert_trip_and_version_cascades!()
    Repo.query!("ROLLBACK TO SAVEPOINT prior_runs_ownership", [], sandbox_subtransaction: false)
    Repo.query!("RELEASE SAVEPOINT prior_runs_ownership", [], sandbox_subtransaction: false)

    assert_trip_and_version_cascades!()
  end

  test "new stop levels reject a parent from another version of the same organization" do
    org = organization_fixture()
    first = gtfs_version_fixture(org.id)
    second = gtfs_version_fixture(org.id)
    foreign_stop = stop_fixture(org.id, first.id, %{location_type: 1})
    level = level_fixture(org.id, second.id)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!(
            """
            INSERT INTO stop_levels
              (id, stop_id, level_id, organization_id, gtfs_version_id, inserted_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, now(), now())
            """,
            [
              Ecto.UUID.dump!(Ecto.UUID.generate()),
              Ecto.UUID.dump!(foreign_stop.id),
              Ecto.UUID.dump!(level.id),
              Ecto.UUID.dump!(org.id),
              Ecto.UUID.dump!(second.id)
            ]
          )
        end)
      end

    assert error.postgres.code == :foreign_key_violation
    assert error.postgres.constraint == "stop_levels_stops_owner_fkey"
  end

  test "a trip with no timed pattern uses MATCH SIMPLE and inserts" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    now = DateTime.utc_now()

    assert {1, _} =
             Repo.insert_all(Trip, [
               %{
                 id: Ecto.UUID.generate(),
                 trip_id: "unlinked",
                 route_id: "route",
                 service_id: "service",
                 timed_pattern_id: nil,
                 organization_id: org.id,
                 gtfs_version_id: version.id,
                 inserted_at: now,
                 updated_at: now
               }
             ])
  end

  test "journal entries reject a station from another version of the same organization" do
    org = organization_fixture()
    first = gtfs_version_fixture(org.id)
    second = gtfs_version_fixture(org.id)
    station = stop_fixture(org.id, first.id, %{location_type: 1})

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!(
            """
            INSERT INTO journal_entries
              (id, organization_id, gtfs_version_id, station_id, author_id, target_type,
               captured_at, inserted_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, 'station', now(), now(), now())
            """,
            [
              Ecto.UUID.dump!(Ecto.UUID.generate()),
              Ecto.UUID.dump!(org.id),
              Ecto.UUID.dump!(second.id),
              Ecto.UUID.dump!(station.id),
              Ecto.UUID.dump!(@actor.id)
            ]
          )
        end)
      end

    assert error.postgres.code == :foreign_key_violation
    assert error.postgres.constraint == "journal_entries_stops_owner_fkey"
  end

  test "organization deletion still cascades routes, trips and change logs" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    route = route_fixture(org.id, version.id)
    garage = garage_fixture(org.id)
    vehicle_type = vehicle_type_fixture(org.id)
    upstream_ids = insert_upstream_rows!(org.id, version.id, garage.id, vehicle_type.id)
    now = DateTime.utc_now()
    trip_id = Ecto.UUID.generate()
    log_id = Ecto.UUID.generate()

    assert {1, _} =
             Repo.insert_all(Trip, [
               %{
                 id: trip_id,
                 trip_id: "T1",
                 route_id: route.route_id,
                 service_id: "S1",
                 organization_id: org.id,
                 gtfs_version_id: version.id,
                 inserted_at: now,
                 updated_at: now
               }
             ])

    run_id = insert_trip_run!(org.id, version.id, trip_id, "R1")

    Repo.query!(
      """
      INSERT INTO change_logs
        (id, entity_type, entity_external_id, station_stop_id, actor_id, actor_email,
         action, organization_id, gtfs_version_id, inserted_at)
      VALUES ($1, 'route', 'R1', 'station', $2, 'operator@example.com', 'created', $3, $4, now())
      """,
      [
        Ecto.UUID.dump!(log_id),
        Ecto.UUID.dump!(@actor.id),
        Ecto.UUID.dump!(org.id),
        Ecto.UUID.dump!(version.id)
      ]
    )

    assert {:ok, _} = Organizations.delete_organization(org)
    assert is_nil(Repo.get(GtfsVersion, version.id))
    assert is_nil(Repo.get(Route, route.id))
    assert is_nil(Repo.get(Trip, trip_id))
    assert is_nil(Repo.get(TripRun, run_id))

    for {table, id} <- upstream_ids do
      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM #{table} WHERE id = $1", [Ecto.UUID.dump!(id)])
    end

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM change_logs WHERE id = $1", [
               Ecto.UUID.dump!(log_id)
             ])
  end

  test "organization deletion cascaded trip assignments before the new scoped keys" do
    # Keep the named savepoint outside the Sandbox's per-query savepoint wrapper.
    Repo.query!("SAVEPOINT prior_runs_organization", [], sandbox_subtransaction: false)
    Repo.query!("ALTER TABLE trip_runs DROP CONSTRAINT trip_runs_version_owner_fkey")
    Repo.query!("ALTER TABLE trip_runs DROP CONSTRAINT trip_runs_trips_owner_fkey")

    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    route = route_fixture(org.id, version.id)
    trip = trip_fixture(org.id, version.id, route.route_id)
    run_id = insert_trip_run!(org.id, version.id, trip.id, "R1")
    log_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO change_logs
        (id, entity_type, entity_external_id, station_stop_id, actor_id, actor_email,
         action, organization_id, gtfs_version_id, inserted_at)
      VALUES ($1, 'route', 'R1', 'station', $2, 'operator@example.com', 'created', $3, $4, now())
      """,
      Enum.map([log_id, @actor.id, org.id, version.id], &Ecto.UUID.dump!/1)
    )

    assert {:ok, _} = Organizations.delete_organization(org)
    assert is_nil(Repo.get(GtfsVersion, version.id))
    assert is_nil(Repo.get(Route, route.id))
    assert is_nil(Repo.get(Trip, trip.id))
    assert is_nil(Repo.get(TripRun, run_id))

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM change_logs WHERE id = $1", [
               Ecto.UUID.dump!(log_id)
             ])

    Repo.query!("ROLLBACK TO SAVEPOINT prior_runs_organization", [],
      sandbox_subtransaction: false
    )

    Repo.query!("RELEASE SAVEPOINT prior_runs_organization", [], sandbox_subtransaction: false)
    assert Map.has_key?(constraints(), "trip_runs_trips_owner_fkey")
  end

  test "existing stop ownership blocks organization deletion until its journal and stop are removed" do
    assert {:ok, :baseline_observed} =
             Repo.transaction(fn ->
               Repo.query!("SAVEPOINT baseline_scope")

               for {table, constraint} <- [
                     {"journal_entries", "journal_entries_stops_owner_fkey"},
                     {"journal_entries", "journal_entries_version_owner_fkey"},
                     {"stops", "stops_version_owner_fkey"}
                   ] do
                 Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{constraint}")
               end

               {org, version, station, journal_id} = insert_station_journal()
               assert_organization_delete_refused(org, version, station, journal_id)
               Repo.query!("ROLLBACK TO SAVEPOINT baseline_scope")
               :baseline_observed
             end)

    assert Map.has_key?(constraints(), "journal_entries_stops_owner_fkey")

    {org, version, station, journal_id} = insert_station_journal()

    assert {:ok, :after_observed} =
             Repo.transaction(fn ->
               assert_organization_delete_refused(org, version, station, journal_id)
               :after_observed
             end)

    assert {:ok, _} = Repo.delete(station)

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM journal_entries WHERE id = $1", [
               Ecto.UUID.dump!(journal_id)
             ])

    assert {:ok, _} = Organizations.delete_organization(org)
    assert is_nil(Repo.get(GtfsVersion, version.id))
  end

  defp insert_station_journal do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    station = stop_fixture(org.id, version.id, %{location_type: 1})
    journal_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO journal_entries
        (id, organization_id, gtfs_version_id, station_id, author_id, target_type,
         captured_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, 'station', now(), now(), now())
      """,
      [
        Ecto.UUID.dump!(journal_id),
        Ecto.UUID.dump!(org.id),
        Ecto.UUID.dump!(version.id),
        Ecto.UUID.dump!(station.id),
        Ecto.UUID.dump!(@actor.id)
      ]
    )

    {org, version, station, journal_id}
  end

  defp assert_organization_delete_refused(org, version, station, journal_id) do
    Repo.query!("SAVEPOINT organization_delete")

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!("DELETE FROM organizations WHERE id = $1", [Ecto.UUID.dump!(org.id)])
      end

    Repo.query!("ROLLBACK TO SAVEPOINT organization_delete")

    assert error.postgres.code == :foreign_key_violation
    assert error.postgres.constraint == "stops_organization_id_fkey"
    assert Repo.get!(Organization, org.id)
    assert Repo.get!(GtfsVersion, version.id)
    assert Repo.get!(Stop, station.id)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM journal_entries WHERE id = $1", [
               Ecto.UUID.dump!(journal_id)
             ])
  end

  test "a full imported feed can be failed and cleaned without losing its receipt" do
    org = organization_fixture()

    # Creating a target and claiming a cleanup reauthorize their actor, so both are active editors.
    operator = editor_fixture(org)
    cleaner = editor_fixture(org)
    actor = %{id: operator.id, email: operator.email}
    cleanup_actor = %{id: cleaner.id, email: cleaner.email}

    {:ok, %{run: run, version: version}} =
      ImportRuns.create_pending_target(org.id, actor, %{name: "Ownership cleanup"})

    {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

    fixture_path = Path.expand("../../../fixtures/gtfs/ownership_cleanup_feed.json", __DIR__)
    feed = fixture_path |> File.read!() |> Jason.decode!()
    assert Enum.sort(Map.keys(feed)) == Enum.sort(Import.supported_filenames())

    files = Enum.map(feed, fn {filename, content} -> %{filename: filename, content: content} end)
    assert {:ok, result} = StagedImport.import_files(org.id, version.id, files)

    garage = garage_fixture(org.id)
    vehicle_type = vehicle_type_fixture(org.id)
    upstream_ids = insert_upstream_rows!(org.id, version.id, garage.id, vehicle_type.id)

    trip =
      Repo.all(Trip)
      |> Enum.find(&(&1.organization_id == org.id and &1.gtfs_version_id == version.id))

    assert trip
    run_id = insert_trip_run!(org.id, version.id, trip.id, "R1")

    assert result.counts
           |> Map.drop([:patterns_created, :timings_created, :trips_linked, :trips_custom])
           |> Enum.all?(fn {_name, count} -> count > 0 end)

    failure =
      Import.Failure.from_error(:unknown,
        phase: :phase_2,
        outcome: :failed,
        committed_counts: result.counts
      )

    assert {:ok, _, _} = ImportRuns.fail_import(org.id, run.id, token, failure)

    assert {:ok, _, claimed_version, cleanup_token} =
             ImportRuns.claim_cleanup(org.id, run.id, cleanup_actor)

    assert {:ok, nil} = Recovery.discard_claimed(run, claimed_version, cleanup_token)
    assert is_nil(Repo.get(GtfsVersion, version.id))
    assert is_nil(Repo.get(TripRun, run_id))

    for {table, id} <- upstream_ids do
      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM #{table} WHERE id = $1", [Ecto.UUID.dump!(id)])
    end

    assert Repo.get!(GtfsPlanner.Operations.Garage, garage.id)
    assert Repo.get!(GtfsPlanner.Operations.VehicleType, vehicle_type.id)

    receipt = Repo.get!(Run, run.id)
    assert receipt.state == "cleaned"
    assert receipt.gtfs_version_id == version.id
    assert receipt.version_name == "Ownership cleanup"
    assert receipt.actor_id == actor.id
    assert receipt.actor_email == actor.email
  end

  defp constraints do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.conname, child.relname, parent.relname, pg_get_constraintdef(c.oid), c.confdeltype
      FROM pg_constraint AS c
      JOIN pg_class AS child ON child.oid = c.conrelid
      JOIN pg_class AS parent ON parent.oid = c.confrelid
      JOIN pg_namespace AS ns ON ns.oid = child.relnamespace
      WHERE ns.nspname = 'public' AND c.contype = 'f'
      """)

    Map.new(rows, fn [name, child, parent, definition, delete_rule] ->
      {name, {child, parent, definition, delete_rule}}
    end)
  end

  defp unique_scoped_index?(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pg_get_indexdef(i.indexrelid)
        FROM pg_index AS i
        JOIN pg_class AS t ON t.oid = i.indrelid
        JOIN pg_namespace AS n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public' AND t.relname = $1 AND i.indisunique
        """,
        [table]
      )

    Enum.any?(rows, fn [definition] ->
      String.ends_with?(definition, "(id, organization_id, gtfs_version_id)")
    end)
  end

  defp unique_organization_index?(table) do
    name = "#{table}_id_organization_id_owner_index"

    %{rows: [[definition]]} =
      Repo.query!(
        """
        SELECT pg_get_indexdef(i.indexrelid)
        FROM pg_index AS i
        JOIN pg_class AS idx ON idx.oid = i.indexrelid
        JOIN pg_namespace AS ns ON ns.oid = idx.relnamespace
        WHERE ns.nspname = 'public' AND idx.relname = $1 AND i.indisunique
        """,
        [name]
      )

    String.ends_with?(definition, "(id, organization_id)")
  end

  defp unique_runs_trip_index? do
    %{rows: [[definition]]} =
      Repo.query!("""
      SELECT indexdef FROM pg_indexes
      WHERE schemaname = 'public'
        AND indexname = 'trips_id_organization_id_gtfs_version_id_owner_index'
      """)

    String.ends_with?(definition, "(id, organization_id, gtfs_version_id)")
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

  defp assert_fk_violation!(constraint, operation) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> operation.() end)
      end

    assert error.postgres.code == :foreign_key_violation
    assert error.postgres.constraint == constraint
  end

  defp assert_trip_and_version_cascades! do
    org = organization_fixture()
    route_only_version = gtfs_version_fixture(org.id)
    route_only = route_fixture(org.id, route_only_version.id)

    assert_fk_violation!("routes_version_owner_fkey", fn ->
      Repo.query!("DELETE FROM gtfs_versions WHERE id = $1", [
        Ecto.UUID.dump!(route_only_version.id)
      ])
    end)

    assert Repo.get!(GtfsVersion, route_only_version.id)
    assert Repo.get!(Route, route_only.id)
    assert {:ok, _} = Repo.delete(route_only)
    assert {:ok, _} = Repo.delete(route_only_version)

    version = gtfs_version_fixture(org.id)
    route = route_fixture(org.id, version.id)
    first = trip_fixture(org.id, version.id, route.route_id)
    second = trip_fixture(org.id, version.id, route.route_id)
    first_run = insert_trip_run!(org.id, version.id, first.id, "R1")
    second_run = insert_trip_run!(org.id, version.id, second.id, "R2")
    log_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO change_logs
        (id, entity_type, entity_external_id, station_stop_id, actor_id, actor_email,
         action, organization_id, gtfs_version_id, inserted_at)
      VALUES ($1, 'route', 'R1', 'station', $2, 'operator@example.com', 'created', $3, $4, now())
      """,
      Enum.map([log_id, @actor.id, org.id, version.id], &Ecto.UUID.dump!/1)
    )

    assert_fk_violation_one_of!(["routes_version_owner_fkey", "trips_version_owner_fkey"], fn ->
      Repo.query!("DELETE FROM gtfs_versions WHERE id = $1", [Ecto.UUID.dump!(version.id)])
    end)

    assert Repo.get!(GtfsVersion, version.id)
    assert Repo.get!(Route, route.id)
    assert Repo.get!(Trip, first.id)
    assert Repo.get!(Trip, second.id)
    assert Repo.get!(TripRun, first_run)
    assert Repo.get!(TripRun, second_run)
    assert change_log_exists?(log_id)

    assert {:ok, _} = Repo.delete(first)
    assert is_nil(Repo.get(TripRun, first_run))
    assert Repo.get!(TripRun, second_run)

    assert {:ok, _} = Repo.delete(route)

    assert_fk_violation!("trips_version_owner_fkey", fn ->
      Repo.query!("DELETE FROM gtfs_versions WHERE id = $1", [Ecto.UUID.dump!(version.id)])
    end)

    assert Repo.get!(TripRun, second_run)
    assert Repo.get!(Trip, second.id)
    assert Repo.get!(GtfsVersion, version.id)
    assert change_log_exists?(log_id)
    assert {:ok, _} = Repo.delete(second)
    assert is_nil(Repo.get(TripRun, second_run))
    assert is_nil(Repo.get(Trip, second.id))
    Repo.query!("DELETE FROM change_logs WHERE id = $1", [Ecto.UUID.dump!(log_id)])
    assert {:ok, _} = Repo.delete(version)
  end

  defp assert_fk_violation_one_of!(constraints, operation) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> operation.() end)
      end

    assert error.postgres.code == :foreign_key_violation
    assert error.postgres.constraint in constraints
  end

  defp change_log_exists?(id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM change_logs WHERE id = $1", [Ecto.UUID.dump!(id)])

    count == 1
  end

  defp insert_upstream_rows!(org_id, version_id, garage_id, vehicle_type_id) do
    block_id = Ecto.UUID.generate()
    route_id = Ecto.UUID.generate()
    deadhead_id = Ecto.UUID.generate()
    relief_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO block_attributes
        (id, organization_id, gtfs_version_id, service_id, block_id, garage_id,
         vehicle_type_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'SERVICE', $4, $5, $6, now(), now())
      """,
      Enum.map([block_id, org_id, version_id], &Ecto.UUID.dump!/1) ++
        ["BLOCK_#{block_id}", Ecto.UUID.dump!(garage_id), Ecto.UUID.dump!(vehicle_type_id)]
    )

    Repo.query!(
      """
      INSERT INTO route_operating_settings
        (id, organization_id, gtfs_version_id, route_id, garage_id,
         required_vehicle_type_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'ROUTE', $4, $5, now(), now())
      """,
      Enum.map([route_id, org_id, version_id, garage_id, vehicle_type_id], &Ecto.UUID.dump!/1)
    )

    Repo.query!(
      """
      INSERT INTO deadhead_times
        (id, organization_id, gtfs_version_id, from_ref, to_ref, minutes, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'stop:START', 'stop:END', 12, now(), now())
      """,
      Enum.map([deadhead_id, org_id, version_id], &Ecto.UUID.dump!/1)
    )

    Repo.query!(
      """
      INSERT INTO relief_points
        (id, organization_id, gtfs_version_id, stop_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'STOP', now(), now())
      """,
      Enum.map([relief_id, org_id, version_id], &Ecto.UUID.dump!/1)
    )

    [
      {"block_attributes", block_id},
      {"route_operating_settings", route_id},
      {"deadhead_times", deadhead_id},
      {"relief_points", relief_id}
    ]
  end

  defp insert_asset_link!(child, column, org_id, version_id, parent_id) do
    id = Ecto.UUID.generate()
    ids = [Ecto.UUID.dump!(id), Ecto.UUID.dump!(org_id), Ecto.UUID.dump!(version_id)]
    parent = if parent_id, do: Ecto.UUID.dump!(parent_id), else: nil

    case child do
      "block_attributes" ->
        Repo.query!(
          """
          INSERT INTO block_attributes
            (id, organization_id, gtfs_version_id, service_id, block_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, 'SERVICE', $4, $5, now(), now())
          """,
          ids ++ ["BLOCK_#{id}", parent]
        )

      "route_operating_settings" ->
        Repo.query!(
          """
          INSERT INTO route_operating_settings
            (id, organization_id, gtfs_version_id, route_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, now(), now())
          """,
          ids ++ ["ROUTE_#{id}", parent]
        )

      "blocking_settings" ->
        Repo.query!(
          """
          INSERT INTO blocking_settings
            (id, organization_id, gtfs_version_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, now(), now())
          """,
          ids ++ [parent]
        )

      "vehicles" ->
        Repo.query!(
          """
          INSERT INTO vehicles
            (id, organization_id, vehicle_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, now(), now())
          """,
          Enum.take(ids, 2) ++ ["VEHICLE_#{id}", parent]
        )
    end

    id
  end
end
