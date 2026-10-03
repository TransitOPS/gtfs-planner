defmodule GtfsPlanner.Gtfs.Routes.MapPerformanceTest do
  @moduledoc """
  Deterministic 500-route map workload (spec 16, step 32 — AC-30, EV-8).

  One published version holds the declared workload: the current route plus
  499 other routes, every route carrying its own distinct
  geometry assembled from `route_patterns`, `route_pattern_stops`, `stops` and
  `shapes`/`trips` rows. `GtfsPlanner.Gtfs.Routes.Map.route_map/3` and
  `route_context_map/4` are exercised through the ordinary public facades
  (`Gtfs.route_map/3`, `Gtfs.route_context_map/4`, seam `S-3`) — the same
  production composition the Details map hook consumes, with concrete internal
  adapters and no private LiveView assign injection.

  The workload lives in this dedicated module so the small diagnosable
  interaction fixtures in `map_test.exs` stay untouched (spec note C1).
  Measurements record payload bytes, SQL query counts and wall time; they
  establish mechanism and growth shape on the declared fixture, not deployed
  production capacity (R7).
  """

  use GtfsPlanner.DataCase

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # The declared workload: 500 routes in one published version — the current
  # route plus 499 context routes.
  @current_route_id "mw_000"
  @workload_routes 500
  @context_routes 499
  @context_pages 10
  @page_size 50

  # The viewport the context reads use: exactly the current route's bounding
  # box, which contains every context route's corridor.
  @bounds %{north: 1.5, south: 1.0, east: 2.5, west: 2.0}

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "the 500-route workload through the ordinary public entrypoint" do
    @tag :map_workload
    test "repeated trip references on a fixed geometry add no geometry entries and no per-trip queries",
         %{organization: org, version: version} do
      build_workload(org, version)

      assert trip_count(org, version) == @workload_routes

      {:ok, map_before} = Gtfs.route_map(org.id, version.id, @current_route_id)

      assert {:ok, context_before} =
               Gtfs.route_context_map(org.id, version.id, @current_route_id, %{
                 bounds: @bounds,
                 cursor: nil
               })

      {{:ok, _}, map_measured} =
        measure(fn -> Gtfs.route_map(org.id, version.id, @current_route_id) end)

      {{:ok, _}, context_measured} =
        measure(fn ->
          Gtfs.route_context_map(org.id, version.id, @current_route_id, %{
            bounds: @bounds,
            cursor: nil
          })
        end)

      # Nine more trips, every one reusing an existing shape: four on the
      # current route's imported shape, five on context route mw_001's shape.
      add_reused_trips(org, version)

      assert trip_count(org, version) == @workload_routes + 9

      # route_map/3: the whole projection is unchanged — no extra visit,
      # section or variant entry anywhere.
      assert Gtfs.route_map(org.id, version.id, @current_route_id) == {:ok, map_before}

      # route_context_map/4: the page is unchanged too — geometry is
      # deduplicated by shape, so repeated trips contribute no entries.
      assert {:ok, context_after} =
               Gtfs.route_context_map(org.id, version.id, @current_route_id, %{
                 bounds: @bounds,
                 cursor: nil
               })

      assert context_after == context_before

      # No per-trip SQL queries: the query counts are identical before and
      # after trip multiplicity grew ninefold on the two fixed shapes.
      {{:ok, _}, map_measured_after} =
        measure(fn -> Gtfs.route_map(org.id, version.id, @current_route_id) end)

      {{:ok, _}, context_measured_after} =
        measure(fn ->
          Gtfs.route_context_map(org.id, version.id, @current_route_id, %{
            bounds: @bounds,
            cursor: nil
          })
        end)

      assert map_measured_after.queries == map_measured.queries
      assert context_measured_after.queries == context_measured.queries

      # The workload still fits the established fixed query sets.
      assert map_measured.queries <= 6
      assert context_measured.queries <= 6
    end

    @tag :map_workload
    test "records payload bytes, SQL query counts and timings for the current route and every context page",
         %{organization: org, version: version} do
      build_workload(org, version)

      {{:ok, map}, map_m} =
        measure(fn -> Gtfs.route_map(org.id, version.id, @current_route_id) end)

      map_bytes = :erlang.external_size(map)

      assert map.status == :ok
      assert length(map.patterns) == 2
      assert length(map.imported_shape_variants) == 1
      assert map_m.queries <= 6

      {pages, totals} = paginate_context(org, version)

      # 499 other routes arrive as #{@context_pages} deterministic keyset
      # pages: nine full pages of #{@page_size} and a final page of 49.
      assert length(pages) == @context_pages

      page_sizes = Enum.map(pages, &length(&1.routes))
      assert Enum.drop(page_sizes, -1) == List.duplicate(@page_size, @context_pages - 1)
      assert List.last(page_sizes) == @context_routes - @page_size * (@context_pages - 1)

      all_ids = pages |> Enum.flat_map(& &1.routes) |> Enum.map(& &1.route_id)
      assert length(all_ids) == @context_routes
      assert all_ids == Enum.sort(all_ids)
      assert length(Enum.uniq(all_ids)) == @context_routes
      refute @current_route_id in all_ids

      # The fixture really is distinct geometry: each context route carries
      # exactly one saved stop_pair section and one saved imported shape, and
      # no two routes share a section coordinate list.
      context_routes = Enum.flat_map(pages, & &1.routes)

      assert Enum.all?(context_routes, fn route ->
               match?(
                 [%{source: :stop_pair, status: :saved, coordinates: [_, _]}],
                 route.sections
               ) and
                 match?(
                   [%{source: :imported_shape, status: :saved, coordinates: [_, _]}],
                   route.imported_shape_variants
                 )
             end)

      section_signatures =
        Enum.map(context_routes, fn route ->
          Enum.map(route.sections, & &1.coordinates)
        end)

      assert length(Enum.uniq(section_signatures)) == @context_routes

      IO.puts(
        "map workload: #{@workload_routes} routes, distinct geometry " <>
          "(fixture-scale mechanism measurement, not deployed capacity)"
      )

      IO.puts("  route_map      #{format_measurement(map_bytes, map_m)}")

      Enum.with_index(pages, 1)
      |> Enum.each(fn {page, number} ->
        IO.puts(
          "  context page #{String.pad_leading(Integer.to_string(number), 2, "0")} " <>
            "routes=#{length(page.routes)} #{format_measurement(:erlang.external_size(page), Map.fetch!(totals.pages, number))}"
        )
      end)

      IO.puts(
        "  context total  pages=#{length(pages)} routes=#{@context_routes} " <>
          format_measurement(totals.bytes, totals)
      )
    end

    @tag :map_workload
    test "complete current route, paginated context and local preview reads coexist on the declared workload",
         %{organization: org, version: version} do
      build_workload(org, version)

      {:ok, map_before} = Gtfs.route_map(org.id, version.id, @current_route_id)

      # The current route is complete: every pattern's ordered visits, its
      # saved connector sections and the imported shape variant are present.
      assert %{
               status: :ok,
               route_id: @current_route_id,
               saved_alignment: :unavailable,
               patterns: [trunk, branch],
               imported_shape_variants: [variant]
             } = map_before

      assert length(trunk.visits) == 3
      assert length(branch.visits) == 2

      assert Enum.all?(trunk.visits ++ branch.visits, fn visit ->
               %{coordinates: [lon, lat]} = visit
               is_float(lon) and is_float(lat)
             end)

      assert [
               %{source: :stop_pair, status: :saved, from_position: 1, to_position: 2},
               %{source: :stop_pair, status: :saved, from_position: 2, to_position: 3}
             ] =
               trunk.sections

      assert [%{source: :stop_pair, status: :saved}] = branch.sections
      assert %{source: :imported_shape, status: :saved, shape_id: "mw_sh_000"} = variant
      assert length(variant.coordinates) == 3

      # The context paginates fully beside that complete current route.
      {pages, totals} = paginate_context(org, version)

      assert length(pages) == @context_pages
      assert pages |> Enum.flat_map(& &1.routes) |> length() == @context_routes

      # Paging the context leaves the current route's own read untouched.
      {{:ok, map_after}, map_m} =
        measure(fn -> Gtfs.route_map(org.id, version.id, @current_route_id) end)

      assert map_after == map_before

      # The under-100ms local color preview (AC-19) on this declared fixture is
      # the browser half of this case: assets/e2e/route_lifecycle_map.spec.js
      # measures the picker feedback against the same seeded workload (EV-8's
      # exact second procedure). This boundary records the server-side reads
      # the preview composes beside.
      IO.puts(
        "map workload coexistence: complete current route (2 patterns, 1 variant) beside " <>
          "#{@context_routes} context routes in #{length(pages)} pages"
      )

      IO.puts("  route_map      #{format_measurement(:erlang.external_size(map_after), map_m)}")

      IO.puts(
        "  context total  pages=#{length(pages)} #{format_measurement(totals.bytes, totals)}"
      )
    end
  end

  # ── Workload fixture ────────────────────────────────────────────────────────

  # The current route through the ordinary fixture path, then the context
  # routes as deterministic bulk rows.
  defp build_workload(org, version) do
    route_fixture(org.id, version.id, %{
      route_id: @current_route_id,
      route_short_name: "M0",
      route_long_name: "Map workload current route",
      route_color: "FF0000",
      route_text_color: "FFFFFF"
    })

    trunk =
      route_pattern_fixture(org.id, version.id, %{
        route_pattern_id: "mw_p1",
        route_id: @current_route_id,
        route_pattern_name: "Workload trunk",
        route_pattern_sort_order: 0
      })

    branch =
      route_pattern_fixture(org.id, version.id, %{
        route_pattern_id: "mw_p2",
        route_id: @current_route_id,
        route_pattern_name: "Workload branch",
        route_pattern_sort_order: 1
      })

    # The trunk spans the whole corridor so a fitted map viewport contains
    # every context route; the branch sits inside it.
    [
      {trunk, "mw_stop_a", 1, "1.0", "2.0"},
      {trunk, "mw_stop_b", 2, "1.25", "2.25"},
      {trunk, "mw_stop_c", 3, "1.5", "2.5"},
      {branch, "mw_stop_d", 1, "1.1", "2.1"},
      {branch, "mw_stop_e", 2, "1.2", "2.2"}
    ]
    |> Enum.each(fn {pattern, stop_id, position, lat, lon} ->
      stop_fixture(org.id, version.id, %{
        stop_id: stop_id,
        stop_name: "Workload stop #{stop_id}",
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new(lon)
      })

      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    # One imported shape spanning the corridor, one trip referencing it.
    [{"1.0", "2.0", 1}, {"1.25", "2.25", 2}, {"1.5", "2.5", 3}]
    |> Enum.each(fn {lat, lon, sequence} ->
      Repo.insert!(%Shape{
        organization_id: org.id,
        gtfs_version_id: version.id,
        shape_id: "mw_sh_000",
        shape_pt_lat: Decimal.new(lat),
        shape_pt_lon: Decimal.new(lon),
        shape_pt_sequence: sequence
      })
    end)

    trip =
      trip_fixture(org.id, version.id, @current_route_id, %{
        trip_id: "mw_trip_000",
        service_id: "mw_service",
        shape_id: "mw_sh_000"
      })

    # Trip.changeset/2 does not cast route_pattern_id (step 17 finding), so
    # the link is set directly.
    Repo.update!(Ecto.Changeset.change(trip, route_pattern_id: "mw_p1"))

    insert_context_routes(org, version)
  end

  defp insert_context_routes(org, version) do
    now = now()
    pattern_ids = Map.new(1..@context_routes, fn i -> {i, Ecto.UUID.generate()} end)

    route_rows = Enum.map(1..@context_routes, &context_route_row(org, version, &1, now))

    pattern_rows =
      Enum.map(
        1..@context_routes,
        &context_pattern_row(org, version, &1, now, Map.fetch!(pattern_ids, &1))
      )

    stop_rows = Enum.flat_map(1..@context_routes, &context_stop_rows(org, version, &1, now))

    occurrence_rows =
      Enum.flat_map(1..@context_routes, fn i ->
        context_occurrence_rows(org, version, i, now)
      end)

    shape_rows = Enum.flat_map(1..@context_routes, &context_shape_rows(org, version, &1, now))
    trip_rows = Enum.map(1..@context_routes, &context_trip_row(org, version, &1, now))

    chunked_insert(Route, route_rows)
    chunked_insert(RoutePattern, pattern_rows)
    chunked_insert(Stop, stop_rows)
    chunked_insert(RoutePatternStop, occurrence_rows)
    chunked_insert(Shape, shape_rows)
    chunked_insert(Trip, trip_rows)
  end

  # Nine more trips that all reuse existing shapes: four on the current
  # route's imported shape and five on context route mw_001's shape.
  defp add_reused_trips(org, version) do
    now = now()

    rows =
      for {route_id, pattern_id, shape_id, range} <- [
            {@current_route_id, "mw_p1", "mw_sh_000", 1..4},
            {"mw_001", "mw_p_001", "mw_sh_001", 1..5}
          ],
          n <- range do
        %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: version.id,
          trip_id: "mw_reuse_#{route_id}_#{n}",
          route_id: route_id,
          service_id: "mw_service",
          shape_id: shape_id,
          route_pattern_id: pattern_id,
          direction_id: 0,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Trip, rows)
  end

  defp context_route_row(org, version, i, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: org.id,
      gtfs_version_id: version.id,
      route_id: context_route_id(i),
      route_short_name: "M#{i}",
      route_long_name: "Map workload route #{i}",
      route_type: 3,
      active: true,
      inserted_at: now,
      updated_at: now
    }
  end

  defp context_pattern_row(org, version, i, now, pattern_id) do
    %{
      id: pattern_id,
      organization_id: org.id,
      gtfs_version_id: version.id,
      route_pattern_id: "mw_p_#{pad(i)}",
      route_id: context_route_id(i),
      direction_id: 0,
      route_pattern_name: "Workload context #{i}",
      route_pattern_sort_order: 0,
      inserted_at: now,
      updated_at: now
    }
  end

  defp context_stop_rows(org, version, i, now) do
    {{lat_a, lon_a}, {lat_b, lon_b}} = context_coordinates(i)

    base = %{
      organization_id: org.id,
      gtfs_version_id: version.id,
      inserted_at: now,
      updated_at: now
    }

    [
      Map.merge(base, %{
        id: Ecto.UUID.generate(),
        stop_id: "mw_stop_#{pad(i)}_a",
        stop_name: "Workload stop #{context_route_id(i)} a",
        stop_lat: dec(lat_a),
        stop_lon: dec(lon_a),
        location_type: 0
      }),
      Map.merge(base, %{
        id: Ecto.UUID.generate(),
        stop_id: "mw_stop_#{pad(i)}_b",
        stop_name: "Workload stop #{context_route_id(i)} b",
        stop_lat: dec(lat_b),
        stop_lon: dec(lon_b),
        location_type: 0
      })
    ]
  end

  defp context_occurrence_rows(org, version, i, now) do
    [
      %{
        id: Ecto.UUID.generate(),
        route_pattern_id: "mw_p_#{pad(i)}",
        organization_id: org.id,
        gtfs_version_id: version.id,
        stop_id: "mw_stop_#{pad(i)}_a",
        position: 1,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        route_pattern_id: "mw_p_#{pad(i)}",
        organization_id: org.id,
        gtfs_version_id: version.id,
        stop_id: "mw_stop_#{pad(i)}_b",
        position: 2,
        inserted_at: now,
        updated_at: now
      }
    ]
  end

  defp context_shape_rows(org, version, i, now) do
    {{lat_a, lon_a}, {lat_b, lon_b}} = context_coordinates(i)
    shape_id = "mw_sh_#{pad(i)}"

    [
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: version.id,
        shape_id: shape_id,
        shape_pt_lat: dec(lat_a),
        shape_pt_lon: dec(lon_a),
        shape_pt_sequence: 1,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: version.id,
        shape_id: shape_id,
        shape_pt_lat: dec(lat_b),
        shape_pt_lon: dec(lon_b),
        shape_pt_sequence: 2,
        inserted_at: now,
        updated_at: now
      }
    ]
  end

  defp context_trip_row(org, version, i, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: org.id,
      gtfs_version_id: version.id,
      trip_id: "mw_trip_#{pad(i)}",
      route_id: context_route_id(i),
      service_id: "mw_service",
      shape_id: "mw_sh_#{pad(i)}",
      route_pattern_id: "mw_p_#{pad(i)}",
      direction_id: 0,
      inserted_at: now,
      updated_at: now
    }
  end

  # Every context route owns a distinct two-stop corridor strictly inside the
  # current route's bounding box (lat 1.0..1.5, lon 2.0..2.5), so all of them
  # sit in the fitted map viewport and in the context bounds.
  defp context_coordinates(i) do
    lat = 1.02 + i * 0.0009
    lon = 2.02 + i * 0.0009
    {{lat, lon}, {lat + 0.0004, lon + 0.0004}}
  end

  defp context_route_id(i), do: "mw_#{pad(i)}"

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 3, "0")

  defp dec(value), do: value |> :erlang.float_to_binary(decimals: 4) |> Decimal.new()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp chunked_insert(schema, rows) do
    rows
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(schema, &1))
  end

  # ── Measurement helpers ─────────────────────────────────────────────────────

  # Walks every context page through the public facade, measuring each read.
  defp paginate_context(org, version) do
    paginate_context(org, version, nil, 1, [], %{queries: 0, time_us: 0, bytes: 0, pages: %{}})
  end

  defp paginate_context(org, version, cursor, page_number, pages, totals) do
    {{:ok, page}, m} =
      measure(fn ->
        Gtfs.route_context_map(org.id, version.id, @current_route_id, %{
          bounds: @bounds,
          cursor: cursor
        })
      end)

    assert page.status == :ok
    assert length(page.routes) <= @page_size
    assert m.queries <= 6

    # INV-5 at scale: every entry keeps its source and a truthful status.
    for route <- page.routes do
      for section <- route.sections do
        assert section.source == :stop_pair
        assert section.status in [:saved, :missing, :unavailable]
      end

      for variant <- route.imported_shape_variants do
        assert variant.source == :imported_shape
        assert variant.status in [:saved, :missing]
      end
    end

    bytes = :erlang.external_size(page)

    totals = %{
      queries: totals.queries + m.queries,
      time_us: totals.time_us + m.time_us,
      bytes: totals.bytes + bytes,
      pages: Map.put(totals.pages, page_number, m)
    }

    pages = [page | pages]

    if page.partial do
      assert is_binary(page.next_cursor)
      paginate_context(org, version, page.next_cursor, page_number + 1, pages, totals)
    else
      assert page.next_cursor == nil
      {Enum.reverse(pages), totals}
    end
  end

  defp trip_count(org, version) do
    Repo.aggregate(
      from(t in Trip,
        where: t.organization_id == ^org.id and t.gtfs_version_id == ^version.id
      ),
      :count
    )
  end

  # Counts SQL queries through the same repository telemetry event the small
  # interaction tests use, plus wall time for the recorded measurements.
  defp measure(fun) do
    test_pid = self()
    handler_id = "map-workload-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test_pid, :repo_query) end,
      nil
    )

    try do
      {time_us, result} = :timer.tc(fun)
      {result, %{queries: drain_queries(0), time_us: time_us}}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(count) do
    receive do
      :repo_query -> drain_queries(count + 1)
    after
      0 -> count
    end
  end

  defp format_measurement(bytes, m) do
    "bytes=#{bytes} queries=#{m.queries} time_us=#{m.time_us}"
  end
end
