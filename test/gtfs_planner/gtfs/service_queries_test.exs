defmodule GtfsPlanner.Gtfs.ServiceQueriesTest do
  @moduledoc """
  Merge evidence (EV-3) for `ServiceQueries.departures/2`, `coverage/2` and
  `compare_dates/2`: the A02 holiday-replacement fixture, the shifted
  first-stop frequency windows, loop-occurrence resolution, the A19
  service-loss comparison, the bounded refusals, and one controlled writer
  interleaving against a real `REPEATABLE READ READ ONLY` snapshot.

  Every expectation is hand-derived from the acceptance cases and the GTFS
  Schedule reference, not from a second invocation of the module under test:

    * 2026-11-26 is a Thursday. `WEEKDAY` runs it weekly and a `calendar_dates`
      removal takes it out; `HOLIDAY` has no weekly row and adds that one date,
      so every H8 answer for the date comes from the exception-only calendar.
    * "After 18:00" is strictly greater, so the 18:00:00 departures are excluded
      and 18:20 and 19:10 are not. `24:30:00` is a service-day time that follows
      `23:50:00`.
    * A `frequencies.txt` window is anchored at the trip's first stop, so a trip
      leaving Harbor Yards at 20:00 and boarding Central Station 15 minutes later
      answers 20:15-22:15 with an exclusive end; an exact and a nonexact window
      on that trip stay distinct and neither becomes a listed departure.
    * A trip with no recorded departure time is disclosed beside the answer and
      counted in no total.
    * Coverage counts templates, so a frequency trip and a trip with no recorded
      time are both service; H12 keeps Sunday frequency service through `SCHOOL`
      after `REGULAR` ends, while H8 has nothing.

  The interleaving case runs the production snapshot boundary on its own
  committing connection, so the writer's committed change is either wholly
  invisible or wholly visible to rows, totals and digest.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.ServiceQueries
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @collect_timeout 10_000
  @pause_timeout 30_000
  @race_handler {__MODULE__, :service_query_snapshot_race}

  # 2026-11-26 is Thanksgiving in the A02 worked example: a weekday Thursday
  # whose weekday service is removed and replaced by an exception-only calendar.
  @thanksgiving ~D[2026-11-26]
  @thanksgiving_eve ~D[2026-11-25]
  @regular_last_day ~D[2026-10-31]
  @nov_first ~D[2026-11-01]
  @nov_sunday ~D[2026-11-08]
  @central "CENTRAL"
  @harbor "HARBOR"

  # `start_supervised!` rather than a linked `Task.Supervisor.start_link/0`: a
  # linked supervisor is already shutting down by the time `on_exit` runs, so
  # stopping it there races and fails the test for a reason of its own.
  setup do
    {:ok, supervisor: start_supervised!({Task.Supervisor, []})}
  end

  describe "departures/2 (AC-5, AC-6, AC-7, AC-8)" do
    test "answers the A02 holiday replacement with typed windows and a separate unknown time" do
      scope = harbor_scope()

      assert {:ok, answer} = departures(scope, departure_selection())

      # The weekday baseline is removed on this date and the exception-only
      # calendar supplies the trips, so the whole answer comes from it.
      assert answer.active_service_ids == ["HOLIDAY"]
      assert answer.route.state == :active
      assert answer.route.route_id == "H8"
      assert answer.timezone == "America/New_York"
      assert answer.occurrence == %{stop_id: @central, stop_sequence: 1}
      assert answer.stop_name == "Central Station"
      assert answer.completeness == :complete
      assert answer.disclosures == []

      # 18:20 and 19:10 are the only listed departures strictly after 18:00:
      # the two 18:00:00 departures are at the boundary and are excluded.
      expected = [
        {secs("18:20:00"), "H8-1820", "18:20:00"},
        {secs("19:10:00"), "H8-1910", "19:10:00"}
      ]

      assert expected == Enum.map(answer.departures, &{&1.secs, &1.trip_id, &1.time})

      assert answer.total == 2
      assert Enum.all?(answer.departures, &(&1.secs > secs("18:00:00")))

      # The 20:00-22:00 first-stop window is translated by the occurrence's
      # 15-minute offset: 20:15-22:15, with the end still exclusive.
      nonexact = Enum.find(answer.frequency_windows, &(&1.exact_times == 0))

      assert nonexact.trip_id == "H8-FREQ"
      assert nonexact.start_secs == secs("20:15:00")
      assert nonexact.end_secs == secs("22:15:00")
      assert nonexact.start_time == "20:15:00"
      assert nonexact.end_time == "22:15:00"
      assert nonexact.offset_secs == 15 * 60
      assert nonexact.headway_secs == 20 * 60
      assert nonexact.expanded? == false

      # The trip's own stop time anchors the window; it is a template, not an
      # extra listed departure.
      refute Enum.any?(answer.departures, &(&1.trip_id == "H8-FREQ"))
      assert %{reason: :frequency_template, count: 1} = exclusion(answer, :frequency_template)

      # The unknown time is disclosed beside the answer and counted nowhere.
      assert [unknown] = answer.unknown_times
      assert unknown.trip_id == "H8-UNKNOWN"

      refute Enum.any?(answer.departures, &(&1.trip_id == "H8-UNKNOWN"))

      # 18:00 twice (H8-1800 and the loop's first visit) and 24:30 without an
      # after-midnight request.
      assert %{reason: :before_boundary, count: 2} = exclusion(answer, :before_boundary)

      assert %{reason: :after_midnight_excluded, count: 1} =
               exclusion(answer, :after_midnight_excluded)

      # The digest identifies the content this answer was computed from.
      assert answer.digest =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "keeps an exact frequency window distinct and out of the exact total" do
      scope = harbor_scope()

      assert {:ok, answer} = departures(scope, departure_selection())

      exact = Enum.find(answer.frequency_windows, &(&1.exact_times == 1))

      # Both windows of the same trip stay typed and distinct: the exact one is
      # 21:00-22:00 at the first stop, so 21:15-22:15 at this occurrence.
      assert exact.trip_id == "H8-FREQ"
      assert exact.start_time == "21:15:00"
      assert exact.end_time == "22:15:00"
      assert exact.offset_secs == 15 * 60
      assert exact.expanded? == false

      # A window is never expanded into invented listed departures.
      assert length(answer.frequency_windows) == 2
      assert answer.total == 2
    end

    test "requires a selected occurrence for a loop stop and orders 24:30 after 23:50" do
      scope = harbor_scope()

      # The loop visits Central Station twice, so the stop alone is ambiguous and
      # the candidates are the exact sequences that answer it.
      assert {:error, {:ambiguous_occurrence, candidates}} =
               departures(
                 scope,
                 %{departure_selection() | occurrence: %{stop_id: @central, stop_sequence: nil}}
               )

      assert Enum.map(candidates, & &1.stop_sequence) == [1, 9]

      assert {:ok, later} =
               departures(
                 scope,
                 %{
                   departure_selection()
                   | after_secs: secs("17:00:00"),
                     include_after_midnight?: true,
                     occurrence: %{stop_id: @central, stop_sequence: 9}
                 }
               )

      # The loop's later visit resolves by occurrence, never by stop name.
      assert later.occurrence == %{stop_id: @central, stop_sequence: 9}
      assert [departure] = later.departures
      assert departure.trip_id == "H8-LOOP"
      assert departure.secs == secs("23:50:00")
      assert departure.time == "23:50:00"
      assert later.total == 1

      # 18:00 is excluded by "after 18:00" at the loop's first visit too.
      assert {:ok, first_visit} = departures(scope, departure_selection())
      assert first_visit.occurrence == %{stop_id: @central, stop_sequence: 1}
      refute Enum.any?(first_visit.departures, &(&1.secs == secs("18:00:00")))
    end

    test "includes an after-midnight service day only when the caller asks" do
      scope = harbor_scope()

      assert {:ok, without} = departures(scope, departure_selection())
      refute Enum.any?(without.departures, &(&1.secs >= 24 * 3600))

      assert {:ok, with_late} =
               departures(scope, %{departure_selection() | include_after_midnight?: true})

      times = Enum.map(with_late.departures, & &1.secs)

      # Ordering is integer service-day seconds, so 24:30 follows the same-day
      # departures instead of sorting first as a display string would. The
      # loop's 23:50 visit belongs to the other occurrence, so it is not in
      # this answer.
      assert times == Enum.sort(times)
      assert secs("24:30:00") in times

      assert Enum.find_index(times, &(&1 == secs("19:10:00"))) <
               Enum.find_index(times, &(&1 == secs("24:30:00")))
    end

    test "separates an unreadable calendar, an unusable zone and an unknown occurrence" do
      scope = harbor_scope()

      # A retained weekly range the shared date evaluator refuses is unreadable
      # source, so the answer refuses and names the service.
      insert_unreadable_calendar(scope, "HOLIDAY")

      assert {:error, {:unreadable_calendar, "HOLIDAY"}} =
               departures(scope, departure_selection())

      unusable_zone = harbor_scope(agencies: [%{agency_timezone: "Mars/Olympus"}])

      assert {:error, {:timezone_unavailable, :invalid}} =
               departures(unusable_zone, departure_selection())

      assert {:error, :occurrence_not_found} =
               departures(harbor_scope(), %{
                 departure_selection()
                 | occurrence: %{stop_id: @harbor, stop_sequence: 4}
               })
    end

    test "refuses a foreign or unbound route and a malformed selection" do
      scope = harbor_scope()

      foreign = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign.id)
      foreign_route = route_fixture(foreign.id, foreign_version.id, %{route_id: "H8"})

      assert {:error, :not_found} =
               departures(%{scope | route_id: foreign_route.id}, departure_selection())

      assert {:error, :not_found} =
               departures(%{scope | organization_id: Ecto.UUID.generate()}, departure_selection())

      assert {:error, :not_found} =
               departures(%{scope | gtfs_version_id: Ecto.UUID.generate()}, departure_selection())

      assert {:error, :invalid_selection} =
               departures(%{scope | route_id: nil}, departure_selection())

      assert {:error, :invalid_selection} =
               departures(scope, Map.put(departure_selection(), :after_secs, "18:00"))

      assert {:error, :invalid_selection} =
               departures(scope, Map.put(departure_selection(), :service_date, "2026-11-26"))

      assert {:error, :invalid_selection} =
               departures(scope, Map.delete(departure_selection(), :include_after_midnight?))

      assert {:error, :invalid_selection} =
               departures(scope, Map.put(departure_selection(), :direction_id, 2))

      assert {:error, :invalid_selection} =
               departures(
                 scope,
                 Map.put(departure_selection(), :occurrence, %{stop_id: "", stop_sequence: 1})
               )
    end

    test "answers an empty route state with a named cause instead of an error" do
      inactive = harbor_scope()

      _route = route_fixture(inactive.organization.id, inactive.version.id, %{route_id: "H9"})

      # A route with no calendar on the requested date is a complete empty
      # answer with a named cause, never a refused occurrence.
      assert {:ok, answer} =
               departures(
                 inactive,
                 %{departure_selection() | service_date: @nov_first}
               )

      assert answer.total == 0
      assert answer.departures == []
      assert answer.active_service_ids == []
      assert exclusion(answer, :no_active_trip).detail =~ "No calendar"
    end

    test "exposes the bound it enforces so the two cannot drift" do
      assert ServiceQueries.examined_occurrence_limit() == 10_000
      assert ServiceQueries.coverage_limits() == %{dates: 31, routes: 20}
    end
  end

  describe "coverage/2 and compare_dates/2 (AC-9, AC-10)" do
    test "reports H8 losing all service while H12 keeps Sunday service on another calendar" do
      scope = harbor_scope()

      selection = %{
        dates: [@nov_first, @nov_sunday],
        route_ids: ["H8", "H12"],
        service_id: "REGULAR"
      }

      assert {:ok, answer} = coverage(scope, selection)

      # One record per route/date pair, and the total covers all of them.
      assert length(answer.records) == 4
      assert answer.total == 4
      assert answer.completeness == :complete
      assert answer.disclosures == []

      h8_first = record(answer, "H8", @nov_first)

      # `REGULAR` ended on 2026-10-31 and H8 has no other service.
      assert h8_first.recorded_service? == false
      assert h8_first.absence_reason == :no_active_trip
      assert h8_first.service_ids == []
      assert h8_first.route_state == :active
      assert record(answer, "H8", @nov_sunday).recorded_service? == false

      h12_sunday = record(answer, "H12", @nov_sunday)

      # H12's Sunday frequency trip runs through `SCHOOL`, the alternate service
      # beside the reviewed calendar.
      assert h12_sunday.recorded_service? == true
      assert h12_sunday.service_ids == ["SCHOOL"]
      assert h12_sunday.alternate_service_ids == ["SCHOOL"]

      # A frequency template is evidence of service, not a departure count, and
      # the trip with no recorded time beside it is listed service too.
      assert h12_sunday.frequency_templates == 1
      assert h12_sunday.listed_trip_templates == 1
      assert h12_sunday.missing_time_templates == 1
      assert h12_sunday.absence_reason == nil
    end

    test "counts a trip with no recorded time as service" do
      scope = harbor_scope()

      assert {:ok, answer} =
               coverage(scope, %{dates: [@nov_sunday], route_ids: ["H12"], service_id: nil})

      record = hd(answer.records)

      assert record.recorded_service? == true
      assert record.listed_trip_templates == 1
      assert record.missing_time_templates == 1

      # Without a named calendar every active service is listed, so nothing is
      # hidden by omitting the argument.
      assert record.alternate_service_ids == record.service_ids
    end

    test "distinguishes an inactive route, a route without trips and no active service" do
      scope = harbor_scope()

      route_fixture(scope.organization.id, scope.version.id, %{route_id: "H8-OLD", active: false})
      route_fixture(scope.organization.id, scope.version.id, %{route_id: "H14"})

      assert {:ok, answer} =
               coverage(scope, %{
                 dates: [@nov_first],
                 route_ids: ["H8", "H8-OLD", "H14"],
                 service_id: nil
               })

      assert record(answer, "H8", @nov_first).absence_reason == :no_active_trip

      assert record(answer, "H8-OLD", @nov_first).route_state == :inactive
      assert record(answer, "H8-OLD", @nov_first).absence_reason == :inactive_route
      assert record(answer, "H8-OLD", @nov_first).recorded_service? == false

      assert record(answer, "H14", @nov_first).absence_reason == :no_recorded_trips
      assert record(answer, "H14", @nov_first).recorded_service? == false
    end

    test "marks an unreadable relevant calendar undetermined instead of zero service" do
      scope = harbor_scope()
      insert_unreadable_calendar(scope, "SCHOOL")

      assert {:ok, answer} =
               coverage(scope, %{dates: [@nov_sunday], route_ids: ["H12"], service_id: "SCHOOL"})

      record = hd(answer.records)

      assert record.recorded_service? == nil
      assert record.absence_reason == :unreadable_calendar
      assert record.unreadable_service_ids == ["SCHOOL"]
      assert answer.completeness == :incomplete
      assert answer.total == nil
      assert [%{reason: :unreadable_calendar}] = answer.disclosures
    end

    test "compares explicit dates without hiding a route that never changed" do
      scope = harbor_scope()

      assert {:ok, answer} =
               compare_dates(scope, %{
                 dates: [@thanksgiving, @thanksgiving_eve],
                 route_ids: ["H8", "H12"],
                 service_id: "REGULAR"
               })

      assert answer.dates == [@thanksgiving_eve, @thanksgiving]
      assert answer.completeness == :complete
      assert length(answer.comparisons) == 2

      h8 = Enum.find(answer.comparisons, &(&1.route_id == "H8"))

      # Wednesday the 25th has no H8 service in this fixture; Thanksgiving has
      # the holiday replacement.
      assert h8.dates_with_service == [@thanksgiving]
      assert h8.dates_without_service == [@thanksgiving_eve]
      assert h8.service_ids == ["HOLIDAY"]

      h12 = Enum.find(answer.comparisons, &(&1.route_id == "H12"))

      assert h12.dates_with_service == []
      assert h12.dates_without_service == [@thanksgiving_eve, @thanksgiving]
      assert h12.undetermined_dates == []
      assert h12.first_service_date == nil
      assert h12.last_service_date == nil
    end

    test "refuses over-limit, foreign and malformed coverage requests" do
      scope = harbor_scope()

      assert {:error, :too_many_dates} =
               coverage(scope, %{
                 dates: Enum.to_list(Date.range(@nov_first, Date.add(@nov_first, 31))),
                 route_ids: ["H8"]
               })

      assert {:error, :too_many_routes} =
               coverage(scope, %{
                 dates: [@nov_first],
                 route_ids: Enum.map(1..21, &"R#{&1}")
               })

      assert {:error, :not_found} =
               coverage(scope, %{dates: [@nov_first], route_ids: ["NOT-A-ROUTE"]})

      assert {:error, :invalid_selection} =
               coverage(scope, %{dates: [@nov_first], route_ids: []})

      assert {:error, :invalid_selection} =
               coverage(scope, %{dates: [@nov_first, @nov_first], route_ids: ["H8"]})

      assert {:error, :invalid_selection} =
               coverage(scope, %{dates: "2026-11-01", route_ids: ["H8"]})

      # A malformed range is a route question for step 4's pack to ask, so it is
      # an invalid selection rather than a route refusal.
      assert {:error, :invalid_selection} =
               coverage(scope, %{dates: [@nov_first], route_ids: [123]})
    end
  end

  describe "one snapshot (AC-11, AC-12)" do
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

      # The reader pauses inside its repeatable-read transaction, after it has
      # read the trips and before it reads their calendars.
      pause_after_trip_read(parent, reader_pid)
      send(reader_pid, :start_read)
      assert_receive {:reader_paused, ^reader_pid}, @collect_timeout

      assert :ok = in_task(supervisor, fn -> remove_holiday_service(scope) end)
      send(reader_pid, :resume_query)

      assert {:ok, before_change} = await_worker(reader)

      # Read wholly before the commit: the added holiday exception is still
      # there, so the rows, total and digest describe that state.
      assert Enum.map(before_change.departures, & &1.trip_id) == ["H8-1820", "H8-1910"]
      assert before_change.active_service_ids == ["HOLIDAY"]
      assert before_change.total == 2

      assert {:ok, after_change} =
               in_task(supervisor, fn -> departures(scope, departure_selection()) end)

      # Read wholly after the commit: the removal exception takes the date out
      # of the exception calendar, so the same request has no service at all.
      # Two whole states, never one of each.
      assert after_change.departures == []
      assert after_change.unknown_times == []
      assert after_change.active_service_ids == []
      assert after_change.total == 0
      assert exclusion(after_change, :no_active_trip).count == 0
      refute after_change.digest == before_change.digest

      # The queries read only: the only changed row is the writer's own exception.
      assert counts(scope) == seeded
      assert audit_count(scope) == 0
    end

    test "leaves the source rows unchanged", %{supervisor: supervisor} do
      scope = harbor_scope()

      before = counts(scope)

      assert {:ok, _answer} = departures(scope, departure_selection())

      assert {:ok, _coverage} =
               coverage(scope, %{dates: [@nov_sunday], route_ids: ["H8", "H12"]})

      assert counts(scope) == before
      assert audit_count(scope) == 0
      assert supervisor != nil
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # Harbor Transit's illustrative A02/A19 dataset: `WEEKDAY` is the recurring
  # calendar removed on the holiday, `HOLIDAY` is exception-only, `SCHOOL` keeps
  # H12's Sunday service after `REGULAR` ends, and `REGULAR` is the calendar the
  # A19 coverage question reviews.
  defp harbor_scope(opts \\ []) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    for attrs <- Keyword.get(opts, :agencies, [%{agency_timezone: "America/New_York"}]) do
      agency_fixture(organization.id, version.id, attrs)
    end

    for {stop_id, stop_name} <- [
          {@central, "Central Station"},
          {@harbor, "Harbor Yards"}
        ] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})
    route_fixture(organization.id, version.id, %{route_id: "H12"})

    calendar_fixture(
      organization.id,
      version.id,
      weekday_calendar("WEEKDAY", ~D[2026-01-01], ~D[2026-12-31])
    )

    calendar_fixture(
      organization.id,
      version.id,
      daily_calendar("REGULAR", ~D[2026-01-01], @regular_last_day)
    )

    calendar_fixture(
      organization.id,
      version.id,
      sunday_calendar("SCHOOL", ~D[2026-09-01], ~D[2026-12-31])
    )

    # The holiday replacement: the weekday baseline is removed on 2026-11-26 and
    # an exception-only calendar with no weekly row adds that one date.
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

    seed_trips(organization.id, version.id)

    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      route_id: route.id,
      organization: organization,
      version: version,
      route: route
    }
  end

  defp seed_trips(organization_id, version_id) do
    # Three holiday departures at Central Station, two of them exactly at the
    # 18:00 boundary and one of them after midnight.
    for {trip_id, time} <- [
          {"H8-1800", "18:00:00"},
          {"H8-1820", "18:20:00"},
          {"H8-1910", "19:10:00"},
          {"H8-LATE", "24:30:00"}
        ] do
      holiday_trip(organization_id, version_id, trip_id, [
        {@central, 1, time}
      ])
    end

    # A loop that visits Central Station twice, so the occurrence is the pair.
    holiday_trip(organization_id, version_id, "H8-LOOP", [
      {@central, 1, "18:00:00"},
      {@harbor, 5, "21:00:00"},
      {@central, 9, "23:50:00"}
    ])

    # A frequency trip leaving its first stop at 20:00 and boarding Central
    # Station 15 minutes later, with one nonexact and one exact window.
    holiday_trip(organization_id, version_id, "H8-FREQ", [
      {@harbor, 0, "20:00:00"},
      {@central, 1, "20:15:00"}
    ])

    frequency_fixture(organization_id, version_id, "H8-FREQ", %{
      start_time: "20:00:00",
      end_time: "22:00:00",
      headway_secs: 1200,
      exact_times: 0
    })

    frequency_fixture(organization_id, version_id, "H8-FREQ", %{
      start_time: "21:00:00",
      end_time: "22:00:00",
      headway_secs: 600,
      exact_times: 1
    })

    # A holiday trip with no usable departure time at the occurrence.
    holiday_trip(organization_id, version_id, "H8-UNKNOWN", [{@central, 1, nil}])

    # H12 keeps Sunday service through `SCHOOL` after `REGULAR` ends.
    school_trip(organization_id, version_id, "H12-SUN-FREQ", [{@central, 1, "12:00:00"}])

    frequency_fixture(organization_id, version_id, "H12-SUN-FREQ", %{
      start_time: "12:00:00",
      end_time: "14:00:00",
      headway_secs: 1800,
      exact_times: 0
    })

    school_trip(organization_id, version_id, "H12-SUN-UNKNOWN", [{@central, 1, nil}])
  end

  defp holiday_trip(organization_id, version_id, trip_id, stops) do
    trip =
      trip_fixture(organization_id, version_id, "H8", %{
        trip_id: trip_id,
        service_id: "HOLIDAY",
        direction_id: 0
      })

    Enum.each(stops, fn {stop_id, sequence, time} ->
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end)

    trip
  end

  defp school_trip(organization_id, version_id, trip_id, stops) do
    trip =
      trip_fixture(organization_id, version_id, "H12", %{
        trip_id: trip_id,
        service_id: "SCHOOL"
      })

    Enum.each(stops, fn {stop_id, sequence, time} ->
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
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

  defp sunday_calendar(service_id, first, last) do
    %{
      service_id: service_id,
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 1,
      start_date: first,
      end_date: last
    }
  end

  defp daily_calendar(service_id, first, last) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1,
      start_date: first,
      end_date: last
    }
  end

  # A retained weekly range the shared date evaluator refuses cannot be written
  # through the changeset, so the row is inserted as persisted source. A service
  # the fixture already created is rewritten in place, because the calendar
  # itself is unique per organization, version and service.
  defp insert_unreadable_calendar(scope, service_id) do
    attrs = %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      service_id: service_id,
      monday: 1,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-12-31],
      end_date: ~D[2026-01-01]
    }

    case Repo.get_by(Calendar,
           organization_id: scope.organization_id,
           gtfs_version_id: scope.gtfs_version_id,
           service_id: service_id
         ) do
      nil -> Repo.insert!(struct!(%Calendar{}, attrs))
      calendar -> Repo.update!(Ecto.Changeset.change(calendar, attrs))
    end
  end

  # The writer commits a conflicting change: the added exception becomes a
  # removal, which is the interleaving the snapshot must hide or expose whole.
  defp remove_holiday_service(scope) do
    {1, _returned} =
      Repo.update_all(
        from(d in CalendarDate,
          where:
            d.organization_id == ^scope.organization_id and
              d.gtfs_version_id == ^scope.gtfs_version_id and
              d.service_id == "HOLIDAY" and d.date == ^@thanksgiving
        ),
        set: [exception_type: 2]
      )

    :ok
  end

  # -- calls ------------------------------------------------------------------

  defp departure_selection do
    %{
      service_date: @thanksgiving,
      after_secs: secs("18:00:00"),
      include_after_midnight?: false,
      direction_id: 0,
      occurrence: %{stop_id: @central, stop_sequence: 1}
    }
  end

  defp departures(scope, selection), do: ServiceQueries.departures(scope, selection)

  defp coverage(scope, selection),
    do: ServiceQueries.coverage(Map.put(scope, :route_id, nil), selection)

  defp compare_dates(scope, selection),
    do: ServiceQueries.compare_dates(Map.put(scope, :route_id, nil), selection)

  defp exclusion(answer, reason), do: Enum.find(answer.exclusions, &(&1.reason == reason))

  defp record(answer, route_id, date),
    do: Enum.find(answer.records, &(&1.route_id == route_id and &1.date == date))

  defp secs(clock) do
    {:ok, value} = GtfsTime.parse(clock)
    value
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

  # -- snapshot plumbing ------------------------------------------------------

  # The reader runs the production entrypoint on its own committing connection,
  # so `SET TRANSACTION ISOLATION LEVEL` applies and the pause happens inside the
  # snapshot rather than inside the test's rolled-back transaction.
  defp pause_then_read(scope, parent) do
    send(parent, {:reader_ready, self()})

    receive do
      :start_read -> :ok
    end

    unboxed(fn -> departures(scope, departure_selection()) end)
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
        flunk("query worker failed: #{inspect(reason)}")
    after
      @collect_timeout ->
        flunk("query worker timed out")
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

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Unboxed cases commit, so this package's own fixtures are deleted explicitly.
  defp cleanup(scopes) do
    unboxed(fn ->
      organization_ids = Enum.map(scopes, & &1.organization.id)

      Repo.delete_all(from(f in Frequency, where: f.organization_id in ^organization_ids))
      Repo.delete_all(from(s in StopTime, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(c in Calendar, where: c.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end
end
