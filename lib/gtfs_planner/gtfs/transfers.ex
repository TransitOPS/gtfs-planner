defmodule GtfsPlanner.Gtfs.Transfers do
  @moduledoc """
  Scoped read of one version's transfer rules and their catalog annotation.

  `load_catalog/3` loads one organization/version scope in a bounded number of
  queries — the version's transfers, the stops and the parents of the stops the
  rules name, the selector routes and trips, and the `stop_time` incidence of
  every coverage leaf of a general rule — and annotates each row in Elixir. The
  query count is independent of the number of rules, because the rows are
  annotated from the loaded references rather than by a query per row.

  A row carries its stored `Transfer`, both endpoints (name, location type,
  platform code, top-level station, child count, selector and resolved route), its
  GTFS specificity rank, the R11 attention reasons, the ids of the general rules it
  competes with (R6, from the real `stop_time` incidence) and the id of its exact
  mirror in the same view (R7). Attention is a list of data terms in a fixed order
  — `{:competes, n}` first, then the from-side reasons in the order stop, route,
  trip, trip-not-on-route, trip-not-at-stop, then the to-side reasons in the same
  order, then `:min_time_missing` — and the components layer owns their text.
  Coverage follows R2: a station covers itself and its direct children with a
  location type of nil or 0, every other stop covers only itself, and a stop that
  is not in the version covers nothing.

  `:general` (the default view) holds types 0–3 and `:in_seat` holds types 4 and
  5; counts cover the whole version. The listing options narrow that view: a stop
  or route filter, a type inside its view's range, `attention: true` in the
  general view, and a case-insensitive search over stop names, IDs, platform
  codes and parent stations, route IDs and names, and trip IDs. The filtered rows
  sort by the from or to endpoint, the transfer type or the minimum time, and one
  page of them is returned with the requested rule selected when it is present.

  Both views are read-only here: in-seat rows carry no attention reasons and no
  competitors. The module's two writes, `create_general/2` and `update_general/4`,
  reach a types 0–3 rule only and never touch a type 4/5 row (R1). The filtered page
  is a display set, never a write or delete scope, and `count_general/3` counts a
  detail page's related rules with the same stop and route predicates this listing
  uses.

  The editor's option queries read the same scope: `search_stops/3` matches a
  case-insensitive substring of the stop name, ID or platform code among the stops
  the editor may pick (`location_type` nil, 0 or 1) and returns 20 options plus
  `truncated?`; `fetch_pickable_stop/3` resolves one picked ID fail-closed;
  `route_options/4` lists the active routes serving a stop's R2 coverage; and
  `trip_options/6` lists the trips of one route that serve that coverage, each with
  the first five characters of its earliest arrival (`:from`) or departure (`:to`).
  A stored selector that is missing, inactive or no longer serving is appended with
  the reason, so an edit never silently drops it. None of these queries writes, and
  every one of them is scoped by organization and version.

  The map reads answer the connection view from the same scope: `map_payload/3`
  resolves the two selected endpoints to float points, the drawable children of a
  station endpoint tagged with their side, and the endpoints that have no
  coordinates; `stops_in_bounds/3` parses and clamps a viewport from the map hook
  and answers at most 200 drawable stops with `truncated?`; and `version_extent/2`
  returns the version's own bounding box, or nil when no stop has coordinates.

  `create_general/2` creates and `update_general/4` changes one general rule in
  this module's own retry loop over the configured `ReviewedApplyTransaction`
  module: the editor changeset's references are checked against the version's stops,
  routes and trips inside the write transaction (R2/R4), one `"transfer"` change log
  is written with the row in the same transaction (R9), and a unique-key failure is
  reported after the rollback as `{:duplicate, %{id, transfer_type} | nil}` (R5).
  Serialization failures and deadlocks retry up to three attempts before `:busy`
  (R8). The update loads its target through an id-scoped types 0–3 query, refuses a
  mismatched, missing or unparseable `expected_updated_at` as `:stale`, and returns
  the row untouched with no audit log when the submitted values change nothing.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers.Overlaps
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @general_types [0, 1, 2, 3]
  @in_seat_types [4, 5]
  @default_per_page 50
  @stop_search_limit 20
  @stop_bounds_limit 200
  @sort_keys [:from, :to, :type, :min_time]
  @write_attempts 3
  @key_fields [
    :from_stop_id,
    :to_stop_id,
    :from_route_id,
    :to_route_id,
    :from_trip_id,
    :to_trip_id
  ]

  @missing_stop_message "Choose a stop or station in this version"
  @invalid_stop_type_message "Choose a stop, platform or station"
  @missing_route_message "Choose a route in this version"
  @missing_trip_message "Choose a trip in this version"
  @trip_not_on_route_message "This trip is on a different route"
  @trip_not_at_stop_message "This trip doesn't stop here"

  @typedoc "A side's effective selector: the trip when set, else the route, else nothing."
  @type selector :: :any | {:route, String.t()} | {:trip, String.t()}

  @typedoc "A resolved side of a rule, with its station context and route."
  @type endpoint :: %{
          stop_id: String.t() | nil,
          name: String.t() | nil,
          location_type: integer() | nil,
          platform_code: String.t() | nil,
          top_level: %{stop_id: String.t(), name: String.t() | nil} | nil,
          child_count: non_neg_integer(),
          selector: selector(),
          route:
            %{
              route_id: String.t(),
              route_short_name: String.t() | nil,
              route_long_name: String.t() | nil
            }
            | nil
        }

  @typedoc "One R11 reason why a general rule needs attention."
  @type attention ::
          {:competes, pos_integer()}
          | :min_time_missing
          | {:missing_stop, :from | :to, String.t()}
          | {:invalid_stop_type, :from | :to, String.t(), integer()}
          | {:missing_route, :from | :to, String.t()}
          | {:missing_trip, :from | :to, String.t()}
          | {:trip_not_on_route, :from | :to, String.t(), String.t()}
          | {:trip_not_at_stop, :from | :to, String.t(), String.t()}

  @typedoc "One annotated catalog row."
  @type row :: %{
          id: Ecto.UUID.t(),
          transfer: Transfer.t(),
          from: endpoint(),
          to: endpoint(),
          rank: 1..6,
          attention: [attention()],
          competitor_ids: [Ecto.UUID.t()],
          reverse_id: Ecto.UUID.t() | nil
        }

  @typedoc "The loaded catalog for one view of one version."
  @type catalog :: %{
          view: :general | :in_seat,
          rows: [row()],
          total_count: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          selected: row() | nil,
          competitors: [row()],
          counts: %{general: non_neg_integer(), in_seat: non_neg_integer()},
          filter_options: %{stops: [map()], routes: [map()], types: [0..5]}
        }

  @typedoc "One selectable stop or station option for the editor."
  @type stop_option :: %{
          stop_id: String.t(),
          stop_name: String.t() | nil,
          location_type: integer() | nil,
          platform_code: String.t() | nil,
          parent_name: String.t() | nil,
          child_count: non_neg_integer(),
          lat: float() | nil,
          lon: float() | nil
        }

  @typedoc "One route option, with the stored route's note when it is not offered."
  @type route_option :: %{
          route_id: String.t(),
          route_short_name: String.t() | nil,
          route_long_name: String.t() | nil,
          note: nil | :not_serving | :inactive | :missing
        }

  @typedoc "One point the connection map can draw: a stop with float coordinates."
  @type map_point :: %{
          stop_id: String.t(),
          name: String.t() | nil,
          lat: float(),
          lon: float(),
          location_type: integer() | nil
        }

  @typedoc "The connection map payload for one pair of selected endpoints."
  @type map_payload :: %{
          a: map_point() | nil,
          b: map_point() | nil,
          children: [map()],
          missing_coordinates: [String.t()]
        }

  @typedoc "One trip option of a route at a stop's coverage for one side."
  @type trip_option :: %{
          trip_id: String.t(),
          time: String.t() | nil,
          headsign: String.t() | nil,
          service_id: String.t() | nil,
          note: nil | :not_serving | :other_route | :missing
        }

  @doc """
  Loads one version's transfer catalog for the requested view and listing options.

  Options are read from a keyword list of typed values; the LiveView canonicalizes
  the URL strings before calling this function. `view` selects `:general` (the
  default, types 0–3) or `:in_seat` (types 4 and 5). `type` is applied only inside
  its view's range, `attention: true` only in the general view, `stop` matches the
  stored stop or any of its children and `route` matches a stored route selector or
  the route of a stored trip; `search` matches a case-insensitive substring of the
  row's stop names, IDs, platform codes and parent station names, route IDs and
  names, and trip IDs. Filters combine with AND.

  Rows are ordered by `sort_by` (`:from` default, `:to`, `:type` or `:min_time`) in
  `sort_dir` (`:asc` default), with ties always by from name, then to name, then id
  ascending; a nil minimum time sorts before any number when ascending. `rows` is
  one page (`per_page` 50 by default) of the filtered list. `page` is the requested
  page clamped to `1..max_page`, unless `rule` names a row in the filtered list,
  which selects that row and its page; `selected` is that row or the page's first
  row. `competitors` are the version's general rows that compete with the selected
  row (R6), in default order, and `filter_options` describes the view's own rows
  plus the requested stop or route when the view has no option for it.

  Every query is scoped by organization and version, so a foreign or mismatched
  pair yields an empty catalog, and the filtered rows are never a write scope.
  """
  @spec load_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: catalog()
  def load_catalog(organization_id, gtfs_version_id, opts \\ []) do
    view = requested_view(opts)
    transfers = load_transfers(organization_id, gtfs_version_id)
    {in_seat, general} = Enum.split_with(transfers, &in_seat?/1)

    stops = load_stop_index(organization_id, gtfs_version_id, transfers)
    trips = load_trip_index(organization_id, gtfs_version_id, transfers)
    routes = load_route_index(organization_id, gtfs_version_id, transfers, trips)
    incidence = load_incidence(organization_id, gtfs_version_id, coverage_leaves(general, stops))

    data = %{stops: stops, trips: trips, routes: routes, incidence: incidence}
    competitor_ids = Overlaps.evaluate(Enum.map(general, &rule(&1, stops)), incidence)

    general_rows = view_rows(general, data, competitor_ids)
    in_seat_rows = view_rows(in_seat, data, competitor_ids)
    all_view_rows = if view == :in_seat, do: in_seat_rows, else: general_rows

    route_id = string_option(opts[:route])
    stop_ids = stop_filter(organization_id, gtfs_version_id, string_option(opts[:stop]))
    trip_routes = trip_route_index(trips)

    filtered =
      all_view_rows
      |> filter_type(opts[:type], view)
      |> filter_attention(opts[:attention], view)
      |> Enum.filter(&matches_filters?(&1.transfer, stop_ids, route_id, trip_routes))
      |> filter_search(string_option(opts[:search]))
      |> sort_rows(requested_sort_by(opts), requested_sort_dir(opts))

    per_page = requested_per_page(opts)

    {page, page_rows, selected} =
      paginate(filtered, opts[:rule], requested_page(opts), per_page)

    %{
      view: view,
      rows: page_rows,
      total_count: length(filtered),
      page: page,
      per_page: per_page,
      selected: selected,
      competitors: competitors(general_rows, selected),
      counts: %{general: length(general), in_seat: length(in_seat)},
      filter_options: filter_options(all_view_rows, view, opts)
    }
  end

  @doc """
  Counts a version's general rules that match a stop or route filter.

  The related-transfer counts on route and stop details use the same stop and route
  predicates as `load_catalog/3` over the general rows only, so the count equals the
  rows listed at the matching filtered URL. Incidence is never loaded and the
  overlap evaluator never runs, because a count needs no competition verdict.
  """
  @spec count_general(Ecto.UUID.t(), Ecto.UUID.t(), [stop: String.t()] | [route: String.t()]) ::
          non_neg_integer()
  def count_general(organization_id, gtfs_version_id, opts) do
    general =
      load_transfers(organization_id, gtfs_version_id)
      |> Enum.reject(&in_seat?/1)

    route_id = string_option(opts[:route])

    trip_routes =
      if route_id do
        general
        |> then(&load_trip_index(organization_id, gtfs_version_id, &1))
        |> trip_route_index()
      else
        %{}
      end

    stop_ids = stop_filter(organization_id, gtfs_version_id, string_option(opts[:stop]))

    general
    |> Enum.filter(&matches_filters?(&1, stop_ids, route_id, trip_routes))
    |> length()
  end

  @doc """
  Searches one version's selectable stops and stations for the editor.

  The query matches a case-insensitive substring of the stop name, the stop ID or
  the platform code, with `%`, `_` and `\` treated literally, and returns only the
  stops the editor may pick: `location_type` nil, 0 or 1 (R2), so a station is an
  option and an entrance is not. At most 20 options come back ordered by name then
  ID, and `truncated?` is true when more stops match; a blank query returns none.
  Every query is scoped by organization and version, so a foreign version's stops
  never appear.
  """
  @spec search_stops(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          %{stops: [stop_option()], truncated?: boolean()}
  def search_stops(organization_id, gtfs_version_id, query) do
    case stop_search_pattern(query) do
      nil ->
        %{stops: [], truncated?: false}

      pattern ->
        {matches, extra} =
          from(s in Stop,
            where:
              s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
            where: is_nil(s.location_type) or s.location_type in [0, 1],
            where:
              ilike(s.stop_name, ^pattern) or ilike(s.stop_id, ^pattern) or
                ilike(s.platform_code, ^pattern),
            order_by: [asc: s.stop_name, asc: s.stop_id],
            limit: @stop_search_limit + 1
          )
          |> Repo.all()
          |> Enum.split(@stop_search_limit)

        %{stops: stop_options(organization_id, gtfs_version_id, matches), truncated?: extra != []}
    end
  end

  @doc """
  Fetches one selectable stop for the editor's pick-on-map flow.

  The same option shape as `search_stops/3`, resolved from a scoped query for the
  requested ID. The lookup is fail-closed: an unknown ID, a stop of another
  organization or version, a non-string payload value and a stop whose
  `location_type` is not nil, 0 or 1 are all `:error`, so a picked ID must resolve
  inside the socket's own version (R2, R10).
  """
  @spec fetch_pickable_stop(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, stop_option()} | :error
  def fetch_pickable_stop(_organization_id, _gtfs_version_id, stop_id)
      when not is_binary(stop_id),
      do: :error

  def fetch_pickable_stop(organization_id, gtfs_version_id, stop_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      where: s.stop_id == ^stop_id,
      where: is_nil(s.location_type) or s.location_type in [0, 1]
    )
    |> Repo.all()
    |> case do
      [stop] -> {:ok, stop_options(organization_id, gtfs_version_id, [stop]) |> hd()}
      [] -> :error
    end
  end

  @doc """
  Lists the active routes that serve a stop's coverage, plus the stored route.

  The coverage is R2's: a station covers itself and its child stops and platforms,
  and any other stop covers only itself. The options are the active routes with a
  `stop_time` at one of those leaves, ordered by short name then ID. When the
  stored route is not among them it is appended with the reason it is missing —
  `:missing` (no such route), `:inactive` (the route is not active) or
  `:not_serving` (active, but it does not serve this stop) — so an edit can still
  show the stored selector. A nil stop has no options.
  """
  @spec route_options(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil, String.t() | nil) ::
          [route_option()]
  def route_options(_organization_id, _gtfs_version_id, nil, _current), do: []

  def route_options(organization_id, gtfs_version_id, stop_id, current) do
    coverage = stop_coverage(organization_id, gtfs_version_id, stop_id)
    route_ids = serving_route_ids(organization_id, gtfs_version_id, coverage)
    options = active_route_options(organization_id, gtfs_version_id, route_ids)

    append_current_route(options, organization_id, gtfs_version_id, current)
  end

  @doc """
  Lists the trips of one route that serve a stop's coverage for one side.

  `:from` reports the earliest arrival and `:to` the earliest departure at any leaf
  of the stop's coverage, as the first five characters of the stored clock, ordered
  by that clock then trip ID. The stored trip is appended with `:missing` (no such
  trip), `:other_route` (it exists on another route) or `:not_serving` (it exists on
  this route but has no `stop_time` in the coverage) when it is not among them, so
  an edit can still show the stored selector. A nil route or nil stop has no
  options.
  """
  @spec trip_options(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t() | nil,
          String.t() | nil,
          :from | :to,
          String.t() | nil
        ) :: [trip_option()]
  def trip_options(_organization_id, _gtfs_version_id, nil, _stop_id, _side, _current), do: []
  def trip_options(_organization_id, _gtfs_version_id, _route_id, nil, _side, _current), do: []

  def trip_options(organization_id, gtfs_version_id, route_id, stop_id, side, current) do
    coverage = stop_coverage(organization_id, gtfs_version_id, stop_id)
    options = trip_option_rows(organization_id, gtfs_version_id, route_id, coverage, side)

    append_current_trip(options, organization_id, gtfs_version_id, route_id, current)
  end

  @doc """
  Builds the connection map payload for one pair of selected endpoints (AC-22).

  `a` is the departure endpoint's point and `b` the arrival endpoint's, each with
  float coordinates, or `nil` when the ID names no stop of this organization and
  version or the stop carries no coordinates. `children` are the direct children
  of a station endpoint that are stops or platforms (`location_type` nil or 0),
  have coordinates and are therefore drawable, each tagged with its endpoint's
  `side` ("a" or "b"); the departure endpoint's children come first. A child is
  listed once, so the same station on both sides does not double it. Entrances,
  generic nodes and children without coordinates are omitted.

  `missing_coordinates` names, once each in endpoint order, the endpoints that are
  in this version but have no coordinates, using the stop name or else the stop ID,
  so the page can explain an absent marker. An unknown or foreign ID contributes no
  entry: only stops this version actually holds are reported.
  """
  @spec map_payload(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: map_payload()
  def map_payload(organization_id, gtfs_version_id, endpoints) do
    from_id = map_stop_id(Map.get(endpoints, :from_stop_id))
    to_id = map_stop_id(Map.get(endpoints, :to_stop_id))

    stops =
      [from_id, to_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> then(&load_stops(organization_id, gtfs_version_id, &1))

    index = Map.new(stops, &{&1.stop_id, &1})

    %{
      a: map_endpoint(index, from_id),
      b: map_endpoint(index, to_id),
      children: map_children(index, from_id, to_id),
      missing_coordinates: missing_coordinates(index, [from_id, to_id])
    }
  end

  @doc """
  Lists the version's drawable stops inside a map viewport (AC-23).

  `bounds` carries `south`, `west`, `north` and `east` under string keys (atom keys
  are accepted too) as numbers or numeric strings; the values arrive from the map
  hook, so they are parsed rather than interpolated, latitudes are clamped to
  ±90 and longitudes to ±180, and a value that is missing or not a number, or
  bounds whose clamped `south > north` or `west > east`, is
  `{:error, :invalid_bounds}` — the antimeridian is not supported. The result
  holds at most 200 stops and stations (`location_type` nil, 0 or 1) with
  coordinates inside the box, ordered by name then ID, with `truncated?: true`
  when more matched, so the page can ask the operator to zoom in. Every query is
  scoped by organization and version.
  """
  @spec stops_in_bounds(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{stops: [map_point()], truncated?: boolean()}} | {:error, :invalid_bounds}
  def stops_in_bounds(organization_id, gtfs_version_id, bounds) do
    case parse_bounds(bounds) do
      {:ok, parsed} -> {:ok, bounds_stops(organization_id, gtfs_version_id, parsed)}
      :error -> {:error, :invalid_bounds}
    end
  end

  @doc """
  Returns the version's stop bounding box for the map's initial view.

  The box is the minimum and maximum latitude and longitude over the stops of this
  organization and version that carry both coordinates, as floats, in one
  aggregate query. A version with no such stop — empty, or every stop missing a
  coordinate — is `nil`, so the hook falls back to its default view instead of a
  zero-sized box.
  """
  @spec version_extent(Ecto.UUID.t(), Ecto.UUID.t()) ::
          %{south: float(), west: float(), north: float(), east: float()} | nil
  def version_extent(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      where: not is_nil(s.stop_lat) and not is_nil(s.stop_lon),
      select: %{
        south: min(s.stop_lat),
        west: min(s.stop_lon),
        north: max(s.stop_lat),
        east: max(s.stop_lon)
      }
    )
    |> Repo.one()
    |> extent()
  end

  @typedoc "The row that already holds a written rule's six-field key."
  @type collision :: %{id: Ecto.UUID.t(), transfer_type: 0..5}

  @typedoc "A failed transfer write."
  @type write_error ::
          Ecto.Changeset.t() | {:duplicate, collision() | nil} | :not_found | :stale | :busy

  @doc """
  Creates one general (types 0–3) transfer rule for the audit context's version.

  The rule's organization and version come only from `audit`; a tenant value in
  `attrs` is ignored, and `Transfer.editor_changeset/2` accepts types 0–3 only, so
  a type 4/5 row can never be created here (R1). The changeset's references are
  then checked inside the write transaction: each stop must exist in this version
  with `location_type` nil, 0 or 1 (R2), and each set route and trip must exist,
  with the trip on the side's route and serving the side's coverage (R4). The row
  is inserted and audited with one `"transfer"` change log in the same transaction
  (R9); an audit failure rolls the whole write back.

  The transaction runs in this module's retry loop over the configured
  `ReviewedApplyTransaction` module, retrying a serialization failure (40001) or a
  deadlock (40P01) up to three attempts before `:busy` (R8). A unique-key failure
  returns `{:error, {:duplicate, collision}}` where `collision` carries the
  colliding row's id and type, or `nil` when that row was removed in between; the
  lookup runs after the failed transaction has rolled back (R5).
  """
  @spec create_general(map(), AuditContext.t()) :: {:ok, Transfer.t()} | {:error, write_error()}
  def create_general(attrs, %AuditContext{} = audit) when is_map(attrs) do
    case run_write(fn -> create_general_transaction(attrs, audit) end) do
      {:error, %Ecto.Changeset{} = changeset} -> duplicate_result(changeset, audit)
      result -> result
    end
  end

  @doc """
  Changes one existing general (types 0–3) transfer rule in the audit context's version.

  The target is loaded through a query scoped to the organization, the version and
  `transfer_type in 0..3`, so an unknown or malformed ID, another version's or
  organization's row and a type 4/5 row are all `:not_found` and change nothing
  (R1/R10). The write proceeds only when `expected_updated_at` — the stored
  `DateTime` or its ISO 8601 string — matches the loaded row; a different, missing or
  unparseable value is `:stale` with no write (R8).

  The changeset is applied to the loaded row, so the organization and version cannot
  change and a type 4/5 row is already out of reach. Submitting the row's current
  values returns `{:ok, row}` unchanged, with no update and no audit log.
  `Transfer.editor_changeset/2` records no change for a value equal to the stored one
  and stores nil for every non-2 type, so the check is on the changeset's changes.
  Otherwise the changeset's references are validated inside the write transaction
  (R2/R4) and the row is audited with one `"updated"` `"transfer"` change log whose
  `before` and `after` are the eight GTFS columns on either side of the write (R9).
  A key collision returns `{:error, {:duplicate, %{id, transfer_type} | nil}}` through
  the same post-rollback lookup `create_general/2` uses (R5), and serialization
  failures and deadlocks retry up to three attempts before `:busy` (R8).
  """
  @spec update_general(Ecto.UUID.t(), map(), DateTime.t() | String.t() | nil, AuditContext.t()) ::
          {:ok, Transfer.t()} | {:error, write_error()}
  def update_general(id, attrs, expected_updated_at, %AuditContext{} = audit)
      when is_map(attrs) do
    case run_write(fn -> update_general_transaction(id, attrs, expected_updated_at, audit) end) do
      {:error, %Ecto.Changeset{} = changeset} -> duplicate_result(changeset, audit)
      result -> result
    end
  end

  # -- Scoped loads ----------------------------------------------------------

  defp load_transfers(organization_id, gtfs_version_id) do
    from(t in Transfer,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.id]
    )
    |> Repo.all()
  end

  # Query 2: the endpoint stops themselves and every stop that names an endpoint as
  # its parent station, so a station endpoint's coverage is complete.
  defp load_stops(_organization_id, _gtfs_version_id, []), do: []

  defp load_stops(organization_id, gtfs_version_id, stop_ids) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          (s.stop_id in ^stop_ids or s.parent_station in ^stop_ids)
    )
    |> Repo.all()
  end

  defp load_stop_index(organization_id, gtfs_version_id, transfers) do
    loaded = load_stops(organization_id, gtfs_version_id, transfer_stop_ids(transfers))
    loaded_ids = MapSet.new(loaded, & &1.stop_id)

    parents =
      loaded
      |> Enum.map(& &1.parent_station)
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(loaded_ids, &1)))
      |> Enum.uniq()

    (loaded ++ load_parent_stops(organization_id, gtfs_version_id, parents))
    |> Map.new(&{&1.stop_id, &1})
  end

  # Query 3: the parents of loaded endpoint stops that query 2 did not return, so a
  # platform endpoint can report its top-level station.
  defp load_parent_stops(_organization_id, _gtfs_version_id, []), do: []

  defp load_parent_stops(organization_id, gtfs_version_id, parent_ids) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id in ^parent_ids
    )
    |> Repo.all()
  end

  # Query 4: the trips a rule selects, with the route each one belongs to.
  defp load_trips(_organization_id, _gtfs_version_id, []), do: []

  defp load_trips(organization_id, gtfs_version_id, trip_ids) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
          t.trip_id in ^trip_ids,
      select: %{
        trip_id: t.trip_id,
        route_id: t.route_id,
        trip_headsign: t.trip_headsign,
        service_id: t.service_id
      }
    )
    |> Repo.all()
  end

  defp load_trip_index(organization_id, gtfs_version_id, transfers) do
    transfers
    |> transfer_trip_ids()
    |> then(&load_trips(organization_id, gtfs_version_id, &1))
    |> Map.new(&{&1.trip_id, &1})
  end

  # Query 5: the routes a rule selects plus the routes of loaded selector trips.
  defp load_routes(_organization_id, _gtfs_version_id, []), do: []

  defp load_routes(organization_id, gtfs_version_id, route_ids) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.route_id in ^route_ids,
      select: %{
        route_id: r.route_id,
        route_short_name: r.route_short_name,
        route_long_name: r.route_long_name,
        active: r.active
      }
    )
    |> Repo.all()
  end

  defp load_route_index(organization_id, gtfs_version_id, transfers, trips) do
    route_ids =
      Enum.map(trips, fn {_trip_id, trip} -> trip.route_id end)

    route_ids = Enum.uniq(transfer_route_ids(transfers) ++ route_ids)

    load_routes(organization_id, gtfs_version_id, route_ids)
    |> Map.new(&{&1.route_id, &1})
  end

  # Query 6: the stop_time incidence of every coverage leaf of a general rule, with
  # the trip's route. The join repeats organization and version so the same trip_id
  # in another version cannot supply a route.
  defp load_incidence(_organization_id, _gtfs_version_id, []), do: %{}

  defp load_incidence(organization_id, gtfs_version_id, leaves) do
    from(st in StopTime,
      join: t in Trip,
      on:
        t.trip_id == st.trip_id and t.organization_id == st.organization_id and
          t.gtfs_version_id == st.gtfs_version_id,
      where:
        st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
          st.stop_id in ^leaves,
      distinct: true,
      select: {st.stop_id, st.trip_id, t.route_id}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {stop_id, _trip_id, _route_id} -> stop_id end,
      fn {_stop_id, trip_id, route_id} -> {trip_id, route_id} end
    )
  end

  defp transfer_stop_ids(transfers) do
    transfers
    |> Enum.flat_map(&[&1.from_stop_id, &1.to_stop_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp transfer_trip_ids(transfers) do
    transfers
    |> Enum.flat_map(&[&1.from_trip_id, &1.to_trip_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp transfer_route_ids(transfers) do
    transfers
    |> Enum.flat_map(&[&1.from_route_id, &1.to_route_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # -- Annotation ------------------------------------------------------------

  defp view_rows(transfers, data, competitor_ids) do
    transfers
    |> Enum.map(&row(&1, data, competitor_ids))
    |> attach_reverse_ids()
    |> sort_rows(:from, :asc)
  end

  defp row(transfer, data, competitor_ids) do
    ids = Map.get(competitor_ids, transfer.id, [])

    %{
      id: transfer.id,
      transfer: transfer,
      from: endpoint(transfer, :from, data),
      to: endpoint(transfer, :to, data),
      rank: Overlaps.rank(transfer),
      attention: attention(transfer, ids, data),
      competitor_ids: ids,
      reverse_id: nil
    }
  end

  defp endpoint(transfer, side, data) do
    stop = Map.get(data.stops, stop_id(transfer, side))
    trip = Map.get(data.trips, trip_id(transfer, side))
    route_id = route_id(transfer, side) || (trip && trip.route_id)

    %{
      stop_id: stop_id(transfer, side),
      name: stop && stop.stop_name,
      location_type: stop && stop.location_type,
      platform_code: stop && stop.platform_code,
      top_level: top_level(stop, data.stops),
      child_count: child_count(stop_id(transfer, side), data.stops),
      selector: selector(transfer, side),
      route: route_map(Map.get(data.routes, route_id))
    }
  end

  # R2: only a station expands to its direct children, and only the children that
  # are stops or platforms (location type nil or 0).
  defp coverage(nil, _stops), do: []

  defp coverage(stop_id, stops) do
    case Map.get(stops, stop_id) do
      nil -> []
      %Stop{location_type: 1} = station -> [station.stop_id | child_stop_ids(station, stops)]
      %Stop{} = stop -> [stop.stop_id]
    end
  end

  defp child_stop_ids(station, stops) do
    stops
    |> Map.values()
    |> Enum.filter(&(&1.parent_station == station.stop_id and &1.location_type in [nil, 0]))
    |> Enum.map(& &1.stop_id)
    |> Enum.sort()
  end

  defp coverage_leaves(general, stops) do
    general
    |> Enum.flat_map(&(coverage(&1.from_stop_id, stops) ++ coverage(&1.to_stop_id, stops)))
    |> Enum.uniq()
  end

  defp child_count(nil, _stops), do: 0

  defp child_count(stop_id, stops) do
    case coverage(stop_id, stops) do
      [] -> 0
      leaves -> length(leaves) - 1
    end
  end

  defp top_level(nil, _stops), do: nil

  defp top_level(%Stop{} = stop, stops) do
    case Map.get(stops, stop.parent_station) do
      %Stop{stop_id: stop_id, stop_name: name} -> %{stop_id: stop_id, name: name}
      nil -> %{stop_id: stop.stop_id, name: stop.stop_name}
    end
  end

  defp route_map(nil), do: nil

  defp route_map(route) do
    %{
      route_id: route.route_id,
      route_short_name: route.route_short_name,
      route_long_name: route.route_long_name
    }
  end

  defp selector(transfer, side) do
    case trip_id(transfer, side) do
      nil ->
        case route_id(transfer, side) do
          nil -> :any
          route_id -> {:route, route_id}
        end

      trip_id ->
        {:trip, trip_id}
    end
  end

  # Rules: a general rule for the R6 evaluator, carrying the coverage computed from
  # the same stop index the rows use.
  defp rule(transfer, stops) do
    %{
      id: transfer.id,
      from_coverage: coverage(transfer.from_stop_id, stops),
      to_coverage: coverage(transfer.to_stop_id, stops),
      from_route_id: transfer.from_route_id,
      to_route_id: transfer.to_route_id,
      from_trip_id: transfer.from_trip_id,
      to_trip_id: transfer.to_trip_id,
      transfer_type: transfer.transfer_type,
      min_transfer_time: transfer.min_transfer_time
    }
  end

  # R11 in the documented order. An in-seat row is read-only here, so it carries no
  # attention reason even when its references are damaged.
  defp attention(%Transfer{transfer_type: type}, _ids, _data) when type in @in_seat_types, do: []

  defp attention(transfer, ids, data) do
    competes(ids) ++
      side_reasons(transfer, :from, data) ++
      side_reasons(transfer, :to, data) ++
      min_time_reasons(transfer)
  end

  defp competes([]), do: []
  defp competes(ids), do: [{:competes, length(ids)}]

  defp min_time_reasons(%Transfer{transfer_type: 2, min_transfer_time: nil}),
    do: [:min_time_missing]

  defp min_time_reasons(%Transfer{}), do: []

  defp side_reasons(transfer, side, data) do
    stop_id = stop_id(transfer, side)
    route_id = route_id(transfer, side)
    trip_id = trip_id(transfer, side)

    stop_reasons(stop_id, side, data) ++
      route_reasons(route_id, side, data) ++
      trip_reasons(trip_id, side, data) ++
      trip_on_route_reasons(trip_id, route_id, side, data) ++
      trip_at_stop_reasons(trip_id, stop_id, side, data)
  end

  defp stop_reasons(nil, _side, _data), do: []

  defp stop_reasons(stop_id, side, data) do
    case Map.get(data.stops, stop_id) do
      nil -> [{:missing_stop, side, stop_id}]
      %Stop{location_type: type} when type in [nil, 0, 1] -> []
      %Stop{location_type: type} -> [{:invalid_stop_type, side, stop_id, type}]
    end
  end

  defp route_reasons(nil, _side, _data), do: []

  defp route_reasons(route_id, side, data) do
    if Map.has_key?(data.routes, route_id), do: [], else: [{:missing_route, side, route_id}]
  end

  defp trip_reasons(nil, _side, _data), do: []

  defp trip_reasons(trip_id, side, data) do
    if Map.has_key?(data.trips, trip_id), do: [], else: [{:missing_trip, side, trip_id}]
  end

  defp trip_on_route_reasons(nil, _route_id, _side, _data), do: []
  defp trip_on_route_reasons(_trip_id, nil, _side, _data), do: []

  defp trip_on_route_reasons(trip_id, route_id, side, data) do
    case Map.get(data.trips, trip_id) do
      %{route_id: ^route_id} -> []
      %{} -> [{:trip_not_on_route, side, trip_id, route_id}]
      nil -> []
    end
  end

  # A missing trip or an unknown stop already reports its own reason, so the service
  # reasons are only evaluated against resolved references.
  defp trip_at_stop_reasons(nil, _stop_id, _side, _data), do: []
  defp trip_at_stop_reasons(_trip_id, nil, _side, _data), do: []

  defp trip_at_stop_reasons(trip_id, stop_id, side, data) do
    cond do
      not Map.has_key?(data.trips, trip_id) -> []
      not Map.has_key?(data.stops, stop_id) -> []
      served?(data.incidence, coverage(stop_id, data.stops), trip_id) -> []
      true -> [{:trip_not_at_stop, side, trip_id, stop_id}]
    end
  end

  defp served?(incidence, leaves, trip_id) do
    leaves
    |> Enum.flat_map(&Map.get(incidence, &1, []))
    |> Enum.any?(fn {trip, _route_id} -> trip == trip_id end)
  end

  defp stop_id(transfer, :from), do: transfer.from_stop_id
  defp stop_id(transfer, :to), do: transfer.to_stop_id
  defp route_id(transfer, :from), do: transfer.from_route_id
  defp route_id(transfer, :to), do: transfer.to_route_id
  defp trip_id(transfer, :from), do: transfer.from_trip_id
  defp trip_id(transfer, :to), do: transfer.to_trip_id

  # -- Listing ---------------------------------------------------------------

  # A stop filter matches the requested stop and every stop whose parent it is,
  # whatever location type, so a station matches its children. R2's coverage is the
  # narrower rule the editor and the incidence query use.
  defp stop_filter(_organization_id, _gtfs_version_id, nil), do: nil

  defp stop_filter(organization_id, gtfs_version_id, stop_id) do
    children = Enum.map(load_stops(organization_id, gtfs_version_id, [stop_id]), & &1.stop_id)
    MapSet.new([stop_id | children])
  end

  # The one predicate the listing and the related counts share (CR-4).
  defp matches_filters?(transfer, stop_ids, route_id, trip_routes) do
    matches_stop?(transfer, stop_ids) and matches_route?(transfer, route_id, trip_routes)
  end

  defp matches_stop?(_transfer, nil), do: true

  defp matches_stop?(transfer, stop_ids) do
    MapSet.member?(stop_ids, transfer.from_stop_id) or
      MapSet.member?(stop_ids, transfer.to_stop_id)
  end

  defp matches_route?(_transfer, nil, _trip_routes), do: true

  defp matches_route?(transfer, route_id, trip_routes) do
    transfer.from_route_id == route_id or transfer.to_route_id == route_id or
      Map.get(trip_routes, transfer.from_trip_id) == route_id or
      Map.get(trip_routes, transfer.to_trip_id) == route_id
  end

  # The route of every loaded trip, so a rule whose stored trip is on the requested
  # route matches without a route selector of its own.
  defp trip_route_index(trips),
    do: Map.new(trips, fn {trip_id, trip} -> {trip_id, trip.route_id} end)

  # `type` is a filter only inside the range of the view being listed: 4 in the
  # general view is dropped rather than answered with an empty list.
  defp filter_type(rows, type, view) do
    if valid_type?(type, view) do
      Enum.filter(rows, &(&1.transfer.transfer_type == type))
    else
      rows
    end
  end

  defp valid_type?(type, :in_seat), do: type in @in_seat_types
  defp valid_type?(type, _view), do: type in @general_types

  # `attention: true` narrows the general view to rows with at least one R11 reason;
  # the in-seat view carries no reasons, so the option is ignored there.
  defp filter_attention(rows, true, :general), do: Enum.filter(rows, &(&1.attention != []))
  defp filter_attention(rows, _attention, _view), do: rows

  defp filter_search(rows, nil), do: rows

  defp filter_search(rows, search) do
    needle = String.downcase(search)
    Enum.filter(rows, &String.contains?(haystack(&1), needle))
  end

  # One field per line, so a query cannot match across two fields: the stored stop,
  # route and trip ids, the resolved endpoint names, platform codes and parent
  # station names, and the resolved route ids and names.
  defp haystack(row) do
    (stored_haystack(row.transfer) ++ endpoint_haystack(row.from) ++ endpoint_haystack(row.to))
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n", &String.downcase/1)
  end

  defp stored_haystack(transfer) do
    [
      transfer.from_stop_id,
      transfer.to_stop_id,
      transfer.from_route_id,
      transfer.to_route_id,
      transfer.from_trip_id,
      transfer.to_trip_id
    ]
  end

  defp endpoint_haystack(endpoint) do
    [
      endpoint.name,
      endpoint.platform_code,
      nested(endpoint.top_level, :name),
      nested(endpoint.route, :route_id),
      nested(endpoint.route, :route_short_name),
      nested(endpoint.route, :route_long_name)
    ]
  end

  defp nested(nil, _key), do: nil
  defp nested(map, key), do: Map.get(map, key)

  # Only the primary key takes the direction; ties stay by from name, to name and id
  # ascending in both directions, so a descending sort reverses the primary order.
  defp sort_rows(rows, sort_by, sort_dir) do
    Enum.sort(rows, fn a, b -> ordered?(a, b, sort_by, sort_dir) end)
  end

  defp ordered?(a, b, sort_by, sort_dir) do
    primary = primary_key(a, sort_by)
    other = primary_key(b, sort_by)

    cond do
      primary == other -> tie_key(a) <= tie_key(b)
      sort_dir == :desc -> primary > other
      true -> primary < other
    end
  end

  defp primary_key(row, :from), do: sort_display(row.from)
  defp primary_key(row, :to), do: sort_display(row.to)
  defp primary_key(row, :type), do: row.transfer.transfer_type

  defp primary_key(row, :min_time) do
    case row.transfer.min_transfer_time do
      nil -> {0, nil}
      seconds -> {1, seconds}
    end
  end

  defp tie_key(row), do: {sort_display(row.from), sort_display(row.to), row.id}

  defp sort_display(endpoint), do: endpoint |> display() |> String.downcase()

  # A `rule` inside the filtered list selects its own page and row; otherwise the
  # requested page is clamped to the filtered list.
  defp paginate(rows, rule, requested, per_page) do
    case rule_index(rows, rule) do
      nil ->
        page = min(requested, max_page(rows, per_page))
        page_rows = Enum.slice(rows, (page - 1) * per_page, per_page)
        {page, page_rows, List.first(page_rows)}

      index ->
        page = div(index, per_page) + 1
        {page, Enum.slice(rows, (page - 1) * per_page, per_page), Enum.at(rows, index)}
    end
  end

  defp rule_index(rows, rule) when is_binary(rule) and rule != "" do
    Enum.find_index(rows, &(&1.id == rule))
  end

  defp rule_index(_rows, _rule), do: nil

  # A typed option is used only when it is a non-blank string; anything else is
  # treated as absent rather than coerced. The LiveView canonicalizes the URL.
  defp string_option(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_option(_value), do: nil

  defp max_page(rows, per_page), do: max(1, div(length(rows) + per_page - 1, per_page))

  defp requested_page(opts) do
    case Keyword.get(opts, :page) do
      page when is_integer(page) and page > 0 -> page
      _other -> 1
    end
  end

  defp requested_per_page(opts) do
    case Keyword.get(opts, :per_page) do
      per_page when is_integer(per_page) and per_page > 0 -> per_page
      _other -> @default_per_page
    end
  end

  defp requested_sort_by(opts) do
    case Keyword.get(opts, :sort_by) do
      key when key in @sort_keys -> key
      _other -> :from
    end
  end

  defp requested_sort_dir(opts) do
    case Keyword.get(opts, :sort_dir) do
      :desc -> :desc
      _other -> :asc
    end
  end

  # The filter options describe the view's own rows rather than the filtered page,
  # so a filter control keeps its choices. The value currently applied is appended
  # when the view has no option for it — an unknown id, or a platform listed under
  # its station — with no name, so the control can still show it selected.
  defp filter_options(rows, view, opts) do
    %{
      stops: rows |> stop_options() |> put_missing_stop(string_option(opts[:stop])),
      routes: rows |> route_options() |> put_missing_route(string_option(opts[:route])),
      types: if(view == :in_seat, do: @in_seat_types, else: @general_types)
    }
  end

  defp stop_options(rows) do
    rows
    |> Enum.flat_map(&[&1.from.top_level, &1.to.top_level])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.stop_id)
    |> Enum.sort_by(&{&1.name, &1.stop_id})
  end

  defp route_options(rows) do
    rows
    |> Enum.flat_map(&[&1.from.route, &1.to.route])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.route_id)
    |> Enum.sort_by(&{&1.route_short_name, &1.route_id})
  end

  defp put_missing_stop(options, nil), do: options

  defp put_missing_stop(options, stop_id) do
    if Enum.any?(options, &(&1.stop_id == stop_id)) do
      options
    else
      options ++ [%{stop_id: stop_id, name: nil}]
    end
  end

  defp put_missing_route(options, nil), do: options

  defp put_missing_route(options, route_id) do
    if Enum.any?(options, &(&1.route_id == route_id)) do
      options
    else
      options ++ [%{route_id: route_id, route_short_name: nil, route_long_name: nil}]
    end
  end

  # -- Editor options ---------------------------------------------------------

  # The same trim and LIKE-wildcard escaping as `RoutePatterns.search_stops/3`, so
  # `%`, `_` and `\` in a query match literally instead of scanning the version's
  # stops.
  defp stop_search_pattern(query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        nil

      trimmed ->
        "%" <> String.replace(trimmed, ~r/[\\%_]/, fn match -> "\\" <> match end) <> "%"
    end
  end

  defp stop_search_pattern(_query), do: nil

  # The parent name and the station child count come from two bounded follow-up
  # queries for the returned options, so the search itself stays one query.
  defp stop_options(_organization_id, _gtfs_version_id, []), do: []

  defp stop_options(organization_id, gtfs_version_id, stops) do
    parent_names = load_parent_names(organization_id, gtfs_version_id, stops)
    child_counts = load_child_counts(organization_id, gtfs_version_id, stops)

    Enum.map(stops, &build_stop_option(&1, parent_names, child_counts))
  end

  defp load_parent_names(organization_id, gtfs_version_id, stops) do
    parent_ids =
      stops
      |> Enum.map(& &1.parent_station)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    organization_id
    |> load_parent_stops(gtfs_version_id, parent_ids)
    |> Map.new(&{&1.stop_id, &1.stop_name})
  end

  # R2's selectable children only: the nil-or-0 location types the validator and
  # the coverage rule count, never an entrance or a generic node.
  defp load_child_counts(organization_id, gtfs_version_id, stops) do
    station_ids = for %Stop{location_type: 1, stop_id: stop_id} <- stops, do: stop_id

    case station_ids do
      [] ->
        %{}

      ids ->
        from(s in Stop,
          where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
          where: s.parent_station in ^ids,
          where: is_nil(s.location_type) or s.location_type == 0,
          group_by: s.parent_station,
          select: {s.parent_station, count(s.stop_id)}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  defp build_stop_option(stop, parent_names, child_counts) do
    %{
      stop_id: stop.stop_id,
      stop_name: stop.stop_name,
      location_type: stop.location_type,
      platform_code: stop.platform_code,
      parent_name: Map.get(parent_names, stop.parent_station),
      child_count: Map.get(child_counts, stop.stop_id, 0),
      lat: decimal_to_float(stop.stop_lat),
      lon: decimal_to_float(stop.stop_lon)
    }
  end

  defp decimal_to_float(nil), do: nil
  defp decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)

  # R2 coverage of one stop from a scoped load. A stop that is not in this
  # organization and version covers nothing, so a foreign or unknown ID can never
  # contribute a route or a trip option.
  defp stop_coverage(organization_id, gtfs_version_id, stop_id) do
    stops =
      organization_id
      |> load_stops(gtfs_version_id, [stop_id])
      |> Map.new(&{&1.stop_id, &1})

    coverage(stop_id, stops)
  end

  # `Gtfs.get_routes_for_stops/3` answers with route maps keyed by stop; only the
  # route IDs are used here, because the options need the active routes and their
  # long names, which that helper does not return.
  defp serving_route_ids(_organization_id, _gtfs_version_id, []), do: []

  defp serving_route_ids(organization_id, gtfs_version_id, coverage) do
    organization_id
    |> Gtfs.get_routes_for_stops(gtfs_version_id, coverage)
    |> Enum.flat_map(fn {_stop_id, routes} -> routes end)
    |> Enum.map(& &1.route_id)
    |> Enum.uniq()
  end

  defp active_route_options(_organization_id, _gtfs_version_id, []), do: []

  defp active_route_options(organization_id, gtfs_version_id, route_ids) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      where: r.route_id in ^route_ids and r.active == true,
      order_by: [asc: r.route_short_name, asc: r.route_id],
      select: %{
        route_id: r.route_id,
        route_short_name: r.route_short_name,
        route_long_name: r.route_long_name
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :note, nil))
  end

  defp append_current_route(options, _organization_id, _gtfs_version_id, nil), do: options

  defp append_current_route(options, organization_id, gtfs_version_id, current) do
    if Enum.any?(options, &(&1.route_id == current)) do
      options
    else
      options ++ [current_route_option(organization_id, gtfs_version_id, current)]
    end
  end

  defp current_route_option(organization_id, gtfs_version_id, route_id) do
    case load_routes(organization_id, gtfs_version_id, [route_id]) do
      [] ->
        %{route_id: route_id, route_short_name: nil, route_long_name: nil, note: :missing}

      [route] ->
        %{
          route_id: route_id,
          route_short_name: route.route_short_name,
          route_long_name: route.route_long_name,
          note: if(route.active, do: :not_serving, else: :inactive)
        }
    end
  end

  # One query for every stop_time of the route's trips at a coverage leaf, grouped
  # per trip; the earliest clock of a trip decides the displayed time.
  defp trip_option_rows(_organization_id, _gtfs_version_id, _route_id, [], _side), do: []

  defp trip_option_rows(organization_id, gtfs_version_id, route_id, coverage, side) do
    from(st in StopTime,
      join: t in Trip,
      on:
        t.trip_id == st.trip_id and t.organization_id == st.organization_id and
          t.gtfs_version_id == st.gtfs_version_id,
      where:
        st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
          t.route_id == ^route_id and st.stop_id in ^coverage,
      select: {t.trip_id, t.trip_headsign, t.service_id, st.arrival_time, st.departure_time}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(&trip_option(&1, side))
    |> Enum.sort_by(&{&1.time, &1.trip_id})
  end

  defp trip_option(
         {trip_id, [{_trip_id, headsign, service_id, _arrival, _departure} | _] = rows},
         side
       ) do
    %{
      trip_id: trip_id,
      time: rows |> Enum.map(&side_clock(&1, side)) |> earliest_clock(),
      headsign: headsign,
      service_id: service_id,
      note: nil
    }
  end

  defp side_clock({_trip_id, _headsign, _service_id, arrival, _departure}, :from), do: arrival
  defp side_clock({_trip_id, _headsign, _service_id, _arrival, departure}, :to), do: departure

  # The earliest clock is compared as parsed seconds, so a GTFS value past midnight
  # or a single-digit hour still orders correctly; an unparseable stored value sorts
  # after every valid clock by its own text rather than raising.
  defp earliest_clock(clocks) do
    case Enum.reject(clocks, &is_nil/1) do
      [] -> nil
      values -> values |> Enum.min_by(&clock_key/1) |> String.slice(0, 5)
    end
  end

  defp clock_key(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> {0, seconds, value}
      {:error, :invalid_time} -> {1, 0, value}
    end
  end

  defp append_current_trip(options, _organization_id, _gtfs_version_id, _route_id, nil),
    do: options

  defp append_current_trip(options, organization_id, gtfs_version_id, route_id, current) do
    if Enum.any?(options, &(&1.trip_id == current)) do
      options
    else
      options ++ [current_trip_option(organization_id, gtfs_version_id, route_id, current)]
    end
  end

  # The appended selector carries no clock: the trip is offered for its note, not
  # as a schedulable option with a time at this coverage.
  defp current_trip_option(organization_id, gtfs_version_id, route_id, trip_id) do
    case load_trips(organization_id, gtfs_version_id, [trip_id]) do
      [] ->
        %{trip_id: trip_id, time: nil, headsign: nil, service_id: nil, note: :missing}

      [%{route_id: ^route_id} = trip] ->
        %{
          trip_id: trip_id,
          time: nil,
          headsign: trip.trip_headsign,
          service_id: trip.service_id,
          note: :not_serving
        }

      [trip] ->
        %{
          trip_id: trip_id,
          time: nil,
          headsign: trip.trip_headsign,
          service_id: trip.service_id,
          note: :other_route
        }
    end
  end

  # -- Map reads -------------------------------------------------------------

  # `map_payload/3` answers the whole payload from one scoped `load_stops/3` call:
  # that query already returns the endpoint stops and every stop naming one as its
  # parent station, so the points and the children come from the same rows.
  defp map_endpoint(_index, nil), do: nil

  defp map_endpoint(index, stop_id) do
    case Map.get(index, stop_id) do
      %Stop{stop_lat: lat, stop_lon: lon} = stop when not is_nil(lat) and not is_nil(lon) ->
        map_point(stop)

      _missing_or_incomplete ->
        nil
    end
  end

  # R2 again: only a station endpoint expands to children, and only the children
  # that are stops or platforms (nil or 0) with coordinates, because a marker needs
  # a position. A child of both sides is drawn once, under the departure side.
  defp map_children(index, from_id, to_id) do
    [{"a", from_id}, {"b", to_id}]
    |> Enum.filter(fn {_side, stop_id} -> station?(Map.get(index, stop_id)) end)
    |> Enum.flat_map(fn {side, stop_id} ->
      index
      |> Map.values()
      |> Enum.filter(fn child ->
        child.parent_station == stop_id and child.location_type in [nil, 0] and
          not is_nil(child.stop_lat) and not is_nil(child.stop_lon)
      end)
      |> Enum.sort_by(&{&1.stop_name, &1.stop_id})
      |> Enum.map(&Map.put(map_point(&1), :side, side))
    end)
    |> Enum.uniq_by(& &1.stop_id)
  end

  defp station?(%Stop{location_type: 1}), do: true
  defp station?(_stop), do: false

  # Endpoint display names, once each, in endpoint order: a name or else the ID.
  defp missing_coordinates(index, stop_ids) do
    stop_ids
    |> Enum.flat_map(&missing_coordinate_name(index, &1))
    |> Enum.uniq()
  end

  defp missing_coordinate_name(_index, nil), do: []

  defp missing_coordinate_name(index, stop_id) do
    case Map.get(index, stop_id) do
      %Stop{stop_lat: nil} = stop -> [stop_label(stop)]
      %Stop{stop_lon: nil} = stop -> [stop_label(stop)]
      _known_with_coordinates_or_unknown -> []
    end
  end

  defp stop_label(%Stop{stop_name: name, stop_id: stop_id}), do: name || stop_id

  # A hook payload value names a stop only when it is a non-blank string; anything
  # else is treated as no endpoint rather than cast (CR-6 untrusted input).
  defp map_stop_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp map_stop_id(_value), do: nil

  defp map_point(%Stop{} = stop) do
    %{
      stop_id: stop.stop_id,
      name: stop.stop_name,
      lat: decimal_to_float(stop.stop_lat),
      lon: decimal_to_float(stop.stop_lon),
      location_type: stop.location_type
    }
  end

  # The bounds parser. Values arrive from the map hook, so they are parsed from a
  # number or a numeric string and never interpolated into SQL; the clamped values
  # are what the ordering check and the query use.
  defp parse_bounds(bounds) when is_map(bounds) do
    with {:ok, south} <- bound_value(bounds, :south),
         {:ok, west} <- bound_value(bounds, :west),
         {:ok, north} <- bound_value(bounds, :north),
         {:ok, east} <- bound_value(bounds, :east) do
      parsed = %{
        south: clamp_latitude(south),
        west: clamp_longitude(west),
        north: clamp_latitude(north),
        east: clamp_longitude(east)
      }

      if parsed.south <= parsed.north and parsed.west <= parsed.east do
        {:ok, parsed}
      else
        :error
      end
    end
  end

  defp parse_bounds(_bounds), do: :error

  defp bound_value(bounds, key) do
    case Map.get(bounds, key) || Map.get(bounds, Atom.to_string(key)) do
      value when is_number(value) -> {:ok, value / 1}
      value when is_binary(value) -> bound_number(value)
      _missing_or_not_a_number -> :error
    end
  end

  # `Float.parse/1` accepts a number only when the rest of the string is blank, so
  # "40.0abc" is invalid rather than silently 40.0.
  defp bound_number(value) do
    case Float.parse(value) do
      {number, rest} -> if String.trim(rest) == "", do: {:ok, number}, else: :error
      :error -> :error
    end
  end

  defp clamp_latitude(value), do: value |> max(-90.0) |> min(90.0)
  defp clamp_longitude(value), do: value |> max(-180.0) |> min(180.0)

  defp bounds_stops(organization_id, gtfs_version_id, parsed) do
    south = Decimal.from_float(parsed.south)
    west = Decimal.from_float(parsed.west)
    north = Decimal.from_float(parsed.north)
    east = Decimal.from_float(parsed.east)

    rows =
      from(s in Stop,
        where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
        where: is_nil(s.location_type) or s.location_type in [0, 1],
        where: not is_nil(s.stop_lat) and not is_nil(s.stop_lon),
        where:
          s.stop_lat >= ^south and s.stop_lat <= ^north and s.stop_lon >= ^west and
            s.stop_lon <= ^east,
        order_by: [asc: s.stop_name, asc: s.stop_id],
        limit: @stop_bounds_limit + 1
      )
      |> Repo.all()

    {stops, extra} = Enum.split(rows, @stop_bounds_limit)

    %{stops: Enum.map(stops, &map_point/1), truncated?: extra != []}
  end

  defp extent(%{south: nil}), do: nil

  defp extent(%{south: south, west: west, north: north, east: east}) do
    %{
      south: decimal_to_float(south),
      west: decimal_to_float(west),
      north: decimal_to_float(north),
      east: decimal_to_float(east)
    }
  end

  # -- View, order and reverse links -----------------------------------------

  defp requested_view(opts) do
    case Keyword.get(opts, :view) do
      :in_seat -> :in_seat
      _other -> :general
    end
  end

  defp in_seat?(%Transfer{transfer_type: type}), do: type in @in_seat_types

  defp display(endpoint), do: endpoint.name || endpoint.stop_id || ""

  # R7: the mirror of a key is the same six GTFS fields with both sides swapped,
  # resolved inside the row's own view.
  defp attach_reverse_ids(rows) do
    index = Map.new(rows, &{key(&1.transfer), &1.id})

    Enum.map(rows, fn row -> %{row | reverse_id: reverse_id(index, row)} end)
  end

  defp reverse_id(index, row) do
    case Map.get(index, mirror_key(row.transfer)) do
      id when is_binary(id) and id != row.id -> id
      _id -> nil
    end
  end

  defp key(transfer) do
    {transfer.from_stop_id, transfer.to_stop_id, transfer.from_route_id, transfer.to_route_id,
     transfer.from_trip_id, transfer.to_trip_id}
  end

  defp mirror_key(transfer) do
    {transfer.to_stop_id, transfer.from_stop_id, transfer.to_route_id, transfer.from_route_id,
     transfer.to_trip_id, transfer.from_trip_id}
  end

  defp competitors(_rows, nil), do: []

  defp competitors(rows, %{competitor_ids: ids}) do
    Enum.filter(rows, &(&1.id in ids))
  end

  # -- Writes ----------------------------------------------------------------

  # Bounded retry over the configured transaction module. This is the third copy
  # beside `Schedules` and `RoutePatterns`, which keep private loops of their own;
  # extract one shared loop once package 05's retry-code change merges (spec
  # Deferred work). A serialization failure (40001) or a deadlock (40P01) retries
  # the whole transaction; every other failure is returned unchanged.
  defp run_write(transaction, attempts \\ @write_attempts) do
    case run_write_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:retryable_failure, _error} ->
        retry_write(transaction, attempts)

      {:error, reason} ->
        retry_write_error(reason, transaction, attempts)
    end
  end

  defp retry_write(transaction, attempts) when attempts > 1,
    do: run_write(transaction, attempts - 1)

  defp retry_write(_transaction, _attempts), do: {:error, :busy}

  defp retry_write_error(reason, transaction, attempts) do
    if retryable?(reason),
      do: retry_write(transaction, attempts),
      else: {:error, reason}
  end

  defp run_write_transaction(transaction) do
    write_transaction_module().run(transaction)
  rescue
    error in Postgrex.Error ->
      if retryable?(error) do
        {:retryable_failure, error}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp write_transaction_module do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    )
  end

  defp retryable?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:serialization_failure, "40001", :deadlock_detected, "40P01"],
       do: true

  defp retryable?(_error), do: false

  defp create_general_transaction(attrs, audit) do
    %Transfer{organization_id: audit.organization_id, gtfs_version_id: audit.gtfs_version_id}
    |> Transfer.editor_changeset(attrs)
    |> validate_references(audit.organization_id, audit.gtfs_version_id)
    |> insert_created_transfer(audit)
  end

  defp insert_created_transfer(%Ecto.Changeset{valid?: false} = changeset, _audit),
    do: Repo.rollback(changeset)

  defp insert_created_transfer(changeset, audit) do
    case Repo.insert(changeset) do
      {:ok, transfer} -> audit_created_transfer(transfer, audit)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp audit_created_transfer(transfer, audit) do
    case Gtfs.record_change_in_transaction(audit, :transfer, transfer, "created", %{
           before: nil,
           after: Transfer.audit_snapshot(transfer),
           operation_id: Ecto.UUID.generate(),
           affected_transfer_ids: [transfer.id]
         }) do
      {:ok, _log} -> transfer
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # The id-scoped load an update target goes through: another organization's or
  # version's row and a type 4/5 row are indistinguishable from an unknown ID, so
  # none of them can be written through this module (R1/R10).
  defp scoped_general(organization_id, gtfs_version_id, transfer_id) do
    from(t in Transfer,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
          t.id == ^transfer_id and t.transfer_type in ^@general_types
    )
  end

  defp update_general_transaction(id, attrs, expected_updated_at, audit) do
    case load_general(audit, id) do
      {:ok, transfer} ->
        if stale?(transfer, expected_updated_at),
          do: Repo.rollback(:stale),
          else: save_updated_transfer(transfer, attrs, audit)

      :error ->
        Repo.rollback(:not_found)
    end
  end

  defp load_general(audit, id) do
    with {:ok, transfer_id} <- Ecto.UUID.cast(id),
         %Transfer{} = transfer <-
           Repo.one(scoped_general(audit.organization_id, audit.gtfs_version_id, transfer_id)) do
      {:ok, transfer}
    else
      _error -> :error
    end
  end

  # A valid changeset with no changes is a no-op: the loaded row comes back with its
  # stored `updated_at`, no UPDATE runs and no audit log is written (R8).
  defp save_updated_transfer(transfer, attrs, audit) do
    case Transfer.editor_changeset(transfer, attrs) do
      %Ecto.Changeset{valid?: false} = changeset ->
        Repo.rollback(changeset)

      %Ecto.Changeset{changes: changes} when changes == %{} ->
        transfer

      changeset ->
        changeset
        |> validate_references(audit.organization_id, audit.gtfs_version_id)
        |> persist_updated_transfer(transfer, audit)
    end
  end

  defp persist_updated_transfer(%Ecto.Changeset{valid?: false} = changeset, _transfer, _audit),
    do: Repo.rollback(changeset)

  defp persist_updated_transfer(changeset, transfer, audit) do
    before_snapshot = Transfer.audit_snapshot(transfer)

    case Repo.update(changeset) do
      {:ok, updated} -> audit_updated_transfer(updated, before_snapshot, audit)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp audit_updated_transfer(transfer, before_snapshot, audit) do
    case Gtfs.record_change_in_transaction(audit, :transfer, transfer, "updated", %{
           before: before_snapshot,
           after: Transfer.audit_snapshot(transfer),
           operation_id: Ecto.UUID.generate(),
           affected_transfer_ids: [transfer.id]
         }) do
      {:ok, _log} -> transfer
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # R8: the caller's expected timestamp may be the stored DateTime or its ISO 8601
  # form; anything missing or unparseable is stale, so an update is never blind.
  defp stale?(transfer, expected_updated_at) do
    case normalize_timestamp(expected_updated_at) do
      %DateTime{} = expected -> DateTime.compare(transfer.updated_at, expected) != :eq
      nil -> true
    end
  end

  defp normalize_timestamp(%DateTime{} = value), do: value

  defp normalize_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp normalize_timestamp(_value), do: nil

  # CR-3: the unique-constraint failure already rolled the transaction back, so the
  # colliding row is read in a fresh query. The error lands on `:organization_id`
  # (the first field of the constraint list), so the key is taken from the applied
  # values, never from the error field.
  defp duplicate_result(%Ecto.Changeset{} = changeset, audit) do
    if unique_conflict?(changeset) do
      collision =
        find_collision(
          audit.organization_id,
          audit.gtfs_version_id,
          apply_changes(changeset)
        )

      {:error, {:duplicate, collision}}
    else
      {:error, changeset}
    end
  end

  # Empty equals empty: a nil key column is compared with `IS NULL`, so the lookup
  # matches the NULLS NOT DISTINCT index across all types, including an in-seat row
  # that holds the same key as the refused general rule (R5).
  defp find_collision(organization_id, gtfs_version_id, %Transfer{} = transfer) do
    @key_fields
    |> Enum.reduce(
      from(t in Transfer,
        where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
        select: %{id: t.id, transfer_type: t.transfer_type},
        limit: 1
      ),
      fn field, query ->
        value = Map.fetch!(transfer, field)

        if is_nil(value) do
          where(query, [t], is_nil(field(t, ^field)))
        else
          where(query, [t], field(t, ^field) == ^value)
        end
      end
    )
    |> Repo.one()
  end

  defp unique_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, meta}} ->
      constraint_type(meta) == :unique
    end)
  end

  defp constraint_type(meta) when is_list(meta), do: Keyword.get(meta, :constraint)
  defp constraint_type(meta) when is_map(meta), do: Map.get(meta, :constraint)
  defp constraint_type(_meta), do: nil

  # R2/R4 reference validation, run inside the write transaction so the read of
  # the referenced trips and stop_times is ordered with a concurrent trip deletion
  # (INV-4). A field the changeset has already rejected is not re-checked, and a
  # side whose stop is not usable contributes no trip-at-stop error.
  defp validate_references(changeset, organization_id, gtfs_version_id) do
    stops = reference_stops(changeset, organization_id, gtfs_version_id)
    routes = reference_route_ids(changeset, organization_id, gtfs_version_id)
    trips = reference_trips(changeset, organization_id, gtfs_version_id)
    incidence = trip_stop_incidence(changeset, organization_id, gtfs_version_id, stops)

    changeset
    |> validate_stop(:from, stops)
    |> validate_stop(:to, stops)
    |> validate_route(:from, routes)
    |> validate_route(:to, routes)
    |> validate_trip(:from, trips, incidence, stops)
    |> validate_trip(:to, trips, incidence, stops)
  end

  # One query for both stops and every stop naming one of them as its parent, so a
  # station endpoint's coverage is complete.
  defp reference_stops(changeset, organization_id, gtfs_version_id) do
    changeset
    |> reference_ids([:from_stop_id, :to_stop_id])
    |> then(&load_stops(organization_id, gtfs_version_id, &1))
    |> Map.new(&{&1.stop_id, &1})
  end

  defp reference_route_ids(changeset, organization_id, gtfs_version_id) do
    route_ids = reference_ids(changeset, [:from_route_id, :to_route_id])

    if route_ids == [] do
      MapSet.new()
    else
      from(r in Route,
        where:
          r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
            r.route_id in ^route_ids,
        select: r.route_id
      )
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp reference_trips(changeset, organization_id, gtfs_version_id) do
    changeset
    |> reference_ids([:from_trip_id, :to_trip_id])
    |> then(&load_trips(organization_id, gtfs_version_id, &1))
    |> Map.new(&{&1.trip_id, &1})
  end

  defp reference_ids(changeset, fields) do
    fields
    |> Enum.map(&get_field(changeset, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp validate_stop(changeset, side, stops) do
    field = stop_field(side)

    case {field_error?(changeset, field), Map.get(stops, get_field(changeset, field))} do
      {true, _stop} -> changeset
      {false, nil} -> add_error(changeset, field, @missing_stop_message)
      {false, %Stop{location_type: type}} when type in [nil, 0, 1] -> changeset
      {false, %Stop{}} -> add_error(changeset, field, @invalid_stop_type_message)
    end
  end

  defp validate_route(changeset, side, routes) do
    field = route_field(side)
    route_id = get_field(changeset, field)

    if not is_nil(route_id) and not field_error?(changeset, field) and
         not MapSet.member?(routes, route_id),
       do: add_error(changeset, field, @missing_route_message),
       else: changeset
  end

  defp validate_trip(changeset, side, trips, incidence, stops) do
    field = trip_field(side)
    trip_id = get_field(changeset, field)
    trip = Map.get(trips, trip_id)

    cond do
      is_nil(trip_id) or field_error?(changeset, field) ->
        changeset

      is_nil(trip) ->
        add_error(changeset, field, @missing_trip_message)

      different_route?(changeset, side, trip) ->
        add_error(changeset, field, @trip_not_on_route_message)

      not valid_stop?(changeset, side, stops) ->
        changeset

      not trip_serves_stop?(trip_id, changeset, side, stops, incidence) ->
        add_error(changeset, field, @trip_not_at_stop_message)

      true ->
        changeset
    end
  end

  defp different_route?(changeset, side, trip) do
    route_id = get_field(changeset, route_field(side))
    not is_nil(route_id) and trip.route_id != route_id
  end

  defp valid_stop?(changeset, side, stops) do
    case Map.get(stops, get_field(changeset, stop_field(side))) do
      %Stop{location_type: type} when type in [nil, 0, 1] -> true
      _stop -> false
    end
  end

  defp trip_serves_stop?(trip_id, changeset, side, stops, incidence) do
    coverage(get_field(changeset, stop_field(side)), stops)
    |> Enum.any?(&MapSet.member?(incidence, {trip_id, &1}))
  end

  defp trip_stop_incidence(changeset, organization_id, gtfs_version_id, stops) do
    trip_ids = reference_ids(changeset, [:from_trip_id, :to_trip_id])
    leaves = reference_coverage(changeset, stops)

    if trip_ids == [] or leaves == [] do
      MapSet.new()
    else
      from(st in StopTime,
        where:
          st.organization_id == ^organization_id and
            st.gtfs_version_id == ^gtfs_version_id and
            st.trip_id in ^trip_ids and st.stop_id in ^leaves,
        select: {st.trip_id, st.stop_id}
      )
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp reference_coverage(changeset, stops) do
    changeset
    |> reference_ids([:from_stop_id, :to_stop_id])
    |> Enum.flat_map(&coverage(&1, stops))
    |> Enum.uniq()
  end

  defp stop_field(:from), do: :from_stop_id
  defp stop_field(:to), do: :to_stop_id
  defp route_field(:from), do: :from_route_id
  defp route_field(:to), do: :to_route_id
  defp trip_field(:from), do: :from_trip_id
  defp trip_field(:to), do: :to_trip_id

  defp field_error?(%Ecto.Changeset{errors: errors}, field), do: Keyword.has_key?(errors, field)
end
