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

  `Fares.Conversion` is the first of this package's writers: it builds a
  version's first managed fare set from the four answers of the first-use setup,
  and converts imported fares in later steps. `save_prices/2` is the writer the
  price grid calls, and `Fares.Transfers` follows.

  `preview_price_change/3` and `apply_price_change/3` are the Change prices
  dialog's pair (AC-15). The preview raises no prices and shows the rows a
  chosen scope, amount or percentage, rounding and half-fare rule would change;
  the apply writes exactly those rows through the same fenced path
  `save_prices/2` uses, with each row's `now` as the amount it reviewed.

  ## How a write is fenced

  Every writer in this module runs through the private `write/4` helper, so
  they all share one shape (R15, INV-1):

  - `Fares.VersionLock.transact/3` holds the organization's published version
    row `FOR UPDATE`, so writers of one version's fares serialize and a pair
    that is not a published version of that organization answers
    `{:error, :not_found}` with nothing written;
  - the version must be managed — there is a `fare_version_settings` row — and
    answers `{:error, :unmanaged}` otherwise, because the editor edits fares
    through the managed form and an unmanaged version still exports its
    imported files;
  - the writer's own function re-checks the values the editor reviewed and
    answers `{:error, {:stale, cells}}` when any differ, writing nothing;
  - `Fares.Normalize.run!/2` runs before the transaction commits;
  - one `fare_version` change-log entry is recorded, carrying the shared
    operation id, the summary the editor's history shows and the rows before
    and after;
  - `{:ok, %{operation_id, inverse}}` is returned, and `undo/3` applies that
    inverse while every row still holds what the write left.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Normalize
  alias GtfsPlanner.Gtfs.Fares.VersionLock
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

  # The key a price write's inverse is named under, which is what `undo/3`
  # matches on to tell a price change from a setup or a conversion.
  @price_inverse :prices

  @undo_price_summary "Restored the prices a price change replaced"

  @typedoc """
  The arguments every writer of this package takes: the organization and version
  whose fare rows the write touches, and the audit identity its change-log entry
  is recorded for (R15).
  """
  @type scope :: %{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          audit: AuditContext.t()
        }

  @typedoc """
  What a write answers: the shared operation id naming its change-log entry, and
  the inverse `undo/3` applies. A refusal answers `{:error, reason}` and has
  written nothing.
  """
  @type write_result ::
          {:ok, %{operation_id: Ecto.UUID.t(), inverse: term()}}
          | {:error, {:stale, [map()]} | Ecto.Changeset.t() | atom()}

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
  Applies the inverse of a write while the rows it created are still the
  version's own (R15).

  A `setup/2` inverse is applied by `Fares.Conversion.undo_setup/3`, which deletes
  the rows that setup wrote while the version's settings row still names this
  operation. A `Conversion.apply/3` inverse is applied the same way by
  `Fares.Conversion.undo_conversion/3`, so undoing a conversion returns the
  version to unmanaged with its imported `fare_attributes` and `fare_rules` rows
  untouched. A `save_prices/2` inverse is applied by `undo_prices/3`, which
  restores each row only while it still holds the amount that write left.
  An inverse no writer of this package produces yet is refused with
  `{:error, :unknown_inverse}` rather than guessed at.
  """
  @spec undo(scope(), Ecto.UUID.t(), term()) :: write_result()
  def undo(scope, operation_id, %{setup: _inverse} = inverse) do
    Conversion.undo_setup(scope, operation_id, inverse)
  end

  def undo(scope, operation_id, %{conversion: _inverse} = inverse) do
    Conversion.undo_conversion(scope, operation_id, inverse)
  end

  def undo(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{
          prices: _inverse
        } = inverse
      ) do
    write(scope, @undo_price_summary, @price_inverse, fn setting ->
      undo_prices(organization_id, gtfs_version_id, operation_id, setting, inverse)
    end)
  end

  def undo(_scope, _operation_id, _inverse), do: {:error, :unknown_inverse}

  @doc """
  Stores the prices an editor reviewed and changed, and returns the inverse
  `undo/3` applies (AC-14, R9, R15).

  `cells` are the price grid's changed cells, one map each:

      %{fare_product_id: String.t(),
        rider_category_id: String.t(),
        fare_media_id: String.t() | nil,
        reviewed: Decimal.t() | nil,
        amount: Decimal.t() | String.t() | nil}

  A cell names one `fare_products` row by the three values that key it, beside
  the amount the editor reviewed and the amount they typed. An `amount` of
  `nil`, or of a string `Money.parse/1` reads as blank, deletes the row: blank
  means not sold, which is a missing row rather than a zero (R9). A `nil`
  `fare_media_id` is the row that names no method, which GTFS reads as one
  price payable any way — the grid submits a method, so this is what an imported
  row carries.

  A cell with no stored row and an amount creates it, naming the fare and
  currency of the product's other rows. A cell whose `fare_product_id` names no
  product of this version answers `{:error, :not_found}`, so another
  organization's or version's product is never written through this writer.

  Amounts are rounded to the version's currency minor units (R9). A negative
  amount and an unreadable one answer `{:error, :invalid_price}`: only the
  transfer-fee writer may store a negative price, and a mistyped cell must never
  be read as a deletion.

  `reviewed` is the fence. When a stored row holds an amount other than the one
  the editor reviewed — or a row the editor saw is gone — nothing is written and
  the answer is `{:error, {:stale, cells}}` naming each offending cell with the
  amount stored now. A version that is not managed answers
  `{:error, :unmanaged}`, and a pair that is not a published version of that
  organization answers `{:error, :not_found}`.
  """
  @spec save_prices(scope(), [map()]) :: write_result()
  def save_prices(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        cells
      )
      when is_list(cells) do
    write(scope, "Changed #{pluralize(length(cells), "price", "prices")}", @price_inverse, fn
      _setting -> apply_prices(organization_id, gtfs_version_id, cells)
    end)
  end

  @doc """
  The price changes a Change prices dialog is showing, computed and not written
  (AC-15).

  `options` is the dialog's own state:

      %{scope: :single | :pass | :all,
        riders: [String.t()],
        how: :amount | :percent,
        value: Decimal.t() | String.t() | number,
        round: Decimal.t() | String.t() | number,
        half_reduced?: boolean}

  `scope` names the fares: `:single` and `:pass` are the products the editor
  recorded as one ride or as a bundle, and `:all` is every fare a rider reads.
  A transfer fee is none of those — R6 reads its amount out of the transfer
  rules, and R9 reserves a negative amount for the transfer-fee writer — so no
  scope changes one. `riders` are the rider categories to change, `how` moves
  each price by `value` (an amount of dollars, which may be negative to lower
  prices, or a percentage) and `round` is the step the new price is rounded to.

  Each row is one `fare_products` row that would change:

      %{fare_product_id: String.t(),
        rider_category_id: String.t(),
        fare_media_id: String.t() | nil,
        now: Decimal.t(),
        new: Decimal.t()}

  A price that is absent, free or already equal to the new one is not in the
  answer: a fare a rider is not sold on, a child who rides free, and a price the
  chosen rule would not move are all left alone. With `half_reduced?` the
  `reduced` rider's new price is half the new adult price of the same fare and
  payment method, rounded the same way — a fare whose adult price the dialog
  cannot see (no adult row at all) falls back to the ordinary rule for that row.

  Everything here is read through the version pair (INV-5), so no row of
  another organization or another version can be previewed. An amount that
  would fall below zero is raised to zero rather than refused, because a lower
  price is a thing an operator asks for.
  """
  @spec preview_price_change(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: [map()]
  def preview_price_change(organization_id, gtfs_version_id, options)
      when is_binary(organization_id) and is_binary(gtfs_version_id) and is_map(options) do
    products = version_products(organization_id, gtfs_version_id)
    change = price_change(products, organization_id, gtfs_version_id, options)

    products
    |> price_change_products(change)
    |> Enum.flat_map(&price_change_row(&1, products, change))
    |> Enum.sort_by(&{&1.fare_product_id, &1.rider_category_id, &1.fare_media_id || ""})
  end

  @doc """
  Writes exactly the rows a `preview_price_change/3` showed, through the same
  fenced path `save_prices/2` takes (AC-15).

  `rows` are the preview's own rows, and each row's `now` is the amount this
  write reviewed: a row somebody else has changed since the preview refuses the
  whole change with `{:error, {:stale, cells}}` and writes nothing, exactly as
  `save_prices/2` does. One change-log entry is recorded with the summary
  `"Changed N prices with Change prices"`, so the history says where the change
  came from, and the inverse is the price inverse `undo/3` already applies.

  The options are the dialog's state the rows were previewed from, kept so the
  dialog can hold them in one form; the rows are what is written, so a caller
  that hands over rows of its own has written what it named.
  """
  @spec apply_price_change(scope(), map(), [map()]) :: write_result()
  def apply_price_change(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        _options,
        rows
      )
      when is_list(rows) do
    summary =
      "Changed #{pluralize(length(rows), "price", "prices")} with Change prices"

    write(scope, summary, @price_inverse, fn _setting ->
      apply_prices(organization_id, gtfs_version_id, Enum.map(rows, &price_change_cell/1))
    end)
  end

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

  # -- Writers -------------------------------------------------------------------

  # The one write path every writer in this module takes (R15, INV-1).
  #
  # The version lock opens the transaction and validates the scope pair, so a
  # pair that is not a published version of that organization never reaches
  # `fun` and answers `{:error, :not_found}`. The version must be managed, which
  # is checked before `fun` runs rather than by the caller, so no writer of this
  # module can forget it. `fun` answers `{:ok, result}` with
  #
  #     %{before: rows, after: rows, inverse: term(),
  #       operation_id: uuid, entry_id: uuid, action: String.t(),
  #       rolled_back_to_log_id: uuid}
  #
  # where all four trailing fields are optional. A write reports the id of the
  # entry it records, which is the id `undo/3` finds that entry by, so the two
  # name each other by construction. An undo reports the operation it reverses
  # and gives its own entry an id of its own, since a reversal is a second entry
  # pointing at the first through `rolled_back_to_log_id`.
  #
  # `Normalize.run!/2` runs inside this transaction before it commits, so a
  # version is never left with rules this package has not normalized (INV-1),
  # and the one `fare_version` change-log entry is written here rather than by
  # each writer, so every operation is recorded the same way (AC-26).
  defp write(
         %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
         summary,
         inverse_key,
         fun
       ) do
    VersionLock.transact(organization_id, gtfs_version_id, fn ->
      with {:ok, setting} <- managed_setting(organization_id, gtfs_version_id),
           {:ok, result} <- fun.(setting) do
        :ok = Normalize.run!(organization_id, gtfs_version_id)
        entry_id = Map.get(result, :entry_id) || Ecto.UUID.generate()
        operation_id = Map.get(result, :operation_id) || entry_id
        record_entry(scope, setting, summary, result, entry_id, operation_id)

        %{operation_id: operation_id, inverse: wrap_inverse(inverse_key, result.inverse)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The one `fare_version` change-log entry of an operation (R15). The entry
  # addresses the version's Fares section rather than a GTFS natural key: an
  # external id of `"fares"`, no snapshot, and the rows the write read and wrote
  # beside the shared operation id and the summary the editor's history shows.
  defp record_entry(scope, setting, summary, result, entry_id, operation_id) do
    attrs = %{
      entity_type: "fare_version",
      entity_id: setting.id,
      entity_external_id: "fares",
      actor_id: scope.audit.actor_id,
      actor_email: scope.audit.actor_email,
      action: Map.get(result, :action, "updated"),
      rolled_back_to_log_id: Map.get(result, :rolled_back_to_log_id),
      changed_fields: %{
        "operation_id" => operation_id,
        "summary" => summary,
        "before" => result.before,
        "after" => result.after
      },
      organization_id: setting.organization_id,
      gtfs_version_id: setting.gtfs_version_id
    }

    %ChangeLog{id: entry_id}
    |> ChangeLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, %ChangeLog{}} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # The row that makes the version managed, or `:unmanaged`. A fare edit goes
  # through the managed form; an unmanaged version still exports the files its
  # import wrote, so its prices are edited by importing again or by converting
  # it (R12).
  defp managed_setting(organization_id, gtfs_version_id) do
    case settings(organization_id, gtfs_version_id) do
      %FareVersionSetting{} = setting -> {:ok, setting}
      nil -> {:error, :unmanaged}
    end
  end

  # An undo has no inverse of its own to apply a second time, so it reports the
  # nil inverse a caller cannot act on rather than a key holding nothing.
  defp wrap_inverse(_inverse_key, nil), do: nil
  defp wrap_inverse(inverse_key, inverse), do: %{inverse_key => inverse}

  # -- Changing many prices at once ----------------------------------------------

  # The rider the half-fare rule follows. R10's setup, the prototype's dialog and
  # R9's grid all name the reduced rider by this id, so a bulk change is not the
  # only place that knows it.
  @reduced_rider_id "reduced"

  # The fare kinds a bulk price change may touch. A transfer fee is excluded: R6
  # reads its amount out of the transfer rules, and R9 reserves a negative amount
  # for the transfer-fee writer, so raising it here would price a rule rather
  # than a ride.
  @changeable_kinds ["single", "pass"]

  # The step a dialog that names no rounding rounds to: a cent, which leaves the
  # price in the currency's own minor units and is what "Don't round" means (R9).
  @no_rounding Decimal.new("0.01")

  # The dialog's state, read once so every row is priced by the same rule: the
  # rider types it changes, whether it moves by an amount or a percentage, that
  # amount, the step it rounds to, whether the reduced rider stays at half, and
  # the currency the new amounts are stored in (R9).
  defp price_change(products, organization_id, gtfs_version_id, options) do
    %{
      scope: options[:scope] || :all,
      riders: MapSet.new(List.wrap(options[:riders])),
      percent?: options[:how] == :percent,
      value: change_number(options[:value], Decimal.new(0)),
      step: change_number(options[:round], @no_rounding),
      half_reduced?: options[:half_reduced?] == true,
      adult: default_rider_id(organization_id, gtfs_version_id),
      currency: currency(products),
      details: detail_index(organization_id, gtfs_version_id)
    }
  end

  # The version's one default rider type, which is whose price a fare's other
  # rider types are read against (R8). A version with no default has no adult
  # row to move, so no row is treated as one.
  defp default_rider_id(organization_id, gtfs_version_id) do
    RiderCategory
    |> scoped(organization_id, gtfs_version_id)
    |> where([rider], rider.is_default_fare_category == 1)
    |> select([rider], rider.rider_category_id)
    |> Repo.one()
  end

  # The dialog types a number the way an operator reads it, so `$`, a comma and a
  # leading or trailing space are stripped and a minus sign is kept — lowering a
  # price is a thing the dialog offers. Anything that is not a number at all
  # moves nothing, so a half-typed field previews no change rather than raising
  # while the operator is still typing.
  defp change_number(value, default)
  defp change_number(%Decimal{} = value, _default), do: value
  defp change_number(value, _default) when is_integer(value), do: Decimal.new(value)

  defp change_number(value, _default) when is_float(value) do
    value |> Float.round(6) |> Decimal.from_float()
  end

  defp change_number(value, default) when is_binary(value) do
    value
    |> String.replace(~r/[$,\s]/, "")
    |> Decimal.parse()
    |> case do
      {number, ""} -> number
      _other -> default
    end
  end

  defp change_number(_value, default), do: default

  # The rows the scope and the chosen rider types leave in play: a stored price
  # of a fare in scope, sold to a rider type the dialog changes. A fare is a kind
  # the editor recorded, so the scope reads `fare_product_details` the same way
  # the grid's own read model does.
  defp price_change_products(products, change) do
    details = change.details

    products
    |> Enum.group_by(& &1.fare_product_id)
    |> Enum.flat_map(fn {product_id, rows} ->
      product_kind = kind(Map.get(details, product_id), rows)

      if changeable_kind?(product_kind, change.scope) do
        Enum.filter(rows, &changeable_row?(&1, change))
      else
        []
      end
    end)
  end

  defp changeable_kind?(product_kind, :all), do: product_kind in @changeable_kinds
  defp changeable_kind?("single", :single), do: true
  defp changeable_kind?("pass", :pass), do: true
  defp changeable_kind?(_product_kind, _scope), do: false

  # A rider a fare is not sold on holds no row at all, and a free price stays
  # free (R9), so neither is in the answer.
  defp changeable_row?(product, change) do
    MapSet.member?(change.riders, product.rider_category_id) and
      not is_nil(product.amount) and
      not Decimal.equal?(product.amount, 0)
  end

  # One row of the preview, or none when the chosen rule leaves the price where
  # it is: a dialog that lists a row nobody's price changes is showing work that
  # is not there.
  defp price_change_row(product, products, change) do
    new = changed_amount(product, products, change)

    if Decimal.equal?(new, product.amount) do
      []
    else
      [
        %{
          fare_product_id: product.fare_product_id,
          rider_category_id: product.rider_category_id,
          fare_media_id: product.fare_media_id,
          now: product.amount,
          new: new
        }
      ]
    end
  end

  # The default rider's price moves by the chosen rule, the reduced rider's moves
  # with it when the dialog was asked to keep it at half, and every other rider
  # moves by the rule on its own stored price — which is what the dialog says
  # about app prices: the same rule, whatever the method.
  defp changed_amount(product, products, change) do
    cond do
      product.rider_category_id == change.adult ->
        moved_amount(product.amount, change)

      change.half_reduced? and product.rider_category_id == @reduced_rider_id ->
        case adult_new_amount(product, products, change) do
          nil -> moved_amount(product.amount, change)
          adult_new -> rounded(half(adult_new), change)
        end

      true ->
        moved_amount(product.amount, change)
    end
  end

  # The new price of the adult row this reduced row follows: the same fare sold
  # to the default rider on the same payment method, falling back to the fare's
  # method-less row, which GTFS reads as one price payable any way. A fare with
  # no adult price at all has nothing to be half of, and answers `nil` so the
  # caller moves this row by the ordinary rule instead.
  defp adult_new_amount(product, products, change) do
    adult_rows =
      Enum.filter(products, fn row ->
        row.fare_product_id == product.fare_product_id and
          row.rider_category_id == change.adult and not is_nil(row.amount)
      end)

    Enum.find_value(adult_rows, fn row ->
      if row.fare_media_id == product.fare_media_id or is_nil(row.fare_media_id) do
        moved_amount(row.amount, change)
      end
    end)
  end

  # A percentage moves the price by that share of itself, an amount by that many
  # dollars. Either way the result is rounded to the step the dialog chose and
  # stored in the currency's minor units (R9).
  defp moved_amount(amount, change) do
    moved =
      if change.percent? do
        Decimal.mult(amount, Decimal.add(1, Decimal.div(change.value, 100)))
      else
        Decimal.add(amount, change.value)
      end

    rounded(moved, change)
  end

  defp rounded(amount, change) do
    amount
    |> rounded_to_step(change)
    |> then(&Decimal.max(&1, Decimal.new(0)))
    |> Decimal.round(Money.minor_units(change.currency))
  end

  defp rounded_to_step(amount, %{step: step}) do
    amount
    |> Decimal.div(step)
    |> Decimal.round(0)
    |> Decimal.mult(step)
  end

  defp half(amount), do: Decimal.div(amount, Decimal.new(2))

  # The cell `apply_prices/3` writes, carrying the previewed `now` as the amount
  # this write reviewed — which is what makes a row somebody else has changed
  # since the preview refuse the whole change.
  defp price_change_cell(row) do
    %{
      fare_product_id: row[:fare_product_id],
      rider_category_id: row[:rider_category_id],
      fare_media_id: row[:fare_media_id],
      reviewed: row[:now],
      amount: row[:new]
    }
  end

  # -- Prices --------------------------------------------------------------------

  # Every cell is checked before anything is written, so one stale cell refuses
  # the whole save rather than half of it. A cell with no amount at all is a
  # save of nothing, which is refused rather than recorded as an operation.
  defp apply_prices(_organization_id, _gtfs_version_id, []) do
    {:error, :no_prices}
  end

  defp apply_prices(organization_id, gtfs_version_id, cells) do
    products = version_products(organization_id, gtfs_version_id)
    code = currency(products)

    with {:ok, changes} <- price_changes(cells, products, code) do
      case stale_cells(changes, products) do
        [] -> write_prices(organization_id, gtfs_version_id, changes, products)
        stale -> {:error, {:stale, stale}}
      end
    end
  end

  defp version_products(organization_id, gtfs_version_id) do
    FareProduct
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
  end

  # Each cell becomes a `%{key, reviewed, amount}` change, or the whole save is
  # refused. `amount` is the parsed, rounded price, or `nil` for a blank cell.
  defp price_changes(cells, products, code) do
    Enum.reduce_while(cells, {:ok, []}, fn cell, {:ok, changes} ->
      case price_change(cell, products, code) do
        {:ok, change} -> {:cont, {:ok, [change | changes]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, changes} -> {:ok, Enum.reverse(changes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp price_change(cell, products, code) do
    key = cell_key(cell)

    with {:ok, product} <- fetch_product(products, key),
         {:ok, amount} <- parse_amount(cell, code) do
      {:ok,
       %{
         key: key,
         reviewed: cell[:reviewed],
         amount: amount,
         name: product.fare_product_name,
         currency: product.currency || code
       }}
    end
  end

  # The product the cell names, which is any row of this version carrying that
  # `fare_product_id`. A cell naming no product of this version answers
  # `{:error, :not_found}` — that is what another organization's or version's
  # product id is here (AC-26, INV-5).
  defp fetch_product(products, {product_id, _rider_id, _media_id}) do
    case Enum.find(products, &(&1.fare_product_id == product_id)) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  defp cell_key(cell) do
    {cell[:fare_product_id], cell[:rider_category_id], cell[:fare_media_id]}
  end

  # A price arrives as the `Decimal` a preview computed or as the string an
  # operator typed, and `Fares.Money.parse/1` is the one place either is read
  # (R9). A blank cell parses to `nil`, which deletes the row rather than
  # storing a zero, and an unreadable cell is refused rather than treated as
  # blank — a mistyped cell must never delete a price. A negative amount is
  # refused too: a `fare_products` row may hold one, but only the transfer-fee
  # writer stores one (R9).
  defp parse_amount(cell, code) do
    cell[:amount]
    |> money_amount()
    |> case do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, amount} ->
        if Decimal.negative?(amount) do
          {:error, :invalid_price}
        else
          {:ok, Decimal.round(amount, Money.minor_units(code))}
        end

      {:error, :invalid} ->
        {:error, :invalid_price}
    end
  end

  # A price reaches this writer either as the string an operator typed, which
  # `Fares.Money.parse/1` reads, or as the `Decimal` a preview computed for this
  # package's own writers — `preview_price_change/3` hands its rows straight to
  # `apply_price_change/3` — which is already a price and needs only the
  # currency's minor units below. A `Decimal` is never read from a person, so
  # `Money.parse/1` is not asked to parse one.
  defp money_amount(%Decimal{} = amount), do: {:ok, amount}
  defp money_amount(amount), do: Money.parse(amount)

  # The fence: every cell's stored row must still hold the amount the editor
  # reviewed, and a cell that reviewed no row must still have none. The answer
  # names each offending cell and the amount stored now, which is what the grid
  # reloads from.
  defp stale_cells(changes, products) do
    Enum.flat_map(changes, fn change -> stale_cell(change, products) end)
  end

  defp stale_cell(change, products) do
    case stored_amount(products, change.key) do
      {:ok, stored} ->
        if same_amount?(stored, change.reviewed), do: [], else: [named_stale_cell(change, stored)]

      :missing ->
        if is_nil(change.reviewed), do: [], else: [named_stale_cell(change, nil)]
    end
  end

  defp stored_amount(products, key) do
    case Enum.find(products, &(product_key(&1) == key)) do
      nil -> :missing
      product -> {:ok, product.amount}
    end
  end

  # `numeric` columns keep no scale, so a stored zero reads back as `0` and not
  # as `0.00`; `Decimal.equal?/2` compares the amount rather than the scale
  # Postgres happened to keep.
  defp same_amount?(nil, nil), do: true
  defp same_amount?(_stored, nil), do: false
  defp same_amount?(nil, _reviewed), do: false
  defp same_amount?(stored, %Decimal{} = reviewed), do: Decimal.equal?(stored, reviewed)

  defp named_stale_cell(change, stored) do
    {product_id, rider_id, media_id} = change.key

    %{
      fare_product_id: product_id,
      rider_category_id: rider_id,
      fare_media_id: media_id,
      reviewed: change.reviewed,
      stored: stored
    }
  end

  # Writes the cells and returns the change-log rows beside the inverse
  # `undo/3` applies. A cell whose stored amount already equals the new one is
  # left alone and names nothing in either set, so an editor who saved without
  # changing anything records one entry with empty before and after.
  defp write_prices(organization_id, gtfs_version_id, changes, products) do
    {inverse, before_rows, after_rows} =
      Enum.reduce(changes, {[], [], []}, fn change, {inverse, before_rows, after_rows} ->
        case write_price(organization_id, gtfs_version_id, change, products) do
          :unchanged ->
            {inverse, before_rows, after_rows}

          {state, before_row, after_row} ->
            {[state | inverse], [before_row | before_rows], [after_row | after_rows]}
        end
      end)

    {:ok,
     %{
       before: Enum.reverse(before_rows),
       after: Enum.reverse(after_rows),
       inverse: %{fare_products: Enum.reverse(inverse)}
     }}
  end

  defp write_price(organization_id, gtfs_version_id, change, products) do
    case Enum.find(products, &(product_key(&1) == change.key)) do
      nil -> insert_price(organization_id, gtfs_version_id, change)
      product -> update_price(organization_id, gtfs_version_id, product, change)
    end
  end

  # A blank cell for a row the fare was never sold on: there is nothing to
  # delete, so nothing is written and the inverse names nothing.
  defp insert_price(_organization_id, _gtfs_version_id, %{amount: nil}), do: :unchanged

  # A new price for a rider type or a payment method the fare is not sold on.
  # The row names the product it extends, so one fare keeps one name and one
  # currency across every rider and method.
  defp insert_price(organization_id, gtfs_version_id, change) do
    {product_id, rider_id, media_id} = change.key

    %FareProduct{}
    |> Map.merge(%{organization_id: organization_id, gtfs_version_id: gtfs_version_id})
    |> FareProduct.changeset(%{
      fare_product_id: product_id,
      fare_product_name: change.name,
      fare_media_id: media_id,
      rider_category_id: rider_id,
      amount: change.amount,
      currency: change.currency
    })
    |> Repo.insert()
    |> case do
      {:ok, product} ->
        {%{key: change.key, id: product.id, before: nil, after: change.amount},
         log_row(change.key, nil), log_row(change.key, change.amount)}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp update_price(_organization_id, _gtfs_version_id, %FareProduct{amount: nil}, %{amount: nil}) do
    :unchanged
  end

  # A blank cell deletes the row: blank means not sold, which is a missing row
  # rather than a zero (R9). The whole row goes into the inverse, so undo puts
  # back the row the import or an earlier write created rather than one rebuilt
  # from the cell alone.
  defp update_price(organization_id, gtfs_version_id, product, %{amount: nil}) do
    delete_price(organization_id, gtfs_version_id, product)

    key = product_key(product)

    {%{key: key, id: product.id, before: product.amount, after: nil, row: product},
     log_row(key, product.amount), log_row(key, nil)}
  end

  defp update_price(_organization_id, _gtfs_version_id, product, change) do
    if same_amount?(product.amount, change.amount) do
      :unchanged
    else
      change_price(product, change.amount)
      key = product_key(product)

      {%{key: key, id: product.id, before: product.amount, after: change.amount},
       log_row(key, product.amount), log_row(key, change.amount)}
    end
  end

  defp delete_price(organization_id, gtfs_version_id, product) do
    Repo.delete_all(
      from(row in FareProduct,
        where:
          row.id == ^product.id and row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id
      )
    )
  end

  # The row is changed through its own changeset rather than with `update_all`,
  # so the amount passes the same `validate_required/1` every other write of
  # this table does. The row was read through the scoped query inside the version
  # lock, so it is this version's own row (INV-5).
  defp change_price(product, amount) do
    product
    |> Ecto.Changeset.change(%{amount: amount})
    |> Repo.update!()
  end

  # The rows a change-log entry records, with the amounts as strings: a
  # `Decimal` is not a JSON value, and an amount in the history is a thing to
  # read rather than to compute with. A cell with no amount names a deleted row.
  defp log_row({product_id, rider_id, media_id}, amount) do
    %{
      "fare_product_id" => product_id,
      "rider_category_id" => rider_id,
      "fare_media_id" => media_id,
      "amount" => amount_text(amount)
    }
  end

  defp amount_text(nil), do: nil
  defp amount_text(amount), do: Decimal.to_string(amount)

  defp product_key(product) do
    {product.fare_product_id, product.rider_category_id, product.fare_media_id}
  end

  # -- Undoing a price change -----------------------------------------------------

  # Applies a `save_prices/2` inverse, restoring every row it named.
  #
  # The entry this reversal names has to exist in this version, and every row
  # the write touched must still hold the value that write left: a row it
  # created must still be there, a row it changed must still hold the new
  # amount, and a row it deleted must still be gone. Anything else answers
  # `{:error, :stale}` and changes nothing, so undo can never revert a later
  # edit (R15, AC-26).
  defp undo_prices(organization_id, gtfs_version_id, operation_id, _setting, %{
         prices: %{fare_products: states}
       })
       when is_list(states) do
    with :ok <- require_entry(operation_id, organization_id, gtfs_version_id),
         :ok <- require_unchanged(organization_id, gtfs_version_id, states) do
      restore_prices(organization_id, gtfs_version_id, states)

      {:ok,
       %{
         before: Enum.map(states, &log_row(&1.key, &1.after)),
         after: Enum.map(states, &log_row(&1.key, &1.before)),
         inverse: nil,
         operation_id: operation_id,
         action: "rolled_back",
         rolled_back_to_log_id: operation_id
       }}
    end
  end

  # An inverse held in the editor's socket that names no rows is not one this
  # writer produced, so it is stale rather than a reversal of nothing.
  defp undo_prices(_organization_id, _gtfs_version_id, _operation_id, _setting, _inverse) do
    {:error, :stale}
  end

  # The entry this reversal names is the undo target, so an operation id this
  # version never recorded — a random UUID, or another organization's entry — is
  # stale rather than a reversal of something.
  defp require_entry(operation_id, organization_id, gtfs_version_id) do
    found =
      ChangeLog
      |> where(
        [log],
        log.id == ^operation_id and log.organization_id == ^organization_id and
          log.gtfs_version_id == ^gtfs_version_id and log.entity_type == "fare_version"
      )
      |> Repo.exists?()

    if found, do: :ok, else: {:error, :stale}
  end

  defp require_unchanged(organization_id, gtfs_version_id, states) do
    stale? =
      Enum.any?(states, fn state ->
        row = fetch_price(organization_id, gtfs_version_id, state.id)

        case {state.after, row} do
          {nil, nil} -> false
          {nil, _row} -> true
          {_amount, nil} -> true
          {amount, row} -> not same_amount?(row.amount, amount)
        end
      end)

    if stale?, do: {:error, :stale}, else: :ok
  end

  # A row the write created is deleted, a row it changed goes back to the amount
  # it held, and a row it deleted is put back whole — with the id it had, so a
  # `fare_leg_rules` row naming its `fare_product_id` finds the same row it
  # named before the price save.
  defp restore_prices(organization_id, gtfs_version_id, states) do
    Enum.each(states, fn state ->
      case state do
        # A row the write deleted goes back whole, with the id it had, so a
        # `fare_leg_rules` row naming its `fare_product_id` finds the same row it
        # named before the price save.
        %{row: row} when not is_nil(row) ->
          Repo.insert!(Ecto.Changeset.change(row))

        # A row the write created goes away again.
        %{before: nil} ->
          delete_price_by_id(organization_id, gtfs_version_id, state.id)

        # A row the write changed goes back to the amount it held.
        state ->
          restore_price(organization_id, gtfs_version_id, state)
      end
    end)
  end

  defp restore_price(organization_id, gtfs_version_id, state) do
    case fetch_price(organization_id, gtfs_version_id, state.id) do
      nil ->
        :ok

      row ->
        row
        |> Ecto.Changeset.change(%{amount: state.before})
        |> Repo.update!()

        :ok
    end
  end

  defp delete_price_by_id(organization_id, gtfs_version_id, id) do
    Repo.delete_all(
      from(row in FareProduct,
        where:
          row.id == ^id and row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id
      )
    )
  end

  defp fetch_price(organization_id, gtfs_version_id, id) do
    FareProduct
    |> where(
      [row],
      row.id == ^id and row.organization_id == ^organization_id and
        row.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(number, _singular, plural), do: "#{number} #{plural}"
end
