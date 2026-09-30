defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.FrequencyTest do
  @moduledoc """
  Merge evidence (EV-16) for R8/R9 frequency service through the engine (step 17):

  - Adding frequency service creates one linked trip whose template is the timing
    materialized at the first window's start, with every stored row carrying the
    command's `exact_times`; the insert has no block and the apply captures it for
    Undo (AC-17, FH-7's valid counterpart).
  - An overlapping window list is `{:error, {:invalid_windows, _}}`: the review plans
    no trip and the apply is refused with nothing written (FH-7).
  - Adding frequency service to a pattern whose listed trips run on a shared date is
    `{:error, {:mixed_service, _}}` and writes nothing (FH-10, AC-20).
  - An update with `exact_times: :keep` leaves a blank stored `exact_times` blank, and
    one that adds a window keeps the stored rows' values by index while the new row
    takes the first stored value (FH-9, AC-18).
  - An update moves the template by the first-window start change as a whole R1 move,
    so a linked trip stays linked and the Undo capture holds the old template (R8).
  - A template that would move below 00:00 refuses the command and writes nothing.

  Every expected value is literal and hand-derived from R8, R9 and the §4.4
  contracts in spec.md; nothing computes an expectation with the planner under test.
  Every apply runs through the real production entry point
  `Gtfs.apply_trip_change/4` with its §4.4 fence (`:none` for adding, `{:expected, _}`
  for a window edit), on the real local PostgreSQL test database with sandboxed
  fixtures.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/trip_changes/frequency_test.exs`
  (EV-16, 120 s deadline); it is deferred to branch review.
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  describe "adding frequency service (R8, AC-17)" do
    test "stores exact_times 1 on every row and materializes the timing at 10:00" do
      scope = editing_scope!("12", %{timing_headsign: "Downtown"})

      command =
        {:add_frequency,
         %{
           pattern_id: scope.bundle.pattern.id,
           timed_pattern_id: scope.bundle.timing.id,
           service_id: scope.service,
           windows: [
             %{start_secs: 36_000, end_secs: 39_600, headway_secs: 600},
             %{start_secs: 39_600, end_secs: 43_200, headway_secs: 900}
           ],
           exact_times: 1
         }}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 0, created: 1, deleted: 0, excluded: 0, skipped: 0}
      assert review.change_set.updates == []
      assert review.change_set.deletes == []
      assert review.change_set.consequences == []
      assert review.preview == %{}

      assert [insert] = review.change_set.inserts
      assert insert.source_id == nil
      assert insert.attrs.trip_id == "12-0-#{scope.service}-1000"
      assert insert.attrs.route_id == "12"
      assert insert.attrs.service_id == scope.service
      assert insert.attrs.direction_id == 0
      assert insert.attrs.trip_headsign == "Downtown"
      assert insert.attrs.shape_id == nil
      assert insert.attrs.route_pattern_id == scope.bundle.pattern.route_pattern_id
      assert insert.attrs.timed_pattern_id == scope.bundle.timing.id
      assert insert.attrs.pattern_derivation_state == "linked"
      assert insert.attrs.pattern_derivation_reason == nil
      refute Map.has_key?(insert.attrs, :block_id)

      assert insert.frequencies == [
               %{
                 start_time: "10:00:00",
                 end_time: "11:00:00",
                 headway_secs: 600,
                 exact_times: 1
               },
               %{
                 start_time: "11:00:00",
                 end_time: "12:00:00",
                 headway_secs: 900,
                 exact_times: 1
               }
             ]

      assert Enum.map(insert.stop_times, &stop_row/1) == [
               {"A", 1, "10:00:00", "10:00:00", 1, nil, nil, nil},
               {"B", 2, "10:05:00", "10:05:30", 1, nil, nil, nil},
               {"C", 3, "10:12:00", "10:12:00", 1, nil, nil, nil}
             ]

      assert {:ok, result} = Gtfs.apply_trip_change("12", command, :none, scope.audit)

      assert result.changed_trip_ids == []
      assert result.transfers_removed == 0
      assert result.change_set == review.change_set
      assert [created_id] = result.created_trip_ids

      created = Repo.get!(Trip, created_id)
      assert created.trip_id == "12-0-#{scope.service}-1000"
      assert created.service_id == scope.service
      assert created.direction_id == 0
      assert created.trip_headsign == "Downtown"
      assert created.block_id == nil
      assert created.route_pattern_id == scope.bundle.pattern.route_pattern_id
      assert created.timed_pattern_id == scope.bundle.timing.id
      assert created.pattern_derivation_state == "linked"
      assert created.pattern_derivation_reason == nil

      assert stop_time_clocks(created) == [
               {"10:00:00", "10:00:00", 1, nil},
               {"10:05:00", "10:05:30", 1, nil},
               {"10:12:00", "10:12:00", 1, nil}
             ]

      assert Enum.map(frequency_rows(created), &frequency_row/1) == [
               {"10:00:00", "11:00:00", 600, 1},
               {"11:00:00", "12:00:00", 900, 1}
             ]

      # The restore capture an undo re-submits lists the created trip so a later
      # Undo deletes it (R10).
      assert %{operation_id: operation_id, trips: [], created: [created_entry]} = result.restore
      assert operation_id == result.operation_id
      assert created_entry.id == created_id
      assert created_entry.trip_id == "12-0-#{scope.service}-1000"
      assert created_entry.written_updated_at == created.updated_at

      assert [log] = trip_logs(created)
      assert log.action == "created"
      assert log.changed_fields["operation_id"] == result.operation_id
      assert log.changed_fields["affected_trip_ids"] == [created.id]
      assert log.changed_fields["before"] == nil
      assert log.changed_fields["after"]["trip_id"] == "12-0-#{scope.service}-1000"
      assert log.changed_fields["after"]["service_id"] == scope.service
      assert log.changed_fields["after"]["block_id"] == nil
    end

    test "an overlapping window list is refused and writes nothing (FH-7)" do
      scope = editing_scope!("12")

      command =
        {:add_frequency,
         %{
           pattern_id: scope.bundle.pattern.id,
           timed_pattern_id: scope.bundle.timing.id,
           service_id: scope.service,
           windows: [
             %{start_secs: 36_000, end_secs: 39_600, headway_secs: 600},
             %{start_secs: 37_800, end_secs: 43_200, headway_secs: 600}
           ],
           exact_times: 1
         }}

      errors = [%{index: 1, reason: :overlap}]

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.change_set.inserts == []
      assert review.change_set.updates == []
      assert review.change_set.consequences == [{:error, {:invalid_windows, errors}}]
      assert review.counts == %{changed: 0, created: 0, deleted: 0, excluded: 0, skipped: 0}

      assert {:error, {:refused, [{:error, {:invalid_windows, ^errors}}]}} =
               Gtfs.apply_trip_change("12", command, :none, scope.audit)

      assert trip_count(scope) == 0
    end

    test "a listed pattern on a shared date is refused with {:mixed_service, _} (FH-10)" do
      scope = editing_scope!("12")
      %{school: school} = shared_dates_calendars!(scope)
      listed = linked_trip!(scope, "07:00:00")
      listed_before = trip_row(listed)

      command =
        {:add_frequency,
         %{
           pattern_id: scope.bundle.pattern.id,
           timed_pattern_id: scope.bundle.timing.id,
           service_id: school,
           windows: [%{start_secs: 36_000, end_secs: 39_600, headway_secs: 600}],
           exact_times: 1
         }}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert [{:error, {:mixed_service, details}}] = review.change_set.consequences
      assert details.service_ids == Enum.sort([school, scope.service])
      # Every Mon–Fri of the fixture year: 2026-01-01 through 2026-12-31.
      assert details.date_count == 261

      # The refused review still carries the planned insert; the engine refuses
      # before any write.
      assert review.counts == %{changed: 0, created: 1, deleted: 0, excluded: 0, skipped: 0}

      assert {:error, {:refused, [{:error, {:mixed_service, refused}}]}} =
               Gtfs.apply_trip_change("12", command, :none, scope.audit)

      assert refused == details
      assert trip_row(listed) == listed_before
      assert trip_logs(listed) == []
      assert trip_count(scope) == 1
    end
  end

  describe "editing frequency windows (R8, AC-18)" do
    test "an update with :keep leaves a blank exact_times blank (FH-9)" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(scope, [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 600}],
          exact_times: nil
        )

      command =
        {:update_frequency, trip.id,
         %{
           windows: [%{start_secs: 21_600, end_secs: 28_800, headway_secs: 1_200}],
           exact_times: :keep
         }}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 1, created: 0, deleted: 0, excluded: 0, skipped: 0}

      assert [reviewed] = review.change_set.updates
      assert reviewed.stop_times == :unchanged

      assert reviewed.frequencies == [
               %{
                 start_time: "06:00:00",
                 end_time: "08:00:00",
                 headway_secs: 1_200,
                 exact_times: nil
               }
             ]

      row = trip_row(trip)

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => row.updated_at}},
                 scope.audit
               )

      assert result.changed_trip_ids == [trip.id]
      assert result.created_trip_ids == []

      assert Enum.map(frequency_rows(trip), &frequency_row/1) ==
               [{"06:00:00", "08:00:00", 1_200, nil}]

      # The first window still starts at 06:00, so the template did not move.
      assert stop_time_clocks(trip) == [
               {"06:00:00", "06:00:00", nil, nil},
               {"06:05:00", "06:05:30", nil, nil},
               {"06:12:00", "06:12:00", nil, nil}
             ]

      assert [%{frequencies: [restored], stop_times: restored_rows}] = result.restore.trips

      assert restored == %{
               start_time: "06:00:00",
               end_time: "07:00:00",
               headway_secs: 600,
               exact_times: nil
             }

      assert Enum.map(restored_rows, &{&1.arrival_time, &1.departure_time}) == [
               {"06:00:00", "06:00:00"},
               {"06:05:00", "06:05:30"},
               {"06:12:00", "06:12:00"}
             ]

      assert [log] = trip_logs(trip)
      assert log.action == "updated"
      assert log.changed_fields["operation_id"] == result.operation_id
    end

    test "an update with :keep pairs unpadded stored clocks in time order" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(
          scope,
          [
            %{start_secs: 32_400, end_secs: 36_000, headway_secs: 600, exact_times: 1},
            %{start_secs: 36_000, end_secs: 39_600, headway_secs: 900, exact_times: nil}
          ],
          exact_times: nil
        )

      # Imported feeds may store "9:00:00", which sorts after "10:00:00" as text.
      from(f in Frequency, where: f.trip_id == ^trip.trip_id and f.start_time == "09:00:00")
      |> Repo.update_all(set: [start_time: "9:00:00"])

      command =
        {:update_frequency, trip.id,
         %{
           windows: [
             %{start_secs: 32_400, end_secs: 36_000, headway_secs: 600},
             %{start_secs: 36_000, end_secs: 39_600, headway_secs: 900}
           ],
           exact_times: :keep
         }}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert [update] = review.change_set.updates
      assert update.stop_times == :unchanged
      assert Enum.map(update.frequencies, & &1.exact_times) == [1, nil]
    end

    test "an update with :keep matches stored rows by index and fills a new row from the first (AC-18)" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(
          scope,
          [
            %{start_secs: 21_600, end_secs: 25_200, headway_secs: 600, exact_times: 1},
            %{start_secs: 25_200, end_secs: 28_800, headway_secs: 900, exact_times: nil}
          ],
          exact_times: nil
        )

      command =
        {:update_frequency, trip.id,
         %{
           windows: [
             %{start_secs: 21_600, end_secs: 25_200, headway_secs: 600},
             %{start_secs: 25_200, end_secs: 28_800, headway_secs: 900},
             %{start_secs: 28_800, end_secs: 32_400, headway_secs: 1_200}
           ],
           exact_times: :keep
         }}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert [update] = review.change_set.updates
      assert update.stop_times == :unchanged

      assert update.frequencies == [
               %{
                 start_time: "06:00:00",
                 end_time: "07:00:00",
                 headway_secs: 600,
                 exact_times: 1
               },
               %{
                 start_time: "07:00:00",
                 end_time: "08:00:00",
                 headway_secs: 900,
                 exact_times: nil
               },
               %{
                 start_time: "08:00:00",
                 end_time: "09:00:00",
                 headway_secs: 1_200,
                 exact_times: 1
               }
             ]

      row = trip_row(trip)

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => row.updated_at}},
                 scope.audit
               )

      assert result.changed_trip_ids == [trip.id]

      assert Enum.map(frequency_rows(trip), &frequency_row/1) == [
               {"06:00:00", "07:00:00", 600, 1},
               {"07:00:00", "08:00:00", 900, nil},
               {"08:00:00", "09:00:00", 1_200, 1}
             ]
    end

    test "an update moves the template by the first-window start change and stays linked (R8)" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(scope, [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 600}],
          exact_times: 1
        )

      command =
        {:update_frequency, trip.id,
         %{
           windows: [%{start_secs: 27_000, end_secs: 30_600, headway_secs: 600}],
           exact_times: 1
         }}

      row = trip_row(trip)

      assert {:ok, result} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => row.updated_at}},
                 scope.audit
               )

      assert [updated] = result.change_set.updates
      assert updated.fields == %{}

      assert updated.frequencies == [
               %{
                 start_time: "07:30:00",
                 end_time: "08:30:00",
                 headway_secs: 600,
                 exact_times: 1
               }
             ]

      assert Enum.map(updated.stop_times, &update_row/1) == [
               {1, "07:30:00", "07:30:00", nil, nil, nil, nil},
               {2, "07:35:00", "07:35:30", nil, nil, nil, nil},
               {3, "07:42:00", "07:42:00", nil, nil, nil, nil}
             ]

      assert stop_time_clocks(trip) == [
               {"07:30:00", "07:30:00", nil, nil},
               {"07:35:00", "07:35:30", nil, nil},
               {"07:42:00", "07:42:00", nil, nil}
             ]

      assert Enum.map(frequency_rows(trip), &frequency_row/1) ==
               [{"07:30:00", "08:30:00", 600, 1}]

      changed = trip_row(trip)
      assert changed.pattern_derivation_state == "linked"
      assert changed.timed_pattern_id == scope.bundle.timing.id
      assert DateTime.compare(changed.updated_at, row.updated_at) == :gt

      # The Undo capture holds the template and the windows this write replaced.
      assert [%{frequencies: [restored], stop_times: restored_rows}] = result.restore.trips

      assert restored == %{
               start_time: "06:00:00",
               end_time: "07:00:00",
               headway_secs: 600,
               exact_times: 1
             }

      assert Enum.map(restored_rows, &{&1.arrival_time, &1.departure_time}) == [
               {"06:00:00", "06:00:00"},
               {"06:05:00", "06:05:30"},
               {"06:12:00", "06:12:00"}
             ]
    end

    test "a template that would move below 00:00 is refused and writes nothing" do
      scope = editing_scope!("12")

      trip =
        frequency_trip!(scope, [%{start_secs: 10_800, end_secs: 14_400, headway_secs: 600}],
          state: "custom",
          reason: "edited_in_schedules",
          exact_times: 1,
          stop_times: [
            {"A", "02:58:00", "03:00:00"},
            {"B", "03:05:00", "03:05:30"},
            {"C", "03:12:00", "03:12:00"}
          ]
        )

      command =
        {:update_frequency, trip.id,
         %{windows: [%{start_secs: 0, end_secs: 3_600, headway_secs: 600}], exact_times: :keep}}

      row = trip_row(trip)
      frequencies_before = frequency_rows(trip)
      clocks_before = stop_time_clocks(trip)

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.change_set.updates == []
      assert review.change_set.consequences == [{:error, :negative_time}]
      assert review.counts == %{changed: 0, created: 0, deleted: 0, excluded: 0, skipped: 0}

      assert {:error, {:refused, [{:error, :negative_time}]}} =
               Gtfs.apply_trip_change(
                 "12",
                 command,
                 {:expected, %{trip.id => row.updated_at}},
                 scope.audit
               )

      assert frequency_rows(trip) == frequencies_before
      assert stop_time_clocks(trip) == clocks_before
      assert trip_logs(trip) == []
    end
  end

  # -- Readbacks -------------------------------------------------------------

  defp stop_row(row) do
    {row.stop_id, row.stop_sequence, row.arrival_time, row.departure_time, row.timepoint,
     row.pickup_type, row.drop_off_type, row.shape_dist_traveled}
  end

  defp update_row(row) do
    {row.position, row.arrival_time, row.departure_time, row.timepoint, row.pickup_type,
     row.drop_off_type, row.stop_headsign}
  end

  defp frequency_row(row), do: {row.start_time, row.end_time, row.headway_secs, row.exact_times}

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
