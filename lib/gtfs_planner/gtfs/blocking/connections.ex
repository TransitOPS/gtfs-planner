defmodule GtfsPlanner.Gtfs.Blocking.Connections do
  @moduledoc """
  Pure in-seat connections and their groups, derived from one loaded day.

  A connection is one consecutive pair of trips in one block — the same pair the
  timeline draws as a gap and the connection drawer opens — carrying the type 4/5
  records the day already holds for it, its setting and whether it needs review
  (R13) and the group it belongs to (R12). Groups are the way an agency decides a
  connection: the arrival stop, the two routes and the two directions, so the same
  routes joining at two different stops, or the same stop in two different
  directions, are never one decision. Nothing is stored; `build/1` recomputes all
  of it from the day on every load, and no record is written here.

  The setting of a connection follows R13: no record is `:none`, one type 4 record
  is `:stay`, one type 5 record is `:reboard` and two or more are `:conflict`. A
  connection needs review when it has two or more records or when any of its
  records is stale, because a stale record is one the day load found no longer
  next on at least one day type. A record is paired exactly as the gap drawer
  pairs it, so a pair with no hosting gap is still shown and one pair's records
  are never counted twice.

  Groups sort by connection count descending, then place name, then key, so the
  busiest place is the first thing the page shows and the order is stable for a
  day that has not changed. `token/1` names a group in a URL without exposing a
  joinable id: the key's five parts joined by the unit separator and encoded
  without padding.

  The module is pure: it reads the day it is given and calls no repository,
  clock, file or network (CR-1, CR-4).
  """

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Checks

  # The group's key parts are joined by the ASCII unit separator, which no GTFS
  # id, route id or direction carries, so one part can never be read as two.
  @part <<31>>

  # The handoff kinds `Checks.handoff/2` returns, in the order a group lists the
  # distinct kinds it holds: the same stop, the same station, a nearby stop, and
  # finally a move.
  @handoff_order [:same_stop, :same_station, :nearby, :moves]

  @type setting :: :none | :stay | :reboard | :conflict

  @typedoc """
  R12's group key: the arrival stop, then the from route and direction and the to
  route and direction. A direction the version does not carry is `nil`.
  """
  @type group_key ::
          {String.t() | nil, String.t(), 0 | 1 | nil, String.t(), 0 | 1 | nil}

  @typedoc """
  The place a group is decided at: the arrival stop's parent station when it has
  one, else the stop itself.
  """
  @type place :: %{id: String.t(), name: String.t()}

  @typedoc """
  How many of a group's connections carry each setting, and how many need review.
  A connection needing review is counted under its setting and under `:review`.

  A surface that quotes `stay` or `reboard` beside a filter should count the
  filtered group's own decidable connections instead — these two fields cover
  every connection the group holds, including the ones a chosen filter drops.
  """
  @type counts :: %{
          none: non_neg_integer(),
          stay: non_neg_integer(),
          reboard: non_neg_integer(),
          conflict: non_neg_integer(),
          review: non_neg_integer()
        }

  @type connection :: %{
          id: String.t(),
          block_id: String.t(),
          from: Checks.trip_row(),
          to: Checks.trip_row(),
          gap: Checks.gap(),
          records: [Blocking.in_seat_entry()],
          setting: setting(),
          review?: boolean(),
          group_key: group_key()
        }

  @type group :: %{
          key: group_key(),
          token: String.t(),
          place: place(),
          arrival_stop: Checks.stop_ref() | nil,
          departure_stop: Checks.stop_ref() | nil,
          from_route_id: String.t(),
          to_route_id: String.t(),
          headsign: String.t() | nil,
          turnback?: boolean(),
          handoffs: [atom()],
          wait_min: integer(),
          wait_max: integer(),
          first_arrival: integer() | nil,
          last_arrival: integer() | nil,
          connections: [connection()],
          counts: counts()
        }

  @typedoc "The filters the Connections view applies to the day's groups."
  @type filter :: %{
          optional(:setting) => nil | :none | :stay | :reboard | :review,
          optional(:route) => String.t() | nil,
          optional(:q) => String.t() | nil
        }

  @doc """
  Returns the day's connections and its groups, sorted per R12.

  Every gap of every block is one connection, named by its two trip UUIDs joined by
  a bar, the way the drawer's `gap=` parameter names it, so a page can open a
  connection it
  found here without translating anything. A gap whose two trips the block does
  not carry contributes nothing, which a loaded day cannot produce: a gap is
  derived from the block's own trips.
  """
  @spec build(Blocking.day()) :: %{connections: [connection()], groups: [group()]}
  def build(day) do
    connections = connections(day)

    %{connections: connections, groups: groups(connections)}
  end

  @doc """
  Returns the groups keeping only the connections the filters accept, in the order
  they arrived.

  `setting: :review` keeps the connections needing review whatever their setting;
  `:none`, `:stay` and `:reboard` keep that setting's quiet connections, so a
  connection whose record has gone stale never hides under a decided setting.
  `route` matches either of a connection's routes and `q` is a case-insensitive
  substring of the place name, either stop's name, either route ID, either trip ID
  or `"block " <> block ID`. A group with no surviving connection is dropped, and
  a group that keeps some is rebuilt from them, so its counts and its wait range
  describe what is left.

  The order is the one `build/1` sorted: filtering never re-sorts, so a group
  keeps its place in the day rather than jumping because a filter changed its
  count.
  """
  @spec filter([group()], filter()) :: [group()]
  def filter(groups, params) do
    setting = Map.get(params, :setting)
    route = presence(Map.get(params, :route))
    q = Map.get(params, :q) |> search_term()

    Enum.flat_map(groups, &filter_group(&1, setting, route, q))
  end

  @doc """
  Returns one page of groups, the page it landed on and the page count.

  The page is clamped the way the block list clamps its own, so a page number left
  in a URL by a shorter list lands on the last page instead of showing nothing,
  and an empty list is one empty page 1.
  """
  @spec page([group()], pos_integer(), pos_integer()) :: %{
          groups: [group()],
          page: pos_integer(),
          pages: pos_integer()
        }
  def page(groups, requested, size) when is_integer(requested) and requested > 0 and size > 0 do
    pages = max(div(length(groups) + size - 1, size), 1)
    page = min(requested, pages)

    %{groups: Enum.slice(groups, (page - 1) * size, size), page: page, pages: pages}
  end

  @doc """
  Returns one row per place in the given groups, busiest first.

  A place's count is the connections of every group decided there, `review?` is
  true when any of them needs review, and the coordinates are those of the
  arrival stop — `nil` for a stop the version gives none, which the map reports
  as a place it cannot draw while the list still lists it.
  """
  @spec places([group()]) :: [
          %{
            id: String.t(),
            name: String.t(),
            lat: float() | nil,
            lon: float() | nil,
            count: pos_integer(),
            review?: boolean()
          }
        ]
  def places(groups) do
    groups
    |> Enum.group_by(& &1.place.id)
    |> Enum.map(fn {id, groups} -> place_row(id, groups) end)
    |> Enum.sort_by(&{-&1.count, &1.name})
  end

  @doc """
  Returns the URL-safe name of a group key.

  The key's five parts are joined by the unit separator and encoded as unpadded
  URL-safe Base64, with a missing direction written as an empty part, so
  `Base.url_decode64!(token, padding: false)` returns the key's parts in order.
  """
  @spec token(group_key()) :: String.t()
  def token(key) do
    key
    |> Tuple.to_list()
    |> Enum.map_join(@part, &part/1)
    |> Base.url_encode64(padding: false)
  end

  defp connections(day) do
    in_seat = Map.get(day, :in_seat, %{})

    Enum.flat_map(day.blocks, fn block ->
      Enum.flat_map(block.gaps, &gap_connections(block, &1, in_seat))
    end)
  end

  # A gap whose two trips the block does not carry contributes nothing, which a
  # loaded day cannot produce: a gap is derived from the block's own trips.
  defp gap_connections(block, gap, in_seat) do
    with from when not is_nil(from) <- Enum.find(block.trips, &(&1.id == gap.from_id)),
         to when not is_nil(to) <- Enum.find(block.trips, &(&1.id == gap.to_id)) do
      [connection(block, from, to, gap, in_seat)]
    else
      _other -> []
    end
  end

  defp connection(block, from, to, gap, in_seat) do
    records = pair_records(in_seat, from, to)

    %{
      id: "#{from.id}|#{to.id}",
      block_id: block.summary.block_id,
      from: from,
      to: to,
      gap: gap,
      records: records,
      setting: setting(records),
      review?: review?(records),
      group_key: group_key(from, to)
    }
  end

  # Every type 4/5 record naming both trips of the pair, whichever of the two
  # trips the day's own map lists it under, the same pairing the gap drawer uses.
  defp pair_records(in_seat, from, to) do
    (Map.get(in_seat, from.id, []) ++ Map.get(in_seat, to.id, []))
    |> Enum.filter(&(&1.row.from_trip_id == from.trip_id and &1.row.to_trip_id == to.trip_id))
    |> Enum.uniq()
  end

  defp setting([]), do: :none

  defp setting([%{row: %{transfer_type: 4}}]), do: :stay
  defp setting([%{row: %{transfer_type: 5}}]), do: :reboard
  defp setting(_two_or_more), do: :conflict

  # R13: two records are always a conflict to resolve, and a stale record needs
  # review even when the pair has only that one record.
  defp review?(records) do
    length(records) >= 2 or Enum.any?(records, &match?({:stale, _}, &1.state))
  end

  defp group_key(from, to) do
    {stop_id(from.last_stop), from.route_id, from.direction_id, to.route_id, to.direction_id}
  end

  defp groups(connections) do
    connections
    |> Enum.group_by(& &1.group_key)
    |> Enum.map(fn {key, connections} -> group(key, connections) end)
    |> Enum.sort_by(&{-length(&1.connections), &1.place.name, &1.key})
  end

  # The group's facts are read off its first connection, and its connections are
  # ordered by arrival so the first is the day's first at that place and the
  # arrival range and wait range run the way a reader scans them.
  defp group(key, connections) do
    connections = Enum.sort_by(connections, &{&1.from.last_arrival, &1.to.first_departure, &1.id})
    [first | _] = connections

    %{
      key: key,
      token: token(key),
      place: place(first.from.last_stop),
      arrival_stop: first.from.last_stop,
      departure_stop: first.to.first_stop,
      from_route_id: first.from.route_id,
      to_route_id: first.to.route_id,
      headsign: first.to.trip_headsign,
      turnback?: turnback?(first),
      handoffs: handoffs(connections),
      wait_min: wait(connections, :min),
      wait_max: wait(connections, :max),
      first_arrival: first.from.last_arrival,
      last_arrival: connections |> List.last() |> arrival(),
      connections: connections,
      counts: counts(connections)
    }
  end

  # The place is the arrival stop's station when it has one, so the two bays of a
  # station are one decision, and the stop's own name otherwise. The id follows
  # the name: the parent station's id when there is one, else the stop's own, so
  # `places/1` rolls every group decided at one station into a single place.
  defp place(stop_ref) do
    %{
      id: place_id(stop_ref) || "",
      name: name(stop_ref) || stop_id(stop_ref) || ""
    }
  end

  defp place_id(stop_ref) when is_map(stop_ref),
    do: presence(Map.get(stop_ref, :parent_station)) || Map.get(stop_ref, :stop_id)

  defp place_id(_stop_ref), do: nil

  # Google offers staying on board within one route only for a loop, so a group
  # whose two directions of one route meet is a turnback; a direction the version
  # does not carry cannot establish one.
  defp turnback?(connection) do
    not is_nil(connection.from.direction_id) and not is_nil(connection.to.direction_id) and
      connection.from.route_id == connection.to.route_id and
      connection.from.direction_id != connection.to.direction_id
  end

  defp handoffs(connections) do
    kinds =
      connections
      |> Enum.map(&handoff_kind(&1.gap.handoff))
      |> Enum.uniq()

    Enum.filter(@handoff_order, &(&1 in kinds))
  end

  defp handoff_kind(:same_stop), do: :same_stop
  defp handoff_kind(:same_station), do: :same_station
  defp handoff_kind({:nearby, _meters}), do: :nearby
  defp handoff_kind({:moves, _meters}), do: :moves

  # A wait is the gap in whole minutes, and an overlapping pair's negative gap
  # keeps its sign, so a group whose pairs overlap reports a negative wait rather
  # than rounding the overlap away.
  defp wait(connections, :min), do: connections |> waits() |> Enum.min()
  defp wait(connections, :max), do: connections |> waits() |> Enum.max()

  defp waits(connections), do: Enum.map(connections, &div(&1.gap.gap_secs, 60))

  defp arrival(connection), do: connection.from.last_arrival

  defp counts(connections) do
    Enum.reduce(connections, empty_counts(), fn connection, acc ->
      acc
      |> Map.update!(connection.setting, &(&1 + 1))
      |> Map.update!(:review, &(&1 + if(connection.review?, do: 1, else: 0)))
    end)
  end

  defp empty_counts,
    do: %{none: 0, stay: 0, reboard: 0, conflict: 0, review: 0}

  defp filter_group(group, setting, route, q) do
    case Enum.filter(group.connections, &matches?(&1, group.place.name, setting, route, q)) do
      [] -> []
      connections -> [group(group.key, connections)]
    end
  end

  defp matches?(connection, place_name, setting, route, q) do
    setting_match?(connection, setting) and route_match?(connection, route) and
      search_match?(connection, place_name, q)
  end

  defp setting_match?(_connection, nil), do: true
  defp setting_match?(connection, :review), do: connection.review?

  defp setting_match?(connection, setting) do
    connection.setting == setting and not connection.review?
  end

  defp route_match?(_connection, nil), do: true

  defp route_match?(connection, route) do
    connection.from.route_id == route or connection.to.route_id == route
  end

  defp search_match?(_connection, _place_name, nil), do: true

  defp search_match?(connection, place_name, q) do
    Enum.any?(search_haystack(connection, place_name), &String.contains?(&1, q))
  end

  defp search_haystack(connection, place_name) do
    [
      place_name,
      name(connection.from.last_stop),
      name(connection.to.first_stop),
      connection.from.route_id,
      connection.to.route_id,
      connection.from.trip_id,
      connection.to.trip_id,
      "block " <> connection.block_id
    ]
    |> Enum.reject(&is_nil/1)
    # The term is downcased by `search_term/1`, so the haystack is downcased
    # here: stop names, route ids and trip ids are feed text carrying capitals,
    # and a reader typing "depot" is asking about "Depot Row".
    |> Enum.map(&String.downcase/1)
  end

  defp place_row(id, groups) do
    [first | _] = groups
    stop_ref = first.arrival_stop

    %{
      id: id,
      name: first.place.name,
      lat: coordinate(stop_ref, :lat),
      lon: coordinate(stop_ref, :lon),
      count: Enum.sum(Enum.map(groups, &length(&1.connections))),
      review?: Enum.any?(groups, &(&1.counts.review > 0))
    }
  end

  defp coordinate(stop_ref, key) when is_map(stop_ref), do: Map.get(stop_ref, key)
  defp coordinate(_stop_ref, _key), do: nil

  defp stop_id(stop_ref) when is_map(stop_ref), do: Map.get(stop_ref, :stop_id)
  defp stop_id(_stop_ref), do: nil

  defp name(stop_ref) when is_map(stop_ref),
    do: presence(Map.get(stop_ref, :parent_name) || Map.get(stop_ref, :name))

  defp name(_stop_ref), do: nil

  defp part(nil), do: ""
  defp part(value), do: to_string(value)

  defp search_term(q), do: q |> presence() |> search_downcase()

  defp search_downcase(nil), do: nil
  defp search_downcase(q), do: String.downcase(q)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
