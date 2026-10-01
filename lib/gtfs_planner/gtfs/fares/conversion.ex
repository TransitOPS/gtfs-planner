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

  ## Converting an imported older-format feed

  A version whose fares were imported as `fare_attributes.txt` and
  `fare_rules.txt` holds prices an agency already publishes, so converting it is
  not an edit the operator may make by hand. `preview/2` therefore answers what a
  conversion would write and what it could not reproduce, and `apply/3` writes it
  only while the stored rows are still the ones the editor reviewed (R12, R13):

  - one `rider_categories` row, the Adult default, because the older rows carry
    one price per fare and no rider dimension;
  - one `fare_products` row per `fare_attributes` row, named by its `fare_id`,
    sold on the `cash` medium when that row is paid on board;
  - one `networks` row per group of routes the older rows price the same way —
  the routes that share a set of route-specific `fare_rules` rows make one
  group, and a route priced on its own makes a group of its own — with a
  `route_networks` row per route, and the group named from its routes' short
  names;
  - one `fare_leg_rules` row per area pair per group: a `fare_rules` row naming
    no route applies to every route, so it is written once per group, and a row
  naming one route is written on that route's own group;
  - one free same-group `fare_transfer_rules` row per group, carrying the
  `transfers` and `transfer_duration` of the fares priced in it;
  - one `fare_version_settings` row, and one `fare_version` change-log entry.

  A `contains_id` row is not converted. A fare that covers a journey passing
  through a third zone is not a Fares v2 leg rule, so the row is listed as kept
  in the older format and the derived older-format files keep writing it (R11).

  The conversion is accepted only when it changes no rider-facing price. Every
  active route is checked against every ordered pair of the version's zones,
  each including none, by pricing one single-leg journey twice: the way an app
  reading `fare_attributes.txt` and `fare_rules.txt` prices it on the stored
  rows, and the way `Fares.Pricing` prices it on the rows the conversion would
  write. Any difference refuses the whole conversion with `:price_mismatch` and
  writes nothing (R12), because a converted feed that quietly repriced a route
  would show riders a price their agency never agreed to.

  Every stored `fare_attributes` and `fare_rules` row is left exactly as it was
  (INV-3). The inverse names only the rows this write created, and undoing the
  conversion returns the version to unmanaged with its imported files back.
  """

  import Ecto.Query, warn: false
  # The spec's contract names this module's writer `apply/3`, which would
  # otherwise collide with `Kernel.apply/3`.
  import Kernel, except: [apply: 3]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Normalize
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.Fares.VersionLock
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.Stop
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

  # -- Converting an imported older-format feed --------------------------------

  # R12's older rows carry one price per fare and no rider dimension, so every
  # derived product is sold to the Adult rider type, which is the version's one
  # default (R8).
  @adult_rider_id "adult"
  @adult_rider_name "Adult"

  # `fare_attributes.payment_method` 0 is the fare a rider pays on board, which
  # is the `cash` medium the editor's grid reads a price under.
  @v1_cash_media_id "cash"
  @v1_cash_media_name "Cash"
  @v1_cash_media_type 0

  # `duration_limit_type` 0 measures the open fare from its first departure to
  # this arrival, which is the clock Google's older format runs.
  @duration_first_departure_to_arrival 0

  # The price check walks every active route against every ordered pair of the
  # version's zones, so a feed with thousands of routes and zones must not walk
  # it. R12 refuses such a version outright; step 15 times the largest public
  # excerpt and records the value it settles on here.
  @max_domain 20_000

  # A refused review names enough of the differences to act on, and no more.
  @max_examples 5

  @price_mismatch_message "Converting these fares would change a price a rider is charged"

  @transfer_clock_difference "A free change is measured between the two rides' route groups " <>
                               "here; the older format measured one window from the first " <>
                               "departure to the last arrival of the whole journey."

  @whole_journey_difference "The older format priced a whole journey with the one fare that " <>
                              "covered all of it; each ride is priced on its own here and a " <>
                              "change is priced by the transfer rules, so a journey one fare " <>
                              "covered can now total differently."

  @contains_reason "A journey that passes through this zone is not a Fares v2 leg rule, so " <>
                     "this rule stays in the exported older-format files."

  @stale_message "The stored fares changed since the review, so nothing was written."

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
          record_rollback(scope, setting, entry, @undo_summary)
          %{operation_id: operation_id, inverse: nil}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  What converting this version's imported `fare_attributes` and `fare_rules` rows
  would write, or why it must not (R12, AC-11).

  Answers `{:ok, plan}` for a version that stores the older format and whose
  prices the conversion reproduces exactly:

      %{source: :v1,
        creates: %{table => count},
        updates: %{},
        price_differences: 0,
        known_differences: [String.t()],
        kept_older_only: [map()],
        fingerprint: String.t()}

  `creates` counts the rows of each table the conversion would write and
  `updates` is empty because a conversion never changes a stored older-format
  row (INV-3). `known_differences` lists the transfer-clock and whole-journey
  sentences R12 records rather than refuses, and `kept_older_only` lists the
  `contains_id` rows the derived older-format files keep writing. `fingerprint`
  is the hash of the stored rows the plan was built from, which `apply/3`
  re-checks before it writes anything.

  Answers `{:refused, [%{code: :price_mismatch, message: String.t(),
  examples: [String.t()]}]}` when the conversion would change a price, and
  `{:refused, [%{code: :too_large, ...}]}` when the version's routes and zones
  make the price check larger than the limit this module measures. A version with
  no fare rows is the first-use setup and answers `source: :none` with nothing to
  create; a version that already stores Fares v2 rows has no older-format
  conversion to make and is refused with `:unsupported_source` until that
  conversion exists.

  Nothing here writes: a preview is a read of the version's stored rows.
  """
  @spec preview(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:refused, [map()]}
  def preview(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    rows = Interpreter.load_rows(organization_id, gtfs_version_id)

    case source(rows) do
      :v1 -> plan_v1(rows)
      :none -> {:ok, empty_preview(rows)}
      :v2 -> {:refused, [unsupported_source()]}
    end
  end

  @doc """
  Converts this version's imported older-format fares, or refuses to.

  `fingerprint` is the value `preview/2` returned: the hash of the stored
  `fare_attributes` and `fare_rules` rows the editor reviewed. It is recomputed
  inside the version lock, so a fare row that changed after the review answers
  `{:refused, [%{code: :stale}]}` and writes nothing (AC-13). `opts` is this
  writer's option list and carries nothing today.

  Everything else is one `VersionLock.transact/3` transaction: the plan is
  rebuilt and refused on `:price_mismatch` before a row is written, the rows are
  written, `Fares.Normalize.run!/2` runs before the transaction commits (INV-1),
  one `fare_version` change-log entry is recorded, the `fare_version_settings` row
  is inserted with `older_format: "derived"`, and `{:ok, %{operation_id,
  inverse}}` is returned (R15). Every stored `fare_attributes` and `fare_rules`
  row is left exactly as it was (INV-3).
  """
  @spec apply(Fares.scope(), String.t(), keyword()) ::
          Fares.write_result() | {:refused, [map()]}
  def apply(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        fingerprint,
        opts \\ []
      ) do
    _opts = opts

    case VersionLock.transact(organization_id, gtfs_version_id, fn ->
           rows = Interpreter.load_rows(organization_id, gtfs_version_id)
           write_or_refuse(scope, rows, fingerprint)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:refused, reasons}} -> {:refused, reasons}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies a conversion's inverse, deleting every row that write created.

  A conversion creates rows and updates none, so the reversal is the same fence
  `undo_setup/3` uses: the settings row must still exist and still name
  `operation_id` as its `conversion_operation_id`, or the answer is
  `{:error, :stale}` and nothing is deleted (R13).
  """
  @spec undo_conversion(Fares.scope(), Ecto.UUID.t(), map()) :: Fares.write_result()
  def undo_conversion(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        %{conversion: inverse}
      ) do
    VersionLock.transact(organization_id, gtfs_version_id, fn ->
      case undoable_setting(organization_id, gtfs_version_id, operation_id) do
        {:ok, setting, entry} ->
          delete_created(organization_id, gtfs_version_id, inverse)
          :ok = Normalize.run!(organization_id, gtfs_version_id)
          record_rollback(scope, setting, entry, conversion_undo_summary())
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

  # One `fare_version` entry (R15) for either writer in this module.
  defp record_setup(scope, plan, inverse) do
    record_operation(scope, summary(plan), rows_written(plan, inverse))
  end

  # One `fare_version` entry (R15) for either writer here. The settings row's
  # `conversion_operation_id` names this entry, so the entry is written first
  # and the settings row second. The entry addresses the version's Fares section
  # rather than a GTFS natural key, which is how a fare operation is audited: an
  # external id of `"fares"`, no snapshot, and the rows the write touched beside
  # the shared operation id and the summary the editor's history shows.
  defp record_operation(%{audit: %AuditContext{} = audit}, summary, after_fields) do
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
        "summary" => summary,
        "before" => nil,
        "after" => after_fields
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

  # The `rolled_back` entry the audit trail reads as an undo of the entry named
  # in the settings row.
  defp record_rollback(%{audit: %AuditContext{} = audit}, setting, entry, summary) do
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
        "summary" => summary,
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

  # -- The older format --------------------------------------------------------

  # A managed version, or one holding Fares v2 rows, has nothing an older-format
  # conversion reads; a version with no fare rows is the first-use setup.
  defp source(%Rows{managed?: true}), do: :v2

  defp source(%Rows{} = rows) do
    cond do
      rows.fare_products != [] or rows.fare_leg_rules != [] or rows.fare_transfer_rules != [] ->
        :v2

      rows.fare_attributes != [] or rows.fare_rules != [] ->
        :v1

      true ->
        :none
    end
  end

  defp empty_preview(%Rows{} = rows) do
    %{
      source: :none,
      creates: %{},
      updates: %{},
      price_differences: 0,
      known_differences: [],
      kept_older_only: [],
      fingerprint: fingerprint(rows)
    }
  end

  defp unsupported_source do
    %{
      code: :unsupported_source,
      message:
        "This version stores Fares v2 rows, so there is no older-format conversion to " <>
          "make; a version with no fare rows is the first-use setup instead.",
      examples: []
    }
  end

  defp plan_v1(%Rows{} = rows) do
    active = active_routes(rows)
    representatives = zone_representatives(rows)

    if within_domain?(active, representatives) do
      plan = build_plan(rows, active, representatives)

      case price_differences(rows, plan) do
        [] ->
          {:ok, plan}

        examples ->
          {:refused,
           [%{code: :price_mismatch, message: @price_mismatch_message, examples: examples}]}
      end
    else
      {:refused, [too_large(active, representatives)]}
    end
  end

  defp within_domain?(routes, representatives) do
    domain_size(routes, representatives) <= @max_domain
  end

  defp domain_size(routes, representatives) do
    length(routes) * length(representatives) * length(representatives)
  end

  defp too_large(routes, representatives) do
    %{
      code: :too_large,
      message:
        "The version has #{length(routes)} routes and #{length(representatives)} zones, " <>
          "which is #{domain_size(routes, representatives)} prices to check; the limit is " <>
          "#{@max_domain}.",
      examples: []
    }
  end

  # The routes the price check walks: every route the version still runs. A route
  # named only by a `fare_rules` row is not one, and the export already leaves
  # such a row out.
  defp active_routes(%Rows{organization_id: organization_id, gtfs_version_id: gtfs_version_id}) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.active != false,
      order_by: [asc: r.route_id],
      select: {r.route_id, r.route_short_name}
    )
    |> Repo.all()
    |> Enum.map(fn {route_id, short_name} ->
      %{route_id: route_id, short_name: presence(short_name) || route_id}
    end)
  end

  # One stop per zone, plus one stop in no zone where the version has one. These
  # are the endpoints R12's price check walks: every active route against every
  # ordered pair of them, each including none.
  defp zone_representatives(%Rows{} = rows) do
    zoned =
      Enum.group_by(
        rows.stop_zones,
        fn {_stop_id, zone_id} -> zone_id end,
        fn {stop_id, _zone_id} -> stop_id end
      )
      |> Enum.map(fn {zone_id, stop_ids} -> {zone_id, Enum.min(stop_ids)} end)

    case zone_less_stop(rows.organization_id, rows.gtfs_version_id) do
      nil -> Enum.sort_by(zoned, &elem(&1, 0))
      stop_id -> Enum.sort_by([{nil, stop_id} | zoned], &(elem(&1, 0) || ""))
    end
  end

  defp zone_less_stop(organization_id, gtfs_version_id) do
    Repo.one(
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
            (is_nil(s.zone_id) or s.zone_id == ""),
        order_by: [asc: s.stop_id],
        limit: 1,
        select: s.stop_id
      )
    )
  end

  defp build_plan(%Rows{} = rows, active, representatives) do
    attributes = Enum.sort_by(rows.fare_attributes, & &1.fare_id)
    networks = networks_for(routes_for(rows, active), rows)
    route_networks = route_networks_for(networks)
    leg_rules = leg_rules_for(rows, networks, route_networks)
    transfer_rules = transfer_rules_for(networks, leg_rules, attributes)
    media = media_for(attributes)
    products = products_for(attributes)

    %{
      source: :v1,
      route_ids: Enum.map(active, & &1.route_id),
      zone_representatives: representatives,
      currency: currency_of(attributes),
      riders: [%{id: @adult_rider_id, name: @adult_rider_name, default?: true}],
      media: media,
      products: products,
      networks: networks,
      route_networks: route_networks,
      leg_rules: leg_rules,
      transfer_rules: transfer_rules,
      kept_older_only: kept_rules(rows),
      known_differences: [@transfer_clock_difference, @whole_journey_difference],
      creates: %{
        rider_categories: 1,
        fare_media: length(media),
        networks: length(networks),
        route_networks: length(route_networks),
        fare_products: length(products),
        fare_product_details: length(products),
        fare_leg_rules: length(leg_rules),
        fare_transfer_rules: length(transfer_rules)
      },
      updates: %{},
      price_differences: 0,
      fingerprint: fingerprint(rows)
    }
  end

  defp currency_of(attributes) do
    case Enum.find(attributes, &(presence(&1.currency_type) != nil)) do
      nil -> @default_currency
      attribute -> attribute.currency_type
    end
  end

  # Every route the conversion gives a group: the active ones, plus any route a
  # `fare_rules` row names that the version does not run, so a stored price for
  # it is carried into the derived rows rather than dropped.
  defp routes_for(%Rows{} = rows, active) do
    known = MapSet.new(active, & &1.route_id)

    named =
      rows.fare_rules
      |> Enum.map(&presence(&1.route_id))
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(known, &1)))
      |> Enum.uniq()
      |> Enum.map(&%{route_id: &1, short_name: &1})

    active ++ Enum.sort_by(named, & &1.route_id)
  end

  # One group per set of route-specific rules: the routes the older rows price
  # the same way share a group, and a route priced on its own makes a group of
  # its own. A `contains_id` rule is left out of the signature — it prices
  # nothing here and stays in the older-format files.
  defp networks_for(routes, %Rows{} = rows) do
    specific = Enum.filter(rows.fare_rules, &(presence(&1.route_id) != nil))

    routes
    |> Enum.group_by(&signature(&1, specific))
    |> Enum.sort_by(fn {_signature, group} -> hd(group).route_id end)
    |> Enum.map(fn {_signature, group} ->
      %{route_ids: Enum.map(group, & &1.route_id), name: group_name(group)}
    end)
    |> name_networks()
  end

  defp signature(%{route_id: route_id}, specific) do
    specific
    |> Enum.filter(&(presence(&1.route_id) == route_id))
    |> Enum.map(&{&1.fare_id, presence(&1.origin_id), presence(&1.destination_id)})
    |> Enum.sort()
  end

  # A group is named from its routes' short names, which is what the editor's
  # route-group list shows an operator.
  defp group_name([%{short_name: short_name}]), do: "Route #{short_name}"
  defp group_name(routes), do: "Routes " <> Enum.join(segments(routes), ", ")

  # A run of consecutive route numbers reads as one range, and a group of more
  # than two runs is written as its first run and one range over the rest, which
  # is how the sample's thirteen local routes read "Routes 1-7, 11-40".
  defp segments(routes) do
    {numbered, named} = Enum.split_with(routes, &is_integer(numeric(&1.short_name)))
    numbers = numbered |> Enum.map(&numeric(&1.short_name)) |> Enum.sort()
    texts = named |> Enum.map(& &1.short_name) |> Enum.sort()
    runs = consecutive(numbers)

    cond do
      runs == [] -> texts
      texts != [] -> Enum.map(runs, &range/1) ++ texts
      length(runs) <= 2 -> Enum.map(runs, &range/1)
      true -> [range(hd(runs)), range([Enum.at(runs, 1) |> List.first(), List.last(numbers)])]
    end
  end

  defp consecutive([]), do: []
  defp consecutive([first | rest]), do: runs([first], rest)

  defp runs(current, [next | rest]) do
    if List.last(current) + 1 == next do
      runs(current ++ [next], rest)
    else
      [current | runs([next], rest)]
    end
  end

  defp runs(current, []), do: [current]

  defp range([number]), do: Integer.to_string(number)
  defp range(numbers), do: "#{List.first(numbers)}-#{List.last(numbers)}"

  defp numeric(name) do
    case name |> presence() |> Integer.parse() do
      {number, ""} -> number
      _other -> nil
    end
  end

  # The network id is the group's name as a GTFS id, and a repeated name takes a
  # numeric suffix so two groups never share one.
  defp name_networks(networks) do
    {named, _used} =
      Enum.map_reduce(networks, MapSet.new(), fn network, used ->
        network_id = unique_id(network_slug(network.name), used)
        {Map.put(network, :network_id, network_id), MapSet.put(used, network_id)}
      end)

    named
  end

  defp unique_id(base, used), do: unique_id(base, 1, used)

  defp unique_id(base, n, used) do
    candidate = if n == 1, do: base, else: "#{base}_#{n}"

    if MapSet.member?(used, candidate) do
      unique_id(base, n + 1, used)
    else
      candidate
    end
  end

  defp network_slug(name) do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_") do
      "" -> "network"
      slug -> slug
    end
  end

  defp route_networks_for(networks) do
    for network <- networks,
        route_id <- network.route_ids,
        do: %{route_id: route_id, network_id: network.network_id}
  end

  # One leg rule per area pair per group: a `fare_rules` row naming no route
  # applies to every route, so it is written once per group, and a row naming one
  # route is written on that route's own group.
  defp leg_rules_for(%Rows{} = rows, networks, route_networks) do
    every_group = Enum.map(networks, & &1.network_id)
    by_route = Map.new(route_networks, &{&1.route_id, &1.network_id})

    rows.fare_rules
    |> Enum.reject(&contains?/1)
    |> Enum.flat_map(fn rule ->
      case presence(rule.route_id) do
        nil -> every_group
        route_id -> List.wrap(Map.get(by_route, route_id))
      end
      |> Enum.map(fn network_id ->
        %{
          network_id: network_id,
          from_area_id: presence(rule.origin_id),
          to_area_id: presence(rule.destination_id),
          fare_product_id: rule.fare_id
        }
      end)
    end)
    |> Enum.uniq()
  end

  defp contains?(rule), do: presence(rule.contains_id) != nil

  defp kept_rules(%Rows{} = rows) do
    rows.fare_rules
    |> Enum.filter(&contains?/1)
    |> Enum.map(fn rule ->
      %{
        fare_id: rule.fare_id,
        route_id: presence(rule.route_id),
        origin_id: presence(rule.origin_id),
        destination_id: presence(rule.destination_id),
        contains_id: rule.contains_id,
        reason: @contains_reason
      }
    end)
    |> Enum.sort_by(&{&1.fare_id, &1.route_id || "", &1.origin_id || "", &1.destination_id || ""})
  end

  # `fare_attributes.transfers` and `transfer_duration` belong to the fare the
  # older format keeps open, while a Fares v2 transfer rule belongs to a pair of
  # route groups — the transfer-clock difference the review lists rather than
  # refuses. Each group takes the most restrictive terms of the fares priced in
  # it, so a conversion never makes a change cheaper than the older format
  # charged, and a fare allowing no change leaves the group with no rule.
  defp transfer_rules_for(networks, leg_rules, attributes) do
    terms = Map.new(attributes, &{&1.fare_id, {&1.transfers || 0, &1.transfer_duration}})

    for network <- networks, reduce: [] do
      rules ->
        case group_terms(network.network_id, leg_rules, terms) do
          {transfers, duration} when transfers > 0 ->
            [transfer_rule(network.network_id, transfers, duration) | rules]

          _no_free_change ->
            rules
        end
    end
    |> Enum.reverse()
  end

  defp group_terms(network_id, leg_rules, terms) do
    candidates =
      for rule <- leg_rules,
          rule.network_id == network_id,
          do: Map.get(terms, rule.fare_product_id, {0, nil})

    case candidates do
      [] -> nil
      _many -> Enum.min_by(candidates, fn {transfers, duration} -> {transfers, duration || 0} end)
    end
  end

  defp transfer_rule(network_id, transfers, duration) do
    %{
      from_leg_group_id: network_id,
      to_leg_group_id: network_id,
      transfer_count: transfers,
      duration_limit: duration,
      duration_limit_type: @duration_first_departure_to_arrival,
      fare_transfer_type: @free_transfer_type
    }
  end

  # A fare paid on board is the `cash` medium; a version whose fares are all paid
  # by card gets no medium, and every product is then sold on any method, which
  # is the older row's own meaning.
  defp media_for(attributes) do
    if Enum.any?(attributes, &(&1.payment_method == 0)) do
      [%{id: @v1_cash_media_id, name: @v1_cash_media_name, type: @v1_cash_media_type}]
    else
      []
    end
  end

  defp products_for(attributes) do
    attributes
    |> Enum.with_index()
    |> Enum.map(fn {attribute, position} ->
      %{
        product_id: attribute.fare_id,
        name: attribute.fare_id,
        amount: attribute.price,
        currency: presence(attribute.currency_type) || @default_currency,
        rider: @adult_rider_id,
        media: if(attribute.payment_method == 0, do: @v1_cash_media_id, else: nil),
        position: position
      }
    end)
  end

  # -- The price equivalence check --------------------------------------------

  # Every active route against every ordered pair of zones, priced twice: the
  # way an app reading `fare_attributes.txt` and `fare_rules.txt` prices one
  # single-leg journey on the stored rows, and the way `Fares.Pricing` prices it
  # on the rows the conversion would write. The second price is worked out on a
  # `Rows` struct built from the plan rather than on the database, because a
  # preview must not write.
  defp price_differences(%Rows{} = rows, plan) do
    proposed = proposed_rows(rows, plan)
    medium_id = medium_id(plan)

    for route_id <- plan.route_ids,
        {from_zone, from_stop_id} <- plan.zone_representatives,
        {to_zone, to_stop_id} <- plan.zone_representatives,
        reduce: [] do
      differences ->
        journey = single_leg(route_id, from_stop_id, to_stop_id, medium_id)
        stored = Interpreter.price_journey_v1(rows, journey).total
        derived = Pricing.price_journey(proposed, journey).total

        if same_amount?(stored, derived) do
          differences
        else
          [difference(route_id, from_zone, to_zone, stored, derived, plan.currency) | differences]
        end
    end
    |> Enum.reverse()
    |> Enum.take(@max_examples)
  end

  defp medium_id(%{media: [medium | _rest]}), do: medium.id
  defp medium_id(%{media: []}), do: nil

  # The rows the conversion would write, read as a managed version's rows: the
  # proposed v2 rows beside the version's own zones, with the leg rules already
  # carrying the priority `Fares.Normalize` will give them.
  defp proposed_rows(%Rows{} = rows, plan) do
    %Rows{
      organization_id: rows.organization_id,
      gtfs_version_id: rows.gtfs_version_id,
      managed?: true,
      fare_products: Enum.map(plan.products, &product_row/1),
      fare_leg_rules: Enum.map(plan.leg_rules, &leg_rule_row/1),
      fare_transfer_rules: plan.transfer_rules,
      fare_product_details: Enum.map(plan.products, &detail_row/1),
      networks: Enum.map(plan.networks, &network_row/1),
      route_networks: Map.new(plan.route_networks, &{&1.route_id, &1.network_id}),
      stop_areas: Map.new(rows.stop_zones, fn {stop_id, zone_id} -> {stop_id, [zone_id]} end),
      stop_zones: rows.stop_zones,
      rider_categories: Enum.map(plan.riders, &rider_row/1),
      fare_media: Enum.map(plan.media, &media_row/1)
    }
  end

  defp product_row(product) do
    %{
      fare_product_id: product.product_id,
      fare_product_name: product.name,
      fare_media_id: product.media,
      amount: product.amount,
      currency: product.currency,
      rider_category_id: product.rider
    }
  end

  defp leg_rule_row(rule) do
    conditions = %{
      from_timeframe_group_id: nil,
      network_id: rule.network_id,
      from_area_id: rule.from_area_id,
      to_area_id: rule.to_area_id
    }

    %{
      network_id: rule.network_id,
      from_area_id: rule.from_area_id,
      to_area_id: rule.to_area_id,
      from_timeframe_group_id: nil,
      to_timeframe_group_id: nil,
      leg_group_id: rule.network_id,
      fare_product_id: rule.fare_product_id,
      rule_priority: Normalize.priority(conditions)
    }
  end

  defp detail_row(product) do
    %{fare_product_id: product.product_id, kind: "single", position: product.position}
  end

  defp network_row(network), do: %{network_id: network.network_id, network_name: network.name}

  defp rider_row(rider) do
    %{
      rider_category_id: rider.id,
      rider_category_name: rider.name,
      is_default_fare_category: if(rider.default?, do: 1, else: 0)
    }
  end

  defp media_row(medium) do
    %{fare_media_id: medium.id, fare_media_name: medium.name, fare_media_type: medium.type}
  end

  # One leg with no times: the older clock cannot be measured without them, and
  # the check is about which fare prices the ride rather than about a change.
  defp single_leg(route_id, from_stop_id, to_stop_id, medium_id) do
    %{
      rider_category_id: @adult_rider_id,
      fare_media_id: medium_id,
      service_date: nil,
      legs: [
        %{
          route_id: route_id,
          from_stop_id: from_stop_id,
          to_stop_id: to_stop_id,
          departs: nil,
          arrives: nil
        }
      ]
    }
  end

  defp same_amount?(nil, nil), do: true
  defp same_amount?(nil, _derived), do: false
  defp same_amount?(_stored, nil), do: false
  defp same_amount?(stored, derived), do: Decimal.compare(stored, derived) == :eq

  defp difference(route_id, from_zone, to_zone, stored, derived, currency) do
    "Route #{route_id} from #{zone(from_zone)} to #{zone(to_zone)}: the older format prices " <>
      "#{price(stored, currency)}, the converted rows price #{price(derived, currency)}"
  end

  defp zone(nil), do: "no zone"
  defp zone(zone_id), do: zone_id

  defp price(nil, _currency), do: "no fare"
  defp price(amount, currency), do: Money.format(amount, currency || @default_currency)

  # The reviewed state the editor converts: the stored `fare_attributes` and
  # `fare_rules` rows in id order, hashed. `apply/3` recomputes it inside the
  # version lock, so a fare row that changed between the review and the write
  # refuses the conversion instead of writing rows built from a price nobody
  # reviewed.
  defp fingerprint(%Rows{} = rows) do
    lines =
      Enum.map(Enum.sort_by(rows.fare_attributes, & &1.id), &attribute_line/1) ++
        Enum.map(Enum.sort_by(rows.fare_rules, & &1.id), &rule_line/1)

    :sha256
    |> :crypto.hash(Enum.join(lines, "\n"))
    |> Base.encode16(case: :lower)
  end

  defp attribute_line(attribute) do
    Enum.join(
      [
        attribute.id,
        attribute.fare_id,
        Decimal.to_string(attribute.price, :normal),
        attribute.currency_type,
        attribute.payment_method,
        attribute.transfers,
        attribute.agency_id,
        attribute.transfer_duration
      ],
      "|"
    )
  end

  defp rule_line(rule) do
    Enum.join(
      [
        rule.id,
        rule.fare_id,
        rule.route_id,
        rule.origin_id,
        rule.destination_id,
        rule.contains_id
      ],
      "|"
    )
  end

  # -- Writing the conversion -------------------------------------------------

  defp write_or_refuse(scope, %Rows{} = rows, fingerprint) do
    case source(rows) do
      :v1 -> write_plan_or_refuse(scope, rows, fingerprint)
      _other -> Repo.rollback({:refused, [unsupported_source()]})
    end
  end

  defp write_plan_or_refuse(scope, %Rows{} = rows, fingerprint) do
    case plan_v1(rows) do
      {:ok, plan} ->
        if plan.fingerprint == fingerprint do
          write_conversion(scope, plan)
        else
          Repo.rollback({:refused, [%{code: :stale, message: @stale_message, examples: []}]})
        end

      {:refused, reasons} ->
        Repo.rollback({:refused, reasons})
    end
  end

  defp write_conversion(scope, plan) do
    organization_id = scope.organization_id
    gtfs_version_id = scope.gtfs_version_id

    rider_rows = insert_rider_categories(organization_id, gtfs_version_id, plan.riders)
    media_rows = insert_media(organization_id, gtfs_version_id, plan.media)
    network_rows = insert_networks_for(organization_id, gtfs_version_id, plan.networks)
    route_rows = insert_route_networks_for(organization_id, gtfs_version_id, plan.route_networks)
    product_rows = insert_products_for(organization_id, gtfs_version_id, plan.products)
    detail_rows = insert_product_details(organization_id, gtfs_version_id, plan.products)
    rule_rows = insert_leg_rules_for(organization_id, gtfs_version_id, plan.leg_rules)

    transfer_rows =
      insert_transfer_rules_for(organization_id, gtfs_version_id, plan.transfer_rules)

    :ok = Normalize.run!(organization_id, gtfs_version_id)

    # The medium and the settings row are one row each, so the inverse carries
    # their ids the way `write_setup/4` records them.
    inverse = %{
      rider_categories: Enum.map(rider_rows, & &1.id),
      fare_media: media_ids(media_rows),
      networks: Enum.map(network_rows, & &1.id),
      route_networks: Enum.map(route_rows, & &1.id),
      fare_products: Enum.map(product_rows, & &1.id),
      fare_product_details: Enum.map(detail_rows, & &1.id),
      fare_leg_rules: Enum.map(rule_rows, & &1.id),
      fare_transfer_rules: Enum.map(transfer_rows, & &1.id)
    }

    operation = record_operation(scope, conversion_summary(plan), plan.creates)
    setting = insert_settings(organization_id, gtfs_version_id, operation.id)

    %{operation_id: operation.id, inverse: %{conversion: Map.put(inverse, :setting, setting.id)}}
  end

  defp conversion_summary(plan) do
    "Converted #{plan.creates.fare_products} older-format fares into " <>
      "#{plan.creates.fare_leg_rules} leg rules and #{plan.creates.networks} route groups"
  end

  defp conversion_undo_summary,
    do: "Removed the fares the older-format conversion created"

  # The medium is the same `cash` row the first-use setup writes, so a version
  # that was set up and then re-imported still carries one row per method.
  defp insert_media(_organization_id, _gtfs_version_id, []), do: []

  defp insert_media(organization_id, gtfs_version_id, [_medium | _rest]),
    do: [insert_cash_medium(organization_id, gtfs_version_id)]

  defp media_ids([]), do: nil
  defp media_ids([medium]), do: medium.id

  defp insert_networks_for(organization_id, gtfs_version_id, networks) do
    Enum.map(networks, fn network ->
      %Network{}
      |> Network.changeset(%{
        network_id: network.network_id,
        network_name: network.name,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end)
  end

  defp insert_route_networks_for(organization_id, gtfs_version_id, route_networks) do
    Enum.map(route_networks, fn route_network ->
      %RouteNetwork{}
      |> RouteNetwork.changeset(%{
        network_id: route_network.network_id,
        route_id: route_network.route_id,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end)
  end

  defp insert_products_for(organization_id, gtfs_version_id, products) do
    Enum.map(products, fn product ->
      %FareProduct{}
      |> FareProduct.changeset(%{
        fare_product_id: product.product_id,
        fare_product_name: product.name,
        fare_media_id: product.media,
        amount: product.amount,
        currency: product.currency,
        rider_category_id: product.rider,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end)
  end

  defp insert_leg_rules_for(organization_id, gtfs_version_id, rules) do
    Enum.map(rules, fn rule ->
      %FareLegRule{}
      |> FareLegRule.changeset(%{
        network_id: rule.network_id,
        from_area_id: rule.from_area_id,
        to_area_id: rule.to_area_id,
        fare_product_id: rule.fare_product_id,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })
      |> Repo.insert!()
    end)
  end

  defp insert_transfer_rules_for(organization_id, gtfs_version_id, rules) do
    Enum.map(rules, fn rule ->
      %FareTransferRule{}
      |> FareTransferRule.changeset(
        Map.merge(rule, %{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })
      )
      |> Repo.insert!()
    end)
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
