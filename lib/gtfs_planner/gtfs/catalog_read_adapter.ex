defmodule GtfsPlanner.Gtfs.CatalogReadAdapter do
  @moduledoc """
  Operational read contract for the route and stop/station catalog and detail views,
  for the editable calendar list and detail reads, for the version's transfer
  catalog, for the Fare zones workspace, and for the Flex services list.

  Catalog reads must distinguish ready values, missing records, partial enrichment,
  and a database connection that is temporarily unavailable. Only a lost database
  connection is normalized to `{:error, :unavailable}`; query, cast, configuration,
  and programmer defects stay crash-visible so a code defect is never presented to
  a user as downtime.

  Calendar reads keep their domain tagged results: `{:ok, ...}` for a coherent
  scoped load and `{:error, :not_found}` for a foreign, unpublished or unknown
  scope, with only `DBConnection.ConnectionError` becoming `{:error, :unavailable}`.
  The calendar list resolves its agency-local today and version-wide feed gaps
  through one operational read so the list header and its gap callout come from
  the same clock resolution. The calendar screen read composes the summaries with
  those same facts in one protected snapshot, and reports `complete?: false` with
  `gaps: nil` for a version that holds a retained invalid weekly range instead of
  asserting a complete gap set.

  `GtfsPlanner.Gtfs.CatalogReadAdapter.Repo` is the production implementation.
  `GtfsPlanner.Gtfs` resolves the module at call time from
  `:gtfs_planner, :gtfs_catalog_read_adapter`, defaulting to the Repo adapter, so
  focused LiveView tests can substitute this application-owned behaviour without
  mocking `Repo` or Postgrex.

  The blocking day read keeps its domain tagged results the same way: `{:ok, day}`
  for a coherent scoped load, `{:error, :not_found}` for a foreign or unpublished
  version and `{:error, {:unknown_day_type, day_types}}` for a key no day type has.
  The Schedules block warning and the Blocks deep-link key are reads of the same
  kind: a foreign or unpublished version is `{:error, :not_found}`, a lost
  connection `{:error, :unavailable}`, and a service with no active date is the
  in-band answer `{:ok, :none}` rather than an error.
  """

  alias GtfsPlanner.Gtfs.{
    Blocking,
    Calendars,
    FareZones,
    Flex.Checks,
    FlexService,
    Route,
    RoutePattern,
    Routes,
    Schedules,
    Stop,
    Transfers
  }

  alias GtfsPlanner.Gtfs.Runs

  alias GtfsPlanner.Gtfs.Blocking.DayTypes

  @type unavailable :: {:error, :unavailable}
  @type route_page :: %{
          rows: [Route.t()],
          total_count: non_neg_integer(),
          page: pos_integer(),
          route_types: [integer()],
          agencies: [String.t()]
        }
  @type stop_page :: %{
          rows: [Stop.t()],
          total_count: non_neg_integer(),
          page: pos_integer(),
          available_routes: [Route.t()],
          routes_by_stop: %{optional(String.t()) => [Route.t()]}
        }
  @type stop_region(value) :: {:ok, value} | unavailable()
  @type calendar_page :: [Calendars.summary()]
  @type fare_workspace :: %{
          inventory: FareZones.inventory(),
          checks: FareZones.checks(),
          stops: FareZones.stop_page()
        }
  @type flex_list :: %{
          services: [%{service: FlexService.t(), checks: [Checks.check()]}],
          calendars: %{optional(String.t()) => %{name: String.t(), plural: String.t()}},
          map: Flex.map_payload(),
          routes: [Flex.route_choice()],
          has_fixed_routes?: boolean(),
          include_flex: boolean()
        }
  @type calendar_screen :: Calendars.screen()
  @type route_editor :: Routes.editor_workspace()

  @callback load_route_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:ok, route_page()} | unavailable()
  @callback load_stop_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:ok, stop_page()}
              | {:partial, stop_page(), :route_enrichment_unavailable}
              | unavailable()
  @callback fetch_route(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, Route.t()} | {:error, :not_found | :unavailable}
  @callback load_route_editor(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, route_editor()} | {:error, :not_found | :unavailable}
  @callback load_route_patterns(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, [RoutePattern.t()]} | unavailable()
  @callback load_route_pattern_screen(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, :not_found | :unavailable}
  @callback search_stops(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, %{stops: [Stop.t()], truncated?: boolean()}} | unavailable()
  @callback fetch_stop(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, Stop.t()} | {:error, :not_found | :unavailable}
  @callback load_calendar_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:ok, calendar_page()} | {:error, :not_found | :unavailable}
  @callback load_calendar_screen(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:ok, calendar_screen()} | {:error, :not_found | :unavailable}
  @callback fetch_calendar(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, Calendars.payload()} | {:error, :not_found | :unavailable}
  @callback load_calendar_feed_status(Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, %{today: Date.t(), gaps: [Calendars.feed_gap()]}}
              | {:error, :not_found | :unavailable}
  @callback load_route_schedule(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), Schedules.filters()) ::
              {:ok, Schedules.schedule()} | {:error, :not_found | :unavailable}
  @callback load_blocking_day(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
              {:ok, Blocking.day()}
              | {:error, {:unknown_day_type, [DayTypes.day_type()]} | :not_found | :unavailable}
  @callback block_problems_for_trips(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) ::
              {:ok, [Blocking.problem()]} | {:error, :not_found | :unavailable}
  @callback first_day_type_key(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, String.t() | :none} | {:error, :not_found | :unavailable}
  @callback load_stop_regions(Ecto.UUID.t(), Ecto.UUID.t(), Stop.t()) :: %{
              child_stops: stop_region([Stop.t()]),
              levels: stop_region(list()),
              pathways: stop_region(list()),
              editing_status: stop_region(struct() | nil)
            }
  @callback load_fare_workspace(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:ok, fare_workspace()} | unavailable()
  @callback load_flex_list(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, flex_list()} | unavailable()
  @callback load_transfer_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:ok, Transfers.catalog()} | unavailable()
  @callback load_runs(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
              {:ok, Runs.runs_day()}
              | {:error, :not_found | {:unknown_day_type, [DayTypes.day_type()]} | :unavailable}
end
