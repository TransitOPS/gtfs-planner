defmodule GtfsPlanner.Gtfs.Rosters.SetWeekdayGroupTest do
  @moduledoc """
  `set_roster_weekday_group/4` is the "Set Mon–Fri to run N" write: one run on
  every weekday of the requested weekday's base-day group, in one transaction,
  only when `Rosters.Candidates.group_availability/4` allows it, and a refusal
  that writes no row.

  Every case goes through the `Gtfs` facade, the path the Rosters slot drawer
  calls, so the delegate is on the path being tested rather than bypassed.
  Stored rows are read back from `roster_line_days` and composed state through
  `Gtfs.load_roster/2`, because "nothing was written" and "the day carries the
  run's own times" are claims about the table, not about what was returned.

  ## The day

  `RunsFixtures.runs_version_fixture/1` with block 101 on run `2001` and block
  102 on run `2002`, so Monday to Friday share one day type and Saturday and
  Sunday have none of their own until `add_weekend/1` gives them one:

  * `2001` signs on at 02:09 and off at 13:52 (7 740 and 49 920 s). Two
    consecutive `2001` days leave `7 740 + 86 400 - 49 920 = 44 220 s`, over the
    36 000 s the 600-minute rule needs, so a whole Mon–Fri group of `2001` is
    allowed and a group of `2002` would not be the interesting case.
  * `2002` signs on at 08:19 and off at 16:41 (29 940 and 60 060 s), which is
    why "the line already works a different run on Monday" is a real difference
    rather than an invented one.
  * a Saturday-only service with one trip on run `6010` (09:00 to 17:00), which
    gives Saturday a base day type whose group is that one day — the
    `:single_day_group` case.
  * a Sunday-only service with one trip on run `7007` (22:00 to 23:30), whose
    derived sign-off is 84 900 s — after 23:00. Monday's `2001` would start
    `7 740 + 86 400 - 84 900 = 9 240 s` after it, well under 36 000 s, which is
    the Sunday-to-Monday wrap `Checks.short_rests/2` reports.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/set_weekday_group_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.TripRun

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  @monday 1
  @wednesday 3
  @saturday 6
  @sunday 7
  @weekdays [1, 2, 3, 4, 5]

  # The two weekday runs' own work times, which every stored group day carries.
  @run_2001 %{sign_on_secs: 7_740, sign_off_secs: 49_920}
  @run_2002 %{sign_on_secs: 29_940, sign_off_secs: 60_060}

  # The seconds of rest the late Sunday run and Monday's `2001` leave between
  # them, written out from the two runs' own sign-off and sign-on.
  # `Checks.rest_secs/2` is `next.sign_on + 86_400 - previous.sign_off`.
  @short_rest_secs 9_240

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

    %{world: add_weekend(world)}
  end

  describe "set_roster_weekday_group/4" do
    test "fills every weekday of the group with the run and its current times", %{world: world} do
      line = new_line(world)

      assert {:ok, %{weekdays: @weekdays}} =
               set_group(world, line, @wednesday, "2001")

      for weekday <- @weekdays do
        assert stored_day(world, line, weekday) ==
                 {world.day_type_key, "2001", @run_2001.sign_on_secs, @run_2001.sign_off_secs}
      end

      assert day_count(world) == 5

      # The composition agrees the five days are fresh, which is what storing the
      # run's own times buys (INV-13).
      roster = load_roster(world)

      for weekday <- @weekdays do
        assert slot(roster, 1, weekday).state == :ok
        assert slot(roster, 1, weekday).run.work.sign_on_secs == @run_2001.sign_on_secs
      end

      # No short rest was created, so the line carries no rest finding either:
      # consecutive `2001` days leave 44 220 s against a 36 000 s rule.
      refute Enum.any?(roster.lines |> hd() |> Map.fetch!(:findings), &(&1.code == :short_rest))
    end

    test "the same weekday group fills from any of its weekdays", %{world: world} do
      from_monday = new_line(world)
      from_friday = new_line(world)

      assert {:ok, %{weekdays: @weekdays}} = set_group(world, from_monday, @monday, "2001")
      assert {:ok, %{weekdays: @weekdays}} = set_group(world, from_friday, 5, "2002")

      # Both lines work the whole group, each with its own run, and the run-once
      # index is untouched because the runs differ.
      roster = load_roster(world)
      assert Map.keys(slots(roster, 1)) == @weekdays
      assert Enum.map(@weekdays, &slot(roster, 2, &1).run_id) == List.duplicate("2002", 5)
      assert day_count(world) == 10
    end

    test "a stale slot holding the same run is overwritten with the run's current times", %{
      world: world
    } do
      line = new_line(world)

      assert {:ok, %{short_rests: []}} = set_slot(world, line, @wednesday, "2001")

      # The run keeps its ID and loses its last trip, which is what a re-cut does
      # to a run's work time.
      move_last_trip_to_run(world, "2001", "2002")
      recut = derived_run(world, "2001").work

      assert slot(load_roster(world), 1, @wednesday).state == {:stale, :run_changed}

      # A slot holding the *same* run does not fill its day, so the group write
      # is allowed and replaces every group day, Wednesday among them.
      assert {:ok, %{weekdays: @weekdays}} = set_group(world, line, @wednesday, "2001")

      for weekday <- @weekdays do
        assert stored_day(world, line, weekday) ==
                 {world.day_type_key, "2001", recut.sign_on_secs, recut.sign_off_secs}
      end

      assert day_count(world) == 5

      roster = load_roster(world)
      assert slot(roster, 1, @wednesday).state == :ok
    end
  end

  describe "set_roster_weekday_group/4 refusals" do
    test "a run another line holds on a day of the group is refused, naming the line", %{
      world: world
    } do
      holder = new_line(world)
      asker = new_line(world)

      assert {:ok, %{short_rests: []}} = set_slot(world, holder, @wednesday, "2001")

      assert {:error, {:run_held, @wednesday, 1}} = set_group(world, asker, @wednesday, "2001")

      # Nothing was written: the asker works no day, and only the holder's own
      # row exists.
      assert day_count(world) == 1
      assert slots(load_roster(world), 2) == %{}
    end

    test "a day the line already works a different run on is refused, writing nothing", %{
      world: world
    } do
      line = new_line(world)

      assert {:ok, %{short_rests: []}} = set_slot(world, line, @monday, "2002")

      assert {:error, {:day_filled, @monday, "2002"}} =
               set_group(world, line, @monday, "2001")

      # The one day the line worked is the day it worked before the refusal:
      # no Tuesday to Friday row was added.
      assert day_count(world) == 1

      assert stored_day(world, line, @monday) ==
               {world.day_type_key, "2002", @run_2002.sign_on_secs, @run_2002.sign_off_secs}
    end

    test "a Sunday wrap the group would shorten below the minimum rest is refused", %{
      world: world
    } do
      line = new_line(world)

      # The late Sunday run is set one day at a time, which a manual edit allows:
      # on a Sunday-only line there is no adjacent working day, so nothing is
      # short and nothing is reported.
      assert {:ok, %{short_rests: []}} = set_slot(world, line, @sunday, world.sunday.run_id)

      assert {:error, {:short_rest, @sunday, @monday, @short_rest_secs, "2001"}} =
               set_group(world, line, @wednesday, "2001")

      # The builder refuses what the per-day edit would have created, so the
      # line is still a Sunday-only line.
      assert day_count(world) == 1
      assert stored_day(world, line, @sunday) |> elem(1) == world.sunday.run_id
      assert slot(load_roster(world), 1, @monday) == nil
    end

    test "a weekday whose group is one day is refused", %{world: world} do
      line = new_line(world)

      # Saturday has a base day type of its own, so the run is a real Saturday
      # run, but its group is that one day: "set the group" would set one slot
      # and imply a rule it has none of.
      assert {:error, :single_day_group} =
               set_group(world, line, @saturday, world.saturday.run_id)

      assert day_count(world) == 0
    end

    test "a run the day type does not derive is refused", %{world: world} do
      line = new_line(world)

      assert {:error, {:unknown_run, "9999"}} = set_group(world, line, @wednesday, "9999")
      assert day_count(world) == 0
    end

    test "a line of another version, another organization or a malformed id is not found", %{
      world: world
    } do
      new_line(world)
      new_line(runs_version_fixture())

      for bad_line <- ["not-a-uuid", 42, nil, Ecto.UUID.generate()] do
        assert {:error, :not_found} =
                 Gtfs.set_roster_weekday_group(
                   world_audit(world),
                   bad_line,
                   @wednesday,
                   "2001"
                 )
      end

      assert day_count(world) == 0
    end

    test "an unpublished version is not found and no day is written", %{world: world} do
      line = new_line(world)
      :ok = stage(world)

      assert {:error, :not_found} = set_group(world, line, @wednesday, "2001")
      assert day_count(world) == 0
    end
  end

  # Saturday and Sunday each get a calendar service of their own, a trip on it
  # and a `trip_runs` row, so each weekday has a base day type and a derived run
  # of its own: Saturday's group is one day and the Sunday run signs off late.
  # The services are additions, so the weekday day type's own key is unchanged.
  defp add_weekend(world) do
    world
    |> weekend_service(
      :saturday,
      "SA",
      "Saturday",
      %{saturday: 1},
      "09:00:00",
      "17:00:00",
      "6010"
    )
    |> weekend_service(:sunday, "SU", "Sunday", %{sunday: 1}, "22:00:00", "23:30:00", "7007")
  end

  defp weekend_service(world, weekday_key, service_id, name, days, from, to, run_id) do
    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: service_id,
      name: name,
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: Map.get(days, :saturday, 0),
      sunday: Map.get(days, :sunday, 0)
    })

    trip =
      blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
        trip_id: service_id,
        service_id: service_id,
        block_id: service_id,
        first_departure: from,
        last_arrival: to
      })

    key = weekend_day_type_key(world, service_id)

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: trip,
      day_type_key: key,
      run_id: run_id
    })

    Map.put(world, weekday_key, %{day_type_key: key, run_id: run_id})
  end

  # The day type of one weekend service, read from the version's own derivation
  # rather than recomputed here, so a fixture cannot name a key the roster would
  # not derive.
  defp weekend_day_type_key(world, service_id) do
    world.organization.id
    |> Blocking.list_day_types(world.version.id)
    |> Enum.find(&(service_id in &1.service_ids))
    |> Map.fetch!(:key)
  end

  defp new_line(world) do
    assert {:ok, %{id: id, line_number: number}} =
             Gtfs.create_roster_line(world_audit(world))

    %{id: id, line_number: number}
  end

  defp set_group(world, line, weekday, run_id),
    do:
      Gtfs.set_roster_weekday_group(
        world_audit(world),
        line.id,
        weekday,
        run_id
      )

  defp set_slot(world, line, weekday, run_id),
    do: Gtfs.set_roster_slot(world_audit(world), line.id, weekday, run_id)

  defp load_roster(world) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
    roster
  end

  # The composed slots of one line, or the one weekday's slot on it.
  defp slots(roster, line_number) do
    roster.lines |> Enum.find(&(&1.line_number == line_number)) |> Map.fetch!(:slots)
  end

  defp slot(roster, line_number, weekday), do: slots(roster, line_number) |> Map.get(weekday)

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
            t.day_type_key == ^world.day_type_key and t.trip_id == ^trip.trip_id
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
