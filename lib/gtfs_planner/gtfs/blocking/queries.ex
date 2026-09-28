defmodule GtfsPlanner.Gtfs.Blocking.Queries do
  @moduledoc """
  Scoped reads for one GTFS version's blocks.

  Every query filters on both `organization_id` and `gtfs_version_id`, so another
  organization, another version or an unpublished scope can never reach a loaded
  day or a block command (CR-4).

  `trip_rows/3` loads the trips, their two endpoint stop times, the endpoint stops
  and their frequency rows in six queries whatever the trip count: the trips
  themselves, one first and one last `DISTINCT ON (trip_id)` stop-time query, one
  query for the endpoint stops, one for their parent stations and one grouped
  `frequencies` query. Endpoints are chosen by `stop_sequence` in SQL, never by an
  ordering of clock text, and the clock values are parsed with `GtfsTime.parse/1`
  in Elixir, so `25:10:00` becomes the integer 90_600 and orders after `05:00:00` (CR-3).

  A stop reference carries its parent station's coordinates when its own are nil,
  so a layover distance is decided from one row per stop (`Checks.handoff/2`).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.{Agency, Frequency, GtfsTime, Route, Stop, StopTime, Transfer, Trip}
  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Repo

  # `stop_ref/0` and `trip_row/0` are the shapes `Checks` already declares and
  # consumes, so the read and the pure checks cannot drift apart.
  @type stop_ref :: Checks.stop_ref()

  @type trip_row :: Checks.trip_row()

  @type route_info :: %{
          route_id: String.t(),
          short_name: String.t() | nil,
          long_name: String.t() | nil,
          route_color: String.t() | nil,
          route_text_color: String.t() | nil
        }

  @type filter ::
          {:services, [String.t()]}
          | {:uuids, [Ecto.UUID.t()]}
          | {:trip_ids, [String.t()]}
          | {:blocks, [String.t()], [String.t()]}

  @type in_seat_row :: %{
          id: Ecto.UUID.t(),
          from_trip_id: String.t(),
          to_trip_id: String.t(),
          transfer_type: 4 | 5,
          from_stop_id: String.t() | nil,
          to_stop_id: String.t() | nil
        }

  @doc """
  Loads one filter's trips with both endpoints, their stops and their frequency flag.

  `first_arrival`, `first_departure`, `last_arrival` and `last_departure` come from
  the smallest and largest `stop_sequence` rows of `stop_times`; a value that is
  missing or does not parse is `nil`. `plottable?` is true exactly when all four
  parsed, `frequency?` exactly when the trip has a `frequencies` row, and
  `headway_secs` is the smallest headway of those rows.

  The filter is one of the four `filter()` variants: a day type's services, exact
  trip UUIDs, natural trip IDs, or block IDs within a set of services.
  """
  @spec trip_rows(Ecto.UUID.t(), Ecto.UUID.t(), filter()) :: [trip_row()]
  def trip_rows(organization_id, gtfs_version_id, filter) do
    filtered = trips_filter(filter, organization_id, gtfs_version_id)
    trip_ids = from(t in filtered, select: t.trip_id)

    trips =
      filtered
      |> select([t], %{
        id: t.id,
        trip_id: t.trip_id,
        route_id: t.route_id,
        service_id: t.service_id,
        block_id: t.block_id,
        trip_headsign: t.trip_headsign,
        route_pattern_id: t.route_pattern_id,
        updated_at: t.updated_at
      })
      |> Repo.all()

    first_endpoints = endpoint_rows(organization_id, gtfs_version_id, trip_ids, :asc)
    last_endpoints = endpoint_rows(organization_id, gtfs_version_id, trip_ids, :desc)

    stop_refs =
      first_endpoints
      |> endpoint_stop_ids(last_endpoints)
      |> then(&stop_refs(&1, organization_id, gtfs_version_id))

    headways = headway_rows(organization_id, gtfs_version_id, trip_ids)

    Enum.map(trips, &trip_row(&1, first_endpoints, last_endpoints, stop_refs, headways))
  end

  @doc """
  Returns the route identities of `route_ids`, keyed by route ID.

  The IDs are deduplicated, so one route shared by every trip of a day is one
  query parameter rather than one per trip.
  """
  @spec routes(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: %{String.t() => route_info()}
  def routes(organization_id, gtfs_version_id, route_ids) do
    route_ids = Enum.uniq(route_ids)

    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.route_id in ^route_ids,
      select: %{
        route_id: r.route_id,
        short_name: r.route_short_name,
        long_name: r.route_long_name,
        route_color: r.route_color,
        route_text_color: r.route_text_color
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.route_id, &1})
  end

  @doc """
  Loads the type 4/5 transfer records naming any of `trip_ids`.

  A record is returned when either of its two trips is among the natural IDs,
  so a pair is read once for both named trips and a record whose other trip runs
  outside the day type is included (AC-7). One query answers whatever the number
  of records or trips, and `order_by` makes the reading order stable: the records
  are ordered by their two trip IDs and their UUID.

  Rows are not joined to the trips they name: a record whose trip is absent from
  the version is returned like any other, so the rule can report it as missing.
  """
  @spec in_seat_rows(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: [in_seat_row()]
  def in_seat_rows(organization_id, gtfs_version_id, trip_ids) do
    from(t in Transfer,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
          t.transfer_type in [4, 5] and
          (t.from_trip_id in ^trip_ids or t.to_trip_id in ^trip_ids),
      order_by: [asc: t.from_trip_id, asc: t.to_trip_id, asc: t.id],
      select: %{
        id: t.id,
        from_trip_id: t.from_trip_id,
        to_trip_id: t.to_trip_id,
        transfer_type: t.transfer_type,
        from_stop_id: t.from_stop_id,
        to_stop_id: t.to_stop_id
      }
    )
    |> Repo.all()
  end

  @doc """
  Reports whether the version's agencies carry more than one timezone.

  A version whose agencies disagree needs the day read in each of their local
  times, which the scope header names.
  """
  @spec mixed_timezones?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def mixed_timezones?(organization_id, gtfs_version_id) do
    timezone_count =
      Repo.one(
        from(a in Agency,
          where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
          select: count(a.agency_timezone, :distinct)
        )
      )

    timezone_count > 1
  end

  defp trips_filter({:services, service_ids}, organization_id, gtfs_version_id) do
    scoped_trips(organization_id, gtfs_version_id)
    |> where([t], t.service_id in ^service_ids)
  end

  defp trips_filter({:uuids, ids}, organization_id, gtfs_version_id) do
    scoped_trips(organization_id, gtfs_version_id)
    |> where([t], t.id in ^ids)
  end

  defp trips_filter({:trip_ids, trip_ids}, organization_id, gtfs_version_id) do
    scoped_trips(organization_id, gtfs_version_id)
    |> where([t], t.trip_id in ^trip_ids)
  end

  defp trips_filter({:blocks, block_ids, service_ids}, organization_id, gtfs_version_id) do
    scoped_trips(organization_id, gtfs_version_id)
    |> where([t], t.block_id in ^block_ids and t.service_id in ^service_ids)
  end

  defp scoped_trips(organization_id, gtfs_version_id) do
    from(t in Trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id
    )
  end

  # `DISTINCT ON (trip_id)` with `stop_sequence` as the leading tie-breaker after
  # the trip ID keeps one row per trip: the smallest sequence when ascending and
  # the largest when descending.
  defp endpoint_rows(organization_id, gtfs_version_id, trip_ids, direction) do
    organization_id
    |> endpoint_query(gtfs_version_id, trip_ids)
    |> distinct([st], asc: st.trip_id)
    |> order_by([st], asc: st.trip_id)
    |> order_by([st], [{^direction, st.stop_sequence}])
    |> Repo.all()
    |> Map.new(&{&1.trip_id, &1})
  end

  defp endpoint_query(organization_id, gtfs_version_id, trip_ids) do
    from(st in StopTime,
      where:
        st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
          st.trip_id in subquery(trip_ids),
      select: %{
        trip_id: st.trip_id,
        stop_id: st.stop_id,
        arrival_time: st.arrival_time,
        departure_time: st.departure_time
      }
    )
  end

  defp headway_rows(organization_id, gtfs_version_id, trip_ids) do
    from(f in Frequency,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
          f.trip_id in subquery(trip_ids),
      group_by: f.trip_id,
      select: %{trip_id: f.trip_id, headway_secs: min(f.headway_secs)}
    )
    |> Repo.all()
    |> Map.new(&{&1.trip_id, &1.headway_secs})
  end

  defp endpoint_stop_ids(first_endpoints, last_endpoints) do
    (Map.values(first_endpoints) ++ Map.values(last_endpoints))
    |> Enum.map(& &1.stop_id)
    |> Enum.uniq()
  end

  defp stop_refs(stop_ids, organization_id, gtfs_version_id) do
    stops = stops_by_id(organization_id, gtfs_version_id, stop_ids)

    parents =
      stops
      |> Map.values()
      |> Enum.map(& &1.parent_station)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> then(&stops_by_id(organization_id, gtfs_version_id, &1))

    Map.new(stops, fn {stop_id, stop} ->
      {stop_id, stop_ref(stop, Map.get(parents, stop.parent_station))}
    end)
  end

  defp stops_by_id(organization_id, gtfs_version_id, stop_ids) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id in ^stop_ids,
      select: %{
        stop_id: s.stop_id,
        name: s.stop_name,
        parent_station: s.parent_station,
        lat: s.stop_lat,
        lon: s.stop_lon
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.stop_id, &1})
  end

  defp stop_ref(stop, parent) do
    %{
      stop_id: stop.stop_id,
      name: stop.name,
      parent_station: stop.parent_station,
      lat: coordinate(stop.lat) || coordinate(parent && parent.lat),
      lon: coordinate(stop.lon) || coordinate(parent && parent.lon)
    }
  end

  defp coordinate(nil), do: nil
  defp coordinate(%Decimal{} = value), do: Decimal.to_float(value)

  defp trip_row(trip, first_endpoints, last_endpoints, stop_refs, headways) do
    first = Map.get(first_endpoints, trip.trip_id)
    last = Map.get(last_endpoints, trip.trip_id)

    {first_arrival, first_departure} = endpoint_times(first)
    {last_arrival, last_departure} = endpoint_times(last)

    %{
      id: trip.id,
      trip_id: trip.trip_id,
      route_id: trip.route_id,
      service_id: trip.service_id,
      block_id: trip.block_id,
      trip_headsign: trip.trip_headsign,
      route_pattern_id: trip.route_pattern_id,
      updated_at: trip.updated_at,
      frequency?: Map.has_key?(headways, trip.trip_id),
      headway_secs: Map.get(headways, trip.trip_id),
      first_arrival: first_arrival,
      first_departure: first_departure,
      last_arrival: last_arrival,
      last_departure: last_departure,
      first_stop: stop_ref_for(first, stop_refs),
      last_stop: stop_ref_for(last, stop_refs),
      plottable?:
        Enum.all?([first_arrival, first_departure, last_arrival, last_departure], &is_integer/1)
    }
  end

  defp endpoint_times(nil), do: {nil, nil}

  defp endpoint_times(endpoint) do
    {parse_time(endpoint.arrival_time), parse_time(endpoint.departure_time)}
  end

  defp stop_ref_for(nil, _stop_refs), do: nil
  defp stop_ref_for(endpoint, stop_refs), do: Map.get(stop_refs, endpoint.stop_id)

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> nil
    end
  end
end
