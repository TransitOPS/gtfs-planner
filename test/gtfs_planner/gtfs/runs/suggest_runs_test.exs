defmodule GtfsPlanner.Gtfs.Runs.SuggestRunsTest do
  @moduledoc """
  Suggesting is read-only and hands back a fingerprinted plan.

  `plan_test.exs` shows each input changes the fingerprint. These cases show the
  other two properties: that suggesting writes nothing (the row count is unchanged
  after a suggestion), and that the plan's own numbers are the ones an apply would
  produce rather than a second, hopeful derivation of them.

  That last one is the assertion worth reading twice. `plan.after` is compared
  against the figures from `load_runs/3` *after* `apply_moves/4` has actually
  written the same moves. A preview that disagreed with reality by one notice,
  or by one run's work time, would pass every other test in this file.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/suggest_runs_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.TripRun

  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  setup do
    world = runs_version_fixture()

    # Block 101's four trips on "1001"; block 102's two are uncovered, which is
    # what an `:uncovered_only` suggestion has to work on.
    for trip <- world.blocks["101"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1001"
      })
    end

    %{world: world}
  end

  # The whole table, not a count. "Writes nothing" is a claim about contents as
  # much as about rows: an update that preserved the count would still be a
  # write.
  defp whole_table do
    Repo.all(from(row in TripRun, select: {row.id, row.trip_id, row.day_type_key, row.run_id}))
    |> Enum.sort()
  end

  defp suggest(world, scope) do
    {:ok, plan} =
      Gtfs.suggest_runs(world.organization.id, world.version.id, world.day_type_key, scope)

    plan
  end

  describe "suggesting writes nothing" do
    test "the trip_runs table is identical before and after, in both scopes", %{world: world} do
      before = whole_table()

      suggest(world, :uncovered_only)
      assert whole_table() == before

      suggest(world, :replace_all)
      assert whole_table() == before
    end

    test "a suggestion writes nothing even when it produces many moves", %{world: world} do
      plan = suggest(world, :replace_all)
      assert plan.moves != []

      before = whole_table()
      suggest(world, :replace_all)
      assert whole_table() == before
    end

    test "suggesting is repeatable and returns the same plan", %{world: world} do
      first = suggest(world, :uncovered_only)
      second = suggest(world, :uncovered_only)

      assert first == second
    end
  end

  describe "an uncovered-only plan" do
    test "moves only the uncovered trips", %{world: world} do
      plan = suggest(world, :uncovered_only)

      covered = MapSet.new(world.blocks["101"] |> Enum.map(& &1.id))
      uncovered = MapSet.new(world.blocks["102"] |> Enum.map(& &1.id))

      moved = MapSet.new(Enum.map(plan.moves, & &1.trip_id))

      # Only the uncovered trips move, and all of them do. The covered set is
      # named here so a regression that moved a covered trip would show as an
      # overlap rather than only as a larger moved set.
      assert Enum.all?(plan.moves, &MapSet.member?(uncovered, &1.trip_id))
      assert moved == uncovered
      assert MapSet.disjoint?(moved, covered)
      assert Enum.all?(plan.moves, &is_nil(&1.from))
    end

    test "every covered trip keeps the run it was already on", %{world: world} do
      plan = suggest(world, :uncovered_only)

      for trip <- world.blocks["101"] do
        refute Enum.any?(plan.moves, &(&1.trip_id == trip.id))
      end
    end

    test "the moves apply and leave the day as the preview said", %{world: world} do
      plan = suggest(world, :uncovered_only)

      # `to` is never nil or :new for a suggestion, so it is directly a move for
      # `apply_run_moves/4`.
      moves = Enum.map(plan.moves, &%{trip_id: &1.trip_id, from: &1.from, to: &1.to})

      assert {:ok, _} =
               Gtfs.apply_run_moves(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 moves
               )

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.derived.stats == plan.after
    end
  end

  describe "a replace-all plan" do
    test "numbers from the rebuild prefix, not from the highest run", %{world: world} do
      # Put the day's only run on 1013 first, so the two numbering rules give
      # different answers: the rebuild prefix is 1000, so a rebuild numbers 1001,
      # 1002 - while "one above the highest" would have given 1014. The plan is
      # only interesting on a day type whose scheme has to survive.
      {:ok, _} =
        Gtfs.rename_run(
          world.organization.id,
          world.version.id,
          world.day_type_key,
          "1001",
          "1013"
        )

      plan = suggest(world, :replace_all)

      ids = plan.preview.runs |> Enum.map(& &1.run_id) |> Enum.sort()
      assert ids == ["1001", "1002", "1003", "1004"]
    end

    test "new_run_ids are the proposed IDs not already in use", %{world: world} do
      {:ok, _} =
        Gtfs.rename_run(
          world.organization.id,
          world.version.id,
          world.day_type_key,
          "1001",
          "1013"
        )

      plan = suggest(world, :replace_all)

      # All four are new: the day type's only run was 1013, which the rebuild
      # replaces. No old ID appears.
      assert plan.new_run_ids == ["1001", "1002", "1003", "1004"]
    end

    test "a rebuild reassigns every trip, and applying it produces the previewed day", %{
      world: world
    } do
      # Renamed first so the old run genuinely disappears, which a rebuild onto
      # the same numbers would hide.
      {:ok, _} =
        Gtfs.rename_run(
          world.organization.id,
          world.version.id,
          world.day_type_key,
          "1001",
          "1013"
        )

      plan = suggest(world, :replace_all)

      moves = Enum.map(plan.moves, &%{trip_id: &1.trip_id, from: &1.from, to: &1.to})

      assert {:ok, _} =
               Gtfs.apply_run_moves(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 moves
               )

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      every_trip = (world.blocks["101"] ++ world.blocks["102"]) |> Enum.map(& &1.id)
      assert MapSet.new(Map.keys(runs_day.assignments)) == MapSet.new(every_trip)

      # The old run is gone entirely, not merely unreferenced: a rebuild that
      # left rows behind would keep counting them as orphans.
      assert runs_day.orphans.count == 0
      refute "1013" in Enum.map(runs_day.derived.runs, & &1.run_id)

      # And what the planner was shown is what the day now is.
      previewed = plan.preview.runs |> Enum.map(& &1.run_id) |> Enum.uniq() |> Enum.sort()
      applied = runs_day.derived.runs |> Enum.map(& &1.run_id) |> Enum.uniq() |> Enum.sort()
      assert applied == previewed
    end

    test "a trip the rebuild leaves on the same run has no move", %{world: world} do
      plan = suggest(world, :replace_all)

      # A move is a trip whose run differs. A trip the rebuild happens to leave
      # where it is has not moved, and the plan says so rather than writing a
      # no-op row.
      for move <- plan.moves do
        refute move.from == move.to
      end
    end
  end

  describe "the plan's own numbers" do
    test "plan.before is exactly what load_runs/3 reported", %{world: world} do
      plan = suggest(world, :uncovered_only)

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert plan.before == runs_day.derived.stats
    end

    test "plan.fingerprint is exactly load_runs/3's fingerprint", %{world: world} do
      plan = suggest(world, :uncovered_only)

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      # This is the value apply re-checks under the lock, so it must be the one
      # the page is looking at, not a fresh one computed here.
      assert plan.fingerprint == runs_day.fingerprint
    end

    test "plan.after is the figures an apply actually produces", %{world: world} do
      plan = suggest(world, :uncovered_only)

      moves = Enum.map(plan.moves, &%{trip_id: &1.trip_id, from: &1.from, to: &1.to})

      {:ok, _} =
        Gtfs.apply_run_moves(world.organization.id, world.version.id, world.day_type_key, moves)

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.derived.stats == plan.after
    end

    test "plan.after is also what plan.preview reports", %{world: world} do
      plan = suggest(world, :uncovered_only)

      assert plan.after == plan.preview.stats
    end

    test "before and after differ on a day with uncovered work", %{world: world} do
      plan = suggest(world, :uncovered_only)

      # If they were equal the preview would be showing nothing.
      refute plan.before == plan.after
      assert plan.after.uncovered.trips == 0
      assert plan.before.uncovered.trips == 2
    end

    test "the orphan notice is carried into the after figures", %{world: world} do
      # An orphan is not removed by an apply, so a preview that dropped the
      # notice would disagree with the day an apply produces. This is the case
      # that keeps `after` honest.
      [unassigned | _] = world.blocks["102"]

      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: unassigned,
        day_type_key: "deleted-day-type",
        run_id: "7777"
      })

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.orphans.count == 1

      plan = suggest(world, :uncovered_only)

      assert plan.after.problems.notices == runs_day.derived.stats.problems.notices

      assert Enum.count(plan.preview.findings, &(&1.severity == :notice)) ==
               plan.after.problems.notices
    end

    test "changed_run_ids names every run the plan touches, on both sides", %{world: world} do
      plan = suggest(world, :replace_all)

      assert plan.changed_run_ids != []
      assert Enum.sort(plan.changed_run_ids) == plan.changed_run_ids
      # "1001" is a run today and is emptied by a rebuild, so it is changed
      # although no move has it as a `to`.
      assert "1001" in plan.changed_run_ids
    end

    test "the plan carries the day type key and the scope it was asked for", %{world: world} do
      assert suggest(world, :replace_all).day_type_key == world.day_type_key
      assert suggest(world, :replace_all).scope == :replace_all
      assert suggest(world, :uncovered_only).scope == :uncovered_only
    end
  end

  describe "refusals" do
    test "another organization's version is not found", %{world: world} do
      theirs = runs_version_fixture()

      assert {:error, :not_found} =
               Gtfs.suggest_runs(
                 world.organization.id,
                 theirs.version.id,
                 theirs.day_type_key,
                 :uncovered_only
               )
    end

    test "an unknown day type key is refused", %{world: world} do
      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.suggest_runs(world.organization.id, world.version.id, "nope", :uncovered_only)

      assert Enum.map(day_types, & &1.key) == [world.day_type_key]
    end
  end
end
