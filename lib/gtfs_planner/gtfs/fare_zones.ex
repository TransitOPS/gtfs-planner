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
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Route
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

  @type assignment_change :: %{id: Ecto.UUID.t(), from: String.t() | nil, to: String.t() | nil}

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
end
