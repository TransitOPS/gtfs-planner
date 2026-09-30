defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.EditStopTest do
  @moduledoc """
  Merge evidence (EV-12) for the R1 stop edit through the engine (step 13):

  - The Cedar Library example: editing Cedar Library 07:26 → 07:28 with `:later`
    moves Market Square to 07:35 and Valley College to 07:55, leaves Riverside at
    07:15, and makes the trip custom with reason `edited_in_schedules` (AC-2, AC-3,
    FH-3).
  - An edit whose result equals the Peak timing's materialization links the trip to
    Peak (`timed_pattern_id` = Peak, state `linked`, reason nil); equal clocks with a
    different `pickup_type` stay custom (AC-3, FH-5).
  - A first-stop edit moves the whole trip and keeps the linked timing (AC-2, AC-3).
  - A Timepoints `:only` edit persists the re-spaced hidden stop with
    `timepoint = 0` and its literal floored clock (AC-2).
  - Delete/Backspace clears only an intermediate stop whose stored `timepoint` is 0;
    any other clear is refused (AC-5).
  - An out-of-order edit, a time below 00:00, a frequency trip, a trip whose stops
    differ, and a stale edit are refused and leave the clocks and `updated_at`
    unchanged with no audit log (AC-4, FH-6).

  Every expected value is literal and hand-derived from R1 and the §4.2 examples in
  spec.md; nothing computes an expectation with the planner under test. Every edit
  runs through the real production entry point `Gtfs.apply_trip_change/4` with an
  `{:expected, …}` fence, on the real local PostgreSQL test database with sandboxed
  fixtures.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/trip_changes/edit_stop_test.exs`
  (EV-12, 120 s deadline).
  """
  use GtfsPlanner.DataCase

  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StopTime

  @cedar_stops [
    {"Riverside", 0, 0, 1},
    {"Cedar Library", 660, 660, 1},
    {"Market Square", 1080, 1080, 1},
    {"Valley College", 2280, 2280, 1}
  ]
  @base_stops [
    {"Riverside", 0, 0, 1},
    {"Cedar Library", 600, 600, 1},
    {"Market Square", 1020, 1020, 1},
    {"Valley College", 2220, 2220, 1}
  ]
  @peak_offsets [{0, 0, 1}, {780, 780, 1}, {1200, 1200, 1}, {2400, 2400, 1}]
  @clear_stops [
    {"Riverside", 0, 0, 1},
    {"Cedar Library", 600, 600, 0},
    {"Market Square", 1200, 1200, 1},
    {"Valley College", 1800, 1800, 1}
  ]
  @timepoint_stops [
    {"Riverside", 0, 0, 1},
    {"Cedar Library", 300, 300, 0},
    {"Market Square", 600, 600, 1},
    {"Valley College", 900, 900, 1}
  ]
  @stop_ids ["Riverside", "Cedar Library", "Market Square", "Valley College"]

  describe "the Cedar Library example (AC-2, AC-3, FH-3)" do
    test "moves the edited stop and later stops only and makes the trip custom" do
      scope = editing_scope!("12", %{stops: @cedar_stops})
      trip = linked_trip!(scope, "07:15:00")

      command =
        {:edit_stop, trip.id, %{position: 2, value: 26_880, mode: :later, shown_positions: :all}}

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert result.changed_trip_ids == [trip.id]
      assert result.created_trip_ids == []
      assert result.deleted_trip_ids == []
      assert result.transfers_removed == 0

      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", nil, nil},
               {"07:28:00", "07:28:00", nil, nil},
               {"07:35:00", "07:35:00", nil, nil},
               {"07:55:00", "07:55:00", nil, nil}
             ]

      row = trip_row(trip)
      assert row.pattern_derivation_state == "custom"
      assert row.pattern_derivation_reason == "edited_in_schedules"
      assert row.timed_pattern_id == nil
      assert DateTime.compare(row.updated_at, trip.updated_at) == :gt

      assert result.change_set.consequences == [{:note, {:becomes_custom, [trip.id]}}]
    end
  end

  describe "relinking (AC-3, FH-5)" do
    test "links an edit whose result equals the Peak timing's materialization" do
      scope = peak_scope!()
      trip = linked_trip!(scope, "07:15:00")
      set_timepoints!(trip, 1)

      command =
        {:edit_stop, trip.id, %{position: 2, value: 26_880, mode: :later, shown_positions: :all}}

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", 1, nil},
               {"07:28:00", "07:28:00", 1, nil},
               {"07:35:00", "07:35:00", 1, nil},
               {"07:55:00", "07:55:00", 1, nil}
             ]

      row = trip_row(trip)
      assert row.pattern_derivation_state == "linked"
      assert row.timed_pattern_id == scope.peak.id
      assert row.pattern_derivation_reason == nil
      assert result.change_set.consequences == []
    end

    test "equal clocks with a different pickup_type stay custom (FH-5)" do
      scope = peak_scope!()

      trip =
        custom_trip!(scope, [
          {"Riverside", "07:15:00", "07:15:00"},
          {"Cedar Library", "07:28:00", "07:28:00"},
          {"Market Square", "07:35:00", "07:35:00"},
          {"Valley College", "07:55:00", "07:55:00"}
        ])

      set_timepoints!(trip, 1)
      set_pickup_type!(trip, "Cedar Library", 1)

      # The result equals the Base timing in clocks and timepoints, but its Cedar
      # Library pickup type is 1 where the timing stores nil, so it stays custom.
      command =
        {:edit_stop, trip.id, %{position: 2, value: 26_700, mode: :later, shown_positions: :all}}

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", 1, nil},
               {"07:25:00", "07:25:00", 1, 1},
               {"07:32:00", "07:32:00", 1, nil},
               {"07:52:00", "07:52:00", 1, nil}
             ]

      row = trip_row(trip)
      assert row.pattern_derivation_state == "custom"
      assert row.pattern_derivation_reason == "edited_in_schedules"
      assert row.timed_pattern_id == nil
      assert result.change_set.consequences == []
    end
  end

  describe "whole-trip moves (AC-2, AC-3)" do
    test "a first-stop edit moves the whole trip and keeps the linked timing" do
      scope = base_scope!()
      trip = linked_trip!(scope, "07:15:00")

      command =
        {:edit_stop, trip.id, %{position: 1, value: 26_400, mode: :only, shown_positions: :all}}

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert [update] = result.change_set.updates
      assert update.fields == %{}

      assert stop_time_clocks(trip) == [
               {"07:20:00", "07:20:00", nil, nil},
               {"07:30:00", "07:30:00", nil, nil},
               {"07:37:00", "07:37:00", nil, nil},
               {"07:57:00", "07:57:00", nil, nil}
             ]

      row = trip_row(trip)
      assert row.pattern_derivation_state == "linked"
      assert row.timed_pattern_id == scope.bundle.timing.id
      assert row.pattern_derivation_reason == nil
      assert result.change_set.consequences == []
    end

    test "a last-stop :anchor edit moves every stop" do
      scope = base_scope!()
      trip = linked_trip!(scope, "07:15:00")

      # The last stop edits arrival: 07:52 → 08:02 moves every stop by +10 minutes.
      command =
        {:edit_stop, trip.id, %{position: 4, value: 28_920, mode: :anchor, shown_positions: :all}}

      assert {:ok, _result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == [
               {"07:25:00", "07:25:00", nil, nil},
               {"07:35:00", "07:35:00", nil, nil},
               {"07:42:00", "07:42:00", nil, nil},
               {"08:02:00", "08:02:00", nil, nil}
             ]

      assert trip_row(trip).pattern_derivation_state == "linked"
    end
  end

  describe "the Timepoints :only edit (AC-2)" do
    test "persists the re-spaced hidden stop with timepoint 0 and a floored clock" do
      scope = editing_scope!("12", %{stops: @timepoint_stops})
      trip = linked_trip!(scope, "07:15:00")
      set_timepoints!(trip, [1, 0, 1, 1])

      # Market Square 07:25 → 07:28; Cedar Library is hidden between Riverside and
      # Market Square, so it re-spaces to 07:15 + floor(300 × 780 / 600) = 07:21:30
      # and is stored as a timepoint-0 stop.
      command =
        {:edit_stop, trip.id,
         %{position: 3, value: 26_880, mode: :only, shown_positions: [1, 3, 4]}}

      assert {:ok, _result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", 1, nil},
               {"07:21:30", "07:21:30", 0, nil},
               {"07:28:00", "07:28:00", 1, nil},
               {"07:30:00", "07:30:00", 1, nil}
             ]

      row = trip_row(trip)
      assert row.pattern_derivation_state == "custom"
      assert row.pattern_derivation_reason == "edited_in_schedules"
    end
  end

  describe "clearing (AC-5)" do
    test "clears an intermediate timepoint-0 stop and persists empty clocks" do
      scope = editing_scope!("12", %{stops: @clear_stops})
      trip = linked_trip!(scope, "07:15:00")
      set_timepoints!(trip, [1, 0, 1, 1])

      command =
        {:edit_stop, trip.id, %{position: 2, value: :clear, mode: :only, shown_positions: :all}}

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", 1, nil},
               {nil, nil, 0, nil},
               {"07:35:00", "07:35:00", 1, nil},
               {"07:45:00", "07:45:00", 1, nil}
             ]

      row = trip_row(trip)
      assert row.pattern_derivation_state == "custom"
      assert row.pattern_derivation_reason == "edited_in_schedules"
      assert result.change_set.consequences == [{:note, {:becomes_custom, [trip.id]}}]
    end

    test "refuses a clear at a timepoint stop, the first stop and the last stop" do
      scope = base_scope!()
      trip = linked_trip!(scope, "07:15:00")
      clocks_before = stop_time_clocks(trip)

      for position <- [1, 2, 4] do
        command =
          {:edit_stop, trip.id,
           %{position: position, value: :clear, mode: :only, shown_positions: :all}}

        assert {:error, {:refused, [{:error, :clear_not_allowed}]}} =
                 Gtfs.apply_trip_change(
                   "12",
                   command,
                   {:expected, %{trip.id => trip.updated_at}},
                   scope.audit
                 )
      end

      assert stop_time_clocks(trip) == clocks_before
      assert DateTime.compare(trip_row(trip).updated_at, trip.updated_at) == :eq
      assert trip_logs(trip) == []
    end
  end

  describe "refusals write nothing (AC-4, FH-6)" do
    test "an out-of-order edit is refused with the pattern occurrence position" do
      scope = base_scope!()
      trip = linked_trip!(scope, "07:15:00")
      clocks_before = stop_time_clocks(trip)

      # Market Square 07:32 → 07:20 is earlier than Cedar Library's 07:25 departure.
      command =
        {:edit_stop, trip.id, %{position: 3, value: 26_400, mode: :only, shown_positions: :all}}

      assert {:error, {:refused, [{:error, {:out_of_order, 3}}]}} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == clocks_before
      assert DateTime.compare(trip_row(trip).updated_at, trip.updated_at) == :eq
      assert trip_logs(trip) == []
    end

    test "an anchor edit below 00:00 is refused" do
      scope = base_scope!()
      trip = linked_trip!(scope, "07:15:00")
      clocks_before = stop_time_clocks(trip)

      # The last stop 07:52 → 00:30 drags the first stop below 00:00.
      command =
        {:edit_stop, trip.id, %{position: 4, value: 1_800, mode: :anchor, shown_positions: :all}}

      assert {:error, {:refused, [{:error, :negative_time}]}} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == clocks_before
      assert DateTime.compare(trip_row(trip).updated_at, trip.updated_at) == :eq
      assert trip_logs(trip) == []
    end

    test "a frequency trip is refused" do
      scope = base_scope!()
      trip = frequency_trip!(scope, [{"06:00:00", "07:00:00", 600}])
      clocks_before = stop_time_clocks(trip)
      windows_before = frequency_rows(trip)

      command =
        {:edit_stop, trip.id, %{position: 2, value: 26_880, mode: :later, shown_positions: :all}}

      assert {:error, {:refused, [{:error, :frequency_trip}]}} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == clocks_before
      assert frequency_rows(trip) == windows_before
      assert DateTime.compare(trip_row(trip).updated_at, trip.updated_at) == :eq
    end

    test "a trip whose stops differ from the pattern is refused" do
      scope = base_scope!()

      trip =
        custom_trip!(scope, [
          {"Riverside", "07:15:00", "07:15:00"},
          {"Cedar Library", "07:26:00", "07:26:00"}
        ])

      clocks_before = stop_time_clocks(trip)

      command =
        {:edit_stop, trip.id, %{position: 1, value: 26_400, mode: :later, shown_positions: :all}}

      assert {:error, {:refused, [{:error, :stops_differ}]}} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => trip.updated_at}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == clocks_before
      assert DateTime.compare(trip_row(trip).updated_at, trip.updated_at) == :eq
      assert trip_logs(trip) == []
    end

    test "a stale updated_at is refused with nothing written" do
      scope = base_scope!()
      trip = linked_trip!(scope, "07:15:00")
      clocks_before = stop_time_clocks(trip)
      stale = DateTime.add(trip.updated_at, -1, :second)

      command =
        {:edit_stop, trip.id, %{position: 2, value: 26_880, mode: :later, shown_positions: :all}}

      assert {:error, :stale} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => stale}},
                 scope.audit
               )

      assert stop_time_clocks(trip) == clocks_before
      assert DateTime.compare(trip_row(trip).updated_at, trip.updated_at) == :eq
      assert trip_logs(trip) == []
    end
  end

  # -- Fixtures and readbacks -------------------------------------------------

  defp base_scope! do
    editing_scope!("12", %{stops: @base_stops, timing_name: "Base"})
  end

  defp peak_scope! do
    scope = base_scope!()
    Map.put(scope, :peak, extra_timing!(scope.bundle, @peak_offsets, "Peak"))
  end

  defp set_timepoints!(trip, timepoint) when is_integer(timepoint) do
    Enum.each(@stop_ids, &set_timepoint!(trip, &1, timepoint))
  end

  defp set_timepoints!(trip, timepoints) when is_list(timepoints) do
    @stop_ids
    |> Enum.zip(timepoints)
    |> Enum.each(fn {stop_id, timepoint} -> set_timepoint!(trip, stop_id, timepoint) end)
  end

  defp set_timepoint!(trip, stop_id, timepoint) do
    Repo.update_all(stop_time_query(trip, stop_id), set: [timepoint: timepoint])
  end

  defp set_pickup_type!(trip, stop_id, pickup_type) do
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
