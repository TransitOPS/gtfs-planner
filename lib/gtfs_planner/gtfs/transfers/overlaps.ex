defmodule GtfsPlanner.Gtfs.Transfers.Overlaps do
  @moduledoc """
  Pure R6 evaluator for witnessed equal-specificity competition between general
  transfer rules.

  Two general rules compete when one actual trip pair is served by both of them,
  both carry the best (lowest) GTFS rank among the general rules that apply to
  that pair, and their effects differ. A witness is an arrival trip with a
  `stop_time` at a stop both rules' `from` coverage contains together with a
  departure trip with a `stop_time` at a stop both rules' `to` coverage contains,
  so opposite directions and rule pairs whose coverage does not overlap never
  compete. Several better rules can shadow one witness between them; no single
  shadowing rule has to cover the whole intersection.

  `rank/1` reads the four selector keys of any map or struct, so a stored
  `GtfsPlanner.Gtfs.Transfer` needs no adaptation. `evaluate/2` consumes the
  stop_time incidence it is given and returns rule ids only; it never touches a
  repository, and catalog reads re-evaluate it rather than caching a verdict.
  `witnesses/2` is the same evaluation reported as the concrete stop and trip of
  each disagreeing pair, which is what a reviewed policy change shows the editor
  and what `evaluate/2` is derived from.

  Cost is the sum over rules of the (from stop x from class x to stop x to class)
  witnesses one rule applies to: the per-leaf class index collapses trips that are
  interchangeable for every rule covering that leaf, and the six-field key
  uniqueness bounds how many broad rules can share one stop pair. The upgrade path
  for a rule set far beyond NFR 5.1 is to index rules by their per-leaf selectors
  instead of scanning the rule list once per leaf.
  `test/support/transfer_overlap_oracle.ex` re-derives the same verdict from the
  GTFS text for every concrete trip pair, and EV-13 measures the end-to-end budget.
  """

  @type rule :: %{
          id: term(),
          from_coverage: [String.t()],
          to_coverage: [String.t()],
          from_route_id: String.t() | nil,
          to_route_id: String.t() | nil,
          from_trip_id: String.t() | nil,
          to_trip_id: String.t() | nil,
          transfer_type: 0..3,
          min_transfer_time: integer() | nil
        }

  @type incidence :: %{optional(String.t()) => [{trip_id :: String.t(), route_id :: String.t()}]}

  @type trip_class :: {:trip, String.t(), String.t()} | {:route, String.t()} | :other

  @type witness :: {String.t(), trip_class(), String.t(), trip_class()}

  @typedoc "One witnessed disagreement, named by the concrete stop and trip of each side."
  @type conflict_witness :: %{
          from_stop_id: String.t(),
          from_trip_id: String.t(),
          to_stop_id: String.t(),
          to_trip_id: String.t(),
          rule_ids: [term()]
        }

  # R6's rank table, keyed by the two sides' effective selectors.
  @rank %{
    {:trip, :trip} => 1,
    {:trip, :route} => 2,
    {:route, :trip} => 2,
    {:trip, :any} => 3,
    {:any, :trip} => 3,
    {:route, :route} => 4,
    {:route, :any} => 5,
    {:any, :route} => 5,
    {:any, :any} => 6
  }

  @doc """
  Returns the GTFS specificity rank of a rule, `1` (most specific) to `6`.

  The rank comes from each side's effective selector: a trip when one is set,
  otherwise a route, otherwise no selector.
  """
  @spec rank(map()) :: 1..6
  def rank(rule) do
    Map.fetch!(@rank, {specificity(rule, :from), specificity(rule, :to)})
  end

  @doc """
  Returns every pair of rules that competes over `incidence`.

  The result maps a rule id to its sorted, unique competitor ids and contains only
  rules that compete with at least one other rule.
  """
  @spec evaluate([rule()], incidence()) :: %{optional(term()) => [term()]}
  def evaluate(rules, incidence) do
    rules
    |> witnesses(incidence)
    |> Enum.reduce(%{}, fn %{rule_ids: [left, right]}, edges ->
      edges |> add_edge(left, right) |> add_edge(right, left)
    end)
    |> Map.new(fn {id, competitor_ids} -> {id, competitor_ids |> Enum.uniq() |> Enum.sort()} end)
  end

  @doc """
  Returns every witnessed equal-specificity disagreement as a concrete witness.

  Each entry names the stop and trip of both sides and the two rules whose
  effects differ. The named trip of a side is the lexicographically first member
  of that side's trip class, which is one of the real `stop_time` rows the class
  was built from, so the entry is an actual arrival/departure pair a rider could
  make. `evaluate/2` is this function reduced to rule ids.
  """
  @spec witnesses([rule()], incidence()) :: [conflict_witness()]
  def witnesses(rules, incidence) do
    index = class_index(rules, incidence)

    rules
    |> Enum.reduce(%{}, fn rule, acc -> record_witnesses(acc, rule, index) end)
    |> Enum.flat_map(fn {{from_leaf, from_class, to_leaf, to_class}, {_rank, best}} ->
      from_trip = representative(index, from_leaf, :from, from_class)
      to_trip = representative(index, to_leaf, :to, to_class)

      for [left, right] <- pairs(best), effect(left) != effect(right) do
        %{
          from_stop_id: from_leaf,
          from_trip_id: from_trip,
          to_stop_id: to_leaf,
          to_trip_id: to_trip,
          rule_ids: Enum.sort([id(left), id(right)])
        }
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp record_witnesses(acc, rule, index) do
    rule_rank = rank(rule)

    rule
    |> rule_witnesses(index)
    |> Enum.reduce(acc, fn witness, acc -> keep_best(acc, witness, rule_rank, rule) end)
  end

  # One witness keeps only the rules at the lowest rank seen for it, so a better
  # rule reaching the witness later replaces the rules already collected there.
  defp keep_best(acc, witness, rank, rule) do
    Map.update(acc, witness, {rank, [rule]}, fn
      {best_rank, _rules} when rank < best_rank -> {rank, [rule]}
      {best_rank, rules} when rank == best_rank -> {best_rank, [rule | rules]}
      existing -> existing
    end)
  end

  defp pairs(rules) do
    indexed = Enum.with_index(rules)

    for {left, index} <- indexed, {right, other} <- indexed, other > index, do: [left, right]
  end

  defp add_edge(edges, id, competitor_id) do
    Map.update(edges, id, [competitor_id], &[competitor_id | &1])
  end

  defp effect(rule) do
    case Map.fetch!(rule, :transfer_type) do
      2 -> {2, Map.get(rule, :min_transfer_time)}
      type -> {type, nil}
    end
  end

  defp id(rule), do: Map.fetch!(rule, :id)

  # Per leaf stop and side, the trips with a stop_time there collapse into
  # equivalence classes: a trip named by a rule covering that leaf keeps its own
  # class, other trips of a route named there share one class, and the remaining
  # trips share the last class. Selector matching is constant inside a class, so
  # enumerating classes instead of trips cannot change which rules a witness has.
  # The index keeps the members of each class, which only `witnesses/2` reads to
  # name a real trip.
  defp class_index(rules, incidence) do
    Map.new(incidence, fn {leaf, trips} ->
      {leaf,
       %{
         from: class_members(trips, rules, leaf, :from),
         to: class_members(trips, rules, leaf, :to)
       }}
    end)
  end

  defp class_members(trips, rules, leaf, side) do
    naming = Enum.filter(rules, &(leaf in coverage(&1, side)))
    named_trips = naming |> Enum.flat_map(&List.wrap(trip_selector(&1, side))) |> MapSet.new()
    named_routes = naming |> Enum.flat_map(&List.wrap(route_selector(&1, side))) |> MapSet.new()

    Enum.group_by(trips, fn {trip_id, route_id} ->
      cond do
        MapSet.member?(named_trips, trip_id) -> {:trip, trip_id, route_id}
        MapSet.member?(named_routes, route_id) -> {:route, route_id}
        true -> :other
      end
    end)
  end

  defp representative(index, leaf, side, class) do
    index
    |> classes_at(leaf, side)
    |> Map.fetch!(class)
    |> Enum.min()
    |> elem(0)
  end

  defp rule_witnesses(rule, index) do
    for from_leaf <- coverage(rule, :from),
        from_class <- matching_classes(index, from_leaf, :from, rule),
        to_leaf <- coverage(rule, :to),
        to_class <- matching_classes(index, to_leaf, :to, rule) do
      {from_leaf, from_class, to_leaf, to_class}
    end
  end

  defp matching_classes(index, leaf, side, rule) do
    index
    |> classes_at(leaf, side)
    |> Map.keys()
    |> Enum.filter(&matches?(&1, trip_selector(rule, side), route_selector(rule, side)))
  end

  defp classes_at(index, leaf, side) do
    case Map.fetch(index, leaf) do
      {:ok, sides} -> Map.fetch!(sides, side)
      :error -> %{}
    end
  end

  defp matches?({:trip, trip_id, route_id}, trip, route) do
    (is_nil(trip) or trip == trip_id) and (is_nil(route) or route == route_id)
  end

  defp matches?({:route, class_route}, trip, route) do
    is_nil(trip) and (is_nil(route) or route == class_route)
  end

  defp matches?(:other, trip, route), do: is_nil(trip) and is_nil(route)

  defp specificity(rule, side) do
    case {trip_selector(rule, side), route_selector(rule, side)} do
      {trip, _route} when not is_nil(trip) -> :trip
      {nil, route} when not is_nil(route) -> :route
      {nil, nil} -> :any
    end
  end

  defp coverage(rule, :from), do: Map.fetch!(rule, :from_coverage)
  defp coverage(rule, :to), do: Map.fetch!(rule, :to_coverage)

  defp trip_selector(rule, :from), do: Map.get(rule, :from_trip_id)
  defp trip_selector(rule, :to), do: Map.get(rule, :to_trip_id)

  defp route_selector(rule, :from), do: Map.get(rule, :from_route_id)
  defp route_selector(rule, :to), do: Map.get(rule, :to_route_id)
end
