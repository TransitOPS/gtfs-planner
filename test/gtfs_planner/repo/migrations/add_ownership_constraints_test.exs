defmodule GtfsPlanner.Repo.Migrations.AddOwnershipConstraintsTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.Recovery
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Integrity.OwnershipAudit
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @containment [
    {"stop_levels", "stop_id", "stops"},
    {"stop_levels", "level_id", "levels"},
    {"route_pattern_stops", "route_pattern_id", "route_patterns"},
    {"timed_patterns", "route_pattern_id", "route_patterns"},
    {"trips", "timed_pattern_id", "timed_patterns"},
    {"alignment_segments", "from_occurrence_id", "route_pattern_stops"},
    {"flex_areas", "flex_service_id", "flex_services"},
    {"journal_entries", "station_id", "stops"},
    {"station_editing_statuses", "station_id", "stops"}
  ]

  @actor %{id: Ecto.UUID.generate(), email: "operator@example.com"}
  @cleanup_actor %{id: Ecto.UUID.generate(), email: "cleaner@example.com"}

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

    refute Enum.any?(constraints, fn {_name, {child, parent, _definition, _delete_rule}} ->
             child == "gtfs_import_runs" and parent == "gtfs_versions"
           end)

    assert {"journal_entries", "stops",
            "FOREIGN KEY (station_id) REFERENCES stops(id) ON DELETE CASCADE", "c"} =
             Map.fetch!(constraints, "journal_entries_station_id_fkey")

    for table <- ~w(route_patterns timed_patterns route_pattern_stops flex_services) do
      assert unique_scoped_index?(table)
    end
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

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM change_logs WHERE id = $1", [
               Ecto.UUID.dump!(log_id)
             ])
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

    assert {:ok, _} = Gtfs.delete_stop(station)

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

    {:ok, %{run: run, version: version}} =
      ImportRuns.create_pending_target(org.id, @actor, %{name: "Ownership cleanup"})

    {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

    fixture_path = Path.expand("../../../fixtures/gtfs/ownership_cleanup_feed.json", __DIR__)
    feed = fixture_path |> File.read!() |> Jason.decode!()
    assert Enum.sort(Map.keys(feed)) == Enum.sort(Import.supported_filenames())

    files = Enum.map(feed, fn {filename, content} -> %{filename: filename, content: content} end)
    assert {:ok, result} = Import.import_files(org.id, version.id, files)

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
             ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

    assert {:ok, nil} = Recovery.discard_claimed(run, claimed_version, cleanup_token)
    assert is_nil(Repo.get(GtfsVersion, version.id))

    receipt = Repo.get!(Run, run.id)
    assert receipt.state == "cleaned"
    assert receipt.gtfs_version_id == version.id
    assert receipt.version_name == "Ownership cleanup"
    assert receipt.actor_id == @actor.id
    assert receipt.actor_email == @actor.email
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
end
