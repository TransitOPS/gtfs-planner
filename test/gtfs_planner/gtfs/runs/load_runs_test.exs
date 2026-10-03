defmodule GtfsPlanner.Gtfs.Runs.LoadRunsTest do
  @moduledoc """
  The day read returns a composed day scoped to one organization, version and day
  type.

  The failures are a run shown that does not exist, a trip shown as covered that
  is not, and one organization's rows reaching another's page. All are scoping
  failures, and two organizations and two day types are how they are tested: a
  foreign version, a Saturday row under the same trip UUIDs, and a row under a key
  that is not a day type are each built beside the day under test and must be
  absent from it.

  Every case goes through the `Gtfs` facade, which resolves the production
  `CatalogReadAdapter.Repo` with no override, so the adapter callback and its
  Repo implementation are on the path being tested rather than bypassed.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/load_runs_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Runs

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  require Ecto.Query

  @moduletag timeout: 120_000

  # Every trip of block 101 on one run, and block 102 left unassigned, so a day
  # with both a run and uncovered work is the default rather than a special case.
  defp assign_block_101(%{organization: org, version: version, day_type_key: key, blocks: blocks}) do
    for trip <- blocks["101"] do
      trip_run_fixture(org.id, version.id, %{trip: trip, day_type_key: key, run_id: "1001"})
    end
  end

  defp run_ids(runs), do: runs |> Enum.map(& &1.run_id) |> Enum.sort()

  defp assigned_trip_ids(run) do
    run.pieces |> Enum.flat_map(& &1.trips) |> Enum.map(& &1.id) |> Enum.sort()
  end

  # The trip keeps its `trip_runs` row but leaves the services the weekday day
  # type runs, which is what makes that row an orphan.
  defp move_trip_to_service(trip, service_id) do
    Ecto.Query.from(t in GtfsPlanner.Gtfs.Trip, where: t.id == ^trip.id)
    |> Repo.update_all(set: [service_id: service_id])
  end

  describe "load_runs/3" do
    setup do
      world = runs_version_fixture()
      assign_block_101(world)
      %{world: world}
    end

    test "returns runs whose pieces hold the assigned trips, through the facade", %{world: world} do
      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.derived.stats.runs == 1
      assert run_ids(runs_day.derived.runs) == ["1001"]

      [run] = runs_day.derived.runs
      assert assigned_trip_ids(run) == world.blocks["101"] |> Enum.map(& &1.id) |> Enum.sort()
      assert run.pieces != []
      assert Enum.all?(run.pieces, &(&1.run_id == "1001"))
    end

    test "carries the day, the crew rules and the assignments", %{world: world} do
      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.day.day_type.key == world.day_type_key
      assert runs_day.crew.max_spread_minutes == 720
      assert map_size(runs_day.assignments) == 4
      assert Map.values(runs_day.assignments) |> Enum.uniq() == ["1001"]
    end

    test "an unassigned sequence trip is uncovered work, not a run", %{world: world} do
      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      uncovered_ids = runs_day.derived.uncovered |> Enum.flat_map(& &1.trips) |> Enum.map(& &1.id)
      expected = world.blocks["102"] |> Enum.map(& &1.id) |> Enum.sort()

      assert Enum.sort(uncovered_ids) == expected
      assert runs_day.derived.stats.uncovered.trips == 2
      # It is reported as uncovered work rather than as a run called nil.
      assert runs_day.derived.stats.runs == 1
      assert Enum.any?(runs_day.derived.findings, &(&1.code == :uncovered_work))
    end

    test "with no assignments at all there are no runs and every trip is uncovered", %{
      world: world
    } do
      Repo.delete_all(GtfsPlanner.Gtfs.TripRun)

      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.derived.runs == []
      assert runs_day.assignments == %{}
      assert runs_day.derived.stats.uncovered.trips == 6
    end

    test "relief_ready? is true with a marked relief point and a piece limit", %{world: world} do
      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.relief_ready?
    end

    test "relief_ready? is false with no marked relief point", %{world: world} do
      {:ok, :ok} =
        Blocking.update_relief_settings(
          world.audit,
          world.day_type_key,
          %{max_piece_minutes: 330, marked: []}
        )

      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      refute runs_day.relief_ready?
    end

    test "relief_ready? is false with a marked point but no piece limit", %{world: world} do
      {:ok, :ok} =
        Blocking.update_relief_settings(
          world.audit,
          world.day_type_key,
          %{max_piece_minutes: nil, marked: [world.relief_stop_id]}
        )

      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      refute runs_day.relief_ready?
    end

    test "an unknown day-type key returns the in-band error with the day types", %{world: world} do
      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.load_runs(world.organization.id, world.version.id, "nope")

      assert Enum.map(day_types, & &1.key) == [world.day_type_key]
    end

    test "another organization's version is not found and its rows never appear" do
      mine = runs_version_fixture()
      theirs = runs_version_fixture()

      for trip <- theirs.blocks["101"] do
        trip_run_fixture(theirs.organization.id, theirs.version.id, %{
          trip: trip,
          day_type_key: theirs.day_type_key,
          run_id: "9999"
        })
      end

      assert {:error, :not_found} =
               Gtfs.load_runs(mine.organization.id, theirs.version.id, theirs.day_type_key)

      assert {:error, :not_found} =
               Gtfs.load_runs(theirs.organization.id, mine.version.id, mine.day_type_key)

      assert {:ok, runs_day} =
               Gtfs.load_runs(mine.organization.id, mine.version.id, mine.day_type_key)

      assert runs_day.derived.stats.runs == 0
      refute "9999" in run_ids(runs_day.derived.runs)
    end
  end

  describe "orphans" do
    setup do
      world = runs_version_fixture()
      # The orphans are only meaningful against a day that has runs: a day with
      # no assignments at all has nothing for a stray row to be a stray from.
      assign_block_101(world)
      %{world: world}
    end

    test "a row whose trip left the day type is counted and reaches no run or figure", %{
      world: world
    } do
      [moved | _] = world.blocks["101"]

      # The trip keeps its row, but it is moved to a service the weekday day type
      # does not run, so the row can no longer belong to a weekday run.
      move_trip_to_service(moved, "SAT")

      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.orphans == %{count: 1}
      # It is not in any run, and it is not counted as covered work either.
      refute moved.id in assigned_trip_ids(hd(runs_day.derived.runs))
      assert runs_day.derived.stats.runs == 1

      assert runs_day.assignments |> Map.keys() |> Enum.sort() ==
               (world.blocks["101"] -- [moved]) |> Enum.map(& &1.id) |> Enum.sort()

      # The moved trip is in neither the runs nor the uncovered set: it is not
      # this day's work at all any more, which is exactly why its row is an
      # orphan rather than an assignment or a gap in coverage.
      uncovered_ids = runs_day.derived.uncovered |> Enum.flat_map(& &1.trips) |> Enum.map(& &1.id)
      refute moved.id in uncovered_ids
      assert runs_day.derived.stats.uncovered.trips == 2
    end

    test "a row under a key that is no longer a day type is counted on every day type", %{
      world: world
    } do
      [first | _] = world.blocks["102"]

      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: first,
        day_type_key: "deleted-day-type",
        run_id: "7777"
      })

      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.orphans == %{count: 1}
      # It is counted, and it is not a run: its key is not this day's.
      refute "7777" in run_ids(runs_day.derived.runs)
      assert runs_day.derived.stats.runs == 1
    end

    test "the orphan notice is appended and the day's notice count recounts it", %{world: world} do
      assert {:ok, before} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert before.orphans == %{count: 0}
      refute Enum.any?(before.derived.findings, &(&1.code == :orphan_assignments))
      before_notices = before.derived.stats.problems.notices
      # The uncovered-work warning is a warning, not a notice, so the day's
      # notice count is the day's own.
      assert Enum.count(before.derived.findings, &(&1.severity == :notice)) == before_notices

      [moved | _] = world.blocks["101"]

      move_trip_to_service(moved, "SAT")

      assert {:ok, after_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert [notice] = Enum.filter(after_day.derived.findings, &(&1.code == :orphan_assignments))
      assert notice.severity == :notice
      assert notice.detail == %{count: 1}

      # The point of the recount: `Runs.Day.derive/4` counted problems before this
      # module knew about orphans, so without it the day's notice count would be
      # one short of its own findings.
      assert after_day.derived.stats.problems.notices == before_notices + 1

      assert Enum.count(after_day.derived.findings, &(&1.severity == :notice)) ==
               after_day.derived.stats.problems.notices
    end

    test "a clean day raises no orphan notice", %{world: world} do
      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.orphans == %{count: 0}
      refute Enum.any?(runs_day.derived.findings, &(&1.code == :orphan_assignments))
    end
  end

  describe "the fingerprint" do
    setup do
      world = runs_version_fixture()
      assign_block_101(world)
      %{world: world}
    end

    test "is a 64-character hex string", %{world: world} do
      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert Regex.match?(~r/^[0-9a-f]{64}$/, runs_day.fingerprint)
    end

    test "is stable across two reads of an unchanged day", %{world: world} do
      assert {:ok, first} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert {:ok, second} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert first.fingerprint == second.fingerprint
    end

    test "changes after a direct row insert, as an apply would", %{world: world} do
      assert {:ok, before} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      [first_unassigned | _] = world.blocks["102"]

      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: first_unassigned,
        day_type_key: world.day_type_key,
        run_id: "1002"
      })

      assert {:ok, after_insert} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      # Stale-plan refusal in miniature: a suggested plan was built against the
      # earlier fingerprint, and applying it now must be refused rather than
      # written.
      refute before.fingerprint == after_insert.fingerprint
    end

    test "changes when a crew rule changes", %{world: world} do
      assert {:ok, before} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      {:ok, _settings} =
        Runs.update_crew_settings(world.audit, %{
          max_spread_minutes: 600
        })

      assert {:ok, after_crew} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      refute before.fingerprint == after_crew.fingerprint
    end

    test "a foreign organization's day has a different fingerprint", %{world: world} do
      theirs = runs_version_fixture()

      assert {:ok, mine} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert {:ok, other} =
               Gtfs.load_runs(theirs.organization.id, theirs.version.id, theirs.day_type_key)

      refute mine.fingerprint == other.fingerprint
    end
  end

  # This file also holds the `count_runs_for_trips/3` cases. Both are runs reads
  # against the same fixture, and a separate file for a four-case count would only
  # split the same setup in two.
  describe "count_runs_for_trips/3" do
    setup do
      world = runs_version_fixture()

      calendar_service_fixture(world.organization.id, world.version.id, %{
        service_id: "SAT",
        name: "Saturday",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0
      })

      saturday_key = DayTypes.key(["SAT"])

      saturday_trip =
        blocked_trip_fixture(
          world.organization.id,
          world.version.id,
          world.route.route_id,
          %{trip_id: "saturday_trip", service_id: "SAT", block_id: "101"}
        )

      %{world: world, saturday_key: saturday_key, saturday_trip: saturday_trip}
    end

    test "two trips of one run count 1", %{world: world} do
      assign_block_101(world)

      # Block 101 has four trips; all four are on run 1001, and a run is counted
      # once however many of its trips the caller names.
      trip_ids = Enum.map(world.blocks["101"], & &1.id)

      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, trip_ids) == 1
    end

    test "a single trip counts its one run", %{world: world} do
      assign_block_101(world)
      [first | _] = world.blocks["101"]

      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, [first.id]) ==
               1
    end

    test "the same run ID on Weekday and on Saturday counts 2", %{
      world: world,
      saturday_key: saturday_key,
      saturday_trip: saturday_trip
    } do
      assign_block_101(world)

      # Run "1001" on both day types. A run is scoped to its day type, so these
      # are two runs that share an ID, not one run counted twice.
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: saturday_trip,
        day_type_key: saturday_key,
        run_id: "1001"
      })

      [first | _] = world.blocks["101"]

      assert Gtfs.count_runs_for_trips(
               world.organization.id,
               world.version.id,
               [first.id, saturday_trip.id]
             ) == 2

      # And each of them alone is one, which is what makes the 2 above a count
      # of two runs rather than a count of two rows.
      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, [first.id]) ==
               1

      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, [
               saturday_trip.id
             ]) == 1
    end

    test "two runs on one day type count 2", %{world: world} do
      assign_block_101(world)

      # One trip of block 101 moves to a second run on the same day type.
      [first | _rest] = world.blocks["101"]

      Ecto.Query.from(r in GtfsPlanner.Gtfs.TripRun, where: r.trip_id == ^first.id)
      |> Repo.update_all(set: [run_id: "1002"])

      trip_ids = Enum.map(world.blocks["101"], & &1.id)

      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, trip_ids) == 2
    end

    test "an empty list counts 0", %{world: world} do
      assign_block_101(world)

      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, []) == 0
    end

    test "a trip held by no run counts 0", %{world: world} do
      assign_block_101(world)

      # Block 102 is the fixture's unassigned block.
      [unassigned | _] = world.blocks["102"]

      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, [
               unassigned.id
             ]) == 0
    end

    test "a trip no run holds at all counts 0", %{world: world} do
      # A well-formed UUID that names no trip, so the 0 is the empty answer
      # rather than a cast error.
      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, [
               Ecto.UUID.generate()
             ]) == 0
    end

    test "another organization's rows count 0", %{world: world} do
      assign_block_101(world)
      theirs = runs_version_fixture()
      assign_block_101(theirs)

      trip_ids = Enum.map(world.blocks["101"], & &1.id)

      # Both worlds carry the same GTFS trip names, so this is scoping and not a
      # missing trip. The UUIDs are necessarily different - they are separate
      # Trip rows - so the names are what makes the point and the UUIDs are
      # what the function is given.
      assert Enum.map(theirs.blocks["101"], & &1.trip_id) ==
               Enum.map(world.blocks["101"], & &1.trip_id)

      refute Enum.map(theirs.blocks["101"], & &1.id) == trip_ids
      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, trip_ids) == 1
      assert Gtfs.count_runs_for_trips(theirs.organization.id, world.version.id, trip_ids) == 0
    end

    test "another version's rows count 0", %{world: world} do
      assign_block_101(world)
      other = gtfs_version_fixture(world.organization.id)
      trip_ids = Enum.map(world.blocks["101"], & &1.id)

      assert Gtfs.count_runs_for_trips(world.organization.id, other.id, trip_ids) == 0
    end

    test "an orphan row is still counted, because it is still a run", %{world: world} do
      assign_block_101(world)

      [orphan | _] = world.blocks["101"]
      move_trip_to_service(orphan, "SAT")

      # The trip left the weekday day type, so `load_runs/3` no longer reports
      # this assignment in `current`. The row is still in the table, and the
      # Blocks preview's question is about the table; excluding it here would
      # make this figure disagree with what `remove_orphans/3` would delete.
      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      refute Map.has_key?(runs_day.assignments, orphan.id)
      assert runs_day.orphans.count >= 1

      assert Gtfs.count_runs_for_trips(world.organization.id, world.version.id, [
               orphan.id
             ]) == 1
    end
  end
end
