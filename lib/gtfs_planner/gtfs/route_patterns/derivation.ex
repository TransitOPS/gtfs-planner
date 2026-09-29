defmodule GtfsPlanner.Gtfs.RoutePatterns.Derivation do
  @moduledoc """
  Derives editable route patterns, timings and trip classifications from imported trips.

  Derivation runs inside one transaction per route under the shared route-row
  `FOR UPDATE` writer boundary, so a route commits its complete classification or
  none of it. It is driven by the importer after Phase 2 and by the authorized
  manual build/retry entrypoint; provenance is never accepted from browser
  parameters.

  Classification keeps supplied `trips.route_pattern_id` values verbatim and
  links only trips whose ordered stop-ID sequence matches a canonical sequence
  and whose ordered timing vector is representable. Everything else is stored as
  a terminal custom classification with a bounded reason; imported stop-time rows
  are never rewritten.

  Grouping is bounded: the first pass retains only hash/count/representative
  records for canonical sequences and the second pass loads one trip vector at a
  time, reusing signature-indexed timings. Trips are visited in stable
  `trip_id` order through keyset pages, so no pass retains the feed's stop-time
  vectors.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # A bounded page keeps every read/write batch constant in size for a feed of
  # any length: one label page and one vector page per iteration.
  @trip_page_size 500
  # A whole-route derivation commits in one transaction (INV: a route commits its
  # complete derivation or none of it), so the transaction budget must cover a
  # route-sized feed section. The deployment already budgets 300s for large GTFS
  # operations (`config/dev.exs`, `config/runtime.exs`); this keeps the
  # derivation transaction on the same bounded budget instead of the connection
  # default, which a large route would otherwise exhaust.
  @route_transaction_timeout 300_000
  @reason_max 80
  @short_suffix_lengths [4, 6, 8, 12, 16]
  @endpoint_separator " – "

  @type provenance :: {:import, Ecto.UUID.t() | nil} | {:editor, AuditContext.t()}

  @type summary :: %{
          patterns_created: non_neg_integer(),
          timings_created: non_neg_integer(),
          trips_linked: non_neg_integer(),
          trips_custom: non_neg_integer()
        }

  @type version_summary :: %{
          patterns_created: non_neg_integer(),
          timings_created: non_neg_integer(),
          trips_linked: non_neg_integer(),
          trips_custom: non_neg_integer(),
          routes_failed: non_neg_integer()
        }

  @doc """
  Derives every route with pending trips in a version in stable route-ID order.

  A route-local failure is non-fatal: its bounded reason is persisted on the
  route row and the remaining routes continue. Trips whose `route_id` has no
  route row are classified custom in a separate scoped pass instead of creating a
  fictional route.
  """
  @spec derive_version(Ecto.UUID.t(), Ecto.UUID.t(), provenance()) ::
          {:ok, version_summary()}
  def derive_version(organization_id, version_id, provenance) do
    provenance = normalize_provenance!(provenance)

    case pending_route_ids(organization_id, version_id) do
      [] ->
        {:ok, Map.put(zero_summary(), :routes_failed, 0)}

      pending_routes ->
        derive_pending_routes(organization_id, version_id, provenance, pending_routes)
    end
  end

  defp derive_pending_routes(organization_id, version_id, provenance, pending_routes) do
    existing = existing_route_ids(organization_id, version_id)

    {missing_routes, present_routes} =
      Enum.split_with(
        pending_routes,
        &(&1 not in existing)
      )

    missing_custom = classify_missing_routes(organization_id, version_id, missing_routes)

    {summaries, failed_routes} =
      present_routes
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn route_id, {summaries, failed} ->
        case derive_route(organization_id, version_id, route_id, provenance) do
          {:ok, summary} ->
            {[summary | summaries], failed}

          {:error, reason} ->
            persist_route_error!(organization_id, version_id, route_id, reason)
            {summaries, [route_id | failed]}
        end
      end)

    summary =
      Enum.reduce(summaries, zero_summary(missing_custom), fn summary, acc ->
        Map.merge(acc, summary, fn _key, left, right -> left + right end)
      end)

    {:ok, Map.put(summary, :routes_failed, length(failed_routes))}
  end

  @doc """
  Derives patterns, timings and trip classifications for one route.

  Returns the bounded counters for the route, or a bounded reason when the route
  transaction rolled back.
  """
  @spec derive_route(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), provenance()) ::
          {:ok, summary()} | {:error, atom() | term()}
  def derive_route(organization_id, version_id, route_id, provenance)
      when is_binary(route_id) do
    provenance = normalize_provenance!(provenance)

    run_derivation_transaction(
      fn -> derive_route_transaction(organization_id, version_id, route_id, provenance) end,
      provenance
    )
  end

  def derive_route(_organization_id, _version_id, _route_id, _provenance),
    do: {:error, :invalid_input}

  # Editor-provenance derivation joins the R5 M1 serializable/retry convention:
  # the whole route closure runs through the reviewed-apply adapter at
  # SERIALIZABLE with the preserved 300-second route budget. Import provenance
  # keeps its independent unpublished-version contract (plain transaction on
  # the importer's own version), unchanged.
  defp run_derivation_transaction(transaction, {:import, _import_run_id}),
    do: Repo.transaction(transaction, timeout: @route_transaction_timeout)

  defp run_derivation_transaction(transaction, {:editor, %AuditContext{}}) do
    run_editor_transaction(transaction)
  end

  # The route command bounded-retry convention: rerun the whole serializable
  # closure on a transient serialization failure (40001) or deadlock (40P01),
  # at most three attempts, then `:busy`. Every other failure is returned
  # unchanged, preserving derive_route/4's return shape.
  defp run_editor_transaction(transaction, attempts \\ 3) do
    case run_reviewed_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:retryable_conflict, _error} ->
        retry_editor_transaction(transaction, attempts)

      {:error, reason} ->
        if retryable_conflict?(reason),
          do: retry_editor_transaction(transaction, attempts),
          else: {:error, reason}
    end
  end

  defp retry_editor_transaction(transaction, attempts) when attempts > 1,
    do: run_editor_transaction(transaction, attempts - 1)

  defp retry_editor_transaction(_transaction, _attempts), do: {:error, :busy}

  defp run_reviewed_transaction(transaction) do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    ).run(transaction, timeout: @route_transaction_timeout)
  rescue
    error in Postgrex.Error ->
      if retryable_conflict?(error),
        do: {:retryable_conflict, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp retryable_conflict?(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :serialization_failure,
              "40001",
              :deadlock_detected,
              "40P01"
            ],
       do: true

  defp retryable_conflict?(_reason), do: false

  @doc """
  Counts the trips still pending derivation for one route.

  The manual build/retry entrypoint uses this to refuse a custom-only retry.
  """
  @spec pending_trip_count(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def pending_trip_count(organization_id, version_id, route_id) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.route_id == ^route_id and t.pattern_derivation_state == "pending"
      ),
      :count
    )
  end

  # --- orchestration ---------------------------------------------------------

  defp pending_route_ids(organization_id, version_id) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.pattern_derivation_state == "pending",
      distinct: true,
      select: t.route_id
    )
    |> Repo.all()
  end

  defp existing_route_ids(organization_id, version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id,
      select: r.route_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp classify_missing_routes(organization_id, version_id, route_ids) do
    Enum.reduce(Enum.sort(route_ids), 0, fn route_id, total ->
      {count, nil} =
        from(t in Trip,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
              t.route_id == ^route_id and t.pattern_derivation_state == "pending"
        )
        |> Repo.update_all(
          set: [
            pattern_derivation_state: "custom",
            pattern_derivation_reason: "missing_route",
            timed_pattern_id: nil
          ]
        )

      total + count
    end)
  end

  defp persist_route_error!(organization_id, version_id, route_id, reason) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id and
          r.route_id == ^route_id
    )
    |> Repo.update_all(set: [pattern_derivation_error: bounded_reason(reason)])

    :ok
  end

  defp bounded_reason(reason) when is_atom(reason) and not is_nil(reason),
    do: reason |> Atom.to_string() |> String.slice(0, @reason_max)

  defp bounded_reason(%Ecto.Changeset{}), do: "invalid_changeset"
  defp bounded_reason(_reason), do: "derivation_error"

  defp zero_summary(trips_custom \\ 0) do
    %{
      patterns_created: 0,
      timings_created: 0,
      trips_linked: 0,
      trips_custom: trips_custom
    }
  end

  # --- one route -------------------------------------------------------------

  defp derive_route_transaction(organization_id, version_id, route_id, provenance) do
    route = lock_route!(organization_id, version_id, route_id, provenance)
    before = trip_totals(route)

    if before.pending == 0 do
      zero_summary()
    else
      context = load_context(route)
      stage_one = first_pass(route, context)
      plan = plan_patterns!(route, context, stage_one)

      maybe_inject_route_failure!(route_id)

      state =
        second_pass(route, plan)
        |> initialize_template_timings(plan)

      finalize_timing_headsigns(state)

      clear_route_error!(route)
      summary = state.summary

      audit_build!(provenance, route, before, trip_totals(route), summary)
      summary
    end
  end

  defp lock_route!(organization_id, version_id, route_id, provenance) do
    route =
      from(r in Route,
        where:
          r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id and
            r.route_id == ^route_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case route do
      nil ->
        Repo.rollback(:missing_route)

      %Route{} = route ->
        ensure_scope!(route, version_id, provenance)
        route
    end
  end

  # The importer already owns its exact target version; an interactive manual
  # build additionally requires the published-version editor boundary and an
  # authenticated actor.
  defp ensure_scope!(_route, _version_id, {:import, _import_run_id}), do: :ok

  defp ensure_scope!(route, version_id, {:editor, %AuditContext{} = audit}) do
    unless audit.organization_id == route.organization_id and
             audit.gtfs_version_id == version_id and is_binary(audit.actor_id) and
             is_binary(audit.actor_email) do
      Repo.rollback(:not_found)
    end

    version =
      Repo.one(
        from(v in GtfsVersion,
          where:
            v.id == ^version_id and v.organization_id == ^route.organization_id and
              v.publication_status == "published"
        )
      )

    if is_nil(version), do: Repo.rollback(:not_found)
    :ok
  end

  defp trip_totals(route) do
    counts =
      from(t in Trip,
        where:
          t.organization_id == ^route.organization_id and
            t.gtfs_version_id == ^route.gtfs_version_id and t.route_id == ^route.route_id,
        group_by: t.pattern_derivation_state,
        select: {t.pattern_derivation_state, count(t.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      pending: Map.get(counts, "pending", 0),
      linked: Map.get(counts, "linked", 0),
      custom: Map.get(counts, "custom", 0)
    }
  end

  defp clear_route_error!(route) do
    from(r in Route, where: r.id == ^route.id and not is_nil(r.pattern_derivation_error))
    |> Repo.update_all(set: [pattern_derivation_error: nil])
  end

  # --- route context ---------------------------------------------------------

  defp load_context(route) do
    supplied_ids = pending_supplied_ids(route)
    supplied = supplied_patterns(route, supplied_ids)
    derived = derived_patterns(route)

    eligible_stops = eligible_stop_ids(route)

    %{
      supplied_ids: supplied_ids,
      supplied: supplied,
      derived: derived,
      occurrences: occurrence_rows(pattern_ids(supplied, derived)),
      representatives: representative_sequences(route, supplied, eligible_stops),
      eligible_stops: eligible_stops,
      names: pattern_names(route)
    }
  end

  # A usable stop sequence contains only this version's boarding stops/platforms
  # (location_type nil/0), the same eligibility the interactive stop editor
  # enforces; a station, entrance or unknown reference can never become an
  # editable pattern stop.
  defp eligible_stop_ids(route) do
    from(stop in Stop,
      where:
        stop.organization_id == ^route.organization_id and
          stop.gtfs_version_id == ^route.gtfs_version_id and
          (is_nil(stop.location_type) or stop.location_type == 0),
      select: stop.stop_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp pending_supplied_ids(route) do
    from(t in Trip,
      where:
        t.organization_id == ^route.organization_id and
          t.gtfs_version_id == ^route.gtfs_version_id and t.route_id == ^route.route_id and
          t.pattern_derivation_state == "pending" and not is_nil(t.route_pattern_id),
      distinct: true,
      select: t.route_pattern_id
    )
    |> Repo.all()
  end

  defp supplied_patterns(route, supplied_ids) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^route.organization_id and
          p.gtfs_version_id == ^route.gtfs_version_id and p.route_pattern_id in ^supplied_ids
    )
    |> Repo.all()
    |> Map.new(&{&1.route_pattern_id, &1})
  end

  defp derived_patterns(route) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^route.organization_id and
          p.gtfs_version_id == ^route.gtfs_version_id and p.route_id == ^route.route_id and
          not is_nil(p.derivation_key)
    )
    |> Repo.all()
    |> Map.new(&{&1.derivation_key, &1})
  end

  defp pattern_ids(supplied, derived) do
    Enum.map(Map.values(supplied), & &1.id) ++
      Enum.map(derived, fn {_key, pattern} -> pattern.id end)
  end

  defp occurrence_rows([]), do: %{}

  defp occurrence_rows(pattern_ids) do
    from(o in RoutePatternStop,
      where: o.route_pattern_id in ^pattern_ids,
      order_by: [asc: o.route_pattern_id, asc: o.position],
      select: %{route_pattern_id: o.route_pattern_id, id: o.id, stop_id: o.stop_id}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_pattern_id)
  end

  defp representative_sequences(route, supplied, eligible_stops) do
    supplied
    |> Map.values()
    |> Enum.filter(
      &(&1.route_id == route.route_id and is_binary(&1.representative_trip_id) and
          &1.representative_trip_id != "")
    )
    |> Enum.reduce(%{}, fn pattern, acc ->
      case representative_sequence(route, pattern, eligible_stops) do
        nil -> acc
        sequence -> Map.put(acc, pattern.id, sequence)
      end
    end)
  end

  defp representative_sequence(route, pattern, eligible_stops) do
    trip_id =
      Repo.one(
        from(t in Trip,
          where:
            t.organization_id == ^route.organization_id and
              t.gtfs_version_id == ^route.gtfs_version_id and
              t.trip_id == ^pattern.representative_trip_id and t.route_id == ^route.route_id and
              t.route_pattern_id == ^pattern.route_pattern_id,
          select: t.trip_id
        )
      )

    if is_nil(trip_id) do
      nil
    else
      labels = Map.get(page_labels(route, [trip_id]), trip_id, [])

      if usable_labels?(labels, eligible_stops), do: Enum.map(labels, &elem(&1, 0)), else: nil
    end
  end

  defp pattern_names(route) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^route.organization_id and
          p.gtfs_version_id == ^route.gtfs_version_id and p.route_id == ^route.route_id,
      select: p.route_pattern_name
    )
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # --- first pass: canonical sequences ---------------------------------------

  # One bounded page of trip labels is read per query; only hash/count/
  # representative records are retained across pages.
  defp first_pass(route, context) do
    each_pending_trip_page(route, empty_first_pass(), fn trips, acc ->
      labels_by_trip = page_labels(route, page_range(trips))

      Enum.reduce(trips, acc, fn trip, acc ->
        accumulate_first_pass(
          route,
          context,
          trip,
          Map.get(labels_by_trip, trip.trip_id, []),
          acc
        )
      end)
    end)
  end

  defp empty_first_pass do
    %{supplied: %{}, supplied_referenced: MapSet.new(), derived: %{}}
  end

  defp accumulate_first_pass(route, context, trip, labels, acc) do
    if is_nil(trip.route_pattern_id) do
      accumulate_derived_first_pass(route, context, trip, labels, acc)
    else
      accumulate_supplied_first_pass(route, context, trip, labels, acc)
    end
  end

  defp accumulate_derived_first_pass(_route, context, trip, labels, acc) do
    if trip.direction_id in [0, 1] and usable_labels?(labels, context.eligible_stops) do
      sequence = Enum.map(labels, &elem(&1, 0))
      key = {trip.direction_id, sequence_key(sequence)}
      update_in(acc.derived, &accumulate_sequence(&1, key, sequence, trip.trip_id))
    else
      acc
    end
  end

  defp accumulate_supplied_first_pass(route, context, trip, labels, acc) do
    case Map.get(context.supplied, trip.route_pattern_id) do
      %RoutePattern{} = pattern ->
        accumulate_supplied_pattern(route, context.eligible_stops, trip, labels, acc, pattern)

      nil ->
        acc
    end
  end

  defp accumulate_supplied_pattern(route, eligible_stops, trip, labels, acc, pattern) do
    if pattern.route_id == route.route_id and trip.direction_id == pattern.direction_id do
      acc
      |> put_supplied_referenced(trip.route_pattern_id)
      |> accumulate_supplied_sequence(labels, pattern, trip.trip_id, eligible_stops)
    else
      acc
    end
  end

  defp put_supplied_referenced(acc, natural_id) do
    update_in(acc.supplied_referenced, &MapSet.put(&1, natural_id))
  end

  defp accumulate_supplied_sequence(acc, labels, pattern, trip_id, eligible_stops) do
    if usable_labels?(labels, eligible_stops) do
      sequence = Enum.map(labels, &elem(&1, 0))

      update_in(
        acc.supplied,
        &accumulate_supplied_pattern_sequence(
          &1,
          pattern.route_pattern_id,
          sequence,
          trip_id
        )
      )
    else
      acc
    end
  end

  # A supplied pattern accumulates one record per distinct ordered stop-ID
  # sequence, so the most-common-eligible-sequence rule has real counts to
  # compare instead of one shared counter.
  defp accumulate_supplied_pattern_sequence(supplied, natural_id, sequence, trip_id) do
    sequences = Map.get(supplied, natural_id, %{})

    Map.put(
      supplied,
      natural_id,
      accumulate_sequence(sequences, sequence_key(sequence), sequence, trip_id)
    )
  end

  defp accumulate_sequence(sequences, key, sequence, trip_id) do
    Map.update(
      sequences,
      key,
      %{count: 1, representative: trip_id, sequence: sequence},
      fn entry ->
        entry
        |> Map.update!(:count, &(&1 + 1))
        |> Map.update!(:representative, &min(&1, trip_id))
      end
    )
  end

  # --- planning: patterns, occurrences, names, typicality ---------------------

  defp plan_patterns!(route, context, stage_one) do
    status =
      Enum.reduce(context.supplied_ids, %{}, fn natural_id, acc ->
        case Map.get(context.supplied, natural_id) do
          nil ->
            Map.put(acc, natural_id, :missing_pattern)

          %RoutePattern{route_id: route_id} ->
            Map.put(acc, natural_id, status_for(route, route_id))
        end
      end)

    {supplied, names} = plan_supplied_targets(route, context, stage_one, context.names)
    {derived, patterns_created, _names} = plan_derived_targets(route, context, stage_one, names)

    %{
      status: status,
      supplied: supplied,
      derived: derived,
      patterns_created: patterns_created,
      eligible_stops: context.eligible_stops
    }
  end

  defp status_for(route, pattern_route_id),
    do: if(pattern_route_id == route.route_id, do: :ok, else: :scope_mismatch)

  defp plan_supplied_targets(_route, context, stage_one, names) do
    targets =
      stage_one.supplied_referenced
      |> MapSet.to_list()
      |> Map.new(fn natural_id ->
        {natural_id, supplied_target(context, stage_one, natural_id)}
      end)

    {targets, names}
  end

  defp supplied_target(context, stage_one, natural_id) do
    pattern = Map.fetch!(context.supplied, natural_id)

    case Map.get(context.occurrences, pattern.id) do
      nil -> new_supplied_target(context, stage_one, pattern)
      occurrences -> occurred_target(pattern, occurrences)
    end
  end

  defp new_supplied_target(context, stage_one, pattern) do
    case canonical_supplied_sequence(context, stage_one, pattern) do
      nil ->
        %{pattern: pattern, sequence: nil, occurrences: []}

      sequence ->
        %{
          pattern: pattern,
          sequence: sequence,
          occurrences: occurrence_ids(insert_occurrences!(pattern, sequence))
        }
    end
  end

  defp occurred_target(pattern, occurrences) do
    %{
      pattern: pattern,
      sequence: Enum.map(occurrences, & &1.stop_id),
      occurrences: occurrence_ids(occurrences)
    }
  end

  defp canonical_supplied_sequence(context, stage_one, pattern) do
    Map.get(context.representatives, pattern.id) ||
      winning_sequence(Map.get(stage_one.supplied, pattern.route_pattern_id))
  end

  defp winning_sequence(nil), do: nil

  defp winning_sequence(sequences) when map_size(sequences) > 0 do
    sequences
    |> Enum.min_by(fn {_key, entry} -> {-entry.count, entry.representative} end)
    |> elem(1)
    |> Map.fetch!(:sequence)
  end

  defp winning_sequence(_sequences), do: nil

  defp plan_derived_targets(route, context, stage_one, names) do
    planning = %{
      typical: typical_keys(stage_one.derived),
      stop_names: stop_names(route, derived_stop_ids(stage_one.derived))
    }

    stage_one.derived
    |> Enum.sort_by(fn {{direction, key}, _entry} -> {direction, key} end)
    |> Enum.reduce({%{}, {0, names}}, fn {{direction, _key} = group_key, entry},
                                         {targets, progress} ->
      {target, progress} =
        plan_derived_target(route, context, group_key, entry, planning, progress)

      {Map.put(targets, {direction, derivation_key(direction, entry.sequence)}, target), progress}
    end)
    |> then(fn {targets, {created, names}} -> {targets, created, names} end)
  end

  defp plan_derived_target(
         route,
         context,
         group_key,
         entry,
         planning,
         {created, names} = progress
       ) do
    {direction, _key} = group_key
    derivation_key = derivation_key(direction, entry.sequence)

    case Map.get(context.derived, derivation_key) do
      %RoutePattern{} = pattern ->
        target =
          case Map.get(context.occurrences, pattern.id) do
            nil -> existing_derived_target(pattern, entry.sequence, true)
            occurrences -> existing_derived_target(pattern, occurrences, false)
          end

        {target, progress}

      nil ->
        create_derived_target(route, group_key, derivation_key, entry, planning, {created, names})
    end
  end

  defp existing_derived_target(pattern, occurrences_or_sequence, insert?) do
    if insert? do
      %{
        pattern: pattern,
        sequence: occurrences_or_sequence,
        occurrences: occurrence_ids(insert_occurrences!(pattern, occurrences_or_sequence))
      }
    else
      occurred_target(pattern, occurrences_or_sequence)
    end
  end

  defp create_derived_target(
         route,
         {direction, key},
         derivation_key,
         entry,
         planning,
         {created, names}
       ) do
    name = unique_pattern_name(entry.sequence, planning.stop_names, names, key)
    typicality = typicality(planning.typical, {direction, key})

    pattern =
      insert_pattern!(
        route,
        direction,
        derivation_key,
        name,
        typicality,
        entry.representative
      )

    occurrences = insert_occurrences!(pattern, entry.sequence)

    target = %{
      pattern: pattern,
      sequence: entry.sequence,
      occurrences: occurrence_ids(occurrences)
    }

    {target, {created + 1, MapSet.put(names, name)}}
  end

  defp typical_keys(derived) do
    derived
    |> Enum.group_by(fn {{direction, _key}, _entry} -> direction end)
    |> Enum.map(fn {_direction, entries} ->
      entries
      |> Enum.min_by(fn {{_direction, key}, entry} -> {-entry.count, key} end)
      |> elem(0)
    end)
    |> MapSet.new()
  end

  defp typicality(typical, key), do: if(MapSet.member?(typical, key), do: 1, else: 0)

  defp derived_stop_ids(derived) do
    derived
    |> Map.values()
    |> Enum.flat_map(fn entry -> Enum.uniq(entry.sequence) end)
    |> Enum.uniq()
  end

  defp stop_names(_route, []), do: %{}

  defp stop_names(route, stop_ids) do
    from(s in Stop,
      where:
        s.organization_id == ^route.organization_id and
          s.gtfs_version_id == ^route.gtfs_version_id and s.stop_id in ^stop_ids,
      select: {s.stop_id, s.stop_name}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp unique_pattern_name(sequence, stop_names, names, sequence_key) do
    base =
      endpoint_name(sequence, stop_names) ||
        "Pattern #{String.slice(sequence_key, 0, 8)}"

    if MapSet.member?(names, base) do
      suffixed_name(base, sequence_key, names)
    else
      base
    end
  end

  defp endpoint_name([first | _] = sequence, stop_names) do
    last = List.last(sequence)

    "#{stop_label(first, stop_names)}#{@endpoint_separator}#{stop_label(last, stop_names)}"
  end

  defp endpoint_name([], _stop_names), do: nil

  defp stop_label(stop_id, stop_names) do
    case Map.get(stop_names, stop_id) do
      name when is_binary(name) and name != "" -> name
      _ -> stop_id
    end
  end

  defp suffixed_name(base, sequence_key, names) do
    Enum.find_value(
      @short_suffix_lengths,
      "#{base} (#{String.slice(sequence_key, 0, 16)})",
      fn length ->
        candidate = "#{base} (#{String.slice(sequence_key, 0, length)})"
        if MapSet.member?(names, candidate), do: nil, else: candidate
      end
    )
  end

  defp insert_pattern!(route, direction, derivation_key, name, typicality, representative_trip_id) do
    %RoutePattern{}
    |> RoutePattern.changeset(%{
      route_pattern_id: "app-" <> Ecto.UUID.generate(),
      route_id: route.route_id,
      direction_id: direction,
      route_pattern_name: name,
      route_pattern_typicality: typicality,
      derivation_key: derivation_key,
      representative_trip_id: representative_trip_id,
      organization_id: route.organization_id,
      gtfs_version_id: route.gtfs_version_id
    })
    |> insert_or_rollback!()
  end

  # Occurrence and timing rows are inserted in bounded batches. Every value is
  # derived from the target's own pattern transaction state (never from request
  # parameters), and the database still enforces the scoped foreign keys, the
  # positive-position check and each uniqueness constraint.
  defp insert_occurrences!(pattern, sequence) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      sequence
      |> Enum.with_index(1)
      |> Enum.map(fn {stop_id, position} ->
        %{
          id: Ecto.UUID.generate(),
          route_pattern_id: pattern.id,
          organization_id: pattern.organization_id,
          gtfs_version_id: pattern.gtfs_version_id,
          stop_id: stop_id,
          position: position,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(RoutePatternStop, rows)

    if count != length(rows) do
      Repo.rollback(:occurrence_insert_failed)
    end

    Enum.map(rows, &%{id: &1.id, stop_id: &1.stop_id})
  end

  defp occurrence_ids(occurrences), do: Enum.map(occurrences, & &1.id)

  defp derivation_key(direction, sequence) do
    "d#{direction}-#{String.slice(sequence_key(sequence), 0, 32)}"
  end

  # --- second pass: link or classify one trip vector at a time ---------------

  # Reads and writes are batched per bounded trip page so the number of database
  # round trips stays proportional to `trips / page_size` while the retained
  # working set stays a page of scalar rows. A per-trip round trip would not
  # complete the specified large-feed envelope inside the connection timeout.
  defp second_pass(route, plan) do
    state = %{
      summary: %{
        patterns_created: plan.patterns_created,
        timings_created: 0,
        trips_linked: 0,
        trips_custom: 0
      },
      timings: %{},
      created_timings: MapSet.new(),
      headsigns: %{}
    }

    each_pending_trip_page(route, state, &process_page(route, plan, &1, &2))
  end

  defp process_page(route, plan, trips, state) do
    lock_trip_page!(trips)
    rows_by_trip = page_rows(route, page_range(trips))

    {state, links, customs} =
      Enum.reduce(trips, {state, %{}, %{}}, fn trip, acc ->
        collect_trip(plan, trip, Map.get(rows_by_trip, trip.trip_id, []), acc)
      end)

    flush_links!(links)
    flush_custom!(customs)
    state
  end

  defp collect_trip(plan, trip, rows, {state, links, customs}) do
    case process_trip(plan, trip, rows, state) do
      {:linked, pattern_natural_id, timing_id, state} ->
        {state, Map.update(links, {pattern_natural_id, timing_id}, [trip.id], &[trip.id | &1]),
         customs}

      {:custom, reason, state} ->
        {state, links, Map.update(customs, reason, [trip.id], &[trip.id | &1])}
    end
  end

  defp process_trip(plan, trip, rows, state) do
    if is_nil(trip.route_pattern_id) do
      process_derived_trip(plan, trip, rows, state)
    else
      process_supplied_trip(plan, trip, rows, state)
    end
  end

  defp process_derived_trip(plan, trip, rows, state) do
    cond do
      trip.direction_id not in [0, 1] ->
        custom_decision(trip, :missing_direction, state)

      not usable_labels?(Enum.map(rows, &{&1.stop_id, &1.stop_sequence}), plan.eligible_stops) ->
        custom_decision(trip, :unusable_stops, state)

      true ->
        sequence = Enum.map(rows, & &1.stop_id)
        key = {trip.direction_id, derivation_key(trip.direction_id, sequence)}

        case Map.get(plan.derived, key) do
          nil -> custom_decision(trip, :unusable_stops, state)
          target -> assign_trip(target, rows, trip, state)
        end
    end
  end

  defp process_supplied_trip(plan, trip, rows, state) do
    case Map.get(plan.status, trip.route_pattern_id) do
      :missing_pattern ->
        custom_decision(trip, :missing_pattern, state)

      :scope_mismatch ->
        custom_decision(trip, :scope_mismatch, state)

      :ok ->
        # Planning only targets references that agree with the supplied pattern's
        # route and direction, so a same-route reference with another direction
        # has no target at all; it stays a preserved custom reference instead of
        # aborting the route transaction with a missing fetch.
        case Map.fetch(plan.supplied, trip.route_pattern_id) do
          {:ok, target} -> assign_supplied_trip(target, trip, rows, plan.eligible_stops, state)
          :error -> custom_decision(trip, direction_reason(trip), state)
        end

      nil ->
        custom_decision(trip, :missing_pattern, state)
    end
  end

  defp direction_reason(%{direction_id: nil}), do: :missing_direction
  defp direction_reason(_trip), do: :scope_mismatch

  defp assign_supplied_trip(
         %{pattern: pattern, sequence: canonical} = target,
         trip,
         rows,
         eligible_stops,
         state
       ) do
    cond do
      is_nil(canonical) ->
        custom_decision(trip, :unusable_stops, state)

      is_nil(trip.direction_id) ->
        custom_decision(trip, :missing_direction, state)

      trip.direction_id != pattern.direction_id ->
        custom_decision(trip, :scope_mismatch, state)

      not usable_labels?(Enum.map(rows, &{&1.stop_id, &1.stop_sequence}), eligible_stops) ->
        custom_decision(trip, :unusable_stops, state)

      Enum.map(rows, & &1.stop_id) != canonical ->
        custom_decision(trip, :different_stops, state)

      true ->
        assign_trip(target, rows, trip, state)
    end
  end

  defp assign_trip(target, vector, trip, state) do
    case timing_rows(vector) do
      {:error, reason} ->
        custom_decision(trip, reason, state)

      {:ok, rows} ->
        signature = vector_signature(rows)
        {timing_id, state} = find_or_create_timing(target, signature, rows, state)

        state = state |> bump(:trips_linked) |> record_headsign(timing_id, trip.trip_headsign)
        {:linked, target.pattern.route_pattern_id, timing_id, state}
    end
  end

  defp custom_decision(_trip, reason, state) do
    {:custom, reason, bump(state, :trips_custom)}
  end

  defp flush_links!(links) do
    Enum.each(links, fn {{pattern_natural_id, timing_id}, trip_ids} ->
      from(t in Trip, where: t.id in ^trip_ids)
      |> Repo.update_all(
        set: [
          route_pattern_id: pattern_natural_id,
          pattern_derivation_state: "linked",
          pattern_derivation_reason: nil,
          timed_pattern_id: timing_id
        ]
      )
    end)
  end

  defp flush_custom!(customs) do
    Enum.each(customs, fn {reason, trip_ids} ->
      from(t in Trip, where: t.id in ^trip_ids)
      |> Repo.update_all(
        set: [
          pattern_derivation_state: "custom",
          pattern_derivation_reason: Atom.to_string(reason),
          timed_pattern_id: nil
        ]
      )
    end)
  end

  defp bump(state, key), do: put_in(state, [:summary, key], state.summary[key] + 1)

  # --- timings ---------------------------------------------------------------

  defp timing_rows(vector) do
    with :ok <- present_times(vector),
         {:ok, parsed} <- parse_times(vector),
         :ok <- valid_chronology(parsed),
         :ok <- valid_attributes(vector) do
      base = parsed |> hd() |> elem(1)

      rows =
        vector
        |> Enum.zip(parsed)
        |> Enum.map(fn {stop_time, {arrival, departure}} ->
          %{
            arrival_offset: arrival - base,
            departure_offset: departure - base,
            timepoint: stop_time.timepoint,
            pickup_type: stop_time.pickup_type,
            drop_off_type: stop_time.drop_off_type,
            stop_headsign: stop_time.stop_headsign
          }
        end)

      {:ok, rows}
    else
      {:error, _reason} = error -> error
    end
  end

  defp present_times(vector) do
    missing? =
      Enum.any?(vector, fn row ->
        not is_binary(row.arrival_time) or not is_binary(row.departure_time) or
          row.arrival_time == "" or row.departure_time == ""
      end)

    if missing?, do: {:error, :missing_times}, else: :ok
  end

  defp parse_times(vector) do
    Enum.reduce_while(vector, {:ok, []}, fn row, {:ok, acc} ->
      with {:ok, arrival} <- GtfsTime.parse(row.arrival_time),
           {:ok, departure} <- GtfsTime.parse(row.departure_time) do
        {:cont, {:ok, [{arrival, departure} | acc]}}
      else
        {:error, _reason} -> {:halt, {:error, :invalid_time}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp valid_chronology(parsed) do
    case parsed do
      [{first_arrival, first_departure} | rest] ->
        if first_departure >= first_arrival do
          validate_chronology(rest, first_departure)
        else
          {:error, :invalid_chronology}
        end

      [] ->
        {:error, :missing_times}
    end
  end

  defp validate_chronology([], _preceding_departure), do: :ok

  defp validate_chronology([{arrival, departure} | rest], preceding_departure) do
    if arrival >= preceding_departure and departure >= arrival do
      validate_chronology(rest, departure)
    else
      {:error, :invalid_chronology}
    end
  end

  defp valid_attributes(vector) do
    valid? =
      Enum.all?(vector, fn row ->
        row.timepoint in [nil, 0, 1] and row.pickup_type in [nil, 0, 1, 2, 3] and
          row.drop_off_type in [nil, 0, 1, 2, 3]
      end)

    if valid?, do: :ok, else: {:error, :invalid_attribute}
  end

  defp vector_signature(rows) do
    rows
    |> Enum.map(
      &{
        &1.arrival_offset,
        &1.departure_offset,
        &1.timepoint,
        &1.pickup_type,
        &1.drop_off_type,
        &1.stop_headsign
      }
    )
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp find_or_create_timing(target, signature, rows, state) do
    key = {target.pattern.id, signature}

    case Map.fetch(state.timings, key) do
      {:ok, timing_id} ->
        {timing_id, state}

      :error ->
        case stored_timing(target.pattern.id, signature, rows) do
          {:ok, timing_id} ->
            {timing_id, put_in(state, [:timings, key], timing_id)}

          :none ->
            create_timing(target, signature, rows, state)

          :mismatch ->
            create_timing(target, unique_signature_key(target.pattern.id, signature), rows, state)
        end
    end
  end

  defp stored_timing(pattern_id, signature, rows) do
    case Repo.one(
           from(t in TimedPattern,
             where: t.route_pattern_id == ^pattern_id and t.derivation_key == ^signature
           )
         ) do
      nil ->
        :none

      timing ->
        if stored_rows(timing.id) == rows, do: {:ok, timing.id}, else: :mismatch
    end
  end

  defp stored_rows(timing_id) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where: row.timed_pattern_id == ^timing_id,
      order_by: [asc: occurrence.position],
      select: %{
        arrival_offset: row.arrival_offset,
        departure_offset: row.departure_offset,
        timepoint: row.timepoint,
        pickup_type: row.pickup_type,
        drop_off_type: row.drop_off_type,
        stop_headsign: row.stop_headsign
      }
    )
    |> Repo.all()
  end

  defp unique_signature_key(pattern_id, signature) do
    taken =
      from(t in TimedPattern,
        where: t.route_pattern_id == ^pattern_id and not is_nil(t.derivation_key),
        select: t.derivation_key
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.find_value(2..7, fn attempt ->
      key = "#{signature}-#{attempt}"
      if MapSet.member?(taken, key), do: nil, else: key
    end) || Repo.rollback(:signature_conflict)
  end

  defp create_timing(target, derivation_key, rows, state) do
    pattern = target.pattern

    timing =
      %TimedPattern{}
      |> TimedPattern.changeset(%{
        route_pattern_id: pattern.id,
        route_pattern: pattern,
        organization_id: pattern.organization_id,
        gtfs_version_id: pattern.gtfs_version_id,
        name: RoutePatterns.next_timing_name(pattern.id),
        headsign: nil,
        derivation_key: derivation_key
      })
      |> insert_or_rollback!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    timing_rows =
      target.occurrences
      |> Enum.zip(rows)
      |> Enum.map(fn {occurrence_id, row} ->
        Map.merge(row, %{
          id: Ecto.UUID.generate(),
          timed_pattern_id: timing.id,
          route_pattern_stop_id: occurrence_id,
          inserted_at: now,
          updated_at: now
        })
      end)

    {count, nil} = Repo.insert_all(TimedPatternStop, timing_rows)

    if count != length(timing_rows) do
      Repo.rollback(:timing_row_insert_failed)
    end

    state =
      state
      |> bump(:timings_created)
      |> put_in([:created_timings], MapSet.put(state.created_timings, timing.id))

    {timing.id, state}
  end

  defp record_headsign(state, timing_id, headsign) do
    if MapSet.member?(state.created_timings, timing_id) do
      counts = Map.get(state.headsigns, timing_id, %{})
      put_in(state, [:headsigns, timing_id], Map.update(counts, headsign, 1, &(&1 + 1)))
    else
      state
    end
  end

  # A pattern whose known stops could not link any trip still keeps the
  # promised editable starting point: exactly one zero-valued, unassigned Timing
  # A. Custom trips and their imported stop times stay untouched, and retry skips
  # any pattern that already has a timing.
  defp initialize_template_timings(state, plan) do
    Enum.reduce(Map.values(plan.supplied) ++ Map.values(plan.derived), state, fn target, state ->
      if length(target.occurrences) >= 2 and not pattern_has_timing?(target.pattern.id) do
        {_timing_id, state} =
          create_timing(target, nil, zero_rows(length(target.occurrences)), state)

        state
      else
        state
      end
    end)
  end

  defp pattern_has_timing?(pattern_id) do
    Repo.exists?(from(t in TimedPattern, where: t.route_pattern_id == ^pattern_id))
  end

  defp zero_rows(count),
    do: List.duplicate(%{arrival_offset: 0, departure_offset: 0}, count)

  defp finalize_timing_headsigns(state) do
    state.created_timings
    |> Enum.flat_map(fn timing_id ->
      case modal_headsign(Map.get(state.headsigns, timing_id, %{})) do
        nil -> []
        headsign -> [{headsign, timing_id}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {headsign, timing_ids} ->
      from(t in TimedPattern, where: t.id in ^timing_ids)
      |> Repo.update_all(set: [headsign: headsign])
    end)
  end

  defp modal_headsign(counts) when map_size(counts) == 0, do: nil

  defp modal_headsign(counts) do
    counts
    |> Enum.min_by(fn {headsign, count} -> {-count, headsign || ""} end)
    |> elem(0)
  end

  # --- trip/vector reads -----------------------------------------------------

  defp each_pending_trip_page(route, acc, fun, cursor \\ "") do
    trips = pending_trip_page(route, cursor)

    case trips do
      [] ->
        acc

      trips ->
        acc = fun.(trips, acc)
        each_pending_trip_page(route, acc, fun, List.last(trips).trip_id)
    end
  end

  defp pending_trip_page(route, cursor) do
    from(t in Trip,
      where:
        t.organization_id == ^route.organization_id and
          t.gtfs_version_id == ^route.gtfs_version_id and t.route_id == ^route.route_id and
          t.pattern_derivation_state == "pending" and t.trip_id > ^cursor,
      order_by: [asc: t.trip_id],
      limit: ^@trip_page_size,
      select: %{
        id: t.id,
        trip_id: t.trip_id,
        direction_id: t.direction_id,
        route_pattern_id: t.route_pattern_id,
        trip_headsign: t.trip_headsign
      }
    )
    |> Repo.all()
  end

  # Derivation and every interactive mutation serialize on the route row first,
  # so trip rows are locked per bounded page in UUID order before assignment.
  defp lock_trip_page!(trips) do
    trip_ids = Enum.map(trips, & &1.id)

    from(t in Trip, where: t.id in ^trip_ids, order_by: [asc: t.id], lock: "FOR UPDATE")
    |> Repo.all()

    :ok
  end

  # Restrict each working window to the exact pending page, including sparse retries.
  defp page_range(trips), do: Enum.map(trips, & &1.trip_id)

  defp page_labels(route, trip_ids) do
    from(st in StopTime,
      where:
        st.organization_id == ^route.organization_id and
          st.gtfs_version_id == ^route.gtfs_version_id and st.trip_id in ^trip_ids,
      order_by: [asc: st.trip_id, asc: st.stop_sequence, asc: st.id],
      select: {st.trip_id, st.stop_id, st.stop_sequence}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_trip_id, stop_id, sequence} -> {stop_id, sequence} end)
  end

  defp page_rows(route, trip_ids) do
    from(st in StopTime,
      where:
        st.organization_id == ^route.organization_id and
          st.gtfs_version_id == ^route.gtfs_version_id and st.trip_id in ^trip_ids,
      order_by: [asc: st.trip_id, asc: st.stop_sequence, asc: st.id],
      select:
        {st.trip_id,
         %{
           stop_id: st.stop_id,
           stop_sequence: st.stop_sequence,
           arrival_time: st.arrival_time,
           departure_time: st.departure_time,
           timepoint: st.timepoint,
           pickup_type: st.pickup_type,
           drop_off_type: st.drop_off_type,
           stop_headsign: st.stop_headsign
         }}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp usable_labels?([_, _ | _] = labels, eligible_stops) do
    sequences = Enum.map(labels, &elem(&1, 1))

    not Enum.any?(
      labels |> Enum.chunk_every(2, 1, :discard),
      fn [left, right] -> elem(left, 0) == elem(right, 0) end
    ) and
      sequences == Enum.sort(sequences) and
      length(sequences) == length(Enum.uniq(sequences)) and
      Enum.all?(labels, fn {stop_id, _sequence} -> MapSet.member?(eligible_stops, stop_id) end)
  end

  defp usable_labels?(_labels, _eligible_stops), do: false

  defp sequence_key(sequence) do
    sequence
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # --- audit -----------------------------------------------------------------

  defp audit_build!({:import, _import_run_id}, _route, _before, _after, _summary), do: :ok

  defp audit_build!({:editor, %AuditContext{} = audit}, route, before, after_totals, summary) do
    if changed?(before, after_totals, summary) do
      attrs = %{
        before: totals(before),
        after: totals(after_totals),
        patterns_created: summary.patterns_created,
        timings_created: summary.timings_created
      }

      case Gtfs.record_change_in_transaction(
             %{audit | station_stop_id: nil},
             :route_pattern_build,
             route,
             "updated",
             attrs
           ) do
        {:ok, _log} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      :ok
    end
  end

  defp totals(totals),
    do: %{pending: totals.pending, custom: totals.custom, linked: totals.linked}

  defp changed?(before, after_totals, summary) do
    totals(before) != totals(after_totals) or summary.patterns_created > 0 or
      summary.timings_created > 0
  end

  # --- test-only fault seam --------------------------------------------------

  # Mirrors `:import_cleanup_inject_failure` in `GtfsPlanner.Gtfs.Import.Recovery`:
  # a test can name a route id so the route transaction rolls back entirely after
  # its patterns were planned. The environment value is absent in production.
  defp maybe_inject_route_failure!(route_id) do
    case Application.get_env(:gtfs_planner, :route_pattern_derivation_inject_failure) do
      ^route_id -> Repo.rollback(:injected_derivation_failure)
      _ -> :ok
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp normalize_provenance!({:import, import_run_id})
       when is_nil(import_run_id) or is_binary(import_run_id),
       do: {:import, import_run_id}

  defp normalize_provenance!({:editor, %AuditContext{} = audit_context}),
    do: {:editor, audit_context}

  defp normalize_provenance!(other) do
    raise ArgumentError,
          "derivation provenance must be {:import, run_id} or {:editor, %AuditContext{}}, " <>
            "got: #{inspect(other)}"
  end

  defp insert_or_rollback!(%Ecto.Changeset{} = changeset) do
    case Repo.insert(changeset) do
      {:ok, struct} -> struct
      {:error, error} -> Repo.rollback(error)
    end
  end
end
