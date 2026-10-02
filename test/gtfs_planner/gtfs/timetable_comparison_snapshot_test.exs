defmodule GtfsPlanner.Gtfs.TimetableComparisonSnapshotTest do
  @moduledoc """
  Merge evidence (EV-6) for `TimetableComparison.load/2`, the bounded read-only
  feed snapshot one approved-timetable comparison is computed from.

  The four cases are the ones the step's execution card names:

    * the production entrypoint on an unboxed isolated connection reads exactly
      one route and version, and refuses a foreign organization, a foreign
      version, a foreign route and a revoked editor membership before any row is
      exposed;
    * a second connection committing a calendar exception and a stop-time change
      between two of the loader's reads is invisible or wholly visible — rows,
      totals and digest describe one database state, never a mixture;
    * the ordinary SQL-sandbox fixture uses the existing no-op snapshot only
      because the sandbox already holds an open transaction, and the production
      default boundary is proved separately with that override removed;
    * an over-cap scope is refused whole as `{:incomplete, reason}` with no
      partial rows, and no domain or audit row is written.

  Every expected value is hand-derived from the GTFS Schedule reference and the
  fixture calendar, not from a second invocation of the module under test:
  `WEEKDAY` runs Monday–Friday all year with the Thanksgiving removal, so
  2026-11-25 and 2026-11-27 are service while 2026-11-26 is not; `HOLIDAY` has no
  weekly row at all and adds exactly 2026-11-26. `24:30:00` is a service-day
  time that follows `23:50:00`, and an unreadable arrival stays unknown instead of
  borrowing the departure (CL-5).
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimetableComparison
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # The two ceiling cases insert their bulk rows directly, so they are slower
  # than the rest of the file and carry their own finite budget.
  @moduletag timeout: 240_000

  @collect_timeout 10_000
  @pause_timeout 30_000
  @race_handler {__MODULE__, :timetable_comparison_snapshot_race}

  # 2026-11-25 is the Wednesday before Thanksgiving, 2026-11-26 the Thursday
  # itself and 2026-11-27 the Friday after.
  @thanksgiving ~D[2026-11-26]
  @interval {~D[2026-11-25], ~D[2026-11-27]}
  @central "CENTRAL"
  @harbor "HARBOR"

  setup do
    # `start_supervised!` rather than a linked `Task.Supervisor.start_link/0`: a
    # linked supervisor is already shutting down by the time `on_exit` runs.
    {:ok, supervisor: start_supervised!({Task.Supervisor, []})}
  end

  describe "load/2 authorization (AC-9, AC-13)" do
    test "reads one route and version, and refuses foreign or revoked scope before rows", %{
      supervisor: supervisor
    } do
      scope = in_task(supervisor, fn -> harbor_scope() end)
      on_exit(fn -> cleanup([scope, scope.foreign]) end)

      use_production_snapshot()

      assert {:ok, inputs} = on_connection(fn -> load(scope, %{interval: @interval}) end)

      # Exactly this route in exactly this version, and nothing from the
      # foreign organization seeded alongside it.
      assert inputs.route.route_id == "H8"
      assert inputs.route.state == :active
      assert inputs.scope.organization_id == scope.organization_id
      assert inputs.scope.gtfs_version_id == scope.gtfs_version_id
      assert inputs.scope.route_id == scope.route.id
      assert Enum.all?(inputs.trips, &(&1.service_id in ["WEEKDAY", "HOLIDAY"]))
      refute Enum.any?(inputs.trips, &(&1.trip_id in ["X8-0700"]))
      assert inputs.completeness == :complete
      assert inputs.unreadable_service_ids == []

      # Another organization's own scope reads only its own rows: the route with
      # the same GTFS id is a different route in a different tenant, and this
      # scope's trips never appear in it.
      assert {:ok, foreign} =
               on_connection(fn -> load(scope.foreign, %{interval: @interval}) end)

      assert foreign.route.route_id == "H8"
      assert Enum.map(foreign.trips, & &1.trip_id) == ["X8-0700"]
      refute Enum.any?(foreign.trips, &(&1.trip_id in ["H8-0715", "H8-1820"]))
      refute foreign.feed_digest == inputs.feed_digest

      # This actor has no membership in that organization, so crossing the
      # tenant boundary is refused rather than answered.
      assert {:error, :forbidden} =
               on_connection(fn ->
                 load(%{scope | organization_id: scope.foreign.organization_id}, %{
                   interval: @interval
                 })
               end)

      # A route or version outside the trusted scope is not found, never
      # another tenant's metadata.
      assert {:error, :not_found} =
               on_connection(fn ->
                 load(%{scope | route_id: scope.foreign_route.id}, %{interval: @interval})
               end)

      assert {:error, :not_found} =
               on_connection(fn ->
                 load(%{scope | gtfs_version_id: Ecto.UUID.generate()}, %{interval: @interval})
               end)

      # Access withdrawn after the conversation started stops this read too.
      assert {:ok, _deleted} =
               in_task(supervisor, fn ->
                 Accounts.delete_user_org_membership(scope.membership)
               end)

      assert {:error, :forbidden} = on_connection(fn -> load(scope, %{interval: @interval}) end)
    end

    test "refuses an over-long interval and a malformed selection whole" do
      scope = harbor_scope()

      assert {:error, {:incomplete, {:too_many_dates, 367}}} =
               load(scope, %{interval: {~D[2026-01-01], ~D[2027-01-02]}})

      assert {:error, :invalid_selection} =
               load(scope, %{interval: {~D[2026-11-27], ~D[2026-11-25]}})

      assert {:error, :invalid_selection} = load(scope, %{interval: {"2026-11-25", "2026-11-27"}})

      assert {:error, :invalid_selection} =
               load(scope, %{interval: @interval, direction_ids: [2]})

      assert {:error, :invalid_selection} =
               load(scope, %{interval: @interval, pattern_ids: ["PA", "PA"]})

      # A pattern the route does not run is not found rather than widened to the
      # route's own patterns.
      assert {:error, :not_found} = load(scope, %{interval: @interval, pattern_ids: ["NOPE"]})
    end
  end

  describe "the loaded rows (AC-9)" do
    test "reads complete applicable rows, effective dates and both clocks separately" do
      scope = harbor_scope()

      assert {:ok, inputs} = load(scope, %{interval: @interval})

      # `WEEKDAY` runs Monday–Friday with the Thanksgiving removal, so the
      # interval's Wednesday and Friday are service and the Thursday is not.
      assert inputs.services["WEEKDAY"].active_dates == [~D[2026-11-25], ~D[2026-11-27]]
      assert inputs.services["WEEKDAY"].weekly.start_date == ~D[2026-01-01]
      assert inputs.services["WEEKDAY"].weekly.end_date == ~D[2026-12-31]

      # `HOLIDAY` has no weekly row: its single addition is the whole calendar,
      # and it is still service.
      assert inputs.services["HOLIDAY"].weekly == nil

      assert inputs.services["HOLIDAY"].exceptions == [
               %{date: @thanksgiving, exception_type: 1}
             ]

      assert inputs.services["HOLIDAY"].active_dates == [@thanksgiving]
      assert inputs.service_ids == ["HOLIDAY", "WEEKDAY"]

      assert inputs.interval == @interval

      assert inputs.selection == %{
               interval: @interval,
               direction_ids: nil,
               pattern_ids: nil,
               service_ids: nil
             }

      # Each trip carries the dates its own service actually runs, so the
      # holiday trips are not counted as weekday service.
      by_id = Map.new(inputs.trips, &{&1.trip_id, &1})
      assert by_id["H8-1820"].service_dates == [@thanksgiving]
      assert by_id["H8-0715"].service_dates == [~D[2026-11-25], ~D[2026-11-27]]

      assert inputs.totals == %{trips: 7, stop_times: 8, frequencies: 2}

      # A past-midnight departure keeps its service-day seconds, and the
      # arrival is read on its own: the unreadable one stays unknown instead of
      # borrowing the readable departure beside it.
      late = Enum.find(inputs.stop_times, &(&1.trip_id == "H8-LATE"))
      assert late.departure_secs == 88_200
      assert late.arrival_secs == nil
      assert late.departure_time == "24:30:00"

      # 07:15:00 is 26,100 service-day seconds, read identically on both sides.
      assert clock(inputs, "H8-0715") == {26_100, 26_100}

      # A frequency window is loaded whole and never expanded into departures.
      windows =
        inputs.frequencies
        |> Enum.map(&{&1.start_secs, &1.end_secs, &1.headway_secs, &1.exact_times})
        |> Enum.sort()

      # The non-exact 20:00-22:00 window at 20 minutes and the exact 21:00-22:00
      # window at 10 minutes stay two distinct typed windows, neither expanded.
      assert windows == [
               {72_000, 79_200, 1200, 0},
               {75_600, 79_200, 600, 1}
             ]

      # The two reviewed patterns the scoped trips actually use, each with its
      # own occurrences in that pattern's order.
      assert Enum.map(inputs.patterns, & &1.route_pattern_id) == ["PA", "PB"]
      assert Enum.map(inputs.patterns, & &1.direction_id) == [0, 1]

      assert [inbound, outbound] = inputs.patterns
      assert inbound.name == "Harbor inbound"

      assert inbound.occurrences == [
               %{stop_id: @central, position: 1},
               %{stop_id: @harbor, position: 2}
             ]

      assert outbound.name == "Harbor outbound"
      assert outbound.occurrences == [%{stop_id: @central, position: 1}]

      assert inputs.feed_digest =~ ~r/\A[0-9a-f]{64}\z/

      # The same content read again is the same digest; nothing here is a clock
      # or a row counter.
      assert {:ok, again} = load(scope, %{interval: @interval})
      assert again.feed_digest == inputs.feed_digest
    end

    test "narrows to the reviewed directions, patterns and services, and reads nothing else" do
      scope = harbor_scope()

      assert {:ok, direction} =
               load(scope, %{interval: @interval, direction_ids: [1]})

      # Only the outbound trip; the inbound calendar and pattern stay unread.
      assert Enum.map(direction.trips, & &1.trip_id) == ["H8-OUT-0900"]
      assert direction.totals.trips == 1
      assert Enum.map(direction.patterns, & &1.route_pattern_id) == ["PB"]

      assert {:ok, service} = load(scope, %{interval: @interval, service_ids: ["HOLIDAY"]})
      assert service.service_ids == ["HOLIDAY"]
      assert Enum.map(service.trips, & &1.trip_id) == ["H8-1820", "H8-1910"]
      assert service.totals.stop_times == 2

      # A narrowed scope is a different snapshot, so its digest is too.
      refute service.feed_digest == direction.feed_digest
    end
  end

  describe "one snapshot (AC-11, CL-5)" do
    test "reads a controlled writer's committed change wholly before or wholly after", %{
      supervisor: supervisor
    } do
      scope = in_task(supervisor, fn -> harbor_scope() end)
      on_exit(fn -> cleanup([scope]) end)

      seeded = counts(scope)
      parent = self()

      use_production_snapshot()

      reader = start_worker(fn -> pause_then_read(scope, parent) end)
      assert_receive {:reader_ready, reader_pid}, @collect_timeout

      # The reader pauses inside its repeatable-read transaction, after the
      # scoped trips and before their calendars and stop times.
      pause_after_trip_read(parent, reader_pid)
      send(reader_pid, :start_read)
      assert_receive {:reader_paused, ^reader_pid}, @collect_timeout

      assert :ok = in_task(supervisor, fn -> replace_holiday_and_timing(scope) end)
      send(reader_pid, :resume_query)

      assert {:ok, before_change} = await_worker(reader)

      # Read wholly before the commit: the weekday removal still keeps
      # Thanksgiving out of the weekday calendar, the exception-only calendar
      # still adds it, and the 07:15 row still carries its original clocks.
      assert before_change.services["WEEKDAY"].active_dates == [
               ~D[2026-11-25],
               ~D[2026-11-27]
             ]

      assert before_change.services["HOLIDAY"].active_dates == [@thanksgiving]
      assert clock(before_change, "H8-0715") == {26_100, 26_100}

      assert {:ok, after_change} =
               in_task(supervisor, fn -> load(scope, %{interval: @interval}) end)

      # Read wholly after the commit: the holiday addition became a removal, so
      # Thanksgiving now has no exception service, and the weekday trip's
      # departure moved seven minutes later.
      assert after_change.services["HOLIDAY"].active_dates == []

      assert after_change.services["WEEKDAY"].active_dates == [
               ~D[2026-11-25],
               ~D[2026-11-27]
             ]

      assert clock(after_change, "H8-0715") == {26_100, 26_520}

      # Two whole states, never one of each: the digest, the totals and the
      # calendar rows all moved together.
      refute after_change.feed_digest == before_change.feed_digest
      assert before_change.totals == after_change.totals
      assert before_change.completeness == :complete
      assert after_change.completeness == :complete

      # The queries read only: the only changed rows are the writer's own.
      assert counts(scope) == seeded
      assert audit_count(scope) == 0
    end

    test "reads the production default boundary with no test override in place", %{
      supervisor: supervisor
    } do
      scope = in_task(supervisor, fn -> harbor_scope() end)
      on_exit(fn -> cleanup([scope]) end)

      # The ordinary fixture runs against the sandbox no-op, which exists only
      # because the sandbox already holds an open transaction.
      assert Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot) == Snapshot.Sandbox

      use_production_snapshot()

      # With the override removed the module resolves its own shipped default,
      # and that default sets the read-only repeatable-read transaction.
      remove_snapshot_override()

      assert {:ok, inputs} = on_connection(fn -> load(scope, %{interval: @interval}) end)
      assert inputs.completeness == :complete
      assert inputs.feed_digest =~ ~r/\A[0-9a-f]{64}\z/
      # The load wrote nothing.
      assert audit_count(scope) == 0
    end
  end

  describe "work caps (AC-13)" do
    test "refuses a scope over the trip ceiling whole, without a partial answer" do
      scope = harbor_scope()

      assert TimetableComparison.limits() == %{dates: 366, trips: 10_000, stop_times: 75_000}

      before = counts(scope)

      # The route's seven real trips plus 9,994 bulk `WEEKDAY` trips: one over
      # the ceiling for the whole route, and under it for the reviewed inbound
      # direction, the reviewed `WEEKDAY` service and the reviewed `HOLIDAY`
      # service.
      insert_trips(scope, 9_994)

      assert {:error, {:incomplete, {:too_many_trips, 10_001}}} =
               load(scope, %{interval: @interval})

      # Six real inbound trips plus the bulk rows is exactly the ceiling, so the
      # reviewed inbound direction loads complete while the whole route — which
      # also holds the one outbound trip — is one over it.
      assert {:ok, inbound} = load(scope, %{interval: @interval, direction_ids: [0]})
      assert inbound.totals.trips == 10_000
      assert inbound.completeness == :complete

      # The reviewed `WEEKDAY` service holds five real trips plus the bulk rows,
      # still under the ceiling, and the reviewed `HOLIDAY` service is
      # unaffected: the cap bounds the requested scope, not the route.
      assert {:ok, weekday} = load(scope, %{interval: @interval, service_ids: ["WEEKDAY"]})
      assert weekday.totals.trips == 9_999
      assert weekday.completeness == :complete

      assert {:ok, narrowed} = load(scope, %{interval: @interval, service_ids: ["HOLIDAY"]})
      assert Enum.map(narrowed.trips, & &1.trip_id) == ["H8-1820", "H8-1910"]
      assert narrowed.completeness == :complete

      # Nothing was written by any of it.
      assert audit_count(scope) == 0

      assert Repo.aggregate(
               from(t in Trip, where: t.organization_id == ^scope.organization_id),
               :count
             ) ==
               before.trips + 9_994
    end

    test "refuses a scope over the stop-time ceiling whole, without a partial answer" do
      scope = harbor_scope()

      before = counts(scope)

      # 75,001 rows on one trip of the scoped route.
      insert_stop_times(scope, "H8-0800", 75_001 - 1)

      assert {:error, {:incomplete, {:too_many_stop_times, 75_001}}} =
               load(scope, %{interval: @interval})

      # The same route with a reviewed service that holds no bulk rows still
      # loads, so the refusal is about the scope and not about the route.
      assert {:ok, inputs} = load(scope, %{interval: @interval, service_ids: ["HOLIDAY"]})
      assert inputs.totals.stop_times == 2
      assert inputs.completeness == :complete

      assert audit_count(scope) == 0

      assert Repo.aggregate(
               from(s in StopTime, where: s.organization_id == ^scope.organization_id),
               :count
             ) ==
               before.stop_times + 75_001 - 1
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # A holiday-replacement route: `WEEKDAY` is the recurring calendar removed on
  # Thanksgiving, `HOLIDAY` is exception-only, and the route runs three weekday
  # trips, two holiday trips, one frequency trip and one inbound trip.
  defp harbor_scope do
    organization = organization_fixture(%{alias: "ai04-step6-#{unique_suffix()}"})
    user = editor_user()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id)

    foreign_organization = organization_fixture(%{alias: "ai04-step6-#{unique_suffix()}"})
    foreign_user = editor_user()
    organization_membership_fixture(foreign_user, foreign_organization)
    foreign_version = gtfs_version_fixture(foreign_organization.id)

    stop_fixture(organization.id, version.id, %{stop_id: @central, stop_name: "Central Station"})
    stop_fixture(organization.id, version.id, %{stop_id: @harbor, stop_name: "Harbor Yards"})

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})

    foreign_route = route_fixture(foreign_organization.id, foreign_version.id, %{route_id: "H8"})

    foreign_stop = stop_fixture(foreign_organization.id, foreign_version.id, %{stop_id: @central})

    foreign_trip =
      trip_fixture(foreign_organization.id, foreign_version.id, "H8", %{trip_id: "X8-0700"})

    stop_time_fixture(
      foreign_organization.id,
      foreign_version.id,
      foreign_trip.trip_id,
      foreign_stop.stop_id,
      %{
        stop_sequence: 0,
        departure_time: "07:00:00"
      }
    )

    calendar_fixture(
      organization.id,
      version.id,
      weekday_calendar("WEEKDAY", ~D[2026-01-01], ~D[2026-12-31])
    )

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      date: @thanksgiving,
      exception_type: 2
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "HOLIDAY",
      date: @thanksgiving,
      exception_type: 1
    })

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: "PA",
        route_id: "H8",
        direction_id: 0,
        route_pattern_name: "Harbor inbound"
      })

    route_pattern_stop(pattern, @central, 1)
    route_pattern_stop(pattern, @harbor, 2)

    # Three weekday trips: a plain one, one with an unreadable arrival beside a
    # readable departure, and one that leaves after midnight.
    weekday_trip(organization.id, version.id, "H8-0715", pattern, [
      {@central, 1, "07:15:00", "07:15:00"},
      {@harbor, 2, "07:35:00", "07:35:00"}
    ])

    weekday_trip(organization.id, version.id, "H8-0800", pattern, [
      {@central, 1, "08:00:00", "08:00:00"}
    ])

    weekday_trip(organization.id, version.id, "H8-LATE", pattern, [
      {@central, 1, nil, "24:30:00"}
    ])

    # A frequency trip with one exact and one non-exact window.
    weekday_trip(organization.id, version.id, "H8-FREQ", pattern, [
      {@harbor, 1, "20:00:00", "20:00:00"}
    ])

    frequency_fixture(organization.id, version.id, "H8-FREQ", %{
      start_time: "20:00:00",
      end_time: "22:00:00",
      headway_secs: 1200,
      exact_times: 0
    })

    frequency_fixture(organization.id, version.id, "H8-FREQ", %{
      start_time: "21:00:00",
      end_time: "22:00:00",
      headway_secs: 600,
      exact_times: 1
    })

    holiday_trip(organization.id, version.id, "H8-1820", pattern, [
      {@central, 1, "18:20:00", "18:20:00"}
    ])

    holiday_trip(organization.id, version.id, "H8-1910", pattern, [
      {@central, 1, "19:10:00", "19:10:00"}
    ])

    # The inbound trip is on the other direction and another calendar, so a
    # reviewed direction and a reviewed service each exclude it.
    outbound =
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: "PB",
        route_id: "H8",
        direction_id: 1,
        route_pattern_name: "Harbor outbound"
      })

    route_pattern_stop(outbound, @central, 1)

    weekday_trip(organization.id, version.id, "H8-OUT-0900", outbound, [
      {@central, 1, "09:00:00", "09:00:00"}
    ])

    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: user.id,
      route_id: route.id,
      organization: organization,
      version: version,
      route: route,
      membership: membership,
      foreign_route: foreign_route,
      foreign: %{
        organization_id: foreign_organization.id,
        gtfs_version_id: foreign_version.id,
        actor_id: foreign_user.id,
        route_id: foreign_route.id
      }
    }
  end

  # The unboxed cases commit, so the fixture's own users need an address the
  # suite's counter cannot hand out twice. They are deleted by `cleanup/1`.
  defp unique_suffix, do: System.unique_integer([:positive])

  defp editor_user do
    user_fixture(%{email: "ai04-step6-#{unique_suffix()}@example.com"})
  end

  defp route_pattern_stop(pattern, stop_id, position) do
    route_pattern_stop_fixture(pattern, stop_id, position)
  end

  # `Gtfs.Trip.changeset/2` casts no `route_pattern_id` (a derived assignment
  # rather than imported GTFS text), so the reviewed pattern is written onto the
  # inserted trip the way the pattern derivation writes it.
  defp trip_for(organization_id, version_id, trip_id, pattern, attrs) do
    organization_id
    |> trip_fixture(version_id, "H8", Map.put(attrs, :trip_id, trip_id))
    |> Ecto.Changeset.change(%{
      direction_id: pattern.direction_id,
      route_pattern_id: pattern.route_pattern_id
    })
    |> Repo.update!()
  end

  defp weekday_trip(organization_id, version_id, trip_id, pattern, stops) do
    trip_for(organization_id, version_id, trip_id, pattern, %{service_id: "WEEKDAY"})
    |> seed_stop_times(organization_id, version_id, stops)
  end

  defp holiday_trip(organization_id, version_id, trip_id, pattern, stops) do
    trip_for(organization_id, version_id, trip_id, pattern, %{service_id: "HOLIDAY"})
    |> seed_stop_times(organization_id, version_id, stops)
  end

  defp seed_stop_times(trip, organization_id, version_id, stops) do
    Enum.each(stops, fn {stop_id, sequence, arrival, departure} ->
      stop_time_fixture(organization_id, version_id, trip.trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: arrival,
        departure_time: departure
      })
    end)

    trip
  end

  defp weekday_calendar(service_id, first, last) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: first,
      end_date: last
    }
  end

  # The writer commits two conflicting changes: the exception-only addition
  # becomes a removal, and the 07:15 departure moves seven minutes later. Either
  # one alone would be invisible to a read that started before it.
  defp replace_holiday_and_timing(scope) do
    {1, _returned} =
      Repo.update_all(
        from(d in CalendarDate,
          where:
            d.organization_id == ^scope.organization_id and
              d.gtfs_version_id == ^scope.gtfs_version_id and d.service_id == "HOLIDAY" and
              d.date == ^@thanksgiving
        ),
        set: [exception_type: 2]
      )

    {1, _returned} =
      Repo.update_all(
        from(s in StopTime,
          where:
            s.organization_id == ^scope.organization_id and
              s.gtfs_version_id == ^scope.gtfs_version_id and s.trip_id == "H8-0715" and
              s.stop_sequence == 1
        ),
        set: [departure_time: "07:22:00"]
      )

    :ok
  end

  # Bulk rows for the ceiling cases. They are inserted straight into the tables
  # the loader reads, because the point of the case is the count and not the
  # fixture ergonomics.
  defp insert_trips(scope, count) do
    now = DateTime.utc_now()

    rows =
      for index <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          organization_id: scope.organization_id,
          gtfs_version_id: scope.gtfs_version_id,
          trip_id: "BULK-#{index}",
          route_id: "H8",
          service_id: "WEEKDAY",
          direction_id: 0,
          inserted_at: now,
          updated_at: now
        }
      end

    rows
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(Trip, &1))

    :ok
  end

  defp insert_stop_times(scope, trip_id, count) do
    now = DateTime.utc_now()

    rows =
      for index <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          organization_id: scope.organization_id,
          gtfs_version_id: scope.gtfs_version_id,
          trip_id: trip_id,
          stop_id: @harbor,
          stop_sequence: index + 100,
          departure_time: "12:00:00",
          inserted_at: now,
          updated_at: now
        }
      end

    rows
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(StopTime, &1))

    :ok
  end

  # -- expectations helpers ---------------------------------------------------

  defp load(scope, selection), do: TimetableComparison.load(scope_of(scope), selection)

  defp scope_of(scope) do
    %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      actor_id: scope.actor_id,
      route_id: scope.route_id
    }
  end

  # One trip's own first-stop occurrence, so a two-stop trip is not read as its
  # last row.
  defp clock(inputs, trip_id) do
    row =
      inputs.stop_times
      |> Enum.filter(&(&1.trip_id == trip_id))
      |> Enum.min_by(& &1.stop_sequence)

    {row.arrival_secs, row.departure_secs}
  end

  defp counts(scope) do
    %{
      trips:
        Repo.aggregate(
          from(t in Trip, where: t.organization_id == ^scope.organization_id),
          :count
        ),
      stop_times:
        Repo.aggregate(
          from(s in StopTime, where: s.organization_id == ^scope.organization_id),
          :count
        ),
      frequencies:
        Repo.aggregate(
          from(f in Frequency, where: f.organization_id == ^scope.organization_id),
          :count
        ),
      calendars:
        Repo.aggregate(
          from(c in Calendar, where: c.organization_id == ^scope.organization_id),
          :count
        ),
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^scope.organization_id),
          :count
        )
    }
  end

  defp audit_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog, where: l.organization_id == ^scope.organization_id),
      :count
    )
  end

  # -- fixture helpers --------------------------------------------------------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # The reader runs the production entrypoint on its own committing connection,
  # so `SET TRANSACTION ISOLATION LEVEL` applies and the pause happens inside the
  # snapshot rather than inside the test's rolled-back transaction.
  defp pause_then_read(scope, parent) do
    send(parent, {:reader_ready, self()})

    receive do
      :start_read -> :ok
    end

    unboxed(fn -> load(scope, %{interval: @interval}) end)
  end

  # Every worker runs on its own committing connection through an unlinked
  # spawn, so a rendezvous pause in one worker cannot take a supervisor down.
  defp start_worker(fun) do
    parent = self()
    spawn_monitor(fn -> send(parent, {:done, self(), unboxed(fun)}) end)
  end

  defp await_worker({pid, ref}) do
    receive do
      {:done, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("loader worker failed: #{inspect(reason)}")
    after
      @collect_timeout ->
        flunk("loader worker timed out")
    end
  end

  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> unboxed(fun) end)
    |> Task.await(@collect_timeout)
  end

  # `SET TRANSACTION ISOLATION LEVEL` only applies at the top of a transaction,
  # so the production boundary needs a connection that holds no enclosing
  # transaction. The adapter is selected here, in the test process, so its
  # restore belongs to this test's `on_exit` and survives a killed worker.
  defp use_production_snapshot do
    previous = Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot)
    on_exit(fn -> Application.put_env(:gtfs_planner, :gtfs_service_query_snapshot, previous) end)

    Application.put_env(:gtfs_planner, :gtfs_service_query_snapshot, Snapshot.Repo)
  end

  # With no override at all the module resolves its own shipped default, which
  # is the same production boundary. The removal is restored by this test's
  # `use_production_snapshot/0` exit callback.
  defp remove_snapshot_override do
    Application.delete_env(:gtfs_planner, :gtfs_service_query_snapshot)
  end

  defp pause_after_trip_read(parent, reader_pid) do
    :telemetry.attach(
      @race_handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, reader} ->
        if self() == reader and String.contains?(to_string(metadata[:query]), ~s(FROM "trips")) do
          :telemetry.detach(@race_handler)
          send(owner, {:reader_paused, self()})

          receive do
            :resume_query -> :ok
          after
            @pause_timeout -> :ok
          end
        end
      end,
      {parent, reader_pid}
    )

    on_exit(fn -> :telemetry.detach(@race_handler) end)
  end

  defp on_connection(fun), do: Sandbox.unboxed_run(Repo, fun)

  # The tenant-isolation fixture seeds a second organization beside the scoped
  # one, so both are this case's own rows.
  defp scope_foreign_organization_id(scope),
    do: scope |> Map.get(:foreign, %{}) |> Map.get(:organization_id)

  # Unboxed cases commit, so this package's own fixtures are deleted explicitly.
  defp cleanup(scopes) do
    unboxed(fn ->
      organization_ids =
        scopes
        |> Enum.flat_map(&[&1.organization_id, scope_foreign_organization_id(&1)])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      Repo.delete_all(from(f in Frequency, where: f.organization_id in ^organization_ids))

      Repo.delete_all(from(s in StopTime, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))

      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id in ^organization_ids))

      Repo.delete_all(from(p in RoutePattern, where: p.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))

      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))

      Repo.delete_all(
        from(m in GtfsPlanner.Accounts.UserOrgMembership,
          where: m.organization_id in ^organization_ids
        )
      )

      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      # The unboxed fixture's own users, matched by this file's address prefix.
      Repo.delete_all(from(u in GtfsPlanner.Accounts.User, where: like(u.email, "ai04-step6-%")))

      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(s in StopTime, where: s.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end
end
