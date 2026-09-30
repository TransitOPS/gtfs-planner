defmodule GtfsPlanner.Gtfs.Blocking.TripChangesProjectionTest do
  @moduledoc """
  Merge evidence (EV-6) for the per-trip block projection of Shift and Change calendar:

  - The R6 counterexample: block 103's trips A and B both move Weekday → Saturday and both
    keep block 103, because the one projection applies every changed row before any keep
    decision; deciding one trip at a time would still see B on Weekday and clear A (FH-20).
  - Moving only A clears A while B keeps block 103: A would otherwise carry the block alone
    on dates no companion runs, the companion-left-behind half of R6.
  - Moving A onto dates where another block 103 trip already runs clears A: the new
    companion was not a companion before, the R9 half that stops a move silently joining
    another vehicle's work.
  - A shifted trip whose new endpoints squeeze a layover below the stored minimum adds one
    `:short_layover` finding naming the shifted trip, and a shift never clears a block.
  - No changed rows returns identical before/after findings and no clear.
  - The changed rows may arrive in any order and return the same projection.

  Every expected value is literal: the block IDs, dates, clock seconds and the 120-second
  gap are fixed in the fixtures below, and the findings are the real `Checks` results
  hand-derived from the gap rule (a non-negative gap below the 5-minute minimum is one
  `:short_layover` warning between the two trips). The module is pure and reads no
  database, clock, files or network, so no sandbox or fixture cleanup is involved.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/trip_changes_projection_test.exs
  test/gtfs_planner/gtfs/calendars/combination_blocks_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes

  @wkdy [~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04]]
  @sat [~D[2026-03-07]]

  describe "a block whose trips move together" do
    test "both moved Weekday to Saturday keep block 103" do
      data = block_inputs()

      result = project(data, [moved(data, "trip-a", "SAT"), moved(data, "trip-b", "SAT")])

      assert result.cleared_trip_ids == []
      assert result.before_findings == []
      assert result.after_findings == []
      assert result.transfers == []
    end

    test "reordering the changed rows returns an identical projection" do
      data = block_inputs()
      changed = [moved(data, "trip-a", "SAT"), moved(data, "trip-b", "SAT")]

      assert project(data, changed) == project(data, Enum.reverse(changed))
    end
  end

  describe "a trip that moves away from its block" do
    test "moving only A clears A and leaves B on block 103" do
      data = block_inputs()

      result = project(data, [moved(data, "trip-a", "SAT")])

      # A's companion B stays on Weekday, whose dates share none of Saturday's, so the
      # projected companion set is empty where it held B before.
      assert result.cleared_trip_ids == ["trip-a"]
      refute "trip-b" in result.cleared_trip_ids
      assert result.before_findings == []
      assert result.after_findings == []
    end

    test "moving A onto dates where block 103 already runs clears A" do
      data = with_saturday_companion()

      result = project(data, [moved(data, "trip-a", "SAT")])

      # "trip-c" already runs block 103 on Saturday and overlaps the moved A 08:00-09:00
      # with its own 08:30-09:30, so A's projected companions are {c} where they held {b}
      # before. The clear is applied before the checks, so the overlap A would have joined
      # is not reported: after_findings is empty.
      assert result.cleared_trip_ids == ["trip-a"]
      refute "trip-b" in result.cleared_trip_ids
      refute "trip-c" in result.cleared_trip_ids
      assert result.before_findings == []
      assert result.after_findings == []
    end

    test "an unblocked trip's service move is never a clear" do
      data = block_inputs()

      result = project(data, [%{moved(data, "trip-a", "SAT") | block_id: nil}])

      assert result.cleared_trip_ids == []
    end
  end

  describe "endpoint changes" do
    test "a shifted trip that squeezes a layover below the minimum adds a :short_layover finding" do
      data = block_inputs()

      result = project(data, [shifted(data, "trip-a", 8 * 60)])

      # A moves to 08:08-09:08 and B still leaves 09:10, so the 10-minute layover becomes
      # 120 seconds, below the stored 5-minute minimum; the shift keeps block 103.
      assert result.cleared_trip_ids == []
      assert result.before_findings == []

      assert [finding] = result.after_findings
      assert finding.code == :short_layover
      assert finding.severity == :warning
      assert finding.block_id == "103"
      assert finding.trip_ids == ["trip-a", "trip-b"]
      assert finding.detail == %{gap_secs: 120}
      assert finding.transfer_id == nil
      assert finding.day_type_keys == [DayTypes.key(["WKDY"])]
      assert finding.dates == @wkdy
    end
  end

  describe "no changed rows" do
    test "returns identical before and after findings" do
      data = block_inputs()

      result = project(data, [])

      assert result.cleared_trip_ids == []
      assert result.after_findings == result.before_findings
      assert result.transfers == []
    end
  end

  # --- fixtures -------------------------------------------------------------

  # Block 103 on Weekday: A 08:00-09:00 and B 09:10-10:00 with a 10-minute layover at the
  # same stop, so the loaded day has no findings and B's dates are the Weekday ones only.
  defp block_inputs do
    trips = [
      trip("trip-a", "WKDY", "103", at(8, 0), at(9, 0), trip_id: "A"),
      trip("trip-b", "WKDY", "103", at(9, 10), at(10, 0), trip_id: "B")
    ]

    inputs([calendar("WKDY", @wkdy), calendar("SAT", @sat)], trips)
  end

  # The same block with a Saturday trip "trip-c" 08:30-09:30 that already carries block 103.
  defp with_saturday_companion do
    data = block_inputs()

    %{
      data
      | trips:
          data.trips ++
            [trip("trip-c", "SAT", "103", at(8, 30), at(9, 30), trip_id: "C")]
    }
  end

  defp inputs(calendars, trips) do
    %{
      calendars: calendars,
      trips: trips,
      transfers: [],
      settings: %{min_layover_minutes: 5}
    }
  end

  defp project(data, changed_trips) do
    Blocking.project_trip_changes(data, changed_trips)
  end

  defp row(data, id), do: Enum.find(data.trips, &(&1.id == id))

  defp moved(data, id, service_id), do: %{row(data, id) | service_id: service_id}

  defp shifted(data, id, delta_secs) do
    trip = row(data, id)

    %{
      trip
      | first_arrival: trip.first_arrival + delta_secs,
        first_departure: trip.first_departure + delta_secs,
        last_arrival: trip.last_arrival + delta_secs,
        last_departure: trip.last_departure + delta_secs
    }
  end

  defp calendar(service_id, active_dates) do
    %{
      service_id: service_id,
      name: service_id,
      active_dates: active_dates,
      trip_count: 1
    }
  end

  defp trip(id, service_id, block_id, from_secs, to_secs, opts) do
    stop = stop_ref()

    %{
      id: id,
      trip_id: Keyword.get(opts, :trip_id, id),
      route_id: "R1",
      service_id: service_id,
      block_id: block_id,
      trip_headsign: nil,
      route_pattern_id: nil,
      updated_at: ~U[2026-01-01 00:00:00Z],
      frequency?: false,
      headway_secs: nil,
      first_arrival: from_secs,
      first_departure: from_secs,
      last_arrival: to_secs,
      last_departure: to_secs,
      first_stop: stop,
      last_stop: stop,
      plottable?: true
    }
  end

  # One shared stop, so a gap is a `:same_stop` handoff and never a `:repositions` notice.
  defp stop_ref do
    %{stop_id: "S1", name: nil, parent_station: nil, lat: nil, lon: nil}
  end

  defp at(hours, minutes), do: hours * 3600 + minutes * 60
end
