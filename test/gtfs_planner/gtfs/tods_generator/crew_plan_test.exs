defmodule GtfsPlanner.Gtfs.TodsGenerator.CrewPlanTest do
  @moduledoc """
  Step 3: the crew stage cuts a generation candidate's uncovered work through the
  runs planner and refuses what it cannot stand behind.

  These are the failures specific to *generation* crew work, which the single-day
  suggestion tests cannot see because they never ask the question:

    * a 16-hour block with a usable same-place relief is cut into multiple legal
      duties, and the same block with no such relief leaves its hard-invalid duty
      uncovered rather than absorbed into one impossible run;
    * travel the version cannot establish — an impossible drive, an uncomputable
      one — never becomes an accepted run, while a merely estimated travel time
      stays visible on the duty that keeps it;
    * an existing run keeps its trips, its numbering is not reused, and a sign-off
      past midnight keeps its service-day seconds unmodified.

  Every case runs the production chain — `Gtfs.preview_tods_generation/2` through
  `TodsGenerator.preview/2` and `Plan.with_runs/3`, with the real
  `Runs.Cutter.run/5` and `Runs.Day.derive/4` behind it — against the fixture's own
  small schedule, and the facts it asserts are that schedule's own: literal
  service-day seconds, literal run counts, and the exclusions of the trips the case
  built. The run IDs a case compares are the ones the delta names — compared
  against each other and against the ID the version already had, never written into
  a case as an invented number. The run work is read from `run_deltas` (what a save
  would add) and `run_days` (the day that would be left).

  Run with:
  `mix test test/gtfs_planner/gtfs/tods_generator/crew_plan_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.TodsGeneratorFixtures

  alias GtfsPlanner.Gtfs.Runs

  describe "a long block's duties" do
    test "a 16-hour block with a terminal relief yields multiple legal duties" do
      world = crew_world_fixture(block: :long_duty, existing_run: "9001", max_piece_minutes: 480)

      assert {:ok, preview} = preview(world, crew_inputs(world, %{"terminal_relief?" => true}))

      # One day type is in scope, so every fact below is about one day.
      assert preview.day_type_keys == [world.weekday_day_type]

      # The mark is the block's own terminal, it is additive, and it is reported
      # because an admitted duty hands over at it.
      assert preview.relief_additions == [world.terminal_stop_id]
      assert preview.assumptions == [:terminal_relief_additive]

      # The block's first trip keeps the run it had; the uncovered remainder is cut
      # at the block's middle layover into two duties of its own.
      day_type_key = world.weekday_day_type
      assert preview.run_deltas[day_type_key][trip_uuid(world, "long-1")] == nil

      second = run_id(preview, world, "long-2")
      rest = run_id(preview, world, "long-3")

      assert rest == run_id(preview, world, "long-4")
      refute second == rest

      assert trip_ids(derived_run(preview, world, second)) == ["long-2"]
      assert trip_ids(derived_run(preview, world, rest)) == ["long-3", "long-4"]

      # Multiple legal duties: neither generated run carries a finding, and the
      # existing one is untouched.
      assert derived_run(preview, world, second).findings == []
      assert derived_run(preview, world, rest).findings == []
      assert trip_ids(derived_run(preview, world, "9001")) == ["long-1"]
      assert preview.counts.refused_runs == 0
      assert preview.exclusions == []
    end

    test "without that relief the hard-invalid duty stays uncovered" do
      world = crew_world_fixture(block: :long_duty, existing_run: "9001", max_piece_minutes: 480)

      assert {:ok, preview} = preview(world, crew_inputs(world))

      # Nothing was proposed and nothing was assumed: terminal relief is opt-in.
      assert preview.relief_additions == []
      assert preview.assumptions == []

      # The handover at the unmarked layover is a change away from relief, so the
      # whole duty is refused and all three of its trips are reported uncovered.
      assert preview.counts.refused_runs == 1

      assert exclusions(world, preview) == [
               {"long-2", :not_at_relief},
               {"long-3", :not_at_relief},
               {"long-4", :not_at_relief}
             ]

      for trip_id <- ["long-2", "long-3", "long-4"] do
        assert preview.run_deltas[world.weekday_day_type][trip_uuid(world, trip_id)] == nil
      end

      # The trips the refused duty would have held are uncovered work, and the
      # existing run is neither removed nor repaired: it keeps its trip and its
      # handover error is the operator's to fix.
      assert Enum.map(preview.run_days[world.weekday_day_type].uncovered, &piece_trip_ids/1) ==
               [["long-2", "long-3", "long-4"]]

      assert trip_ids(derived_run(preview, world, "9001")) == ["long-1"]

      assert Enum.any?(
               derived_run(preview, world, "9001").findings,
               &(&1.code == :not_at_relief and &1.severity == :error)
             )
    end
  end

  describe "travel the generator cannot establish" do
    test "an impossible drive leaves its duty uncovered" do
      world = crew_world_fixture(block: :impossible_drive)

      assert {:ok, preview} = preview(world, crew_inputs(world))

      # The block's gap is 3 minutes for a 6-minute drive: no relief window exists
      # in it and the duty that would have to make the move is refused.
      assert exclusions(world, preview) == [
               {"edge-1", :cannot_reach},
               {"edge-2", :cannot_reach}
             ]

      for trip_id <- ["edge-1", "edge-2"] do
        assert preview.run_deltas[world.weekday_day_type][trip_uuid(world, trip_id)] == nil
      end
    end

    test "an uncomputable drive leaves its duty uncovered" do
      world = crew_world_fixture(block: :unknown_drive)

      assert {:ok, preview} = preview(world, crew_inputs(world))

      # One end of the block's gap has no coordinates, so the drive is unknown
      # rather than zero and the duty is refused rather than paid as free.
      assert exclusions(world, preview) == [
               {"nogeo-1", :travel_unknown},
               {"nogeo-2", :travel_unknown}
             ]

      for trip_id <- ["nogeo-1", "nogeo-2"] do
        assert preview.run_deltas[world.weekday_day_type][trip_uuid(world, trip_id)] == nil
      end
    end

    test "a duty kept over its piece limit stays disclosed with its estimates" do
      world = crew_world_fixture()

      assert {:ok, preview} = preview(world, crew_inputs(world))

      # Block 101's four trips are uncovered, and the piece the cut leaves after its
      # first trip is over the fixture's 330-minute limit. That is a warning rather
      # than a refusal: the duty is kept, and what is wrong with it is visible.
      day_type_key = world.weekday_day_type
      run_id = run_id(preview, world, "b")

      assert run_id != nil
      assert run_id == run_id(preview, world, "c")
      assert run_id == run_id(preview, world, "d")

      assert [warning] =
               Enum.filter(
                 preview.warnings,
                 &(&1.run_ids == [run_id] and &1.code == :piece_too_long)
               )

      assert warning.severity == :warning
      assert warning.day_type_key == day_type_key
      assert warning.block_id == "101"

      # The duty's travel is an estimate, and the estimate is on the run's own work
      # rather than summarized away.
      derived = derived_run(preview, world, run_id)
      assert Enum.any?(derived.work.segments, &(&1.kind == :travel and &1.source == :estimated))
      assert preview.counts.refused_runs == 0
    end
  end

  describe "the day's saved work" do
    test "existing runs stay, numbering avoids them and overnight seconds are unmodified" do
      world = crew_world_fixture(block: :overnight, existing_run: "1")
      organization_id = world.organization.id
      version_id = world.version.id

      before = Runs.assignments_by_day_type(organization_id, version_id)

      assert {:ok, preview} = preview(world, crew_inputs(world, %{"terminal_relief?" => true}))

      # The stored assignments are exactly what they were, row for row: the crew
      # stage is pure and a generation adds runs rather than rewriting one.
      assert Runs.assignments_by_day_type(organization_id, version_id) == before

      day_type_key = world.weekday_day_type
      assert preview.run_deltas[day_type_key][trip_uuid(world, "night-1")] == nil

      # One new duty, numbered above the ID in use, and its own seconds are
      # service-day seconds on both sides of midnight.
      new_run_id = preview.run_deltas[day_type_key][trip_uuid(world, "night-2")]

      assert new_run_id != nil
      refute new_run_id == "1"
      refute "1" in Map.values(preview.run_deltas[day_type_key])

      existing = derived_run(preview, world, "1")
      assert trip_ids(existing) == ["night-1"]
      assert existing.work.sign_on_secs == hms(23, 15)
      assert existing.work.sign_off_secs == hms(24, 35)
      assert derived_run(preview, world, new_run_id).work.sign_on_secs == hms(24, 25)
      assert derived_run(preview, world, new_run_id).work.sign_off_secs == hms(25, 45)

      # The block's own layover is the only mark proposed, and the day it leaves has
      # no error in it: the saved trip keeps its run and the new one is cut at the
      # terminal.
      assert preview.relief_additions == [world.terminal_stop_id]
      assert preview.counts.refused_runs == 0
      assert preview.counts.new_runs == 5
      refute Enum.any?(preview.run_days[day_type_key].findings, &(&1.severity == :error))
    end
  end

  # Every trip the fixture wrote, by its GTFS `trip_id`, whether it is one of the
  # world's own or one a crew case's block added.
  defp trip_uuids(world) do
    crew = Map.get(world, :trips, %{})

    Map.merge(world.trip_ids, Map.new(crew, fn {trip_id, trip} -> {trip_id, trip.id} end))
  end

  defp trip_uuid(world, trip_id), do: Map.fetch!(trip_uuids(world), trip_id)

  defp run_id(preview, world, trip_id),
    do: preview.run_deltas[world.weekday_day_type][trip_uuid(world, trip_id)]

  # One derived run of the case's day type, by its ID. The expectation is asserted
  # here rather than left to a later assertion on `nil`, so a run the day does not
  # have fails as the run that is missing.
  defp derived_run(preview, world, run_id) do
    day = preview.run_days[world.weekday_day_type]
    assert run = Enum.find(day.runs, &(&1.run_id == run_id))
    run
  end

  defp trip_ids(run), do: run.pieces |> Enum.flat_map(& &1.trips) |> Enum.map(& &1.trip_id)

  defp piece_trip_ids(piece), do: Enum.map(piece.trips, & &1.trip_id)

  # The exclusions keyed by the fixture's own trip IDs, sorted, so an assertion says
  # which trips were refused rather than which opaque UUIDs.
  defp exclusions(world, preview) do
    names = Map.new(trip_uuids(world), fn {trip_id, uuid} -> {uuid, trip_id} end)

    preview.exclusions
    |> Enum.map(fn %{subject: uuid, reason: reason} -> {Map.fetch!(names, uuid), reason} end)
    |> Enum.sort()
  end

  defp hms(hours, minutes), do: hours * 3600 + minutes * 60
end
