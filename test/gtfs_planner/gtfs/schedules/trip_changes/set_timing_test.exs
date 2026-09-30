defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.SetTimingTest do
  @moduledoc """
  Merge evidence (EV-13) for the R5 timing change through the engine (step 14):

  - Two linked trips on Base and one custom trip take the Peak timing's literal
    clocks at each trip's own first departure, become linked to Peak with reason
    nil, and the custom trip is named once in
    `{:note, {:loses_custom_times, [id]}}` (AC-12).
  - A trip whose stops differ is excluded as
    `{:note, {:excluded, id, :stops_differ}}` and stays byte-unchanged with no
    audit log (AC-12, FH-22); a selected trip of another pattern is excluded the
    same way even when its stops match the chosen timing's pattern.
  - A frequency trip's template changes to the chosen timing and its frequency
    windows stay byte-unchanged (AC-12).
  - A selection in which no trip is eligible is refused with `:no_eligible_trips`
    and writes nothing.

  Every expected value is literal and hand-derived from R5 and the §4.2 examples
  in spec.md; nothing computes an expectation with the planner under test. Every
  apply runs through the real production entry point `Gtfs.apply_trip_change/4`
  with its reviewed-fingerprint fence, on the real local PostgreSQL test database
  with sandboxed fixtures.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/trip_changes/set_timing_test.exs`
  (EV-13, 120 s deadline).
  """
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPatternStop

  @base_stops [
    {"Riverside", 0, 0, 1},
    {"Cedar Library", 600, 600, 1},
    {"Market Square", 1020, 1020, 1},
    {"Valley College", 2220, 2220, 1}
  ]
  @peak_offsets [{0, 0, 1}, {780, 780, 1}, {1200, 1200, 1}, {2400, 2400, 1}]

  describe "the R5 re-materialization (AC-12)" do
    test "two linked and one custom trip take the new timing's literal clocks and become linked" do
      scope = peak_scope!()
      first = linked_trip!(scope, "07:15:00")
      second = linked_trip!(scope, "08:00:00")

      custom =
        custom_trip!(scope, [
          {"Riverside", "07:20:00", "07:20:00"},
          {"Cedar Library", "07:33:00", "07:33:00"},
          {"Market Square", "07:40:00", "07:40:00"},
          {"Valley College", "08:00:00", "08:00:00"}
        ])

      # A custom per-stop value the timing does not carry: Peak's Cedar Library
      # pickup type is 2, so the custom trip's 1 is replaced by 2.
      set_trip_pickup_type!(custom, "Cedar Library", 1)

      command = {:set_timing, [first.id, second.id, custom.id], scope.peak.id}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 3, created: 0, deleted: 0, excluded: 0, skipped: 0}
      assert review.change_set.consequences == [{:note, {:loses_custom_times, [custom.id]}}]
      assert review.change_set.updates |> Enum.all?(&(&1.frequencies == :unchanged))
      assert review.preview[first.id] == %{1 => 26_100, 2 => 26_880, 3 => 27_300, 4 => 28_500}

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert result.created_trip_ids == []
      assert Enum.sort(result.changed_trip_ids) == Enum.sort([first.id, second.id, custom.id])

      assert stop_time_clocks(first) == [
               {"07:15:00", "07:15:00", 1, nil},
               {"07:28:00", "07:28:00", 1, 2},
               {"07:35:00", "07:35:00", 1, nil},
               {"07:55:00", "07:55:00", 1, nil}
             ]

      assert stop_time_clocks(second) == [
               {"08:00:00", "08:00:00", 1, nil},
               {"08:13:00", "08:13:00", 1, 2},
               {"08:20:00", "08:20:00", 1, nil},
               {"08:40:00", "08:40:00", 1, nil}
             ]

      assert stop_time_clocks(custom) == [
               {"07:20:00", "07:20:00", 1, nil},
               {"07:33:00", "07:33:00", 1, 2},
               {"07:40:00", "07:40:00", 1, nil},
               {"08:00:00", "08:00:00", 1, nil}
             ]

      for trip <- [first, second, custom] do
        row = trip_row(trip)
        assert row.pattern_derivation_state == "linked"
        assert row.timed_pattern_id == scope.peak.id
        assert row.pattern_derivation_reason == nil
        assert DateTime.compare(row.updated_at, trip.updated_at) == :gt

        assert [log] = trip_logs(trip)
        assert log.action == "updated"
        assert log.changed_fields["operation_id"] == result.operation_id
      end
    end
  end

  describe "exclusions (AC-12, FH-22)" do
    test "a trip whose stops differ is excluded and byte-unchanged" do
      scope = peak_scope!()
      eligible = linked_trip!(scope, "07:15:00")

      differ =
        custom_trip!(scope, [
          {"Riverside", "06:00:00", "06:00:00"},
          {"Cedar Library", "06:20:00", "06:20:00"}
        ])

      clocks_before = stop_time_clocks(differ)

      command = {:set_timing, [eligible.id, differ.id], scope.peak.id}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 1, created: 0, deleted: 0, excluded: 1, skipped: 0}
      assert review.change_set.consequences == [{:note, {:excluded, differ.id, :stops_differ}}]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert result.changed_trip_ids == [eligible.id]
      assert trip_row(eligible).timed_pattern_id == scope.peak.id

      assert stop_time_clocks(differ) == clocks_before
      assert DateTime.compare(trip_row(differ).updated_at, differ.updated_at) == :eq
      assert trip_logs(differ) == []
    end

    test "a trip on another pattern is excluded even when its stops match" do
      scope = peak_scope!()
      first = linked_trip!(scope, "07:15:00")

      other_bundle =
        schedule_pattern_fixture(scope.organization.id, scope.version.id, %{
          route_id: scope.bundle.pattern.route_id,
          stops: @base_stops,
          timing_name: "Other"
        })

      other =
        schedule_trip_fixture(
          scope.organization.id,
          scope.version.id,
          scope.bundle.pattern.route_id,
          other_bundle,
          %{service_id: scope.service, state: "linked", start_time: "09:00:00"}
        ).trip

      clocks_before = stop_time_clocks(other)

      command = {:set_timing, [first.id, other.id], scope.peak.id}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts.changed == 1
      assert review.counts.excluded == 1
      assert review.change_set.consequences == [{:note, {:excluded, other.id, :stops_differ}}]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert result.changed_trip_ids == [first.id]
      assert trip_row(first).timed_pattern_id == scope.peak.id

      assert stop_time_clocks(other) == clocks_before
      assert DateTime.compare(trip_row(other).updated_at, other.updated_at) == :eq
      assert trip_logs(other) == []
    end

    test "a selection with no eligible trip is refused and writes nothing" do
      scope = peak_scope!()

      differ =
        custom_trip!(scope, [
          {"Riverside", "06:00:00", "06:00:00"},
          {"Cedar Library", "06:20:00", "06:20:00"}
        ])

      clocks_before = stop_time_clocks(differ)
      command = {:set_timing, [differ.id], scope.peak.id}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert review.change_set.consequences == [
               {:error, :no_eligible_trips},
               {:note, {:excluded, differ.id, :stops_differ}}
             ]

      assert review.counts == %{changed: 0, created: 0, deleted: 0, excluded: 1, skipped: 0}

      assert {:error, {:refused, [{:error, :no_eligible_trips}]}} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert stop_time_clocks(differ) == clocks_before
      assert DateTime.compare(trip_row(differ).updated_at, differ.updated_at) == :eq
      assert trip_logs(differ) == []
    end
  end

  describe "frequency service (AC-12)" do
    test "a frequency trip's template changes and its windows do not" do
      scope = peak_scope!()

      trip =
        frequency_trip!(
          scope,
          [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 600, exact_times: 1}]
        )

      windows_before = frequency_rows(trip)

      assert Enum.map(
               windows_before,
               &{&1.start_time, &1.end_time, &1.headway_secs, &1.exact_times}
             ) ==
               [{"06:00:00", "07:00:00", 600, 1}]

      command = {:set_timing, [trip.id], scope.peak.id}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.change_set.consequences == []

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert result.changed_trip_ids == [trip.id]

      assert stop_time_clocks(trip) == [
               {"06:00:00", "06:00:00", 1, nil},
               {"06:13:00", "06:13:00", 1, 2},
               {"06:20:00", "06:20:00", 1, nil},
               {"06:40:00", "06:40:00", 1, nil}
             ]

      assert frequency_rows(trip) == windows_before

      row = trip_row(trip)
      assert row.pattern_derivation_state == "linked"
      assert row.timed_pattern_id == scope.peak.id
      assert row.pattern_derivation_reason == nil
    end
  end

  # -- Fixtures and readbacks -------------------------------------------------

  defp peak_scope! do
    scope = editing_scope!("12", %{stops: @base_stops, timing_name: "Base"})
    peak = extra_timing!(scope.bundle, @peak_offsets, "Peak")

    # Peak's Cedar Library pickup type is 2, so a change onto Peak must write it
    # over whatever the trip stored.
    Repo.update_all(
      from(row in TimedPatternStop,
        join: occurrence in RoutePatternStop,
        on: occurrence.id == row.route_pattern_stop_id,
        where: row.timed_pattern_id == ^peak.id and occurrence.stop_id == "Cedar Library"
      ),
      set: [pickup_type: 2]
    )

    Map.put(scope, :peak, peak)
  end

  defp set_trip_pickup_type!(trip, stop_id, pickup_type) do
    Repo.update_all(stop_time_query(trip, stop_id), set: [pickup_type: pickup_type])
  end

  defp stop_time_query(trip, stop_id) do
    from(st in StopTime,
      where:
        st.organization_id == ^trip.organization_id and
          st.gtfs_version_id == ^trip.gtfs_version_id and st.trip_id == ^trip.trip_id and
          st.stop_id == ^stop_id
    )
  end
end
