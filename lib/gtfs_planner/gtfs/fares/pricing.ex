defmodule GtfsPlanner.Gtfs.Fares.Pricing do
  @moduledoc """
  What one journey costs in a version's fare rows, and why each ride costs it.

  `price_journey/2` is the journey check the Checks tab and the saved journeys
  read (AC-5, AC-33, AC-41). It is pure over a
  `GtfsPlanner.Gtfs.Fares.Interpreter.Rows` struct: it reads rows, never queries
  the database, and never writes one, so a price and the rows that produced it are
  worked out from the same snapshot.

  A journey is a rider category, a payment medium, a service date and an ordered
  list of legs, each with its route, its two stops and its departure and arrival in
  seconds after local midnight. The result is

      %{total: Decimal.t() | nil, legs: [map()], passes: [map()], problems: [String.t()]}

  where `total` is `nil` whenever any ride is unpriced — the reference's "the fare
  is unknown" for a leg no rule covers, and a product with no row for this rider
  and medium — because a journey nobody can price must not read as a free ride.

  ## How a ride is priced

  Each leg's route gives its network, its stops give their areas, and
  `Interpreter.leg_rules/5` gives the rules that price it. Among the products
  those rules name, the passes are set aside and the single rides compete; the
  cheapest one the rider and medium can actually buy is the ride's fare, because
  the reference leaves equal options at the top priority to the rider. A product is
  read for a rider and medium from its `fare_products` rows — one row per
  `rider_category_id` and `fare_media_id` pair, where an empty value means "any" —
  preferring the exact pair, then the row with no medium, then the row with no
  rider category. A product with no `fare_product_details` row is read as a single
  ride, which is what an imported v2 version's products are until the editor
  records their kind.

  ## How a change between rides is priced

  The reference's rules are applied in order (`fare_transfer_rules.txt`, "Transfer
  matching and cost", as quoted in
  `.specs/_references/reports/GTFS fares v1 and v2 authoring research.md`):

  - the rules are filtered on `from_leg_group_id` and `to_leg_group_id`, the exact
    pair first and the rows with an empty value only where there is no exact row,
    because a route belongs to one leg group and the managed rows of R3 name it
    explicitly;
  - of the rules that remain, the one with "the minimum `transfer_count` that is
    greater than or equal to the current transfer count" applies, where an empty
    `transfer_count` means no limit;
  - `duration_limit` is measured from the first leg of the open fare over the clock
    `duration_limit_type` names: 0 from the first departure to this arrival, 1
    departure to departure, 2 from the first arrival to this departure, 3 arrival
    to arrival;
  - `fare_transfer_type` then prices the change: 0 keeps the fare already paid and
    adds the transfer product (the `fee` policy of R5), 1 adds this ride's own
    fare, and 2 replaces the fare already paid with the transfer product alone,
    which is the `difference` policy of R5.

  A rule that does not match, a limit that has passed, or a change the rule no
  longer spans ends the open fare: the ride starts a new one and the leg says why.
  The reference's "when one rule matches repeatedly, the clock runs starting from
  the first matched leg" is why a change limit is measured against the first leg of
  the open fare rather than against the previous leg.

  A `difference` rule whose product has no row for this rider and medium falls
  back to this ride's own fare and reports a problem, because a journey must never
  total less than the ride that priced it — the undercharge R6 exists to prevent.

  ## Passes

  `passes` lists the pass products the leg rules name for *every* leg of the
  journey, priced for the rider and medium, with what buying the pass instead would
  save. A pass is a product whose `fare_product_details` row says `pass`, so an
  imported version with no detail rows lists no passes. That is a limit of reading
  kind from the editor's own facts, not a price.

  ## Known ceilings

  - A stop in more than one area is read as its first area, and a leg no rule covers
    that way is reported as unpriced rather than priced from another area.
  - A leg without a departure or arrival time is not measured against a change's
    duration limit, because the reference's clock has no endpoint to measure.
  - Pass coverage is a rule match, not a record of what a rider already bought.
  """

  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows
  alias GtfsPlanner.Gtfs.Fares.Money

  # `fare_transfer_type`: the fare already paid plus the transfer product, plus
  # this ride's own fare, or the transfer product alone.
  @a_plus_transfer 0
  @a_plus_transfer_and_ride 1
  @transfer_product 2

  # `duration_limit_type`: which endpoints of the open fare the clock runs between.
  @first_departure_to_last_arrival 0
  @departure_to_departure 1
  @first_arrival_to_last_departure 2

  @pass "pass"

  @default_currency "USD"
  @zero Decimal.new(0)
  @seconds_per_minute 60

  # A `transfer_count` of `-1`, or none at all, spans every transfer, so it is
  # ranked after every bounded count when the reference asks for the minimum count
  # that still covers the current transfer.
  @unlimited_count 1_000_000_000

  @doc """
  Prices one journey and explains every ride in it.

  See the module doc for the result's shape. `total` is `nil` when any ride is
  unpriced, which is also when `passes` is empty.

  A leg's fields are read by either key kind, so a journey saved as
  `fare_saved_journeys.legs` — which comes back from `jsonb` with string keys —
  prices exactly as the one the editor priced did.
  """
  @spec price_journey(Rows.t(), map()) :: %{
          total: Decimal.t() | nil,
          legs: [map()],
          passes: [map()],
          problems: [String.t()]
        }
  def price_journey(%Rows{} = rows, journey) do
    catalog = catalog(rows, journey)

    {priced, leg_problems} =
      journey
      |> Map.get(:legs, [])
      |> Enum.map(&atomize_leg/1)
      |> Enum.with_index(1)
      |> Enum.map_reduce([], &price_leg(&1, &2, rows, catalog))
      |> then(fn {legs, problems} -> {legs, Enum.reverse(problems)} end)

    {legs, running, state} = fold_transfers(priced, catalog)

    total = if Enum.all?(legs, & &1.known?), do: running, else: nil

    %{
      total: total,
      legs: legs,
      passes: covering_passes(legs, catalog, total),
      problems: leg_problems ++ state.problems
    }
  end

  # The fields one leg carries, which are the keys `fare_saved_journeys.legs`
  # stores and the only keys renamed when it comes back from `jsonb` as strings.
  @leg_fields [:route_id, :from_stop_id, :to_stop_id, :departs, :arrives]

  # A leg read back from `fare_saved_journeys.legs` carries string keys, which
  # `jsonb` gives every key it stores. The fields are read by atom key below, so
  # the string-keyed half is renamed here rather than in each read, and only for
  # the fields a leg holds: a key this module has no atom for is left alone.
  defp atomize_leg(leg) when is_map(leg) do
    Enum.reduce(@leg_fields, leg, fn field, acc ->
      case Map.fetch(acc, Atom.to_string(field)) do
        {:ok, value} -> acc |> Map.delete(Atom.to_string(field)) |> Map.put(field, value)
        :error -> acc
      end
    end)
  end

  defp atomize_leg(leg), do: leg

  # One leg, priced on its own: the network, the areas, the rules, the fare. The
  # change that may apply to it is worked out in `fold_transfers/2`, which needs
  # every leg's fare first.
  defp price_leg({leg, index}, problems, rows, catalog) do
    route_id = Map.get(leg, :route_id)
    from_stop_id = Map.get(leg, :from_stop_id)
    to_stop_id = Map.get(leg, :to_stop_id)
    departs = Map.get(leg, :departs)
    arrives = Map.get(leg, :arrives)
    network_id = Interpreter.network_for_route(rows, route_id)
    from_area_id = stop_area(rows, from_stop_id)
    to_area_id = stop_area(rows, to_stop_id)

    rules =
      Interpreter.leg_rules(
        rows,
        network_id,
        from_area_id,
        to_area_id,
        active_timeframes(rows, catalog.service_date, departs)
      )

    base = %{
      index: index,
      route_id: route_id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      departs: departs,
      arrives: arrives,
      network_id: network_id,
      leg_group_id: leg_group(rules),
      from_area_id: from_area_id,
      to_area_id: to_area_id,
      product_ids: Enum.map(rules, & &1.fare_product_id),
      product_id: nil,
      product_name: nil,
      full: nil,
      currency: @default_currency,
      known?: false,
      reason: nil,
      charged: @zero,
      running_total: @zero,
      transfer: nil
    }

    put_fare(base, rules, catalog, problems)
  end

  # A stop's first area, which is the one its leg is matched on. A stop in no area
  # is `nil`, which is how a leg rule with an empty area reads it.
  defp stop_area(rows, stop_id) do
    rows.stop_areas
    |> Map.get(stop_id, [])
    |> Enum.find(&(not blank?(&1)))
  end

  defp active_timeframes(rows, %Date{} = date, departs) when is_integer(departs) and departs >= 0,
    do: Interpreter.active_timeframes(rows, date, departs)

  defp active_timeframes(_rows, _date, _departs), do: []

  # Every rule that matched prices the same leg group in a managed version, where
  # `leg_group_id` is the rule's network (R3). The first is read when an imported
  # version's rules disagree, and the disagreement is the check tab's
  # `ride_with_two_fares` condition rather than a price.
  defp leg_group([]), do: nil

  defp leg_group(rules) do
    rules
    |> Enum.map(& &1.leg_group_id)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> List.first()
  end

  # The ride's own fare, chosen among the single-ride products the rules name.
  defp put_fare(leg, [], _catalog, problems) do
    problem =
      "No fare covers Route #{leg.route_id} from #{area(leg.from_area_id)} to #{area(leg.to_area_id)}."

    {%{leg | reason: problem}, [problem | problems]}
  end

  defp put_fare(leg, _rules, catalog, problems) do
    case choose_fare(leg.product_ids, catalog) do
      {:ok, product} ->
        {%{
           leg
           | product_id: product.fare_product_id,
             product_name: product_name(product),
             full: product.amount,
             currency: product.currency || @default_currency,
             known?: true
         }, problems}

      :none ->
        product_id = single_product_id(leg.product_ids, catalog)
        problem = not_sold_reason(product_id, catalog)

        {%{leg | product_id: product_id, reason: problem}, [problem | problems]}
    end
  end

  defp choose_fare(product_ids, catalog) do
    product_ids
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(catalog.kinds, &1) != @pass))
    |> Enum.map(&fare_row(&1, catalog))
    |> Enum.flat_map(fn
      {:ok, product} -> [product]
      :none -> []
    end)
    |> case do
      [] -> :none
      products -> {:ok, Enum.min_by(products, &Decimal.to_float(&1.amount))}
    end
  end

  defp single_product_id(product_ids, catalog) do
    product_ids
    |> Enum.uniq()
    |> Enum.find(&(Map.get(catalog.kinds, &1) != @pass))
  end

  # One product row for a rider and medium, preferring the exact pair, then the row
  # with no medium, then the row with no rider category.
  defp fare_row(product_id, catalog) do
    {rider_category_id, fare_media_id} = catalog.request

    [
      {product_id, rider_category_id, fare_media_id},
      {product_id, rider_category_id, nil},
      {product_id, nil, fare_media_id},
      {product_id, nil, nil}
    ]
    |> Enum.find_value(fn key -> Map.get(catalog.products, key) end)
    |> case do
      nil -> :none
      product -> {:ok, product}
    end
  end

  # The changes, in order. Every leg after the first either continues the open fare
  # under the rule that matched, or starts a new one and says why.
  defp fold_transfers(priced, catalog) do
    {legs, state} =
      Enum.map_reduce(
        priced,
        %{total: @zero, chain: nil, problems: []},
        &apply_change(&1, &2, catalog)
      )

    {legs, running_total(state), state}
  end

  # An unpriced ride is not a fare, so the open one is left exactly as it was and
  # the whole journey stays unpriced.
  defp apply_change(%{known?: false} = leg, state, _catalog) do
    {%{leg | charged: @zero, running_total: running_total(state)}, state}
  end

  defp apply_change(%{index: 1} = leg, state, catalog),
    do: open_new_fare(leg, state, catalog, nil, nil)

  # A journey whose first ride could not be priced has no open fare to continue, so
  # this ride opens one; the journey still totals nothing.
  defp apply_change(leg, %{chain: nil} = state, catalog),
    do: open_new_fare(leg, state, catalog, not_applied_transfer(), no_open_fare_reason())

  defp apply_change(leg, state, catalog) do
    chain = state.chain
    transfer_count = chain.transfers + 1
    rules = transfer_rules(catalog.transfer_rules, chain.leg_group_id, leg.leg_group_id)

    case pick_rule(Enum.filter(rules, &covers_count?(&1, transfer_count))) do
      nil ->
        open_new_fare(
          leg,
          state,
          catalog,
          not_applied_transfer(),
          no_rule_reason(chain, leg, rules, transfer_count, catalog)
        )

      rule ->
        elapsed = elapsed(chain, leg, rule.duration_limit_type)

        if limit_passed?(rule, elapsed) do
          open_new_fare(
            leg,
            state,
            catalog,
            transfer(rule, elapsed, false),
            too_late_reason(rule, elapsed)
          )
        else
          continue_fare(leg, rule, chain, elapsed, state, catalog)
        end
    end
  end

  # A ride that opens a fare closes whatever was open before it: the closed amount
  # joins `total` and the new ride's own fare becomes the open fare, so no fare is
  # counted twice in the running total.
  defp open_new_fare(leg, state, catalog, transfer, prefix) do
    closed = running_total(state)
    running = Decimal.add(closed, leg.full)

    leg = %{
      leg
      | charged: leg.full,
        reason: join_reason(prefix, ride_reason(leg, catalog)),
        running_total: running,
        transfer: transfer
    }

    {leg, %{state | total: closed, chain: open_fare(leg)}}
  end

  # The change the transfer rules were read for, whether or not the rule was
  # allowed. A leg carrying it is a leg whose fare was read against them, and the
  # check tab shows the reason either way.
  defp transfer(rule, elapsed, applied?) do
    rule = rule || %{}

    %{
      applied?: applied?,
      from_leg_group_id: Map.get(rule, :from_leg_group_id),
      to_leg_group_id: Map.get(rule, :to_leg_group_id),
      fare_transfer_type: Map.get(rule, :fare_transfer_type),
      transfer_count: Map.get(rule, :transfer_count),
      duration_limit: Map.get(rule, :duration_limit),
      product_id: Map.get(rule, :fare_product_id),
      elapsed_seconds: elapsed
    }
  end

  defp not_applied_transfer, do: transfer(nil, nil, false)

  defp no_open_fare_reason,
    do: "The ride before it could not be priced, so there was no fare to continue"

  # The fare already paid, its leg group, the endpoints any change limit is measured
  # from, and how many changes it has already covered.
  defp open_fare(leg) do
    %{
      amount: leg.full,
      leg_group_id: leg.leg_group_id,
      first_departure: leg.departs,
      first_arrival: leg.arrives,
      transfers: 0
    }
  end

  # The open fare continues, and `fare_transfer_type` says what the change costs.
  defp continue_fare(leg, rule, chain, elapsed, state, catalog) do
    transfer = transfer(rule, elapsed, true)

    case change_charge(leg, rule, chain, catalog) do
      {:ok, amount, reason} ->
        leg = %{
          leg
          | charged: amount,
            reason: reason,
            transfer: transfer,
            running_total: Decimal.add(state.total, Decimal.add(chain.amount, amount))
        }

        chain = %{
          chain
          | amount: Decimal.add(chain.amount, amount),
            transfers: chain.transfers + 1
        }

        {leg, %{state | chain: chain}}

      {:unpriced, reason} ->
        # Charging the ride's own fare is the more expensive reading, which keeps a
        # journey from totalling less than the rides that priced it.
        problem = not_sold_reason(rule.fare_product_id, catalog)

        leg = %{
          leg
          | charged: leg.full,
            reason: reason,
            transfer: transfer,
            running_total: Decimal.add(state.total, Decimal.add(chain.amount, leg.full))
        }

        chain = %{
          chain
          | amount: Decimal.add(chain.amount, leg.full),
            transfers: chain.transfers + 1
        }

        {leg, %{state | chain: chain, problems: [problem | state.problems]}}
    end
  end

  # `0` adds the transfer product to the fare already paid, `1` adds this ride's
  # own fare, and `2` leaves the transfer product as the whole fare.
  defp change_charge(leg, rule, chain, catalog) do
    product = transfer_product(rule, catalog)

    case {rule.fare_transfer_type, product} do
      {@a_plus_transfer, nil} ->
        {:ok, @zero, free_transfer_reason(rule, chain, catalog)}

      {@a_plus_transfer, product} ->
        {:ok, product.amount, transfer_fee_reason(rule, product, catalog)}

      {@a_plus_transfer_and_ride, _product} ->
        {:ok, leg.full,
         own_fare_reason(rule, chain, catalog) <> ". " <> ride_reason(leg, catalog)}

      {@transfer_product, nil} ->
        {:unpriced,
         own_fare_reason(rule, chain, catalog) <> ", because its product is not priced"}

      {@transfer_product, product} ->
        {:ok, Decimal.sub(product.amount, chain.amount),
         difference_reason(product, chain, catalog)}
    end
  end

  defp transfer_product(%{fare_product_id: nil}, _catalog), do: nil

  defp transfer_product(rule, catalog) do
    case fare_row(rule.fare_product_id, catalog) do
      {:ok, product} -> product
      :none -> nil
    end
  end

  # The rules for one ordered pair of leg groups: the exact pair, and only where
  # there is none the rows with an empty value, which the reference reads as every
  # leg group. A managed version names the pair on every row (R5), so the empty
  # reading is there for imported rows.
  defp transfer_rules(rules, from_leg_group_id, to_leg_group_id) do
    exact =
      Enum.filter(rules, fn rule ->
        presence(rule.from_leg_group_id) == presence(from_leg_group_id) and
          presence(rule.to_leg_group_id) == presence(to_leg_group_id)
      end)

    if exact == [] do
      Enum.filter(rules, fn rule ->
        matches_group?(rule.from_leg_group_id, from_leg_group_id) and
          matches_group?(rule.to_leg_group_id, to_leg_group_id)
      end)
    else
      exact
    end
  end

  defp matches_group?(rule_leg_group_id, leg_group_id) do
    blank?(rule_leg_group_id) or presence(rule_leg_group_id) == presence(leg_group_id)
  end

  # "The minimum `transfer_count` that is greater than or equal to the current
  # transfer count" applies; among those the longest change window, so a feed that
  # states two limits for one count is read as the more generous one.
  defp pick_rule([]), do: nil

  defp pick_rule(rules) do
    Enum.min_by(rules, &{count_limit(&1), -(Map.get(&1, :duration_limit) || 0)})
  end

  defp covers_count?(rule, transfer_count), do: count_limit(rule) >= transfer_count

  defp count_limit(%{transfer_count: nil}), do: @unlimited_count
  defp count_limit(%{transfer_count: count}) when count < 0, do: @unlimited_count
  defp count_limit(%{transfer_count: count}), do: count

  # The clock the change limit is measured over. A leg without the times the type
  # names cannot be measured, and a limit that cannot be shown to have passed does
  # not end the fare.
  defp elapsed(chain, leg, @first_departure_to_last_arrival),
    do: difference(leg.arrives, chain.first_departure)

  defp elapsed(chain, leg, @departure_to_departure),
    do: difference(leg.departs, chain.first_departure)

  defp elapsed(chain, leg, @first_arrival_to_last_departure),
    do: difference(leg.departs, chain.first_arrival)

  defp elapsed(chain, leg, _to_arrival),
    do: difference(leg.arrives, chain.first_arrival)

  defp difference(nil, _from), do: nil
  defp difference(_to, nil), do: nil
  defp difference(to, from), do: to - from

  defp limit_passed?(%{duration_limit: nil}, _elapsed), do: false
  defp limit_passed?(_rule, nil), do: false
  defp limit_passed?(%{duration_limit: limit}, elapsed), do: elapsed > limit

  defp chain_amount(nil), do: @zero
  defp chain_amount(chain), do: chain.amount

  defp running_total(state), do: Decimal.add(state.total, chain_amount(state.chain))

  # The pass products the leg rules name for every leg of the journey, priced for
  # this rider and medium. A journey with an unpriced ride lists none, because a
  # pass that covers rides nobody can price covers nothing here.
  defp covering_passes([], _catalog, _total), do: []

  defp covering_passes(legs, catalog, total) do
    if Enum.all?(legs, & &1.known?) do
      legs
      |> hd()
      |> Map.fetch!(:product_ids)
      |> Enum.filter(fn product_id ->
        Map.get(catalog.kinds, product_id) == @pass and
          Enum.all?(legs, &(&1.product_id == product_id or product_id in &1.product_ids))
      end)
      |> Enum.map(&fare_row(&1, catalog))
      |> Enum.flat_map(fn
        {:ok, product} ->
          [
            %{
              fare_product_id: product.fare_product_id,
              name: product_name(product),
              amount: product.amount,
              currency: product.currency || @default_currency,
              saves: Decimal.sub(total, product.amount)
            }
          ]

        :none ->
          []
      end)
    else
      []
    end
  end

  # What one ride's own fare is, in the words the Checks tab shows.
  defp ride_reason(leg, catalog) do
    "Route #{leg.route_id} is on #{group(leg.network_id, catalog)}; the ride from " <>
      "#{area(leg.from_area_id)} to #{area(leg.to_area_id)} pays #{leg.product_name}, " <>
      "#{money(leg.full, leg.currency)}"
  end

  defp free_transfer_reason(rule, _chain, catalog) do
    "Free transfer from #{group(rule.from_leg_group_id, catalog)} to " <>
      "#{group(rule.to_leg_group_id, catalog)}#{window_phrase(rule)}"
  end

  defp transfer_fee_reason(rule, product, catalog) do
    "Transfer fee of #{money(product.amount, product.currency)} from " <>
      "#{group(rule.from_leg_group_id, catalog)} to #{group(rule.to_leg_group_id, catalog)}"
  end

  defp own_fare_reason(rule, _chain, catalog) do
    "The change from #{group(rule.from_leg_group_id, catalog)} to " <>
      "#{group(rule.to_leg_group_id, catalog)} is priced on its own#{window_phrase(rule)}"
  end

  defp difference_reason(product, chain, _catalog) do
    "Pays the difference: #{product_name(product)} at #{money(product.amount, product.currency)} " <>
      "replaces the #{money(chain.amount, product.currency || @default_currency)} already paid"
  end

  # No rule for the pair at all, and the change count the rules do allow when there
  # are rules but none of them spans this change.
  defp no_rule_reason(chain, leg, [], _transfer_count, catalog) do
    "No transfer rule from #{group(chain.leg_group_id, catalog)} to " <>
      "#{group(leg.leg_group_id, catalog)}"
  end

  defp no_rule_reason(chain, leg, rules, transfer_count, catalog) do
    change = "change #{transfer_count}"
    allowed = rules |> Enum.map(&count_limit/1) |> Enum.min()
    allowed = if allowed == @unlimited_count, do: "no limit on", else: "only #{allowed} free"

    "Change #{transfer_count} from #{group(chain.leg_group_id, catalog)} to " <>
      "#{group(leg.leg_group_id, catalog)} when the rule allows #{allowed} #{plural_word(change)}"
  end

  defp plural_word("change 1"), do: "change"
  defp plural_word(_change), do: "changes"

  defp too_late_reason(rule, elapsed) do
    "Past the #{minutes(rule.duration_limit)}-minute limit on this change " <>
      "(#{minutes(elapsed)} minutes after the first boarding)"
  end

  # The reference reads a `transfer_count` as a limit of free changes, and a rule
  # that allows none as a paid change, so both read as changes here.
  defp window_phrase(%{duration_limit: nil, transfer_count: nil}), do: ""

  defp window_phrase(rule) do
    windows =
      []
      |> then(
        &if rule.duration_limit,
          do: ["the #{minutes(rule.duration_limit)}-minute limit" | &1],
          else: &1
      )
      |> then(
        &if rule.transfer_count,
          do: [
            "#{rule.transfer_count} free #{plural(rule.transfer_count, "change", "changes")}" | &1
          ],
          else: &1
      )
      |> Enum.reverse()

    ", within " <> Enum.join(windows, " and ")
  end

  defp not_sold_reason(nil, _catalog),
    do: "No single-ride fare covers this ride for this rider and payment method."

  defp not_sold_reason(product_id, catalog) do
    "#{Map.get(catalog.product_name, product_id) || fare_label(product_id)} is not sold to " <>
      "#{catalog.rider_label} on #{catalog.media_label}."
  end

  defp join_reason(nil, reason), do: reason
  defp join_reason(prefix, reason), do: "#{prefix}, so this is a new fare: #{reason}"

  defp area(nil), do: "no area"
  defp area(area_id), do: area_id

  defp group(nil, _catalog), do: "no route group"

  defp group(leg_group_id, catalog),
    do: Map.get(catalog.network_name, leg_group_id) || leg_group_id

  defp money(nil, _currency), do: "no price"
  defp money(amount, currency), do: Money.format(amount, currency || @default_currency)

  defp product_name(product) do
    presence(Map.get(product, :fare_product_name)) || presence(Map.get(product, :fare_product_id)) ||
      "this fare"
  end

  defp fare_label(product_id), do: presence(product_id) || "This fare"

  defp minutes(seconds), do: div(seconds, @seconds_per_minute)

  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many

  defp label(present, id, fallback) do
    cond do
      present -> Map.get(present, id) || id
      is_binary(id) -> id
      true -> fallback
    end
  end

  # Everything the pricing reads once per journey: the products keyed the way a
  # rider and medium find one, each product's kind, and the names the explanations
  # use.
  defp catalog(rows, journey) do
    rider_category_id = presence(Map.get(journey, :rider_category_id))
    fare_media_id = presence(Map.get(journey, :fare_media_id))

    %{
      request: {rider_category_id, fare_media_id},
      service_date: Map.get(journey, :service_date),
      products: Map.new(rows.fare_products, &{fare_key(&1), &1}),
      product_name:
        Map.new(rows.fare_products, &{presence(&1.fare_product_id), &1.fare_product_name}),
      kinds: Map.new(rows.fare_product_details, &{presence(&1.fare_product_id), &1.kind}),
      rider_label: label(rider_names(rows), rider_category_id, "any rider type"),
      media_label: label(media_names(rows), fare_media_id, "any payment method"),
      network_name: Map.new(rows.networks, &{presence(&1.network_id), &1.network_name}),
      transfer_rules: rows.fare_transfer_rules
    }
  end

  defp fare_key(product) do
    {presence(product.fare_product_id), presence(product.rider_category_id),
     presence(product.fare_media_id)}
  end

  defp rider_names(rows) do
    Map.new(rows.rider_categories, &{presence(&1.rider_category_id), &1.rider_category_name})
  end

  defp media_names(rows) do
    Map.new(rows.fare_media, &{presence(&1.fare_media_id), &1.fare_media_name})
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_other), do: false

  defp presence(value) do
    if blank?(value), do: nil, else: String.trim(value)
  end
end
