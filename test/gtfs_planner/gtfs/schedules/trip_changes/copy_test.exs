defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.CopyTest do
  @moduledoc """
  Merge evidence (EV-15) for the R7 copies through the engine (step 16):

  - Copying a blocked trip to Saturday creates a new unblocked trip that carries the
    source's clocks, rider-facing metadata, stop flags and shape distances, while the
    source and its in-seat transfer stay byte-unchanged (FH-23, AC-14).
  - A target trip already leaving at the copy's first departure is skipped and
    counted; with skip off the same copy is created (FH-24).
  - A same-service duplicate at +30 minutes stores no trip number; a copy to another
    service keeps it (FH-25).
  - A frequency source copies its template and windows moved by the offset.
  - A copy that would mix listed and frequency service on a pattern-date for the
    first time is refused with `{:mixed_service, _}` and writes nothing (FH-10, R9,
    AC-20).
  - A source and target service that share dates is stated as a `{:shared_dates, _}`
    warning and the copy still proceeds (AC-14).

  Every expected value is literal and hand-derived from R7, R9 and the §4.4
  contracts in spec.md; nothing computes an expectation with the planner under test.
  Every apply runs through the real production entry point
  `Gtfs.apply_trip_change/4` with its reviewed-fingerprint fence, on the real local
  PostgreSQL test database with sandboxed fixtures.

  The prepared focused command is
  `mix test test/gtfs_planner/gtfs/schedules/trip_changes/copy_test.exs`
  (EV-15, 120 s deadline); it is deferred to branch review.
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  describe "a copy starts unblocked with no transfers (FH-23, R7)" do
    test "copying a blocked weekday trip to Saturday keeps the source's detail without its block" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      [a, b] = blocked_pair!(scope, "103", ["07:00:00", "08:00:00"])
      stamp_trip_metadata!(a)
      stamp_stop_time_detail!(a)
      _transfer = in_seat_transfer_fixture(scope.organization.id, scope.version.id, a, b)
      a_before = trip_row(a)
      transfers_before = transfer_rows(scope)

      command = {:copy, [a.id], saturday, 0, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 0, created: 1, deleted: 0, excluded: 0, skipped: 0}
      assert review.change_set.updates == []
      assert review.change_set.deletes == []
      assert review.change_set.consequences == []
      assert review.preview == %{}

      assert [insert] = review.change_set.inserts
      assert insert.source_id == a.id
      assert insert.attrs.trip_id == "12-0-#{saturday}-0700"
      assert insert.attrs.service_id == saturday
      refute Map.has_key?(insert.attrs, :block_id)
      assert insert.attrs.trip_headsign == "Downtown"
      assert insert.attrs.wheelchair_accessible == 2
      assert insert.attrs.bikes_allowed == 1
      assert insert.attrs.shape_id == "shp_9"
      assert insert.attrs.route_pattern_id == scope.bundle.pattern.route_pattern_id
      assert insert.attrs.timed_pattern_id == scope.bundle.timing.id
      assert insert.attrs.pattern_derivation_state == "linked"
      assert insert.frequencies == []
      assert insert.stop_times == stop_time_rows(a)

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert result.changed_trip_ids == []
      assert result.transfers_removed == 0
      assert result.change_set == review.change_set
      assert [created_id] = result.created_trip_ids

      created = Repo.get!(Trip, created_id)
      assert created.trip_id == "12-0-#{saturday}-0700"
      assert created.service_id == saturday
      assert created.block_id == nil
      assert created.trip_headsign == "Downtown"
      assert created.wheelchair_accessible == 2
      assert created.bikes_allowed == 1
      assert created.shape_id == "shp_9"
      assert created.pattern_derivation_state == "linked"
      assert created.timed_pattern_id == scope.bundle.timing.id
      assert stop_time_rows(created) == stop_time_rows(a)

      assert trip_row(a) == a_before
      assert trip_logs(a) == []
      assert transfer_rows(scope) == transfers_before

      # The restore capture an undo re-submits lists the created trip so a later
      # Undo deletes it (R10).
      assert %{operation_id: operation_id, trips: [], created: [created_entry]} = result.restore
      assert operation_id == result.operation_id
      assert created_entry.id == created_id
      assert created_entry.trip_id == "12-0-#{saturday}-0700"
      assert created_entry.written_updated_at == created.updated_at

      assert [log] = trip_logs(created)
      assert log.action == "created"
      assert log.changed_fields["operation_id"] == result.operation_id
      assert log.changed_fields["affected_trip_ids"] == [created.id]
      assert log.changed_fields["before"] == nil
      assert log.changed_fields["after"]["block_id"] == nil
      assert log.changed_fields["after"]["trip_id"] == "12-0-#{saturday}-0700"
    end
  end

  describe "skip trips that already leave at the same time (FH-24, R7)" do
    test "a target trip at 17:00 skips the copy and counts it" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      source = linked_trip!(scope, "17:00:00")
      target = linked_trip!(scope, "17:00:00", %{service_id: saturday})
      source_before = trip_row(source)
      target_before = trip_row(target)

      command = {:copy, [source.id], saturday, 0, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 0, created: 0, deleted: 0, excluded: 0, skipped: 1}
      assert review.change_set.inserts == []

      assert review.change_set.consequences == [
               {:note, {:skipped_existing, source.id, "17:00:00"}}
             ]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert result.created_trip_ids == []
      assert trip_row(source) == source_before
      assert trip_row(target) == target_before
      assert trip_logs(source) == []
      assert trip_logs(target) == []
    end

    test "with skip off the second 17:00 trip is created" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      source = linked_trip!(scope, "17:00:00")
      _target = linked_trip!(scope, "17:00:00", %{service_id: saturday})

      command = {:copy, [source.id], saturday, 0, false}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 0, created: 1, deleted: 0, excluded: 0, skipped: 0}
      assert review.change_set.consequences == []
      assert [insert] = review.change_set.inserts
      assert insert.attrs.trip_id == "12-0-#{saturday}-1700"

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert [created_id] = result.created_trip_ids
      assert Repo.get!(Trip, created_id).trip_id == "12-0-#{saturday}-1700"
      assert Repo.get!(Trip, created_id).service_id == saturday
    end
  end

  describe "the trip number only repeats on another service day (FH-25, R7)" do
    test "a same-service duplicate at +30 minutes stores no trip number" do
      scope = editing_scope!("12")
      source = linked_trip!(scope, "09:00:00", %{trip_short_name: "9"})

      command = {:copy, [source.id], scope.service, 1800, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert [insert] = review.change_set.inserts
      assert insert.attrs.service_id == scope.service
      assert insert.attrs.trip_id == "12-0-#{scope.service}-0930"
      assert insert.attrs.trip_short_name == nil

      assert Enum.map(insert.stop_times, & &1.departure_time) ==
               ["09:30:00", "09:35:30", "09:42:00"]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert [created_id] = result.created_trip_ids
      created = Repo.get!(Trip, created_id)
      assert created.service_id == scope.service
      assert created.trip_short_name == nil
      assert created.block_id == nil
      assert trip_count(scope) == 2
    end

    test "a copy to another service keeps the trip number" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      source = linked_trip!(scope, "09:00:00", %{trip_short_name: "9"})

      command = {:copy, [source.id], saturday, 0, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert [insert] = review.change_set.inserts
      assert insert.attrs.service_id == saturday
      assert insert.attrs.trip_short_name == "9"

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert [created_id] = result.created_trip_ids
      created = Repo.get!(Trip, created_id)
      assert created.service_id == saturday
      assert created.trip_short_name == "9"
    end
  end

  describe "a frequency source copies its template and windows (R7)" do
    test "windows and the template move by the offset" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)

      source =
        frequency_trip!(scope, [%{start_secs: 28_800, end_secs: 32_400, headway_secs: 600}])

      command = {:copy, [source.id], saturday, 1800, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 0, created: 1, deleted: 0, excluded: 0, skipped: 0}
      assert [insert] = review.change_set.inserts
      assert insert.attrs.trip_id == "12-0-#{saturday}-0830"
      assert insert.attrs.service_id == saturday
      refute Map.has_key?(insert.attrs, :block_id)
      assert insert.attrs.pattern_derivation_state == "linked"
      assert insert.attrs.timed_pattern_id == scope.bundle.timing.id

      assert insert.frequencies == [
               %{start_time: "08:30:00", end_time: "09:30:00", headway_secs: 600, exact_times: 0}
             ]

      assert Enum.map(insert.stop_times, &{&1.stop_id, &1.arrival_time, &1.departure_time}) ==
               [
                 {"A", "08:30:00", "08:30:00"},
                 {"B", "08:35:00", "08:35:30"},
                 {"C", "08:42:00", "08:42:00"}
               ]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert [created_id] = result.created_trip_ids
      created = Repo.get!(Trip, created_id)
      assert created.block_id == nil

      assert Enum.map(
               frequency_rows(created),
               &{&1.start_time, &1.end_time, &1.headway_secs, &1.exact_times}
             ) ==
               [{"08:30:00", "09:30:00", 600, 0}]

      assert Enum.map(stop_time_rows(created), &{&1.stop_id, &1.arrival_time, &1.departure_time}) ==
               [
                 {"A", "08:30:00", "08:30:00"},
                 {"B", "08:35:00", "08:35:30"},
                 {"C", "08:42:00", "08:42:00"}
               ]
    end
  end

  describe "R9 mixing (AC-20, FH-10)" do
    test "copying a listed trip onto a service day carrying frequency service is refused" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      %{daily: daily} = shared_dates_calendars!(scope)

      listed = linked_trip!(scope, "07:00:00")
      listed_before = trip_row(listed)

      frequency_trip!(scope, [%{start_secs: 28_800, end_secs: 32_400, headway_secs: 600}],
        service_id: saturday
      )

      command = {:copy, [listed.id], daily, 0, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

      assert [
               {:error, {:mixed_service, details}},
               {:warning, {:shared_dates, shared_service, 261}}
             ] = review.change_set.consequences

      assert MapSet.new(details.service_ids) == MapSet.new([daily, saturday])
      # Every Saturday of the fixture year: 2026-01-03 through 2026-12-26.
      assert details.date_count == 52
      assert shared_service == scope.service
      # The refused review still carries the planned insert (the R9 error is added
      # after planning); the engine refuses before any write.
      assert review.counts == %{changed: 0, created: 1, deleted: 0, excluded: 0, skipped: 0}

      assert {:error, {:refused, [{:error, {:mixed_service, refused}}]}} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert refused == details
      assert trip_row(listed) == listed_before
      assert trip_logs(listed) == []
      assert trip_count(scope) == 2
    end
  end

  describe "shared dates are stated (AC-14)" do
    test "a copy to a service that shares dates proceeds and states the shared count" do
      scope = editing_scope!("12")
      %{daily: daily} = shared_dates_calendars!(scope)
      source = linked_trip!(scope, "07:00:00")

      command = {:copy, [source.id], daily, 0, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.counts == %{changed: 0, created: 1, deleted: 0, excluded: 0, skipped: 0}

      assert review.change_set.consequences == [
               {:warning, {:shared_dates, scope.service, 261}}
             ]

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert [created_id] = result.created_trip_ids
      assert Repo.get!(Trip, created_id).service_id == daily
      assert stop_time_rows(Repo.get!(Trip, created_id)) == stop_time_rows(source)
    end
  end

  describe "the allocated trip ID (R7)" do
    test "a taken base takes the smallest free suffix" do
      scope = editing_scope!("12")
      %{saturday: saturday} = weekday_and_saturday!(scope)
      source = linked_trip!(scope, "17:00:00")

      _existing =
        linked_trip!(scope, "16:00:00", %{
          service_id: saturday,
          trip_id: "12-0-#{saturday}-1700"
        })

      command = {:copy, [source.id], saturday, 0, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert [insert] = review.change_set.inserts
      assert insert.attrs.trip_id == "12-0-#{saturday}-1700-2"

      assert {:ok, result} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert [created_id] = result.created_trip_ids
      assert Repo.get!(Trip, created_id).trip_id == "12-0-#{saturday}-1700-2"
    end
  end

  describe "an offset below 00:00 (R7)" do
    test "refuses the command without writing" do
      scope = editing_scope!("12")
      source = linked_trip!(scope, "00:30:00")
      source_before = trip_row(source)
      rows_before = stop_time_rows(source)

      command = {:copy, [source.id], scope.service, -3600, true}

      assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
      assert review.change_set.inserts == []
      assert review.change_set.consequences == [{:error, :negative_time}]
      assert review.counts == %{changed: 0, created: 0, deleted: 0, excluded: 0, skipped: 0}

      assert {:error, {:refused, [{:error, :negative_time}]}} =
               Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

      assert trip_row(source) == source_before
      assert stop_time_rows(source) == rows_before
      assert trip_logs(source) == []
      assert trip_count(scope) == 1
    end
  end

  # -- Fixtures and readbacks -------------------------------------------------

  defp stamp_trip_metadata!(trip) do
    Repo.update!(
      Ecto.Changeset.change(trip,
        trip_headsign: "Downtown",
        shape_id: "shp_9",
        wheelchair_accessible: 2,
        bikes_allowed: 1
      )
    )
  end

  # Literal per-row detail on the source trip's three stops, so a copied full row
  # is comparable byte for byte: shape distances, stop headsign, timepoint and the
  # pickup, drop-off and continuous flags.
  defp stamp_stop_time_detail!(trip) do
    [first, second, third] = stop_time_structs(trip)

    Repo.update!(
      Ecto.Changeset.change(first,
        shape_dist_traveled: Decimal.new("1.25"),
        stop_headsign: "Downtown",
        pickup_type: 1,
        drop_off_type: 2,
        timepoint: 1
      )
    )

    Repo.update!(
      Ecto.Changeset.change(second,
        shape_dist_traveled: Decimal.new("2.5"),
        continuous_pickup: 2,
        continuous_drop_off: 3,
        timepoint: 0
      )
    )

    Repo.update!(
      Ecto.Changeset.change(third,
        shape_dist_traveled: Decimal.new("3.75"),
        timepoint: 1
      )
    )

    :ok
  end

  defp stop_time_structs(trip) do
    Repo.all(
      from(st in StopTime,
        where:
          st.trip_id == ^trip.trip_id and st.organization_id == ^trip.organization_id and
            st.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: st.stop_sequence, asc: st.id]
      )
    )
  end

  defp stop_time_rows(trip) do
    Repo.all(
      from(st in StopTime,
        where:
          st.trip_id == ^trip.trip_id and st.organization_id == ^trip.organization_id and
            st.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: st.stop_sequence, asc: st.id],
        select: %{
          stop_id: st.stop_id,
          stop_sequence: st.stop_sequence,
          arrival_time: st.arrival_time,
          departure_time: st.departure_time,
          stop_headsign: st.stop_headsign,
          pickup_type: st.pickup_type,
          drop_off_type: st.drop_off_type,
          continuous_pickup: st.continuous_pickup,
          continuous_drop_off: st.continuous_drop_off,
          shape_dist_traveled: st.shape_dist_traveled,
          timepoint: st.timepoint
        }
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
