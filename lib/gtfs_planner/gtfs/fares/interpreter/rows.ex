defmodule GtfsPlanner.Gtfs.Fares.Interpreter.Rows do
  @moduledoc """
  One version's fare rows, loaded once and then read without a database.

  `GtfsPlanner.Gtfs.Fares.Interpreter.load_rows/2` fills this struct; the fare
  interpreter and `GtfsPlanner.Gtfs.Fares.Pricing` read it instead of querying,
  so a journey price or a conversion check is worked out from the rows as they
  stand. The maps are built while loading because the reference constrains them:
  a route belongs to at most one network, and a stop may belong to many areas.

  `stop_areas` is the leg-matching view of a stop's areas: the version's
  `stop_areas` rows, or its `stops.zone_id` values when the version is managed —
  a managed version's areas *are* its fare zones (`area_id = zone_id`) and
  `FareZones` is their writer, so `stops.zone_id` is the current carrier there.
  `stop_zones` keeps the `stops.zone_id` values for every version, which is what
  the older `fare_attributes`/`fare_rules` model addresses, so a v1 price never
  has to read the areas.

  `calendars` and `calendar_dates` are the service rows `active_timeframes/3`
  needs: a timeframe group counts only when one of its `service_id` values runs
  on the event's date.

  `fare_product_details` says which products are single rides, passes or transfer
  fees, which the Fares v2 files do not record, and `rider_categories` and
  `fare_media` carry the names `Fares.Pricing` reads in a rider's price
  explanation.
  """

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t() | nil,
          gtfs_version_id: Ecto.UUID.t() | nil,
          managed?: boolean(),
          fare_products: [GtfsPlanner.Gtfs.FareProduct.t()],
          fare_leg_rules: [GtfsPlanner.Gtfs.FareLegRule.t()],
          fare_transfer_rules: [GtfsPlanner.Gtfs.FareTransferRule.t()],
          timeframes: [GtfsPlanner.Gtfs.Timeframe.t()],
          networks: [GtfsPlanner.Gtfs.Network.t()],
          route_networks: %{optional(String.t()) => String.t()},
          route_network_ids: %{optional(String.t()) => String.t()},
          stop_areas: %{optional(String.t()) => [String.t()]},
          stop_zones: %{optional(String.t()) => String.t()},
          fare_attributes: [GtfsPlanner.Gtfs.FareAttribute.t()],
          fare_rules: [GtfsPlanner.Gtfs.FareRule.t()],
          fare_product_details: [GtfsPlanner.Gtfs.FareProductDetail.t()],
          rider_categories: [GtfsPlanner.Gtfs.RiderCategory.t()],
          fare_media: [GtfsPlanner.Gtfs.FareMedia.t()],
          calendars: [GtfsPlanner.Gtfs.Calendar.t()],
          calendar_dates: [GtfsPlanner.Gtfs.CalendarDate.t()]
        }

  defstruct organization_id: nil,
            gtfs_version_id: nil,
            managed?: false,
            fare_products: [],
            fare_leg_rules: [],
            fare_transfer_rules: [],
            timeframes: [],
            networks: [],
            route_networks: %{},
            route_network_ids: %{},
            stop_areas: %{},
            stop_zones: %{},
            fare_attributes: [],
            fare_rules: [],
            fare_product_details: [],
            rider_categories: [],
            fare_media: [],
            calendars: [],
            calendar_dates: []
end
