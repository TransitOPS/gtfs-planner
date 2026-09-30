defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.ConvertTest do
  @moduledoc """
  Merge evidence (EV-17) for converting frequency service through the engine (step 18):

  - A 06:00–07:00 service every 10 minutes converts into six listed trips leaving
    06:00 … 06:50 and none at 07:00, because the stored windows are half-open
    (FH-8, AC-19).
  - Every converted trip is the source's timing materialized at its departure, linked
    to that timing, with the source's service, pattern and headsign, an allocated trip
    ID, no block and no trip number.
  - The apply deletes the frequency trip, its stop times, its frequency rows and the
    transfer naming it, reports the removed transfer count, records one `"trip"` log
    per affected trip under one operation id and returns no restore payload, so
    Convert is not undoable (FH-29, R10, AC-19).
  - A custom source converts into offset copies of its own stored template and keeps
    its custom linkage (R8).
  - A stored window list that R8 refuses (an overlap) plans nothing and an unreadable
    stored clock is `:invalid_command`: a conversion never deletes a source whose
    service it cannot faithfully list.

  Every expected value is literal and hand-derived from R8, R10 and the §4.4
  contracts in spec.md; nothing computes an expectation with the planner under test.
  Every apply runs through the real production entry point
  `Gtfs.apply_trip_change/4` with its reviewed-fingerprint fence, on the real local
  PostgreSQL test database with sandboxed fixtures.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/trip_changes/convert_test.exs`
  (EV-17, 120 s deadline); it is deferred to branch review.
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  describe "converting a linked frequency trip (R8, AC-19)" do
    test "06:00–07:00 every 10 minutes becomes six trips ending 06:50 (FH-8)" do
      scope = editing_scope!("12")

      windows = [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 600, exact_times: 1}]
      trip = frequency_trip!(scope, windows, %{trip_headsign: "Downtown"})
      later = linked_trip!(scope, "08:00:00")
      transfer = in_seat_transfer_fixture(scope.organization.id, scope.version.id, trip, later)
      command = {:convert_frequency, trip.id}
      trips_before = trip_count(scope)

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 0, created: 6, deleted: 1, excluded: 0, skipped: 0}
      assert review.change_set.updates == []
      assert review.change_set.deletes == [trip.id]
      assert review.change_set.consequences == [{:note, {:transfers_removed, 1}}]
      assert review.preview == %{}

      assert Enum.map(review.change_set.inserts, & &1.attrs.trip_id) == [
               "12-0-#{scope.service}-0600",
               "12-0-#{scope.service}-0610",
               "12-0-#{scope.service}-0620",
               "12-0-#{scope.service}-0630",
               "12-0-#{scope.service}-0640",
               "12-0-#{scope.service}-0650"
             ]

      assert Enum.all?(review.change_set.inserts, &(&1.source_id == trip.id))
      assert Enum.all?(review.change_set.inserts, &(&1.frequencies == []))

      [first | _rest] = review.change_set.inserts
      assert first.attrs.service_id == scope.service
      assert first.attrs.route_id == "12"
      assert first.attrs.direction_id == 0
      assert first.attrs.trip_headsign == "Downtown"
      assert first.attrs.trip_short_name == nil
      assert first.attrs.route_pattern_id == scope.bundle.pattern.route_pattern_id
      assert first.attrs.timed_pattern_id == scope.bundle.timing.id
      assert first.attrs.pattern_derivation_state == "linked"
      assert first.attrs.pattern_derivation_reason == nil
      refute Map.has_key?(first.attrs, :block_id)

      assert Enum.map(first.stop_times, &stop_row/1) == [
               {"A", 1, "06:00:00", "06:00:00", 1, nil, nil, nil},
               {"B", 2, "06:05:00", "06:05:30", 1, nil, nil, nil},
               {"C", 3, "06:12:00", "06:12:00", 1, nil, nil, nil}
             ]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert result.changed_trip_ids == []
      assert result.deleted_trip_ids == [trip.id]
      assert length(result.created_trip_ids) == 6
      assert result.transfers_removed == 1
      assert result.change_set == review.change_set
      assert result.restore == nil

      created =
        result.created_trip_ids
        |> Enum.map(&Repo.get!(Trip, &1))
        |> Map.new(&{&1.trip_id, &1})

      assert Map.keys(created) |> Enum.sort() == [
               "12-0-#{scope.service}-0600",
               "12-0-#{scope.service}-0610",
               "12-0-#{scope.service}-0620",
               "12-0-#{scope.service}-0630",
               "12-0-#{scope.service}-0640",
               "12-0-#{scope.service}-0650"
             ]

      at_0600 = Map.fetch!(created, "12-0-#{scope.service}-0600")
      assert at_0600.service_id == scope.service
      assert at_0600.route_id == "12"
      assert at_0600.direction_id == 0
      assert at_0600.trip_headsign == "Downtown"
      assert at_0600.trip_short_name == nil
      assert at_0600.block_id == nil
      assert at_0600.route_pattern_id == scope.bundle.pattern.route_pattern_id
      assert at_0600.timed_pattern_id == scope.bundle.timing.id
      assert at_0600.pattern_derivation_state == "linked"
      assert at_0600.pattern_derivation_reason == nil
      assert frequency_rows(at_0600) == []

      assert stop_time_clocks(at_0600) == [
               {"06:00:00", "06:00:00", 1, nil},
               {"06:05:00", "06:05:30", 1, nil},
               {"06:12:00", "06:12:00", 1, nil}
             ]

      at_0650 = Map.fetch!(created, "12-0-#{scope.service}-0650")

      assert stop_time_clocks(at_0650) == [
               {"06:50:00", "06:50:00", 1, nil},
               {"06:55:00", "06:55:30", 1, nil},
               {"07:02:00", "07:02:00", 1, nil}
             ]

      departures =
        created
        |> Map.values()
        |> Enum.map(fn trip -> trip |> stop_time_clocks() |> hd() |> elem(1) end)
        |> Enum.sort()

      assert departures == [
               "06:00:00",
               "06:10:00",
               "06:20:00",
               "06:30:00",
               "06:40:00",
               "06:50:00"
             ]

      refute "07:00:00" in departures

      # The source and everything the delete removes are gone (FH-29).
      assert Repo.get(Trip, trip.id) == nil
      assert stop_time_clocks(trip) == []
      assert frequency_rows(trip) == []
      assert Repo.get(Transfer, transfer.id) == nil
      assert transfer_rows(scope) == []
      assert trip_count(scope) == trips_before + 5

      for created_trip <- Map.values(created) do
        assert [log] = trip_logs(created_trip)
        assert log.action == "created"
        assert log.changed_fields["operation_id"] == result.operation_id
      end

      assert [deleted_log] = trip_logs(trip)
      assert deleted_log.action == "deleted"
      assert deleted_log.changed_fields["operation_id"] == result.operation_id
      assert deleted_log.changed_fields["before"]["trip_id"] == trip.trip_id
      assert deleted_log.changed_fields["after"] == nil

      affected = Enum.sort(result.created_trip_ids ++ [trip.id])
      assert deleted_log.changed_fields["affected_trip_ids"] |> Enum.sort() == affected
    end
  end

  describe "converting keeps the source's stored stop-time values" do
    test "each converted linked trip keeps the stored continuous flags and shape distance" do
      scope = editing_scope!("12")
      windows = [%{start_secs: 21_600, end_secs: 22_800, headway_secs: 600, exact_times: 0}]
      trip = frequency_trip!(scope, windows)

      # Imported values the timing does not carry: continuous stopping at B and
      # shape distances at A and B; C has no stored distance.
      stored = %{
        "A" => [continuous_pickup: 1, continuous_drop_off: 1, shape_dist_traveled: 0],
        "B" => [continuous_pickup: 0, continuous_drop_off: 2, shape_dist_traveled: 1500],
        "C" => [continuous_pickup: 1, continuous_drop_off: 1]
      }

      Enum.each(stored, fn {stop_id, values} ->
        from(st in StopTime,
          where:
            st.trip_id == ^trip.trip_id and st.gtfs_version_id == ^scope.version.id and
              st.stop_id == ^stop_id
        )
        |> Repo.update_all(set: values)
      end)

      command = {:convert_frequency, trip.id}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert length(result.created_trip_ids) == 2

      for created_id <- result.created_trip_ids do
        created = Repo.get!(Trip, created_id)

        assert continuous_rows(created) == [
                 {"A", 1, 1, Decimal.new("0")},
                 {"B", 0, 2, Decimal.new("1500")},
                 {"C", 1, 1, nil}
               ]
      end
    end
  end

  describe "converting a custom frequency trip (R8)" do
    test "every converted trip offsets the stored template by its departure difference" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(scope, [%{start_secs: 21_600, end_secs: 22_800, headway_secs: 600}],
          state: "custom",
          reason: "edited_in_schedules",
          trip_headsign: "Downtown",
          stop_times: [
            {"A", "05:58:00", "05:58:00"},
            {"B", "06:03:00", "06:04:00"},
            {"C", "06:10:00", "06:10:00"}
          ]
        )

      command = {:convert_frequency, trip.id}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 0, created: 2, deleted: 1, excluded: 0, skipped: 0}
      assert review.change_set.deletes == [trip.id]
      assert review.change_set.consequences == [{:note, {:transfers_removed, 0}}]

      assert [first, second] = review.change_set.inserts
      assert first.attrs.trip_id == "12-0-#{scope.service}-0600"
      assert second.attrs.trip_id == "12-0-#{scope.service}-0610"

      assert first.attrs.pattern_derivation_state == "custom"
      assert first.attrs.pattern_derivation_reason == "edited_in_schedules"
      assert first.attrs.timed_pattern_id == nil
      assert first.attrs.trip_short_name == nil
      assert first.attrs.trip_headsign == "Downtown"
      refute Map.has_key?(first.attrs, :block_id)

      assert Enum.map(first.stop_times, &stop_row/1) == [
               {"A", 1, "06:00:00", "06:00:00", nil, nil, nil, nil},
               {"B", 2, "06:05:00", "06:06:00", nil, nil, nil, nil},
               {"C", 3, "06:12:00", "06:12:00", nil, nil, nil, nil}
             ]

      assert Enum.map(second.stop_times, &stop_row/1) == [
               {"A", 1, "06:10:00", "06:10:00", nil, nil, nil, nil},
               {"B", 2, "06:15:00", "06:16:00", nil, nil, nil, nil},
               {"C", 3, "06:22:00", "06:22:00", nil, nil, nil, nil}
             ]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert result.restore == nil
      assert result.transfers_removed == 0
      assert result.deleted_trip_ids == [trip.id]

      created =
        result.created_trip_ids
        |> Enum.map(&Repo.get!(Trip, &1))
        |> Map.new(&{&1.trip_id, &1})

      at_0600 = Map.fetch!(created, "12-0-#{scope.service}-0600")
      assert at_0600.pattern_derivation_state == "custom"
      assert at_0600.pattern_derivation_reason == "edited_in_schedules"
      assert at_0600.timed_pattern_id == nil
      assert at_0600.block_id == nil
      assert at_0600.trip_short_name == nil

      assert stop_time_clocks(at_0600) == [
               {"06:00:00", "06:00:00", nil, nil},
               {"06:05:00", "06:06:00", nil, nil},
               {"06:12:00", "06:12:00", nil, nil}
             ]
    end

    test "a linked trip whose stops differ from its pattern keeps its own stops" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(
          scope,
          [%{start_secs: 21_600, end_secs: 22_800, headway_secs: 600}],
          trip_headsign: "Downtown",
          stop_times: [
            {"A", "06:00:00", "06:00:00"},
            {"X", "06:05:00", "06:05:00"},
            {"C", "06:12:00", "06:12:00"}
          ]
        )

      command = {:convert_frequency, trip.id}
      assert trip_row(trip).pattern_derivation_state == "linked"

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert [first, second] = review.change_set.inserts

      # The stored stops are not the pattern's, so the timing is not materialized:
      # the trip becomes custom rather than claiming a linkage it cannot follow.
      assert first.attrs.pattern_derivation_state == "custom"
      assert first.attrs.pattern_derivation_reason == "edited_in_schedules"
      assert first.attrs.timed_pattern_id == nil

      assert Enum.map(first.stop_times, &stop_row/1) == [
               {"A", 1, "06:00:00", "06:00:00", nil, nil, nil, nil},
               {"X", 2, "06:05:00", "06:05:00", nil, nil, nil, nil},
               {"C", 3, "06:12:00", "06:12:00", nil, nil, nil, nil}
             ]

      assert Enum.map(second.stop_times, &stop_row/1) == [
               {"A", 1, "06:10:00", "06:10:00", nil, nil, nil, nil},
               {"X", 2, "06:15:00", "06:15:00", nil, nil, nil, nil},
               {"C", 3, "06:22:00", "06:22:00", nil, nil, nil, nil}
             ]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      created =
        result.created_trip_ids
        |> Enum.map(&Repo.get!(Trip, &1))
        |> Map.new(&{&1.trip_id, &1})

      at_0600 = Map.fetch!(created, "12-0-#{scope.service}-0600")
      assert stop_id_rows(at_0600) == ["A", "X", "C"]
      assert stop_id_rows(trip) == []
    end
  end

  describe "a source whose stored service cannot be listed faithfully" do
    test "an overlapping stored window list is refused and writes nothing" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(scope, [
          %{start_secs: 21_600, end_secs: 25_200, headway_secs: 600},
          %{start_secs: 24_000, end_secs: 28_800, headway_secs: 600}
        ])

      command = {:convert_frequency, trip.id}
      errors = [%{index: 1, reason: :overlap}]

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert review.change_set == %{
               updates: [],
               inserts: [],
               deletes: [],
               consequences: [{:error, {:invalid_windows, errors}}]
             }

      assert review.counts == %{changed: 0, created: 0, deleted: 0, excluded: 0, skipped: 0}

      row = trip_row(trip)
      clocks_before = stop_time_clocks(trip)
      frequencies_before = frequency_rows(trip)

      assert {:error, {:refused, [{:error, {:invalid_windows, ^errors}}]}} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert trip_row(trip) == row
      assert stop_time_clocks(trip) == clocks_before
      assert frequency_rows(trip) == frequencies_before
      assert trip_logs(trip) == []
    end

    test "a stored clock the planner cannot read is :invalid_command" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(scope, [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 600}])

      Repo.update_all(
        from(f in Frequency,
          where:
            f.organization_id == ^scope.organization.id and
              f.gtfs_version_id == ^scope.version.id and f.trip_id == ^trip.trip_id
        ),
        set: [start_time: "0700"]
      )

      assert {:error, :invalid_command} =
               Gtfs.review_trip_change("12", {:convert_frequency, trip.id}, scope.audit)

      assert trip_row(trip) != nil
    end
  end

  describe "only a frequency trip converts" do
    test "a listed trip is :invalid_command" do
      scope = editing_scope!("12")
      trip = linked_trip!(scope, "07:00:00")

      assert {:error, :invalid_command} =
               Gtfs.review_trip_change("12", {:convert_frequency, trip.id}, scope.audit)
    end
  end

  # -- Readbacks -------------------------------------------------------------

  defp stop_row(row) do
    {row.stop_id, row.stop_sequence, row.arrival_time, row.departure_time, row.timepoint,
     row.pickup_type, row.drop_off_type, row.shape_dist_traveled}
  end

  defp continuous_rows(trip) do
    Repo.all(
      from(st in StopTime,
        where:
          st.trip_id == ^trip.trip_id and st.organization_id == ^trip.organization_id and
            st.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: st.stop_sequence, asc: st.id],
        select: {st.stop_id, st.continuous_pickup, st.continuous_drop_off, st.shape_dist_traveled}
      )
    )
  end

  defp stop_id_rows(trip) do
    Repo.all(
      from(st in StopTime,
        where:
          st.trip_id == ^trip.trip_id and st.organization_id == ^trip.organization_id and
            st.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: st.stop_sequence, asc: st.id],
        select: st.stop_id
      )
    )
  end

  defp transfer_rows(scope) do
    Repo.all(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id,
        order_by: [asc: t.id],
        select: %{
          id: t.id,
          from_trip_id: t.from_trip_id,
          to_trip_id: t.to_trip_id,
          from_stop_id: t.from_stop_id,
          to_stop_id: t.to_stop_id,
          transfer_type: t.transfer_type
        }
      )
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
end
