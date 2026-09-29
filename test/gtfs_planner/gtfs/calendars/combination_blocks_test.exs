defmodule GtfsPlanner.Gtfs.Calendars.CombinationBlocksTest do
  @moduledoc """
  Merge evidence (EV-4) for the simultaneous block projection of one calendar
  combination:

  - Two source calendars that never shared a date and both move to one destination are
    cleared together, because one projection decides every moved block before any clear:
    clearing the first trip first would have left the second with no companion at all.
  - A moved trip whose projected companions are a subset of its original ones keeps its
    block, and the destination's own block stays assigned while its gained date adds a
    real `:overlap` warning that the same day type did not have before.
  - A pre-existing warning keeps its `Checks.finding_key/1` while its date context grows,
    and an in-seat record keeps its key while its reason and dates change, so a changed
    detail is never read as an unchanged warning.
  - A companion on a calendar that is not selected clears the moved block when it runs on
    a gained destination date, and a type-4/5 counterpart on another such calendar is
    reported `{:stale, {:not_next, ...}}` after the move where it was
    `{:stale, :no_shared_date}` before, naming the trip the moved trip's block runs
    after it.
  - A trip whose service moves is decided whether or not the selection named it, an
    unblocked moving trip is never a clear, and a transfer record naming trips the
    projection does not hold is reported `{:stale, :trip_missing}`.
  - The destination's own trip is never a clear candidate: a destination block that gains a
    non-selected companion on a gained date keeps its ID (AC-17) and the new warning about it
    is reported instead of a silent unassignment.
  - Reordering every input list returns an identical projection.

  Every expectation comes from the literal dates, times and block IDs of the fixtures below
  and from the shared `Checks`, `DayTypes` and `InSeat` rules; no expected finding is
  hard-coded from the projection's own output. The module is pure and reads no database,
  clock, files or network, so no sandbox or fixture cleanup is involved.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 mix test
  test/gtfs_planner/gtfs/calendars/combination_blocks_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.{Checks, DayTypes}

  @sat [~D[2026-03-07]]
  @sun [~D[2026-03-08]]
  @destination_dates [~D[2026-03-07], ~D[2026-03-09]]

  @wkdy [~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04]]
  @span [~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04], ~D[2026-03-09]]
  @dest [~D[2026-03-02], ~D[2026-03-09]]
  @result_dates [~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04], ~D[2026-03-09]]

  describe "one simultaneous projection" do
    test "two sources sharing an originally disjoint block clear together, not in sequence" do
      result = project(two_source_inputs([]), two_source_command())

      # Neither source runs on a date of the other, so neither has a companion before the
      # move; afterwards both run on the destination's dates. Clearing "trip-a" first would
      # leave "trip-b" with no companion at all and keep its block, so clearing both proves
      # every decision came from the before/after pair rather than from a sequence (PM-4).
      assert result.cleared_trip_ids == ["trip-a", "trip-b"]
      assert result.before_findings == []
      assert result.after_findings == []
      assert result.transfers == []
      refute "trip-d" in result.cleared_trip_ids
    end

    test "a moved companion the selection did not name is still decided" do
      result = project(two_source_inputs([], ["trip-a"]), two_source_command())

      # `selected_trip_ids` names the loader's start set, not what moves: AC-11 moves every
      # trip of a source calendar, so a loaded companion on one takes its block with it.
      assert result.cleared_trip_ids == ["trip-a", "trip-b"]
    end

    test "an unblocked moving trip is never a clear and contributes no finding" do
      trips = [
        trip("trip-u", "SAT", nil, at(8, 0), at(9, 0)),
        trip("trip-b", "SUN", "101", at(10, 0), at(11, 0))
      ]

      calendars = [
        calendar("SAT", @sat, 1),
        calendar("SUN", @sun, 1),
        calendar("DEST", @destination_dates, 1)
      ]

      result = project(inputs(calendars, trips), two_source_command())

      assert result.cleared_trip_ids == []
      assert result.before_findings == []
      assert result.after_findings == []
    end
  end

  describe "projected block consequences" do
    test "a subset-safe moved trip keeps its block while the destination block reports its new warning" do
      result = project(block_700_inputs([]), wkdy_command())

      # "trip-s" runs with the non-selected "trip-c" and with destination trip "trip-d"
      # before and after, so its projected companions are a subset of its original ones.
      assert result.cleared_trip_ids == []
      refute "trip-d" in result.cleared_trip_ids

      gained_key = DayTypes.key(["DEST", "SPAN"])

      refute Enum.any?(
               result.before_findings,
               &(&1.code == :overlap and &1.block_id == "700" and &1.day_type_keys == [gained_key])
             )

      new_warning = overlap_on(result.after_findings, gained_key)

      assert new_warning.trip_ids == ["trip-s", "trip-d"]
      assert new_warning.severity == :error
      assert new_warning.block_id == "700"
      assert new_warning.detail.overlap_secs == 1800
      # The day type "DEST" runs alone on the gained 2026-03-09, which is why the same pair
      # of trips is a new warning there and not on the dates it already shared.
      assert new_warning.dates == [~D[2026-03-09]]

      shared_key = DayTypes.key(["DEST", "SPAN", "WKDY"])
      before_shared = overlap_on(result.before_findings, shared_key)
      after_shared = overlap_on(result.after_findings, shared_key)

      # The pre-existing warning keeps its finding key and grows across the moved trip's
      # new dates, so a key-only comparison would call it unchanged.
      assert Checks.finding_key(before_shared) == Checks.finding_key(after_shared)
      assert before_shared.dates == [~D[2026-03-02]]
      assert after_shared.dates == [~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04]]
    end

    test "a non-selected companion on a gained date clears the moved block" do
      trips = [
        trip("trip-a", "SAT", "101", at(8, 0), at(9, 0)),
        trip("trip-y", "MID", "101", at(8, 30), at(9, 30))
      ]

      calendars = [
        calendar("SAT", @sat, 1),
        calendar("MID", [~D[2026-03-09]], 1),
        calendar("DEST", [~D[2026-03-09]], 0)
      ]

      data = inputs(calendars, trips)

      # "trip-y" runs only on 2026-03-09, which "trip-a" gains, so the projected block
      # introduces a companion the original one did not have.
      assert project(data, command(["SAT"], [~D[2026-03-07], ~D[2026-03-09]])).cleared_trip_ids ==
               ["trip-a"]

      # Without that companion the same command keeps the block: the non-selected calendar
      # is what makes the difference.
      assert project(
               %{data | trips: [hd(trips)]},
               command(["SAT"], [~D[2026-03-07], ~D[2026-03-09]])
             ).cleared_trip_ids ==
               []
    end

    test "a transfer counterpart on a non-selected calendar is reported before and after" do
      data =
        sunonly_inputs([
          transfer("tr-0", "missing-from", "missing-to"),
          transfer("tr-1", "S", "X")
        ])

      result = project(data, wkdy_command())

      # A record naming trips the projection does not hold is reported, not raised on.
      assert %{id: "tr-0", before: {:stale, :trip_missing}, after: {:stale, :trip_missing}} =
               Enum.find(result.transfers, &(&1.id == "tr-0"))

      assert Enum.map(result.transfers, & &1.id) == ["tr-0", "tr-1"]

      counterpart_key = DayTypes.key(["DEST", "SPAN", "SUNONLY"])
      assert DayTypes.key(["SUNONLY"]) != counterpart_key

      assert %{
               id: "tr-1",
               before: {:stale, :no_shared_date},
               after: {:stale, {:not_next, [failure]}}
             } =
               Enum.find(result.transfers, &(&1.id == "tr-1"))

      assert failure.key == counterpart_key
      assert failure.date_count == 1
      # The counterpart trip "X" is blocked on its own block, so the record is not
      # next on the moved trip's block either, and the day type's own order runs
      # destination trip "D" after "S" on block "700".
      assert failure.next_trip_id == "D"

      assert Enum.sort(Map.keys(failure)) == [:date_count, :key, :label, :next_trip_id]

      before_finding = in_seat_finding(result.before_findings)
      after_finding = in_seat_finding(result.after_findings)

      assert Checks.finding_key(before_finding) == Checks.finding_key(after_finding)
      assert before_finding.detail.reason == :no_shared_date
      assert before_finding.day_type_keys == []
      assert before_finding.dates == []

      assert {:not_next, [reason_failure]} = after_finding.detail.reason
      assert reason_failure.key == counterpart_key
      assert reason_failure.next_trip_id == "D"
      assert after_finding.day_type_keys == [counterpart_key]
      assert after_finding.dates == [~D[2026-03-09]]
      assert after_finding.block_id == "700"
    end
  end

  describe "destination block preservation" do
    test "a destination block that gains a companion on a gained date keeps its ID" do
      result = project(destination_block_inputs(), destination_block_command())

      # "trip-d" is the destination's own trip on block "705". Before the move it runs alone on
      # 2026-03-02; the reviewed result adds 2026-03-09, where the non-selected "XNO" trip-x runs
      # the same block, so trip-d's projected companions are not a subset of its original ones.
      # AC-17 keeps destination block IDs assigned, so no trip is cleared here at all: the
      # regression a subset-only rule would produce is `["trip-d"]`.
      assert result.cleared_trip_ids == []
      refute "trip-d" in result.cleared_trip_ids

      refute Enum.any?(result.before_findings, &(&1.code == :overlap and &1.block_id == "705"))

      # The destination block keeps its ID and the combination's own new warning about it is
      # reported, which is what a review shows instead of a silent unassignment.
      warning = overlap_on_block(result.after_findings, "705")

      assert Enum.sort(warning.trip_ids) == ["trip-d", "trip-x"]
      assert warning.day_type_keys == [DayTypes.key(["DEST", "SRC", "XNO"])]
      assert warning.dates == [~D[2026-03-09]]
      assert warning.block_id == "705"
    end
  end

  describe "determinism" do
    test "reordering every input list returns an identical projection" do
      data = sunonly_inputs([transfer("tr-1", "S", "X")])
      command = wkdy_command()
      expected = project(data, command)

      reversed = %{
        data
        | calendars: Enum.reverse(data.calendars),
          trips: Enum.reverse(data.trips),
          transfers: Enum.reverse(data.transfers),
          selected_trip_ids: Enum.reverse(data.selected_trip_ids)
      }

      assert project(reversed, %{command | source_ids: Enum.reverse(command.source_ids)}) ==
               expected

      rotated = %{data | trips: Enum.drop(data.trips, 1) ++ Enum.take(data.trips, 1)}
      assert project(rotated, command) == expected
      assert project(data, command) == expected

      two_source = two_source_inputs([])

      assert project(two_source, two_source_command()) ==
               project(
                 %{two_source | trips: Enum.reverse(two_source.trips)},
                 %{two_source_command() | source_ids: ["SUN", "SAT"]}
               )
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp two_source_inputs(transfers, selected_trip_ids \\ ["trip-a", "trip-b"]) do
    trips = [
      trip("trip-a", "SAT", "101", at(8, 0), at(9, 0)),
      trip("trip-b", "SUN", "101", at(10, 0), at(11, 0)),
      trip("trip-d", "DEST", "201", at(8, 0), at(9, 0))
    ]

    calendars = [
      calendar("SAT", @sat, 1),
      calendar("SUN", @sun, 1),
      calendar("DEST", @destination_dates, 1)
    ]

    inputs(calendars, trips, transfers, selected_trip_ids)
  end

  defp two_source_command, do: command(["SAT", "SUN"], @destination_dates)

  # Destination block "700": the moving "WKDY" trip shares the block with a non-selected
  # "SPAN" companion on every WKDY date and with destination trip "DEST" on 2026-03-02, and
  # the destination gains 2026-03-03 and 2026-03-04.
  defp block_700_inputs(transfers) do
    trips = [
      trip("trip-s", "WKDY", "700", at(8, 0), at(9, 0), trip_id: "S"),
      trip("trip-c", "SPAN", "700", at(12, 0), at(13, 0), trip_id: "C"),
      trip("trip-d", "DEST", "700", at(8, 30), at(9, 30), trip_id: "D")
    ]

    calendars = [
      calendar("WKDY", @wkdy, 1),
      calendar("SPAN", @span, 1),
      calendar("DEST", @dest, 1)
    ]

    inputs(calendars, trips, transfers, ["trip-s"])
  end

  defp wkdy_command, do: command(["WKDY"], @result_dates)

  # The same fixture with a counterpart "trip-x" on the non-selected "SUNONLY" calendar,
  # which runs only on the date the destination gains.
  defp sunonly_inputs(transfers) do
    data = block_700_inputs(transfers)

    %{
      data
      | calendars: data.calendars ++ [calendar("SUNONLY", [~D[2026-03-09]], 1)],
        trips:
          data.trips ++
            [trip("trip-x", "SUNONLY", "800", at(9, 30), at(10, 30), trip_id: "X")]
    }
  end

  defp inputs(calendars, trips, transfers \\ [], selected_trip_ids \\ nil) do
    %{
      calendars: calendars,
      trips: trips,
      selected_trip_ids: selected_trip_ids || Enum.map(trips, & &1.id),
      transfers: transfers,
      settings: %{min_layover_minutes: 5},
      raw: %{selected_calendars: %{}},
      today: ~D[2026-03-05]
    }
  end

  defp command(source_ids, result_dates) do
    %{destination_id: "DEST", source_ids: source_ids, result_dates: result_dates}
  end

  defp project(data, command), do: Blocking.project_calendar_combination(data, command)

  defp calendar(service_id, active_dates, trip_count) do
    %{
      service_id: service_id,
      name: service_id,
      active_dates: active_dates,
      trip_count: trip_count
    }
  end

  defp trip(id, service_id, block_id, from_secs, to_secs, opts \\ []) do
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
      first_stop: nil,
      last_stop: nil,
      plottable?: true
    }
  end

  defp transfer(id, from_trip_id, to_trip_id) do
    %{
      id: id,
      from_trip_id: from_trip_id,
      to_trip_id: to_trip_id,
      transfer_type: 4,
      from_stop_id: nil,
      to_stop_id: nil
    }
  end

  defp overlap_on(findings, day_type_key) do
    Enum.find(
      findings,
      &(&1.code == :overlap and &1.block_id == "700" and &1.day_type_keys == [day_type_key])
    )
  end

  defp overlap_on_block(findings, block_id) do
    Enum.find(findings, &(&1.code == :overlap and &1.block_id == block_id))
  end

  # Destination block "705": the destination's own trip-d runs alone on 2026-03-02, the
  # non-selected "XNO" trip-x runs the gained 2026-03-09 on the same block, and the moving
  # "SRC" trip-s runs 2026-03-09 on its own block.
  defp destination_block_inputs do
    trips = [
      trip("trip-d", "DEST", "705", at(8, 30), at(9, 30), trip_id: "D"),
      trip("trip-x", "XNO", "705", at(8, 45), at(9, 45), trip_id: "X"),
      trip("trip-s", "SRC", "706", at(10, 0), at(11, 0), trip_id: "S")
    ]

    calendars = [
      calendar("DEST", [~D[2026-03-02]], 1),
      calendar("SRC", [~D[2026-03-09]], 1),
      calendar("XNO", [~D[2026-03-09]], 1)
    ]

    inputs(calendars, trips, [], ["trip-d", "trip-s"])
  end

  defp destination_block_command do
    %{destination_id: "DEST", source_ids: ["SRC"], result_dates: [~D[2026-03-02], ~D[2026-03-09]]}
  end

  defp in_seat_finding(findings), do: Enum.find(findings, &(&1.transfer_id == "tr-1"))

  defp at(hours, minutes), do: hours * 3600 + minutes * 60
end
