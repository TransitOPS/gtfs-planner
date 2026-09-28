defmodule GtfsPlanner.Gtfs.CatalogReadAdapter.Repo do
  @moduledoc """
  Production `GtfsPlanner.Gtfs.CatalogReadAdapter` implementation.

  It reuses the catalog and detail queries the route and Stops & stations
  surfaces already read through and adds only outcome classification plus
  canonical page clamping. Catalog reads count the matching rows, clamp the
  requested page to `1..max_page`, and only then fetch rows at that canonical
  page, so pagination metadata and fetched rows cannot disagree.

  A lost database connection becomes `{:error, :unavailable}`. A missing route
  or stop becomes `{:error, :not_found}`. Stop-catalog route enrichment runs
  separately from the primary stop read, so an enrichment failure yields
  `{:partial, page, :route_enrichment_unavailable}` while keeping the loaded
  stop rows. Station-detail regions resolve independently so one failing region
  does not erase the others. Calendar list and detail reads delegate to
  `GtfsPlanner.Gtfs.Calendars` and unwrap only its outer transaction tuple while
  preserving the domain's own `{:error, :not_found}`. A blocking day read delegates to
  `GtfsPlanner.Gtfs.Blocking` and unwraps its transaction tuple the same way, as do the
  Schedules block warning and the first-day-type key. The calendar screen read
  delegates the same way, so its one protected snapshot carries the summaries, the
  resolved agency-local today and the global horizon and gaps, with `gaps: nil`
  and `complete?: false` when the version holds a retained invalid calendar range.
  The calendar list feed status resolves the agency-local today once and reports
  the version-wide service gaps with it. The Fare zones workspace resolves its inventory, checks
  and first stop page in one operational read, so a lost connection is reported
  once for the whole workspace. Nothing else is rescued, so
  a malformed id, a bad query, or any other defect still raises rather than being
  reported as downtime.
  """

  @behaviour GtfsPlanner.Gtfs.CatalogReadAdapter

  alias GtfsPlanner.Gtfs

  alias GtfsPlanner.Gtfs.{
    Blocking,
    Calendars,
    DisplayClock,
    FareZones,
    Route,
    RoutePatterns,
    Routes,
    Schedules,
    Stop,
    Transfers
  }

  @default_per_page 25

  @phase_event [:gtfs_planner, :stop_catalog, :phase]

  @impl true
  def load_route_catalog(organization_id, gtfs_version_id, opts) do
    run(fn ->
      per_page = resolve_per_page(opts)
      total_count = Gtfs.count_routes(organization_id, gtfs_version_id, opts)
      page = canonical_page(opts[:page], total_count, per_page)

      rows =
        Gtfs.list_routes(organization_id, gtfs_version_id, Keyword.put(opts, :page, page))

      %{
        rows: rows,
        total_count: total_count,
        page: page,
        route_types: Gtfs.list_distinct_route_types(organization_id, gtfs_version_id),
        agencies: Gtfs.list_distinct_agencies(organization_id, gtfs_version_id)
      }
    end)
  end

  @impl true
  def load_stop_catalog(organization_id, gtfs_version_id, opts) do
    per_page = resolve_per_page(opts)

    case primary_stop_page(organization_id, gtfs_version_id, opts, per_page) do
      {:error, :unavailable} = error -> error
      {:ok, page} -> merge_route_enrichment(page, organization_id, gtfs_version_id)
    end
  end

  @impl true
  def fetch_route(organization_id, gtfs_version_id, route_id) do
    case run(fn -> Gtfs.get_route_by_route_id(organization_id, gtfs_version_id, route_id) end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Route{} = route} -> {:ok, route}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def load_route_editor(organization_id, gtfs_version_id, route_id) do
    case run(fn -> Routes.route_editor(organization_id, gtfs_version_id, route_id) end) do
      {:ok, {:ok, workspace}} -> {:ok, workspace}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def load_route_patterns(organization_id, gtfs_version_id, route_id) do
    run(fn -> Gtfs.list_route_patterns_for_route(organization_id, gtfs_version_id, route_id) end)
  end

  @impl true
  def load_route_pattern_screen(organization_id, gtfs_version_id, route_id, opts) do
    case run(fn ->
           RoutePatterns.pattern_screen(organization_id, gtfs_version_id, route_id, opts)
         end) do
      {:ok, {:ok, screen}} -> {:ok, screen}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def search_stops(organization_id, gtfs_version_id, query) do
    case run(fn -> RoutePatterns.search_stops(organization_id, gtfs_version_id, query) end) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def fetch_stop(organization_id, gtfs_version_id, stop_id) do
    case run(fn -> Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Stop{} = stop} -> {:ok, stop}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def load_calendar_catalog(organization_id, gtfs_version_id, opts) do
    case run(fn -> Calendars.list_calendars(organization_id, gtfs_version_id, opts) end) do
      {:ok, {:ok, summaries}} -> {:ok, summaries}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def load_calendar_screen(organization_id, gtfs_version_id, opts) do
    case run(fn -> Calendars.load_screen(organization_id, gtfs_version_id, opts) end) do
      {:ok, {:ok, screen}} -> {:ok, screen}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def load_calendar_feed_status(organization_id, gtfs_version_id) do
    case run(fn ->
           zone = DisplayClock.today(organization_id, gtfs_version_id)
           {zone, Calendars.feed_service_gaps(organization_id, gtfs_version_id, zone.date)}
         end) do
      {:ok, {zone, {:ok, gaps}}} -> {:ok, %{today: zone.date, zone: zone, gaps: gaps}}
      {:ok, {_today, {:error, reason}}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def fetch_calendar(organization_id, gtfs_version_id, service_id) do
    case run(fn -> Calendars.get_calendar(organization_id, gtfs_version_id, service_id) end) do
      {:ok, {:ok, payload}} -> {:ok, payload}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def load_route_schedule(organization_id, gtfs_version_id, route_id, filters) do
    case run(fn ->
           Schedules.load_route_schedule(organization_id, gtfs_version_id, route_id, filters)
         end) do
      {:ok, {:ok, schedule}} -> {:ok, schedule}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def load_blocking_day(organization_id, gtfs_version_id, day_type_key) do
    case run(fn -> Blocking.load_day(organization_id, gtfs_version_id, day_type_key) end) do
      {:ok, {:ok, day}} -> {:ok, day}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def block_problems_for_trips(organization_id, gtfs_version_id, trip_ids) do
    case run(fn ->
           Blocking.block_problems_for_trips(organization_id, gtfs_version_id, trip_ids)
         end) do
      {:ok, {:ok, problems}} -> {:ok, problems}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def first_day_type_key(organization_id, gtfs_version_id, service_id) do
    case run(fn -> Blocking.first_day_type_key(organization_id, gtfs_version_id, service_id) end) do
      {:ok, {:ok, key}} -> {:ok, key}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def load_transfer_catalog(organization_id, gtfs_version_id, opts) do
    run(fn -> Transfers.load_catalog(organization_id, gtfs_version_id, opts) end)
  end

  @impl true
  def load_stop_regions(organization_id, gtfs_version_id, %Stop{} = station) do
    %{
      child_stops:
        run(fn ->
          Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station.id)
        end),
      levels:
        run(fn -> Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id) end),
      pathways:
        run(fn ->
          Gtfs.list_pathways_for_station(organization_id, gtfs_version_id, station.id)
        end),
      editing_status:
        run(fn ->
          Gtfs.get_station_editing_status(organization_id, gtfs_version_id, station.id)
        end)
    }
  end

  @impl true
  def load_fare_workspace(organization_id, gtfs_version_id, opts) do
    run(fn ->
      %{
        inventory: FareZones.inventory(organization_id, gtfs_version_id),
        checks: FareZones.checks(organization_id, gtfs_version_id),
        stops: FareZones.list_stops(organization_id, gtfs_version_id, opts)
      }
    end)
  end

  defp primary_stop_page(organization_id, gtfs_version_id, opts, per_page) do
    {duration, result} =
      measure(fn ->
        run(fn ->
          total_count = Gtfs.count_stations(organization_id, gtfs_version_id, opts)
          page = canonical_page(opts[:page], total_count, per_page)

          rows =
            Gtfs.list_stations(
              organization_id,
              gtfs_version_id,
              Keyword.put(opts, :page, page)
            )

          %{rows: rows, total_count: total_count, page: page}
        end)
      end)

    case result do
      {:ok, page} ->
        emit_phase(:primary, :ok, duration, length(page.rows))
        {:ok, page}

      {:error, :unavailable} ->
        emit_phase(:primary, :unavailable, duration, 0)
        {:error, :unavailable}
    end
  end

  defp merge_route_enrichment(page, organization_id, gtfs_version_id) do
    {duration, result} =
      measure(fn ->
        run(fn -> route_enrichment(organization_id, gtfs_version_id, page.rows) end)
      end)

    case result do
      {:ok, enrichment} ->
        enriched = Map.merge(page, enrichment)
        emit_phase(:route_enrichment, :ok, duration, length(enriched.rows))
        {:ok, enriched}

      {:error, :unavailable} ->
        partial = Map.merge(page, empty_enrichment())
        emit_phase(:route_enrichment, :unavailable, duration, length(partial.rows))
        {:partial, partial, :route_enrichment_unavailable}
    end
  end

  defp route_enrichment(organization_id, gtfs_version_id, rows) do
    stop_ids = Enum.map(rows, & &1.stop_id)

    %{
      available_routes: Gtfs.list_routes_serving_stations(organization_id, gtfs_version_id),
      routes_by_stop: Gtfs.get_routes_for_stops(organization_id, gtfs_version_id, stop_ids)
    }
  end

  defp empty_enrichment do
    %{available_routes: [], routes_by_stop: %{}}
  end

  # Clamps a requested page to a valid canonical page for the given total. A
  # missing, non-integer, or out-of-bounds request resolves to the nearest valid
  # page so the queried rows always match the reported page. An empty collection
  # still reports page 1.
  defp canonical_page(requested, total_count, per_page) do
    max_page = max(1, div(total_count + per_page - 1, per_page))

    requested =
      if is_integer(requested) and requested >= 1, do: requested, else: 1

    requested |> min(max_page) |> max(1)
  end

  defp resolve_per_page(opts) do
    case opts[:per_page] do
      per_page when is_integer(per_page) and per_page >= 1 -> per_page
      _ -> @default_per_page
    end
  end

  # Wraps query execution only. `DBConnection.ConnectionError` is the single
  # recoverable operational failure; every other exception propagates so a code
  # defect can never be reported to an operator as downtime.
  defp run(query) do
    {:ok, query.()}
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  defp measure(fun) do
    start = System.monotonic_time()
    result = fun.()
    {System.monotonic_time() - start, result}
  end

  defp emit_phase(phase, outcome, duration, row_count) do
    :telemetry.execute(
      @phase_event,
      %{duration: duration},
      %{phase: phase, outcome: outcome, row_count: row_count}
    )
  end
end
