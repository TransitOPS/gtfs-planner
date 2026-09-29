defmodule GtfsPlanner.Gtfs.Flex.Geometry do
  @moduledoc """
  Valid, bounded flex-area geometry and its GeoJSON output (R8).

  `flex_areas.geom` is deliberately not an Ecto field, so every geometry value
  crosses this module as a GeoJSON map. This is the only module that issues
  geometry SQL (R8, CR-1): other modules pass a GeoJSON map in and get one back.

  `normalize/1` decodes a GeoJSON binary (or takes an already decoded map),
  accepts a `Feature`, a one-feature `FeatureCollection`, a `Polygon` or a
  `MultiPolygon`, rejects every other shape, rejects more than 5,000 positions,
  answers `:swapped_coordinates` when a `[lat, lon]` pair would be fixed by
  swapping, and returns PostGIS's own verdict for an invalid ring. A valid shape
  comes back as a valid `MultiPolygon` through the R8 output transform
  (`ST_ForcePolygonCCW(ST_ReducePrecision(g, 0.000001))` and then
  `ST_AsGeoJSON`); `ST_AsGeoJSON` never receives a precision argument, because
  rounding there made a real Census boundary invalid.

  `simplify/2` simplifies in the geometry's best metric SRID with a tolerance in
  metres and returns the R8 output of the result, so it also serves a ring that
  `normalize/1` rejected as too large. `export_geojson/1` applies the output
  transform to geometry that is already stored or derived.

  `stats/3` measures a draft area against one version (km², the stops inside and
  the routes serving them), `overlaps/4` measures its intersection with other
  active area services, and `compare/2` reports the change against a saved area.

  `route_buffer/4` derives a route-distance area from the version's current
  shapes (AC-11) and `detour_zones/3` derives the detour zones of a detour
  service's stretch (AC-21), one per unordered stop pair, from the route's
  active patterns. Both are recomputed from the version on every call and both
  finish through the same R8 validity and emptiness checks as stored geometry.

  `put_geom/2` and `get_geojson/1` are the storage pair. Both run on the
  caller's connection, so a context can write geometry inside its own
  transaction.
  """

  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  @max_vertices 5_000

  # PostGIS's verdict for the shape ($1 is GeoJSON text).
  @validity_sql """
  SELECT valid, reason, ST_X(location), ST_Y(location)
  FROM ST_IsValidDetail(ST_GeomFromGeoJSON($1))
  """

  # R8 output transform for a stored area: always a MultiPolygon.
  @normalize_sql """
  SELECT ST_AsGeoJSON(
           ST_Multi(
             ST_ForcePolygonCCW(ST_ReducePrecision(ST_GeomFromGeoJSON($1), 0.000001))
           )
         )
  """

  # R8 output transform for geometry that is not (re-)stored.
  @export_sql """
  SELECT ST_AsGeoJSON(
           ST_ForcePolygonCCW(ST_ReducePrecision(ST_GeomFromGeoJSON($1), 0.000001))
         )
  """

  # Simplify in the geometry's best metric SRID, then back to 4326. $2 is the
  # tolerance in metres: a tolerance in degrees would depend on latitude and a
  # fixed projected SRID would distort. ST_SimplifyPreserveTopology never returns
  # an invalid shape, so the output transform is safe in the same query.
  @simplify_sql """
  SELECT valid,
         reason,
         ST_X(location),
         ST_Y(location),
         ST_AsGeoJSON(
           ST_ForcePolygonCCW(ST_ReducePrecision(simplified.geometry, 0.000001))
         )
  FROM (
         SELECT ST_Transform(
                  ST_SimplifyPreserveTopology(ST_Transform(g, _ST_BestSRID(g)), $2),
                  4326
                ) AS geometry
         FROM (SELECT ST_GeomFromGeoJSON($1) AS g) AS source
       ) AS simplified,
       LATERAL ST_IsValidDetail(simplified.geometry)
  """

  # A stop's coordinates are `numeric`; a point on the boundary counts as
  # covered (`ST_Covers`, not `ST_Contains`), which is what AC-14 means by
  # "stops inside" and what the boundary test pins.
  @stats_sql """
  WITH area AS (
    SELECT ST_GeomFromGeoJSON($3) AS g
  ),
  covered AS (
    SELECT s.stop_id
    FROM stops s, area
    WHERE s.organization_id = $1
      AND s.gtfs_version_id = $2
      AND s.stop_lat IS NOT NULL
      AND s.stop_lon IS NOT NULL
      AND ST_Covers(
            area.g,
            ST_SetSRID(ST_MakePoint(s.stop_lon::float8, s.stop_lat::float8), 4326)
          )
  )
  SELECT ST_Area(area.g::geography) / 1e6,
         ARRAY(SELECT stop_id FROM covered ORDER BY stop_id),
         ARRAY(
           SELECT DISTINCT t.route_id
           FROM stop_times st
           JOIN trips t
             ON t.organization_id = st.organization_id
            AND t.gtfs_version_id = st.gtfs_version_id
            AND t.trip_id = st.trip_id
           WHERE st.organization_id = $1
             AND st.gtfs_version_id = $2
             AND st.stop_id IN (SELECT stop_id FROM covered)
           ORDER BY t.route_id
         )
  FROM area
  """

  # A service's stored areas are unioned before the intersection, so overlapping
  # areas cannot count twice. A touching intersection is a line or point, so the
  # polygonal parts are extracted before the geography cast; an empty result is
  # 0 km². The threshold applies to the service's total intersection and the
  # output order is stable.
  @overlaps_sql """
  WITH draft AS (
    SELECT ST_GeomFromGeoJSON($3) AS g
  ),
  stored AS (
    SELECT a.flex_service_id AS service_id, ST_Union(a.geom) AS geom
    FROM flex_areas a
    WHERE a.organization_id = $1
      AND a.gtfs_version_id = $2
      AND a.geom IS NOT NULL
    GROUP BY a.flex_service_id
  ),
  overlap AS (
    SELECT s.id AS service_id,
           s.name AS name,
           ST_Area(
             ST_CollectionExtract(ST_Intersection(stored.geom, draft.g), 3)::geography
           ) / 1e6 AS km2
    FROM stored
    JOIN flex_services s
      ON s.id = stored.service_id
     AND s.organization_id = $1
     AND s.gtfs_version_id = $2
    CROSS JOIN draft
    WHERE s.active
      AND s.kind = 'area'
      AND ($4::uuid IS NULL OR s.id <> $4::uuid)
      AND ST_Intersects(stored.geom, draft.g)
  )
  SELECT service_id::text, name, km2
  FROM overlap
  WHERE km2 >= 0.5
  ORDER BY name, service_id
  """

  # The one-side area for `compare/2` when a caller passes geometry but no
  # measured km².
  @area_sql """
  SELECT ST_Area(ST_GeomFromGeoJSON($1)::geography) / 1e6
  """

  # Route-distance derivation (R8, AC-11) for `route_buffer/4`. $1 organization,
  # $2 version, $3 requested route IDs, $4 distance in metres. A shape is the
  # points of one `shape_id` in `shape_pt_sequence` order, and only the shapes of
  # trips on the requested routes count. `ST_Buffer(geography, m)` keeps the
  # buffer metric and is available in PostGIS 3.5. A shape with fewer than two
  # points cannot make a line, and no shape at all leaves the union NULL.
  @route_buffer_cte """
  WITH
  requested AS (
    SELECT DISTINCT unnest($3::text[]) AS route_id
  ),
  known AS (
    SELECT r.route_id
    FROM routes r
    WHERE r.organization_id = $1
      AND r.gtfs_version_id = $2
      AND r.route_id IN (SELECT route_id FROM requested)
  ),
  shape_ids AS (
    SELECT DISTINCT t.shape_id
    FROM trips t
    WHERE t.organization_id = $1
      AND t.gtfs_version_id = $2
      AND t.route_id IN (SELECT route_id FROM requested)
      AND t.shape_id IS NOT NULL
  ),
  shape_lines AS (
    SELECT ST_MakeLine(
             ST_SetSRID(ST_MakePoint(s.shape_pt_lon::float8, s.shape_pt_lat::float8), 4326)
             ORDER BY s.shape_pt_sequence
           ) AS line
    FROM shapes s
    WHERE s.organization_id = $1
      AND s.gtfs_version_id = $2
      AND s.shape_id IN (SELECT shape_id FROM shape_ids)
    GROUP BY s.shape_id
    HAVING count(*) >= 2
  ),
  unioned AS (
    SELECT ST_Union(ST_Buffer(line::geography, $4)::geometry) AS geom
    FROM shape_lines
  )
  """

  # The route-distance checks. `coalesce(..., true)` makes an empty union and a
  # union of NULLs (a nil distance) the same `:empty` answer. Validity is read in
  # its own statement: ST_ReducePrecision raises on an invalid shape instead of
  # returning it, so it must never see one.
  @route_buffer_check_sql """
  #{@route_buffer_cte}
  SELECT
    (SELECT coalesce(array_agg(route_id ORDER BY route_id), '{}')
     FROM requested
     WHERE route_id NOT IN (SELECT route_id FROM known)),
    coalesce(ST_IsEmpty(unioned.geom), true),
    detail.valid,
    detail.reason,
    ST_X(detail.location),
    ST_Y(detail.location)
  FROM unioned
  LEFT JOIN LATERAL ST_IsValidDetail(unioned.geom) detail ON true
  """

  @route_buffer_geojson_sql """
  #{@route_buffer_cte}
  SELECT ST_AsGeoJSON(
           ST_Multi(ST_ForcePolygonCCW(ST_ReducePrecision(unioned.geom, 0.000001)))
         )
  FROM unioned
  """

  # Detour-zone derivation (R13, AC-21) for `detour_zones/3`. $1 organization,
  # $2 version, $3 route ID, $4 first stop ID, $5 last stop ID, $6 distance in
  # metres, $7 `'route'` or `'stops'`.
  #
  # `bounds` locates the named stops on each active pattern of the route. The
  # stretch runs between their first occurrences in whichever order the pattern
  # visits them; a pattern that visits only one of them (a short turn) runs from
  # that stop to the pattern's end, or from the pattern's start to it. A pattern
  # with neither stop contributes nothing.
  #
  # `walk` resolves each stretch stop's fraction along the shape in position
  # order: `shape_dist_traveled / total` when the pattern stop and the shape both
  # carry distances, otherwise located after the previous stop's fraction, so a
  # stop the shape visits twice cuts the second visit rather than the first. A
  # pattern without a usable shape walks with NULL fractions and falls back to a
  # straight line between the two stop points.
  #
  # `pairs` cuts one segment per consecutive pair, `segments` buffers it, and
  # `zones` unions every pattern's and direction's segments by the unordered pair
  # with the lesser stop ID first, so two patterns, both directions and a short
  # turn sharing a pair produce one zone.
  @detour_zones_cte """
  WITH RECURSIVE
  patterns AS (
    SELECT p.id AS pattern_id, p.shape_id
    FROM route_patterns p
    WHERE p.organization_id = $1
      AND p.gtfs_version_id = $2
      AND p.route_id = $3
      AND p.active
  ),
  visits AS (
    SELECT ps.route_pattern_id, ps.stop_id, ps.position, ps.shape_dist_traveled
    FROM route_pattern_stops ps
    WHERE ps.organization_id = $1
      AND ps.gtfs_version_id = $2
      AND ps.route_pattern_id IN (SELECT pattern_id FROM patterns)
  ),
  bounds AS (
    SELECT route_pattern_id,
           min(position) FILTER (WHERE stop_id = $4) AS first_pos,
           min(position) FILTER (WHERE stop_id = $5) AS last_pos,
           max(position) AS max_pos
    FROM visits
    GROUP BY route_pattern_id
  ),
  stretch AS (
    SELECT v.route_pattern_id, v.stop_id, v.position, v.shape_dist_traveled
    FROM visits v
    JOIN bounds b ON b.route_pattern_id = v.route_pattern_id
    WHERE $4 IS NOT NULL
      AND $5 IS NOT NULL
      AND (b.first_pos IS NOT NULL OR b.last_pos IS NOT NULL)
      AND v.position BETWEEN
            least(coalesce(b.first_pos, b.last_pos), coalesce(b.last_pos, b.first_pos))
            AND greatest(coalesce(b.last_pos, b.max_pos), coalesce(b.first_pos, 1))
  ),
  stop_points AS (
    SELECT s.stop_id,
           ST_SetSRID(ST_MakePoint(s.stop_lon::float8, s.stop_lat::float8), 4326) AS pt
    FROM stops s
    WHERE s.organization_id = $1
      AND s.gtfs_version_id = $2
      AND s.stop_lat IS NOT NULL
      AND s.stop_lon IS NOT NULL
  ),
  shape_lines AS (
    SELECT sh.shape_id,
           ST_MakeLine(
             ST_SetSRID(ST_MakePoint(sh.shape_pt_lon::float8, sh.shape_pt_lat::float8), 4326)
             ORDER BY sh.shape_pt_sequence
           ) AS line,
           max(sh.shape_dist_traveled)::float8 AS total
    FROM shapes sh
    WHERE sh.organization_id = $1
      AND sh.gtfs_version_id = $2
    GROUP BY sh.shape_id
    HAVING count(*) >= 2
  ),
  prepared AS (
    SELECT st.route_pattern_id, st.stop_id, st.position, st.shape_dist_traveled,
           ln.line, ln.total, pt.pt,
           row_number() OVER (PARTITION BY st.route_pattern_id ORDER BY st.position) AS step
    FROM stretch st
    LEFT JOIN patterns p ON p.pattern_id = st.route_pattern_id
    LEFT JOIN shape_lines ln ON ln.shape_id = p.shape_id
    LEFT JOIN stop_points pt ON pt.stop_id = st.stop_id
  ),
  walk AS (
    SELECT p.route_pattern_id, p.step, p.stop_id, p.pt, p.line, p.total,
           CASE
             WHEN p.line IS NULL OR p.pt IS NULL THEN NULL
             WHEN p.shape_dist_traveled IS NOT NULL AND p.total > 0 THEN
               least(greatest(p.shape_dist_traveled::float8 / p.total, 0::float8), 1::float8)
             ELSE least(greatest(ST_LineLocatePoint(p.line, p.pt), 0::float8), 1::float8)
           END AS fraction
    FROM prepared p
    WHERE p.step = 1
    UNION ALL
    SELECT n.route_pattern_id, n.step, n.stop_id, n.pt, n.line, n.total,
           CASE
             WHEN n.line IS NULL OR n.pt IS NULL THEN w.fraction
             WHEN n.shape_dist_traveled IS NOT NULL AND n.total > 0 THEN
               least(greatest(n.shape_dist_traveled::float8 / n.total, 0::float8), 1::float8)
             WHEN w.fraction IS NULL THEN
               least(greatest(ST_LineLocatePoint(n.line, n.pt), 0::float8), 1::float8)
             ELSE least(
                    greatest(
                      w.fraction + ST_LineLocatePoint(
                                     ST_LineSubstring(w.line, least(w.fraction, 0.999999::float8), 1::float8),
                                     n.pt
                                   ) * (1 - least(w.fraction, 0.999999::float8)),
                      0::float8
                    ),
                    1::float8
                  )
           END AS fraction
    FROM walk w
    JOIN prepared n ON n.route_pattern_id = w.route_pattern_id AND n.step = w.step + 1
  ),
  pairs AS (
    SELECT w.route_pattern_id, w.stop_id AS stop_a, w.pt AS pt_a, w.line,
           w.fraction AS f_a,
           lead(w.stop_id) OVER (PARTITION BY w.route_pattern_id ORDER BY w.step) AS stop_b,
           lead(w.pt) OVER (PARTITION BY w.route_pattern_id ORDER BY w.step) AS pt_b,
           lead(w.fraction) OVER (PARTITION BY w.route_pattern_id ORDER BY w.step) AS f_b
    FROM walk w
  ),
  segments AS (
    SELECT stop_a, stop_b,
           CASE
             WHEN $7 = 'stops' THEN
               ST_Union(
                 ST_Buffer(pt_a::geography, $6)::geometry,
                 ST_Buffer(pt_b::geography, $6)::geometry
               )
             WHEN line IS NOT NULL AND f_a IS NOT NULL AND f_b IS NOT NULL AND f_a <> f_b THEN
               ST_Buffer(
                 ST_LineSubstring(line, least(f_a, f_b), greatest(f_a, f_b))::geography,
                 $6
               )::geometry
             ELSE
               ST_Buffer(ST_MakeLine(pt_a, pt_b)::geography, $6)::geometry
           END AS geom
    FROM pairs
    WHERE stop_b IS NOT NULL
      AND pt_a IS NOT NULL
      AND pt_b IS NOT NULL
  ),
  zones AS (
    SELECT least(stop_a, stop_b) AS stop_a,
           greatest(stop_a, stop_b) AS stop_b,
           ST_Union(geom) AS geom
    FROM segments
    GROUP BY least(stop_a, stop_b), greatest(stop_a, stop_b)
  ),
  checks AS (
    SELECT
      EXISTS (
        SELECT 1
        FROM routes r
        WHERE r.organization_id = $1
          AND r.gtfs_version_id = $2
          AND r.route_id = $3
      ) AS route_exists,
      $4 IS NOT NULL
        AND $5 IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM bounds b
          WHERE b.first_pos IS NOT NULL OR b.last_pos IS NOT NULL
        ) AS stretch_on_route
  )
  """

  @detour_zones_check_sql """
  #{@detour_zones_cte}
  SELECT checks.route_exists,
         checks.stretch_on_route,
         zones.stop_a,
         zones.stop_b,
         coalesce(ST_IsEmpty(zones.geom), true),
         detail.valid,
         detail.reason,
         ST_X(detail.location),
         ST_Y(detail.location)
  FROM checks
  LEFT JOIN zones ON true
  LEFT JOIN LATERAL ST_IsValidDetail(zones.geom) detail ON true
  ORDER BY zones.stop_a, zones.stop_b
  """

  @detour_zones_geojson_sql """
  #{@detour_zones_cte}
  SELECT zones.stop_a,
         zones.stop_b,
         ST_AsGeoJSON(
           ST_Multi(ST_ForcePolygonCCW(ST_ReducePrecision(zones.geom, 0.000001)))
         )
  FROM zones
  WHERE NOT coalesce(ST_IsEmpty(zones.geom), true)
  ORDER BY zones.stop_a, zones.stop_b
  """

  @put_geom_sql """
  UPDATE flex_areas
  SET geom = ST_Multi(ST_GeomFromGeoJSON($1))
  WHERE id = $2
  """

  @get_geojson_sql """
  SELECT id::text,
         ST_AsGeoJSON(ST_ForcePolygonCCW(ST_ReducePrecision(geom, 0.000001)))
  FROM flex_areas
  WHERE id = ANY($1) AND geom IS NOT NULL
  """

  @doc """
  Normalises a GeoJSON area to a stored-ready MultiPolygon.

  Returns the normalised geometry and the number of submitted positions, or the
  reason the input cannot be stored: `:unreadable` for a binary that is not
  JSON, `:not_polygon` for anything that is not one closed polygon,
  `:too_many_vertices` above 5,000 positions, `:swapped_coordinates` for a
  `[lat, lon]` input whose swap brings every latitude back inside ±90, or
  `{:invalid, reason, [lon, lat]}` with PostGIS's first problem.
  """
  @spec normalize(map() | binary()) ::
          {:ok, %{geojson: map(), vertices: pos_integer()}}
          | {:error,
             :unreadable
             | :not_polygon
             | :too_many_vertices
             | :swapped_coordinates
             | {:invalid, String.t(), [float()]}}
  def normalize(input) do
    with {:ok, document} <- decode(input),
         {:ok, geometry, positions} <- polygon_geometry(document),
         :ok <- validate_vertex_count(positions),
         :ok <- validate_coordinate_order(positions) do
      storeable_geometry(geometry, positions)
    end
  end

  @doc """
  Applies the R8 output transform to a stored or derived geometry.

  The result carries at most six decimals per coordinate. It is not validated;
  callers pass geometry that `normalize/1` or a derivation already checked.
  """
  @spec export_geojson(map()) :: map()
  def export_geojson(geojson) do
    %Postgrex.Result{rows: [[output]]} = Repo.query!(@export_sql, [Jason.encode!(geojson)])

    Jason.decode!(output)
  end

  @doc """
  Simplifies a geometry with a tolerance in metres and returns the R8 output.

  Runs `ST_SimplifyPreserveTopology` in the geometry's best metric SRID, so holes
  and topology survive. The input may be a ring that `normalize/1` rejected as
  over the vertex cap.
  """
  @spec simplify(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def simplify(geojson, tolerance_m) do
    %Postgrex.Result{rows: [[valid, reason, lon, lat, output]]} =
      Repo.query!(@simplify_sql, [Jason.encode!(geojson), tolerance_m])

    if valid do
      {:ok, Jason.decode!(output)}
    else
      {:error, {:invalid, reason, [lon, lat]}}
    end
  end

  @doc """
  Measures a draft area against one version.

  Returns the area in km², the `stop_id`s of stops with coordinates that the
  area covers (a stop exactly on the boundary counts), and the `route_id`s of
  trips whose stop times visit those stops. Stops, stop times and trips are all
  filtered to this organization and version. Both lists are sorted.
  """
  @spec stats(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: %{
          km2: float(),
          stop_ids: [String.t()],
          route_ids: [String.t()]
        }
  def stats(organization_id, version_id, geojson) do
    %Postgrex.Result{rows: [[km2, stop_ids, route_ids]]} =
      Repo.query!(@stats_sql, [
        Ecto.UUID.dump!(organization_id),
        Ecto.UUID.dump!(version_id),
        Jason.encode!(geojson)
      ])

    %{km2: km2, stop_ids: stop_ids, route_ids: route_ids}
  end

  @doc """
  Lists the other active area services whose stored areas intersect the draft.

  `exclude_service_id` keeps the service being edited out of the list; pass
  `nil` to compare against every active area service. A service appears once,
  with its stored areas unioned first, and only when that intersection is at
  least 0.5 km². Services that are inactive, of `:detour` kind, or without
  stored geometry are left out. The list is ordered by name and id.
  """
  @spec overlaps(Ecto.UUID.t(), Ecto.UUID.t(), map(), Ecto.UUID.t() | nil) :: [
          %{service_id: Ecto.UUID.t(), name: String.t(), km2: float()}
        ]
  def overlaps(organization_id, version_id, geojson, exclude_service_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(@overlaps_sql, [
        Ecto.UUID.dump!(organization_id),
        Ecto.UUID.dump!(version_id),
        Jason.encode!(geojson),
        exclude_service_id && Ecto.UUID.dump!(exclude_service_id)
      ])

    Enum.map(rows, fn [service_id, name, km2] ->
      %{service_id: service_id, name: name, km2: km2}
    end)
  end

  @doc """
  Compares a saved area with the draft.

  Each side is `nil` or a map from `stats/3` (`:km2` and `:stop_ids`); a side
  that carries `:geojson` but no measured `:km2` has its area computed here.
  `nil` is 0 km² with no stops, so comparing a new area reports every stop in
  the draft as joined. A stop that is in both sides, or in neither, is not
  reported.
  """
  @spec compare(map() | nil, map()) :: %{
          km2_before: float(),
          km2_after: float(),
          stops_joined: [String.t()],
          stops_left: [String.t()]
        }
  def compare(saved, draft) do
    before = side_stats(saved)
    after_stats = side_stats(draft)

    %{
      km2_before: before.km2,
      km2_after: after_stats.km2,
      stops_joined: after_stats.stop_ids -- before.stop_ids,
      stops_left: before.stop_ids -- after_stats.stop_ids
    }
  end

  @doc """
  Derives the buffered area around the given routes' current shapes (AC-11).

  Every shape referenced by a trip on those routes is built from its `shapes`
  rows in `shape_pt_sequence` order, buffered on geography by `distance_m`
  metres and unioned. The result is that union through the R8 output transform,
  so it is one valid `MultiPolygon` in SRID 4326: export recomputes it from the
  version rather than trusting a stored draft.

  Answers `{:error, {:missing_routes, ids}}` when a requested route is not in
  the version, before deriving anything, `{:error, :empty}` when the union is
  empty (no route has a shape of at least two points, including a nil
  `distance_m`), and `{:error, {:invalid, reason, [lon, lat]}}` with PostGIS's
  first problem when the union is invalid.
  """
  @spec route_buffer(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()], pos_integer()) ::
          {:ok, map()}
          | {:error, :empty | {:missing_routes, [String.t()]} | {:invalid, String.t(), [float()]}}
  def route_buffer(organization_id, version_id, route_ids, distance_m) do
    params = [
      Ecto.UUID.dump!(organization_id),
      Ecto.UUID.dump!(version_id),
      Enum.uniq(route_ids),
      distance_m
    ]

    %Postgrex.Result{rows: [[missing, empty, valid, reason, lon, lat]]} =
      Repo.query!(@route_buffer_check_sql, params)

    cond do
      missing != [] ->
        {:error, {:missing_routes, missing}}

      empty ->
        {:error, :empty}

      not valid ->
        {:error, {:invalid, reason, [lon, lat]}}

      true ->
        %Postgrex.Result{rows: [[geojson]]} = Repo.query!(@route_buffer_geojson_sql, params)
        {:ok, Jason.decode!(geojson)}
    end
  end

  @doc """
  Derives one detour zone per unordered stop pair of a detour service (R13).

  For every active pattern of the service's route, the stretch between
  `first_stop_id` and `last_stop_id` is taken in whichever order the pattern
  visits them; a pattern that visits only one of them contributes the part it
  covers, so a short turn sharing a pair adds geometry without adding a zone.
  Each consecutive pair of stops contributes its cut shape segment, or a
  straight line between the two stops when the pattern has no shape, buffered by
  `distance_m` metres on geography. `measure: :stops` buffers the two stop
  points instead. Segments are unioned by the unordered pair, so two patterns,
  both directions and a short turn that share a pair produce one zone.

  Returns the zones ordered by stop pair as `%{zone_id: "flex-<key>-<a>-<b>",
  stop_a: —, stop_b: —, geojson: —}` with the lesser stop ID first. A zone
  without geometry is dropped, so `{:error, :empty}` answers a service that has
  no derivable geometry at all, including a nil `distance_m`. Answers
  `{:error, {:missing_routes, [route_id]}}` when the service's route is not in
  the version, `:stretch_not_on_route` when no active pattern visits the named
  stops, and `{:error, {:invalid, reason, [lon, lat]}}` when PostGIS rejects a
  zone.
  """
  @spec detour_zones(Ecto.UUID.t(), Ecto.UUID.t(), FlexService.t()) ::
          {:ok, [%{zone_id: String.t(), stop_a: String.t(), stop_b: String.t(), geojson: map()}]}
          | {:error,
             :empty
             | :stretch_not_on_route
             | {:missing_routes, [String.t()]}
             | {:invalid, String.t(), [float()]}}
  def detour_zones(organization_id, version_id, %FlexService{} = service) do
    params = [
      Ecto.UUID.dump!(organization_id),
      Ecto.UUID.dump!(version_id),
      service.route_id,
      service.first_stop_id,
      service.last_stop_id,
      service.distance_m,
      Atom.to_string(service.measure)
    ]

    %Postgrex.Result{rows: rows} = Repo.query!(@detour_zones_check_sql, params)

    case rows do
      [[false, _stretch_on_route | _rest] | _rows] ->
        {:error, {:missing_routes, [service.route_id]}}

      [[true, false | _rest] | _rows] ->
        {:error, :stretch_not_on_route}

      [[true, true | _rest] | _rows] ->
        detour_zone_list(params, rows, service)
    end
  end

  # Empty zones carry no geography and contribute no location, so they are
  # dropped; a zone that survives the emptiness check but is invalid is the
  # whole derivation's failure, because a caller cannot write it. The GeoJSON
  # output is a second statement so that ST_ReducePrecision never sees geometry
  # PostGIS rejected.
  defp detour_zone_list(params, rows, service) do
    zones =
      for [_route, _stretch, stop_a, stop_b, empty, valid, reason, lon, lat] <- rows,
          stop_a != nil,
          not empty do
        %{stop_a: stop_a, stop_b: stop_b, valid: valid, reason: reason, location: [lon, lat]}
      end

    invalid = Enum.find(zones, &(not &1.valid))

    cond do
      invalid != nil ->
        {:error, {:invalid, invalid.reason, invalid.location}}

      zones == [] ->
        {:error, :empty}

      true ->
        zone_geojson(params, service)
    end
  end

  defp zone_geojson(params, service) do
    %Postgrex.Result{rows: rows} = Repo.query!(@detour_zones_geojson_sql, params)

    zones =
      Enum.map(rows, fn [stop_a, stop_b, geojson] ->
        %{
          zone_id: "flex-#{service.key}-#{stop_a}-#{stop_b}",
          stop_a: stop_a,
          stop_b: stop_b,
          geojson: Jason.decode!(geojson)
        }
      end)

    case zones do
      [] -> {:error, :empty}
      zones -> {:ok, zones}
    end
  end

  defp side_stats(nil), do: %{km2: 0.0, stop_ids: []}

  defp side_stats(side) do
    %{km2: side_km2(side), stop_ids: Map.get(side, :stop_ids, [])}
  end

  defp side_km2(%{km2: km2}) when is_number(km2), do: km2 * 1.0

  defp side_km2(%{geojson: geojson}) do
    %Postgrex.Result{rows: [[km2]]} = Repo.query!(@area_sql, [Jason.encode!(geojson)])
    km2
  end

  defp side_km2(_side), do: 0.0

  @doc """
  Writes one area's geometry, replacing whatever was stored.

  `{:error, :not_found}` means no area with that id exists; the caller is then
  inside its own transaction and can decide what to do about it.
  """
  @spec put_geom(Ecto.UUID.t(), map()) :: :ok | {:error, :not_found}
  def put_geom(area_id, geojson) do
    %Postgrex.Result{num_rows: num_rows} =
      Repo.query!(@put_geom_sql, [Jason.encode!(geojson), Ecto.UUID.dump!(area_id)])

    if num_rows == 1, do: :ok, else: {:error, :not_found}
  end

  @doc """
  Reads stored geometry for the given area ids, keyed by id.

  Areas without geometry (`:route_distance` areas) and unknown ids are absent
  from the result.
  """
  @spec get_geojson([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => map()}
  def get_geojson([]), do: %{}

  def get_geojson(area_ids) when is_list(area_ids) do
    ids = Enum.map(area_ids, &Ecto.UUID.dump!/1)
    %Postgrex.Result{rows: rows} = Repo.query!(@get_geojson_sql, [ids])

    Map.new(rows, fn [id, geojson] -> {id, Jason.decode!(geojson)} end)
  end

  defp decode(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, document} -> {:ok, document}
      {:error, _error} -> {:error, :unreadable}
    end
  end

  defp decode(input), do: {:ok, input}

  defp polygon_geometry(%{"type" => "Feature", "geometry" => geometry}),
    do: polygon_geometry(geometry)

  defp polygon_geometry(%{"type" => "FeatureCollection", "features" => [feature]}),
    do: polygon_geometry(feature)

  defp polygon_geometry(%{"type" => "Polygon", "coordinates" => rings}) when is_list(rings) do
    case rings_positions(rings) do
      {:ok, [_ | _] = positions} ->
        {:ok, %{"type" => "Polygon", "coordinates" => rings}, positions}

      _empty_or_error ->
        {:error, :not_polygon}
    end
  end

  defp polygon_geometry(%{"type" => "MultiPolygon", "coordinates" => polygons})
       when is_list(polygons) do
    case polygons_positions(polygons) do
      {:ok, [_ | _] = positions} ->
        {:ok, %{"type" => "MultiPolygon", "coordinates" => polygons}, positions}

      _empty_or_error ->
        {:error, :not_polygon}
    end
  end

  defp polygon_geometry(_document), do: {:error, :not_polygon}

  defp rings_positions(rings) do
    rings
    |> Enum.reduce_while([], fn ring, acc ->
      case ring_positions(ring) do
        {:ok, positions} -> {:cont, [positions | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> positions_result()
  end

  defp polygons_positions(polygons) do
    polygons
    |> Enum.reduce_while([], fn polygon, acc ->
      case rings_positions(polygon) do
        {:ok, [_ | _] = positions} -> {:cont, [positions | acc]}
        _error -> {:halt, :error}
      end
    end)
    |> positions_result()
  end

  defp positions_result(:error), do: :error

  defp positions_result(groups), do: {:ok, groups |> Enum.reverse() |> Enum.concat()}

  defp ring_positions(ring) when is_list(ring) and ring != [] do
    if Enum.all?(ring, &position?/1), do: {:ok, ring}, else: :error
  end

  defp ring_positions(_ring), do: :error

  defp position?([lon, lat | _rest]) when is_number(lon) and is_number(lat), do: true
  defp position?(_position), do: false

  defp validate_vertex_count(positions) when length(positions) > @max_vertices,
    do: {:error, :too_many_vertices}

  defp validate_vertex_count(_positions), do: :ok

  # GeoJSON lists longitude first. A latitude beyond ±90 in the second slot means
  # the pair is reversed, but only a swap that brings every latitude back inside
  # ±90 (and every longitude inside ±180) is a fix worth offering (AC-13).
  defp validate_coordinate_order(positions) do
    if Enum.any?(positions, &out_of_range_latitude?/1) and
         Enum.all?(positions, &swapable_position?/1) do
      {:error, :swapped_coordinates}
    else
      :ok
    end
  end

  defp out_of_range_latitude?([_lon, lat | _rest]), do: abs(lat) > 90

  defp swapable_position?([lon, lat | _rest]), do: abs(lon) <= 90 and abs(lat) <= 180

  defp storeable_geometry(geometry, positions) do
    encoded = Jason.encode!(geometry)

    # The validity query runs first: ST_ReducePrecision raises on an invalid shape
    # instead of returning it, so it must never see one.
    %Postgrex.Result{rows: [[valid, reason, lon, lat]]} = Repo.query!(@validity_sql, [encoded])

    if valid do
      %Postgrex.Result{rows: [[geojson]]} = Repo.query!(@normalize_sql, [encoded])

      {:ok, %{geojson: Jason.decode!(geojson), vertices: length(positions)}}
    else
      {:error, {:invalid, reason, invalid_location(lon, lat, positions)}}
    end
  end

  # Some problems have no reported location; fall back to the first submitted
  # position so the editor always has a point to mark.
  defp invalid_location(nil, nil, [[lon, lat | _rest] | _positions]), do: [lon, lat]
  defp invalid_location(lon, lat, _positions), do: [lon, lat]
end
