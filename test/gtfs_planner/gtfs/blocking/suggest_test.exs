defmodule GtfsPlanner.Gtfs.Blocking.SuggestTest do
  @moduledoc """
  Merge evidence (EV-23) for CL-23: `suggest_blocks/4` reads the day type, scopes
  its trips by mode and refuses a selection or a scope it cannot answer, so
  FH-23's two failures — an empty selection rebuilding everything, and a huge scope
  running unbounded — stay rejected (AC-26).

  One case covers each observation EV-23 rejects FH-23 with:

  - `:unassigned_only` on a day type with four existing blocks and two pool trips
    moves exactly those two pool trips; every already-assigned trip keeps its block
    in the database and no move names one;
  - `{:selected, ["101", "102"]}` moves exactly those two blocks' trips, onto the
    same two numbers, and leaves the pool, the other blocks and the frequency trip
    where they are;
  - `{:selected, []}` and `{:selected, ["999"]}` are `:no_selection`, and a block the
    selected day type does not run is refused the same way while a block it does
    run is suggested;
  - `:replace_all` moves every non-frequency trip of the day type, and the
    frequency trip is neither moved nor stored anywhere else: it keeps its block and
    is reported as a `:repeating_service` leftover;
  - 3,001 trips in scope are refused as `{:too_large, 3001}`, and the refusal costs
    no plan: the scope is read and counted and the generator never runs;
  - a key the version does not derive is `{:unknown_day_type, day_types}` and
    nothing falls back to another day type (INV-6); a version of another
    organization is `:not_found`;
  - a suggestion writes nothing: the row counts of `trips`, `stop_times`,
    `frequencies`, `transfers`, `block_attributes` and `blocking_settings` are
    identical before and after every mode, including the refusals.

  The plans are built by the production chain — `Blocking.Generator.run/4` over the
  real rows and context and `Blocking.Plan.build/1` over the real review — through
  the ordinary `Gtfs.suggest_blocks/4` entry, and the day types come from the
  fixture's own calendars through `Calendars.list_calendars/3`, never hand-written.
  The "too large" case writes its 3,001 trips with `Repo.insert_all/3` inside this
  test's SQL Sandbox transaction, which rolls them back.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/suggest_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  # The two school weekdays inside `WKDY`'s Mon-Fri year, so the version derives
  # `{SCHOOL, WKDY}` on those two dates and `{WKDY}` on every other weekday.
  @school_dates [~D[2026-09-01], ~D[2026-09-02]]

  # The six trips already in blocks: 101 and 102 are two-trip runs an hour apart,
  # 103 and 104 are single trips. Block 105 is created for the frequency trip.
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

  @frequency_trip_id "wk_freq"
  @frequency_block "105"
  @school_block "201"

  # One route and two stops with coordinates, no garage and no vehicle type: every
  # drive between the two stops is the symmetric estimate, so a plan's blocks are
  # decided by the times and the minimum layover alone and no fixture detail can
  # change what a plan proposes.
  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WKDY",
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
      service_id: "SCHOOL",
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
      trip(organization, version, route, trip_id, "WKDY", block_id, first, last)
    end

    for {trip_id, first, last} <- @pool_trips do
      trip(organization, version, route, trip_id, "WKDY", nil, first, last)
    end

    frequency_trip =
      trip(
        organization,
        version,
        route,
        @frequency_trip_id,
        "WKDY",
        @frequency_block,
        "06:00:00",
        "06:30:00"
      )

    frequency_row_fixture(organization.id, version.id, %{trip_id: frequency_trip.trip_id})

    %{organization: organization, version: version, route: route}
  end

  describe ":unassigned_only" do
    test "moves the two pool trips and leaves every existing block as it was", scope do
      %{organization: organization, version: version} = scope
      key = day_type_key(organization, version, ["WKDY"])

      assert {:ok, plan} = Gtfs.suggest_blocks(organization.id, version.id, key, :unassigned_only)

      assert plan.mode == :unassigned_only
      assert plan.day_type_key == key

      assert Enum.map(plan.moves, & &1.trip.trip_id) == ["p_1", "p_2"]
      assert Enum.all?(plan.moves, &is_nil(&1.from))

      # Every trip that already had a block keeps it: no move names one, and the
      # stored assignments are exactly what the fixture wrote (AC-22).
      assert stored_blocks(
               scope,
               Enum.map(@blocked_trips, &elem(&1, 0)) ++ [@frequency_trip_id]
             ) == %{
               "wk_1" => "101",
               "wk_2" => "101",
               "wk_3" => "102",
               "wk_4" => "102",
               "wk_5" => "103",
               "wk_6" => "104",
               @frequency_trip_id => @frequency_block
             }
    end

    test "every pool trip lands on a block the run named and the review lists the moves", scope do
      %{organization: organization, version: version} = scope
      key = day_type_key(organization, version, ["WKDY"])

      assert {:ok, plan} = Gtfs.suggest_blocks(organization.id, version.id, key, :unassigned_only)

      placed = Enum.map(plan.moves, & &1.to)
      assert length(placed) == 2
      assert Enum.all?(placed, &(not is_nil(&1)))

      # The review is the plan's own: the moves are its changes and the selected
      # day type is the first effect it lists.
      assert plan.review.changes == plan.moves
      assert [selected | _] = plan.review.effects
      assert selected.selected?
      assert selected.day_type.key == key

      # A new block's attribute rows are proposed, never written.
      assert Enum.all?(plan.attribute_rows, &(&1.service_id == "WKDY"))
      assert attribute_rows(organization, version) == []
    end
  end

  describe "{:selected, ids}" do
    test "moves only those blocks' trips", scope do
      %{organization: organization, version: version} = scope
      key = day_type_key(organization, version, ["WKDY"])

      assert {:ok, plan} =
               Gtfs.suggest_blocks(organization.id, version.id, key, {:selected, ["101", "102"]})

      assert plan.mode == {:selected, ["101", "102"]}

      # Only the selected blocks' trips are in the run, so only they can be a
      # move: rebuilding 101 and 102 here reaches the same two numbers, and a
      # trip whose block does not change is not a move at all.
      moved = Enum.map(plan.moves, & &1.trip.trip_id)

      assert moved != []
      assert Enum.all?(moved, &(&1 in ["wk_1", "wk_2", "wk_3", "wk_4"]))

      assert Enum.all?(plan.moves, &(&1.from in ["101", "102"]))
      assert Enum.all?(plan.moves, &(&1.to in ["101", "102"]))
      assert Enum.sort(Enum.map(plan.new_blocks, & &1.block_id)) == ["101", "102"]

      # The unselected block, the pool and the frequency trip are not touched.
      assert stored_blocks(scope, ["wk_5", "wk_6", "p_1", "p_2"]) == %{
               "wk_5" => "103",
               "wk_6" => "104",
               "p_1" => nil,
               "p_2" => nil
             }

      assert stored_blocks(scope, [@frequency_trip_id]) == %{
               @frequency_trip_id => @frequency_block
             }
    end

    test "an empty selection is :no_selection", scope do
      %{organization: organization, version: version} = scope
      key = day_type_key(organization, version, ["WKDY"])

      assert {:error, :no_selection} =
               Gtfs.suggest_blocks(organization.id, version.id, key, {:selected, []})
    end

    test "a block the day type does not run is :no_selection", scope do
      %{organization: organization, version: version, route: route} = scope

      # 201 runs only on `SCHOOL`, so it is a block of `{SCHOOL, WKDY}` and of no
      # other day type.
      trip(organization, version, route, "sc_1", "SCHOOL", @school_block, "11:00:00", "12:00:00")

      school_key = day_type_key(organization, version, ["SCHOOL", "WKDY"])
      weekday_key = day_type_key(organization, version, ["WKDY"])

      assert {:error, :no_selection} =
               Gtfs.suggest_blocks(organization.id, version.id, weekday_key, {:selected, ["201"]})

      assert {:error, :no_selection} =
               Gtfs.suggest_blocks(
                 organization.id,
                 version.id,
                 weekday_key,
                 {:selected, ["999"]}
               )

      assert {:ok, plan} =
               Gtfs.suggest_blocks(
                 organization.id,
                 version.id,
                 school_key,
                 {:selected, [@school_block]}
               )

      # The school trip is the only trip the selected block runs, and the run puts
      # it back where it is, so nothing moves and only the block's attribute row is
      # proposed.
      assert plan.moves == []
      assert Enum.map(plan.new_blocks, & &1.block_id) == [@school_block]
      assert Enum.map(plan.attribute_rows, & &1.block_id) == [@school_block]
    end
  end

  describe ":replace_all" do
    test "covers every non-frequency trip and leaves the frequency trip's block alone", scope do
      %{organization: organization, version: version} = scope
      key = day_type_key(organization, version, ["WKDY"])

      assert {:ok, plan} = Gtfs.suggest_blocks(organization.id, version.id, key, :replace_all)

      every_scheduled = Enum.sort(Enum.map(@blocked_trips, &elem(&1, 0)) ++ ["p_1", "p_2"])

      assert Enum.sort(Enum.map(plan.moves, & &1.trip.trip_id)) == every_scheduled

      # Every scheduled trip ends in exactly one block, and no trip is proposed
      # twice (AC-22).
      assert length(Enum.uniq_by(plan.moves, & &1.trip.id)) == length(plan.moves)
      assert Enum.all?(plan.moves, &(not is_nil(&1.to)))

      # The frequency trip is never reassigned and is reported instead.
      refute @frequency_trip_id in Enum.map(plan.moves, & &1.trip.trip_id)

      assert stored_blocks(scope, [@frequency_trip_id]) == %{
               @frequency_trip_id => @frequency_block
             }

      frequency_leftover = Enum.find(plan.leftovers, &(&1.trip.trip_id == @frequency_trip_id))

      assert frequency_leftover.reason == :repeating_service
      assert frequency_leftover.block_id == @frequency_block
    end
  end

  describe "the scope bound" do
    test "more than 3,000 trips in scope is {:too_large, n}", scope do
      %{organization: organization} = scope

      # A version of its own, so the scope is exactly the bulk day and nothing
      # the other cases built is counted with it.
      version = bulk_version(organization.id)

      assert bulk_day(organization.id, version.id, 3_001) == %{trips: 3_001, stop_times: 6_002}

      assert {:error, {:too_large, 3001}} =
               Gtfs.suggest_blocks(organization.id, version.id, nil, :replace_all)
    end
  end

  describe "lookups" do
    test "an unknown day type key is {:unknown_day_type, day_types}", scope do
      %{organization: organization, version: version} = scope

      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.suggest_blocks(organization.id, version.id, "NOPE", :unassigned_only)

      assert Enum.sort(Enum.map(day_types, & &1.service_ids)) ==
               [["SCHOOL", "WKDY"], ["WKDY"]]
    end

    test "a version of another organization is :not_found", scope do
      %{organization: organization} = scope
      foreign_version = gtfs_version_fixture(organization_fixture().id)

      assert {:error, :not_found} =
               Gtfs.suggest_blocks(organization.id, foreign_version.id, nil, :unassigned_only)
    end
  end

  describe "the suggestion writes nothing" do
    test "every mode and every refusal leaves the same rows in the database", scope do
      %{organization: organization, version: version} = scope
      key = day_type_key(organization, version, ["WKDY"])
      before = row_counts(scope)

      assert {:ok, _} = Gtfs.suggest_blocks(organization.id, version.id, key, :unassigned_only)
      assert row_counts(scope) == before

      assert {:ok, _} =
               Gtfs.suggest_blocks(organization.id, version.id, key, {:selected, ["101", "102"]})

      assert row_counts(scope) == before
      assert {:ok, _} = Gtfs.suggest_blocks(organization.id, version.id, key, :replace_all)
      assert row_counts(scope) == before

      assert {:error, :no_selection} =
               Gtfs.suggest_blocks(organization.id, version.id, key, {:selected, ["999"]})

      assert row_counts(scope) == before

      assert {:error, {:unknown_day_type, _}} =
               Gtfs.suggest_blocks(organization.id, version.id, "NOPE", :unassigned_only)

      assert row_counts(scope) == before
    end
  end

  # --- fixture ---------------------------------------------------------------

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

  defp day_type_key(organization, version, service_ids) do
    day_type = Enum.find(day_types(organization, version), &(&1.service_ids == service_ids))

    assert day_type, "no day type for #{inspect(service_ids)}"

    day_type.key
  end

  defp day_types(organization, version) do
    {:ok, calendars} = Calendars.list_calendars(organization.id, version.id)
    DayTypes.derive(calendars)
  end

  # Natural trip ID to its stored `block_id`, read from the database rather than
  # from the plan, so "the suggestion wrote nothing" is observed on stored data.
  defp stored_blocks(scope, trip_ids) do
    organization_id = scope.organization.id
    version_id = scope.version.id

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
        where: a.organization_id == ^organization.id and a.gtfs_version_id == ^version.id,
        select: {a.service_id, a.block_id}
      )
    )
  end

  defp row_counts(scope) do
    ids = {scope.organization.id, scope.version.id}

    %{
      trips: count(Trip, ids),
      stop_times: count(GtfsPlanner.Gtfs.StopTime, ids),
      frequencies: count(Frequency, ids),
      transfers: count(Transfer, ids),
      block_attributes: count(BlockAttribute, ids),
      blocking_settings: count(BlockingSetting, ids)
    }
  end

  defp count(schema, {organization_id, version_id}) do
    Repo.one!(
      from(row in schema,
        where: row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id,
        select: count()
      )
    )
  end

  # --- the oversized scope ---------------------------------------------------

  # A published version of the same organization holding only the bulk day, so the
  # scope the bound is checked against is exactly the trips written below.
  defp bulk_version(organization_id) do
    version = gtfs_version_fixture(organization_id)

    calendar_service_fixture(organization_id, version.id, %{
      service_id: "BULK",
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

  # `count` scheduled trips and two stop times each, written with
  # `Repo.insert_all/3` in chunks on the version's own calendar service. The lane
  # database's statistics describe an empty table, so the two tables are analyzed
  # inside this test's transaction: `ANALYZE` reads the rows this transaction has
  # written, and its catalog rows roll back with the fixture.
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
          service_id: "BULK",
          block_id: nil,
          inserted_at: now,
          updated_at: now
        }
      end

    stop_times =
      Enum.flat_map(trips, fn trip ->
        first_secs = 21_600 + index_of(trip) * 900

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

  defp index_of(%{trip_id: "B" <> index}), do: String.to_integer(index)

  defp insert_chunked!(schema, rows) do
    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn chunk ->
      {written, nil} = Repo.insert_all(schema, chunk)
      assert written == length(chunk)
    end)
  end
end
