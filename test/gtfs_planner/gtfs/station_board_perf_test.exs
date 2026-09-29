defmodule GtfsPlanner.Gtfs.StationBoardPerfTest do
  @moduledoc """
  Measures the station board's build at the documented scale (EV-22, CL-11, AC-33).

  The fixture holds 100 stations, each with 20 child stops and 30 pathways, and ten completed
  reachability runs of 1,000 pairs per station, built with `Repo.insert_all/3` inside this
  test's SQL Sandbox transaction so no row survives the run. Each run stores a real
  `Reachability.Envelope.build/1` payload, so the run history carries the production JSON shape
  and size and the reachability read pays the detoast cost it does in production. The tables
  the reads scan are analyzed after the inserts, because the lane database's statistics
  otherwise describe an empty table.

  `StationBoard.base/2` and `StationBoard.statuses/3` are timed with `:timer.tc/1`, and a
  `[:gtfs_planner, :repo, :query]` telemetry handler counts the repo queries they run. One
  untimed warm-up build runs first, because the first call after the fixture pays one-time
  costs (Postgres JIT and plan setup, prepared statements, the page cache for the freshly
  written runs) that no later mount does; the counted call is the steady-state one. The test
  prints one `EV-22:` line with the station, child-stop, pathway and run counts, both elapsed
  times and the query count, then asserts the budget (`base + statuses <= 1,000 ms`) and the
  fixed query ceiling (12) that tells a per-station query apart from the five bulk reads of
  `base/2` plus the four of `statuses/3` and the newest-run lookup.

  The budget is the spec's assumed design budget, not a sourced requirement: a failure is the
  recorded input for the stored per-version summary upgrade path, so the measured line is
  printed before both assertions.

  The fixture fills a whole test-database transaction, so the module carries
  `@moduletag :home_perf`, which `test/test_helper.exs` excludes from the default suite, plus
  the card's 300-second timeout. Branch review runs it explicitly:

      MIX_ENV=test MIX_TEST_PARTITION=_home26 mix test --only home_perf test/gtfs_planner/gtfs/station_board_perf_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationBoard
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Reachability.Envelope
  alias GtfsPlanner.Reachability.Pair
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :home_perf
  @moduletag timeout: 300_000

  @stations 100
  @children_per_station 20
  @pathways_per_station 30
  @runs_per_station 10
  @pairs_per_run 1_000
  @levels 3
  @stop_chunk_size 500
  @pathway_chunk_size 500
  @child_location_types [0, 2, 3, 4]
  @pathway_modes [1, 2, 5]
  @pair_kinds [:entry, :egress, :transfer]
  @run_base_time ~U[2026-09-01 09:00:00.000000Z]

  @budget_ms 1_000
  # base/2 runs five bulk reads; statuses/3 runs four, two of them the newest-run lookup.
  @min_queries 5
  @max_queries 12

  describe "the board build at 100 stations" do
    test "runs base/2 and statuses/3 within the one-second budget with fixed queries" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      counts = build_fixture(organization.id, gtfs_version.id)

      # The measured build is the steady-state one: the first call after the fixture pays
      # one-time costs (Postgres JIT and plan setup, prepared statements, the page cache for
      # the freshly written runs) that no later mount does, and a benchmark run on a freshly
      # migrated partition measured 2,306.7 ms for it against 303-457 ms once warm. Reading
      # this pair before attaching the counter keeps those warm-up queries out of the count.
      warm_bases = StationBoard.base(organization.id, gtfs_version.id)
      StationBoard.statuses(organization.id, gtfs_version.id, warm_bases)

      counter = start_supervised!({Agent, fn -> 0 end})
      handler_id = "station-board-perf-#{System.unique_integer([:positive])}"
      attach_query_counter(handler_id, counter)

      try do
        {base_us, bases} =
          :timer.tc(fn -> StationBoard.base(organization.id, gtfs_version.id) end)

        {statuses_us, statuses} =
          :timer.tc(fn -> StationBoard.statuses(organization.id, gtfs_version.id, bases) end)

        queries = Agent.get(counter, & &1)

        assert counts == %{
                 stations: @stations,
                 child_stops: @stations * @children_per_station,
                 pathways: @stations * @pathways_per_station,
                 runs: @stations * @runs_per_station
               }

        assert length(bases) == @stations
        assert map_size(statuses) == @stations

        assert Enum.all?(bases, &(&1.pathway_count == @pathways_per_station)),
               "every station must own #{@pathways_per_station} pathways: the fixture did not " <>
                 "land as intended"

        assert Enum.all?(statuses, fn {_station, status} ->
                 match?(%{reachability: %{outcome: :passed, pair_count: @pairs_per_run}}, status)
               end),
               "every station must report the newest of its #{@runs_per_station} runs"

        base_ms = milliseconds(base_us)
        statuses_ms = milliseconds(statuses_us)
        total_ms = milliseconds(base_us + statuses_us)

        print_observation(counts, base_ms, statuses_ms, total_ms, queries)

        assert base_us + statuses_us <= @budget_ms * 1_000,
               "the #{@stations}-station board build took #{total_ms} ms " <>
                 "(base #{base_ms} ms + statuses #{statuses_ms} ms), budget #{@budget_ms} ms"

        assert queries <= @max_queries,
               "base/2 + statuses/3 ran #{queries} repo queries for #{@stations} stations: " <>
                 "the board must not query per station (ceiling #{@max_queries})"

        assert queries >= @min_queries,
               "the query counter saw #{queries} events: the telemetry handler did not observe " <>
                 "the board's reads"
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  test "the default suite excludes this module" do
    config = ExUnit.configuration()

    assert :home_perf in config[:exclude]
    assert Map.get(__MODULE__.__ex_unit__().tags, :home_perf) == true

    # ExUnit's own decision for a run with no include filter and these excludes, which is the
    # default suite `mix test` and `mix precommit` run: a `:home_perf` test is excluded, so the
    # 100-station fixture is only built by an explicit `--only home_perf` run.
    assert {:excluded, _} = ExUnit.Filters.eval([], config[:exclude], %{home_perf: true}, [])
  end

  # Builds AC-33's shape inside this test's sandbox transaction and returns its row counts.
  defp build_fixture(organization_id, gtfs_version_id) do
    now = DateTime.utc_now()

    insert_all!(
      Level,
      for index <- 0..(@levels - 1) do
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          level_id: "L#{index}",
          level_index: index * 1.0,
          level_name: "Level #{index}",
          inserted_at: now,
          updated_at: now
        }
      end
    )

    insert_chunked!(Stop, stop_rows(organization_id, gtfs_version_id, now), @stop_chunk_size)

    insert_chunked!(
      Pathway,
      pathway_rows(organization_id, gtfs_version_id, now),
      @pathway_chunk_size
    )

    insert_runs(organization_id, gtfs_version_id)

    analyze!(["stops", "pathways", "gtfs_validation_runs"])

    %{
      stations: @stations,
      child_stops: @stations * @children_per_station,
      pathways: @stations * @pathways_per_station,
      runs: @stations * @runs_per_station
    }
  end

  defp stop_rows(organization_id, gtfs_version_id, now) do
    Enum.flat_map(1..@stations, fn station_index ->
      station_stop_id = station_stop_id(station_index)

      station = %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        stop_id: station_stop_id,
        stop_name: "Station #{station_stop_id}",
        stop_lat: Decimal.new("40.7128"),
        stop_lon: Decimal.new("-74.0060"),
        location_type: 1,
        wheelchair_boarding: 0,
        inserted_at: now,
        updated_at: now
      }

      children =
        Enum.map(
          0..(@children_per_station - 1),
          &child_stop_row(organization_id, gtfs_version_id, station_stop_id, &1, now)
        )

      [station | children]
    end)
  end

  defp child_stop_row(organization_id, gtfs_version_id, station_stop_id, child_index, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      stop_id: child_stop_id(station_stop_id, child_index),
      stop_name: child_stop_name(station_stop_id, child_index),
      stop_lat: Decimal.new("40.7128"),
      stop_lon: Decimal.new("-74.0060"),
      location_type:
        Enum.at(@child_location_types, rem(child_index, length(@child_location_types))),
      wheelchair_boarding: 0,
      parent_station: station_stop_id,
      level_id: "L#{rem(child_index, @levels)}",
      inserted_at: now,
      updated_at: now
    }
  end

  defp pathway_rows(organization_id, gtfs_version_id, now) do
    Enum.flat_map(1..@stations, fn station_index ->
      station_stop_id = station_stop_id(station_index)

      child_ids =
        Enum.map(0..(@children_per_station - 1), &child_stop_id(station_stop_id, &1))

      endpoints =
        Enum.map(0..(@children_per_station - 1), fn index ->
          {Enum.at(child_ids, index), Enum.at(child_ids, rem(index + 1, @children_per_station))}
        end) ++
          Enum.map(10..19, fn index ->
            {Enum.at(child_ids, index - 10), Enum.at(child_ids, index)}
          end)

      endpoints
      |> Enum.with_index()
      |> Enum.map(fn {{from_stop_id, to_stop_id}, pathway_index} ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          pathway_id: "#{station_stop_id}_PW#{pad(pathway_index, 2)}",
          pathway_mode: Enum.at(@pathway_modes, rem(pathway_index, length(@pathway_modes))),
          is_bidirectional: true,
          traversal_time: 60,
          from_stop_id: from_stop_id,
          to_stop_id: to_stop_id,
          inserted_at: now,
          updated_at: now
        }
      end)
    end)
  end

  # One production-shaped envelope per station, reused by its ten runs: the runs differ in
  # their timestamps only, and building 100,000 pair entries once per station keeps the
  # fixture's memory bounded while every stored run is the size the reads must detoast.
  defp insert_runs(organization_id, gtfs_version_id) do
    Enum.each(1..@stations, fn station_index ->
      station_stop_id = station_stop_id(station_index)
      envelope = envelope(station_stop_id)

      rows =
        Enum.map(1..@runs_per_station, fn run_index ->
          completed_at = DateTime.add(@run_base_time, -run_index, :hour)

          %{
            id: Ecto.UUID.generate(),
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id,
            run_type: "station_reachability",
            status: "completed",
            engine: "pathways_router",
            result_schema_version: 1,
            errors_count: 0,
            warnings_count: 0,
            infos_count: @pairs_per_run,
            duration_ms: 1_000,
            error_details: nil,
            result_json: envelope,
            started_at: DateTime.add(completed_at, -60, :second),
            completed_at: completed_at,
            inserted_at: completed_at,
            updated_at: completed_at
          }
        end)

      insert_all!(ValidationRun, rows)
    end)
  end

  defp envelope(station_stop_id) do
    children =
      Enum.map(0..(@children_per_station - 1), fn child_index ->
        {child_stop_id(station_stop_id, child_index),
         child_stop_name(station_stop_id, child_index)}
      end)

    origins = Enum.take(children, 5)
    destinations = Enum.drop(children, 5)

    pairs =
      Enum.map(1..@pairs_per_run, fn pair_index ->
        {from_stop_id, from_stop_name} = Enum.at(origins, rem(pair_index, length(origins)))
        {to_stop_id, to_stop_name} = Enum.at(destinations, rem(pair_index, length(destinations)))

        %Pair{
          index: pair_index,
          kind: Enum.at(@pair_kinds, rem(pair_index, length(@pair_kinds))),
          mode: if(rem(pair_index, 5) == 0, do: :wheelchair, else: :walking),
          from_stop_id: from_stop_id,
          from_stop_name: from_stop_name,
          to_stop_id: to_stop_id,
          to_stop_name: to_stop_name
        }
      end)

    results = Enum.map(pairs, &%{pair: &1, outcome: :reachable, route: nil, reason: nil})

    Envelope.build(%{
      station: %{stop_id: station_stop_id, stop_name: "Station #{station_stop_id}"},
      pairs: pairs,
      results: results,
      diagnostics: [],
      topology: %{
        entrance_count: 5,
        platform_count: 5,
        pathway_count: @pathways_per_station,
        level_count: @levels
      },
      started_at: DateTime.add(@run_base_time, -2, :hour),
      completed_at: @run_base_time
    })
  end

  # The lane database's statistics for these tables describe an empty table, so the planner
  # would otherwise plan the newest-run lookup without knowing the 1,000 runs. PostgreSQL
  # allows `ANALYZE` inside a transaction block, and it reads the rows this transaction has
  # already written - the statistics a committed import would have from autovacuum.
  defp analyze!(tables) do
    Enum.each(tables, &Repo.query!("ANALYZE #{&1}"))
  end

  # Ecto emits `[:gtfs_planner, :repo, :query]` in the process that issued the query, which is
  # this test process for both timed calls. The tally lives in an Agent (the pattern the
  # blocking scale test uses) so a future build that queries from a child process is still
  # counted, and it is filtered by `metadata.repo` so only this application's reads count.
  defp attach_query_counter(handler_id, counter) do
    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, counter ->
        if metadata.repo == Repo, do: Agent.update(counter, &(&1 + 1))
      end,
      counter
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp print_observation(counts, base_ms, statuses_ms, total_ms, queries) do
    IO.puts(
      "EV-22: stations=#{counts.stations} child_stops=#{counts.child_stops} " <>
        "pathways=#{counts.pathways} runs=#{counts.runs} pairs_per_run=#{@pairs_per_run} " <>
        "base_ms=#{base_ms} statuses_ms=#{statuses_ms} total_ms=#{total_ms} " <>
        "queries=#{queries} budget_ms=#{@budget_ms}"
    )
  end

  defp insert_chunked!(schema, rows, chunk_size) do
    rows
    |> Enum.chunk_every(chunk_size)
    |> Enum.each(&insert_all!(schema, &1))
  end

  defp insert_all!(schema, rows) do
    {count, nil} = Repo.insert_all(schema, rows)

    if count != length(rows) do
      raise "#{inspect(schema)} insert wrote #{count} of #{length(rows)} rows"
    end
  end

  defp station_stop_id(index), do: "HP" <> pad(index, 3)
  defp child_stop_id(station_stop_id, index), do: "#{station_stop_id}_#{pad(index, 2)}"

  defp child_stop_name(station_stop_id, index),
    do: "Station #{station_stop_id} Child #{pad(index, 2)}"

  defp pad(value, width), do: String.pad_leading(Integer.to_string(value), width, "0")
  defp milliseconds(microseconds), do: Float.round(microseconds / 1_000, 1)
end
