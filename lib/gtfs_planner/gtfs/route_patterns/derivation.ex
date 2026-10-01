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
  and whose timing rows are valid. A stop without a scheduled time is kept as a
  nil offset pair, so a trip blank between its ends and its timepoints links and
  every other trip is stored as a terminal custom classification with a bounded
  reason; imported stop-time rows are never rewritten.

  Grouping is bounded: the first pass retains only hash/count/representative
  records for canonical sequences and the second pass loads one trip vector at a
  time, reusing signature-indexed timings. Trips are visited in stable
  `trip_id` order through keyset pages, so no pass retains the feed's stop-time
  vectors.
  """

  import Ecto.Query

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Audit
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatterns.Grouping
  alias GtfsPlanner.Gtfs.RoutePatterns.LabelRules
  alias GtfsPlanner.Gtfs.RoutePatterns.TimingRules
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
  # Equirectangular projection radius in metres. Stop-to-line distance is a
  # review-time advisory, and one shared constant keeps it in the same units as
  # the materializer's haversine lengths.
  @earth_radius_m 6_371_008.8
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
  fictional route. Editor-provenance batch writes use the same reviewed
  transaction boundary as a single-route derivation.
  """
  @spec derive_version(Ecto.UUID.t(), Ecto.UUID.t(), provenance()) ::
          {:ok, version_summary()} | {:error, atom() | term()}
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

    missing_result =
      if missing_routes == [] do
        {:ok, 0}
      else
        run_batch_write(
          fn -> classify_missing_routes(organization_id, version_id, missing_routes) end,
          organization_id,
          version_id,
          provenance
        )
      end

    with {:ok, missing_custom} <- missing_result,
         {:ok, {summaries, failed_routes}} <-
           derive_present_routes(organization_id, version_id, provenance, present_routes) do
      summary =
        Enum.reduce(summaries, zero_summary(missing_custom), fn summary, acc ->
          Map.merge(acc, summary, fn _key, left, right -> left + right end)
        end)

      {:ok, Map.put(summary, :routes_failed, length(failed_routes))}
    end
  end

  defp derive_present_routes(organization_id, version_id, provenance, present_routes) do
    present_routes
    |> Enum.sort()
    |> Enum.reduce_while({:ok, {[], []}}, fn route_id, {:ok, {summaries, failed}} ->
      case derive_route(organization_id, version_id, route_id, provenance) do
        {:ok, summary} ->
          {:cont, {:ok, {[summary | summaries], failed}}}

        {:error, :forbidden} when elem(provenance, 0) == :editor ->
          {:halt, {:error, :forbidden}}

        {:error, reason} ->
          case run_batch_write(
                 fn -> persist_route_error!(organization_id, version_id, route_id, reason) end,
                 organization_id,
                 version_id,
                 provenance
               ) do
            {:ok, :ok} -> {:cont, {:ok, {summaries, [route_id | failed]}}}
            {:error, write_reason} -> {:halt, {:error, write_reason}}
          end
      end
    end)
  end

  # The importer owns its version. Editor batch writes get a fresh membership
  # lock and audit scope check at the start of each reviewed retry attempt.
  # Per-route derivation retains its own independent transaction and check.
  defp run_batch_write(write, _organization_id, _version_id, {:import, _}), do: {:ok, write.()}

  defp run_batch_write(write, organization_id, version_id, {:editor, audit_context}) do
    run_editor_transaction(fn ->
      Authorization.lock_editor!(audit_context)

      unless audit_context.organization_id == organization_id and
               audit_context.gtfs_version_id == version_id do
        Repo.rollback(:not_found)
      end

      write.()
    end)
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

  @typedoc "One confirmed group: its preview key, the exported direction and the target it joins."
  @type selection :: %{key: String.t(), direction_id: 0 | 1, target: :new | Ecto.UUID.t()}

  @doc """
  Applies a confirmed grouping review to one route's left-out trips.

  The whole apply runs in the reviewed-apply transaction, so the route's row
  lock, the fingerprint comparison, the trip updates and derivation's own
  planning commit or roll back together. The preview is recomputed inside that
  transaction and compared with the caller's fingerprint: any linkage change
  since the review opened is `{:error, :stale}` and writes nothing (rule 7).

  Every selected group must exist in the recomputed preview and carry a
  direction of 0 or 1, and an explicit target must be a pattern of this route;
  anything else is `{:error, :invalid_selection}`. A group with no target joins
  the rule-5 candidate head, and `:new` plans a new pattern.

  The confirmed groups' trips are set pending with the confirmed direction and
  then handed to derivation's own planning with a target map, so a grouped
  route is planned, named and timed exactly as a derived one (CR-4). Only trip
  linkage, direction, `updated_at`, pattern/timing rows and the route audit
  entry are written; imported `stop_times` are never touched (rule 3, INV-2).
  """
  @spec group_left_out(String.t(), [selection()], String.t(), AuditContext.t()) ::
          {:ok, summary()}
          | {:error, :stale | :not_found | :busy | :invalid_selection | term()}
  def group_left_out(route_id, selections, fingerprint, %AuditContext{} = audit)
      when is_binary(route_id) and is_list(selections) and is_binary(fingerprint) do
    case run_editor_transaction(fn ->
           group_left_out_transaction(
             audit.organization_id,
             audit.gtfs_version_id,
             route_id,
             selections,
             fingerprint,
             audit
           )
         end) do
      # An unknown route is reported as not found rather than as a
      # derivation-internal reason, matching how the preview answers the same
      # scope question.
      {:error, :missing_route} -> {:error, :not_found}
      result -> result
    end
  end

  def group_left_out(_route_id, _selections, _fingerprint, _audit),
    do: {:error, :invalid_input}

  defp group_left_out_transaction(
         organization_id,
         version_id,
         route_id,
         selections,
         fingerprint,
         audit
       ) do
    route = lock_route!(organization_id, version_id, route_id, {:editor, audit})
    review = left_out_review(route)

    if review.fingerprint != fingerprint, do: Repo.rollback(:stale)

    confirmed = confirm_selections!(selections, review, route)
    grouped = mark_grouped_pending!(route, confirmed, review)

    derive_locked_route(route, {:editor, audit}, %{
      targets: selection_targets(confirmed),
      timing_names: selection_timing_names(confirmed),
      grouped: grouped
    })
  end

  defp confirm_selections!(selections, review, route) do
    Enum.map(selections, &confirm_selection!(&1, review, route))
  end

  defp confirm_selection!(selection, review, route) when is_map(selection) do
    with key when is_binary(key) <- Map.get(selection, :key),
         group when not is_nil(group) <- Map.get(review.groups_by_key, key),
         direction when direction in [0, 1] <- Map.get(selection, :direction_id) do
      {key, group, direction, resolve_target(selection, group, direction, review, route)}
    else
      _other -> Repo.rollback(:invalid_selection)
    end
  end

  defp confirm_selection!(_selection, _review, _route), do: Repo.rollback(:invalid_selection)

  # `:new` plans a pattern, an explicit id must name one of the group's candidates
  # in the confirmed direction (same route, direction and stop order), and an
  # absent target takes the rule-5 candidate head, so an unconfirmed chooser
  # still resolves to one deterministic pattern.
  defp resolve_target(selection, group, direction, review, route) do
    candidates = Grouping.candidates(group, direction, review.pattern_refs)

    case Map.get(selection, :target) do
      :new ->
        nil

      id when is_binary(id) ->
        pattern_id = cast_pattern_id(id)

        if Enum.any?(candidates, &(&1.id == pattern_id)),
          do: Map.fetch!(route_patterns(route), pattern_id),
          else: Repo.rollback(:invalid_selection)

      _absent ->
        case candidates do
          [%{id: id} | _rest] -> Map.get(route_patterns(route), id)
          [] -> nil
        end
    end
  end

  defp cast_pattern_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  # Each confirmed group's trips become pending with the confirmed direction, so
  # derivation's own first pass sees them as the trips it is meant to classify.
  # The prior direction is read from the same rows the fingerprint covered, so
  # the audit entry reports what the review was looking at.
  defp mark_grouped_pending!(route, confirmed, review) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    confirmed
    |> Enum.flat_map(fn {_key, group, direction, _target} ->
      prior = Map.new(group.trip_ids, &{&1, Map.get(review.directions, &1)})

      {count, nil} =
        from(t in Trip,
          where:
            t.organization_id == ^route.organization_id and
              t.gtfs_version_id == ^route.gtfs_version_id and t.route_id == ^route.route_id and
              t.id in ^Map.keys(prior)
        )
        |> Repo.update_all(
          set: [
            direction_id: direction,
            pattern_derivation_state: "pending",
            pattern_derivation_reason: nil,
            updated_at: now
          ]
        )

      # A trip the review counted that this transaction cannot write means the
      # review and the write disagree, which is the stale case.
      if count != map_size(prior), do: Repo.rollback(:stale)

      Enum.map(prior, fn {trip_id, prior_direction_id} ->
        %{trip_id: trip_id, prior_direction_id: prior_direction_id}
      end)
    end)
    |> Enum.sort_by(& &1.trip_id)
  end

  # The target override is keyed the way derivation's own planning keys a
  # derived group, so the confirmed pattern is the one the group's trips join.
  defp selection_targets(confirmed) do
    confirmed
    |> Enum.flat_map(fn {_key, group, direction, target} ->
      case target do
        %RoutePattern{} = pattern -> [{plan_group_key(group, direction), pattern}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  # Rule 6: the preview already named each group's timing, so the apply reuses
  # that name instead of naming a second time from a different answer.
  defp selection_timing_names(confirmed) do
    confirmed
    |> Enum.flat_map(fn {_key, group, direction, _target} ->
      case group.timing_names do
        [name | _rest] when is_binary(name) -> [{plan_group_key(group, direction), name}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp plan_group_key(group, direction),
    do: {direction, derivation_key(direction, group.stop_ids)}

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

  # --- grouping preview (read-only) ------------------------------------------

  @typedoc "One group's card data, as the grouping review reads it."
  @type preview_group :: %{
          key: String.t(),
          stop_ids: [String.t()],
          stop_names: [String.t()],
          trip_count: pos_integer(),
          services: [{String.t(), pos_integer()}],
          shapes: [{String.t(), pos_integer()}],
          direction_id: 0 | 1 | nil,
          suggestion: Grouping.suggestion(),
          candidates: [Grouping.pattern_ref()],
          timing_names: [String.t()],
          stop_distances_m: [{String.t(), float()}] | nil
        }

  @type preview :: %{
          groups: [preview_group()],
          blocked: [%{reason: atom(), trip_ids: [Ecto.UUID.t()]}],
          fingerprint: String.t()
        }

  @doc """
  Previews the grouping of one route's left-out trips without writing anything.

  The route's `custom` trips are paged in `trip_id` order with the same keyset
  helpers derivation uses, so a feed of any length is read in bounded pages.
  Each vector is re-checked with the same eligibility rules derivation applies,
  except that a missing direction is not a failure here: naming a direction is
  what the review is for. A vector that fails for any other reason is reported
  in `blocked` with that reason, so the editor sees why a trip is not being
  offered rather than a silently smaller total.

  The rest are grouped by the pure `Grouping` rules, which decide the direction
  suggestion (rule 4), the ordered candidates (rule 5), the timing names (rule 6)
  and the fingerprint (rule 7). `stop_distances_m` is present only when the
  first candidate already has a saved map line, because distance to a line that
  does not exist yet would be an invented number.

  An unknown route in the organization/version scope is `{:error, :not_found}`,
  so a foreign or unpublished route cannot be previewed.
  """
  @spec preview_left_out(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, preview()} | {:error, :not_found}
  def preview_left_out(organization_id, version_id, route_id) when is_binary(route_id) do
    case RoutePatterns.published_route(organization_id, version_id, route_id) do
      {:ok, route} ->
        review = left_out_review(route)

        {:ok,
         %{
           groups: review.groups,
           blocked: review.blocked,
           fingerprint: review.fingerprint
         }}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def preview_left_out(_organization_id, _version_id, _route_id),
    do: {:error, :not_found}

  # One read of the review the editor is looking at. The preview returns its
  # display fields and the apply confirms against the same groups, so a rule
  # cannot answer one way on screen and another way in the transaction.
  defp left_out_review(route) do
    context = preview_context(route)
    {rows, vectors, blocked} = collect_left_out(route, context)

    groups = Grouping.group(vectors)
    previews = preview_groups(route, context, groups)

    cards =
      Enum.zip(groups, previews) |> Enum.map(fn {group, preview} -> Map.merge(group, preview) end)

    %{
      # Key order is the preview's own order, so the cards a review shows and
      # the groups an apply confirms are the same collection in the same order.
      groups: cards,
      groups_by_key: Map.new(cards, &{&1.key, &1}),
      blocked: blocked_reasons(blocked),
      fingerprint: Grouping.fingerprint(rows),
      pattern_refs: context.pattern_refs,
      directions: Map.new(rows, &{&1.id, &1.direction_id})
    }
  end

  defp preview_context(route) do
    %{
      eligible_stops: eligible_stop_ids(route),
      pattern_refs: pattern_refs(route),
      patterns: route_patterns(route)
    }
  end

  # The route's own patterns, with their stop orders, linked-trip counts and
  # label owners, are what rules 4 and 5 are answered from. This is the same
  # shape `Grouping.suggest_direction/3` and `candidates/3` take, so the preview
  # introduces no second notion of a pattern reference.
  defp route_patterns(route) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^route.organization_id and
          p.gtfs_version_id == ^route.gtfs_version_id and p.route_id == ^route.route_id,
      order_by: [asc: p.route_pattern_id]
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp pattern_refs(route) do
    patterns = route_patterns(route) |> Map.values()
    stops_by_pattern = occurrence_stop_ids(Enum.map(patterns, & &1.id))
    linked = linked_trip_counts(route, Enum.map(patterns, & &1.route_pattern_id))

    Enum.map(patterns, fn pattern ->
      %{
        id: pattern.id,
        route_pattern_id: pattern.route_pattern_id,
        direction_id: pattern.direction_id,
        stop_ids: Map.get(stops_by_pattern, pattern.id, []),
        derivation_key: pattern.derivation_key,
        linked_trip_count: Map.get(linked, pattern.route_pattern_id, 0),
        # `Grouping` answers a labelled child's group from its owner, so the
        # preview has to carry the real owner rather than a placeholder.
        label_pattern_id: pattern.label_pattern_id
      }
    end)
  end

  defp occurrence_stop_ids([]), do: %{}

  defp occurrence_stop_ids(pattern_ids) do
    from(o in RoutePatternStop,
      where: o.route_pattern_id in ^pattern_ids,
      order_by: [asc: o.route_pattern_id, asc: o.position],
      select: {o.route_pattern_id, o.stop_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_pattern_id, stop_id} -> stop_id end)
  end

  defp linked_trip_counts(_route, []), do: %{}

  defp linked_trip_counts(route, natural_ids) do
    from(t in Trip,
      where:
        t.organization_id == ^route.organization_id and
          t.gtfs_version_id == ^route.gtfs_version_id and t.route_id == ^route.route_id and
          t.route_pattern_id in ^natural_ids and t.pattern_derivation_state == "linked",
      group_by: t.route_pattern_id,
      select: {t.route_pattern_id, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # One bounded page of custom trips plus its stop-time vectors, exactly as the
  # second pass reads them. The retained window is the page, not the feed.
  defp collect_left_out(route, context) do
    each_custom_trip_page(route, {[], [], %{}}, fn trips, acc ->
      rows_by_trip = page_rows(route, page_range(trips))
      Enum.reduce(trips, acc, &accumulate_left_out(&1, &2, rows_by_trip, context))
    end)
  end

  # Every left-out trip contributes to the fingerprint, blocked ones included:
  # rule 7 makes the review stale on any linkage change, and a blocked trip can
  # become groupable by exactly such a change.
  defp accumulate_left_out(trip, {rows, vectors, blocked}, rows_by_trip, context) do
    {id, trip_row, vector, reason} =
      classify_vector(trip, Map.get(rows_by_trip, trip.trip_id, []), context)

    blocked = if reason, do: block(blocked, reason, id), else: blocked

    {[trip_row | rows], if(vector, do: [vector | vectors], else: vectors), blocked}
  end

  defp block(blocked, reason, id), do: Map.update(blocked, reason, [id], &[id | &1])

  # Re-checks one vector with derivation's own rules, direction aside. Only a
  # missing direction is forgivable: the review exists to supply it. A vector
  # that no longer passes the step-3 stop and timing rules is blocked with the
  # reason it fails, so the preview cannot offer a trip derivation would refuse.
  defp classify_vector(trip, rows, context) do
    trip_row = fingerprint_row(trip)

    with :ok <- preview_labels(rows, context),
         {:ok, _timing} <- timing_rows(rows) do
      {trip.id, trip_row, groupable_vector(trip, rows), nil}
    else
      {:error, reason} -> {trip.id, trip_row, nil, reason}
    end
  end

  defp preview_labels(rows, context) do
    if usable_labels?(Enum.map(rows, &{&1.stop_id, &1.stop_sequence}), context.eligible_stops) do
      :ok
    else
      {:error, :unusable_stops}
    end
  end

  # The linkage fields rule 7 fingerprints, read from the page's own row.
  defp fingerprint_row(trip) do
    %{
      id: trip.id,
      pattern_derivation_state: trip.pattern_derivation_state,
      route_pattern_id: trip.route_pattern_id,
      timed_pattern_id: trip.timed_pattern_id,
      direction_id: trip.direction_id,
      updated_at: trip.updated_at
    }
  end

  defp groupable_vector(trip, rows) do
    %{
      id: trip.id,
      trip_id: trip.trip_id,
      direction_id: trip.direction_id,
      route_pattern_id: trip.route_pattern_id,
      service_id: trip.service_id,
      shape_id: trip.shape_id,
      stop_ids: Enum.map(rows, & &1.stop_id)
    }
  end

  # A supplied pattern ID that names no pattern of this route is a stale
  # reference, not a groupable stop order: step 15 links those as children.
  defp blocked_reasons(blocked) do
    blocked
    |> Enum.map(fn {reason, trip_ids} ->
      %{reason: reason, trip_ids: Enum.sort(trip_ids)}
    end)
    |> Enum.sort_by(& &1.reason)
  end

  defp each_custom_trip_page(route, acc, fun, cursor \\ "") do
    trips = custom_trip_page(route, cursor)

    case trips do
      [] ->
        acc

      trips ->
        each_custom_trip_page(route, fun.(trips, acc), fun, List.last(trips).trip_id)
    end
  end

  # The custom-trip page is `pending_trip_page/2` with one state changed, so the
  # two passes read a route's trips the same way and a preview can never show a
  # trip derivation has not yet classified.
  defp custom_trip_page(route, cursor) do
    from(t in Trip,
      where:
        t.organization_id == ^route.organization_id and
          t.gtfs_version_id == ^route.gtfs_version_id and t.route_id == ^route.route_id and
          t.pattern_derivation_state == "custom" and t.trip_id > ^cursor,
      order_by: [asc: t.trip_id],
      limit: ^@trip_page_size,
      select: %{
        id: t.id,
        trip_id: t.trip_id,
        direction_id: t.direction_id,
        route_pattern_id: t.route_pattern_id,
        timed_pattern_id: t.timed_pattern_id,
        service_id: t.service_id,
        shape_id: t.shape_id,
        pattern_derivation_state: t.pattern_derivation_state,
        updated_at: t.updated_at
      }
    )
    |> Repo.all()
  end

  # The direction the card is about: the one the route's own patterns decided,
  # or the one the trips already agree on. A group with neither has no
  # direction yet and so has no candidates, which is what leaves the editor to
  # answer.
  defp preview_direction(group, groups, refs) do
    case Grouping.suggest_direction(group, groups, refs) do
      {:suggested, direction, _reason} -> direction
      _ -> group.direction_id
    end
  end

  defp preview_groups(route, context, groups) do
    refs = context.pattern_refs
    service_names = service_names(route, groups)
    taken = taken_timing_names(refs)

    Enum.map(groups, fn group ->
      direction = preview_direction(group, groups, refs)
      candidates = if is_nil(direction), do: [], else: Grouping.candidates(group, direction, refs)

      %{
        key: group.key,
        stop_ids: group.stop_ids,
        stop_names: stop_labels(group.stop_ids, route),
        trip_count: length(group.trip_ids),
        services: ordered_counts(group.services),
        shapes: ordered_counts(group.shapes),
        direction_id: direction,
        suggestion: Grouping.suggest_direction(group, groups, refs),
        candidates: candidates,
        timing_names: timing_names(group, service_names, taken, candidates),
        stop_distances_m: stop_distances(context, group, candidates)
      }
    end)
  end

  # Rule 6: one service is named after it, two are joined with "and", and any
  # other number falls back to the pattern's own next timing name. A new pattern
  # has no timings yet, so the fallback is the name derivation would give it.
  defp timing_names(group, service_names, taken, candidates) do
    names =
      group.services
      |> Enum.map(fn {service_id, _count} -> Map.get(service_names, service_id, service_id) end)
      |> Enum.sort()

    case Grouping.timing_name(names, taken) do
      :fallback -> [fallback_timing_name(candidates)]
      name -> [name]
    end
  end

  defp fallback_timing_name([]), do: "Timing A"
  defp fallback_timing_name([%{id: id} | _rest]), do: RoutePatterns.next_timing_name(id)

  # The names a target's timings already hold, so rule 6's " 2", " 3" suffix
  # never proposes a name the pattern owns.
  defp taken_timing_names(refs) do
    pattern_ids = Enum.map(refs, & &1.id)

    if pattern_ids == [] do
      MapSet.new()
    else
      from(t in TimedPattern,
        where: t.route_pattern_id in ^pattern_ids,
        select: t.name
      )
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp service_names(_route, []), do: %{}

  defp service_names(route, groups) do
    service_ids =
      groups
      |> Enum.flat_map(fn group -> Map.keys(group.services) end)
      |> Enum.uniq()

    from(a in CalendarAttribute,
      where:
        a.organization_id == ^route.organization_id and
          a.gtfs_version_id == ^route.gtfs_version_id and a.service_id in ^service_ids,
      select: {a.service_id, a.service_description}
    )
    |> Repo.all()
    |> Map.new(fn {service_id, description} ->
      {service_id, service_name(description, service_id)}
    end)
  end

  defp service_name(description, _service_id)
       when is_binary(description) and description != "",
       do: description

  defp service_name(_description, service_id), do: service_id

  defp stop_labels(stop_ids, route) do
    names = stop_names(route, Enum.uniq(stop_ids))
    Enum.map(stop_ids, &stop_label(&1, names))
  end

  defp ordered_counts(counts) do
    counts
    |> Enum.sort_by(fn {value, count} -> {-count, value} end)
  end

  # Distances are measured against the first candidate's own saved map line, so
  # the card shows how far a group's stops sit from the line the editor is about
  # to join. A candidate with no saved line reports `nil` rather than a distance
  # to a line that does not exist.
  defp stop_distances(_context, _group, []), do: nil

  defp stop_distances(context, group, [%{id: pattern_id} | _rest]) do
    case Map.fetch(context.patterns, pattern_id) do
      {:ok, pattern} -> measure_stop_distances(pattern, group.stop_ids)
      :error -> nil
    end
  end

  # The line is drawn from the pattern's own resolved visits and sections
  # through the one resolver every reader uses (R3), so the preview measures the
  # same geometry export draws and cannot drift from it.
  defp measure_stop_distances(pattern, stop_ids) do
    resolved = Alignments.resolve(pattern)
    polyline = polyline(resolved)

    if polyline == [] do
      nil
    else
      coordinates = Map.new(resolved.visits, &{&1.stop_id, {&1.lon, &1.lat}})
      reference = reference_latitude(polyline)

      stop_ids
      |> Enum.map(fn stop_id ->
        {stop_id, distance_to_polyline(Map.get(coordinates, stop_id), polyline, reference)}
      end)
    end
  end

  # A saved line is the pattern's drawn sections in position order: an override
  # or a shared segment, joined through its visits' coordinates. A section with
  # no stored segment is a gap in the line, not a straight leg, so the line
  # stops where the drawing stops instead of inventing the missing road.
  #
  # Stored points arrive as `[lon, lat]` lists, so every vertex is normalized to
  # a `{lon, lat}` tuple here and the projection reads one shape.
  defp polyline(%{visits: visits, sections: sections}) do
    coordinates = Map.new(visits, &{&1.occurrence_id, {&1.lon, &1.lat}})

    sections
    |> Enum.filter(&(&1.kind in [:override, :shared]))
    |> Enum.flat_map(fn section ->
      from = Map.get(coordinates, section.from_occurrence_id)
      to = Map.get(coordinates, section.to_occurrence_id)
      interior = Enum.map(section.points, fn [lon, lat] -> {lon, lat} end)

      [from, to] |> Enum.reject(&is_nil/1) |> Enum.concat(interior)
    end)
  end

  # Equirectangular projection: longitude degrees are scaled by the cosine of a
  # reference latitude, which is accurate over the few kilometres one feed's
  # route line spans and keeps the answer in metres.
  defp project({lon, lat}, reference) do
    {
      @earth_radius_m * radians(lon) * :math.cos(radians(reference)),
      @earth_radius_m * radians(lat)
    }
  end

  defp reference_latitude(points) do
    Enum.sum(Enum.map(points, fn {_lon, lat} -> lat end)) / max(length(points), 1)
  end

  # A stop with no usable coordinates cannot be measured, and neither can a line
  # with no vertices; both report zero rather than a fabricated number, and the
  # review's own copy is what tells the editor a stop has no location.
  defp distance_to_polyline(nil, _polyline, _reference), do: 0.0

  defp distance_to_polyline({lon, lat}, polyline, reference) do
    projected = Enum.map(polyline, &project(&1, reference))
    point = project({lon, lat}, reference)

    projected
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{ax, ay}, to] ->
      :math.sqrt(distance_squared(point, {ax, ay}, to))
    end)
    |> Enum.min(fn -> 0.0 end)
  end

  # The standard point-to-segment distance, clamped to the segment so a stop
  # beyond either end measures to that end.
  defp distance_squared({px, py}, {ax, ay}, {bx, by}) do
    dx = bx - ax
    dy = by - ay
    denominator = dx * dx + dy * dy

    t =
      if denominator == 0.0 do
        0.0
      else
        ((px - ax) * dx + (py - ay) * dy) / denominator
      end

    t = max(min(t, 1.0), 0.0)

    (px - (ax + t * dx)) ** 2 + (py - (ay + t * dy)) ** 2
  end

  defp radians(value), do: :math.pi() * value / 180.0

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
    case provenance do
      {:editor, audit_context} ->
        Authorization.lock_editor!(audit_context)

        unless audit_context.organization_id == organization_id and
                 audit_context.gtfs_version_id == version_id do
          Repo.rollback(:not_found)
        end

      {:import, _} ->
        :ok
    end

    route = lock_route!(organization_id, version_id, route_id, provenance)
    derive_locked_route(route, provenance, %{})
  end

  # The body of a route derivation, for a route this transaction already holds
  # the row lock on. `overrides` carries what a caller has confirmed outside a
  # fresh import: the grouping review's target map and timing names, and the
  # trips it set pending. An import passes none, so a derived route is planned
  # from the imported data alone.
  defp derive_locked_route(route, provenance, overrides) do
    before = trip_totals(route)

    if before.pending == 0 do
      zero_summary()
    else
      context = load_context(route, overrides)
      stage_one = first_pass(route, context)
      plan = plan_patterns!(route, context, stage_one)

      maybe_inject_route_failure!(route.route_id)

      state =
        second_pass(route, plan)
        |> initialize_template_timings(plan)

      finalize_timing_headsigns(state)

      clear_route_error!(route)
      summary = state.summary

      audit_build!(
        provenance,
        route,
        before,
        trip_totals(route),
        summary,
        Map.get(overrides, :grouped, [])
      )

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

  defp load_context(route, overrides) do
    supplied_ids = pending_supplied_ids(route)
    supplied = supplied_patterns(route, supplied_ids)
    derived = derived_patterns(route)

    eligible_stops = eligible_stop_ids(route)

    %{
      supplied_ids: supplied_ids,
      supplied: supplied,
      derived: derived,
      occurrences: occurrence_rows(pattern_ids(supplied, derived, overrides)),
      representatives: representative_sequences(route, supplied, eligible_stops),
      eligible_stops: eligible_stops,
      names: pattern_names(route),
      targets: Map.get(overrides, :targets, %{}),
      timing_names: Map.get(overrides, :timing_names, %{})
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

  # A confirmed override names the pattern to join, and that pattern is often a
  # hand-made one: it has no derivation key and no pending trips pointing at it,
  # so `supplied` and `derived` are both blind to it. Without its own occurrences
  # here, `existing_target/3` would insert a second copy of its stops and trip
  # over the unique position constraint.
  defp pattern_ids(supplied, derived, overrides) do
    targets = Map.get(overrides, :targets) || %{}

    supplied_ids = Enum.map(Map.values(supplied), & &1.id)
    derived_ids = Enum.map(derived, fn {_key, pattern} -> pattern.id end)
    target_ids = targets |> Map.values() |> Enum.map(& &1.id)

    supplied_ids ++ derived_ids ++ target_ids
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

    {supplied, children_created, names} =
      plan_supplied_targets(route, context, stage_one, context.names)

    {derived, derived_created, _names} = plan_derived_targets(route, context, stage_one, names)

    %{
      status: status,
      supplied: supplied,
      derived: derived,
      patterns_created: children_created + derived_created,
      eligible_stops: context.eligible_stops
    }
  end

  defp status_for(route, pattern_route_id),
    do: if(pattern_route_id == route.route_id, do: :ok, else: :scope_mismatch)

  defp plan_supplied_targets(route, context, stage_one, names) do
    stop_names = stop_names(route, supplied_sequence_stop_ids(stage_one))

    stage_one.supplied_referenced
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.reduce({%{}, 0, names}, fn natural_id, {targets, created, names} ->
      target = supplied_target(context, stage_one, natural_id)

      {target, created, names} =
        plan_supplied_children(
          route,
          context,
          stage_one,
          target,
          stop_names,
          created,
          names
        )

      {Map.put(targets, natural_id, target), created, names}
    end)
  end

  # A supplied trip whose ordered stops differ from its supplied pattern's
  # canonical sequence joins a child pattern labelled by that owner, so the
  # exported `route_pattern_id` stays the owner's supplied ID (rule 1 of the
  # proposal, AC-19). Only the sequences the first pass actually saw are
  # planned, so a child is never created for a sequence no trip serves.
  defp plan_supplied_children(
         route,
         context,
         stage_one,
         %{pattern: owner, sequence: canonical} = target,
         stop_names,
         created,
         names
       ) do
    case canonical do
      nil ->
        {Map.put(target, :children, %{}), created, names}

      _canonical ->
        {children, created, names} =
          stage_one.supplied
          |> Map.get(owner.route_pattern_id, %{})
          |> Enum.reject(fn {_key, entry} -> entry.sequence == canonical end)
          |> Enum.sort_by(fn {key, _entry} -> key end)
          |> Enum.reduce({%{}, created, names}, fn {key, entry}, {children, created, names} ->
            {child, created, names} =
              supplied_child_target(route, context, entry, owner, stop_names, created, names)

            {Map.put(children, key, child), created, names}
          end)

        {Map.put(target, :children, children), created, names}
    end
  end

  # A child is reused when the route already holds the pattern this owner and
  # this sequence derived before, and created otherwise. Its key names the
  # owner, the direction and the stop list, so the same express trips always
  # reach the same child across a re-run.
  defp supplied_child_target(route, context, entry, owner, stop_names, created, names) do
    key = child_derivation_key(owner, entry.sequence)

    case Map.get(context.derived, key) do
      %RoutePattern{} = pattern ->
        validate_label_pair!(pattern, owner)

        {existing_child_target(context, pattern, entry.sequence), created, names}

      nil ->
        name = unique_pattern_name(entry.sequence, stop_names, names, key)

        pattern =
          insert_pattern!(
            route,
            owner.direction_id,
            key,
            name,
            0,
            entry.representative,
            owner.id
          )

        validate_label_pair!(pattern, owner)

        occurrences = insert_occurrences!(pattern, entry.sequence)

        child = %{
          pattern: pattern,
          sequence: entry.sequence,
          occurrences: occurrence_ids(occurrences)
        }

        {child, created + 1, MapSet.put(names, name)}
    end
  end

  # INV-3: every label pair is decided by `LabelRules` and nowhere else, and the
  # transaction rolls back rather than committing an inconsistent pair.
  defp validate_label_pair!(child, owner) do
    case LabelRules.validate(child, owner) do
      :ok -> :ok
      {:error, _violation} -> Repo.rollback(:invalid_label_pair)
    end
  end

  # The key already names the stop list, so an existing child that does not
  # carry it is not this sequence's child and the route is rolled back instead
  # of linking trips to a pattern with the wrong stops.
  defp existing_child_target(context, pattern, sequence) do
    case Map.get(context.occurrences, pattern.id) do
      nil ->
        existing_derived_target(pattern, sequence, true)

      occurrences ->
        if Enum.map(occurrences, & &1.stop_id) == sequence do
          occurred_target(pattern, occurrences)
        else
          Repo.rollback(:label_child_mismatch)
        end
    end
  end

  defp supplied_sequence_stop_ids(stage_one) do
    stage_one.supplied
    |> Map.values()
    |> Enum.flat_map(fn sequences -> Enum.map(Map.values(sequences), & &1.sequence) end)
    |> Enum.flat_map(& &1)
    |> Enum.uniq()
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
         progress
       ) do
    {direction, _key} = group_key
    derivation_key = derivation_key(direction, entry.sequence)
    timing_name = Map.get(context.timing_names, {direction, derivation_key})

    # A confirmed grouping target wins over a pattern derivation already owns:
    # the editor chose the pattern the group's trips join, and derivation's
    # second pass reaches the same group through this same key.
    {target, progress} =
      case Map.get(context.targets, {direction, derivation_key}) do
        %RoutePattern{} = pattern ->
          {existing_target(pattern, entry, context), progress}

        _absent ->
          plan_derived_target_from_context(
            route,
            context,
            group_key,
            entry,
            planning,
            derivation_key,
            progress
          )
      end

    # The confirmed name travels on the target, so a timing the review already
    # named is created under that name and every other one keeps derivation's
    # own next-timing-name rule.
    {Map.put(target, :timing_name, timing_name), progress}
  end

  defp plan_derived_target_from_context(
         route,
         context,
         group_key,
         entry,
         planning,
         derivation_key,
         progress
       ) do
    case Map.get(context.derived, derivation_key) do
      %RoutePattern{} = pattern ->
        # A derived pattern that survived a previous run already owns its
        # occurrences, so a retry reuses them the way a supplied pattern's are
        # reused instead of inserting a second copy of the same positions.
        {existing_target(pattern, entry, context), progress}

      nil ->
        create_derived_target(route, group_key, derivation_key, entry, planning, progress)
    end
  end

  # A pattern's target is its own occurrences, or the sequence derivation would
  # have given it when it has none yet.
  defp existing_target(pattern, entry, context) do
    case Map.get(context.occurrences, pattern.id) do
      nil -> existing_derived_target(pattern, entry.sequence, true)
      occurrences -> existing_derived_target(pattern, occurrences, false)
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

  # `label_pattern_id` is deliberately not cast by the changeset, so a label
  # child is given its owner here and nowhere else (rule 8).
  defp insert_pattern!(
         route,
         direction,
         derivation_key,
         name,
         typicality,
         representative_trip_id,
         label_pattern_id \\ nil
       ) do
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
    |> Ecto.Changeset.change(label_pattern_id: label_pattern_id)
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

  defp child_derivation_key(owner, sequence) do
    "l-" <> owner.route_pattern_id <> "-" <> derivation_key(owner.direction_id, sequence)
  end

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

      true ->
        case supplied_sequence_target(target, rows) do
          nil -> custom_decision(trip, :different_stops, state)
          sequence_target -> assign_trip(sequence_target, rows, trip, state)
        end
    end
  end

  # The owner's own sequence keeps the owner; any other sequence the supplied
  # pattern's trips served joins the child planned for it, so the exported
  # `route_pattern_id` stays the supplied ID.
  defp supplied_sequence_target(%{sequence: canonical} = target, rows) do
    case Enum.map(rows, & &1.stop_id) do
      ^canonical -> target
      sequence -> Map.get(Map.get(target, :children, %{}), sequence_key(sequence))
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

  # Rule 7: linking bumps `updated_at`, so a review that was open over these
  # trips goes stale for the next editor instead of applying twice.
  defp flush_links!(links) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(links, fn {{pattern_natural_id, timing_id}, trip_ids} ->
      from(t in Trip, where: t.id in ^trip_ids)
      |> Repo.update_all(
        set: [
          route_pattern_id: pattern_natural_id,
          pattern_derivation_state: "linked",
          pattern_derivation_reason: nil,
          timed_pattern_id: timing_id,
          updated_at: now
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

  # A blank arrival and departure is the absence of a scheduled time, not a
  # malformed row: it becomes a nil offset pair and `TimingRules` decides whether
  # its position allows the blank. A half pair is carried through the same way so
  # the rule that rejects it stays in one owner.
  defp timing_rows(vector) do
    with {:ok, parsed} <- parse_times(vector),
         rows = timing_row_values(vector, parsed),
         :ok <- valid_timing_rows(rows),
         :ok <- valid_attributes(vector) do
      {:ok, rows}
    else
      {:error, _reason} = error -> error
    end
  end

  # Offsets stay relative to the trip's first departure, and a blank row keeps
  # its nil pair instead of an offset of zero. A trip whose first row is blank is
  # rejected as a blank terminal below, so its neutral zero base never persists.
  defp timing_row_values(vector, parsed) do
    base =
      case parsed do
        [{_arrival, departure} | _rest] -> if(is_integer(departure), do: departure, else: 0)
      end

    vector
    |> Enum.zip(parsed)
    |> Enum.map(fn {stop_time, {arrival, departure}} ->
      %{
        arrival_offset: relative_offset(arrival, base),
        departure_offset: relative_offset(departure, base),
        timepoint: stop_time.timepoint,
        pickup_type: stop_time.pickup_type,
        drop_off_type: stop_time.drop_off_type,
        stop_headsign: stop_time.stop_headsign
      }
    end)
  end

  defp relative_offset(nil, _base), do: nil
  defp relative_offset(seconds, base), do: seconds - base

  defp valid_timing_rows(rows) do
    case TimingRules.validate(rows) do
      :ok -> :ok
      {:error, violations} -> timing_reason(violations)
    end
  end

  # Both reasons are custom classifications, so a trip that breaks more than one
  # rule keeps the more specific one: out of order is a different mistake from a
  # missing time.
  defp timing_reason(violations) do
    if Enum.any?(violations, &match?({_index, :out_of_order}, &1)) do
      {:error, :invalid_chronology}
    else
      {:error, :missing_times}
    end
  end

  defp parse_times([]), do: {:error, :missing_times}

  defp parse_times(vector) do
    Enum.reduce_while(vector, {:ok, []}, fn row, {:ok, acc} ->
      case parse_row_times(row) do
        {:ok, times} -> {:cont, {:ok, [times | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_row_times(row) do
    case {time_value(row.arrival_time), time_value(row.departure_time)} do
      {{:ok, arrival}, {:ok, departure}} -> {:ok, {arrival, departure}}
      {:blank, :blank} -> {:ok, {nil, nil}}
      {{:ok, arrival}, :blank} -> {:ok, {arrival, nil}}
      {:blank, {:ok, departure}} -> {:ok, {nil, departure}}
      {{:invalid, _value}, _departure} -> {:error, :invalid_time}
      {_arrival, {:invalid, _value}} -> {:error, :invalid_time}
    end
  end

  # An imported blank is nil or an empty string; anything else that is not a
  # parseable time is malformed input rather than an absent one.
  defp time_value(value) when value in [nil, ""], do: :blank

  defp time_value(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> {:ok, seconds}
      {:error, _reason} -> {:invalid, value}
    end
  end

  defp time_value(value), do: {:invalid, value}

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
        name: timing_name_for(target, pattern),
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

  # A grouping review already named the timing it would create (rule 6), so
  # that name is used. Every other timing keeps derivation's own rule, so an
  # import names timings exactly as before.
  defp timing_name_for(%{timing_name: name}, _pattern) when is_binary(name), do: name
  defp timing_name_for(_target, pattern), do: RoutePatterns.next_timing_name(pattern.id)

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
    (Map.values(plan.supplied) ++
       Map.values(plan.derived) ++ supplied_child_targets(plan.supplied))
    |> Enum.reduce(state, fn target, state ->
      if length(target.occurrences) >= 2 and not pattern_has_timing?(target.pattern.id) do
        {_timing_id, state} =
          create_timing(target, nil, zero_rows(length(target.occurrences)), state)

        state
      else
        state
      end
    end)
  end

  defp supplied_child_targets(supplied) do
    supplied
    |> Map.values()
    |> Enum.flat_map(fn target -> Map.values(Map.get(target, :children, %{})) end)
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

  defp audit_build!({:import, _import_run_id}, _route, _before, _after, _summary, _grouped),
    do: :ok

  defp audit_build!(
         {:editor, %AuditContext{} = audit},
         route,
         before,
         after_totals,
         summary,
         grouped
       ) do
    if changed?(before, after_totals, summary) do
      attrs = %{
        before: totals(before),
        after: totals(after_totals),
        patterns_created: summary.patterns_created,
        timings_created: summary.timings_created
      }

      # A grouped apply records the direction each trip had before the review
      # wrote it, so the route's build history can answer what grouping changed.
      attrs =
        if grouped == [] do
          attrs
        else
          Map.put(attrs, :grouped_trips, grouped)
        end

      case Audit.record_change_in_transaction(
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
