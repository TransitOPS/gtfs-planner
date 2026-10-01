defmodule GtfsPlanner.Gtfs.Rosters.CreateLineFromRunTest do
  @moduledoc """
  `create_roster_line_from_run/3` is the "Create Mon–Fri line" write: a numbered
  new line holding one run on every weekday of that run's own group, in one
  transaction, only when `Rosters.Candidates.new_line_availability/3` allows it,
  and a refusal that writes no line at all.

  Every case goes through the `Gtfs` facade, the path the Rosters open-work card
  calls, so the delegate is on the path being tested rather than bypassed. Stored
  rows are read back from `roster_lines` and `roster_line_days` and composed
  state through `Gtfs.load_roster/2`, because "nothing was written" and "the day
  carries the run's own times" are claims about the tables, not about what was
  returned.

  ## The day

  `RunsFixtures.runs_version_fixture/1` with block 101 on run `2001` and block
  102 on run `2002`, so Monday to Friday share one day type, plus a
  Saturday-only and a Sunday-only service of their own:

  * `2001` signs on at 02:09 and off at 13:52, so consecutive `2001` days leave
    over the 36 000 s the 600-minute rule needs and a whole Mon–Fri line of it is
    allowed.
  * a Saturday-only service on run `6010` and a Sunday-only service on run
    `7007`, each its own single-day group, which is what "nothing on 6 and 7"
    means: the line built from `2001` works neither.
  * a third block, `103`, on run `3003`, whose two trips are seventeen hours
    apart. Its spread is over 960 minutes, so it can only exist at all with the
    crew rule raised — `Runs.update_crew_settings/3` with `max_spread_minutes`
    1 080 — and repeated Monday to Friday it leaves under 600 minutes of rest.
    That is the spec's own counterexample, built from fixture trips rather than
    asserted about a value table (FH-13).

  The "no weekday is based on it" case adds a service of its own to five
  individual weekday dates and moves the base week onto it, which is the only way
  a real day type stops being some weekday's base.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/create_line_from_run_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  @wednesday 3
  @saturday 6
  @sunday 7
  @weekdays [1, 2, 3, 4, 5]

  # The two weekday runs' own work times, which every stored day carries. Read
  # back from the version's own derivation in `setup` rather than assumed, so a
  # change to the crew rules cannot silently move the expectation.
  @run_2001_id "2001"
  @run_3003_id "3003"

  # The crew rules the long-spread run needs: `max_spread_minutes` at its 1 080
  # ceiling, the rest at the researched defaults.
  @long_spread_crew %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 1080
  }

  setup do
    world = runs_version_fixture()

    # One run per block, so a run that keeps its ID and loses its last trip stays
    # observable: the derivation follows the stored assignments, not the blocks.
    for {block_id, run_id} <- [{"101", @run_2001_id}, {"102", "2002"}],
        trip <- world.blocks[block_id] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: run_id
      })
    end

    world =
      world
      |> add_long_run()
      |> add_weekend()

    %{world: world, run_2001: derived_run(world, world.day_type_key, @run_2001_id).work}
  end

  describe "create_roster_line_from_run/3" do
    test "creates the next numbered line holding the run on every weekday of its group", %{
      world: world,
      run_2001: run
    } do
      # Two lines already exist, so the new line's number is the version's
      # highest plus one — the same numbering `create_roster_line/1` uses.
      new_line(world)
      new_line(world)

      assert {:ok, %{line_number: 3, weekdays: @weekdays}} =
               create(world, world.day_type_key, @run_2001_id)

      assert line_count(world) == 3

      for weekday <- @weekdays do
        assert stored_day(world, 3, weekday) ==
                 {world.day_type_key, @run_2001_id, run.sign_on_secs, run.sign_off_secs}
      end

      assert day_count(world) == 5

      roster = load_roster(world)

      # Nothing on Saturday or Sunday: those weekdays have a day type of their
      # own, which this run is not a run of, and a day off is the absence of a
      # row rather than a row storing nothing.
      for weekday <- [@saturday, @sunday] do
        assert stored_day(world, 3, weekday) == nil
        assert slot(roster, 3, weekday) == nil
      end

      # The five stored days are fresh, which is what storing the run's own times
      # buys (INV-13), and no short rest was created.
      for weekday <- @weekdays do
        assert slot(roster, 3, weekday).state == :ok
      end

      refute Enum.any?(
               slots_of_line(roster, 3) |> Map.fetch!(:findings),
               &(&1.code == :short_rest)
             )
    end

    test "the run is open again once the line that held it is cleared", %{world: world} do
      {1, line} = new_line(world)

      assert {:ok, %{short_rests: []}} = set_slot(world, line, @wednesday, @run_2001_id)

      assert {:error, {:run_held, @wednesday, 1}} =
               create(world, world.day_type_key, @run_2001_id)

      assert {:ok, :cleared} =
               Gtfs.clear_roster_slot(world_audit(world), line, @wednesday)

      assert {:ok, %{line_number: 2, weekdays: @weekdays}} =
               create(world, world.day_type_key, @run_2001_id)

      assert day_count(world) == 5
    end
  end

  describe "create_roster_line_from_run/3 refusals" do
    test "a run another line holds on a day of its group is refused, naming the line", %{
      world: world
    } do
      {1, holder} = new_line(world)
      new_line(world)

      assert {:ok, %{short_rests: []}} = set_slot(world, holder, @wednesday, @run_2001_id)

      assert {:error, {:run_held, @wednesday, 1}} =
               create(world, world.day_type_key, @run_2001_id)

      # Not even an empty line is left behind: the refusal happens before the
      # insert, so the version still has the two lines it had.
      assert line_count(world) == 2
      assert day_count(world) == 1
      assert slots(load_roster(world), 2) == %{}
    end

    test "a run whose own consecutive days would leave short rest is refused", %{world: world} do
      {:ok, _crew} =
        Gtfs.update_crew_settings(world.audit, @long_spread_crew)

      run = derived_run(world, world.day_type_key, @run_3003_id).work

      # The premise, in the version's own derived numbers: the run's spread is
      # over 960 minutes and its own repeated days leave under 600 minutes of
      # rest. Without this the refusal below would prove nothing.
      assert run.spread_secs > 960 * 60
      rest_secs = run.sign_on_secs + 86_400 - run.sign_off_secs
      assert rest_secs < 600 * 60

      assert {:error, {:short_rest, 1, 2, ^rest_secs, @run_3003_id}} =
               create(world, world.day_type_key, @run_3003_id)

      assert line_count(world) == 0
      assert day_count(world) == 0
    end

    test "a run the day type does not derive is refused", %{world: world} do
      assert {:error, {:unknown_run, "9999"}} = create(world, world.day_type_key, "9999")
      assert line_count(world) == 0
    end

    test "a day type no weekday is based on is refused", %{world: world} do
      # The base week is moved onto a day type of its own, so the weekday day
      # type `2001` belongs to is based on no weekday at all while the Wednesday
      # slot still holds the run.
      alternate = add_alternate_weekdays(world)
      {1, line} = new_line(world)

      assert {:ok, %{short_rests: []}} = set_slot(world, line, @wednesday, @run_2001_id)
      assert {:ok, _settings} = base_week_on(world, alternate)

      assert {:error, {:no_base, _weekday}} = create(world, world.day_type_key, @run_2001_id)

      # The refusal wrote nothing; the line still works only the Wednesday it was
      # set with, and now reads as a base change.
      assert line_count(world) == 1
      assert day_count(world) == 1
      assert slot(load_roster(world), 1, @wednesday).state == {:stale, :base_changed}
    end

    test "an unpublished version is not found and no line is written", %{world: world} do
      :ok = stage(world)

      assert {:error, :not_found} = create(world, world.day_type_key, @run_2001_id)
      assert line_count(world) == 0
    end
  end

  # A second weekday service of its own, added through five calendar-date
  # exceptions — one Monday, one Tuesday, one Wednesday, one Thursday and one
  # Friday. A service active on a subset of dates derives a day type of its own
  # while the fixture's `WK` keeps its own, so the base week has somewhere else
  # to move to. A service active on *every* weekday would not: it would merge
  # into `WK`'s dates and change `WK`'s own key.
  defp add_alternate_weekdays(world) do
    service_id = "ALT"

    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: service_id,
      name: "Weekday alternate",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      dates: [~D[2026-01-05], ~D[2026-01-06], ~D[2026-01-07], ~D[2026-01-08], ~D[2026-01-09]]
    })

    day_type_key_of_service(world, service_id)
  end

  # A block of its own whose two trips are seventeen hours apart, which is the
  # spec's counterexample run: its spread is over 960 minutes, so the crew rule
  # has to be raised for it to exist at all, and repeated on consecutive weekdays
  # it leaves under the minimum rest (FH-13).
  defp add_long_run(world) do
    for {trip_id, from, to} <- [{"g", "04:30:00", "05:00:00"}, {"h", "21:30:00", "22:00:00"}] do
      trip =
        blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
          trip_id: trip_id,
          service_id: "WK",
          block_id: "103",
          first_departure: from,
          last_arrival: to
        })

      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: @run_3003_id
      })
    end

    world
  end

  # Saturday and Sunday each get a calendar service of their own, a trip on it
  # and a `trip_runs` row, so each weekday has a base day type and a derived run
  # of its own — which is what makes "nothing on 6 and 7" a claim about the new
  # line rather than about a week that has no weekend at all.
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

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: trip,
      day_type_key: day_type_key_of_service(world, service_id),
      run_id: run_id
    })

    Map.put(world, weekday_key, run_id)
  end

  # The day type of one calendar service, read from the version's own derivation
  # rather than recomputed here, so a fixture cannot name a key the roster would
  # not derive.
  defp day_type_key_of_service(world, service_id) do
    world.organization.id
    |> Blocking.list_day_types(world.version.id)
    |> Enum.find(&(service_id in &1.service_ids))
    |> Map.fetch!(:key)
  end

  # The base week moved onto one day type for every weekday it runs on, which
  # leaves the fixture's own weekday day type based on no weekday. The choice
  # goes through the roster settings writer, so it is validated against the
  # version's own calendars exactly as a planner's save would be.
  defp base_week_on(world, alternate) do
    Gtfs.update_roster_settings(
      world_audit(world),
      %{
        min_rest_minutes: 600,
        weekly_hours_warn_above: 48,
        roster_day_types: Map.new(1..5, &{Integer.to_string(&1), alternate})
      }
    )
  end

  defp new_line(world) do
    assert {:ok, %{id: id, line_number: number}} =
             Gtfs.create_roster_line(world_audit(world))

    {number, id}
  end

  defp set_slot(world, line, weekday, run_id) do
    Gtfs.set_roster_slot(world_audit(world), line, weekday, run_id)
  end

  defp create(world, day_type_key, run_id) do
    Gtfs.create_roster_line_from_run(
      world_audit(world),
      day_type_key,
      run_id
    )
  end

  defp load_roster(world) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
    roster
  end

  defp slots_of_line(roster, line_number) do
    roster.lines |> Enum.find(&(&1.line_number == line_number))
  end

  defp slots(roster, line_number), do: slots_of_line(roster, line_number) |> Map.fetch!(:slots)

  defp slot(roster, line_number, weekday), do: slots(roster, line_number) |> Map.get(weekday)

  # The stored row, read back as the four values the writer had to get right.
  defp stored_day(world, line_number, weekday) do
    Repo.one(
      from(d in RosterLineDay,
        join: l in RosterLine,
        on: l.id == d.roster_line_id,
        where:
          l.line_number == ^line_number and d.weekday == ^weekday and
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

  defp line_count(world) do
    Repo.one(
      from(l in RosterLine,
        where:
          l.organization_id == ^world.organization.id and l.gtfs_version_id == ^world.version.id,
        select: count(l.id)
      )
    )
  end

  # One derived run, read inside its own transaction so the read cannot sit in a
  # caller's aborted one.
  defp derived_run(world, key, run_id) do
    {:ok, {:ok, day}} =
      Repo.transaction(fn ->
        Runs.load_runs(world.organization.id, world.version.id, key)
      end)

    Enum.find(day.derived.runs, &(&1.run_id == run_id))
  end

  # The version as a draft: every roster writer refuses an unpublished version,
  # the same as a version of another organization.
  defp stage(world) do
    {1, _} =
      Repo.update_all(
        from(v in GtfsVersion, where: v.id == ^world.version.id),
        set: [publication_status: "staging", published_at: nil]
      )

    :ok
  end
end
