defmodule GtfsPlanner.Gtfs.Rosters.LineWritesTest do
  @moduledoc """
  The three line writers — "Add line", "clear day" and "delete line" — number,
  clear and remove exactly what they say, scope every id to the caller's
  organization and version, and write nothing when they refuse.

  Every case goes through the `Gtfs` facade, the path the Rosters page calls, so
  the delegates are on the path being tested rather than bypassed.

  The day is `RunsFixtures.runs_version_fixture/1` with block 101 on run `2001`
  and block 102 on run `2002`: a published version whose one calendar service
  runs Monday to Friday, so Monday's base day type is the fixture's own key and
  both runs are available to place. The slots themselves are inserted through
  `Repo.insert/1` of the schemas, because `Rosters.set_slot/5` arrives in step 13
  — the rows here are what a step-13 writer would have written, with the derived
  run's own sign-on and sign-off, so a stale-slot state cannot be mistaken for a
  clear that failed.

  "Open work" is asserted through `Gtfs.load_roster/2` rather than by counting
  rows: a cleared day and a deleted line have to give their runs back to the
  composition the page draws, and that is the only place open work exists
  (INV-15).

  Scoping is asserted in both directions and with a malformed id, because a
  `term()` id is only safe if all three refusals are `:not_found` and none of
  them writes.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/line_writes_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  # Monday, and Tuesday: two weekdays of the fixture's single base day type.
  @monday 1
  @tuesday 2

  setup do
    %{world: assign_runs(runs_version_fixture())}
  end

  # One run per block, so a run that keeps its ID and loses its last trip stays
  # observable; the derivation follows the stored assignments, not the blocks.
  # A second world built by a case — the other organization of the scoping cases
  # — needs the same assignment, or it derives no runs at all and every write
  # against it is refused as an unknown run.
  defp assign_runs(world) do
    for {block_id, run_id} <- [{"101", "2001"}, {"102", "2002"}],
        trip <- world.blocks[block_id] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: run_id
      })
    end

    world
  end

  describe "create_roster_line/2" do
    test "a version with no line gets line 1", %{world: world} do
      assert {:ok, %{line_number: 1, id: line_id}} =
               Gtfs.create_roster_line(world.organization.id, world.version.id)

      assert line_id == line_id(world, 1)
    end

    test "each new line is one above the highest, and a gap is not reused", %{world: world} do
      ids =
        for expected <- [1, 2, 3] do
          assert {:ok, %{line_number: ^expected, id: id}} =
                   Gtfs.create_roster_line(world.organization.id, world.version.id)

          id
        end

      assert {:ok, %{line_number: 2}} =
               Gtfs.delete_roster_line(world.organization.id, world.version.id, Enum.at(ids, 1))

      # Deleting line 2 leaves lines 1 and 3. Numbering follows the lines that
      # exist, so the next line is 4 rather than 2: a number a planner has seen
      # is never handed to a different line.
      assert {:ok, %{line_number: 4}} =
               Gtfs.create_roster_line(world.organization.id, world.version.id)

      assert line_numbers(world) == [1, 3, 4]
    end

    test "a sibling version of the same organization numbers from its own lines", %{world: world} do
      assert {:ok, %{line_number: 1}} =
               Gtfs.create_roster_line(world.organization.id, world.version.id)

      assert {:ok, %{line_number: 2}} =
               Gtfs.create_roster_line(world.organization.id, world.version.id)

      sibling = gtfs_version_fixture(world.organization.id)

      # The sibling's own first line is 1 even though the organization holds
      # higher lines elsewhere: numbering is per version.
      assert {:ok, %{line_number: 1}} = Gtfs.create_roster_line(world.organization.id, sibling.id)
    end

    test "an unpublished version is not found and no line is written", %{world: world} do
      :ok = stage(world)

      assert {:error, :not_found} =
               Gtfs.create_roster_line(world.organization.id, world.version.id)

      assert line_numbers(world) == []
    end
  end

  describe "clear_roster_slot/4" do
    test "clearing a day removes the row and returns the run to open work", %{world: world} do
      line = working_line(world, "2001", @monday)

      # While the slot holds the run, Monday has one open run-day of two.
      assert {:ok, %{roster: before}} = Gtfs.load_roster(world.organization.id, world.version.id)
      assert before.summary.open_by_weekday[@monday] == 1

      assert {:ok, :cleared} =
               Gtfs.clear_roster_slot(world.organization.id, world.version.id, line.id, @monday)

      assert {:ok, %{roster: after_roster}} =
               Gtfs.load_roster(world.organization.id, world.version.id)

      assert after_roster.summary.open_by_weekday[@monday] == 2

      # The run is open again by name, not only by count: the composition is what
      # the page's open-work list reads.
      [group] = after_roster.groups
      open = Enum.find(group.open_runs, &(&1.run_id == "2001"))
      assert @monday in open.open_weekdays

      # The line itself is untouched — clearing a day is not deleting a line.
      assert Enum.map(after_roster.lines, & &1.line_number) == [1]
      assert map_size(after_roster.lines |> hd() |> Map.fetch!(:slots)) == 0
    end

    test "clearing a day that already holds nothing is already off", %{world: world} do
      line = working_line(world, "2001", @monday)

      assert {:ok, :already_off} =
               Gtfs.clear_roster_slot(world.organization.id, world.version.id, line.id, @tuesday)

      # The already-off answer is the state reached, not a refusal: the Monday row
      # is still there and the version still has one line.
      assert {:ok, :cleared} =
               Gtfs.clear_roster_slot(world.organization.id, world.version.id, line.id, @monday)

      assert line_numbers(world) == [1]
    end

    test "an unpublished version is not found and the day stays as it was", %{world: world} do
      line = working_line(world, "2001", @monday)
      :ok = stage(world)

      assert {:error, :not_found} =
               Gtfs.clear_roster_slot(world.organization.id, world.version.id, line.id, @monday)

      assert day_count(world) == 1
    end
  end

  describe "delete_roster_line/3" do
    test "deleting a line removes its days, its pick and returns its runs to open work", %{
      world: world
    } do
      line = working_line(world, "2001", @monday)
      operator = operator_fixture(world)

      {1, nil} =
        Repo.update_all(from(l in RosterLine, where: l.id == ^line.id),
          set: [operator_id: operator.id]
        )

      assert {:ok, %{line_number: 1, run_days: 1}} =
               Gtfs.delete_roster_line(world.organization.id, world.version.id, line.id)

      assert line_numbers(world) == []
      assert day_count(world) == 0

      # The pick went with the row: the operator holds no line in this version,
      # so it can be given another.
      assert held_line_numbers(world, operator.id) == []

      # Both runs are open on every weekday of the group again, which is what
      # deleting a line has to restore.
      {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
      assert roster.summary.open_by_weekday[@monday] == 2
      assert roster.summary.run_days_in_lines == 0
    end

    test "a line with no days reports zero run-days", %{world: world} do
      assert {:ok, line} = Gtfs.create_roster_line(world.organization.id, world.version.id)

      assert {:ok, %{line_number: 1, run_days: 0}} =
               Gtfs.delete_roster_line(world.organization.id, world.version.id, line.id)
    end

    test "an unpublished version is not found and the line stays", %{world: world} do
      line = working_line(world, "2001", @monday)
      :ok = stage(world)

      assert {:error, :not_found} =
               Gtfs.delete_roster_line(world.organization.id, world.version.id, line.id)

      assert line_numbers(world) == [1]
      assert day_count(world) == 1
    end
  end

  describe "line id scoping" do
    test "a line of another version is not found and nothing is written", %{world: world} do
      working_line(world, "2001", @monday)
      sibling = gtfs_version_fixture(world.organization.id)

      # The sibling has no calendars of its own, so it derives no runs; the slot
      # it holds only has to exist under a foreign version for these refusals.
      # Its times come from the run the caller's own version derives.
      other_line = line_with_run(world, sibling, derived_run(world, "2001"), @monday)

      # The row exists, under the right shape and the caller's own organization —
      # only the version is foreign. Version scoping is the query's own work, not
      # something the row's organization can stand in for.
      assert {:error, :not_found} =
               Gtfs.clear_roster_slot(
                 world.organization.id,
                 world.version.id,
                 other_line.id,
                 @monday
               )

      assert {:error, :not_found} =
               Gtfs.delete_roster_line(world.organization.id, world.version.id, other_line.id)

      # The sibling's line is untouched, and the caller's own line still holds its
      # day: the refusals changed nothing on either side.
      assert day_count(%{world | version: sibling}) == 1
      assert day_count(world) == 1
      assert line_numbers(%{world | version: sibling}) == [1]
    end

    test "a line of another organization is not found and nothing is written", %{world: world} do
      theirs = assign_runs(runs_version_fixture())
      their_line = working_line(theirs, "2001", @monday)

      assert {:error, :not_found} =
               Gtfs.clear_roster_slot(
                 world.organization.id,
                 world.version.id,
                 their_line.id,
                 @monday
               )

      assert {:error, :not_found} =
               Gtfs.delete_roster_line(world.organization.id, world.version.id, their_line.id)

      assert day_count(theirs) == 1
      assert line_numbers(theirs) == [1]
    end

    test "a malformed line id is not found rather than a crash", %{world: world} do
      working_line(world, "2001", @monday)

      for bad_id <- ["not-a-uuid", 42, nil, ""] do
        assert {:error, :not_found} =
                 Gtfs.clear_roster_slot(world.organization.id, world.version.id, bad_id, @monday)

        assert {:error, :not_found} =
                 Gtfs.delete_roster_line(world.organization.id, world.version.id, bad_id)
      end

      assert day_count(world) == 1
      assert line_numbers(world) == [1]
    end

    test "a line that does not exist is not found and nothing is written", %{world: world} do
      missing = Ecto.UUID.generate()

      assert {:error, :not_found} =
               Gtfs.clear_roster_slot(world.organization.id, world.version.id, missing, @monday)

      assert {:error, :not_found} =
               Gtfs.delete_roster_line(world.organization.id, world.version.id, missing)

      assert line_numbers(world) == []
    end
  end

  # A line working `run_id` on `weekday`, stored with the derived run's own
  # sign-on and sign-off — exactly what `Rosters.set_slot/5` will write in
  # step 13. It goes through `create_roster_line/2` so the line it returns is one
  # a writer numbered, not a row the test invented.
  defp working_line(world, run_id, weekday) do
    line_with_run(world, world.version, derived_run(world, run_id), weekday)
  end

  # A line of `version` working `run` on `weekday`, stored with that run's own
  # sign-on and sign-off. `world` supplies the organization, the day-type key and
  # the run; `version` is where the line goes, which is what lets a case put one
  # under a sibling version the world itself never derived a run for.
  defp line_with_run(world, version, run, weekday) do
    {:ok, %{id: id}} = Gtfs.create_roster_line(world.organization.id, version.id)

    {:ok, _day} =
      %RosterLineDay{
        roster_line_id: id,
        organization_id: world.organization.id,
        gtfs_version_id: version.id,
        weekday: weekday,
        day_type_key: world.day_type_key
      }
      |> RosterLineDay.changeset(%{
        run_id: run.run_id,
        run_sign_on_secs: run.work.sign_on_secs,
        run_sign_off_secs: run.work.sign_off_secs
      })
      |> Repo.insert()

    %{id: id}
  end

  # Run `run_id` as the Runs page derives it, so a stored slot carries the times
  # a writer would store for it rather than times invented by the test.
  defp derived_run(world, run_id) do
    {:ok, {:ok, day}} =
      Repo.transaction(fn ->
        Runs.load_runs(world.organization.id, world.version.id, world.day_type_key)
      end)

    Enum.find(day.derived.runs, &(&1.run_id == run_id))
  end

  # The line id the version's line numbered `line_number` was given, read back
  # from the table rather than from the writer's answer.
  defp line_id(world, line_number) do
    Repo.one!(
      from(l in RosterLine,
        where:
          l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id and l.line_number == ^line_number,
        select: l.id
      )
    )
  end

  defp line_numbers(world) do
    Repo.all(
      from(l in RosterLine,
        where:
          l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id,
        select: l.line_number,
        order_by: l.line_number
      )
    )
  end

  defp held_line_numbers(world, operator_id) do
    Repo.all(
      from(l in RosterLine,
        where:
          l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id and l.operator_id == ^operator_id,
        select: l.line_number,
        order_by: l.line_number
      )
    )
  end

  # Both tables, counted directly, so "nothing was written" is observed where the
  # refusal's effect would be rather than through the composition alone.
  defp day_count(world) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.organization_id == ^world.organization.id and
            d.gtfs_version_id == ^world.version.id,
        select: count(d.id)
      )
    )
  end

  # An operator of the world's own organization, inserted through the schema's
  # changeset. `Operations` writers arrive in steps 18 and 19; this row only has
  # to exist for the pick and the line's unique-per-operator index.
  defp operator_fixture(world) do
    Repo.insert!(
      %Operator{organization_id: world.organization.id}
      |> Operator.changeset(%{employee_id: "E-1", display_name: "Sam Okafor"})
    )
  end

  # The version as a draft: an unpublished version is refused by every roster
  # writer, the same as a version of another organization.
  defp stage(world) do
    {1, _} =
      Repo.update_all(
        from(v in GtfsPlanner.Versions.GtfsVersion, where: v.id == ^world.version.id),
        set: [publication_status: "staging", published_at: nil]
      )

    :ok
  end
end
