defmodule GtfsPlanner.Gtfs.Schedules.BlockCalendarChangeTest do
  @moduledoc """
  Merge evidence (EV-15) for CL-13: D2 keeps or clears a trip's block on a Schedules
  calendar change, atomically, so FH-13's three failures stay rejected — a calendar
  change may neither silently join another vehicle's block nor clear a block it could
  keep, and neither clear may land outside the transaction that changes the calendar.

  One case covers each observation R9 and AC-17 require:

  - a Weekday trip of block "101" with Weekday companions moved to a Saturday
    calendar where the Saturday "101" trips run clears `block_id` and changes
    `service_id` in one update, and stores one `"trip"` log whose
    `changed_fields["before"]["block_id"]` is "101" and `["after"]["block_id"]` nil
    beside the calendar change;
  - a move to a school-day calendar whose dates are a subset of the Weekday dates
    keeps the block, and its log records the same block on both sides;
  - a move to a calendar on which no "101" trip runs keeps the block;
  - a move of an ID no other service uses ("201" against a Saturday block "202")
    keeps it;
  - an unblocked trip's calendar change neither gains nor loses a block;
  - a retime without a calendar change keeps the block;
  - with `hashtext('blocking:' || version_id)` held on a second committed connection,
    the calendar change does not complete while the lock is held — observed with
    `refute Task.yield/2`, the pattern `Schedules.ConcurrencyTest` uses for the same
    claim — and returns `{:ok, _}` with the clear committed once it is released;

  Every value is read back from the database: the stored `service_id` and `block_id`,
  the `change_logs.changed_fields` snapshots, the stop time a retime rewrote and the
  companions' untouched blocks. The lock case commits its own disposable
  organization, version, route, actor, calendars and trips on an own connection — a
  holder and a blocked writer must see them — and `on_exit` deletes exactly those
  rows, including the change log, even when the test fails.

  The lock case's blocked writer is observed with `Task.yield/2` rather than
  `schedules_test.exs`'s `wait_until_locked/2` poll: AGENTS.md's test guidelines forbid
  `Process.sleep/1` in tests, and the yield's assertion is deterministic — a calendar
  change that joined the block guarantee cannot complete while another connection
  owns the advisory lock, and one that skipped the lock returns within the bounded
  wait and fails the `refute`.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/schedules/block_calendar_change_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # The lock case holds one lock open and observes another backend's wait, so the
  # module carries EV-15's 120 s command deadline and every hold self-releases.
  @moduletag timeout: 120_000

  # Three calendars of one version: the Weekday service every blocked trip starts on,
  # the Saturday service the moves target, and a school-day service whose dates are a
  # strict subset of the Weekday dates.
  @weekday "WK"
  @saturday "SAT"
  @school "SCH"

  @block "101"
  @own_block "201"
  @other_block "202"

  @receive_timeout 5_000
  @task_timeout 15_000
  @hold_timeout 10_000
  # The bounded wait that observes a calendar change blocked on the held lock. The
  # waiting change can never finish while the holder owns the lock, so the wait is
  # not a race: it only delays either the release or the failure.
  @lock_wait 500

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "12b"})
    actor = editor_fixture(organization)

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @weekday,
      name: "Weekday"
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @saturday,
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @school,
      name: "School days",
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-03-31]
    })

    %{
      organization: organization,
      version: version,
      route_id: route.route_id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  describe "a calendar change that joins another vehicle's work" do
    test "clears the block and the calendar in one audited update", context do
      moved = blocked_trip(context, %{trip_id: "wk1", block_id: @block})
      companion = blocked_trip(context, %{trip_id: "wk2", block_id: @block})
      saturday = blocked_trip(context, %{trip_id: "sa1", block_id: @block, service_id: @saturday})

      assert {:ok, updated} = change_calendar(context, moved, @saturday)

      assert updated.service_id == @saturday
      assert updated.block_id == nil
      assert persisted(moved).service_id == @saturday
      assert persisted(moved).block_id == nil

      # Only the moved trip changed.
      assert persisted(companion).block_id == @block
      assert persisted(companion).service_id == @weekday
      assert persisted(saturday).block_id == @block

      assert [log] = trip_logs(context)
      assert log.entity_type == "trip"
      assert log.entity_external_id == "wk1"
      assert log.action == "updated"
      assert log.changed_fields["before"]["block_id"] == @block
      assert log.changed_fields["after"]["block_id"] == nil
      assert log.changed_fields["before"]["service_id"] == @weekday
      assert log.changed_fields["after"]["service_id"] == @saturday

      # The two changes share one entry: the snapshots differ in the block and the
      # calendar only, and the log names the command's operation and trip.
      assert Map.drop(log.changed_fields["before"], ["block_id", "service_id"]) ==
               Map.drop(log.changed_fields["after"], ["block_id", "service_id"])

      assert is_binary(log.changed_fields["operation_id"])
      assert log.changed_fields["affected_trip_ids"] == [moved.id]
    end
  end

  describe "a calendar change the trip's block survives" do
    test "keeps the block when the new dates are a subset of the old ones", context do
      moved = blocked_trip(context, %{trip_id: "wk3", block_id: @block})
      blocked_trip(context, %{trip_id: "wk4", block_id: @block})

      assert {:ok, updated} = change_calendar(context, moved, @school)

      assert updated.service_id == @school
      assert updated.block_id == @block
      assert persisted(moved).service_id == @school
      assert persisted(moved).block_id == @block

      assert [log] = trip_logs(context)
      assert log.changed_fields["before"]["block_id"] == @block
      assert log.changed_fields["after"]["block_id"] == @block
      assert log.changed_fields["before"]["service_id"] == @weekday
      assert log.changed_fields["after"]["service_id"] == @school

      assert Map.drop(log.changed_fields["before"], ["service_id"]) ==
               Map.drop(log.changed_fields["after"], ["service_id"])
    end

    test "keeps the block when no companion runs on the new dates", context do
      moved = blocked_trip(context, %{trip_id: "wk5", block_id: @block})
      blocked_trip(context, %{trip_id: "wk6", block_id: @block})

      assert {:ok, updated} = change_calendar(context, moved, @saturday)

      assert updated.block_id == @block
      assert persisted(moved).block_id == @block

      assert [log] = trip_logs(context)
      assert log.changed_fields["before"]["block_id"] == @block
      assert log.changed_fields["after"]["block_id"] == @block
    end

    test "keeps an ID that no other service uses", context do
      moved = blocked_trip(context, %{trip_id: "wk7", block_id: @own_block})

      other =
        blocked_trip(context, %{trip_id: "sa2", block_id: @other_block, service_id: @saturday})

      assert {:ok, updated} = change_calendar(context, moved, @saturday)

      assert updated.service_id == @saturday
      assert updated.block_id == @own_block
      assert persisted(moved).block_id == @own_block
      assert persisted(other).block_id == @other_block
    end

    test "an unblocked trip's calendar change stays unblocked", context do
      moved = blocked_trip(context, %{trip_id: "wk8"})
      saturday = blocked_trip(context, %{trip_id: "sa3", block_id: @block, service_id: @saturday})

      assert {:ok, updated} = change_calendar(context, moved, @saturday)

      assert updated.service_id == @saturday
      assert updated.block_id == nil
      assert persisted(moved).block_id == nil
      assert persisted(saturday).block_id == @block

      assert [log] = trip_logs(context)
      assert log.changed_fields["before"]["block_id"] == nil
      assert log.changed_fields["after"]["block_id"] == nil
    end

    test "a retime without a calendar change keeps the block", context do
      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: context.route_id,
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
        })

      %{trip: trip} =
        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          context.route_id,
          bundle,
          %{
            trip_id: "wk9",
            service_id: @weekday,
            start_time: "06:00:00",
            block_id: @block
          }
        )

      assert {:ok, updated} =
               Gtfs.update_trip(
                 context.route_id,
                 trip.id,
                 %{start_time: "07:00:00"},
                 trip.updated_at,
                 context.audit
               )

      assert updated.service_id == @weekday
      assert updated.block_id == @block
      assert persisted(trip).block_id == @block
      assert first_departure_time(context, trip) == "07:00:00"

      assert [log] = trip_logs(context)
      assert log.changed_fields["before"]["block_id"] == @block
      assert log.changed_fields["after"]["block_id"] == @block
      assert log.changed_fields["after"]["start_time"] == "07:00:00"
    end
  end

  describe "the blocking lock on a calendar change" do
    test "waits for the version's held lock and completes after the release" do
      scope = committed_scope()
      on_exit(fn -> cleanup_committed_scope(scope) end)

      parent = self()
      holder = Task.async(fn -> hold_blocking_lock(scope, parent) end)
      assert_receive :blocking_lock_held, @receive_timeout

      changer = Task.async(fn -> change_calendar_on_own_connection(scope, parent) end)

      # The change is inside its transaction, past its version, route and trip reads.
      assert_receive {:changer_pid, _changer_pid}, @receive_timeout

      # `lock_blocking!/1` is what stops the change: the write reaches the advisory
      # lock after those reads and cannot finish while the holder owns it. An
      # implementation that skipped the lock would complete here and fail the refute.
      refute Task.yield(changer, @lock_wait)

      send(holder.pid, :release)
      assert Task.await(holder, @task_timeout) == {:ok, :ok}

      assert {:ok, updated} = Task.await(changer, @task_timeout)
      assert updated.service_id == @saturday
      assert updated.block_id == nil

      assert persisted(scope.trips.moved).service_id == @saturday
      assert persisted(scope.trips.moved).block_id == nil
      assert persisted(scope.trips.saturday).block_id == @block
      assert change_log_count(scope) == 1
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp blocked_trip(context, attrs) do
    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.route_id,
      Map.put_new(Map.new(attrs), :service_id, @weekday)
    )
  end

  defp change_calendar(context, trip, service_id) do
    Gtfs.update_trip(
      context.route_id,
      trip.id,
      %{service_id: service_id},
      trip.updated_at,
      context.audit
    )
  end

  defp persisted(%{id: id}), do: Repo.get!(Trip, id)

  defp trip_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^context.organization.id and l.entity_type == "trip",
        order_by: [asc: l.entity_external_id]
      )
    )
  end

  defp first_departure_time(context, trip) do
    Repo.one!(
      from(st in StopTime,
        where:
          st.organization_id == ^context.organization.id and
            st.gtfs_version_id == ^context.version.id and st.trip_id == ^trip.trip_id and
            st.stop_sequence == 1,
        select: st.departure_time
      )
    )
  end

  # A committed scope for the lock case: a holder and a blocked writer each run on
  # their own connection and must see the rows, so nothing here is sandboxed.
  defp committed_scope do
    unboxed(fn ->
      organization =
        organization_fixture(%{alias: "block-calendar-#{System.unique_integer([:positive])}"})

      version = gtfs_version_fixture(organization.id)
      route = route_fixture(organization.id, version.id, %{route_id: "12blk"})
      actor = editor_fixture(organization)

      calendar_service_fixture(organization.id, version.id, %{
        service_id: @weekday,
        name: "Weekday"
      })

      calendar_service_fixture(organization.id, version.id, %{
        service_id: @saturday,
        name: "Saturday",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0
      })

      trips = %{
        moved:
          blocked_trip_fixture(organization.id, version.id, route.route_id, %{
            trip_id: "wk1",
            block_id: @block,
            service_id: @weekday
          }),
        saturday:
          blocked_trip_fixture(organization.id, version.id, route.route_id, %{
            trip_id: "sa1",
            block_id: @block,
            service_id: @saturday
          })
      }

      %{
        organization_id: organization.id,
        version_id: version.id,
        route_id: route.route_id,
        actor_id: actor.id,
        trips: trips,
        audit: %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          station_stop_id: nil,
          actor_id: actor.id,
          actor_email: actor.email
        }
      }
    end)
  end

  # Deletes exactly the rows `committed_scope/0` created plus the change log the
  # calendar change writes, keyed to their own organization, on an own connection so
  # the deletion runs even when the test failed.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      organization_id = scope.organization_id

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
      Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(c in CalendarAttribute, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(c in CalendarDate, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id == ^scope.actor_id))
    end)
  end

  # Runs the production `Gtfs.update_trip/5` on an own committing connection so its
  # advisory lock and row locks are released by its commit, and reports the backend
  # pid once it is inside its transaction.
  defp change_calendar_on_own_connection(scope, parent) do
    unboxed(fn ->
      {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
      send(parent, {:changer_pid, backend_pid})

      Gtfs.update_trip(
        scope.route_id,
        scope.trips.moved.id,
        %{service_id: @saturday},
        scope.trips.moved.updated_at,
        scope.audit
      )
    end)
  end

  # Holds the version's blocking lock on an own connection with the statement
  # `Blocking.lock_blocking!/1` issues, until the test releases it.
  defp hold_blocking_lock(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "blocking:" <> scope.version_id
        ])

        send(parent, :blocking_lock_held)

        receive do
          :release -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  defp change_log_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization_id and
            l.gtfs_version_id == ^scope.version_id and l.entity_type == "trip"
      ),
      :count
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
