defmodule GtfsPlanner.Gtfs.Runs.ApplyMovesTest do
  @moduledoc """
  A manual write checks every trip the editor saw, writes every move or none, and
  undoes by the same rule.

  The failure these cases guard against is a write that clobbers somebody else's
  change, or an undo that puts back a run that has since moved. The answer is
  per-trip optimism: every move names the run the editor saw, and one trip that
  has since changed fails the whole call. That is only meaningful if the check is
  *per trip*, so the tests build a day where most moves are correct and one is
  not, and assert that the correct ones were not written either.

  Rows are re-read after each call, which is why the assertions go through
  `load_runs/3` and a direct row read rather than through the return value. A
  writer that returned what it was asked for, without writing it, would pass a
  test that trusted the return.

  Every case goes through the `Gtfs` facade, the path the page calls.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/apply_moves_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.TripRun
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures, only: [trip_fixture: 4]
  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  setup do
    world = runs_version_fixture()

    # Block 101's four trips start on "1001", so a move has a real `from` to
    # name, and block 102's two start unassigned.
    for trip <- world.blocks["101"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1001"
      })
    end

    %{world: world, a: hd(world.blocks["101"]), b: Enum.at(world.blocks["101"], 1)}
  end

  defp runs_of(world) do
    {:ok, runs_day} = Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)
    runs_day.assignments
  end

  defp stored(world) do
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

  defp move(trip, from, to), do: %{trip_id: trip.id, from: from, to: to}

  describe "apply_run_moves/4 writing" do
    test "assigning, reassigning and unassigning are visible when the rows are re-read", %{
      world: world,
      a: a,
      b: b
    } do
      [unassigned | _] = world.blocks["102"]

      assert {:ok, %{changed_trips: 3}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", "2001"),
                 move(b, "1001", nil),
                 move(unassigned, nil, "3001")
               ])

      assert runs_of(world)[a.id] == "2001"
      refute Map.has_key?(runs_of(world), b.id)
      assert runs_of(world)[unassigned.id] == "3001"
      # Read from the table too, not only through the derived day.
      assert stored(world)[a.id] == "2001"
      refute Map.has_key?(stored(world), b.id)
    end

    test "an empty call changes nothing and returns no new run", %{world: world} do
      before = stored(world)

      assert {:ok, %{changed_trips: 0, new_run_id: nil, undo: []}} =
               Gtfs.apply_run_moves(
                 world.audit,
                 world.day_type_key,
                 []
               )

      assert stored(world) == before
    end

    test "a move that changes nothing reports zero changed trips", %{world: world, a: a} do
      assert {:ok, %{changed_trips: 0}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", "1001")
               ])

      assert stored(world)[a.id] == "1001"
    end

    test "two moves with to: :new create ONE run numbered above the highest", %{
      world: world,
      a: a,
      b: b
    } do
      assert {:ok, %{new_run_id: "1002", changed_trips: 2}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", :new),
                 move(b, "1001", :new)
               ])

      # One run, not two: an operator dragging two trips onto "new run" means one
      # run. Numbered above the highest in use, not above nothing.
      assert runs_of(world)[a.id] == "1002"
      assert runs_of(world)[b.id] == "1002"
      assert Map.values(runs_of(world)) |> Enum.uniq() |> Enum.sort() == ["1001", "1002"]
    end

    test "a :new with no runs in use creates run 1", %{world: world} do
      Repo.delete_all(TripRun)

      [first | _] = world.blocks["101"]

      assert {:ok, %{new_run_id: "1"}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(first, nil, :new)
               ])

      assert runs_of(world)[first.id] == "1"
    end
  end

  describe "refusals" do
    test "a from that differs from the trip's current run is stale and writes nothing", %{
      world: world,
      a: a,
      b: b
    } do
      assert {:error, :stale_moves} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(b, "1001", "2001"),
                 move(a, "WRONG", "2001")
               ])

      # Both refused. The correct move beside the stale one is not written
      # either — that is the "all or none" half, and it is the half a per-move
      # implementation would get wrong.
      assert stored(world)[a.id] == "1001"
      assert stored(world)[b.id] == "1001"
    end

    test "a from of nil is a real expectation, not an unset value", %{world: world} do
      [assigned | _] = world.blocks["101"]

      # The editor believed the trip was unassigned; it is not.
      assert {:error, :stale_moves} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(assigned, nil, "2001")
               ])

      assert stored(world)[assigned.id] == "1001"
    end

    test "a trip of another day type is invalid, and every offender is returned", %{world: world} do
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

      saturday_trip =
        blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
          trip_id: "saturday",
          service_id: "SAT",
          block_id: "101"
        })

      frequency_trip =
        trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
          trip_id: "headway",
          service_id: "WK"
        })

      frequency_row_fixture(world.organization.id, world.version.id, %{trip_id: frequency_trip.id})

      before = stored(world)

      assert {:error, {:invalid_trips, invalid}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(saturday_trip, nil, "2001"),
                 move(frequency_trip, nil, "2001")
               ])

      # Both named, not just the first, so a page can mark them all at once.
      assert Enum.sort(invalid) == Enum.sort([saturday_trip.id, frequency_trip.id])
      assert stored(world) == before
    end

    test "an unknown trip UUID is invalid rather than a crash", %{world: world} do
      assert {:error, {:invalid_trips, [missing]}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 %{trip_id: Ecto.UUID.generate(), from: nil, to: "2001"}
               ])

      assert is_binary(missing)
    end

    test "a to of \"1 2\" is an invalid run id and writes nothing", %{world: world, a: a} do
      assert {:error, {:invalid_run_id, "1 2"}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", "1 2")
               ])

      assert stored(world)[a.id] == "1001"
    end

    test "a too-long run ID is refused", %{world: world, a: a} do
      assert {:error, {:invalid_run_id, "ABCDEFGHI"}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", "ABCDEFGHI")
               ])

      assert stored(world)[a.id] == "1001"
    end

    test "another organization's version is not found and writes nothing", %{
      world: world,
      a: a
    } do
      theirs = runs_version_fixture()
      before = stored(theirs)

      assert {:error, :not_found} =
               Gtfs.apply_run_moves(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                   world.organization.id,
                   theirs.version.id
                 ),
                 theirs.day_type_key,
                 [
                   %{trip_id: a.id, from: nil, to: "2001"}
                 ]
               )

      assert stored(theirs) == before
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

      # The same run ID on the same trip UUID family, on the other day type. A
      # Weekday write must not reach it.
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: saturday,
        day_type_key: saturday_key,
        run_id: "101"
      })

      %{saturday: saturday, saturday_key: saturday_key}
    end

    test "a Weekday write leaves Saturday's rows for run \"101\" unchanged", %{
      world: world,
      a: a,
      saturday: saturday,
      saturday_key: saturday_key
    } do
      before =
        Repo.one(
          from(row in TripRun,
            where:
              row.organization_id == ^world.organization.id and
                row.gtfs_version_id == ^world.version.id and
                row.day_type_key == ^saturday_key,
            select: row.run_id
          )
        )

      assert before == "101"

      assert {:ok, %{changed_trips: 1}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", "101")
               ])

      after_row =
        Repo.one(
          from(row in TripRun,
            where:
              row.organization_id == ^world.organization.id and
                row.gtfs_version_id == ^world.version.id and
                row.day_type_key == ^saturday_key,
            select: row.run_id
          )
        )

      assert after_row == "101"
      assert runs_of(world)[a.id] == "101"

      # And the Saturday trip is not in the Weekday day at all.
      refute Map.has_key?(runs_of(world), saturday.id)
    end
  end

  describe "undo" do
    test "applying the returned undo restores exactly the previous rows", %{
      world: world,
      a: a,
      b: b
    } do
      before = stored(world)

      assert {:ok, %{undo: undo, new_run_id: "1002"}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", :new),
                 move(b, "1001", nil)
               ])

      refute stored(world) == before

      assert {:ok, _} =
               Gtfs.apply_run_moves(
                 world.audit,
                 world.day_type_key,
                 undo
               )

      # Exactly the previous rows: same keys, same values, and the trip that
      # was unassigned is unassigned again rather than left holding a run.
      assert stored(world) == before
    end

    test "undo reverses a move onto a named run too", %{world: world, a: a} do
      before = stored(world)

      assert {:ok, %{undo: undo}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", "2001")
               ])

      assert undo == [%{trip_id: a.id, from: "2001", to: "1001"}]

      assert {:ok, _} =
               Gtfs.apply_run_moves(
                 world.audit,
                 world.day_type_key,
                 undo
               )

      assert stored(world) == before
    end

    test "undo is refused once one of its trips changed, and writes nothing", %{
      world: world,
      a: a,
      b: b
    } do
      {:ok, %{undo: undo}} =
        Gtfs.apply_run_moves(world.audit, world.day_type_key, [
          move(a, "1001", "2001"),
          move(b, "1001", "2001")
        ])

      # Somebody else moves one of the two trips after the undo was handed out.
      {:ok, _} =
        Gtfs.apply_run_moves(world.audit, world.day_type_key, [
          move(a, "2001", "3001")
        ])

      after_their_write = stored(world)

      assert {:error, :stale_moves} =
               Gtfs.apply_run_moves(
                 world.audit,
                 world.day_type_key,
                 undo
               )

      # The undo would have put `a` back on 2001, clobbering the 3001 write. It is
      # refused, and `b` is not restored either — the same all-or-none rule as
      # any other move.
      assert stored(world) == after_their_write
    end

    test "undo of an unassignment restores the run", %{world: world, a: a} do
      before = stored(world)

      assert {:ok, %{undo: undo}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", nil)
               ])

      refute Map.has_key?(stored(world), a.id)

      assert {:ok, _} =
               Gtfs.apply_run_moves(
                 world.audit,
                 world.day_type_key,
                 undo
               )

      assert stored(world) == before
    end
  end

  describe "the composed day after a write" do
    test "runs are re-derived from the rows, never from the call's return", %{world: world, a: a} do
      assert {:ok, %{changed_trips: 1}} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 move(a, "1001", "2001")
               ])

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      # Two runs now exist, built by `load_runs/3` from the rows just written.
      assert runs_day.derived.stats.runs == 2
      assert Enum.sort(Enum.map(runs_day.derived.runs, & &1.run_id)) == ["1001", "2001"]
    end
  end
end
