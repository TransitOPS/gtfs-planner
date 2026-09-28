defmodule GtfsPlanner.TransferOverlapOracle do
  @moduledoc """
  Independent brute-force oracle for R6 transfer competition (EV-3).

  This module derives the expected verdict straight from the GTFS text: it walks
  every concrete (arrival stop, arrival trip, departure stop, departure trip)
  combination the incidence can witness and applies each rule literally, so a
  rule counts only when its coverage contains both stops and every selector it
  sets equals the trip's or route's value. The rules at the lowest specificity
  rank decide that trip pair, and two of them with different effects compete.

  It keeps its own specificity table, named after the GTFS wording, and never
  calls `GtfsPlanner.Gtfs.Transfers.Overlaps` or shares a helper with it, so
  agreeing with the evaluator is evidence rather than a tautology. It is test
  support, not production code: nothing outside `test/` references it.
  """

  @type incidence :: %{optional(String.t()) => [{String.t(), String.t()}]}

  # The rank table is R6 read literally. R6's rank is symmetric in the two sides
  # and "one trip" outranks "both routes", so the sides are first sorted by
  # specificity and the ordered pair is read off one table.
  @specificity_order %{trip: 0, route: 1, none: 2}

  @ordered_rank %{
    {:trip, :trip} => 1,
    {:trip, :route} => 2,
    {:trip, :none} => 3,
    {:route, :route} => 4,
    {:route, :none} => 5,
    {:none, :none} => 6
  }

  @doc """
  Returns the competing rule ids the GTFS text implies for `rules` over `incidence`.

  The shape matches `GtfsPlanner.Gtfs.Transfers.Overlaps.evaluate/2`: a map from
  rule id to sorted, unique competitor ids, containing only competing rules.
  """
  @spec competitors([map()], incidence()) :: %{optional(term()) => [term()]}
  def competitors(rules, incidence) do
    for {from_leaf, from_trips} <- incidence,
        {to_leaf, to_trips} <- incidence,
        {from_trip, from_route} <- from_trips,
        {to_trip, to_route} <- to_trips,
        reduce: %{} do
      edges ->
        add_witness(edges, rules, {from_leaf, from_trip, from_route, to_leaf, to_trip, to_route})
    end
    |> sort_edges()
  end

  defp add_witness(edges, rules, {from_leaf, from_trip, from_route, to_leaf, to_trip, to_route}) do
    applicable =
      Enum.filter(rules, fn rule ->
        from_leaf in Map.fetch!(rule, :from_coverage) and
          to_leaf in Map.fetch!(rule, :to_coverage) and
          selector_matches?(Map.get(rule, :from_trip_id), from_trip) and
          selector_matches?(Map.get(rule, :from_route_id), from_route) and
          selector_matches?(Map.get(rule, :to_trip_id), to_trip) and
          selector_matches?(Map.get(rule, :to_route_id), to_route)
      end)

    case best_rank(applicable) do
      :none -> edges
      best -> add_pair_edges(edges, Enum.filter(applicable, &(specificity_rank(&1) == best)))
    end
  end

  defp best_rank([]), do: :none
  defp best_rank(rules), do: rules |> Enum.map(&specificity_rank/1) |> Enum.min()

  defp selector_matches?(nil, _value), do: true
  defp selector_matches?(expected, value), do: expected == value

  defp specificity_rank(rule) do
    ordered =
      [
        specificity(Map.get(rule, :from_trip_id), Map.get(rule, :from_route_id)),
        specificity(Map.get(rule, :to_trip_id), Map.get(rule, :to_route_id))
      ]
      |> Enum.sort_by(&Map.fetch!(@specificity_order, &1))

    Map.fetch!(@ordered_rank, List.to_tuple(ordered))
  end

  defp specificity(trip, _route) when not is_nil(trip), do: :trip
  defp specificity(nil, route) when not is_nil(route), do: :route
  defp specificity(nil, nil), do: :none

  defp effect(rule) do
    transfer_type = Map.fetch!(rule, :transfer_type)

    if transfer_type == 2,
      do: {transfer_type, Map.get(rule, :min_transfer_time)},
      else: {transfer_type, nil}
  end

  defp add_pair_edges(edges, rules) do
    for [left, right] <- unordered_pairs(rules), effect(left) != effect(right), reduce: edges do
      edges ->
        edges
        |> put_edge(Map.fetch!(left, :id), Map.fetch!(right, :id))
        |> put_edge(Map.fetch!(right, :id), Map.fetch!(left, :id))
    end
  end

  defp unordered_pairs(rules) do
    indexed = Enum.with_index(rules)

    for {left, index} <- indexed, {right, other} <- indexed, other > index, do: [left, right]
  end

  defp put_edge(edges, id, competitor_id) do
    Map.update(edges, id, [competitor_id], &[competitor_id | &1])
  end

  defp sort_edges(edges) do
    Map.new(edges, fn {id, competitors} -> {id, competitors |> Enum.uniq() |> Enum.sort()} end)
  end
end
