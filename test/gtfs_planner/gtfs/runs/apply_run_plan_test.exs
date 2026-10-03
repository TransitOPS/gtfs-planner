defmodule GtfsPlanner.Gtfs.Runs.ApplyRunPlanTest do
  @moduledoc """
  Applying a runs plan is atomic and refuses a plan the day has moved past.

  `plan_test.exs` shows the fingerprint reacts to each input and
  `suggest_runs_test.exs` shows suggesting writes nothing. These cases show that
  applying checks the fingerprint, so a plan cannot be applied to a day it was not
  computed for.

  Each input is edited through its real writer, and that is the whole design. A
  staleness test that edited a row behind the application's back would prove the
  fingerprint covers a column; editing through `Blocking.apply_block_change/4`,
  `update_crew_settings/3`, `put_deadhead_time/4` and the rest proves it covers
  the *inputs* those writers change, which is what a planner's colleague actually
  does.

  The `:write_failed` case is equally deliberate: a plan of more than 500 moves
  whose last batch carries a run ID the database refuses, so earlier batches
  really were written and really were rolled back.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/apply_run_plan_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.TripRun

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  setup do
    world = runs_version_fixture()
    actor = editor_fixture(world.organization)

    for trip <- world.blocks["101"] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: "1001"
      })
    end

    %{world: world, actor: actor}
  end

  defp audit(world, actor) do
    %AuditContext{
      organization_id: world.organization.id,
      gtfs_version_id: world.version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp all_rows(world) do
    Repo.all(
      from(row in TripRun,
        where:
          row.organization_id == ^world.organization.id and
            row.gtfs_version_id == ^world.version.id,
        select: {row.trip_id, row.day_type_key, row.run_id},
        order_by: [asc: row.trip_id]
      )
    )
  end

  defp suggest(world, scope) do
    {:ok, plan} =
      Gtfs.suggest_runs(world.organization.id, world.version.id, world.day_type_key, scope)

    plan
  end

  describe "applying a fresh plan" do
    test "writes exactly its moves", %{world: world} do
      plan = suggest(world, :uncovered_only)
      assert plan.moves != []

      assert {:ok, %{changed_trips: changed, undo: undo}} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert changed == length(plan.moves)

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      for move <- plan.moves do
        assert runs_day.assignments[move.trip_id] == move.to
      end

      # And the day is now what the plan said it would be.
      assert runs_day.derived.stats == plan.after
      assert undo != []
    end

    test "is a no-op on a plan with no moves, and leaves the plan applicable", %{world: world} do
      plan = suggest(world, :uncovered_only)
      before = all_rows(world)

      assert {:ok, %{changed_trips: 0, undo: []}} =
               Gtfs.apply_run_plan(world.audit, %{plan | moves: []})

      assert all_rows(world) == before

      # The empty plan wrote nothing, so it did not invalidate itself: the real
      # plan still applies. This is the flip side of the `updated_at` rule - a
      # write that changes nothing leaves the fingerprint alone.
      assert {:ok, %{changed_trips: changed}} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert changed == length(plan.moves)
    end
  end

  describe "staleness" do
    # Each of these edits one covered input through the writer a planner's
    # colleague would actually use, and then asserts the earlier plan is refused
    # and nothing moved.
    test "a trip's block", %{world: world, actor: actor} do
      plan = suggest(world, :uncovered_only)
      before = all_rows(world)

      assert {:ok, _} =
               Blocking.apply_block_change(
                 world.day_type_key,
                 {:unassign, [hd(world.blocks["102"]).id]},
                 audit(world, actor)
               )

      assert {:error, :stale_plan} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert all_rows(world) == before
    end

    test "the day type's run assignments", %{world: world} do
      plan = suggest(world, :uncovered_only)

      # A colleague moves a trip the plan did not touch. The plan is stale, the
      # colleague's write stands, and the plan adds nothing of its own.
      assert {:ok, _} =
               Gtfs.apply_run_moves(world.audit, world.day_type_key, [
                 %{trip_id: hd(world.blocks["101"]).id, from: "1001", to: "9999"}
               ])

      after_their_write = all_rows(world)

      assert {:error, :stale_plan} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert all_rows(world) == after_their_write
    end

    test "a crew rule", %{world: world} do
      plan = suggest(world, :uncovered_only)
      before = all_rows(world)

      assert {:ok, _} =
               Runs.update_crew_settings(
                 world.audit,
                 %{max_spread_minutes: 600}
               )

      assert {:error, :stale_plan} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert all_rows(world) == before
    end

    test "a Block rules setting", %{world: world} do
      plan = suggest(world, :uncovered_only)
      before = all_rows(world)

      assert {:ok, _} =
               Blocking.update_settings(world.audit, %{
                 min_layover_minutes: 9
               })

      assert {:error, :stale_plan} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert all_rows(world) == before
    end

    test "a relief point", %{world: world} do
      plan = suggest(world, :uncovered_only)
      before = all_rows(world)

      assert {:ok, :ok} =
               Blocking.update_relief_settings(
                 world.audit,
                 world.day_type_key,
                 %{max_piece_minutes: 330, marked: [world.relief_stop_id, "MS"]}
               )

      assert {:error, :stale_plan} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert all_rows(world) == before
    end

    test "a driving time", %{world: world} do
      plan = suggest(world, :uncovered_only)
      before = all_rows(world)

      assert {:ok, _} =
               Blocking.put_deadhead_time(
                 world.audit,
                 {"stop:VC", "stop:MS"},
                 20
               )

      assert {:error, :stale_plan} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert all_rows(world) == before
    end

    test "a block attribute", %{world: world, actor: actor} do
      plan = suggest(world, :uncovered_only)
      before = all_rows(world)

      assert {:ok, _} =
               Blocking.set_block_attributes(
                 world.day_type_key,
                 "101",
                 %{vehicle_type_id: nil, garage_id: world.garage.id},
                 audit(world, actor)
               )

      assert {:error, :stale_plan} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert all_rows(world) == before
    end

    test "another organization's version is not found and writes nothing", %{world: world} do
      theirs = runs_version_fixture()
      plan = suggest(theirs, :uncovered_only)
      before = all_rows(theirs)

      assert {:error, :not_found} =
               Gtfs.apply_run_plan(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                   world.organization.id,
                   theirs.version.id
                 ),
                 plan
               )

      assert all_rows(theirs) == before
    end
  end

  describe "invalid trips" do
    test "a move naming a trip of another day type writes nothing", %{world: world} do
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

      plan = suggest(world, :uncovered_only)
      before = all_rows(world)

      # The fingerprint covers the world, not the plan's moves, so a hand-edited
      # move is not what staleness detects — it is the trip check.
      tampered = %{plan | moves: plan.moves ++ [%{trip_id: saturday.id, from: nil, to: "2001"}]}

      assert {:error, {:invalid_trips, [saturday_id]}} =
               Gtfs.apply_run_plan(world.audit, tampered)

      assert saturday_id == saturday.id
      assert all_rows(world) == before
    end
  end

  describe "day type scoping" do
    test "a Weekday plan leaves Saturday rows unchanged", %{world: world} do
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

      saturday_trip_run =
        trip_run_fixture(world.organization.id, world.version.id, %{
          trip: saturday,
          day_type_key: saturday_key,
          run_id: "101"
        })

      plan = suggest(world, :uncovered_only)

      assert {:ok, _} = Gtfs.apply_run_plan(world.audit, plan)

      still_there =
        Repo.one(
          from(row in TripRun,
            where: row.id == ^saturday_trip_run.id,
            select: row.run_id
          )
        )

      assert still_there == "101"
    end
  end

  describe "undo" do
    test "the returned undo applied through apply_moves/4 restores the previous rows", %{
      world: world
    } do
      before = all_rows(world)
      plan = suggest(world, :uncovered_only)

      assert {:ok, %{undo: undo}} =
               Gtfs.apply_run_plan(world.audit, plan)

      refute all_rows(world) == before

      assert {:ok, _} =
               Gtfs.apply_run_moves(
                 world.audit,
                 world.day_type_key,
                 undo
               )

      assert all_rows(world) == before
    end
  end

  describe "a plan larger than one batch" do
    setup %{world: world} do
      # 510 extra blocked trips, so the replace_all plan is more than 500 moves
      # and really is written in batches. Each is a trip plus its stop times.
      for index <- 1..510 do
        blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
          trip_id: "bulk_#{index}",
          service_id: "WK",
          block_id: "102",
          first_arrival: "14:00:00",
          first_departure: "14:00:00",
          last_arrival: "14:30:00",
          last_departure: "14:30:00"
        })
      end

      :ok
    end

    test "the same plan applies cleanly without the corruption", %{world: world} do
      plan = suggest(world, :replace_all)
      assert length(plan.moves) > 500
      before = all_rows(world)

      # The control for the next test: the batching really does write all of
      # them, so the rollback there is the rollback of real work rather than of
      # a plan that was never applied.
      assert {:ok, %{changed_trips: changed}} =
               Gtfs.apply_run_plan(world.audit, plan)

      assert changed == length(plan.moves)
      refute all_rows(world) == before
    end

    test "a bad run ID in the last batch rolls the whole plan back", %{world: world} do
      plan = suggest(world, :replace_all)
      assert length(plan.moves) > 500

      before = all_rows(world)

      # The fingerprint covers the day, not the plan's moves, so corrupting a
      # move leaves it fresh — and the run ID reaches the database, where the
      # named check constraint refuses it.
      corrupted = List.update_at(plan.moves, -1, &%{&1 | to: "BAD ID"})

      assert {:error, :write_failed} =
               Gtfs.apply_run_plan(world.audit, %{
                 plan
                 | moves: corrupted
               })

      # Every row is what it was, which is the point: the earlier batches were
      # written and then rolled back.
      assert all_rows(world) == before
    end
  end
end
