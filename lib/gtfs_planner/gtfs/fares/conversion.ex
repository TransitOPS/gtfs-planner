defmodule GtfsPlanner.Gtfs.Fares.Conversion do
  @moduledoc """
  First-use setup for a version that holds no fare rows at all.

  A version with no `fare_products`, `fare_attributes`, `fare_leg_rules`,
  `fare_rules`, `fare_transfer_rules`, `networks`, `route_networks`,
  `rider_categories` or `fare_media` row is a version nobody has priced yet, and
  trip planners show no price for any ride on it. `setup/2` turns the four answers
  the editor collects into the smallest managed fare set that answers them
  (AC-10), so a new version becomes editable here rather than by importing a feed:

  - `free` — one `$0.00` single fare sold to the Adult rider type, with a leg rule
    naming no network. The prototype asks no further question for a free system,
    so the price, rider and transfer answers are not read;
  - `flat` — one "Local ride" single fare sold on no network, so one price covers
    every ride between any stops;
  - `route` — one fare and one network per group the answers name, every route of
    the version in the first group, and one leg rule per fare naming its own
    group's network;
  - `zone` — one "Local ride" fare and no zone rules yet, because the operator
    draws the zones on the map next.

  A reduced and a youth rider pay half the adult price rounded to `$0.05`, and a
  child pays nothing (AC-10). Every chosen rider type becomes a
  `rider_categories` row, with `adult` the single default (R8).

  ## What one setup writes

  One `rider_categories` row per chosen rider type, the `cash` `fare_media` row
  the prices are sold on, the `networks` and `route_networks` rows a `route`
  answer needs, one `fare_product_id` per fare carrying one `fare_products` row
  per rider type, one `fare_product_details` row per product recording the
  `single` kind the editor's grid reads, one `fare_leg_rules` row per product, at
  most one free `all_routes` transfer rule, the `fare_version_settings` row that
  marks the version managed, and one `change_logs` entry of entity type
  `fare_version`.

  The `cash` medium exists because the editor's grid reads a fare's prices through
  its first payment method: a product row with no `fare_media_id` means "any
  method" to a consumer, but the grid has no row to draw it on. The prototype's
  own help for the price answer calls it "the price someone pays with cash when
  they board".

  ## How the write is fenced

  The whole write is one `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3`
  transaction, so it serializes on the same published version row as every other
  writer of the version's fares, and a pair that is not a published version of the
  organization answers `{:error, :not_found}` without touching anything (R15).
  `GtfsPlanner.Gtfs.Fares.Normalize.run!/2` runs before the transaction commits
  (INV-1), which is what gives the leg rules their priority and leg group.

  A version that already holds any of those rows answers `{:error, :has_fares}`
  and writes nothing: it is an imported or already-managed version, and R12
  routes those through `preview/2` and `apply/3` instead, because a conversion
  compares prices where setup invents them.

  ## The inverse and undo

  The returned inverse names every row the write created, by table, beside the
  settings row. `GtfsPlanner.Gtfs.Fares.undo/3` applies it through
  `undo_setup/3`, which deletes those rows while the version's settings row still
  names this operation and answers `{:error, :stale}` otherwise — so an undo can
  never remove rows a later write depends on. Setup writes no implied row of its
  own beyond the leg-rule columns `Normalize` fills in, so the inverse covers the
  whole write.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Normalize
  alias GtfsPlanner.Gtfs.Fares.VersionLock
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Repo

  # The four structures the editor's first question offers.
  @structures [:free, :flat, :route, :zone]

  # The currency a stored price is written in. The editor reads the currency from
  # the version's own product rows and has no currency of its own, so a version
  # with no fare rows has none to read.
  @default_currency "USD"

  # The payment method setup sells on: the prototype's price answer is what
  # "someone pays with cash when they board", and the grid draws a fare's prices
  # under its first medium.
  @cash_media_id "cash"
  @cash_media_name "Cash"
  @cash_media_type 0

  # R3's name for the leg rules that name no network, `fare_transfer_type` 0's
  # "free transfer", and `duration_limit_type` 1's "measured from the first
  # boarding" — what "free transfers within N minutes of first boarding" means.
  @all_routes "all_routes"
  @free_transfer_type 0
  @duration_from_first_boarding 1

  # A reduced or youth price is half the adult price to the nearest nickel
  # (AC-10); the operator's own prices are rounded to the currency's minor units.
  @nickel Decimal.new("0.05")

  # The history entry `undo_setup/3` records for the reversal.
  @undo_summary "Removed the fares the first-use setup created"

  @doc """
  The structures `setup/2` builds, in the order the editor's choice cards list
  them.
  """
  @spec structures() :: [atom()]
  def structures, do: @structures

  @doc """
  Builds a managed fare set for a version that holds no fare rows at all.

  `answers` is what the four questions collected:

      %{kind: :free | :flat | :route | :zone,
        adult: Decimal.t() | String.t(),
        groups: [{name :: String.t(), Decimal.t() | String.t()}],
        reduced: boolean(), youth: boolean(), child: boolean(),
        transfer_minutes: pos_integer() | nil}

  A price may arrive as a `Decimal` or as the string an operator typed, which is
  read through `GtfsPlanner.Gtfs.Fares.Money.parse/1` (CR-3). A refused answer —
  an unknown structure, a missing or unreadable price, a blank or repeated group
  name, a transfer value that is not a positive whole number of minutes — answers
  `{:error, reason}` and writes nothing.

  Returns `{:ok, %{operation_id: uuid, inverse: %{setup: inverse}}}` on success
  (R15), `{:error, :has_fares}` when the version already holds any fare row, and
  `{:error, :not_found}` when the pair is not a published version of the
  organization.
  """
  @spec setup(Fares.scope(), map()) :: Fares.write_result()
  def setup(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        answers
      ) do
    VersionLock.transact(organization_id, gtfs_version_id, fn ->
      with :ok <- refuse_stored_fares(organization_id, gtfs_version_id),
           {:ok, plan} <- plan(answers) do
        write_setup(organization_id, gtfs_version_id, scope, plan)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Applies a `setup/2` inverse, deleting every row that write created.

  The version must still be the managed version this operation made: its settings
  row must exist and still name `operation_id` as its `conversion_operation_id`.
  Anything else answers `{:error, :stale}` and deletes nothing. A `rolled_back`
  change-log entry pointing at the entry the setup wrote records the reversal.
  """
  @spec undo_setup(Fares.scope(), Ecto.UUID.t(), map()) :: Fares.write_result()
  def undo_setup(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{setup: inverse}
      ) do
    VersionLock.transact(organization_id, gtfs_version_id, fn ->
      case undoable_setting(organization_id, gtfs_version_id, operation_id) do
        {:ok, setting, entry} ->
          delete_created(organization_id, gtfs_version_id, inverse)
          :ok = Normalize.run!(organization_id, gtfs_version_id)
          record_rollback(scope, setting, entry)
          %{operation_id: operation_id, inverse: nil}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # -- The answers, as a plan ---------------------------------------------------

  # A version that already stores fares is not this function's case: R12 sends an
  # imported version through the conversion's preview and apply, which compare
  # prices instead of writing new ones. Every table an import of any fare file
  # writes is checked, so a version holding only `rider_categories` is refused too.
  defp refuse_stored_fares(organization_id, gtfs_version_id) do
    rows = Interpreter.load_rows(organization_id, gtfs_version_id)

    stored? =
      Enum.any?(
        [
          rows.fare_products,
          rows.fare_attributes,
          rows.fare_leg_rules,
          rows.fare_rules,
          rows.fare_transfer_rules,
          rows.networks,
          rows.rider_categories,
          rows.fare_media
        ],
        &(&1 != [])
      ) or
        Enum.any?([rows.route_networks, rows.route_network_ids], &(map_size(&1) > 0))

    if stored?, do: {:error, :has_fares}, else: :ok
  end

  defp plan(answers) do
    with {:ok, kind} <- structure(answers),
         {:ok, fares} <- fares_for(kind, answers),
         {:ok, riders} <- riders_for(kind, answers),
         {:ok, transfer_minutes} <- transfer_minutes(kind, answers) do
      {:ok, %{kind: kind, fares: fares, riders: riders, transfer_minutes: transfer_minutes}}
    end
  end

  defp structure(answers) do
    case Map.get(answers, :kind) do
      kind when kind in @structures -> {:ok, kind}
      _other -> {:error, :unknown_structure}
    end
  end

  defp fares_for(:free, _answers) do
    {:ok, [fare("free_ride", "Free ride", nil, nil, Decimal.new(0))]}
  end

  # `flat` and `zone` build the same rows: one fare sold on no network, so one
  # price covers every ride between any stops. The zone structure's area rules
  # are drawn on the map afterwards, which is the only difference between them.
  defp fares_for(kind, answers) when kind in [:flat, :zone] do
    with {:ok, adult} <- price(Map.get(answers, :adult)) do
      {:ok, [fare("local_ride", "Local ride", nil, nil, adult)]}
    end
  end

  defp fares_for(:route, answers) do
    with {:ok, groups} <- groups(answers) do
      slugs = Enum.map(groups, & &1.slug)

      if Enum.uniq(slugs) == slugs do
        {:ok, Enum.map(groups, &route_fare/1)}
      else
        {:error, :duplicate_group}
      end
    end
  end

  defp fare(product_id, name, network_id, network_name, adult) do
    %{
      product_id: product_id,
      name: name,
      network_id: network_id,
      network_name: network_name,
      adult: adult
    }
  end

  # A group's network id and its fare product id are the group's name as a GTFS
  # id: lower case, with every run of other characters one underscore.
  defp route_fare(%{slug: slug, name: name, adult: adult}) do
    fare(slug <> "_ride", name <> " ride", slug, name, adult)
  end

  defp groups(answers) do
    groups =
      case Map.get(answers, :groups) do
        groups when is_list(groups) -> groups
        _other -> []
      end

    Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, acc} ->
      case route_group(group) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_groups}
      {:ok, groups} -> {:ok, Enum.reverse(groups)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route_group({name, price}) when is_binary(name) do
    trimmed = String.trim(name)

    with {:ok, slug} <- slug(trimmed),
         {:ok, adult} <- price(price) do
      {:ok, %{name: trimmed, slug: slug, adult: adult}}
    end
  end

  defp route_group(_group), do: {:error, :invalid_group}

  defp slug(""), do: {:error, :invalid_group}

  defp slug(name) do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_") do
      "" -> {:error, :invalid_group}
      slug -> {:ok, slug}
    end
  end

  defp riders_for(:free, _answers), do: {:ok, [rider("adult", "Adult", true)]}

  defp riders_for(_kind, answers) do
    riders =
      [
        {"adult", "Adult", true, true},
        {"reduced", "Reduced fare", false, Map.get(answers, :reduced) == true},
        {"youth", "Youth (6–18)", false, Map.get(answers, :youth) == true},
        {"child", "Children under 6", false, Map.get(answers, :child) == true}
      ]
      |> Enum.filter(fn {_id, _name, _default?, chosen?} -> chosen? end)

    {:ok, Enum.map(riders, fn {id, name, default?, _chosen?} -> rider(id, name, default?) end)}
  end

  defp rider(id, name, default?), do: %{id: id, name: name, default?: default?}

  defp transfer_minutes(:free, _answers), do: {:ok, nil}

  defp transfer_minutes(_kind, answers) do
    case Map.get(answers, :transfer_minutes) do
      nil -> {:ok, nil}
      minutes when is_integer(minutes) and minutes > 0 -> {:ok, minutes}
      _other -> {:error, :invalid_transfer_minutes}
    end
  end

  defp price(%Decimal{} = amount),
    do: {:ok, Decimal.round(amount, Money.minor_units(@default_currency))}

  defp price(value) when is_binary(value) do
    case Money.parse(value) do
      {:ok, nil} -> {:error, :invalid_price}
      {:ok, amount} -> {:ok, Decimal.round(amount, Money.minor_units(@default_currency))}
      {:error, :invalid} -> {:error, :invalid_price}
    end
  end

  defp price(_value), do: {:error, :invalid_price}

  # -- The write ----------------------------------------------------------------

  defp write_setup(organization_id, gtfs_version_id, scope, plan) do
    rider_rows = insert_rider_categories(organization_id, gtfs_version_id, plan.riders)
    media = insert_cash_medium(organization_id, gtfs_version_id)
    networks = insert_networks(organization_id, gtfs_version_id, plan.fares, plan.kind)
    route_networks = insert_route_networks(organization_id, gtfs_version_id, networks)
    products = insert_products(organization_id, gtfs_version_id, plan, rider_rows, media)
    details = insert_product_details(organization_id, gtfs_version_id, plan.fares)
    rules = insert_leg_rules(organization_id, gtfs_version_id, plan.fares)
    transfers = insert_transfer_rule(organization_id, gtfs_version_id, plan.transfer_minutes)

    :ok = Normalize.run!(organization_id, gtfs_version_id)

    inverse = %{
      rider_categories: Enum.map(rider_rows, & &1.id),
      fare_media: media.id,
      networks: Enum.map(networks, & &1.id),
      route_networks: Enum.map(route_networks, & &1.id),
      fare_products: Enum.map(products, & &1.id),
      fare_product_details: Enum.map(details, & &1.id),
      fare_leg_rules: Enum.map(rules, & &1.id),
      fare_transfer_rules: Enum.map(transfers, & &1.id)
    }

    operation = record_setup(scope, plan, inverse)
    setting = insert_settings(organization_id, gtfs_version_id, operation.id)

    %{operation_id: operation.id, inverse: %{setup: Map.put(inverse, :setting, setting.id)}}
  end

  defp insert_rider_categories(organization_id, gtfs_version_id, riders) do
    Enum.map(riders, fn rider ->
      %RiderCategory{}
      |> RiderCategory.changeset(%{
        rider_category_id: rider.id,
        rider_category_name: rider.name,
        is_default_fare_category: if(rider.default?, do: 1, else: 0),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end)
  end

  defp insert_cash_medium(organization_id, gtfs_version_id) do
    %FareMedia{}
    |> FareMedia.changeset(%{
      fare_media_id: @cash_media_id,
      fare_media_name: @cash_media_name,
      fare_media_type: @cash_media_type,
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    })
    |> Repo.insert!()
  end

  defp insert_networks(_organization_id, _gtfs_version_id, _fares, kind) when kind != :route,
    do: []

  defp insert_networks(organization_id, gtfs_version_id, fares, :route) do
    Enum.map(fares, fn fare ->
      %Network{}
      |> Network.changeset(%{
        network_id: fare.network_id,
        network_name: fare.network_name,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end)
  end

  # Every route of the version starts in the first group; the operator moves a
  # route to another group on the next screen.
  defp insert_route_networks(_organization_id, _gtfs_version_id, []), do: []

  defp insert_route_networks(
         organization_id,
         gtfs_version_id,
         [%Network{} = first | _rest]
       ) do
    organization_id
    |> version_route_ids(gtfs_version_id)
    |> Enum.map(fn route_id ->
      %RouteNetwork{}
      |> RouteNetwork.changeset(%{
        network_id: first.network_id,
        route_id: route_id,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end)
  end

  defp version_route_ids(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: r.route_id],
      select: r.route_id
    )
    |> Repo.all()
  end

  # One product per fare, one `fare_products` row per rider type, all carrying the
  # fare's own name so the editor's grid reads the rows as one fare.
  defp insert_products(organization_id, gtfs_version_id, plan, rider_rows, media) do
    for fare <- plan.fares, rider <- rider_rows do
      %FareProduct{}
      |> FareProduct.changeset(%{
        fare_product_id: fare.product_id,
        fare_product_name: fare.name,
        fare_media_id: media.fare_media_id,
        amount: amount(plan.kind, fare, rider),
        currency: @default_currency,
        rider_category_id: rider.rider_category_id,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end
  end

  # The operator facts the Fares v2 files have no place for: the product's kind
  # and its place in the editor's own order.
  defp insert_product_details(organization_id, gtfs_version_id, fares) do
    fares
    |> Enum.with_index()
    |> Enum.map(fn {fare, position} ->
      %FareProductDetail{}
      |> Map.merge(%{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> FareProductDetail.changeset(%{
        fare_product_id: fare.product_id,
        kind: "single",
        position: position
      })
      |> Repo.insert!()
    end)
  end

  # A free system charges nothing to anyone. Otherwise the adult answer is the
  # price, a reduced or youth rider pays half of it to the nearest nickel, and a
  # child rides free (AC-10).
  defp amount(:free, _fare, _rider), do: Decimal.new(0)

  defp amount(_kind, fare, rider) do
    case rider.rider_category_id do
      "child" -> Decimal.new(0)
      "adult" -> fare.adult
      _other -> half(fare.adult)
    end
  end

  defp half(amount) do
    amount
    |> Decimal.div(Decimal.new(2))
    |> Decimal.div(@nickel)
    |> Decimal.round(0)
    |> Decimal.mult(@nickel)
  end

  # One leg rule per product, naming no network unless the answer named one, and
  # no areas: the `zone` structure's area rules are drawn on the map afterwards.
  defp insert_leg_rules(organization_id, gtfs_version_id, fares) do
    Enum.map(fares, fn fare ->
      %FareLegRule{}
      |> FareLegRule.changeset(%{
        network_id: fare.network_id,
        fare_product_id: fare.product_id,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end)
  end

  # The transfer answer's one rule: free changes between any two rides, counted
  # from the first boarding and within the minutes the operator named. A
  # `transfer_count` of -1 is every change, which is what an unlimited free
  # transfer window means.
  defp insert_transfer_rule(_organization_id, _gtfs_version_id, nil), do: []

  defp insert_transfer_rule(organization_id, gtfs_version_id, minutes) do
    [
      %FareTransferRule{}
      |> FareTransferRule.changeset(%{
        from_leg_group_id: @all_routes,
        to_leg_group_id: @all_routes,
        transfer_count: -1,
        duration_limit: minutes * 60,
        duration_limit_type: @duration_from_first_boarding,
        fare_transfer_type: @free_transfer_type,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    ]
  end

  defp insert_settings(organization_id, gtfs_version_id, operation_id) do
    %FareVersionSetting{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      managed_at: DateTime.utc_now(),
      older_format: "derived",
      conversion_operation_id: operation_id
    }
    |> FareVersionSetting.changeset(%{})
    |> Repo.insert!()
  end

  # One `fare_version` entry (R15). The settings row's `conversion_operation_id`
  # names this entry, so the entry is written first and the settings row second.
  # The entry addresses the version's Fares section rather than a GTFS natural
  # key, which is how a fare operation is audited: an external id of `"fares"`,
  # no snapshot, and the rows the write touched beside the shared operation id and
  # the summary the editor's history shows.
  defp record_setup(%{audit: %AuditContext{} = audit}, plan, inverse) do
    operation_id = Ecto.UUID.generate()

    %ChangeLog{id: operation_id}
    |> ChangeLog.changeset(%{
      entity_type: "fare_version",
      entity_external_id: "fares",
      actor_id: audit.actor_id,
      actor_email: audit.actor_email,
      action: "created",
      changed_fields: %{
        "operation_id" => operation_id,
        "summary" => summary(plan),
        "before" => nil,
        "after" => rows_written(plan, inverse)
      },
      organization_id: audit.organization_id,
      gtfs_version_id: audit.gtfs_version_id
    })
    |> Repo.insert()
    |> case do
      {:ok, operation} -> operation
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp rows_written(plan, inverse) do
    %{
      "kind" => to_string(plan.kind),
      "rider_categories" => length(inverse.rider_categories),
      "fare_products" => length(inverse.fare_products),
      "fare_leg_rules" => length(inverse.fare_leg_rules),
      "fare_transfer_rules" => length(inverse.fare_transfer_rules),
      "networks" => length(inverse.networks)
    }
  end

  defp summary(plan) do
    "Set up #{count(length(plan.fares), "fare", "fares")} for " <>
      "#{count(length(plan.riders), "rider type", "rider types")}" <>
      case {plan.kind, plan.transfer_minutes} do
        {:route, _minutes} -> " from the route groups named"
        {:zone, nil} -> ", before zones are drawn"
        {:zone, minutes} -> ", with free transfers for #{minutes} minutes"
        {_kind, nil} -> ""
        {_kind, minutes} -> ", with free transfers for #{minutes} minutes"
      end
  end

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(number, _singular, plural), do: "#{number} #{plural}"

  # -- Undo ---------------------------------------------------------------------

  # The settings row's `conversion_operation_id` is the id of the change-log
  # entry this operation wrote, so the two name each other: the entry is the undo
  # target and the settings row is the fence.
  defp undoable_setting(organization_id, gtfs_version_id, operation_id) do
    with %FareVersionSetting{conversion_operation_id: ^operation_id} = setting <-
           Fares.settings(organization_id, gtfs_version_id),
         {:ok, entry} <- fetch_entry(operation_id, organization_id, gtfs_version_id) do
      {:ok, setting, entry}
    else
      _other -> {:error, :stale}
    end
  end

  defp fetch_entry(operation_id, organization_id, gtfs_version_id) do
    from(log in ChangeLog,
      where:
        log.id == ^operation_id and log.organization_id == ^organization_id and
          log.gtfs_version_id == ^gtfs_version_id and log.entity_type == "fare_version",
      select: {log.id, log.changed_fields}
    )
    |> Repo.one()
    |> case do
      {id, changed_fields} -> {:ok, %{id: id, changed_fields: changed_fields}}
      nil -> {:error, :stale}
    end
  end

  # The rows are deleted in the reverse of the order they were written, and the
  # settings row last: it is the row that makes the version managed.
  defp delete_created(organization_id, gtfs_version_id, inverse) do
    [
      {FareTransferRule, inverse.fare_transfer_rules},
      {FareLegRule, inverse.fare_leg_rules},
      {FareProductDetail, inverse.fare_product_details},
      {FareProduct, inverse.fare_products},
      {RouteNetwork, inverse.route_networks},
      {Network, inverse.networks},
      {RiderCategory, inverse.rider_categories},
      {FareMedia, [inverse.fare_media]},
      {FareVersionSetting, [inverse.setting]}
    ]
    |> Enum.each(fn {schema, ids} ->
      delete_rows(schema, ids, organization_id, gtfs_version_id)
    end)
  end

  defp delete_rows(_schema, [], _organization_id, _gtfs_version_id), do: :ok

  defp delete_rows(schema, ids, organization_id, gtfs_version_id) do
    Repo.delete_all(
      from(row in schema,
        where:
          row.id in ^ids and row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id
      )
    )

    :ok
  end

  # The `rolled_back` entry the audit trail reads as an undo of the setup's entry.
  defp record_rollback(%{audit: %AuditContext{} = audit}, setting, entry) do
    %ChangeLog{}
    |> ChangeLog.changeset(%{
      entity_type: "fare_version",
      entity_id: setting.id,
      entity_external_id: "fares",
      actor_id: audit.actor_id,
      actor_email: audit.actor_email,
      action: "rolled_back",
      rolled_back_to_log_id: entry.id,
      changed_fields: %{
        "operation_id" => setting.conversion_operation_id,
        "summary" => @undo_summary,
        "before" => entry.changed_fields["after"],
        "after" => nil
      },
      organization_id: setting.organization_id,
      gtfs_version_id: setting.gtfs_version_id
    })
    |> Repo.insert()
    |> case do
      {:ok, _log} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
