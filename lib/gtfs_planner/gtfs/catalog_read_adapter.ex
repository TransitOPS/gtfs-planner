defmodule GtfsPlanner.Gtfs.CatalogReadAdapter do
  @moduledoc """
  Operational read contract for the route and stop/station catalog and detail views.

  Catalog reads must distinguish ready values, missing records, partial enrichment,
  and a database connection that is temporarily unavailable. Only a lost database
  connection is normalized to `{:error, :unavailable}`; query, cast, configuration,
  and programmer defects stay crash-visible so a code defect is never presented to
  a user as downtime.

  `GtfsPlanner.Gtfs.CatalogReadAdapter.Repo` is the production implementation.
  `GtfsPlanner.Gtfs` resolves the module at call time from
  `:gtfs_planner, :gtfs_catalog_read_adapter`, defaulting to the Repo adapter, so
  focused LiveView tests can substitute this application-owned behaviour without
  mocking `Repo` or Postgrex.
  """

  alias GtfsPlanner.Gtfs.{Route, RoutePattern, Stop}

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

  @callback load_route_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:ok, route_page()} | unavailable()
  @callback load_stop_catalog(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              {:ok, stop_page()}
              | {:partial, stop_page(), :route_enrichment_unavailable}
              | unavailable()
  @callback fetch_route(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, Route.t()} | {:error, :not_found | :unavailable}
  @callback load_route_patterns(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, [RoutePattern.t()]} | unavailable()
  @callback fetch_stop(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
              {:ok, Stop.t()} | {:error, :not_found | :unavailable}
  @callback load_stop_regions(Ecto.UUID.t(), Ecto.UUID.t(), Stop.t()) :: %{
              child_stops: stop_region([Stop.t()]),
              levels: stop_region(list()),
              pathways: stop_region(list()),
              editing_status: stop_region(struct() | nil)
            }
end
