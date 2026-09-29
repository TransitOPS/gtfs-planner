defmodule GtfsPlanner.Gtfs do
  @moduledoc """
  The Gtfs context.
  """

  @structured_audit_entity_types [
    :route_pattern,
    "route_pattern",
    :timed_pattern,
    "timed_pattern",
    :route_pattern_build,
    "route_pattern_build",
    :calendar,
    "calendar",
    :trip,
    "trip",
    :transfer,
    "transfer",
    :pathway_evolution,
    "pathway_evolution"
  ]

  import Ecto.Query, warn: false
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AlignmentInference
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Area
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.BookingRule
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.Coordinates
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FeedInfo
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.FloorplanTransform
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.Location
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.PathwayEvolutions
  alias GtfsPlanner.Gtfs.RecentChanges
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Gtfs.Routes
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.StationBoard
  alias GtfsPlanner.Gtfs.StationEditingStatus
  alias GtfsPlanner.Gtfs.StationJournal
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlanner.Gtfs.StationNaming
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Timeframe
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Validations.WalkabilityTest
  alias GtfsPlanner.Versions

  require Logger

  @default_catalog_read_adapter CatalogReadAdapter.Repo
  @default_reviewed_apply_transaction ReviewedApplyTransaction.Repo

  @type list_stations_opts :: [
          route_id: String.t() | nil,
          direction_id: integer() | nil,
          wheelchair_boarding: integer() | String.t() | nil,
          search: String.t() | nil,
          sort_by: atom() | nil,
          sort_dir: :asc | :desc | nil,
          page: pos_integer() | nil,
          per_page: pos_integer() | nil,
          location_type: 0 | 1 | 2 | 3 | 4 | String.t() | nil
        ]

  @doc """
  Loads a page of routes for the route catalog through the configured catalog
  read adapter.

  The adapter counts the matching routes, clamps the requested page to a valid
  canonical page, and returns the rows together with total/page metadata and the
  available route types and agencies. A lost database connection becomes
  `{:error, :unavailable}`.

  ## Examples

      iex> load_route_catalog(organization_id, gtfs_version_id, page: 1, per_page: 25)
      {:ok, %{rows: [%Route{}], total_count: 1, page: 1, route_types: [3], agencies: ["agency1"]}}

      iex> load_route_catalog(organization_id, gtfs_version_id, [])
      {:error, :unavailable}
  """
  @spec load_route_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, CatalogReadAdapter.route_page()} | {:error, :unavailable}
  def load_route_catalog(organization_id, gtfs_version_id, opts \\ []) do
    catalog_read_adapter().load_route_catalog(organization_id, gtfs_version_id, opts)
  end

  @doc """
  Loads a page of stations for the Stops & stations catalog through the
  configured catalog read adapter.

  The adapter counts the matching stations, clamps the requested page to a valid
  canonical page, and fetches the rows. Route enrichment (available routes and
  routes-by-stop) runs separately, so its failure yields
  `{:partial, page, :route_enrichment_unavailable}` while keeping the loaded
  stop rows. A primary stop/count failure returns `{:error, :unavailable}`.

  ## Examples

      iex> load_stop_catalog(organization_id, gtfs_version_id, page: 1, per_page: 50)
      {:ok, %{rows: [%Stop{}], total_count: 1, page: 1, available_routes: [], routes_by_stop: %{}}}

      iex> load_stop_catalog(organization_id, gtfs_version_id, [])
      {:partial, %{rows: [%Stop{}]}, :route_enrichment_unavailable}
  """
  @spec load_stop_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, CatalogReadAdapter.stop_page()}
          | {:partial, CatalogReadAdapter.stop_page(), :route_enrichment_unavailable}
          | {:error, :unavailable}
  def load_stop_catalog(organization_id, gtfs_version_id, opts \\ []) do
    catalog_read_adapter().load_stop_catalog(organization_id, gtfs_version_id, opts)
  end

  @doc """
  Fetches a single route by its GTFS `route_id` for the route detail surface
  through the configured catalog read adapter.

  ## Examples

      iex> fetch_catalog_route(organization_id, gtfs_version_id, "R1")
      {:ok, %Route{}}

      iex> fetch_catalog_route(organization_id, gtfs_version_id, "missing")
      {:error, :not_found}
  """
  @spec fetch_catalog_route(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Route.t()} | {:error, :not_found | :unavailable}
  def fetch_catalog_route(organization_id, gtfs_version_id, route_id) do
    catalog_read_adapter().fetch_route(organization_id, gtfs_version_id, route_id)
  end

  @doc """
  Loads the route patterns for a route through the configured catalog read
  adapter.

  ## Examples

      iex> load_catalog_route_patterns(organization_id, gtfs_version_id, "R1")
      {:ok, [%RoutePattern{}]}
  """
  @spec load_catalog_route_patterns(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, [RoutePattern.t()]} | {:error, :unavailable}
  def load_catalog_route_patterns(organization_id, gtfs_version_id, route_id) do
    catalog_read_adapter().load_route_patterns(organization_id, gtfs_version_id, route_id)
  end

  @doc """
  Loads the scoped pattern editor read model for one published route.

  `opts` may carry `:pattern_id` and `:timing_id` to include one pattern's detail
  with only that timing's rows, and `:include_stop_choices` to include the
  version's eligible stop choices. A route or pattern outside the loaded
  organization/version/route scope is `{:error, :not_found}`; a lost database
  connection is `{:error, :unavailable}`.
  """
  @spec load_route_pattern_screen(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :unavailable}
  def load_route_pattern_screen(organization_id, gtfs_version_id, route_id, opts \\ []) do
    catalog_read_adapter().load_route_pattern_screen(
      organization_id,
      gtfs_version_id,
      route_id,
      opts
    )
  end

  @doc """
  Loads the route editor workspace for one published route through the
  configured catalog read adapter.

  The workspace carries the scoped route, its trusted edit source, scoped
  agency options, route mode counts, warning candidates and the route's last
  audit entry (`nil` reports unknown/imported attribution). A foreign or
  unpublished scope is `{:error, :not_found}`; a lost database connection is
  `{:error, :unavailable}`.
  """
  @spec load_route_editor(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :unavailable}
  def load_route_editor(organization_id, gtfs_version_id, route_id) do
    catalog_read_adapter().load_route_editor(organization_id, gtfs_version_id, route_id)
  end

  @doc """
  Projects one published route's saved map geometry through seam `S-3`
  (`GtfsPlanner.Gtfs.Routes.Map.route_map/3` over landed pattern, stop and
  shape rows).

  The map read fails independently of editor reads: a foreign or unpublished
  scope is `{:error, :not_found}` and a lost database connection is
  `{:error, :unavailable}`.
  """
  @spec route_map(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :unavailable}
  def route_map(organization_id, gtfs_version_id, route_id),
    do: Routes.route_map(organization_id, gtfs_version_id, route_id)

  @doc """
  Pages one published route's viewport context geometry (R7, AC-27) through
  seam `S-3` (`GtfsPlanner.Gtfs.Routes.Map.route_context_map/4`): the other
  routes of the same version inside `bounds`, 50 per page over a deterministic
  cursor, with the current route excluded and geometry deduplicated by shape
  and section. Malformed bounds or cursors are rejected, never coerced.
  """
  @spec route_context_map(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), %{
          bounds: term(),
          cursor: term()
        }) ::
          {:ok, map()}
          | {:error, :not_found | :invalid_bounds | :invalid_cursor | :unavailable}
  def route_context_map(organization_id, gtfs_version_id, route_id, %{
        bounds: bounds,
        cursor: cursor
      }),
      do:
        Routes.route_context_map(organization_id, gtfs_version_id, route_id, %{
          bounds: bounds,
          cursor: cursor
        })

  def route_context_map(_organization_id, _gtfs_version_id, _route_id, _opts),
    do: {:error, :invalid_bounds}

  @doc """
  Fetches a single stop by its GTFS `stop_id` for the station detail surface
  through the configured catalog read adapter.

  ## Examples

      iex> fetch_catalog_stop(organization_id, gtfs_version_id, "stop_1")
      {:ok, %Stop{}}

      iex> fetch_catalog_stop(organization_id, gtfs_version_id, "missing")
      {:error, :not_found}
  """
  @spec fetch_catalog_stop(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Stop.t()} | {:error, :not_found | :unavailable}
  def fetch_catalog_stop(organization_id, gtfs_version_id, stop_id) do
    catalog_read_adapter().fetch_stop(organization_id, gtfs_version_id, stop_id)
  end

  @doc """
  Loads the scoped calendar list through the configured catalog read adapter.

  Every calendar identity in the published organization/version is returned once,
  ordered by display name then service ID, with grouped usage, effective dates, a
  source fingerprint and `ServiceDates` warnings. `opts` may carry `:today` to pin
  the warning date; otherwise the agency-local date is resolved through
  `Gtfs.DisplayClock`. A foreign, invalid or unpublished scope is
  `{:error, :not_found}` and a lost database connection is `{:error, :unavailable}`.
  """
  @spec load_calendar_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, [Calendars.summary()]} | {:error, :not_found | :unavailable}
  def load_calendar_catalog(organization_id, gtfs_version_id, opts \\ []) do
    catalog_read_adapter().load_calendar_catalog(organization_id, gtfs_version_id, opts)
  end

  @doc """
  Loads a version's transfer catalog through the configured catalog read adapter.

  `opts` are `GtfsPlanner.Gtfs.Transfers.load_catalog/3`'s page options (`:view`,
  `:search`, `:stop`, `:route`, `:type`, `:attention`, `:sort_by`, `:sort_dir`,
  `:page`, `:per_page`, `:rule`). The catalog is scoped to the organization and
  version, lists general (types 0–3) rules by default and type 4/5 rows only in
  the in-seat view, and annotates every row with its R11 attention reasons. A lost
  database connection is `{:error, :unavailable}`.
  """
  @spec load_transfer_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Transfers.catalog()} | {:error, :unavailable}
  def load_transfer_catalog(organization_id, gtfs_version_id, opts \\ []) do
    catalog_read_adapter().load_transfer_catalog(organization_id, gtfs_version_id, opts)
  end

  @doc """
  Counts a version's general transfer rules for a related page.

  Delegates to `GtfsPlanner.Gtfs.Transfers.count_general/3` directly, not through
  `CatalogReadAdapter` (spec Design decisions: only the page's catalog load uses the
  adapter). `filter` is `[stop: stop_id]` or `[route: route_id]`; the count shares the
  list's own stop and route predicates, so it equals the matching filtered catalog's
  `total_count` and never covers type 4/5 rows.
  """
  @spec count_general_transfers(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          [stop: String.t()] | [route: String.t()]
        ) :: non_neg_integer()
  def count_general_transfers(organization_id, gtfs_version_id, filter) do
    Transfers.count_general(organization_id, gtfs_version_id, filter)
  end

  @doc """
  Searches a version's selectable stops for the transfer editor.

  Delegates directly to `GtfsPlanner.Gtfs.Transfers.search_stops/3`; only the
  page's catalog load uses `CatalogReadAdapter`. The query matches a
  case-insensitive substring of the stop name, ID or platform code among the stops
  the editor may pick (`location_type` nil, 0 or 1) and returns at most 20 options
  in name then ID order, with `truncated?: true` when more stops match.
  """
  @spec search_transfer_stops(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          %{stops: [Transfers.stop_option()], truncated?: boolean()}
  def search_transfer_stops(organization_id, gtfs_version_id, query) do
    Transfers.search_stops(organization_id, gtfs_version_id, query)
  end

  @doc """
  Resolves one picked stop for the transfer editor's map.

  Delegates directly to `GtfsPlanner.Gtfs.Transfers.fetch_pickable_stop/3`: the ID
  must resolve to a stop of the requested organization and version whose location
  type is nil, 0 or 1. An unknown, foreign or non-selectable stop is `:error`, so a
  picked ID never comes from the payload unchecked.
  """
  @spec fetch_transfer_stop(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Transfers.stop_option()} | :error
  def fetch_transfer_stop(organization_id, gtfs_version_id, stop_id) do
    Transfers.fetch_pickable_stop(organization_id, gtfs_version_id, stop_id)
  end

  @doc """
  Lists the active routes serving a stop's coverage for the transfer editor.

  Delegates directly to `GtfsPlanner.Gtfs.Transfers.route_options/4`, which appends
  the stored route with `:missing`, `:inactive` or `:not_serving` when the options
  do not already offer it.
  """
  @spec transfer_route_options(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil, String.t() | nil) ::
          [Transfers.route_option()]
  def transfer_route_options(organization_id, gtfs_version_id, stop_id, current) do
    Transfers.route_options(organization_id, gtfs_version_id, stop_id, current)
  end

  @doc """
  Lists the trips of one route serving a stop's coverage for the transfer editor.

  Delegates directly to `GtfsPlanner.Gtfs.Transfers.trip_options/6`; `side` is
  `:from` (the earliest arrival) or `:to` (the earliest departure) at the coverage,
  and the stored trip is appended with `:missing`, `:other_route` or `:not_serving`
  when the options do not already offer it.
  """
  @spec transfer_trip_options(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t() | nil,
          String.t() | nil,
          :from | :to,
          String.t() | nil
        ) :: [Transfers.trip_option()]
  def transfer_trip_options(organization_id, gtfs_version_id, route_id, stop_id, side, current) do
    Transfers.trip_options(organization_id, gtfs_version_id, route_id, stop_id, side, current)
  end

  @doc """
  Builds the transfer editor's connection map payload for two endpoints.

  Delegates directly to `GtfsPlanner.Gtfs.Transfers.map_payload/3`. The two stop or
  station IDs come from the draft; each resolves inside the requested organization
  and version to a point with float coordinates, or is nil when it is unknown,
  foreign or has no coordinates. `children` holds the drawable children of a
  station endpoint with their side, and `missing_coordinates` names the endpoints
  of this version that carry none.
  """
  @spec transfer_map_payload(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: Transfers.map_payload()
  def transfer_map_payload(organization_id, gtfs_version_id, endpoints) do
    Transfers.map_payload(organization_id, gtfs_version_id, endpoints)
  end

  @doc """
  Lists the version's drawable stops inside a map viewport.

  Delegates directly to `GtfsPlanner.Gtfs.Transfers.stops_in_bounds/3`. `bounds`
  arrives from the map hook with `south`, `west`, `north` and `east` as numbers or
  numeric strings; latitudes and longitudes are clamped to ±90 and ±180 and an
  invalid box is `{:error, :invalid_bounds}`. At most 200 stops and stations come
  back in name then ID order with `truncated?`, scoped to the organization and
  version.
  """
  @spec transfer_stops_in_bounds(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{stops: [Transfers.map_point()], truncated?: boolean()}}
          | {:error, :invalid_bounds}
  def transfer_stops_in_bounds(organization_id, gtfs_version_id, bounds) do
    Transfers.stops_in_bounds(organization_id, gtfs_version_id, bounds)
  end

  @doc """
  Returns the version's stop bounding box for the map's initial view.

  Delegates directly to `GtfsPlanner.Gtfs.Transfers.version_extent/2`: the minimum
  and maximum latitude and longitude over the organization's and version's stops
  that have both coordinates, or nil when none does.
  """
  @spec transfer_version_extent(Ecto.UUID.t(), Ecto.UUID.t()) ::
          %{south: float(), west: float(), north: float(), east: float()} | nil
  def transfer_version_extent(organization_id, gtfs_version_id) do
    Transfers.version_extent(organization_id, gtfs_version_id)
  end

  @doc """
  Creates one general (types 0–3) transfer rule for the audit context's version.

  Delegates directly to `GtfsPlanner.Gtfs.Transfers.create_general/2`. The
  organization and version come from the context, never from the attributes, so a
  foreign tenant or version in the request is ignored (R10). The references are
  validated against the version inside the write transaction (R2/R4), the row is
  audited with one in-transaction `"transfer"` change log (R9), and a key
  collision is `{:error, {:duplicate, %{id, transfer_type} | nil}}` with `nil`
  when the colliding row was removed in between (R5). Serialization failures and
  deadlocks retry up to three attempts before `:busy` (R8).
  """
  @spec create_general_transfer(map(), AuditContext.t()) ::
          {:ok, Transfer.t()} | {:error, Transfers.write_error()}
  def create_general_transfer(attrs, %AuditContext{} = audit) do
    Transfers.create_general(attrs, audit)
  end

  @doc """
  Changes one existing general (types 0–3) transfer rule through
  `GtfsPlanner.Gtfs.Transfers.update_general/4`.

  The organization and version come from the context (R10). The target is loaded
  through an id-scoped types 0–3 query, so an unknown or malformed ID, another
  version's row and a type 4/5 row are `:not_found` (R1). `expected_updated_at` —
  the stored `DateTime` or its ISO 8601 string — must match the loaded row,
  otherwise `{:error, :stale}` is returned with no write; submitting the row's
  current values returns the row unchanged with no audit log. A real change is
  validated against the version's stops, routes and trips in the write transaction
  (R2/R4) and audited with one `"updated"` `"transfer"` change log carrying the
  before and after snapshots (R9). A key collision is
  `{:error, {:duplicate, %{id, transfer_type} | nil}}` (R5), and serialization
  failures and deadlocks retry up to three attempts before `:busy` (R8).
  """
  @spec update_general_transfer(
          Ecto.UUID.t(),
          map(),
          DateTime.t() | String.t() | nil,
          AuditContext.t()
        ) :: {:ok, Transfer.t()} | {:error, Transfers.write_error()}
  def update_general_transfer(id, attrs, expected_updated_at, %AuditContext{} = audit) do
    Transfers.update_general(id, attrs, expected_updated_at, audit)
  end

  @doc """
  Deletes one existing general (types 0–3) transfer rule through
  `GtfsPlanner.Gtfs.Transfers.delete_general/3`.

  The organization and version come from the context (R10). The target is loaded
  through an id-scoped types 0–3 query, so an unknown or malformed ID, another
  version's or organization's row and a type 4/5 row are `:not_found` (R1).
  `expected_updated_at` — the stored `DateTime` or its ISO 8601 string — must match
  the loaded row, otherwise `{:error, :stale}` is returned with no delete (R8).
  Deletion checks scope, type and freshness only and never validates references, so
  a damaged imported row stays deletable; it is audited with one in-transaction
  `"deleted"` `"transfer"` change log carrying its stored snapshot as `before` and
  nil as `after` (R9). Serialization failures and deadlocks retry up to three
  attempts before `:busy` (R8).
  """
  @spec delete_general_transfer(
          Ecto.UUID.t(),
          DateTime.t() | String.t() | nil,
          AuditContext.t()
        ) :: {:ok, Transfer.t()} | {:error, :not_found | :stale | :busy}
  def delete_general_transfer(id, expected_updated_at, %AuditContext{} = audit) do
    Transfers.delete_general(id, expected_updated_at, audit)
  end

  @doc """
  Deletes several general (types 0–3) transfer rules through
  `GtfsPlanner.Gtfs.Transfers.delete_general_many/2`.

  `pairs` is the exact list of `{id, updated_at}` pairs the editor's checked rows
  resolve to; a list filter, search, sort or page never defines this scope (R8). An
  empty list or a malformed element is `{:error, :invalid_input}`. The organization
  and version come from the context (R10); every target is loaded through one query
  scoped to them and to `transfer_type in 0..3`, so a missing, foreign, other-version
  or type 4/5 id makes the whole request `:not_found` and one stale member makes it
  `:stale`, both with nothing deleted (R1/R8). Otherwise the rows are deleted and
  each is audited with one in-transaction `"deleted"` `"transfer"` change log
  sharing one `operation_id` and listing every affected id, so the batch is
  all-or-nothing (R9). Returns `{:ok, count}`. Serialization failures and deadlocks
  retry up to three attempts before `:busy` (R8).
  """
  @spec delete_general_transfers([{Ecto.UUID.t(), DateTime.t() | String.t()}], AuditContext.t()) ::
          {:ok, pos_integer()} | {:error, :invalid_input | :not_found | :stale | :busy}
  def delete_general_transfers(pairs, %AuditContext{} = audit) do
    Transfers.delete_general_many(pairs, audit)
  end

  @doc """
  Loads one coherent calendar screen snapshot through the configured catalog read adapter.

  The snapshot carries every calendar row with its exceptions, derived periods and
  grouped route usage, together with the single agency-local `today` and its `zone`
  resolution, the global `horizon` and the version-wide service `gaps`. `opts` may
  carry `:sort_by`/`:sort_dir`, and `:service_ids` limits only the returned `:rows`;
  the global horizon and gaps are computed over the whole version before any filter.
  A version holding a retained reversed weekly range reports `complete?: false` with
  `:invalid_calendars` populated and `gaps: nil` rather than an asserted complete gap
  set. A foreign, invalid or unpublished scope is `{:error, :not_found}` and a lost
  database connection is `{:error, :unavailable}`.
  """
  @spec load_calendar_screen(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Calendars.screen()} | {:error, :not_found | :unavailable}
  def load_calendar_screen(organization_id, gtfs_version_id, opts \\ []) do
    catalog_read_adapter().load_calendar_screen(organization_id, gtfs_version_id, opts)
  end

  @doc """
  Fetches one calendar identity through the configured catalog read adapter.

  Returns the weekly row (or `nil`), the metadata anchor (or `nil`), the sorted
  exceptions and the source fingerprint used for reviewed commands. An unknown or
  foreign service ID is `{:error, :not_found}`; a lost database connection is
  `{:error, :unavailable}`.
  """
  @spec fetch_calendar(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Calendars.payload()} | {:error, :not_found | :unavailable}
  def fetch_calendar(organization_id, gtfs_version_id, service_id) do
    catalog_read_adapter().fetch_calendar(organization_id, gtfs_version_id, service_id)
  end

  @doc """
  Loads one route's scoped Schedules read through the configured catalog read adapter.

  The read canonicalizes the requested calendar, direction, pattern and stops
  filters against the published scope, then returns the route, the version's
  calendars with this route's trip counts, the route's patterns with their
  timings, the sections built from the stored stop times, the planning summary
  and the direction labels. A foreign, invalid or unpublished scope is
  `{:error, :not_found}`; a lost database connection is `{:error, :unavailable}`.
  """
  @spec load_route_schedule(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), Schedules.filters()) ::
          {:ok, Schedules.schedule()} | {:error, :not_found | :unavailable}
  def load_route_schedule(organization_id, gtfs_version_id, route_id, filters) do
    catalog_read_adapter().load_route_schedule(
      organization_id,
      gtfs_version_id,
      route_id,
      filters
    )
  end

  @doc """
  Expands a departure series for the Add trips preview through `Schedules`.

  Without a repeat this is the single departure `[start_secs]`; with an interval it
  is every `start + k * every` departure at or before `until_secs`, bounded to the
  maximum series size. The drawer preview and `create_trips/3` share this function,
  so what staff see is what the write stores.
  """
  @spec series_starts(non_neg_integer(), pos_integer() | nil, non_neg_integer() | nil) ::
          {:ok, [non_neg_integer()]}
          | {:error, :invalid_interval | :until_before_start | :too_many_trips}
  def series_starts(start_secs, every_minutes, until_secs) do
    Schedules.series_starts(start_secs, every_minutes, until_secs)
  end

  @doc """
  Creates one departure or a bounded series of trips on one of a route's patterns.

  `attrs` carries `:pattern_id`, `:timed_pattern_id`, `:service_id`, `:start_time`
  and an optional `:repeat` (`%{every_minutes: pos_integer(), until: clock}`). The
  write takes the version, route and pattern locks in the rule-table order,
  materializes each stop time from the timing through spec 01's `Materializer`, and
  writes one `"trip"` audit log per created trip in the same transaction. An
  invalid series or scope is refused before or without any write.
  """
  @spec create_trips(String.t(), Schedules.create_attrs(), AuditContext.t()) ::
          {:ok, %{trips: [GtfsPlanner.Gtfs.Trip.t()]}}
          | {:error, Ecto.Changeset.t() | Schedules.create_error()}
  def create_trips(route_id, attrs, %AuditContext{} = audit_context)
      when is_map(attrs) do
    Schedules.create_trips(route_id, attrs, audit_context)
  end

  def create_trips(_route_id, _attrs, _audit_context), do: {:error, :invalid_input}

  @doc """
  Edits one trip in place through `Schedules.update_trip/5`.

  `attrs` is a subset of `:start_time`, `:timed_pattern_id`, `:service_id`,
  `:trip_headsign`, `:trip_short_name`, `:wheelchair_accessible` and
  `:bikes_allowed`. Block membership is read-only in Schedules and changes on the
  Blocks page, so `:block_id` is ignored. `expected_updated_at` must match the
  stored trip, otherwise `{:error, :stale}` is returned with no write. A frequency
  trip refuses a start or timing change with `:frequency_trip`, a linked trip
  re-materializes its stop times in place against a timing of its own pattern, and
  a custom trip adopts a timing only when its ordered stops and direction match or
  returns `:stops_differ`. The trip ID never changes.
  """
  @spec update_trip(
          String.t(),
          Ecto.UUID.t(),
          Schedules.update_attrs(),
          DateTime.t() | String.t() | nil,
          AuditContext.t()
        ) ::
          {:ok, GtfsPlanner.Gtfs.Trip.t()}
          | {:error, Ecto.Changeset.t() | Schedules.update_error()}
  def update_trip(route_id, trip_id, attrs, expected_updated_at, %AuditContext{} = audit_context)
      when is_map(attrs) do
    Schedules.update_trip(route_id, trip_id, attrs, expected_updated_at, audit_context)
  end

  def update_trip(_route_id, _trip_id, _attrs, _expected_updated_at, _audit_context),
    do: {:error, :invalid_input}

  @doc """
  Duplicates one trip through `Schedules.duplicate_trip/4`.

  The new trip lands on the source trip's pattern at the submitted start and
  timing, copies the source's service and rider-facing metadata with a fresh
  allocated trip ID and newly materialized stop times, and is audited as created.
  A frequency source returns `{:error, :frequency_trip}` with no write.
  """
  @spec duplicate_trip(String.t(), Ecto.UUID.t(), Schedules.duplicate_attrs(), AuditContext.t()) ::
          {:ok, GtfsPlanner.Gtfs.Trip.t()}
          | {:error, Ecto.Changeset.t() | Schedules.update_error()}
  def duplicate_trip(route_id, trip_id, attrs, %AuditContext{} = audit_context)
      when is_map(attrs) do
    Schedules.duplicate_trip(route_id, trip_id, attrs, audit_context)
  end

  def duplicate_trip(_route_id, _trip_id, _attrs, _audit_context), do: {:error, :invalid_input}

  @doc """
  Deletes a whole list of trips on one calendar through `Schedules.delete_trips/4`.

  The list is validated in full before anything is deleted: a trip outside this
  organization, version or route returns `{:error, :not_found}` and a trip on
  another calendar returns `{:error, :stale}`, either with no writes. Otherwise
  the trips' stop times, frequencies and trip-scoped transfers are removed before
  the trips in one transaction, and `%{trips: ..., transfers: ...}` reports the
  number of deleted trips and removed transfers, with one shared-operation audit
  log per trip.
  """
  @spec delete_trips(String.t(), String.t() | nil, [Ecto.UUID.t()], AuditContext.t()) ::
          {:ok, Schedules.delete_result()} | {:error, Schedules.delete_error()}
  def delete_trips(route_id, service_id, trip_ids, %AuditContext{} = audit_context)
      when is_list(trip_ids) do
    Schedules.delete_trips(route_id, service_id, trip_ids, audit_context)
  end

  def delete_trips(_route_id, _service_id, _trip_ids, _audit_context),
    do: {:error, :invalid_input}

  @doc """
  Counts the transfers of one organization and version that name any of `trip_ids`.

  `trip_ids` are natural `trips.trip_id` values. See
  `Schedules.count_trip_transfers/3`.
  """
  @spec count_trip_transfers(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: non_neg_integer()
  def count_trip_transfers(organization_id, gtfs_version_id, trip_ids) do
    Schedules.count_trip_transfers(organization_id, gtfs_version_id, trip_ids)
  end

  @doc """
  Loads the independent station-detail regions (child stops, levels, pathways,
  and editing status) for a fetched station through the configured catalog read
  adapter.

  Each region resolves independently, so a failure in one region is reported as
  `{:error, :unavailable}` for that key without discarding the others.

  ## Examples

      iex> load_catalog_stop_regions(organization_id, gtfs_version_id, station)
      %{child_stops: {:ok, [%Stop{}]}, levels: {:ok, []}, pathways: {:ok, []}, editing_status: {:ok, nil}}
  """
  @spec load_catalog_stop_regions(Ecto.UUID.t(), Ecto.UUID.t(), Stop.t()) :: %{
          child_stops: CatalogReadAdapter.stop_region([Stop.t()]),
          levels: CatalogReadAdapter.stop_region(list()),
          pathways: CatalogReadAdapter.stop_region(list()),
          editing_status: CatalogReadAdapter.stop_region(struct() | nil)
        }
  def load_catalog_stop_regions(organization_id, gtfs_version_id, %Stop{} = station) do
    catalog_read_adapter().load_stop_regions(organization_id, gtfs_version_id, station)
  end

  @doc """
  Loads the Fare zones workspace's inventory, checks and first stop page through
  the configured catalog read adapter.

  The workspace's three tabs read the same load, and a lost database connection
  is reported once as `{:error, :unavailable}` so the page can offer its reload
  action instead of blanking data already on screen. `:filter`, `:q` and `:page`
  select the stop page the Zones tab lists.
  """
  @spec load_fare_workspace(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, CatalogReadAdapter.fare_workspace()} | CatalogReadAdapter.unavailable()
  def load_fare_workspace(organization_id, gtfs_version_id, opts) do
    catalog_read_adapter().load_fare_workspace(organization_id, gtfs_version_id, opts)
  end

  @doc """
  Loads the version's flex services list through the configured catalog read
  adapter.

  The load carries everything the list renders: every service with its readiness
  checks (`Flex.Checks.run/3`), the version's calendars map for the rider text
  (`Flex.calendars_map/2`), whether the version has any fixed route (R15's
  only-feed state) and the organization's `include_flex` switch. A lost database
  connection is reported once as `{:error, :unavailable}` so the page can offer
  its retry action rather than presenting an empty list as the version's data.
  """
  @spec load_flex_list(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, CatalogReadAdapter.flex_list()} | CatalogReadAdapter.unavailable()
  def load_flex_list(organization_id, gtfs_version_id) do
    catalog_read_adapter().load_flex_list(organization_id, gtfs_version_id)
  end

  @spec resolve_station_journal_scope(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Scope.t()} | {:error, :not_found | :invalid_id}
  def resolve_station_journal_scope(organization_id, gtfs_version_id, station_id, actor_id),
    do: StationJournal.resolve_scope(organization_id, gtfs_version_id, station_id, actor_id)

  @spec sync_journal_entries(Scope.t(), [map()]) :: %{
          synced_count: non_neg_integer(),
          errors: [map()]
        }
  def sync_journal_entries(%Scope{} = scope, entries),
    do: StationJournal.sync_entries(scope, entries)

  @spec list_station_journal(Scope.t(), keyword()) :: [JournalEntry.t()]
  @doc """
  Returns a list of journal entries for the given scope.

  ## Options
    * `:status` - `:all` (default) or `:open` to filter by closure state
    * `:order` - `:asc` (default) or `:desc` for entry sort direction
    * `:limit` - positive integer or `nil` (default) to cap returned entries
    * `:target` - `{"node", uuid}` or `{"pathway", uuid}` to filter by exact
      target type and target ID; `nil` (default) returns all target types

  Raises `ArgumentError` for unknown options, invalid values, or malformed
  target tuples.
  """
  def list_station_journal(%Scope{} = scope, opts \\ []),
    do: StationJournal.list_entries(scope, opts)

  @spec close_journal_entry(Scope.t(), Ecto.UUID.t()) ::
          {:ok, JournalEntry.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def close_journal_entry(%Scope{} = scope, entry_id),
    do: StationJournal.close_entry(scope, entry_id)

  @spec reopen_journal_entry(Scope.t(), Ecto.UUID.t()) ::
          {:ok, JournalEntry.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def reopen_journal_entry(%Scope{} = scope, entry_id),
    do: StationJournal.reopen_entry(scope, entry_id)

  @spec subscribe_station_journal(Scope.t()) :: :ok | {:error, term()}
  def subscribe_station_journal(%Scope{} = scope),
    do: StationJournal.subscribe(scope)

  @spec create_journal_photo(
          Scope.t(),
          map(),
          %{path: String.t(), filename: String.t(), content_type: String.t() | nil}
        ) :: {:ok, GtfsPlanner.Gtfs.JournalPhoto.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_journal_photo(%Scope{} = scope, attrs, upload),
    do: StationJournal.create_photo(scope, attrs, upload)

  @spec refresh_pin_coordinates_for_stop_level(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh_pin_coordinates_for_stop_level(%StopLevel{} = stop_level, image_w, image_h),
    do: StationJournal.refresh_pin_coordinates_for_stop_level(stop_level, image_w, image_h)

  @doc """
  Normalizes a route status filter to its canonical URL presentation.

  Only explicit `false` is inactive (R4/INV-4): `"true"` selects effectively
  active routes (`active` true or `NULL`), `"false"` selects inactive routes,
  and every other value means no status filter. `list_routes/3`,
  `count_routes/3` and the routes list presentation share this mapping so the
  status filters and their counts cannot disagree.

  ## Examples

      iex> normalize_route_status_filter("true")
      "true"

      iex> normalize_route_status_filter("other")
      ""
  """
  @spec normalize_route_status_filter(term()) :: String.t()
  def normalize_route_status_filter("true"), do: "true"
  def normalize_route_status_filter("false"), do: "false"
  def normalize_route_status_filter(_), do: ""

  @doc """
  Returns the list of routes for an organization and GTFS version.

  Accepts optional filters, search, sort, and pagination via opts keyword list.

  ## Examples

      iex> list_routes(organization_id, gtfs_version_id)
      [%Route{}, ...]

      iex> list_routes(organization_id, gtfs_version_id, route_type: 3, search: "express")
      [%Route{}, ...]
  """
  def list_routes(organization_id, gtfs_version_id, opts \\ []) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
    |> maybe_filter_type(opts[:route_type])
    |> maybe_filter_agency(opts[:agency_id])
    |> maybe_filter_active(opts[:active])
    |> maybe_search(opts[:search])
    |> apply_sort(opts[:sort_by], opts[:sort_dir])
    |> paginate(opts[:page], opts[:per_page])
    |> Repo.all()
  end

  @doc """
  Returns the count of routes for an organization and GTFS version.

  Accepts optional filters via opts keyword list.

  ## Examples

      iex> count_routes(organization_id, gtfs_version_id)
      42

      iex> count_routes(organization_id, gtfs_version_id, route_type: 3)
      15
  """
  def count_routes(organization_id, gtfs_version_id, opts \\ []) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
    |> maybe_filter_type(opts[:route_type])
    |> maybe_filter_agency(opts[:agency_id])
    |> maybe_filter_active(opts[:active])
    |> maybe_search(opts[:search])
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a single route.

  Raises `Ecto.NoResultsError` if the Route does not exist.

  ## Examples

      iex> get_route!(id)
      %Route{}

      iex> get_route!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_route!(id), do: Repo.get!(Route, id)

  @doc """
  Gets a route by its route_id within an organization and GTFS version.

  Returns nil if the route does not exist.

  ## Examples

      iex> get_route_by_route_id(organization_id, gtfs_version_id, "R1")
      %Route{}

      iex> get_route_by_route_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_route_by_route_id(organization_id, gtfs_version_id, route_id) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.route_id == ^route_id
    )
    |> Repo.one()
  end

  @doc """
  Creates a route.

  ## Examples

      iex> create_route(%{organization_id: org_id, gtfs_version_id: version_id, route_id: "R1", route_type: 3, route_short_name: "1"})
      {:ok, %Route{}}

      iex> create_route(%{route_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_route(attrs \\ %{}) do
    %Route{}
    |> Route.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a route in a GTFS version, resolving its agency under the version row lock (R4,
  INV-1).

  `organization_id` and `gtfs_version_id` scope the insert and are never taken from
  `attrs`; `attrs` carry the route fields and may name an `agency_id`, as a string or atom
  key. One transaction share-locks the published version row and resolves the agency
  through `GtfsPlanner.Gtfs.FeedSettings.lock_agency_for_reference!/3`, so the insert
  serializes against an agency deletion, creation or timezone change for the same version
  (INV-2, AC-26) and a route can never commit against an agency that no longer exists.

  ## Returns

  - `{:ok, %Route{}}` with the resolved `agency_id`
  - `{:error, %Ecto.Changeset{}}` for attrs the route changeset refuses
  - `{:error, :not_found}` when the scope is not a published version of the organization
  - `{:error, :agency_required}` when the version has no agency
  - `{:error, :agency_not_found}` when the choice is not one of the version's agencies

  ## Examples

      iex> create_version_route(org_id, version_id, %{route_id: "R1", route_type: 3, route_short_name: "1"})
      {:ok, %Route{}}
  """
  @spec create_version_route(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, Route.t()}
          | {:error, Ecto.Changeset.t() | :not_found | :agency_required | :agency_not_found}
  def create_version_route(organization_id, gtfs_version_id, attrs) when is_map(attrs) do
    # String keys, so the scope and the resolved agency override any key form the caller
    # sent and the changeset reads one shape.
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Repo.transaction(fn ->
      agency_id =
        FeedSettings.lock_agency_for_reference!(
          organization_id,
          gtfs_version_id,
          attrs["agency_id"]
        )

      attrs
      |> Map.merge(%{
        "organization_id" => organization_id,
        "gtfs_version_id" => gtfs_version_id,
        "agency_id" => agency_id
      })
      |> then(&Route.changeset(%Route{}, &1))
      |> Repo.insert()
      |> case do
        {:ok, route} -> route
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Reads the version-scoped agency options and mode counts the create drawer
  presents (R3, R2).

  See `GtfsPlanner.Gtfs.Routes.route_creation_options/2`: the same scoped reads
  the route editor read model builds, so the drawer and Route > Details cannot
  disagree about the version's agencies or modes.
  """
  @spec route_creation_options(Ecto.UUID.t(), Ecto.UUID.t()) :: %{
          agencies: [map()],
          mode_counts: [map()]
        }
  def route_creation_options(organization_id, gtfs_version_id),
    do: Routes.route_creation_options(organization_id, gtfs_version_id)

  @doc """
  Previews the route identifier the create command would allocate (R3).

  See `GtfsPlanner.Gtfs.Routes.suggest_route_id/3` for the inference and its
  duplicate result. The preview never establishes persisted truth: the command
  re-allocates under the published-version write lock.
  """
  @spec suggest_route_id(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, :duplicate_route_id}
  def suggest_route_id(organization_id, gtfs_version_id, attrs),
    do: Routes.suggest_route_id(organization_id, gtfs_version_id, attrs)

  @doc """
  Creates one editor route for a verified creation attempt with audit-backed
  replay protection (R3).

  See `GtfsPlanner.Gtfs.Routes.create_editor_route/3` for the attempt contract
  and error surface. The public facade signature is the seam-`S-2` contract:
  the insert stays inside `Routes.create_editor_route/3` until package 13's
  `Gtfs.create_version_route/3` lands.
  """
  @spec create_editor_route(map(), map(), AuditContext.t()) :: {:ok, map()} | {:error, term()}
  def create_editor_route(attrs, attempt, %AuditContext{} = audit_context),
    do: Routes.create_editor_route(attrs, attempt, audit_context)

  @doc """
  Reports a creation attempt's committed result without inserting (R3).

  See `GtfsPlanner.Gtfs.Routes.reconcile_creation/2` for the attempt contract
  and error surface.
  """
  @spec reconcile_creation(map(), AuditContext.t()) ::
          {:ok, Route.t()} | {:error, :not_started | :attempt_consumed | :forbidden | :not_found}
  def reconcile_creation(attempt, %AuditContext{} = audit_context),
    do: Routes.reconcile_creation(attempt, audit_context)

  @doc """
  Applies reviewed route detail edits (R4).

  See `GtfsPlanner.Gtfs.Routes.update_route/5` for the comparison, merge and
  error contract. The command reauthorizes inside its transaction, takes the
  scoped published-version lock before the route lock, validates only the
  accepted combined result and writes the changed fields together with their
  route audit.
  """
  @spec update_route(String.t(), map(), map(), map(), AuditContext.t()) ::
          {:ok, map()} | {:error, term()}
  def update_route(route_id, attrs, source, choices, %AuditContext{} = audit_context),
    do: Routes.update_route(route_id, attrs, source, choices, audit_context)

  @doc """
  Changes route eligibility (R4 status command).

  See `GtfsPlanner.Gtfs.Routes.set_route_active/4` for the status and error
  contract. The command is separate from detail params: it reauthorizes inside
  its serializable transaction, locks the scoped published version before the
  route row, requires the exact saved UUID/revision for a real state change and
  writes the boolean state together with its transactional route audit. A
  desired state that is already effective is a no-op and never backfills NULL.
  """
  @spec set_route_active(String.t(), boolean(), map(), AuditContext.t()) ::
          {:ok, map()} | {:error, term()}
  def set_route_active(route_id, active, source, %AuditContext{} = audit_context),
    do: Routes.set_route_active(route_id, active, source, audit_context)

  @doc """
  Projects a persisted route row into the trusted edit source (R2).

  The status command's saved identity is built from the loaded route row with
  the same projection the editor workspace uses, so a route tab that holds only
  its scoped read still submits a source the command can recheck (exact UUID,
  scope and revision for a real change; stale or replaced rows refuse).
  """
  @spec route_source(map()) :: map()
  def route_source(%Route{} = route), do: Routes.source(route)

  @doc """
  Builds the complete reviewed route deletion impact summary (R5).

  See `GtfsPlanner.Gtfs.Routes.review_route_deletion/2` for the review,
  category, retained-resource and error contract. The review enumerates only
  the categories computable from landed rows (seam `S-3`): imported and
  unowned shapes are named as retained, and malformed cross-route timing
  ownership blocks the review before any apply decision.
  """
  @spec review_route_deletion(String.t(), AuditContext.t()) :: {:ok, map()} | {:error, term()}
  def review_route_deletion(route_id, %AuditContext{} = audit_context),
    do: Routes.review_route_deletion(route_id, audit_context)

  @doc """
  Applies the reviewed route deletion cascade (R5).

  See `GtfsPlanner.Gtfs.Routes.delete_route/4` for the fingerprint,
  acknowledgement, cascade, checked-summary and error contract. The reviewed
  cascade covers only categories computable from landed rows (seam `S-3`):
  imported and unowned shapes and other shared records are retained, and
  alignment-owned geometry cleanup joins when package 12 lands.
  """
  @spec delete_route(String.t(), String.t(), boolean(), AuditContext.t()) ::
          {:ok, map()} | {:error, term()}
  def delete_route(route_id, review_fingerprint, acknowledged, %AuditContext{} = audit_context),
    do: Routes.delete_route(route_id, review_fingerprint, acknowledged, audit_context)

  @doc """
  Compares a retained deletion review with a fresh one (R5/AC-13).

  See `GtfsPlanner.Gtfs.Routes.deletion_review_changes/2` for the marker
  contract: one entry per changed category, each carrying the stable
  `:count_changed` and `:contents_changed` markers, so a stale apply is
  explained even when the totals are equal.
  """
  @spec deletion_review_changes([map()], [map()]) ::
          [%{key: String.t(), label: String.t(), markers: [atom()]}]
  def deletion_review_changes(previous_categories, categories),
    do: Routes.deletion_review_changes(previous_categories, categories)

  @doc """
  Returns a list of distinct route types for an organization and GTFS version.

  ## Examples

      iex> list_distinct_route_types(organization_id, gtfs_version_id)
      [0, 1, 3]
  """
  def list_distinct_route_types(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      distinct: true,
      select: r.route_type,
      order_by: r.route_type
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of distinct agency IDs for an organization and GTFS version.

  ## Examples

      iex> list_distinct_agencies(organization_id, gtfs_version_id)
      ["agency1", "agency2"]
  """
  def list_distinct_agencies(organization_id, gtfs_version_id) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          not is_nil(r.agency_id),
      distinct: true,
      select: r.agency_id,
      order_by: r.agency_id
    )
    |> Repo.all()
  end

  @doc """
  Searches the version's eligible stops for the pattern editor.

  Returns at most 20 stops or platforms (`location_type` nil/0) ordered by name
  then ID through the configured catalog read adapter, with a `truncated?` flag
  when more matches exist. A lost database connection is `{:error, :unavailable}`.
  """
  @spec search_pattern_stops(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, %{stops: [GtfsPlanner.Gtfs.Stop.t()], truncated?: boolean()}}
          | {:error, :unavailable}
  def search_pattern_stops(organization_id, gtfs_version_id, query) do
    catalog_read_adapter().search_stops(organization_id, gtfs_version_id, query)
  end

  @doc """
  Returns the read-only proposal for a staged stop edit without requiring
  acknowledgement, so the editor can show every timing's proposed values before
  staff acknowledge them. Writes nothing.
  """
  def preview_stop_edit(pattern_id, operation, %AuditContext{} = audit_context),
    do: RoutePatterns.preview_stop_edit(pattern_id, operation, audit_context)

  @doc """
  Returns the list of route patterns for a specific route.

  ## Examples

      iex> list_route_patterns_for_route(organization_id, gtfs_version_id, route_id)
      [%RoutePattern{}, ...]
  """
  def list_route_patterns_for_route(organization_id, gtfs_version_id, route_id) do
    from(rp in RoutePattern,
      where:
        rp.organization_id == ^organization_id and rp.gtfs_version_id == ^gtfs_version_id and
          rp.route_id == ^route_id,
      order_by: [asc: rp.direction_id, asc: rp.route_pattern_sort_order]
    )
    |> Repo.all()
  end

  @doc "Returns the scoped editable patterns for a published route."
  def list_patterns(organization_id, gtfs_version_id, route_id),
    do: RoutePatterns.list_patterns(organization_id, gtfs_version_id, route_id)

  @doc "Loads one editable pattern and an optional timing in its route scope."
  def get_pattern(organization_id, gtfs_version_id, route_id, pattern_id, timing_id \\ nil),
    do:
      RoutePatterns.get_pattern(organization_id, gtfs_version_id, route_id, pattern_id, timing_id)

  @doc "Loads the alignment editor read model for one pattern in its published route scope."
  def alignment_editor(organization_id, gtfs_version_id, route_id, route_pattern_id),
    do: Alignments.editor(organization_id, gtfs_version_id, route_id, route_pattern_id)

  @doc "Summarizes every pattern's alignment status for a route with a constant number of queries."
  def route_alignment_summary(organization_id, gtfs_version_id, route_id),
    do: Alignments.route_summary(organization_id, gtfs_version_id, route_id)

  @doc "Suggests street-routed interior points for the given alignment sections without writing."
  def suggest_alignment_paths(
        organization_id,
        gtfs_version_id,
        route_id,
        route_pattern_id,
        positions
      ),
      do:
        Alignments.suggest_paths(
          organization_id,
          gtfs_version_id,
          route_id,
          route_pattern_id,
          positions
        )

  @doc "Routes one street leg between two `[lon, lat]` endpoints without writing."
  def suggest_alignment_between(from, to),
    do: Alignments.suggest_between(from, to)

  @doc "Suggests street-routed interior points for every missing section of the given patterns without writing."
  def suggest_missing_alignments(
        organization_id,
        gtfs_version_id,
        route_id,
        route_pattern_ids
      ),
      do:
        Alignments.suggest_missing(organization_id, gtfs_version_id, route_id, route_pattern_ids)

  @doc "Reviews an alignment save, computing scope actions, affected patterns and a fingerprint without writing."
  def review_alignment_save(pattern_id, draft_params, %AuditContext{} = audit_context),
    do: Alignments.review_save(pattern_id, draft_params, audit_context)

  @doc "Applies a reviewed alignment save transactionally, re-verifying the review fingerprint and scope choices."
  def apply_alignment_save(
        pattern_id,
        draft_params,
        choices,
        fingerprint,
        %AuditContext{} = audit_context
      ),
      do: Alignments.apply_save(pattern_id, draft_params, choices, fingerprint, audit_context)

  @doc "Creates a pattern, its ordered occurrences, an unassigned Timing A and one audit row."
  def create_pattern(route_id, attrs, %AuditContext{} = audit_context),
    do: RoutePatterns.create_pattern(route_id, attrs, audit_context)

  @doc "Reviews an audit-only pattern or timing lifecycle command."
  def review(pattern_id, operation, source_fingerprint, %AuditContext{} = audit_context),
    do: RoutePatterns.review(pattern_id, operation, source_fingerprint, audit_context)

  @doc "Applies a previously reviewed pattern or timing lifecycle command."
  def apply_review(pattern_id, operation, fingerprint, %AuditContext{} = audit_context),
    do: RoutePatterns.apply_review(pattern_id, operation, fingerprint, audit_context)

  @doc """
  Builds or retries derived route patterns for one published route as an
  authorized editor.

  Runs derivation inside the route transaction and records one actor-bound
  `route_pattern_build` summary there. A route with no pending trips is refused:
  custom classification alone is not retryable.
  """
  def build_route_patterns(route_id, %AuditContext{} = audit_context) when is_binary(route_id) do
    organization_id = audit_context.organization_id
    version_id = audit_context.gtfs_version_id

    if Derivation.pending_trip_count(organization_id, version_id, route_id) == 0 do
      {:error, :nothing_pending}
    else
      Derivation.derive_route(organization_id, version_id, route_id, {:editor, audit_context})
    end
  end

  def build_route_patterns(_route_id, _audit_context), do: {:error, :invalid_input}

  @doc """
  Returns the count of levels for an organization and GTFS version.
  """
  def count_levels(organization_id, gtfs_version_id) do
    from(l in Level,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of levels for an organization and GTFS version.

  ## Examples

      iex> list_levels(organization_id, gtfs_version_id)
      [%Level{}, ...]
  """
  def list_levels(organization_id, gtfs_version_id) do
    from(l in Level,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: l.level_index]
    )
    |> Repo.all()
  end

  @doc """
  Returns all levels for organization and GTFS version.
  """
  def list_all_levels(organization_id, gtfs_version_id) do
    from(l in Level,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: l.level_index]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single level.

  Returns nil if the Level does not exist.

  ## Examples

      iex> get_level(id)
      %Level{}

      iex> get_level(Ecto.UUID.generate())
      nil
  """
  def get_level(id), do: Repo.get(Level, id)

  @doc """
  Gets a single level.

  Raises `Ecto.NoResultsError` if the Level does not exist.

  ## Examples

      iex> get_level!(id)
      %Level{}

      iex> get_level!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_level!(id), do: Repo.get!(Level, id)

  @doc """
  Gets a level by its level_id within an organization and GTFS version.

  Returns nil if the level does not exist.

  ## Examples

      iex> get_level_by_level_id(organization_id, gtfs_version_id, "L1")
      %Level{}

      iex> get_level_by_level_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_level_by_level_id(organization_id, gtfs_version_id, level_id) do
    from(l in Level,
      where:
        l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id and
          l.level_id == ^level_id
    )
    |> Repo.one()
  end

  @doc """
  Creates a level.

  ## Examples

      iex> create_level(%{organization_id: org_id, gtfs_version_id: version_id, level_id: "L1", level_index: 0.0})
      {:ok, %Level{}}

      iex> create_level(%{level_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_level(attrs \\ %{}) do
    %Level{}
    |> Level.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:levels, :created])
  end

  @doc """
  Updates a level.

  ## Examples

      iex> update_level(level, %{level_name: "Ground Floor"})
      {:ok, %Level{}}

      iex> update_level(level, %{level_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_level(%Level{} = level, attrs) do
    level
    |> Level.changeset(attrs)
    |> Repo.update()
    |> broadcast([:levels, :updated])
  end

  @doc """
  Updates a level, cascading level_id changes to all referencing entities
  within the same organization and GTFS version.

  When level_id is unchanged, delegates to update_level/2.
  """
  def update_level_with_cascade(%Level{} = level, attrs) do
    new_level_id = attrs[:level_id] || attrs["level_id"]

    if new_level_id == level.level_id or is_nil(new_level_id) do
      update_level(level, attrs)
    else
      mapping = %{level.level_id => new_level_id}
      now = DateTime.utc_now()

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:update_level, fn _repo, _changes ->
          level
          |> Level.changeset(attrs)
          |> Repo.update()
        end)
        |> Ecto.Multi.run(:cascade_references, fn repo, _changes ->
          {:ok,
           update_level_id_references(
             repo,
             mapping,
             level.organization_id,
             level.gtfs_version_id,
             now
           )}
        end)

      case Repo.transaction(multi) do
        {:ok, %{update_level: updated_level}} ->
          broadcast({:ok, updated_level}, [:levels, :updated])

        {:error, :update_level, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes a stop_level association.
  """
  def delete_stop_level(%StopLevel{} = stop_level) do
    Repo.delete(stop_level)
    |> broadcast([:stop_levels, :deleted])
  end

  @doc """
  Updates a stop_level's diagram filename.
  """
  def update_stop_level_diagram(%StopLevel{} = stop_level, filename) do
    stop_level
    |> StopLevel.changeset(%{
      diagram_filename: filename,
      scale_point_a: nil,
      scale_point_b: nil,
      scale_distance_meters: nil,
      scale_meters_per_unit: nil
    })
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Updates a stop_level's diagram calibration.
  """
  def update_stop_level_scale(%StopLevel{} = stop_level, attrs) do
    stop_level
    |> StopLevel.scale_changeset(attrs)
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Updates a stop_level's floorplan alignment.
  """
  def update_stop_level_alignment(%StopLevel{} = stop_level, attrs) do
    stop_level
    |> StopLevel.alignment_changeset(attrs)
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Saves a stop_level's floorplan alignment.
  """
  def save_stop_level_alignment(%StopLevel{} = stop_level, attrs) do
    stop_level
    |> StopLevel.alignment_changeset(attrs)
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Clears a stop_level's floorplan alignment.
  """
  def clear_stop_level_alignment(%StopLevel{} = stop_level) do
    update_stop_level_alignment(stop_level, %{
      floorplan_center_lat: nil,
      floorplan_center_lon: nil,
      floorplan_scale_mpp: nil,
      floorplan_rotation_deg: nil
    })
  end

  @doc """
  Derives geographic coordinates for eligible child stops of a station level
  using its saved floorplan alignment.

  Eligible stops are those attached (directly or transitively) to the parent
  station, pinned to the active level, and having a `diagram_coordinate` that
  normalizes via `Coordinates.normalize_point/1`.

  Returns `{:ok, entries}` where each entry is a map with `:stop_id`,
  `:stop_name`, `:lat`, and `:lon`. Returns `{:error, :alignment_missing}` when
  any of the four alignment fields on the stop level are nil,
  `{:error, :invalid_image_dims}` when image dimensions are not positive
  integers, or `{:error, {:transform, reason}}` when the coordinate transform
  rejects an input.

  ## Examples

      iex> derive_child_stop_coords(stop_level, 1024, 768)
      {:ok, [%{stop_id: "...", stop_name: "Platform 1", lat: 40.7128, lon: -74.0060}]}
  """
  @spec derive_child_stop_coords(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok,
           [%{stop_id: Ecto.UUID.t(), stop_name: String.t() | nil, lat: float(), lon: float()}]}
          | {:error, :alignment_missing | :invalid_image_dims | {:transform, atom()}}
  def derive_child_stop_coords(%StopLevel{} = stop_level, image_w, image_h) do
    with {:ok, alignment} <- extract_alignment(stop_level),
         :ok <- validate_positive_image_dims(image_w, image_h) do
      stop_level.stop_id
      |> list_child_stops_for_level(stop_level.level_id)
      |> Enum.filter(& &1.on_active_level)
      |> Enum.reduce_while({:ok, []}, fn stop, {:ok, acc} ->
        case Coordinates.normalize_point(stop.diagram_coordinate) do
          nil ->
            {:cont, {:ok, acc}}

          %{x: x, y: y} ->
            case FloorplanTransform.svg_to_lat_lon(alignment, image_w, image_h, %{x: x, y: y}) do
              {:ok, {lat, lon}} ->
                entry = %{stop_id: stop.id, stop_name: stop.stop_name, lat: lat, lon: lon}
                {:cont, {:ok, [entry | acc]}}

              {:error, reason} ->
                {:halt, {:error, {:transform, reason}}}
            end
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _} = error -> error
      end
    end
  end

  defp extract_alignment(%StopLevel{} = stop_level) do
    case StopLevel.alignment_transform(stop_level) do
      {:ok, alignment} -> {:ok, alignment}
      {:error, :alignment_missing} -> {:error, :alignment_missing}
      {:error, :invalid_alignment} -> {:error, :alignment_missing}
    end
  end

  defp validate_positive_image_dims(w, h)
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: :ok

  defp validate_positive_image_dims(_, _), do: {:error, :invalid_image_dims}

  @type alignment_preview :: %{
          stop_level_id: Ecto.UUID.t(),
          level_id: Ecto.UUID.t(),
          image_width: pos_integer(),
          image_height: pos_integer(),
          proposed_alignment: map(),
          fingerprint: String.t(),
          stop_count: non_neg_integer(),
          rows: [map()]
        }

  @type coordinate_change :: %{
          stop_id: Ecto.UUID.t(),
          stop_external_id: String.t(),
          current: %{lat: Decimal.t() | nil, lon: Decimal.t() | nil},
          proposed: %{lat: float(), lon: float()},
          distance_meters: float() | nil
        }

  @type coordinate_review :: %{
          changes: [coordinate_change()],
          unchanged_count: non_neg_integer(),
          unplaced_count: non_neg_integer(),
          fingerprint: String.t()
        }

  @doc """
  Returns a read-only coordinate review for applying a floorplan alignment to
  the eligible child stops on a stop level.

  The review classifies each eligible stop as changed or unchanged using
  `Decimal.compare/2`, reports unplaced stops on the scoped level, and produces
  a deterministic fingerprint that binds all projection inputs including the
  unplaced count.
  """
  @spec preview_stop_level_alignment(Ecto.UUID.t(), map(), pos_integer(), pos_integer()) ::
          {:ok, coordinate_review()}
          | {:error,
             :not_found
             | :invalid_input
             | :alignment_missing
             | :invalid_image_dims
             | {:transform, atom()}
             | Ecto.Changeset.t()}
  def preview_stop_level_alignment(stop_level_id, proposed_alignment, image_w, image_h)
      when is_binary(stop_level_id) and is_map(proposed_alignment) do
    with {:ok, projection} <-
           build_alignment_projection(stop_level_id, proposed_alignment, image_w, image_h) do
      {:ok,
       %{
         changes: projection.changes,
         unchanged_count: projection.unchanged_count,
         unplaced_count: projection.unplaced_count,
         fingerprint: projection.fingerprint
       }}
    end
  end

  def preview_stop_level_alignment(_, _, _, _), do: {:error, :invalid_input}

  defp build_alignment_projection(
         stop_level_id,
         proposed_alignment,
         image_w,
         image_h,
         options \\ []
       ) do
    with :ok <- validate_positive_image_dims(image_w, image_h),
         %StopLevel{} = stop_level <- Repo.get(StopLevel, stop_level_id),
         {:ok, proposed_stop_level} <- proposed_stop_level(stop_level, proposed_alignment),
         {:ok, rows} <-
           preview_rows(
             proposed_stop_level,
             eligible_child_stops(stop_level, options),
             image_w,
             image_h
           ) do
      unplaced_count = count_unplaced_on_level(stop_level, options)
      normalized_alignment = stop_level_alignment_snapshot(proposed_stop_level)
      {changes, unchanged_count} = classify_projection_rows(rows)

      fingerprint =
        alignment_preview_fingerprint(
          stop_level,
          normalized_alignment,
          image_w,
          image_h,
          rows,
          unplaced_count
        )

      {:ok,
       %{
         stop_level: stop_level,
         proposed_stop_level: proposed_stop_level,
         normalized_alignment: normalized_alignment,
         rows: rows,
         changes: changes,
         unchanged_count: unchanged_count,
         unplaced_count: unplaced_count,
         fingerprint: fingerprint
       }}
    else
      nil -> {:error, :not_found}
      {:error, :invalid_image_dims} = error -> error
      {:error, :alignment_missing} = error -> error
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, _} = error -> error
    end
  end

  defp classify_projection_rows(rows) do
    Enum.reduce(rows, {[], 0}, fn row, {changes, unchanged} ->
      case classify_coordinate_change(row.old_lat, row.old_lon, row.new_lat, row.new_lon) do
        %{changed?: true} = classification ->
          change = %{
            stop_id: row.stop_id,
            stop_external_id: row.stop_code,
            current: %{lat: row.old_lat, lon: row.old_lon},
            proposed: %{lat: row.new_lat, lon: row.new_lon},
            distance_meters: classification.distance_meters
          }

          {[change | changes], unchanged}

        %{changed?: false} ->
          {changes, unchanged + 1}
      end
    end)
    |> then(fn {changes, unchanged} -> {Enum.reverse(changes), unchanged} end)
  end

  defp classify_coordinate_change(old_lat, old_lon, new_lat, new_lon) do
    lat_changed? = axis_changed?(old_lat, new_lat)
    lon_changed? = axis_changed?(old_lon, new_lon)

    distance =
      if is_nil(old_lat) or is_nil(old_lon) do
        nil
      else
        FloorplanTransform.distance_meters(
          {Decimal.to_float(old_lat), Decimal.to_float(old_lon)},
          {new_lat, new_lon}
        )
      end

    %{
      changed?: lat_changed? or lon_changed?,
      lat_changed?: lat_changed?,
      lon_changed?: lon_changed?,
      distance_meters: distance,
      changed_attrs:
        %{}
        |> then(fn attrs ->
          if lat_changed?, do: Map.put(attrs, :stop_lat, Decimal.from_float(new_lat)), else: attrs
        end)
        |> then(fn attrs ->
          if lon_changed?, do: Map.put(attrs, :stop_lon, Decimal.from_float(new_lon)), else: attrs
        end)
    }
  end

  defp axis_changed?(nil, _proposed), do: true

  defp axis_changed?(%Decimal{} = current, proposed) when is_float(proposed),
    do: Decimal.compare(current, Decimal.from_float(proposed)) != :eq

  defp count_unplaced_on_level(%StopLevel{} = stop_level, options) do
    case level_scoped_descendants_base(stop_level, options) do
      nil ->
        0

      base_query ->
        base_query
        |> Repo.all()
        |> Enum.count(fn stop ->
          is_nil(stop.diagram_coordinate) or
            is_nil(Coordinates.normalize_point(stop.diagram_coordinate))
        end)
    end
  end

  defp level_scoped_descendants_base(%StopLevel{} = stop_level, options) do
    case Repo.get(Stop, stop_level.stop_id) do
      %Stop{} = station ->
        descendants =
          descendant_stop_ids_query(
            station.organization_id,
            station.gtfs_version_id,
            station.stop_id
          )

        query =
          from(stop in Stop,
            where:
              stop.stop_id in subquery(descendants) and
                stop.organization_id == ^stop_level.organization_id and
                stop.gtfs_version_id == ^stop_level.gtfs_version_id and
                stop.level_id == ^level_external_id(stop_level.level_id),
            order_by: [asc: stop.id]
          )

        if Keyword.get(options, :lock) == "FOR UPDATE",
          do: from(stop in query, lock: "FOR UPDATE"),
          else: query

      nil ->
        nil
    end
  end

  @doc """
  Returns a read-only, fingerprinted preview of applying a floorplan alignment
  to the eligible child stops on a stop level.

  The fingerprint binds the proposed alignment, image dimensions, and every
  eligible stop input used to derive the preview. It is verified again from a
  serializable snapshot before `apply_stop_level_coordinate_preview/2` writes.
  """
  @spec preview_stop_level_coordinate_application(
          Ecto.UUID.t(),
          map(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, alignment_preview()}
          | {:error,
             :not_found | :invalid_input | :alignment_missing | :invalid_image_dims | term()}
  def preview_stop_level_coordinate_application(
        stop_level_id,
        proposed_alignment,
        image_w,
        image_h
      )
      when is_binary(stop_level_id) and is_map(proposed_alignment) do
    with {:ok, projection} <-
           build_alignment_projection(stop_level_id, proposed_alignment, image_w, image_h) do
      {:ok,
       %{
         stop_level_id: projection.stop_level.id,
         level_id: projection.stop_level.level_id,
         image_width: image_w,
         image_height: image_h,
         proposed_alignment: projection.normalized_alignment,
         fingerprint: projection.fingerprint,
         stop_count: length(projection.rows),
         rows: public_preview_rows(projection.rows)
       }}
    end
  end

  def preview_stop_level_coordinate_application(_, _, _, _), do: {:error, :invalid_input}

  @doc """
  Applies a previously generated coordinate preview in a bounded serializable
  transaction within the audit context scope.

  The preview must still match the transaction snapshot before any write. Only
  stops whose derived coordinates differ are updated and audited. A PostgreSQL
  serialization failure retries the whole compare-and-apply attempt up to three
  times; exhausted retries return `:busy` without publishing a broadcast from an
  aborted attempt.
  """
  @spec apply_stop_level_coordinate_preview(alignment_preview(), AuditContext.t()) ::
          {:ok,
           %{
             active_stop_level: StopLevel.t(),
             rows: [map()],
             touched_stop_count: non_neg_integer()
           }}
          | {:error, :stale_preview | :busy | :not_found | :invalid_input | term()}
  def apply_stop_level_coordinate_preview(preview, %AuditContext{} = audit_ctx)
      when is_map(preview) do
    with :ok <- validate_alignment_preview(preview) do
      preview.stop_level_id
      |> apply_reviewed_with_retries(
        preview.proposed_alignment,
        preview.image_width,
        preview.image_height,
        preview.fingerprint,
        audit_ctx,
        3
      )
      |> publish_preview_result()
    end
  end

  def apply_stop_level_coordinate_preview(_, _), do: {:error, :invalid_input}

  defp publish_preview_result({:ok, result}) do
    %{active_stop_level: stop_level, changed_stops: changed_stops, rows: rows} = result
    broadcast({:ok, stop_level}, [:stop_levels, :updated])

    Enum.each(changed_stops, fn stop ->
      broadcast({:ok, stop}, [:stops, :updated])
    end)

    {:ok,
     %{
       active_stop_level: stop_level,
       rows: public_preview_rows(rows),
       touched_stop_count: length(changed_stops)
     }}
  end

  defp publish_preview_result({:error, :stale_review}), do: {:error, :stale_preview}
  defp publish_preview_result({:error, reason}), do: {:error, reason}

  defp validate_alignment_preview(%{
         stop_level_id: stop_level_id,
         level_id: level_id,
         image_width: image_w,
         image_height: image_h,
         proposed_alignment: proposed_alignment,
         fingerprint: fingerprint
       })
       when is_binary(stop_level_id) and is_binary(level_id) and is_map(proposed_alignment) and
              is_binary(fingerprint) do
    validate_positive_image_dims(image_w, image_h)
  end

  defp validate_alignment_preview(_), do: {:error, :invalid_input}

  defp proposed_stop_level(%StopLevel{} = stop_level, proposed_alignment)
       when is_map(proposed_alignment) do
    stop_level
    |> StopLevel.alignment_changeset(proposed_alignment)
    |> Ecto.Changeset.apply_action(:update)
  end

  defp eligible_child_stops(%StopLevel{} = stop_level, options) do
    case level_scoped_descendants_base(stop_level, options) do
      nil ->
        []

      base_query ->
        base_query
        |> where([stop], not is_nil(stop.diagram_coordinate))
        |> Repo.all()
        |> Enum.filter(&(not is_nil(Coordinates.normalize_point(&1.diagram_coordinate))))
    end
  end

  defp level_external_id(level_id) do
    case Repo.get(Level, level_id) do
      %Level{level_id: external_id} -> external_id
      nil -> nil
    end
  end

  defp preview_rows(stop_level, stops, image_w, image_h) do
    with {:ok, alignment} <- extract_alignment(stop_level),
         :ok <- validate_positive_image_dims(image_w, image_h) do
      Enum.reduce_while(stops, {:ok, []}, fn stop, {:ok, rows} ->
        append_preview_row(stop, rows, alignment, image_w, image_h)
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        {:error, _} = error -> error
      end
    end
  end

  defp append_preview_row(stop, rows, alignment, image_w, image_h) do
    %{x: x, y: y} = Coordinates.normalize_point(stop.diagram_coordinate)

    case FloorplanTransform.svg_to_lat_lon(alignment, image_w, image_h, %{x: x, y: y}) do
      {:ok, {lat, lon}} ->
        {:cont, {:ok, [preview_row(stop, x, y, lat, lon) | rows]}}

      {:error, reason} ->
        {:halt, {:error, {:transform, reason}}}
    end
  end

  defp preview_row(stop, x, y, lat, lon) do
    %{
      stop: stop,
      stop_id: stop.id,
      stop_code: stop.stop_id,
      diagram_coordinate: %{x: x, y: y},
      old_lat: stop.stop_lat,
      old_lon: stop.stop_lon,
      new_lat: lat,
      new_lon: lon
    }
  end

  defp alignment_preview_fingerprint(
         stop_level,
         proposed_alignment,
         image_w,
         image_h,
         rows,
         unplaced_count
       ) do
    payload = %{
      stop_level: %{id: stop_level.id, level_id: stop_level.level_id},
      proposed_alignment: proposed_alignment,
      image: %{width: image_w, height: image_h},
      eligible_stops:
        Enum.map(rows, fn row ->
          %{
            id: row.stop_id,
            stop_id: row.stop_code,
            level_id: row.stop.level_id,
            diagram_coordinate: row.diagram_coordinate,
            stop_lat: row.old_lat,
            stop_lon: row.old_lon
          }
        end),
      stop_count: length(rows),
      unplaced_count: unplaced_count
    }

    payload
    |> canonical_preview_value()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_preview_value(%Decimal{} = value),
    do: {:decimal, Decimal.to_string(value, :normal)}

  defp canonical_preview_value(value) when is_float(value),
    do: {:float, :erlang.float_to_binary(value, [:compact])}

  defp canonical_preview_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} -> {to_string(key), canonical_preview_value(map_value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_preview_value(value) when is_list(value),
    do: Enum.map(value, &canonical_preview_value/1)

  defp canonical_preview_value(value), do: value

  defp public_preview_rows(rows) do
    Enum.map(rows, &Map.drop(&1, [:stop]))
  end

  defp serialization_failure?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:serialization_failure, "40001"],
       do: true

  defp serialization_failure?(_), do: false

  @type reviewed_alignment_attrs :: %{
          floorplan_center_lat: number(),
          floorplan_center_lon: number(),
          floorplan_scale_mpp: number(),
          floorplan_rotation_deg: number(),
          fingerprint: String.t()
        }

  @doc """
  Saves a reviewed floorplan alignment and applies it to changed child stops
  within the audit context scope.

  Verifies the review fingerprint under a `FOR UPDATE` lock before any write.
  Only stops whose derived coordinates differ (via `Decimal.compare/2`) are
  updated and audited. Publishes broadcasts after commit.
  """
  @spec save_and_apply_stop_level_alignment(
          Ecto.UUID.t(),
          reviewed_alignment_attrs(),
          pos_integer(),
          pos_integer(),
          AuditContext.t()
        ) ::
          {:ok,
           %{
             active_stop_level: StopLevel.t(),
             apply_result: %{
               updated_stop_count: non_neg_integer(),
               unchanged_count: non_neg_integer(),
               unplaced_count: non_neg_integer()
             }
           }}
          | {:error,
             :not_found
             | :invalid_input
             | :stale_review
             | :busy
             | :alignment_missing
             | :invalid_image_dims
             | {:transform, atom()}
             | Ecto.Changeset.t()
             | term()}
  def save_and_apply_stop_level_alignment(
        stop_level_id,
        reviewed_attrs,
        image_w,
        image_h,
        %AuditContext{} = audit_ctx
      )
      when is_binary(stop_level_id) and is_map(reviewed_attrs) do
    with {:ok, fingerprint} <- extract_review_fingerprint(reviewed_attrs),
         :ok <- validate_positive_image_dims(image_w, image_h) do
      alignment_attrs = Map.delete(reviewed_attrs, :fingerprint)

      stop_level_id
      |> apply_reviewed_with_retries(
        alignment_attrs,
        image_w,
        image_h,
        fingerprint,
        audit_ctx,
        3
      )
      |> publish_reviewed_result()
    end
  end

  def save_and_apply_stop_level_alignment(_, _, _, _, _), do: {:error, :invalid_input}

  defp extract_review_fingerprint(%{fingerprint: fp}) when is_binary(fp) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, fp),
      do: {:ok, fp},
      else: {:error, :invalid_input}
  end

  defp extract_review_fingerprint(_), do: {:error, :invalid_input}

  defp apply_reviewed_with_retries(
         stop_level_id,
         alignment_attrs,
         image_w,
         image_h,
         fingerprint,
         audit_ctx,
         attempts_remaining
       )
       when attempts_remaining > 0 do
    tx_fn = fn ->
      apply_reviewed_alignment_in_tx(
        stop_level_id,
        alignment_attrs,
        image_w,
        image_h,
        fingerprint,
        audit_ctx
      )
    end

    case run_reviewed_apply_transaction(tx_fn) do
      {:ok, result} ->
        {:ok, result}

      {:serialization_failure, _exception} when attempts_remaining > 1 ->
        apply_reviewed_with_retries(
          stop_level_id,
          alignment_attrs,
          image_w,
          image_h,
          fingerprint,
          audit_ctx,
          attempts_remaining - 1
        )

      {:serialization_failure, _exception} ->
        {:error, :busy}

      {:error, reason} when attempts_remaining > 1 ->
        if serialization_failure?(reason) do
          apply_reviewed_with_retries(
            stop_level_id,
            alignment_attrs,
            image_w,
            image_h,
            fingerprint,
            audit_ctx,
            attempts_remaining - 1
          )
        else
          {:error, reason}
        end

      {:error, reason} ->
        if serialization_failure?(reason), do: {:error, :busy}, else: {:error, reason}
    end
  end

  defp run_reviewed_apply_transaction(transaction) do
    reviewed_apply_transaction().run(transaction)
  rescue
    exception in Postgrex.Error ->
      if serialization_failure?(exception) do
        {:serialization_failure, exception}
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp reviewed_apply_transaction do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      @default_reviewed_apply_transaction
    )
  end

  defp publish_reviewed_result({:ok, result}) do
    %{
      active_stop_level: stop_level,
      changed_stops: changed_stops,
      updated_stop_count: updated_count,
      unchanged_count: unchanged_count,
      unplaced_count: unplaced_count
    } = result

    broadcast({:ok, stop_level}, [:stop_levels, :updated])

    Enum.each(changed_stops, fn stop ->
      broadcast({:ok, stop}, [:stops, :updated])
    end)

    {:ok,
     %{
       active_stop_level: stop_level,
       apply_result: %{
         updated_stop_count: updated_count,
         unchanged_count: unchanged_count,
         unplaced_count: unplaced_count
       }
     }}
  end

  defp publish_reviewed_result({:error, reason}), do: {:error, reason}

  defp apply_reviewed_alignment_in_tx(
         stop_level_id,
         proposed_alignment,
         image_w,
         image_h,
         expected_fingerprint,
         %AuditContext{} = audit_ctx
       ) do
    # Reviewed alignment rewrites child stop geometry, a combination input, so the scoped version
    # share lock is taken before the stop-level `FOR UPDATE`, the fingerprint comparison and every
    # child update. The surrounding serializable transaction and its whole-transaction retry stay
    # exactly as they were.
    Versions.lock_for_input_write!(audit_ctx.organization_id, audit_ctx.gtfs_version_id)

    case load_stop_level_for_update_scoped(stop_level_id, audit_ctx) do
      nil ->
        Repo.rollback(:not_found)

      %StopLevel{} = stop_level ->
        with {:ok, projection} <-
               build_alignment_projection(
                 stop_level.id,
                 proposed_alignment,
                 image_w,
                 image_h,
                 lock: "FOR UPDATE"
               ),
             :ok <- verify_review_fingerprint(projection, expected_fingerprint),
             {:ok, updated_stop_level} <-
               stop_level
               |> StopLevel.alignment_changeset(proposed_alignment)
               |> Repo.update(),
             {:ok, changed_stops} <-
               persist_changed_stops_with_audit(
                 projection,
                 audit_ctx
               ),
             {:ok, _pin_count} <-
               StationJournal.refresh_pin_coordinates_for_stop_level(
                 updated_stop_level,
                 image_w,
                 image_h
               ) do
          %{
            active_stop_level: updated_stop_level,
            changed_stops: changed_stops,
            rows: projection.rows,
            updated_stop_count: length(changed_stops),
            unchanged_count: projection.unchanged_count,
            unplaced_count: projection.unplaced_count
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp load_stop_level_for_update_scoped(stop_level_id, %AuditContext{} = audit_ctx) do
    from(sl in StopLevel,
      where:
        sl.id == ^stop_level_id and
          sl.organization_id == ^audit_ctx.organization_id and
          sl.gtfs_version_id == ^audit_ctx.gtfs_version_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp verify_review_fingerprint(projection, expected_fingerprint) do
    if projection.fingerprint == expected_fingerprint,
      do: :ok,
      else: {:error, :stale_review}
  end

  defp persist_changed_stops_with_audit(projection, %AuditContext{} = audit_ctx) do
    projection.rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, updated_stops} ->
      persist_row_if_changed(row, updated_stops, audit_ctx)
    end)
    |> case do
      {:ok, stops} -> {:ok, Enum.reverse(stops)}
      {:error, _} = error -> error
    end
  end

  defp persist_row_if_changed(row, updated_stops, audit_ctx) do
    classification =
      classify_coordinate_change(row.old_lat, row.old_lon, row.new_lat, row.new_lon)

    if classification.changed? do
      case update_and_audit_stop(row.stop, classification.changed_attrs, audit_ctx) do
        {:ok, updated_stop} -> {:cont, {:ok, [updated_stop | updated_stops]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      {:cont, {:ok, updated_stops}}
    end
  end

  defp update_and_audit_stop(%Stop{} = stop, changed_attrs, %AuditContext{} = audit_ctx) do
    with {:ok, updated_stop} <-
           stop
           |> Stop.changeset(changed_attrs)
           |> Repo.update(),
         {:ok, _log} <-
           record_change_in_transaction(audit_ctx, :stop, stop, "updated", changed_attrs) do
      {:ok, updated_stop}
    end
  end

  defp stop_level_alignment_snapshot(%StopLevel{} = stop_level) do
    %{
      floorplan_center_lat: stop_level.floorplan_center_lat,
      floorplan_center_lon: stop_level.floorplan_center_lon,
      floorplan_scale_mpp: stop_level.floorplan_scale_mpp,
      floorplan_rotation_deg: stop_level.floorplan_rotation_deg
    }
  end

  @doc """
  Applies the saved floorplan alignment to persist `stop_lat`/`stop_lon` on every
  eligible child stop of `stop_level`.

  Derives coordinates via `derive_child_stop_coords/3`, then updates all derived
  stops atomically in a single `Repo.transaction`. Each successful update emits a
  `[:stops, :updated]` broadcast. A single failed changeset rolls back every write
  in the call.

  Returns `{:ok, count}` with the number of updated stops, `{:ok, 0}` when no
  eligible stops exist, or `{:error, reason}` on derivation or persistence failure.
  """
  @spec apply_alignment_to_child_stops(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()}
          | {:error, :alignment_missing | :invalid_image_dims | {:transform, atom()} | term()}
  def apply_alignment_to_child_stops(%StopLevel{} = stop_level, image_w, image_h) do
    with {:ok, derived} <- derive_child_stop_coords(stop_level, image_w, image_h) do
      persist_derived_coords(derived, stop_level)
    end
  end

  defp persist_derived_coords([], _stop_level), do: {:ok, 0}

  defp persist_derived_coords(derived, %StopLevel{} = stop_level) when is_list(derived) do
    transaction_result =
      Repo.transaction(fn ->
        # Derived child coordinates are a reviewed combination input, so the version share lock is
        # the first statement of this transaction, before the child stop rows are read or updated.
        Versions.lock_for_input_write!(stop_level.organization_id, stop_level.gtfs_version_id)

        Enum.map(derived, fn entry ->
          case update_derived_stop_coords(entry) do
            {:ok, updated_stop} -> updated_stop
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end)

    case transaction_result do
      {:ok, updated_stops} ->
        Enum.each(updated_stops, fn stop ->
          broadcast({:ok, stop}, [:stops, :updated])
        end)

        {:ok, length(updated_stops)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_derived_stop_coords(%{stop: %Stop{} = stop, new_lat: lat, new_lon: lon}) do
    stop
    |> Stop.changeset(%{
      stop_lat: Decimal.from_float(lat),
      stop_lon: Decimal.from_float(lon)
    })
    |> Repo.update()
  end

  defp update_derived_stop_coords(%{stop_id: stop_id, lat: lat, lon: lon}) do
    case Repo.get(Stop, stop_id) do
      nil ->
        {:error, :stop_not_found}

      %Stop{} = stop ->
        stop
        |> Stop.changeset(%{
          stop_lat: Decimal.from_float(lat),
          stop_lon: Decimal.from_float(lon)
        })
        |> Repo.update()
    end
  end

  @doc """
  Infers floorplan alignment for `stop_level` from anchored child stops and
  eligible cross-level elevator pathways.

  Returns the inferred alignment plus lists of anchors used and candidates that
  were excluded with reasons. Does not persist any data.
  """
  @spec infer_level_alignment(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok,
           %{
             inferred_alignment: map(),
             anchors_used: [map()],
             excluded_anchors: [map()]
           }}
          | {:error,
             :alignment_prerequisites_missing
             | :insufficient_anchors
             | :degenerate_geometry
             | :high_residual
             | :invalid_input
             | :not_found}
  def infer_level_alignment(nil, _image_w, _image_h), do: {:error, :not_found}

  def infer_level_alignment(%StopLevel{level_id: nil}, _image_w, _image_h),
    do: {:error, :alignment_prerequisites_missing}

  def infer_level_alignment(%StopLevel{} = stop_level, image_w, image_h) do
    with :ok <- validate_positive_image_dims(image_w, image_h) do
      direct = direct_candidates_for(stop_level)
      cross = cross_level_candidates_for(stop_level)

      {anchors, exclusions} = AlignmentInference.select_anchors(direct, cross)

      case AlignmentInference.infer_alignment(anchors, image_w, image_h) do
        {:ok, inferred} ->
          {:ok,
           %{
             inferred_alignment: inferred,
             anchors_used: anchors,
             excluded_anchors: exclusions
           }}

        {:error, _} = error ->
          error
      end
    else
      {:error, :invalid_image_dims} -> {:error, :invalid_input}
      other -> other
    end
  end

  @doc """
  Infers and persists floorplan alignment for `stop_level`.

  Calls `infer_level_alignment/3` and, on success, writes the inferred
  `floorplan_*` fields via `StopLevel.alignment_changeset/2`. Emits a
  `[:stop_levels, :updated]` broadcast only on successful update.
  """
  @spec save_inferred_level_alignment(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok, StopLevel.t(), map()}
          | {:error,
             :alignment_prerequisites_missing
             | :insufficient_anchors
             | :degenerate_geometry
             | :high_residual
             | :invalid_input
             | :not_found
             | Ecto.Changeset.t()}
  def save_inferred_level_alignment(%StopLevel{} = stop_level, image_w, image_h) do
    with {:ok, %{inferred_alignment: inferred} = result} <-
           infer_level_alignment(stop_level, image_w, image_h),
         {:ok, updated} <- persist_inferred_alignment(stop_level, inferred) do
      broadcast({:ok, updated}, [:stop_levels, :updated])
      {:ok, updated, result}
    end
  end

  def save_inferred_level_alignment(nil, _image_w, _image_h), do: {:error, :not_found}

  defp persist_inferred_alignment(%StopLevel{} = stop_level, inferred) do
    stop_level
    |> StopLevel.alignment_changeset(%{
      floorplan_center_lat: inferred.center_lat,
      floorplan_center_lon: inferred.center_lon,
      floorplan_scale_mpp: inferred.scale_mpp,
      floorplan_rotation_deg: inferred.rotation_deg
    })
    |> Repo.update()
  end

  defp direct_candidates_for(%StopLevel{} = stop_level) do
    stop_level.stop_id
    |> list_child_stops_for_level(stop_level.level_id)
    |> Enum.filter(& &1.on_active_level)
    |> Enum.map(fn stop ->
      {sx, sy} = svg_xy_from_coordinate(stop.diagram_coordinate)

      %{
        stop_id: stop.id,
        svg_x: sx,
        svg_y: sy,
        lat: decimal_to_float(stop.stop_lat),
        lon: decimal_to_float(stop.stop_lon)
      }
    end)
  end

  defp cross_level_candidates_for(%StopLevel{} = stop_level) do
    pathways =
      list_pathways_for_level(
        stop_level.organization_id,
        stop_level.gtfs_version_id,
        stop_level.level_id,
        stop_level.stop_id
      )
      |> Enum.filter(& &1.is_cross_level)

    target_level = Repo.get!(Level, stop_level.level_id)
    partner_level_indexes = load_partner_level_indexes(pathways, stop_level, target_level)

    pathways
    |> Enum.map(fn pathway ->
      case cross_level_endpoints(pathway) do
        {target_stop, partner_stop} ->
          partner_index = Map.get(partner_level_indexes, partner_stop.level_id)
          delta = level_index_delta(target_level.level_index, partner_index)
          build_cross_level_candidate(pathway, target_stop, partner_stop, delta)

        nil ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp cross_level_endpoints(%{from_on_active_level: true, to_on_active_level: false} = p),
    do: {p.from_stop, p.to_stop}

  defp cross_level_endpoints(%{from_on_active_level: false, to_on_active_level: true} = p),
    do: {p.to_stop, p.from_stop}

  defp cross_level_endpoints(_), do: nil

  defp build_cross_level_candidate(_pathway, _target_stop, %Stop{parent_station: nil}, _delta),
    do: nil

  defp build_cross_level_candidate(_pathway, _target_stop, %Stop{parent_station: ""}, _delta),
    do: nil

  defp build_cross_level_candidate(_pathway, _target_stop, _partner_stop, nil), do: nil

  defp build_cross_level_candidate(pathway, target_stop, partner_stop, delta) do
    {sx, sy} = svg_xy_from_coordinate(target_stop.diagram_coordinate)

    %{
      stop_id: target_stop.id,
      pathway_id: pathway.id,
      pathway_mode: pathway.pathway_mode,
      level_index_delta: delta,
      svg_x: sx,
      svg_y: sy,
      lat: decimal_to_float(partner_stop.stop_lat),
      lon: decimal_to_float(partner_stop.stop_lon)
    }
  end

  defp load_partner_level_indexes(pathways, stop_level, target_level) do
    partner_level_ids =
      pathways
      |> Enum.flat_map(fn pathway ->
        case cross_level_endpoints(pathway) do
          {_target, partner} -> [partner.level_id]
          nil -> []
        end
      end)
      |> Enum.reject(&(is_nil(&1) or &1 == target_level.level_id))
      |> Enum.uniq()

    case partner_level_ids do
      [] ->
        %{}

      ids ->
        from(l in Level,
          where:
            l.organization_id == ^stop_level.organization_id and
              l.gtfs_version_id == ^stop_level.gtfs_version_id and
              l.level_id in ^ids,
          select: {l.level_id, l.level_index}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  defp level_index_delta(_target_index, nil), do: nil
  defp level_index_delta(target_index, partner_index), do: abs(partner_index - target_index)

  defp svg_xy_from_coordinate(coord) do
    case Coordinates.normalize_point(coord) do
      %{x: x, y: y} -> {x, y}
      nil -> {nil, nil}
    end
  end

  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n * 1.0
  defp decimal_to_float(_), do: nil

  @doc """
  Recalculates same-level pathway lengths from the diagram after a scale change.

  A length is overwritten only when it is empty or equals what `previous_stop_level`
  (the scale in force before this change) would have produced for the pathway's
  stops. Any other length was entered or imported, so it is kept. Each overwrite
  records an "updated" pathway change log; run this inside the caller's transaction
  so a failed log or update rolls back the earlier writes.

  Returns `{:ok, %{recalculated_count: n, kept_count: k}}`, where `k` counts pathways
  with a computable length that was left alone because it was not derived from the plan.
  """
  def recalculate_pathway_lengths_for_level(
        %StopLevel{} = previous_stop_level,
        %StopLevel{} = stop_level,
        organization_id,
        gtfs_version_id,
        level_id,
        parent_station_id,
        %AuditContext{} = audit_ctx
      ) do
    initial_counts = %{recalculated_count: 0, kept_count: 0}

    organization_id
    |> list_pathways_for_level(gtfs_version_id, level_id, parent_station_id)
    |> Enum.reject(& &1.is_cross_level)
    |> Enum.sort_by(& &1.pathway_id, :asc)
    |> Enum.reduce_while({:ok, initial_counts}, fn pathway, {:ok, counts} ->
      case recalculate_pathway_length(pathway, previous_stop_level, stop_level, audit_ctx) do
        {:ok, :recalculated} ->
          {:cont, {:ok, Map.update!(counts, :recalculated_count, &(&1 + 1))}}

        {:ok, :kept} ->
          {:cont, {:ok, Map.update!(counts, :kept_count, &(&1 + 1))}}

        {:ok, :unchanged} ->
          {:cont, {:ok, counts}}

        {:error, changeset} ->
          {:halt, {:error, changeset}}
      end
    end)
  end

  defp recalculate_pathway_length(pathway, previous_stop_level, stop_level, audit_ctx) do
    new_length = calculate_pathway_length(stop_level, pathway.from_stop, pathway.to_stop)

    cond do
      is_nil(new_length) ->
        {:ok, :unchanged}

      not is_nil(pathway.length) and Decimal.equal?(pathway.length, new_length) ->
        {:ok, :unchanged}

      not derived_pathway_length?(pathway, previous_stop_level) ->
        {:ok, :kept}

      true ->
        with {:ok, _pathway} <-
               pathway
               |> Pathway.changeset(%{length: new_length})
               |> Repo.update(),
             {:ok, _log} <-
               record_change_in_transaction(audit_ctx, :pathway, pathway, "updated", %{
                 length: new_length
               }) do
          {:ok, :recalculated}
        end
    end
  end

  # Length has no stored provenance, so a length counts as derived from the plan
  # only when the previous scale would have produced exactly this value (both are
  # rounded to 2 places by `calculate_pathway_length/3`). Ceiling: a derived length
  # whose endpoints moved after it was computed no longer matches and is treated as
  # entered. Upgrade path: store length provenance on the pathway.
  defp derived_pathway_length?(%Pathway{length: nil}, _previous_stop_level), do: true

  defp derived_pathway_length?(%Pathway{} = pathway, previous_stop_level) do
    case calculate_pathway_length(previous_stop_level, pathway.from_stop, pathway.to_stop) do
      %Decimal{} = previous_length -> Decimal.equal?(pathway.length, previous_length)
      nil -> false
    end
  end

  @doc """
  Saves stop-level calibration and recalculates the pathway lengths derived from the
  previous scale atomically, recording a change log for each recalculated pathway.

  Returns `{:ok, %{stop_level:, recalculated_count:, kept_count:}}`; see
  `recalculate_pathway_lengths_for_level/7` for which lengths are kept.
  """
  def save_scale_and_recalculate(
        %StopLevel{} = stop_level,
        scale_attrs,
        organization_id,
        gtfs_version_id,
        level_id,
        parent_station_id,
        %AuditContext{} = audit_ctx
      ) do
    transaction_result =
      Repo.transaction(fn ->
        with {:ok, updated_stop_level} <-
               stop_level
               |> StopLevel.scale_changeset(scale_attrs)
               |> Repo.update(),
             {:ok, counts} <-
               recalculate_pathway_lengths_for_level(
                 stop_level,
                 updated_stop_level,
                 organization_id,
                 gtfs_version_id,
                 level_id,
                 parent_station_id,
                 audit_ctx
               ) do
          Map.put(counts, :stop_level, updated_stop_level)
        else
          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case transaction_result do
      {:ok, result} ->
        broadcast({:ok, result.stop_level}, [:stop_levels, :updated])
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clears a stop_level's diagram calibration.
  """
  def clear_stop_level_scale(%StopLevel{} = stop_level) do
    update_stop_level_scale(stop_level, %{
      scale_point_a: nil,
      scale_point_b: nil,
      scale_distance_meters: nil,
      scale_meters_per_unit: nil
    })
  end

  @doc """
  Calculates a pathway length in meters from two stops and a calibrated stop_level.
  Returns nil when calibration or coordinates are unavailable.
  """
  def calculate_pathway_length(%StopLevel{} = stop_level, %Stop{} = from_stop, %Stop{} = to_stop) do
    with %{x: from_x, y: from_y} <- Coordinates.normalize_point(from_stop.diagram_coordinate),
         %{x: to_x, y: to_y} <- Coordinates.normalize_point(to_stop.diagram_coordinate),
         %Decimal{} = meters_per_unit <- stop_level.scale_meters_per_unit,
         :gt <- Decimal.compare(meters_per_unit, Decimal.new(0)) do
      svg_distance =
        :math.sqrt(:math.pow(to_x - from_x, 2) + :math.pow(to_y - from_y, 2))

      svg_distance
      |> Decimal.from_float()
      |> Decimal.mult(meters_per_unit)
      |> Decimal.round(2)
    else
      _ -> nil
    end
  end

  def calculate_pathway_length(_, _, _), do: nil

  @doc """
  Deletes a level.

  ## Examples

      iex> delete_level(level)
      {:ok, %Level{}}

      iex> delete_level(level)
      {:error, %Ecto.Changeset{}}
  """
  def delete_level(%Level{} = level) do
    Repo.delete(level)
    |> broadcast([:levels, :deleted])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking level changes.

  ## Examples

      iex> change_level(level)
      %Ecto.Changeset{data: %Level{}}
  """
  def change_level(%Level{} = level, attrs \\ %{}) do
    Level.changeset(level, attrs)
  end

  @doc """
  Returns the count of stops for an organization and GTFS version.
  """
  def count_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of stops for an organization and GTFS version.
  """
  def list_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.stop_name]
    )
    |> Repo.all()
  end

  @doc """
  Returns a map of stop_id to list of routes serving that stop.
  """
  def get_routes_for_stops(organization_id, gtfs_version_id, stop_ids) do
    query =
      from(st in StopTime,
        join: t in Trip,
        on:
          st.trip_id == t.trip_id and st.organization_id == t.organization_id and
            st.gtfs_version_id == t.gtfs_version_id,
        join: r in Route,
        on:
          t.route_id == r.route_id and t.organization_id == r.organization_id and
            t.gtfs_version_id == r.gtfs_version_id,
        where:
          st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
            st.stop_id in ^stop_ids,
        distinct: [st.stop_id, r.route_id],
        order_by: [asc: r.route_short_name],
        select:
          {st.stop_id,
           %{
             route_id: r.route_id,
             route_short_name: r.route_short_name,
             route_color: r.route_color,
             route_text_color: r.route_text_color
           }}
      )

    Repo.all(query)
    |> Enum.group_by(fn {stop_id, _} -> stop_id end, fn {_, route} -> route end)
  end

  @doc """
  Returns a map of station stop_id to the routes serving its child platforms.

  A station's lines come from the stop_times of its child stops, so a child stop
  (`parent_station` equal to a requested station) contributes only when it is a
  platform (`location_type` `0` or `nil`); a stop_time on the station row itself
  contributes nothing. Stops, stop_times, trips and routes from another organization
  or version are ignored, and the result is distinct on station and route. An empty
  `station_stop_ids` list returns `%{}` without querying.
  """
  @spec routes_by_station(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) ::
          %{String.t() => [%{route_id: String.t(), route_short_name: String.t() | nil}]}
  def routes_by_station(_organization_id, _gtfs_version_id, []), do: %{}

  def routes_by_station(organization_id, gtfs_version_id, station_stop_ids) do
    from(s in Stop,
      join: st in StopTime,
      on:
        st.stop_id == s.stop_id and st.organization_id == s.organization_id and
          st.gtfs_version_id == s.gtfs_version_id,
      join: t in Trip,
      on:
        st.trip_id == t.trip_id and st.organization_id == t.organization_id and
          st.gtfs_version_id == t.gtfs_version_id,
      join: r in Route,
      on:
        t.route_id == r.route_id and t.organization_id == r.organization_id and
          t.gtfs_version_id == r.gtfs_version_id,
      where: s.organization_id == ^organization_id,
      where: s.gtfs_version_id == ^gtfs_version_id,
      where: s.parent_station in ^station_stop_ids,
      where: is_nil(s.location_type) or s.location_type == 0,
      distinct: [s.parent_station, r.route_id],
      order_by: [asc: s.parent_station, asc: r.route_id],
      select: {s.parent_station, %{route_id: r.route_id, route_short_name: r.route_short_name}}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {station_stop_id, _route} -> station_stop_id end,
      fn {_station_stop_id, route} -> route end
    )
  end

  @doc """
  Returns a list of routes that serve at least one station (stop with no parent).
  """
  def list_routes_serving_stations(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      where: fragment("EXISTS (
        SELECT 1 FROM stop_times st
        JOIN trips t ON st.trip_id = t.trip_id AND st.organization_id = t.organization_id AND st.gtfs_version_id = t.gtfs_version_id
        JOIN stops s ON st.stop_id = s.stop_id AND st.organization_id = s.organization_id AND st.gtfs_version_id = s.gtfs_version_id
        WHERE t.route_id = ? AND t.organization_id = ? AND t.gtfs_version_id = ?
        AND s.parent_station IS NULL
      )", r.route_id, r.organization_id, r.gtfs_version_id),
      order_by: [asc: r.route_short_name, asc: r.route_id],
      select: %{
        route_id: r.route_id,
        route_short_name: r.route_short_name,
        route_color: r.route_color
      }
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of stations (stops with no parent) for an organization and GTFS version.

  Accepts optional filters, search, sort, and pagination via opts keyword list.

  ## Examples

      iex> list_stations(organization_id, gtfs_version_id)
      [%Stop{}, ...]
  """
  def list_stations(organization_id, gtfs_version_id, opts \\ []) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          is_nil(s.parent_station)
    )
    |> maybe_filter_location_type(opts[:location_type])
    |> maybe_filter_route(opts[:route_id], organization_id, gtfs_version_id)
    |> maybe_filter_direction(opts[:direction_id], organization_id, gtfs_version_id)
    |> maybe_filter_wheelchair(opts[:wheelchair_boarding])
    |> maybe_search_stops(opts[:search])
    |> apply_stop_sort(opts[:sort_by], opts[:sort_dir])
    |> paginate(opts[:page], opts[:per_page])
    |> Repo.all()
  end

  @doc """
  Returns the count of stations (stops with no parent) for an organization and GTFS version.

  Accepts optional filters via opts keyword list.

  ## Examples

      iex> count_stations(organization_id, gtfs_version_id)
      42
  """
  def count_stations(organization_id, gtfs_version_id, opts \\ []) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          is_nil(s.parent_station)
    )
    |> maybe_filter_location_type(opts[:location_type])
    |> maybe_filter_route(opts[:route_id], organization_id, gtfs_version_id)
    |> maybe_filter_direction(opts[:direction_id], organization_id, gtfs_version_id)
    |> maybe_filter_wheelchair(opts[:wheelchair_boarding])
    |> maybe_search_stops(opts[:search])
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a single stop.

  Returns nil if the Stop does not exist.

  ## Examples

      iex> get_stop(id)
      %Stop{}

      iex> get_stop(Ecto.UUID.generate())
      nil
  """
  def get_stop(id), do: Repo.get(Stop, id)

  @doc """
  Gets a single stop.

  Raises `Ecto.NoResultsError` if the Stop does not exist.

  ## Examples

      iex> get_stop!(id)
      %Stop{}

      iex> get_stop!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_stop!(id), do: Repo.get!(Stop, id)

  @doc """
  Gets a stop by its stop_id within an organization and GTFS version.

  Returns nil if the stop does not exist.

  ## Examples

      iex> get_stop_by_stop_id(organization_id, gtfs_version_id, "stop_123")
      %Stop{}

      iex> get_stop_by_stop_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id == ^stop_id
    )
    |> Repo.one()
  end

  @doc """
  Gets the active station editing status for an organization, GTFS version, and station.
  """
  @spec get_station_editing_status(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          StationEditingStatus.t() | nil
  def get_station_editing_status(organization_id, gtfs_version_id, station_id) do
    from(s in StationEditingStatus,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.station_id == ^station_id,
      preload: [:user]
    )
    |> Repo.one()
  end

  @doc """
  Lists the station editing statuses for an organization and GTFS version.

  Each entry names its station and user, and the list is ordered by `started_at`
  ascending. A status whose station belongs to another organization or version is
  omitted.
  """
  @spec list_station_editors(Ecto.UUID.t(), Ecto.UUID.t()) ::
          [
            %{
              station_id: Ecto.UUID.t(),
              station_stop_id: String.t(),
              station_name: String.t() | nil,
              user_id: Ecto.UUID.t(),
              email: String.t(),
              started_at: DateTime.t()
            }
          ]
  def list_station_editors(organization_id, gtfs_version_id) do
    from(s in StationEditingStatus,
      join: station in Stop,
      on:
        station.id == s.station_id and station.organization_id == ^organization_id and
          station.gtfs_version_id == ^gtfs_version_id,
      join: user in Accounts.User,
      on: user.id == s.user_id,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.started_at],
      select: %{
        station_id: s.station_id,
        station_stop_id: station.stop_id,
        station_name: station.stop_name,
        user_id: s.user_id,
        email: user.email,
        started_at: s.started_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Subscribes to station editing status updates for an organization, GTFS version, and station.
  """
  @spec subscribe_station_editing_status(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, term()}
  def subscribe_station_editing_status(organization_id, gtfs_version_id, station_id) do
    Phoenix.PubSub.subscribe(
      GtfsPlanner.PubSub,
      station_editing_status_topic(organization_id, gtfs_version_id, station_id)
    )
  end

  @doc """
  Creates or replaces the active editing status for a station.
  """
  @spec set_station_editing_status(Ecto.UUID.t(), Ecto.UUID.t(), Stop.t(), Accounts.User.t()) ::
          {:ok, StationEditingStatus.t()} | {:error, Ecto.Changeset.t()}
  def set_station_editing_status(
        organization_id,
        gtfs_version_id,
        %Stop{} = station,
        %Accounts.User{} = user
      ) do
    started_at = DateTime.utc_now()

    attrs = %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      station_id: station.id,
      user_id: user.id,
      started_at: started_at
    }

    Repo.transaction(fn ->
      lock_station_editing_status!(organization_id, gtfs_version_id, station.id)

      %StationEditingStatus{}
      |> StationEditingStatus.changeset(attrs)
      |> Repo.insert(
        on_conflict: [set: [user_id: user.id, started_at: started_at]],
        conflict_target: [:organization_id, :gtfs_version_id, :station_id],
        returning: true
      )
      |> case do
        {:ok, status} ->
          status = Repo.preload(status, :user)
          :ok = broadcast_station_editing_status(status)
          {:ok, status}

        {:error, changeset} ->
          {:error, changeset}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clears the active station editing status for an organization, GTFS version, and station.

  Returns `:ok` on success. A failed transaction or a lost database connection
  returns `{:error, reason}` instead of crashing, so callers can preserve the
  prior status and offer an in-flow retry.
  """
  @spec clear_station_editing_status(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, term()}
  def clear_station_editing_status(organization_id, gtfs_version_id, station_id) do
    Repo.transaction(fn ->
      lock_station_editing_status!(organization_id, gtfs_version_id, station_id)

      from(s in StationEditingStatus,
        where:
          s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
            s.station_id == ^station_id
      )
      |> Repo.delete_all()

      :ok =
        broadcast_station_editing_status(
          organization_id,
          gtfs_version_id,
          station_id,
          nil
        )
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  defp broadcast_station_editing_status(%StationEditingStatus{} = status) do
    broadcast_station_editing_status(
      status.organization_id,
      status.gtfs_version_id,
      status.station_id,
      status
    )
  end

  defp broadcast_station_editing_status(organization_id, gtfs_version_id, station_id, status) do
    Phoenix.PubSub.broadcast(
      GtfsPlanner.PubSub,
      station_editing_status_topic(organization_id, gtfs_version_id, station_id),
      {:station_editing_status_updated, status}
    )
  end

  defp station_editing_status_topic(organization_id, gtfs_version_id, station_id) do
    "station_editing_status:#{organization_id}:#{gtfs_version_id}:#{station_id}"
  end

  defp lock_station_editing_status!(organization_id, gtfs_version_id, station_id) do
    topic = station_editing_status_topic(organization_id, gtfs_version_id, station_id)

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1)::bigint)",
      [topic]
    )

    :ok
  end

  @doc """
  Returns a station-scoped snapshot used to build deterministic station reports.

  The snapshot includes the parent station stop, station child stops, station levels,
  and pathways touching station child stops (with `from_stop` and `to_stop` populated).
  """
  @spec get_station_report_snapshot(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok,
           %{
             station: Stop.t(),
             child_stops: [Stop.t()],
             levels: [map()],
             pathways: [Pathway.t()]
           }}
          | {:error, :not_found}
  def get_station_report_snapshot(organization_id, gtfs_version_id, stop_id) do
    case get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
      %Stop{} = station ->
        snapshot = %{
          station: station,
          child_stops: list_child_stops_for_parent(organization_id, gtfs_version_id, station.id),
          levels: list_levels_for_station(organization_id, gtfs_version_id, station.id),
          pathways: list_pathways_for_station(organization_id, gtfs_version_id, station.id)
        }

        {:ok, snapshot}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists one published station's scheduled pathway closures beside its station snapshot.

  A closure is included when its pathway has either endpoint among the station's
  descendant stops, boarding areas included, and every pathway mode is eligible.
  Each closure row carries its fingerprint, exact snapshot pathway and native
  calendar option. Unknown, non-station, unpublished or foreign targets return
  `{:error, :not_found}`.
  """
  def station_closures(organization_id, gtfs_version_id, stop_id),
    do: PathwayEvolutions.station_closures(organization_id, gtfs_version_id, stop_id)

  @doc """
  Lists the native calendar choices for closures in one published organization/version.

  Metadata-only (attributes-only) services are excluded; dates-only and unnamed
  native services are included with their exact identifiers.
  """
  def closure_calendars(organization_id, gtfs_version_id),
    do: PathwayEvolutions.closure_calendars(organization_id, gtfs_version_id)

  @doc "Returns the count of scheduled closures for a published organization and GTFS version."
  def count_closures(organization_id, gtfs_version_id),
    do: PathwayEvolutions.count_closures(organization_id, gtfs_version_id)

  @doc """
  Previews one station's closure effect at a single service date and service time.

  Every input is loaded inside the export read snapshot, so the station snapshot,
  the station's closures, the referenced native calendars and the agency zone
  describe one committed revision. `service_time` is added to the
  PostgreSQL-derived service-day origin, so `00:15:00` on a New York
  spring-forward date is `2027-03-14T04:15:00Z` and a value above `24:00:00`
  stays above it. Returns the exact closed instances, the selected date's
  instances, the intersecting timeline instances with their span and boundary
  action targets, and the base/effective comparison, or `:not_found`,
  `{:timezone_unavailable, reason}` or `:analysis_too_large`.
  """
  def preview_closures(organization_id, gtfs_version_id, stop_id, service_date, service_time),
    do:
      PathwayEvolutions.preview_closures(
        organization_id,
        gtfs_version_id,
        stop_id,
        service_date,
        service_time
      )

  @doc """
  Reports every station access loss over a range of service dates.

  The covered span starts at the first service date's origin and ends at the later
  of the origin after the last service date and the latest end of an instance on
  it, so a `00:00:00` window on a daylight-saving date and a `25:00:00` window on
  the last date are both inside it. Every instance boundary is swept rather than
  sampled, and only the periods whose comparison differs from the base graph are
  returned, each with its exact active instances, both UTC offsets and the
  `preview_target` naming its start instant.

  A reversed range or a span over 31 requested service days is refused before any
  row is read, as `:range_invalid`; a missing, invalid or conflicting agency zone
  is refused with its reason, and the candidate-span and instance bounds are
  checked before any instance is built. An incomplete station keeps the report
  `:incomplete` whatever the findings are.
  """
  def analyze_closures(organization_id, gtfs_version_id, stop_id, first_date, last_date),
    do:
      PathwayEvolutions.analyze_closures(
        organization_id,
        gtfs_version_id,
        stop_id,
        first_date,
        last_date
      )

  @doc """
  Creates one validated closure under the published-version write lock.

  The actor's active editor membership is rechecked and the scoped published
  version is locked before the exact native service and pathway references are
  validated. One `pathway_evolution` change log records the closure UUID, the
  `pathway_id`, the audit scope (including the page's `station_stop_id`) and the
  `after` snapshot in the same transaction; any audit failure rolls back the
  closure. Returns the persisted row, its fingerprint and same-service overlap /
  no-active-dates notices, or a changeset field error, `:forbidden` or
  `:not_found`.
  """
  def create_pathway_evolution(attrs, audit_context),
    do: PathwayEvolutions.create_pathway_evolution(attrs, audit_context)

  @doc """
  Updates one persisted closure under the published-version write lock.

  The scoped row is loaded `FOR UPDATE` and compared with the supplied
  fingerprint before any write, so a save based on an older row returns
  `:stale_review` while edits beside the row never do. References are
  rechecked and an unchanged valid submission writes neither row nor audit.
  One `pathway_evolution` change log records the `before`/`after` snapshots in
  the same transaction; any audit failure rolls the update back. Returns the
  persisted row, its fingerprint and notices, or a changeset field error,
  `:forbidden`, `:not_found` or `:stale_review`.
  """
  def update_pathway_evolution(id, attrs, fingerprint, audit_context),
    do: PathwayEvolutions.update_pathway_evolution(id, attrs, fingerprint, audit_context)

  @doc """
  Deletes one persisted closure under the published-version write lock.

  The same fingerprint guard as `update_pathway_evolution/4` applies; a stale
  fingerprint preserves the row. Deletion is independent of calendar activity
  and removes only the closure row. One `pathway_evolution` change log records
  the `before` snapshot in the same transaction; any audit failure rolls the
  delete back.
  """
  def delete_pathway_evolution(id, fingerprint, audit_context),
    do: PathwayEvolutions.delete_pathway_evolution(id, fingerprint, audit_context)

  @doc """
  Returns a unique stop_id within an organization and GTFS version.

  Uses the provided base stop_id if available, otherwise appends `_2`, `_3`, etc.
  """
  def unique_stop_id(organization_id, gtfs_version_id, base_stop_id, exclude_stop_id \\ nil) do
    escaped_base_stop_id = escape_like_pattern(base_stop_id)

    query =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            fragment(
              "? LIKE ? ESCAPE ?",
              s.stop_id,
              ^"#{escaped_base_stop_id}%",
              ^"\\"
            ),
        select: s.stop_id
      )

    query =
      if is_nil(exclude_stop_id) do
        query
      else
        where(query, [s], s.stop_id != ^exclude_stop_id)
      end

    existing_ids =
      query
      |> Repo.all()
      |> MapSet.new()

    if MapSet.member?(existing_ids, base_stop_id) do
      suffix =
        Stream.iterate(2, &(&1 + 1))
        |> Enum.find(fn n ->
          candidate = "#{base_stop_id}_#{n}"
          not MapSet.member?(existing_ids, candidate)
        end)

      case suffix do
        nil ->
          raise "Unable to generate unique stop_id for #{inspect(base_stop_id)}"

        n ->
          "#{base_stop_id}_#{n}"
      end
    else
      base_stop_id
    end
  end

  @doc """
  Generates a kebab-case stop_id from a stop name with a two-digit sequence suffix.

  Tries `{kebab}-01`, `{kebab}-02`, etc. until finding one that does not collide
  with existing stop_ids in the same organization and version. The optional
  `exclude_stop_id` is ignored during collision checks (useful when renaming a stop
  so its own current ID is not treated as a collision).
  """
  def generate_kebab_stop_id(organization_id, gtfs_version_id, stop_name, exclude_stop_id \\ nil) do
    kebab =
      case Stop.kebabify(stop_name) do
        "" -> "stop"
        k -> k
      end

    escaped_kebab = escape_like_pattern(kebab)

    query =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            fragment(
              "? LIKE ? ESCAPE ?",
              s.stop_id,
              ^"#{escaped_kebab}-%",
              ^"\\"
            ),
        select: s.stop_id
      )

    query =
      if is_nil(exclude_stop_id) do
        query
      else
        where(query, [s], s.stop_id != ^exclude_stop_id)
      end

    existing_ids =
      query
      |> Repo.all()
      |> MapSet.new()

    seq =
      1..99
      |> Enum.find(fn n ->
        candidate = "#{kebab}-#{String.pad_leading(Integer.to_string(n), 2, "0")}"
        not MapSet.member?(existing_ids, candidate)
      end)

    case seq do
      nil ->
        {:error, "Unable to generate unique stop ID — all sequences exhausted"}

      n ->
        {:ok, "#{kebab}-#{String.pad_leading(Integer.to_string(n), 2, "0")}"}
    end
  end

  @doc false
  def escape_like_pattern(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Creates a stop.

  ## Examples

      iex> create_stop(%{organization_id: org_id, gtfs_version_id: version_id, stop_id: "stop_123", stop_name: "Central Station"})
      {:ok, %Stop{}}

      iex> create_stop(%{stop_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_stop(attrs \\ %{}) do
    %Stop{}
    |> Stop.changeset(attrs)
    |> insert_with_input_write_lock()
    |> broadcast([:stops, :created])
  end

  @doc """
  Creates a stop for import workflows using permissive parent/level validation.
  """
  def import_create_stop(attrs \\ %{}) do
    %Stop{}
    |> Stop.import_changeset(attrs)
    |> insert_with_input_write_lock()
    |> broadcast([:stops, :created])
  end

  @doc """
  Updates a stop.

  ## Examples

      iex> update_stop(stop, %{stop_name: "Updated Station Name"})
      {:ok, %Stop{}}

      iex> update_stop(stop, %{stop_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_stop(%Stop{} = stop, attrs) do
    stop
    |> Stop.changeset(attrs)
    |> update_with_input_write_lock()
    |> broadcast([:stops, :updated])
  end

  @doc """
  Updates a stop, cascading stop_id changes to all referencing records when the
  stop_id is modified. Delegates to `update_stop/2` when the stop_id is unchanged.
  """
  def update_stop_with_cascade(%Stop{} = stop, attrs) do
    new_stop_id = attrs[:stop_id] || attrs["stop_id"]

    if new_stop_id == stop.stop_id or is_nil(new_stop_id) do
      update_stop(stop, attrs)
    else
      mapping = %{stop.stop_id => new_stop_id}
      now = DateTime.utc_now()

      multi =
        Ecto.Multi.new()
        |> lock_input_write_multi(stop.organization_id, stop.gtfs_version_id)
        |> Ecto.Multi.run(:update_stop, fn _repo, _changes ->
          stop
          |> Stop.changeset(attrs)
          |> Repo.update()
        end)
        |> Ecto.Multi.run(:cascade_references, fn repo, _changes ->
          {:ok,
           update_stop_id_references(
             repo,
             mapping,
             stop.organization_id,
             stop.gtfs_version_id,
             now
           )}
        end)

      case Repo.transaction(multi) do
        {:ok, %{update_stop: updated_stop}} ->
          broadcast({:ok, updated_stop}, [:stops, :updated])

        {:error, :update_stop, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Updates a stop for import workflows using permissive parent/level validation.
  """
  def import_update_stop(%Stop{} = stop, attrs) do
    stop
    |> Stop.import_changeset(attrs)
    |> update_with_input_write_lock()
    |> broadcast([:stops, :updated])
  end

  @doc """
  Deletes a stop.

  ## Examples

      iex> delete_stop(stop)
      {:ok, %Stop{}}

      iex> delete_stop(stop)
      {:error, %Ecto.Changeset{}}
  """
  def delete_stop(%Stop{} = stop) do
    delete_with_input_write_lock(stop)
    |> broadcast([:stops, :deleted])
  end

  @doc """
  Deletes a child stop and its connected pathways in a single transaction.

  Scopes the lookup to the given organization, version, and parent station
  to prevent cross-tenant mutations.
  """
  @spec delete_child_stop(integer(), integer(), String.t(), integer()) ::
          {:ok, Stop.t()} | {:error, :not_found | term()}
  def delete_child_stop(organization_id, gtfs_version_id, station_stop_id, stop_id) do
    descendants = descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id)

    stop_query =
      from(s in Stop,
        where:
          s.id == ^stop_id and
            s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendants)
      )

    case Repo.one(stop_query) do
      nil ->
        {:error, :not_found}

      stop ->
        with :ok <-
               check_pathways_closure_free(organization_id, gtfs_version_id, stop.stop_id) do
          delete_child_stop_transaction(organization_id, gtfs_version_id, stop)
        end
    end
  end

  # The delete and the pathway cleanup commit together under the published
  # version's write lock; the composite-reference refusal becomes
  # `:pathway_in_use` and any other constraint failure is re-raised.
  defp delete_child_stop_transaction(organization_id, gtfs_version_id, stop) do
    Ecto.Multi.new()
    |> lock_input_write_multi(organization_id, gtfs_version_id)
    |> delete_pathways_for_stop_multi(organization_id, gtfs_version_id, stop.stop_id)
    |> Ecto.Multi.delete(:stop, stop)
    |> Repo.transaction()
    |> case do
      {:ok, %{stop: deleted_stop}} ->
        broadcast({:ok, deleted_stop}, [:stops, :deleted])

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      pathway_in_use_or_reraise(e, __STACKTRACE__)
  end

  @doc """
  Removes a child stop from the station diagram by clearing its
  `diagram_coordinate` and `level_id`, and deletes connected pathways
  so no dangling references remain.

  Records an "updated" change log for the stop and a "deleted" one for each
  deleted pathway in the same transaction, so a failed log rolls the removal back.

  Scopes the update to the given organization, version, and parent station
  to prevent cross-tenant mutations.
  """
  @spec remove_child_stop_from_diagram(
          integer(),
          integer(),
          String.t(),
          integer(),
          AuditContext.t()
        ) :: {:ok, Stop.t()} | {:error, :not_found | term()}
  def remove_child_stop_from_diagram(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        stop_id,
        %AuditContext{} = audit_ctx
      ) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    descendants = descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id)

    stop_query =
      from(s in Stop,
        where:
          s.id == ^stop_id and
            s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendants)
      )

    case Repo.one(stop_query) do
      nil ->
        {:error, :not_found}

      stop ->
        with :ok <-
               check_pathways_closure_free(organization_id, gtfs_version_id, stop.stop_id) do
          remove_child_stop_transaction(organization_id, gtfs_version_id, stop, now, audit_ctx)
        end
    end
  end

  # The diagram clearing and the pathway cleanup commit together, under the
  # same composite-reference guard as the delete.
  defp remove_child_stop_transaction(organization_id, gtfs_version_id, stop, now, audit_ctx) do
    update_query = from(s in Stop, where: s.id == ^stop.id)

    Ecto.Multi.new()
    |> delete_pathways_for_stop_multi(organization_id, gtfs_version_id, stop.stop_id)
    |> Ecto.Multi.update_all(:stop, update_query,
      set: [diagram_coordinate: nil, level_id: nil, updated_at: now]
    )
    |> Ecto.Multi.run(:audit, fn _repo, %{pathways: {_count, deleted_pathways}} ->
      record_diagram_removal(audit_ctx, stop, deleted_pathways)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} ->
        Repo.get!(Stop, stop.id)
        |> then(&{:ok, &1})
        |> broadcast([:stops, :updated])

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      pathway_in_use_or_reraise(e, __STACKTRACE__)
  end

  # A composite pathway reference refused the mutation while a closure still
  # names the pathway; every other constraint failure keeps its own error.
  defp pathway_in_use_or_reraise(exception, stacktrace) do
    if closure_reference_violation?(exception) do
      {:error, :pathway_in_use}
    else
      reraise(exception, stacktrace)
    end
  end

  defp record_diagram_removal(audit_ctx, %Stop{} = stop, deleted_pathways) do
    with {:ok, _} <- record_diagram_clear(audit_ctx, stop) do
      record_pathway_deletions(audit_ctx, deleted_pathways)
    end
  end

  # Skipped when the stop had neither a level nor a coordinate to clear, so History
  # never shows an update with no changed fields.
  defp record_diagram_clear(_audit_ctx, %Stop{level_id: nil, diagram_coordinate: nil}),
    do: {:ok, :unchanged}

  defp record_diagram_clear(audit_ctx, %Stop{} = stop) do
    record_change_in_transaction(audit_ctx, :stop, stop, "updated", %{
      diagram_coordinate: nil,
      level_id: nil
    })
  end

  defp record_pathway_deletions(audit_ctx, pathways) do
    Enum.reduce_while(pathways, {:ok, :recorded}, fn pathway, acc ->
      case record_change_in_transaction(audit_ctx, :pathway, pathway, "deleted") do
        {:ok, _log} -> {:cont, acc}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking stop changes.

  ## Examples

      iex> change_stop(stop)
      %Ecto.Changeset{data: %Stop{}}
  """
  def change_stop(%Stop{} = stop, attrs \\ %{}) do
    Stop.changeset(stop, attrs)
  end

  @doc """
  Returns child stops for a parent station, preloading level association.

  ## Examples

      iex> list_child_stops_for_parent(org_id, version_id, parent_id)
      [%Stop{level: %Level{}}, ...]
  """
  def list_child_stops_for_parent(organization_id, gtfs_version_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    from(s in Stop,
      left_join: l in Level,
      on:
        l.level_id == s.level_id and
          l.organization_id == ^organization_id and
          l.gtfs_version_id == ^gtfs_version_id,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id in subquery(descendants),
      order_by: [asc: s.stop_name],
      select: s,
      select_merge: %{level: l}
    )
    |> Repo.all()
  end

  @doc """
  Returns deterministic station-scope stop_ids for a station stop_id.

  Scope includes:
  - the station stop_id itself
  - direct children where parent_station equals station stop_id
  - boarding-area grandchildren where location_type is 4 and parent_station references a direct child
  """
  @spec list_station_scope_stop_ids(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :station_not_found}
  def list_station_scope_stop_ids(organization_id, gtfs_version_id, station_stop_id)
      when is_binary(station_stop_id) do
    case get_stop_by_stop_id(organization_id, gtfs_version_id, station_stop_id) do
      nil ->
        {:error, :station_not_found}

      _station ->
        descendant_stop_ids =
          organization_id
          |> descendant_stop_ids_query(gtfs_version_id, station_stop_id)
          |> Repo.all()

        {:ok,
         descendant_stop_ids
         |> Kernel.++([station_stop_id])
         |> Enum.uniq()
         |> Enum.sort()}
    end
  end

  @doc """
  Returns the list of levels for a specific station with stop counts.
  Uses a hybrid approach: combines levels from child stops with levels from stop_levels table.

  ## Examples

      iex> list_levels_for_station(organization_id, gtfs_version_id, parent_station_id)
      [%{level: %Level{}, stop_count: 5}, ...]
  """
  def list_levels_for_station(organization_id, gtfs_version_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    # Query 1: Levels from child stops that have a level_id set
    levels_from_stops =
      from(s in Stop,
        join: l in Level,
        on:
          l.level_id == s.level_id and
            l.organization_id == ^organization_id and
            l.gtfs_version_id == ^gtfs_version_id,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendants) and
            not is_nil(s.level_id),
        group_by: l.id,
        select: %{level_id: l.id, stop_count: count(s.id)}
      )
      |> Repo.all()
      |> Enum.into(%{}, fn %{level_id: id, stop_count: count} -> {id, count} end)

    # Query 2: Levels from stop_levels table (expressing intent)
    levels_from_stop_levels =
      from(sl in StopLevel,
        join: l in Level,
        on: sl.level_id == l.id,
        where:
          sl.organization_id == ^organization_id and
            sl.gtfs_version_id == ^gtfs_version_id and
            sl.stop_id == ^parent_station_id,
        select: %{level: l, stop_level: sl, diagram_filename: sl.diagram_filename}
      )
      |> Repo.all()

    # Combine: unique list of level IDs from both sources
    all_level_ids =
      (Map.keys(levels_from_stops) ++ Enum.map(levels_from_stop_levels, & &1.level.id))
      |> Enum.uniq()

    levels_from_stop_levels_by_id =
      Map.new(levels_from_stop_levels, fn %{level: level} = level_data ->
        {level.id, level_data}
      end)

    missing_level_ids =
      all_level_ids
      |> Enum.reject(&Map.has_key?(levels_from_stop_levels_by_id, &1))

    missing_levels_by_id =
      if missing_level_ids == [] do
        %{}
      else
        from(l in Level,
          where: l.id in ^missing_level_ids,
          select: {l.id, l}
        )
        |> Repo.all()
        |> Map.new()
      end

    # Build final result with stop counts and diagram filenames
    all_level_ids
    |> Enum.map(fn level_id ->
      # Get level from stop_levels query if available (includes diagram_filename)
      from_stop_levels = Map.get(levels_from_stop_levels_by_id, level_id)

      level =
        if from_stop_levels do
          from_stop_levels.level
        else
          case Map.fetch(missing_levels_by_id, level_id) do
            {:ok, level} ->
              level

            :error ->
              raise Ecto.NoResultsError,
                queryable: Level,
                query: "level not found for id #{inspect(level_id)} in list_levels_for_station/3"
          end
        end

      stop_count = Map.get(levels_from_stops, level_id, 0)
      diagram_filename = if from_stop_levels, do: from_stop_levels.diagram_filename, else: nil
      stop_level = if from_stop_levels, do: from_stop_levels.stop_level, else: nil

      %{
        level: level,
        stop_count: stop_count,
        diagram_filename: diagram_filename,
        stop_level: stop_level
      }
    end)
    |> Enum.sort_by(& &1.level.level_index, :asc)
  end

  @doc """
  Lists stop_level rows for a station within an organization/version scope.

  Results are deterministically ordered by `level_index`, then `stop_levels.id`.
  Each row preloads its associated `level` for adjacency and propagation logic.
  """
  @spec list_stop_levels_for_station(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          [StopLevel.t()]
  def list_stop_levels_for_station(organization_id, gtfs_version_id, station_id) do
    from(sl in StopLevel,
      join: l in assoc(sl, :level),
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          sl.stop_id == ^station_id,
      order_by: [asc: l.level_index, asc: sl.id],
      preload: [level: l]
    )
    |> Repo.all()
  end

  @doc """
  Gets a stop_level by stop_id and level_id.
  """
  def get_stop_level(organization_id, gtfs_version_id, stop_id, level_id) do
    from(sl in StopLevel,
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          sl.stop_id == ^stop_id and
          sl.level_id == ^level_id
    )
    |> Repo.one()
  end

  @doc """
  Returns true if the given level is associated with any station other than `station_id`.
  """
  def level_used_by_other_stations?(organization_id, gtfs_version_id, level_id, station_id) do
    from(sl in StopLevel,
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          sl.level_id == ^level_id and
          sl.stop_id != ^station_id
    )
    |> Repo.exists?()
  end

  @doc """
  Removes a level association from a station while preserving the shared level record.

  Stops of the station on that level lose their level and diagram coordinate, within the given
  organization and version only. That covers direct children and the boarding areas under its
  platforms, so no stop keeps a level the station no longer has. Returns `{:error, :not_found}`
  when `level_id` is not a level of that organization and version.
  """
  def remove_level_from_station(
        organization_id,
        gtfs_version_id,
        station_id,
        station_stop_id,
        level_id
      ) do
    Repo.transaction(fn ->
      level =
        Repo.get_by(Level,
          id: level_id,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        ) || Repo.rollback(:not_found)

      descendants = descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id)

      from(s in Stop,
        where:
          s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendants) and s.level_id == ^level.level_id
      )
      |> Repo.update_all(set: [level_id: nil, diagram_coordinate: nil])

      with %StopLevel{} = stop_level <-
             get_stop_level(organization_id, gtfs_version_id, station_id, level_id),
           {:ok, _deleted_stop_level} <- Repo.delete(stop_level) do
        :removed
      else
        nil -> :removed
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :removed} -> {:ok, :removed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a stop_level association.
  """
  def create_stop_level(attrs \\ %{}) do
    %StopLevel{}
    |> StopLevel.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:stop_levels, :created])
  end

  @doc """
  Updates a stop's diagram coordinate.

  ## Examples

      iex> update_stop_diagram_coordinate(stop, %{x: 50.5, y: 25.0})
      {:ok, %Stop{}}
  """
  def update_stop_diagram_coordinate(%Stop{} = stop, %{x: _, y: _} = coordinate) do
    stop
    |> Stop.changeset(%{diagram_coordinate: coordinate})
    |> Repo.update()
    |> broadcast([:stops, :updated])
  end

  @doc """
  Returns child stops for a parent station filtered by level.

  ## Examples

      iex> list_child_stops_for_level(parent_station_id, level_id)
      [%Stop{}, ...]
  """
  def list_child_stops_for_level(parent_station_id, level_id) do
    with %Stop{} = parent_station <- Repo.get(Stop, parent_station_id),
         %Level{} = level <- Repo.get(Level, level_id) do
      descendants =
        descendant_stop_ids_query(
          parent_station.organization_id,
          parent_station.gtfs_version_id,
          parent_station.stop_id
        )

      from(s in Stop,
        where:
          s.stop_id in subquery(descendants) and
            s.organization_id == ^parent_station.organization_id and
            s.gtfs_version_id == ^parent_station.gtfs_version_id,
        order_by: [asc: s.stop_name]
      )
      |> Repo.all()
      |> Enum.map(fn stop ->
        # Add a virtual field indicating if this stop is on the active level
        Map.put(stop, :on_active_level, stop.level_id == level.level_id)
      end)
    else
      _ -> []
    end
  end

  @doc """
  Returns pathways where the from_stop is on the specified level
  and both endpoints belong to the specified parent station.

  ## Examples

      iex> list_pathways_for_level(org_id, version_id, level_id, parent_station_id)
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  def list_pathways_for_level(organization_id, gtfs_version_id, level_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)
    level = Repo.get!(Level, level_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    from(p in Pathway,
      join: from_stop in Stop,
      on:
        p.from_stop_id == from_stop.stop_id and
          from_stop.organization_id == ^organization_id and
          from_stop.gtfs_version_id == ^gtfs_version_id,
      join: to_stop in Stop,
      on:
        p.to_stop_id == to_stop.stop_id and
          to_stop.organization_id == ^organization_id and
          to_stop.gtfs_version_id == ^gtfs_version_id,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (from_stop.level_id == ^level.level_id or to_stop.level_id == ^level.level_id) and
          from_stop.stop_id in subquery(descendants) and
          to_stop.stop_id in subquery(descendants),
      order_by: [asc: p.pathway_id],
      select: p,
      select_merge: %{from_stop: from_stop, to_stop: to_stop}
    )
    |> Repo.all()
    |> Enum.map(fn pathway ->
      # Add flags indicating if this is a cross-level pathway
      from_on_level = pathway.from_stop.level_id == level.level_id
      to_on_level = pathway.to_stop.level_id == level.level_id
      is_cross_level = from_on_level != to_on_level

      Map.merge(pathway, %{
        is_cross_level: is_cross_level,
        from_on_active_level: from_on_level,
        to_on_active_level: to_on_level
      })
    end)
  end

  @doc """
  Returns pathways that touch the given stop on the specified level.

  Behaves like `list_pathways_for_level/4` but only includes pathways where
  the given `stop_id` is one of the endpoints. Both endpoints must still belong
  to the parent station descendant set and at least one endpoint must be on the
  requested level. Endpoint stops and cross-level flags are populated the same
  way as `list_pathways_for_level/4`.

  ## Examples

      iex> list_pathways_for_stop_on_level(org_id, version_id, level_id, parent_station_id, "stop_123")
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  @spec list_pathways_for_stop_on_level(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t()
        ) :: [GtfsPlanner.Gtfs.Pathway.t() | map()]
  def list_pathways_for_stop_on_level(
        organization_id,
        gtfs_version_id,
        level_id,
        parent_station_id,
        stop_id
      ) do
    parent_station = Repo.get!(Stop, parent_station_id)
    level = Repo.get!(Level, level_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    from(p in Pathway,
      join: from_stop in Stop,
      on:
        p.from_stop_id == from_stop.stop_id and
          from_stop.organization_id == ^organization_id and
          from_stop.gtfs_version_id == ^gtfs_version_id,
      join: to_stop in Stop,
      on:
        p.to_stop_id == to_stop.stop_id and
          to_stop.organization_id == ^organization_id and
          to_stop.gtfs_version_id == ^gtfs_version_id,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id == ^stop_id or p.to_stop_id == ^stop_id) and
          (from_stop.level_id == ^level.level_id or to_stop.level_id == ^level.level_id) and
          from_stop.stop_id in subquery(descendants) and
          to_stop.stop_id in subquery(descendants),
      order_by: [asc: p.pathway_id],
      select: p,
      select_merge: %{from_stop: from_stop, to_stop: to_stop}
    )
    |> Repo.all()
    |> Enum.map(fn pathway ->
      # Add flags indicating if this is a cross-level pathway
      from_on_level = pathway.from_stop.level_id == level.level_id
      to_on_level = pathway.to_stop.level_id == level.level_id
      is_cross_level = from_on_level != to_on_level

      Map.merge(pathway, %{
        is_cross_level: is_cross_level,
        from_on_active_level: from_on_level,
        to_on_active_level: to_on_level
      })
    end)
  end

  @doc """
  Returns pathways where from_stop or to_stop is a child of the given station.

  ## Examples

      iex> list_pathways_for_station(org_id, version_id, parent_id)
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  def list_pathways_for_station(organization_id, gtfs_version_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    from(p in Pathway,
      join: from_stop in Stop,
      on:
        p.from_stop_id == from_stop.stop_id and
          from_stop.organization_id == ^organization_id and
          from_stop.gtfs_version_id == ^gtfs_version_id,
      join: to_stop in Stop,
      on:
        p.to_stop_id == to_stop.stop_id and
          to_stop.organization_id == ^organization_id and
          to_stop.gtfs_version_id == ^gtfs_version_id,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id in subquery(descendants) or
             p.to_stop_id in subquery(descendants)),
      order_by: [asc: p.pathway_id],
      select: p,
      select_merge: %{from_stop: from_stop, to_stop: to_stop}
    )
    |> Repo.all()
  end

  defp descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id) do
    direct_child_ids =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.parent_station == ^station_stop_id,
        select: s.stop_id
      )

    from(s in Stop,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          (s.parent_station == ^station_stop_id or
             (s.location_type == 4 and s.parent_station in subquery(direct_child_ids))),
      select: s.stop_id
    )
  end

  @doc """
  Returns pathways where the given stop_id is either the from_stop or to_stop.

  ## Examples

      iex> list_pathways_for_stop(org_id, version_id, "stop_123")
      [%Pathway{}, ...]
  """
  def list_pathways_for_stop(organization_id, gtfs_version_id, stop_id) do
    from(p in Pathway,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id == ^stop_id or p.to_stop_id == ^stop_id),
      order_by: [asc: p.pathway_id]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of pathways for an organization and GTFS version.
  """
  def count_pathways(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  def list_pathways(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: p.pathway_id]
    )
    |> Repo.all()
  end

  @doc """
  Creates a pathway.

  ## Examples

      iex> create_pathway(%{pathway_id: "P1", pathway_mode: 1, ...})
      {:ok, %Pathway{}}
  """
  def create_pathway(attrs \\ %{}) do
    %Pathway{}
    |> Pathway.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:pathways, :created])
  end

  @doc """
  Gets a single pathway.

  Raises `Ecto.NoResultsError` if the Pathway does not exist.

  ## Examples

      iex> get_pathway!(id)
      %Pathway{}

      iex> get_pathway!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_pathway!(id), do: Repo.get!(Pathway, id)

  @doc """
  Gets a single pathway, returning `nil` if it does not exist.
  """
  def get_pathway(id), do: Repo.get(Pathway, id)

  @doc """
  Gets a single pathway by its GTFS pathway_id within an org+version scope.

  Returns `nil` if no matching pathway exists.
  """
  def get_pathway_by_pathway_id(organization_id, gtfs_version_id, pathway_id) do
    from(p in Pathway,
      where:
        p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id and
          p.pathway_id == ^pathway_id
    )
    |> Repo.one()
  end

  @doc """
  Gets a single pathway with manually populated from_stop and to_stop.

  Raises `Ecto.NoResultsError` if the Pathway does not exist.

  ## Examples

      iex> get_pathway_with_stops!(id)
      %Pathway{from_stop: %Stop{}, to_stop: %Stop{}}

      iex> get_pathway_with_stops!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_pathway_with_stops!(id) do
    pathway = Repo.get!(Pathway, id)

    from_stop =
      get_stop_by_stop_id(pathway.organization_id, pathway.gtfs_version_id, pathway.from_stop_id)

    to_stop =
      get_stop_by_stop_id(pathway.organization_id, pathway.gtfs_version_id, pathway.to_stop_id)

    %{pathway | from_stop: from_stop, to_stop: to_stop}
  end

  @doc """
  Updates a pathway.

  ## Examples

      iex> update_pathway(pathway, %{pathway_mode: 2})
      {:ok, %Pathway{}}

      iex> update_pathway(pathway, %{pathway_mode: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_pathway(%Pathway{} = pathway, attrs) do
    pathway
    |> Pathway.changeset(attrs)
    |> Repo.update()
    |> broadcast([:pathways, :updated])
  end

  @doc """
  Deletes a pathway.

  Returns `{:error, :pathway_in_use}` when a scheduled closure references the
  pathway instead of raising the step-1 `ON DELETE RESTRICT` violation.

  ## Examples

      iex> delete_pathway(pathway)
      {:ok, %Pathway{}}

      iex> delete_pathway(pathway)
      {:error, :pathway_in_use}
  """
  @spec delete_pathway(Pathway.t()) ::
          {:ok, Pathway.t()} | {:error, :pathway_in_use | Ecto.Changeset.t()}
  def delete_pathway(%Pathway{} = pathway) do
    delete_pathway_record(pathway)
    |> broadcast([:pathways, :deleted])
  end

  # Shared step-6 deletion guard (R1-F4): scoped closure precheck plus a
  # named-FK-mapped delete, so a closure inserted after the check still
  # returns :pathway_in_use instead of raising. No broadcast here, so import
  # apply can reuse it inside its own fenced transaction.
  defp delete_pathway_record(%Pathway{} = pathway) do
    if pathway_closure_exists?(
         pathway.organization_id,
         pathway.gtfs_version_id,
         pathway.pathway_id
       ) do
      {:error, :pathway_in_use}
    else
      pathway
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:pathway_id,
        name: :pathway_evolutions_pathway_fkey
      )
      |> Repo.delete()
      |> pathway_delete_result()
    end
  end

  defp pathway_delete_result({:ok, _deleted} = ok), do: ok

  defp pathway_delete_result({:error, %Ecto.Changeset{} = changeset}) do
    if closure_constraint_error?(changeset) do
      {:error, :pathway_in_use}
    else
      {:error, changeset}
    end
  end

  # Agency functions

  @doc """
  Returns the count of agencies for an organization and GTFS version.
  """
  def count_agencies(organization_id, gtfs_version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of agencies for an organization and GTFS version.
  """
  def list_agencies(organization_id, gtfs_version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: a.agency_name]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single agency by UUID.
  """
  def get_agency!(id), do: Repo.get!(Agency, id)

  @doc """
  Gets an agency by its agency_id within an organization and GTFS version.
  """
  def get_agency_by_agency_id(organization_id, gtfs_version_id, agency_id) do
    from(a in Agency,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          a.agency_id == ^agency_id
    )
    |> Repo.one()
  end

  @doc """
  Creates an agency.

  ## Examples

      iex> create_agency(%{organization_id: org_id, gtfs_version_id: version_id, agency_name: "Transit Agency"})
      {:ok, %Agency{}}

      iex> create_agency(%{agency_name: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_agency(attrs \\ %{}) do
    %Agency{}
    |> Agency.changeset(attrs)
    |> insert_with_input_write_lock()
  end

  # Display clock functions

  @doc """
  Resolves the display timezone for an organization and GTFS version.

  See `GtfsPlanner.Gtfs.DisplayClock.resolve_zone/2`.
  """
  @spec resolve_display_zone(Ecto.UUID.t(), Ecto.UUID.t()) :: DisplayClock.zone_resolution()
  defdelegate resolve_display_zone(organization_id, gtfs_version_id),
    to: DisplayClock,
    as: :resolve_zone

  @doc """
  Localizes stored UTC timestamps for display, preserving input order.

  See `GtfsPlanner.Gtfs.DisplayClock.localize_many/2`.
  """
  @spec localize_display_times([DateTime.t()], DisplayClock.zone_resolution()) :: [
          NaiveDateTime.t()
        ]
  defdelegate localize_display_times(timestamps, zone_resolution),
    to: DisplayClock,
    as: :localize_many

  @doc """
  Formats a localized time as unpadded 12-hour time with uppercase AM/PM.

  See `GtfsPlanner.Gtfs.DisplayClock.format_time/2`.
  """
  @spec format_display_time(NaiveDateTime.t(), keyword()) :: String.t()
  defdelegate format_display_time(local_time, opts \\ []), to: DisplayClock, as: :format_time

  # Recent change functions

  @doc """
  Returns up to five recent destination groups for one audience, newest first.

  See `GtfsPlanner.Gtfs.RecentChanges.recent/4`.
  """
  @spec recent_changes(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          :everyone | {:actor, Ecto.UUID.t()},
          DisplayClock.zone_resolution()
        ) :: [RecentChanges.group()]
  defdelegate recent_changes(organization_id, gtfs_version_id, audience, zone_resolution),
    to: RecentChanges,
    as: :recent

  @doc """
  Returns the actor's own recent groups, or the team's when the actor has none.

  See `GtfsPlanner.Gtfs.RecentChanges.recent_for_user/4`.
  """
  @spec recent_changes_for_user(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          DisplayClock.zone_resolution()
        ) :: %{scope: :own | :team, groups: [RecentChanges.group()]}
  defdelegate recent_changes_for_user(
                organization_id,
                gtfs_version_id,
                actor_id,
                zone_resolution
              ),
              to: RecentChanges,
              as: :recent_for_user

  @doc """
  Counts distinct operations and distinct non-null stations changed after `since`.

  See `GtfsPlanner.Gtfs.RecentChanges.count_since/3`.
  """
  @spec count_changes_since(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: %{
          changes: non_neg_integer(),
          stations: non_neg_integer()
        }
  defdelegate count_changes_since(organization_id, gtfs_version_id, since),
    to: RecentChanges,
    as: :count_since

  # Station board functions

  @doc """
  Returns one station board summary per station of the version, sorted by `stop_id`.

  See `GtfsPlanner.Gtfs.StationBoard.base/2`.
  """
  @spec station_board_base(Ecto.UUID.t(), Ecto.UUID.t()) :: [StationBoard.base()]
  defdelegate station_board_base(organization_id, gtfs_version_id),
    to: StationBoard,
    as: :base

  # Area functions

  @doc """
  Returns the list of areas for an organization and GTFS version.
  """
  def list_areas(organization_id, gtfs_version_id) do
    from(a in Area,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: a.area_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single area by UUID.
  """
  def get_area!(id), do: Repo.get!(Area, id)

  @doc """
  Gets an area by its area_id within an organization and GTFS version.
  """
  def get_area_by_area_id(organization_id, gtfs_version_id, area_id) do
    from(a in Area,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          a.area_id == ^area_id
    )
    |> Repo.one()
  end

  # Attribution functions

  @doc """
  Returns the count of attributions for an organization and GTFS version.
  """
  def count_attributions(organization_id, gtfs_version_id) do
    from(a in Attribution,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of attributions for an organization and GTFS version.
  """
  def list_attributions(organization_id, gtfs_version_id) do
    from(a in Attribution,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single attribution by UUID.
  """
  def get_attribution!(id), do: Repo.get!(Attribution, id)

  # BookingRule functions

  @doc """
  Returns the list of booking rules for an organization and GTFS version.
  """
  def list_booking_rules(organization_id, gtfs_version_id) do
    from(b in BookingRule,
      where: b.organization_id == ^organization_id and b.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: b.booking_rule_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single booking rule by UUID.
  """
  def get_booking_rule!(id), do: Repo.get!(BookingRule, id)

  @doc """
  Gets a booking rule by its booking_rule_id within an organization and GTFS version.
  """
  def get_booking_rule_by_booking_rule_id(organization_id, gtfs_version_id, booking_rule_id) do
    from(b in BookingRule,
      where:
        b.organization_id == ^organization_id and b.gtfs_version_id == ^gtfs_version_id and
          b.booking_rule_id == ^booking_rule_id
    )
    |> Repo.one()
  end

  # FareAttribute functions

  @doc """
  Returns the count of fare attributes for an organization and GTFS version.
  """
  def count_fare_attributes(organization_id, gtfs_version_id) do
    from(f in FareAttribute,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of fare attributes for an organization and GTFS version.
  """
  def list_fare_attributes(organization_id, gtfs_version_id) do
    from(f in FareAttribute,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare attribute by UUID.
  """
  def get_fare_attribute!(id), do: Repo.get!(FareAttribute, id)

  @doc """
  Gets a fare attribute by its fare_id within an organization and GTFS version.
  """
  def get_fare_attribute_by_fare_id(organization_id, gtfs_version_id, fare_id) do
    from(f in FareAttribute,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
          f.fare_id == ^fare_id
    )
    |> Repo.one()
  end

  # FareLegJoinRule functions

  @doc """
  Returns the list of fare leg join rules for an organization and GTFS version.
  """
  def list_fare_leg_join_rules(organization_id, gtfs_version_id) do
    from(f in FareLegJoinRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare leg join rule by UUID.
  """
  def get_fare_leg_join_rule!(id), do: Repo.get!(FareLegJoinRule, id)

  # FareLegRule functions

  @doc """
  Returns the list of fare leg rules for an organization and GTFS version.
  """
  def list_fare_leg_rules(organization_id, gtfs_version_id) do
    from(f in FareLegRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare leg rule by UUID.
  """
  def get_fare_leg_rule!(id), do: Repo.get!(FareLegRule, id)

  # FareMedia functions

  @doc """
  Returns the list of fare media for an organization and GTFS version.
  """
  def list_fare_media(organization_id, gtfs_version_id) do
    from(f in FareMedia,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_media_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare media by UUID.
  """
  def get_fare_media!(id), do: Repo.get!(FareMedia, id)

  @doc """
  Gets a fare media by its fare_media_id within an organization and GTFS version.
  """
  def get_fare_media_by_fare_media_id(organization_id, gtfs_version_id, fare_media_id) do
    from(f in FareMedia,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
          f.fare_media_id == ^fare_media_id
    )
    |> Repo.one()
  end

  # FareProduct functions

  @doc """
  Returns the list of fare products for an organization and GTFS version.
  """
  def list_fare_products(organization_id, gtfs_version_id) do
    from(f in FareProduct,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_product_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare product by UUID.
  """
  def get_fare_product!(id), do: Repo.get!(FareProduct, id)

  # FareRule functions

  @doc """
  Returns the count of fare rules for an organization and GTFS version.
  """
  def count_fare_rules(organization_id, gtfs_version_id) do
    from(f in FareRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of fare rules for an organization and GTFS version.
  """
  def list_fare_rules(organization_id, gtfs_version_id) do
    from(f in FareRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare rule by UUID.
  """
  def get_fare_rule!(id), do: Repo.get!(FareRule, id)

  # FareTransferRule functions

  @doc """
  Returns the list of fare transfer rules for an organization and GTFS version.
  """
  def list_fare_transfer_rules(organization_id, gtfs_version_id) do
    from(f in FareTransferRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare transfer rule by UUID.
  """
  def get_fare_transfer_rule!(id), do: Repo.get!(FareTransferRule, id)

  # FeedInfo functions

  @doc """
  Returns the count of feed info for an organization and GTFS version.
  """
  def count_feed_info(organization_id, gtfs_version_id) do
    from(f in FeedInfo,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the feed info for an organization and GTFS version.
  """
  def get_feed_info(organization_id, gtfs_version_id) do
    from(f in FeedInfo,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  @doc """
  Gets a single feed info by UUID.
  """
  def get_feed_info!(id), do: Repo.get!(FeedInfo, id)

  # Frequency functions

  @doc """
  Returns the count of frequencies for an organization and GTFS version.
  """
  def count_frequencies(organization_id, gtfs_version_id) do
    from(f in Frequency,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of frequencies for an organization and GTFS version.
  """
  def list_frequencies(organization_id, gtfs_version_id) do
    from(f in Frequency,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.trip_id, asc: f.start_time]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single frequency by UUID.
  """
  def get_frequency!(id), do: Repo.get!(Frequency, id)

  # Location functions

  @doc """
  Returns the list of locations for an organization and GTFS version.
  """
  def list_locations(organization_id, gtfs_version_id) do
    from(l in Location,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: l.location_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single location by UUID.
  """
  def get_location!(id), do: Repo.get!(Location, id)

  @doc """
  Gets a location by its location_id within an organization and GTFS version.
  """
  def get_location_by_location_id(organization_id, gtfs_version_id, location_id) do
    from(l in Location,
      where:
        l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id and
          l.location_id == ^location_id
    )
    |> Repo.one()
  end

  # Network functions

  @doc """
  Returns the list of networks for an organization and GTFS version.
  """
  def list_networks(organization_id, gtfs_version_id) do
    from(n in Network,
      where: n.organization_id == ^organization_id and n.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: n.network_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single network by UUID.
  """
  def get_network!(id), do: Repo.get!(Network, id)

  @doc """
  Gets a network by its network_id within an organization and GTFS version.
  """
  def get_network_by_network_id(organization_id, gtfs_version_id, network_id) do
    from(n in Network,
      where:
        n.organization_id == ^organization_id and n.gtfs_version_id == ^gtfs_version_id and
          n.network_id == ^network_id
    )
    |> Repo.one()
  end

  # RiderCategory functions

  @doc """
  Returns the list of rider categories for an organization and GTFS version.
  """
  def list_rider_categories(organization_id, gtfs_version_id) do
    from(r in RiderCategory,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: r.rider_category_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single rider category by UUID.
  """
  def get_rider_category!(id), do: Repo.get!(RiderCategory, id)

  @doc """
  Gets a rider category by its rider_category_id within an organization and GTFS version.
  """
  def get_rider_category_by_rider_category_id(organization_id, gtfs_version_id, rider_category_id) do
    from(r in RiderCategory,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.rider_category_id == ^rider_category_id
    )
    |> Repo.one()
  end

  # RouteNetwork functions

  @doc """
  Returns the list of route networks for an organization and GTFS version.
  """
  def list_route_networks(organization_id, gtfs_version_id) do
    from(r in RouteNetwork,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: r.network_id, asc: r.route_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single route network by UUID.
  """
  def get_route_network!(id), do: Repo.get!(RouteNetwork, id)

  # Shape functions

  @doc """
  Returns the count of shapes for an organization and GTFS version.
  """
  def count_shapes(organization_id, gtfs_version_id) do
    from(s in Shape,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of shapes for an organization and GTFS version.
  """
  def list_shapes(organization_id, gtfs_version_id) do
    from(s in Shape,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.shape_id, asc: s.shape_pt_sequence]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single shape by UUID.
  """
  def get_shape!(id), do: Repo.get!(Shape, id)

  # StopArea functions

  @doc """
  Returns the list of stop areas for an organization and GTFS version.
  """
  def list_stop_areas(organization_id, gtfs_version_id) do
    from(s in StopArea,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.area_id, asc: s.stop_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single stop area by UUID.
  """
  def get_stop_area!(id), do: Repo.get!(StopArea, id)

  # Timeframe functions

  @doc """
  Returns the list of timeframes for an organization and GTFS version.
  """
  def list_timeframes(organization_id, gtfs_version_id) do
    from(t in Timeframe,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.timeframe_group_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single timeframe by UUID.
  """
  def get_timeframe!(id), do: Repo.get!(Timeframe, id)

  # Transfer functions

  @doc """
  Returns the count of transfers for an organization and GTFS version.
  """
  def count_transfers(organization_id, gtfs_version_id) do
    from(t in Transfer,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of transfers for an organization and GTFS version.
  """
  def list_transfers(organization_id, gtfs_version_id) do
    from(t in Transfer,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.from_stop_id, asc: t.to_stop_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single transfer by UUID.
  """
  def get_transfer!(id), do: Repo.get!(Transfer, id)

  # Translation functions

  @doc """
  Returns the list of translations for an organization and GTFS version.
  """
  def list_translations(organization_id, gtfs_version_id) do
    from(t in Translation,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.table_name, asc: t.field_name, asc: t.language]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single translation by UUID.
  """
  def get_translation!(id), do: Repo.get!(Translation, id)

  # Trip functions

  @doc """
  Returns the count of trips for an organization and GTFS version.
  """
  def count_trips(organization_id, gtfs_version_id) do
    from(t in Trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates a trip.
  """
  def create_trip(attrs \\ %{}) do
    %Trip{}
    |> Trip.changeset(attrs)
    |> insert_with_input_write_lock()
  end

  # StopTime functions

  @doc """
  Returns the count of stop times for an organization and GTFS version.
  """
  def count_stop_times(organization_id, gtfs_version_id) do
    from(s in StopTime,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates a stop time.
  """
  def create_stop_time(attrs \\ %{}) do
    %StopTime{}
    |> StopTime.changeset(attrs)
    |> insert_with_input_write_lock()
  end

  # Calendar functions

  @doc """
  Returns the count of calendars for an organization and GTFS version.
  """
  def count_calendars(organization_id, gtfs_version_id) do
    from(c in Calendar,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  # CalendarDate functions

  @doc """
  Returns the count of calendar dates for an organization and GTFS version.
  """
  def count_calendar_dates(organization_id, gtfs_version_id) do
    from(c in CalendarDate,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  # CalendarAttribute functions

  @doc """
  Returns the count of calendar attributes for an organization and GTFS version.
  """
  def count_calendar_attributes(organization_id, gtfs_version_id) do
    from(c in CalendarAttribute,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc "Returns the scoped trip usage of one calendar identity grouped by route."
  def calendar_usage(organization_id, gtfs_version_id, service_id),
    do: Calendars.calendar_usage(organization_id, gtfs_version_id, service_id)

  @doc "Returns the owning station stop ids of each pathway by scoped endpoint ancestry."
  def pathway_station_ids(organization_id, gtfs_version_id, pathway_ids),
    do: Calendars.pathway_station_ids(organization_id, gtfs_version_id, pathway_ids)

  @doc "Returns the version's maximal civil-date runs with no calendar service."
  def feed_service_gaps(organization_id, gtfs_version_id, today),
    do: Calendars.feed_service_gaps(organization_id, gtfs_version_id, today)

  @doc "Lists the unified scoped calendars of one published organization/version."
  def list_calendars(organization_id, gtfs_version_id, opts \\ []),
    do: Calendars.list_calendars(organization_id, gtfs_version_id, opts)

  @doc "Resolves the agency-local today and the version-wide calendar service gaps for the list."
  def load_calendar_feed_status(organization_id, gtfs_version_id),
    do: catalog_read_adapter().load_calendar_feed_status(organization_id, gtfs_version_id)

  @doc "Loads one calendar identity as its weekly row, anchor, exceptions and fingerprint."
  def get_calendar(organization_id, gtfs_version_id, service_id),
    do: Calendars.get_calendar(organization_id, gtfs_version_id, service_id)

  @doc "Creates one weekly or dates-only calendar under the scoped write lock."
  def create_calendar(attrs, %AuditContext{} = audit_context),
    do: Calendars.create_calendar(attrs, audit_context)

  @doc "Duplicates one calendar identity under the scoped write lock."
  def duplicate_calendar(service_id, attrs, %AuditContext{} = audit_context),
    do: Calendars.duplicate_calendar(service_id, attrs, audit_context)

  @doc """
  Reviews a calendar command against the caller's retained source fingerprints.

  The reviewed `{:combine, destination_id, source_ids, decisions}` command reads the complete
  protected input set of the version instead of one form source and returns the factual reviewed
  combination - conflicts, per-calendar effects, moved trip count, retained sources and the
  simultaneous block effects - with a fingerprint over those rows. A command whose decisions are
  incomplete has no projected result and no token.
  """
  def review_calendar_change(command, source_fingerprints, %AuditContext{} = audit_context),
    do: Calendars.review_calendar_change(command, source_fingerprints, audit_context)

  @doc """
  Applies a previously reviewed calendar command under the write lock.

  A retained-form command recomputes the reviewed source from current rows and refuses a mismatch
  with `:stale_review`. A reviewed `{:combine, destination_id, source_ids, decisions}` applies in
  one ordinary read-committed transaction and returns
  `%{action: :combined | :unchanged, operation_id: uuid | nil, destination_id: id,
  moved_trip_count: n, changed_trip_ids: [uuid], affected_service_ids: [id]}`; a no-op has a nil
  `operation_id` and writes nothing. A serialization failure or deadlock retries the whole
  transaction at most three times and then returns `:busy`.
  """
  def apply_calendar_change(command, fingerprint, %AuditContext{} = audit_context),
    do: Calendars.apply_calendar_change(command, fingerprint, audit_context)

  def get_file_inventory(organization_id, gtfs_version_id, export_type) do
    if export_type == :pathways do
      [
        {"stops.txt", count_stops(organization_id, gtfs_version_id)},
        {"levels.txt", count_levels(organization_id, gtfs_version_id)},
        {"pathways.txt", count_pathways(organization_id, gtfs_version_id)}
      ]
    else
      [
        {"agency.txt", count_agencies(organization_id, gtfs_version_id)},
        {"stops.txt", count_stops(organization_id, gtfs_version_id)},
        {"routes.txt", count_routes(organization_id, gtfs_version_id)},
        {"trips.txt", count_trips(organization_id, gtfs_version_id)},
        {"stop_times.txt", count_stop_times(organization_id, gtfs_version_id)},
        {"calendar.txt", count_calendars(organization_id, gtfs_version_id)},
        {"calendar_dates.txt", count_calendar_dates(organization_id, gtfs_version_id)},
        {"calendar_attributes.txt", count_calendar_attributes(organization_id, gtfs_version_id)},
        {"fare_attributes.txt", count_fare_attributes(organization_id, gtfs_version_id)},
        {"fare_rules.txt", count_fare_rules(organization_id, gtfs_version_id)},
        {"shapes.txt", count_shapes(organization_id, gtfs_version_id)},
        {"frequencies.txt", count_frequencies(organization_id, gtfs_version_id)},
        {"transfers.txt", count_transfers(organization_id, gtfs_version_id)},
        {"pathways.txt", count_pathways(organization_id, gtfs_version_id)},
        {"levels.txt", count_levels(organization_id, gtfs_version_id)},
        {"feed_info.txt", count_feed_info(organization_id, gtfs_version_id)},
        {"attributions.txt", count_attributions(organization_id, gtfs_version_id)}
      ] ++
        Enum.map(
          [
            {"fare_products.txt", FareProduct},
            {"fare_media.txt", FareMedia},
            {"fare_leg_rules.txt", FareLegRule},
            {"fare_leg_join_rules.txt", FareLegJoinRule},
            {"fare_transfer_rules.txt", FareTransferRule},
            {"rider_categories.txt", RiderCategory},
            {"timeframes.txt", Timeframe},
            {"areas.txt", Area},
            {"stop_areas.txt", StopArea},
            {"networks.txt", Network},
            {"route_networks.txt", RouteNetwork},
            {"locations.txt", Location},
            {"booking_rules.txt", BookingRule},
            {"translations.txt", Translation},
            {"pathway_evolutions.txt", PathwayEvolution}
          ],
          fn {filename, schema} ->
            {filename, count_version_rows(schema, organization_id, gtfs_version_id)}
          end
        )
    end
  end

  defp count_version_rows(schema, organization_id, gtfs_version_id) do
    from(r in schema,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  # Private helper functions

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, ""), do: query

  defp maybe_filter_type(query, route_type) do
    where(query, [r], r.route_type == ^route_type)
  end

  defp maybe_filter_agency(query, nil), do: query
  defp maybe_filter_agency(query, ""), do: query

  defp maybe_filter_agency(query, agency_id) do
    where(query, [r], r.agency_id == ^agency_id)
  end

  # Shared list/count status predicate: only explicit false is inactive, so
  # Active is `active IS DISTINCT FROM FALSE` (true or NULL) and Inactive is
  # `active = false`. Both `list_routes/3` and `count_routes/3` funnel through
  # here so filtered counts always match filtered rows.
  defp maybe_filter_active(query, active) do
    case normalize_route_status_filter(active) do
      "true" -> where(query, [r], fragment("? IS DISTINCT FROM FALSE", r.active))
      "false" -> where(query, [r], r.active == false)
      "" -> query
    end
  end

  defp maybe_filter_wheelchair(query, nil), do: query
  defp maybe_filter_wheelchair(query, ""), do: query

  # GTFS treats an empty wheelchair_boarding the same as 0 (no information).
  defp maybe_filter_wheelchair(query, value) when value in [0, "0"] do
    where(query, [s], s.wheelchair_boarding == 0 or is_nil(s.wheelchair_boarding))
  end

  defp maybe_filter_wheelchair(query, wheelchair_boarding) do
    where(query, [s], s.wheelchair_boarding == ^wheelchair_boarding)
  end

  defp maybe_filter_location_type(query, nil), do: query
  defp maybe_filter_location_type(query, ""), do: query

  defp maybe_filter_location_type(query, location_type) do
    where(query, [s], s.location_type == ^location_type)
  end

  defp maybe_filter_route(query, nil, _organization_id, _gtfs_version_id), do: query
  defp maybe_filter_route(query, "", _organization_id, _gtfs_version_id), do: query

  defp maybe_filter_route(query, route_id, organization_id, gtfs_version_id) do
    # Step 1: Get representative trip_ids from route_patterns (typically 2-4 trips)
    # This is much faster than scanning all trips for a route
    representative_trip_ids =
      from(rp in RoutePattern,
        where:
          rp.route_id == ^route_id and
            rp.organization_id == ^organization_id and
            rp.gtfs_version_id == ^gtfs_version_id and
            not is_nil(rp.representative_trip_id),
        select: rp.representative_trip_id
      )
      |> Repo.all()

    # Step 2: Get stop_ids using route_patterns (fast) or all trips (fallback)
    stop_ids =
      if representative_trip_ids != [] do
        # Fast path: Query only 2-4 representative trips
        from(st in StopTime,
          where:
            st.trip_id in ^representative_trip_ids and
              st.organization_id == ^organization_id and
              st.gtfs_version_id == ^gtfs_version_id,
          distinct: true,
          select: st.stop_id
        )
        |> Repo.all()
      else
        # Fallback: For data without route_patterns, query all trips
        from(st in StopTime,
          join: t in Trip,
          on:
            st.trip_id == t.trip_id and
              st.organization_id == t.organization_id and
              st.gtfs_version_id == t.gtfs_version_id,
          where:
            t.route_id == ^route_id and
              t.organization_id == ^organization_id and
              t.gtfs_version_id == ^gtfs_version_id,
          distinct: true,
          select: st.stop_id
        )
        |> Repo.all()
      end

    # Step 3: Filter stops using IN clause (efficient with index)
    where(query, [s], s.stop_id in ^stop_ids)
  end

  defp maybe_filter_direction(query, nil, _organization_id, _gtfs_version_id), do: query
  defp maybe_filter_direction(query, "", _organization_id, _gtfs_version_id), do: query

  defp maybe_filter_direction(query, direction_id, organization_id, gtfs_version_id) do
    # Filter stations by direction_id
    # Find stops that are served by trips with the specified direction_id
    stop_ids =
      from(st in StopTime,
        join: t in Trip,
        on:
          st.trip_id == t.trip_id and
            st.organization_id == t.organization_id and
            st.gtfs_version_id == t.gtfs_version_id,
        where:
          t.direction_id == ^direction_id and
            t.organization_id == ^organization_id and
            t.gtfs_version_id == ^gtfs_version_id,
        distinct: true,
        select: st.stop_id
      )
      |> Repo.all()

    where(query, [s], s.stop_id in ^stop_ids)
  end

  defp maybe_search_stops(query, nil), do: query
  defp maybe_search_stops(query, ""), do: query

  defp maybe_search_stops(query, term) do
    pattern = "%#{term}%"
    where(query, [s], ilike(s.stop_id, ^pattern) or ilike(s.stop_name, ^pattern))
  end

  defp apply_stop_sort(query, sort_by, sort_dir)
       when sort_by in [:stop_id, :stop_name, :location_type] and sort_dir in [:asc, :desc] do
    order_by(query, [s], [{^sort_dir, field(s, ^sort_by)}, asc: s.stop_id])
  end

  # Equal sort keys must not leave the page order to the database.
  defp apply_stop_sort(query, _sort_by, _sort_dir) do
    order_by(query, [s], asc: s.stop_name, asc: s.stop_id)
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, term) do
    search_pattern = "%#{term}%"

    where(
      query,
      [r],
      ilike(r.route_id, ^search_pattern) or
        ilike(r.route_short_name, ^search_pattern) or
        ilike(r.route_long_name, ^search_pattern)
    )
  end

  defp apply_sort(query, nil, _sort_dir), do: order_by(query, [r], asc: r.route_id)
  defp apply_sort(query, _sort_by, nil), do: order_by(query, [r], asc: r.route_id)

  defp apply_sort(query, sort_by, sort_dir)
       when sort_by in [:route_id, :route_short_name, :route_long_name, :route_type, :active] and
              sort_dir in [:asc, :desc] do
    order_by(query, [r], [{^sort_dir, field(r, ^sort_by)}])
  end

  defp apply_sort(query, _sort_by, _sort_dir), do: order_by(query, [r], asc: r.route_id)

  # Resolved per call so tests and future runtime configuration take effect
  # without recompiling this context.
  defp catalog_read_adapter do
    Application.get_env(
      :gtfs_planner,
      :gtfs_catalog_read_adapter,
      @default_catalog_read_adapter
    )
  end

  defp paginate(query, nil, _per_page), do: paginate(query, 1, 25)
  defp paginate(query, _page, nil), do: paginate(query, 1, 25)

  defp paginate(query, page, per_page) when is_integer(page) and is_integer(per_page) do
    offset = (page - 1) * per_page
    query |> limit(^per_page) |> offset(^offset)
  end

  defp paginate(query, _page, _per_page), do: paginate(query, 1, 25)

  defp delete_pathways_for_stop_multi(multi, organization_id, gtfs_version_id, stop_id) do
    pathway_query =
      organization_id
      |> pathways_for_stop_query(gtfs_version_id, stop_id)
      |> select([p], p)

    Ecto.Multi.delete_all(multi, :pathways, pathway_query)
  end

  # Step-6 precheck (R1-F4) shared by delete_child_stop/4 and
  # remove_child_stop_from_diagram/4. It runs before the Multi because a
  # failing Multi.run step rolls back the ambient outer transaction. A
  # closure inserted after this check still surfaces as :pathway_in_use
  # through the named-FK rescue at the outer boundary.
  defp check_pathways_closure_free(organization_id, gtfs_version_id, stop_id) do
    pathway_ids =
      Repo.all(
        from(p in Pathway,
          where:
            p.organization_id == ^organization_id and
              p.gtfs_version_id == ^gtfs_version_id and
              (p.from_stop_id == ^stop_id or p.to_stop_id == ^stop_id),
          select: p.pathway_id
        )
      )

    closure_exists? =
      pathway_ids != [] and
        Repo.exists?(
          from(e in PathwayEvolution,
            where:
              e.organization_id == ^organization_id and
                e.gtfs_version_id == ^gtfs_version_id and e.pathway_id in ^pathway_ids
          )
        )

    if closure_exists?, do: {:error, :pathway_in_use}, else: :ok
  end

  defp pathways_for_stop_query(organization_id, gtfs_version_id, stop_id) do
    from(p in Pathway,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id == ^stop_id or p.to_stop_id == ^stop_id)
    )
  end

  defp pathway_closure_exists?(organization_id, gtfs_version_id, pathway_id) do
    from(e in PathwayEvolution,
      where:
        e.organization_id == ^organization_id and
          e.gtfs_version_id == ^gtfs_version_id and e.pathway_id == ^pathway_id
    )
    |> Repo.exists?()
  end

  defp closure_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:pathway_id, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :foreign_key and
          Keyword.get(opts, :constraint_name) == "pathway_evolutions_pathway_fkey"

      _other ->
        false
    end)
  end

  # Matches only the step-1 closure FK after the owning transaction has
  # rolled back. Any other constraint or driver error is reraised. The code
  # allowlist covers both historic 23503 and the newer 23001
  # restrict_violation that ON DELETE RESTRICT now reports.
  defp closure_reference_violation?(%Ecto.ConstraintError{
         type: :foreign_key,
         constraint: constraint
       }),
       do: to_string(constraint) == "pathway_evolutions_pathway_fkey"

  defp closure_reference_violation?(%Postgrex.Error{postgres: postgres}),
    do:
      Map.get(postgres, :constraint) == "pathway_evolutions_pathway_fkey" and
        to_string(Map.get(postgres, :code)) in [
          "restrict_violation",
          "foreign_key_violation",
          "23001",
          "23503"
        ]

  defp closure_reference_violation?(_other), do: false

  # ============================================================================
  # Blocks
  # ============================================================================

  @doc """
  Loads one day type's blocks, pool and checks through the configured catalog read adapter.

  The read derives the published version's day types, selects `day_type_key` (`nil`
  selects the first in list order) and returns every trip of that day type exactly
  once, in the block named by its `block_id` or in the pool, together with the
  day's findings, counts, peak and timeline axis. A foreign or unpublished version
  is `{:error, :not_found}`, an unknown key `{:error, {:unknown_day_type, day_types}}`
  and a lost database connection `{:error, :unavailable}`.
  """
  @spec load_blocking_day(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Blocking.day()}
          | {:error,
             :not_found
             | {:unknown_day_type, [GtfsPlanner.Gtfs.Blocking.DayTypes.day_type()]}
             | :unavailable}
  def load_blocking_day(organization_id, gtfs_version_id, day_type_key) do
    catalog_read_adapter().load_blocking_day(organization_id, gtfs_version_id, day_type_key)
  end

  @doc """
  Returns the current block errors and warnings involving the given trips.

  Natural trip IDs name the trips; for each one that runs in a block, every day
  type its service runs in is checked and the type 4/5 records naming it are
  evaluated, so the answer covers every date the trip runs, not only the one on
  screen. Each problem carries its code, block ID, day-type keys and the number of
  dates it affects, errors before warnings. The read takes no lock: it is advisory
  and never decides whether a write may proceed. A foreign or unpublished version
  is `{:error, :not_found}` and a lost database connection `{:error, :unavailable}`.
  """
  @spec block_problems_for_trips(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) ::
          {:ok, [Blocking.problem()]} | {:error, :not_found | :unavailable}
  def block_problems_for_trips(organization_id, gtfs_version_id, trip_ids) do
    catalog_read_adapter().block_problems_for_trips(organization_id, gtfs_version_id, trip_ids)
  end

  @doc """
  Returns the key of the first day type containing a service, or `:none`.

  The key is derived from the published version's calendars through the same
  `Blocking.DayTypes` derivation every day load uses, so it selects exactly the day
  type it names and never falls back to another (INV-6). A service whose calendar
  has no active date is `{:ok, :none}`; a foreign or unpublished version is
  `{:error, :not_found}` and a lost database connection `{:error, :unavailable}`.
  """
  @spec first_blocking_day_type_key(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, String.t() | :none} | {:error, :not_found | :unavailable}
  def first_blocking_day_type_key(organization_id, gtfs_version_id, service_id) do
    catalog_read_adapter().first_day_type_key(organization_id, gtfs_version_id, service_id)
  end

  @doc """
  Returns every Block rules setting for an organization's GTFS version.

  A version with no stored setting returns the defaults (5 minutes minimum layover,
  no block-length or piece limit, 0 minutes pull-out buffer, any interlining, no
  default garage, 30 km/h deadhead speed at 1.3 circuity); the read never inserts a
  row.
  """
  @spec get_blocking_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: Blocking.settings()
  def get_blocking_settings(organization_id, gtfs_version_id) do
    Blocking.get_settings(organization_id, gtfs_version_id)
  end

  @doc """
  Stores the eight Block rules settings for an organization's published version.

  Every value is range-checked, the interlining value must be one of the three, and
  a `default_garage_id` must be a garage of this organization. The save takes
  `Blocking.lock_blocking!/1` and replaces every settings column of the version's one
  row.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when a value is rejected.
  """
  @spec update_blocking_settings(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, BlockingSetting.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_blocking_settings(organization_id, gtfs_version_id, attrs) do
    Blocking.update_settings(organization_id, gtfs_version_id, attrs)
  end

  @doc """
  Returns one entry per route of a version, with its stored home garage and
  required vehicle type (`nil` when the planner has set neither).

  The routes are the version's own, ordered by short name then route ID, so the
  Block rules drawer lists every route whether or not a row exists for it.
  """
  @spec list_route_operating_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: [Blocking.route_setting()]
  def list_route_operating_settings(organization_id, gtfs_version_id) do
    Blocking.list_route_operating_settings(organization_id, gtfs_version_id)
  end

  @doc """
  Stores the home garage and required vehicle type of the given routes of an
  organization's published version.

  Each entry is a map with `route_id`, `garage_id` and
  `required_vehicle_type_id`; a blank value is stored as `nil`. The batch is
  all-or-nothing: a garage or type of another organization, or a route the
  version does not have, returns
  `{:error, {:invalid, [%{route_id: id, field: field, message: message}]}}` and
  stores nothing. The save takes `Blocking.lock_blocking!/1`, and a staging or
  foreign version is `{:error, :not_found}`.
  """
  @spec update_route_operating_settings(Ecto.UUID.t(), Ecto.UUID.t(), [map()]) ::
          :ok | {:error, :not_found | {:invalid, [map()]}}
  def update_route_operating_settings(organization_id, gtfs_version_id, entries) do
    Blocking.update_route_operating_settings(organization_id, gtfs_version_id, entries)
  end

  @doc """
  Lists every directional driving-time pair the day type's blocks connect.

  Each pair carries the stored `from`/`to` reference strings, the stop or garage
  labels, how many legs of the day drove that exact direction, the minutes and
  their source (`:entered`, `:estimated` or `:unknown`), ordered by uses
  descending and then by label. The pairs are derived from the day the page
  already loads, so the drawer lists the drives the plan really has. An unknown
  day type is `{:error, {:unknown_day_type, day_types}}` and a foreign or
  unpublished version `{:error, :not_found}`.
  """
  @spec list_deadhead_pairs(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, [Blocking.pair()]}
          | {:error,
             :not_found | {:unknown_day_type, [GtfsPlanner.Gtfs.Blocking.DayTypes.day_type()]}}
  def list_deadhead_pairs(organization_id, gtfs_version_id, day_type_key) do
    Blocking.list_deadhead_pairs(organization_id, gtfs_version_id, day_type_key)
  end

  @doc """
  Stores an entered driving time for one direction of one pair.

  `{from_ref, to_ref}` is the ordered pair of stored reference strings the list
  hands out, and `minutes` is 0–600. A stop ref that is not a stop of the version
  or a garage ref that is not a garage of the organization is
  `{:error, :invalid_ref}` with nothing stored; an out-of-range value is a
  changeset error. The save takes `Blocking.lock_blocking!/1` and replaces the
  minutes of exactly this direction — writing A→B never writes B→A. A staging or
  foreign version is `{:error, :not_found}`.
  """
  @spec put_deadhead_time(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          {String.t(), String.t()},
          non_neg_integer()
        ) ::
          {:ok, DeadheadTime.t()}
          | {:error, :not_found | :invalid_ref | Ecto.Changeset.t()}
  def put_deadhead_time(organization_id, gtfs_version_id, {from_ref, to_ref}, minutes) do
    Blocking.put_deadhead_time(organization_id, gtfs_version_id, {from_ref, to_ref}, minutes)
  end

  @doc """
  Removes the entered driving time of one direction, so the pair shows its
  estimate again.

  Only the named row is deleted, and a pair with no stored row is
  `{:error, :not_found}`, as is a staging or foreign version. The delete takes
  `Blocking.lock_blocking!/1`.
  """
  @spec clear_deadhead_time(Ecto.UUID.t(), Ecto.UUID.t(), {String.t(), String.t()}) ::
          :ok | {:error, :not_found}
  def clear_deadhead_time(organization_id, gtfs_version_id, {from_ref, to_ref}) do
    Blocking.clear_deadhead_time(organization_id, gtfs_version_id, {from_ref, to_ref})
  end

  @doc """
  Lists every place an operator change may be made on one day type of a version.

  The candidates are the day type's own trip endpoints, a stop with a
  `parent_station` grouped under that station, each with the number of the day's
  feasible waits that happen there, whether the version marks it, and — for a
  station — the names of the day's stops beneath it. They are ordered by waits
  descending, then name. A `nil` day type key selects the first day type; an
  unknown key is `{:error, {:unknown_day_type, day_types}}`, and a staging or
  foreign version is `{:error, :not_found}`.
  """
  @spec list_relief_candidates(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, [Blocking.relief_candidate()]}
          | {:error,
             :not_found | {:unknown_day_type, [GtfsPlanner.Gtfs.Blocking.DayTypes.day_type()]}}
  def list_relief_candidates(organization_id, gtfs_version_id, day_type_key) do
    Blocking.list_relief_candidates(organization_id, gtfs_version_id, day_type_key)
  end

  @doc """
  Stores the relief limit and which of the day type's candidates are marked.

  `attrs` carries `max_piece_minutes` (60–720, or blank for "no limit", which
  turns the `:no_relief_opportunity` checks off) and `marked`, the list of ticked
  candidate IDs. The save is all-or-nothing, takes `Blocking.lock_blocking!/1`,
  and writes only the `max_piece_minutes` column of the shared settings row, so
  the other seven settings are untouched. Exactly the given IDs among the day
  type's candidates end up marked: an ID that is not a candidate is ignored and a
  mark on a stop outside the candidates stays. An out-of-range limit is a
  changeset error and stores nothing; a staging or foreign version is
  `{:error, :not_found}`.
  """
  @spec update_relief_settings(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t() | nil,
          map()
        ) ::
          {:ok, :ok}
          | {:error,
             :not_found
             | {:unknown_day_type, [GtfsPlanner.Gtfs.Blocking.DayTypes.day_type()]}
             | Ecto.Changeset.t()}
  def update_relief_settings(organization_id, gtfs_version_id, day_type_key, attrs) do
    Blocking.update_relief_settings(organization_id, gtfs_version_id, day_type_key, attrs)
  end

  @doc """
  Applies one block command on a day type of an organization's GTFS version.

  The command is an `:assign` or `:unassign` of trips or a `:rename` or `:merge`
  of block IDs; the whole command runs in the configured reviewed transaction
  (SERIALIZABLE in production). A rename takes the selected day type's trips
  carrying the source ID and is `:block_id_taken` when the new ID is already used
  on those trips' dates; a merge additionally requires the destination block on
  the selected day type (`:not_found` otherwise). A command with
  nothing to change returns `{:ok, result}` with no `changed_trip_ids`; a command
  whose effects reach another date returns `{:needs_confirmation, review}` and writes
  nothing until it is called again with the review's fingerprint. Every refusal
  (`:not_found`, `{:ineligible, ids}`, `:too_many_trips`, `:unknown_day_type`,
  `:invalid_command`, `:invalid_block_id`, `:block_id_taken`, `{:stale_review,
  review}`, `{:audit_failed, reason}`, `:busy`) is an `{:error, reason}` and writes
  nothing: a refused audit insert rolls the command back and is reported, never
  raised.
  """
  @spec apply_block_change(
          String.t(),
          GtfsPlanner.Gtfs.Blocking.command(),
          AuditContext.t(),
          String.t() | nil
        ) ::
          {:ok, GtfsPlanner.Gtfs.Blocking.apply_result()}
          | {:needs_confirmation, GtfsPlanner.Gtfs.Blocking.Review.review()}
          | {:error, term()}
  def apply_block_change(day_type_key, command, audit_context),
    do: apply_block_change(day_type_key, command, audit_context, nil)

  def apply_block_change(day_type_key, command, %AuditContext{} = audit_context, confirmation) do
    Blocking.apply_block_change(day_type_key, command, audit_context, confirmation)
  end

  # ============================================================================
  # Station Naming
  # ============================================================================

  @doc """
  Builds a preview of the station naming convention without writing.

  When `selected_ids` is provided, the preview rows, collision checks, and updated
  reference counts are limited to that subset while preserving the naming derived
  from the full station descendant set.

  Returns
  `{:ok, %{rows: [...], renamed_stops_count: n, updated_pathways_count: n, updated_references_count: n}}`
  or `{:error, reason}`.
  """
  def preview_station_naming(organization_id, gtfs_version_id, station_stop_id),
    do:
      preview_station_naming(organization_id, gtfs_version_id, station_stop_id, :structured, nil)

  def preview_station_naming(organization_id, gtfs_version_id, station_stop_id, style),
    do: preview_station_naming(organization_id, gtfs_version_id, station_stop_id, style, nil)

  def preview_station_naming(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        style,
        selected_ids
      ) do
    descendant_ids = descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id)

    child_stops =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendant_ids) and
            s.location_type in [0, 2, 3, 4],
        order_by: [asc: s.stop_id]
      )
      |> Repo.all()

    case child_stops do
      [] ->
        {:error, :no_stops}

      _ ->
        child_stop_ids = Enum.map(child_stops, & &1.stop_id)

        pathways =
          from(p in Pathway,
            where:
              p.organization_id == ^organization_id and
                p.gtfs_version_id == ^gtfs_version_id and
                (p.from_stop_id in ^child_stop_ids or p.to_stop_id in ^child_stop_ids)
          )
          |> Repo.all()

        naming_map =
          case style do
            :kebab -> StationNaming.build_kebab_naming_map(child_stops)
            _structured -> StationNaming.build_naming_map(child_stops, pathways, station_stop_id)
          end

        rows =
          if selected_ids do
            Enum.filter(naming_map, fn %{old_id: old_id} ->
              MapSet.member?(selected_ids, old_id)
            end)
          else
            naming_map
          end

        old_id_set = MapSet.new(rows, & &1.old_id)

        # Query only candidate new IDs (excluding IDs that are being renamed in this operation).
        candidate_new_ids =
          rows
          |> Enum.map(& &1.new_id)
          |> MapSet.new()
          |> MapSet.difference(old_id_set)
          |> MapSet.to_list()

        existing_ids =
          case candidate_new_ids do
            [] ->
              MapSet.new()

            _ ->
              from(s in Stop,
                where:
                  s.organization_id == ^organization_id and
                    s.gtfs_version_id == ^gtfs_version_id and
                    s.stop_id in ^candidate_new_ids,
                select: s.stop_id
              )
              |> Repo.all()
              |> MapSet.new()
          end

        case rows do
          [] ->
            {:error, :no_stops}

          _ ->
            case StationNaming.detect_collisions(rows, existing_ids) do
              [] ->
                reference_counts =
                  count_stop_id_references(organization_id, gtfs_version_id, old_id_set)

                {:ok,
                 %{
                   rows: rows,
                   renamed_stops_count: length(rows),
                   updated_pathways_count: reference_counts.pathways,
                   updated_references_count: reference_counts.total
                 }}

              collisions ->
                {:error, {:naming_collision, collisions}}
            end
        end
    end
  end

  @doc """
  Applies the station naming convention transactionally.

  Performs a two-phase rename to avoid transient ID collisions:
  1) child stop IDs old -> temporary IDs
  2) references old -> temporary
  3) child stop IDs temporary -> final IDs
  4) references temporary -> final IDs

  When `selected_ids` is provided via `apply_station_naming/5`, only that subset
  of previewed child stops is renamed. Passing an empty `MapSet` is a no-op and
  returns zero updated counts.

  Returns `{:ok, %{renamed_stops: n, updated_pathways: n, updated_references: n}}`
  or `{:error, reason}`.
  """
  def apply_station_naming(organization_id, gtfs_version_id, station_stop_id),
    do:
      do_apply_station_naming(organization_id, gtfs_version_id, station_stop_id, :structured, nil)

  def apply_station_naming(organization_id, gtfs_version_id, station_stop_id, style),
    do: do_apply_station_naming(organization_id, gtfs_version_id, station_stop_id, style, nil)

  def apply_station_naming(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        style,
        selected_ids
      ),
      do:
        do_apply_station_naming(
          organization_id,
          gtfs_version_id,
          station_stop_id,
          style,
          selected_ids
        )

  defp do_apply_station_naming(
         organization_id,
         gtfs_version_id,
         station_stop_id,
         style,
         selected_ids
       ) do
    case preview_station_naming(
           organization_id,
           gtfs_version_id,
           station_stop_id,
           style,
           selected_ids
         ) do
      {:ok, preview} ->
        old_to_new = Map.new(preview.rows, fn %{old_id: old, new_id: new} -> {old, new} end)
        old_to_temp = build_temp_stop_id_map(preview.rows)

        temp_to_new =
          Map.new(old_to_temp, fn {old_id, temp_id} ->
            {temp_id, Map.fetch!(old_to_new, old_id)}
          end)

        now = DateTime.utc_now()

        multi =
          Ecto.Multi.new()
          |> lock_input_write_multi(organization_id, gtfs_version_id)
          |> Ecto.Multi.run(:rename_stops_to_temp, fn repo, _changes ->
            {:ok,
             update_stop_field_values(
               repo,
               :stop_id,
               old_to_temp,
               organization_id,
               gtfs_version_id,
               now
             )}
          end)
          |> Ecto.Multi.run(:update_refs_to_temp, fn repo, _changes ->
            {:ok,
             update_stop_id_references(
               repo,
               old_to_temp,
               organization_id,
               gtfs_version_id,
               now
             )}
          end)
          |> Ecto.Multi.run(:rename_stops_to_final, fn repo, _changes ->
            {:ok,
             update_stop_field_values(
               repo,
               :stop_id,
               temp_to_new,
               organization_id,
               gtfs_version_id,
               now
             )}
          end)
          |> Ecto.Multi.run(:update_refs_to_final, fn repo, _changes ->
            {:ok,
             update_stop_id_references(
               repo,
               temp_to_new,
               organization_id,
               gtfs_version_id,
               now
             )}
          end)

        case Repo.transaction(multi) do
          {:ok, %{rename_stops_to_final: renamed, update_refs_to_final: refs}} ->
            {:ok,
             %{
               renamed_stops: renamed,
               updated_pathways: refs.pathways,
               updated_references: refs.total
             }}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end

      {:error, :no_stops} when is_struct(selected_ids, MapSet) ->
        {:ok, %{renamed_stops: 0, updated_pathways: 0, updated_references: 0}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_temp_stop_id_map(rows) do
    Map.new(rows, fn %{old_id: old_id} ->
      {old_id, "__tmp_station_naming_#{Ecto.UUID.generate()}_#{Stop.slugify(old_id)}"}
    end)
  end

  defp count_stop_id_references(organization_id, gtfs_version_id, stop_ids) do
    stop_id_list = MapSet.to_list(stop_ids)

    if stop_id_list == [] do
      empty_stop_id_reference_counts()
    else
      pathways_from =
        from(p in Pathway,
          where:
            p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id and
              p.from_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      pathways_to =
        from(p in Pathway,
          where:
            p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id and
              p.to_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      stop_times =
        from(st in StopTime,
          where:
            st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
              st.stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      transfers_from =
        from(t in Transfer,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
              t.from_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      transfers_to =
        from(t in Transfer,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
              t.to_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      stop_areas =
        from(sa in StopArea,
          where:
            sa.organization_id == ^organization_id and
              sa.gtfs_version_id == ^gtfs_version_id and
              sa.stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      fare_leg_join_rules_from =
        from(fl in FareLegJoinRule,
          where:
            fl.organization_id == ^organization_id and
              fl.gtfs_version_id == ^gtfs_version_id and
              fl.from_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      fare_leg_join_rules_to =
        from(fl in FareLegJoinRule,
          where:
            fl.organization_id == ^organization_id and
              fl.gtfs_version_id == ^gtfs_version_id and
              fl.to_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      parent_stations =
        from(s in Stop,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
              s.parent_station in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      translations =
        from(t in Translation,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
              t.table_name == "stops" and t.record_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      walkability_tests =
        from(wt in WalkabilityTest,
          where:
            wt.organization_id == ^organization_id and
              wt.gtfs_version_id == ^gtfs_version_id and
              wt.stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      %{
        pathways: pathways_from + pathways_to,
        stop_times: stop_times,
        transfers: transfers_from + transfers_to,
        stop_areas: stop_areas,
        fare_leg_join_rules: fare_leg_join_rules_from + fare_leg_join_rules_to,
        parent_stations: parent_stations,
        translations: translations,
        walkability_tests: walkability_tests
      }
      |> with_total_stop_id_reference_counts()
    end
  end

  defp update_level_id_references(repo, mapping, organization_id, gtfs_version_id, now) do
    stops =
      update_stop_field_values(repo, :level_id, mapping, organization_id, gtfs_version_id, now)

    translations =
      mapping
      |> Enum.reduce(0, fn {old_id, new_id}, count ->
        {updated_count, _} =
          from(t in Translation,
            where:
              t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
                t.table_name == "levels" and t.record_id == ^old_id
          )
          |> repo.update_all(set: [record_id: new_id, updated_at: now])

        count + updated_count
      end)

    %{stops: stops, translations: translations}
  end

  defp update_stop_id_references(repo, mapping, organization_id, gtfs_version_id, now) do
    pathways_from =
      update_schema_field_values(
        repo,
        Pathway,
        :from_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    pathways_to =
      update_schema_field_values(
        repo,
        Pathway,
        :to_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    stop_times =
      update_schema_field_values(
        repo,
        StopTime,
        :stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    transfers_from =
      update_schema_field_values(
        repo,
        Transfer,
        :from_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    transfers_to =
      update_schema_field_values(
        repo,
        Transfer,
        :to_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    stop_areas =
      update_schema_field_values(
        repo,
        StopArea,
        :stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    fare_leg_join_rules_from =
      update_schema_field_values(
        repo,
        FareLegJoinRule,
        :from_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    fare_leg_join_rules_to =
      update_schema_field_values(
        repo,
        FareLegJoinRule,
        :to_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    parent_stations =
      update_stop_field_values(
        repo,
        :parent_station,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    translations =
      mapping
      |> Enum.reduce(0, fn {old_id, new_id}, count ->
        {updated_count, _} =
          from(t in Translation,
            where:
              t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
                t.table_name == "stops" and t.record_id == ^old_id
          )
          |> repo.update_all(set: [record_id: new_id, updated_at: now])

        count + updated_count
      end)

    walkability_tests =
      update_schema_field_values(
        repo,
        WalkabilityTest,
        :stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    %{
      pathways: pathways_from + pathways_to,
      stop_times: stop_times,
      transfers: transfers_from + transfers_to,
      stop_areas: stop_areas,
      fare_leg_join_rules: fare_leg_join_rules_from + fare_leg_join_rules_to,
      parent_stations: parent_stations,
      translations: translations,
      walkability_tests: walkability_tests
    }
    |> with_total_stop_id_reference_counts()
  end

  defp update_stop_field_values(repo, field, mapping, organization_id, gtfs_version_id, now) do
    mapping
    |> Enum.reduce(0, fn {old_id, new_id}, count ->
      {updated_count, _} =
        from(s in Stop,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
              field(s, ^field) == ^old_id
        )
        |> repo.update_all(set: [{field, new_id}, {:updated_at, now}])

      count + updated_count
    end)
  end

  defp update_schema_field_values(
         repo,
         schema,
         field,
         mapping,
         organization_id,
         gtfs_version_id,
         now
       ) do
    mapping
    |> Enum.reduce(0, fn {old_id, new_id}, count ->
      {updated_count, _} =
        from(row in schema,
          where:
            row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
              field(row, ^field) == ^old_id
        )
        |> repo.update_all(set: [{field, new_id}, {:updated_at, now}])

      count + updated_count
    end)
  end

  defp with_total_stop_id_reference_counts(counts) do
    Map.put(counts, :total, Enum.sum(Map.values(counts)))
  end

  defp empty_stop_id_reference_counts do
    %{
      pathways: 0,
      stop_times: 0,
      transfers: 0,
      stop_areas: 0,
      fare_leg_join_rules: 0,
      parent_stations: 0,
      translations: 0,
      walkability_tests: 0,
      total: 0
    }
  end

  defp broadcast({:ok, result}, event_topic) do
    broadcast_result =
      case event_topic do
        [:levels, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "levels", {event_topic, result})

        [:stops, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "stops", {event_topic, result})

        [:pathways, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "pathways", {event_topic, result})

        [:stop_levels, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "stop_levels", {event_topic, result})
      end

    case broadcast_result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to broadcast #{inspect(event_topic)} event: #{inspect(reason)}")
    end

    {:ok, result}
  end

  defp broadcast({:error, reason}, _event_topic) do
    {:error, reason}
  end

  # ============================================================================
  # Change Log / Audit
  # ============================================================================

  @doc """
  Records a change log entry for a mutation.

  `entity_or_nil` is the entity before the mutation (nil for creates).
  `action` is "created", "updated", or "deleted".
  `attrs` is the attribute map being applied (used to compute changed_fields for "updated").

  Returns `:ok` — failures are logged to Logger and the mutation proceeds normally.
  """
  @spec record_change(AuditContext.t(), atom(), struct() | nil, String.t(), map()) :: :ok
  def record_change(%AuditContext{} = ctx, entity_type, entity_or_nil, action, attrs \\ %{}) do
    snapshot = build_snapshot(entity_type, entity_or_nil)
    changed_fields_attrs = changed_fields_attrs(action, entity_type, attrs)
    changed_fields = build_changed_fields(entity_type, action, snapshot, changed_fields_attrs)

    entity_external_id = entity_external_id_for(entity_type, entity_or_nil, attrs)
    entity_id = entity_id_for(entity_or_nil)

    %ChangeLog{}
    |> ChangeLog.changeset(%{
      entity_type: Atom.to_string(entity_type),
      entity_id: entity_id,
      entity_external_id: entity_external_id,
      station_stop_id: ctx.station_stop_id,
      actor_id: ctx.actor_id,
      actor_email: ctx.actor_email,
      snapshot: snapshot,
      changed_fields: changed_fields,
      action: action,
      organization_id: ctx.organization_id,
      gtfs_version_id: ctx.gtfs_version_id
    })
    |> Repo.insert()
    |> then(fn
      {:ok, _log} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to insert change_log: #{inspect(changeset.errors)}")
        :ok
    end)
  end

  @doc false
  @spec route_audit_snapshot(Route.t()) :: map()
  def route_audit_snapshot(%Route{} = route), do: snapshot_route(route)

  @doc false
  @spec record_change_in_transaction(AuditContext.t(), atom(), struct() | nil, String.t(), map()) ::
          {:ok, ChangeLog.t()} | {:error, Ecto.Changeset.t()}
  def record_change_in_transaction(
        %AuditContext{} = ctx,
        entity_type,
        entity_or_nil,
        action,
        attrs \\ %{}
      ) do
    snapshot = build_snapshot(entity_type, entity_or_nil)
    changed_fields_attrs = changed_fields_attrs(action, entity_type, attrs)
    changed_fields = build_changed_fields(entity_type, action, snapshot, changed_fields_attrs)

    %ChangeLog{}
    |> ChangeLog.changeset(%{
      entity_type: Atom.to_string(entity_type),
      entity_id: entity_id_for(entity_or_nil),
      entity_external_id: entity_external_id_for(entity_type, entity_or_nil, attrs),
      station_stop_id: ctx.station_stop_id,
      actor_id: ctx.actor_id,
      actor_email: ctx.actor_email,
      snapshot: snapshot,
      changed_fields: changed_fields,
      action: action,
      organization_id: ctx.organization_id,
      gtfs_version_id: ctx.gtfs_version_id
    })
    |> Repo.insert()
  end

  @doc false
  @spec lock_import_entity(atom(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          Level.t() | Stop.t() | Pathway.t() | nil
  def lock_import_entity(entity_type, organization_id, gtfs_version_id, natural_key)
      when entity_type in [:level, :stop, :pathway] and is_binary(natural_key) do
    {schema, key_field} = import_entity_schema(entity_type)

    from(entity in schema,
      where:
        entity.organization_id == ^organization_id and entity.gtfs_version_id == ^gtfs_version_id and
          field(entity, ^key_field) == ^natural_key,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  @doc false
  @spec apply_import_entity(:add | :modify | :remove | :conflict, atom(), struct() | nil, map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | term()}
  def apply_import_entity(:add, :level, _current, attrs),
    do: %Level{} |> Level.changeset(attrs) |> Repo.insert()

  def apply_import_entity(:add, :stop, _current, attrs),
    do: %Stop{} |> Stop.import_changeset(attrs) |> Repo.insert()

  def apply_import_entity(:add, :pathway, _current, attrs),
    do: %Pathway{} |> Pathway.changeset(attrs) |> Repo.insert()

  def apply_import_entity(action, :level, %Level{} = current, attrs)
      when action in [:modify, :conflict],
      do: current |> Level.changeset(attrs) |> Repo.update()

  def apply_import_entity(action, :stop, %Stop{} = current, attrs)
      when action in [:modify, :conflict],
      do: current |> Stop.import_changeset(attrs) |> Repo.update()

  def apply_import_entity(action, :pathway, %Pathway{} = current, attrs)
      when action in [:modify, :conflict],
      do: current |> Pathway.changeset(attrs) |> Repo.update()

  def apply_import_entity(:remove, :pathway, %Pathway{} = current, _attrs),
    do: delete_pathway_record(current)

  def apply_import_entity(:remove, _entity_type, current, _attrs) when not is_nil(current),
    do: Repo.delete(current)

  def apply_import_entity(_, _, _, _), do: {:error, :invalid_decision}

  # Tables that hold a stop's or level's GTFS ID as a plain string, as
  # {kind, schema, column, column already counted}. There are no foreign keys, so a
  # removal leaves these rows pointing at a missing record. A row naming one stop in
  # both columns is counted once, by the first column.
  @stop_references [
    {:stop_times, StopTime, :stop_id, nil},
    {:transfers, Transfer, :from_stop_id, nil},
    {:transfers, Transfer, :to_stop_id, :from_stop_id},
    {:pathways, Pathway, :from_stop_id, nil},
    {:pathways, Pathway, :to_stop_id, :from_stop_id},
    {:child_stops, Stop, :parent_station, nil},
    {:stop_areas, StopArea, :stop_id, nil},
    {:route_pattern_stops, RoutePatternStop, :stop_id, nil},
    {:fare_leg_join_rules, FareLegJoinRule, :from_stop_id, nil},
    {:fare_leg_join_rules, FareLegJoinRule, :to_stop_id, :from_stop_id}
  ]
  @level_references [{:stops, Stop, :level_id, nil}]

  # Counts the records of one organization and version that still use each of the given
  # stops or levels, as `%{natural_key => %{kind => count}}`. Keys nothing uses are absent.
  @doc false
  @spec import_dependent_counts(atom(), Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) ::
          %{String.t() => %{atom() => pos_integer()}}
  def import_dependent_counts(_entity_type, _organization_id, _gtfs_version_id, []), do: %{}

  def import_dependent_counts(:stop, organization_id, gtfs_version_id, natural_keys),
    do: dependent_counts(@stop_references, organization_id, gtfs_version_id, natural_keys)

  def import_dependent_counts(:level, organization_id, gtfs_version_id, natural_keys),
    do: dependent_counts(@level_references, organization_id, gtfs_version_id, natural_keys)

  def import_dependent_counts(_entity_type, _organization_id, _gtfs_version_id, _natural_keys),
    do: %{}

  defp dependent_counts(references, organization_id, gtfs_version_id, natural_keys) do
    Enum.reduce(references, %{}, fn {kind, schema, column, counted_in}, counts ->
      from(row in schema,
        where:
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
            field(row, ^column) in ^natural_keys,
        group_by: field(row, ^column),
        select: {field(row, ^column), count(row.id)}
      )
      |> skip_counted_column(counted_in, column)
      |> Repo.all()
      |> Enum.reduce(counts, &add_dependent_count(&2, kind, &1))
    end)
  end

  defp add_dependent_count(counts, kind, {key, count}) do
    Map.update(counts, key, %{kind => count}, fn kinds ->
      Map.update(kinds, kind, count, &(&1 + count))
    end)
  end

  defp skip_counted_column(query, nil, _column), do: query

  defp skip_counted_column(query, counted_in, column) do
    where(
      query,
      [row],
      is_nil(field(row, ^counted_in)) or field(row, ^counted_in) != field(row, ^column)
    )
  end

  defp import_entity_schema(:level), do: {Level, :level_id}
  defp import_entity_schema(:stop), do: {Stop, :stop_id}
  defp import_entity_schema(:pathway), do: {Pathway, :pathway_id}

  defp changed_fields_attrs("updated", entity_type, attrs),
    do: audited_attrs_for(entity_type, attrs)

  defp changed_fields_attrs(_action, _entity_type, attrs), do: attrs

  @doc """
  Returns change log entries for a specific entity, most recent first.
  """
  def list_change_logs_for_entity(organization_id, gtfs_version_id, entity_type, entity_id) do
    from(cl in ChangeLog,
      where:
        cl.organization_id == ^organization_id and
          cl.gtfs_version_id == ^gtfs_version_id and
          cl.entity_type == ^entity_type and
          cl.entity_id == ^entity_id,
      order_by: [desc: cl.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single change log entry.

  Raises `Ecto.NoResultsError` if the entry does not exist.
  """
  def get_change_log!(id), do: Repo.get!(ChangeLog, id)

  @doc """
  Gets a single change log entry, returning `nil` if it does not exist.
  """
  def get_change_log(id), do: Repo.get(ChangeLog, id)

  @doc """
  Returns the list of identity field names (as strings) for an entity type.

  Identity fields are preserved across rollback and excluded from rollback diffs.
  """
  def identity_fields_for("stop"), do: ~w(stop_id)
  def identity_fields_for("pathway"), do: ~w(pathway_id from_stop_id to_stop_id)
  def identity_fields_for("level"), do: ~w(level_id)

  @doc """
  Returns the list of reversible field names (as strings) for an entity type.
  """
  @spec reversible_fields_for(String.t() | atom()) :: [String.t()]
  def reversible_fields_for(:stop), do: reversible_fields_for("stop")

  def reversible_fields_for("stop"),
    do: ~w(
        stop_name
        stop_desc
        stop_lat
        stop_lon
        location_type
        wheelchair_boarding
        platform_code
        diagram_coordinate
        parent_station
        level_id
      )

  def reversible_fields_for(:pathway), do: reversible_fields_for("pathway")

  def reversible_fields_for("pathway"),
    do: ~w(
        pathway_mode
        is_bidirectional
        traversal_time
        length
        stair_count
        max_slope
        min_width
        signposted_as
        reversed_signposted_as
        field_notes
        field_completed_at
      )

  def reversible_fields_for(:level), do: reversible_fields_for("level")
  def reversible_fields_for("level"), do: ~w(level_name level_index)

  def reversible_fields_for(type)
      when type in [:route_pattern, :timed_pattern, :route_pattern_build],
      do: []

  def reversible_fields_for(type)
      when type in ["route_pattern", "timed_pattern", "route_pattern_build"],
      do: []

  # Route audit entries are history records: generic rollback never applies to
  # them, so no route field is reversible.
  def reversible_fields_for(type) when type in [:route, "route"], do: []

  def reversible_fields_for(:calendar), do: reversible_fields_for("calendar")
  def reversible_fields_for("calendar"), do: []

  def reversible_fields_for(:pathway_evolution), do: reversible_fields_for("pathway_evolution")
  def reversible_fields_for("pathway_evolution"), do: []

  @doc """
  Builds a normalized snapshot map for a stop, pathway, or level entity.

  Used by rollback preview to compare a current entity against a stored snapshot
  with equivalent value normalization (e.g. Decimal → string).
  """
  def entity_snapshot(entity_type, entity), do: build_snapshot(entity_type, entity)

  @doc """
  Rolls back a stop, pathway, or level to the state captured in a change log entry.

  Only works for "updated" entries. Produces a new "rolled_back" change log entry
  attributed to `audit_ctx`. Identity fields (stop_id, pathway_id, level_id,
  from_stop_id, to_stop_id) are preserved.

  Returns `{:ok, entity}` or `{:error, reason}`.
  """
  @spec rollback_entity(ChangeLog.t(), AuditContext.t()) ::
          {:ok, Stop.t() | Pathway.t() | Level.t()} | {:error, atom()}
  def rollback_entity(%ChangeLog{} = log, %AuditContext{} = audit_ctx)
      when audit_ctx.organization_id != log.organization_id or
             audit_ctx.gtfs_version_id != log.gtfs_version_id do
    {:error, :unauthorized}
  end

  def rollback_entity(%ChangeLog{entity_type: type}, %AuditContext{})
      when type in [
             "route",
             "route_pattern",
             "timed_pattern",
             "route_pattern_build",
             "calendar",
             "trip",
             "transfer",
             "pathway_evolution"
           ],
      do: {:error, :audit_only_entity}

  def rollback_entity(%ChangeLog{} = log, %AuditContext{} = audit_ctx) do
    with {:ok, target_snapshot} <- rollback_target_snapshot(log),
         {:ok, entity} <- rollback_entity_for_log(log),
         :ok <- ensure_rollback_changes_entity(log.entity_type, entity, target_snapshot) do
      update_attrs = snapshot_to_update_attrs(log.entity_type, target_snapshot)
      rollback_entity_transaction(update_attrs, log, audit_ctx, entity)
    end
  end

  @doc """
  Calculates the snapshot an entity should be restored to for a rollback.
  """
  @spec rollback_target_snapshot(ChangeLog.t()) :: {:ok, map()} | {:error, atom()}
  def rollback_target_snapshot(%ChangeLog{entity_type: type})
      when type in [
             "route",
             "route_pattern",
             "timed_pattern",
             "route_pattern_build",
             "calendar",
             "trip",
             "transfer",
             "pathway_evolution"
           ],
      do: {:error, :audit_only_entity}

  def rollback_target_snapshot(%ChangeLog{action: action})
      when action in ["created", "deleted"] do
    {:error, :cannot_rollback_create_or_delete}
  end

  def rollback_target_snapshot(%ChangeLog{action: action, snapshot: nil})
      when action in ["updated", "rolled_back"] do
    {:error, :missing_rollback_snapshot}
  end

  def rollback_target_snapshot(%ChangeLog{
        action: action,
        entity_type: entity_type,
        snapshot: snapshot,
        changed_fields: changed_fields
      })
      when action in ["updated", "rolled_back"] do
    target_snapshot =
      snapshot
      |> fill_snapshot_from_changed_fields(changed_fields)
      |> then(&sanitize_rollback_snapshot(entity_type, &1))

    {:ok, target_snapshot}
  end

  @doc """
  Returns changed field names that can be previewed and applied by rollback.
  """
  @spec rollback_previewable_fields(ChangeLog.t()) :: [String.t()]
  def rollback_previewable_fields(%ChangeLog{} = log) do
    changed_field_names =
      log.changed_fields
      |> Kernel.||(%{})
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    reversible_field_names =
      log.entity_type
      |> reversible_fields_for()
      |> MapSet.new()

    changed_field_names
    |> MapSet.intersection(reversible_field_names)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp update_entity_without_broadcast(%Stop{} = stop, attrs) do
    stop
    |> Stop.changeset(attrs)
    |> Repo.update()
  end

  defp update_entity_without_broadcast(%Pathway{} = pathway, attrs) do
    pathway
    |> Pathway.changeset(attrs)
    |> Repo.update()
  end

  defp update_entity_without_broadcast(%Level{} = level, attrs) do
    level
    |> Level.changeset(attrs)
    |> Repo.update()
  end

  defp broadcast_topic_for(%Stop{}), do: [:stops, :updated]
  defp broadcast_topic_for(%Pathway{}), do: [:pathways, :updated]
  defp broadcast_topic_for(%Level{}), do: [:levels, :updated]

  # -- Direct input writer coordination --

  # Direct trip, stop-time and agency inserts are reviewed inputs of a calendar combination
  # (trip membership, the display zone that dates agency-local "today"), so each one takes the
  # scoped version share lock inside its own transaction before the insert. Invalid input is
  # refused with the changeset exactly as `Repo.insert/1` did, without a transaction or a lock.
  defp insert_with_input_write_lock(changeset) do
    if changeset.valid? do
      Repo.transaction(fn -> insert_after_version_lock(changeset) end)
    else
      # Repo rejects an invalid changeset without a query and sets its action, which forms
      # need to render field errors.
      Repo.insert(changeset)
    end
  end

  defp insert_after_version_lock(changeset) do
    lock_changeset_version!(changeset)

    case Repo.insert(changeset) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Stop and parent rows are reviewed inputs too: the combination projection reads endpoint and
  # parent coordinates with a parent-coordinate fallback and the fingerprint carries parent rows
  # including their absence. Each stop update therefore takes the same scoped version share lock
  # before its row mutation; invalid input keeps its changeset error without a transaction.
  defp update_with_input_write_lock(changeset) do
    if changeset.valid? do
      Repo.transaction(fn -> update_after_version_lock(changeset) end)
    else
      # Repo rejects an invalid changeset without a query and sets its action, which forms
      # need to render field errors.
      Repo.update(changeset)
    end
  end

  defp update_after_version_lock(changeset) do
    lock_changeset_version!(changeset)

    case Repo.update(changeset) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp delete_with_input_write_lock(row) do
    Repo.transaction(fn ->
      Versions.lock_for_input_write!(row.organization_id, row.gtfs_version_id)

      case Repo.delete(row) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # The stop cascade and the child-deletion transaction lock the version as their first step,
  # before the `FOR UPDATE` on the referenced rows and before any stop_id rewrite.
  defp lock_input_write_multi(multi, organization_id, gtfs_version_id) do
    Ecto.Multi.run(multi, :lock_version, fn _repo, _changes ->
      {:ok, Versions.lock_for_input_write!(organization_id, gtfs_version_id)}
    end)
  end

  defp lock_changeset_version!(changeset) do
    Versions.lock_for_input_write!(
      Ecto.Changeset.get_field(changeset, :organization_id),
      Ecto.Changeset.get_field(changeset, :gtfs_version_id)
    )
  end

  # -- Snapshot helpers --

  defp build_snapshot(_entity_type, nil), do: nil

  defp build_snapshot(:stop, %Stop{} = stop), do: snapshot_stop(stop)
  defp build_snapshot(:pathway, %Pathway{} = pw), do: snapshot_pathway(pw)
  defp build_snapshot(:level, %Level{} = level), do: snapshot_level(level)

  defp build_snapshot(:route_pattern, %RoutePattern{} = pattern),
    do: snapshot_route_pattern(pattern)

  defp build_snapshot("route_pattern", %RoutePattern{} = pattern),
    do: snapshot_route_pattern(pattern)

  # A route's audit identity is its UUID plus its GTFS `route_id`; the snapshot
  # captures the persisted editor-owned fields so history and replay see the
  # route state at record time.
  defp build_snapshot(type, %Route{} = route) when type in [:route, "route"],
    do: snapshot_route(route)

  defp build_snapshot(:timed_pattern, %GtfsPlanner.Gtfs.TimedPattern{} = timing),
    do: snapshot_timed_pattern(timing)

  defp build_snapshot("timed_pattern", %GtfsPlanner.Gtfs.TimedPattern{} = timing),
    do: snapshot_timed_pattern(timing)

  defp build_snapshot("stop", %Stop{} = stop), do: snapshot_stop(stop)
  defp build_snapshot("pathway", %Pathway{} = pw), do: snapshot_pathway(pw)
  defp build_snapshot("level", %Level{} = level), do: snapshot_level(level)

  # A calendar's audit identity is its metadata anchor. The complete aggregate
  # before/after snapshots are passed explicitly by Calendars, so the stored
  # anchor snapshot never has to be expanded into native weekly/date rows here.
  defp build_snapshot(:calendar, %CalendarAttribute{} = anchor),
    do: Calendars.audit_snapshot(anchor)

  defp build_snapshot("calendar", %CalendarAttribute{} = anchor),
    do: Calendars.audit_snapshot(anchor)

  # A closure's audit identity is the closure UUID; the structured create record
  # carries before=nil and after=the normalized closure snapshot.
  defp build_snapshot(:pathway_evolution, %PathwayEvolution{} = evolution),
    do: snapshot_pathway_evolution(evolution)

  defp build_snapshot("pathway_evolution", %PathwayEvolution{} = evolution),
    do: snapshot_pathway_evolution(evolution)

  # A trip's audit identity is the trip UUID plus its GTFS `trip_id`; the complete
  # aggregate before/after snapshots are passed explicitly by Schedules, so the
  # entity itself never yields a snapshot.
  defp build_snapshot(type, %Trip{}) when type in [:trip, "trip"], do: nil

  # A transfer's audit identity is the row UUID plus its GTFS external ID; the
  # complete before/after snapshots are passed explicitly by Transfers, so the
  # entity itself never yields a snapshot.
  defp build_snapshot(type, %Transfer{}) when type in [:transfer, "transfer"], do: nil
  # Alignment segments snapshot their scope, stop-pair identity, override
  # linkage, optimistic-lock revision and interior points. Pattern shapes
  # snapshot the owning pattern's shape identity; the replaced-shape detail
  # travels in the explicit before/after maps (INV-5).
  defp build_snapshot(type, %AlignmentSegment{} = segment)
       when type in [:alignment_segment, "alignment_segment"] do
    %{
      id: segment.id,
      scope: %{
        organization_id: segment.organization_id,
        gtfs_version_id: segment.gtfs_version_id
      },
      from_stop_id: segment.from_stop_id,
      to_stop_id: segment.to_stop_id,
      from_occurrence_id: segment.from_occurrence_id,
      lock_version: segment.lock_version,
      points: normalize_value(segment.points)
    }
  end

  defp build_snapshot(type, %RoutePattern{} = pattern)
       when type in [:pattern_shape, "pattern_shape"] do
    %{
      route_pattern_id: pattern.route_pattern_id,
      shape_id: pattern.shape_id,
      alignment_digest: pattern.alignment_digest
    }
  end

  defp build_snapshot(_, _), do: nil

  defp snapshot_stop(stop) do
    %{
      stop_name: stop.stop_name,
      stop_desc: stop.stop_desc,
      stop_lat: jsonify(stop.stop_lat),
      stop_lon: jsonify(stop.stop_lon),
      location_type: stop.location_type,
      wheelchair_boarding: stop.wheelchair_boarding,
      platform_code: stop.platform_code,
      diagram_coordinate: stop.diagram_coordinate,
      parent_station: stop.parent_station,
      level_id: stop.level_id
    }
  end

  defp snapshot_pathway(pw) do
    %{
      from_stop_id: pw.from_stop_id,
      to_stop_id: pw.to_stop_id,
      pathway_mode: pw.pathway_mode,
      is_bidirectional: pw.is_bidirectional,
      traversal_time: pw.traversal_time,
      length: jsonify(pw.length),
      stair_count: pw.stair_count,
      max_slope: jsonify(pw.max_slope),
      min_width: jsonify(pw.min_width),
      signposted_as: pw.signposted_as,
      reversed_signposted_as: pw.reversed_signposted_as,
      field_notes: pw.field_notes,
      field_completed_at: jsonify(pw.field_completed_at)
    }
  end

  defp snapshot_level(level) do
    %{level_name: level.level_name, level_index: level.level_index}
  end

  defp snapshot_route(route) do
    %{
      route_short_name: route.route_short_name,
      route_long_name: route.route_long_name,
      route_type: route.route_type,
      agency_id: route.agency_id,
      route_desc: route.route_desc,
      route_url: route.route_url,
      route_color: route.route_color,
      route_text_color: route.route_text_color,
      route_sort_order: route.route_sort_order,
      continuous_pickup: route.continuous_pickup,
      continuous_drop_off: route.continuous_drop_off,
      network_id: route.network_id,
      active: route.active
    }
  end

  defp snapshot_pathway_evolution(evolution) do
    %{
      pathway_id: evolution.pathway_id,
      service_id: evolution.service_id,
      start_time: evolution.start_time,
      end_time: evolution.end_time,
      note: evolution.note
    }
  end

  defp snapshot_route_pattern(pattern),
    do: RoutePatterns.audit_snapshot(pattern)

  defp snapshot_timed_pattern(timing),
    do: RoutePatterns.audit_timing_snapshot(timing)

  # -- Entity identity helpers --

  defp entity_id_for(nil), do: nil
  defp entity_id_for(%{id: id}), do: id

  defp entity_external_id_for(_entity_type, nil, attrs) do
    cond do
      attrs[:stop_id] -> attrs[:stop_id]
      attrs["stop_id"] -> attrs["stop_id"]
      attrs[:pathway_id] -> attrs[:pathway_id]
      attrs["pathway_id"] -> attrs["pathway_id"]
      attrs[:level_id] -> attrs[:level_id]
      attrs["level_id"] -> attrs["level_id"]
      true -> nil
    end
  end

  defp entity_external_id_for(:stop, %Stop{} = stop, _attrs), do: stop.stop_id
  defp entity_external_id_for(:pathway, %Pathway{} = pw, _attrs), do: pw.pathway_id
  defp entity_external_id_for(:level, %Level{} = level, _attrs), do: level.level_id

  defp entity_external_id_for(:route_pattern, %RoutePattern{} = pattern, _attrs),
    do: pattern.route_pattern_id

  defp entity_external_id_for(type, %Route{} = route, _attrs) when type in [:route, "route"],
    do: route.route_id

  defp entity_external_id_for(:timed_pattern, %GtfsPlanner.Gtfs.TimedPattern{} = timing, attrs) do
    pattern_natural_id =
      Map.get(attrs, :pattern_route_pattern_id) || Map.get(attrs, "pattern_route_pattern_id") ||
        "unknown"

    "#{timing.id}:#{pattern_natural_id}"
  end

  defp entity_external_id_for(:calendar, %CalendarAttribute{} = anchor, _attrs),
    do: anchor.service_id

  defp entity_external_id_for("calendar", %CalendarAttribute{} = anchor, _attrs),
    do: anchor.service_id

  defp entity_external_id_for(type, %PathwayEvolution{} = evolution, _attrs)
       when type in [:pathway_evolution, "pathway_evolution"],
       do: evolution.pathway_id

  defp entity_external_id_for(type, %Trip{} = trip, _attrs) when type in [:trip, "trip"],
    do: trip.trip_id

  defp entity_external_id_for(type, %Transfer{} = transfer, _attrs)
       when type in [:transfer, "transfer"],
       do: Transfer.audit_external_id(transfer)

  # A shared segment is addressed by its stop pair; an override also names the
  # visit it belongs to (INV-6). A pattern shape is addressed by the pattern's
  # natural GTFS ID.
  defp entity_external_id_for(type, %AlignmentSegment{} = segment, _attrs)
       when type in [:alignment_segment, "alignment_segment"] do
    pair = "#{segment.from_stop_id}>#{segment.to_stop_id}"

    if is_nil(segment.from_occurrence_id) do
      pair
    else
      "#{pair}@#{segment.from_occurrence_id}"
    end
  end

  defp entity_external_id_for(type, %RoutePattern{} = pattern, _attrs)
       when type in [:pattern_shape, "pattern_shape"],
       do: pattern.route_pattern_id

  defp entity_external_id_for(:route_pattern_build, %Route{} = route, _attrs), do: route.route_id

  defp entity_external_id_for(:route_pattern_build, nil, attrs),
    do: Map.get(attrs, :route_id) || Map.get(attrs, "route_id")

  defp entity_module_for("stop"), do: Stop
  defp entity_module_for("pathway"), do: Pathway
  defp entity_module_for("level"), do: Level

  defp audited_attrs_for(type, attrs) when type in [:route_pattern, "route_pattern"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(
        route_pattern_name route_pattern_time_desc direction_id
        route_pattern_typicality headsign canonical_route_pattern route_pattern_sort_order
        occurrences timings before after affected_trips
      )
    end)
  end

  defp audited_attrs_for(type, attrs) when type in [:timed_pattern, "timed_pattern"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(name headsign rows before after affected_trips)
    end)
  end

  defp audited_attrs_for(:route_pattern_build, attrs), do: attrs
  defp audited_attrs_for("route_pattern_build", attrs), do: attrs

  # Calendar diffs are already explicit aggregate before/after snapshots.
  defp audited_attrs_for(type, attrs) when type in [:calendar, "calendar"], do: attrs

  # Route diffs are explicit before/after snapshots plus command provenance; no
  # route column is diffed field-by-field.
  defp audited_attrs_for(type, attrs) when type in [:route, "route"], do: attrs

  # A trip update carries the explicit before/after snapshots, its operation scope and - for a
  # reviewed calendar combination - the one optional combination envelope; no trip column is diffed
  # field-by-field. The per-trip `affected_trip_ids` list is deliberately unused by a combination,
  # whose complete member list lives once in the envelope (AC-26).
  defp audited_attrs_for(type, attrs) when type in [:trip, "trip"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(before after operation_id affected_trip_ids combination)
    end)
  end

  # A transfer write carries the explicit before/after snapshots and its operation
  # scope; no transfer column is diffed field-by-field.
  defp audited_attrs_for(type, attrs) when type in [:transfer, "transfer"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(before after operation_id affected_transfer_ids)
    end)
  end

  # Alignment entries carry explicit before/after aggregates like trips and
  # calendars; no segment or shape column is diffed field-by-field.
  defp audited_attrs_for(type, attrs)
       when type in [:alignment_segment, "alignment_segment", :pattern_shape, "pattern_shape"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(before after)
    end)
  end

  # A closure update carries the explicit before/after snapshots; no closure
  # column is diffed field-by-field.
  defp audited_attrs_for(type, attrs) when type in [:pathway_evolution, "pathway_evolution"] do
    Map.filter(attrs, fn {key, _value} -> to_string(key) in ~w(before after) end)
  end

  defp audited_attrs_for(entity_type, attrs), do: reversible_attrs_for(entity_type, attrs)

  # -- Diff and rollback helpers --

  # Calendars diff two explicit aggregate snapshots instead of comparing the
  # anchor's own fields, so this clause must precede the generic update branch.
  defp build_changed_fields(entity_type, action, _snapshot, attrs)
       when entity_type in [:calendar, "calendar"] and
              action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
    |> put_calendar_operation(attrs)
  end

  # Routes, like calendars and trips, diff two explicit before/after snapshots.
  # The log carries the shared operation id, creation-attempt provenance and
  # affected identity/count metadata so create replay and reviewed deletion can
  # be reconstructed from the retained entry. A created route log whose caller
  # omits the explicit after value stores the entity snapshot (R3: the create
  # log keeps before/after alongside the attempt metadata).
  defp build_changed_fields(entity_type, action, snapshot, attrs)
       when entity_type in [:route, "route"] and action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(route_after_snapshot(action, attrs, snapshot))
    }
    |> put_route_operation(attrs)
  end

  # Trips, like calendars, diff two explicit aggregate snapshots. The log carries
  # no trip-column diff, and a bulk operation records its shared operation UUID
  # and affected trip UUIDs alongside the snapshot.
  defp build_changed_fields(entity_type, action, _snapshot, attrs)
       when entity_type in [:trip, "trip"] and action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
    |> put_trip_operation(attrs)
  end

  # Transfers, like trips, diff two explicit snapshots supplied by the caller. The log
  # carries no transfer-column diff, and a bulk delete records its shared operation
  # UUID and affected transfer UUIDs alongside the snapshot.
  defp build_changed_fields(entity_type, action, _snapshot, attrs)
       when entity_type in [:transfer, "transfer"] and
              action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
    |> put_transfer_operation(attrs)
  end

  # Alignment entries, like trips, store the explicit before/after aggregates
  # (including INV-5 replaced-shape detail) rather than a column diff.
  defp build_changed_fields(entity_type, action, _snapshot, attrs)
       when entity_type in [
              :alignment_segment,
              "alignment_segment",
              :pattern_shape,
              "pattern_shape"
            ] and action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
  end

  # Closures, like calendars and trips, diff two explicit normalized snapshots:
  # the update log carries before/after while the entity snapshot stays the
  # after state.
  defp build_changed_fields(entity_type, "updated", _snapshot, attrs)
       when entity_type in [:pathway_evolution, "pathway_evolution"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
  end

  defp build_changed_fields(_entity_type, action, snapshot, attrs)
       when action == "updated" and not is_nil(snapshot) do
    snapshot_str_keys = stringify_map_keys(snapshot)

    attrs
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn {field, new_value}, acc ->
      current_value = Map.get(snapshot_str_keys, field)

      if same_value?(current_value, new_value) do
        acc
      else
        Map.put(acc, field, %{
          "from" => normalize_value(current_value),
          "to" => normalize_value(new_value)
        })
      end
    end)
  end

  defp build_changed_fields(entity_type, "created", snapshot, attrs)
       when entity_type in @structured_audit_entity_types and not is_nil(snapshot) do
    after_snapshot = Map.get(attrs, :after, Map.get(attrs, "after", snapshot))
    %{"before" => nil, "after" => normalize_value(after_snapshot)}
  end

  defp build_changed_fields(entity_type, "deleted", snapshot, attrs)
       when entity_type in @structured_audit_entity_types and not is_nil(snapshot),
       do:
         %{"before" => normalize_value(snapshot), "after" => nil}
         |> put_shared_operation(attrs)

  defp build_changed_fields(entity_type, "updated", _snapshot, attrs)
       when entity_type in [:route_pattern_build, "route_pattern_build"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after"))),
      "patterns_created" =>
        normalize_value(Map.get(attrs, :patterns_created, Map.get(attrs, "patterns_created"))),
      "timings_created" =>
        normalize_value(Map.get(attrs, :timings_created, Map.get(attrs, "timings_created")))
    }
  end

  defp build_changed_fields(_entity_type, _action, _snapshot, _attrs), do: nil

  # A reviewed bulk deletion shares one operation id across its route, trip and
  # pattern logs, so structured deleted entries carry it when provided. Logs
  # without an operation id keep their previous shape unchanged.
  defp put_shared_operation(changed, attrs) do
    case Map.get(attrs, :operation_id, Map.get(attrs, "operation_id")) do
      nil -> changed
      value -> Map.put(changed, "operation_id", normalize_value(value))
    end
  end

  defp route_after_snapshot("created", attrs, snapshot),
    do: Map.get(attrs, :after, Map.get(attrs, "after", snapshot))

  defp route_after_snapshot(_action, attrs, _snapshot),
    do: Map.get(attrs, :after, Map.get(attrs, "after"))

  # A bulk calendar operation records its shared operation UUID and scope alongside the
  # per-calendar before/after snapshots, so one log per changed calendar can be
  # reconstructed into the whole command.
  defp put_calendar_operation(changed, attrs) do
    keys = [:operation_id, :affected_service_ids, :selected_dates, :combination]

    Enum.reduce(keys, changed, fn key, acc ->
      case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), normalize_value(value))
      end
    end)
  end

  # A bulk trip operation records its shared operation UUID and the affected trip
  # UUIDs alongside the per-trip before/after snapshot, so one log per affected
  # trip can be reconstructed into the whole command.
  defp put_trip_operation(changed, attrs) do
    Enum.reduce([:operation_id, :affected_trip_ids, :combination], changed, fn key, acc ->
      case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), normalize_value(value))
      end
    end)
  end

  # A bulk transfer delete records its shared operation UUID and every affected
  # transfer UUID alongside each row's before/after snapshot.
  defp put_transfer_operation(changed, attrs) do
    Enum.reduce([:operation_id, :affected_transfer_ids], changed, fn key, acc ->
      case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), normalize_value(value))
      end
    end)
  end

  # A route command records its shared operation id, creation-attempt provenance
  # and affected identity/count metadata alongside the before/after snapshots, so
  # one log per route can be reconstructed into the whole command.
  defp put_route_operation(changed, attrs) do
    Enum.reduce(
      [
        :operation_id,
        :creation_attempt_id,
        :request_digest,
        :affected_identities,
        :affected_counts
      ],
      changed,
      fn key, acc ->
        case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
          nil -> acc
          value -> Map.put(acc, Atom.to_string(key), normalize_value(value))
        end
      end
    )
  end

  @spec reversible_attrs_for(String.t() | atom(), map()) :: map()
  defp reversible_attrs_for(entity_type, attrs) when is_map(attrs) do
    change_log_fields = change_log_fields_for(entity_type)

    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in change_log_fields
    end)
  end

  defp change_log_fields_for(:pathway), do: change_log_fields_for("pathway")

  defp change_log_fields_for("pathway"),
    do: reversible_fields_for("pathway") ++ ~w(from_stop_id to_stop_id)

  defp change_log_fields_for(entity_type), do: reversible_fields_for(entity_type)

  defp fill_snapshot_from_changed_fields(snapshot, changed_fields) when is_map(changed_fields) do
    Enum.reduce(changed_fields, snapshot, fn
      {field, %{"from" => from}}, acc ->
        put_missing_snapshot_field(acc, field, from)

      _entry, acc ->
        acc
    end)
  end

  defp fill_snapshot_from_changed_fields(snapshot, _changed_fields), do: snapshot

  @spec sanitize_rollback_snapshot(String.t(), map()) :: map()
  defp sanitize_rollback_snapshot(entity_type, snapshot) when is_map(snapshot) do
    reversible_fields = reversible_fields_for(entity_type)

    Map.filter(snapshot, fn {key, _value} ->
      to_string(key) in reversible_fields
    end)
  end

  defp rollback_entity_for_log(log) do
    case Repo.get(entity_module_for(log.entity_type), log.entity_id) do
      nil -> {:error, :entity_not_found}
      entity -> {:ok, entity}
    end
  end

  defp ensure_rollback_changes_entity(entity_type, entity, target_snapshot) do
    if rollback_would_change_entity?(entity_type, entity, target_snapshot) do
      :ok
    else
      {:error, :already_matches_current}
    end
  end

  defp rollback_entity_transaction(update_attrs, log, audit_ctx, entity) do
    log
    |> rollback_multi(audit_ctx, entity, update_attrs)
    |> Repo.transaction()
    |> handle_rollback_transaction_result(log)
  end

  defp rollback_multi(log, audit_ctx, entity, update_attrs) do
    Ecto.Multi.new()
    |> lock_input_write_multi(log.organization_id, log.gtfs_version_id)
    |> Ecto.Multi.run(:update_entity, fn _repo, _changes ->
      update_entity_without_broadcast(entity, update_attrs)
    end)
    |> Ecto.Multi.run(:rollback_log, fn _repo, _changes ->
      insert_rollback_log(log, audit_ctx, entity, update_attrs)
    end)
  end

  defp handle_rollback_transaction_result({:ok, %{update_entity: updated_entity}}, _log) do
    broadcast({:ok, updated_entity}, broadcast_topic_for(updated_entity))
    {:ok, updated_entity}
  end

  defp handle_rollback_transaction_result(
         {:error, :update_entity, %Ecto.Changeset{} = changeset, _changes},
         log
       ) do
    Logger.error(
      "Rollback update failed change_log_id=#{log.id} entity_type=#{log.entity_type} entity_id=#{log.entity_id} errors=#{inspect(changeset.errors)}"
    )

    {:error, changeset}
  end

  defp handle_rollback_transaction_result({:error, :update_entity, reason, _changes}, _log) do
    {:error, reason}
  end

  defp handle_rollback_transaction_result({:error, :rollback_log, reason, _changes}, _log) do
    Logger.error("Failed to insert rollback change_log: #{inspect(reason)}")
    {:error, :rollback_log_failed}
  end

  defp rollback_would_change_entity?(entity_type, entity, target_snapshot) do
    current_snapshot =
      entity_type
      |> entity_snapshot(entity)
      |> stringify_map_keys()

    identity_fields = identity_fields_for(entity_type)

    target_snapshot
    |> stringify_map_keys()
    |> Map.drop(identity_fields)
    |> Enum.any?(fn {field, target_value} ->
      current_value = Map.get(current_snapshot, field)
      not same_value?(current_value, target_value)
    end)
  end

  defp put_missing_snapshot_field(snapshot, field, value) do
    if snapshot_field_present?(snapshot, field) do
      snapshot
    else
      Map.put(snapshot, field, value)
    end
  end

  defp snapshot_field_present?(snapshot, field) do
    Map.has_key?(snapshot, field) or snapshot_has_existing_atom_key?(snapshot, field)
  end

  defp snapshot_has_existing_atom_key?(snapshot, field) when is_binary(field) do
    case safe_string_to_existing_atom(field) do
      {:ok, atom_key} -> Map.has_key?(snapshot, atom_key)
      :error -> false
    end
  end

  defp snapshot_has_existing_atom_key?(_snapshot, _field), do: false

  defp same_value?(a, b), do: normalize_value(a) == normalize_value(b)

  defp normalize_value(nil), do: nil
  defp normalize_value(%Decimal{} = d), do: Decimal.to_string(d)

  defp normalize_value(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp normalize_value(%NaiveDateTime{} = ndt) do
    ndt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  end

  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value) when is_number(value), do: value
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(%_{} = struct), do: inspect(struct)
  defp normalize_value(value) when is_map(value), do: value
  defp normalize_value(value) when is_list(value), do: value

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp jsonify(nil), do: nil
  defp jsonify(value), do: normalize_value(value)

  defp snapshot_to_update_attrs(_entity_type, nil), do: %{}

  defp snapshot_to_update_attrs(entity_type, snapshot) when is_map(snapshot) do
    snapshot
    |> then(&sanitize_rollback_snapshot(entity_type, &1))
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key_str = to_string(key)

      case safe_string_to_existing_atom(key_str) do
        {:ok, atom_key} -> Map.put(acc, atom_key, value)
        :error -> acc
      end
    end)
  end

  defp safe_string_to_existing_atom(str) do
    try do
      {:ok, String.to_existing_atom(str)}
    rescue
      ArgumentError -> :error
    end
  end

  defp insert_rollback_log(
         %ChangeLog{} = log,
         %AuditContext{} = ctx,
         current_entity,
         update_attrs
       ) do
    pre_rollback_snapshot = build_snapshot(log.entity_type, current_entity)

    %ChangeLog{}
    |> ChangeLog.changeset(%{
      entity_type: log.entity_type,
      entity_id: log.entity_id,
      entity_external_id: log.entity_external_id,
      station_stop_id: log.station_stop_id,
      actor_id: ctx.actor_id,
      actor_email: ctx.actor_email,
      snapshot: pre_rollback_snapshot,
      changed_fields: rollback_changed_fields(pre_rollback_snapshot, update_attrs),
      action: "rolled_back",
      rolled_back_to_log_id: log.id,
      organization_id: log.organization_id,
      gtfs_version_id: log.gtfs_version_id
    })
    |> Repo.insert()
  end

  defp rollback_changed_fields(pre_rollback_snapshot, update_attrs) do
    current = stringify_map_keys(pre_rollback_snapshot)
    target = stringify_map_keys(update_attrs)

    target
    |> Enum.reduce(%{}, fn {field, target_value}, acc ->
      current_value = Map.get(current, field)

      if same_value?(current_value, target_value) do
        acc
      else
        Map.put(acc, field, %{"from" => current_value, "to" => target_value})
      end
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      changed -> changed
    end
  end
end
