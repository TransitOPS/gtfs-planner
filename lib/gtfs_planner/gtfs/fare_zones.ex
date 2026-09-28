defmodule GtfsPlanner.Gtfs.FareZones do
  @moduledoc """
  Version-scoped fare zones and the projection of `fare_rules` rows into rules.

  This sub-context owns fare-zone data outside import: it is the only module that
  reads `fare_zones`, and — with the full importer — the only module that writes
  `stops.zone_id` and changes `fare_rules` rows. LiveViews call these functions
  instead of querying those tables themselves.

  Every read and write is filtered by `organization_id` and `gtfs_version_id`, so
  a row of another organization or version never resolves. Zone IDs and rule zone
  references are the exact stored strings: they are compared and written
  byte-for-byte, never trimmed or normalized. Membership counts and stop lists
  cover boardable stops (`location_type` 0) only; station and entrance zone IDs
  are kept and exported but not edited.

  `list_rule_groups/2` is the read side of the rule projection. One UI fare rule
  is exactly the set of `fare_rules` rows sharing `(fare_id, route_id, origin_id,
  destination_id, contains_id IS NOT NULL)`: a `contains_id` of NULL forms the
  rule for the journey itself, and rows with a `contains_id` form one rule whose
  `contains` values are the zones the journey must all visit. Every row of the
  version belongs to exactly one group, duplicate rows included, so the
  projection is lossless.

  `inventory/2` is the union of the version's `fare_zones` records, its distinct
  `stops.zone_id` values of every location type and the zone IDs its fare rules
  reference, compared byte-for-byte. A declared zone keeps its record's name and
  palette color; every other zone is named by its exact ID and colored with
  `FareZone.default_color/1`. `stop_count` counts boardable members and
  `other_stop_count` the remaining location types. `checks/2` derives the Checks
  tab's rows from that inventory and `zone_names/3` resolves display names for a
  list of zone IDs.

  The workspace's stop reads — `list_stops/3`, `matching_stop_ids/3` and
  `list_stop_points/2` — cover the version's boardable stops only. A zone filter
  matches the exact stored ID, search treats `%` and `_` literally, and the order
  is `stop_name` with names missing last, then `stop_id`, so the list pages, the
  current match and the map points stay deterministic.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @type zone :: %{
          zone_id: String.t(),
          name: String.t(),
          color: String.t(),
          declared?: boolean(),
          stop_count: non_neg_integer(),
          other_stop_count: non_neg_integer(),
          rule_count: non_neg_integer()
        }

  @type inventory :: %{
          zones: [zone()],
          unassigned_count: non_neg_integer(),
          boardable_count: non_neg_integer()
        }

  @type rule_key :: {String.t(), String.t() | nil, String.t() | nil, String.t() | nil, boolean()}

  @type rule_row :: %{
          id: Ecto.UUID.t(),
          fare_id: String.t(),
          route_id: String.t() | nil,
          origin_id: String.t() | nil,
          destination_id: String.t() | nil,
          contains_id: String.t() | nil
        }

  @type rule_group :: %{
          key: rule_key(),
          fare_id: String.t(),
          route_id: String.t() | nil,
          origin_id: String.t() | nil,
          destination_id: String.t() | nil,
          contains: [String.t()],
          rows: [rule_row()],
          fare: %{price: Decimal.t(), currency_type: String.t()} | nil,
          route: %{short_name: String.t() | nil, long_name: String.t() | nil} | nil,
          unknown_fare?: boolean(),
          unknown_route?: boolean()
        }

  @type stop_filter :: :all | :unassigned | {:zone, String.t()}

  @type stop_entry :: %{
          id: Ecto.UUID.t(),
          stop_id: String.t(),
          stop_name: String.t() | nil,
          parent_station: String.t() | nil,
          platform_code: String.t() | nil,
          zone_id: String.t() | nil,
          located?: boolean()
        }

  @type stop_page :: %{
          entries: [stop_entry()],
          total_count: non_neg_integer(),
          page: pos_integer(),
          per_page: pos_integer(),
          without_location_count: non_neg_integer()
        }

  @type stop_point :: [Ecto.UUID.t() | String.t() | float() | nil]

  @type assignment_change :: %{id: Ecto.UUID.t(), from: String.t() | nil, to: String.t() | nil}

  @type checks :: %{
          stopless_referenced: [zone()],
          unassigned_count: non_neg_integer(),
          empty_declared: [zone()],
          rules_reference_zones?: boolean()
        }

  @doc """
  Projects every `fare_rules` row of a version into one group per UI rule.

  Rows are grouped by `(fare_id, route_id, origin_id, destination_id, contains_id
  IS NOT NULL)`; `contains` holds the sorted unique non-nil `contains_id` values
  and `rows` lists every contributing row, duplicates included, ordered by ID.
  The group resolves its fare from the scoped `fare_attributes` row and its route
  from the scoped `routes` row: a missing fare sets `unknown_fare?` with a nil
  `fare`, a missing non-nil route sets `unknown_route?` with a nil `route`, and a
  nil route ID resolves to no route without being unknown.

  Groups are ordered by `fare_id`, origin, destination, route (nil first) and
  contains presence. A pair that is not a version of the organization returns an
  empty list.
  """
  @spec list_rule_groups(Ecto.UUID.t(), Ecto.UUID.t()) :: [rule_group()]
  def list_rule_groups(organization_id, gtfs_version_id) do
    rules = list_rows(organization_id, gtfs_version_id)
    fares = fare_index(organization_id, gtfs_version_id, Enum.map(rules, & &1.fare_id))
    routes = route_index(organization_id, gtfs_version_id, Enum.map(rules, & &1.route_id))

    rules
    |> Enum.group_by(&group_key/1)
    |> Enum.map(fn {key, rows} -> build_group(key, rows, fares, routes) end)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc """
  The version's fare-zone inventory: declared records, stop zone IDs and rules.

  The zones are the byte-for-byte union of the version's `fare_zones` records,
  the distinct non-nil `stops.zone_id` values of every location type and the zone
  IDs its fare rules reference, sorted by ID. A zone with a record takes that
  record's name and color and is `declared?`; every other zone is named by its
  exact ID and colored with `FareZone.default_color/1`.

  `stop_count` counts `location_type` 0 members and `other_stop_count` the rest,
  so a zone carried only by a station or entrance has no stops. `rule_count`
  counts fare rules, not rows: a rule that references a zone twice, or whose rows
  repeat, counts once. `boardable_count` is every `location_type` 0 stop of the
  version and `unassigned_count` those without a zone.

  IDs are returned exactly as stored, so `" A"` and `"A"` are two zones with
  their own counts. A pair that is not a version of the organization returns an
  empty inventory.
  """
  @spec inventory(Ecto.UUID.t(), Ecto.UUID.t()) :: inventory()
  def inventory(organization_id, gtfs_version_id) do
    stop_counts = stop_zone_counts(organization_id, gtfs_version_id)
    declared = declared_zones(organization_id, gtfs_version_id)
    rule_counts = rule_zone_counts(organization_id, gtfs_version_id)
    {boardable_count, unassigned_count} = boardable_counts(organization_id, gtfs_version_id)

    zones =
      Enum.uniq(Map.keys(stop_counts) ++ Map.keys(declared) ++ Map.keys(rule_counts))
      |> Enum.sort()
      |> Enum.map(&build_zone(&1, declared, stop_counts, rule_counts))

    %{zones: zones, unassigned_count: unassigned_count, boardable_count: boardable_count}
  end

  @doc """
  The Checks tab's derived state.

  `stopless_referenced` lists the zones fare rules use that have no boardable
  stops, `unassigned_count` the version's boardable stops without a zone,
  `empty_declared` the declared zones that have no stops and no rules, and
  `rules_reference_zones?` whether any fare rule references a zone at all.
  """
  @spec checks(Ecto.UUID.t(), Ecto.UUID.t()) :: checks()
  def checks(organization_id, gtfs_version_id) do
    %{zones: zones, unassigned_count: unassigned_count} =
      inventory(organization_id, gtfs_version_id)

    %{
      stopless_referenced: Enum.filter(zones, &(&1.rule_count > 0 and &1.stop_count == 0)),
      unassigned_count: unassigned_count,
      empty_declared:
        Enum.filter(zones, &(&1.declared? and &1.stop_count == 0 and &1.rule_count == 0)),
      rules_reference_zones?: Enum.any?(zones, &(&1.rule_count > 0))
    }
  end

  @doc """
  Resolves display names for zone IDs.

  A zone with a `fare_zones` record returns that record's name; an undeclared
  zone returns its exact ID, so every requested ID has an entry. IDs of another
  organization or version never resolve.
  """
  @spec zone_names(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: %{String.t() => String.t()}
  def zone_names(_organization_id, _gtfs_version_id, []), do: %{}

  def zone_names(organization_id, gtfs_version_id, zone_ids) do
    names =
      from(z in FareZone,
        where:
          z.organization_id == ^organization_id and z.gtfs_version_id == ^gtfs_version_id and
            z.zone_id in ^Enum.uniq(zone_ids),
        select: {z.zone_id, z.name}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(zone_ids, fn zone_id -> {zone_id, Map.get(names, zone_id, zone_id)} end)
  end

  @default_page 1
  @default_per_page 100

  @doc """
  Lists one page of the version's boardable stops for the workspace list.

  `:filter` is `:all`, `:unassigned` (boardable stops without a zone) or
  `{:zone, id}`, which matches the stored zone ID byte-for-byte, so `" A"` never
  returns `"A"`. `:q` searches stop name and stop ID case-insensitively with `%`
  and `_` matched literally, so `50%` finds `Gate 50%` and not `Gate 500`, and
  `a_b` does not find `axb`; a nil or empty `:q` searches nothing.

  Entries are ordered by `stop_name` with names missing last, then by `stop_id`,
  so page boundaries do not depend on the database. `total_count` counts the
  stops the filter and search match, and `page` is clamped into `1..last_page`:
  a page past the end returns the last page, and an empty result is page 1.
  `without_location_count` counts the stops the filter alone matches that miss
  `stop_lat` or `stop_lon`, ignoring `:q`, for the workspace's "N without map
  location" caption. An entry carries `located?: false` when either coordinate
  is missing.

  A pair that is not a version of the organization returns an empty page.
  """
  @spec list_stops(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: stop_page()
  def list_stops(organization_id, gtfs_version_id, opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)
    per_page = Keyword.get(opts, :per_page, @default_per_page)

    matched =
      organization_id
      |> boardable_query(gtfs_version_id)
      |> apply_filter(filter)
      |> apply_search(Keyword.get(opts, :q))

    total_count = count_stops(matched)
    page = clamp_page(Keyword.get(opts, :page, @default_page), total_count, per_page)

    entries =
      matched
      |> order_by([s], asc_nulls_last: s.stop_name, asc: s.stop_id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> select([s], %{
        id: s.id,
        stop_id: s.stop_id,
        stop_name: s.stop_name,
        parent_station: s.parent_station,
        platform_code: s.platform_code,
        zone_id: s.zone_id,
        located?: not is_nil(s.stop_lat) and not is_nil(s.stop_lon)
      })
      |> Repo.all()

    %{
      entries: entries,
      total_count: total_count,
      page: page,
      per_page: per_page,
      without_location_count:
        count_stops(unlocated_stops(organization_id, gtfs_version_id, filter))
    }
  end

  @doc """
  Lists the IDs of every boardable stop a filter and search match.

  The result is the whole set `list_stops/3` pages through, in the same order
  (`stop_name` with missing names last, then `stop_id`), so a caller can hold it
  as the current match and offer "select all matching". `:ids` restricts the
  result to the given stop UUIDs: UUIDs of another organization or version and
  UUIDs of non-boardable stops are dropped, so one call validates a client
  selection. An empty `:ids` list matches nothing.
  """
  @spec matching_stop_ids(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: [Ecto.UUID.t()]
  def matching_stop_ids(organization_id, gtfs_version_id, opts \\ []) do
    organization_id
    |> boardable_query(gtfs_version_id)
    |> apply_filter(Keyword.get(opts, :filter, :all))
    |> apply_search(Keyword.get(opts, :q))
    |> restrict_to_ids(Keyword.get(opts, :ids))
    |> order_by([s], asc_nulls_last: s.stop_name, asc: s.stop_id)
    |> select([s], s.id)
    |> Repo.all()
  end

  @doc """
  Lists the map points of the version's located boardable stops.

  Each point is the list `[id, stop_id, stop_name, lat, lon, zone_id,
  parent_station]`, ordered by `stop_id`, so the whole payload encodes directly
  as the map hook's JSON. Only `location_type` 0 stops with both `stop_lat` and
  `stop_lon` appear, and the coordinates are floats. The zone ID is the exact
  stored string.

  A pair that is not a version of the organization returns an empty list.
  """
  @spec list_stop_points(Ecto.UUID.t(), Ecto.UUID.t()) :: [stop_point()]
  def list_stop_points(organization_id, gtfs_version_id) do
    organization_id
    |> boardable_query(gtfs_version_id)
    |> where([s], not is_nil(s.stop_lat) and not is_nil(s.stop_lon))
    |> order_by([s], asc: s.stop_id)
    |> select([s], {
      s.id,
      s.stop_id,
      s.stop_name,
      s.stop_lat,
      s.stop_lon,
      s.zone_id,
      s.parent_station
    })
    |> Repo.all()
    |> Enum.map(fn {id, stop_id, stop_name, lat, lon, zone_id, parent_station} ->
      [
        id,
        stop_id,
        stop_name,
        Decimal.to_float(lat),
        Decimal.to_float(lon),
        zone_id,
        parent_station
      ]
    end)
  end

  defp boardable_query(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.location_type == 0
    )
  end

  defp apply_filter(query, :all), do: query
  defp apply_filter(query, :unassigned), do: where(query, [s], is_nil(s.zone_id))

  defp apply_filter(query, {:zone, zone_id}) do
    where(query, [s], s.zone_id == ^zone_id)
  end

  defp apply_search(query, nil), do: query
  defp apply_search(query, ""), do: query

  defp apply_search(query, q) when is_binary(q) do
    pattern = "%" <> GtfsPlanner.Gtfs.escape_like_pattern(q) <> "%"
    where(query, [s], ilike(s.stop_name, ^pattern) or ilike(s.stop_id, ^pattern))
  end

  defp restrict_to_ids(query, nil), do: query
  defp restrict_to_ids(query, []), do: where(query, [s], false)
  defp restrict_to_ids(query, ids), do: where(query, [s], s.id in ^ids)

  defp unlocated_stops(organization_id, gtfs_version_id, filter) do
    organization_id
    |> boardable_query(gtfs_version_id)
    |> apply_filter(filter)
    |> where([s], is_nil(s.stop_lat) or is_nil(s.stop_lon))
  end

  defp count_stops(query), do: Repo.aggregate(query, :count)

  defp clamp_page(page, total_count, per_page) do
    last_page = max(div(total_count + per_page - 1, per_page), 1)
    page |> max(1) |> min(last_page)
  end

  defp list_rows(organization_id, gtfs_version_id) do
    from(r in FareRule,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      select: %{
        id: r.id,
        fare_id: r.fare_id,
        route_id: r.route_id,
        origin_id: r.origin_id,
        destination_id: r.destination_id,
        contains_id: r.contains_id
      }
    )
    |> Repo.all()
  end

  defp group_key(row) do
    {row.fare_id, row.route_id, row.origin_id, row.destination_id, not is_nil(row.contains_id)}
  end

  defp build_group(
         {fare_id, route_id, origin_id, destination_id, _contains?} = key,
         rows,
         fares,
         routes
       ) do
    fare = Map.get(fares, fare_id)
    route = route_id && Map.get(routes, route_id)

    %{
      key: key,
      fare_id: fare_id,
      route_id: route_id,
      origin_id: origin_id,
      destination_id: destination_id,
      contains:
        rows
        |> Enum.map(& &1.contains_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort(),
      rows: Enum.sort_by(rows, & &1.id),
      fare: fare,
      route: route,
      unknown_fare?: is_nil(fare),
      unknown_route?: not is_nil(route_id) and is_nil(route)
    }
  end

  defp fare_index(_organization_id, _gtfs_version_id, []), do: %{}

  defp fare_index(organization_id, gtfs_version_id, fare_ids) do
    from(a in FareAttribute,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          a.fare_id in ^Enum.uniq(fare_ids),
      select: {a.fare_id, a.price, a.currency_type}
    )
    |> Repo.all()
    |> Map.new(fn {fare_id, price, currency_type} ->
      {fare_id, %{price: price, currency_type: currency_type}}
    end)
  end

  defp route_index(organization_id, gtfs_version_id, route_ids) do
    route_ids = route_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if route_ids == [] do
      %{}
    else
      from(r in Route,
        where:
          r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
            r.route_id in ^route_ids,
        select: {r.route_id, r.route_short_name, r.route_long_name}
      )
      |> Repo.all()
      |> Map.new(fn {route_id, short_name, long_name} ->
        {route_id, %{short_name: short_name, long_name: long_name}}
      end)
    end
  end

  defp sort_key(group) do
    {group.fare_id, group.origin_id, group.destination_id, group.route_id, elem(group.key, 4)}
  end

  defp stop_zone_counts(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          not is_nil(s.zone_id),
      group_by: s.zone_id,
      select: {
        s.zone_id,
        filter(count(s.id), s.location_type == 0),
        filter(count(s.id), s.location_type != 0)
      }
    )
    |> Repo.all()
    |> Map.new(fn {zone_id, stop_count, other_stop_count} ->
      {zone_id, {stop_count, other_stop_count}}
    end)
  end

  defp boardable_counts(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.location_type == 0,
      select: {count(s.id), filter(count(s.id), is_nil(s.zone_id))}
    )
    |> Repo.one()
  end

  defp declared_zones(organization_id, gtfs_version_id) do
    from(z in FareZone,
      where: z.organization_id == ^organization_id and z.gtfs_version_id == ^gtfs_version_id,
      select: {z.zone_id, %{name: z.name, color: z.color}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp rule_zone_counts(organization_id, gtfs_version_id) do
    organization_id
    |> list_rule_groups(gtfs_version_id)
    |> Enum.reduce(%{}, fn group, counts ->
      group
      |> referenced_zone_ids()
      |> Enum.reduce(counts, fn zone_id, counts -> Map.update(counts, zone_id, 1, &(&1 + 1)) end)
    end)
  end

  defp referenced_zone_ids(group) do
    [group.origin_id, group.destination_id | group.contains]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_zone(zone_id, declared, stop_counts, rule_counts) do
    record = Map.get(declared, zone_id)
    {stop_count, other_stop_count} = Map.get(stop_counts, zone_id, {0, 0})

    %{
      zone_id: zone_id,
      name: if(record, do: record.name, else: zone_id),
      color: if(record, do: record.color, else: FareZone.default_color(zone_id)),
      declared?: not is_nil(record),
      stop_count: stop_count,
      other_stop_count: other_stop_count,
      rule_count: Map.get(rule_counts, zone_id, 0)
    }
  end
end
