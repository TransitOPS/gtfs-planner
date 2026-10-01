defmodule GtfsPlanner.Reachability.Envelope do
  @moduledoc """
  Builds the versioned, JSON-safe result payload stored in result_json.
  Schema version 1.

  `input_provenance/1` digests the exact execution snapshot a run was routed
  from, so a later database edit cannot rewrite what an older result was
  computed against. Envelopes recorded before this field existed carry no
  provenance and stay readable as unknown.
  """

  alias GtfsPlanner.Reachability.{Pair, Scoring}
  alias GtfsPlanner.Routing.{Diagnostic, FeedAdapter}

  @engine "pathways_router"
  @engine_ref "f1bf1b58e29307d410742af95dfde18111bcb07a"
  @schema_version 1
  @preferences "default"

  @input_provenance_version 1
  # The router compares static pathways only; selected-time closure filtering is
  # never evaluated here, so the envelope must not imply otherwise.
  @closure_evaluation "not_evaluated"

  @typedoc """
  Recorded provenance of one execution snapshot.
  """
  @type input_provenance :: %{required(String.t()) => pos_integer() | String.t()}

  @doc """
  Canonical provenance for the execution snapshot itself.

  `closure_evaluation` is `not_evaluated` because this engine never evaluates
  closures; a reader must not treat a matching digest as closure filtering.
  """
  @spec input_provenance(map()) :: input_provenance()
  def input_provenance(snapshot) do
    digest =
      snapshot
      |> canonical_input()
      |> canonical_json()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{
      "version" => @input_provenance_version,
      "digest" => digest,
      "closure_evaluation" => @closure_evaluation
    }
  end

  @spec build(%{
          station: map(),
          pairs: [Pair.t()],
          results: [
            %{pair: Pair.t(), outcome: atom(), route: map() | nil, reason: String.t() | nil}
          ],
          diagnostics: [Diagnostic.t()],
          topology: map(),
          started_at: DateTime.t(),
          completed_at: DateTime.t(),
          input_provenance: input_provenance() | nil
        }) :: map()
  def build(attrs) do
    %{
      station: station,
      pairs: _pairs,
      results: results,
      diagnostics: diagnostics,
      topology: topology,
      started_at: started_at,
      completed_at: completed_at
    } = attrs

    outcome = Scoring.run_outcome(Enum.map(results, &%{mode: &1.pair.mode, outcome: &1.outcome}))
    counts = Scoring.counts(Enum.map(results, &%{mode: &1.pair.mode, outcome: &1.outcome}))

    totals = build_totals(results, counts)
    duration_ms = DateTime.diff(completed_at, started_at, :millisecond)

    envelope = %{
      "engine" => @engine,
      "engine_ref" => @engine_ref,
      "result_schema_version" => @schema_version,
      "preferences" => @preferences,
      "metadata" => %{"station_stop_id" => station.stop_id},
      "outcome" => Atom.to_string(outcome),
      "station" => %{"stop_id" => station.stop_id, "stop_name" => station.stop_name},
      "topology" => %{
        "entrance_count" => topology.entrance_count,
        "platform_count" => topology.platform_count,
        "pathway_count" => topology.pathway_count,
        "level_count" => topology.level_count
      },
      "totals" => totals,
      "diagnostics" => Enum.map(diagnostics, &Diagnostic.to_map/1),
      "pairs" => Enum.map(results, &pair_entry/1),
      "started_at" => DateTime.to_iso8601(started_at),
      "completed_at" => DateTime.to_iso8601(completed_at),
      "duration_ms" => duration_ms
    }

    # Absent provenance means a result recorded before this field existed: it
    # stays valid and readable, and its freshness stays unknown.
    case Map.get(attrs, :input_provenance) do
      nil -> envelope
      provenance -> Map.put(envelope, "input_provenance", provenance)
    end
  end

  # The digest describes the assembled execution input. Its rows are the exact
  # shapes the router loaded, plus pathway min_width (a recorded input the
  # router ignores today) and station/child membership.
  defp canonical_input(snapshot) do
    pathways = Map.get(snapshot, :pathways, [])

    %{
      "engine" => @engine,
      "engine_ref" => @engine_ref,
      "preferences" => @preferences,
      "stops" => canonical_stops(snapshot),
      "pathways" =>
        pathways
        |> FeedAdapter.pathway_rows()
        |> Enum.zip(pathways)
        |> Enum.map(fn {row, pathway} ->
          row |> Map.put(:min_width, Map.get(pathway, :min_width)) |> string_keys()
        end)
        |> Enum.sort_by(& &1["pathway_id"]),
      "levels" =>
        snapshot
        |> Map.get(:levels, [])
        |> FeedAdapter.level_rows()
        |> Enum.map(&string_keys/1)
        |> Enum.sort_by(& &1["level_id"])
    }
  end

  defp canonical_stops(snapshot) do
    child_rows =
      snapshot
      |> Map.get(:child_stops, [])
      |> FeedAdapter.stop_rows()
      |> Enum.map(&Map.put(&1, :membership, "child"))

    case Map.get(snapshot, :station) do
      nil ->
        child_rows

      station ->
        station_rows =
          [station]
          |> FeedAdapter.stop_rows()
          |> Enum.map(&Map.put(&1, :membership, "station"))

        station_rows ++ child_rows
    end
    |> Enum.map(&string_keys/1)
    |> Enum.sort_by(& &1["id"])
  end

  # Decimals carry recorded scale; the value is what execution used, so they
  # canonicalize through `Decimal.normalize/1`, which drops trailing zeros.
  defp string_keys(row) do
    Map.new(row, fn {key, value} -> {Atom.to_string(key), canonical_value(value)} end)
  end

  defp canonical_value(%Decimal{} = value) do
    value |> Decimal.normalize() |> Decimal.to_string()
  end

  defp canonical_value(nil), do: nil

  defp canonical_value(value) when is_boolean(value) or is_number(value) or is_binary(value),
    do: value

  defp canonical_value(value) when is_atom(value), do: Atom.to_string(value)

  # Deterministic JSON: keys sorted, no insignificant whitespace. Only the
  # canonical scalar types appear, so an unexpected term fails the digest
  # instead of silently widening what it covers.
  defp canonical_json(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> Jason.encode!(key) <> ":" <> canonical_json(value) end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_json(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(%Decimal{} = value) do
    Jason.encode!(value |> Decimal.normalize() |> Decimal.to_string())
  end

  defp canonical_json(value) when is_binary(value), do: Jason.encode!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp canonical_json(nil), do: "null"
  defp canonical_json(value) when is_boolean(value), do: Atom.to_string(value)

  defp build_totals(results, counts) do
    pair_count = length(results)

    walking_reachable =
      Enum.count(results, &(&1.pair.mode == :walking and &1.outcome == :reachable))

    walking_unreachable =
      Enum.count(results, &(&1.pair.mode == :walking and &1.outcome == :unreachable))

    wheelchair_reachable =
      Enum.count(results, &(&1.pair.mode == :wheelchair and &1.outcome == :reachable))

    wheelchair_unreachable =
      Enum.count(results, &(&1.pair.mode == :wheelchair and &1.outcome == :unreachable))

    %{
      "pair_count" => pair_count,
      "reachable" => counts.infos,
      "unreachable" => walking_unreachable + wheelchair_unreachable,
      "invalid" => Enum.count(results, &(&1.outcome == :invalid)),
      "walking_reachable" => walking_reachable,
      "walking_unreachable" => walking_unreachable,
      "wheelchair_reachable" => wheelchair_reachable,
      "wheelchair_unreachable" => wheelchair_unreachable
    }
  end

  defp pair_entry(%{pair: pair, outcome: outcome, route: route, reason: reason}) do
    base = %{
      "index" => pair.index,
      "kind" => Atom.to_string(pair.kind),
      "mode" => Atom.to_string(pair.mode),
      "from_stop_id" => pair.from_stop_id,
      "from_stop_name" => pair.from_stop_name,
      "to_stop_id" => pair.to_stop_id,
      "to_stop_name" => pair.to_stop_name,
      "outcome" => Atom.to_string(outcome),
      "reason" => reason
    }

    case route do
      nil ->
        Map.merge(base, %{
          "duration_seconds" => nil,
          "distance_meters" => nil,
          "generalized_cost" => nil,
          "step_count" => nil
        })

      route ->
        Map.merge(base, %{
          "duration_seconds" => route.duration_seconds,
          "distance_meters" => route.distance_meters,
          "generalized_cost" => route.generalized_cost,
          "step_count" => route.step_count
        })
    end
  end
end
