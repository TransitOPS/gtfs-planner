defmodule GtfsPlanner.Gtfs.Runs.OrphansTest do
  @moduledoc """
  The cleanup deletes exactly the rows the read counted.

  A wrong cleanup is a scoping failure, so rows are seeded per orphan kind. Both
  kinds are seeded on one version, so a cleanup that handled only one of them is
  visibly half-done, and a cleanup that computed its own set rather than sharing
  the read's is caught by the count agreeing with `load_runs/3`.

  The central assertion is the agreement: the number `remove_orphans/3` returns
  is the number `load_runs/3` reported, and what is left is what it said would
  be left. A cleanup that deleted live rows, or missed an orphan kind, could not
  satisfy both at once.

  Every case goes through the `Gtfs` facade, the path the page calls.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/orphans_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.TripRun

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  setup do
    world = runs_version_fixture()

    for trip <- world.blocks["101"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1001"
      })
    end

    %{world: world, moved: hd(world.blocks["101"])}
  end

  # A trip that keeps its row but leaves the services this day type runs, which
  # is what makes that row an orphan.
  defp move_trip_to_service(trip, service_id) do
    Ecto.Query.from(t in GtfsPlanner.Gtfs.Trip, where: t.id == ^trip.id)
    |> Repo.update_all(set: [service_id: service_id])
  end

  defp all_rows(world) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^world.organization.id and
            row.gtfs_version_id == ^world.version.id,
        select: {row.id, row.trip_id, row.day_type_key, row.run_id}
      )
    )
    |> Enum.sort()
  end

  defp orphan_count(world) do
    {:ok, runs_day} = Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)
    runs_day.orphans.count
  end

  # Seeds one orphan of each kind on the same version: a trip that left the day
  # type, and a row under a key that is not a day type.
  defp seed_both_orphan_kinds(world, moved) do
    move_trip_to_service(moved, "SAT")

    [unassigned | _] = world.blocks["102"]

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: unassigned,
      day_type_key: "deleted-day-type",
      run_id: "7777"
    })
  end

  describe "remove_run_orphans/3" do
    test "both orphan kinds are deleted and the count matches the read", %{
      world: world,
      moved: moved
    } do
      seed_both_orphan_kinds(world, moved)

      # The read says what is there, and the write must agree with it.
      assert orphan_count(world) == 2

      assert {:ok, 2} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      # Nothing left that the read would call an orphan.
      assert orphan_count(world) == 0

      assert {:ok, runs_day} =
               Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      refute Enum.any?(runs_day.derived.findings, &(&1.code == :orphan_assignments))
    end

    test "the live rows remain and only the orphans go", %{world: world, moved: moved} do
      seed_both_orphan_kinds(world, moved)
      before = all_rows(world)

      assert {:ok, 2} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      after_rows = all_rows(world)

      # Three of the four live rows are untouched, byte for byte, and exactly two
      # rows are gone.
      assert length(after_rows) == length(before) - 2

      live_remaining =
        Enum.filter(before, fn {row_id, _trip, key, _run} ->
          key == world.day_type_key and row_id not in removed(before, after_rows)
        end)

      assert length(live_remaining) == 3
      assert Enum.all?(live_remaining, &Enum.member?(after_rows, &1))

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert runs_day.derived.stats.runs == 1
    end

    test "a second call returns {:ok, 0}", %{world: world, moved: moved} do
      seed_both_orphan_kinds(world, moved)

      assert {:ok, 2} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      assert {:ok, 0} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )
    end

    test "a day type with nothing to clean returns {:ok, 0} and writes nothing", %{world: world} do
      before = all_rows(world)

      assert {:ok, 0} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      assert all_rows(world) == before
    end

    test "only one kind seeded removes only that kind", %{world: world, moved: moved} do
      # A trip that left, and nothing else: the row under the deleted key is not
      # there to be counted.
      move_trip_to_service(moved, "SAT")

      assert orphan_count(world) == 1

      assert {:ok, 1} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      assert orphan_count(world) == 0
    end

    test "the stale-key row is removed from whichever day type asks", %{world: world} do
      [unassigned | _] = world.blocks["102"]

      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: unassigned,
        day_type_key: "deleted-day-type",
        run_id: "7777"
      })

      # The row's key belongs to no day type, so the weekday page is the only
      # place its count can ever surface. Removing from Saturday would leave it
      # there forever.
      assert {:ok, 1} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      assert all_rows(world) |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [world.day_type_key]
    end
  end

  describe "scoping" do
    test "another organization's orphan rows remain", %{world: world, moved: moved} do
      theirs = runs_version_fixture()
      their_moved = hd(theirs.blocks["101"])

      for trip <- theirs.blocks["101"] do
        trip_run_fixture(theirs.organization.id, theirs.version.id, %{
          trip: trip,
          day_type_key: theirs.day_type_key,
          run_id: "1001"
        })
      end

      seed_both_orphan_kinds(theirs, their_moved)
      mine_before = all_rows(world)
      theirs_before = all_rows(theirs)

      # Mine has an orphan of its own; theirs is beside it.
      move_trip_to_service(moved, "SAT")

      assert {:ok, 1} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      assert all_rows(theirs) == theirs_before
      refute all_rows(world) == mine_before
    end

    test "another organization's rows are not even counted", %{world: world} do
      theirs = runs_version_fixture()

      for trip <- theirs.blocks["101"] do
        trip_run_fixture(theirs.organization.id, theirs.version.id, %{
          trip: trip,
          day_type_key: theirs.day_type_key,
          run_id: "1001"
        })
      end

      move_trip_to_service(hd(theirs.blocks["101"]), "SAT")

      # My day type sees none of theirs.
      assert orphan_count(world) == 0

      assert {:ok, 0} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      assert orphan_count(theirs) == 1
    end

    test "a second day type's live rows remain", %{world: world} do
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

      saturday =
        blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
          trip_id: "saturday_trip",
          service_id: "SAT",
          block_id: "102"
        })

      saturday_key = DayTypes.key(["SAT"])

      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: saturday,
        day_type_key: saturday_key,
        run_id: "1001"
      })

      move_trip_to_service(hd(world.blocks["101"]), "SAT")

      assert {:ok, 1} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key
               )

      saturday_rows =
        Repo.all(
          from(row in TripRun,
            where:
              row.organization_id == ^world.organization.id and
                row.gtfs_version_id == ^world.version.id and
                row.day_type_key == ^saturday_key,
            select: {row.trip_id, row.run_id}
          )
        )

      assert saturday_rows == [{saturday.id, "1001"}]
    end

    test "a foreign organization's version is not found and writes nothing", %{world: world} do
      theirs = runs_version_fixture()
      their_moved = hd(theirs.blocks["101"])

      for trip <- theirs.blocks["101"] do
        trip_run_fixture(theirs.organization.id, theirs.version.id, %{
          trip: trip,
          day_type_key: theirs.day_type_key,
          run_id: "1001"
        })
      end

      seed_both_orphan_kinds(theirs, their_moved)
      before = all_rows(theirs)

      assert {:error, :not_found} =
               Gtfs.remove_run_orphans(
                 world.organization.id,
                 theirs.version.id,
                 theirs.day_type_key
               )

      assert all_rows(theirs) == before
    end

    test "an unknown day type key is refused and writes nothing", %{world: world, moved: moved} do
      seed_both_orphan_kinds(world, moved)
      before = all_rows(world)

      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.remove_run_orphans(world.organization.id, world.version.id, "nope")

      assert Enum.map(day_types, & &1.key) == [world.day_type_key]
      assert all_rows(world) == before
    end
  end

  # The row tuples that were in `before` and are not in `after`.
  defp removed(before, after_rows),
    do: Enum.map(before, &elem(&1, 0)) -- Enum.map(after_rows, &elem(&1, 0))
end
