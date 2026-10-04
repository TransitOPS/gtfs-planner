defmodule GtfsPlanner.Gtfs.ReleaseComparison.AssistantContext do
  @moduledoc """
  Freezes one finished native comparison into the AI04 shared source-snapshot
  contract, so the assistant answers from an immutable copy of exactly the rows
  the page is showing.

  This module owns the *projection* and nothing else. Admission - the whole
  context's byte measurement, the payload's JSON compatibility and the digest -
  belongs to `GtfsPlanner.Agents.Scope.with_source_snapshot/2`, which is the AI04
  step 1 seam this package consumes rather than reimplements. No digest is
  computed here and no caller may supply one: `selected_digest` and
  `result_digest` are both copied from the comparison's own deterministic
  digest, so two identical comparisons freeze to two identical payloads and two
  different scopes never share one identity.

  Three properties are load-bearing:

    * **A refusal attaches nothing.** `{:error, :source_too_large}` and
      `{:error, :invalid_scope}` are returned, never a partial snapshot and never
      a truncated summary. The shared contract already returns the untouched
      context in its error cases and this module passes that answer through, so
      the caller keeps whatever it had - including the native result it was
      showing.

    * **Nothing is silently shortened.** No row is dropped, no list is capped
      and no string is clipped to make room. Scalar strings are copied at their
      source length; a payload that does not fit is refused as a whole, which is
      the only answer that keeps "what the helper read" equal to "what the
      comparison proved".

    * **No host handles travel.** Every value is a plain string, number,
      boolean, `nil`, list or map. There is no pid, no ETS reference, no
      process dictionary, no LiveView assign, no filesystem path and no URL. A
      row reference is the typed physical GTFS member and row - `trips.txt`
      row 12 - which is evidence, not a handle to one.

  The admitted copy is immutable and bounded by the *original* artifacts' own
  retention: `expires_at` is the earliest of the two exports' expiries, copied
  rather than recomputed, so freezing never extends the life of a retained
  artifact and losing the helper context ends its usability without touching
  the source's own TTL.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare

  @schema_version 1

  @typedoc """
  One admitted resource context, or the two reasons this package's translation
  of the shared contract produces.

  `:source_too_large` is the shared `{:error, :too_large}`: the whole serialized
  context exceeded AI04's byte ceiling, so nothing is attached. `:invalid_scope`
  covers both a narrowing that names no unit or date in this result and the
  shared `{:error, :invalid_snapshot}`.
  """
  @type freeze_result ::
          {:ok, Scope.resource_context()} | {:error, :source_too_large | :invalid_scope}

  @doc """
  Freezes `result` for the assistant as the shared `release_comparison` snapshot.

  `context` is a `GtfsPlanner.Agents.Scope` resource context and `result` is the
  delivered native comparison (`%{fingerprint:, window:, left:, right:,
  comparison:}`). `selection` is either `:all` for the complete comparison, or
  `%{route_pair_keys: [String.t()], dates: [Date.t()]}` for an explicit narrowing.

  A narrowed selection is re-validated here against the result it narrows
  rather than trusted from the caller, and the narrowed body - its scoped
  totals, its exclusions and its own digest - is recomputed by the same
  `Compare.narrow/2` the page used. That is what keeps a narrowed snapshot
  truthful: it can never reuse the complete result's totals, and its omitted
  groups stay disclosed in `exclusions`.

  Returns `{:ok, admitted_context}` on success, or `{:error, reason}` where a
  rejected source never becomes a half-attached one.
  """
  @spec freeze(Scope.resource_context(), map(), :all | map()) :: freeze_result()
  # A delivered native result is the only shape this module will project: a
  # caller that hands over something else is refused rather than allowed to
  # raise inside the projection, because a helper context must never be built
  # from a half-read result.
  def freeze(context, result, selection \\ :all)

  def freeze(context, %{comparison: comparison} = result, selection)
      when is_map(context) and is_map(comparison) and (selection == :all or is_map(selection)) do
    with true <- delivered?(result) do
      case selection do
        :all ->
          admitted(context, result, comparison)

        narrowing ->
          narrowed(context, result, narrowing)
      end
    else
      _not_delivered -> {:error, :invalid_scope}
    end
  end

  def freeze(_context, _result, _selection), do: {:error, :invalid_scope}

  defp delivered?(result) do
    match?(%{fingerprint: _, window: %{from: _, to: _}, left: _, right: _}, result)
  end

  defp narrowed(context, result, selection) do
    case Compare.narrow(result.comparison, selection) do
      {:ok, narrowed} -> admitted(context, result, narrowed)
      {:error, :invalid_scope} -> {:error, :invalid_scope}
    end
  end

  # The shared contract decides admission and owns the digest. Its two refusals
  # are translated, never smoothed: `:too_large` is this package's
  # `:source_too_large` and `:invalid_snapshot` is `:invalid_scope`, and the
  # original context the contract returns on those paths is what the caller
  # keeps, snapshot-free.
  defp admitted(context, result, view) do
    case Scope.with_source_snapshot(context, %{
           kind: "release_comparison",
           payload: projection(result, view)
         }) do
      {:ok, admitted_context} -> {:ok, admitted_context}
      {:error, :too_large} -> {:error, :source_too_large}
      {:error, :invalid_snapshot} -> {:error, :invalid_scope}
    end
  end

  defp projection(result, view) do
    %{
      "schema_version" => @schema_version,
      "source_ref" => result.fingerprint,
      "result_digest" => result.comparison.digest,
      "selected_digest" => view.digest,
      "artifacts" => artifacts(result),
      "window" => window(result.window),
      "selected_route_pairs" => selected_route_pairs(view),
      "selected_dates" => selected_dates(view),
      "groups" => Enum.map(view.groups, &group/1),
      "changes" => %{
        "effective" => Enum.map(view.effective_changes, &effective_change/1),
        "structural" => Enum.map(view.structural_changes, &structural_change/1)
      },
      "unresolved" => Enum.map(view.unresolved, &unresolved/1),
      "unknowns" => Enum.map(view.unknowns, &unknown/1),
      "totals" => totals(view.totals),
      "completeness" => completeness(view.completeness),
      "exclusions" => Enum.map(view.exclusions, &exclusion/1),
      "scope" => scope(view),
      "expires_at" => earliest_expiry(result)
    }
  end

  # Both artifacts are named by what the native export recorded, never by a
  # client-supplied digest or a filename. `profile` is the export type the run
  # itself carries, so the helper can tell a full feed from a partial one
  # without reading a receipt.
  defp artifacts(result) do
    [
      artifact("left", result.left),
      artifact("right", result.right)
    ]
  end

  defp artifact(side, identity) do
    %{
      "side" => side,
      "run_id" => identity.run_id,
      "version_id" => identity.version_id,
      "sha256" => identity.sha256,
      "size" => identity.size,
      "profile" => to_string(identity.export_type),
      "expires_at" => DateTime.to_iso8601(identity.expires_at),
      "estimate_missing_times" => identity.estimate_missing_times == true,
      "estimate_method" => estimate_method(identity.estimate_method)
    }
  end

  defp estimate_method(nil), do: nil
  defp estimate_method(method), do: to_string(method)

  defp window(%{from: from, to: to}),
    do: %{"from" => Date.to_iso8601(from), "to" => Date.to_iso8601(to)}

  # A complete comparison's admitted scope is the whole proven result: every
  # route pair it contains and every date it covered. A narrowed one states the
  # subset that was chosen, which is what a reader needs to know the totals are
  # scoped rather than whole-system.
  defp selected_route_pairs(view) do
    case Map.get(view, :scope) do
      %{route_pair_keys: keys} -> Enum.sort(keys)
      _complete -> view |> Compare.route_pairs() |> Enum.map(& &1.key) |> Enum.sort()
    end
  end

  defp selected_dates(view) do
    case Map.get(view, :scope) do
      %{dates: dates} -> dates |> Enum.sort() |> Enum.map(&Date.to_iso8601/1)
      _complete -> Date.range(view.window.from, view.window.to) |> Enum.map(&Date.to_iso8601/1)
    end
  end

  defp scope(view) do
    case Map.get(view, :scope) do
      nil -> nil
      %{route_pair_keys: keys, dates: dates} -> narrowed_scope(keys, dates)
    end
  end

  defp narrowed_scope(keys, dates) do
    %{
      "narrowed" => true,
      "route_pair_keys" => Enum.sort(keys),
      "dates" => dates |> Enum.sort() |> Enum.map(&Date.to_iso8601/1)
    }
  end

  defp group(%{
         route: route,
         route_ids: route_ids,
         direction_id: direction_id,
         date: date,
         route_mapped?: route_mapped?,
         comparable?: comparable?,
         reason: reason,
         left: left,
         right: right,
         delta: delta,
         span_reason: span_reason,
         pattern_pairs: pattern_pairs,
         pattern_reason: pattern_reason
       }) do
    %{
      "route" => route,
      "route_ids" => route_ids_of(route_ids),
      "direction_id" => direction_id,
      "date" => Date.to_iso8601(date),
      "route_mapped" => route_mapped?,
      "comparable" => comparable?,
      "reason" => reason_text(reason),
      "left" => side(left),
      "right" => side(right),
      "delta" => delta_of(delta),
      "span_reason" => reason_text(span_reason),
      "pattern_pairs" => Enum.map(pattern_pairs, &pattern_pair/1),
      "pattern_reason" => reason_text(pattern_reason)
    }
  end

  defp side(nil), do: nil

  defp side(%{
         route_id: route_id,
         timezone: timezone,
         scheduled_count: scheduled_count,
         exact_count: exact_count,
         count_complete?: count_complete?,
         span_complete?: span_complete?,
         first_secs: first_secs,
         last_secs: last_secs,
         pattern_count: pattern_count,
         pattern_reason: pattern_reason,
         source_refs: source_refs
       }) do
    %{
      "route_id" => route_id,
      "timezone" => timezone,
      "scheduled_count" => scheduled_count,
      "exact_count" => exact_count,
      "count_complete" => count_complete?,
      "span_complete" => span_complete?,
      "first_secs" => first_secs,
      "last_secs" => last_secs,
      "pattern_count" => pattern_count,
      "pattern_reason" => reason_text(pattern_reason),
      "source_refs" => Enum.map(source_refs, &row_ref/1)
    }
  end

  # A pattern is an ordered list of stop references, not a stop name and not a
  # path: the identity a stop-time row asserts, which is what a rename or a
  # reorder has to be judged against.
  defp pattern_pair(%{pattern: pattern, left: left, right: right}) do
    %{
      "pattern" => Enum.map(pattern, &stop/1),
      "left" => pattern_side(left),
      "right" => pattern_side(right)
    }
  end

  defp pattern_side(nil), do: nil
  defp pattern_side(pattern), do: Enum.map(pattern, &stop/1)

  defp stop(%{stop_id: stop_id, sequence: sequence}),
    do: %{"stop_id" => stop_id, "sequence" => sequence}

  defp route_ids_of(route_ids),
    do: %{"left" => Map.get(route_ids, :left), "right" => Map.get(route_ids, :right)}

  defp delta_of(%{
         scheduled_count: scheduled_count,
         exact_count: exact_count,
         first_secs: first_secs,
         last_secs: last_secs
       }) do
    %{
      "scheduled_count" => scheduled_count,
      "exact_count" => exact_count,
      "first_secs" => first_secs,
      "last_secs" => last_secs
    }
  end

  defp effective_change(%{
         kind: kind,
         route: route,
         route_ids: route_ids,
         direction_id: direction_id,
         date: date,
         dates: dates,
         counts: counts,
         delta: delta,
         timing: timing,
         frequency_windows: windows,
         trips: trips,
         reason: reason,
         source_refs: source_refs
       }) do
    %{
      "kind" => to_string(kind),
      "route" => route,
      "route_ids" => route_ids_of(route_ids),
      "direction_id" => direction_id,
      "date" => optional_date(date),
      "dates" => Enum.map(dates, &Date.to_iso8601/1),
      "counts" => %{
        "left" => counts_of(Map.get(counts, :left)),
        "right" => counts_of(Map.get(counts, :right))
      },
      "delta" => delta_of(delta),
      "timing" => timing(timing),
      "frequency_windows" => %{
        "left" => windows_of(Map.get(windows, :left)),
        "right" => windows_of(Map.get(windows, :right))
      },
      "trips" => %{"left" => Map.get(trips, :left), "right" => Map.get(trips, :right)},
      "reason" => reason_text(reason),
      "source_refs" => %{
        "left" => row_refs(Map.get(source_refs, :left)),
        "right" => row_refs(Map.get(source_refs, :right))
      }
    }
  end

  # A side's two counts are a nested map in the comparison, so they are rebuilt
  # rather than copied: an atom-keyed map is not a JSON payload.
  defp counts_of(nil), do: nil

  defp counts_of(counts),
    do: %{
      "scheduled_count" => Map.get(counts, :scheduled_count),
      "exact_count" => Map.get(counts, :exact_count)
    }

  defp timing(nil), do: nil

  defp timing(deltas) do
    Enum.map(deltas, fn delta ->
      %{
        "index" => Map.get(delta, :index),
        "date" => optional_date(Map.get(delta, :date)),
        "left_secs" => Map.get(delta, :left_secs),
        "right_secs" => Map.get(delta, :right_secs),
        "delta_secs" => Map.get(delta, :delta_secs),
        "left_arrival_secs" => Map.get(delta, :left_arrival_secs),
        "right_arrival_secs" => Map.get(delta, :right_arrival_secs),
        "arrival_delta_secs" => Map.get(delta, :arrival_delta_secs)
      }
    end)
  end

  # A frequency window is a template, not a trip count, so it travels as its own
  # four numbers rather than being folded into a delta.
  defp windows_of(nil), do: []

  defp windows_of(windows) do
    Enum.map(windows, fn {start_secs, end_secs, headway_secs, exact_times} ->
      %{
        "start_secs" => start_secs,
        "end_secs" => end_secs,
        "headway_secs" => headway_secs,
        "exact_times" => exact_times
      }
    end)
  end

  defp structural_change(%{
         entity: entity,
         id: id,
         change: change,
         left: left,
         right: right,
         left_ref: left_ref,
         right_ref: right_ref,
         meaning_changed: meaning_changed
       }) do
    %{
      "entity" => to_string(entity),
      "id" => id,
      "change" => to_string(change),
      "left" => json(left),
      "right" => json(right),
      "left_ref" => optional_row_ref(left_ref),
      "right_ref" => optional_row_ref(right_ref),
      "meaning_changed" => meaning_changed
    }
  end

  # A structural side is whatever the matcher compared: an identifier, a list of
  # dates, or a tuple - a stop pattern entry, a time pair, a frequency window, a
  # coordinate pair or a parent. JSON has neither tuples nor atoms, so a tuple is
  # its elements in order and an atom is its name; the shared seam refuses the
  # whole payload for any other shape.
  defp json(nil), do: nil
  defp json(value) when is_boolean(value) or is_number(value) or is_binary(value), do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&json/1)
  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(%Date{} = date), do: Date.to_iso8601(date)
  defp json(%Decimal{} = decimal), do: Decimal.to_string(decimal)
  defp json(other), do: inspect(other)

  defp unresolved(%{
         entity: entity,
         reason: reason,
         left_ref: left_ref,
         right_ref: right_ref,
         candidates: candidates
       }) do
    %{
      "entity" => to_string(entity),
      "reason" => to_string(reason),
      "left_ref" => optional_row_ref(left_ref),
      "right_ref" => optional_row_ref(right_ref),
      "candidates" => row_refs(candidates)
    }
  end

  # An unknown is evidence in its own right, so its reason and its detail travel
  # with it rather than being summarised away.
  defp unknown(%{
         side: side,
         layer: layer,
         entity: entity,
         entity_id: entity_id,
         field: field,
         reason: reason,
         detail: detail,
         source: source
       }) do
    %{
      "side" => to_string(side),
      "layer" => to_string(layer),
      "entity" => optional_atom(entity),
      "entity_id" => entity_id,
      "field" => field,
      "reason" => to_string(reason),
      "detail" => detail,
      "source" => row_ref(source)
    }
  end

  defp totals(%{
         exact_count_delta: exact_count_delta,
         scheduled_count_delta: scheduled_count_delta,
         reasons: reasons,
         measured_units: measured_units,
         total_units: total_units
       }) do
    %{
      "exact_count_delta" => exact_count_delta,
      "scheduled_count_delta" => scheduled_count_delta,
      # A suppressed total keeps its reasons: `nil` with no cause would read as
      # no difference at all.
      "reasons" => Enum.map(reasons, &to_string/1),
      "measured_units" => measured_units,
      "total_units" => total_units
    }
  end

  defp completeness(%{status: status, reasons: reasons}),
    do: %{"status" => to_string(status), "reasons" => Enum.map(reasons, &to_string/1)}

  # The exclusions are the comparison's own fixed scope disclosure - the member
  # allowlist's boundary - not prose written about this result, so they are
  # copied verbatim.
  defp exclusion(%{entity: entity, reason: reason, detail: detail}) do
    %{
      "entity" => to_string(entity),
      "reason" => to_string(reason),
      "detail" => detail
    }
  end

  # The retained artifacts keep their own retention. Copying the earliest expiry
  # is what stops a frozen context from outliving the bytes it describes.
  defp earliest_expiry(result) do
    [result.left.expires_at, result.right.expires_at]
    |> Enum.sort_by(&DateTime.to_iso8601/1)
    |> hd()
    |> DateTime.to_iso8601()
  end

  # A row reference is a GTFS member name and a 1-based row: evidence a person
  # can open the file and check, and never a path on this server.
  defp row_refs(nil), do: []

  defp row_refs(refs) do
    refs
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      %{file: file, row: row} -> %{"file" => file, "row" => row}
      other -> %{"file" => Map.get(other, :file), "row" => Map.get(other, :row)}
    end)
  end

  defp row_ref(%{file: file, row: row}), do: %{"file" => file, "row" => row}

  defp row_ref(_other), do: nil

  defp optional_row_ref(nil), do: nil
  defp optional_row_ref(ref), do: row_ref(ref)

  defp optional_date(nil), do: nil
  defp optional_date(%Date{} = date), do: Date.to_iso8601(date)

  defp optional_atom(nil), do: nil
  defp optional_atom(atom) when is_atom(atom), do: to_string(atom)

  defp reason_text(nil), do: nil
  defp reason_text(reason) when is_atom(reason), do: to_string(reason)
  defp reason_text(reason), do: to_string(reason)
end
