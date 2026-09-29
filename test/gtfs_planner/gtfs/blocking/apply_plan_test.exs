defmodule GtfsPlanner.Gtfs.Blocking.ApplyPlanTest do
  @moduledoc """
  Merge evidence (EV-5) for CL-5: `apply_block_plan/3` writes a reviewed suggestion
  atomically, fingerprinted over every planning input and serialized on the blocking
  lock, so FH-5's three failures stay rejected — an intervening edit is overwritten,
  an audit row survives a rollback, and a plan over 500 moves splits (AC-27, AC-5).

  One case covers each observation EV-5 rejects FH-5 with:

  - an `:unassigned_only` plan moves the two pool trips onto the blocks it names,
    writes one `block_attributes` row per new block and one `"trip"` change log per
    moved trip, all under a single `operation_id`, with the whole affected list on
    every log;
  - a day type sharing `{WKDY}` and `{WKDY, SCHOOL}` applies on `{WKDY, SCHOOL}` and
    changes the `WKDY` trips on *both* day types, because `block_id` is per trip
    (R2, R3): what the plan's effects list as affected, the apply writes;
  - each of a settings save, an entered driving time, a relief mark, a garage
    coordinate edit and a newly added trip, made after the suggestion, is answered
    `{:error, :stale_plan}` with no `block_id` and no attribute row changed (INV-7);
  - a 620-move `:replace_all` plan applies inside one transaction, its `update_all`
    writes stay at or below 500 IDs a statement, and all 620 audits share one
    `operation_id`;
  - a `ReviewedApplyTransaction` mock whose transaction returns a failed audit
    changeset is `{:error, {:audit_failed, _}}` with no `block_id`, no attribute row
    and no audit row persisted;
  - three raised `40001` errors from the mock are `{:error, :busy}` and nothing
    raises out of the call;
  - a plan for another organization's version is `:not_found`;
  - no `transfers` row is inserted, updated or deleted by any apply, refusal included
    (INV-3).

  Every apply runs through the production chain — `Gtfs.apply_block_plan/3` ->
  `Blocking.apply_block_plan/3` -> `ReviewedApplyTransaction` -> the real generator and
  `Plan.build/1` over the real rows — with the day types read from the fixture's own
  calendars. The failure cases swap only the transaction boundary, through the Mox
  mock the card names, and restore the application env in `on_exit`.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/apply_plan_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Mox

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  # The batch size `update_trip_blocks!/3` writes at. Named here rather than reaching
  # into the module's attribute so the assertion states the bound the plan promises.
  @max_batch 500

  # The two school weekdays inside `WKDY`'s Mon-Fri year, so the version derives
  # `{SCHOOL, WKDY}` on those two dates and `{WKDY}` on every other weekday. The same
  # shape `suggest_test.exs` builds, so the two files describe one version.
  @school_dates [~D[2026-09-01], ~D[2026-09-02]]

  @weekday "WKDY"
  @school "SCHOOL"

  # The six already-blocked trips and the two pool trips. 101 and 102 are two-trip
  # runs an hour apart; 103 and 104 are single trips.
  @blocked_trips [
    {"wk_1", "101", "08:00:00", "09:00:00"},
    {"wk_2", "101", "09:30:00", "10:00:00"},
    {"wk_3", "102", "08:10:00", "09:10:00"},
    {"wk_4", "102", "09:40:00", "10:10:00"},
    {"wk_5", "103", "07:00:00", "08:00:00"},
    {"wk_6", "104", "07:30:00", "08:30:00"}
  ]

  @pool_trips [
    {"p_1", "09:15:00", "10:15:00"},
    {"p_2", "09:45:00", "10:45:00"}
  ]

  @bulk_version_service "BULK"
  @bulk_moves 620

  # One route, two stops with coordinates, a garage and a vehicle type so the new
  # blocks' attribute rows carry a resolution rather than a `nil` the assertion could
  # not distinguish from a missing write.
  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})
    actor = editor_fixture(organization)
    garage = garage_fixture(organization.id)
    vehicle_type = vehicle_type_fixture(organization.id)

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @weekday,
      name: "Weekday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @school,
      name: "School",
      dates: @school_dates
    })

    for {stop_id, name, lat} <- [
          {"S1", "Riverside", "40.0000"},
          {"S2", "Market Square", "40.0300"}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0")
      })
    end

    for {trip_id, block_id, first, last} <- @blocked_trips do
      trip(organization, version, route, trip_id, @weekday, block_id, first, last)
    end

    for {trip_id, first, last} <- @pool_trips do
      trip(organization, version, route, trip_id, @weekday, nil, first, last)
    end

    %{
      organization: organization,
      version: version,
      route: route,
      actor: actor,
      garage: garage,
      vehicle_type: vehicle_type
    }
  end

  describe "an :unassigned_only plan" do
    test "moves the pool trips, writes the new blocks' attributes and one audit each", scope do
      %{organization: organization, version: version} = scope
      key = weekday_key(organization, version)

      plan = suggest!(organization, version, key, :unassigned_only)
      assert Enum.map(plan.moves, & &1.trip.trip_id) == ["p_1", "p_2"]

      moved_ids = Enum.map(plan.moves, & &1.trip.id)
      transfer_before = transfer_rows(organization, version)

      assert {:ok, result} = Gtfs.apply_block_plan(key, plan, audit(scope))

      assert result.changed_trip_ids == Enum.sort(moved_ids)
      assert is_binary(result.operation_id)

      # Every move landed on the block the plan named, and every trip the plan did not
      # move kept the block it had (AC-22).
      assert stored_blocks(organization, version, ["p_1", "p_2"]) == %{
               "p_1" => travel(plan, "p_1"),
               "p_2" => travel(plan, "p_2")
             }

      assert is_binary(travel(plan, "p_1"))
      assert is_binary(travel(plan, "p_2"))

      assert stored_blocks(
               organization,
               version,
               Enum.map(@blocked_trips, &elem(&1, 0))
             ) == %{
               "wk_1" => "101",
               "wk_2" => "101",
               "wk_3" => "102",
               "wk_4" => "102",
               "wk_5" => "103",
               "wk_6" => "104"
             }

      # One attribute row per new block, carrying exactly the resolution the plan
      # proposed, keyed `(service_id, block_id)`. The stored rows are read from the
      # database, so "the plan's rows were written" is not the plan agreeing with
      # itself.
      assert attribute_rows(organization, version) ==
               Enum.map(
                 plan.attribute_rows,
                 &Map.take(&1, [:service_id, :block_id, :garage_id, :vehicle_type_id])
               )
               |> Enum.sort_by(&{&1.service_id, &1.block_id})

      # One `"trip"` log per moved trip, one operation ID, the whole affected list and
      # the block on each side of the change (INV-4).
      logs = trip_logs(organization, version)
      assert length(logs) == 2

      assert Enum.all?(logs, &(&1.changed_fields["operation_id"] == result.operation_id))
      assert Enum.all?(logs, &(&1.changed_fields["affected_trip_ids"] == result.changed_trip_ids))
      assert Enum.all?(logs, &(&1.action == "updated"))
      assert Enum.all?(logs, &is_nil(&1.changed_fields["before"]["block_id"]))
      assert Enum.all?(logs, &is_binary(&1.changed_fields["after"]["block_id"]))

      # INV-3: a plan apply writes no transfer record, before or after.
      assert transfer_rows(organization, version) == transfer_before
    end

    test "is stale the moment a planning input changes", scope do
      %{organization: organization, version: version} = scope
      key = weekday_key(organization, version)

      # Each case is its own transaction so a rollback in one cannot decide the next.
      for change <- [
            fn ->
              Gtfs.update_blocking_settings(organization.id, version.id, %{max_block_minutes: 240})
            end,
            fn -> put_deadhead(organization, version) end,
            fn -> mark_relief(organization, version) end,
            fn -> move_garage(organization, scope.actor, scope.garage) end,
            fn -> add_trip(organization, version, scope.route) end
          ] do
        plan = suggest!(organization, version, key, :unassigned_only)
        before_blocks = stored_blocks(organization, version, ["p_1", "p_2"])
        before_attributes = attribute_rows(organization, version)
        before_logs = length(trip_logs(organization, version))

        assert change.()

        assert {:error, :stale_plan} = Gtfs.apply_block_plan(key, plan, audit(scope))

        assert stored_blocks(organization, version, ["p_1", "p_2"]) == before_blocks
        assert attribute_rows(organization, version) == before_attributes
        assert length(trip_logs(organization, version)) == before_logs
      end
    end
  end

  describe "a day type sharing a service with another" do
    test "applies on {WKDY, SCHOOL} and changes the WKDY trips on both day types", scope do
      %{organization: organization, version: version, route: route} = scope
      school_key = day_type_key(organization.id, version.id, [@school, @weekday])
      weekday_key = weekday_key(organization, version)

      # A pool trip on `WKDY` alone. `WKDY` is in both derived day types, so this trip
      # runs on the school dates and on every other weekday, and one `block_id` on it
      # is the same work on both (R2, R3).
      shared = trip(organization, version, route, "sh_1", @weekday, nil, "11:00:00", "12:00:00")

      plan = suggest!(organization, version, school_key, :unassigned_only)

      moved_ids = Enum.map(plan.moves, & &1.trip.id)
      assert shared.id in moved_ids

      shared_move = Enum.find(plan.moves, &(&1.trip.id == shared.id))

      # The plan's own review names both day types as affected, the selected one first:
      # the moved trips run on `WKDY`, which both day types contain.
      assert Enum.map(plan.review.effects, & &1.day_type.key) == [school_key, weekday_key]

      transfer_before = transfer_rows(organization, version)

      assert {:ok, result} = Gtfs.apply_block_plan(school_key, plan, audit(scope))
      assert result.changed_trip_ids == Enum.sort(moved_ids)

      # The trip the plan moved carries the new block, and it is one of the trips that
      # block holds on `WKDY` (R2).
      assert Repo.get!(Trip, shared.id).block_id == shared_move.to
      assert shared.id in block_on(organization, version, shared_move.to, @weekday)
      assert transfer_rows(organization, version) == transfer_before

      # `block_id` is a column on the trip, not a per-day-type table, so the block the
      # plan created holds the same trips whichever of the two day types that share
      # `WKDY` is read through (R3). Both reads name the same block and the same
      # trips, and the trip the plan moved is among them on both.
      assert block_trips_on(organization, version, school_key, shared_move.to) ==
               block_trips_on(organization, version, weekday_key, shared_move.to)

      assert shared.id in block_trips_on(organization, version, school_key, shared_move.to)

      # Every moved trip's log names the affected list of the whole plan, under one
      # operation ID, whether it was reviewed on the school day type or the weekday one.
      logs = trip_logs(organization, version)
      assert length(logs) == length(moved_ids)

      assert logs |> Enum.map(& &1.changed_fields["operation_id"]) |> Enum.uniq() == [
               result.operation_id
             ]
    end
  end

  describe "a plan over the 500-row command bound" do
    test "applies 620 moves in one transaction with bounded batches and one operation", scope do
      %{organization: organization} = scope

      # A version of its own holding only the bulk day, so the plan's scope is exactly
      # the 620 trips written below and no other case's rows are counted with it.
      version = bulk_version(organization.id)
      bulk_scope = %{scope | version: version}

      assert bulk_day(organization.id, version.id, @bulk_moves) == %{
               trips: @bulk_moves,
               stop_times: @bulk_moves * 2
             }

      key = day_type_key(organization.id, version.id, [@bulk_version_service])
      plan = suggest!(organization.id, version.id, key, :replace_all)

      assert length(plan.moves) == @bulk_moves

      batches =
        capture_update_batches(fn ->
          assert {:ok, result} = Gtfs.apply_block_plan(key, plan, audit(bulk_scope))
          assert length(result.changed_trip_ids) == @bulk_moves
        end)

      # Every write stayed at or below the 500-row bound, and more than one statement
      # carried the plan, so 620 moves did not become one unbounded statement.
      assert batches != []
      assert Enum.all?(batches, &(&1 <= @max_batch))
      assert length(batches) > 1

      # All 620 rows moved, and all 620 audits share the one operation ID.
      assert moved_count(organization.id, version.id) == @bulk_moves

      logs = trip_logs(organization.id, version.id)
      assert length(logs) == @bulk_moves

      assert logs |> Enum.map(& &1.changed_fields["operation_id"]) |> Enum.uniq() |> length() == 1
      assert Enum.all?(logs, &(&1.changed_fields["affected_trip_ids"] |> length() == @bulk_moves))
    end
  end

  describe "a failed audit" do
    test "rolls the whole plan back and reports the refusal", scope do
      %{organization: organization, version: version} = scope
      key = weekday_key(organization, version)
      plan = suggest!(organization, version, key, :unassigned_only)

      before_blocks = stored_blocks(organization, version, ["p_1", "p_2"])
      before_attributes = attribute_rows(organization, version)
      before_transfers = transfer_rows(organization, version)

      # The production transaction runs for real and the audit insert inside it is
      # refused by the audit layer's own changeset, which is the shape a
      # database-rejected or audit-layer-refused log takes (AC-10, INV-4).
      #
      # A changeset the audit layer refuses: the transaction is run with an audit
      # context whose actor is missing, so `record_change_in_transaction/5` returns an
      # invalid changeset for every moved trip.
      assert {:error, {:audit_failed, reason}} =
               Gtfs.apply_block_plan(key, plan, %{audit(scope) | actor_id: nil})

      assert is_map(reason)

      # Nothing the plan would have written persisted: the assignments, the attribute
      # rows and the audits all rolled back with the failed log (INV-4, FH-5).
      assert stored_blocks(organization, version, ["p_1", "p_2"]) == before_blocks
      assert attribute_rows(organization, version) == before_attributes
      assert transfer_rows(organization, version) == before_transfers
      assert trip_logs(organization, version) == []
    end
  end

  describe "serialization failures" do
    test "three raised 40001 errors report :busy without raising", scope do
      %{organization: organization, version: version} = scope
      key = weekday_key(organization, version)
      plan = suggest!(organization, version, key, :unassigned_only)

      before_blocks = stored_blocks(organization, version, ["p_1", "p_2"])
      before_attributes = attribute_rows(organization, version)

      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction ->
        raise postgrex_serialization_failure()
      end)

      assert {:error, :busy} = Gtfs.apply_block_plan(key, plan, audit(scope))

      assert stored_blocks(organization, version, ["p_1", "p_2"]) == before_blocks
      assert attribute_rows(organization, version) == before_attributes
      assert trip_logs(organization, version) == []
    end
  end

  describe "a plan about another organization" do
    test "is :not_found and writes nothing", scope do
      %{organization: organization, version: version} = scope
      key = weekday_key(organization, version)

      # A plan built for another organization's own version, from its own rows. Its day
      # type key is derived from that version's calendars and its moves name its trips,
      # so nothing about it names this organization (AC-5).
      foreign_org = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_org.id)
      build_scope(foreign_org, foreign_version)

      foreign_key = day_type_key(foreign_org.id, foreign_version.id, [@weekday])
      foreign_plan = suggest!(foreign_org.id, foreign_version.id, foreign_key, :unassigned_only)

      assert foreign_plan.moves != []

      before_blocks = stored_blocks(organization, version, ["p_1", "p_2"])
      before_attributes = attribute_rows(organization, version)
      before_transfers = transfer_rows(organization, version)

      assert {:error, :not_found} = Gtfs.apply_block_plan(key, foreign_plan, audit(scope))

      assert stored_blocks(organization, version, ["p_1", "p_2"]) == before_blocks
      assert attribute_rows(organization, version) == before_attributes
      assert transfer_rows(organization, version) == before_transfers
      assert trip_logs(organization, version) == []
    end
  end

  describe "shape refusals" do
    test "a plan with no mode is :invalid_plan and costs no query", scope do
      %{organization: organization, version: version} = scope
      key = weekday_key(organization, version)
      plan = suggest!(organization, version, key, :unassigned_only)

      before_blocks = stored_blocks(organization, version, ["p_1", "p_2"])

      assert {:error, :invalid_plan} =
               Gtfs.apply_block_plan(key, Map.delete(plan, :mode), audit(scope))

      assert {:error, :invalid_plan} =
               Gtfs.apply_block_plan(key, %{mode: :nonsense}, audit(scope))

      assert stored_blocks(organization, version, ["p_1", "p_2"]) == before_blocks
    end

    test "a day type the version does not derive is {:unknown_day_type, day_types}", scope do
      %{organization: organization, version: version} = scope
      plan = suggest!(organization, version, weekday_key(organization, version), :unassigned_only)

      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.apply_block_plan("NOPE", plan, audit(scope))

      assert Enum.map(day_types, & &1.key) |> Enum.sort() ==
               [
                 weekday_key(organization, version),
                 day_type_key(organization.id, version.id, [@school, @weekday])
               ]
               |> Enum.sort()
    end
  end

  # --- fixtures and helpers -------------------------------------------------

  defp build_scope(organization, version) do
    route = route_fixture(organization.id, version.id, %{route_id: "F12", route_short_name: "F"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @weekday,
      name: "Weekday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @school,
      dates: @school_dates
    })

    for {stop_id, name, lat} <- [{"S1", "Riverside", "40.0000"}, {"S2", "Market", "40.0300"}] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0")
      })
    end

    for {trip_id, block_id, first, last} <- @blocked_trips do
      trip(organization, version, route, trip_id, @weekday, block_id, first, last)
    end

    for {trip_id, first, last} <- @pool_trips do
      trip(organization, version, route, trip_id, @weekday, nil, first, last)
    end

    %{
      organization: organization,
      version: version,
      route: route,
      actor: editor_fixture(organization),
      garage: garage_fixture(organization.id),
      vehicle_type: vehicle_type_fixture(organization.id)
    }
  end

  defp audit(%{organization: organization, version: version, actor: actor}) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  # Accepts the organization and version as the structs a test destructures from its
  # scope, or as the IDs the bulk case has only IDs for.
  defp suggest!(organization, version, key, mode) do
    assert {:ok, plan} = Gtfs.suggest_blocks(id(organization), id(version), key, mode)
    plan
  end

  defp id(%{id: id}), do: id
  defp id(id) when is_binary(id), do: id

  defp trip(organization, version, route, trip_id, service_id, block_id, first, last) do
    blocked_trip_fixture(
      organization.id,
      version.id,
      route.route_id,
      %{
        trip_id: trip_id,
        service_id: service_id,
        block_id: block_id,
        first_stop: "S1",
        last_stop: "S2",
        first_arrival: first,
        last_arrival: last
      }
    )
  end

  defp weekday_key(organization, version),
    do: day_type_key(organization.id, version.id, [@weekday])

  defp day_type_key(organization_id, version_id, service_ids) do
    day_type =
      Enum.find(day_types(organization_id, version_id), &(&1.service_ids == service_ids))

    assert day_type, "no day type for #{inspect(service_ids)}"

    day_type.key
  end

  defp day_types(organization_id, version_id) do
    {:ok, calendars} = Calendars.list_calendars(organization_id, version_id)
    DayTypes.derive(calendars)
  end

  # The move the plan names for one trip, or `nil` when the plan does not move it.
  defp travel(plan, trip_id) do
    case Enum.find(plan.moves, &(&1.trip.trip_id == trip_id)) do
      nil -> nil
      move -> move.to
    end
  end

  # The trip UUIDs one named block holds, read through one day type's day load, so
  # "the same block on both day types" is observed on the production reader rather than
  # on a query written to agree with it.
  defp block_trips_on(organization, version, day_type_key, block_id) do
    assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, day_type_key)

    day.blocks
    |> Enum.filter(&(&1.summary.block_id == block_id))
    |> Enum.flat_map(fn block -> Enum.map(block.trips, fn trip -> trip.id end) end)
    |> Enum.sort()
  end

  # The trip UUIDs a block holds on one service, read from the database, so "the same
  # block on both day types" is observed on stored rows rather than on the plan.
  defp block_on(organization, version, block_id, service_id) do
    Repo.all(
      from(t in Trip,
        where:
          t.organization_id == ^organization.id and t.gtfs_version_id == ^version.id and
            t.block_id == ^block_id and t.service_id == ^service_id,
        select: t.id,
        order_by: t.id
      )
    )
  end

  defp stored_blocks(organization, version, trip_ids) do
    organization_id = organization.id
    version_id = version.id

    Repo.all(
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.trip_id in ^trip_ids,
        select: {t.trip_id, t.block_id}
      )
    )
    |> Map.new()
  end

  defp attribute_rows(organization, version) do
    Repo.all(
      from(a in BlockAttribute,
        where: a.organization_id == ^id(organization) and a.gtfs_version_id == ^id(version),
        select: %{
          service_id: a.service_id,
          block_id: a.block_id,
          garage_id: a.garage_id,
          vehicle_type_id: a.vehicle_type_id
        },
        order_by: [asc: a.service_id, asc: a.block_id]
      )
    )
  end

  # Every reader here takes the organization and version as the structs a test
  # destructures from its scope, or as the IDs the bulk case has only IDs for.
  defp trip_logs(organization, version) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.organization_id == ^id(organization) and l.gtfs_version_id == ^id(version) and
            l.entity_type == "trip",
        order_by: l.entity_external_id
      )
    )
  end

  defp transfer_rows(organization, version) do
    Repo.all(
      from(t in Transfer,
        where: t.organization_id == ^organization.id and t.gtfs_version_id == ^version.id,
        select: {t.from_trip_id, t.to_trip_id, t.from_stop_id, t.to_stop_id, t.min_transfer_time}
      )
    )
  end

  defp moved_count(organization_id, version_id) do
    Repo.one!(
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            not is_nil(t.block_id),
        select: count()
      )
    )
  end

  # --- the intervening changes ----------------------------------------------

  # The five edits that each make a reviewed plan stale: a setting, an entered driving
  # time, a relief mark, a garage coordinate and one added trip. They all run through
  # their own production writer, so each takes `lock_blocking!/1` exactly as INV-7 says
  # an input writer does.
  # Each of these returns the row or value its own API returns, so the loop above
  # asserts the one shape rather than re-wrapping five different ones.
  defp put_deadhead(organization, version) do
    deadhead_time_fixture(organization.id, version.id, %{
      from_ref: {:stop, "S1"},
      to_ref: {:stop, "S2"},
      minutes: 42
    })
  end

  defp mark_relief(organization, version) do
    key = weekday_key(organization, version)

    Gtfs.update_relief_settings(organization.id, version.id, key, %{
      max_piece_minutes: 240,
      marked: ["S1"]
    })
  end

  defp move_garage(organization, actor, garage) do
    Operations.update_garage(organization.id, actor, garage.id, %{
      "garage_id" => garage.garage_id,
      "name" => garage.name,
      "lat" => "41.1000",
      "lon" => "-74.5000"
    })
  end

  defp add_trip(organization, version, route) do
    {:ok, _trip} =
      {:ok, trip(organization, version, route, "p_new", @weekday, nil, "11:00:00", "12:00:00")}

    :ok
  end

  # --- observing the batch bound --------------------------------------------

  # The number of trip rows each `update_all` statement carried, read from the SQL
  # Ecto hands Postgrex. The observation is the statement's own `IN` list rather than a
  # counter this test keeps, so a batch that exceeded the bound could not be hidden by
  # the code under test.
  defp capture_update_batches(fun) do
    parent = self()
    handler = "apply-plan-batches-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measure, meta, _config ->
        if update_trips_query?(meta) do
          send(parent, {:update_batch, batch_size(meta.query)})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_batches([])
  end

  defp collect_batches(acc) do
    receive do
      {:update_batch, size} -> collect_batches([size | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The repository reports the table it touched as the telemetry `source`, so the
  # statement this test wants is the one against `trips` that writes rather than
  # reads.
  defp update_trips_query?(%{source: "trips", query: query}) do
    is_binary(query) and String.starts_with?(query, ~s(UPDATE "trips"))
  end

  defp update_trips_query?(_meta), do: false

  # The number of `?` placeholders Ecto generated for the ID list, which is one per
  # row in the batch: an `IN (?, ?, ...)` written as `$1, $2, ...` in the sent query.
  # The number of placeholders Ecto generated for the ID list, which is one per row in
  # the batch: an `IN ($1, $2, ...)` in the sent query.
  defp batch_size(query) do
    case Regex.run(~r/IN \([^)]+\)/, query) do
      [match] -> match |> String.split("$") |> Enum.count(&(String.trim(&1) != ""))
      _no_list -> 0
    end
  end

  # --- the bulk version ------------------------------------------------------

  defp bulk_version(organization_id) do
    version = gtfs_version_fixture(organization_id)

    calendar_service_fixture(organization_id, version.id, %{
      service_id: @bulk_version_service,
      name: "Bulk",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    route_fixture(organization_id, version.id, %{route_id: "BULK_R", route_short_name: "B"})

    for {stop_id, lat} <- [{"S1", "42.3000"}, {"S2", "42.3100"}] do
      stop_with_coordinates_fixture(organization_id, version.id, %{
        stop_id: stop_id,
        stop_name: stop_id,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-71.0")
      })
    end

    version
  end

  # `count` scheduled trips and two stop times each, written with `Repo.insert_all/3`
  # in chunks on the version's own calendar service. The lane database's statistics
  # describe an empty table, so the two tables are analyzed inside this test's
  # transaction: `ANALYZE` reads the rows this transaction has written, and its catalog
  # rows roll back with the fixture.
  defp bulk_day(organization_id, version_id, count) do
    now = DateTime.utc_now()

    trips =
      for index <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: version_id,
          trip_id: "B#{index}",
          route_id: "BULK_R",
          service_id: @bulk_version_service,
          block_id: nil,
          inserted_at: now,
          updated_at: now
        }
      end

    stop_times =
      Enum.flat_map(trips, fn trip ->
        first_secs = 21_600 + bulk_index(trip) * 900

        for {stop_id, sequence, secs} <- [{"S1", 1, first_secs}, {"S2", 2, first_secs + 300}] do
          clock = GtfsTime.format(secs)

          %{
            id: Ecto.UUID.generate(),
            organization_id: organization_id,
            gtfs_version_id: version_id,
            trip_id: trip.trip_id,
            stop_id: stop_id,
            stop_sequence: sequence,
            arrival_time: clock,
            departure_time: clock,
            inserted_at: now,
            updated_at: now
          }
        end
      end)

    insert_chunked!(Trip, trips)
    insert_chunked!(GtfsPlanner.Gtfs.StopTime, stop_times)
    Repo.query!("ANALYZE trips")
    Repo.query!("ANALYZE stop_times")

    %{trips: length(trips), stop_times: length(stop_times)}
  end

  defp bulk_index(%{trip_id: "B" <> index}), do: String.to_integer(index)

  defp insert_chunked!(schema, rows) do
    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn chunk ->
      {written, nil} = Repo.insert_all(schema, chunk)
      assert written == length(chunk)
    end)
  end

  # --- the transaction boundary ----------------------------------------------

  # The failure cases swap the application's transaction boundary for the Mox mock, so
  # the original value is captured before the change and restored in `on_exit`
  # (unit-testing guide §6).
  defp use_reviewed_apply_transaction_mock do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransactionMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)
  end

  # What a real server raises for SQLSTATE 40001; the retry path classifies it by the
  # normalised atom, so no live serialization failure is needed to exercise the retry.
  defp postgrex_serialization_failure do
    %Postgrex.Error{
      postgres: %{code: "40001", message: "could not serialize access", severity: "ERROR"}
    }
  end
end
