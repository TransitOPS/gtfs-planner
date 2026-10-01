defmodule GtfsPlanner.Gtfs.Rosters.RosterQueriesTest do
  @moduledoc """
  The two read-only roster queries: `roster_operator_holdings/2`, which names
  every line an operator holds across the organization's versions before a hard
  delete, and `count_roster_slots_for_day_type/3`, which says how much of a day
  type the roster has taken before a runs rebuild.

  Both go through the `Gtfs` facade, the path the Rosters page and the Runs page
  call, so the delegates are on the paths being tested rather than bypassed. The
  numbers each one reports are read back from `roster_lines` and
  `roster_line_days` as well, because "the line is held" and "the slot is
  counted" are claims about stored rows, not about what the caller was told.

  The world is `RunsFixtures.runs_version_fixture/1`: a published version in its
  own organization, whose one calendar service runs Monday to Friday, so all
  five weekdays share one day type. Block 101 is on run `2001` and block 102 on
  run `2002`, which gives two distinct runs a line can work the same day type on,
  and two lines can fill Monday to Friday without either line taking a run the
  other already holds.

  The version names in the holdings case are the ones the delete confirmation
  names, and the two extra versions of the same organization exist only so the
  answer is ordered by version name rather than by insertion.

  The scoping case builds a second organization of the same fixture: its version
  derives the same day-type key — the key is a hash of the service set, not of
  the organization — so a count that ignored the version would add its slots.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/roster_queries_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  @weekdays [1, 2, 3, 4, 5]

  # A key no roster day of this fixture names. The key is a hash of a service
  # set, so "unused" is expressed as a key that is well formed and absent rather
  # than as a malformed one, which the count is not asked about.
  @unused_key "9Y3vQ0RkZmFrY3lKZzBBRQ"

  setup do
    %{world: assign_runs(runs_version_fixture())}
  end

  # One run per block, so two lines can work the same day type on the same
  # weekday without either of them taking a run the other holds. The second
  # organization of the scoping case is built by the case itself and needs the
  # same assignment, or it derives no runs and its own write is refused.
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

  describe "roster_operator_holdings/2" do
    test "names every line the operator holds, ordered by version name", %{world: world} do
      operator = operator_fixture(world, "E-7", "Aurelia Nowak", 7)

      # Three versions of one organization, each with its own line numbering:
      # the same operator holds one line in each of them.
      service = named_version(world, "2026-27 service")
      spring = named_version(world, "2027 spring")

      service_line = line_on(service, 2)
      spring_line = line_on(spring, 4)
      current_line = new_line(world)

      for {scope, line} <- [
            {service, service_line},
            {spring, spring_line},
            {world, current_line}
          ] do
        assert {:ok, %{line_number: _}} =
                 Gtfs.assign_roster_operator(
                   world_audit(scope),
                   line.id,
                   operator.id
                 )
      end

      # Ordered by version name, with the line number of each version's own
      # numbering beside it. One operator holds at most one line per version, so
      # the line number is a tiebreaker here rather than an ordering that can
      # fire; the confirmation copies both numbers as they are.
      assert Gtfs.roster_operator_holdings(world.organization.id, operator.id) == [
               %{
                 gtfs_version_id: service.version.id,
                 version_name: "2026-27 service",
                 line_number: 2
               },
               %{gtfs_version_id: spring.version.id, version_name: "2027 spring", line_number: 4},
               %{
                 gtfs_version_id: world.version.id,
                 version_name: world.version.name,
                 line_number: 1
               }
             ]
    end

    test "an operator holding nothing, of another organization, or named badly holds nothing",
         %{world: world} do
      holder_line = new_line(world)
      holder = operator_fixture(world, "E-7", "Aurelia Nowak", 7)

      assert {:ok, %{line_number: 1}} =
               Gtfs.assign_roster_operator(
                 world_audit(world),
                 holder_line.id,
                 holder.id
               )

      assert [%{line_number: 1}] =
               Gtfs.roster_operator_holdings(world.organization.id, holder.id)

      theirs = runs_version_fixture()
      foreign = operator_fixture(theirs, "E-7", "Bo Lindqvist", 8)
      unused = operator_fixture(world, "E-9", "Cyd Renner", 9)

      for operator_id <- [unused.id, foreign.id, "not-a-uuid", 42, nil, Ecto.UUID.generate()] do
        assert Gtfs.roster_operator_holdings(world.organization.id, operator_id) == []
      end

      # The holder's line is untouched by those reads, and a cleared pick stops
      # being a holding — the same `[]` the confirmation would show.
      assert {:ok, %{line_number: 1}} =
               Gtfs.assign_roster_operator(
                 world_audit(world),
                 holder_line.id,
                 nil
               )

      assert Gtfs.roster_operator_holdings(world.organization.id, holder.id) == []
      assert stored_operator(world, holder_line) == nil
    end

    test "another organization's held line is not named, and the caller cannot widen the scope",
         %{world: world} do
      theirs = runs_version_fixture()
      their_line = new_line(theirs)
      their_operator = operator_fixture(theirs, "E-7", "Bo Lindqvist", 8)

      assert {:ok, %{line_number: 1}} =
               Gtfs.assign_roster_operator(
                 world_audit(theirs),
                 their_line.id,
                 their_operator.id
               )

      assert Gtfs.roster_operator_holdings(theirs.organization.id, their_operator.id) == [
               %{
                 gtfs_version_id: theirs.version.id,
                 version_name: theirs.version.name,
                 line_number: 1
               }
             ]

      # The same operator id read under this organization names nothing: the
      # scope is the argument, not the row.
      assert Gtfs.roster_operator_holdings(world.organization.id, their_operator.id) == []
    end
  end

  describe "count_roster_slots_for_day_type/3" do
    test "counts the lines and the slots a day type occupies", %{world: world} do
      first = new_line(world)
      second = new_line(world)

      for weekday <- @weekdays do
        assert {:ok, %{short_rests: _rest}} = set(world, first, weekday, "2001")
        assert {:ok, %{short_rests: _rest}} = set(world, second, weekday, "2002")
      end

      # Two lines, five days each: the confirmation names both figures, and they
      # are counted in the table rather than derived from the runs.
      assert Gtfs.count_roster_slots_for_day_type(
               world.organization.id,
               world.version.id,
               world.day_type_key
             ) == %{lines: 2, slots: 10}

      assert stored_day_count(world, world.day_type_key) == 10
      assert held_line_count(world, world.day_type_key) == 2
    end

    test "a day type nothing is rostered against counts as no lines and no slots", %{world: world} do
      new_line(world)

      assert Gtfs.count_roster_slots_for_day_type(
               world.organization.id,
               world.version.id,
               @unused_key
             ) == %{lines: 0, slots: 0}

      # A version with no lines at all answers the same, without a special case.
      empty = named_version(world, "2026-27 service")

      assert Gtfs.count_roster_slots_for_day_type(
               world.organization.id,
               empty.version.id,
               world.day_type_key
             ) == %{lines: 0, slots: 0}
    end

    test "another version's and another organization's slots are not counted", %{world: world} do
      line = new_line(world)
      assert {:ok, %{short_rests: _rest}} = set(world, line, 1, "2001")

      # A sibling version of the same organization answers zero for the key this
      # version has a slot of, so the version in the arguments is the only
      # version counted.
      sibling = named_version(world, "2026-27 service")

      assert Gtfs.count_roster_slots_for_day_type(
               world.organization.id,
               sibling.version.id,
               world.day_type_key
             ) == %{lines: 0, slots: 0}

      # A second organization of the same fixture derives the same key, so a
      # count scoped only by key would answer twice the slots.
      theirs = assign_runs(runs_version_fixture())
      their_line = new_line(theirs)
      assert {:ok, %{short_rests: _rest}} = set(theirs, their_line, 1, "2001")
      assert theirs.day_type_key == world.day_type_key

      assert Gtfs.count_roster_slots_for_day_type(
               world.organization.id,
               world.version.id,
               world.day_type_key
             ) == %{lines: 1, slots: 1}
    end
  end

  # A published version of the world's own organization, named as the
  # confirmation's copy names it. A version needs no fixture of its own to hold a
  # roster line: the line number comes from the writer, not from calendars.
  defp named_version(world, name) do
    version = gtfs_version_fixture(world.organization.id, %{name: name})
    %{world | version: version}
  end

  # The version's line numbered `line_number`, made by creating lines in order so
  # the numbering is the writer's own.
  defp line_on(world, line_number) do
    line = Enum.reduce(1..line_number//1, nil, fn _, _ -> new_line(world) end)
    assert line.line_number == line_number
    line
  end

  defp new_line(world) do
    assert {:ok, %{id: id, line_number: number}} =
             Gtfs.create_roster_line(world_audit(world))

    %{id: id, line_number: number}
  end

  defp set(world, line, weekday, run_id),
    do: Gtfs.set_roster_slot(world_audit(world), line.id, weekday, run_id)

  # The stored pick, read back from the table rather than from a writer's answer.
  defp stored_operator(world, line) do
    Repo.one(
      from(l in RosterLine,
        where:
          l.id == ^line.id and l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id,
        select: l.operator_id
      )
    )
  end

  # What each count is drawn from, counted in the tables themselves.
  defp stored_day_count(world, day_type_key) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.organization_id == ^world.organization.id and
            d.gtfs_version_id == ^world.version.id and d.day_type_key == ^day_type_key,
        select: count(d.id)
      )
    )
  end

  defp held_line_count(world, day_type_key) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.organization_id == ^world.organization.id and
            d.gtfs_version_id == ^world.version.id and d.day_type_key == ^day_type_key,
        select: count(d.roster_line_id, :distinct)
      )
    )
  end

  # An operator of the world's own organization, inserted through the schema's
  # changeset because `Operations`' writers arrive in steps 18 and 19. Only the
  # three business fields are set: a pick stores no personal data of its own.
  defp operator_fixture(world, employee_id, display_name, seniority_number) do
    Repo.insert!(
      %Operator{organization_id: world.organization.id}
      |> Operator.changeset(%{
        employee_id: employee_id,
        display_name: display_name,
        seniority_number: seniority_number
      })
    )
  end
end
