defmodule GtfsPlanner.Gtfs.Runs.RenameRunTest do
  @moduledoc """
  A rename moves every trip of one run, refuses the IDs it must, and undoes
  through the same optimistic per-trip rule as any other write.

  The failure is a write that clobbers someone else's change. A rename is the one
  write that touches a whole run rather than the trips a planner dragged, so it is
  where an over-broad `UPDATE` does the most damage: every trip of the run at
  once, including a trip somebody else moved since the page loaded. The scoping
  cases here are built so a missing scope column would be *visible* — another day
  type holding the same old ID, and a day type holding the same new ID, which is
  the case a uniqueness check written against the wrong scope would refuse.

  Rows are re-read, which is why the assertions read `trip_runs` directly and
  through `load_runs/3`, never the rename's own return value for the rows it
  claims to have moved.

  Every case goes through the `Gtfs` facade, the path the page calls.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/rename_run_test.exs`.
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

    # Block 101's four trips on "1006", and block 102's two on "2006" — a second
    # run in the same day type, so a rename to it is a real collision.
    for trip <- world.blocks["101"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1006"
      })
    end

    for trip <- world.blocks["102"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "2006"
      })
    end

    %{world: world}
  end

  defp rows_for(world, run_id) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^world.organization.id and
            row.gtfs_version_id == ^world.version.id and
            row.day_type_key == ^world.day_type_key and
            row.run_id == ^run_id,
        select: row.trip_id,
        order_by: [asc: row.trip_id]
      )
    )
  end

  defp all_rows(world) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^world.organization.id and
            row.gtfs_version_id == ^world.version.id and
            row.day_type_key == ^world.day_type_key,
        select: {row.trip_id, row.run_id}
      )
    )
    |> Map.new()
  end

  describe "rename_run/5" do
    test "renaming 1006 to 2006-style new ID moves every trip and leaves none behind", %{
      world: world
    } do
      assert {:ok, %{undo: undo}} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "3006"
               )

      moved = Enum.sort(world.blocks["101"] |> Enum.map(& &1.id))
      assert rows_for(world, "3006") == moved
      assert rows_for(world, "1006") == []

      # The other run in the same day type did not move.
      assert rows_for(world, "2006") == Enum.sort(world.blocks["102"] |> Enum.map(& &1.id))

      # The undo is one move per trip, from the new ID back to the old.
      assert undo == Enum.map(moved, &%{trip_id: &1, from: "3006", to: "1006"})
    end

    test "the renamed run is re-derived by the day read, not by the rename", %{world: world} do
      assert {:ok, _} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "3006"
               )

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert Enum.sort(Enum.map(runs_day.derived.runs, & &1.run_id)) == ["2006", "3006"]
    end

    test "the returned undo applied through apply_moves/4 restores the old ID", %{world: world} do
      before = all_rows(world)

      assert {:ok, %{undo: undo}} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "3006"
               )

      refute all_rows(world) == before

      assert {:ok, _} =
               Gtfs.apply_run_moves(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 undo
               )

      assert all_rows(world) == before
    end

    test "the undo is refused when one of its trips changed since", %{world: world} do
      [moved_trip | _] = world.blocks["101"]

      {:ok, %{undo: undo}} =
        Gtfs.rename_run(
          world.organization.id,
          world.version.id,
          world.day_type_key,
          "1006",
          "3006"
        )

      # Somebody else moves one of the renamed trips after the undo was handed out.
      {:ok, _} =
        Gtfs.apply_run_moves(world.organization.id, world.version.id, world.day_type_key, [
          %{trip_id: moved_trip.id, from: "3006", to: "4006"}
        ])

      after_their_write = all_rows(world)

      assert {:error, :stale_moves} =
               Gtfs.apply_run_moves(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 undo
               )

      assert all_rows(world) == after_their_write
    end
  end

  describe "refusals" do
    test "renaming to an ID already used in the day type is a run_id changeset error", %{
      world: world
    } do
      before = all_rows(world)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "2006"
               )

      assert changeset.valid? == false
      assert {"is already used in this day type", _} = changeset.errors[:run_id]

      # Nothing moved, not even the run being renamed.
      assert all_rows(world) == before
      assert rows_for(world, "1006") != []
    end

    test "a nine-character ID is the format error and writes nothing", %{world: world} do
      before = all_rows(world)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "ABCDEFGHI"
               )

      assert changeset.valid? == false
      assert {"must be one to eight letters, digits or hyphens", _} = changeset.errors[:run_id]
      assert all_rows(world) == before
    end

    test "an ID with a space is the format error", %{world: world} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "1 2"
               )

      assert {"must be one to eight letters, digits or hyphens", _} = changeset.errors[:run_id]
    end

    test "an old ID with no rows is :unknown_run", %{world: world} do
      before = all_rows(world)

      assert {:error, :unknown_run} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "9999",
                 "3006"
               )

      assert all_rows(world) == before
    end

    test "existence is checked before uniqueness, so a missing run wins", %{world: world} do
      # "2006" is taken AND "9999" does not exist. "This run does not exist" is
      # the more useful answer: there is nothing to rename.
      assert {:error, :unknown_run} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "9999",
                 "2006"
               )
    end

    test "renaming a run to its own ID is a no-op, not a duplicate", %{world: world} do
      before = all_rows(world)

      assert {:ok, _} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "1006"
               )

      assert all_rows(world) == before
    end

    test "a foreign organization's version is not found and writes nothing", %{world: world} do
      theirs = runs_version_fixture()

      for trip <- theirs.blocks["101"] do
        trip_run_fixture(theirs.organization.id, theirs.version.id, %{
          trip: trip,
          day_type_key: theirs.day_type_key,
          run_id: "1006"
        })
      end

      before = all_rows(theirs)

      assert {:error, :not_found} =
               Gtfs.rename_run(
                 world.organization.id,
                 theirs.version.id,
                 theirs.day_type_key,
                 "1006",
                 "3006"
               )

      assert all_rows(theirs) == before
    end

    test "an unpublished version is not found and writes nothing", %{world: world} do
      world.version
      |> Ecto.Changeset.change(publication_status: "staging", published_at: nil)
      |> GtfsPlanner.Repo.update!()

      before = all_rows(world)

      assert {:error, :not_found} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "3006"
               )

      assert all_rows(world) == before
    end
  end

  describe "day type scoping" do
    setup %{world: world} do
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

      # The same old ID on the other day type. A rename whose UPDATE forgot the
      # day type key would move these too, and they are the only rows carrying
      # "1006" there.
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: saturday,
        day_type_key: saturday_key,
        run_id: "1006"
      })

      %{saturday: saturday, saturday_key: saturday_key}
    end

    test "Saturday's run with the same old ID is untouched", %{
      world: world,
      saturday: saturday,
      saturday_key: saturday_key
    } do
      assert {:ok, _} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "1006",
                 "3006"
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

      assert saturday_rows == [{saturday.id, "1006"}]
    end

    test "an ID used only on Saturday is free on Weekday", %{
      world: world,
      saturday_key: saturday_key
    } do
      # A second Saturday-only run, so there is an ID the organization uses that
      # this day type does not. A uniqueness check scoped to the organization
      # rather than to the day type would wrongly refuse it.
      other =
        blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
          trip_id: "saturday_other",
          service_id: "SAT",
          block_id: "102"
        })

      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: other,
        day_type_key: saturday_key,
        run_id: "5000"
      })

      assert {:ok, _} =
               Gtfs.rename_run(
                 world.organization.id,
                 world.version.id,
                 world.day_type_key,
                 "2006",
                 "5000"
               )

      assert rows_for(world, "5000") == Enum.sort(world.blocks["102"] |> Enum.map(& &1.id))
      assert rows_for(world, "2006") == []
    end
  end
end
