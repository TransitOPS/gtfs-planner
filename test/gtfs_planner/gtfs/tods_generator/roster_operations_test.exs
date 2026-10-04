defmodule GtfsPlanner.Gtfs.TodsGenerator.RosterOperationsTest do
  @moduledoc """
  Step 6: a generation's roster, operator and slot writes are transaction-local
  operations the caller's transaction owns.

  `Rosters.apply_generation_in_transaction!/4` and
  `Operations.create_operator_in_transaction!/2` are the pieces a generation's save
  composes after the candidate's blocks, relief marks and runs have landed in the
  same transaction. They open no transaction and keep no fingerprint, so the
  failures specific to *them* are the ones a single-owner suite cannot see:

    * a candidate's base-week choice, its fictional operators, its single-slot lines
      and the slots themselves are stored together, and the slot's stored times are
      the run the version persists now rather than the candidate's own snapshot;
    * a proposal the version no longer answers — a run it does not derive, a run-day
      another line has since taken, a base choice the operator has since stored —
      rolls the caller's whole transaction back, so the operators, lines and slots
      the earlier proposals wrote do not survive without it;
    * an employee ID the organization already holds is refused, and the existing
      person is neither edited nor attached to the new line.

  Every case composes its candidate from a real `Gtfs.preview_tods_generation/2`
  over the fixture's own small schedule — `TodsGeneratorFixtures.roster_world_fixture/0`,
  the world `RosterPlanTest` reads — and then calls the production operations
  against the isolated test database. The line's run is written first through
  `Runs.apply_generation_in_transaction!/2`, the order the save's contract names,
  so the run the slot is checked against is a persisted one rather than a struct a
  case built. The `DEMO-<uuid>-<ordinal>` employee IDs and `"Demo operator NNN"`
  names are the fixture's own literal form of the generator's naming rule; the
  operation accepts the caller's attributes and checks the collision, it does not
  invent the name.

  Run with:
  `mix test test/gtfs_planner/gtfs/tods_generator/roster_operations_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.TodsGeneratorFixtures

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Rosters
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @moduletag timeout: 120_000

  describe "inside one caller-owned transaction" do
    test "the candidate's base choice, operators, lines and slots are stored together" do
      world = roster_world_fixture()
      holiday_week = Date.to_iso8601(Date.add(roster_monday(world), 14))

      assert {:ok, preview} =
               roster_preview(world, %{"representative_week" => holiday_week})

      # The representative Monday is the holiday, so this request would store
      # Monday's choice and propose Monday's lines beside the weekday ones.
      assert preview.roster_day_types == %{"1" => world.holiday_day_type}
      assert preview.roster_lines != []
      assert Enum.any?(preview.roster_lines, &(&1.weekday == 1))

      # The fixture's trips are all blocked already, so the candidate adds no
      # block: the save this case composes is the run write and the roster write.
      assert preview.blocks == []
      assert preview.assignments == %{}

      operators = operators_by_ordinal(preview.roster_lines, Ecto.UUID.generate())

      # An ordinal no proposal names: a save creates no operator for it.
      unused = %{employee_id: "DEMO-unused-999", display_name: "Demo operator 999"}
      operators = Map.put(operators, 99, unused)

      assert {:ok, result} = save(world, preview, operators)

      assert result.settings_changes == %{"1" => world.holiday_day_type}
      assert length(result.line_ids) == length(preview.roster_lines)
      assert length(result.slot_ids) == length(preview.roster_lines)
      assert Enum.uniq(result.line_ids) == result.line_ids
      assert Enum.uniq(result.slot_ids) == result.slot_ids

      # The choice is stored, read back through the reader the settings form uses.
      assert stored_choices(world) == %{"1" => world.holiday_day_type}

      for {proposal, line_id, slot_id} <-
            Enum.zip([preview.roster_lines, result.line_ids, result.slot_ids]) do
        run = derived_run(world, proposal.day_type_key, proposal.run_id)
        attrs = Map.fetch!(operators, proposal.operator_ordinal)

        # The stored slot carries the run the version persists now — the run this
        # transaction's own run write made — and not the candidate's snapshot.
        assert stored_slot(world, slot_id) ==
                 {line_id, proposal.weekday, proposal.day_type_key, proposal.run_id,
                  run.work.sign_on_secs, run.work.sign_off_secs}

        # One line per run-day, one slot each, held by the fictional operator of its
        # own ordinal and carrying no seniority number.
        assert stored_operator(world, line_id) ==
                 {attrs.employee_id, attrs.display_name, nil}
      end

      assert line_count(world) == length(preview.roster_lines)
      assert slot_count(world) == length(preview.roster_lines)
      assert operator_count(world) == length(preview.roster_lines)
      refute employee_id_taken?(world, unused.employee_id)
    end

    test "a run the version does not derive on a later proposal rolls back the earlier writes" do
      world = roster_world_fixture()

      assert {:ok, preview} = roster_preview(world)

      [first, second | _rest] = preview.roster_lines
      operators = operators_by_ordinal(preview.roster_lines, Ecto.UUID.generate())

      # The second proposal names a run the version never derives. The first is
      # admitted and written before it, so the refusal has earlier operator, line
      # and slot inserts to roll back.
      broken = %{preview | roster_lines: [first, %{second | run_id: "9999"}]}

      assert {:error, {:unknown_run, "9999"}} = save(world, broken, operators)

      # Nothing the first proposal wrote survived: no line, no slot and no operator.
      assert line_count(world) == 0
      assert slot_count(world) == 0
      assert operator_count(world) == 0

      # The same two proposals with the run the version does derive are admitted, so
      # the rollback removed real writes rather than a call that writes nothing.
      assert {:ok, result} = save(world, %{preview | roster_lines: [first, second]}, operators)

      assert length(result.line_ids) == 2
      assert line_count(world) == 2
      assert slot_count(world) == 2
      assert operator_count(world) == 2
    end

    test "a run-day a stored line has taken refuses the later proposal and rolls the earlier one back" do
      world = roster_world_fixture()

      assert {:ok, preview} = roster_preview(world)

      [_, second | _rest] = preview.roster_lines
      operators = operators_by_ordinal(preview.roster_lines, Ecto.UUID.generate())

      # The candidate's runs are written, as the save writes them before its roster
      # writes, and then a planner works the second proposal's run-day by hand: the
      # candidate is composed and no longer current.
      assert {:ok, _written} = persist_runs(world, preview)
      holder = new_line(world)
      assert {:ok, _set} = set_slot(world, holder, second.weekday, second.run_id)

      assert {:error, {:run_held, weekday, line_number}} =
               apply_roster(world, preview, operators)

      assert weekday == second.weekday
      assert line_number == holder.line_number

      # The planner's line still holds the run-day, and the first proposal's line,
      # slot and operator are gone — a generation never takes over held work.
      assert line_count(world) == 1
      assert slot_count(world) == 1
      assert operator_count(world) == 0

      assert stored_slot_line(world, holder.id, second.weekday) ==
               {holder.id, second.day_type_key, second.run_id}
    end

    test "a proposal whose ordinal names no operator attributes is refused" do
      world = roster_world_fixture()

      assert {:ok, preview} = roster_preview(world)
      [first | _rest] = preview.roster_lines
      operators = operators_by_ordinal(preview.roster_lines, Ecto.UUID.generate())

      assert {:ok, _written} = persist_runs(world, preview)

      assert {:error, {:missing_operator, ordinal}} =
               apply_roster(
                 world,
                 %{preview | roster_lines: [first]},
                 Map.delete(operators, first.operator_ordinal)
               )

      # The refusal names the ordinal, and the line and slot written before it are
      # rolled back with it.
      assert ordinal == first.operator_ordinal
      assert line_count(world) == 0
      assert slot_count(world) == 0
      assert operator_count(world) == 0
    end
  end

  describe "a candidate the version no longer answers" do
    test "times that are not the persisted run's are refused and store nothing" do
      world = roster_world_fixture()

      assert {:ok, preview} = roster_preview(world)
      [first | _rest] = preview.roster_lines
      operators = operators_by_ordinal(preview.roster_lines, Ecto.UUID.generate())
      before = roster_state(world)

      # A client-supplied snapshot: the run is derived, but with other times than
      # the run this transaction persists.
      stale = %{first | run_sign_on_secs: first.run_sign_on_secs - 60}

      assert {:error, :stale_plan} = save(world, %{preview | roster_lines: [stale]}, operators)

      assert roster_state(world) == before
      assert line_count(world) == 0
      assert slot_count(world) == 0
      assert operator_count(world) == 0

      # The unstale proposal of the same run is admitted, so the refusal above was
      # the times and nothing else.
      assert {:ok, result} = save(world, %{preview | roster_lines: [first]}, operators)
      assert length(result.line_ids) == 1
      assert stored_choices(world) == %{}
    end

    test "a weekday base the version has chosen since is refused and the choice stands" do
      world = roster_world_fixture()
      holiday_week = Date.to_iso8601(Date.add(roster_monday(world), 14))

      assert {:ok, preview} =
               roster_preview(world, %{"representative_week" => holiday_week})

      assert preview.roster_day_types == %{"1" => world.holiday_day_type}

      # The operator stores Monday's own choice after the candidate was composed.
      assert {:ok, _settings} =
               Gtfs.update_roster_settings(world.audit, %{
                 "roster_day_types" => %{"1" => world.monday_day_type}
               })

      operators = operators_by_ordinal(preview.roster_lines, Ecto.UUID.generate())

      assert {:error, :stale_plan} = save(world, preview, operators)

      # The operator's own choice stands and nothing was written beside it.
      assert stored_choices(world) == %{"1" => world.monday_day_type}
      assert line_count(world) == 0
      assert slot_count(world) == 0
      assert operator_count(world) == 0
    end
  end

  describe "the fictional operator" do
    test "an employee ID the organization already holds is refused and the holder is untouched" do
      world = roster_world_fixture()

      assert {:ok, preview} = roster_preview(world)
      [first | _rest] = preview.roster_lines
      operators = operators_by_ordinal(preview.roster_lines, Ecto.UUID.generate())
      attrs = Map.fetch!(operators, first.operator_ordinal)

      # The person a previous save left under this employee ID: a generation must
      # not attach its line to them or correct their name.
      assert {:ok, holder} = insert_operator(world, attrs.employee_id, "Existing person", 7)

      assert {:error, %Ecto.Changeset{} = refused} =
               save(world, %{preview | roster_lines: [first]}, operators)

      assert {message, _options} = refused.errors[:employee_id]

      assert message == "#{attrs.employee_id} is already used by Existing person."

      # The holder keeps every field it had and holds no line; the refused call wrote
      # no line, slot or operator at all.
      assert stored_operator_row(world, holder.id) ==
               {attrs.employee_id, "Existing person", 7}

      assert held_line_numbers(world, holder.id) == []
      assert line_count(world) == 0
      assert slot_count(world) == 0
      assert operator_count(world) == 1
    end

    test "an employee ID of another organization neither blocks the write nor is touched" do
      world = roster_world_fixture()
      theirs = roster_world_fixture()

      assert {:ok, preview} = roster_preview(world)
      [first | _rest] = preview.roster_lines
      operators = operators_by_ordinal(preview.roster_lines, Ecto.UUID.generate())
      attrs = Map.fetch!(operators, first.operator_ordinal)

      # The same employee ID, in an organization this write has no scope for.
      assert {:ok, foreign} = insert_operator(theirs, attrs.employee_id, "Their person", 3)

      assert {:ok, result} = save(world, %{preview | roster_lines: [first]}, operators)

      # This organization's operator is its own row, and the other organization's
      # person is exactly as it was.
      assert [line_id] = result.line_ids
      assert stored_operator(world, line_id) == {attrs.employee_id, attrs.display_name, nil}

      assert stored_operator_row(theirs, foreign.id) ==
               {attrs.employee_id, "Their person", 3}
    end
  end

  # --- the save's own shape -------------------------------------------------

  # The candidate's roster writes as the save composes them: the caller's locks,
  # the block/relief writes (this fixture's blocks are already stored), the run
  # writes, and then the roster operation.
  defp save(world, preview, operators) do
    Repo.transaction(fn ->
      lock_caller_scope(world)
      Runs.apply_generation_in_transaction!(world.audit, preview.run_deltas)

      Rosters.apply_generation_in_transaction!(
        world.audit,
        preview.roster_day_types,
        preview.roster_lines,
        operators
      )
    end)
  end

  # The candidate's runs alone, for a case that has to interleave a planner's own
  # write between the run writes and the roster ones.
  defp persist_runs(world, preview) do
    Repo.transaction(fn ->
      lock_caller_scope(world)
      Runs.apply_generation_in_transaction!(world.audit, preview.run_deltas)
    end)
  end

  defp apply_roster(world, preview, operators) do
    Repo.transaction(fn ->
      lock_caller_scope(world)

      Rosters.apply_generation_in_transaction!(
        world.audit,
        preview.roster_day_types,
        preview.roster_lines,
        operators
      )
    end)
  end

  # The locks a generation's save holds before it calls the transaction-local
  # operations: the editor membership lock, the version `FOR SHARE` and the
  # blocking lock, the same arrangement `TransactionOperationsTest` uses.
  defp lock_caller_scope(world) do
    Authorization.lock_editor!(world.audit)
    Versions.lock_for_input_write!(world.organization.id, world.version.id)
    :ok = Blocking.lock_blocking!(world.version.id)
  end

  # --- the generator's own naming -------------------------------------------

  # The fictional operator one proposal's ordinal is created as, in the generator's
  # naming rule: `DEMO-<request UUID>-<ordinal>` and `Demo operator NNN`.
  defp operators_by_ordinal(lines, request_id) do
    Map.new(lines, fn line ->
      ordinal = line.operator_ordinal

      {ordinal,
       %{
         employee_id: "DEMO-#{request_id}-#{ordinal(ordinal)}",
         display_name: "Demo operator #{ordinal(ordinal)}"
       }}
    end)
  end

  defp ordinal(number), do: String.pad_leading(Integer.to_string(number), 3, "0")

  # --- the world's own writes and reads -------------------------------------

  defp new_line(world) do
    assert {:ok, %{id: id, line_number: number}} = Gtfs.create_roster_line(world.audit)
    %{id: id, line_number: number}
  end

  defp set_slot(world, line, weekday, run_id),
    do: Gtfs.set_roster_slot(world.audit, line.id, weekday, run_id)

  defp insert_operator(world, employee_id, display_name, seniority_number) do
    Operations.create_operator(
      world.organization.id,
      %{id: world.audit.actor_id},
      %{
        employee_id: employee_id,
        display_name: display_name,
        seniority_number: seniority_number
      }
    )
  end

  defp stored_choices(world) do
    Gtfs.get_roster_settings(world.organization.id, world.version.id).roster_day_types
  end

  # Run `run_id` as the Rosters page derives it now, so the times a stored slot is
  # compared against are the times the writer itself read.
  defp derived_run(world, day_type_key, run_id) do
    {:ok, {:ok, day}} =
      Repo.transaction(fn ->
        Runs.load_runs(world.organization.id, world.version.id, day_type_key)
      end)

    Enum.find(day.derived.runs, &(&1.run_id == run_id))
  end

  defp stored_slot(world, slot_id) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.id == ^slot_id and d.organization_id == ^world.organization.id and
            d.gtfs_version_id == ^world.version.id,
        select:
          {d.roster_line_id, d.weekday, d.day_type_key, d.run_id, d.run_sign_on_secs,
           d.run_sign_off_secs}
      )
    )
  end

  defp stored_slot_line(world, line_id, weekday) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.roster_line_id == ^line_id and d.weekday == ^weekday and
            d.organization_id == ^world.organization.id,
        select: {d.roster_line_id, d.day_type_key, d.run_id}
      )
    )
  end

  defp stored_operator(world, line_id) do
    Repo.one(
      from(l in RosterLine,
        join: o in assoc(l, :operator),
        where: l.id == ^line_id and l.organization_id == ^world.organization.id,
        select: {o.employee_id, o.display_name, o.seniority_number}
      )
    )
  end

  defp stored_operator_row(world, operator_id) do
    Repo.one(
      from(o in Operator,
        where: o.id == ^operator_id and o.organization_id == ^world.organization.id,
        select: {o.employee_id, o.display_name, o.seniority_number}
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

  defp employee_id_taken?(world, employee_id) do
    Repo.exists?(
      from(o in Operator,
        where: o.organization_id == ^world.organization.id and o.employee_id == ^employee_id
      )
    )
  end

  # Every roster fact a generation would change, read from the database.
  defp roster_state(world) do
    %{
      choices: stored_choices(world),
      lines: line_count(world),
      slots: slot_count(world),
      operators: operator_count(world),
      runs: run_rows(world)
    }
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

  defp slot_count(world) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.organization_id == ^world.organization.id and d.gtfs_version_id == ^world.version.id,
        select: count(d.id)
      )
    )
  end

  defp operator_count(world) do
    Repo.one(
      from(o in Operator,
        where: o.organization_id == ^world.organization.id,
        select: count(o.id)
      )
    )
  end

  defp run_rows(world) do
    Repo.all(
      from(r in TripRun,
        where:
          r.organization_id == ^world.organization.id and r.gtfs_version_id == ^world.version.id,
        select: {r.day_type_key, r.trip_id, r.run_id},
        order_by: [r.day_type_key, r.trip_id]
      )
    )
  end
end
