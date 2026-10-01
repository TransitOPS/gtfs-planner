defmodule GtfsPlanner.Gtfs.Fares.Projection do
  @moduledoc """
  The older GTFS fare files, worked out from a managed version's own rows (R11).

  The editor holds one fare model: a fare is priced for several rider types and
  payment methods, is sold on route networks, may change by time of day and may be
  a pass. `fare_attributes.txt` and `fare_rules.txt` are the pair an app that
  reads only the older format shows, and that pair can carry one price per fare
  for every rider type, one transfer allowance per fare, and no passes at all.
  `v1_rows/2` derives the rows it can from the rows
  `GtfsPlanner.Gtfs.Fares.Interpreter.load_rows/2` loaded, and where the older
  format cannot say something it carries the dearer answer, which is what the
  GTFS Best Practices ask for.

  Every row is a plain map keyed by the file specs' own field names, so
  `GtfsPlanner.Gtfs.Export.CsvWriter.write_row/4` writes one without a schema
  and a derived row can stand in for a stored one in
  `Interpreter.price_journey_v1/2` — which is how both prices of one journey come
  from one snapshot.

  ## What is derived

  `fare_attributes` holds one row per fare a leg rule charges, priced at the
  default rider type's amount on a cash medium, and `fare_rules` one row per cell
  `{network, from area, to area}` such a fare charges. A rule names areas and a
  route group; the older format names zones and routes, so the zone pairs and
  route lists a rule needs are worked out here from the version's stops' fare
  zones and its `route_networks`/`routes.network_id` rows.

  ## What is not

  Passes, the other rider types' prices, the app-only prices, the transfers
  between route groups and the prices that change by time of day have no older
  format row. `GtfsPlanner.Gtfs.Fares.Checks.run/2` is what tells an operator
  that; the projection never says so itself.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @attributes_file "fare_attributes.txt"
  @rules_file "fare_rules.txt"

  # R3's cash medium, the only price the older format can state per fare, and R5's
  # free transfer, the only transfer policy one allowance per fare can describe.
  @cash_media_type 0
  @free_transfer 0

  @pass_kind "pass"
  @single_kind "single"

  # A `transfer_count` of `-1`, or none at all, spans every change, which the older
  # `transfers` column states as a blank; a counted one is capped at 2, the
  # largest value that column allows.
  @unlimited_count -1
  @max_transfers 2

  @doc """
  The `fare_attributes.txt` and `fare_rules.txt` rows this version derives.

      v1_rows(organization_id, gtfs_version_id)
      #=> %{
      #=>   "fare_attributes.txt" => [%{fare_id: "local_ride", price: #Decimal<1.50>, ...}],
      #=>   "fare_rules.txt" => [%{fare_id: "local_ride", route_id: nil, ...}]
      #=> }

  The keys are the filenames the rows belong to and each row carries that file
  spec's own field names, which is what `CsvWriter.write_row/4` reads.

  A stored `fare_rules` row naming a `contains_id` is appended unchanged when the
  fare it names is one of the derived fares, because a journey crossing the zone
  such a row names cannot be priced by any row derived here. A stored
  `contains_id` row for a fare this version no longer holds is left out, as the
  whole of a stored `fare_rules` row is.
  """
  @spec v1_rows(Ecto.UUID.t(), Ecto.UUID.t()) :: %{String.t() => [map()]}
  def v1_rows(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    rows = Interpreter.load_rows(organization_id, gtfs_version_id)

    version = %{
      rows: rows,
      rules_by_product: Enum.group_by(rows.fare_leg_rules, & &1.fare_product_id),
      stops: route_stops(organization_id, gtfs_version_id),
      media: media_order(rows),
      rider_id: default_rider_id(rows),
      agencies: agency_ids(organization_id, gtfs_version_id),
      route_agencies: route_agencies(organization_id, gtfs_version_id),
      network_routes: network_routes(rows)
    }

    fares = fares(version)
    attributes = fares |> Enum.map(&attribute(&1, version)) |> Enum.sort_by(& &1.fare_id)
    derived = MapSet.new(attributes, & &1.fare_id)

    %{
      @attributes_file => attributes,
      @rules_file => rule_rows(fares, version) ++ contains_rows(rows, derived)
    }
  end

  # -- The fares a row is derived from ----------------------------------------------

  # A fare is the `fare_products` rows sharing a name, which is the identity the
  # editor's own writers use and the one an older `fare_attributes` row is.
  #
  # R11 gives a row to the single-ride fares a leg rule charges, so a fare no rule
  # charges is left out, and a pass is left out because it has no older-format row:
  # its leg rules stand in for other fares rather than charge a ride. "Charges" is
  # read as "is the fare some ride of this version is charged", so the products are
  # the ones `Interpreter.leg_products/5` names for the version's own networks and
  # fare areas.
  defp fares(version) do
    charged = charged_products(version)

    version.rows.fare_products
    |> Enum.group_by(&fare_key/1)
    |> Enum.map(&fare(&1, version, charged))
    |> Enum.filter(&(&1.kind != @pass_kind and &1.rules != []))
    |> Enum.sort_by(& &1.fare_id)
  end

  defp fare({_name, products}, version, charged) do
    fare_id = slug(fare_name(products))

    rules =
      products
      |> Enum.flat_map(&Map.get(version.rules_by_product, &1.fare_product_id, []))
      |> Enum.filter(&MapSet.member?(charged, &1.fare_product_id))
      |> Enum.map(&cell(&1, fare_id))

    %{
      fare_id: fare_id,
      products: products,
      kind: kind(version.rows, products),
      groups: rules |> Enum.map(& &1.leg_group_id) |> Enum.uniq(),
      rules: rules
    }
  end

  # One cell is one rule's conditions with the fare that charges it. The leg group
  # is kept for R11's free same-group transfer policy, not for the rule itself,
  # which the older format addresses by zones and routes.
  defp cell(rule, fare_id) do
    %{
      network_id: presence(rule.network_id),
      from_area_id: presence(rule.from_area_id),
      to_area_id: presence(rule.to_area_id),
      leg_group_id: presence(rule.leg_group_id),
      fare_id: fare_id
    }
  end

  defp fare_key(%{fare_product_name: name, fare_product_id: id}), do: presence(name) || id

  defp fare_name(products) do
    case presence(hd(products).fare_product_name) do
      nil -> hd(products).fare_product_id
      name -> name
    end
  end

  # The product's own kind where the editor recorded one, which is where a pass
  # and a transfer fee are held, and R12's reading otherwise: a product that
  # bundles or dates rides is not a single ride.
  defp kind(rows, products) do
    details = Map.new(rows.fare_product_details, &{presence(&1.fare_product_id), &1.kind})

    products
    |> Enum.map(&Map.get(details, &1.fare_product_id))
    |> Enum.find(&(is_binary(&1) and &1 != ""))
    |> case do
      nil -> inferred_kind(products)
      kind -> kind
    end
  end

  defp inferred_kind(products) do
    if Enum.any?(products, &(not is_nil(&1.bundle_amount) or not is_nil(&1.duration_amount))),
      do: @pass_kind,
      else: @single_kind
  end

  # The products a leg rule charges. A leg is in one of the version's networks and
  # runs between two of the version's fare areas, and every timeframe group counts
  # as active: which of them is running is a question about a date and a time, and
  # a fare a rule prices at some hour of some day is charged. The combinations are
  # the version's own rather than the stops its routes happen to serve, because a
  # fare no route serves today is still the fare a feed states for those areas.
  defp charged_products(%{rows: rows}) do
    timeframe_ids = rows.timeframes |> Enum.map(& &1.timeframe_group_id) |> Enum.uniq()
    version_areas = areas(rows)

    for network_id <- networks(rows),
        from_area_id <- version_areas,
        to_area_id <- version_areas,
        reduce: MapSet.new() do
      charged ->
        rows
        |> Interpreter.leg_products(network_id, from_area_id, to_area_id, timeframe_ids)
        |> Enum.reduce(charged, &MapSet.put(&2, &1))
    end
  end

  defp networks(rows) do
    rows.networks
    |> Enum.map(& &1.network_id)
    |> Enum.concat(Map.values(rows.route_networks) ++ Map.values(rows.route_network_ids))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp areas(rows) do
    rows.stop_zones
    |> Map.values()
    |> Enum.concat(Enum.flat_map(rows.fare_leg_rules, &[&1.from_area_id, &1.to_area_id]))
    |> Enum.map(&presence/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # -- `fare_attributes.txt` ----------------------------------------------------------

  defp attribute(fare, version) do
    {transfers, transfer_duration} = allowance(version.rows, fare.groups)

    %{
      fare_id: fare.fare_id,
      price: price(fare, version),
      currency_type: currency(fare.products),
      payment_method: payment_method(fare.products, version.media),
      transfers: transfers,
      agency_id: agency_id(fare, version),
      transfer_duration: transfer_duration
    }
  end

  # The default rider type's amount on a cash medium, else the row that names no
  # medium at all, else the fare's first medium in the version's own order. A fare
  # the default rider type is not sold at still needs the one price the older
  # format carries, so its own first stored amount stands in.
  defp price(fare, version) do
    sold = fare.products |> Enum.map(& &1.fare_media_id) |> Enum.uniq()
    cash = Enum.find(cash_media(version.media), &(&1 in sold))
    first = Enum.find(Enum.map(version.media, &elem(&1, 0)), &(&1 in sold))

    case Enum.find_value([cash, nil, first], &rider_amount(fare, version, &1)) do
      nil -> fare.products |> Enum.reject(&is_nil(&1.amount)) |> List.first() |> field(:amount)
      amount -> amount
    end
  end

  defp rider_amount(fare, version, media_id) do
    fare.products
    |> Enum.find(&(&1.rider_category_id == version.rider_id and &1.fare_media_id == media_id))
    |> field(:amount)
  end

  defp field(nil, _field), do: nil
  defp field(product, field), do: Map.fetch!(product, field)

  defp currency(products) do
    products |> Enum.find(&(not is_nil(&1.currency))) |> field(:currency)
  end

  # R11: 0 when the fare accepts a cash medium or names no medium at all, because
  # either way the older format can say the price is paid on board.
  defp payment_method(products, media) do
    cash = cash_media(media)
    sold = products |> Enum.map(& &1.fare_media_id) |> Enum.uniq()

    if Enum.all?(sold, &is_nil/1) or Enum.any?(sold, &(&1 in cash)), do: 0, else: 1
  end

  # R11's transfer allowance is the fare's route group's own free policy, and a
  # group with no such policy leaves the fare with no free transfer at all: the
  # older format has one allowance per fare and nowhere to say "only between the
  # routes of this group".
  defp allowance(rows, groups) do
    policies = Enum.map(groups, &free_policy(rows, &1))

    if policies == [] or Enum.any?(policies, &is_nil/1) do
      {0, nil}
    else
      {transfers(Enum.map(policies, & &1.transfer_count)), duration(policies)}
    end
  end

  defp free_policy(rows, group) do
    rows.fare_transfer_rules
    |> Enum.filter(
      &(&1.fare_transfer_type == @free_transfer and presence(&1.from_leg_group_id) == group and
          presence(&1.to_leg_group_id) == group)
    )
    # A bounded count is read before an open one: a fare that allows two changes
    # inside one group allows them wherever that fare is used.
    |> Enum.sort_by(&{count_rank(&1.transfer_count), &1.transfer_count || 0, &1.id})
    |> List.first()
  end

  defp count_rank(nil), do: 1
  defp count_rank(@unlimited_count), do: 1
  defp count_rank(_count), do: 0

  defp transfers(counts) do
    if Enum.any?(counts, &(is_nil(&1) or &1 == @unlimited_count)),
      do: nil,
      else: counts |> Enum.min() |> min(@max_transfers)
  end

  defp duration(policies) do
    case policies |> Enum.map(& &1.duration_limit) |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] -> nil
      [limit | _rest] -> limit
    end
  end

  # R11: the only agency's id, or — when the version has several — the agency every
  # route of the fare's own groups runs, and blank when they share none, which is
  # what `Fares.Checks.run/2` reports.
  defp agency_id(fare, version) do
    case version.agencies do
      [agency_id] ->
        agency_id

      _several ->
        fare.groups
        |> Enum.flat_map(&Map.get(version.network_routes, &1, []))
        |> Enum.map(&Map.get(version.route_agencies, &1))
        |> Enum.uniq()
        |> case do
          [agency_id] when is_binary(agency_id) -> agency_id
          _not_shared -> nil
        end
    end
  end

  # -- `fare_rules.txt` ---------------------------------------------------------------

  # One row per cell `{network, from area, to area}` a single-ride fare charges.
  # Several time periods pricing one cell is one cell the older format holds once,
  # and it is held at the dearer of them.
  defp rule_rows(fares, version) do
    prices = Map.new(fares, &{&1.fare_id, price(&1, version)})

    fares
    |> Enum.flat_map(& &1.rules)
    |> Enum.group_by(&{&1.network_id, &1.from_area_id, &1.to_area_id})
    |> Enum.sort_by(fn {cell, _rules} -> cell end)
    |> Enum.flat_map(fn {cell, rules} ->
      priced = Enum.map(rules, &{&1.fare_id, Map.fetch!(prices, &1.fare_id)})

      cell_rows(cell, fare_id(priced), version)
    end)
  end

  # R11: `route_id` is blank for a cell in no network. For a network it is blank
  # too unless a route outside that network serves stops in both zones — a rule
  # with no route matches every route, so one that would price an outside route is
  # narrowed to the routes of its own network instead. A cell in no zones at all
  # names every stop, and is narrowed the same way.
  defp cell_rows({network_id, from_area_id, to_area_id}, fare_id, version) do
    if network_id != nil and clash?(network_id, from_area_id, to_area_id, version) do
      network_id
      |> own_routes(version)
      |> Enum.map(&rule(fare_id, &1, from_area_id, to_area_id))
    else
      [rule(fare_id, nil, from_area_id, to_area_id)]
    end
  end

  defp clash?(network_id, from_area_id, to_area_id, version) do
    inside = own_routes(network_id, version)

    version.stops
    |> Map.keys()
    |> Enum.reject(&(&1 in inside))
    |> Enum.any?(&serves_pair?(&1, from_area_id, to_area_id, version.stops))
  end

  defp own_routes(network_id, version), do: Map.get(version.network_routes, network_id, [])

  # Whether a route offers the pair: a stop in the origin area and a different stop
  # in the destination area. An area the pair leaves open is any area, and two ends
  # of a ride are two stops, so a route serving one stop of an area cannot offer
  # that area to itself.
  defp serves_pair?(route_id, from_area_id, to_area_id, stops) do
    served = Map.get(stops, route_id, [])

    Enum.any?(served, fn {stop_id, zone_id} ->
      in_area?(zone_id, from_area_id) and
        Enum.any?(served, fn {other_id, other_zone} ->
          other_id != stop_id and in_area?(other_zone, to_area_id)
        end)
    end)
  end

  # An area the pair leaves open is any area.
  defp in_area?(_zone_id, nil), do: true
  defp in_area?(zone_id, area_id), do: zone_id == area_id

  defp rule(fare_id, route_id, from_area_id, to_area_id) do
    %{
      fare_id: fare_id,
      route_id: route_id,
      origin_id: from_area_id,
      destination_id: to_area_id,
      contains_id: nil
    }
  end

  # The fare of the highest-priced product charging the cell, which is one row
  # because the older format holds a cell once. A tie keeps the fare that comes
  # first by id, so the same version always answers the same way.
  defp fare_id(priced) do
    priced
    |> Enum.uniq_by(fn {fare_id, _price} -> fare_id end)
    |> Enum.sort(&dearer?/2)
    |> hd()
    |> elem(0)
  end

  defp dearer?({left_id, left}, {right_id, right}) do
    case compare_price(left, right) do
      :gt -> true
      :lt -> false
      :eq -> left_id <= right_id
    end
  end

  # A fare with no amount at all is dearer than nothing, so it loses the cell.
  defp compare_price(nil, nil), do: :eq
  defp compare_price(nil, _amount), do: :lt
  defp compare_price(_amount, nil), do: :gt
  defp compare_price(left, right), do: Decimal.compare(left, right)

  defp contains_rows(rows, derived) do
    rows.fare_rules
    |> Enum.filter(
      &(not is_nil(presence(&1.contains_id)) and
          MapSet.member?(derived, presence(&1.fare_id)))
    )
    |> Enum.sort_by(& &1.id)
    |> Enum.map(
      &%{
        fare_id: presence(&1.fare_id),
        route_id: presence(&1.route_id),
        origin_id: presence(&1.origin_id),
        destination_id: presence(&1.destination_id),
        contains_id: presence(&1.contains_id)
      }
    )
  end

  # -- The version's own rows -----------------------------------------------------------

  # Every stop each route serves, with that stop's fare zone. A leg is a pair of
  # these, and `fare_rules` addresses the routes' zones.
  defp route_stops(organization_id, gtfs_version_id) do
    Trip
    |> join(:inner, [trip], st in StopTime,
      on:
        st.trip_id == trip.trip_id and st.organization_id == ^organization_id and
          st.gtfs_version_id == ^gtfs_version_id
    )
    |> join(:inner, [trip, stop_time], stop in Stop,
      on:
        stop.stop_id == stop_time.stop_id and stop.organization_id == ^organization_id and
          stop.gtfs_version_id == ^gtfs_version_id
    )
    |> where(
      [trip],
      trip.organization_id == ^organization_id and trip.gtfs_version_id == ^gtfs_version_id
    )
    |> select([trip, _stop_time, stop], {trip.route_id, stop.stop_id, stop.zone_id})
    |> Repo.all()
    |> Enum.map(fn {route_id, stop_id, zone_id} -> {route_id, stop_id, presence(zone_id)} end)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), fn {_route_id, stop_id, zone_id} -> {stop_id, zone_id} end)
  end

  defp agency_ids(organization_id, gtfs_version_id) do
    Agency
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Enum.map(&presence(&1.agency_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp route_agencies(organization_id, gtfs_version_id) do
    Route
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Map.new(&{&1.route_id, presence(&1.agency_id)})
  end

  # `route_networks.txt` answers when the version has it, because a route belongs to
  # at most one network; otherwise `routes.network_id` does.
  defp network_routes(rows) do
    rows.route_networks
    |> Map.merge(rows.route_network_ids)
    |> Enum.group_by(
      fn {_route_id, network_id} -> network_id end,
      fn {route_id, _network_id} -> route_id end
    )
    |> Map.new(fn {network_id, route_ids} ->
      {network_id, route_ids |> Enum.uniq() |> Enum.sort()}
    end)
  end

  # The version's own payment methods in the order the editor's own grid reads them
  # (lowest `fare_media_type`, then id).
  defp media_order(rows) do
    rows.fare_media
    |> Enum.sort_by(&{&1.fare_media_type || 0, &1.fare_media_id})
    |> Enum.map(&{&1.fare_media_id, &1.fare_media_type})
  end

  defp cash_media(media) do
    media
    |> Enum.filter(&(elem(&1, 1) == @cash_media_type))
    |> Enum.map(&elem(&1, 0))
  end

  defp default_rider_id(rows) do
    case Enum.find(rows.rider_categories, & &1.is_default_fare_category) do
      nil -> nil
      rider -> rider.rider_category_id
    end
  end

  # A fare's older-format id is its name the way `Fares.save_fare/2` writes one:
  # lower case, with every run of other characters one underscore.
  defp slug(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
  end

  defp presence(nil), do: nil
  defp presence(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp presence(value), do: value

  defp scoped(queryable, organization_id, gtfs_version_id) do
    from(row in queryable,
      where:
        row.organization_id == ^organization_id and
          row.gtfs_version_id == ^gtfs_version_id
    )
  end
end
