defmodule GtfsPlanner.Reachability.Battery do
  @moduledoc """
  Pure derivation of a deterministic, ordered set of in-station origin/destination pairs.
  """

  alias GtfsPlanner.Reachability.Pair

  @max_pairs 2000

  @spec derive(%{child_stops: [map()]}) :: [Pair.t()]
  def derive(%{child_stops: child_stops}) do
    entrances =
      child_stops
      |> Enum.filter(&(&1.location_type == 2))
      |> Enum.sort_by(& &1.stop_id)

    platforms =
      child_stops
      |> Enum.filter(&(&1.location_type == 0))
      |> Enum.sort_by(& &1.stop_id)

    entry_pairs =
      for ent <- entrances, plat <- platforms do
        {ent, plat, :entry}
      end

    egress_pairs =
      for plat <- platforms, ent <- entrances do
        {plat, ent, :egress}
      end

    transfer_pairs =
      for from <- platforms, to <- platforms, from.stop_id != to.stop_id do
        {from, to, :transfer}
      end

    all_raw = entry_pairs ++ egress_pairs ++ transfer_pairs

    all_raw
    |> Enum.flat_map(fn {from, to, kind} ->
      [
        {from, to, kind, :walking},
        {from, to, kind, :wheelchair}
      ]
    end)
    |> Enum.uniq_by(fn {from, to, _kind, mode} -> {from.stop_id, to.stop_id, mode} end)
    |> Enum.sort_by(fn {from, to, kind, mode} ->
      {kind_rank(kind), from.stop_id, to.stop_id, mode_rank(mode)}
    end)
    |> Enum.with_index()
    |> Enum.map(fn {{from, to, kind, mode}, index} ->
      %Pair{
        index: index,
        kind: kind,
        mode: mode,
        from_stop_id: from.stop_id,
        from_stop_name: from.stop_name,
        to_stop_id: to.stop_id,
        to_stop_name: to.stop_name
      }
    end)
  end

  @spec max_pairs() :: pos_integer()
  def max_pairs, do: @max_pairs

  defp kind_rank(:entry), do: 0
  defp kind_rank(:egress), do: 1
  defp kind_rank(:transfer), do: 2

  defp mode_rank(:walking), do: 0
  defp mode_rank(:wheelchair), do: 1
end
