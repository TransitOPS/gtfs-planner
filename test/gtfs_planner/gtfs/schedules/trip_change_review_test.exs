defmodule GtfsPlanner.Gtfs.Schedules.TripChangeReviewTest do
  @moduledoc """
  Merge evidence (EV-9) for the change review path (step 10):

  - A shift review plans every selected trip without writing: `counts.changed`
    names the selected trips and the trips, stop_times and change_logs row counts
    are equal before and after (R3, AC-15).
  - The review fingerprint changes when one fenced trip's `updated_at` changes
    between two reviews, so a change between review and apply cannot pass the
    fence (FH-14).
  - A foreign organization's trip UUID and a trip of another route are
    `{:error, :not_found}`; an unknown target calendar is
    `{:error, :calendar_not_found}`.
  - A timepoint shift excludes a selected frequency trip and counts it excluded.

  Every expected value is literal and hand-derived from R1, R3, R4 and the §4.4
  contract in spec.md; nothing computes an expectation with the loader, the
  planner or the review. Every review runs through the real production entry
  point `Gtfs.review_trip_change/3`, never the private loader.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/schedules/trip_change_review_test.exs`.
  """
  use GtfsPlanner.DataCase

  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    %{scope: editing_scope!("12")}
  end

  describe "a shift review" do
    test "counts the selected trips and writes no row", %{scope: scope} do
      first = linked_trip!(scope, "07:00:00")
      second = linked_trip!(scope, "08:00:00")
      third = linked_trip!(scope, "09:00:00")
      selected = Enum.sort([first.id, second.id, third.id])

      before = scoped_counts(scope)

      assert {:ok, review} =
               Gtfs.review_trip_change("12", {:shift, selected, 300, nil}, scope.audit)

      assert review.command == {:shift, selected, 300, nil}
      assert review.counts == %{changed: 3, created: 0, deleted: 0, excluded: 0, skipped: 0}
      assert Enum.map(review.change_set.updates, & &1.trip_id) |> Enum.sort() == selected
      assert review.change_set.inserts == []
      assert review.change_set.deletes == []

      # The stored rows are 07:00 / 07:05+07:05:30 / 07:12; a +5 minute shift
      # moves every clock, and the last column previews the arrival.
      assert review.preview == %{
               first.id => %{1 => 25_500, 2 => 25_830, 3 => 26_220},
               second.id => %{1 => 29_100, 2 => 29_430, 3 => 29_820},
               third.id => %{1 => 32_700, 2 => 33_030, 3 => 33_420}
             }

      assert review.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert scoped_counts(scope) == before
    end

    test "excludes a timepoint-shifted frequency trip from the counts", %{scope: scope} do
      listed = linked_trip!(scope, "07:00:00")
      frequency = frequency_trip!(scope, [{21_600, 25_200, 600}])

      assert {:ok, review} =
               Gtfs.review_trip_change(
                 "12",
                 {:shift, [listed.id, frequency.id], 300, 1},
                 scope.audit
               )

      assert review.counts == %{changed: 1, created: 0, deleted: 0, excluded: 1, skipped: 0}
      assert Enum.map(review.change_set.updates, & &1.trip_id) == [listed.id]
      assert review.preview == %{listed.id => %{1 => 25_500, 2 => 25_830, 3 => 26_220}}
    end
  end

  describe "the loaded change state" do
    test "carries the stored stop-time flags into the planned update", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")

      Repo.update!(
        Ecto.Changeset.change(first_stop_time(trip), %{
          timepoint: 1,
          pickup_type: 2,
          drop_off_type: 3,
          stop_headsign: "Cedar Library"
        })
      )

      assert {:ok, review} =
               Gtfs.review_trip_change("12", {:shift, [trip.id], 300, nil}, scope.audit)

      assert [update] = review.change_set.updates
      assert [first | _rest] = update.stop_times

      assert first == %{
               position: 1,
               arrival_time: "07:05:00",
               departure_time: "07:05:00",
               timepoint: 1,
               pickup_type: 2,
               drop_off_type: 3,
               stop_headsign: "Cedar Library"
             }
    end

    test "relinks a custom trip through the loaded pattern, occurrences and timings",
         %{scope: scope} do
      trip =
        custom_trip!(scope, [
          {"A", "07:00:00", "07:00:00"},
          {"B", "07:05:00", "07:05:30"},
          {"C", "07:12:00", "07:12:00"}
        ])

      Enum.each(trip_stop_times(trip), fn stop_time ->
        Repo.update!(Ecto.Changeset.change(stop_time, %{timepoint: 1}))
      end)

      assert {:ok, review} =
               Gtfs.review_trip_change("12", {:shift, [trip.id], 300, nil}, scope.audit)

      assert [update] = review.change_set.updates

      assert update.fields == %{
               timed_pattern_id: scope.bundle.timing.id,
               pattern_derivation_state: "linked",
               pattern_derivation_reason: nil
             }

      assert Enum.map(update.stop_times, & &1.departure_time) ==
               ["07:05:00", "07:10:30", "07:17:00"]
    end
  end

  describe "the R3 fingerprint" do
    test "changes when a fenced trip changes between two reviews", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")
      command = {:shift, [trip.id], 300, nil}

      assert {:ok, first} = Gtfs.review_trip_change("12", command, scope.audit)
      assert {:ok, repeat} = Gtfs.review_trip_change("12", command, scope.audit)
      assert repeat.fingerprint == first.fingerprint

      Repo.update_all(
        from(t in Trip, where: t.id == ^trip.id),
        set: [updated_at: ~U[2026-10-01 12:00:00.000000Z]]
      )

      assert {:ok, second} = Gtfs.review_trip_change("12", command, scope.audit)
      assert second.fingerprint != first.fingerprint
    end
  end

  describe "command scoping" do
    test "a foreign organization's trip and another route's trip are not found", %{scope: scope} do
      foreign = editing_scope!("91")
      foreign_trip = linked_trip!(foreign, "07:00:00")

      assert {:error, :not_found} =
               Gtfs.review_trip_change("12", {:shift, [foreign_trip.id], 300, nil}, scope.audit)

      other_route =
        editing_scope!("13",
          organization: scope.organization,
          version: scope.version,
          actor: scope.actor,
          audit: scope.audit
        )

      other_trip = linked_trip!(other_route, "07:00:00")

      assert {:error, :not_found} =
               Gtfs.review_trip_change("12", {:shift, [other_trip.id], 300, nil}, scope.audit)

      assert {:error, :not_found} =
               Gtfs.review_trip_change(
                 "12",
                 {:shift, [Ecto.UUID.generate()], 300, nil},
                 scope.audit
               )
    end

    test "an unknown target calendar is refused", %{scope: scope} do
      trip = linked_trip!(scope, "07:00:00")

      assert {:error, :calendar_not_found} =
               Gtfs.review_trip_change(
                 "12",
                 {:copy, [trip.id], "no_such_service", 0, true},
                 scope.audit
               )
    end
  end

  defp first_stop_time(trip) do
    trip
    |> trip_stop_times()
    |> List.first()
  end

  defp trip_stop_times(trip) do
    Repo.all(
      from(st in StopTime,
        where: st.trip_id == ^trip.trip_id,
        order_by: [asc: st.stop_sequence, asc: st.id]
      )
    )
  end

  defp scoped_counts(scope) do
    %{
      trips:
        Repo.aggregate(
          from(t in Trip,
            where:
              t.organization_id == ^scope.organization.id and
                t.gtfs_version_id == ^scope.version.id
          ),
          :count
        ),
      stop_times:
        Repo.aggregate(
          from(st in StopTime,
            where:
              st.organization_id == ^scope.organization.id and
                st.gtfs_version_id == ^scope.version.id
          ),
          :count
        ),
      change_logs:
        Repo.aggregate(
          from(l in ChangeLog,
            where:
              l.organization_id == ^scope.organization.id and
                l.gtfs_version_id == ^scope.version.id
          ),
          :count
        )
    }
  end
end
