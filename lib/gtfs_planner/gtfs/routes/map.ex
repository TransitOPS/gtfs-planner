defmodule GtfsPlanner.Gtfs.Routes.Map do
  @moduledoc """
  Batched read-only route-map projection (seam `S-3`).

  `route_map/3` projects one published route's saved geometry from landed
  `route_patterns`, `route_pattern_stops`, `stops` and `shapes`/`trips` rows in
  one fixed query set — never one read per pattern and never a route editor
  call per pattern. It returns the scoped route UUID, every current-route
  pattern with its ordered occurrence visits and connector sections, the
  distinct imported shape variants and the overall read status.

  Coordinates are JSON numbers in `[lon, lat]` order at this boundary; the
  Leaflet hook converts them explicitly. Coordinates are omitted only together
  with explicit `unlocated` metadata, and a connector with unlocated endpoints
  is never fabricated. Loop patterns keep every occurrence: visits carry their
  occurrence `position` and sections reference `from_position`/`to_position`,
  so a stop visited twice keeps two distinct occurrence identities. Imported
  trip shapes are deduplicated by `shape_id` and labelled as variants, so
  duplicate trip copies never duplicate geometry. Each variant also carries
  `outside_trip_count`: how many of its trips are outside every route pattern
  (`custom` derivation), counted from landed trip rows, with
  `route_pattern_ids` naming only the patterns its trips are linked to.

  Every section carries its `source` (`:stop_pair` for connectors derived from
  ordered stop coordinates, `:imported_shape` for `shapes` rows) and a truthful
  saved-geometry `status` (INV-5): `:saved` is geometry present in landed rows
  and returned verbatim, `:missing` is geometry known absent (a stored stop
  without coordinates, a referenced shape without points), and `:unavailable`
  is geometry that cannot be determined — unknown geometry is `:unavailable`,
  never fabricated as `:missing` or `:saved`. Saved-alignment sections report
  `:unavailable` in this baseline and are never fabricated: when package 12
  lands `resolve/1` and `route_summary/3`, seam `S-3` delegates section
  resolution there. No `GtfsPlanner.Gtfs.Alignments` context exists here and
  none is called.

  A foreign, unpublished or unknown scope is `{:error, :not_found}` with no
  map fragments; a lost database connection is `{:error, :unavailable}`. Map
  reads fail independently of editor reads.

  `route_context_map/4` pages the *other* routes of the same published version
  whose saved geometry falls inside a viewport. Pagination is a stable keyset
  over deterministic route-id order — 50 contextual routes per page as a code
  constant — and the geometry it returns is deduplicated per route by shape and
  section, so trip multiplicity never multiplies entries (AC-27/AC-30). The
  current route is excluded and stays complete in `route_map/3`; the two reads
  page and fail independently. Malformed bounds and cursors are rejected, never
  coerced, and every context section keeps the same `source` and
  `saved | missing | unavailable` truthfulness as the current route (INV-5).
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values

  # How many contextual routes one page carries. A code constant by contract
  # (R7), not runtime configuration.
  @context_page_size 50

  # The opaque, deterministic keyset cursor: `"ctx1:" <> last route_id`. The
  # prefix versions the format so an unrecognised token is rejected instead of
  # being interpreted as a route id.
  @context_cursor_prefix "ctx1:"

  @type coordinate :: [number()]
  @type unlocated_reason :: :coordinates_absent | :stop_not_found | :shape_points_absent
  @type unlocated :: %{ref: String.t(), reason: unlocated_reason()}
  @type visit ::
          %{required(:position) => pos_integer(), required(:stop_id) => String.t()}
          | %{
              required(:position) => pos_integer(),
              required(:stop_id) => String.t(),
              required(:coordinates) => coordinate()
            }
          | %{
              required(:position) => pos_integer(),
              required(:stop_id) => String.t(),
              required(:unlocated) => [unlocated()]
            }
  @type connector_section :: %{
          optional(:coordinates) => [coordinate()],
          optional(:unlocated) => [unlocated()],
          source: :stop_pair,
          status: :saved | :missing | :unavailable,
          from_position: pos_integer(),
          to_position: pos_integer()
        }
  @type shape_variant :: %{
          optional(:coordinates) => [coordinate()],
          optional(:unlocated) => [unlocated()],
          source: :imported_shape,
          status: :saved | :missing,
          shape_id: String.t(),
          variant: pos_integer(),
          label: String.t(),
          route_pattern_ids: [String.t()],
          outside_trip_count: non_neg_integer()
        }
  @type pattern_map :: %{
          id: Ecto.UUID.t(),
          route_pattern_id: String.t(),
          direction_id: integer() | nil,
          route_pattern_name: String.t() | nil,
          visits: [visit()],
          sections: [connector_section()]
        }
  @type route_map :: %{
          route_uuid: Ecto.UUID.t(),
          route_id: String.t(),
          status: :ok,
          saved_alignment: :unavailable,
          patterns: [pattern_map()],
          imported_shape_variants: [shape_variant()]
        }
  @type context_shape :: %{
          optional(:coordinates) => [coordinate()],
          optional(:unlocated) => [unlocated()],
          source: :imported_shape,
          status: :saved | :missing,
          shape_id: String.t()
        }
  @type context_route :: %{
          route_uuid: Ecto.UUID.t(),
          route_id: String.t(),
          route_short_name: String.t() | nil,
          route_long_name: String.t() | nil,
          route_color: String.t() | nil,
          route_text_color: String.t() | nil,
          active: boolean() | nil,
          sections: [connector_section()],
          imported_shape_variants: [context_shape()]
        }
  @type route_context_map :: %{
          status: :ok,
          partial: boolean(),
          next_cursor: String.t() | nil,
          routes: [context_route()]
        }

  @doc """
  Projects one published route's saved map geometry (R7, seam `S-3`).

  Every current-route pattern is included with its ordered occurrence visits,
  their stop coordinates and connector sections. Patterns without trips keep
  their own saved sections; loops keep every occurrence and closing connector.
  Distinct imported trip shapes are returned once each as labelled variants.
  """
  @spec route_map(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, route_map()} | {:error, :not_found | :unavailable}
  def route_map(organization_id, gtfs_version_id, route_id) do
    with {:ok, route} <- RoutePatterns.published_route(organization_id, gtfs_version_id, route_id) do
      patterns = load_patterns(route)
      visits = load_visits(route, patterns)

      {:ok,
       %{
         route_uuid: route.id,
         route_id: route.route_id,
         status: :ok,
         saved_alignment: :unavailable,
         patterns: Enum.map(patterns, &pattern_map(&1, Map.get(visits, &1.route_pattern_id, []))),
         imported_shape_variants: load_shape_variants(route)
       }}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  @doc """
  Pages the saved context geometry of the version's *other* routes (R7, AC-27).

  `opts` carries `bounds` (a `north`/`south`/`east`/`west` viewport box in
  decimal degrees, atom or string keys) and `cursor` (`nil` for the first page,
  otherwise the previous result's `next_cursor`). Routes are selected by any
  located pattern-stop or shape point inside the box, ordered by deterministic
  route-id keyset, and returned #{@context_page_size} at a time with `partial`
  set until the selection is exhausted. Geometry per route is deduplicated by
  shape and section: repeated trips sharing one imported shape contribute one
  entry. The current route is never part of a page; its complete geometry keeps
  coming from `route_map/3` independently.

  Malformed bounds or a malformed cursor are rejected without a read:
  `{:error, :invalid_bounds}` / `{:error, :invalid_cursor}`.
  """
  @spec route_context_map(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), %{
          required(:bounds) => term(),
          required(:cursor) => term()
        }) ::
          {:ok, route_context_map()}
          | {:error, :not_found | :invalid_bounds | :invalid_cursor | :unavailable}
  def route_context_map(organization_id, gtfs_version_id, current_route_id, %{
        bounds: bounds,
        cursor: cursor
      }) do
    with {:ok, box} <- context_bounds(bounds),
         {:ok, cursor_id} <- context_cursor(cursor),
         {:ok, route} <-
           RoutePatterns.published_route(organization_id, gtfs_version_id, current_route_id) do
      page = context_route_page(route, box, cursor_id)
      partial? = length(page) > @context_page_size
      page_routes = Enum.take(page, @context_page_size)

      {:ok,
       %{
         status: :ok,
         partial: partial?,
         next_cursor: context_next_cursor(partial?, page_routes),
         routes: context_routes(route, page_routes)
       }}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  def route_context_map(_organization_id, _gtfs_version_id, _current_route_id, _opts),
    do: {:error, :invalid_bounds}

  # One keyset page of route rows. `exists` keeps the selection to routes whose
  # own saved geometry reaches the viewport, without loading that geometry
  # here; the page is fetched with one extra row so exhaustion needs no count.
  defp context_route_page(route, box, cursor_id) do
    from(route in Route,
      as: :route,
      where:
        route.organization_id == ^route.organization_id and
          route.gtfs_version_id == ^route.gtfs_version_id and
          route.route_id != ^route.route_id and
          route.route_id > ^cursor_id and
          (exists(context_stops_in_bounds(box)) or exists(context_shapes_in_bounds(box))),
      order_by: [asc: route.route_id],
      limit: ^(@context_page_size + 1)
    )
    |> Repo.all()
  end

  # Patterns joined to their occurrences: the GTFS `route_pattern_id` repeats across
  # organizations and versions, so the join carries the scope.
  defp pattern_visits do
    from(pattern in RoutePattern,
      join: occurrence in RoutePatternStop,
      on:
        occurrence.organization_id == pattern.organization_id and
          occurrence.gtfs_version_id == pattern.gtfs_version_id and
          occurrence.route_pattern_id == pattern.route_pattern_id
    )
  end

  defp context_stops_in_bounds(box) do
    from([pattern, occurrence] in pattern_visits(),
      join: stop in Stop,
      on:
        stop.stop_id == occurrence.stop_id and
          stop.organization_id == occurrence.organization_id and
          stop.gtfs_version_id == occurrence.gtfs_version_id,
      where:
        pattern.route_id == parent_as(:route).route_id and
          pattern.organization_id == parent_as(:route).organization_id and
          pattern.gtfs_version_id == parent_as(:route).gtfs_version_id and
          stop.stop_lat >= ^box.south and stop.stop_lat <= ^box.north and
          stop.stop_lon >= ^box.west and stop.stop_lon <= ^box.east,
      select: 1
    )
  end

  defp context_shapes_in_bounds(box) do
    from(trip in Trip,
      join: shape in Shape,
      on:
        shape.shape_id == trip.shape_id and shape.organization_id == trip.organization_id and
          shape.gtfs_version_id == trip.gtfs_version_id,
      where:
        trip.route_id == parent_as(:route).route_id and
          trip.organization_id == parent_as(:route).organization_id and
          trip.gtfs_version_id == parent_as(:route).gtfs_version_id and
          not is_nil(trip.shape_id) and
          fragment("? BETWEEN ? AND ?", shape.shape_pt_lat, ^box.south, ^box.north) and
          fragment("? BETWEEN ? AND ?", shape.shape_pt_lon, ^box.west, ^box.east),
      select: 1
    )
  end

  # Bounds are the hook's viewport, but this boundary trusts nothing: each
  # corner must be a finite number in range and the box must not be inverted.
  defp context_bounds(bounds) when is_map(bounds) do
    with {:ok, north} <- context_bound(bounds, :north),
         {:ok, south} <- context_bound(bounds, :south),
         {:ok, east} <- context_bound(bounds, :east),
         {:ok, west} <- context_bound(bounds, :west),
         true <-
           south >= -90.0 and north <= 90.0 and west >= -180.0 and east <= 180.0 and
             south <= north and west <= east do
      {:ok, %{north: north, south: south, east: east, west: west}}
    else
      _ -> {:error, :invalid_bounds}
    end
  end

  defp context_bounds(_bounds), do: {:error, :invalid_bounds}

  defp context_bound(bounds, key) do
    with :error <- Map.fetch(bounds, key), :error <- Map.fetch(bounds, Atom.to_string(key)) do
      :error
    else
      {:ok, value} -> context_bound_value(value)
    end
  end

  # Non-finite numbers are rejected by the range check below (NaN compares
  # false, infinities exceed range), so the type check stays a plain guard.
  defp context_bound_value(value) when is_number(value), do: {:ok, value * 1.0}
  defp context_bound_value(_value), do: :error

  # `nil` is the first page; anything else must be this module's own cursor
  # format, so a forged or stale token from another surface cannot be read as
  # a route id.
  defp context_cursor(nil), do: {:ok, ""}

  defp context_cursor(cursor) when is_binary(cursor) do
    case String.split(cursor, @context_cursor_prefix, parts: 2) do
      ["", route_id] when route_id != "" -> {:ok, route_id}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp context_cursor(_cursor), do: {:error, :invalid_cursor}

  defp context_next_cursor(false, _page_routes), do: nil

  defp context_next_cursor(true, page_routes),
    do: @context_cursor_prefix <> List.last(page_routes).route_id

  # One fixed query set for whatever the page holds — never per-route reads.
  defp context_routes(_route, []), do: []

  defp context_routes(route, page_routes) do
    route_ids = Enum.map(page_routes, & &1.route_id)
    patterns_by_route = context_patterns(route, route_ids)
    visits = load_visits(route, List.flatten(Map.values(patterns_by_route)))
    shapes_by_route = context_shape_ids(route, route_ids)

    points_by_shape =
      load_shape_points(route, shapes_by_route |> Map.values() |> List.flatten())

    Enum.map(page_routes, fn page_route ->
      patterns = Map.get(patterns_by_route, page_route.route_id, [])
      shape_ids = Map.get(shapes_by_route, page_route.route_id, [])

      %{
        route_uuid: page_route.id,
        route_id: page_route.route_id,
        route_short_name: page_route.route_short_name,
        route_long_name: page_route.route_long_name,
        route_color: page_route.route_color,
        route_text_color: page_route.route_text_color,
        active: page_route.active,
        sections: context_sections(patterns, visits),
        imported_shape_variants:
          Enum.map(shape_ids, &context_shape_variant(&1, Map.get(points_by_shape, &1, [])))
      }
    end)
  end

  defp context_patterns(_route, []), do: %{}

  defp context_patterns(route, route_ids) do
    from(pattern in RoutePattern,
      where:
        pattern.organization_id == ^route.organization_id and
          pattern.gtfs_version_id == ^route.gtfs_version_id and
          pattern.route_id in ^route_ids,
      order_by: [
        asc: pattern.route_id,
        asc_nulls_last: pattern.route_pattern_sort_order,
        asc: pattern.route_pattern_id
      ]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_id)
  end

  # Same connector derivation as the current route, deduplicated across a
  # route's patterns: two patterns over the same stops carry one section. A
  # pattern with no landed occurrences contributes no section rather than
  # failing the whole page.
  defp context_sections(patterns, visits) do
    patterns
    |> Enum.flat_map(&connector_sections(Map.get(visits, &1.route_pattern_id, [])))
    |> Enum.uniq_by(&{&1.source, &1.status, Map.get(&1, :coordinates), Map.get(&1, :unlocated)})
  end

  # Distinct imported shapes per route: one entry per shape_id no matter how
  # many trips repeat it (AC-27).
  defp context_shape_ids(_route, []), do: %{}

  defp context_shape_ids(route, route_ids) do
    from(trip in Trip,
      where:
        trip.organization_id == ^route.organization_id and
          trip.gtfs_version_id == ^route.gtfs_version_id and
          trip.route_id in ^route_ids and not is_nil(trip.shape_id),
      distinct: true,
      order_by: [asc: trip.route_id, asc: trip.shape_id],
      select: {trip.route_id, trip.shape_id}
    )
    |> Repo.all()
    |> Enum.group_by(fn {route_id, _shape_id} -> route_id end, fn {_route_id, shape_id} ->
      shape_id
    end)
  end

  defp context_shape_variant(shape_id, rows) do
    base = %{source: :imported_shape, shape_id: shape_id}

    cond do
      rows == [] ->
        Map.merge(base, %{
          status: :missing,
          unlocated: [%{ref: shape_id, reason: :shape_points_absent}]
        })

      Enum.all?(rows, &(&1.shape_pt_lat != nil and &1.shape_pt_lon != nil)) ->
        Map.merge(base, %{
          status: :saved,
          coordinates:
            Enum.map(rows, &[Values.to_float(&1.shape_pt_lon), Values.to_float(&1.shape_pt_lat)])
        })

      true ->
        Map.merge(base, %{
          status: :missing,
          unlocated: [%{ref: shape_id, reason: :coordinates_absent}]
        })
    end
  end

  defp load_patterns(route) do
    from(pattern in RoutePattern,
      where:
        pattern.organization_id == ^route.organization_id and
          pattern.gtfs_version_id == ^route.gtfs_version_id and
          pattern.route_id == ^route.route_id,
      order_by: [asc_nulls_last: pattern.route_pattern_sort_order, asc: pattern.route_pattern_id]
    )
    |> Repo.all()
  end

  defp load_visits(_route, []), do: %{}

  defp load_visits(route, patterns) do
    route_pattern_ids = Enum.map(patterns, & &1.route_pattern_id)

    from(occurrence in RoutePatternStop,
      left_join: stop in Stop,
      on:
        stop.stop_id == occurrence.stop_id and stop.organization_id == occurrence.organization_id and
          stop.gtfs_version_id == occurrence.gtfs_version_id,
      where:
        occurrence.organization_id == ^route.organization_id and
          occurrence.gtfs_version_id == ^route.gtfs_version_id and
          occurrence.route_pattern_id in ^route_pattern_ids,
      order_by: [asc: occurrence.route_pattern_id, asc: occurrence.position],
      select: %{
        route_pattern_id: occurrence.route_pattern_id,
        position: occurrence.position,
        stop_id: occurrence.stop_id,
        stop_found: not is_nil(stop.id),
        stop_lat: stop.stop_lat,
        stop_lon: stop.stop_lon
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_pattern_id, &visit/1)
  end

  defp visit(row) do
    base = %{position: row.position, stop_id: row.stop_id}

    cond do
      row.stop_found and row.stop_lat != nil and row.stop_lon != nil ->
        Map.put(base, :coordinates, [Values.to_float(row.stop_lon), Values.to_float(row.stop_lat)])

      row.stop_found ->
        Map.put(base, :unlocated, [%{ref: row.stop_id, reason: :coordinates_absent}])

      true ->
        Map.put(base, :unlocated, [%{ref: row.stop_id, reason: :stop_not_found}])
    end
  end

  defp pattern_map(pattern, visits) do
    %{
      id: pattern.id,
      route_pattern_id: pattern.route_pattern_id,
      direction_id: pattern.direction_id,
      route_pattern_name: pattern.route_pattern_name,
      visits: visits,
      sections: connector_sections(visits)
    }
  end

  defp connector_sections(visits) do
    visits
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from_visit, to_visit] -> connector_section(from_visit, to_visit) end)
  end

  defp connector_section(from_visit, to_visit) do
    base = %{
      source: :stop_pair,
      from_position: from_visit.position,
      to_position: to_visit.position
    }

    case {Map.fetch(from_visit, :coordinates), Map.fetch(to_visit, :coordinates)} do
      {{:ok, from_coordinates}, {:ok, to_coordinates}} ->
        Map.merge(base, %{status: :saved, coordinates: [from_coordinates, to_coordinates]})

      _ ->
        unlocated = Map.get(from_visit, :unlocated, []) ++ Map.get(to_visit, :unlocated, [])

        Map.merge(base, %{
          status:
            if(Enum.any?(unlocated, &(&1.reason == :stop_not_found)),
              do: :unavailable,
              else: :missing
            ),
          unlocated: unlocated
        })
    end
  end

  defp load_shape_variants(route) do
    trips_by_shape = load_trips_by_shape(route)

    points_by_shape = load_shape_points(route, Map.keys(trips_by_shape))

    trips_by_shape
    |> Map.keys()
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.map(fn {shape_id, variant} ->
      shape_variant(
        shape_id,
        variant,
        Map.get(points_by_shape, shape_id, []),
        Map.fetch!(trips_by_shape, shape_id)
      )
    end)
  end

  # One row per distinct imported shape: the route pattern ids its trips carry
  # and how many of its trips sit outside every pattern (`custom` derivation),
  # both counted in the database so a shape repeated by many trips still yields
  # one variant. Only this route's trips are read, so another route's outside
  # trips never land in this route's projection.
  defp load_trips_by_shape(route) do
    from(trip in Trip,
      where:
        trip.organization_id == ^route.organization_id and
          trip.gtfs_version_id == ^route.gtfs_version_id and
          trip.route_id == ^route.route_id and not is_nil(trip.shape_id),
      group_by: trip.shape_id,
      select: %{
        shape_id: trip.shape_id,
        route_pattern_ids: fragment("array_agg(?)", trip.route_pattern_id),
        outside_trip_count: filter(count(trip.id), trip.pattern_derivation_state == "custom")
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.shape_id, &1})
  end

  defp load_shape_points(_route, []), do: %{}

  defp load_shape_points(route, shape_ids) do
    from(shape in Shape,
      where:
        shape.organization_id == ^route.organization_id and
          shape.gtfs_version_id == ^route.gtfs_version_id and
          shape.shape_id in ^shape_ids,
      order_by: [asc: shape.shape_id, asc: shape.shape_pt_sequence]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.shape_id)
  end

  defp shape_variant(shape_id, variant, rows, trips) do
    base = %{
      source: :imported_shape,
      shape_id: shape_id,
      variant: variant,
      label: "Variant #{variant}",
      route_pattern_ids:
        trips.route_pattern_ids
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort(),
      outside_trip_count: trips.outside_trip_count
    }

    cond do
      rows == [] ->
        Map.merge(base, %{
          status: :missing,
          unlocated: [%{ref: shape_id, reason: :shape_points_absent}]
        })

      Enum.all?(rows, &(&1.shape_pt_lat != nil and &1.shape_pt_lon != nil)) ->
        Map.merge(base, %{
          status: :saved,
          coordinates:
            Enum.map(rows, &[Values.to_float(&1.shape_pt_lon), Values.to_float(&1.shape_pt_lat)])
        })

      true ->
        Map.merge(base, %{
          status: :missing,
          unlocated: [%{ref: shape_id, reason: :coordinates_absent}]
        })
    end
  end
end
