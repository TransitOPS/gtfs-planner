defmodule GtfsPlanner.Gtfs.Fares do
  @moduledoc """
  The facade over the fare tables a version's fares are edited in.

  A version is *managed* when a `fare_version_settings` row exists for it with
  `managed_at` set. `managed?/2` and `settings/2` are its read side: the export
  and the fare editors ask this module rather than querying the table, so the
  unscoped `get_*!` helpers in `GtfsPlanner.Gtfs` are never used for fare rows.
  Both functions filter by `organization_id` and `gtfs_version_id` together, so
  a version of another organization that carries a settings row is never managed
  (INV-5), and an unmanaged version exports its imported files unchanged.

  `load_workspace/2` is the fare editor's read side: the price grid, riders,
  payment methods, route groups, zone matrices, time periods, transfers, joins,
  the latest `fare_version` history and — for a version that is not managed — the
  stored-row summary, in one scoped snapshot, so no tab queries a fare table
  itself and no two tabs can disagree about what the version holds.

  The remaining writers of this package — `Fares.Conversion`,
  `Fares.Transfers` and `Fares.Normalize` — are added by later steps.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Workspace
  alias GtfsPlanner.Gtfs.FareTimePeriod
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Repo

  # The Recent changes list, and the Prices tab's history card, show the latest
  # three fare changes of a managed version.
  @history_limit 3

  @default_currency "USD"

  # The stored-row counts an unmanaged version's read-only view and its
  # conversion review both state, in the order the review lists them.
  @unmanaged_tables [
    {:fare_attributes, FareAttribute},
    {:fare_rules, FareRule},
    {:fare_products, FareProduct},
    {:fare_leg_rules, FareLegRule},
    {:fare_transfer_rules, FareTransferRule},
    {:fare_leg_join_rules, FareLegJoinRule},
    {:fare_media, FareMedia},
    {:rider_categories, RiderCategory},
    {:networks, Network},
    {:fare_time_periods, FareTimePeriod}
  ]

  @doc """
  Whether the version's fares are managed here.

  True exactly when a `fare_version_settings` row exists for this organization
  and version with `managed_at` set. A settings row of another organization or
  another version never answers for this pair.
  """
  @spec managed?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def managed?(organization_id, gtfs_version_id) do
    query =
      from(setting in FareVersionSetting,
        where:
          setting.organization_id == ^organization_id and
            setting.gtfs_version_id == ^gtfs_version_id and
            not is_nil(setting.managed_at)
      )

    Repo.exists?(query)
  end

  @doc """
  The version's settings row, or `nil` when the version is unmanaged.

  The row carries `older_format` — `"derived"` or `"imported"` — and the
  `conversion_operation_id` a conversion recorded, so undo can find it again.
  """
  @spec settings(Ecto.UUID.t(), Ecto.UUID.t()) :: FareVersionSetting.t() | nil
  def settings(organization_id, gtfs_version_id) do
    FareVersionSetting
    |> where(
      [setting],
      setting.organization_id == ^organization_id and
        setting.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  @doc """
  The fare editor's whole read model for one version.

  One snapshot of the version's fare rows, so the Prices, Where fares apply,
  Transfers and Checks tabs, the route-detail card and the journey check all
  describe the version the same way. Every read here is filtered by
  `organization_id` and `gtfs_version_id` together (INV-5), so another version's
  or another organization's rows are absent from the workspace rather than
  filtered out by the views.

  The fare rows themselves are read through `Fares.Interpreter.load_rows/2` —
  the one scoped fare-row loader this package has, so the editor reads exactly
  the rows a journey price reads — beside the `fare_time_periods`,
  `fare_leg_join_rules` and `fare_version` change-log rows that load does not
  carry. Nothing here writes and no writer is called.

  A lost database connection is the adapter's to report as
  `{:error, :unavailable}`; this function answers `{:ok, workspace}` for any
  scope it was given, and a malformed id or any other defect raises rather than
  being presented as downtime.
  """
  @spec load_workspace(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Workspace.t()}
  def load_workspace(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    {:ok, build_workspace(organization_id, gtfs_version_id)}
  end

  defp build_workspace(organization_id, gtfs_version_id) do
    rows = Interpreter.load_rows(organization_id, gtfs_version_id)
    setting = settings(organization_id, gtfs_version_id)
    details = detail_index(organization_id, gtfs_version_id)
    periods = time_period_rows(organization_id, gtfs_version_id)
    joins = join_rows(organization_id, gtfs_version_id)

    riders = build_riders(rows.rider_categories)
    media = build_media(rows.fare_media)
    groups = build_groups(rows)
    pass_ids = pass_product_ids(details)
    names = zone_names(organization_id, gtfs_version_id, rows)

    %Workspace{
      managed?: rows.managed?,
      older_format: setting && setting.older_format,
      currency: currency(rows.fare_products),
      fares: build_fares(rows.fare_products, details, media, riders),
      riders: riders,
      media: media,
      groups: groups,
      matrices: build_matrices(rows, groups, pass_ids, names),
      transfers: build_transfers(rows.fare_transfer_rules),
      time_periods: build_time_periods(periods, rows.timeframes),
      joins: joins,
      history: history_rows(organization_id, gtfs_version_id),
      unmanaged: unmanaged_summary(organization_id, gtfs_version_id, rows)
    }
  end

  # The version's own rider categories, the default first so the grid's "Shown
  # first" column leads, then the rest by id.
  defp build_riders(rider_categories) do
    rider_categories
    |> Enum.sort_by(&{if(&1.is_default_fare_category == 1, do: 0, else: 1), &1.rider_category_id})
    |> Enum.map(fn rider ->
      %{
        rider_category_id: rider.rider_category_id,
        name: rider.rider_category_name,
        default?: rider.is_default_fare_category == 1,
        min_age: rider.min_age,
        max_age: rider.max_age,
        eligibility_url: rider.eligibility_url
      }
    end)
  end

  # Payment methods in the order a rider reads them: the GTFS
  # `fare_media_type` first, so cash or no ticket (0) precedes an app (4).
  defp build_media(fare_media) do
    fare_media
    |> Enum.sort_by(&{&1.fare_media_type || 0, &1.fare_media_id})
    |> Enum.map(fn medium ->
      %{
        fare_media_id: medium.fare_media_id,
        name: medium.fare_media_name,
        fare_media_type: medium.fare_media_type
      }
    end)
  end

  # The currency is the version's own product currency, else USD: the spec
  # removed a currency of its own, and one grid is shown in one currency.
  defp currency(fare_products) do
    case fare_products do
      [%FareProduct{currency: currency} | _] when is_binary(currency) and currency != "" ->
        currency

      _other ->
        @default_currency
    end
  end

  # A fare is the group of `fare_products` rows that share a `fare_product_name`
  # — the identity the editor's writers use, since one fare is one name sold to
  # several riders and payment methods. `prices` are the amounts at the fare's
  # first payment method, and `media_prices` the per-medium amounts that differ
  # from it, which is exactly the sub-row the grid draws. A rider the fare is not
  # sold to holds `nil`, which reads as "not sold" rather than free.
  defp build_fares(fare_products, details, media, riders) do
    fare_products
    |> Enum.group_by(&fare_name/1)
    |> Enum.map(fn {name, products} -> build_fare(name, products, details, media, riders) end)
    |> Enum.sort_by(&{fare_order(&1.kind), &1.position, &1.name})
  end

  defp fare_name(%FareProduct{fare_product_name: name}) when is_binary(name) and name != "",
    do: name

  defp fare_name(%FareProduct{fare_product_id: id}), do: id

  defp build_fare(name, products, details, media, riders) do
    detail = products |> Enum.map(&Map.get(details, &1.fare_product_id)) |> Enum.find(& &1)
    sold = sold_media(products)
    base = base_medium(sold, media)
    by_medium = prices_by_medium(products, riders, base)
    prices = Map.get(by_medium, base, blank_prices(riders))

    %{
      name: name,
      kind: kind(detail, products),
      position: (detail && detail.position) || 0,
      product_ids: products |> Enum.map(& &1.fare_product_id) |> Enum.uniq() |> Enum.sort(),
      media: if(sold == [], do: List.wrap(base), else: sold),
      prices: prices,
      media_prices:
        by_medium
        |> Enum.reject(fn {medium, amounts} -> medium == base or amounts == prices end)
        |> Map.new(),
      accepted_network_ids: (detail && detail.accepted_network_ids) || []
    }
  end

  defp sold_media(products) do
    products
    |> Enum.map(& &1.fare_media_id)
    |> Enum.reject(&is_nil(&1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp base_medium([], media), do: first_media_id(media)

  defp base_medium(sold, media) do
    # The fare's first method in the version's own media order is the one whose
    # amounts the grid shows on the fare's own row.
    Enum.find(Enum.map(media, & &1.fare_media_id), &(&1 in sold)) || hd(sold)
  end

  defp first_media_id([%{fare_media_id: id} | _rest]), do: id
  defp first_media_id([]), do: nil

  defp blank_prices(riders) do
    Map.new(riders, &{&1.rider_category_id, nil})
  end

  # Each rider's amount per payment method, every rider present in every method
  # so a grid column never disappears because one method stopped selling it. A
  # row with no `fare_media_id` is the fare's base method, which is how GTFS
  # states "one price, any payment method".
  defp prices_by_medium(products, riders, base) do
    products
    |> Enum.reduce(%{}, fn product, acc ->
      medium = product.fare_media_id || base
      rider_id = product.rider_category_id

      if is_nil(medium) or is_nil(rider_id) do
        acc
      else
        amounts = Map.get(acc, medium, %{})
        Map.put(acc, medium, Map.put(amounts, rider_id, product.amount))
      end
    end)
    |> Map.new(fn {medium, amounts} ->
      {medium, Map.merge(blank_prices(riders), amounts)}
    end)
  end

  # A product the editor recorded is what it recorded. A product with no detail
  # row counts as a single ride (the step 11 reading), unless its own rows carry
  # a bundle amount or a duration, which is how an imported feed marks a pass.
  defp kind(nil, products), do: inferred_kind(products)

  defp kind(%FareProductDetail{kind: kind}, _products) when is_binary(kind) and kind != "",
    do: kind

  defp kind(%FareProductDetail{}, products), do: inferred_kind(products)

  defp inferred_kind(products) do
    bundled? =
      Enum.any?(
        products,
        &(not is_nil(&1.bundle_amount) or not is_nil(&1.duration_amount))
      )

    if bundled?, do: "pass", else: "single"
  end

  defp fare_order("single"), do: 0
  defp fare_order("transfer_fee"), do: 2
  defp fare_order(_other), do: 1

  # The products the editor recorded as passes. Their mirrored leg rules never
  # fill a matrix cell.
  defp pass_product_ids(details) do
    details
    |> Map.values()
    |> Enum.filter(&(&1.kind == "pass"))
    |> Enum.map(& &1.fare_product_id)
    |> MapSet.new()
  end

  defp detail_index(organization_id, gtfs_version_id) do
    FareProductDetail
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Map.new(&{&1.fare_product_id, &1})
  end

  defp scoped(queryable, organization_id, gtfs_version_id) do
    where(
      queryable,
      [row],
      row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id
    )
  end

  # The version's route groups with their routes, and whether a group is priced
  # by zone — which is what gives it a matrix. `route_networks` is the loader's
  # route-to-group map, so it is inverted here. A group is zone-priced when any of
  # its own rules names both a departure and an arrival area.
  defp build_groups(%{networks: networks, route_networks: route_networks} = rows) do
    routes_by_network =
      route_networks
      |> Enum.group_by(fn {_route_id, network_id} -> network_id end, fn {route_id, _} ->
        route_id
      end)

    networks
    |> Enum.map(fn network ->
      %{
        network_id: network.network_id,
        name: network.network_name,
        route_ids: routes_by_network |> Map.get(network.network_id, []) |> Enum.sort(),
        zone_priced?: zone_priced?(rows, network.network_id)
      }
    end)
    |> Enum.sort_by(& &1.network_id)
  end

  defp zone_priced?(rows, network_id) do
    Enum.any?(rows.fare_leg_rules, fn rule ->
      rule.network_id == network_id and not is_nil(rule.from_area_id) and
        not is_nil(rule.to_area_id)
    end)
  end

  # One matrix per zone-priced group, over the zones that group's own rules
  # price. Every ordered pair of zones is a cell, so a pair nobody priced is
  # present and flagged as a gap — that is what the Where tab's "No fare" cell
  # writes through. A pass rule never fills a cell: a pass is sold, not applied
  # to a single ride, so its mirrored leg rules are left out of every matrix.
  defp build_matrices(rows, groups, pass_ids, names) do
    for group <- Enum.filter(groups, & &1.zone_priced?),
        zones = group_zones(rows, group.network_id, pass_ids, names),
        zones != [] do
      cells =
        for zone_from <- zones, zone_to <- zones, into: %{} do
          {{zone_from.area_id, zone_to.area_id},
           %{
             products:
               cell_products(rows, group.network_id, zone_from.area_id, zone_to.area_id, pass_ids),
             gap?: false
           }}
        end

      %{
        network_id: group.network_id,
        zones: zones,
        cells:
          Map.new(cells, fn {{from_id, to_id}, cell} ->
            {{from_id, to_id}, Map.put(cell, :gap?, cell.products == [])}
          end)
      }
    end
  end

  defp group_zones(rows, network_id, pass_ids, names) do
    rows.fare_leg_rules
    |> Enum.filter(fn rule ->
      rule.network_id == network_id and not is_nil(rule.from_area_id) and
        not is_nil(rule.to_area_id) and rule.fare_product_id not in pass_ids
    end)
    |> Enum.flat_map(&[&1.from_area_id, &1.to_area_id])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{area_id: &1, name: Map.get(names, &1, &1)})
  end

  defp cell_products(rows, network_id, from_area_id, to_area_id, pass_ids) do
    rows.fare_leg_rules
    |> Enum.filter(fn rule ->
      rule.network_id == network_id and rule.from_area_id == from_area_id and
        rule.to_area_id == to_area_id and rule.fare_product_id not in pass_ids
    end)
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A managed version's areas are its fare zones, so a zone's name is its
  # `fare_zones` record; an undeclared zone is named by its exact id.
  defp zone_names(organization_id, gtfs_version_id, rows) do
    rows.fare_leg_rules
    |> Enum.flat_map(&[&1.from_area_id, &1.to_area_id])
    |> Enum.reject(&is_nil(&1))
    |> Enum.uniq()
    |> then(&FareZones.zone_names(organization_id, gtfs_version_id, &1))
  end

  # The from × to matrix of the version's leg groups: the groups its transfer
  # rules name and the version's networks, so a rule written against a group that
  # is no longer stored still has its cell. `pay` is the editor's own word for
  # `fare_transfer_type`: 0 is a free transfer, 1 charges the named product and
  # 2 pays the difference.
  defp build_transfers(fare_transfer_rules) do
    leg_groups =
      fare_transfer_rules
      |> Enum.flat_map(&[&1.from_leg_group_id, &1.to_leg_group_id])
      |> Enum.reject(&is_nil(&1))
      |> Enum.uniq()
      |> Enum.sort()

    for from <- leg_groups, to <- leg_groups do
      %{
        from_leg_group_id: from,
        to_leg_group_id: to,
        policy: transfer_policy(fare_transfer_rules, from, to)
      }
    end
  end

  # The rule that prices a group pair: a rule with no `transfer_count` covers
  # every change, so it is the fallback and a counted rule is preferred.
  defp transfer_policy(rules, from, to) do
    rules
    |> Enum.filter(&(&1.from_leg_group_id == from and &1.to_leg_group_id == to))
    |> Enum.sort_by(
      &{if(is_nil(&1.transfer_count), do: 1, else: 0), &1.transfer_count || 0, &1.id}
    )
    |> List.first()
    |> case do
      nil ->
        nil

      rule ->
        %{
          pay: pay(rule.fare_transfer_type),
          minutes: minutes(rule),
          count: rule.transfer_count,
          fee: fee(rule),
          fare_transfer_type: rule.fare_transfer_type,
          transfer_count: rule.transfer_count,
          duration_limit: rule.duration_limit,
          duration_limit_type: rule.duration_limit_type
        }
    end
  end

  defp pay(0), do: :free
  defp pay(1), do: :fee
  defp pay(2), do: :difference

  # `duration_limit_type` 1 measures from the first departure; the other types
  # measure from arrival or elsewhere, which this read model does not reduce to
  # minutes.
  defp minutes(%{duration_limit: nil}), do: nil
  defp minutes(%{duration_limit_type: 1, duration_limit: limit}), do: div(limit, 60)
  defp minutes(_rule), do: nil

  defp fee(%{fare_transfer_type: 1, fare_product_id: product_id}), do: product_id
  defp fee(_rule), do: nil

  # A fare time period with the `timeframes` ranges of its group, so the editor
  # draws one card per period carrying its ranges.
  defp build_time_periods(periods, timeframes) do
    periods
    |> Enum.map(fn period ->
      %{
        timeframe_group_id: period.timeframe_group_id,
        name: period.name,
        weekdays: period.weekdays,
        until_end_of_day: period.until_end_of_day,
        service_id: period.service_id,
        ranges:
          timeframes
          |> Enum.filter(&(&1.timeframe_group_id == period.timeframe_group_id))
          |> Enum.sort_by(&{&1.start_time || "", &1.end_time || ""})
          |> Enum.map(&%{start_time: &1.start_time, end_time: &1.end_time})
      }
    end)
    |> Enum.sort_by(&{&1.timeframe_group_id || ""})
  end

  defp time_period_rows(organization_id, gtfs_version_id) do
    FareTimePeriod
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
  end

  # Leg join rules are read-only here: this package never writes them, so the
  # Transfers tab lists them and offers no edit.
  defp join_rows(organization_id, gtfs_version_id) do
    FareLegJoinRule
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Enum.map(fn join ->
      %{
        from_network_id: join.from_network_id,
        to_network_id: join.to_network_id,
        from_stop_id: join.from_stop_id,
        to_stop_id: join.to_stop_id
      }
    end)
    |> Enum.sort_by(
      &{&1.from_network_id || "", &1.to_network_id || "", &1.from_stop_id || "",
       &1.to_stop_id || ""}
    )
  end

  # The latest `fare_version` entries, which the Recent changes destination and
  # the Prices tab's history card both read.
  defp history_rows(organization_id, gtfs_version_id) do
    ChangeLog
    |> where(
      [log],
      log.organization_id == ^organization_id and log.gtfs_version_id == ^gtfs_version_id and
        log.entity_type == "fare_version"
    )
    |> order_by([log], desc: log.inserted_at, desc: log.id)
    |> limit(@history_limit)
    |> Repo.all()
    |> Enum.map(fn log ->
      %{
        id: log.id,
        action: log.action,
        summary: log.changed_fields && log.changed_fields["summary"],
        actor_email: log.actor_email,
        inserted_at: log.inserted_at
      }
    end)
  end

  # An unmanaged version's stored rows, which the read-only Prices view and the
  # conversion review both state. A version with no fare rows at all is the
  # first-use setup rather than an unmanaged conversion, and carries no summary.
  defp unmanaged_summary(_organization_id, _gtfs_version_id, %{managed?: true}), do: nil

  defp unmanaged_summary(organization_id, gtfs_version_id, rows) do
    if rows.fare_attributes == [] and rows.fare_products == [] do
      nil
    else
      %{
        format: unmanaged_format(rows),
        counts:
          Map.new(@unmanaged_tables, fn {key, schema} ->
            {key, count(schema, organization_id, gtfs_version_id)}
          end),
        attributes:
          Enum.map(rows.fare_attributes, fn attribute ->
            %{
              fare_id: attribute.fare_id,
              price: attribute.price,
              currency: attribute.currency_type,
              transfers: attribute.transfers,
              transfer_duration: attribute.transfer_duration
            }
          end)
      }
    end
  end

  defp unmanaged_format(rows) do
    cond do
      rows.fare_products != [] -> :v2
      rows.fare_attributes != [] -> :v1
      true -> :none
    end
  end

  defp count(schema, organization_id, gtfs_version_id) do
    schema
    |> scoped(organization_id, gtfs_version_id)
    |> select([row], count())
    |> Repo.one()
  end
end
