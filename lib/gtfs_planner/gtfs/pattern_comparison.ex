defmodule GtfsPlanner.Gtfs.PatternComparison do
  @moduledoc """
  Scoped read models for the pattern comparison page (spec 19, `R6`-`R10`).

  `compare/2` composes one two-pattern comparison: the URL route's pattern A, an
  optional pattern B resolved through `RoutePatterns.get_scoped_pattern/3`, the
  calendars and timings each side is compared on, trip usage, the stop alignment
  and the end-to-end running times. Every read filters by `organization_id` and
  `gtfs_version_id` and requires a published route (`INV-1`); the module writes
  nothing (`INV-2`) and takes its running-time values from `Alignment` (`INV-5`).

  - `R8` Defaults. The calendar is the one with the most trips of A and B
    combined, ties keeping `Calendars.list_calendars/2` order; an unknown
    `service` falls back to it. A side's timing is the requested one when it
    belongs to that pattern, otherwise the timing with the most trips on the
    calendar, then the most trips on all calendars, then name ascending. The
    all-calendars count is one trip row per trip, while the calendar count is the
    `Usage` departure count the calendar select shows.
  - `R8` Entry. `defaults/3` opens the route's pattern with the most trips on the
    route's busiest calendar as A and the next by trips in A's direction as B.
    A route without patterns gives `a: nil, b: nil`.
  - `AC-21` Overview. `overview/4` lays one direction's patterns out against the
    busiest one with `Alignment.overview_rows/1`, each pattern carrying its
    trips on the calendar, typicality, service description and visit count.
  - `R9` Scope. A is looked up by the URL route plus its natural ID, so a
    pattern outside the route is `{:error, :not_found}`. B resolves inside the
    organization, version and a published route; a missing, foreign or
    unpublished B yields `b: nil`, `b_error: {:not_found, id}` and no B data.
    `ta`/`tb` are used only when they name one of that side's own timings.
  - `R6` End to end. A side's end-to-end time is its last timing row's arrival
    minus its first row's departure. The change is B minus A with the whole
    percentage of A. All are nil when either side has no chosen timing or B is
    shown in reverse.
  - With `b: nil`, up to three same-direction suggestions of the route are
    returned, ordered by trips on the chosen calendar then stops in common; a
    pattern with an identical stop list is excluded.
  - `AC-22` Map. `map_payload/3` resolves A and B with `Alignments.resolve/1`
    and returns the drawable stops and sections per `R10`: saved geometry
    through its anchors and interior points, everything else as the two-anchor
    connector, sections equal on both sides once as `series: :both` and stops
    with `served`. A `b` outside the scope is treated as absent, so the payload
    carries A alone and never foreign geometry.
  - `AC-20` Picker. `picker_patterns/3` lists every pattern of the version that
    sits on a published route with its route names, direction, service
    description, stop IDs and stop names, and ranks them by stops in common
    with the other side, then trips on the calendar.

  When B is shown in reverse the alignment runs against B's reversed stop list
  and running times are not compared; `opposite?` is then false because it
  describes the patterns rather than the reversed view, which `reversed?` names.
  A stop in `stops_by_id` is a timepoint when either side's chosen timing marks
  it as one (`TimedPatternStop.timepoint == 1`). `stops` on a side is its
  ordered stop IDs; stop names, codes and coordinates live in `stops_by_id`.

  Assumed ceilings: stop visits are bounded as `Alignment` documents, the
  suggestion scan reads this route's patterns only, and the picker reads one
  version's patterns and stops (about 200 × 40) in memory.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.PatternComparison.Alignment
  alias GtfsPlanner.Gtfs.PatternComparison.Usage
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @suggestion_limit 3

  @typedoc "The scoped published organization and version every read is limited to."
  @type scope :: %{organization_id: Ecto.UUID.t(), gtfs_version_id: Ecto.UUID.t()}

  @typedoc "One pattern's column facts in the stop-by-pattern overview (AC-21)."
  @type overview_pattern :: %{
          route_pattern_id: String.t(),
          name: String.t() | nil,
          typicality: String.t(),
          service_description: String.t() | nil,
          stop_count: non_neg_integer(),
          trips: non_neg_integer()
        }

  @typedoc "The stop-by-pattern overview of one route direction (AC-21)."
  @type overview :: %{
          route: Route.t(),
          service_id: String.t() | nil,
          calendars: [Usage.calendar_usage()],
          patterns: [overview_pattern()],
          rows: [%{stop_id: String.t(), served: %{String.t() => pos_integer()}}],
          spans: %{String.t() => {non_neg_integer(), non_neg_integer()}},
          stops_by_id: %{String.t() => map()}
        }

  @doc """
  Composes the comparison of `a` and `b` on the URL route (spec §4, `R6`-`R9`).

  A missing route or A is `{:error, :not_found}`. A `b` that does not resolve
  inside the organization, the version and a published route is reported as
  `b_error: {:not_found, id}` with `b`, `alignment` and every B read as nil.
  """
  @spec compare(scope(), map()) :: {:ok, map()} | {:error, :not_found}
  def compare(scope, params) do
    with {:ok, route} <-
           RoutePatterns.published_route(
             scope.organization_id,
             scope.gtfs_version_id,
             Map.get(params, :route_id)
           ),
         {:ok, a} <- route_pattern(scope, route.route_id, Map.get(params, :a)) do
      {b, b_route, b_error} = resolve_b(scope, Map.get(params, :b))
      candidates = if is_nil(b), do: suggestion_candidates(scope, route, a), else: []

      calendars = Usage.calendars(scope, [a.route_pattern_id | pattern_ids(b)])

      service_id =
        resolve_calendar(calendars, Map.get(params, :service), [
          a.route_pattern_id | pattern_ids(b)
        ])

      base_patterns = [a | List.wrap(b)]

      # Visits, timings, trips and usage all key on the GTFS route_pattern_id,
      # which is unique within the scope's organization and version.
      stops_by_pattern =
        pattern_stops(scope, Enum.map(base_patterns ++ candidates, & &1.route_pattern_id))

      timings_by_pattern = pattern_timings(scope, Enum.map(base_patterns, & &1.route_pattern_id))
      all_counts = timing_trip_counts(scope, base_patterns)
      usage = Usage.usage(scope, base_patterns ++ candidates, service_id)

      a_side =
        side(
          a,
          route,
          stops_by_pattern,
          timings_by_pattern,
          all_counts,
          usage,
          Map.get(params, :ta)
        )

      b_side =
        b &&
          side(
            b,
            b_route,
            stops_by_pattern,
            timings_by_pattern,
            all_counts,
            usage,
            Map.get(params, :tb)
          )

      reversed? = Map.get(params, :reverse) == true

      suggestions =
        if is_nil(b_side),
          do: suggestions(candidates, a_side.stops, stops_by_pattern, usage),
          else: []

      {:ok,
       %{
         route: route,
         a: a_side,
         b: b_side,
         b_error: b_error,
         calendars: calendars,
         service_id: service_id,
         alignment: b_side && alignment(a_side, b_side, reversed?),
         stops_by_id:
           stops_by_id(
             scope,
             a_side.stops ++ side_stops(b_side),
             timepoint_ids([a_side.rows | b_rows(b_side)])
           ),
         suggestions: suggestions
       }}
    end
  end

  @doc """
  Resolves the entry defaults for a route (R8, AC-15).

  The route's pattern with the most trips on the route's busiest calendar is A,
  and B is the next by trips in A's direction; a route with a single pattern in
  that direction gives `b: nil`. The busiest calendar is the one with the most
  trips of the route's patterns combined, ties keeping
  `Calendars.list_calendars/2` order. `:service` names another calendar to count
  on; an unknown one falls back to the busiest, as an unknown `service` does in
  `compare/2`. A route without patterns gives `a: nil, b: nil`.

  A route outside the organization and version, or on an unpublished version,
  is `{:error, :not_found}`.
  """
  @spec defaults(scope(), String.t(), keyword()) ::
          {:ok, %{a: String.t() | nil, b: String.t() | nil}} | {:error, :not_found}
  def defaults(scope, route_id, opts) do
    with {:ok, route} <-
           RoutePatterns.published_route(scope.organization_id, scope.gtfs_version_id, route_id) do
      patterns = route_patterns(scope, route.route_id)
      pattern_ids = Enum.map(patterns, & &1.route_pattern_id)
      calendars = Usage.calendars(scope, pattern_ids)
      service_id = resolve_calendar(calendars, Keyword.get(opts, :service), pattern_ids)
      usage = Usage.usage(scope, patterns, service_id)
      ordered = by_trips(patterns, usage)

      a = List.first(ordered)
      b = a && Enum.find(Enum.drop(ordered, 1), &(&1.direction_id == a.direction_id))

      {:ok, %{a: a && a.route_pattern_id, b: b && b.route_pattern_id}}
    end
  end

  @doc """
  Returns the stop-by-pattern overview of one route direction (AC-21).

  Every pattern of the direction is returned busiest first on the calendar
  (ties keep sort order, then natural ID) with its name, typicality label,
  service description, visit count and trips, plus `Alignment.overview_rows/1`'s
  aligned `rows` and `spans` (one row per visit, repeated visits kept).
  `service_id` selects the calendar; an absent or unknown one uses the
  direction's busiest calendar. `stops_by_id` carries each served stop's name,
  code and coordinates, with `timepoint?` true when any timing of the
  direction's patterns marks it as one.

  A route outside the organization and version, or on an unpublished version,
  is `{:error, :not_found}`.
  """
  @spec overview(scope(), String.t(), 0 | 1, String.t() | nil) ::
          {:ok, overview()} | {:error, :not_found}
  def overview(scope, route_id, direction_id, service_id) do
    with {:ok, route} <-
           RoutePatterns.published_route(scope.organization_id, scope.gtfs_version_id, route_id) do
      patterns = route_patterns(scope, route.route_id, direction_id)
      pattern_ids = Enum.map(patterns, & &1.route_pattern_id)
      calendars = Usage.calendars(scope, pattern_ids)
      service_id = resolve_calendar(calendars, service_id, pattern_ids)
      usage = Usage.usage(scope, patterns, service_id)
      stops_by_pattern = pattern_stops(scope, Enum.map(patterns, & &1.route_pattern_id))
      ordered = by_trips(patterns, usage)

      alignment =
        Alignment.overview_rows(
          Enum.map(ordered, &{&1.route_pattern_id, pattern_stop_ids(&1, stops_by_pattern)})
        )

      {:ok,
       %{
         route: route,
         service_id: service_id,
         calendars: calendars,
         patterns: Enum.map(ordered, &overview_pattern(&1, usage, stops_by_pattern)),
         rows: alignment.rows,
         spans: alignment.spans,
         stops_by_id:
           stops_by_id(
             scope,
             Enum.flat_map(ordered, &pattern_stop_ids(&1, stops_by_pattern)),
             direction_timepoints(scope, Enum.map(ordered, & &1.route_pattern_id))
           )
       }}
    end
  end

  @typedoc "One drawable stop of the comparison map (AC-22), `[lon, lat]` as the Leaflet boundary reads it."
  @type map_stop :: %{
          stop_id: String.t(),
          name: String.t(),
          coordinates: [float()],
          served: :a | :b | :both
        }

  @typedoc "One drawable section of the comparison map (R10)."
  @type map_section :: %{
          from_stop_id: String.t(),
          to_stop_id: String.t(),
          series: :a | :b | :both,
          style: :path | :connector,
          points: [[float()]]
        }

  @typedoc "One pattern's first and last visited stop, for the map's end chips (step 20)."
  @type map_end :: %{first_stop_id: String.t() | nil, last_stop_id: String.t() | nil}

  @typedoc "The comparison map payload; the LiveView fills `pins` from the differences (step 21)."
  @type map_payload :: %{
          stops: [map_stop()],
          sections: [map_section()],
          ends: %{a: map_end(), b: map_end() | nil},
          pins: list()
        }

  @typedoc "One row of the pattern picker (AC-20)."
  @type picker_entry :: %{
          route_pattern_id: String.t(),
          name: String.t() | nil,
          route_id: String.t(),
          route_short_name: String.t() | nil,
          route_long_name: String.t() | nil,
          direction_id: integer() | nil,
          service_description: String.t() | nil,
          stop_ids: [String.t()],
          stop_names: %{String.t() => String.t() | nil},
          shared: non_neg_integer(),
          trips: non_neg_integer()
        }

  @doc """
  Builds the map payload for the two compared patterns (AC-22, `R10`).

  Each side is resolved with `Alignments.resolve/1`. A saved section
  (`:override` or `:shared`) is drawn as a path through its two visit anchors
  and its stored interior points; every other kind falls back to the straight
  dashed `:connector` between the two visits, and a section with an unlocated
  visit at either end is omitted because it cannot reach two points. Sections
  whose `{from_stop_id, to_stop_id, style, points}` are equal on both sides are
  emitted once as `series: :both`, so a shared stretch is drawn once; the rest
  keep `:a` or `:b`. `stops` carries every stop either side serves with
  `served: :a | :b | :both` and its coordinates; an unlocated stop is left out
  because it cannot be a marker. Coordinates are JSON numbers in `[lon, lat]`
  order, as `route_details_map.js` reads them. `ends` names each pattern's first
  and last visited stop for the hook's end chips, and `pins` stays empty: the
  LiveView fills it from the differences (step 21).

  `a` is the URL route's A, which `compare/2` has already bound to the route; it
  must resolve inside the organization, the version and a published route
  (`RoutePatterns.get_scoped_pattern/3`), otherwise the result is
  `{:error, :not_found}`. A `b` that does not resolve there (missing, foreign or
  unpublished) is treated as absent, so the payload carries A alone and never
  another tenant's or version's geometry (`R9`).
  """
  @spec map_payload(scope(), String.t(), String.t() | nil) ::
          {:ok, map_payload()} | {:error, :not_found}
  def map_payload(scope, a, b) do
    with {:ok, a_pattern} <- scoped_pattern(scope, a) do
      {:ok, build_map_payload(Alignments.resolve(a_pattern), resolve_map_b(scope, b))}
    end
  end

  @doc """
  Lists every pattern of the version on a published route, for the picker (AC-20).

  Each entry carries the pattern's own facts (natural ID, name, direction, the
  service description it was imported with, its ordered stop IDs with their stop
  names) and its route's short and long names, so the LiveView can group this
  route by direction, then "Other routes", and search names and served stops in
  memory. `shared` is the size of the `MapSet` intersection of stop IDs with
  `other`, the pattern on the other side of the comparison; it is 0 when `other`
  is nil or is not one of the version's published patterns, so a foreign or
  unpublished ID shares nothing and leaks nothing. `trips` is the pattern's
  departures on the `service_id` calendar under `R7`: one count per trip, a
  frequency trip as its expanded departures only, and 0 when no calendar is
  selected.

  Entries are ordered by stops in common descending, then trips descending, then
  the deterministic read order (route ID, direction, sort order, natural ID), so
  the picker shows the order the prototype ranks and needs no second sort. A
  foreign or unpublished scope has no patterns: `{:ok, []}`.

  Ceiling: one query joins the version's patterns, routes, occurrences and stops
  (about 200 patterns × 40 stops, so about 8,000 rows), plus one grouped count
  row per pattern for the calendar's trips without frequency rows and one row per
  frequency row of the trips that repeat. When a version grows past that, search
  stops on the server and return matches with a per-pattern count instead of the
  whole list (PM-6); the in-memory filter is the current upgrade path.
  """
  @spec picker_patterns(scope(), String.t() | nil, String.t()) :: {:ok, [picker_entry()]}
  def picker_patterns(scope, other, service_id) do
    rows = picker_rows(scope)
    groups = Enum.chunk_by(rows, & &1.pattern.id)
    patterns = Enum.map(groups, fn [row | _] -> row.pattern end)
    trips = picker_trip_counts(scope, patterns, service_id)
    other_stops = picker_other_stops(rows, other)

    entries =
      groups
      |> Enum.map(&picker_entry(&1, trips, other_stops))
      |> Enum.sort_by(&{-&1.shared, -&1.trips})

    {:ok, entries}
  end

  defp scoped_pattern(scope, route_pattern_id) do
    RoutePatterns.get_scoped_pattern(
      scope.organization_id,
      scope.gtfs_version_id,
      route_pattern_id
    )
  end

  # B is drawn only when it resolves inside the scope and on a published route,
  # exactly as compare/2 resolves it; anything else stays absent (R9).
  defp resolve_map_b(_scope, nil), do: nil

  defp resolve_map_b(scope, route_pattern_id) do
    case scoped_pattern(scope, route_pattern_id) do
      {:ok, pattern} -> Alignments.resolve(pattern)
      {:error, :not_found} -> nil
    end
  end

  defp build_map_payload(a_resolved, b_resolved) do
    {b_visits, b_sections} =
      case b_resolved do
        nil -> {[], []}
        %{visits: visits, sections: sections} -> {visits, sections}
      end

    %{
      stops: map_stops(a_resolved.visits, b_visits),
      sections:
        merge_series(
          map_sections(a_resolved.visits, a_resolved.sections),
          map_sections(b_visits, b_sections)
        ),
      ends: %{a: pattern_ends(a_resolved.visits), b: b_resolved && pattern_ends(b_visits)},
      pins: []
    }
  end

  # Saved geometry is drawn through its two anchors and its interior points, as
  # the alignment editor draws it; a missing or blocked section is the straight
  # connector between the anchors, and a section with an unlocated anchor is
  # dropped because it cannot reach two points (R10).
  defp map_sections(visits, sections) do
    anchors = Map.new(visits, &{&1.position, &1})

    Enum.flat_map(sections, fn section ->
      from = Map.get(anchors, section.position)
      to = Map.get(anchors, section.position + 1)

      case {coordinate(from), coordinate(to)} do
        {{:ok, from_coordinates}, {:ok, to_coordinates}} ->
          [map_section(section, from_coordinates, to_coordinates)]

        _unlocated ->
          []
      end
    end)
  end

  defp map_section(section, from_coordinates, to_coordinates) do
    base = %{from_stop_id: section.from_stop_id, to_stop_id: section.to_stop_id}

    if section.kind in [:override, :shared] do
      Map.merge(base, %{
        style: :path,
        points: [from_coordinates | section.points] ++ [to_coordinates]
      })
    else
      Map.merge(base, %{style: :connector, points: [from_coordinates, to_coordinates]})
    end
  end

  # A section that is identical on both sides is one shared line (Leaflet cannot
  # offset lines): the first traversal carries it as :both, and a later traversal
  # of the same identity is already drawn. Every other section keeps its side,
  # and B's own sections follow A's in B's order (R10).
  defp merge_series(a_sections, b_sections) do
    shared =
      MapSet.intersection(
        MapSet.new(a_sections, &section_identity/1),
        MapSet.new(b_sections, &section_identity/1)
      )

    {a_series, _emitted} =
      Enum.map_reduce(a_sections, shared, fn section, remaining ->
        identity = section_identity(section)

        cond do
          MapSet.member?(remaining, identity) ->
            {Map.put(section, :series, :both), MapSet.delete(remaining, identity)}

          MapSet.member?(shared, identity) ->
            {nil, remaining}

          true ->
            {Map.put(section, :series, :a), remaining}
        end
      end)

    b_series =
      for section <- b_sections,
          not MapSet.member?(shared, section_identity(section)) do
        Map.put(section, :series, :b)
      end

    Enum.reject(a_series, &is_nil/1) ++ b_series
  end

  defp section_identity(section) do
    {section.from_stop_id, section.to_stop_id, section.style, section.points}
  end

  defp map_stops(a_visits, b_visits) do
    a_stops = located_stops(a_visits)
    b_stops = located_stops(b_visits)

    (Map.keys(a_stops) ++ Map.keys(b_stops))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn stop_id ->
      a_stop = Map.get(a_stops, stop_id)
      b_stop = Map.get(b_stops, stop_id)

      Map.merge(a_stop || b_stop, %{stop_id: stop_id, served: served(a_stop, b_stop)})
    end)
  end

  defp served(nil, _b_stop), do: :b
  defp served(_a_stop, nil), do: :a
  defp served(_a_stop, _b_stop), do: :both

  # A stop without coordinates cannot be a marker, so it is left out; put_new
  # keeps a loop's repeated visit as one entry per side.
  defp located_stops(visits) do
    Enum.reduce(visits, %{}, fn visit, stops ->
      case coordinate(visit) do
        {:ok, coordinates} ->
          Map.put_new(stops, visit.stop_id, %{name: visit.name, coordinates: coordinates})

        :error ->
          stops
      end
    end)
  end

  defp coordinate(%{lat: lat, lon: lon}) when is_number(lat) and is_number(lon) do
    {:ok, [lon * 1.0, lat * 1.0]}
  end

  defp coordinate(_visit), do: :error

  defp pattern_ends([]), do: %{first_stop_id: nil, last_stop_id: nil}

  defp pattern_ends(visits) do
    %{first_stop_id: hd(visits).stop_id, last_stop_id: List.last(visits).stop_id}
  end

  # One query reads the version's patterns with their routes, occurrences and
  # stops, so the picker never reads per pattern. The ceiling and the upgrade
  # path are on picker_patterns/3.
  defp picker_rows(scope) do
    from([pattern, _version, route] in picker_pattern_base(scope),
      left_join: occurrence in RoutePatternStop,
      on:
        occurrence.organization_id == pattern.organization_id and
          occurrence.gtfs_version_id == pattern.gtfs_version_id and
          occurrence.route_pattern_id == pattern.route_pattern_id,
      left_join: stop in Stop,
      on:
        stop.organization_id == occurrence.organization_id and
          stop.gtfs_version_id == occurrence.gtfs_version_id and
          stop.stop_id == occurrence.stop_id,
      order_by: [
        asc: pattern.route_id,
        asc: pattern.direction_id,
        asc: pattern.route_pattern_sort_order,
        asc: pattern.route_pattern_id,
        asc: pattern.id,
        asc: occurrence.position
      ],
      select: %{
        pattern: pattern,
        route: route,
        stop_id: occurrence.stop_id,
        stop_name: stop.stop_name
      }
    )
    |> Repo.all()
  end

  # The published version's patterns with their routes: the version join is what
  # keeps an unpublished version, another organization or another version out of
  # the picker (R9, INV-1).
  defp picker_pattern_base(scope) do
    from(pattern in RoutePattern,
      join: version in GtfsVersion,
      on:
        version.id == pattern.gtfs_version_id and
          version.organization_id == pattern.organization_id,
      join: route in Route,
      on:
        route.organization_id == pattern.organization_id and
          route.gtfs_version_id == pattern.gtfs_version_id and
          route.route_id == pattern.route_id,
      where:
        pattern.organization_id == ^scope.organization_id and
          pattern.gtfs_version_id == ^scope.gtfs_version_id and
          version.publication_status == "published"
    )
  end

  # The other side's stops come from the same read, so an `other` outside the
  # version's published patterns shares nothing instead of leaking a count.
  defp picker_other_stops(_rows, nil), do: MapSet.new()

  defp picker_other_stops(rows, other) do
    for row <- rows,
        row.pattern.route_pattern_id == other,
        is_binary(row.stop_id),
        into: MapSet.new(),
        do: row.stop_id
  end

  defp picker_entry([first | _] = rows, trips, other_stops) do
    stop_ids = Enum.flat_map(rows, &List.wrap(&1.stop_id))
    pattern = first.pattern

    %{
      route_pattern_id: pattern.route_pattern_id,
      name: pattern.route_pattern_name,
      route_id: first.route.route_id,
      route_short_name: first.route.route_short_name,
      route_long_name: first.route.route_long_name,
      direction_id: pattern.direction_id,
      service_description: pattern.route_pattern_time_desc,
      stop_ids: stop_ids,
      stop_names: Map.new(rows, &{&1.stop_id, &1.stop_name}) |> Map.delete(nil),
      shared: MapSet.intersection(MapSet.new(stop_ids), other_stops) |> MapSet.size(),
      trips: Map.get(trips, pattern.route_pattern_id, 0)
    }
  end

  # A pattern's trips on the calendar under R7, without Usage's departure
  # histogram: the picker ranks the whole version, so it must not scan every
  # trip's stop times. `service_id: nil` counts nothing, as an unresolved
  # calendar leaves Usage empty. Trips without frequency rows are counted by one
  # grouped query; only the trips that have frequency rows are read, with their
  # frequencies, to expand their departures. A pattern with no trips has no key.
  defp picker_trip_counts(_scope, [], _service_id), do: %{}

  defp picker_trip_counts(_scope, _patterns, nil), do: %{}

  defp picker_trip_counts(scope, patterns, service_id) do
    route_pattern_ids = Enum.map(patterns, & &1.route_pattern_id)

    plain = picker_plain_trip_counts(scope, route_pattern_ids, service_id)
    repeating = picker_frequency_trips(scope, route_pattern_ids, service_id)

    Enum.reduce(repeating, plain, fn {route_pattern_id, frequencies}, counts ->
      departures = picker_departures(frequencies)
      Map.update(counts, route_pattern_id, departures, &(&1 + departures))
    end)
  end

  # Each trip without a frequency row is one departure. The frequency lookup is
  # scoped by organization and version as the trip is, so a frequency row of
  # another version with the same trip ID does not turn a trip into a repeating one.
  defp picker_plain_trip_counts(scope, route_pattern_ids, service_id) do
    from(trip in Trip,
      as: :trip,
      where:
        trip.organization_id == ^scope.organization_id and
          trip.gtfs_version_id == ^scope.gtfs_version_id and
          trip.route_pattern_id in ^route_pattern_ids and trip.service_id == ^service_id,
      where:
        not exists(
          from(frequency in Frequency,
            where:
              frequency.organization_id == parent_as(:trip).organization_id and
                frequency.gtfs_version_id == parent_as(:trip).gtfs_version_id and
                frequency.trip_id == parent_as(:trip).trip_id
          )
        ),
      group_by: trip.route_pattern_id,
      select: {trip.route_pattern_id, count(trip.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # One `{route_pattern_id, frequency rows}` per trip that has frequency rows;
  # the inner join reads no other trip.
  defp picker_frequency_trips(scope, route_pattern_ids, service_id) do
    from(trip in Trip,
      join: frequency in Frequency,
      on:
        frequency.organization_id == trip.organization_id and
          frequency.gtfs_version_id == trip.gtfs_version_id and
          frequency.trip_id == trip.trip_id,
      where:
        trip.organization_id == ^scope.organization_id and
          trip.gtfs_version_id == ^scope.gtfs_version_id and
          trip.route_pattern_id in ^route_pattern_ids and trip.service_id == ^service_id,
      order_by: [asc: frequency.start_time],
      select: {trip.route_pattern_id, trip.id, frequency}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {route_pattern_id, trip_id, _frequency} -> {route_pattern_id, trip_id} end,
      fn {_route_pattern_id, _trip_id, frequency} -> frequency end
    )
    |> Enum.map(fn {{route_pattern_id, _trip_id}, frequencies} ->
      {route_pattern_id, frequencies}
    end)
  end

  # R7: a trip with usable frequency windows counts as its expanded departures
  # only, never as its template row; any other trip counts as one departure. The
  # exclusive window end follows Schedules.frequency_windows/1, so the picker
  # shows the count the comparison and the Schedules tab show.
  defp picker_departures(frequencies) do
    case Schedules.frequency_windows(frequencies) do
      [] ->
        1

      windows ->
        Summary.trips_per_hour([], windows)
        |> Enum.sum_by(fn {_hour, count, _approximate?} -> count end)
    end
  end

  defp pattern_ids(nil), do: []
  defp pattern_ids(%RoutePattern{route_pattern_id: id}), do: [id]

  defp side_stops(nil), do: []
  defp side_stops(side), do: side.stops

  defp b_rows(nil), do: []
  defp b_rows(side), do: [side.rows]

  # A must belong to the URL route inside the scope; a pattern of another route
  # or version is :not_found, exactly as a missing one is (R9).
  defp route_pattern(scope, route_id, route_pattern_id) do
    query =
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^scope.organization_id and
            pattern.gtfs_version_id == ^scope.gtfs_version_id and
            pattern.route_id == ^route_id and
            pattern.route_pattern_id == ^route_pattern_id
      )

    case Repo.one(query) do
      %RoutePattern{} = pattern -> {:ok, pattern}
      nil -> {:error, :not_found}
    end
  end

  defp resolve_b(_scope, nil), do: {nil, nil, nil}

  defp resolve_b(scope, route_pattern_id) do
    with {:ok, %RoutePattern{} = pattern} <-
           RoutePatterns.get_scoped_pattern(
             scope.organization_id,
             scope.gtfs_version_id,
             route_pattern_id
           ),
         {:ok, route} <-
           RoutePatterns.published_route(
             scope.organization_id,
             scope.gtfs_version_id,
             pattern.route_id
           ) do
      {pattern, route, nil}
    else
      {:error, :not_found} -> {nil, nil, {:not_found, route_pattern_id}}
    end
  end

  defp suggestion_candidates(scope, route, a) do
    from(pattern in RoutePattern,
      where:
        pattern.organization_id == ^scope.organization_id and
          pattern.gtfs_version_id == ^scope.gtfs_version_id and
          pattern.route_id == ^route.route_id and
          pattern.direction_id == ^a.direction_id and
          pattern.route_pattern_id != ^a.route_pattern_id,
      order_by: [asc: pattern.route_pattern_sort_order, asc: pattern.route_pattern_id]
    )
    |> Repo.all()
  end

  # The chosen calendar is the requested one when it exists, otherwise the
  # calendar with the most trips of the given patterns together; ties keep the
  # calendar list order (R8).
  defp resolve_calendar(calendars, requested, pattern_ids) do
    if Enum.any?(calendars, &(&1.service_id == requested)) do
      requested
    else
      busiest_calendar(calendars, pattern_ids)
    end
  end

  defp busiest_calendar([], _pattern_ids), do: nil

  defp busiest_calendar(calendars, pattern_ids) do
    calendars
    |> Enum.reduce(nil, fn calendar, best ->
      if is_nil(best) or calendar_trips(calendar, pattern_ids) > calendar_trips(best, pattern_ids) do
        calendar
      else
        best
      end
    end)
    |> Map.fetch!(:service_id)
  end

  defp calendar_trips(calendar, pattern_ids) do
    Enum.sum_by(pattern_ids, &Map.get(calendar.trips, &1, 0))
  end

  # One route's patterns in the scope, optionally one direction, in the order
  # `overview/4` and `defaults/3` rank from.
  defp route_patterns(scope, route_id, direction_id \\ nil) do
    query =
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^scope.organization_id and
            pattern.gtfs_version_id == ^scope.gtfs_version_id and
            pattern.route_id == ^route_id,
        order_by: [asc: pattern.route_pattern_sort_order, asc: pattern.route_pattern_id]
      )

    if is_nil(direction_id) do
      Repo.all(query)
    else
      Repo.all(where(query, [pattern], pattern.direction_id == ^direction_id))
    end
  end

  # Busiest first on the chosen calendar; ties keep the query's sort order and
  # then the natural ID, so the overview's column order is deterministic.
  defp by_trips(patterns, usage) do
    Enum.sort_by(patterns, fn pattern ->
      {-usage_total(usage, pattern), pattern.route_pattern_sort_order || 0,
       pattern.route_pattern_id}
    end)
  end

  defp usage_total(usage, pattern) do
    usage |> Map.get(pattern.route_pattern_id, %{}) |> Map.get(:total, 0)
  end

  defp overview_pattern(pattern, usage, stops_by_pattern) do
    %{
      route_pattern_id: pattern.route_pattern_id,
      name: pattern.route_pattern_name,
      typicality: RoutePattern.typicality_label(pattern.route_pattern_typicality),
      service_description: pattern.route_pattern_time_desc,
      stop_count: length(pattern_stop_ids(pattern, stops_by_pattern)),
      trips: usage_total(usage, pattern)
    }
  end

  defp pattern_stop_ids(pattern, stops_by_pattern),
    do: Map.get(stops_by_pattern, pattern.route_pattern_id, [])

  defp side(
         pattern,
         route,
         stops_by_pattern,
         timings_by_pattern,
         all_counts,
         usage,
         requested_timing_id
       ) do
    summary = Map.fetch!(usage, pattern.route_pattern_id)
    timings = Map.get(timings_by_pattern, pattern.route_pattern_id, [])

    timing =
      select_timing(
        timings,
        requested_timing_id,
        summary.by_timing,
        Map.get(all_counts, pattern.route_pattern_id, %{})
      )

    %{
      pattern: pattern,
      route: route,
      stops: Map.get(stops_by_pattern, pattern.route_pattern_id, []),
      timings:
        Enum.map(timings, fn timing ->
          %{id: timing.id, name: timing.name, trips: Map.get(summary.by_timing, timing.id, 0)}
        end),
      timing_id: timing && timing.id,
      rows: timing_rows(pattern, timing),
      usage: summary
    }
  end

  defp timing_rows(_pattern, nil), do: nil

  defp timing_rows(pattern, %TimedPattern{} = timing),
    do: RoutePatterns.timing_rows(pattern, timing.id)

  # A requested timing is used only when it belongs to this pattern; otherwise
  # the default is the most trips on the calendar, then the most trips on all
  # calendars, then name ascending (R8, R9).
  defp select_timing([], _requested, _calendar_trips, _all_trips), do: nil

  defp select_timing(timings, requested, calendar_trips, all_trips) do
    case Enum.find(timings, &(&1.id == requested)) do
      %TimedPattern{} = timing -> timing
      nil -> Enum.min_by(timings, &timing_rank(&1, calendar_trips, all_trips))
    end
  end

  defp timing_rank(timing, calendar_trips, all_trips) do
    {-Map.get(calendar_trips, timing.id, 0), -Map.get(all_trips, timing.id, 0), timing.name,
     timing.id}
  end

  defp alignment(a_side, b_side, reversed?) do
    b_stops = if reversed?, do: Enum.reverse(b_side.stops), else: b_side.stops
    rows = Alignment.align(a_side.stops, b_stops)

    # A reversed B has no comparable times: its timing rows run the other way,
    # so segments, waits and boarding comparisons are dropped (R4).
    a_rows = a_side.rows
    b_rows = if reversed?, do: nil, else: b_side.rows
    segments = Alignment.segments(rows, a_rows, b_rows)

    differences =
      Alignment.differences(rows, %{segments: segments.segments, a_rows: a_rows, b_rows: b_rows})

    {end_a, end_b, end_change, end_percent} = end_to_end(a_side.rows, b_side.rows, reversed?)

    %{
      rows: rows,
      segments: segments.segments,
      untimed: segments.untimed,
      waits: segments.waits,
      differences: differences,
      counts: counts(rows),
      identical?: a_side.stops == b_side.stops,
      opposite?: not reversed? and Alignment.opposite?(a_side.stops, b_side.stops),
      reversed?: reversed?,
      end_a: end_a,
      end_b: end_b,
      end_change: end_change,
      end_percent: end_percent
    }
  end

  defp counts(rows) do
    Enum.reduce(rows, %{shared: 0, a_only: 0, b_only: 0, moved: 0}, fn row, counts ->
      case row do
        %{type: :same} -> %{counts | shared: counts.shared + 1}
        %{type: :a, moved_to: nil} -> %{counts | a_only: counts.a_only + 1}
        %{type: :a} -> %{counts | moved: counts.moved + 1}
        %{type: :b, moved_to: nil} -> %{counts | b_only: counts.b_only + 1}
        %{type: :b} -> counts
      end
    end)
  end

  defp end_to_end(_a_rows, _b_rows, true), do: {nil, nil, nil, nil}

  defp end_to_end(a_rows, b_rows, _reversed?) do
    end_a = end_duration(a_rows)
    end_b = end_duration(b_rows)
    change = if is_integer(end_a) and is_integer(end_b), do: end_b - end_a
    percent = if is_integer(change) and end_a != 0, do: round(change / end_a * 100)

    {end_a, end_b, change, percent}
  end

  defp end_duration(nil), do: nil
  defp end_duration([]), do: nil

  defp end_duration([first | _] = rows) do
    last = List.last(rows)

    if is_integer(first.departure_offset) and is_integer(last.arrival_offset) do
      last.arrival_offset - first.departure_offset
    end
  end

  defp suggestions(candidates, a_stops, pattern_stops, usage) do
    a_stop_ids = MapSet.new(a_stops)

    candidates
    |> Enum.map(&suggestion(&1, a_stops, a_stop_ids, pattern_stops, usage))
    |> Enum.reject(& &1.identical?)
    |> Enum.sort_by(&{-&1.trips, -&1.shared})
    |> Enum.take(@suggestion_limit)
    |> Enum.map(&Map.drop(&1, [:identical?]))
  end

  defp suggestion(pattern, a_stops, a_stop_ids, pattern_stops, usage) do
    stops = Map.get(pattern_stops, pattern.route_pattern_id, [])

    %{
      route_pattern_id: pattern.route_pattern_id,
      name: pattern.route_pattern_name,
      shared: MapSet.intersection(a_stop_ids, MapSet.new(stops)) |> MapSet.size(),
      trips: usage_total(usage, pattern),
      identical?: stops == a_stops
    }
  end

  # One query for both sides' visits keyed by GTFS route_pattern_id, ordered by
  # pattern and position.
  defp pattern_stops(_scope, []), do: %{}

  defp pattern_stops(scope, route_pattern_ids) do
    from(occurrence in RoutePatternStop,
      where:
        occurrence.organization_id == ^scope.organization_id and
          occurrence.gtfs_version_id == ^scope.gtfs_version_id and
          occurrence.route_pattern_id in ^Enum.uniq(route_pattern_ids),
      order_by: [asc: occurrence.route_pattern_id, asc: occurrence.position],
      select: {occurrence.route_pattern_id, occurrence.stop_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # One query for every side's named timings, keyed by GTFS route_pattern_id.
  defp pattern_timings(_scope, []), do: %{}

  defp pattern_timings(scope, route_pattern_ids) do
    from(timing in TimedPattern,
      where:
        timing.organization_id == ^scope.organization_id and
          timing.gtfs_version_id == ^scope.gtfs_version_id and
          timing.route_pattern_id in ^Enum.uniq(route_pattern_ids),
      order_by: [asc: timing.route_pattern_id, asc: timing.name, asc: timing.id]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_pattern_id)
  end

  # One query for every side's trips per timing on all calendars, used only for
  # the default-timing tie-break; the selected calendar's counts come from Usage.
  defp timing_trip_counts(scope, patterns) do
    pattern_ids = Enum.map(patterns, & &1.route_pattern_id)

    from(trip in Trip,
      where:
        trip.organization_id == ^scope.organization_id and
          trip.gtfs_version_id == ^scope.gtfs_version_id and
          trip.route_pattern_id in ^pattern_ids,
      group_by: [trip.route_pattern_id, trip.timed_pattern_id],
      select: {trip.route_pattern_id, trip.timed_pattern_id, count(trip.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {pattern_id, timing_id, count}, counts ->
      Map.update(counts, pattern_id, %{timing_id => count}, &Map.put(&1, timing_id, count))
    end)
  end

  # A stop in the overview is a timepoint when any timing of the direction's
  # patterns marks it as one; there is no timepoint column on the visits.
  defp direction_timepoints(_scope, []), do: MapSet.new()

  defp direction_timepoints(scope, route_pattern_ids) do
    from(row in TimedPatternStop,
      join: timing in TimedPattern,
      on: timing.id == row.timed_pattern_id,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where:
        row.timepoint == 1 and timing.organization_id == ^scope.organization_id and
          timing.gtfs_version_id == ^scope.gtfs_version_id and
          timing.route_pattern_id in ^route_pattern_ids and
          occurrence.organization_id == ^scope.organization_id and
          occurrence.gtfs_version_id == ^scope.gtfs_version_id,
      distinct: true,
      select: occurrence.stop_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The card's stop projection: names, codes and coordinates only, in one query.
  # `timepoint?` is decided by the caller's timing rows (compare) or timing
  # marks (overview), not by the stop row.
  defp stops_by_id(scope, stop_ids, timepoints) do
    stop_ids = stop_ids |> Enum.uniq() |> Enum.sort()

    if stop_ids == [] do
      %{}
    else
      from(stop in Stop,
        where:
          stop.organization_id == ^scope.organization_id and
            stop.gtfs_version_id == ^scope.gtfs_version_id and stop.stop_id in ^stop_ids,
        select: %{
          stop_id: stop.stop_id,
          stop_name: stop.stop_name,
          stop_code: stop.stop_code,
          stop_lat: stop.stop_lat,
          stop_lon: stop.stop_lon
        }
      )
      |> Repo.all()
      |> Map.new(fn stop ->
        {stop.stop_id, Map.put(stop, :timepoint?, MapSet.member?(timepoints, stop.stop_id))}
      end)
    end
  end

  defp timepoint_ids(row_lists) do
    for rows <- row_lists,
        is_list(rows),
        row <- rows,
        row.timepoint == 1,
        into: MapSet.new(),
        do: row.stop_id
  end
end
