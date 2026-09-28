defmodule GtfsPlanner.Gtfs.Export.StreamBuilder do
  @moduledoc """
  Builds Ecto streaming queries and lookup maps for GTFS export.

  All streams use batch processing with `max_rows: 1000` to avoid
  memory exhaustion when processing large datasets.

  Export selection follows the R6 inactive-service policy: a route is inactive
  only when its `active` column is explicitly false. Inactive routes, the trips
  naming them, and whole relationship rows referencing either are excluded via
  scoped `NOT EXISTS` matches. NULL, dangling and shared rows stay eligible.
  """

  import Ecto.Query

  @doc """
  Streams records for the given schema filtered by organization and version.

  Returns an Ecto stream that fetches records in batches of 1000.

  ## Examples

      StreamBuilder.stream_records(Repo, Stop, org_id, version_id)
      |> Enum.each(fn stop -> ... end)
  """
  def stream_records(repo, schema, organization_id, gtfs_version_id) do
    from(s in schema, as: :row)
    |> where([s], s.organization_id == ^organization_id)
    |> where([s], s.gtfs_version_id == ^gtfs_version_id)
    |> exclude_inactive_service(schema, organization_id, gtfs_version_id)
    |> order_by_for_schema(schema)
    |> repo.stream(max_rows: 1000)
  end

  @doc """
  Applies `stream_records/4`'s inactive-route exclusion for `schema` to a query
  whose root binding is named `:row`.

  Readers that select their own columns (the flex export's trip and route
  reads) use it so they leave out exactly the routes and trips the exported
  files leave out. A route is inactive only when `active` is explicitly false.
  """
  def exclude_inactive(query, schema, organization_id, gtfs_version_id) do
    exclude_inactive_service(query, schema, organization_id, gtfs_version_id)
  end

  # R6 export selection: exclude whole rows in the inactive route closure. The
  # closure is an explicitly `active = false` route and the trips naming it;
  # relationship rows referencing either are removed whole. Each exclusion is a
  # scoped NOT EXISTS so NULL and dangling references stay eligible, and every
  # other schema keeps the current selection.

  # The row itself is an explicitly inactive route.
  defp exclude_inactive_service(query, GtfsPlanner.Gtfs.Route, organization_id, gtfs_version_id) do
    where(
      query,
      [row],
      not exists(
        from(r in GtfsPlanner.Gtfs.Route,
          where: r.organization_id == ^organization_id,
          where: r.gtfs_version_id == ^gtfs_version_id,
          where: r.id == parent_as(:row).id,
          where: r.active == false
        )
      )
    )
  end

  # The row names an explicitly inactive route through its route_id.
  defp exclude_inactive_service(query, schema, organization_id, gtfs_version_id)
       when schema in [
              GtfsPlanner.Gtfs.Trip,
              GtfsPlanner.Gtfs.RoutePattern,
              GtfsPlanner.Gtfs.FareRule
            ] do
    exclude_named_inactive_routes(query, organization_id, gtfs_version_id)
  end

  # The row names an explicitly inactive route or one of its trips.
  defp exclude_inactive_service(
         query,
         GtfsPlanner.Gtfs.Attribution,
         organization_id,
         gtfs_version_id
       ) do
    query
    |> exclude_named_inactive_routes(organization_id, gtfs_version_id)
    |> exclude_named_inactive_trips(organization_id, gtfs_version_id)
  end

  # The row belongs to a trip naming an explicitly inactive route.
  defp exclude_inactive_service(query, schema, organization_id, gtfs_version_id)
       when schema in [GtfsPlanner.Gtfs.StopTime, GtfsPlanner.Gtfs.Frequency] do
    exclude_named_inactive_trips(query, organization_id, gtfs_version_id)
  end

  # Either route or trip endpoint references the inactive route closure.
  defp exclude_inactive_service(
         query,
         GtfsPlanner.Gtfs.Transfer,
         organization_id,
         gtfs_version_id
       ) do
    query
    |> exclude_inactive_route_endpoints(organization_id, gtfs_version_id)
    |> exclude_inactive_trip_endpoints(organization_id, gtfs_version_id)
  end

  defp exclude_inactive_service(query, _schema, _organization_id, _gtfs_version_id), do: query

  defp exclude_named_inactive_routes(query, organization_id, gtfs_version_id) do
    where(
      query,
      [row],
      not exists(
        from(r in GtfsPlanner.Gtfs.Route,
          where: r.organization_id == ^organization_id,
          where: r.gtfs_version_id == ^gtfs_version_id,
          where: r.route_id == parent_as(:row).route_id,
          where: r.active == false
        )
      )
    )
  end

  defp exclude_named_inactive_trips(query, organization_id, gtfs_version_id) do
    where(
      query,
      [row],
      not exists(
        from(t in GtfsPlanner.Gtfs.Trip,
          join: r in GtfsPlanner.Gtfs.Route,
          on:
            r.organization_id == t.organization_id and
              r.gtfs_version_id == t.gtfs_version_id and
              r.route_id == t.route_id,
          where: t.organization_id == ^organization_id,
          where: t.gtfs_version_id == ^gtfs_version_id,
          where: t.trip_id == parent_as(:row).trip_id,
          where: r.active == false
        )
      )
    )
  end

  defp exclude_inactive_route_endpoints(query, organization_id, gtfs_version_id) do
    where(
      query,
      [row],
      not exists(
        from(r in GtfsPlanner.Gtfs.Route,
          where: r.organization_id == ^organization_id,
          where: r.gtfs_version_id == ^gtfs_version_id,
          where:
            r.route_id == parent_as(:row).from_route_id or
              r.route_id == parent_as(:row).to_route_id,
          where: r.active == false
        )
      )
    )
  end

  defp exclude_inactive_trip_endpoints(query, organization_id, gtfs_version_id) do
    where(
      query,
      [row],
      not exists(
        from(t in GtfsPlanner.Gtfs.Trip,
          join: r in GtfsPlanner.Gtfs.Route,
          on:
            r.organization_id == t.organization_id and
              r.gtfs_version_id == t.gtfs_version_id and
              r.route_id == t.route_id,
          where: t.organization_id == ^organization_id,
          where: t.gtfs_version_id == ^gtfs_version_id,
          where:
            t.trip_id == parent_as(:row).from_trip_id or
              t.trip_id == parent_as(:row).to_trip_id,
          where: r.active == false
        )
      )
    )
  end

  @doc """
  Builds lookup map for stops: UUID → stop_id string.

  ## Examples

      build_stop_lookup(Repo, org_id, version_id)
      # => %{uuid1 => "STOP1", uuid2 => "STOP2", ...}
  """
  def build_stop_lookup(repo, organization_id, gtfs_version_id) do
    alias GtfsPlanner.Gtfs.Stop

    Stop
    |> where([s], s.organization_id == ^organization_id)
    |> where([s], s.gtfs_version_id == ^gtfs_version_id)
    |> select([s], {s.id, s.stop_id})
    |> repo.all()
    |> Map.new()
  end

  @doc """
  Builds lookup map for levels: UUID → level_id string.

  ## Examples

      build_level_lookup(Repo, org_id, version_id)
      # => %{uuid1 => "L1", uuid2 => "L2", ...}
  """
  def build_level_lookup(repo, organization_id, gtfs_version_id) do
    alias GtfsPlanner.Gtfs.Level

    Level
    |> where([l], l.organization_id == ^organization_id)
    |> where([l], l.gtfs_version_id == ^gtfs_version_id)
    |> select([l], {l.id, l.level_id})
    |> repo.all()
    |> Map.new()
  end

  # Primary GTFS ID fields in preference order, used when a schema needs a
  # deterministic single-field sort but has no multi-field identity such as a
  # trip's `stop_sequence` or a route pattern's `route_pattern_id`.
  @ordering_fields [
    :stop_id,
    :route_id,
    :trip_id,
    :agency_id,
    :service_id,
    :fare_id,
    :pathway_id,
    :level_id,
    :attribution_id,
    :inserted_at,
    :id
  ]

  # Natural key columns (the table's unique index) of the Fares v2, Flex, network
  # and translation tables, none of which has a field in `@ordering_fields`.
  # Several key columns are nullable, so rows that tie on the key fall back to
  # `id`, which keeps every export of the same data in the same order.
  @natural_keys %{
    GtfsPlanner.Gtfs.FareProduct => [:fare_product_id, :fare_media_id],
    GtfsPlanner.Gtfs.FareMedia => [:fare_media_id],
    GtfsPlanner.Gtfs.FareLegRule => [:network_id, :from_area_id, :to_area_id, :fare_product_id],
    GtfsPlanner.Gtfs.FareLegJoinRule => [
      :from_network_id,
      :to_network_id,
      :from_stop_id,
      :to_stop_id
    ],
    GtfsPlanner.Gtfs.FareTransferRule => [
      :from_leg_group_id,
      :to_leg_group_id,
      :fare_product_id,
      :transfer_count
    ],
    GtfsPlanner.Gtfs.RiderCategory => [:rider_category_id],
    GtfsPlanner.Gtfs.Timeframe => [:timeframe_group_id, :start_time, :end_time, :service_id],
    GtfsPlanner.Gtfs.Area => [:area_id],
    GtfsPlanner.Gtfs.StopArea => [:area_id, :stop_id],
    GtfsPlanner.Gtfs.Network => [:network_id],
    GtfsPlanner.Gtfs.RouteNetwork => [:network_id, :route_id],
    GtfsPlanner.Gtfs.Location => [:location_id],
    GtfsPlanner.Gtfs.BookingRule => [:booking_rule_id],
    GtfsPlanner.Gtfs.Translation => [
      :table_name,
      :field_name,
      :language,
      :record_id,
      :record_sub_id,
      :field_value
    ]
  }

  # Determines appropriate ordering for GTFS output based on schema
  defp order_by_for_schema(query, GtfsPlanner.Gtfs.StopTime) do
    order_by(query, [s], asc: s.trip_id, asc: s.stop_sequence)
  end

  # Route patterns share a route_id, so the pattern identity breaks the tie
  defp order_by_for_schema(query, GtfsPlanner.Gtfs.RoutePattern) do
    order_by(query, [s], asc: s.route_id, asc: s.route_pattern_id)
  end

  # A closure identity is the whole tuple, so every component orders the output
  defp order_by_for_schema(query, GtfsPlanner.Gtfs.PathwayEvolution) do
    order_by(query, [s],
      asc: s.pathway_id,
      asc: s.service_id,
      asc: s.start_time,
      asc: s.end_time
    )
  end

  defp order_by_for_schema(query, GtfsPlanner.Gtfs.Shape) do
    order_by(query, [s], asc: s.shape_id, asc: s.shape_pt_sequence)
  end

  defp order_by_for_schema(query, schema) when is_map_key(@natural_keys, schema) do
    order_by(query, ^(Map.fetch!(@natural_keys, schema) ++ [:id]))
  end

  defp order_by_for_schema(query, schema) do
    case Enum.find(@ordering_fields, &has_field?(schema, &1)) do
      nil -> query
      field -> order_by(query, [s], asc: field(s, ^field))
    end
  end

  # Check if schema has a field
  defp has_field?(schema, field_name) do
    field_name in schema.__schema__(:fields)
  end
end
