defmodule GtfsPlanner.Gtfs.Calendars.InputWriterConcurrencyTest do
  # AC-15/AC-16: `Gtfs.create_trip/1`, `Gtfs.create_stop_time/1` and `Gtfs.create_agency/1`
  # must take the scoped version share lock before their insert, so a calendar change that
  # owns the same version row `FOR UPDATE` cannot commit a reviewed input between a review
  # load and its apply. A staging scope keeps writing because `Versions.lock_for_input_write!/2`
  # is a scoped row lock, not an authorization check. The same boundary covers the named
  # schedule, pattern, stop/parent, bulk geometry/naming/rollback, published pathway-import and
  # blocking-settings writers, whose contention cases live in the later describes below.
  #
  # `async: false` plus `Sandbox.unboxed_run/2` gives every participant its own committing
  # PostgreSQL connection. Contention is proven by polling `pg_blocking_pids/1` for the
  # holder's own backend until the writer is genuinely waiting, so no timing sleep is the
  # proof, while the parent connection reads the rows that must not exist yet.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner/gtfs/calendars/input_writer_concurrency_test.exs`.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Import.{ChangeDecision, ChangeRun, ChangeRuns}
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @collect_timeout 15_000
  @contention_timeout 10_000
  @poll_interval 10

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  describe "Versions.lock_for_input_write!/2" do
    test "locks the scoped version row and reports a foreign or unknown scope as :not_found" do
      scope = seed_scope("lock")
      other = seed_scope("lock-other")
      on_exit(fn -> cleanup([scope.organization.id, other.organization.id]) end)

      assert {:ok, %GtfsVersion{} = locked} =
               lock_scope(scope.organization.id, scope.version.id)

      assert locked.id == scope.version.id
      assert locked.organization_id == scope.organization.id

      # The lock is not an authorization check: an unpublished import scope is locked too.
      assert {:ok, %GtfsVersion{publication_status: "staging"}} =
               lock_scope(scope.organization.id, scope.staging_version.id)

      assert {:error, :not_found} = lock_scope(scope.organization.id, other.version.id)
      assert {:error, :not_found} = lock_scope(scope.organization.id, Ecto.UUID.generate())
      assert {:error, :not_found} = lock_scope(nil, nil)
    end

    test "calendar reads and schedule writers keep their own published requirement" do
      scope = seed_scope("published")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      assert {:ok, _calendars} =
               unboxed(fn ->
                 Calendars.list_calendars(scope.organization.id, scope.version.id)
               end)

      assert {:error, :not_found} =
               unboxed(fn ->
                 Calendars.list_calendars(scope.organization.id, scope.staging_version.id)
               end)
    end
  end

  describe "direct input writers" do
    test "an exclusive version holder blocks create_trip and create_stop_time until it releases",
         %{supervisor: supervisor} do
      scope = seed_scope("blocked")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {trip_writer, trip_backend} =
        start_writer(supervisor, fn -> Gtfs.create_trip(trip_attrs(scope, "BLOCKED_TRIP")) end)

      {stop_time_writer, stop_time_backend} =
        start_writer(supervisor, fn -> Gtfs.create_stop_time(stop_time_attrs(scope, 1)) end)

      send(trip_writer.pid, :go)
      send(stop_time_writer.pid, :go)

      assert_blocked_by(trip_backend, holder_backend)
      assert_blocked_by(stop_time_backend, holder_backend)

      # Nothing was written while the version was exclusively owned, even though the
      # writers had already issued their inserts.
      assert trip_ids(scope) == []
      assert stop_time_ids(scope) == []

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Trip{trip_id: "BLOCKED_TRIP"}} = Task.await(trip_writer, @collect_timeout)
      assert {:ok, %StopTime{}} = Task.await(stop_time_writer, @collect_timeout)

      assert trip_ids(scope) == ["BLOCKED_TRIP"]
      assert length(stop_time_ids(scope)) == 1
    end

    test "an agency that would change the display zone waits behind the exclusive version lock",
         %{supervisor: supervisor} do
      scope = seed_scope("agency")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      # No agency yet: the review's display clock falls back to UTC.
      assert %{timezone: "UTC", fallback?: true, fallback_reason: :missing} =
               unboxed(fn ->
                 Gtfs.resolve_display_zone(scope.organization.id, scope.version.id)
               end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn ->
          Gtfs.create_agency(agency_attrs(scope, "America/New_York"))
        end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # The zone the review loaded cannot change while the version lock is held.
      assert %{timezone: "UTC", fallback?: true} =
               unboxed(fn ->
                 Gtfs.resolve_display_zone(scope.organization.id, scope.version.id)
               end)

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}
      assert {:ok, %Agency{}} = Task.await(writer, @collect_timeout)

      assert %{timezone: "America/New_York", fallback?: false} =
               unboxed(fn ->
                 Gtfs.resolve_display_zone(scope.organization.id, scope.version.id)
               end)
    end

    test "an independent organization writes while another version is locked and a foreign scope is refused",
         %{supervisor: supervisor} do
      first = seed_scope("independent-first")
      second = seed_scope("independent-second")
      on_exit(fn -> cleanup([first.organization.id, second.organization.id]) end)

      {holder, holder_backend} = hold_exclusive_version(first, supervisor)

      {blocked_writer, blocked_backend} =
        start_writer(supervisor, fn -> Gtfs.create_trip(trip_attrs(first, "WAITING_TRIP")) end)

      send(blocked_writer.pid, :go)
      assert_blocked_by(blocked_backend, holder_backend)

      # The independent scope is not serialized by the first organization's exclusive lock.
      assert {:ok, %Trip{trip_id: "INDEPENDENT_TRIP"}} =
               unboxed(fn -> Gtfs.create_trip(trip_attrs(second, "INDEPENDENT_TRIP")) end)

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}
      assert {:ok, %Trip{trip_id: "WAITING_TRIP"}} = Task.await(blocked_writer, @collect_timeout)

      # A scope pairing one organization with another organization's version is refused.
      assert {:error, :not_found} =
               unboxed(fn ->
                 Gtfs.create_trip(
                   trip_attrs(first, "FOREIGN_TRIP", %{
                     organization_id: second.organization.id
                   })
                 )
               end)

      assert {:error, :not_found} =
               unboxed(fn ->
                 Gtfs.create_stop_time(
                   stop_time_attrs(first, 9, %{organization_id: second.organization.id})
                 )
               end)

      refute unboxed(fn ->
               Repo.exists?(
                 from(t in Trip,
                   where:
                     t.organization_id == ^second.organization.id and
                       t.gtfs_version_id == ^first.version.id
                 )
               )
             end)
    end

    test "a staging import scope keeps its permitted writes", %{supervisor: supervisor} do
      scope = seed_scope("staging")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      # The organization's published version is exclusively owned, as a calendar change
      # would own it; the staging version is a different row and stays writable.
      {holder, _holder_backend} = hold_exclusive_version(scope, supervisor)

      assert {:ok, %Trip{trip_id: "STAGING_TRIP"}} =
               unboxed(fn ->
                 Gtfs.create_trip(
                   trip_attrs(scope, "STAGING_TRIP", %{gtfs_version_id: scope.staging_version.id})
                 )
               end)

      assert {:ok, %StopTime{}} =
               unboxed(fn ->
                 Gtfs.create_stop_time(
                   stop_time_attrs(scope, 2, %{gtfs_version_id: scope.staging_version.id})
                 )
               end)

      assert {:ok, %Agency{}} =
               unboxed(fn ->
                 Gtfs.create_agency(
                   agency_attrs(scope, "Europe/Berlin", %{
                     gtfs_version_id: scope.staging_version.id
                   })
                 )
               end)

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      # Publication rules are unchanged by the writer path: the scope is still unpublished.
      assert %GtfsVersion{publication_status: "staging", published_at: nil} =
               unboxed(fn ->
                 Repo.get!(GtfsVersion, scope.staging_version.id)
               end)
    end
  end

  describe "schedule callers" do
    test "a schedule caller completes while another session holds the version share lock",
         %{supervisor: supervisor} do
      scope = seed_schedule_scope("share")
      on_exit(fn -> cleanup_schedule_scope(scope) end)

      # Another session already holds the organization's version row `FOR SHARE`, exactly as a
      # concurrent calendar read or schedule writer does while it works.
      {share_holder, _holder_backend} = hold_shared_version(scope, supervisor)

      # The real schedule caller takes the same share lock first, then the route, pattern, trip and
      # stop-time locks. An upgraded (exclusive) version lock would refuse this second holder, so a
      # bounded lock timeout turns any upgrade into a loud failure instead of a hang.
      assert {:ok, %{trips: [created]}} =
               unboxed(fn ->
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL lock_timeout = '3s'")

                   {:ok, result} =
                     Gtfs.create_trips(scope.route_id, create_attrs(scope), scope.audit)

                   result
                 end)
               end)

      # The other session held its share lock for the whole call.
      assert Process.alive?(share_holder.pid)

      assert created.trip_id == "#{scope.route_id}-0-#{scope.service}-0700"
      assert unboxed(fn -> trip_ids(scope) end) == [created.trip_id]

      assert unboxed(fn -> stop_time_clocks(scope, created.trip_id) end) == [
               {"A", "07:00:00", "07:00:00"},
               {"B", "07:05:00", "07:05:30"}
             ]

      send(share_holder.pid, :release)
      assert Task.await(share_holder, @collect_timeout) == {:error, :released}
    end

    test "a schedule caller waiting on the route row holds only the shared version lock",
         %{supervisor: supervisor} do
      scope = seed_schedule_scope("route-wait")
      on_exit(fn -> cleanup_schedule_scope(scope) end)

      {route_holder, route_backend} = hold_route_row(scope, supervisor)

      {caller, caller_backend} =
        start_writer(supervisor, fn ->
          Gtfs.create_trips(scope.route_id, create_attrs(scope), scope.audit)
        end)

      send(caller.pid, :go)

      # The caller reached the route lock, which it can only do after the version boundary.
      assert_blocked_by(caller_backend, route_backend)

      # A concurrent share request still succeeds while it waits on the route...
      assert {:ok, %GtfsVersion{}} = share_lock_version(scope)

      # ...and an exclusive request is refused, so the waiting caller does hold the version row,
      # in share mode rather than in an upgraded exclusive one.
      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               exclusive_lock_version(scope)

      send(route_holder.pid, :release)
      assert Task.await(route_holder, @collect_timeout) == {:error, :released}

      assert {:ok, %{trips: [created]}} = Task.await(caller, @collect_timeout)
      assert created.trip_id == "#{scope.route_id}-0-#{scope.service}-0700"
    end
  end

  describe "writer return shapes" do
    test "invalid input keeps the changeset error without requiring a scope or a connection" do
      assert {:error, %Ecto.Changeset{valid?: false}} = Gtfs.create_trip(%{})
      assert {:error, %Ecto.Changeset{valid?: false}} = Gtfs.create_stop_time(%{})
      assert {:error, %Ecto.Changeset{valid?: false}} = Gtfs.create_agency(%{})
    end

    test "a refused duplicate insert releases the version lock for the next writer" do
      scope = seed_scope("duplicate")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      assert {:ok, %Trip{}} = unboxed(fn -> Gtfs.create_trip(trip_attrs(scope, "DUP")) end)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               unboxed(fn -> Gtfs.create_trip(trip_attrs(scope, "DUP")) end)

      # Ecto reports the three-column unique constraint on its first field.
      assert {"has already been taken", opts} = errors[:organization_id]

      assert opts[:constraint_name] == "trips_organization_id_gtfs_version_id_trip_id_index"

      assert {:ok, %Trip{trip_id: "AFTER"}} =
               unboxed(fn -> Gtfs.create_trip(trip_attrs(scope, "AFTER")) end)

      # The refused insert rolled its transaction back, so the version row is free again.
      assert {:ok, :acquired} =
               unboxed(fn ->
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL lock_timeout = '5s'")

                   Repo.one(
                     from(v in GtfsVersion,
                       where: v.id == ^scope.version.id,
                       lock: "FOR UPDATE"
                     )
                   )

                   :acquired
                 end)
               end)
    end
  end

  describe "stop writers" do
    test "a parent coordinate update and a previously absent parent insert wait behind the lock",
         %{supervisor: supervisor} do
      scope = seed_scope("stop-parent")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      parent =
        unboxed(fn ->
          stop_fixture(scope.organization.id, scope.version.id, %{
            stop_id: "PARENT_GEOMETRY",
            location_type: 1,
            stop_lat: Decimal.new("40.0"),
            stop_lon: Decimal.new("-74.0")
          })
        end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {update_writer, update_backend} =
        start_writer(supervisor, fn ->
          Gtfs.update_stop(parent, %{stop_lat: "41.5", stop_lon: "-73.5"})
        end)

      {insert_writer, insert_backend} =
        start_writer(supervisor, fn ->
          Gtfs.create_stop(
            stop_attrs(scope, "PARENT_ADDED", %{
              location_type: 1,
              stop_lat: "42.0",
              stop_lon: "-71.0"
            })
          )
        end)

      send(update_writer.pid, :go)
      send(insert_writer.pid, :go)

      assert_blocked_by(update_backend, holder_backend)
      assert_blocked_by(insert_backend, holder_backend)

      # While the version is exclusively owned, neither the projected coordinate nor the parent
      # row that was previously absent is visible.
      assert coordinates?(stop_coordinates(scope, "PARENT_GEOMETRY"), "40.0", "-74.0")
      assert stop_ids(scope) == ["PARENT_GEOMETRY"]

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_lat: updated_lat}} = Task.await(update_writer, @collect_timeout)
      assert Decimal.equal?(updated_lat, Decimal.new("41.5"))
      assert {:ok, %Stop{stop_id: "PARENT_ADDED"}} = Task.await(insert_writer, @collect_timeout)

      assert coordinates?(stop_coordinates(scope, "PARENT_GEOMETRY"), "41.5", "-73.5")
      assert stop_ids(scope) == ["PARENT_ADDED", "PARENT_GEOMETRY"]
    end

    test "a stop naming an absent parent waits before its phantom becomes visible",
         %{supervisor: supervisor} do
      scope = seed_scope("stop-phantom")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn ->
          Gtfs.create_stop(
            stop_attrs(scope, "PHANTOM_CHILD", %{
              parent_station: "ABSENT_PARENT",
              level_id: "L_ABSENT"
            })
          )
        end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # Neither the referencing stop nor its parent row exists yet, so the parent-coordinate
      # fallback the projection loads cannot change while the version is owned.
      assert stop_ids(scope) == []
      assert stops_named(scope, "ABSENT_PARENT") == []

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_id: "PHANTOM_CHILD", parent_station: "ABSENT_PARENT"}} =
               Task.await(writer, @collect_timeout)

      # The referencing stop now exists; the parent row stays absent, exactly the absence the
      # review fingerprint records.
      assert stop_ids(scope) == ["PHANTOM_CHILD"]
      assert stops_named(scope, "ABSENT_PARENT") == []
    end

    test "a stop delete waits behind the lock, removes the row, and releases the version",
         %{supervisor: supervisor} do
      scope = seed_scope("stop-delete")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      stop =
        unboxed(fn ->
          stop_fixture(scope.organization.id, scope.version.id, %{stop_id: "STOP_TO_DELETE"})
        end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn -> Gtfs.delete_stop(stop) end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)
      assert stop_ids(scope) == ["STOP_TO_DELETE"]

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_id: "STOP_TO_DELETE"}} = Task.await(writer, @collect_timeout)
      assert stop_ids(scope) == []

      # The delete committed and released its share lock, so an exclusive version owner can now
      # take the row.
      assert {:ok, %GtfsVersion{}} = exclusive_lock_version(scope)
    end

    test "a stop-ID cascade waits behind the lock and then rewrites every reference",
         %{supervisor: supervisor} do
      scope = seed_scope("stop-cascade")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      {station, stop_time, transfer} =
        unboxed(fn ->
          station =
            stop_fixture(scope.organization.id, scope.version.id, %{
              stop_id: "CASCADE_STATION",
              location_type: 1
            })

          stop_fixture(scope.organization.id, scope.version.id, %{
            stop_id: "CASCADE_CHILD",
            parent_station: "CASCADE_STATION",
            level_id: "L1"
          })

          stop_time =
            stop_time_fixture(
              scope.organization.id,
              scope.version.id,
              "trip_cascade",
              "CASCADE_STATION"
            )

          transfer =
            transfer_fixture(scope.organization.id, scope.version.id, %{
              from_stop_id: "CASCADE_STATION",
              to_stop_id: "CASCADE_CHILD"
            })

          {station, stop_time, transfer}
        end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn ->
          Gtfs.update_stop_with_cascade(station, %{stop_id: "CASCADE_STATION_RENAMED"})
        end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # No stop row, stop time, transfer or parent reference is rewritten while the version is
      # exclusively owned.
      assert stop_ids(scope) == ["CASCADE_CHILD", "CASCADE_STATION"]
      assert child_parent_stations(scope) == ["CASCADE_STATION"]
      assert stop_time_stop_ids(scope) == ["CASCADE_STATION"]
      assert transfer_stop_ids(scope) == [{"CASCADE_STATION", "CASCADE_CHILD"}]

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_id: "CASCADE_STATION_RENAMED"}} =
               Task.await(writer, @collect_timeout)

      # The linked rows keep pointing at the renamed stop through stop_id itself, so their
      # identities and their existing stop-time rows survive the cascade.
      assert stop_ids(scope) == ["CASCADE_CHILD", "CASCADE_STATION_RENAMED"]
      assert child_parent_stations(scope) == ["CASCADE_STATION_RENAMED"]
      assert stop_time_stop_ids(scope) == ["CASCADE_STATION_RENAMED"]
      assert transfer_stop_ids(scope) == [{"CASCADE_STATION_RENAMED", "CASCADE_CHILD"}]

      assert unboxed(fn -> Repo.get!(StopTime, stop_time.id).stop_id end) ==
               "CASCADE_STATION_RENAMED"

      assert unboxed(fn -> Repo.get!(Transfer, transfer.id).from_stop_id end) ==
               "CASCADE_STATION_RENAMED"
    end
  end

  describe "bulk stop writers" do
    test "a reviewed alignment and a derived child-stop alignment wait behind the version lock",
         %{supervisor: supervisor} do
      scope = seed_scope("bulk-alignment")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      reviewed = seed_alignment_scope(scope, "A", %{x: 50, y: 40}, "1.0", "2.0")
      derived = seed_alignment_scope(scope, "B", %{x: 60, y: 40}, "3.0", "4.0")

      assert {:ok, aligned_derived} =
               unboxed(fn ->
                 Gtfs.update_stop_level_alignment(derived.stop_level, alignment_attrs())
               end)

      audit = bulk_audit(scope, reviewed.station.stop_id)
      on_exit(fn -> cleanup([], [audit.actor_id]) end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {reviewed_writer, reviewed_backend} =
        start_writer(supervisor, fn ->
          Gtfs.save_and_apply_stop_level_alignment(
            reviewed.stop_level.id,
            reviewed.attrs,
            1000,
            800,
            audit
          )
        end)

      {derived_writer, derived_backend} =
        start_writer(supervisor, fn ->
          Gtfs.apply_alignment_to_child_stops(aligned_derived, 1000, 800)
        end)

      send(reviewed_writer.pid, :go)
      send(derived_writer.pid, :go)

      assert_blocked_by(reviewed_backend, holder_backend)
      assert_blocked_by(derived_backend, holder_backend)

      # While the version is exclusively owned, neither child stop's projected geometry is
      # visible and the reviewed stop level still carries no saved alignment.
      assert coordinates?(stop_coordinates(scope, "ALIGN_CHILD_A"), "1.0", "2.0")
      assert coordinates?(stop_coordinates(scope, "ALIGN_CHILD_B"), "3.0", "4.0")
      refute stop_level_aligned?(reviewed.stop_level.id)
      assert stop_change_logs(scope, reviewed.child.id) == []

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok,
              %{
                apply_result: %{
                  updated_stop_count: 1,
                  unchanged_count: 0,
                  unplaced_count: 0
                }
              }} = Task.await(reviewed_writer, @collect_timeout)

      assert {:ok, 1} = Task.await(derived_writer, @collect_timeout)

      refute coordinates?(stop_coordinates(scope, "ALIGN_CHILD_A"), "1.0", "2.0")
      refute coordinates?(stop_coordinates(scope, "ALIGN_CHILD_B"), "3.0", "4.0")
      assert stop_level_aligned?(reviewed.stop_level.id)

      assert [%ChangeLog{entity_type: "stop", action: "updated"}] =
               stop_change_logs(scope, reviewed.child.id)
    end

    test "station naming waits behind the version lock and cannot commit renamed IDs",
         %{supervisor: supervisor} do
      scope = seed_scope("bulk-naming")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      station =
        unboxed(fn ->
          stop_fixture(scope.organization.id, scope.version.id, %{
            stop_id: "NAMING_STATION",
            stop_name: "Naming Station",
            location_type: 1
          })
        end)

      unboxed(fn ->
        stop_fixture(scope.organization.id, scope.version.id, %{
          stop_id: "NAMING_PLATFORM",
          stop_name: "Platform 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ground"
        })
      end)

      # The exact renamed ID comes from the real preview rather than from a naming convention
      # repeated in the test.
      assert {:ok, preview} =
               unboxed(fn ->
                 Gtfs.preview_station_naming(
                   scope.organization.id,
                   scope.version.id,
                   station.stop_id
                 )
               end)

      assert [%{old_id: "NAMING_PLATFORM", new_id: renamed_id}] = preview.rows

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn ->
          Gtfs.apply_station_naming(
            scope.organization.id,
            scope.version.id,
            station.stop_id
          )
        end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # No stop ID and no referencing row was rewritten while the version is exclusively owned.
      assert stop_ids(scope) == ["NAMING_PLATFORM", "NAMING_STATION"]

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %{renamed_stops: 1, updated_pathways: 0, updated_references: 0}} =
               Task.await(writer, @collect_timeout)

      assert stop_ids(scope) == Enum.sort(["NAMING_STATION", renamed_id])
    end

    test "a stop rollback waits behind the version lock and preserves the rollback audit",
         %{supervisor: supervisor} do
      scope = seed_scope("bulk-rollback")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      audit = bulk_audit(scope, "ROLLBACK_STATION")
      on_exit(fn -> cleanup([], [audit.actor_id]) end)

      stop =
        unboxed(fn ->
          stop_fixture(scope.organization.id, scope.version.id, %{
            stop_id: "ROLLBACK_STOP",
            stop_name: "Original"
          })
        end)

      unboxed(fn ->
        Gtfs.record_change(audit, :stop, stop, "updated", %{stop_name: "Changed"})
        Gtfs.update_stop(stop, %{stop_name: "Changed"})
      end)

      log = unboxed(fn -> Repo.one!(stop_change_log_query(scope, stop.id, "updated")) end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn -> Gtfs.rollback_entity(log, audit) end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # The stop name and the rollback journal are untouched while the version is owned.
      assert stop_name(scope, "ROLLBACK_STOP") == "Changed"
      assert stop_change_logs(scope, stop.id, "rolled_back") == []

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_name: "Original", stop_id: "ROLLBACK_STOP"}} =
               Task.await(writer, @collect_timeout)

      assert stop_name(scope, "ROLLBACK_STOP") == "Original"

      assert [%ChangeLog{rolled_back_to_log_id: rolled_back_to}] =
               stop_change_logs(scope, stop.id, "rolled_back")

      assert rolled_back_to == log.id
    end

    test "a published pathway-import stop decision waits, then applies with its audit and lease fence",
         %{supervisor: supervisor} do
      scope = seed_scope("bulk-import-decision")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      run =
        seed_import_run(scope, [
          import_decision("stop:WAITING_STOP", "WAITING_STOP"),
          import_decision("stop:LEASE_STOP", "LEASE_STOP")
        ])

      audit = import_audit_context(run)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn ->
          ChangeRuns.apply_decision(
            scope.organization.id,
            run.run.id,
            "stop:WAITING_STOP",
            run.generation,
            run.token,
            audit
          )
        end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # The entity row, the audit log, the decision row and the run progress are untouched while
      # the version is exclusively owned.
      assert stop_ids(scope) == []
      assert change_logs(scope) == []
      assert import_decision_status("stop:WAITING_STOP") == :approved
      assert import_run_progress(run.run.id) == 0

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %ChangeDecision{status: :applied}} = Task.await(writer, @collect_timeout)

      assert stop_ids(scope) == ["WAITING_STOP"]
      assert import_run_progress(run.run.id) == 1

      assert [
               %ChangeLog{
                 entity_type: "stop",
                 action: "created",
                 station_stop_id: "WAITING_STOP"
               }
             ] = change_logs(scope)

      # The lease fence is unchanged by the new lock: a token that is not the current lease still
      # refuses the decision and writes nothing.
      assert {:error, :lease_lost} =
               unboxed(fn ->
                 ChangeRuns.apply_decision(
                   scope.organization.id,
                   run.run.id,
                   "stop:LEASE_STOP",
                   run.generation,
                   run.token <> "-stale",
                   audit
                 )
               end)

      assert stop_ids(scope) == ["WAITING_STOP"]
      assert import_decision_status("stop:LEASE_STOP") == :approved
      assert import_run_progress(run.run.id) == 1
    end

    test "a full import writes its unpublished target and keeps the publication lifecycle",
         %{supervisor: supervisor} do
      scope = seed_scope("bulk-import-target")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      {holder, _holder_backend} = hold_exclusive_version(scope, supervisor)

      # The import owns its own unpublished target; the published version a combination would own
      # is a different row, so an import-scoped write still commits while it is locked exclusively.
      assert {:ok, %Stop{stop_id: "IMPORTED_STOP"}} =
               unboxed(fn ->
                 Gtfs.import_create_stop(
                   stop_attrs(scope, "IMPORTED_STOP", %{
                     gtfs_version_id: scope.staging_version.id
                   })
                 )
               end)

      assert {:ok, %GtfsVersion{publication_status: "importing", published_at: nil}} =
               unboxed(fn ->
                 Versions.claim_staging_gtfs_version(
                   scope.organization.id,
                   scope.staging_version.id
                 )
               end)

      assert {:ok, %GtfsVersion{publication_status: "published", published_at: published_at}} =
               unboxed(fn ->
                 Versions.publish_importing_gtfs_version(
                   scope.organization.id,
                   scope.staging_version.id
                 )
               end)

      assert %DateTime{} = published_at

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      # The combination-owned published version is untouched, and the imported stop belongs to the
      # import target alone.
      assert %GtfsVersion{publication_status: "published"} =
               unboxed(fn -> Repo.get!(GtfsVersion, scope.version.id) end)

      assert stop_ids_for_version(scope.organization.id, scope.version.id) == []

      assert stop_ids_for_version(scope.organization.id, scope.staging_version.id) == [
               "IMPORTED_STOP"
             ]
    end
  end

  describe "blocking settings writer" do
    test "an existing layover update and a version's first layover row wait behind the lock",
         %{supervisor: supervisor} do
      scope = seed_scope("settings")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      # One version already stores a layover and the other has no settings row, so the upsert's
      # update path and its absent-row insertion path are both observed.
      assert {:ok, %BlockingSetting{min_layover_minutes: 5}} =
               unboxed(fn -> save_layover(scope.organization.id, scope.version.id, 5) end)

      first_row_version = unboxed(fn -> gtfs_version_fixture(scope.organization.id) end)

      {update_holder, update_holder_backend} = hold_exclusive_version(scope, supervisor)

      {insert_holder, insert_holder_backend} =
        hold_exclusive_version(%{scope | version: first_row_version}, supervisor)

      {update_writer, update_backend} =
        start_writer(supervisor, fn ->
          Gtfs.update_blocking_settings(scope.organization.id, scope.version.id, %{
            min_layover_minutes: 9
          })
        end)

      {insert_writer, insert_backend} =
        start_writer(supervisor, fn ->
          Blocking.update_settings(scope.organization.id, first_row_version.id, %{
            min_layover_minutes: 7
          })
        end)

      send(update_writer.pid, :go)
      send(insert_writer.pid, :go)

      assert_blocked_by(update_backend, update_holder_backend)
      assert_blocked_by(insert_backend, insert_holder_backend)

      # While the version is exclusively owned, neither the replaced value nor the version's first
      # row is written; a read still answers the absent-row default and still stores nothing.
      assert stored_layover(scope.organization.id, scope.version.id) == 5
      assert stored_layover(scope.organization.id, first_row_version.id) == nil

      # `get_settings/2` answers the whole eight-key Block rules map, defaults and
      # all, for a version with no stored row.
      assert unboxed(fn -> Blocking.get_settings(scope.organization.id, first_row_version.id) end).min_layover_minutes ==
               5

      assert stored_layover(scope.organization.id, first_row_version.id) == nil

      send(update_holder.pid, :release)
      assert Task.await(update_holder, @collect_timeout) == {:error, :released}

      assert {:ok, %BlockingSetting{min_layover_minutes: 9}} =
               Task.await(update_writer, @collect_timeout)

      assert stored_layover(scope.organization.id, scope.version.id) == 9
      assert layover_rows(scope.organization.id, scope.version.id) == 1
      # The first-row writer still waits on its own version row.
      assert stored_layover(scope.organization.id, first_row_version.id) == nil

      send(insert_holder.pid, :release)
      assert Task.await(insert_holder, @collect_timeout) == {:error, :released}

      assert {:ok, %BlockingSetting{min_layover_minutes: 7}} =
               Task.await(insert_writer, @collect_timeout)

      assert stored_layover(scope.organization.id, first_row_version.id) == 7
      assert layover_rows(scope.organization.id, first_row_version.id) == 1
    end

    test "a committed layover change moves the review fingerprint a confirmation must match" do
      scope = seed_schedule_scope("settings-fingerprint")
      on_exit(fn -> cleanup_schedule_scope(scope) end)

      # Three trips on one service, each four minutes after the previous one: inside the default
      # five-minute layover and outside a stored zero.
      clocks = [{"07:00:00", "07:30:00"}, {"07:34:00", "08:04:00"}, {"08:08:00", "08:38:00"}]

      seeded =
        unboxed(fn ->
          clocks
          |> Enum.with_index(1)
          |> Enum.map(fn {{first_arrival, last_arrival}, index} ->
            blocked_trip_fixture(
              scope.organization.id,
              scope.version.id,
              scope.route_id,
              %{
                trip_id: "FP#{index}",
                service_id: scope.service,
                first_arrival: first_arrival,
                last_arrival: last_arrival
              }
            )
          end)
        end)

      day_key = unboxed(fn -> day_type_key(scope) end)
      command = {:assign, Enum.map(seeded, & &1.id), "FP101"}

      assert {:needs_confirmation, review} =
               unboxed(fn -> Gtfs.apply_block_change(day_key, command, scope.audit) end)

      # Both four-minute gaps are short layovers under the version's default of five minutes.
      assert review.added_problem_count == 2

      # A prior committed layover change: the review input is genuinely different.
      assert {:ok, %BlockingSetting{min_layover_minutes: 0}} =
               unboxed(fn -> save_layover(scope.organization.id, scope.version.id, 0) end)

      assert {:needs_confirmation, refreshed} =
               unboxed(fn -> Gtfs.apply_block_change(day_key, command, scope.audit) end)

      refute refreshed.fingerprint == review.fingerprint
      assert refreshed.added_problem_count == 0

      # The confirmation the earlier review issued no longer matches, and nothing is written.
      assert {:error, {:stale_review, stale}} =
               unboxed(fn ->
                 Gtfs.apply_block_change(day_key, command, scope.audit, review.fingerprint)
               end)

      assert stale.fingerprint == refreshed.fingerprint
      assert trip_blocks(scope, Enum.map(seeded, & &1.trip_id)) == [nil, nil, nil]
    end
  end

  # Releases the writer into real contention for the version row while an independent
  # session owns it exclusively, and verifies the writer really waits on that session.
  defp hold_exclusive_version(scope, supervisor) do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn -> hold_version(scope, parent) end)

    assert_receive {:version_held, holder_pid, holder_backend}, @contention_timeout
    assert holder_pid == holder.pid
    {holder, holder_backend}
  end

  defp hold_version(scope, parent) do
    unboxed(fn -> Repo.transaction(fn -> lock_version_until_released(scope, parent) end) end)
  end

  defp lock_version_until_released(scope, parent) do
    Repo.one(
      from(v in GtfsVersion,
        where: v.id == ^scope.version.id and v.organization_id == ^scope.organization.id,
        lock: "FOR UPDATE"
      )
    )

    send(parent, {:version_held, self(), backend_pid()})

    receive do
      :release -> Repo.rollback(:released)
    end
  end

  defp start_writer(supervisor, run) do
    parent = self()

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          backend = backend_pid()
          send(parent, {:writer_ready, self(), backend})

          receive do
            :go -> :ok
          end

          run.()
        end)
      end)

    assert_receive {:writer_ready, writer_pid, backend}, @contention_timeout
    assert writer_pid == writer.pid
    {writer, backend}
  end

  defp assert_blocked_by(backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout

    case unboxed(fn -> await_blocker(backend, holder_backend, deadline) end) do
      :ok ->
        :ok

      {:error, blocked_by} ->
        flunk(
          "expected backend #{backend} to wait on #{holder_backend}, saw blocking pids #{inspect(blocked_by)}"
        )
    end
  end

  defp await_blocker(backend, holder_backend, deadline) do
    blocked_by = blockers_of(backend)

    cond do
      holder_backend in blocked_by ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, blocked_by}

      true ->
        Process.sleep(@poll_interval)
        await_blocker(backend, holder_backend, deadline)
    end
  end

  defp blockers_of(backend) do
    %Postgrex.Result{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend])
    List.wrap(blockers)
  end

  defp backend_pid do
    %Postgrex.Result{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  defp lock_scope(organization_id, version_id) do
    unboxed(fn ->
      Repo.transaction(fn -> Versions.lock_for_input_write!(organization_id, version_id) end)
    end)
  end

  defp seed_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization = organization_fixture(%{alias: "input-writer-#{suffix}-#{unique}"})
      version = gtfs_version_fixture(organization.id)

      {:ok, staging_version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging #{unique}"})

      %{
        organization: organization,
        version: version,
        staging_version: staging_version
      }
    end)
  end

  defp trip_attrs(scope, trip_id, overrides \\ %{}) do
    Map.merge(
      %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        route_id: "route_input_writer",
        trip_id: trip_id,
        service_id: "service_input_writer"
      },
      Map.new(overrides)
    )
  end

  defp stop_time_attrs(scope, stop_sequence, overrides \\ %{}) do
    Map.merge(
      %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        trip_id: "trip_input_writer",
        stop_id: "stop_input_writer",
        stop_sequence: stop_sequence,
        arrival_time: "08:00:00",
        departure_time: "08:00:00"
      },
      Map.new(overrides)
    )
  end

  defp agency_attrs(scope, timezone, overrides \\ %{}) do
    Map.merge(
      %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        agency_id: "agency_input_writer",
        agency_name: "Input Writer Transit",
        agency_url: "https://example.test",
        agency_timezone: timezone
      },
      Map.new(overrides)
    )
  end

  defp trip_ids(scope) do
    unboxed(fn ->
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id,
        order_by: t.trip_id,
        select: t.trip_id
      )
      |> Repo.all()
    end)
  end

  defp stop_time_ids(scope) do
    unboxed(fn ->
      from(s in StopTime,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id,
        order_by: s.stop_sequence,
        select: s.id
      )
      |> Repo.all()
    end)
  end

  # -- Stop writer fixtures and lock probes ----------------------------------

  defp stop_attrs(scope, stop_id, overrides) do
    Map.merge(
      %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        stop_id: stop_id,
        stop_name: "Stop #{stop_id}",
        location_type: 0,
        wheelchair_boarding: 0
      },
      Map.new(overrides)
    )
  end

  defp stop_ids(scope) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id,
        order_by: s.stop_id,
        select: s.stop_id
      )
      |> Repo.all()
    end)
  end

  defp stops_named(scope, stop_id) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id and s.stop_id == ^stop_id,
        select: s.id
      )
      |> Repo.all()
    end)
  end

  defp stop_coordinates(scope, stop_id) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id and s.stop_id == ^stop_id,
        select: {s.stop_lat, s.stop_lon}
      )
      |> Repo.one()
    end)
  end

  defp coordinates?(coordinates, lat, lon) do
    {actual_lat, actual_lon} = coordinates
    Decimal.equal?(actual_lat, Decimal.new(lat)) and Decimal.equal?(actual_lon, Decimal.new(lon))
  end

  defp child_parent_stations(scope) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id and not is_nil(s.parent_station),
        order_by: s.stop_id,
        select: s.parent_station
      )
      |> Repo.all()
    end)
  end

  defp stop_time_stop_ids(scope) do
    unboxed(fn ->
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization.id and
            st.gtfs_version_id == ^scope.version.id,
        order_by: st.stop_sequence,
        select: st.stop_id
      )
      |> Repo.all()
    end)
  end

  defp transfer_stop_ids(scope) do
    unboxed(fn ->
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and t.gtfs_version_id == ^scope.version.id,
        select: {t.from_stop_id, t.to_stop_id}
      )
      |> Repo.all()
    end)
  end

  defp cleanup(organization_ids, user_ids \\ []) do
    unboxed(fn ->
      Repo.delete_all(from(t in Transfer, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(p in Pathway, where: p.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(s in StopTime, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(sl in StopLevel, where: sl.organization_id in ^organization_ids))
      Repo.delete_all(from(l in Level, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(m in UserOrgMembership, where: m.user_id in ^user_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(s in Stop, where: s.organization_id in ^organization_ids))
      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(sl in StopLevel, where: sl.organization_id in ^organization_ids))
      refute Repo.exists?(from(l in Level, where: l.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      refute Repo.exists?(from(u in User, where: u.id in ^user_ids))
      :ok
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # -- Schedule caller fixtures and lock probes -------------------------------

  # One committed schedule scope: an organization with its published version, one route, one
  # calendar identity the caller references, and one two-stop pattern with a timing whose offsets
  # the caller materializes.
  defp seed_schedule_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization =
        organization_fixture(%{alias: "input-writer-schedule-#{suffix}-#{unique}"})

      version = gtfs_version_fixture(organization.id)
      route_id = "sc#{System.unique_integer([:positive])}"
      route = route_fixture(organization.id, version.id, %{route_id: route_id})
      service = "svc_#{unique}"
      calendar_fixture(organization.id, version.id, %{service_id: service})

      actor = user_fixture()

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      bundle =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route_id,
          route_pattern_id: "SC-#{unique}",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
        })

      %{
        organization: organization,
        version: version,
        route: route,
        route_id: route_id,
        service: service,
        actor: actor,
        audit: audit,
        bundle: bundle
      }
    end)
  end

  defp create_attrs(scope) do
    %{
      pattern_id: scope.bundle.pattern.id,
      timed_pattern_id: scope.bundle.timing.id,
      service_id: scope.service,
      start_time: "07:00:00",
      repeat: nil
    }
  end

  defp stop_time_clocks(scope, trip_id) do
    unboxed(fn ->
      Repo.all(
        from(st in StopTime,
          where: st.organization_id == ^scope.organization.id and st.trip_id == ^trip_id,
          order_by: [asc: st.stop_sequence, asc: st.id],
          select: {st.stop_id, st.arrival_time, st.departure_time}
        )
      )
    end)
  end

  defp hold_shared_version(scope, supervisor) do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn -> hold_shared_until_released(scope, parent) end)

    assert_receive {:version_shared, holder_pid, holder_backend}, @contention_timeout
    assert holder_pid == holder.pid
    {holder, holder_backend}
  end

  defp hold_shared_until_released(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Versions.lock_for_input_write!(scope.organization.id, scope.version.id)
        send(parent, {:version_shared, self(), backend_pid()})

        receive do
          :release -> Repo.rollback(:released)
        end
      end)
    end)
  end

  defp hold_route_row(scope, supervisor) do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn -> hold_route_until_released(scope, parent) end)

    assert_receive {:route_held, holder_pid, holder_backend}, @contention_timeout
    assert holder_pid == holder.pid
    {holder, holder_backend}
  end

  defp hold_route_until_released(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.one(from(r in Route, where: r.id == ^scope.route.id, lock: "FOR UPDATE"))
        send(parent, {:route_held, self(), backend_pid()})

        receive do
          :release -> Repo.rollback(:released)
        end
      end)
    end)
  end

  defp share_lock_version(scope) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '3s'")

        Repo.one(
          from(v in GtfsVersion,
            where: v.id == ^scope.version.id and v.organization_id == ^scope.organization.id,
            lock: "FOR SHARE"
          )
        )
      end)
    end)
  end

  # The probe reports the refusal whether the adapter returns the error tuple or re-raises it.
  defp exclusive_lock_version(scope) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")

        Repo.one(
          from(v in GtfsVersion,
            where: v.id == ^scope.version.id and v.organization_id == ^scope.organization.id,
            lock: "FOR UPDATE"
          )
        )
      end)
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end

  # -- Bulk stop writer fixtures and probes ----------------------------------

  # One station on an active level with a single child stop carrying a diagram coordinate, plus
  # the reviewed alignment attrs whose fingerprint came from the real preview before any lock.
  defp seed_alignment_scope(scope, suffix, diagram_coordinate, lat, lon) do
    unboxed(fn ->
      station =
        stop_fixture(scope.organization.id, scope.version.id, %{
          stop_id: "ALIGN_STATION_#{suffix}",
          location_type: 1
        })

      level =
        level_fixture(scope.organization.id, scope.version.id, %{
          level_id: "L_ALIGN_#{suffix}",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: scope.organization.id,
          gtfs_version_id: scope.version.id,
          stop_id: station.id,
          level_id: level.id
        })

      child =
        stop_fixture(scope.organization.id, scope.version.id, %{
          stop_id: "ALIGN_CHILD_#{suffix}",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: diagram_coordinate,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new(lon)
        })

      {:ok, review} =
        Gtfs.preview_stop_level_alignment(stop_level.id, alignment_attrs(), 1000, 800)

      %{
        station: station,
        level: level,
        stop_level: stop_level,
        child: child,
        attrs: Map.put(alignment_attrs(), :fingerprint, review.fingerprint)
      }
    end)
  end

  defp alignment_attrs do
    %{
      floorplan_center_lat: 40.7128,
      floorplan_center_lon: -74.006,
      floorplan_scale_mpp: 0.25,
      floorplan_rotation_deg: 0.0
    }
  end

  defp bulk_audit(scope, station_stop_id) do
    actor =
      unboxed(fn ->
        user_fixture(%{email: "bulk-stop-#{System.system_time(:microsecond)}@example.com"})
      end)

    %AuditContext{
      organization_id: scope.organization.id,
      gtfs_version_id: scope.version.id,
      station_stop_id: station_stop_id,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp stop_level_aligned?(stop_level_id) do
    unboxed(fn ->
      from(sl in StopLevel, where: sl.id == ^stop_level_id, select: sl.floorplan_center_lat)
      |> Repo.one()
    end) != nil
  end

  defp stop_name(scope, stop_id) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id and s.stop_id == ^stop_id,
        select: s.stop_name
      )
      |> Repo.one()
    end)
  end

  defp stop_ids_for_version(organization_id, gtfs_version_id) do
    unboxed(fn ->
      from(s in Stop,
        where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
        order_by: s.stop_id,
        select: s.stop_id
      )
      |> Repo.all()
    end)
  end

  # -- Blocking settings writer fixtures and observations --------------------

  defp save_layover(organization_id, gtfs_version_id, minutes) do
    Blocking.update_settings(organization_id, gtfs_version_id, %{min_layover_minutes: minutes})
  end

  defp stored_layover(organization_id, gtfs_version_id) do
    unboxed(fn ->
      from(s in BlockingSetting,
        where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
        select: s.min_layover_minutes
      )
      |> Repo.one()
    end)
  end

  defp layover_rows(organization_id, gtfs_version_id) do
    unboxed(fn ->
      Repo.aggregate(
        from(s in BlockingSetting,
          where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
        ),
        :count
      )
    end)
  end

  # The day type key `Blocking` derives for the schedule scope's own service.
  defp day_type_key(scope) do
    {:ok, calendars} = Calendars.list_calendars(scope.organization.id, scope.version.id)
    day_type = Enum.find(DayTypes.derive(calendars), &(scope.service in &1.service_ids))
    assert day_type, "no day type holds #{scope.service}"
    day_type.key
  end

  defp trip_blocks(scope, trip_ids) do
    unboxed(fn ->
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id and t.trip_id in ^trip_ids,
        order_by: t.trip_id,
        select: t.block_id
      )
      |> Repo.all()
    end)
  end

  defp change_logs(scope) do
    unboxed(fn ->
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization.id and
            l.gtfs_version_id == ^scope.version.id,
        order_by: [asc: l.inserted_at],
        select: l
      )
      |> Repo.all()
    end)
  end

  defp stop_change_logs(scope, stop_row_id), do: stop_change_logs(scope, stop_row_id, nil)

  defp stop_change_logs(scope, stop_row_id, action) do
    unboxed(fn -> Repo.all(stop_change_log_query(scope, stop_row_id, action)) end)
  end

  defp stop_change_log_query(scope, stop_row_id, action) do
    query =
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization.id and
            l.gtfs_version_id == ^scope.version.id and l.entity_id == ^stop_row_id,
        order_by: [asc: l.inserted_at]
      )

    if action, do: where(query, [l], l.action == ^action), else: query
  end

  # One approved stop decision on one fenced apply attempt, as the real worker would hold it.
  defp seed_import_run(scope, decisions) do
    unboxed(fn ->
      actor = %{
        id: Ecto.UUID.generate(),
        email: "bulk-stop-#{System.unique_integer([:positive])}@example.test"
      }

      {:ok, run} =
        ChangeRuns.create_pending_compute(scope.organization.id, scope.version.id, actor, [])

      {:ok, _computing, compute_generation, compute_token} =
        ChangeRuns.claim(scope.organization.id, run.id, :compute)

      {:ok, review} =
        ChangeRuns.persist_review(
          scope.organization.id,
          run.id,
          compute_generation,
          compute_token,
          %{decisions: decisions, summary: %{applicable: length(decisions)}, diagnostics: []}
        )

      Enum.each(decisions, fn decision ->
        {:ok, _approved} =
          ChangeRuns.set_decision_status(
            scope.organization.id,
            review.id,
            decision.decision_id,
            :approved
          )
      end)

      {:ok, pending_apply} = ChangeRuns.request_apply(scope.organization.id, review.id)

      {:ok, claimed, generation, token} =
        ChangeRuns.claim(scope.organization.id, pending_apply.id, :apply)

      %{run: claimed, generation: generation, token: token}
    end)
  end

  defp import_decision(decision_id, stop_id) do
    %{
      serializer_version: 1,
      decision_id: decision_id,
      entity_type: :stop,
      action: :add,
      status: :pending,
      natural_key: stop_id,
      current_values: %{},
      uploaded_values: %{
        stop_name: "Imported #{stop_id}",
        stop_lat: 40.0,
        stop_lon: -70.0
      },
      changed_fields: [],
      dependency_keys: [],
      current_fingerprint: nil,
      user_edited: false
    }
  end

  defp import_audit_context(seeded) do
    %AuditContext{
      organization_id: seeded.run.organization_id,
      gtfs_version_id: seeded.run.gtfs_version_id,
      station_stop_id: nil,
      actor_id: seeded.run.actor_id,
      actor_email: seeded.run.actor_email
    }
  end

  defp import_decision_status(decision_id) do
    unboxed(fn ->
      from(d in ChangeDecision, where: d.decision_id == ^decision_id, select: d.status)
      |> Repo.one()
    end)
  end

  defp import_run_progress(run_id) do
    unboxed(fn -> Repo.get!(ChangeRun, run_id).progress_current end)
  end

  defp cleanup_schedule_scope(scope) do
    unboxed(fn ->
      organization_id = scope.organization.id

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
      Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
      # A blocking review fixture carries real stop rows; the organization row does not cascade
      # to them, so they go before the versions and the organization.
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))

      Repo.delete_all(
        from(r in TimedPatternStop,
          where:
            r.timed_pattern_id in subquery(
              from(t in TimedPattern, where: t.organization_id == ^organization_id, select: t.id)
            )
        )
      )

      Repo.delete_all(from(t in TimedPattern, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id == ^organization_id))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id == ^organization_id))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id == ^organization_id))

      Repo.delete_all(from(d in CalendarDate, where: d.organization_id == ^organization_id))
      Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))

      Repo.delete_all(
        from(m in UserOrgMembership,
          where: m.organization_id == ^organization_id or m.user_id == ^scope.actor.id
        )
      )

      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id == ^scope.actor.id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))

      refute Repo.exists?(from(o in Organization, where: o.id == ^organization_id))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      :ok
    end)
  end
end
