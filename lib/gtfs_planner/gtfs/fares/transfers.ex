defmodule GtfsPlanner.Gtfs.Fares.Transfers do
  @moduledoc """
  The writer of one pair of route groups' transfer policy (R5, R6, AC-23).

  A transfer policy is stored directly as `fare_transfer_rules` rows between two
  leg groups, and this module is the only writer of them outside the importer and
  the conversions, which create them from an imported feed's own rows:

  - `free` → `fare_transfer_type 0` with no product, which keeps the fare already
    paid and adds nothing;
  - `fee` → `fare_transfer_type 0` with a `transfer_fee` product, which keeps the
    fare already paid and adds the fee;
  - `difference` → `fare_transfer_type 2` with the destination group's single-ride
    product, which replaces the fare already paid with that product alone;
  - `full` → no row at all, which ends the open fare and charges this ride on its
    own.

  `duration_limit` is the time limit in seconds (`minutes × 60`) and
  `duration_limit_type` is the basis the editor chose, `1` — departure to
  departure — unless it chose another. `transfer_count` is written only when the
  two leg groups are the same one, because the reference forbids it on a pair of
  different groups and R5 keeps that rule: it is `nil` on every cross-group row,
  and `-1` is the operator's "no limit" on a same-group row.

  ## What "pays the difference" may not do

  R6 refuses a `difference` that could undercharge, with
  `{:error, :difference_not_expressible}`. The destination group must charge
  exactly one single-ride fare — two fares in one group leave the rider a choice
  between them, which a type 2 row cannot express — and for every rider type and
  payment method that fare is sold at, its amount must be at least the amount of
  every single-ride product of the origin group for the same rider and method.

  A rider and method the destination fare is not sold at is not compared: GTFS
  reads a product with no row for that pair as the fare unknown for it, and
  `Fares.Pricing` then charges that ride its own fare and says so, which charges
  the rider more rather than less. Comparing it would refuse the sample's own
  `Local → Intercity` difference, whose Intercity fare is not sold in the app.

  ## How a write is fenced

  `save/5` is one `Fares.VersionLock.transact/2` transaction, the path every writer
  of this package takes (R15, INV-1): the version must be managed, the pair's leg
  groups must be route groups of this version, the pair's reviewed row must still
  be the stored one, `Fares.Normalize.run!/2` runs before the commit, one
  `fare_version` change-log entry is recorded, and `{:ok, %{operation_id, inverse}}`
  is returned for `Fares.undo/3` to reverse while every row still holds what this
  write left.

  Every read and write here filters by `organization_id` and `gtfs_version_id`
  together (INV-5), so one version's transfer policies are never written through
  another version's scope.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Normalize
  alias GtfsPlanner.Gtfs.Fares.VersionLock
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Repo

  # R3's name for the leg group of the leg rules that name no network, which is
  # the one value that is not a route group of the version but is still a leg
  # group a transfer rule may name.
  @all_routes "all_routes"

  # R5's `fare_transfer_type`: the fare already paid plus the transfer product,
  # and the transfer product alone.
  @free_type 0
  @difference_type 2

  # R5's default basis, measured from the first departure, and the reference's
  # four bases.
  @default_basis 1
  @max_basis 3

  # The operator's "no limit" on a same-group rule, which the reference reads as
  # every change.
  @unlimited_count -1

  @transfer_fee_kind "transfer_fee"

  @pass_kind "pass"

  @default_currency "USD"

  @choices [:free, :fee, :difference, :full]

  # The facts of a stored policy a reviewed map may carry, and each one is read
  # back out of the pair's rule in the drawer's own words for the fence.
  @reviewed_fields [:pay, :minutes, :count, :fee]

  @doc """
  Stores one pair of route groups' transfer policy and answers the inverse
  `Fares.undo/3` applies (AC-23, R5, R6).

  `from_network` and `to_network` are the leg groups the policy is between: a
  route group of this version, or `"all_routes"` for the leg rules that name no
  network. A value this version does not hold answers `{:error, :not_found}` and
  writes nothing, so another organization's or version's group is never written
  through this writer (AC-26, INV-5).

  `params` is the transfer drawer's own form:

      %{pay: :free | :fee | :difference | :full,
        minutes: pos_integer(),
        basis: 0..3,
        count: pos_integer() | -1 | nil,
        fee: Decimal.t() | String.t() | nil}

  `basis` defaults to `1` and `count` to no limit. `count` is ignored unless the
  two leg groups are the same one, which is the only case R5 writes it in. A
  `fee` is read through the same `Fares.Money.parse/1` every other price is, and
  `pay: :fee` without a readable one answers `{:error, :invalid_price}`. A fee
  amount may be negative here and nowhere else, which is the one reader R9
  reserves for this writer.

  Every rule this pair already holds is deleted before the new one is written, so
  a pair carries exactly one policy whichever choice is made, and `pay: :full`
  leaves the pair with no row at all. A `fee` policy also writes the
  `transfer_fee` product the pair's fee is stored on — one row naming no rider
  type and no payment method, which GTFS reads as the fee for every rider and
  every method — and a policy that is no longer a fee deletes that product when
  no remaining rule names it, so the exported `fare_products.txt` never carries a
  fee nobody is charged.

  `reviewed` is the fence: the policy the drawer showed for this pair, as a map
  carrying any of `:pay`, `:minutes`, `:count` and `:fee`. A fact that has moved
  since answers `{:error, {:stale, details}}` naming it and writes nothing (R15).
  `nil` is a create and has nothing to be stale against.

  A `difference` R6 cannot express answers
  `{:error, :difference_not_expressible}`, a version that is not managed answers
  `{:error, :unmanaged}`, and a pair that is not a published version of that
  organization answers `{:error, :not_found}`.
  """
  @spec save(Fares.scope(), String.t(), String.t(), map(), map() | nil) ::
          Fares.write_result()
  def save(
        %{organization_id: _organization_id, gtfs_version_id: _gtfs_version_id} = scope,
        from_network,
        to_network,
        params,
        reviewed
      )
      when is_binary(from_network) and is_binary(to_network) and is_map(params) do
    with {:ok, choice} <- transfer_choice(params) do
      write_transfer(scope, from_network, to_network, choice, reviewed)
    end
  end

  @doc """
  Reverses one `save/5`, restoring the pair's rules and its fee product.

  The entry this reversal names has to exist in this version, and every row the
  write touched must still hold what that write left: a pair's added rule must
  still be there naming the policy it was written with, the rules it deleted must
  still be gone, and the fee product must still hold — or still be missing — what
  the write left of it. Anything else answers `{:error, :stale}` and changes
  nothing, so a reversal can never revert a later edit (R15, AC-26).
  """
  @spec undo_transfer(Fares.scope(), Ecto.UUID.t(), map()) :: Fares.write_result()
  def undo_transfer(
        %{organization_id: organization_id, gtfs_version_id: gtfs_version_id} = scope,
        operation_id,
        inverse
      )
      when is_map(inverse) do
    VersionLock.transact(scope, fn ->
      with {:ok, setting} <- managed_setting(organization_id, gtfs_version_id),
           {:ok, entry} <- undoable_entry(operation_id, organization_id, gtfs_version_id),
           :ok <- require_pair_restorable(organization_id, gtfs_version_id, inverse) do
        restore_pair(organization_id, gtfs_version_id, inverse)
        :ok = Normalize.run!(organization_id, gtfs_version_id)
        record_rollback(scope, setting, entry, inverse)
        %{operation_id: operation_id, inverse: nil}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp write_transfer(scope, from_network, to_network, choice, reviewed) do
    organization_id = scope.organization_id
    gtfs_version_id = scope.gtfs_version_id

    VersionLock.transact(scope, fn ->
      with {:ok, setting} <- managed_setting(organization_id, gtfs_version_id),
           :ok <- require_leg_groups(organization_id, gtfs_version_id, [from_network, to_network]),
           :ok <-
             require_pair_unchanged(
               organization_id,
               gtfs_version_id,
               from_network,
               to_network,
               reviewed
             ),
           {:ok, product} <-
             difference_product(
               organization_id,
               gtfs_version_id,
               from_network,
               to_network,
               choice
             ),
           {:ok, written} <-
             write_pair(
               organization_id,
               gtfs_version_id,
               from_network,
               to_network,
               choice,
               product
             ) do
        :ok = Normalize.run!(organization_id, gtfs_version_id)

        record_entry(
          scope,
          setting,
          transfer_summary(organization_id, gtfs_version_id, from_network, to_network, choice),
          written
        )

        %{operation_id: written.entry_id, inverse: %{transfer: written.inverse}}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp managed_setting(organization_id, gtfs_version_id) do
    case Fares.settings(organization_id, gtfs_version_id) do
      nil -> {:error, :unmanaged}
      setting -> {:ok, setting}
    end
  end

  # R5's leg groups are this version's route groups, plus the one string that
  # stands for the leg rules naming no network.
  defp require_leg_groups(organization_id, gtfs_version_id, leg_groups) do
    known =
      Network
      |> scoped(organization_id, gtfs_version_id)
      |> select([network], network.network_id)
      |> Repo.all()
      |> MapSet.new()

    if Enum.all?(leg_groups, &(MapSet.member?(known, &1) or &1 == @all_routes)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  # -- The fence -----------------------------------------------------------------

  # What the drawer showed for this pair must still be what is stored. `nil` is a
  # create and has nothing to be stale against.
  defp require_pair_unchanged(_organization_id, _gtfs_version_id, _from, _to, nil), do: :ok

  defp require_pair_unchanged(organization_id, gtfs_version_id, from, to, reviewed) do
    case stale_policy_details(organization_id, gtfs_version_id, from, to, reviewed) do
      [] -> :ok
      stale -> {:error, {:stale, stale}}
    end
  end

  # The facts the drawer showed that no longer match what the pair stores, each
  # naming its field and both values, so the editor can say which cell moved.
  defp stale_policy_details(organization_id, gtfs_version_id, from, to, reviewed) do
    stored = stored_policy(organization_id, gtfs_version_id, from, to)

    Enum.flat_map(@reviewed_fields, &stale_detail(&1, reviewed, stored))
  end

  defp stale_detail(field, reviewed, stored) do
    case Map.fetch(reviewed, field) do
      :error -> []
      {:ok, value} -> moved_detail(field, value, Map.get(stored, field))
    end
  end

  defp moved_detail(field, value, stored) do
    if same_policy_value(field, value, stored) do
      []
    else
      [%{field: field, reviewed: value, stored: stored}]
    end
  end

  # A fee is compared as a decimal, so an amount written and read back is the same
  # fact however either side spells it.
  defp same_policy_value(:fee, reviewed, stored) do
    decimal_amount(reviewed) == decimal_amount(stored)
  end

  defp same_policy_value(_field, reviewed, stored), do: reviewed == stored

  # What the pair's stored rule states, in the words the drawer shows, which is
  # the shape `Fares.load_workspace/2` gives a transfer cell.
  defp stored_policy(organization_id, gtfs_version_id, from, to) do
    case pair_rule(organization_id, gtfs_version_id, from, to) do
      nil ->
        %{pay: :full, minutes: nil, count: nil, fee: nil}

      rule ->
        %{
          pay: pay_of(rule),
          minutes: minutes_of(rule),
          count: rule.transfer_count,
          fee: stored_fee(organization_id, gtfs_version_id, rule)
        }
    end
  end

  defp pay_of(%{fare_transfer_type: @difference_type}), do: :difference
  defp pay_of(%{fare_product_id: nil}), do: :free
  defp pay_of(_rule), do: :fee

  defp minutes_of(%{duration_limit: nil}), do: nil
  defp minutes_of(%{duration_limit_type: 1, duration_limit: limit}), do: div(limit, 60)
  defp minutes_of(_rule), do: nil

  defp stored_fee(_organization_id, _gtfs_version_id, rule) do
    if pay_of(rule) == :fee, do: rule.fare_product_id, else: nil
  end

  # -- R6's guard ----------------------------------------------------------------

  # `nil` for every choice but `difference`; for `difference` the destination
  # group's one single-ride product, which `Fares.Normalize` also refreshes a
  # difference rule to (R5, INV-4).
  defp difference_product(_organization_id, _gtfs_version_id, _from, _to, %{pay: pay})
       when pay != :difference,
       do: {:ok, nil}

  defp difference_product(organization_id, gtfs_version_id, from, to, _choice) do
    origin_fares = group_fares(organization_id, gtfs_version_id, from)
    destination_fares = group_fares(organization_id, gtfs_version_id, to)

    with {:ok, destination} <- only_fare(destination_fares),
         :ok <- amounts_never_lower?(destination.rows, all_rows(origin_fares)) do
      default_rider_product(organization_id, gtfs_version_id, destination)
    end
  end

  # The destination group must charge exactly one single-ride fare.
  defp only_fare([fare]), do: {:ok, fare}
  defp only_fare(_fares), do: {:error, :difference_not_expressible}

  defp all_rows(fares), do: Enum.flat_map(fares, & &1.rows)

  # For every rider and method the destination fare is sold at, its amount must be
  # at least the highest amount the origin group's fares charge that same rider
  # and method. A pair the destination fare is not sold at is not compared; see
  # the module doc.
  defp amounts_never_lower?(destination_rows, origin_rows) do
    never_lower?(destination_rows, origin_rows, compared_pairs(destination_rows, origin_rows))
  end

  defp never_lower?(_destination_rows, _origin_rows, []), do: :ok

  defp never_lower?(destination_rows, origin_rows, [{rider, medium} | rest]) do
    case {amount_for(destination_rows, rider, medium), highest_amount(origin_rows, rider, medium)} do
      # A pair the destination fare is not sold at, or one the origin charges
      # nothing for, is not compared; see the module doc.
      {nil, _other} ->
        never_lower?(destination_rows, origin_rows, rest)

      {_amount, nil} ->
        never_lower?(destination_rows, origin_rows, rest)

      {amount, highest} ->
        if Decimal.compare(amount, highest) != :lt,
          do: never_lower?(destination_rows, origin_rows, rest),
          else: {:error, :difference_not_expressible}
    end
  end

  # The pairs the guard looks at: the origin group's own rider and method pairs,
  # which is where an undercharge could show, plus the pairs the destination fare
  # names outright. A destination row naming no rider type or no method answers
  # any pair through `amount_for/3`, so it takes part in all of them.
  defp compared_pairs(destination_rows, origin_rows) do
    Enum.uniq(pairs_of(destination_rows) ++ pairs_of(origin_rows))
  end

  defp pairs_of(rows) do
    for %FareProduct{rider_category_id: rider, fare_media_id: medium} <- rows,
        not is_nil(rider) and not is_nil(medium),
        do: {rider, medium}
  end

  # The amount a product's rows state for one rider and method, read the way the
  # reference and `Fares.Pricing` read them: the exact pair, then the row with no
  # medium, then the row with no rider type, then the row with neither. Applied to
  # one row at a time so a nil rider or medium on the row itself is answered by
  # the rows around it.
  defp amount_for(rows, rider, medium) do
    [
      {rider, medium},
      {rider, nil},
      {nil, medium},
      {nil, nil}
    ]
    |> Enum.find_value(&row_amount_for(rows, &1))
  end

  defp row_amount_for(rows, {row_rider, row_medium}) do
    Enum.find_value(rows, &row_amount(&1, row_rider, row_medium))
  end

  defp row_amount(row, row_rider, row_medium) do
    if row.rider_category_id == row_rider and row.fare_media_id == row_medium do
      row.amount
    end
  end

  defp highest_amount(rows, rider, medium) do
    rows
    |> Enum.map(fn row -> amount_for([row], rider, medium) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> Decimal.new(0) end)
  end

  # The product a type 2 row names: the destination fare's product for the
  # version's default rider type where the fare sells one, which is the same
  # choice `Fares.Normalize`'s difference refresh makes.
  defp default_rider_product(organization_id, gtfs_version_id, fare) do
    default_rider = default_rider_category(organization_id, gtfs_version_id)

    chosen =
      Enum.find(fare.rows, fn row -> row.rider_category_id == default_rider end) ||
        Enum.min_by(fare.rows, fn row ->
          {row.rider_category_id || "", row.fare_media_id || "", row.fare_product_id}
        end)

    case chosen do
      nil -> {:error, :difference_not_expressible}
      row -> {:ok, row.fare_product_id}
    end
  end

  defp default_rider_category(organization_id, gtfs_version_id) do
    RiderCategory
    |> scoped(organization_id, gtfs_version_id)
    |> where([category], category.is_default_fare_category == 1)
    |> order_by([category], asc: category.rider_category_id)
    |> select([category], category.rider_category_id)
    |> limit(1)
    |> Repo.one()
  end

  # -- The group's own single-ride fares -----------------------------------------

  # The single-ride fares one leg group prices, sorted by name so the answer does
  # not depend on the order the rows came back in. A pass's leg rules are
  # `Fares.Normalize`'s rows rather than a fare of the group (R4, INV-4).
  defp group_fares(organization_id, gtfs_version_id, leg_group_id) do
    products = version_products(organization_id, gtfs_version_id)

    group_leg_rules(organization_id, gtfs_version_id, leg_group_id)
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.flat_map(&List.wrap(Map.get(products, &1)))
    |> Enum.group_by(&fare_name/1)
    |> Enum.map(fn {name, rows} -> %{name: name, rows: rows} end)
    |> Enum.sort_by(& &1.name)
  end

  defp group_leg_rules(organization_id, gtfs_version_id, @all_routes) do
    FareLegRule
    |> scoped(organization_id, gtfs_version_id)
    |> where([rule], is_nil(rule.network_id))
    |> exclude_pass_products(organization_id, gtfs_version_id)
    |> Repo.all()
  end

  defp group_leg_rules(organization_id, gtfs_version_id, network_id) do
    FareLegRule
    |> scoped(organization_id, gtfs_version_id)
    |> where([rule], rule.network_id == ^network_id)
    |> exclude_pass_products(organization_id, gtfs_version_id)
    |> Repo.all()
  end

  defp exclude_pass_products(query, organization_id, gtfs_version_id) do
    pass_ids =
      FareProductDetail
      |> scoped(organization_id, gtfs_version_id)
      |> where([detail], detail.kind == @pass_kind)
      |> select([detail], detail.fare_product_id)
      |> Repo.all()

    where(query, [rule], rule.fare_product_id not in ^pass_ids)
  end

  # A fare is the group of `fare_products` rows sharing a `fare_product_name`,
  # which is the identity this package's own writers use.
  defp fare_name(%FareProduct{fare_product_name: name}) when is_binary(name) and name != "",
    do: name

  defp fare_name(%FareProduct{fare_product_id: id}), do: id

  defp version_products(organization_id, gtfs_version_id) do
    FareProduct
    |> scoped(organization_id, gtfs_version_id)
    |> Repo.all()
    |> Map.new(&{&1.fare_product_id, &1})
  end

  # -- The write -----------------------------------------------------------------

  # The pair's stored rules go, the new one is written unless the choice is
  # `full`, and the fee product follows the choice.
  defp write_pair(organization_id, gtfs_version_id, from, to, choice, product) do
    removed = pair_rules(organization_id, gtfs_version_id, from, to)
    fee_before = fee_product_before(organization_id, gtfs_version_id, from, to)
    delete_rules(organization_id, gtfs_version_id, removed)
    added = insert_rule(organization_id, gtfs_version_id, from, to, choice, product)
    fee_after = write_fee_product(organization_id, gtfs_version_id, from, to, choice, fee_before)

    {:ok,
     %{
       entry_id: Ecto.UUID.generate(),
       removed: removed,
       added: added,
       fee_after: fee_after,
       inverse: %{
         from: from,
         to: to,
         removed: removed,
         added: added,
         fee_before: fee_before,
         fee_after: fee_after
       }
     }}
  end

  defp insert_rule(_organization_id, _gtfs_version_id, _from, _to, %{pay: :full}, _product),
    do: nil

  defp insert_rule(organization_id, gtfs_version_id, from, to, choice, product) do
    attrs = %{
      from_leg_group_id: from,
      to_leg_group_id: to,
      transfer_count: transfer_count(choice, from, to),
      duration_limit: choice.minutes * 60,
      duration_limit_type: choice.basis,
      fare_transfer_type: transfer_type(choice),
      fare_product_id: product_id(choice, from, to, product),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    %FareTransferRule{}
    |> FareTransferRule.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, rule} -> rule
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # R5: a count only where the two leg groups are the same one.
  defp transfer_count(choice, from, to) when from == to, do: choice.count
  defp transfer_count(_choice, _from, _to), do: nil

  defp transfer_type(%{pay: pay}) when pay in [:free, :fee], do: @free_type
  defp transfer_type(%{pay: :difference}), do: @difference_type

  defp product_id(%{pay: :fee}, from, to, _product), do: fee_product_id(from, to)
  defp product_id(%{pay: :difference}, _from, _to, product), do: product
  defp product_id(_choice, _from, _to, _product), do: nil

  defp fee_product_id(from, to), do: "fee_#{from}_#{to}"

  # The fee product this pair's fee is stored on: one row naming no rider type and
  # no payment method, which GTFS reads as the fee for every rider and every
  # method, plus the detail row that records its kind.
  defp fee_product_before(organization_id, gtfs_version_id, from, to) do
    product_id = fee_product_id(from, to)

    %{
      product: fee_product_row(organization_id, gtfs_version_id, product_id),
      detail: fee_detail_row(organization_id, gtfs_version_id, product_id)
    }
  end

  defp write_fee_product(
         organization_id,
         gtfs_version_id,
         from,
         to,
         %{pay: :fee} = choice,
         _before
       ) do
    product_id = fee_product_id(from, to)
    currency = version_currency(organization_id, gtfs_version_id)
    amount = round_amount(choice.fee, currency)

    upsert_fee_product(organization_id, gtfs_version_id, product_id, amount, currency)
    upsert_fee_detail(organization_id, gtfs_version_id, product_id)

    row = fee_product_row(organization_id, gtfs_version_id, product_id)
    %{product_id: product_id, id: row.id, amount: amount}
  end

  # The fee product this writer created goes when the pair stops charging it and
  # no remaining rule names it, so the export never carries a fee nobody is
  # charged. Its detail row goes with it.
  defp write_fee_product(organization_id, gtfs_version_id, from, to, _choice, before) do
    product_id = fee_product_id(from, to)

    unless fee_referenced?(organization_id, gtfs_version_id, product_id) do
      delete_row(organization_id, gtfs_version_id, FareProduct, before.product)
      delete_row(organization_id, gtfs_version_id, FareProductDetail, before.detail)
    end

    nil
  end

  defp upsert_fee_product(organization_id, gtfs_version_id, product_id, amount, currency) do
    case fee_product_row(organization_id, gtfs_version_id, product_id) do
      nil ->
        %FareProduct{}
        |> FareProduct.changeset(%{
          fare_product_id: product_id,
          fare_product_name: "Transfer fee",
          amount: amount,
          currency: currency,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        })
        |> Repo.insert()
        |> unwrap_or_rollback()

      row ->
        row
        |> FareProduct.changeset(%{
          fare_product_id: product_id,
          fare_product_name: "Transfer fee",
          amount: amount,
          currency: currency
        })
        |> Repo.update()
        |> unwrap_or_rollback()
    end
  end

  defp upsert_fee_detail(organization_id, gtfs_version_id, product_id) do
    if is_nil(fee_detail_row(organization_id, gtfs_version_id, product_id)) do
      attrs = %{
        fare_product_id: product_id,
        kind: @transfer_fee_kind,
        position: 0,
        accepted_network_ids: []
      }

      detail =
        FareProductDetail.changeset(
          Map.merge(%FareProductDetail{}, %{
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }),
          attrs
        )

      detail |> Repo.insert() |> unwrap_or_rollback()
    end

    :ok
  end

  defp unwrap_or_rollback({:ok, row}), do: row
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp fee_referenced?(organization_id, gtfs_version_id, product_id) do
    FareTransferRule
    |> scoped(organization_id, gtfs_version_id)
    |> where([rule], rule.fare_product_id == ^product_id)
    |> Repo.exists?()
  end

  defp fee_product_row(organization_id, gtfs_version_id, product_id) do
    FareProduct
    |> scoped(organization_id, gtfs_version_id)
    |> where([product], product.fare_product_id == ^product_id)
    |> order_by([product], asc: product.rider_category_id, asc: product.fare_media_id)
    |> Repo.one()
  end

  defp fee_detail_row(organization_id, gtfs_version_id, product_id) do
    FareProductDetail
    |> scoped(organization_id, gtfs_version_id)
    |> where([detail], detail.fare_product_id == ^product_id)
    |> Repo.one()
  end

  # Deleting by the row's own id, re-asserting the version pair, so a row that
  # moved between versions is never deleted through this path (INV-5).
  defp delete_row(_organization_id, _gtfs_version_id, _schema, nil), do: :ok

  defp delete_row(organization_id, gtfs_version_id, schema, row) do
    Repo.delete_all(
      from(r in schema,
        where:
          r.id == ^row.id and r.organization_id == ^organization_id and
            r.gtfs_version_id == ^gtfs_version_id
      )
    )
  end

  defp version_currency(organization_id, gtfs_version_id) do
    FareProduct
    |> scoped(organization_id, gtfs_version_id)
    |> order_by([product], asc: product.fare_product_id)
    |> select([product], product.currency)
    |> Repo.all()
    |> Enum.find(&(is_binary(&1) and &1 != "")) || @default_currency
  end

  defp round_amount(amount, currency) do
    Decimal.round(amount, Money.minor_units(currency))
  end

  # -- The pair's own rules ------------------------------------------------------

  defp pair_rules(organization_id, gtfs_version_id, from, to) do
    FareTransferRule
    |> scoped(organization_id, gtfs_version_id)
    |> where([rule], rule.from_leg_group_id == ^from and rule.to_leg_group_id == ^to)
    |> Repo.all()
  end

  # The one rule a pair is read through: a counted rule covers fewer changes than
  # an uncounted one, so a counted rule is the pair's policy where it has one.
  defp pair_rule(organization_id, gtfs_version_id, from, to) do
    pair_rules(organization_id, gtfs_version_id, from, to)
    |> Enum.sort_by(
      &{if(is_nil(&1.transfer_count), do: 1, else: 0), &1.transfer_count || 0, &1.id}
    )
    |> List.first()
  end

  defp delete_rules(_organization_id, _gtfs_version_id, []), do: :ok

  defp delete_rules(organization_id, gtfs_version_id, rules) do
    Repo.delete_all(
      from(rule in FareTransferRule,
        where:
          rule.organization_id == ^organization_id and rule.gtfs_version_id == ^gtfs_version_id and
            rule.id in ^Enum.map(rules, & &1.id)
      )
    )
  end

  defp transfer_rule(organization_id, gtfs_version_id, id) do
    FareTransferRule
    |> scoped(organization_id, gtfs_version_id)
    |> where([rule], rule.id == ^id)
    |> Repo.one()
  end

  defp scoped(queryable, organization_id, gtfs_version_id) do
    from(row in queryable,
      where: row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id
    )
  end

  # -- The drawer's form ---------------------------------------------------------

  defp transfer_choice(params) do
    with {:ok, pay} <- pay_choice(params),
         {:ok, minutes} <- minutes_choice(params, pay),
         {:ok, basis} <- basis_choice(params),
         {:ok, count} <- count_choice(params),
         {:ok, fee} <- fee_choice(params, pay) do
      {:ok, %{pay: pay, minutes: minutes, basis: basis, count: count, fee: fee}}
    end
  end

  defp pay_choice(params) do
    case Map.get(params, :pay) do
      pay when pay in @choices -> {:ok, pay}
      _other -> {:error, :invalid_policy}
    end
  end

  # `full` writes no row, so it has no time limit to check.
  defp minutes_choice(_params, :full), do: {:ok, 0}

  defp minutes_choice(params, _pay) do
    case positive_integer(Map.get(params, :minutes)) do
      {:ok, minutes} -> {:ok, minutes}
      :error -> {:error, :invalid_minutes}
    end
  end

  defp basis_choice(params) do
    case Map.get(params, :basis) do
      basis when is_integer(basis) and basis >= 0 and basis <= @max_basis -> {:ok, basis}
      "" -> {:ok, @default_basis}
      nil -> {:ok, @default_basis}
      _other -> {:error, :invalid_basis}
    end
  end

  defp count_choice(params) do
    case Map.get(params, :count) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      @unlimited_count ->
        {:ok, @unlimited_count}

      value ->
        case positive_integer(value) do
          {:ok, count} -> {:ok, count}
          :error -> {:error, :invalid_count}
        end
    end
  end

  defp fee_choice(_params, pay) when pay != :fee, do: {:ok, nil}

  defp fee_choice(params, :fee) do
    case Map.get(params, :fee) do
      %Decimal{} = amount -> {:ok, amount}
      value when is_binary(value) -> parse_fee(value)
      _other -> {:error, :invalid_price}
    end
  end

  defp parse_fee(value) do
    case Money.parse(value) do
      {:ok, nil} -> {:error, :invalid_price}
      {:ok, amount} -> {:ok, amount}
      {:error, :invalid} -> {:error, :invalid_price}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count > 0 -> {:ok, count}
      _other -> :error
    end
  end

  defp positive_integer(_value), do: :error

  defp decimal_amount(%Decimal{} = amount), do: amount
  defp decimal_amount(""), do: nil
  defp decimal_amount(value) when is_binary(value), do: Decimal.parse(value)
  defp decimal_amount(_value), do: nil

  # -- The change-log entry ------------------------------------------------------

  defp transfer_summary(organization_id, gtfs_version_id, from, to, %{pay: :full}) do
    "Removed the #{group_sentence(organization_id, gtfs_version_id, from, to)} transfer policy"
  end

  defp transfer_summary(organization_id, gtfs_version_id, from, to, %{pay: :free} = choice) do
    "Set the #{group_sentence(organization_id, gtfs_version_id, from, to)} transfer to be free " <>
      "for #{choice.minutes} minutes"
  end

  defp transfer_summary(organization_id, gtfs_version_id, from, to, %{pay: :fee} = choice) do
    currency = version_currency(organization_id, gtfs_version_id)
    fee = Money.format(round_amount(choice.fee, currency), currency)

    "Set the #{group_sentence(organization_id, gtfs_version_id, from, to)} transfer to charge #{fee}"
  end

  defp transfer_summary(organization_id, gtfs_version_id, from, to, %{pay: :difference}) do
    "Set the #{group_sentence(organization_id, gtfs_version_id, from, to)} transfer to pay the difference"
  end

  defp group_sentence(organization_id, gtfs_version_id, from, to) do
    "#{group_name(organization_id, gtfs_version_id, from)} to " <>
      "#{group_name(organization_id, gtfs_version_id, to)}"
  end

  defp group_name(_organization_id, _gtfs_version_id, @all_routes), do: "every route group"

  defp group_name(organization_id, gtfs_version_id, network_id) do
    Network
    |> scoped(organization_id, gtfs_version_id)
    |> where([network], network.network_id == ^network_id)
    |> select([network], network.network_name)
    |> Repo.one() || network_id
  end

  defp record_entry(scope, setting, summary, written) do
    attrs = %{
      entity_type: "fare_version",
      entity_id: setting.id,
      entity_external_id: "fares",
      actor_id: scope.audit.actor_id,
      actor_email: scope.audit.actor_email,
      action: action_of(written),
      changed_fields: %{
        "operation_id" => written.entry_id,
        "summary" => summary,
        "before" => Enum.map(written.removed, &transfer_log_row/1),
        "after" => after_log_rows(written)
      },
      organization_id: setting.organization_id,
      gtfs_version_id: setting.gtfs_version_id
    }

    %ChangeLog{id: written.entry_id}
    |> ChangeLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, %ChangeLog{}} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp action_of(%{added: nil}), do: "deleted"
  defp action_of(%{removed: []}), do: "created"
  defp action_of(_written), do: "updated"

  defp after_log_rows(%{added: nil, fee_after: nil}), do: []

  defp after_log_rows(%{added: added, fee_after: fee_after}) do
    rows = if added, do: [transfer_log_row(added)], else: []
    rows ++ fee_log_rows(fee_after)
  end

  defp fee_log_rows(nil), do: []

  defp fee_log_rows(fee_after),
    do: [
      %{
        "transfer_fee" => fee_after.product_id,
        "amount" => Decimal.to_string(fee_after.amount)
      }
    ]

  defp transfer_log_row(rule) do
    %{
      "from_leg_group_id" => rule.from_leg_group_id,
      "to_leg_group_id" => rule.to_leg_group_id,
      "transfer_count" => rule.transfer_count,
      "duration_limit" => rule.duration_limit,
      "duration_limit_type" => rule.duration_limit_type,
      "fare_transfer_type" => rule.fare_transfer_type,
      "fare_product_id" => rule.fare_product_id
    }
  end

  # -- Undo ----------------------------------------------------------------------

  defp undoable_entry(operation_id, organization_id, gtfs_version_id) do
    ChangeLog
    |> scoped(organization_id, gtfs_version_id)
    |> where(
      [log],
      log.id == ^operation_id and log.entity_type == "fare_version" and
        log.entity_external_id == "fares"
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :stale}
      entry -> {:ok, entry}
    end
  end

  # A saved pair's added rule must still be there naming the policy it was written
  # with, the rules it deleted must still be gone, and its fee product must still
  # hold — or still be missing — what the write left of it.
  defp require_pair_restorable(organization_id, gtfs_version_id, inverse) do
    with :ok <- added_rule_untouched(organization_id, gtfs_version_id, inverse.added),
         :ok <- removed_rules_gone(organization_id, gtfs_version_id, inverse.removed) do
      fee_untouched(organization_id, gtfs_version_id, inverse)
    end
  end

  defp added_rule_untouched(_organization_id, _gtfs_version_id, nil), do: :ok

  defp added_rule_untouched(organization_id, gtfs_version_id, rule) do
    case transfer_rule(organization_id, gtfs_version_id, rule.id) do
      nil ->
        {:error, :stale}

      current ->
        if transfer_log_row(current) == transfer_log_row(rule), do: :ok, else: {:error, :stale}
    end
  end

  defp removed_rules_gone(_organization_id, _gtfs_version_id, []), do: :ok

  defp removed_rules_gone(organization_id, gtfs_version_id, rules) do
    if Enum.any?(rules, &(transfer_rule(organization_id, gtfs_version_id, &1.id) != nil)) do
      {:error, :stale}
    else
      :ok
    end
  end

  defp fee_untouched(organization_id, gtfs_version_id, inverse) do
    product_id = fee_product_id(inverse.from, inverse.to)
    current = fee_product_row(organization_id, gtfs_version_id, product_id)

    case inverse.fee_after do
      # The write deleted the fee product, so it must still be gone.
      nil ->
        if is_nil(current), do: :ok, else: {:error, :stale}

      after_state ->
        cond do
          is_nil(current) -> {:error, :stale}
          not Decimal.equal?(current.amount, after_state.amount) -> {:error, :stale}
          # A fee this write created must still be the product it created, not one
          # an edit since has taken over.
          is_nil(inverse.fee_before.product) and current.id != after_state.id -> {:error, :stale}
          true -> :ok
        end
    end
  end

  defp restore_pair(organization_id, gtfs_version_id, inverse) do
    delete_rules(organization_id, gtfs_version_id, List.wrap(inverse.added))
    Enum.each(inverse.removed, &Repo.insert!(Ecto.Changeset.change(&1)))
    restore_fee_product(organization_id, gtfs_version_id, inverse)

    :ok
  end

  defp restore_fee_product(organization_id, gtfs_version_id, inverse) do
    cond do
      is_nil(inverse.fee_before.product) and is_nil(inverse.fee_after) ->
        :ok

      is_nil(inverse.fee_before.product) ->
        delete_row(
          organization_id,
          gtfs_version_id,
          FareProduct,
          fee_product_row(organization_id, gtfs_version_id, inverse.fee_after.product_id)
        )

        delete_row(
          organization_id,
          gtfs_version_id,
          FareProductDetail,
          fee_detail_row(organization_id, gtfs_version_id, inverse.fee_after.product_id)
        )

      is_nil(inverse.fee_after) ->
        Repo.insert!(Ecto.Changeset.change(inverse.fee_before.product))
        insert_detail(inverse.fee_before.detail)

      true ->
        restore_row(organization_id, gtfs_version_id, FareProduct, inverse.fee_before.product)
    end
  end

  defp restore_row(_organization_id, _gtfs_version_id, _schema, nil), do: :ok

  defp restore_row(organization_id, gtfs_version_id, schema, row) do
    delete_row(organization_id, gtfs_version_id, schema, row)
    Repo.insert!(Ecto.Changeset.change(row))
  end

  defp insert_detail(nil), do: :ok
  defp insert_detail(detail), do: Repo.insert!(Ecto.Changeset.change(detail))

  defp record_rollback(scope, setting, entry, inverse) do
    attrs = %{
      entity_type: "fare_version",
      entity_id: setting.id,
      entity_external_id: "fares",
      actor_id: scope.audit.actor_id,
      actor_email: scope.audit.actor_email,
      action: "rolled_back",
      rolled_back_to_log_id: entry.id,
      changed_fields: %{
        "operation_id" => entry.id,
        "summary" => "Restored the transfer policy a change replaced",
        "before" => entry.changed_fields["after"],
        "after" => entry.changed_fields["before"],
        "restored" => Enum.map(inverse.removed, &transfer_log_row/1)
      },
      organization_id: setting.organization_id,
      gtfs_version_id: setting.gtfs_version_id
    }

    %ChangeLog{}
    |> ChangeLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, %ChangeLog{}} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
