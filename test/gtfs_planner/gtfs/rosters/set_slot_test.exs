defmodule GtfsPlanner.Gtfs.Rosters.SetSlotTest do
  @moduledoc """
  `set_roster_slot/5` is the slot drawer's write: it stores a run-day with the
  run's own times, replaces whatever that weekday held, reports a short rest
  instead of refusing one, and refuses a held or unknown run or a weekday with no
  base day type by name.

  Every case goes through the `Gtfs` facade, the path the Rosters page calls, so
  the delegate is on the path being tested rather than bypassed. Stored rows are
  read back from `roster_line_days` and composed state is read back through
  `Gtfs.load_roster/2`, because "the row says the run's own times" and "the slot
  is fresh" are claims about what was written, not about what was returned.

  The day is `RunsFixtures.runs_version_fixture/1` with block 101 on run `2001`
  and block 102 on run `2002`: a published version whose one calendar service
  runs Monday to Friday, so Monday to Friday share its single day type and
  Saturday has no base day type at all. Run `2001` derives a sign-on at 02:09
  and a sign-off at 13:52 (7 740 and 49 920 s); run `2002` signs on at 08:19 and
  off at 16:41 (29 940 and 60 060 s). Those figures are read back from
  `Runs.load_runs/3` as well as compared with the literals, because "the slot
  stores the run's current times" only means something against the derivation
  the writer itself reads (INV-11, INV-13).

  `2002` on Monday followed by `2001` on Tuesday leaves 29 940 + 86 400 − 60 060
  = 34 080 s of rest, which is under the 600-minute rule: the short-rest case is
  a real pair of adjacent days of this fixture rather than an invented one.

  The concurrency case runs two `Task`s over the SQL Sandbox owner's connection
  with `Sandbox.allow/3`, the arrangement this repository's other task-based
  cases use, and asserts that the run-day ends up held by exactly one line and
  that the loser is told which line won.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/set_slot_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.TripRun

  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  @monday 1
  @tuesday 2
  @wednesday 3
  @thursday 4
  @saturday 6

  # The two derived runs' own work times, which every stored slot has to carry.
  @run_2001 %{sign_on_secs: 7_740, sign_off_secs: 49_920}
  @run_2002 %{sign_on_secs: 29_940, sign_off_secs: 60_060}

  # 2002's Monday sign-off and 2001's Tuesday sign-on, which is under 600
  # minutes of rest between the two adjacent days.
  @short_rest_secs 34_080

  setup do
    world = runs_version_fixture()

    # One run per block, so a run that keeps its ID and loses its last trip stays
    # observable: the derivation follows the stored assignments, not the blocks.
    for {block_id, run_id} <- [{"101", "2001"}, {"102", "2002"}],
        trip <- world.blocks[block_id] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: run_id
      })
    end

    %{world: world}
  end

  describe "set_roster_slot/5" do
    test "stores the weekday's base day type, the run and the run's current times", %{
      world: world
    } do
      line = new_line(world)

      assert {:ok, %{short_rests: []}} =
               set(world, line, @monday, "2001")

      assert stored_day(world, line, @monday) ==
               {world.day_type_key, "2001", @run_2001.sign_on_secs, @run_2001.sign_off_secs}

      # The stored times are the run's own, not the ones the slot was set with
      # by a previous write: the composition agrees they are fresh.
      assert {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
      assert slot(roster, 1, @monday).state == :ok
      assert slot(roster, 1, @monday).run.work.sign_on_secs == @run_2001.sign_on_secs
    end

    test "setting a different run on the same day replaces the earlier row", %{world: world} do
      line = new_line(world)

      assert {:ok, %{short_rests: []}} = set(world, line, @monday, "2001")
      assert {:ok, %{short_rests: []}} = set(world, line, @monday, "2002")

      # One row for that line and weekday, carrying the new run's own times.
      assert stored_day(world, line, @monday) ==
               {world.day_type_key, "2002", @run_2002.sign_on_secs, @run_2002.sign_off_secs}

      assert day_count(world) == 1
      assert slot(load_roster(world), 1, @monday).run_id == "2002"
    end

    test "a result that creates short rest is written and reported", %{world: world} do
      line = new_line(world)

      assert {:ok, %{short_rests: []}} = set(world, line, @monday, "2002")

      # 2002 signs off at 60 060 and 2001 signs on at 7 740 the next day, which
      # leaves 34 080 s — under the 600-minute rule. A manual edit is allowed to
      # leave short rest, so the day is written and the pair is reported.
      assert {:ok, %{short_rests: [%{from: 1, to: 2, rest_secs: @short_rest_secs}]}} =
               set(world, line, @tuesday, "2001")

      roster = load_roster(world)

      assert day_count(world) == 2
      assert slot(roster, 1, @tuesday).state == :ok

      # The same pair is a finding on the composed line, so the warning the
      # drawer shows and the rests the writer returned cannot disagree (INV-15).
      finding =
        roster.lines
        |> hd()
        |> Map.fetch!(:findings)
        |> Enum.find(&(&1.code == :short_rest))

      assert finding.detail.rest_secs == @short_rest_secs
    end

    test "re-setting a re-cut run stores the new times and the slot is fresh again", %{
      world: world
    } do
      line = new_line(world)

      assert {:ok, %{short_rests: []}} = set(world, line, @monday, "2002")

      # The run keeps its ID and loses its last trip, which is what a re-cut
      # does to a run's work time.
      move_last_trip_to_run(world, "2002", "2001")
      recut = derived_run(world, "2002").work

      assert slot(load_roster(world), 1, @monday).state == {:stale, :run_changed}

      assert {:ok, %{short_rests: _short_rests}} = set(world, line, @monday, "2002")

      assert stored_day(world, line, @monday) ==
               {world.day_type_key, "2002", recut.sign_on_secs, recut.sign_off_secs}

      roster = load_roster(world)
      assert slot(roster, 1, @monday).state == :ok
      assert Enum.empty?(roster.lines |> hd() |> Map.fetch!(:findings))
    end
  end

  describe "set_roster_slot/5 refusals" do
    test "a run another line holds that weekday is refused, naming the holding line", %{
      world: world
    } do
      holder = new_line(world)
      asker = new_line(world)

      assert {:ok, %{short_rests: []}} = set(world, holder, @wednesday, "2001")

      assert {:error, {:run_held, @wednesday, 1}} = set(world, asker, @wednesday, "2001")

      # Nothing was written: the holder still holds it, and the asker works no
      # day at all.
      assert day_count(world) == 1
      assert slot(load_roster(world), 2, @wednesday) == nil
    end

    test "a run that is not one of the base day type's runs is refused", %{world: world} do
      line = new_line(world)

      assert {:error, {:unknown_run, "9999"}} = set(world, line, @monday, "9999")
      assert day_count(world) == 0
    end

    test "a weekday with no base day type is refused", %{world: world} do
      line = new_line(world)

      # The fixture's one service runs Monday to Friday, so Saturday has no base
      # day type and no run-day can be placed on it.
      assert {:error, {:no_base, @saturday}} = set(world, line, @saturday, "2001")
      assert day_count(world) == 0
    end

    test "a line of another version, another organization or a malformed id is not found", %{
      world: world
    } do
      new_line(world)

      theirs = runs_version_fixture()
      their_line = new_line(theirs)

      sibling = gtfs_version_fixture(world.organization.id)

      for bad_line <- [their_line.id, "not-a-uuid", 42, nil, Ecto.UUID.generate()] do
        assert {:error, :not_found} =
                 Gtfs.set_roster_slot(
                   world.organization.id,
                   world.version.id,
                   bad_line,
                   @monday,
                   "2001"
                 )
      end

      # The other version's own line still holds its own run-day, and neither
      # organization gained a row in the other.
      assert day_count(world) == 0
      assert day_count(theirs) == 0

      assert {:ok, %{line_number: 1, id: sibling_line}} =
               Gtfs.create_roster_line(world.organization.id, sibling.id)

      assert {:error, :not_found} =
               Gtfs.set_roster_slot(
                 world.organization.id,
                 world.version.id,
                 sibling_line,
                 @monday,
                 "2001"
               )

      assert day_count(%{world | version: sibling}) == 0
    end

    test "an unpublished version is not found and no day is written", %{world: world} do
      line = new_line(world)
      :ok = stage(world)

      assert {:error, :not_found} = set(world, line, @monday, "2001")
      assert day_count(world) == 0
    end
  end

  describe "two writers at once" do
    test "the same run-day on two lines leaves one holder and one named refusal", %{world: world} do
      first = new_line(world)
      second = new_line(world)
      parent = self()

      # Both writers run the real writer on the real facade, over the sandbox
      # owner's connection, and neither sees the other's half-finished work
      # before it decides.
      results =
        [first, second]
        |> Enum.map(fn line ->
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())
            Gtfs.set_roster_slot(world.organization.id, world.version.id, line, @thursday, "2001")
          end)
        end)
        |> Enum.map(&Task.await(&1, 30_000))

      {ok, refused} = Enum.split_with(results, &match?({:ok, _}, &1))

      assert [{:ok, %{short_rests: []}}] = ok

      # The loser is told which line won rather than being left to guess, and the
      # run-day is held by exactly one row (AC-13).
      assert [{:error, {:run_held, @thursday, holder_line}}] = refused
      assert holder_line in [1, 2]
      assert day_count(world) == 1

      assert stored_day(world, line_id_of(world, holder_line), @thursday) ==
               {world.day_type_key, "2001", @run_2001.sign_on_secs, @run_2001.sign_off_secs}

      # The other line worked no day at all, which is what "one line per
      # run-day" means from the composition the page draws.
      assert slot(load_roster(world), 3 - holder_line, @thursday) == nil
    end
  end

  # The id the version's line numbered `line_number` was given, read back from the
  # table rather than from a writer's answer.
  defp line_id_of(world, line_number) do
    Repo.one!(
      from(l in RosterLine,
        where:
          l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id and l.line_number == ^line_number,
        select: l.id
      )
    )
  end

  defp new_line(world) do
    assert {:ok, %{id: id, line_number: number}} =
             Gtfs.create_roster_line(world.organization.id, world.version.id)

    %{id: id, line_number: number}
  end

  defp set(world, line, weekday, run_id),
    do: Gtfs.set_roster_slot(world.organization.id, world.version.id, line.id, weekday, run_id)

  defp load_roster(world) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
    roster
  end

  defp slot(roster, line_number, weekday) do
    roster.lines
    |> Enum.find(&(&1.line_number == line_number))
    |> Map.get(:slots)
    |> Map.get(weekday)
  end

  # The stored row, read back as the four values the writer had to get right.
  defp stored_day(world, line, weekday) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.roster_line_id == ^line.id and d.weekday == ^weekday and
            d.organization_id == ^world.organization.id and
            d.gtfs_version_id == ^world.version.id,
        select: {d.day_type_key, d.run_id, d.run_sign_on_secs, d.run_sign_off_secs}
      )
    )
  end

  # Counted directly, so "a refusal wrote nothing" is observed where the refusal's
  # effect would be rather than through the composition alone.
  defp day_count(world) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.organization_id == ^world.organization.id and d.gtfs_version_id == ^world.version.id,
        select: count(d.id)
      )
    )
  end

  # Run `run_id` as the Runs page derives it, so the times this test compares a
  # stored row against are the times the writer would have stored.
  defp derived_run(world, run_id) do
    {:ok, {:ok, day}} =
      Repo.transaction(fn ->
        Runs.load_runs(world.organization.id, world.version.id, world.day_type_key)
      end)

    Enum.find(day.derived.runs, &(&1.run_id == run_id))
  end

  # The run keeps its ID and loses its last trip: the trip's `trip_runs` row is
  # re-pointed at `to_run_id`, the same move a planner makes.
  defp move_last_trip_to_run(world, from_run_id, to_run_id) do
    trip =
      world
      |> derived_run(from_run_id)
      |> Map.fetch!(:pieces)
      |> hd()
      |> Map.fetch!(:trips)
      |> List.last()

    Repo.delete_all(
      from(t in TripRun,
        where:
          t.organization_id == ^world.organization.id and
            t.gtfs_version_id == ^world.version.id and
            t.day_type_key == ^world.day_type_key and t.trip_id == ^trip.id
      )
    )

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: trip,
      day_type_key: world.day_type_key,
      run_id: to_run_id
    })
  end

  # The version as a draft: every roster writer refuses an unpublished version,
  # the same as a version of another organization.
  defp stage(world) do
    {1, _} =
      Repo.update_all(
        from(v in GtfsPlanner.Versions.GtfsVersion, where: v.id == ^world.version.id),
        set: [publication_status: "staging", published_at: nil]
      )

    :ok
  end
end
