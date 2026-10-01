defmodule GtfsPlanner.Gtfs.Rosters.LoadRosterTest do
  @moduledoc """
  The roster read composes one published version's day types, derived runs,
  stored rules and lines into the one roster the page and the export share.

  Every case goes through the `Gtfs` facade, which resolves the production
  `CatalogReadAdapter.Repo` with no override, so the new adapter callback and
  its Repo implementation are on the path being tested rather than bypassed. The
  facade answer is compared with `Rosters.load_roster/2` itself in the happy path,
  so the adapter cannot translate a result of its own.

  The day is `RunsFixtures.runs_version_fixture/1` with block 101 on run `2001`
  and block 102 on run `2002`: a published version whose one calendar service
  runs Monday to Friday, so its single day type is the base of ISO weekdays 1 to
  5. Run `2001` derives a sign-on at 02:09 (a garage pull-out before the 05:50
  first departure), a sign-off at 13:52 and 42,180 paid seconds — 11 h 42 min.
  Those are the derived times, read back here from `Runs.load_runs/3` as well as
  compared with the literals, because "the roster shows the run's own work times"
  is only meaningful against the same derivation the Runs page reads (INV-11).

  The lines are inserted through `Repo.insert/1` of the schemas rather than
  through a writer: `Rosters.create_line/2` and the slot writers arrive in steps
  12 to 15. The stored run times come from the derived run itself, which is what
  a writer will store, so the fresh slot is fresh for the same reason a written
  one would be.

  Staleness is proved both ways on the same line: renaming `2001` removes the run
  the slot names (`{:stale, :run_removed}`), and moving its last trip to `2002`
  leaves the run in place with an earlier sign-off (`{:stale, :run_changed}`).
  A stale slot is still a working day but is left out of weekly paid, which the
  cases assert too.

  `async: false`, deliberately. The `:unavailable` case replaces the
  application environment's catalog read adapter, which is global, so an async
  test would swap it under the other tests running beside it; the swap is put
  back in `on_exit/1`.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/load_roster_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Rosters
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.TripRun

  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  # Monday, and the day type every line slot below names.
  @monday 1

  # The derived work of run 2001 with block 101 on it: a garage pull-out before
  # 05:50, a sign-off after the 10:30 last arrival, and the paid time between.
  @run_2001 %{sign_on_secs: 7_740, sign_off_secs: 49_920, paid_secs: 42_180}

  setup do
    world = runs_version_fixture()
    assign_runs(world)

    %{world: world}
  end

  # One run per block, so a run that keeps its ID and loses its last trip is
  # observable: the derivation follows the stored assignments, not the blocks.
  defp assign_runs(world) do
    for {block_id, run_id} <- [{"101", "2001"}, {"102", "2002"}],
        trip <- world.blocks[block_id] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: run_id
      })
    end
  end

  describe "load_roster/2" do
    test "carries the day types, the runs, the rules and the composed roster", %{world: world} do
      run = derived_run(world, "2001")
      slot_line(world, run, @monday)

      assert {:ok, view} = Gtfs.load_roster(world.organization.id, world.version.id)

      assert Enum.map(view.day_types, & &1.key) == [world.day_type_key]
      assert view.settings == Rosters.get_roster_settings(world.organization.id, world.version.id)

      # The runs the roster reads are the ones the Runs page reads, not a second
      # derivation: the same run, with the same work times, under the same key.
      assert run_work(view.run_days[world.day_type_key], "2001") == run.work

      # The adapter answers with what `Rosters.load_roster/2` returns, so a
      # translation at the boundary cannot change the roster.
      assert {:ok, direct} = Rosters.load_roster(world.organization.id, world.version.id)
      assert view == direct
    end

    test "a fresh slot carries the run's work times and counts its paid time", %{world: world} do
      run = derived_run(world, "2001")
      slot_line(world, run, @monday)

      assert {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

      assert [line] = roster.lines
      assert line.line_number == 1

      slot = line.slots[@monday]
      assert slot.state == :ok
      assert slot.run_id == "2001"
      assert slot.run.work.sign_on_secs == @run_2001.sign_on_secs
      assert slot.run.work.sign_off_secs == @run_2001.sign_off_secs
      assert line.paid_secs == @run_2001.paid_secs

      # The line's whole weekly paid figure is this run's paid time, because it
      # is the line's only working day.
      assert line.paid_secs == roster.summary.weekly_paid.avg_secs
    end

    test "a renamed run leaves the slot stale and its hours uncounted", %{world: world} do
      run = derived_run(world, "2001")
      slot_line(world, run, @monday)

      assert {:ok, %{undo: [_ | _]}} =
               Runs.rename_run(world.audit, world.day_type_key, "2001", "2999")

      assert {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

      [line] = roster.lines
      slot = line.slots[@monday]

      # The run the slot names is gone: the trips still run, under a new ID.
      assert slot.state == {:stale, :run_removed}
      assert slot.run == nil
      assert line.paid_secs == 0
      assert roster.summary.stale_slots == 1
    end

    test "a re-cut run leaves the slot stale with the run still there", %{world: world} do
      run = derived_run(world, "2001")
      slot_line(world, run, @monday)

      move_last_trip_to_run(world, "2001", "2002")

      assert {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

      [line] = roster.lines
      slot = line.slots[@monday]

      # The run kept its ID and signed off earlier, because its last trip moved
      # to the other run. That is the drift a slot cannot be trusted through.
      assert slot.state == {:stale, :run_changed}
      assert slot.run.run_id == "2001"
      assert slot.run.work.sign_off_secs == 46_680
      assert line.paid_secs == 0
      assert roster.summary.stale_slots == 1
    end

    test "another organization's version is not found and its lines are never composed", %{
      world: world
    } do
      theirs = runs_version_fixture()
      assign_runs(theirs)
      run = derived_run(theirs, "2001")
      slot_line(theirs, run, @monday)

      assert {:error, :not_found} = Gtfs.load_roster(world.organization.id, theirs.version.id)
      assert {:error, :not_found} = Gtfs.load_roster(theirs.organization.id, world.version.id)

      assert {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
      assert roster.lines == []
    end

    test "an unpublished version is not found", %{world: world} do
      :ok = stage(world)

      assert {:error, :not_found} = Gtfs.load_roster(world.organization.id, world.version.id)
    end

    test "a sibling version of the same organization keeps its own lines", %{world: world} do
      run = derived_run(world, "2001")
      slot_line(world, run, @monday)

      sibling = gtfs_version_fixture(world.organization.id)

      # The sibling's line names the day type key of this version on purpose:
      # the row's own day type is not what scopes it. Both loads must see only
      # their own version's line.
      slot_line(%{world | version: sibling}, run, @monday)

      assert {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
      assert Enum.map(roster.lines, & &1.line_number) == [1]

      assert {:ok, %{roster: sibling_roster}} =
               Gtfs.load_roster(world.organization.id, sibling.id)

      assert Enum.map(sibling_roster.lines, & &1.line_number) == [1]
    end

    test "a lost connection is unavailable rather than a version with no roster", %{world: world} do
      install_failing_adapter()

      assert {:error, :unavailable} = Gtfs.load_roster(world.organization.id, world.version.id)
    end
  end

  describe "export_roster/4" do
    test "a version with no lines has no roster to export", %{world: world} do
      {:ok, view} = Gtfs.load_roster(world.organization.id, world.version.id)

      assert Rosters.export_roster(
               world.organization.id,
               world.version.id,
               movements(world),
               view.run_days
             ) == nil
    end

    test "a version with lines exports the same roster the page reads", %{world: world} do
      run = derived_run(world, "2001")
      slot_line(world, run, @monday)

      {:ok, view} = Gtfs.load_roster(world.organization.id, world.version.id)

      assert Rosters.export_roster(
               world.organization.id,
               world.version.id,
               movements(world),
               view.run_days
             ) == view.roster
    end
  end

  # The version's movements, the same result `load_roster/2` derives its runs
  # from, handed to `export_roster/4` the way `Export.movement_rows/2` will.
  defp movements(world),
    do: Blocking.export_movements(world.organization.id, world.version.id)

  # Run `2001` as the Runs page derives it, so a stored slot carries the times a
  # writer would store for it rather than times invented by the test.
  defp derived_run(world, run_id) do
    {:ok, {:ok, day}} =
      Repo.transaction(fn ->
        Runs.load_runs(world.organization.id, world.version.id, world.day_type_key)
      end)

    Enum.find(day.derived.runs, &(&1.run_id == run_id))
  end

  # A line working `run` on `weekday`, stored with the run's own sign-on and
  # sign-off — exactly what `Rosters.set_slot/5` will write in step 14.
  defp slot_line(world, run, weekday) do
    {:ok, line} =
      %RosterLine{
        organization_id: world.organization.id,
        gtfs_version_id: world.version.id,
        line_number: 1
      }
      |> Ecto.Changeset.change(%{})
      |> RosterLine.changeset(%{})
      |> Repo.insert()

    {:ok, _day} =
      %RosterLineDay{
        roster_line_id: line.id,
        organization_id: world.organization.id,
        gtfs_version_id: world.version.id,
        weekday: weekday,
        day_type_key: world.day_type_key
      }
      |> RosterLineDay.changeset(%{
        run_id: run.run_id,
        run_sign_on_secs: run.work.sign_on_secs,
        run_sign_off_secs: run.work.sign_off_secs
      })
      |> Repo.insert()

    line
  end

  # The run keeps its ID and loses its last trip, which is what a re-cut does to
  # a run's work time: the trip's `trip_runs` row is re-pointed at `to_run_id`,
  # the same move a planner makes, and the derivation follows it.
  defp move_last_trip_to_run(world, from_run_id, to_run_id) do
    run = derived_run(world, from_run_id)
    trip = run.pieces |> hd() |> Map.get(:trips) |> List.last()

    Repo.delete_all(
      from(t in TripRun,
        where:
          t.organization_id == ^world.organization.id and t.gtfs_version_id == ^world.version.id and
            t.day_type_key == ^world.day_type_key and t.trip_id == ^trip.id
      )
    )

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: trip,
      day_type_key: world.day_type_key,
      run_id: to_run_id
    })
  end

  defp run_work(day_type, run_id) do
    day_type.runs |> Enum.find(&(&1.run_id == run_id)) |> Map.get(:work)
  end

  # The version as a draft: a staging version is refused by every roster read
  # and writer, the same as a version of another organization.
  defp stage(world) do
    {1, _} =
      Repo.update_all(
        from(v in GtfsPlanner.Versions.GtfsVersion, where: v.id == ^world.version.id),
        set: [publication_status: "staging", published_at: nil]
      )

    :ok
  end

  # Replaces the production adapter with one that refuses the roster read, and
  # puts the previous value back on exit. The application environment is
  # global, so a test that left the mock installed would break every other test
  # running beside it.
  defp install_failing_adapter do
    previous = Application.fetch_env(:gtfs_planner, :gtfs_catalog_read_adapter)
    Application.put_env(:gtfs_planner, :gtfs_catalog_read_adapter, CatalogReadAdapterMock)

    Mox.stub(CatalogReadAdapterMock, :load_roster, fn _organization_id, _version_id ->
      {:error, :unavailable}
    end)

    on_exit(fn ->
      # `:gtfs_catalog_read_adapter` has no config default — the Repo adapter is
      # the compiled-in fallback inside `Gtfs.catalog_read_adapter/0` — so
      # `fetch_env/2` answers `:error` and the restore has to DELETE the key.
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :gtfs_catalog_read_adapter, value)
        :error -> Application.delete_env(:gtfs_planner, :gtfs_catalog_read_adapter)
      end
    end)
  end
end
