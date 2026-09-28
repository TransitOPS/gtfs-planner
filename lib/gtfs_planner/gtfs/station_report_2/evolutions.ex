defmodule GtfsPlanner.Gtfs.StationReport2.Evolutions do
  @moduledoc """
  Pure comparison of one station's base and effective pathway connections.

  `evaluate/2` answers one question: with a set of closed `pathway_id`s removed,
  which entrance/platform connections survive, in both directions, for walking
  and for step-free travel? `compare/2` then diffs a base evaluation against an
  effective one and names the pairs that were lost, the pairs the base graph
  never had, and the platforms that lost every step-free route.

  ## Contracts

    * A closure removes its pathway from the graph before either adjacency is
      built, so a bidirectional pathway loses both directions. Geometry is never
      modified and a direction is never flipped, so a missing connection is
      reported as missing.
    * Walking uses every pathway mode. Step-free uses the same mode set as
      `Graph.build_step_free_directed_adjacency/1` - walkway, moving sidewalk,
      elevator, fare gate and exit gate - so stairs (2) and escalators (4) can
      never supply a step-free route. No width, slope or other wheelchair need
      is decided here.
    * A platform is its own `location_type` 0 stop plus its `location_type` 4
      boarding areas, through `Graph.build_platform_target_index/1`. Going
      `to_platform` means reaching any member of that set; going `to_exit` means
      starting from any member, because a boarding area is where a rider meets
      the platform.
    * Reachability is directed. An unidirectional pathway supplies only its own
      direction, so the two directions of a pair are computed independently.

  ## Incomplete input

  `:incomplete` is the only honest status when the station has no entrances, no
  platforms, or a pathway whose other endpoint is outside the station;
  `incomplete_reasons` names the case and lists cross-station pathways by
  `pathway_id`. A pathway that leaves the station is still evaluated rather than
  dropped, because dropping an edge could invent a loss, and the incomplete
  status keeps the result from reading as an all-clear. Every pair that can be
  computed is still returned, so a caller shows what it knows and says what is
  missing.

  ## Ownership

  `PathwayEvolutions` loads one station snapshot plus the closed pathway set for
  one absolute instant, calls `evaluate/2` for the base and the effective graph
  and `compare/2` once. Service-day instants come from
  `PathwayEvolutions.Schedule`. This module reads no clock, no calendar and no
  repository, and returns the same comparison for the same inputs in the same
  order, so a moment preview, a timeline and a range report cannot disagree.
  """

  alias GtfsPlanner.Gtfs.Graph
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop

  @type incomplete_reason ::
          :no_entrances
          | :no_platforms
          | {:cross_station_pathways, [String.t()]}

  @type pair :: %{
          entrance_id: String.t(),
          platform_id: String.t(),
          walking_to_platform: boolean(),
          step_free_to_platform: boolean(),
          walking_to_exit: boolean(),
          step_free_to_exit: boolean()
        }

  @type evaluation :: %{
          status: :complete | :incomplete,
          incomplete_reasons: [incomplete_reason()],
          pairs: [pair()]
        }

  @type finding :: %{
          entrance_id: String.t(),
          platform_id: String.t(),
          mode: :walking | :step_free,
          direction: :to_platform | :to_exit
        }

  @type comparison :: %{
          lost: [finding()],
          baseline_gaps: [finding()],
          platforms_without_step_free: %{to_platform: [String.t()], to_exit: [String.t()]}
        }

  # The four booleans a pair carries, in the order a caller reads them, paired
  # with the mode and direction a finding names. Stating the pair key with its
  # mode and direction keeps the classification free of derived atom names.
  @reachability_keys [
    {:walking_to_platform, :walking, :to_platform},
    {:step_free_to_platform, :step_free, :to_platform},
    {:walking_to_exit, :walking, :to_exit},
    {:step_free_to_exit, :step_free, :to_exit}
  ]

  @doc """
  Evaluates every entrance/platform pair with `closed_pathway_ids` removed.

  The closed set names `pathway_id` values; a name the station does not have
  changes nothing. `pairs` is sorted by platform then entrance, so the same
  snapshot and the same closed set always produce the same list.
  """
  @spec evaluate(
          %{station: Stop.t(), child_stops: [Stop.t()], pathways: [Pathway.t()]},
          MapSet.t(String.t())
        ) :: evaluation()
  def evaluate(snapshot, closed_pathway_ids) do
    entrances = stops_with_location_type(snapshot.child_stops, 2)
    platforms = stops_with_location_type(snapshot.child_stops, 0)
    open_pathways = open_pathways(snapshot.pathways, closed_pathway_ids)

    walking = Graph.build_directed_adjacency(open_pathways)
    step_free = Graph.build_step_free_directed_adjacency(open_pathways)
    platform_targets = Graph.build_platform_target_index(snapshot.child_stops)

    reasons = incomplete_reasons(snapshot, entrances, platforms)

    %{
      status: if(reasons == [], do: :complete, else: :incomplete),
      incomplete_reasons: reasons,
      pairs: build_pairs(entrances, platforms, platform_targets, walking, step_free)
    }
  end

  @doc """
  Diffs a base evaluation against the effective one for the same snapshot.

  A pair direction the base could reach and the effective graph cannot is `lost`;
  a direction the base never reached is a `baseline_gap` and is never a loss, so
  a closure is not blamed for a connection the feed never had. Removing pathways
  can only take reachability away, so the two cases cover every direction.

  `platforms_without_step_free` names the platforms where the base had a
  step-free route in that direction and no entrance still has one. When another
  entrance still reaches the platform the loss stays a pair finding, so closing
  one entrance never claims the whole platform lost access.

  Both finding lists are sorted by platform, entrance, mode and direction, and
  the platform lists by platform. Findings name the entrances and platforms
  involved, not an individual closure: cause wording belongs to the caller,
  which knows the active instance set.
  """
  @spec compare(evaluation(), evaluation()) :: comparison()
  def compare(base, effective) do
    effective_pairs = Map.new(effective.pairs, &{pair_key(&1), &1})

    # Both evaluations come from one snapshot, so every base pair has an
    # effective counterpart. An unpaired base pair is skipped rather than
    # crashing a report.
    matched =
      Enum.flat_map(base.pairs, fn base_pair ->
        case Map.fetch(effective_pairs, pair_key(base_pair)) do
          {:ok, effective_pair} -> [{base_pair, effective_pair}]
          :error -> []
        end
      end)

    classified =
      Enum.flat_map(matched, fn {base_pair, effective_pair} ->
        classify(base_pair, effective_pair)
      end)

    %{
      lost: classified |> findings_of(:lost) |> sort_findings(),
      baseline_gaps: classified |> findings_of(:baseline_gap) |> sort_findings(),
      platforms_without_step_free: platforms_without_step_free(matched)
    }
  end

  # -- evaluation ------------------------------------------------------------

  defp stops_with_location_type(child_stops, location_type) do
    child_stops
    |> Enum.filter(&(&1.location_type == location_type))
    |> Enum.sort_by(& &1.stop_id)
  end

  defp open_pathways(pathways, closed_pathway_ids) do
    Enum.reject(pathways, &MapSet.member?(closed_pathway_ids, &1.pathway_id))
  end

  defp build_pairs(entrances, platforms, platform_targets, walking, step_free) do
    for platform <- platforms,
        entrance <- entrances do
      targets = platform_target_set(platform_targets, platform.stop_id)
      exits = MapSet.new([entrance.stop_id])

      %{
        entrance_id: entrance.stop_id,
        platform_id: platform.stop_id,
        walking_to_platform: Graph.reachable?(entrance.stop_id, targets, walking),
        step_free_to_platform: Graph.reachable?(entrance.stop_id, targets, step_free),
        walking_to_exit: reachable_from_any?(targets, exits, walking),
        step_free_to_exit: reachable_from_any?(targets, exits, step_free)
      }
    end
    |> Enum.sort_by(&pair_key/1)
  end

  defp platform_target_set(platform_targets, platform_id) do
    Map.get(platform_targets, platform_id, MapSet.new([platform_id]))
  end

  defp reachable_from_any?(sources, targets, adjacency) do
    Enum.any?(sources, &Graph.reachable?(&1, targets, adjacency))
  end

  defp incomplete_reasons(snapshot, entrances, platforms) do
    missing =
      for {stops, reason} <- [{entrances, :no_entrances}, {platforms, :no_platforms}],
          stops == [],
          do: reason

    case cross_station_pathway_ids(snapshot) do
      [] -> missing
      pathway_ids -> missing ++ [{:cross_station_pathways, pathway_ids}]
    end
  end

  # The station snapshot keeps a pathway when either endpoint is a station
  # descendant, so a pathway that leaves the station is still evaluated rather
  # than silently dropped. It is reported by `pathway_id` instead.
  defp cross_station_pathway_ids(snapshot) do
    in_station =
      Enum.reduce(
        snapshot.child_stops,
        MapSet.new([snapshot.station.stop_id]),
        &MapSet.put(&2, &1.stop_id)
      )

    snapshot.pathways
    |> Enum.filter(fn pathway ->
      not (MapSet.member?(in_station, pathway.from_stop_id) and
             MapSet.member?(in_station, pathway.to_stop_id))
    end)
    |> Enum.map(& &1.pathway_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # -- comparison ------------------------------------------------------------

  defp classify(base_pair, effective_pair) do
    Enum.flat_map(@reachability_keys, fn {key, mode, direction} ->
      cond do
        not Map.fetch!(base_pair, key) ->
          [{:baseline_gap, finding(base_pair, mode, direction)}]

        not Map.fetch!(effective_pair, key) ->
          [{:lost, finding(base_pair, mode, direction)}]

        true ->
          []
      end
    end)
  end

  defp platforms_without_step_free(matched) do
    by_platform =
      Enum.group_by(matched, fn {base_pair, _effective_pair} -> base_pair.platform_id end)

    platforms = by_platform |> Map.keys() |> Enum.sort()

    %{
      to_platform:
        Enum.filter(platforms, &platform_lost_step_free?(by_platform[&1], :to_platform)),
      to_exit: Enum.filter(platforms, &platform_lost_step_free?(by_platform[&1], :to_exit))
    }
  end

  defp platform_lost_step_free?(pairs, direction) do
    key = step_free_key(direction)

    Enum.any?(pairs, fn {base_pair, _effective_pair} -> Map.fetch!(base_pair, key) end) and
      not Enum.any?(pairs, fn {_base_pair, effective_pair} -> Map.fetch!(effective_pair, key) end)
  end

  defp step_free_key(:to_platform), do: :step_free_to_platform
  defp step_free_key(:to_exit), do: :step_free_to_exit

  defp findings_of(classified, kind) do
    classified |> Enum.filter(&match?({^kind, _finding}, &1)) |> Enum.map(&elem(&1, 1))
  end

  defp finding(pair, mode, direction) do
    %{
      entrance_id: pair.entrance_id,
      platform_id: pair.platform_id,
      mode: mode,
      direction: direction
    }
  end

  defp pair_key(pair), do: {pair.platform_id, pair.entrance_id}

  defp sort_findings(findings) do
    Enum.sort_by(findings, &{&1.platform_id, &1.entrance_id, &1.mode, &1.direction})
  end
end
