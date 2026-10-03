defmodule GtfsPlanner.Gtfs.Runs.Plan do
  @moduledoc """
  Builds a runs plan — the diff between what a day looks like now and what a
  suggestion would make it — and the fingerprint that says whether the day still
  looks the same.

  Pure: it reads its arguments, calls `Blocking.Context.digest/1` and no
  repository, clock, file or network, and writes nothing. It proposes;
  `Runs.apply_run_plan/3` is what writes, and it recomputes this fingerprint
  under the lock before it does.

  ## The fingerprint is a question, not a lock

  A plan is built from a **preview** — a moment when the planner looked at the
  day — and applied later, possibly minutes later, possibly on another tab. Any
  input the suggestion depended on may have changed in between, and a plan
  applied to a day it was not computed for would write assignments against
  trips that have moved.

  So `fingerprint/1` covers **everything the suggestion was derived from**: the
  whole planning context, every sequence trip's identity and timing and its two
  end stops, every assignment, and the crew rules. `apply_run_plan/3`
  recomputes it under the lock and refuses a mismatch with `:stale_plan`. That
  is the whole mechanism; there is no version counter and no timestamp, because
  a counter misses an edit made by a different session and a timestamp misses
  nothing but is not an input.

  ## Why the ordering rules matter

  Two days that differ only in the order their inputs arrived are the same day
  and must have the same fingerprint, or a plan would go stale for no reason.
  So every term is sorted and canonicalised before it is hashed: the context
  through `Context.digest/1`, which already sorts maps, MapSets and tuples, the
  trip terms by trip ID, the assignment pairs by trip ID, and the crew rules as
  a sorted list. The hash is SHA-256 over
  `:erlang.term_to_binary(term, [:deterministic])`, which is the only encoding
  here that does not depend on map iteration order or on the BEAM's internals.

  ## The diff

  `build/1` is deliberately boring. A **move** is a trip whose run differs, and
  nothing else: a trip already on the right run is not in the plan, however the
  suggestion was arrived at. Moves are sorted by trip ID, `changed_run_ids` is
  the sorted union of every run named on either side of a move, and
  `new_run_ids` is the suggested IDs that are not in use now.

  The union matters in both directions. A run that loses a trip and a run that
  gains one are both affected, and a page that only knew about the new IDs would
  leave the old ones on screen with no indication they had changed.
  """

  @type move :: %{trip_id: Ecto.UUID.t(), from: String.t() | nil, to: String.t() | nil}

  @type t :: %{
          day_type_key: String.t(),
          scope: atom(),
          moves: [move()],
          changed_run_ids: [String.t()],
          new_run_ids: [String.t()],
          before: map(),
          after: map(),
          preview: map(),
          fingerprint: String.t()
        }

  @doc """
  The fingerprint of everything a suggestion was derived from.

  Takes `%{context:, trips:, assignments:, crew:}` and returns a lowercase
  SHA-256 hex string. Two equal days in any order hash the same; any change to
  the context, a trip, an assignment or a crew rule hashes differently.
  """
  @spec fingerprint(%{context: map(), trips: [map()], assignments: map(), crew: map()}) ::
          String.t()
  alias GtfsPlanner.Gtfs.Blocking.Context

  def fingerprint(%{context: context, trips: trips, assignments: assignments, crew: crew}) do
    %{
      context: Context.digest(context),
      trips: Enum.map(trips, &trip_term/1) |> Enum.sort(),
      assignments: assignments |> Enum.sort(),
      crew: Map.to_list(crew) |> Enum.sort()
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Only what a suggestion actually depends on. A trip's stop *names* and
  # coordinates are not here — the planning context already covers the stops
  # themselves — but its two end stops are, because which stops a trip runs
  # between is part of its identity for blocking purposes.
  defp trip_term(trip) do
    {trip.id, trip.block_id, trip.first_departure, trip.last_arrival, stop_id(trip.first_stop),
     stop_id(trip.last_stop), trip.updated_at}
  end

  defp stop_id(nil), do: nil
  defp stop_id(stop), do: stop.stop_id

  @doc """
  Builds the plan from a suggestion and the day it was made against.

  Takes `%{day_type_key:, scope:, current:, proposed:, before:, after:, preview:,
  fingerprint:}`, where `current` and `proposed` are assignment maps keyed by
  trip UUID. The result is `t()`.
  """
  @spec build(map()) :: t()
  def build(%{
        day_type_key: day_type_key,
        scope: scope,
        current: current,
        proposed: proposed,
        before: before,
        after: after_stats,
        preview: preview,
        fingerprint: fingerprint
      }) do
    moves = diff(current, proposed)

    %{
      day_type_key: day_type_key,
      scope: scope,
      moves: moves,
      changed_run_ids: changed_run_ids(moves),
      new_run_ids: new_run_ids(current, proposed),
      before: before,
      after: after_stats,
      preview: preview,
      fingerprint: fingerprint
    }
  end

  # Every trip whose run differs, and only those. A trip on the right run
  # already is not a change, whatever produced the suggestion.
  defp diff(current, proposed) do
    current
    |> Map.keys()
    |> Kernel.++(Map.keys(proposed))
    |> Enum.uniq()
    |> Enum.map(&%{trip_id: &1, from: Map.get(current, &1), to: Map.get(proposed, &1)})
    |> Enum.filter(&(&1.from != &1.to))
    |> Enum.sort_by(& &1.trip_id)
  end

  # Both sides of every move, so a run that only lost a trip is still reported.
  defp changed_run_ids(moves) do
    moves
    |> Enum.flat_map(fn move -> [move.from, move.to] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp new_run_ids(current, proposed) do
    in_use = MapSet.new(Map.values(current))

    proposed
    |> Map.values()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(in_use, &1))
    |> Enum.sort()
  end
end
