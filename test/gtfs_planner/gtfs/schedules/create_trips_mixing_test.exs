defmodule GtfsPlanner.Gtfs.Schedules.CreateTripsMixingTest do
  @moduledoc """
  Merge evidence (EV-18) for R9 in `Schedules.create_trips/3` (step 19):

  - Listed departures onto a frequency-only pattern-date are refused with
    `{:error, {:mixed_service, details}}` and write no trip, stop-time or audit
    row (FH-12, AC-20).
  - Listed departures onto a pattern-date that already mixes listed and frequency
    trips are created (FH-11).
  - A frequency trip on another pattern of the same route does not refuse the
    create; the rule reads the requested pattern only.
  - Frequency service on a service day sharing none of the requested dates does
    not refuse the create.
  - Frequency service on another service day sharing the requested dates is
    refused, so the check spans the pattern's services and not only the requested
    one.

  Every expected value is literal and hand-derived from R9 and the §4.2 rule
  examples in spec.md; nothing computes an expectation with the code under test.
  Every create runs through the real production entry point `Gtfs.create_trips/3`
  on the real local PostgreSQL test database with sandboxed fixtures.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/create_trips_mixing_test.exs
  test/gtfs_planner/gtfs/schedules/mutations_test.exs
  test/gtfs_planner/gtfs/schedules_test.exs` (EV-18, 120 s deadline); it is
  deferred to branch review.
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # The scope's default calendar runs Mon-Fri over 2026: 261 dates (step-15's
  # shared weekday count). The window is 08:00-09:00 every 10 minutes.
  @weekday_window_start 28_800
  @weekday_window_end 32_400

  describe "R9 in create_trips (EV-18, AC-20)" do
    test "listed trips onto a frequency-only pattern date are refused with no rows (FH-12)" do
      scope = editing_scope!("12")
      frequency = frequency_trip!(scope, [window()])
      frequency_before = trip_row(frequency)
      trips_before = trip_count(scope)
      stop_times_before = stop_time_count(scope)

      assert {:error, {:mixed_service, details}} =
               Gtfs.create_trips("12", create_attrs(scope), scope.audit)

      assert details == %{service_ids: [scope.service], date_count: 261}
      assert trip_count(scope) == trips_before
      assert stop_time_count(scope) == stop_times_before
      assert version_logs(scope) == []
      assert trip_row(frequency) == frequency_before
    end

    test "listed trips onto an already-mixed pattern date are created (FH-11)" do
      scope = editing_scope!("12")
      _listed = linked_trip!(scope, "06:00:00")
      _frequency = frequency_trip!(scope, [window()])

      assert {:ok, %{trips: [created]}} =
               Gtfs.create_trips(
                 "12",
                 create_attrs(scope, %{start_time: "07:00:00"}),
                 scope.audit
               )

      assert created.trip_id == "12-0-#{scope.service}-0700"
      assert created.route_pattern_id == scope.bundle.pattern.route_pattern_id
      assert trip_count(scope) == 3

      assert stop_time_rows(created) == [
               {"A", "07:00:00", "07:00:00"},
               {"B", "07:05:00", "07:05:30"},
               {"C", "07:12:00", "07:12:00"}
             ]

      assert [%ChangeLog{}] = trip_logs(created)
    end

    test "frequency service on another pattern of the route does not refuse the create" do
      scope = editing_scope!("12")

      other =
        schedule_pattern_fixture(scope.organization.id, scope.version.id, %{
          route_id: "12",
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]
        })

      _frequency = frequency_trip!(%{scope | bundle: other}, [window()])

      assert {:ok, %{trips: [created]}} =
               Gtfs.create_trips("12", create_attrs(scope), scope.audit)

      assert created.route_pattern_id == scope.bundle.pattern.route_pattern_id
      assert trip_count(scope) == 2
    end

    test "frequency service on a service day sharing no dates does not refuse the create" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      _frequency = frequency_trip!(scope, [window()], service_id: saturday)

      assert {:ok, %{trips: [created]}} =
               Gtfs.create_trips("12", create_attrs(scope), scope.audit)

      assert created.service_id == scope.service
      assert trip_count(scope) == 2
    end

    test "frequency service on another service day sharing the requested dates is refused" do
      scope = editing_scope!("12")
      %{daily: daily} = shared_dates_calendars!(scope)
      _frequency = frequency_trip!(scope, [window()], service_id: daily)
      trips_before = trip_count(scope)

      assert {:error, {:mixed_service, details}} =
               Gtfs.create_trips("12", create_attrs(scope), scope.audit)

      assert MapSet.new(details.service_ids) == MapSet.new([daily, scope.service])
      # The requested weekday service and the daily service share the 261 weekdays of 2026.
      assert details.date_count == 261
      assert trip_count(scope) == trips_before
      assert version_logs(scope) == []
    end
  end

  describe "R9 in update_trip" do
    test "moving a frequency trip onto listed trips' dates is refused with nothing written" do
      scope = editing_scope!("12")
      %{weekday: weekday, saturday: saturday} = weekday_and_saturday!(scope)
      _listed = linked_trip!(scope, "06:00:00", %{service_id: weekday})
      frequency = frequency_trip!(scope, [window()], service_id: saturday)
      frequency_before = trip_row(frequency)

      assert {:error, {:mixed_service, details}} =
               Gtfs.update_trip(
                 "12",
                 frequency.id,
                 %{service_id: weekday},
                 frequency_before.updated_at,
                 scope.audit
               )

      assert details == %{service_ids: [weekday], date_count: 261}
      assert trip_row(frequency) == frequency_before
      assert version_logs(scope) == []
    end

    test "moving a frequency trip to a service day sharing no listed dates is saved" do
      scope = editing_scope!("12")
      %{weekday: weekday, saturday: saturday} = weekday_and_saturday!(scope)
      _listed = linked_trip!(scope, "06:00:00", %{service_id: saturday})
      frequency = frequency_trip!(scope, [window()], service_id: scope.service)

      assert {:ok, updated} =
               Gtfs.update_trip(
                 "12",
                 frequency.id,
                 %{service_id: weekday},
                 trip_row(frequency).updated_at,
                 scope.audit
               )

      assert updated.service_id == weekday
      assert trip_row(frequency).service_id == weekday
    end
  end

  # -- Fixtures and readbacks -------------------------------------------------

  defp window do
    %{
      start_secs: @weekday_window_start,
      end_secs: @weekday_window_end,
      headway_secs: 600
    }
  end

  defp create_attrs(scope, overrides \\ %{}) do
    Map.merge(
      %{
        pattern_id: scope.bundle.pattern.id,
        timed_pattern_id: scope.bundle.timing.id,
        service_id: scope.service,
        start_time: "07:00:00",
        repeat: nil
      },
      Map.new(overrides)
    )
  end

  defp trip_count(scope) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id
      ),
      :count
    )
  end

  defp stop_time_count(scope) do
    Repo.aggregate(
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization.id and
            st.gtfs_version_id == ^scope.version.id
      ),
      :count
    )
  end

  defp stop_time_rows(trip) do
    Repo.all(
      from(st in StopTime,
        where:
          st.trip_id == ^trip.trip_id and st.organization_id == ^trip.organization_id and
            st.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: st.stop_sequence],
        select: {st.stop_id, st.arrival_time, st.departure_time}
      )
    )
  end

  defp version_logs(scope) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization.id and
            l.gtfs_version_id == ^scope.version.id,
        order_by: [asc: l.inserted_at, asc: l.id]
      )
    )
  end
end
