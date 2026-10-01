defmodule GtfsPlanner.Gtfs.Fares.Normalize do
  @moduledoc """
  The one writer of a managed version's implied fare rows (R3–R5, R8).

  A managed version stores what an operator edits and rebuilds what that edit
  implies. Priorities, leg groups, pass rows and a difference rule's product are
  implied by the rules themselves, so they are written here and nowhere else
  (INV-4): `Fares.Interpreter` reads the same columns and never writes them, and
  no `Fares` writer or LiveView sets them directly.

  `run!/2` must be called inside `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3`,
  by every writer that changed the version's rules, products or rider categories.
  It is deliberately not wrapped in a transaction of its own: the writes belong to
  the caller's one write, and a caller that ran Normalize outside the lock would
  normalize a version another writer may be holding. The steps, in order:

  1. every non-pass leg rule gets `rule_priority` per R3
     (`8·[from_timeframe_group_id] + 4·[network_id] + 2·[from_area_id] +
     1·[to_area_id]`), a nil `to_timeframe_group_id` and a `leg_group_id` of its
     `network_id`, or `"all_routes"` when that is nil;
  2. the version's pass rows — the leg rules naming a product whose
     `fare_product_details.kind` is `"pass"` — are deleted, and one row per
     accepting network and condition set is written back;
  3. each `fare_transfer_type = 2` row names the destination leg group's
     single-ride product again, so a price edit cannot leave a difference rule
     pointing at a product that no longer applies;
  4. a version with rider categories must leave exactly one default, or
     `GtfsPlanner.Gtfs.Fares.InvariantError` raises and the caller's transaction
     rolls back.

  ## Why pass rows are one per condition and not one per row

  R4 mirrors each single-ride row, and the reference only offers the rules at the
  top priority, so a pass row has to tie with the single-ride rows it stands in
  for. Two single-ride rows that differ only by rider category state the same
  conditions and the same priority, so mirroring them one for one would write the
  same pass row two, four or eight times over. Pass rows are therefore one per
  condition set — `(network_id, from_area_id, to_area_id,
  from_timeframe_group_id)` — of an accepting network, which is the smallest set
  of rows that still ties with every single-ride row at that cell, and which keeps
  a rider's pass out of the other riders' cells of the same zone pair.

  Pass rows multiply: accepted networks × zones² × passes, which is PM-8's growth
  and its ceiling of about 300 rows for the sample. Conversion refuses a version
  whose domain is larger than its own `@max_domain`, and that refusal — not a
  count checked here — is what keeps a normalize run bounded; this rebuild has no
  independent row limit to enforce.

  Every read and write here is filtered by `organization_id` and
  `gtfs_version_id` together (INV-5), so normalizing one version never touches a
  row of another.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares.InvariantError
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Repo

  # R4's name for the leg rules whose `network_id` is nil.
  @all_routes "all_routes"

  # R5's "pays the difference", the only transfer type whose product Normalize owns.
  @difference_type 2

  @from_timeframe_weight 8
  @network_weight 4
  @from_area_weight 2
  @to_area_weight 1

  @pass_kind "pass"

  @doc """
  The `rule_priority` `run!/2` gives a leg rule with these conditions (R3).

  `conditions` is a map or struct carrying `from_timeframe_group_id`,
  `network_id`, `from_area_id` and `to_area_id`, and an empty value counts as
  absent. `run!/2` is the only writer of the column (INV-4); this function is
  the one place its value is worked out, so a caller that has to reason about a
  leg rule before the row exists — `Fares.Conversion`'s price-equivalence check
  prices proposed rows that `run!/2` has not written yet — reads it here rather
  than repeating R3's weights.
  """
  @spec priority(map()) :: integer()
  def priority(conditions), do: conditions_priority(conditions)

  @doc """
  The leg group R3 gives a leg rule: its own network, or `"all_routes"` when it
  names none.

  `run!/2` is the only writer of `leg_group_id` (INV-4); this is the one place
  its value is worked out, so `Fares.Conversion` can state the rows a conversion
  will produce before they exist.
  """
  @spec leg_group_id(map()) :: String.t()
  def leg_group_id(rule), do: accepted_network_id(rule)

  @doc """
  The condition sets a pass mirrors for the leg groups it accepts (R4).

  `rules` are the version's non-pass leg rules and `accepted` a pass's
  `accepted_network_ids`. The answer is the distinct, sorted
  `{network_id, from_area_id, to_area_id, from_timeframe_group_id}` sets of the
  rules whose leg group the pass accepts, which is the one place `run!/2` derives
  the same list when it rebuilds a pass's rows — a caller that has to state
  those rows before they are written reads them here.
  """
  @spec mirrored_condition_sets([map()], [String.t()]) :: [tuple()]
  def mirrored_condition_sets(rules, accepted) do
    rules
    |> Enum.filter(&(accepted_network(&1) in accepted))
    |> Enum.map(&{&1.network_id, &1.from_area_id, &1.to_area_id, &1.from_timeframe_group_id})
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Rewrites the version's implied fare rows and returns `:ok`.

  Raises `GtfsPlanner.Gtfs.Fares.InvariantError` when the version's rider
  categories do not leave exactly one default, which rolls the caller's
  transaction back. Every other write is scoped to this organization and version.
  """
  @spec run!(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def run!(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    pass_ids = pass_product_ids(organization_id, gtfs_version_id)
    rules = scoped_rules(organization_id, gtfs_version_id)

    rewrite_leg_rules(rules, pass_ids)
    rebuild_pass_rows(organization_id, gtfs_version_id, rules, pass_ids)
    refresh_difference_products(organization_id, gtfs_version_id, rules, pass_ids)
    ensure_one_default_rider_category(organization_id, gtfs_version_id)

    :ok
  end

  # R3: the priority is a function of the row's conditions, so rows that already
  # carry it are left alone and keep their `updated_at`.
  defp rewrite_leg_rules(rules, pass_ids) do
    now = DateTime.utc_now()

    for rule <- rules,
        not MapSet.member?(pass_ids, rule.fare_product_id),
        changed?(rule) do
      organization_id = rule.organization_id
      gtfs_version_id = rule.gtfs_version_id
      rule_id = rule.id
      rule_priority = priority(rule)
      group_id = leg_group(rule)

      from(r in FareLegRule,
        where:
          r.id == ^rule_id and r.organization_id == ^organization_id and
            r.gtfs_version_id == ^gtfs_version_id
      )
      |> Repo.update_all(
        set: [
          rule_priority: rule_priority,
          leg_group_id: group_id,
          to_timeframe_group_id: nil,
          updated_at: now
        ]
      )
    end
  end

  defp changed?(rule) do
    rule.rule_priority != priority(rule) or rule.leg_group_id != leg_group(rule) or
      not is_nil(rule.to_timeframe_group_id)
  end

  # R4. The rows to mirror are the single-ride rows — every rule that does not
  # name a pass product — reduced to their condition sets, and each pass only
  # mirrors the sets whose network it accepts.
  defp rebuild_pass_rows(organization_id, gtfs_version_id, rules, pass_ids) do
    delete_pass_rows(organization_id, gtfs_version_id, pass_ids)

    now = DateTime.utc_now()

    pass_rows =
      for {fare_product_id, accepted} <- accepted_networks(organization_id, gtfs_version_id),
          {network_id, from_area_id, to_area_id, timeframe} <-
            mirrored_conditions(rules, pass_ids, accepted) do
        pass_row(
          organization_id,
          gtfs_version_id,
          fare_product_id,
          %{
            network_id: network_id,
            from_area_id: from_area_id,
            to_area_id: to_area_id,
            from_timeframe_group_id: timeframe
          },
          now
        )
      end

    FareLegRule |> Repo.insert_all(pass_rows)

    :ok
  end

  defp delete_pass_rows(organization_id, gtfs_version_id, pass_ids) do
    case MapSet.to_list(pass_ids) do
      [] ->
        :ok

      product_ids ->
        Repo.delete_all(
          from(r in FareLegRule,
            where:
              r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
                r.fare_product_id in ^product_ids
          )
        )
    end
  end

  defp mirrored_conditions(rules, pass_ids, accepted) do
    rules
    |> Enum.reject(&MapSet.member?(pass_ids, &1.fare_product_id))
    |> mirrored_condition_sets(accepted)
  end

  defp pass_row(organization_id, gtfs_version_id, fare_product_id, conditions, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      leg_group_id: accepted_network_id(conditions),
      network_id: conditions.network_id,
      from_area_id: conditions.from_area_id,
      to_area_id: conditions.to_area_id,
      from_timeframe_group_id: conditions.from_timeframe_group_id,
      to_timeframe_group_id: nil,
      fare_product_id: fare_product_id,
      rule_priority: priority(conditions),
      inserted_at: now,
      updated_at: now
    }
  end

  # R5's refresh. The rule keeps naming its product while that product is still
  # one of the destination group's single rides; otherwise the destination's
  # product for the version's default rider type is named, and failing that the
  # destination's first product by the operator's own grid order. A difference
  # rule whose destination has no single-ride product keeps the value it has,
  # because a type 2 row naming nothing is worse than one naming a product the
  # Checks tab can report: `Fares.Pricing` falls back to the ride's own fare and
  # says so.
  defp refresh_difference_products(organization_id, gtfs_version_id, rules, pass_ids) do
    now = DateTime.utc_now()

    for rule <- difference_rules(organization_id, gtfs_version_id),
        candidates = destination_products(rules, pass_ids, rule.to_leg_group_id),
        candidates != [],
        product_id = difference_product(rule, candidates, organization_id, gtfs_version_id),
        rule.fare_product_id != product_id do
      rule_id = rule.id

      from(t in FareTransferRule,
        where:
          t.id == ^rule_id and t.organization_id == ^organization_id and
            t.gtfs_version_id == ^gtfs_version_id
      )
      |> Repo.update_all(set: [fare_product_id: product_id, updated_at: now])
    end

    :ok
  end

  defp difference_rules(organization_id, gtfs_version_id) do
    from(t in FareTransferRule,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
          t.fare_transfer_type == ^@difference_type
    )
    |> Repo.all()
  end

  defp destination_products(rules, pass_ids, to_leg_group_id) do
    for rule <- rules,
        not MapSet.member?(pass_ids, rule.fare_product_id),
        leg_group(rule) == to_leg_group_id do
      rule.fare_product_id
    end
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp difference_product(rule, candidates, organization_id, gtfs_version_id) do
    cond do
      rule.fare_product_id in candidates ->
        rule.fare_product_id

      default_id = default_rider_category_id(organization_id, gtfs_version_id) ->
        candidates
        |> Enum.find(&(default_id in rider_categories_of(&1, organization_id, gtfs_version_id))) ||
          Enum.min_by(candidates, &{grid_position(&1, organization_id, gtfs_version_id), &1})

      true ->
        Enum.min_by(candidates, &{grid_position(&1, organization_id, gtfs_version_id), &1})
    end
  end

  defp grid_position(fare_product_id, organization_id, gtfs_version_id) do
    case Repo.one(
           from(d in FareProductDetail,
             where:
               d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id and
                 d.fare_product_id == ^fare_product_id,
             select: d.position
           )
         ) do
      nil -> 0
      position -> position
    end
  end

  defp rider_categories_of(fare_product_id, organization_id, gtfs_version_id) do
    from(p in FareProduct,
      where:
        p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id and
          p.fare_product_id == ^fare_product_id,
      select: p.rider_category_id,
      distinct: true
    )
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
  end

  defp default_rider_category_id(organization_id, gtfs_version_id) do
    from(c in RiderCategory,
      where:
        c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id and
          c.is_default_fare_category == 1,
      order_by: c.rider_category_id,
      limit: 1,
      select: c.rider_category_id
    )
    |> Repo.one()
  end

  # R8. A version with no rider categories at all is not this rule's case, so it
  # passes; one with categories must leave exactly one default.
  defp ensure_one_default_rider_category(organization_id, gtfs_version_id) do
    categories = scoped_rider_categories(organization_id, gtfs_version_id)
    defaults = Enum.count(categories, &(&1.is_default_fare_category == 1))

    if categories != [] and defaults != 1 do
      raise InvariantError,
            "version #{gtfs_version_id} has #{length(categories)} rider categories " <>
              "and #{defaults} of them are the default; a managed version needs exactly one"
    end

    :ok
  end

  defp scoped_rider_categories(organization_id, gtfs_version_id) do
    from(c in RiderCategory,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  defp pass_product_ids(organization_id, gtfs_version_id) do
    from(d in FareProductDetail,
      where:
        d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id and
          d.kind == ^@pass_kind,
      select: d.fare_product_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp accepted_networks(organization_id, gtfs_version_id) do
    from(d in FareProductDetail,
      where:
        d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id and
          d.kind == ^@pass_kind,
      order_by: d.fare_product_id,
      select: {d.fare_product_id, d.accepted_network_ids}
    )
    |> Repo.all()
  end

  defp scoped_rules(organization_id, gtfs_version_id) do
    from(r in FareLegRule,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: r.network_id, asc: r.from_area_id, asc: r.to_area_id]
    )
    |> Repo.all()
  end

  defp conditions_priority(conditions) do
    weight(conditions.from_timeframe_group_id, @from_timeframe_weight) +
      weight(conditions.network_id, @network_weight) +
      weight(conditions.from_area_id, @from_area_weight) +
      weight(conditions.to_area_id, @to_area_weight)
  end

  defp weight(nil, _points), do: 0
  defp weight("", _points), do: 0
  defp weight(_value, points), do: points

  # R3's leg groups are per route group, so a rule's group is its network, and a
  # rule with no network is the `all_routes` group.
  defp leg_group(rule), do: accepted_network_id(rule)

  defp accepted_network_id(%{network_id: nil}), do: @all_routes
  defp accepted_network_id(%{network_id: ""}), do: @all_routes
  defp accepted_network_id(%{network_id: network_id}), do: network_id

  # The name a pass must accept for a rule: its leg group, which is the same
  # string the editor lists in `accepted_network_ids`.
  defp accepted_network(rule), do: leg_group(rule)
end
