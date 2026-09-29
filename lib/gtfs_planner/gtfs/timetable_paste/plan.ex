defmodule GtfsPlanner.Gtfs.TimetablePaste.Plan do
  @moduledoc """
  Turns resolved paste rows and the loaded scope into a review plan (rules
  R10, R13-plumbing, AC-12, AC-13).

  Step 7 implements the Add-mode path of `build/6`: every accepted row
  becomes an `:add`, duplicates are detected against existing trips and
  earlier accepted rows of the same build, and timings are reused or named.
  Replace mode (`:replace`) is not built here — it arrives in step 8 and
  `build/6` raises for it rather than half-building it.

  ## Add-mode rules

    * Only `:ready` rows are candidates. `:skipped` rows become `:skipped`
      changes and `:decision` rows become `:needs_decision` changes; neither
      is counted as an add and neither consumes a timing.
    * A ready row whose pattern and start equal an existing scope trip's, or
      an earlier accepted row's in the same build, is `:duplicate` and is
      skipped until the row's decision carries a truthy `keep` ("Add
      anyway"), which promotes it back to `:add`. Accepted rows are exactly
      the rows that become `:add`.
    * Timing reuse is on exact key equality only: an applied group reuses
      the pattern's existing timing when its `key` matches, otherwise the
      group shares one pending new timing. `key` already covers the full
      final vector plus per-stop attributes, so no canonicalizer is needed
      here — existing timing keys are computed with the same tuple layout
      `RowResolver` uses.
    * Pending timings are named `Pasted <stamp> · A`, B, … Z, AA, … with
      the first free suffix per pattern, compared case-insensitively
      against that pattern's existing names plus the pending names already
      assigned in this build. `next_free_name/3` is the pure naming mirror
      of `RoutePatterns.next_free_timing_name/3` (which arrives in step
      12); the suffix sequence mirrors private `alpha_name/1` exactly.

  ## Shapes

  The scope is server-built with atom keys; this module also tolerates
  string keys on the fields it reads. Only these fields are read:

    * `scope.patterns` — `[%{id:, route_pattern_id:, timings: [%{id:,
      name:, rows:, trip_count:}]}]`; timing `rows` align positionally with
      the pattern's occurrences (the shape step 16 `load_paste_scope/5`
      must provide): `%{arrival_offset:, departure_offset:, timepoint:,
      pickup_type:, drop_off_type:, stop_headsign:}`. A `nil` timepoint on
      a stored row reads as `1`: a missing value is exact, matching the
      GTFS semantics the paste relies on elsewhere.
    * `scope.trips` — every trip of the route on the calendar (both
      directions): `%{route_pattern_id:, start_secs:, ...}`. The whole
      trip map is carried onto a `:duplicate` change so the review can
      name the conflicting trip; in-paste-only duplicates carry `nil`.

  The fourth argument accepts either the review input (a map holding
  `:decisions`/`"decisions"`) or the decisions map itself
  (`%{row => %{keep: ...}}`), because step 11 `TimetablePaste.review/2`
  passes the input while tests and later callers may pass decisions
  directly. Row keys may be integers or numeric strings and decision maps
  may use atom or string keys, matching the LiveView JSON round-trip that
  `RowResolver` already tolerates. The `stamp` is a display string such as
  `"Sep 28"` (built by the caller with `Calendar.strftime/2`); block rows
  arrive as the sixth argument and are ignored until step 10 owns
  block-overlap warnings.

  Pure: no Repo, clock or process state (INV-3). `vehicles` stays a
  `%{before: nil, after: nil}` placeholder for step 10, which computes it
  with `Summary.peak_vehicles/1`; `trips` is counted directly because it
  needs no outside data. Headsign/default and warning rules belong to
  steps 9–10, so row metadata passes through untouched here.
  """

  @type change_op ::
          :add | :change | :unchanged | :remove | :duplicate | :skipped | :needs_decision

  @type timing_ref :: {:existing, term()} | {:new, String.t()} | nil

  @type change :: %{
          op: change_op(),
          row: map() | nil,
          trip: map() | nil,
          diffs: [:times | :trip_short_name | :block_id | :trip_headsign],
          timing: timing_ref(),
          trip_short_name: String.t() | nil,
          block_id: String.t() | nil,
          trip_headsign: String.t() | nil,
          warnings: [atom()]
        }

  @type new_timing :: %{
          pattern_id: term(),
          name: String.t(),
          timing_rows: [map()],
          key: binary()
        }

  @type plan :: %{
          changes: [change()],
          counts: %{
            add: non_neg_integer(),
            change: non_neg_integer(),
            unchanged: non_neg_integer(),
            remove: non_neg_integer(),
            duplicate: non_neg_integer(),
            skipped: non_neg_integer(),
            needs_decision: non_neg_integer()
          },
          new_timings: [new_timing()],
          refusal: nil | {:frequency, map()} | {:stops_differ, map()} | :nothing_accepted,
          warnings: [term()],
          vehicles: %{before: nil | non_neg_integer(), after: nil | non_neg_integer()},
          trips: %{before: non_neg_integer(), after: non_neg_integer()},
          transfers_removed: non_neg_integer(),
          replace_patterns: [term()],
          writes_blocks?: boolean()
        }

  @doc """
  Builds the Add-mode plan for `resolved_rows` against `scope`.

  Raises `ArgumentError` for `:replace` (step 8) or any other mode.
  """
  @spec build([map()], map(), :add | :replace, map(), String.t(), [map()]) :: plan()
  def build(resolved_rows, scope, :add, input_or_decisions, stamp, _block_rows) do
    rows = if(is_list(resolved_rows), do: resolved_rows, else: [])
    scope_map = if(is_map(scope), do: scope, else: %{})
    decisions = normalize_decisions(unwrap_decisions(input_or_decisions))

    patterns =
      normalize_patterns(Map.get(scope_map, :patterns, Map.get(scope_map, "patterns", [])))

    by_pattern = Map.new(patterns, &{&1.id, &1})
    trips = normalize_trips(Map.get(scope_map, :trips, Map.get(scope_map, "trips", [])))

    {ranked, _accepted} = mark_rows(rows, by_pattern, trips, decisions)
    {changes, new_timings} = assign_timings(ranked, by_pattern, stamp)

    %{
      changes: changes,
      counts: count_ops(changes),
      new_timings: new_timings,
      refusal: nil,
      warnings: [],
      vehicles: %{before: nil, after: nil},
      trips: %{before: length(trips), after: length(trips) + count_op(changes, :add)},
      transfers_removed: 0,
      replace_patterns: [],
      writes_blocks?: writes_blocks?(changes)
    }
  end

  def build(_resolved_rows, _scope, mode, _input_or_decisions, _stamp, _block_rows) do
    raise ArgumentError,
          "GtfsPlanner.Gtfs.TimetablePaste.Plan.build/6 does not implement mode #{inspect(mode)} yet (Replace arrives in step 8)"
  end

  @doc """
  Names the next pending timing for `stamp` (e.g. `"Sep 28"`), returning
  `"Pasted <stamp> · <suffix>"` with the first free suffix starting at `A`.

  `existing_names` are the pattern's stored timing names and
  `pending_names` the names already assigned to that pattern in this build;
  both compare case-insensitively. The suffix sequence mirrors
  `RoutePatterns` private `alpha_name/1`: A … Z, AA …

  ## Examples

      iex> Plan.next_free_name([], "Sep 28", [])
      "Pasted Sep 28 · A"

      iex> Plan.next_free_name(["pasted sep 28 · a"], "Sep 28", [])
      "Pasted Sep 28 · B"

  """
  @spec next_free_name([term()], term(), [term()]) :: String.t()
  def next_free_name(existing_names, stamp, pending_names) do
    taken =
      MapSet.new(
        Enum.map(
          List.wrap(existing_names) ++ List.wrap(pending_names),
          &String.downcase(to_string(&1))
        )
      )

    prefix = "Pasted #{stamp} · "

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = prefix <> alpha_name(index)
      unless MapSet.member?(taken, String.downcase(name)), do: name
    end)
  end

  # Exact mirror of RoutePatterns private alpha_name/1: 0 → A … 25 → Z,
  # 26 → AA. Read there to confirm before touching this.
  @spec alpha_name(non_neg_integer()) :: String.t()
  defp alpha_name(index) when index < 26, do: <<?A + index>>
  defp alpha_name(index), do: alpha_name(div(index, 26) - 1) <> alpha_name(rem(index, 26))

  # --- Row marking (Add mode) ---

  # Splits rows into applied (:add) and unapplied (:duplicate, :skipped,
  # :needs_decision) changes without timings. Returns the ranked list plus
  # the accepted {pattern_id, start_secs} set (used only while marking).
  @spec mark_rows([map()], map(), [map()], map()) ::
          {[{change_op(), map(), map() | nil}], MapSet.t()}
  defp mark_rows(rows, by_pattern, trips, decisions) do
    {ranked_reversed, accepted} =
      Enum.reduce(rows, {[], MapSet.new()}, fn row, {ranked, accepted} ->
        row_map = if(is_map(row), do: row, else: %{})
        row_num = get(row_map, :row, "row")
        status = get(row_map, :status, "status")

        case status do
          :ready ->
            mark_ready(row_map, row_num, by_pattern, trips, decisions, ranked, accepted)

          "ready" ->
            mark_ready(row_map, row_num, by_pattern, trips, decisions, ranked, accepted)

          :decision ->
            {[{:needs_decision, row_map, nil} | ranked], accepted}

          "decision" ->
            {[{:needs_decision, row_map, nil} | ranked], accepted}

          _skipped ->
            {[{:skipped, row_map, nil} | ranked], accepted}
        end
      end)

    {Enum.reverse(ranked_reversed), accepted}
  end

  # A ready row without the fields a decision could reference (nil pattern,
  # start or key) cannot be matched or timed; it needs an editor decision
  # rather than silently vanishing from the review.
  @spec mark_ready(map(), term(), map(), [map()], map(), list(), MapSet.t()) ::
          {list(), MapSet.t()}
  defp mark_ready(row, row_num, by_pattern, trips, decisions, ranked, accepted) do
    pattern_id = get(row, :pattern_id, "pattern_id")
    start_secs = get(row, :start_secs, "start_secs")
    key = get(row, :key, "key")

    if is_nil(pattern_id) or is_nil(start_secs) or is_nil(key) do
      {[{:needs_decision, row, nil} | ranked], accepted}
    else
      identity = {pattern_id, start_secs}
      trip = find_trip(by_pattern, trips, pattern_id, start_secs)

      duplicate? = not is_nil(trip) or MapSet.member?(accepted, identity)

      if duplicate? and not keep?(decisions, row_num) do
        {[{:duplicate, row, trip} | ranked], accepted}
      else
        {[{:add, row, nil} | ranked], MapSet.put(accepted, identity)}
      end
    end
  end

  # Duplicate identity is pattern plus exact start. The row's pattern id is
  # the scope pattern uuid; trips carry the natural `route_pattern_id`, so
  # both refs of the row's pattern match (plain scopes where they are
  # equal match on either side).
  @spec find_trip(map(), [map()], term(), term()) :: map() | nil
  defp find_trip(by_pattern, trips, pattern_id, start_secs) do
    refs =
      case Map.get(by_pattern, pattern_id) do
        %{refs: refs} -> refs
        nil -> MapSet.new([pattern_id])
      end

    case Enum.find(trips, fn trip ->
           trip.start_secs == start_secs and MapSet.member?(refs, trip.ref)
         end) do
      %{trip: trip} -> trip
      nil -> nil
    end
  end

  @spec keep?(map(), term()) :: boolean()
  defp keep?(decisions, row_num) do
    case Map.get(decisions, row_num) do
      %{keep: keep} -> truthy?(keep)
      _decision -> false
    end
  end

  # --- Timing assignment ---

  # Groups applied rows by {pattern_id, key} in first-appearance order,
  # reuses an existing timing on exact key equality, and otherwise mints
  # one shared pending timing per group. Builds the final changes in input
  # order.
  @spec assign_timings([{change_op(), map(), map() | nil}], map(), term()) ::
          {[change()], [new_timing()]}
  defp assign_timings(ranked, by_pattern, stamp) do
    groups =
      ranked
      |> Enum.filter(fn {op, _row, _trip} -> op == :add end)
      |> Enum.map(fn {:add, row, _trip} ->
        {get(row, :pattern_id, "pattern_id"), get(row, :key, "key"), row}
      end)
      |> Enum.uniq_by(fn {pattern_id, key, _row} -> {pattern_id, key} end)

    {by_group, new_timings} =
      Enum.reduce(groups, {%{}, []}, fn {pattern_id, key, row}, {by_group, new_timings} ->
        pattern = Map.get(by_pattern, pattern_id)
        existing = if(is_nil(pattern), do: [], else: pattern.timings)

        case Enum.find(existing, &(&1.key == key)) do
          %{id: id} ->
            {Map.put(by_group, {pattern_id, key}, {:existing, id}), new_timings}

          nil ->
            pending =
              new_timings
              |> Enum.filter(&(&1.pattern_id == pattern_id))
              |> Enum.map(& &1.name)

            existing_names = Enum.map(existing, & &1.name)
            name = next_free_name(existing_names, stamp, pending)

            entry = %{
              pattern_id: pattern_id,
              name: name,
              timing_rows: get(row, :timing_rows, "timing_rows") || [],
              key: key
            }

            {Map.put(by_group, {pattern_id, key}, {:new, name}), new_timings ++ [entry]}
        end
      end)

    changes =
      Enum.map(ranked, fn
        {:add, row, _trip} ->
          timing =
            Map.fetch!(by_group, {get(row, :pattern_id, "pattern_id"), get(row, :key, "key")})

          to_change(:add, row, nil, timing)

        {op, row, trip} ->
          to_change(op, row, trip, nil)
      end)

    {changes, new_timings}
  end

  @spec to_change(change_op(), map(), map() | nil, timing_ref()) :: change()
  defp to_change(op, row, trip, timing) do
    %{
      op: op,
      row: row,
      trip: trip,
      diffs: [],
      timing: timing,
      trip_short_name: get(row, :trip_short_name, "trip_short_name"),
      block_id: get(row, :block_id, "block_id"),
      trip_headsign: get(row, :trip_headsign, "trip_headsign"),
      warnings: []
    }
  end

  # --- Counting ---

  @spec count_ops([change()]) :: map()
  defp count_ops(changes) do
    %{
      add: count_op(changes, :add),
      change: count_op(changes, :change),
      unchanged: count_op(changes, :unchanged),
      remove: count_op(changes, :remove),
      duplicate: count_op(changes, :duplicate),
      skipped: count_op(changes, :skipped),
      needs_decision: count_op(changes, :needs_decision)
    }
  end

  @spec count_op([change()], change_op()) :: non_neg_integer()
  defp count_op(changes, op), do: Enum.count(changes, &(&1.op == op))

  # A block value is written when an applied row carries one; blank cells
  # already arrive as nil from RowResolver, so only a present value counts.
  @spec writes_blocks?([change()]) :: boolean()
  defp writes_blocks?(changes) do
    Enum.any?(changes, fn change ->
      change.op == :add and present?(change.block_id)
    end)
  end

  @spec present?(term()) :: boolean()
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  # --- Normalization ---

  @spec normalize_patterns(term()) :: [map()]
  defp normalize_patterns(patterns) when is_list(patterns) do
    patterns
    |> Enum.map(fn
      pattern when is_map(pattern) ->
        id = get(pattern, :id, "id")

        if is_nil(id) do
          nil
        else
          natural = get(pattern, :route_pattern_id, "route_pattern_id")

          %{
            id: id,
            refs: MapSet.new(Enum.reject([id, natural], &is_nil/1)),
            timings: normalize_timings(get(pattern, :timings, "timings"))
          }
        end

      _pattern ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_patterns(_patterns), do: []

  @spec normalize_timings(term()) :: [map()]
  defp normalize_timings(timings) when is_list(timings) do
    timings
    |> Enum.map(fn
      timing when is_map(timing) ->
        id = get(timing, :id, "id")

        if is_nil(id) do
          nil
        else
          rows = normalize_timing_rows(get(timing, :rows, "rows"))

          %{id: id, name: get(timing, :name, "name"), rows: rows, key: timing_key(rows)}
        end

      _timing ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_timings(_timings), do: []

  # Positional against the pattern's occurrences, as RowResolver consumes
  # them. Only the six key fields are kept so the key below matches
  # `timing_key/1` in RowResolver tuple-for-tuple.
  @spec normalize_timing_rows(term()) :: [map()]
  defp normalize_timing_rows(rows) when is_list(rows) do
    Enum.map(rows, fn
      row when is_map(row) ->
        %{
          arrival_offset: to_offset(get(row, :arrival_offset, "arrival_offset")),
          departure_offset: to_offset(get(row, :departure_offset, "departure_offset")),
          timepoint: to_timepoint(get(row, :timepoint, "timepoint")),
          pickup_type: get(row, :pickup_type, "pickup_type", 0),
          drop_off_type: get(row, :drop_off_type, "drop_off_type", 0),
          stop_headsign: get(row, :stop_headsign, "stop_headsign")
        }

      _row ->
        %{
          arrival_offset: 0,
          departure_offset: 0,
          timepoint: 1,
          pickup_type: 0,
          drop_off_type: 0,
          stop_headsign: nil
        }
    end)
  end

  defp normalize_timing_rows(_rows), do: []

  # Same tuple layout as RowResolver private timing_key/1: the full final
  # vector plus per-stop attributes, as a deterministic binary. Reuse is an
  # exact match on this binary.
  @spec timing_key([map()]) :: binary()
  defp timing_key(timing_rows) do
    vector =
      Enum.map(timing_rows, fn row ->
        {row.arrival_offset, row.departure_offset, row.timepoint, row.pickup_type,
         row.drop_off_type, row.stop_headsign}
      end)

    :erlang.term_to_binary(vector, [:deterministic])
  end

  @spec to_offset(term()) :: integer()
  defp to_offset(value) when is_integer(value), do: value
  defp to_offset(_value), do: 0

  # Stored rows may predate the explicit-0 rule (R9); a missing timepoint
  # is exact, so it reads as 1.
  @spec to_timepoint(term()) :: 0 | 1
  defp to_timepoint(0), do: 0
  defp to_timepoint("0"), do: 0
  defp to_timepoint(false), do: 0
  defp to_timepoint(nil), do: 1
  defp to_timepoint(_value), do: 1

  @spec normalize_trips(term()) :: [map()]
  defp normalize_trips(trips) when is_list(trips) do
    trips
    |> Enum.map(fn
      trip when is_map(trip) ->
        ref =
          get(trip, :route_pattern_id, "route_pattern_id") ||
            get(trip, :pattern_id, "pattern_id")

        start_secs = get(trip, :start_secs, "start_secs")

        if is_nil(ref) or is_nil(start_secs) do
          nil
        else
          %{ref: ref, start_secs: start_secs, trip: trip}
        end

      _trip ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_trips(_trips), do: []

  # Accepts the review input or the decisions map itself; see the
  # moduledoc. Normalizes to %{row_number => %{keep: ...}} so row lookups
  # below only handle one shape.
  @spec unwrap_decisions(term()) :: term()
  defp unwrap_decisions(%{decisions: decisions}) when is_map(decisions), do: decisions
  defp unwrap_decisions(%{"decisions" => decisions}) when is_map(decisions), do: decisions
  defp unwrap_decisions(decisions), do: decisions

  @spec normalize_decisions(term()) :: %{pos_integer() => map()}
  defp normalize_decisions(decisions) when is_map(decisions) do
    decisions
    |> Enum.map(fn {row, decision} -> {to_row_num(row), normalize_decision(decision)} end)
    |> Enum.reject(fn {row, _decision} -> is_nil(row) end)
    |> Map.new()
  end

  defp normalize_decisions(_decisions), do: %{}

  @spec to_row_num(term()) :: pos_integer() | nil
  defp to_row_num(row) when is_integer(row) and row >= 1, do: row

  defp to_row_num(row) when is_binary(row) do
    case Integer.parse(String.trim(row)) do
      {num, ""} when num >= 1 -> num
      _ -> nil
    end
  end

  defp to_row_num(_row), do: nil

  @spec normalize_decision(term()) :: map()
  defp normalize_decision(decision) when is_map(decision) do
    %{keep: get(decision, :keep, "keep")}
  end

  defp normalize_decision(_decision), do: %{keep: nil}

  @spec truthy?(term()) :: boolean()
  defp truthy?(value) when value in [false, nil, 0, "", "false", "0"], do: false
  defp truthy?(_value), do: true

  @spec get(map(), atom(), String.t()) :: term()
  defp get(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  @spec get(map(), atom(), String.t(), term()) :: term()
  defp get(map, atom_key, string_key, default) do
    case get(map, atom_key, string_key) do
      nil -> default
      value -> value
    end
  end
end
