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
  duplicate trip copies never duplicate geometry.

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
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

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
          route_pattern_ids: [String.t()]
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
         patterns: Enum.map(patterns, &pattern_map(&1, Map.fetch!(visits, &1.id))),
         imported_shape_variants: load_shape_variants(route)
       }}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
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
    pattern_ids = Enum.map(patterns, & &1.id)

    from(occurrence in RoutePatternStop,
      left_join: stop in Stop,
      on:
        stop.stop_id == occurrence.stop_id and stop.organization_id == occurrence.organization_id and
          stop.gtfs_version_id == occurrence.gtfs_version_id,
      where:
        occurrence.organization_id == ^route.organization_id and
          occurrence.gtfs_version_id == ^route.gtfs_version_id and
          occurrence.route_pattern_id in ^pattern_ids,
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
        Map.put(base, :coordinates, [number(row.stop_lon), number(row.stop_lat)])

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
    pattern_ids_by_shape =
      from(trip in Trip,
        where:
          trip.organization_id == ^route.organization_id and
            trip.gtfs_version_id == ^route.gtfs_version_id and
            trip.route_id == ^route.route_id and not is_nil(trip.shape_id),
        distinct: true,
        select: {trip.route_pattern_id, trip.shape_id}
      )
      |> Repo.all()
      |> Enum.group_by(fn {_pattern_id, shape_id} -> shape_id end, fn {pattern_id, _} ->
        pattern_id
      end)

    points_by_shape = load_shape_points(route, Map.keys(pattern_ids_by_shape))

    pattern_ids_by_shape
    |> Map.keys()
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.map(fn {shape_id, variant} ->
      shape_variant(
        shape_id,
        variant,
        Map.get(points_by_shape, shape_id, []),
        pattern_ids_by_shape
      )
    end)
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

  defp shape_variant(shape_id, variant, rows, pattern_ids_by_shape) do
    base = %{
      source: :imported_shape,
      shape_id: shape_id,
      variant: variant,
      label: "Variant #{variant}",
      route_pattern_ids:
        pattern_ids_by_shape
        |> Map.fetch!(shape_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
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
          coordinates: Enum.map(rows, &[number(&1.shape_pt_lon), number(&1.shape_pt_lat)])
        })

      true ->
        Map.merge(base, %{
          status: :missing,
          unlocated: [%{ref: shape_id, reason: :coordinates_absent}]
        })
    end
  end

  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value) when is_number(value), do: value
end
