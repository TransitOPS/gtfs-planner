defmodule GtfsPlanner.Gtfs.TodsGenerator.TransactionOperationsTest do
  @moduledoc """
  Step 5: a generation's block and run writes are transaction-local operations the
  caller's transaction owns.

  `Blocking.apply_generation_in_transaction!/3` and
  `Runs.apply_generation_in_transaction!/2` are the pieces a generation's save
  composes after it has rebuilt the authoritative candidate under its locks. They
  open no transaction and keep no fingerprint, so the failures specific to *them*
  are the ones a single-owner suite cannot see:

    * inside one caller-owned transaction the candidate's new block, its attribute
      row, its trip audits and its new run rows persist together, and a forced
      rollback of that outer transaction removes every one of them — the audit rows
      included — while a candidate's relief mark does the same beside the version's
      stored marks;
    * the operations refuse a delta that would replace a current manual
      assignment: a trip a planner has since blocked is `:stale_plan` rather than
      overwritten, and a trip a planner has since put in a run is `:stale_moves`,
      with nothing written in either case.

  Every case composes its delta from a real `Gtfs.preview_tods_generation/2`
  candidate over the fixture's own small schedule and then calls the production
  operations against the isolated test database. The delta's block IDs, run IDs
  and relief stops are the ones the preview named, never invented numbers; the
  `9001` the run-refusal case is refused over is the planner's own manual run.

  Run with:
  `mix test test/gtfs_planner/gtfs/tods_generator/transaction_operations_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.TodsGeneratorFixtures

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @moduletag timeout: 120_000

  describe "inside one caller-owned transaction" do
    test "the candidate's block, attribute row, runs and audits all roll back together" do
      world = tods_world_fixture(extra_trips: [weekday_trip()])
      audit = world.audit

      assert {:ok, preview} = preview(world, crew_inputs(world))

      # One new block for the trip the generator placed, and a run for every
      # uncovered trip of the day — the new block's own included.
      assert [block] = preview.blocks
      assert block.block_id == "103"
      assert Enum.map(block.trips, & &1.trip_id) == ["gen-a"]
      assert block.garage_id == world.garage.id
      assert preview.assignments == %{trip_uuid(world, "gen-a") => "103"}

      run_deltas = preview.run_deltas[world.weekday_day_type]
      assert map_size(run_deltas) > 1
      assert is_binary(run_deltas[trip_uuid(world, "gen-a")])

      before = generation_state(world)

      assert {:error, :forced_rollback} =
               Repo.transaction(fn ->
                 lock_caller_scope(world)

                 block_result =
                   Blocking.apply_generation_in_transaction!(
                     audit,
                     block_delta(preview),
                     preview.relief_additions
                   )

                 run_result = Runs.apply_generation_in_transaction!(audit, preview.run_deltas)

                 # Inside the transaction the writes are real: the assignment, the
                 # new block's attribute row, the run rows and one audit per moved
                 # trip all describe the candidate.
                 assert Map.take(block_ids(world), Map.keys(preview.assignments)) ==
                          preview.assignments

                 assert attributes(world) == [
                          %{
                            service_id: "WK",
                            block_id: "103",
                            garage_id: block.garage_id,
                            vehicle_type_id: block.vehicle_type_id
                          }
                        ]

                 assert run_ids(world) |> Map.take(Map.keys(run_deltas)) == run_deltas

                 logs = trip_logs(world)
                 assert length(logs) == map_size(preview.assignments)

                 assert logs |> Enum.map(& &1.changed_fields["operation_id"]) |> Enum.uniq() ==
                          [block_result.operation_id]

                 assert logs
                        |> Enum.flat_map(& &1.changed_fields["affected_trip_ids"])
                        |> Enum.uniq()
                        |> Enum.sort() ==
                          preview.assignments |> Map.keys() |> Enum.sort()

                 assert block_result.changed_trip_ids == Map.keys(preview.assignments)
                 assert block_result.relief_stop_ids == preview.relief_additions

                 assert run_result.changed_trips == map_size(run_deltas)

                 assert run_result.run_ids ==
                          run_deltas |> Map.values() |> Enum.uniq() |> Enum.sort()

                 Repo.rollback(:forced_rollback)
               end)

      # Nothing the candidate proposed survived the rollback, audits included.
      assert generation_state(world) == before
    end

    test "the candidate's relief marks roll back with the rest of the transaction" do
      world = crew_world_fixture(block: :long_duty, max_piece_minutes: 480)
      audit = world.audit

      assert {:ok, preview} = preview(world, crew_inputs(world, %{"terminal_relief?" => true}))

      # The stored 16-hour block is cut at a terminal the version does not mark, so
      # the candidate proposes exactly that mark beside the runs it adds. No block
      # is new, so the block delta is empty and the mark is the write this case
      # isolates.
      assert preview.relief_additions == [world.terminal_stop_id]
      assert block_delta(preview) == %{assignments: %{}, blocks: []}

      before = generation_state(world)
      refute world.terminal_stop_id in before.relief

      assert {:error, :forced_rollback} =
               Repo.transaction(fn ->
                 lock_caller_scope(world)

                 assert Blocking.apply_generation_in_transaction!(
                          audit,
                          block_delta(preview),
                          preview.relief_additions
                        ).relief_stop_ids == [world.terminal_stop_id]

                 Runs.apply_generation_in_transaction!(audit, preview.run_deltas)

                 # The mark is a stored row inside the transaction, beside the
                 # version's own existing mark.
                 assert world.terminal_stop_id in relief_stops(world)

                 Repo.rollback(:forced_rollback)
               end)

      assert generation_state(world) == before
    end
  end

  describe "a delta that is no longer additive" do
    test "a trip a planner has since blocked is :stale_plan and is not replaced" do
      world = tods_world_fixture(extra_trips: [weekday_trip()])
      audit = world.audit

      assert {:ok, preview} = preview(world, crew_inputs(world))
      uuid = trip_uuid(world, "gen-a")
      assert preview.assignments == %{uuid => "103"}

      # A planner assigns the trip by hand after the preview was composed, so the
      # candidate's move is no longer additive.
      assert :ok = assign_by_hand(world, uuid)
      assert blocked?(uuid)

      before = generation_state(world)

      assert {:error, :stale_plan} =
               Repo.transaction(fn ->
                 lock_caller_scope(world)

                 Blocking.apply_generation_in_transaction!(audit, block_delta(preview), [])
               end)

      # The planner's assignment stands and the candidate wrote nothing: no
      # attribute row for the block it wanted, no audit.
      assert generation_state(world) == before
    end

    test "a trip a planner has since put in a run is :stale_moves and is not replaced" do
      world = tods_world_fixture(extra_trips: [weekday_trip()])
      audit = world.audit

      assert {:ok, preview} = preview(world, crew_inputs(world))
      uuid = trip_uuid(world, "gen-a")
      assert is_binary(preview.run_deltas[world.weekday_day_type][uuid])

      # The trip has to be in a block before a run can hold it, so the planner
      # blocks it by hand and then puts it in a run of their own.
      assert :ok = assign_by_hand(world, uuid)

      assert {:ok, _} =
               Gtfs.apply_run_moves(audit, world.weekday_day_type, [
                 %{trip_id: uuid, from: nil, to: "9001"}
               ])

      before = generation_state(world)

      assert {:error, :stale_moves} =
               Repo.transaction(fn ->
                 lock_caller_scope(world)

                 Runs.apply_generation_in_transaction!(audit, preview.run_deltas)
               end)

      assert generation_state(world) == before
    end
  end

  # --- fixtures and helpers -------------------------------------------------

  # One unblocked weekday trip on the generator's own route and vehicle type, so
  # the generator opens one new block ("103") for it carrying the selected garage.
  defp weekday_trip, do: {"gen-a", "WK", "RIV", "RIV", "04:00:00", "04:30:00"}

  defp block_delta(preview), do: Map.take(preview, [:assignments, :blocks])

  defp trip_uuid(world, trip_id), do: Map.fetch!(world.trip_ids, trip_id)

  # The locks a generation's save holds before it calls the transaction-local
  # operations: the editor membership lock, the version `FOR SHARE` and the
  # blocking lock.
  defp lock_caller_scope(world) do
    Authorization.lock_editor!(world.audit)
    Versions.lock_for_input_write!(world.organization.id, world.version.id)
    :ok = Blocking.lock_blocking!(world.version.id)
  end

  # The planner's own write, and the confirmation the block review asks for when
  # the new block adds a problem.
  defp assign_by_hand(world, trip_id) do
    command = {:assign, [trip_id], :new}

    case Blocking.apply_block_change(world.weekday_day_type, command, world.audit) do
      {:ok, _result} ->
        :ok

      {:needs_confirmation, review} ->
        case Blocking.apply_block_change(
               world.weekday_day_type,
               command,
               world.audit,
               review.fingerprint
             ) do
          {:ok, _result} -> :ok
          other -> flunk("assigning the trip by hand was refused: #{inspect(other)}")
        end
    end
  end

  defp blocked?(uuid) do
    Repo.one!(from(t in Trip, where: t.id == ^uuid, select: not is_nil(t.block_id)))
  end

  # Every fact a generation would change, read from the database: the trips'
  # blocks, the attribute rows, the run rows, the marks and the audits.
  defp generation_state(world) do
    %{
      blocks: block_ids(world),
      attributes: attributes(world),
      runs: run_ids(world),
      relief: relief_stops(world),
      audits: audits(world)
    }
  end

  defp block_ids(world) do
    from(t in Trip, select: {t.id, t.block_id})
    |> scoped(world)
    |> Repo.all()
    |> Map.new()
  end

  defp attributes(world) do
    from(a in BlockAttribute,
      select: %{
        service_id: a.service_id,
        block_id: a.block_id,
        garage_id: a.garage_id,
        vehicle_type_id: a.vehicle_type_id
      },
      order_by: [asc: a.service_id, asc: a.block_id]
    )
    |> scoped(world)
    |> Repo.all()
  end

  # `trip_id => run_id` for the world's weekday day type, the shape one key of a
  # run delta is.
  defp run_ids(world) do
    from(r in TripRun,
      where: r.day_type_key == ^world.weekday_day_type,
      select: {r.trip_id, r.run_id}
    )
    |> scoped(world)
    |> Repo.all()
    |> Map.new()
  end

  defp relief_stops(world) do
    from(p in ReliefPoint, select: p.stop_id, order_by: p.stop_id)
    |> scoped(world)
    |> Repo.all()
  end

  defp audits(world), do: Enum.map(trip_logs(world), & &1.id)

  defp trip_logs(world) do
    from(l in ChangeLog,
      where: l.entity_type == "trip",
      order_by: l.entity_external_id
    )
    |> scoped(world)
    |> Repo.all()
  end

  defp scoped(query, world) do
    where(
      query,
      [r],
      field(r, :organization_id) == ^world.organization.id and
        field(r, :gtfs_version_id) == ^world.version.id
    )
  end
end
