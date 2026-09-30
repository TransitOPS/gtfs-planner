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

  `used_block_ids/3` and `lock_trips!/5` are the two reads a block command needs
  before it writes: R8's collision set for a fresh block ID, and the one `FOR
  UPDATE` query that takes every decision input of the command in UUID order
  (INV-1). Both filter on the organization and the version like every other read
  here, so a command can never see or lock another scope's rows (CR-4).

  `planning_rows/3`, `shape_points/3` and `stop_paths/3` are the planning reads a
  loaded context needs. Each costs one query per kind - four, one and one - so a
  context costs the same however many trips, routes or stops the day has.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.{
    Agency,
    BlockAttribute,
    DeadheadTime,
    Frequency,
    GtfsTime,
    ReliefPoint,
    Route,
    RouteOperatingSetting,
    Shape,
    Stop,
    StopTime,
    Transfer,
    Trip
  }

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
          | {:blocks, [String.t()]}
          | {:blocks, [String.t()], [String.t()]}

  # The four planning-input kinds, as the reads return them: one list per kind,
  # each ordered by its own natural keys so two reads of unchanged data produce
  # the same rows in the same order.
  @type planning_rows :: %{
          route_settings: [
            %{
              route_id: String.t(),
              garage_id: Ecto.UUID.t() | nil,
              required_vehicle_type_id: Ecto.UUID.t() | nil
            }
          ],
          attributes: [
            %{
              service_id: String.t(),
              block_id: String.t(),
              garage_id: Ecto.UUID.t() | nil,
              vehicle_type_id: Ecto.UUID.t() | nil
            }
          ],
          deadhead: [%{from_ref: String.t(), to_ref: String.t(), minutes: integer()}],
          relief: [%{stop_id: String.t()}]
        }

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

  `shape_id` is the trip's own nullable column, carried so a context can measure a
  shaped trip from its shape and a shapeless one from its stop path without
  re-reading the trips. It is deliberately absent from `trip_identities/3`: that
  read feeds a review fingerprint, and adding a column there would change the
  fingerprints already produced.

  The filter is one of the `filter()` variants: a day type's services, exact trip
  UUIDs, natural trip IDs, block IDs within a set of services, or block IDs across
  every service of the version (which is what a calendar combination's companion
  closure needs).
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
        shape_id: t.shape_id,
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
  Loads one filter's trip identities without their endpoints, stops or frequencies.

  The filter is the same `filter()` `trip_rows/3` accepts and the rows come back in
  UUID order. Each carries the mutable trip columns a review fingerprints, including
  `updated_at`, so a caller can read the identities, take its row locks and then read
  the derived rows of exactly the set it locked (the lock-then-reread order
  `Blocking.apply_block_change/4` already uses).
  """
  @spec trip_identities(Ecto.UUID.t(), Ecto.UUID.t(), filter()) :: [map()]
  def trip_identities(organization_id, gtfs_version_id, filter) do
    filter
    |> trips_filter(organization_id, gtfs_version_id)
    |> order_by([t], asc: t.id)
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
  end

  @doc """
  Loads the raw rows behind `trip_rows/3`'s endpoints, stop geometry and headways.

  `stop_times` are the two endpoint rows of each trip - the smallest and the largest
  `stop_sequence`, the same rows `trip_rows/3` derives its clocks from - `stops` are
  the stops those rows name, `parents` the parent stations the stops reference
  (empty when none is referenced or one is missing) and `frequencies` every row of
  the trips rather than only the smallest headway. Each list is ordered by its
  natural keys.

  A caller that digests these rows detects a same-count endpoint replacement, a
  retiming, a stop or parent change and a headway change instead of trusting only the
  derived values: a stop's own coordinates hide a changed parent otherwise, and the
  smallest headway hides a second frequency window. The read is five queries whatever
  the number of trips.
  """
  @spec raw_sources(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) :: %{
          stop_times: [map()],
          stops: [map()],
          parents: [map()],
          frequencies: [map()]
        }
  def raw_sources(organization_id, gtfs_version_id, trip_ids) do
    trip_ids_query =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
            t.id in ^trip_ids,
        select: t.trip_id
      )

    first_endpoints = endpoint_rows(organization_id, gtfs_version_id, trip_ids_query, :asc)
    last_endpoints = endpoint_rows(organization_id, gtfs_version_id, trip_ids_query, :desc)

    stops =
      first_endpoints
      |> endpoint_stop_ids(last_endpoints)
      |> then(&stops_by_id(organization_id, gtfs_version_id, &1))

    parents =
      stops
      |> Map.values()
      |> Enum.map(& &1.parent_station)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> then(&stops_by_id(organization_id, gtfs_version_id, &1))

    %{
      stop_times:
        (Map.values(first_endpoints) ++ Map.values(last_endpoints))
        |> Enum.sort_by(&{&1.trip_id, &1.stop_sequence}),
      stops: stops |> Map.values() |> Enum.sort_by(& &1.stop_id),
      parents: parents |> Map.values() |> Enum.sort_by(& &1.stop_id),
      frequencies: frequency_source_rows(organization_id, gtfs_version_id, trip_ids_query)
    }
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
  Loads the four planning-input kinds a context needs, one query per kind.

  Route operating settings, entered driving times and relief points are scoped to
  the organization and the version alone: a route, a reference pair and a stop are
  properties of the version, not of one day type. Block attributes are
  additionally restricted to `service_ids`, because an attribute row for a service
  the loaded day does not run is not one of that day's inputs - it is kept for the
  next day rather than returned here.

  Every list is ordered by its own natural keys, so a context digest over two
  reads of unchanged data is stable. The read is four queries whatever the number
  of routes, services, references or relief points.
  """
  @spec planning_rows(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: planning_rows()
  def planning_rows(organization_id, gtfs_version_id, service_ids) do
    %{
      route_settings:
        from(s in RouteOperatingSetting,
          where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
          order_by: [asc: s.route_id],
          select: %{
            route_id: s.route_id,
            garage_id: s.garage_id,
            required_vehicle_type_id: s.required_vehicle_type_id
          }
        )
        |> Repo.all(),
      attributes:
        from(a in BlockAttribute,
          where:
            a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
              a.service_id in ^service_ids,
          order_by: [asc: a.service_id, asc: a.block_id],
          select: %{
            service_id: a.service_id,
            block_id: a.block_id,
            garage_id: a.garage_id,
            vehicle_type_id: a.vehicle_type_id
          }
        )
        |> Repo.all(),
      deadhead:
        from(d in DeadheadTime,
          where: d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id,
          order_by: [asc: d.from_ref, asc: d.to_ref],
          select: %{from_ref: d.from_ref, to_ref: d.to_ref, minutes: d.minutes}
        )
        |> Repo.all(),
      relief:
        from(r in ReliefPoint,
          where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
          order_by: [asc: r.stop_id],
          select: %{stop_id: r.stop_id}
        )
        |> Repo.all()
    }
  end

  @doc """
  Loads the points of each of `shape_ids`, keyed by shape ID and walked in order.

  The order is `shape_pt_sequence` in SQL, not the order the feed happened to
  insert the points in, so a shape whose points were imported out of order still
  measures the path it drew. Coordinates are decimals on the column and floats in
  the answer, which is what `Blocking.Distance.path_km/1` takes.

  A shape ID with no rows is absent from the map rather than mapped to `[]`: a
  trip naming it is a shaped trip whose measurement is zero, and the caller decides
  what that means. One query answers any number of shapes.
  """
  @spec shape_points(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: %{
          String.t() => [{float(), float()}]
        }
  def shape_points(organization_id, gtfs_version_id, shape_ids) do
    from(s in Shape,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.shape_id in ^shape_ids,
      order_by: [asc: s.shape_id, asc: s.shape_pt_sequence],
      select: {s.shape_id, s.shape_pt_lat, s.shape_pt_lon}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &point/1)
  end

  @doc """
  Loads each trip's stop path, keyed by trip ID and walked in `stop_sequence` order.

  One query joins `stop_times` to their stops and left joins each stop's parent
  station, coalescing the parent's coordinates for a stop that has none of its own
  exactly as `stop_refs/3` substitutes them for a layover distance. A stop that
  resolves to neither a coordinate of its own nor one of its parent's is skipped
  rather than contributing a point at an unknown position, so the answer is the
  walkable path of the trip. A `stop_times` row naming a stop the version does not
  describe is dropped by the join for the same reason.

  Called only for shapeless trips, whose distance is taken from this path; a
  shaped trip is measured once per `shape_id` by `shape_points/3` instead.
  """
  @spec stop_paths(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: %{
          String.t() => [{float(), float()}]
        }
  def stop_paths(organization_id, gtfs_version_id, trip_ids) do
    from(st in StopTime,
      join: s in Stop,
      on:
        s.stop_id == st.stop_id and s.organization_id == st.organization_id and
          s.gtfs_version_id == st.gtfs_version_id,
      left_join: p in Stop,
      on:
        p.stop_id == s.parent_station and p.organization_id == st.organization_id and
          p.gtfs_version_id == st.gtfs_version_id,
      where:
        st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
          st.trip_id in ^trip_ids,
      order_by: [asc: st.trip_id, asc: st.stop_sequence],
      select: {st.trip_id, coalesce(s.stop_lat, p.stop_lat), coalesce(s.stop_lon, p.stop_lon)}
    )
    |> Repo.all()
    |> Enum.reject(fn {_id, lat, lon} -> is_nil(lat) or is_nil(lon) end)
    |> Enum.group_by(&elem(&1, 0), &point/1)
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

  @doc """
  Returns every block ID used by a trip of `service_ids`, as a set of strings.

  `service_ids` are the affected day types' services, so the answer is exactly the
  set of IDs R8 must avoid: a trip that runs on a date of a changed trip. An
  unblocked trip contributes nothing and a blank scope returns an empty set.
  """
  @spec used_block_ids(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: MapSet.t(String.t())
  def used_block_ids(organization_id, gtfs_version_id, service_ids) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
          t.service_id in ^service_ids and not is_nil(t.block_id),
      distinct: true,
      select: t.block_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Takes one `FOR UPDATE` lock on every command decision input and returns their UUIDs.

  The rows are the changed trips (`changed_ids`) plus every trip of a touched block
  (`block_ids`, the changed trips' old block IDs and the target) that runs in an
  affected service (`service_ids`): exactly what `Review.build/1` and the command's
  fingerprint read, so no writer holding a trip lock can change them between the
  review and the commit. `ORDER BY id` makes the lock order the UUID order INV-1
  requires, so two concurrent commands take the same rows in the same sequence.
  """
  @spec lock_trips!(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()], [String.t()], [String.t()]) ::
          [Ecto.UUID.t()]
  def lock_trips!(organization_id, gtfs_version_id, changed_ids, block_ids, service_ids) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
          (t.id in ^changed_ids or (t.block_id in ^block_ids and t.service_id in ^service_ids)),
      select: t.id,
      order_by: t.id,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
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

  # No service restriction: a combination's companions are every trip sharing a touched
  # block anywhere in the version, so a calendar the review did not select still decides
  # whether the moved block keeps its ID (AC-17).
  defp trips_filter({:blocks, block_ids}, organization_id, gtfs_version_id) do
    scoped_trips(organization_id, gtfs_version_id)
    |> where([t], t.block_id in ^block_ids)
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
        stop_sequence: st.stop_sequence,
        arrival_time: st.arrival_time,
        departure_time: st.departure_time
      }
    )
  end

  defp frequency_source_rows(organization_id, gtfs_version_id, trip_ids) do
    from(f in Frequency,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
          f.trip_id in subquery(trip_ids),
      order_by: [asc: f.trip_id, asc: f.start_time, asc: f.headway_secs, asc: f.id],
      select: %{
        id: f.id,
        trip_id: f.trip_id,
        start_time: f.start_time,
        end_time: f.end_time,
        headway_secs: f.headway_secs,
        exact_times: f.exact_times
      }
    )
    |> Repo.all()
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

  # One `{key, lat, lon}` row becomes the `{lat, lon}` point both distance reads
  # and `Blocking.Distance.path_km/1` speak in, with the column's decimal already
  # narrowed to a float. A row with no coordinates never reaches here.
  defp point({_id, %Decimal{} = lat, %Decimal{} = lon}),
    do: {Decimal.to_float(lat), Decimal.to_float(lon)}

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
      shape_id: trip.shape_id,
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
