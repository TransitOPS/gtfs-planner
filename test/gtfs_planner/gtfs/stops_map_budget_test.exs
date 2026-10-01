defmodule GtfsPlanner.Gtfs.StopsMapBudgetTest do
  @moduledoc """
  Measures the Map view read model at the envelope real feeds reach.

  The ten feeds measured while designing the Map view top out around ten
  thousand stops and a few hundred patterns. A version that size loads 600,000
  shape points, and the question this answers is whether the map is still a map:
  a fixed query count, and a payload small enough to push to a browser.

  Three numbers are measured:

    * **query count** — must be identical to the fixed set `StopsMap.load/2`
      issues for any other version. That property is asserted.
    * **payload bytes** — the encoded size of `display_payload/2` at a 2.0 m
      tolerance. The only assertion is that the simplified payload is smaller
      than the unsimplified one, which is what simplification is *for*; an
      absolute byte budget is not asserted here, because a number nobody has
      measured on a real feed is a threshold that will fail for the wrong
      reason. The measured value is printed so a budget can be set from it.
    * **elapsed milliseconds** — printed, never asserted. This is local
      Postgres timing, not browser rendering time.

  The fixture is written with `Repo.insert_all/3` in chunks of 5,000 inside this
  test's SQL Sandbox transaction, so the shared test database keeps none of it,
  and the bulk-written tables are analyzed afterwards so the load's plans
  describe the rows that are actually there rather than an empty table.

  It is excluded from the default suite by `@moduletag :stops_map_budget`,
  which `test/test_helper.exs` excludes. Run it explicitly:

      mix test --only stops_map_budget test/gtfs_planner/gtfs/stops_map_budget_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.{Route, RoutePattern, RoutePatternStop, Shape, Stop, StopsMap, Trip}
  alias GtfsPlanner.Repo

  @moduletag :stops_map_budget
  @moduletag timeout: 600_000

  @stop_count 10_000
  @pattern_count 300
  @shape_points 2_000
  @stops_per_pattern 10
  @chunk_size 2_000

  # The tolerance the map hook asks for: two metres is under a pixel at the
  # zoom a stop is inspected at, so dropping a point within it cannot change what
  # an editor sees.
  @tolerance_m 2.0

  test "the read model stays a fixed set of queries and the payload stays small" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    build_envelope(organization.id, version.id)
    Repo.query!("ANALYZE stops")
    Repo.query!("ANALYZE route_patterns")
    Repo.query!("ANALYZE route_pattern_stops")
    Repo.query!("ANALYZE trips")
    Repo.query!("ANALYZE shapes")

    {model, load_ms, query_count} =
      count_queries(fn -> StopsMap.load(organization.id, version.id) end)

    assert {:ok, model} = model

    # `:timer.tc/1` answers `{microseconds, result}`, so the elapsed time is the
    # first element and the value the second.
    {full_us, full_payload} = :timer.tc(fn -> StopsMap.display_payload(model, 0.0) end)
    {payload_us, payload} = :timer.tc(fn -> StopsMap.display_payload(model, @tolerance_m) end)

    full_bytes = byte_size(Jason.encode!(full_payload))
    payload_bytes = byte_size(Jason.encode!(payload))

    IO.puts(
      "stops map budget: stops=#{length(model.stops)} patterns=#{length(model.lines)} " <>
        "queries=#{query_count} payload_bytes=#{payload_bytes} " <>
        "unsimplified=#{full_bytes} load_ms=#{load_ms} " <>
        "payload_ms=#{div(payload_us, 1_000)} unsimplified_ms=#{div(full_us, 1_000)}"
    )

    # The measurement is printed above, so the rows are not needed any longer.
    # The envelope is six hundred thousand shape points of WAL on a shared disk,
    # so it is dropped now rather than waiting for the sandbox rollback at the
    # end of the test.
    delete_envelope!()

    # The read is a fixed set of queries, not one per pattern. The set
    # `load/2` issues is five, and 300 patterns must not add to it.
    assert query_count == 5
    assert length(model.stops) == @stop_count
    assert length(model.lines) == @pattern_count

    # The property simplification exists to deliver.
    assert payload_bytes < full_bytes

    assert Enum.all?(payload.lines, fn line ->
             {first, last} = {List.first(line.points), List.last(line.points)}
             first != nil and last != nil
           end)
  end

  # --- fixture

  defp build_envelope(organization_id, gtfs_version_id) do
    now = DateTime.utc_now()
    ids = {organization_id, gtfs_version_id}

    insert_chunked!(Route, [route_row(ids, now)])
    insert_chunked!(Stop, stop_rows(ids, now))

    # `route_pattern_stops.route_pattern_id` is the pattern row's UUID, so the
    # rows are built once and inserted once: a second `pattern_rows/2` call
    # would mint a different UUID per pattern and the occurrences would point at
    # nothing. The `shape_id` string stays the natural link to `shapes`.
    patterns = pattern_rows(ids, now)
    insert_chunked!(RoutePattern, patterns)

    pattern_ids = Map.new(patterns, fn row -> {row.route_pattern_id, row.id} end)

    insert_chunked!(Trip, trip_rows(ids, now))
    insert_chunked!(RoutePatternStop, pattern_stop_rows(ids, now, pattern_ids))
    insert_chunked!(Shape, shape_rows(ids, now))
  end

  defp route_row(ids, now) do
    {organization_id, gtfs_version_id} = ids

    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      route_id: "R1",
      route_type: 3,
      route_short_name: "1",
      route_long_name: "Coast",
      route_color: "1F6FB2",
      route_text_color: "FFFFFF",
      inserted_at: now,
      updated_at: now
    }
  end

  # Stops on a grid, so the envelope has real spread rather than ten thousand
  # coincident pins: a grid in degrees, about 90 m apart, over roughly two by
  # two kilometres. 100 columns by 100 rows.
  defp stop_rows({organization_id, gtfs_version_id} = _ids, now) do
    for index <- 1..@stop_count do
      column = rem(index - 1, 100)
      row = div(index - 1, 100)

      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        stop_id: "S#{index}",
        stop_name: "Stop #{index}",
        stop_lat: Decimal.new(to_string(44.0 + row * 0.0008)),
        stop_lon: Decimal.new(to_string(-124.0 + column * 0.001)),
        location_type: 0,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp pattern_rows({organization_id, gtfs_version_id}, now) do
    for index <- 1..@pattern_count do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        route_pattern_id: "P#{index}",
        route_id: "R1",
        direction_id: rem(index, 2),
        headsign: "To Town",
        shape_id: "shape-#{index}",
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # One trip per pattern, so each pattern's own `shape_id` is exercised and the
  # linked-trip fallback is present in the data without being selected.
  defp trip_rows({organization_id, gtfs_version_id}, now) do
    for index <- 1..@pattern_count do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        trip_id: "T#{index}",
        route_id: "R1",
        service_id: "WK",
        route_pattern_id: "P#{index}",
        shape_id: "shape-#{index}",
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp pattern_stop_rows({organization_id, gtfs_version_id}, now, pattern_ids) do
    for index <- 1..@pattern_count, position <- 1..@stops_per_pattern do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        route_pattern_id: Map.fetch!(pattern_ids, "P#{index}"),
        stop_id: "S#{(index - 1) * @stops_per_pattern + position}",
        position: position,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # Each shape is a gentle curve, not a straight line: a straight line would
  # simplify to two points and the payload measurement would flatter a
  # simplifier that had done nothing.
  #
  # This is a `Stream`, not a list. Materialising 600,000 row maps at once is
  # roughly a gigabyte of BEAM heap, and building it is what pushed the database
  # backend over its limit on the first run. The stream yields one chunk's worth
  # at a time and nothing else.
  defp shape_rows({organization_id, gtfs_version_id}, now) do
    Stream.flat_map(1..@pattern_count, fn index ->
      Stream.map(1..@shape_points, fn sequence ->
        %{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          shape_id: "shape-#{index}",
          shape_pt_sequence: sequence,
          shape_pt_lat:
            Decimal.new(to_string(44.0 + index * 0.0001 + :math.sin(sequence / 20) * 0.0004)),
          shape_pt_lon: Decimal.new(to_string(-124.0 + sequence * 0.0001)),
          inserted_at: now,
          updated_at: now
        }
      end)
    end)
  end

  # Removes the bulk-written rows in child-to-parent order so the envelope does
  # not sit on the disk for the rest of the suite. The rows are inside this
  # test's sandbox transaction, so the rollback at the end of the test is what
  # actually reclaims them; this deletion is what keeps the peak footprint of
  # the test low and is deliberately not a `VACUUM`, which cannot run inside the
  # sandbox's transaction.
  defp delete_envelope! do
    # `timed_pattern_stops` names a `route_pattern_stops` row, so it goes first.
    for table <-
          ~w(timed_pattern_stops route_pattern_stops shapes trips route_patterns stops routes) do
      Repo.query!("DELETE FROM #{table}")
    end
  end

  defp insert_chunked!(schema, rows) do
    rows
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      {count, nil} = Repo.insert_all(schema, chunk)

      if count != length(chunk) do
        raise "insert_all wrote #{count} of #{length(chunk)} rows into #{inspect(schema)}"
      end
    end)
  end

  # Ecto emits `[:gtfs_planner, :repo, :query]` in the process that issued the
  # query, so the tally lives in an Agent that any process can update.
  # `count_queries/1` answers `{result, elapsed_ms, query_count}`.
  defp count_queries(fun) do
    counter = start_supervised!({Agent, fn -> 0 end}, id: {:stops_map_budget_counter, make_ref()})
    handler_id = "stops-map-budget-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, counter ->
        if metadata.repo == Repo, do: Agent.update(counter, &(&1 + 1))
      end,
      counter
    )

    try do
      {elapsed_us, result} = :timer.tc(fun)
      {result, div(elapsed_us, 1_000), Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
    end
  end
end
