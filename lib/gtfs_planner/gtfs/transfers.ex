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
  5; counts cover the whole version. Both views are read-only here: in-seat rows
  carry no attention reasons and no competitors, and nothing in this module
  creates, changes or deletes a transfer, so a catalog read has no stored effect.
  This read returns the whole view as one page (`page` is 1, `per_page` is the row
  count, `filter_options` is empty); search, filters, sorting, pagination and rule
  selection are not consumed yet.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers.Overlaps
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @in_seat_types [4, 5]

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

  @doc """
  Loads one version's transfer catalog annotated for the requested view.

  Options are read from a keyword list; `view` selects `:general` (the default,
  types 0–3) or `:in_seat` (types 4 and 5). Rows are ordered by the from endpoint's
  display name, then the to endpoint's, then the id, and the first row of the view
  is selected with its competitor rows. Every query is scoped by organization and
  version, so a foreign or mismatched pair yields an empty catalog.
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
    rows = if view == :in_seat, do: in_seat_rows, else: general_rows
    selected = List.first(rows)

    %{
      view: view,
      rows: rows,
      total_count: length(rows),
      page: 1,
      per_page: max(length(rows), 1),
      selected: selected,
      competitors: competitors(rows, selected),
      counts: %{general: length(general), in_seat: length(in_seat)},
      filter_options: %{stops: [], routes: [], types: []}
    }
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
    |> Enum.sort_by(&sort_key/1)
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

  # -- View, order and reverse links -----------------------------------------

  defp requested_view(opts) do
    case Keyword.get(opts, :view) do
      :in_seat -> :in_seat
      _other -> :general
    end
  end

  defp in_seat?(%Transfer{transfer_type: type}), do: type in @in_seat_types

  defp sort_key(row) do
    {row.from |> display() |> String.downcase(), row.to |> display() |> String.downcase(), row.id}
  end

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
end
