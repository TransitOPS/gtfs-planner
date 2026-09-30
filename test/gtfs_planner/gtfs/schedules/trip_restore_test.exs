defmodule GtfsPlanner.Gtfs.Schedules.TripRestoreTest do
  @moduledoc """
  Merge evidence (EV-11) for the R10 restore path (step 12):

  - Undoing a shift restores literal clocks, linkage fields and frequency rows,
    and bumps `updated_at` on every restored trip (INV-2).
  - Another editor's `update_trip/5` after the shift is refused as
    `{:error, {:not_restorable, :changed, [id]}}` with the rows byte-equal
    (FH-26); a second restore of the same payload is refused the same way.
  - A restore deletes the payload's created trips with their stop times and
    frequency rows and audits one `"deleted"` log per trip.
  - A transfer naming a created trip is refused as
    `{:error, {:not_restorable, :transfer_names_created_trip, [id]}}` with
    nothing written (FH-27, CR-8).
  - The restore's audit logs carry `undoes` equal to the original operation id,
    share one new operation id and record the pre- and post-restore clocks.
  - A payload whose inner rows are inconsistent is `:invalid_command`, a payload
    with a foreign or unknown trip UUID is `:not_found` and a stop-time list that
    does not match the stored rows rolls back `:trip_stop_times_mismatch`, each
    with nothing written.
  - A captured `block_id` is put back and the restore joins the block guarantee.

  Every expected value is literal and hand-derived from R10, INV-2 and the §4.4
  contract in spec.md; no expectation is computed by the code under test. The
  created-trip cases build the payload with the capture shape a copy apply
  produces, because no planner emits inserts before step 16. Every restore runs
  through the real production entry point `Gtfs.restore_trips/3`.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/trip_restore_test.exs` (EV-11, 120 s
  deadline).
  """
  use GtfsPlanner.DataCase

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    %{scope: editing_scope!("12")}
  end

  describe "undo of a shift" do
    test "restores literal clocks, linkage fields and frequency rows", %{scope: scope} do
      custom = custom_trip!(scope, custom_stop_times(25_200))
      frequency = frequency_trip!(scope, [frequency_window(36_000, 39_600, 600)])
      selected = Enum.sort([custom.id, frequency.id])
      command = {:shift, selected, 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, applied} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      # The shift is the undo's premise: the custom trip loses its stored reason
      # and the frequency trip's window moves (R1, R4).
      assert trip_row(custom).pattern_derivation_reason == "edited_in_schedules"
      assert frequency_rows(frequency) |> Enum.map(& &1.start_time) == ["10:05:00"]
      shifted_updated_at = trip_row(custom).updated_at

      assert {:ok, restored} = Gtfs.restore_trips("12", applied.restore, scope.audit)

      assert Enum.sort(restored.restored_trip_ids) == selected
      assert restored.deleted_trip_ids == []
      assert {:ok, _uuid} = Ecto.UUID.cast(restored.operation_id)
      refute restored.operation_id == applied.operation_id

      # INV-2: a restored trip receives a new updated_at; the fields the shift
      # overwrote come back byte-for-byte (R10).
      assert trip_row(custom).pattern_derivation_reason == "stops_mismatch"
      assert trip_row(custom).pattern_derivation_state == "custom"
      assert trip_row(custom).timed_pattern_id == nil
      assert DateTime.compare(trip_row(custom).updated_at, shifted_updated_at) == :gt

      assert stop_time_clocks(custom) == [
               {"07:00:00", "07:00:00", nil, nil},
               {"07:05:00", "07:05:30", nil, nil},
               {"07:12:00", "07:12:00", nil, nil}
             ]

      assert stop_time_clocks(frequency) == [
               {"10:00:00", "10:00:00", nil, nil},
               {"10:05:00", "10:05:30", nil, nil},
               {"10:12:00", "10:12:00", nil, nil}
             ]

      assert frequency_rows(frequency)
             |> Enum.map(&{&1.start_time, &1.end_time, &1.headway_secs, &1.exact_times}) == [
               {"10:00:00", "11:00:00", 600, 1}
             ]
    end

    test "another editor's update after the shift refuses and writes nothing", %{scope: scope} do
      first = linked_trip!(scope, "07:00:00")
      second = linked_trip!(scope, "08:00:00")
      third = linked_trip!(scope, "09:00:00")
      selected = Enum.sort([first.id, second.id, third.id])
      command = {:shift, selected, 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, applied} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      # Another editor retimes one shifted trip after the write, so the restore
      # payload no longer describes it (FH-26).
      assert {:ok, _updated} =
               Gtfs.update_trip(
                 "12",
                 second.id,
                 %{start_time: "08:10:00"},
                 trip_row(second).updated_at,
                 scope.audit
               )

      clocks_before = Map.new([first, second, third], &{&1.id, stop_time_clocks(&1)})
      logs_before = log_count(scope)

      assert {:error, {:not_restorable, :changed, [changed_id]}} =
               Gtfs.restore_trips("12", applied.restore, scope.audit)

      assert changed_id == second.id

      Enum.each([first, second, third], fn trip ->
        assert stop_time_clocks(trip) == clocks_before[trip.id]
      end)

      assert log_count(scope) == logs_before
    end

    test "a second restore of the same payload refuses and changes nothing", %{scope: scope} do
      custom = custom_trip!(scope, custom_stop_times(25_200))
      command = {:shift, [custom.id], 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, applied} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert {:ok, _restored} = Gtfs.restore_trips("12", applied.restore, scope.audit)

      clocks_before = stop_time_clocks(custom)
      logs_before = log_count(scope)

      assert {:error, {:not_restorable, :changed, [changed_id]}} =
               Gtfs.restore_trips("12", applied.restore, scope.audit)

      assert changed_id == custom.id
      assert stop_time_clocks(custom) == clocks_before
      assert log_count(scope) == logs_before
    end
  end

  describe "undo of a copy" do
    test "deletes the created trips with their stop times and frequencies", %{scope: scope} do
      listed = linked_trip!(scope, "07:00:00")
      frequency = frequency_trip!(scope, [frequency_window(28_800, 32_400, 900)])

      payload =
        captured_payload(scope, %{created: Enum.map([listed, frequency], &created_entry/1)})

      applied_operation_id = payload.operation_id

      assert {:ok, restored} = Gtfs.restore_trips("12", payload, scope.audit)

      assert restored.restored_trip_ids == []
      assert Enum.sort(restored.deleted_trip_ids) == Enum.sort([listed.id, frequency.id])
      refute restored.operation_id == applied_operation_id

      refute Repo.get(Trip, listed.id)
      refute Repo.get(Trip, frequency.id)
      assert stop_time_rows(scope, [listed.trip_id, frequency.trip_id]) == []
      assert frequency_rows(frequency) == []

      logs = Enum.flat_map([listed, frequency], &trip_logs/1)
      assert Enum.map(logs, & &1.action) == ["deleted", "deleted"]

      assert Enum.uniq(Enum.map(logs, & &1.changed_fields["operation_id"])) == [
               restored.operation_id
             ]

      assert Enum.all?(logs, &(&1.changed_fields["undoes"] == applied_operation_id))

      assert Enum.all?(
               logs,
               &(Enum.sort(&1.changed_fields["affected_trip_ids"]) ==
                   Enum.sort([listed.id, frequency.id]))
             )
    end

    test "a transfer naming a created trip refuses and writes nothing", %{scope: scope} do
      created = linked_trip!(scope, "07:00:00")
      other = linked_trip!(scope, "08:00:00")
      transfer = in_seat_transfer_fixture(scope.organization.id, scope.version.id, created, other)
      payload = captured_payload(scope, %{created: [created_entry(created)]})
      rows_before = stop_time_rows(scope, [created.trip_id])
      logs_before = log_count(scope)

      assert {:error, {:not_restorable, :transfer_names_created_trip, [created_id]}} =
               Gtfs.restore_trips("12", payload, scope.audit)

      assert created_id == created.id
      assert Repo.get(Trip, created.id)
      assert stop_time_rows(scope, [created.trip_id]) == rows_before
      assert log_count(scope) == logs_before
      assert Repo.get(Transfer, transfer.id)
    end
  end

  describe "undo after the restored calendar or timing changed" do
    test "a deleted original calendar refuses and writes nothing", %{scope: scope} do
      services = weekday_and_saturday!(scope)
      trip = linked_trip!(scope, "07:00:00", %{service_id: services.weekday})
      command = {:move_calendar, [trip.id], services.saturday}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, applied} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      # The weekday calendar is deleted once no trip uses it.
      from(c in Calendar, where: c.gtfs_version_id == ^scope.version.id)
      |> where([c], c.service_id == ^services.weekday)
      |> Repo.delete_all()

      logs_before = log_count(scope)

      assert {:error, :calendar_not_found} =
               Gtfs.restore_trips("12", applied.restore, scope.audit)

      assert trip_row(trip).service_id == services.saturday
      assert log_count(scope) == logs_before
    end

    test "a timing edited after the change refuses the relink and writes nothing",
         %{scope: scope} do
      trip = timing_linked_trip!(scope)
      original = scope.bundle.timing
      slow = extra_timing!(scope.bundle, [{0, 0, 1}, {360, 390, 1}, {840, 840, 1}], "Slow")
      applied = apply_set_timing!(scope, trip, slow)

      # Another editor retimes the original timing; the trip, now on Slow, keeps
      # its updated_at.
      from(s in TimedPatternStop,
        where: s.timed_pattern_id == ^original.id and s.arrival_offset == 720
      )
      |> Repo.update_all(set: [arrival_offset: 780, departure_offset: 780])

      clocks_before = stop_time_clocks(trip)
      logs_before = log_count(scope)

      assert {:error, {:not_restorable, :changed, [changed_id]}} =
               Gtfs.restore_trips("12", applied.restore, scope.audit)

      assert changed_id == trip.id
      assert trip_row(trip).timed_pattern_id == slow.id
      assert stop_time_clocks(trip) == clocks_before
      assert log_count(scope) == logs_before
    end

    test "a timing deleted after the change refuses the relink and writes nothing",
         %{scope: scope} do
      trip = timing_linked_trip!(scope)
      original = scope.bundle.timing
      slow = extra_timing!(scope.bundle, [{0, 0, 1}, {360, 390, 1}, {840, 840, 1}], "Slow")
      applied = apply_set_timing!(scope, trip, slow)

      Repo.delete_all(from(s in TimedPatternStop, where: s.timed_pattern_id == ^original.id))
      Repo.delete_all(from(t in TimedPattern, where: t.id == ^original.id))

      logs_before = log_count(scope)

      assert {:error, {:not_restorable, :changed, [changed_id]}} =
               Gtfs.restore_trips("12", applied.restore, scope.audit)

      assert changed_id == trip.id
      assert trip_row(trip).timed_pattern_id == slow.id
      assert log_count(scope) == logs_before
    end

    test "an unchanged timing is linked back", %{scope: scope} do
      trip = timing_linked_trip!(scope)
      original = scope.bundle.timing
      slow = extra_timing!(scope.bundle, [{0, 0, 1}, {360, 390, 1}, {840, 840, 1}], "Slow")
      applied = apply_set_timing!(scope, trip, slow)

      assert {:ok, restored} = Gtfs.restore_trips("12", applied.restore, scope.audit)

      assert restored.restored_trip_ids == [trip.id]
      assert trip_row(trip).timed_pattern_id == original.id

      assert stop_time_clocks(trip) == [
               {"07:00:00", "07:00:00", 1, nil},
               {"07:05:00", "07:05:30", 1, nil},
               {"07:12:00", "07:12:00", 1, nil}
             ]
    end

    test "a paste-linked trip whose flags differ from its timing is linked back",
         %{scope: scope} do
      # Timetable paste links a trip whose rows carry timepoint 1 / pickup 0 to
      # a timing whose rows leave both blank; only the clocks agree.
      trip = linked_trip!(scope, "07:00:00")
      original = scope.bundle.timing

      from(st in StopTime,
        where: st.trip_id == ^trip.trip_id and st.gtfs_version_id == ^trip.gtfs_version_id
      )
      |> Repo.update_all(set: [timepoint: 1, pickup_type: 0])

      from(s in TimedPatternStop, where: s.timed_pattern_id == ^original.id)
      |> Repo.update_all(set: [timepoint: nil, pickup_type: nil])

      slow = extra_timing!(scope.bundle, [{0, 0, 1}, {360, 390, 1}, {840, 840, 1}], "Slow")
      applied = apply_set_timing!(scope, trip, slow)

      assert {:ok, restored} = Gtfs.restore_trips("12", applied.restore, scope.audit)

      assert restored.restored_trip_ids == [trip.id]
      assert trip_row(trip).timed_pattern_id == original.id

      assert stop_time_clocks(trip) == [
               {"07:00:00", "07:00:00", 1, 0},
               {"07:05:00", "07:05:30", 1, 0},
               {"07:12:00", "07:12:00", 1, 0}
             ]
    end
  end

  describe "the restore logs" do
    test "carry undoes and the pre- and post-restore clocks", %{scope: scope} do
      trip = custom_trip!(scope, custom_stop_times(25_200))
      command = {:shift, [trip.id], 300, nil}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert {:ok, applied} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert {:ok, restored} = Gtfs.restore_trips("12", applied.restore, scope.audit)
      assert [shift_log, restore_log] = trip_logs(trip)

      assert shift_log.action == "updated"
      assert shift_log.changed_fields["operation_id"] == applied.operation_id
      refute Map.has_key?(shift_log.changed_fields, "undoes")

      assert restore_log.action == "updated"
      assert restore_log.changed_fields["operation_id"] == restored.operation_id
      assert restore_log.changed_fields["undoes"] == applied.operation_id
      assert restore_log.changed_fields["affected_trip_ids"] == [trip.id]

      assert restore_log.changed_fields["before"]["stop_times"] == [
               %{"stop_id" => "A", "arrival_time" => "07:05:00", "departure_time" => "07:05:00"},
               %{"stop_id" => "B", "arrival_time" => "07:10:00", "departure_time" => "07:10:30"},
               %{"stop_id" => "C", "arrival_time" => "07:17:00", "departure_time" => "07:17:00"}
             ]

      assert restore_log.changed_fields["after"]["stop_times"] == [
               %{"stop_id" => "A", "arrival_time" => "07:00:00", "departure_time" => "07:00:00"},
               %{"stop_id" => "B", "arrival_time" => "07:05:00", "departure_time" => "07:05:30"},
               %{"stop_id" => "C", "arrival_time" => "07:12:00", "departure_time" => "07:12:00"}
             ]
    end
  end

  describe "payload integrity" do
    test "an inconsistent updated trip is invalid and writes nothing", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")
      entry = Map.delete(captured_trip(trip, %{}), :fields)
      payload = captured_payload(scope, %{trips: [entry]})
      rows_before = stop_time_rows(scope, [trip.trip_id])

      assert {:error, :invalid_command} = Gtfs.restore_trips("12", payload, scope.audit)
      assert stop_time_rows(scope, [trip.trip_id]) == rows_before
      assert trip_logs(trip) == []
    end

    test "a created entry without its natural trip id is invalid", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")
      entry = %{id: trip.id, written_updated_at: trip.updated_at}
      payload = captured_payload(scope, %{created: [entry]})
      rows_before = stop_time_rows(scope, [trip.trip_id])

      assert {:error, :invalid_command} = Gtfs.restore_trips("12", payload, scope.audit)
      assert stop_time_rows(scope, [trip.trip_id]) == rows_before
    end

    test "a foreign or unknown trip UUID is not found", %{scope: scope} do
      foreign = editing_scope!("91")
      foreign_trip = linked_trip!(foreign, "07:00:00")
      foreign_payload = captured_payload(foreign, %{trips: [captured_trip(foreign_trip, %{})]})

      assert {:error, :not_found} = Gtfs.restore_trips("12", foreign_payload, scope.audit)

      trip = linked_trip!(scope, "08:00:00")

      unknown_payload =
        captured_payload(scope, %{
          trips: [%{captured_trip(trip, %{}) | id: Ecto.UUID.generate()}]
        })

      assert {:error, :not_found} = Gtfs.restore_trips("12", unknown_payload, scope.audit)
    end

    test "a stop-time list that does not match the stored rows rolls back", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")

      entry =
        captured_trip(trip, %{stop_times: Enum.take(captured_stop_times(trip), 1)})

      payload = captured_payload(scope, %{trips: [entry]})
      rows_before = stop_time_rows(scope, [trip.trip_id])
      logs_before = log_count(scope)

      assert {:error, :trip_stop_times_mismatch} = Gtfs.restore_trips("12", payload, scope.audit)
      assert stop_time_rows(scope, [trip.trip_id]) == rows_before
      assert log_count(scope) == logs_before
    end

    test "a captured block id is put back and joins the block guarantee", %{scope: scope} do
      trip = custom_trip!(scope, custom_stop_times(25_200))

      entry =
        captured_trip(trip, %{
          fields: %{
            service_id: scope.service,
            timed_pattern_id: nil,
            pattern_derivation_state: "custom",
            pattern_derivation_reason: "stops_mismatch",
            block_id: "B-193"
          }
        })

      payload = captured_payload(scope, %{trips: [entry]})

      assert {:ok, restored} = Gtfs.restore_trips("12", payload, scope.audit)
      assert restored.restored_trip_ids == [trip.id]
      assert trip_row(trip).block_id == "B-193"

      assert stop_time_clocks(trip) == [
               {"07:00:00", "07:00:00", nil, nil},
               {"07:05:00", "07:05:30", nil, nil},
               {"07:12:00", "07:12:00", nil, nil}
             ]
    end
  end

  # The fixture leaves stop-time timepoints empty; a trip linked by the engine
  # stores its timing's rows exactly, so the relink check can match them.
  defp timing_linked_trip!(scope) do
    trip = linked_trip!(scope, "07:00:00")

    from(st in StopTime,
      where: st.trip_id == ^trip.trip_id and st.gtfs_version_id == ^trip.gtfs_version_id
    )
    |> Repo.update_all(set: [timepoint: 1])

    trip
  end

  defp apply_set_timing!(scope, trip, timing) do
    command = {:set_timing, [trip.id], timing.id}
    {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

    {:ok, applied} =
      Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

    applied
  end

  # -- Payloads --------------------------------------------------------------

  # The capture shape §4.4 fixes: an updated trip carries its pre-write fields,
  # rows and the written `updated_at`; a created trip carries its id, natural
  # trip id and `updated_at`. The created cases use this shape because no planner
  # emits inserts before step 16.
  defp captured_payload(scope, attrs) do
    %{
      operation_id: Map.get(attrs, :operation_id, Ecto.UUID.generate()),
      organization_id: scope.organization.id,
      gtfs_version_id: scope.version.id,
      route_id: scope.route.route_id,
      trips: Map.get(attrs, :trips, []),
      created: Map.get(attrs, :created, [])
    }
  end

  defp captured_trip(trip, attrs) do
    %{
      id: trip.id,
      written_updated_at: Map.get(attrs, :written_updated_at, trip.updated_at),
      fields: Map.get(attrs, :fields, captured_fields(trip)),
      stop_times: Map.get(attrs, :stop_times, captured_stop_times(trip)),
      frequencies: Map.get(attrs, :frequencies, captured_frequencies(trip))
    }
  end

  # What `apply_trip_change/4` appends for each inserted trip: the row UUID, the
  # natural trip id and the `updated_at` the insert produced.
  defp created_entry(trip) do
    %{id: trip.id, trip_id: trip.trip_id, written_updated_at: trip.updated_at}
  end

  defp captured_fields(trip) do
    Map.take(trip, [
      :service_id,
      :timed_pattern_id,
      :pattern_derivation_state,
      :pattern_derivation_reason,
      :block_id
    ])
  end

  defp captured_stop_times(trip) do
    Repo.all(
      from(st in StopTime,
        where:
          st.trip_id == ^trip.trip_id and st.organization_id == ^trip.organization_id and
            st.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: st.stop_sequence, asc: st.id],
        select: %{
          arrival_time: st.arrival_time,
          departure_time: st.departure_time,
          timepoint: st.timepoint,
          pickup_type: st.pickup_type,
          drop_off_type: st.drop_off_type,
          stop_headsign: st.stop_headsign
        }
      )
    )
  end

  defp captured_frequencies(trip) do
    Repo.all(
      from(f in Frequency,
        where:
          f.trip_id == ^trip.trip_id and f.organization_id == ^trip.organization_id and
            f.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: f.start_time, asc: f.id],
        select: %{
          start_time: f.start_time,
          end_time: f.end_time,
          headway_secs: f.headway_secs,
          exact_times: f.exact_times
        }
      )
    )
  end

  # -- Fixtures and readbacks ------------------------------------------------

  defp custom_stop_times(start_secs) do
    [
      {"A", start_secs, start_secs},
      {"B", start_secs + 300, start_secs + 330},
      {"C", start_secs + 720, start_secs + 720}
    ]
    |> Enum.map(fn {stop_id, arrival, departure} ->
      {stop_id, GtfsTime.format(arrival), GtfsTime.format(departure)}
    end)
  end

  defp frequency_window(start_secs, end_secs, headway_secs) do
    %{start_secs: start_secs, end_secs: end_secs, headway_secs: headway_secs, exact_times: 1}
  end

  defp stop_time_rows(scope, trip_ids) do
    Repo.all(
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization.id and
            st.gtfs_version_id == ^scope.version.id and st.trip_id in ^trip_ids,
        order_by: [asc: st.trip_id, asc: st.stop_sequence, asc: st.id]
      )
    )
  end

  defp log_count(scope) do
    Repo.aggregate(
      from(l in GtfsPlanner.Gtfs.ChangeLog,
        where:
          l.organization_id == ^scope.organization.id and
            l.gtfs_version_id == ^scope.version.id
      ),
      :count
    )
  end
end
