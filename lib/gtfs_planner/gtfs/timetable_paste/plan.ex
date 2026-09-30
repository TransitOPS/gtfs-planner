defmodule GtfsPlanner.Gtfs.TimetablePaste.Plan do
  @moduledoc """
  Turns resolved paste rows and the loaded scope into a review plan (rules
  R10-R13, AC-12-AC-17).

  Step 7 implements the Add-mode path of `build/6`: every accepted row
  becomes an `:add`, duplicates are detected against existing trips and
  earlier accepted rows of the same build, and timings are reused or named.
  Step 8 adds the Replace-mode path (`:replace`): rows pair with existing
  trips by pattern and exact start, then a unique equal trip number, then
  an explicit choice; unpaired scope trips are removed; unsafe scopes are
  refused. Step 9 computes per-change metadata (R13 blank-cell rules and
  the XC-11 headsign rule), refines exact pairs to `:unchanged`, emits the
  non-blocking warnings and validates decisions against the rebuilt
  candidates (`discarded_decisions`).

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

    * `scope.patterns` — `[%{id:, route_pattern_id:, headsign:, timings:
      [%{id:, name:, headsign:, rows:, trip_count:}]}]`; timing `rows`
      align positionally with the pattern's occurrences (the shape step 16
      `load_paste_scope/5` must provide): `%{arrival_offset:,
      departure_offset:, timepoint:, pickup_type:, drop_off_type:,
      stop_headsign:}`. A `nil` timepoint on a stored row reads as `1`:
      a missing value is exact, matching the GTFS semantics the paste
      relies on elsewhere. Pattern and timing headsigns drive the XC-11
      rule; scopes without them read every default as `nil`.
    * `scope.trips` — every trip of the route on the calendar (both
      directions): `%{route_pattern_id:, start_secs:, ...}`. The whole
      trip map is carried onto a `:duplicate` change so the review can
      name the conflicting trip; in-paste-only duplicates carry `nil`.
      Replace additionally reads `trip_short_name` (R11 trip-number
      pairing), `timed_pattern_id`/`timing_id` plus `trip_headsign` (R13
      and `diffs`), `frequencies`/`frequency_rows`/`frequency?` (R12),
      the `pattern_derivation_state` plus `stops_differ?` (R12 and the
      `:custom_replaced` warning), an in-seat transfer flag
      (`:in_seat_transfer`/`:in_seat`/`:has_in_seat_transfer`, or a
      non-empty `:in_seat_transfer_ids`/`:in_seat_transfers` list) for
      `:in_seat_retimed`, and `transfer_ids`/`transfers` (the
      `transfers_removed` sum); every field tolerates atom or string keys.

  The fourth argument accepts either the review input (a map holding
  `:decisions`/`"decisions"`) or the decisions map itself
  (`%{row => %{keep: ...}}`), because step 11 `TimetablePaste.review/2`
  passes the input while tests and later callers may pass decisions
  directly. Row keys may be integers or numeric strings and decision maps
  may use atom or string keys, matching the LiveView JSON round-trip that
  `RowResolver` already tolerates. Replace rows read a pairing choice at
  `decisions[row].pair` (aliases `:trip_id`/`:choice`/`:pairing`/`:trip`):
  a candidate trip's `id` or `trip_id`, or `"neither"` to add the row
  instead; anything else (or nothing) leaves an ambiguous group undecided
  and step 9 reports the stale choice in `discarded_decisions`. Pattern
  choices arrive at `decisions[row].pattern_id` (the `RowResolver` key,
  alias `:pattern`); a choice the row no longer fits is discarded and the
  row is withheld. The `stamp` is a display string such as
  `"Sep 28"` (built by the caller with `Calendar.strftime/2`); block rows
  arrive as the sixth argument as `Blocking.Checks.trip_row()` maps (atom
  keys) and drive the step-10 `:block_overlap` warnings.

  Pure: no Repo, clock or process state (INV-3). `vehicles` is computed
  with `Summary.peak_vehicles/1` over scope spans (both directions) and
  the after-state spans; `trips` is counted directly because it
  needs no outside data.

  ## Metadata (R13, AC-16)

  A present pasted value overrides the matched trip. A blank or absent
  Trip number or Block keeps the matched trip's existing value. A blank
  or absent Headsign follows the XC-11 default test: when the trip's
  current headsign equals its old effective default (the old timing's
  headsign, else the old pattern's headsign) the change takes the new
  effective default (the new timing's headsign, else the new pattern's
  headsign); a custom headsign is kept. New trips take the effective
  default of their assigned timing. A blank headsign never writes an
  empty string (blank normalizes to `nil`). `diffs` lists exactly what
  changed against the matched trip (`:times` when the final vector or
  start differs, plus `:trip_short_name`/`:block_id`/`:trip_headsign`),
  and a paired trip whose final vector and metadata match exactly becomes
  `:unchanged` (counted, never applied).

  ## Warnings (AC-17)

  Non-blocking atoms on `change.warnings`: `:custom_replaced` (step 8,
  custom matching-stops trips), `:in_seat_retimed` (a retimed `:change`
  whose trip carries an in-seat transfer flag), `:duplicate_trip_number`
  (the final trip number equals another trip's on the same calendar,
  whether kept or pasted) and `:custom_headsign_moved` (a kept custom
  headsign on a trip whose timed pattern or last stop changed — the
  route-pattern check is in place for pairing that spans patterns).
  `:block_overlap` (step 10) marks an applied `:add`/`:change` whose
  final block overlaps another trip on the same block and calendar
  (`Checks.sequence/1` + `overlap_pairs/1` over the injected block rows
  plus the planned rows for that block).

  ## Decision validation (critique S2 / PM-10)

  Pairing (`pair`), pattern (`pattern_id`) and keep (`keep`) decisions
  are validated against the rebuilt candidates and stale ones are
  reported in `plan.discarded_decisions` (`[]` when none) instead of
  being applied: a pair naming no available candidate (`:unknown_trip`),
  a superseded pair (`:superseded`), a pair where pairing does not apply
  (`:not_applicable`, Add mode), a pattern choice naming no scope
  pattern (`:unknown_pattern`), a scope pattern the row did not take
  (`:not_applied`), a chosen pattern the row no longer fits
  (`:pattern_misfit`, detected as estimates outside the pasted span —
  the row is withheld as `:needs_decision`), a keep on a non-duplicate
  (`:not_a_duplicate`) and any decision for a row that is gone
  (`:unknown_row`). `"neither"` is always honoured silently.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Schedules.Summary

  @type change_op ::
          :add | :change | :unchanged | :remove | :duplicate | :skipped | :needs_decision

  @type timing_ref :: {:existing, term()} | {:new, String.t()} | nil

  @type change :: %{
          optional(:candidates) => [map()],
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

  @type discarded_decision :: %{
          row: pos_integer() | nil,
          kind: :pair | :pattern | :keep,
          value: term(),
          reason:
            :unknown_trip
            | :unknown_pattern
            | :unknown_row
            | :superseded
            | :not_applicable
            | :not_applied
            | :pattern_misfit
            | :not_a_duplicate
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
          vehicles: %{before: non_neg_integer(), after: non_neg_integer()},
          trips: %{before: non_neg_integer(), after: non_neg_integer()},
          transfers_removed: non_neg_integer(),
          replace_patterns: [term()],
          writes_blocks?: boolean(),
          discarded_decisions: [discarded_decision()]
        }

  @doc """
  Builds the review plan for `resolved_rows` against `scope` in `:add`
  or `:replace` mode (pure; INV-3). See the moduledoc for the R13
  metadata rules, the `:unchanged` refinement, the warnings and the
  decision validation reported in `discarded_decisions`.

  Raises `ArgumentError` for any other mode.
  """
  @spec build([map()], map(), :add | :replace, map(), String.t(), [map()]) :: plan()
  def build(resolved_rows, scope, :add, input_or_decisions, stamp, block_rows) do
    rows = if(is_list(resolved_rows), do: resolved_rows, else: [])
    scope_map = if(is_map(scope), do: scope, else: %{})
    decisions = normalize_decisions(unwrap_decisions(input_or_decisions))

    patterns =
      normalize_patterns(Map.get(scope_map, :patterns, Map.get(scope_map, "patterns", [])))

    by_pattern = Map.new(patterns, &{&1.id, &1})
    trips = normalize_trips(Map.get(scope_map, :trips, Map.get(scope_map, "trips", [])))
    scope_trips = Enum.map(trips, & &1.trip)
    raw_trips = raw_scope_trips(scope_map)
    service_id = scope_service_id(scope_map)

    {misfit, pattern_discards} = validate_patterns(decisions, rows, by_pattern)
    {ranked, _accepted} = mark_rows(rows, by_pattern, trips, decisions, misfit)
    {changes, new_timings} = assign_timings(ranked, by_pattern, stamp)

    final =
      changes
      |> apply_metadata(by_pattern)
      |> apply_warnings(by_pattern, scope_trips)
      |> apply_block_overlaps(block_rows, service_id)

    discards =
      finalize_discards(
        pattern_discards ++
          keep_discards(:add, decisions, rows, by_pattern, trips) ++
          add_pair_discards(decisions, rows)
      )

    %{
      changes: final,
      counts: count_ops(final),
      new_timings: new_timings,
      refusal: nil,
      warnings: [],
      vehicles: plan_vehicles(raw_trips, final),
      trips: %{before: length(trips), after: length(trips) + count_op(final, :add)},
      transfers_removed: 0,
      replace_patterns: [],
      writes_blocks?: writes_blocks?(final),
      discarded_decisions: discards
    }
  end

  def build(resolved_rows, scope, :replace, input_or_decisions, stamp, block_rows) do
    rows = if(is_list(resolved_rows), do: resolved_rows, else: [])
    scope_map = if(is_map(scope), do: scope, else: %{})
    decisions = normalize_decisions(unwrap_decisions(input_or_decisions))

    patterns =
      normalize_patterns(Map.get(scope_map, :patterns, Map.get(scope_map, "patterns", [])))

    by_pattern = Map.new(patterns, &{&1.id, &1})
    trips = normalize_trips(Map.get(scope_map, :trips, Map.get(scope_map, "trips", [])))
    all_trip_maps = Enum.map(trips, & &1.trip)
    raw_trips = raw_scope_trips(scope_map)
    service_id = scope_service_id(scope_map)

    {misfit, pattern_discards} = validate_patterns(decisions, rows, by_pattern)
    accepted = replace_accepted(rows, by_pattern, misfit)
    scope_ids = replace_scope_ids(patterns, accepted)
    scope_refs = replace_scope_refs(by_pattern, scope_ids)

    scope_trips =
      trips
      |> Enum.filter(&MapSet.member?(scope_refs, &1.ref))
      |> Enum.with_index()

    refusal = replace_refusal(accepted, scope_trips)

    {ranked, extras, paired, withheld, pair_discards} =
      replace_ranked(rows, by_pattern, accepted, scope_trips, decisions)

    {row_changes, new_timings} = assign_timings(ranked, by_pattern, stamp, [:add, :change])

    pre =
      row_changes
      |> Enum.zip(extras)
      |> Enum.map(fn {change, extra} -> replace_enrich(change, extra) end)
      |> Kernel.++(replace_removals(scope_trips, paired, withheld, refusal))

    final =
      pre
      |> apply_metadata(by_pattern)
      |> apply_warnings(by_pattern, all_trip_maps)
      |> apply_block_overlaps(block_rows, service_id)

    discards =
      finalize_discards(
        pattern_discards ++
          pair_discards ++
          keep_discards(:replace, decisions, rows, by_pattern, trips) ++
          stray_pair_discards(decisions, rows, accepted)
      )

    %{
      changes: final,
      counts: count_ops(final),
      new_timings: new_timings,
      refusal: refusal,
      warnings: [],
      vehicles: plan_vehicles(raw_trips, final),
      trips: %{
        before: length(trips),
        after: length(trips) + count_op(final, :add) - count_op(final, :remove)
      },
      transfers_removed: Enum.sum(Enum.map(final, &replace_transfer_count/1)),
      replace_patterns: scope_ids,
      writes_blocks?: writes_blocks?(final),
      discarded_decisions: discards
    }
  end

  def build(_resolved_rows, _scope, mode, _input_or_decisions, _stamp, _block_rows) do
    raise ArgumentError,
          "GtfsPlanner.Gtfs.TimetablePaste.Plan.build/6 does not implement mode #{inspect(mode)} (expected :add or :replace)"
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
  # Rows in `misfit` carry a chosen pattern they no longer fit (step 9
  # decision validation); they need an editor decision instead of applying.
  @spec mark_rows([map()], map(), [map()], map(), MapSet.t()) ::
          {[{change_op(), map(), map() | nil}], MapSet.t()}
  defp mark_rows(rows, by_pattern, trips, decisions, misfit) do
    {ranked_reversed, accepted} =
      Enum.reduce(rows, {[], MapSet.new()}, fn row, {ranked, accepted} ->
        row_map = if(is_map(row), do: row, else: %{})
        row_num = get(row_map, :row, "row")
        status = get(row_map, :status, "status")

        cond do
          MapSet.member?(misfit, row_num) ->
            {[{:needs_decision, row_map, nil} | ranked], accepted}

          status == :ready or status == "ready" ->
            mark_ready(row_map, row_num, by_pattern, trips, decisions, ranked, accepted)

          status == :decision or status == "decision" ->
            {[{:needs_decision, row_map, nil} | ranked], accepted}

          true ->
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
  # order. `applied_ops` is `[:add]` for Add mode and `[:add, :change]` for
  # Replace; a shared vector keeps one timing across both ops.
  @spec assign_timings([{change_op(), map(), map() | nil}], map(), term(), [change_op()]) ::
          {[change()], [new_timing()]}
  defp assign_timings(ranked, by_pattern, stamp, applied_ops \\ [:add]) do
    groups =
      ranked
      |> Enum.filter(fn {op, _row, _trip} -> op in applied_ops end)
      |> Enum.map(fn {_op, row, _trip} ->
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
      Enum.map(ranked, fn {op, row, trip} ->
        if op in applied_ops do
          timing =
            Map.fetch!(by_group, {get(row, :pattern_id, "pattern_id"), get(row, :key, "key")})

          to_change(op, row, trip, timing)
        else
          to_change(op, row, trip, nil)
        end
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

  # --- Replace mode (R11/R12, AC-14/AC-15) ---
  #
  # Replace scope is the patterns with at least one accepted row (a :ready
  # row on a known pattern with a start and a key). Rows meet scope trips
  # in {pattern_id, start_secs} groups, resolved in row order:
  #
  #   * no candidates → the row is added;
  #   * one candidate → the row pairs with it;
  #   * several candidates → a unique equal trip_short_name pairs without
  #     asking; else decisions[row].pair names a candidate (by its `id` or
  #     `trip_id`) or "neither" (the row is added, the candidates stay
  #     unpaired); anything else leaves the row `:needs_decision` carrying
  #     the candidate trips, and their removal is withheld.
  #
  # Scope trips left unpaired and unwithheld — except frequency trips —
  # become `:remove`. While refused, no `:remove` is emitted at all.
  # A paired custom trip (derivation state other than "linked") becomes
  # `:change` with a `:custom_replaced` warning; a custom trip whose stops
  # differ refuses the whole Replace instead (R12).

  # Accepted rows keyed by row number (or input position when a row has
  # none, which RowResolver never emits). Rows in `misfit` carry a stale
  # pattern choice (step 9); they are withheld from pairing, removal
  # scope and timing assignment and surface as `:needs_decision`.
  @spec replace_accepted([map()], map(), MapSet.t()) :: [{term(), map()}]
  defp replace_accepted(rows, by_pattern, misfit) do
    rows
    |> Enum.with_index()
    |> Enum.filter(fn {row, _i} -> replace_acceptable?(row, by_pattern, misfit) end)
    |> Enum.map(fn {row, i} -> {replace_row_key(row, i), row} end)
  end

  @spec replace_acceptable?(term(), map(), MapSet.t()) :: boolean()
  defp replace_acceptable?(row, by_pattern, misfit) when is_map(row) do
    status = get(row, :status, "status")

    (status == :ready or status == "ready") and
      not MapSet.member?(misfit, get(row, :row, "row")) and
      not is_nil(get(row, :pattern_id, "pattern_id")) and
      Map.has_key?(by_pattern, get(row, :pattern_id, "pattern_id")) and
      not is_nil(get(row, :start_secs, "start_secs")) and
      not is_nil(get(row, :key, "key"))
  end

  defp replace_acceptable?(_row, _by_pattern, _misfit), do: false

  @spec replace_row_key(map(), non_neg_integer()) :: pos_integer() | {:pos, non_neg_integer()}
  defp replace_row_key(row, i) do
    to_row_num(get(row, :row, "row")) || {:pos, i}
  end

  # Scope pattern ids in scope order (not row order), so the review names
  # patterns stably even when pasted rows interleave them.
  @spec replace_scope_ids([map()], [{term(), map()}]) :: [term()]
  defp replace_scope_ids(patterns, accepted) do
    wanted =
      accepted
      |> Enum.map(fn {_key, row} -> get(row, :pattern_id, "pattern_id") end)
      |> MapSet.new()

    patterns |> Enum.map(& &1.id) |> Enum.filter(&MapSet.member?(wanted, &1))
  end

  @spec replace_scope_refs(map(), [term()]) :: MapSet.t()
  defp replace_scope_refs(by_pattern, scope_ids) do
    Enum.reduce(scope_ids, MapSet.new(), fn id, acc ->
      case Map.get(by_pattern, id) do
        %{refs: refs} -> MapSet.union(acc, refs)
        nil -> acc
      end
    end)
  end

  # Refusals in R12 order: nothing accepted, then a frequency trip on a
  # scope pattern, then a custom stops-differ trip on a scope pattern.
  # With no accepted row the scope is empty, so only :nothing_accepted
  # can fire there — never a delete-all.
  @spec replace_refusal([{term(), map()}], [{map(), non_neg_integer()}]) ::
          nil | {:frequency, map()} | {:stops_differ, map()} | :nothing_accepted
  defp replace_refusal([], _scope_trips), do: :nothing_accepted

  defp replace_refusal(_accepted, scope_trips) do
    case Enum.find(scope_trips, fn {wrapper, _i} -> frequency_trip?(wrapper.trip) end) do
      {wrapper, _i} ->
        {:frequency, wrapper.trip}

      nil ->
        case Enum.find(scope_trips, fn {wrapper, _i} ->
               custom_trip?(wrapper.trip) and stops_differ_trip?(wrapper.trip)
             end) do
          {wrapper, _i} -> {:stops_differ, wrapper.trip}
          nil -> nil
        end
    end
  end

  @spec frequency_trip?(term()) :: boolean()
  defp frequency_trip?(trip) when is_map(trip) do
    rows =
      first_present([
        get(trip, :frequencies, "frequencies"),
        get(trip, :frequency_rows, "frequency_rows"),
        get(trip, :frequency, "frequency")
      ])

    (is_list(rows) and rows != []) or (is_map(rows) and map_size(rows) > 0) or
      get(trip, :frequency?, "frequency?") == true
  end

  defp frequency_trip?(_trip), do: false

  # Custom means anything but an explicitly linked derivation. A missing
  # state reads as linked so minimal test scopes never warn spuriously;
  # step 16 always loads the real state.
  @spec custom_trip?(term()) :: boolean()
  defp custom_trip?(trip) when is_map(trip) do
    state =
      first_present([
        get(trip, :pattern_derivation_state, "pattern_derivation_state"),
        get(trip, :derivation_state, "derivation_state")
      ])

    if is_binary(state) do
      state != "linked"
    else
      get(trip, :custom?, "custom?") == true
    end
  end

  defp custom_trip?(_trip), do: false

  @spec stops_differ_trip?(term()) :: boolean()
  defp stops_differ_trip?(trip) when is_map(trip) do
    truthy?(
      first_present([
        get(trip, :stops_differ?, "stops_differ?"),
        get(trip, :stops_differ, "stops_differ")
      ])
    )
  end

  defp stops_differ_trip?(_trip), do: false

  # Ranks every input row in order and returns the aligned per-row extras
  # ({candidate trips, custom?}) plus the globally paired/withheld
  # scope-trip indexes that drive removals, plus the pair decisions that
  # named no available candidate (step 9 `discarded_decisions`).
  @spec replace_ranked([map()], map(), [{term(), map()}], [{map(), non_neg_integer()}], map()) ::
          {
            [{change_op(), map(), map() | nil}],
            [{[map()], boolean()}],
            MapSet.t(),
            MapSet.t(),
            [discarded_decision()]
          }
  defp replace_ranked(rows, by_pattern, accepted, scope_trips, decisions) do
    {resolutions, paired, withheld, pair_discards} =
      Enum.reduce(
        replace_groups(accepted),
        {%{}, MapSet.new(), MapSet.new(), []},
        fn {identity, grows}, acc ->
          resolve_identity_group(identity, grows, scope_trips, by_pattern, decisions, acc)
        end
      )

    {ranked_reversed, extras_reversed} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {row, i}, {ranked, extras} ->
        {entry, extra} = replace_entry(row, replace_row_key(row, i), resolutions)
        {[entry | ranked], [extra | extras]}
      end)

    {Enum.reverse(ranked_reversed), Enum.reverse(extras_reversed), paired, withheld,
     Enum.reverse(pair_discards)}
  end

  # Groups in first-appearance order so resolutions — and therefore
  # removals — never depend on map ordering.
  @spec replace_groups([{term(), map()}]) :: [{{term(), term()}, [{term(), map()}]}]
  defp replace_groups(accepted) do
    {order, by_group} =
      Enum.reduce(accepted, {[], %{}}, fn {key, row}, {order, by_group} ->
        identity = {get(row, :pattern_id, "pattern_id"), get(row, :start_secs, "start_secs")}

        if Map.has_key?(by_group, identity) do
          {order, Map.update!(by_group, identity, &(&1 ++ [{key, row}]))}
        else
          {order ++ [identity], Map.put(by_group, identity, [{key, row}])}
        end
      end)

    Enum.map(order, &{&1, Map.fetch!(by_group, &1)})
  end

  @spec resolve_identity_group(
          {term(), term()},
          [{term(), map()}],
          [{map(), non_neg_integer()}],
          map(),
          map(),
          {map(), MapSet.t(), MapSet.t(), [discarded_decision()]}
        ) :: {map(), MapSet.t(), MapSet.t(), [discarded_decision()]}
  defp resolve_identity_group(
         {pattern_id, start_secs},
         grows,
         scope_trips,
         by_pattern,
         decisions,
         acc
       ) do
    refs =
      case Map.get(by_pattern, pattern_id) do
        %{refs: refs} -> refs
        nil -> MapSet.new()
      end

    candidates =
      Enum.filter(scope_trips, fn {wrapper, _i} ->
        wrapper.start_secs == start_secs and MapSet.member?(refs, wrapper.ref)
      end)

    Enum.reduce(grows, acc, fn {key, row}, acc3 ->
      resolve_group_row(key, row, candidates, decisions, acc3)
    end)
  end

  @spec resolve_group_row(term(), map(), [{map(), non_neg_integer()}], map(), tuple()) :: tuple()
  defp resolve_group_row(
         key,
         row,
         candidates,
         decisions,
         acc
       ) do
    {_resolutions, paired, _withheld, _discards} = acc
    row_num = if(is_integer(key), do: key, else: nil)
    full = Enum.map(candidates, fn {wrapper, _i} -> wrapper.trip end)
    available = Enum.reject(candidates, fn {_wrapper, i} -> MapSet.member?(paired, i) end)
    raw = pair_raw(decisions, key)

    case available do
      [] ->
        add_unpaired_row(key, row_num, raw, full, acc)

      [{wrapper, i}] ->
        pair_single_row(key, row_num, raw, full, wrapper, i, acc)

      _many ->
        pair_many_rows(key, row, row_num, raw, full, available, decisions, acc)
    end
  end

  defp add_unpaired_row(key, row_num, raw, full, {resolutions, paired, withheld, discards}) do
    {Map.put(resolutions, key, {:added}), paired, withheld,
     discard_pair(discards, row_num, raw, full)}
  end

  defp pair_single_row(key, row_num, raw, full, wrapper, i, acc) do
    {resolutions, paired, withheld, discards} = acc

    if pair_names?(wrapper.trip, raw) or is_nil(raw) or neither_choice?(raw) do
      {Map.put(resolutions, key, {:paired, wrapper}), MapSet.put(paired, i), withheld, discards}
    else
      {Map.put(resolutions, key, {:paired, wrapper}), MapSet.put(paired, i), withheld,
       discard_pair(discards, row_num, raw, full)}
    end
  end

  defp pair_many_rows(key, row, row_num, raw, full, available, decisions, acc) do
    case unique_number_match(row, available) do
      {wrapper, i} -> pair_number_match(key, row_num, raw, full, wrapper, i, acc)
      nil -> apply_pair_decision(key, row_num, raw, full, available, decisions, acc)
    end
  end

  defp pair_number_match(key, row_num, raw, full, wrapper, i, acc) do
    {resolutions, paired, withheld, discards} = acc

    {Map.put(resolutions, key, {:paired, wrapper}), MapSet.put(paired, i), withheld,
     discard_pair_on_number(discards, row_num, raw, wrapper.trip, full)}
  end

  defp apply_pair_decision(key, row_num, raw, full, available, decisions, acc) do
    {resolutions, paired, withheld, discards} = acc

    case replace_pair_choice(decisions, key, available) do
      {:pair, {wrapper, i}} ->
        {Map.put(resolutions, key, {:paired, wrapper}), MapSet.put(paired, i), withheld, discards}

      :neither ->
        {Map.put(resolutions, key, {:added}), paired, withheld, discards}

      :none ->
        withhold_available(key, row_num, raw, full, available, acc)
    end
  end

  defp withhold_available(key, row_num, raw, full, available, acc) do
    {resolutions, paired, withheld, discards} = acc
    trips = Enum.map(available, fn {wrapper, _i} -> wrapper.trip end)

    withheld2 =
      Enum.reduce(available, withheld, fn {_wrapper, i}, acc ->
        MapSet.put(acc, i)
      end)

    {Map.put(resolutions, key, {:undecided, trips}), paired, withheld2,
     discard_pair(discards, row_num, raw, full)}
  end

  # The R11 trip-number rule: the row pairs untouched only when exactly
  # one candidate carries the same present trip number. A blank pasted
  # number never matches.
  @spec unique_number_match(map(), [{map(), non_neg_integer()}]) ::
          {map(), non_neg_integer()} | nil
  defp unique_number_match(row, available) do
    case present_number(get(row, :trip_short_name, "trip_short_name")) do
      nil -> nil
      number -> single_number_match(available, number)
    end
  end

  defp single_number_match(available, number) do
    case Enum.filter(available, fn {wrapper, _i} ->
           present_number(get(wrapper.trip, :trip_short_name, "trip_short_name")) == number
         end) do
      [single] -> single
      _ -> nil
    end
  end

  @spec present_number(term()) :: String.t() | nil
  defp present_number(nil), do: nil

  defp present_number(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      number -> number
    end
  end

  @spec replace_pair_choice(map(), term(), [{map(), non_neg_integer()}]) ::
          {:pair, {map(), non_neg_integer()}} | :neither | :none
  defp replace_pair_choice(decisions, key, available) do
    raw = pair_raw(decisions, key)

    cond do
      is_nil(raw) ->
        :none

      neither_choice?(raw) ->
        :neither

      true ->
        find_identity_pair(available, raw)
    end
  end

  @spec find_identity_pair([{map(), non_neg_integer()}], term()) ::
          {:pair, {map(), non_neg_integer()}} | :none
  defp find_identity_pair(available, raw) do
    case Enum.find(available, fn {wrapper, _i} ->
           trip_identity_match?(wrapper.trip, raw)
         end) do
      nil -> :none
      match -> {:pair, match}
    end
  end

  @spec neither_choice?(term()) :: boolean()
  defp neither_choice?(:neither), do: true

  defp neither_choice?(value) when is_binary(value) do
    String.downcase(String.trim(value)) == "neither"
  end

  defp neither_choice?(_value), do: false

  # A choice names its trip by the database `id` or the natural `trip_id`,
  # tolerating the JSON string form of either. A blank choice never
  # matches; step 9 discards it from `discarded_decisions`.
  @spec trip_identity_match?(map(), term()) :: boolean()
  defp trip_identity_match?(trip, raw) when is_map(trip) do
    wanted = raw |> to_string() |> String.trim()

    wanted != "" and
      Enum.any?(
        [get(trip, :id, "id"), get(trip, :trip_id, "trip_id")],
        fn id -> not is_nil(id) and id |> to_string() |> String.trim() == wanted end
      )
  end

  defp trip_identity_match?(_trip, _raw), do: false

  # The raw pairing choice for a resolution key (`nil` when the row
  # carries no pair decision). Blank strings choose nothing.
  @spec pair_raw(map(), term()) :: term()
  defp pair_raw(decisions, key) do
    case Map.get(decisions, key) do
      %{pair: pair} when is_binary(pair) ->
        if String.trim(pair) == "", do: nil, else: pair

      %{pair: pair} ->
        pair

      _decision ->
        nil
    end
  end

  @spec pair_names?(map(), term()) :: boolean()
  defp pair_names?(_trip, nil), do: false
  defp pair_names?(trip, raw), do: trip_identity_match?(trip, raw)

  # Records a stale pair decision for `discarded_decisions`: a choice
  # that named no trip of the row's group (`:unknown_trip`), or named a
  # group trip the row did not pair with (`:superseded` — taken by an
  # earlier row or beaten by the trip-number rule). `"neither"` and an
  # absent choice are never stale.
  @spec discard_pair([discarded_decision()], pos_integer() | nil, term(), [map()]) :: [
          discarded_decision()
        ]
  defp discard_pair(discards, _row_num, nil, _full), do: discards

  defp discard_pair(discards, row_num, raw, full) do
    if neither_choice?(raw) do
      discards
    else
      reason =
        if Enum.any?(full, &trip_identity_match?(&1, raw)), do: :superseded, else: :unknown_trip

      [%{row: row_num, kind: :pair, value: raw, reason: reason} | discards]
    end
  end

  # A trip-number auto-pair wins over a choice naming another candidate
  # (R11 order); the choice is reported as superseded, otherwise as
  # unknown when it names nothing in the group.
  @spec discard_pair_on_number([discarded_decision()], pos_integer() | nil, term(), map(), [
          map()
        ]) :: [discarded_decision()]
  defp discard_pair_on_number(discards, _row_num, nil, _paired_trip, _full), do: discards

  defp discard_pair_on_number(discards, row_num, raw, paired_trip, full) do
    cond do
      neither_choice?(raw) ->
        discards

      trip_identity_match?(paired_trip, raw) ->
        discards

      Enum.any?(full, &trip_identity_match?(&1, raw)) ->
        [%{row: row_num, kind: :pair, value: raw, reason: :superseded} | discards]

      true ->
        [%{row: row_num, kind: :pair, value: raw, reason: :unknown_trip} | discards]
    end
  end

  @spec replace_entry(term(), term(), map()) ::
          {{change_op(), map(), map() | nil}, {[map()], boolean()}}
  defp replace_entry(row, key, resolutions) when is_map(row) do
    status = get(row, :status, "status")

    cond do
      status == :ready or status == "ready" ->
        resolve_ready_entry(row, key, resolutions)

      status == :decision or status == "decision" ->
        {{:needs_decision, row, nil}, {[], false}}

      true ->
        {{:skipped, row, nil}, {[], false}}
    end
  end

  defp replace_entry(row, _key, _resolutions) do
    row_map = if(is_map(row), do: row, else: %{})
    {{:skipped, row_map, nil}, {[], false}}
  end

  defp resolve_ready_entry(row, key, resolutions) do
    case Map.get(resolutions, key) do
      {:paired, wrapper} ->
        {{:change, row, wrapper.trip}, {[], custom_trip?(wrapper.trip)}}

      {:added} ->
        {{:add, row, nil}, {[], false}}

      {:undecided, trips} ->
        {{:needs_decision, row, nil}, {trips, false}}

      nil ->
        {{:needs_decision, row, nil}, {[], false}}
    end
  end

  # Attaches the candidate trips to undecided changes (step 9 validates
  # the eventual choice against them) and the `:custom_replaced` warning
  # to paired custom trips.
  @spec replace_enrich(change(), {[map()], boolean()}) :: change()
  defp replace_enrich(change, {candidates, custom?}) do
    change =
      if change.op == :needs_decision do
        Map.put(change, :candidates, candidates)
      else
        change
      end

    if change.op == :change and custom? do
      %{change | warnings: change.warnings ++ [:custom_replaced]}
    else
      change
    end
  end

  # Unpaired, unwithheld, non-frequency scope trips are removed. Any
  # refusal suppresses every removal, so Replace never deletes while
  # refused.
  @spec replace_removals([{map(), non_neg_integer()}], MapSet.t(), MapSet.t(), term()) :: [
          change()
        ]
  defp replace_removals(_scope_trips, _paired, _withheld, refusal) when not is_nil(refusal),
    do: []

  defp replace_removals(scope_trips, paired, withheld, _refusal) do
    scope_trips
    |> Enum.reject(fn {_wrapper, i} ->
      MapSet.member?(paired, i) or MapSet.member?(withheld, i)
    end)
    |> Enum.map(fn {wrapper, _i} -> wrapper end)
    |> Enum.reject(&frequency_trip?(&1.trip))
    |> Enum.map(&to_remove/1)
  end

  @spec to_remove(map()) :: change()
  defp to_remove(wrapper) do
    trip = wrapper.trip

    %{
      op: :remove,
      row: nil,
      trip: trip,
      diffs: [],
      timing: nil,
      trip_short_name: get(trip, :trip_short_name, "trip_short_name"),
      block_id: get(trip, :block_id, "block_id"),
      trip_headsign: get(trip, :trip_headsign, "trip_headsign"),
      warnings: []
    }
  end

  # Transfers name the natural trip, so the count comes from the removed
  # trip's own transfer ids; both `transfer_ids` and `transfers` lists
  # count, with an integer `transfer_count` fallback.
  @spec replace_transfer_count(change()) :: non_neg_integer()
  defp replace_transfer_count(%{op: :remove, trip: trip}), do: transfer_count(trip)
  defp replace_transfer_count(_change), do: 0

  @spec transfer_count(term()) :: non_neg_integer()
  defp transfer_count(trip) when is_map(trip) do
    ids =
      first_present([
        get(trip, :transfer_ids, "transfer_ids"),
        get(trip, :transfers, "transfers")
      ])

    cond do
      is_list(ids) ->
        length(ids)

      is_integer(ids) ->
        max(ids, 0)

      true ->
        case get(trip, :transfer_count, "transfer_count") do
          count when is_integer(count) -> max(count, 0)
          _count -> 0
        end
    end
  end

  defp transfer_count(_trip), do: 0

  # --- R13 metadata, warnings and decision validation (step 9, AC-16/AC-17) ---
  #
  # `apply_metadata/2` runs after timing assignment (the headsign default
  # needs the assigned timing): `:add` changes take the pasted values with
  # the effective default for a blank headsign; `:change` changes apply
  # the blank-cell keep rules and the XC-11 headsign test, list `diffs`
  # and refine exact pairs to `:unchanged` (an unchanged custom pair
  # keeps no `:custom_replaced`: nothing was replaced). `apply_warnings/3`
  # appends `:in_seat_retimed`, `:duplicate_trip_number` and
  # `:custom_headsign_moved` after any `:custom_replaced` step 8 set.
  # Step 10 hooks `:block_overlap` onto the same pass from the injected
  # block rows.

  @spec apply_metadata([change()], map()) :: [change()]
  defp apply_metadata(changes, by_pattern) do
    Enum.map(changes, fn
      %{op: :add} = change -> add_metadata(change, by_pattern)
      %{op: :change} = change -> change_metadata(change, by_pattern)
      change -> change
    end)
  end

  # New trips take the pasted values; a blank headsign takes the
  # effective default of the assigned timing. Never an empty string:
  # blanks normalize to `nil`.
  @spec add_metadata(change(), map()) :: change()
  defp add_metadata(change, by_pattern) do
    row = change.row

    headsign =
      case clean_meta(get(row, :trip_headsign, "trip_headsign")) do
        nil -> new_default(by_pattern, get(row, :pattern_id, "pattern_id"), change.timing)
        present -> present
      end

    %{
      change
      | trip_short_name: clean_meta(get(row, :trip_short_name, "trip_short_name")),
        block_id: clean_meta(get(row, :block_id, "block_id")),
        trip_headsign: headsign
    }
  end

  @spec change_metadata(change(), map()) :: change()
  defp change_metadata(change, by_pattern) do
    row = change.row
    trip = change.trip
    pattern_id = get(row, :pattern_id, "pattern_id")
    new_def = new_default(by_pattern, pattern_id, change.timing)

    number =
      clean_meta(get(row, :trip_short_name, "trip_short_name")) ||
        clean_meta(get(trip, :trip_short_name, "trip_short_name"))

    block =
      clean_meta(get(row, :block_id, "block_id")) ||
        clean_meta(get(trip, :block_id, "block_id"))

    headsign =
      case clean_meta(get(row, :trip_headsign, "trip_headsign")) do
        nil ->
          old_h = clean_meta(get(trip, :trip_headsign, "trip_headsign"))
          if old_h == old_default(by_pattern, trip), do: new_def, else: old_h

        present ->
          present
      end

    diffs = diff_list(row, trip, by_pattern, number, block, headsign)
    op = if diffs == [], do: :unchanged, else: :change

    warnings =
      if op == :unchanged, do: change.warnings -- [:custom_replaced], else: change.warnings

    %{
      change
      | op: op,
        trip_short_name: number,
        block_id: block,
        trip_headsign: headsign,
        diffs: diffs,
        warnings: warnings
    }
  end

  # Canonical order: `:times`, then the metadata fields.
  @spec diff_list(map(), map(), map(), term(), term(), term()) :: [atom()]
  defp diff_list(row, trip, by_pattern, number, block, headsign) do
    checks = [
      {:times, times_changed?(row, trip, by_pattern)},
      {:trip_short_name, number != clean_meta(get(trip, :trip_short_name, "trip_short_name"))},
      {:block_id, block != clean_meta(get(trip, :block_id, "block_id"))},
      {:trip_headsign, headsign != clean_meta(get(trip, :trip_headsign, "trip_headsign"))}
    ]

    for {field, true} <- checks, do: field
  end

  # Times change when the start or the final vector differs from the
  # trip's current timing. An unknown current timing (custom trips,
  # minimal scopes) always counts as changed: the apply rematerializes
  # the trip, so claiming `:unchanged` would be dishonest.
  @spec times_changed?(map(), map(), map()) :: boolean()
  defp times_changed?(row, trip, by_pattern) do
    get(row, :start_secs, "start_secs") != get(trip, :start_secs, "start_secs") or
      get(row, :key, "key") != old_timing_key(by_pattern, trip)
  end

  @spec apply_warnings([change()], map(), [map()]) :: [change()]
  defp apply_warnings(changes, by_pattern, scope_trip_maps) do
    fellows =
      changes
      |> Enum.with_index()
      |> Enum.filter(fn {change, _i} ->
        change.op in [:add, :change, :unchanged] and is_binary(change.trip_short_name)
      end)
      |> Enum.map(fn {change, i} -> {i, change.trip_short_name} end)

    changes
    |> Enum.with_index()
    |> Enum.map(fn {change, i} ->
      warn_change(change, i, by_pattern, scope_trip_maps, fellows)
    end)
  end

  @spec warn_change(change(), non_neg_integer(), map(), [map()], [{non_neg_integer(), String.t()}]) ::
          change()
  defp warn_change(%{op: op} = change, i, by_pattern, scope_trip_maps, fellows)
       when op in [:add, :change, :unchanged] do
    warnings = change.warnings

    warnings =
      if op == :change and :times in change.diffs and in_seat_trip?(change.trip) do
        warnings ++ [:in_seat_retimed]
      else
        warnings
      end

    warnings =
      if duplicate_number?(change, i, scope_trip_maps, fellows) do
        warnings ++ [:duplicate_trip_number]
      else
        warnings
      end

    warnings =
      if op == :change and headsign_moved?(change, by_pattern) do
        warnings ++ [:custom_headsign_moved]
      else
        warnings
      end

    %{change | warnings: warnings}
  end

  defp warn_change(change, _i, _by_pattern, _scope_trip_maps, _fellows), do: change

  # A kept trip number that equals another trip's on the same calendar,
  # whether the number was kept (blank cell, including `:unchanged`) or
  # pasted. Scope trips are the calendar; fellow applied rows will join
  # it. The matched trip itself never counts.
  @spec duplicate_number?(change(), non_neg_integer(), [map()], [
          {
            non_neg_integer(),
            String.t()
          }
        ]) :: boolean()
  defp duplicate_number?(change, index, scope_trip_maps, fellows) do
    number = change.trip_short_name

    is_binary(number) and
      (Enum.any?(scope_trip_maps, fn trip ->
         not same_trip?(trip, change.trip) and
           clean_meta(get(trip, :trip_short_name, "trip_short_name")) == number
       end) or
         Enum.any?(fellows, fn {j, other} -> j != index and other == number end))
  end

  # Two trip maps name the same trip when they share a non-nil `id` or
  # natural `trip_id`; maps without identifiers only match themselves.
  @spec same_trip?(term(), term()) :: boolean()
  defp same_trip?(a, b) when is_map(a) and is_map(b) do
    ids = fn trip ->
      [get(trip, :id, "id"), get(trip, :trip_id, "trip_id")] |> Enum.reject(&is_nil/1)
    end

    ids.(a) -- ids.(b) != ids.(a) or a == b
  end

  defp same_trip?(_a, _b), do: false

  @spec in_seat_trip?(term()) :: boolean()
  defp in_seat_trip?(trip) when is_map(trip) do
    flag =
      first_present([
        get(trip, :in_seat_transfer, "in_seat_transfer"),
        get(trip, :in_seat, "in_seat"),
        get(trip, :has_in_seat_transfer, "has_in_seat_transfer")
      ])

    ids =
      first_present([
        get(trip, :in_seat_transfer_ids, "in_seat_transfer_ids"),
        get(trip, :in_seat_transfers, "in_seat_transfers")
      ])

    truthy?(flag) or (is_list(ids) and ids != [])
  end

  defp in_seat_trip?(_trip), do: false

  # A kept custom headsign (blank pasted headsign, final equals the
  # trip's own non-default value) on a trip whose route pattern, timed
  # pattern or last stop changed. An explicit pasted headsign is an
  # override, not a keep, and never warns here.
  @spec headsign_moved?(change(), map()) :: boolean()
  defp headsign_moved?(%{row: row, trip: trip, timing: timing, trip_headsign: final}, by_pattern)
       when is_map(row) and is_map(trip) do
    pattern_id = get(row, :pattern_id, "pattern_id")
    new_def = new_default(by_pattern, pattern_id, timing)

    kept? = is_nil(clean_meta(get(row, :trip_headsign, "trip_headsign")))
    custom? = is_binary(final) and final != new_def

    kept? and custom? and moved_pattern?(row, trip, timing, by_pattern)
  end

  defp headsign_moved?(_change, _by_pattern), do: false

  @spec moved_pattern?(map(), map(), timing_ref(), map()) :: boolean()
  defp moved_pattern?(row, trip, timing, by_pattern) do
    route_changed?(row, trip, by_pattern) or timing_changed?(timing, trip) or
      last_stop_changed?(row, trip, by_pattern)
  end

  @spec route_changed?(map(), map(), map()) :: boolean()
  defp route_changed?(row, trip, by_pattern) do
    case trip_pattern(by_pattern, trip) do
      nil -> false
      %{id: id} -> id != get(row, :pattern_id, "pattern_id")
    end
  end

  # A pending timing is new by definition; an unknown old timing cannot
  # be proven the same, so it counts as changed (as in `times_changed?`).
  @spec timing_changed?(timing_ref(), map()) :: boolean()
  defp timing_changed?(timing, trip) do
    old_id =
      get(trip, :timed_pattern_id, "timed_pattern_id") || get(trip, :timing_id, "timing_id")

    case timing do
      {:existing, id} -> id != old_id
      {:new, _name} -> true
      _timing -> false
    end
  end

  @spec last_stop_changed?(map(), map(), map()) :: boolean()
  defp last_stop_changed?(row, trip, by_pattern) do
    new_rows = get(row, :timing_rows, "timing_rows") || []

    case old_timing(by_pattern, trip) do
      nil -> true
      %{rows: old_rows} -> row_tuple(List.last(old_rows)) != row_tuple(List.last(new_rows))
    end
  end

  @spec row_tuple(map() | nil) :: tuple() | nil
  defp row_tuple(nil), do: nil

  defp row_tuple(row) when is_map(row) do
    {get(row, :arrival_offset, "arrival_offset"), get(row, :departure_offset, "departure_offset"),
     get(row, :timepoint, "timepoint"), get(row, :pickup_type, "pickup_type"),
     get(row, :drop_off_type, "drop_off_type"), get(row, :stop_headsign, "stop_headsign")}
  end

  # The new effective default: the assigned timing's headsign, else the
  # row pattern's headsign. A pending timing has no headsign yet, so new
  # trips fall through to the pattern default.
  @spec new_default(map(), term(), timing_ref()) :: String.t() | nil
  defp new_default(by_pattern, pattern_id, timing) do
    timing_h =
      case timing do
        {:existing, id} -> existing_timing_headsign(by_pattern, pattern_id, id)
        _timing -> nil
      end

    timing_h || pattern_headsign(by_pattern, pattern_id)
  end

  # The old effective default: the trip's timing headsign, else its
  # pattern's headsign (XC-11). Blank stored headsigns read as `nil` so
  # an empty default never shadows the pattern's.
  @spec old_default(map(), term()) :: String.t() | nil
  defp old_default(by_pattern, trip) when is_map(trip) do
    old_timing_headsign(by_pattern, trip) || old_pattern_headsign(by_pattern, trip)
  end

  defp old_default(_by_pattern, _trip), do: nil

  @spec pattern_headsign(map(), term()) :: String.t() | nil
  defp pattern_headsign(by_pattern, pattern_id) do
    case Map.get(by_pattern, pattern_id) do
      %{headsign: headsign} -> clean_meta(headsign)
      _pattern -> nil
    end
  end

  @spec existing_timing_headsign(map(), term(), term()) :: String.t() | nil
  defp existing_timing_headsign(by_pattern, pattern_id, timing_id) do
    case Map.get(by_pattern, pattern_id) do
      %{timings: timings} -> timing_headsign_in(timings, timing_id)
      _pattern -> nil
    end
  end

  @spec old_timing_headsign(map(), term()) :: String.t() | nil
  defp old_timing_headsign(by_pattern, trip) when is_map(trip) do
    case old_timing(by_pattern, trip) do
      %{headsign: headsign} -> clean_meta(headsign)
      nil -> nil
    end
  end

  defp old_timing_headsign(_by_pattern, _trip), do: nil

  @spec old_pattern_headsign(map(), map()) :: String.t() | nil
  defp old_pattern_headsign(by_pattern, trip) do
    case trip_pattern(by_pattern, trip) do
      %{headsign: headsign} -> clean_meta(headsign)
      nil -> nil
    end
  end

  @spec old_timing_key(map(), term()) :: binary() | nil
  defp old_timing_key(by_pattern, trip) do
    case old_timing(by_pattern, trip) do
      %{key: key} -> key
      nil -> nil
    end
  end

  @spec old_timing(map(), term()) :: map() | nil
  defp old_timing(by_pattern, trip) when is_map(trip) do
    timing_id =
      get(trip, :timed_pattern_id, "timed_pattern_id") || get(trip, :timing_id, "timing_id")

    if is_nil(timing_id) do
      nil
    else
      by_pattern
      |> Map.values()
      |> Enum.find_value(fn %{timings: timings} ->
        Enum.find(timings, &(&1.id == timing_id))
      end)
    end
  end

  defp old_timing(_by_pattern, _trip), do: nil

  @spec timing_headsign_in([map()], term()) :: String.t() | nil
  defp timing_headsign_in(timings, timing_id) do
    case Enum.find(timings, &(&1.id == timing_id)) do
      %{headsign: headsign} -> clean_meta(headsign)
      nil -> nil
    end
  end

  @spec trip_pattern(map(), term()) :: map() | nil
  defp trip_pattern(by_pattern, trip) when is_map(trip) do
    ref = get(trip, :route_pattern_id, "route_pattern_id") || get(trip, :pattern_id, "pattern_id")

    if is_nil(ref) do
      nil
    else
      Enum.find(Map.values(by_pattern), &MapSet.member?(&1.refs, ref))
    end
  end

  defp trip_pattern(_by_pattern, _trip), do: nil

  # Blank (nil, empty or whitespace-only) normalizes to `nil` so a
  # blank cell never writes an empty value (INV-4); other binaries are
  # trimmed, anything else passes through untouched.
  @spec clean_meta(term()) :: term()
  defp clean_meta(nil), do: nil

  defp clean_meta(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_meta(value), do: value

  @spec blank_choice?(term()) :: boolean()
  defp blank_choice?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_choice?(_value), do: false

  # --- Decision validation (critique S2 / PM-10) ---
  #
  # Pattern choices are validated up front (a stale `:chosen` pattern
  # withholds its row via the `misfit` set); pairing choices are
  # validated while their group resolves; keeps and strays are validated
  # afterwards. Every stale choice lands in `discarded_decisions` in
  # `{row, kind}` order instead of being applied.

  # Validates `pattern_id` choices: unknown patterns, choices for rows
  # that resolved elsewhere and chosen patterns the row no longer fits
  # (estimates outside the pasted span — only a forced choice can
  # produce those, per `RowResolver`). Returns the withheld row numbers
  # plus the discards.
  @spec validate_patterns(map(), [map()], map()) :: {MapSet.t(), [discarded_decision()]}
  defp validate_patterns(decisions, rows, by_pattern) do
    row_by_num =
      rows
      |> Enum.filter(&is_map/1)
      |> Map.new(fn row -> {to_row_num(get(row, :row, "row")), row} end)
      |> Map.delete(nil)

    {misfit, discards} =
      Enum.reduce(decisions, {MapSet.new(), []}, fn {num, decision}, acc ->
        validate_pattern_decision(acc, num, decision, row_by_num, by_pattern)
      end)

    {misfit, Enum.reverse(discards)}
  end

  defp validate_pattern_decision({misfit, discards}, num, decision, row_by_num, by_pattern) do
    case decision_pattern(decision) do
      nil -> {misfit, discards}
      choice -> validate_pattern_row(misfit, discards, num, choice, row_by_num, by_pattern)
    end
  end

  defp validate_pattern_row(misfit, discards, num, choice, row_by_num, by_pattern) do
    case Map.get(row_by_num, num) do
      nil ->
        {misfit, [%{row: num, kind: :pattern, value: choice, reason: :unknown_row} | discards]}

      row ->
        check_pattern_known(misfit, discards, num, row, choice, by_pattern)
    end
  end

  defp check_pattern_known(misfit, discards, num, row, choice, by_pattern) do
    if Map.has_key?(by_pattern, choice) do
      validate_pattern_choice(misfit, discards, num, row, choice)
    else
      {misfit, [%{row: num, kind: :pattern, value: choice, reason: :unknown_pattern} | discards]}
    end
  end

  @spec decision_pattern(term()) :: term()
  defp decision_pattern(decision) when is_map(decision), do: Map.get(decision, :pattern)
  defp decision_pattern(_decision), do: nil

  @spec validate_pattern_choice(MapSet.t(), [discarded_decision()], pos_integer(), map(), term()) ::
          {MapSet.t(), [discarded_decision()]}
  defp validate_pattern_choice(misfit, discards, num, row, choice) do
    how = get(row, :how, "how")

    cond do
      get(row, :pattern_id, "pattern_id") != choice ->
        {misfit, [%{row: num, kind: :pattern, value: choice, reason: :not_applied} | discards]}

      (how == :chosen or how == "chosen") and outside_span?(row) ->
        {MapSet.put(misfit, num),
         [%{row: num, kind: :pattern, value: choice, reason: :pattern_misfit} | discards]}

      true ->
        {misfit, discards}
    end
  end

  # Estimates outside the pasted span can only come from a forced
  # `:chosen` pattern that does not fit: the estimates stack on the
  # nearest anchor instead of sitting between pasted times.
  @spec outside_span?(map()) :: boolean()
  defp outside_span?(row) do
    rows = get(row, :timing_rows, "timing_rows")
    indexed = if is_list(rows), do: Enum.with_index(rows), else: []
    pasted = for {timing_row, i} <- indexed, pasted_stop?(timing_row), do: i

    case pasted do
      [] ->
        true

      _ ->
        {first, last} = Enum.min_max(pasted)

        Enum.any?(indexed, fn {timing_row, i} ->
          not pasted_stop?(timing_row) and (i < first or i > last)
        end)
    end
  end

  @spec pasted_stop?(term()) :: boolean()
  defp pasted_stop?(row) when is_map(row), do: get(row, :timepoint, "timepoint") in [1, "1", true]
  defp pasted_stop?(_row), do: false

  # A truthy `keep` ("Add anyway") only applies to a duplicate. In
  # Replace nothing is a duplicate, so every keep is stale there; in
  # Add the duplicate shape is recomputed without keeps so a keep that
  # changed nothing is reported instead of silently kept.
  @spec keep_discards(:add | :replace, map(), [map()], map(), [map()]) :: [discarded_decision()]
  defp keep_discards(:replace, decisions, rows, _by_pattern, _trips) do
    known = known_rows(rows)

    Enum.reduce(decisions, [], fn {num, decision}, acc ->
      keep_replace_discard(acc, num, decision, known)
    end)
  end

  defp keep_discards(:add, decisions, rows, by_pattern, trips) do
    known = known_rows(rows)
    duplicates = duplicate_identities(rows, by_pattern, trips)

    Enum.reduce(decisions, [], fn {num, decision}, acc ->
      keep_add_discard(acc, num, decision, known, duplicates)
    end)
  end

  defp keep_replace_discard(acc, num, decision, known) do
    if truthy?(Map.get(decision, :keep)) do
      keep_replace_reason(acc, num, decision, known)
    else
      acc
    end
  end

  defp keep_replace_reason(acc, num, decision, known) do
    reason = if MapSet.member?(known, num), do: :not_a_duplicate, else: :unknown_row
    [%{row: num, kind: :keep, value: Map.get(decision, :keep), reason: reason} | acc]
  end

  defp keep_add_discard(acc, num, decision, known, duplicates) do
    if truthy?(Map.get(decision, :keep)) do
      classify_keep_discard(acc, num, decision, known, duplicates)
    else
      acc
    end
  end

  defp classify_keep_discard(acc, num, decision, known, duplicates) do
    cond do
      not MapSet.member?(known, num) ->
        [
          %{row: num, kind: :keep, value: Map.get(decision, :keep), reason: :unknown_row}
          | acc
        ]

      MapSet.member?(duplicates, num) ->
        acc

      true ->
        [
          %{row: num, kind: :keep, value: Map.get(decision, :keep), reason: :not_a_duplicate}
          | acc
        ]
    end
  end

  # Row numbers the input actually carries (decision targets resolve
  # against these).
  @spec known_rows([term()]) :: MapSet.t()
  defp known_rows(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.map(&to_row_num(get(&1, :row, "row")))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # Rows that would be `:duplicate` with every keep ignored: the exact
  # `mark_ready` duplicate test (existing trip or earlier accepted row
  # at the same identity) walked in input order.
  @spec duplicate_identities([term()], map(), [map()]) :: MapSet.t()
  defp duplicate_identities(rows, by_pattern, trips) do
    {duplicates, _accepted} =
      Enum.reduce(rows, {MapSet.new(), MapSet.new()}, fn row, acc ->
        row_map = if(is_map(row), do: row, else: %{})
        check_duplicate_identity(acc, row_map, by_pattern, trips)
      end)

    duplicates
  end

  defp check_duplicate_identity(acc, row_map, by_pattern, trips) do
    if ready_complete?(row_map) do
      track_row_identity(acc, row_map, by_pattern, trips)
    else
      acc
    end
  end

  defp track_row_identity({duplicates, accepted}, row_map, by_pattern, trips) do
    pattern_id = get(row_map, :pattern_id, "pattern_id")
    start_secs = get(row_map, :start_secs, "start_secs")
    identity = {pattern_id, start_secs}

    if not is_nil(find_trip(by_pattern, trips, pattern_id, start_secs)) or
         MapSet.member?(accepted, identity) do
      num = to_row_num(get(row_map, :row, "row"))
      {if(is_nil(num), do: duplicates, else: MapSet.put(duplicates, num)), accepted}
    else
      {duplicates, MapSet.put(accepted, identity)}
    end
  end

  @spec ready_complete?(map()) :: boolean()
  defp ready_complete?(row) do
    status = get(row, :status, "status")

    (status == :ready or status == "ready") and
      not is_nil(get(row, :pattern_id, "pattern_id")) and
      not is_nil(get(row, :start_secs, "start_secs")) and
      not is_nil(get(row, :key, "key"))
  end

  # Pair decisions for rows that never entered a group (Replace): the
  # row is skipped, undecided upstream or gone. Group members were
  # validated while resolving.
  @spec stray_pair_discards(map(), [term()], [{term(), map()}]) :: [discarded_decision()]
  defp stray_pair_discards(decisions, rows, accepted) do
    known = known_rows(rows)

    accepted_nums =
      accepted |> Enum.map(&elem(&1, 0)) |> Enum.filter(&is_integer/1) |> MapSet.new()

    Enum.reduce(decisions, [], fn {num, decision}, acc ->
      raw = Map.get(decision, :pair)

      cond do
        is_nil(raw) or blank_choice?(raw) or neither_choice?(raw) ->
          acc

        MapSet.member?(accepted_nums, num) ->
          acc

        not MapSet.member?(known, num) ->
          [%{row: num, kind: :pair, value: raw, reason: :unknown_row} | acc]

        true ->
          [%{row: num, kind: :pair, value: raw, reason: :unknown_trip} | acc]
      end
    end)
  end

  # Pair decisions never pair in Add mode; `"neither"` stays silent
  # everywhere and blanks choose nothing.
  @spec add_pair_discards(map(), [term()]) :: [discarded_decision()]
  defp add_pair_discards(decisions, rows) do
    known = known_rows(rows)

    Enum.reduce(decisions, [], fn {num, decision}, acc ->
      raw = Map.get(decision, :pair)

      cond do
        is_nil(raw) or blank_choice?(raw) or neither_choice?(raw) ->
          acc

        not MapSet.member?(known, num) ->
          [%{row: num, kind: :pair, value: raw, reason: :unknown_row} | acc]

        true ->
          [%{row: num, kind: :pair, value: raw, reason: :not_applicable} | acc]
      end
    end)
  end

  @spec finalize_discards([discarded_decision()]) :: [discarded_decision()]
  defp finalize_discards(discards) do
    Enum.sort_by(discards, fn discard ->
      {discard.row || 1_000_000_000, kind_order(discard.kind)}
    end)
  end

  @spec kind_order(:pair | :pattern | :keep) :: non_neg_integer()
  defp kind_order(:pair), do: 0
  defp kind_order(:pattern), do: 1
  defp kind_order(:keep), do: 2
  defp kind_order(_kind), do: 3

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
  # Applied means `:add` (Add mode) or `:add`/`:change` (Replace); removals
  # write no block value.
  @spec writes_blocks?([change()]) :: boolean()
  defp writes_blocks?(changes) do
    Enum.any?(changes, fn change ->
      change.op in [:add, :change] and present?(change.block_id)
    end)
  end

  @spec present?(term()) :: boolean()
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  # --- Vehicles (step 10, R17 / AC-18) ---
  #
  # `vehicles.before` is the peak over every scope trip span (both
  # directions live in `scope.trips`, so every entry counts). `after` is
  # the before spans minus the old spans of `:remove` and `:change`
  # trips plus the new spans of `:add` and `:change` rows. Rows that are
  # not applied (`:unchanged`, `:duplicate`, `:skipped`,
  # `:needs_decision`) never count: unchanged spans stay inside before,
  # the rest contribute nothing. Both peaks use
  # `Summary.peak_vehicles/1` over `%{start_secs:, end_secs:}` spans —
  # the same term `Schedules` builds from `trip_bounds/1`/`spans_for/1`
  # (frequency templates keep `headway_secs`/`until_secs` so the peak
  # expands them the same way).
  #
  # Scope trips carry their span as `span` (`%{start_secs:, end_secs:}`
  # with optional `headway_secs`/`until_secs`, or a `{start, end}`
  # tuple), as `spans` (a list of those terms), or as `start_secs` plus
  # `end_secs` directly on the trip. Trips without a usable span
  # contribute no span. Planned spans derive from the row: `start_secs`
  # (the first departure) to `start_secs` plus the last timing row's
  # arrival offset (the last arrival, matching `trip_bounds/1` which runs
  # first departure to last arrival).
  @spec plan_vehicles([map()], [change()]) :: %{
          before: non_neg_integer(),
          after: non_neg_integer()
        }
  defp plan_vehicles(raw_trips, changes) do
    before_spans = Enum.flat_map(raw_trips, &trip_spans/1)

    removed =
      for %{op: op, trip: trip} <- changes,
          op in [:remove, :change],
          is_map(trip),
          do: trip

    remaining =
      Enum.reject(raw_trips, fn trip ->
        Enum.any?(removed, &same_trip?(&1, trip))
      end)

    remaining_spans = Enum.flat_map(remaining, &trip_spans/1)

    new_spans =
      Enum.flat_map(changes, fn
        %{op: op, row: row} when op in [:add, :change] and is_map(row) ->
          case row_span(row) do
            nil -> []
            span -> [span]
          end

        _change ->
          []
      end)

    before = Summary.peak_vehicles(before_spans)
    after_peak = Summary.peak_vehicles(remaining_spans ++ new_spans)

    %{before: before.count, after: after_peak.count}
  end

  @spec trip_spans(term()) :: [map()]
  defp trip_spans(trip) when is_map(trip) do
    spans = get(trip, :spans, "spans")
    span = get(trip, :span, "span")

    cond do
      is_list(spans) ->
        Enum.flat_map(spans, &span_term/1)

      not is_nil(span) ->
        span_term(span)

      is_integer(get(trip, :start_secs, "start_secs")) and
          is_integer(get(trip, :end_secs, "end_secs")) ->
        [
          %{
            start_secs: get(trip, :start_secs, "start_secs"),
            end_secs: get(trip, :end_secs, "end_secs")
          }
        ]

      true ->
        []
    end
  end

  defp trip_spans(_trip), do: []

  @spec span_term(term()) :: [map()]
  defp span_term({start_secs, end_secs})
       when is_integer(start_secs) and is_integer(end_secs) do
    [%{start_secs: start_secs, end_secs: end_secs}]
  end

  defp span_term(span) when is_map(span) do
    start_secs = get(span, :start_secs, "start_secs")
    end_secs = get(span, :end_secs, "end_secs")

    if is_integer(start_secs) and is_integer(end_secs) do
      base = %{start_secs: start_secs, end_secs: end_secs}

      base =
        case get(span, :headway_secs, "headway_secs") do
          headway when is_integer(headway) and headway > 0 ->
            Map.put(base, :headway_secs, headway)

          _headway ->
            base
        end

      base =
        case get(span, :until_secs, "until_secs") do
          until_secs when is_integer(until_secs) ->
            Map.put(base, :until_secs, until_secs)

          _until ->
            base
        end

      [base]
    else
      []
    end
  end

  defp span_term(_span), do: []

  @spec row_span(map()) :: map() | nil
  defp row_span(row) when is_map(row) do
    start_secs = get(row, :start_secs, "start_secs")
    rows = get(row, :timing_rows, "timing_rows")

    if is_integer(start_secs) and is_list(rows) and rows != [] do
      offset = row_end_offset(List.last(rows))
      %{start_secs: start_secs, end_secs: start_secs + offset}
    else
      nil
    end
  end

  defp row_span(_row), do: nil

  defp row_end_offset(last) do
    case get(last, :arrival_offset, "arrival_offset") do
      offset when is_integer(offset) -> offset
      _arrival -> row_departure_offset(last)
    end
  end

  defp row_departure_offset(last) do
    case get(last, :departure_offset, "departure_offset") do
      offset when is_integer(offset) -> offset
      _departure -> 0
    end
  end

  @spec raw_scope_trips(map()) :: [map()]
  defp raw_scope_trips(scope_map) do
    case get(scope_map, :trips, "trips") do
      trips when is_list(trips) -> Enum.filter(trips, &is_map/1)
      _trips -> []
    end
  end

  @spec scope_service_id(map()) :: String.t() | nil
  defp scope_service_id(scope_map) do
    case get(scope_map, :calendar, "calendar") do
      calendar when is_map(calendar) -> get(calendar, :service_id, "service_id")
      _calendar -> nil
    end
  end

  # --- Block overlaps (step 10, R16 / AC-17) ---
  #
  # For every applied `:add`/`:change` carrying a final block value, the
  # planned trip becomes a `Checks.trip_row()` (same calendar as the
  # scope) and joins the injected block rows for that block. `sequence/1`
  # plus `overlap_pairs/1` over the combined list marks each planned trip
  # in an overlapping pair with `:block_overlap`. The old version of a
  # `:change` is excluded from its own block (it is replaced), so a
  # retimed trip never overlaps itself. Two pasted trips on one block
  # warn together even when no block row exists yet. Only same-calendar
  # block rows count; when the scope carries no calendar every injected
  # row counts. Block rows must be `trip_row` maps with atom keys (the
  # shape `load_block_rows/4` returns); rows without the `Checks` keys
  # are ignored.
  @spec apply_block_overlaps([change()], term(), term()) :: [change()]
  defp apply_block_overlaps(changes, block_rows, service_id) do
    existing = normalize_block_rows(block_rows, service_id)
    planned = planned_block_entries(changes, service_id)

    if planned == [] do
      changes
    else
      mark_block_overlaps(changes, planned, existing)
    end
  end

  defp mark_block_overlaps(changes, planned, existing) do
    by_block = Enum.group_by(planned, fn {_idx, block_id, _row} -> block_id end)

    overlapping =
      Enum.reduce(by_block, MapSet.new(), fn {block_id, entries}, acc ->
        overlap_planned_ids(entries, block_id, existing, changes, acc)
      end)

    changes
    |> Enum.with_index()
    |> Enum.map(&mark_block_overlap(&1, overlapping))
  end

  defp mark_block_overlap({change, idx}, overlapping) do
    if MapSet.member?(overlapping, idx) and change.op in [:add, :change] and
         :block_overlap not in change.warnings do
      %{change | warnings: change.warnings ++ [:block_overlap]}
    else
      change
    end
  end

  @spec normalize_block_rows(term(), term()) :: [map()]
  defp normalize_block_rows(block_rows, service_id) when is_list(block_rows) do
    Enum.filter(block_rows, fn row ->
      is_map(row) and is_map_key(row, :plottable?) and is_map_key(row, :frequency?) and
        is_map_key(row, :first_arrival) and is_map_key(row, :last_departure) and
        is_map_key(row, :id) and block_service?(row, service_id)
    end)
  end

  defp normalize_block_rows(_block_rows, _service_id), do: []

  defp block_service?(_row, service_id) when not is_binary(service_id), do: true
  defp block_service?(row, service_id), do: get(row, :service_id, "service_id") == service_id

  @spec planned_block_entries([change()], term()) :: [
          {non_neg_integer(), String.t(), map()}
        ]
  defp planned_block_entries(changes, service_id) do
    changes |> Enum.with_index() |> Enum.flat_map(&planned_block_entry(&1, service_id))
  end

  defp planned_block_entry({change, idx}, service_id) do
    if change.op in [:add, :change] and present?(change.block_id) and is_map(change.row) do
      case planned_trip_row(change, idx, service_id) do
        nil -> []
        planned -> [{idx, change.block_id, planned}]
      end
    else
      []
    end
  end

  @spec planned_trip_row(change(), non_neg_integer(), term()) :: map() | nil
  defp planned_trip_row(change, idx, service_id) do
    row = change.row
    start_secs = get(row, :start_secs, "start_secs")
    rows = get(row, :timing_rows, "timing_rows")

    if is_integer(start_secs) and is_list(rows) and rows != [] do
      first = List.first(rows)
      last = List.last(rows)
      {id, trip_id} = planned_identity(change, row, idx)

      first_arrival = start_secs + offset_value(first, :arrival_offset)
      first_departure = start_secs + offset_value(first, :departure_offset)
      last_arrival = start_secs + offset_value(last, :arrival_offset)
      last_departure = start_secs + offset_value(last, :departure_offset)

      %{
        id: id,
        trip_id: trip_id,
        route_id: nil,
        service_id: service_id,
        block_id: change.block_id,
        trip_headsign: change.trip_headsign,
        route_pattern_id: nil,
        updated_at: nil,
        frequency?: false,
        headway_secs: nil,
        first_arrival: first_arrival,
        first_departure: first_departure,
        last_arrival: last_arrival,
        last_departure: last_departure,
        first_stop: nil,
        last_stop: nil,
        plottable?: is_integer(first_arrival) and is_integer(last_departure)
      }
    else
      nil
    end
  end

  @spec offset_value(map(), atom()) :: integer()
  defp offset_value(row, key) when is_map(row) do
    string_key = Atom.to_string(key)

    case get(row, key, string_key) do
      offset when is_integer(offset) -> offset
      _offset -> 0
    end
  end

  defp offset_value(_row, _key), do: 0

  @spec planned_identity(change(), map(), non_neg_integer()) :: {term(), String.t()}
  defp planned_identity(%{op: :change, trip: trip}, _row, idx) when is_map(trip) do
    id = get(trip, :id, "id") || "paste-change-#{idx}"
    trip_id = get(trip, :trip_id, "trip_id") || to_string(id)
    {id, trip_id}
  end

  defp planned_identity(%{row: row}, _row_arg, idx) do
    number = if is_map(row), do: get(row, :row, "row") || idx, else: idx
    {"paste-row-#{number}", "paste-row-#{number}"}
  end

  @spec overlap_planned_ids(
          [{non_neg_integer(), String.t(), map()}],
          String.t(),
          [map()],
          [change()],
          MapSet.t()
        ) :: MapSet.t()
  defp overlap_planned_ids(entries, block_id, existing, changes, acc) do
    planned_rows = Enum.map(entries, &elem(&1, 2))
    id_to_idx = Map.new(entries, fn {idx, _block_id, planned} -> {planned.id, idx} end)

    old_trips =
      for {idx, _block_id, _planned} <- entries,
          change = Enum.at(changes, idx),
          change.op == :change,
          is_map(change.trip),
          do: change.trip

    existing_here =
      Enum.reject(existing, fn row ->
        get(row, :block_id, "block_id") != block_id or
          Enum.any?(old_trips, &same_trip?(&1, row))
      end)

    combined = existing_here ++ planned_rows
    pairs = combined |> Checks.sequence() |> Checks.overlap_pairs()

    Enum.reduce(pairs, acc, fn {earlier, later}, inner ->
      inner =
        case Map.fetch(id_to_idx, earlier.id) do
          {:ok, idx} -> MapSet.put(inner, idx)
          :error -> inner
        end

      case Map.fetch(id_to_idx, later.id) do
        {:ok, idx} -> MapSet.put(inner, idx)
        :error -> inner
      end
    end)
  end

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
            headsign: get(pattern, :headsign, "headsign"),
            name: get(pattern, :name, "name"),
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

          %{
            id: id,
            name: get(timing, :name, "name"),
            headsign: get(timing, :headsign, "headsign"),
            rows: rows,
            key: timing_key(rows)
          }
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
    %{
      keep: get(decision, :keep, "keep"),
      pair: replace_pair_value(decision),
      pattern: pattern_choice_value(decision)
    }
  end

  defp normalize_decision(_decision), do: %{keep: nil, pair: nil, pattern: nil}

  # The RowResolver pattern choice (`pattern_id`, alias `:pattern`): a
  # blank choice is no choice. Step 9 validates it against the scope
  # patterns and the row it resolved to.
  @spec pattern_choice_value(map()) :: term()
  defp pattern_choice_value(decision) do
    case first_present([
           get(decision, :pattern_id, "pattern_id"),
           get(decision, :pattern, "pattern")
         ]) do
      choice when is_binary(choice) ->
        if String.trim(choice) == "", do: nil, else: choice

      choice ->
        choice
    end
  end

  # The Replace pairing choice lives beside the Add `keep` flag so one
  # decisions map serves both modes. Aliases cover the LiveView field
  # names step 27 may use; Replace reads only `:pair`.
  @spec replace_pair_value(map()) :: term()
  defp replace_pair_value(decision) do
    first_present([
      get(decision, :pair, "pair"),
      get(decision, :trip_id, "trip_id"),
      get(decision, :choice, "choice"),
      get(decision, :pairing, "pairing"),
      get(decision, :trip, "trip")
    ])
  end

  @spec first_present([term()]) :: term()
  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

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
