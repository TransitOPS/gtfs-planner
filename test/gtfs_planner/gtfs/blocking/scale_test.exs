defmodule GtfsPlanner.Gtfs.Blocking.ScaleTest do
  @moduledoc """
  Measures one day load at the largest measured real-feed scale (EV-9, CL-6, AC-3).

  The research feeds reach 17,901 trips and 2,189 blocks in one day type, so the fixture rounds
  both up: 2,200 blocks of 8 trips plus 400 pool trips (18,000 trips), two stop times each,
  beside one weekly calendar, 50 routes and 50 stops, about 54,000 rows inserted with
  `Repo.insert_all/3` in chunks of 5,000 and then analyzed, because the lane database's own
  statistics describe an empty table and the planner would otherwise scan `stop_times` once per
  trip. Every row is created inside this test's SQL Sandbox transaction and rolled back with it,
  so the shared test database keeps none of it.

  The load runs through the ordinary `Gtfs.load_blocking_day/3` entry and the production
  `CatalogReadAdapter.Repo`. A `[:gtfs_planner, :repo, :query]` telemetry handler counts the
  queries of the large day type and of a 10-trip day type of the same shape in another version
  of the same organization: the two counts must be equal, which is AC-3's "the query count does
  not grow with the trip count" at the largest measured scale. The counts must be 18,000 trips,
  2,200 blocks and 400 unassigned.

  The observed elapsed milliseconds (measured with `:timer.tc/1`) and
  `:erts_debug.size(day) * :erlang.system_info(:wordsize)` bytes are printed on one `EV-9:` line
  for the evidence artifact, and no time budget is asserted: the measurement is the recorded
  input for the virtualization decision, not a threshold a slower or faster machine must meet.
  That line is printed *before* the query-count comparison, so the recorded measurement is in
  the output on the run where a count regresses and the comparison fails.

  The fixture and the load fill a whole test-database transaction, so the module carries
  `@moduletag :blocking_scale`, which `test/test_helper.exs` excludes from the default suite,
  plus the card's 300-second timeout. Branch review runs it explicitly:

      mix test --only blocking_scale test/gtfs_planner/gtfs/blocking/scale_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{Calendar, CalendarAttribute, GtfsTime, Route, Stop, StopTime, Trip}
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :blocking_scale
  @moduletag timeout: 300_000

  # 2,200 blocks of 8 trips plus 400 pool trips: 18,000 trips and two stop times each.
  @blocks 2_200
  @trips_per_block 8
  @pool_trips 400
  @trip_count @blocks * @trips_per_block + @pool_trips
  @route_count 50
  @stop_count 50
  @chunk_size 5_000
  @service_id "WK"

  # The comparison day type in another version: the same shape at ten trips.
  @small_blocks 1
  @small_pool_trips 2
  @small_trip_count @small_blocks * @trips_per_block + @small_pool_trips

  # One block's trips run 06:00-08:30 twenty minutes apart for ten minutes each, so consecutive
  # trips of a block leave a ten-minute layover (above the default five-minute minimum) and no
  # two trips of a block overlap. The pool trips are not overlap-free: they spread from 04:00 a
  # minute apart for fifteen minutes each, so about fifteen of them are in flight together. The
  # pool is read one trip at a time and its trips are never compared with each other, so that
  # overlap is deliberate and cannot add a finding.
  @block_first_secs 21_600
  @trip_spacing_secs 1_200
  @trip_duration_secs 600
  @pool_first_secs 14_400
  @pool_spacing_secs 60
  @pool_duration_secs 900

  describe "the largest generated day type" do
    test "loads completely with a 10-trip day's query count, recording time and size" do
      organization = organization_fixture()
      large_version = gtfs_version_fixture(organization.id)
      small_version = gtfs_version_fixture(organization.id)

      assert build_scale_day(organization.id, large_version.id) ==
               %{trips: @trip_count, stop_times: @trip_count * 2}

      assert build_scale_day(organization.id, small_version.id,
               blocks: @small_blocks,
               pool_trips: @small_pool_trips
             ) == %{trips: @small_trip_count, stop_times: @small_trip_count * 2}

      {large_result, large_elapsed_us, large_queries} =
        count_queries(fn -> Gtfs.load_blocking_day(organization.id, large_version.id, nil) end)

      {small_result, _small_elapsed_us, small_queries} =
        count_queries(fn -> Gtfs.load_blocking_day(organization.id, small_version.id, nil) end)

      assert {:ok, large_day} = large_result
      assert {:ok, small_day} = small_result

      assert large_day.counts.trips == @trip_count
      assert large_day.counts.blocks == @blocks
      assert large_day.counts.unassigned == @pool_trips

      assert small_day.counts.trips == @small_trip_count
      assert small_day.counts.blocks == @small_blocks
      assert small_day.counts.unassigned == @small_pool_trips

      # Printed before the comparison below: a count regression is exactly the run whose
      # recorded measurement the evidence artifact needs, and an assertion failure would
      # otherwise hide the line.
      assert_observation(large_day, large_queries, small_queries, large_elapsed_us)

      assert large_queries > 0

      assert large_queries == small_queries,
             "the #{@trip_count}-trip day of version #{large_version.id} ran #{large_queries} " <>
               "queries and the #{@small_trip_count}-trip day of version #{small_version.id} " <>
               "ran #{small_queries}: the count must not grow with the trip count"
    end
  end

  test "the default suite excludes this module" do
    config = ExUnit.configuration()

    assert :blocking_scale in config[:exclude]
    assert Map.get(__MODULE__.__ex_unit__().tags, :blocking_scale) == true

    # ExUnit's own decision for a run with no include filter and these excludes, which is the
    # default suite `mix test` and `mix precommit` run: a `:blocking_scale` test is excluded, so
    # the 18,000-trip fixture is only built by an explicit `--only blocking_scale` run.
    assert {:excluded, _} = ExUnit.Filters.eval([], config[:exclude], %{blocking_scale: true}, [])
  end

  @doc """
  Inserts the scale fixture for one version and returns the inserted row counts.

  `:blocks`, `:trips_per_block` and `:pool_trips` default to the largest measured shape; the
  comparison day type passes its own counts. Rows are written with `Repo.insert_all/3` in
  chunks of 5,000 inside whatever transaction the caller holds, so the SQL Sandbox checkout of
  a test rolls every one of them back, and the two tables written in bulk are analyzed so the
  load's plans describe the rows that are there.

  Public because the step's throwaway local smoke calls this same function without ExUnit; the
  test above is the only committed caller, so the smoke cannot seed a different fixture than the
  gate does.
  """
  @spec build_scale_day(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: %{
          trips: non_neg_integer(),
          stop_times: non_neg_integer()
        }
  def build_scale_day(organization_id, gtfs_version_id, opts \\ []) do
    arguments = {organization_id, gtfs_version_id}
    blocks = Keyword.get(opts, :blocks, @blocks)
    pool_trips = Keyword.get(opts, :pool_trips, @pool_trips)
    now = DateTime.utc_now()

    insert_chunked!(Calendar, [calendar_row(arguments, now)])
    insert_chunked!(CalendarAttribute, [calendar_attribute_row(arguments, now)])
    insert_chunked!(Route, route_rows(arguments, @route_count, now))
    insert_chunked!(Stop, stop_rows(arguments, @stop_count, now))

    trips = trip_specs(blocks, Keyword.get(opts, :trips_per_block, @trips_per_block), pool_trips)

    insert_chunked!(Trip, Enum.map(trips, &trip_row(arguments, &1, now)))

    stop_times = Enum.flat_map(trips, &stop_time_rows(arguments, &1, now))
    insert_chunked!(StopTime, stop_times)

    analyze_bulk_tables!()

    %{trips: length(trips), stop_times: length(stop_times)}
  end

  defp calendar_row({organization_id, gtfs_version_id}, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      service_id: @service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31],
      inserted_at: now,
      updated_at: now
    }
  end

  defp calendar_attribute_row({organization_id, gtfs_version_id}, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      service_id: @service_id,
      service_description: "Weekday",
      inserted_at: now,
      updated_at: now
    }
  end

  defp route_rows({organization_id, gtfs_version_id}, count, now) do
    for index <- 1..count do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        route_id: route_id(index),
        route_short_name: "#{index}",
        route_long_name: "Test Route #{index}",
        route_type: 3,
        route_color: "0000FF",
        route_text_color: "FFFFFF",
        active: true,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp stop_rows({organization_id, gtfs_version_id}, count, now) do
    for index <- 1..count do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        stop_id: stop_id(index),
        stop_name: "Stop #{index}",
        stop_lat: Decimal.from_float(42.3 + index / 1_000),
        stop_lon: Decimal.from_float(-71.0 - index / 1_000),
        location_type: 0,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # One spec per trip: the IDs and the two clock seconds both its trip row and its two
  # stop-time rows need.
  defp trip_specs(blocks, trips_per_block, pool_trips) do
    blocked =
      for block <- 1..blocks, position <- 1..trips_per_block do
        start = @block_first_secs + (position - 1) * @trip_spacing_secs

        spec(
          "B#{block}T#{position}",
          "BLK#{block}",
          rem(block, @route_count) + 1,
          start,
          start + @trip_duration_secs,
          rem(block + position, @stop_count) + 1,
          rem(block + position + 1, @stop_count) + 1
        )
      end

    pool =
      for index <- 1..pool_trips do
        start = @pool_first_secs + (index - 1) * @pool_spacing_secs

        spec(
          "P#{index}",
          nil,
          rem(index, @route_count) + 1,
          start,
          start + @pool_duration_secs,
          rem(index, @stop_count) + 1,
          rem(index + 1, @stop_count) + 1
        )
      end

    blocked ++ pool
  end

  defp spec(trip_id, block_id, route, first_secs, last_secs, first_stop, last_stop) do
    %{
      trip_id: trip_id,
      block_id: block_id,
      route_id: route_id(route),
      first_secs: first_secs,
      last_secs: last_secs,
      first_stop: stop_id(first_stop),
      last_stop: stop_id(last_stop)
    }
  end

  defp trip_row({organization_id, gtfs_version_id}, spec, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      trip_id: spec.trip_id,
      route_id: spec.route_id,
      service_id: @service_id,
      block_id: spec.block_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp stop_time_rows({organization_id, gtfs_version_id}, spec, now) do
    [
      stop_time_row(
        organization_id,
        gtfs_version_id,
        spec,
        spec.first_stop,
        1,
        spec.first_secs,
        now
      ),
      stop_time_row(
        organization_id,
        gtfs_version_id,
        spec,
        spec.last_stop,
        2,
        spec.last_secs,
        now
      )
    ]
  end

  defp stop_time_row(organization_id, gtfs_version_id, spec, stop_id, sequence, secs, now) do
    clock = GtfsTime.format(secs)

    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      trip_id: spec.trip_id,
      stop_id: stop_id,
      stop_sequence: sequence,
      arrival_time: clock,
      departure_time: clock,
      inserted_at: now,
      updated_at: now
    }
  end

  # The lane database's statistics for these tables describe an empty table, so the planner
  # otherwise picks a sequential scan per outer row for `trip_rows/3`'s two `DISTINCT ON`
  # endpoint queries: 30.4 s and 31.5 s each at this scale against 88 ms and 75 ms with real
  # statistics, and a whole load of over a minute against the observed 740-828 ms. PostgreSQL
  # allows `ANALYZE` inside a transaction block, and it reads the rows this transaction has
  # already written - the statistics a committed import would have from autovacuum - so each
  # fixture run analyzes for its own plans instead of depending on an earlier run. The statistic
  # that decides those plans rolls back with the fixture: `pg_statistic` rows are ordinary catalog
  # rows (measured: after a rolled-back probe this lane's `trips.block_id` statistics read exactly
  # as they had before it). The one-row `pg_class.reltuples` update `ANALYZE` also makes is an
  # in-place update outside that rollback (measured: it read the probe's 3,000 rows both before
  # and after the probe's rollback), which is a plan hint for an empty table, not a row of the
  # fixture: no fixture table keeps a row.
  defp analyze_bulk_tables! do
    Repo.query!("ANALYZE trips")
    Repo.query!("ANALYZE stop_times")
  end

  defp insert_chunked!(schema, rows) do
    rows
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      {count, nil} = Repo.insert_all(schema, chunk)

      if count != length(chunk) do
        raise "#{inspect(schema)} insert wrote #{count} of #{length(chunk)} rows"
      end
    end)
  end

  defp route_id(index), do: "R#{index}"
  defp stop_id(index), do: "S#{index}"

  # Ecto emits `[:gtfs_planner, :repo, :query]` in the process that issued the query, so the
  # handler cannot decide by process which queries this test owns: a day load that later runs
  # part of its work in a `Task` would query from a child process. The tally therefore lives in
  # an Agent, which any process can update, instead of this test's mailbox. The filter that
  # remains is `metadata.repo`: only events from this application's repo count, and everything
  # else is the test's own window, which holds the two loads and nothing else (`async: false`,
  # and the fixture is built before the handler is attached).
  defp count_queries(fun) do
    counter =
      start_supervised!({Agent, fn -> 0 end}, id: {:scale_query_counter, make_ref()})

    handler_id = "blocking-scale-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, counter ->
        if metadata.repo == Repo, do: Agent.update(counter, &(&1 + 1))
      end,
      counter
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    try do
      {elapsed_us, result} = :timer.tc(fun)
      {result, elapsed_us, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
    end
  end

  # EV-9's observation line: the loaded counts, both query counts, the elapsed milliseconds and
  # the loaded size in bytes. Nothing compares the elapsed time with a budget; the elapsed and
  # size values are printed for the evidence artifact and returned to the test only as
  # non-negative integers.
  defp assert_observation(day, queries, small_queries, elapsed_us) do
    wordsize = :erlang.system_info(:wordsize)
    day_bytes = :erts_debug.size(day) * wordsize
    elapsed_ms = div(elapsed_us, 1_000)

    line =
      "EV-9: trips=#{day.counts.trips} blocks=#{day.counts.blocks} " <>
        "unassigned=#{day.counts.unassigned} queries=#{queries} " <>
        "small_queries=#{small_queries} elapsed_ms=#{elapsed_ms} day_bytes=#{day_bytes}"

    IO.puts(line)

    assert line =~ "EV-9: trips=#{@trip_count} blocks=#{@blocks} unassigned=#{@pool_trips}"
    assert line =~ "queries=#{queries} small_queries=#{small_queries}"
    assert line =~ ~r/elapsed_ms=\d+ day_bytes=\d+\z/
    assert elapsed_ms >= 0
    assert day_bytes > 0
  end
end
