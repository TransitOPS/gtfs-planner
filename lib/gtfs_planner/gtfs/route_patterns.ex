defmodule GtfsPlanner.Gtfs.RoutePatterns do
  @moduledoc "Scoped reads and audited lifecycle writes for editable route patterns."

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @pattern_fields ~w(route_pattern_name route_pattern_time_desc route_pattern_typicality direction_id headsign canonical_route_pattern route_pattern_sort_order)
  @stop_search_limit 20
  @timing_fields ~w(name headsign)
  @forbidden_linkage_fields ~w(timed_pattern_id pattern_derivation_state pattern_derivation_reason trip_id trip_ids derivation_key)

  def list_patterns(organization_id, version_id, route_id) do
    with {:ok, _route} <- published_route(organization_id, version_id, route_id) do
      patterns =
        from(pattern in RoutePattern,
          where:
            pattern.organization_id == ^organization_id and
              pattern.gtfs_version_id == ^version_id and pattern.route_id == ^route_id,
          order_by: [
            asc: pattern.direction_id,
            asc: pattern.route_pattern_sort_order,
            asc: pattern.route_pattern_id
          ]
        )
        |> Repo.all()

      {:ok, %{patterns: patterns}}
    end
  end

  def get_pattern(organization_id, version_id, route_id, pattern_id, timing_id \\ nil) do
    with {:ok, _route} <- published_route(organization_id, version_id, route_id),
         %RoutePattern{} = pattern <-
           scoped_pattern(organization_id, version_id, route_id, pattern_id),
         {:ok, timing} <- selected_timing(pattern, timing_id) do
      occurrences =
        from(occurrence in RoutePatternStop,
          where: occurrence.route_pattern_id == ^pattern.id,
          order_by: [asc: occurrence.position]
        )
        |> Repo.all()

      timings =
        from(row in TimedPattern,
          where: row.route_pattern_id == ^pattern.id,
          order_by: [asc: row.name, asc: row.id]
        )
        |> Repo.all()

      {:ok,
       %{
         pattern: pattern,
         occurrences: occurrences,
         timings: timings,
         selected_timing: timing,
         source_fingerprint: source_fingerprint(pattern)
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Scoped read model for the pattern editor.

  Returns the route's pattern summaries with their stop, trip and timing counts,
  the route's pending/custom trip counts and bounded derivation error, the
  version's eligible stop choices (only when `include_stop_choices: true`), and
  optionally one pattern's detail: its ordered occurrences, every timing summary
  and only the selected timing's rows. Nothing else is loaded, so the editor
  never accumulates the feed's stop-time vectors (AC-18).

  A missing route, or a pattern outside the loaded route/version scope, returns
  `{:error, :not_found}`; a timing that belongs to another pattern returns
  `{:error, :timing_not_found}`.
  """
  def pattern_screen(organization_id, version_id, route_id, opts \\ []) do
    with {:ok, route} <- published_route(organization_id, version_id, route_id),
         {:ok, detail} <- pattern_detail(route, organization_id, version_id, route_id, opts) do
      patterns = route_patterns_in_order(route)

      stop_counts = route_row_counts(RoutePatternStop, route)
      trip_counts = route_row_counts(Trip, route)
      timing_counts = route_row_counts(TimedPattern, route)
      trip_states = trip_state_counts(route)

      summaries =
        Enum.map(patterns, fn pattern ->
          %{
            id: pattern.route_pattern_id,
            pattern: pattern,
            stop_count: Map.get(stop_counts, pattern.id, 0),
            trip_count: Map.get(trip_counts, pattern.route_pattern_id, 0),
            timing_count: Map.get(timing_counts, pattern.id, 0)
          }
        end)

      {:ok,
       %{
         route: route,
         patterns: summaries,
         pending_trip_count: Map.get(trip_states, "pending", 0),
         custom_trip_count: Map.get(trip_states, "custom", 0),
         linked_trip_count: Map.get(trip_states, "linked", 0),
         derivation_error: route.pattern_derivation_error,
         detail: detail,
         stop_choices:
           if(Keyword.get(opts, :include_stop_choices, false), do: stop_choices(route), else: [])
       }}
    end
  end

  defp route_patterns_in_order(route) do
    from(pattern in RoutePattern,
      where:
        pattern.organization_id == ^route.organization_id and
          pattern.gtfs_version_id == ^route.gtfs_version_id and
          pattern.route_id == ^route.route_id,
      order_by: [
        asc: pattern.direction_id,
        asc: pattern.route_pattern_sort_order,
        asc: pattern.route_pattern_id
      ]
    )
    |> Repo.all()
  end

  defp route_row_counts(schema, route) do
    from(row in schema,
      where:
        row.organization_id == ^route.organization_id and
          row.gtfs_version_id == ^route.gtfs_version_id,
      group_by: row.route_pattern_id,
      select: {row.route_pattern_id, count(row.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp trip_state_counts(route) do
    from(trip in Trip,
      where:
        trip.organization_id == ^route.organization_id and
          trip.gtfs_version_id == ^route.gtfs_version_id and trip.route_id == ^route.route_id,
      group_by: trip.pattern_derivation_state,
      select: {trip.pattern_derivation_state, count(trip.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp pattern_detail(_route, organization_id, version_id, route_id, opts) do
    case Keyword.get(opts, :pattern_id) do
      nil -> {:ok, nil}
      pattern_id -> load_pattern_detail(organization_id, version_id, route_id, opts, pattern_id)
    end
  end

  defp load_pattern_detail(organization_id, version_id, route_id, opts, pattern_id) do
    case scoped_pattern_by_natural_id(organization_id, version_id, route_id, pattern_id) do
      %RoutePattern{} = pattern ->
        build_pattern_detail(pattern, Keyword.get(opts, :timing_id))

      nil ->
        {:error, :not_found}
    end
  end

  defp build_pattern_detail(pattern, timing_id) do
    occurrences = pattern_occurrences(pattern.id)
    timings = pattern_timings(pattern.id)
    timing_trip_counts = timing_trip_counts(pattern)
    stops = stops_by_ids(pattern, Enum.map(occurrences, & &1.stop_id))

    with {:ok, selected} <- select_detail_timing(timings, timing_id) do
      {:ok,
       %{
         pattern: pattern,
         occurrences: occurrences,
         stops: stops,
         timings:
           Enum.map(timings, fn timing ->
             %{timing: timing, trip_count: Map.get(timing_trip_counts, timing.id, 0)}
           end),
         selected_timing: selected,
         selected_timing_rows: detail_timing_rows(pattern, selected, stops),
         stop_count: length(occurrences),
         trip_count: pattern_trip_count(pattern),
         custom_trip_count: pattern_state_count(pattern, "custom"),
         linked_trip_count: pattern_state_count(pattern, "linked"),
         source_fingerprint: source_fingerprint(pattern)
       }}
    end
  end

  defp detail_timing_rows(_pattern, nil, _stops), do: []

  defp detail_timing_rows(pattern, selected, stops),
    do: selected_timing_rows(pattern.id, selected.id, stops)

  # Selecting no timing resolves to the pattern's first timing; a timing that
  # belongs to another pattern is a distinct not-found outcome so the editor can
  # refuse it without leaking the other pattern's data.
  defp select_detail_timing(timings, nil), do: {:ok, List.first(timings)}

  defp select_detail_timing(timings, timing_id) do
    case Enum.find(timings, &(&1.id == timing_id)) do
      %TimedPattern{} = timing -> {:ok, timing}
      nil -> {:error, :timing_not_found}
    end
  end

  defp scoped_pattern_by_natural_id(org_id, version_id, route_id, route_pattern_id) do
    Repo.one(
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^org_id and pattern.gtfs_version_id == ^version_id and
            pattern.route_id == ^route_id and pattern.route_pattern_id == ^route_pattern_id
      )
    )
  end

  defp pattern_trip_count(pattern) do
    Repo.aggregate(
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_pattern_id == ^pattern.route_pattern_id
      ),
      :count
    )
  end

  # The pattern's own custom (and linked) trip counts, so the editor explains a
  # blocked stop list with this pattern's figures rather than the route's.
  defp pattern_state_count(pattern, state) do
    Repo.aggregate(
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_pattern_id == ^pattern.route_pattern_id and
            trip.pattern_derivation_state == ^state
      ),
      :count
    )
  end

  # Only the selected timing's rows are read, and each row is bounded to its
  # occurrence position and offset values; no full stop-time vector list is
  # retained for any other timing.
  defp selected_timing_rows(pattern_id, timing_id, stops) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where: row.timed_pattern_id == ^timing_id and occurrence.route_pattern_id == ^pattern_id,
      order_by: [asc: occurrence.position],
      select: %{
        route_pattern_stop_id: occurrence.id,
        position: occurrence.position,
        stop_id: occurrence.stop_id,
        arrival_offset: row.arrival_offset,
        departure_offset: row.departure_offset,
        timepoint: row.timepoint,
        pickup_type: row.pickup_type,
        drop_off_type: row.drop_off_type,
        stop_headsign: row.stop_headsign
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :stop, Map.get(stops, &1.stop_id)))
  end

  defp timing_trip_counts(pattern) do
    from(trip in Trip,
      where:
        trip.organization_id == ^pattern.organization_id and
          trip.gtfs_version_id == ^pattern.gtfs_version_id and
          trip.route_pattern_id == ^pattern.route_pattern_id and
          not is_nil(trip.timed_pattern_id),
      group_by: trip.timed_pattern_id,
      select: {trip.timed_pattern_id, count(trip.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp stops_by_ids(_pattern, []), do: %{}

  defp stops_by_ids(pattern, stop_ids) do
    from(stop in Stop,
      where:
        stop.organization_id == ^pattern.organization_id and
          stop.gtfs_version_id == ^pattern.gtfs_version_id and
          stop.stop_id in ^Enum.uniq(stop_ids),
      order_by: [asc: stop.stop_name, asc: stop.stop_id]
    )
    |> Repo.all()
    |> Map.new(&{&1.stop_id, &1})
  end

  # Eligible stops are those GTFS allows in a stop sequence. The list is a
  # bounded, name-ordered choice set; targeted search remains the editor's
  # scoped query path.
  @stop_choice_limit 300

  defp stop_choices(route) do
    from(stop in Stop,
      where:
        stop.organization_id == ^route.organization_id and
          stop.gtfs_version_id == ^route.gtfs_version_id and
          (is_nil(stop.location_type) or stop.location_type == 0),
      order_by: [asc: stop.stop_name, asc: stop.stop_id],
      limit: @stop_choice_limit
    )
    |> Repo.all()
  end

  @doc """
  Scoped stop search for the pattern editor.

  Returns at most `@stop_search_limit` GTFS stops or platforms (`location_type`
  nil or 0) in the loaded organization/version scope, ordered by name then ID,
  and a `truncated?` flag when more matches exist. A blank or non-binary query
  returns no matches, so a blank field never scans the feed.
  """
  def search_stops(organization_id, version_id, query) when is_binary(query) do
    case query |> String.trim() |> search_pattern() do
      nil ->
        {:ok, %{stops: [], truncated?: false}}

      pattern ->
        rows =
          from(stop in Stop,
            where:
              stop.organization_id == ^organization_id and
                stop.gtfs_version_id == ^version_id and
                (is_nil(stop.location_type) or stop.location_type == 0) and
                (ilike(stop.stop_name, ^pattern) or ilike(stop.stop_id, ^pattern)),
            order_by: [asc: stop.stop_name, asc: stop.stop_id],
            limit: @stop_search_limit + 1
          )
          |> Repo.all()

        {matches, extra} = Enum.split(rows, @stop_search_limit)
        {:ok, %{stops: matches, truncated?: extra != []}}
    end
  end

  def search_stops(_organization_id, _version_id, _query),
    do: {:ok, %{stops: [], truncated?: false}}

  # Wraps a trimmed query as a substring pattern and neutralizes the LIKE
  # wildcards a user could otherwise type to scan the version's stops.
  defp search_pattern(""), do: nil

  defp search_pattern(query) do
    "%" <> String.replace(query, ~r/[\\%_]/, fn match -> "\\" <> match end) <> "%"
  end

  @doc """
  Read-only preview of a staged stop edit.

  Returns the proposed timing rows, estimates, start shifts and affected trip
  count for the editor to display before staff acknowledge them. It writes
  nothing and does not require acknowledgement, so the acknowledgements bound by
  `review/4` always describe values the editor actually showed.
  """
  def preview_stop_edit(pattern_id, operation, %AuditContext{} = audit_context)
      when is_binary(pattern_id) do
    Repo.transaction(fn ->
      with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context),
           {:ok, %{pattern: pattern} = loaded} <-
             get_pattern(
               audit_context.organization_id,
               audit_context.gtfs_version_id,
               route_id,
               pattern_id
             ),
           :ok <-
             validate_lifecycle_operation(pattern, operation, loaded,
               require_acknowledgements: false
             ),
           {:ok, proposal} <-
             review_proposal(pattern, operation, loaded, require_acknowledgements: false) do
        {:ok, %{proposed: proposal, impact: operation_impact(operation, loaded)}}
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_read_transaction()
  end

  def preview_stop_edit(_, _, _), do: {:error, :invalid_input}

  def create_pattern(route_id, attrs, %AuditContext{} = audit_context) when is_map(attrs) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_pattern_attrs(attrs),
         {:ok, stops} <- normalize_stop_ids(attrs),
         :ok <- validate_occurrence_list(stops) do
      run_serializable_write(fn ->
        route = lock_published_route!(audit_context, route_id)
        eligible_stops = load_eligible_stops!(route, stops)

        pattern =
          %RoutePattern{}
          |> RoutePattern.changeset(
            Map.merge(values, %{
              route_pattern_id: natural_pattern_id(),
              route_id: route.route_id,
              organization_id: route.organization_id,
              gtfs_version_id: route.gtfs_version_id
            })
          )
          |> insert_or_rollback!()

        occurrences = insert_occurrences!(pattern, eligible_stops)
        timing = insert_timing!(pattern, "Timing A", nil)
        insert_timing_rows!(timing, occurrences, zero_timing_rows(length(occurrences)))

        audited_pattern = load_pattern_for_audit!(pattern.id)

        audit!(audit_context, :route_pattern, audited_pattern, "created", %{
          after: pattern_snapshot(audited_pattern)
        })

        audited_pattern
      end)
    end
  end

  def create_pattern(_, _, _), do: {:error, :invalid_input}

  def review(pattern_id, operation, source_fingerprint, %AuditContext{} = audit_context)
      when is_binary(pattern_id) do
    Repo.transaction(fn ->
      unless Keyword.get(Repo.config(), :pool) == Ecto.Adapters.SQL.Sandbox do
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
      end

      with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context),
           {:ok, %{pattern: pattern} = loaded} <-
             get_pattern(
               audit_context.organization_id,
               audit_context.gtfs_version_id,
               route_id,
               pattern_id
             ),
           true <- is_nil(source_fingerprint) or source_fingerprint == loaded.source_fingerprint,
           :ok <- validate_lifecycle_operation(pattern, operation, loaded),
           {:ok, proposal} <- review_proposal(pattern, operation, loaded) do
        impact = operation_impact(operation, loaded)

        {:ok,
         %{
           fingerprint:
             review_fingerprint(loaded.source_fingerprint, {operation, impact, proposal}),
           impact: impact,
           proposed: proposal
         }}
      else
        false -> Repo.rollback(:stale_review)
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_read_transaction()
  end

  def review(_, _, _, _), do: {:error, :invalid_input}

  defp unwrap_read_transaction({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_read_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_read_transaction({:error, reason}), do: {:error, reason}

  def apply_review(pattern_id, operation, review_fingerprint, %AuditContext{} = audit_context)
      when is_binary(pattern_id) and is_binary(review_fingerprint) do
    with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context) do
      run_serializable_write(fn ->
        apply_review_transaction(
          pattern_id,
          operation,
          route_id,
          review_fingerprint,
          audit_context
        )
      end)
    end
  end

  def apply_review(_, _, _, _), do: {:error, :invalid_input}

  @doc false
  def audit_snapshot(%RoutePattern{} = pattern), do: pattern_snapshot(pattern)

  @doc false
  def audit_timing_snapshot(%TimedPattern{} = timing) do
    %{
      id: timing.id,
      route_pattern_id: timing.route_pattern_id,
      name: timing.name,
      headsign: timing.headsign,
      derivation_key: timing.derivation_key,
      rows:
        Enum.map(timing_rows(timing.id), fn row ->
          occurrence = Repo.get!(RoutePatternStop, row.route_pattern_stop_id)

          Map.merge(timing_row_attrs(row), %{
            occurrence_id: occurrence.id,
            position: occurrence.position
          })
        end)
    }
  end

  defp apply_lifecycle_operation!(_route, pattern, {:details, attrs}, audit_context) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, attrs} <- normalize_allowed_attrs(attrs, @pattern_fields),
         :ok <- validate_noop_or_pattern(pattern, attrs) do
      attrs = RoutePattern.changeset(pattern, attrs).changes

      if same_values?(pattern, attrs) do
        %{pattern: pattern, trips_updated: 0}
      else
        trips_updated = update_direction_trips(pattern, attrs)

        updated = pattern |> RoutePattern.changeset(attrs) |> update_or_rollback!()
        maybe_clear_pattern_signature!(pattern, attrs)

        audit!(
          audit_context,
          :route_pattern,
          pattern,
          "updated",
          Map.put(attrs, :affected_trips, trips_updated)
        )

        %{pattern: load_pattern_for_audit!(updated.id), trips_updated: trips_updated}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_lifecycle_operation!(
         _route,
         pattern,
         {:stops, entries, reviewed_values},
         audit_context
       ) do
    case prepare_stop_edit(pattern, entries, reviewed_values) do
      {:ok, edit} -> apply_stop_edit!(pattern, edit, audit_context)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_lifecycle_operation!(_route, pattern, {:timing, timing_id, attrs}, audit_context) do
    rows_input = Map.get(attrs, :rows, Map.get(attrs, "rows"))

    with {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         %TimedPattern{} = timing <- scoped_timing(pattern, timing_id),
         :ok <- validate_timing_attrs(values),
         {:ok, rows} <- validate_timing_rows(pattern, timing, rows_input) do
      values = TimedPattern.changeset(timing, values).changes
      before = audit_timing_snapshot(timing)

      if same_values?(timing, values) and timing_rows_unchanged?(timing, rows) do
        %{pattern: pattern, trips_updated: 0}
      else
        apply_timing_edit!(pattern, timing, values, rows, before, audit_context)
      end
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_lifecycle_operation!(_route, pattern, {:add_timing, attrs}, audit_context) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values),
         {:ok, source} <- copy_source_timing(pattern, attrs) do
      name = Map.get(values, :name) || next_timing_name(pattern.id)
      timing = insert_timing!(pattern, name, Map.get(values, :headsign))
      occurrences = pattern_occurrences(pattern.id)

      if source,
        do: copy_timing_rows!(timing, occurrences, timing_rows(source.id)),
        else: insert_timing_rows!(timing, occurrences, zero_timing_rows(length(occurrences)))

      audit!(
        audit_context,
        :timed_pattern,
        timing,
        "created",
        timing_audit_attrs(pattern, timing, %{after: audit_timing_snapshot(timing)})
      )

      %{pattern: pattern, trips_updated: 0}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_lifecycle_operation!(route, pattern, {:delete_timing, timing_id}, audit_context) do
    timing = scoped_timing(pattern, timing_id)

    cond do
      is_nil(timing) ->
        Repo.rollback(:not_found)

      timing_count(pattern.id) <= 1 ->
        Repo.rollback(:last_timing)

      timing_used?(route, timing) ->
        Repo.rollback(:timing_in_use)

      true ->
        audit_pattern = pattern

        audit!(
          audit_context,
          :timed_pattern,
          timing,
          "deleted",
          timing_audit_attrs(audit_pattern, timing, %{})
        )

        Repo.delete!(timing)
        %{pattern: pattern, trips_updated: 0}
    end
  end

  defp apply_lifecycle_operation!(_route, pattern, :copy, audit_context) do
    copied =
      %RoutePattern{
        organization_id: pattern.organization_id,
        gtfs_version_id: pattern.gtfs_version_id,
        route_id: pattern.route_id,
        direction_id: pattern.direction_id
      }
      |> RoutePattern.changeset(%{
        route_pattern_id: natural_pattern_id(),
        route_pattern_name: copy_name(pattern.route_pattern_name),
        route_pattern_time_desc: pattern.route_pattern_time_desc,
        route_pattern_typicality: pattern.route_pattern_typicality,
        headsign: pattern.headsign,
        direction_id: pattern.direction_id,
        representative_trip_id: nil,
        derivation_key: nil,
        active: true
      })
      |> insert_or_rollback!()

    copied_occurrences =
      pattern
      |> pattern_occurrences()
      |> Enum.map(fn occurrence ->
        insert_occurrence!(copied, occurrence.stop_id, occurrence.position)
      end)

    pattern
    |> pattern_timings()
    |> Enum.each(fn timing ->
      copied_timing = insert_timing!(copied, timing.name, timing.headsign)
      rows = timing_rows(timing.id)
      copy_timing_rows!(copied_timing, copied_occurrences, rows)
    end)

    Alignments.copy_pattern_alignment!(
      pattern,
      copied,
      pattern_occurrences(pattern),
      copied_occurrences,
      audit_context
    )

    copied = load_pattern_for_audit!(copied.id)
    audit!(audit_context, :route_pattern, copied, "created", %{after: pattern_snapshot(copied)})
    %{pattern: copied, trips_updated: 0}
  end

  defp apply_lifecycle_operation!(route, pattern, :delete, audit_context) do
    if pattern_used?(route, pattern) do
      Repo.rollback(:pattern_in_use)
    else
      snapshot = pattern_snapshot(load_pattern_for_audit!(pattern.id))
      audit!(audit_context, :route_pattern, pattern, "deleted", %{before: snapshot})
      _children = delete_pattern_children!([pattern.id])
      Alignments.delete_owned_shape!(pattern)
      Repo.delete!(pattern)
      %{pattern: nil, trips_updated: 0}
    end
  end

  defp apply_lifecycle_operation!(_route, _pattern, _operation, _audit_context),
    do: Repo.rollback(:invalid_operation)

  # A new timing either starts blank or copies another timing of the same
  # pattern; the source is resolved from the loaded pattern, never trusted as a
  # browser-supplied identity.
  defp copy_source_timing(pattern, attrs) do
    case map_value(attrs, :source_timing_id) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      source_id ->
        case scoped_timing(pattern, source_id) do
          %TimedPattern{} = source -> {:ok, source}
          nil -> {:error, :not_found}
        end
    end
  end

  defp update_direction_trips(pattern, attrs) do
    case Map.fetch(attrs, :direction_id) do
      {:ok, direction_id} -> update_trip_direction!(pattern, direction_id)
      :error -> 0
    end
  end

  defp apply_stop_edit!(pattern, %{noop?: true}, _audit_context),
    do: %{pattern: pattern, trips_updated: 0}

  defp apply_stop_edit!(pattern, edit, audit_context) do
    # The before snapshot has to be read before any occurrence/timing row is
    # written; querying it after persistence would record the post-mutation
    # structure as its own predecessor.
    before = pattern_snapshot(pattern)
    trips_updated = persist_stop_edit!(pattern, edit)
    clear_structure_signatures!(pattern)
    after_pattern = load_pattern_for_audit!(pattern.id)

    audit!(audit_context, :route_pattern, after_pattern, "updated", %{
      before: before,
      after: pattern_snapshot(after_pattern),
      affected_trips: trips_updated
    })

    %{pattern: after_pattern, trips_updated: trips_updated}
  end

  defp apply_timing_edit!(pattern, timing, values, rows, before, audit_context) do
    trips_updated = if rows, do: persist_timing_edit!(pattern, timing, rows), else: 0
    if rows, do: clear_timing_signature!(timing)
    if values != %{}, do: timing |> TimedPattern.changeset(values) |> update_or_rollback!()
    after_snapshot = audit_timing_snapshot(Repo.get!(TimedPattern, timing.id))

    audit!(
      audit_context,
      :timed_pattern,
      timing,
      "updated",
      timing_audit_attrs(
        pattern,
        timing,
        Map.merge(values, %{
          before: before,
          after: after_snapshot,
          affected_trips: trips_updated
        })
      )
    )

    %{pattern: pattern, trips_updated: trips_updated}
  end

  # FK-safe order: timing rows reference both timings and occurrences, so they
  # leave first. The set-based list form is shared by single pattern delete and
  # the reviewed route cascade (R5); callers own the pattern row deletion.
  defp delete_pattern_children!(pattern_ids) when is_list(pattern_ids) do
    timing_ids =
      from(timing in TimedPattern,
        where: timing.route_pattern_id in ^pattern_ids,
        select: timing.id
      )
      |> Repo.all()

    {timing_rows, nil} =
      Repo.delete_all(from(row in TimedPatternStop, where: row.timed_pattern_id in ^timing_ids))

    {timings, nil} =
      Repo.delete_all(from(timing in TimedPattern, where: timing.id in ^timing_ids))

    {occurrences, nil} =
      Repo.delete_all(
        from(occurrence in RoutePatternStop, where: occurrence.route_pattern_id in ^pattern_ids)
      )

    %{
      timed_pattern_stops: timing_rows,
      timed_patterns: timings,
      pattern_stops: occurrences
    }
  end

  # R5 M1's bounded retry convention: a serialization failure (40001) or
  # deadlock (40P01) reruns the whole transaction closure, at most three times,
  # then returns `:busy`. Every other failure is returned unchanged.
  defp run_serializable_write(transaction, attempts \\ 3) do
    case run_apply_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:retryable_conflict, _error} ->
        retry_serializable_write(transaction, attempts)

      {:error, reason} ->
        retry_serializable_write_error(reason, transaction, attempts)
    end
  end

  defp retry_serializable_write(transaction, attempts) when attempts > 1,
    do: run_serializable_write(transaction, attempts - 1)

  defp retry_serializable_write(_transaction, _attempts), do: {:error, :busy}

  defp retry_serializable_write_error(reason, transaction, attempts) do
    if retryable_conflict?(reason),
      do: retry_serializable_write(transaction, attempts),
      else: {:error, reason}
  end

  defp run_apply_transaction(transaction) do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    ).run(transaction)
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

  defp retryable_conflict?(_), do: false

  defp apply_review_transaction(pattern_id, operation, route_id, fingerprint, audit_context) do
    route = lock_published_route!(audit_context, route_id)
    pattern = lock_pattern!(route, pattern_id)
    lock_trips_for_operation!(route, pattern, operation)
    loaded_view = load_locked_pattern!(route, pattern, audit_context)
    verify_review_fingerprint!(loaded_view, operation, fingerprint)
    apply_lifecycle_operation!(route, loaded_view.pattern, operation, audit_context)
  end

  defp lock_trips_for_operation!(route, pattern, operation) do
    if trips_lock_required?(operation), do: lock_pattern_trips!(route, pattern)
  end

  defp load_locked_pattern!(route, pattern, audit_context) do
    case get_pattern(
           audit_context.organization_id,
           audit_context.gtfs_version_id,
           route.route_id,
           pattern.id
         ) do
      {:ok, loaded_view} -> loaded_view
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp verify_review_fingerprint!(loaded_view, operation, fingerprint) do
    reviewed_source = fingerprint |> String.split(":", parts: 2) |> hd()

    unless secure_equal?(reviewed_source, loaded_view.source_fingerprint),
      do: Repo.rollback(:stale_review)

    pattern = loaded_view.pattern
    impact = operation_impact(operation, %{pattern: pattern})

    with :ok <- validate_lifecycle_operation(pattern, operation, loaded_view),
         {:ok, proposal} <- review_proposal(pattern, operation, loaded_view) do
      current = review_fingerprint(loaded_view.source_fingerprint, {operation, impact, proposal})
      if secure_equal?(fingerprint, current), do: :ok, else: Repo.rollback(:stale_review)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # `opts` carries `require_acknowledgements: false` for the read-only preview, so
  # the editor can show proposed values before staff acknowledge them.
  defp validate_lifecycle_operation(pattern, operation, loaded, opts \\ [])

  defp validate_lifecycle_operation(pattern, {:stops, entries, reviewed_values}, loaded, opts) do
    case prepare_stop_edit(pattern, entries, reviewed_values, loaded, opts) do
      {:ok, _edit} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_lifecycle_operation(pattern, {:details, attrs}, _loaded, _opts) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @pattern_fields) do
      validate_noop_or_pattern(pattern, values)
    end
  end

  defp validate_lifecycle_operation(pattern, {:timing, timing_id, attrs}, _loaded, _opts) do
    with %TimedPattern{} <- scoped_timing(pattern, timing_id),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values),
         {:ok, _rows} <-
           validate_timing_rows(pattern, scoped_timing(pattern, timing_id), Map.get(attrs, :rows)) do
      :ok
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp validate_lifecycle_operation(pattern, {:add_timing, attrs}, _loaded, _opts) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values) do
      case copy_source_timing(pattern, attrs) do
        {:ok, _source} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_lifecycle_operation(pattern, {:delete_timing, timing_id}, _loaded, _opts) do
    timing = scoped_timing(pattern, timing_id)

    cond do
      is_nil(timing) -> {:error, :not_found}
      timing_count(pattern.id) <= 1 -> {:error, :last_timing}
      timing_used?(nil, timing) -> {:error, :timing_in_use}
      true -> :ok
    end
  end

  defp validate_lifecycle_operation(pattern, :copy, _loaded, _opts) do
    if is_nil(pattern), do: {:error, :not_found}, else: :ok
  end

  defp validate_lifecycle_operation(pattern, :delete, _loaded, _opts) do
    if pattern_used?(nil, pattern), do: {:error, :pattern_in_use}, else: :ok
  end

  defp validate_lifecycle_operation(_pattern, _, _, _), do: {:error, :invalid_operation}

  defp operation_impact({:delete_timing, timing_id}, %{pattern: pattern}) do
    %{trips_affected: count_timing_trips(pattern, timing_id)}
  end

  defp operation_impact(:delete, %{pattern: pattern}),
    do: %{trips_affected: count_pattern_trips(pattern)}

  defp operation_impact({:stops, _entries, _values}, %{pattern: pattern}),
    do: %{trips_affected: count_pattern_trips(pattern)}

  defp operation_impact({:timing, timing_id, _attrs}, %{pattern: pattern}),
    do: %{trips_affected: count_timing_trips(pattern, timing_id)}

  defp operation_impact({:details, attrs}, %{pattern: pattern}) when is_map(attrs) do
    changes = RoutePattern.changeset(pattern, attrs).changes

    if Map.has_key?(changes, :direction_id),
      do: %{trips_affected: count_pattern_trips(pattern)},
      else: %{trips_affected: 0}
  end

  defp operation_impact(_, _), do: %{trips_affected: 0}

  defp operation_proposal({:details, attrs}, _pattern), do: attrs
  defp operation_proposal({:timing, _id, attrs}, _pattern), do: attrs
  defp operation_proposal({:add_timing, attrs}, _pattern), do: attrs

  defp operation_proposal({:stops, entries, values}, pattern),
    do: %{occurrences: entries, timings: values, pattern_id: pattern.id}

  defp operation_proposal(operation, _pattern), do: operation

  defp review_proposal(pattern, operation, loaded, opts \\ [])

  defp review_proposal(pattern, {:stops, entries, reviewed_values}, loaded, opts) do
    with {:ok, edit} <- prepare_stop_edit(pattern, entries, reviewed_values, loaded, opts) do
      {:ok,
       %{
         occurrences: Enum.map(edit.new_occurrences, &occurrence_proposal/1),
         removed: edit.removed,
         added: edit.added,
         timing_rows: edit.timing_rows,
         start_shifts: edit.start_shifts,
         estimates: edit.estimates
       }}
    end
  end

  defp review_proposal(pattern, {:timing, timing_id, attrs}, _loaded, _opts) do
    timing = scoped_timing(pattern, timing_id)

    with {:ok, rows} <- validate_timing_rows(pattern, timing, map_value(attrs, :rows)) do
      {:ok, if(rows, do: %{attrs: Map.drop(attrs, [:rows, "rows"]), rows: rows}, else: attrs)}
    end
  end

  defp review_proposal(_pattern, operation, _loaded, _opts),
    do: {:ok, operation_proposal(operation, nil)}

  defp prepare_stop_edit(pattern, entries, reviewed_values, loaded \\ nil, opts \\ []) do
    old_occurrences = if loaded, do: loaded.occurrences, else: pattern_occurrences(pattern)
    timings = if loaded, do: loaded.timings, else: pattern_timings(pattern)
    trips = pattern_trips(pattern)

    with {:ok, new_occurrences} <- normalize_occurrence_entries(entries, pattern),
         :ok <- validate_retained_stop_ids(old_occurrences, new_occurrences),
         :ok <- validate_structural_trips(trips, old_occurrences, new_occurrences),
         :ok <- ensure_eligible_occurrences!(pattern, new_occurrences),
         {:ok, timing_groups} <- load_timing_groups(timings),
         {:ok, reviewed} <-
           Materializer.review_stops(
             old_occurrences,
             new_occurrences,
             timing_groups,
             reviewed_values
           ),
         :ok <-
           require_timing_acknowledgements(
             new_occurrences,
             reviewed.estimates,
             reviewed_values,
             trips,
             timings,
             opts
           ),
         true <- timing_ids_match?(timings, reviewed.timing_rows) do
      new_ids = MapSet.new(Enum.map(new_occurrences, &Map.get(&1, :id)))
      removed = Enum.reject(old_occurrences, &MapSet.member?(new_ids, &1.id))
      added = Enum.reject(new_occurrences, &Map.get(&1, :id))

      {:ok,
       %{
         old_occurrences: old_occurrences,
         new_occurrences: new_occurrences,
         timings: timings,
         timing_rows: reviewed.timing_rows,
         start_shifts: Map.get(reviewed, :shifts, [%{start_shift: reviewed.start_shift}]),
         estimates: reviewed.estimates,
         removed: Enum.map(removed, &occurrence_proposal/1),
         added: Enum.map(added, &occurrence_proposal/1),
         noop?:
           Enum.map(old_occurrences, &{&1.id, &1.stop_id}) ==
             Enum.map(new_occurrences, &{Map.get(&1, :id), &1.stop_id})
       }}
    else
      false -> {:error, :invalid_timing_review}
      {:error, _} = error -> error
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp normalize_occurrence_entries(entries, _pattern) when is_list(entries) do
    normalized =
      Enum.map(entries, fn entry ->
        id = map_value(entry, :id)
        stop_id = map_value(entry, :stop_id)
        key = map_value(entry, :key)

        cond do
          is_binary(id) and is_binary(stop_id) -> %{id: id, stop_id: stop_id}
          is_nil(id) and is_binary(stop_id) and is_binary(key) -> %{key: key, stop_id: stop_id}
          true -> nil
        end
      end)

    if Enum.any?(normalized, &is_nil/1), do: {:error, :invalid_input}, else: {:ok, normalized}
  end

  defp normalize_occurrence_entries(_, _), do: {:error, :invalid_input}

  defp validate_structural_trips(trips, old_occurrences, new_occurrences) do
    linked? = Enum.any?(trips, &(&1.pattern_derivation_state == "linked"))
    custom? = Enum.any?(trips, &(&1.pattern_derivation_state == "custom"))
    retained = Enum.filter(new_occurrences, &Map.has_key?(&1, :id))

    cond do
      custom? ->
        {:error, :custom_trips_block_stop_edit}

      length(new_occurrences) < 2 ->
        {:error, :at_least_two_stops}

      linked? and retained == [] ->
        {:error, :retained_occurrence_required}

      linked? ->
        old_ids = Enum.map(old_occurrences, & &1.id)
        new_ids = Enum.map(retained, & &1.id)

        if new_ids == Enum.filter(old_ids, &(&1 in new_ids)),
          do: :ok,
          else: {:error, :invalid_occurrence_order}

      true ->
        :ok
    end
  end

  defp ensure_eligible_occurrences!(pattern, occurrences) do
    stop_ids = Enum.map(occurrences, & &1.stop_id)

    cond do
      length(stop_ids) < 2 ->
        {:error, :at_least_two_stops}

      Enum.any?(Enum.chunk_every(stop_ids, 2, 1, :discard), fn [a, b] -> a == b end) ->
        {:error, :adjacent_duplicate_stops}

      true ->
        ensure_stops_exist(pattern, stop_ids)
    end
  end

  defp ensure_stops_exist(pattern, stop_ids) do
    eligible =
      from(stop in Stop,
        where:
          stop.organization_id == ^pattern.organization_id and
            stop.gtfs_version_id == ^pattern.gtfs_version_id and
            stop.stop_id in ^stop_ids and (is_nil(stop.location_type) or stop.location_type == 0),
        select: stop.stop_id
      )
      |> Repo.all()
      |> MapSet.new()

    if MapSet.size(eligible) == length(Enum.uniq(stop_ids)),
      do: :ok,
      else: {:error, :not_found}
  end

  defp validate_retained_stop_ids(old_occurrences, new_occurrences) do
    old_by_id = Map.new(old_occurrences, &{&1.id, &1.stop_id})

    if Enum.all?(new_occurrences, &retained_identity_valid?(&1, old_by_id)) do
      :ok
    else
      {:error, :invalid_occurrence_identity}
    end
  end

  defp retained_identity_valid?(occurrence, old_by_id) do
    case Map.fetch(occurrence, :id) do
      {:ok, id} -> Map.get(old_by_id, id) == occurrence.stop_id
      :error -> true
    end
  end

  defp load_timing_groups(timings) do
    {:ok,
     Enum.map(timings, fn timing -> %{timing_id: timing.id, rows: timing_rows(timing.id)} end)}
  end

  # An unseen added-stop value can never be silently acknowledged: when an
  # addition affects trips, every timing in the edit must carry an explicit
  # acknowledgement, not only the timings a caller happened to supply. Times
  # re-sequenced by a reorder are estimates as well and are written to the
  # timing rows whether or not any trip uses the pattern.
  defp require_timing_acknowledgements(new, estimates, values, trips, timings, opts) do
    added? = Enum.any?(new, &(not Map.has_key?(&1, :id)))
    affected? = trips != []
    resequenced? = Enum.any?(estimates, & &1[:resequenced])

    if ((added? and affected?) or resequenced?) and
         Keyword.get(opts, :require_acknowledgements, true) do
      acknowledged =
        for {timing_id, entry} <- values,
            map_value(entry, :acknowledged) == true,
            do: to_string(timing_id)

      required = Enum.map(timings, &to_string(&1.id))

      if Enum.sort(acknowledged) == Enum.sort(required),
        do: :ok,
        else: {:error, :timing_acknowledgement_required}
    else
      :ok
    end
  end

  defp timing_ids_match?(timings, result_rows),
    do:
      Enum.sort(Enum.map(timings, & &1.id)) ==
        Enum.sort(Enum.map(result_rows, &Map.get(&1, :timing_id)))

  defp occurrence_proposal(occurrence),
    do: %{
      id: Map.get(occurrence, :id),
      key: Map.get(occurrence, :key),
      stop_id: Map.get(occurrence, :stop_id)
    }

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_, _), do: nil

  defp validate_timing_rows(_pattern, _timing, nil), do: {:ok, nil}

  defp validate_timing_rows(pattern, _timing, rows) when is_list(rows) do
    occurrences = pattern_occurrences(pattern)

    normalized =
      Enum.map(rows, fn row ->
        %{
          route_pattern_stop_id: map_value(row, :route_pattern_stop_id),
          arrival_offset: map_value(row, :arrival_offset),
          departure_offset: map_value(row, :departure_offset),
          timepoint: map_value(row, :timepoint),
          pickup_type: map_value(row, :pickup_type),
          drop_off_type: map_value(row, :drop_off_type),
          stop_headsign: map_value(row, :stop_headsign)
        }
      end)

    with true <- length(normalized) == length(occurrences),
         true <-
           Enum.map(normalized, & &1.route_pattern_stop_id) == Enum.map(occurrences, & &1.id),
         true <- Enum.all?(normalized, &valid_service_row?/1),
         :ok <- validate_relative_rows(normalized) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  defp validate_timing_rows(_pattern, _timing, _rows), do: {:error, :invalid_input}

  defp valid_service_row?(row) do
    row.timepoint in [nil, 0, 1] and row.pickup_type in [nil, 0, 1, 2, 3] and
      row.drop_off_type in [nil, 0, 1, 2, 3] and
      is_integer(row.arrival_offset) and row.arrival_offset in -2_147_483_647..2_147_483_647 and
      is_integer(row.departure_offset) and row.departure_offset in 0..2_147_483_647
  end

  defp validate_relative_rows(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, nil}, fn {row, index}, {:ok, preceding_departure} ->
      arrival = row.arrival_offset
      departure = row.departure_offset

      case relative_row_error(arrival, departure, index, preceding_departure) do
        nil -> {:cont, {:ok, departure}}
        reason -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp relative_row_error(arrival, departure, index, preceding_departure) do
    cond do
      not is_integer(arrival) or not is_integer(departure) or departure < arrival ->
        :invalid_chronology

      index > 0 and arrival < preceding_departure ->
        :invalid_chronology

      index == 0 and departure != 0 ->
        :first_departure_must_be_zero

      true ->
        nil
    end
  end

  # A submitted vector that matches the stored timing row-for-row is a no-op: it
  # must not write rows, clear a derivation signature or record an audit entry.
  defp timing_rows_unchanged?(_timing, nil), do: true

  defp timing_rows_unchanged?(timing, rows) do
    stored =
      Enum.map(timing_rows(timing.id), fn row ->
        Map.merge(timing_row_attrs(row), %{route_pattern_stop_id: row.route_pattern_stop_id})
      end)

    stored == rows
  end

  defp persist_timing_edit!(pattern, timing, rows) do
    trips = linked_timing_trips(pattern, timing.id)
    occurrences = pattern_occurrences(pattern)

    Enum.each(trips, fn trip ->
      rematerialize_trip!(trip, occurrences, rows, current_trip_start!(trip, occurrences))
    end)

    update_trip_timestamps!(trips)

    Enum.zip(occurrences, rows)
    |> Enum.each(fn {occurrence, attrs} -> update_timing_row!(timing, occurrence, attrs) end)

    if rows != [] do
      Repo.update_all(from(t in TimedPattern, where: t.id == ^timing.id),
        set: [updated_at: DateTime.utc_now()]
      )
    end

    length(trips)
  end

  defp persist_stop_edit!(pattern, edit) do
    old = edit.old_occurrences
    new = persist_occurrences!(pattern, old, edit.new_occurrences)
    timing_rows_by_id = Map.new(edit.timing_rows, &{&1.timing_id, &1.rows})

    Enum.each(edit.timings, fn timing ->
      persist_pattern_timing_rows!(timing, old, new, Map.fetch!(timing_rows_by_id, timing.id))
    end)

    trips = linked_pattern_trips(pattern)

    shifts =
      Map.new(edit.start_shifts, fn item -> {Map.get(item, :timing_id), item.start_shift} end)

    Enum.each(trips, fn trip ->
      rows = Map.fetch!(timing_rows_by_id, trip.timed_pattern_id)
      shift = Map.get(shifts, trip.timed_pattern_id, Map.get(edit, :start_shift, 0))
      persist_structural_trip!(trip, old, new, rows, shift)
    end)

    update_trip_timestamps!(trips)

    if not is_nil(pattern.shape_id) and
         retained_structure_changed?(edit.old_occurrences, edit.new_occurrences) do
      Alignments.clear_visit_distances!(pattern)
    end

    if trips != [] or edit.added != [] or edit.removed != [] do
      Repo.update_all(from(p in RoutePattern, where: p.id == ^pattern.id),
        set: [updated_at: DateTime.utc_now()]
      )
    end

    length(trips)
  end

  # R14: a structural edit that changes the relative order of retained visits,
  # or a retained visit's stop, invalidates derived distances on a drawn pattern
  # (stale values would export decreasing distances). Inserts and removals keep
  # the remaining distances. `old_occurrences` are structs; `new_occurrences`
  # are `%{id | key, stop_id}` entries in position order, where `:id` marks a
  # retained visit.
  defp retained_structure_changed?(old_occurrences, new_occurrences) do
    old_by_id = Map.new(old_occurrences, &{&1.id, &1.stop_id})

    new_retained_ids =
      new_occurrences
      |> Enum.filter(&Map.get(&1, :id))
      |> Enum.map(&Map.get(&1, :id))

    new_retained_set = MapSet.new(new_retained_ids)

    old_retained_order =
      old_occurrences
      |> Enum.sort_by(& &1.position)
      |> Enum.map(& &1.id)
      |> Enum.filter(&MapSet.member?(new_retained_set, &1))

    order_changed? = new_retained_ids != old_retained_order

    stop_changed? =
      Enum.any?(new_occurrences, fn entry ->
        case Map.get(entry, :id) do
          nil -> false
          id -> Map.get(old_by_id, id) != Map.get(entry, :stop_id)
        end
      end)

    order_changed? or stop_changed?
  end

  defp persist_occurrences!(pattern, old, new) do
    new_ids = new |> Enum.map(&Map.get(&1, :id)) |> Enum.reject(&is_nil/1) |> MapSet.new()
    removed = Enum.reject(old, &MapSet.member?(new_ids, &1.id))

    if removed != [] do
      removed_ids = Enum.map(removed, & &1.id)

      Repo.delete_all(
        from(row in TimedPatternStop, where: row.route_pattern_stop_id in ^removed_ids)
      )
    end

    Enum.each(removed, &Repo.delete!/1)

    retained = Enum.filter(new, &Map.get(&1, :id))

    temp_positions =
      unused_positive_values(Enum.map(old, & &1.position), length(retained), length(new))

    Enum.zip(retained, temp_positions)
    |> Enum.each(fn {occurrence, position} ->
      Repo.update_all(from(o in RoutePatternStop, where: o.id == ^occurrence.id),
        set: [position: position]
      )
    end)

    Enum.with_index(new, 1)
    |> Enum.map(fn {entry, position} ->
      case Map.get(entry, :id) do
        nil ->
          insert_occurrence!(pattern, entry.stop_id, position)

        id ->
          Repo.update_all(from(o in RoutePatternStop, where: o.id == ^id),
            set: [position: position, stop_id: entry.stop_id]
          )

          Repo.get!(RoutePatternStop, id)
      end
    end)
  end

  defp persist_pattern_timing_rows!(timing, old, new, rows) do
    new_ids = MapSet.new(Enum.map(new, & &1.id))
    removed_ids = old |> Enum.reject(&MapSet.member?(new_ids, &1.id)) |> Enum.map(& &1.id)

    Repo.delete_all(
      from(r in TimedPatternStop,
        where: r.timed_pattern_id == ^timing.id and r.route_pattern_stop_id in ^removed_ids
      )
    )

    existing = Map.new(timing_rows(timing.id), &{&1.route_pattern_stop_id, &1})

    Enum.zip(new, rows)
    |> Enum.each(fn {occurrence, attrs} ->
      case Map.get(existing, occurrence.id) do
        nil ->
          insert_timing_rows!(timing, [occurrence], [attrs])

        row ->
          row
          |> Ecto.Changeset.change(
            Map.take(attrs, [
              :arrival_offset,
              :departure_offset,
              :timepoint,
              :pickup_type,
              :drop_off_type,
              :stop_headsign
            ])
          )
          |> update_or_rollback!()
      end
    end)
  end

  defp persist_structural_trip!(trip, old_occurrences, new_occurrences, timing_rows, shift) do
    rows = trip_stop_times(trip)

    if length(rows) != length(old_occurrences), do: Repo.rollback(:trip_stop_times_mismatch)

    with {:ok, start_seconds} <- trip_start_seconds(rows),
         {:ok, materialized} <-
           Materializer.materialize(start_seconds + shift, new_occurrences, timing_rows) do
      persist_structural_rows!(
        trip,
        rows,
        old_occurrences,
        new_occurrences,
        timing_rows,
        materialized
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp trip_start_seconds([first | _]), do: GtfsTime.parse(first.departure_time)

  # The single caller of `rematerialize_trip!/4` resolves each trip's current
  # first departure itself and passes it in, so the shared seam takes the start
  # as an argument instead of reading it from the trip's first stop time.
  defp current_trip_start!(trip, occurrences) do
    stop_times = trip_stop_times(trip)

    if length(stop_times) != length(occurrences),
      do: Repo.rollback(:trip_stop_times_mismatch)

    case trip_start_seconds(stop_times) do
      {:ok, start_seconds} -> start_seconds
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_structural_rows!(
         trip,
         rows,
         old_occurrences,
         new_occurrences,
         timing_rows,
         materialized
       ) do
    old_by_occurrence = old_rows_by_occurrence(old_occurrences, new_occurrences, rows)
    retained_times = old_by_occurrence |> Map.values() |> Enum.reject(&is_nil/1)
    delete_removed_stop_times!(rows, retained_times)
    move_retained_sequences!(rows, retained_times, length(new_occurrences))

    persist_final_occurrence_rows!(
      trip,
      new_occurrences,
      timing_rows,
      materialized,
      old_by_occurrence
    )
  end

  defp old_rows_by_occurrence(old_occurrences, new_occurrences, rows) do
    occurrence_indexes =
      Map.new(Enum.with_index(old_occurrences), fn {item, index} -> {item.id, index} end)

    Map.new(new_occurrences, fn occurrence ->
      old_index = Map.get(occurrence_indexes, occurrence.id)
      {occurrence.id, if(old_index, do: Enum.at(rows, old_index))}
    end)
  end

  defp delete_removed_stop_times!(rows, retained_times) do
    rows
    |> Enum.reject(&(&1 in retained_times))
    |> Enum.each(&Repo.delete!/1)
  end

  defp move_retained_sequences!(rows, retained_times, final_count) do
    temporary_values =
      unused_positive_values(
        Enum.map(rows, & &1.stop_sequence),
        length(retained_times),
        final_count
      )

    Enum.zip(retained_times, temporary_values)
    |> Enum.each(fn {row, sequence} ->
      Repo.update_all(from(st in StopTime, where: st.id == ^row.id),
        set: [stop_sequence: sequence]
      )
    end)
  end

  defp persist_final_occurrence_rows!(trip, occurrences, timing_rows, materialized, old_rows) do
    Enum.zip([occurrences, materialized, timing_rows])
    |> Enum.with_index(1)
    |> Enum.each(fn {{occurrence, materialized_row, timing_row}, sequence} ->
      persist_occurrence_row!(trip, occurrence, materialized_row, timing_row, sequence, old_rows)
    end)
  end

  defp persist_occurrence_row!(trip, occurrence, materialized, timing_row, sequence, old_rows) do
    case Map.get(old_rows, occurrence.id) do
      nil ->
        %StopTime{}
        |> StopTime.changeset(
          stop_time_attrs(trip, occurrence, materialized, timing_row, sequence)
        )
        |> insert_or_rollback!()

      old_row ->
        attrs =
          Map.merge(
            preserved_clocks(old_row, materialized),
            Map.take(timing_row, [:stop_headsign, :pickup_type, :drop_off_type, :timepoint])
          )
          |> Map.merge(%{stop_id: occurrence.stop_id, stop_sequence: sequence})

        # The retained row was moved to a temporary sequence before this final
        # assignment, so the sequence has to be written even when every other
        # value is unchanged; otherwise the temporary value would survive.
        old_row
        |> Ecto.Changeset.change(attrs)
        |> Ecto.Changeset.force_change(:stop_sequence, sequence)
        |> update_or_rollback!()
    end
  end

  @doc """
  Re-materializes one linked trip's stop times from a timing's offsets.

  Rewrites each existing `StopTime` row of `trip` positionally against
  `occurrences` (the pattern's stops ordered by position) using `timing_rows`,
  starting from `start_seconds`. Only `arrival_time`, `departure_time`,
  `stop_headsign`, `pickup_type`, `drop_off_type` and `timepoint` change: row
  IDs, `stop_sequence` labels, `shape_dist_traveled`, the continuous fields and
  `inserted_at` are preserved.

  Call only inside `Repo.transaction/1`, after the route and pattern locks. It
  takes the trip's stop times with `FOR UPDATE` and rolls back
  `:trip_stop_times_mismatch` when their number differs from `occurrences`.
  """
  def rematerialize_trip!(trip, occurrences, timing_rows, start_seconds) do
    stop_times = trip_stop_times(trip)

    if length(stop_times) != length(occurrences),
      do: Repo.rollback(:trip_stop_times_mismatch)

    case Materializer.materialize(start_seconds, occurrences, timing_rows) do
      {:ok, materialized} ->
        Enum.zip([stop_times, materialized, timing_rows])
        |> Enum.each(fn {old, value, timing_row} ->
          attrs =
            Map.merge(
              preserved_clocks(old, value),
              Map.take(timing_row, [:stop_headsign, :pickup_type, :drop_off_type, :timepoint])
            )

          old |> Ecto.Changeset.change(attrs) |> update_or_rollback!()
        end)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp preserved_clocks(old, values) do
    Map.new([:arrival_time, :departure_time], fn field ->
      existing = Map.get(old, field)
      proposed = Map.fetch!(values, field)

      value =
        if GtfsTime.parse(existing) == GtfsTime.parse(proposed), do: existing, else: proposed

      {field, value}
    end)
  end

  defp stop_time_attrs(trip, occurrence, materialized, timing_row, sequence) do
    Map.merge(
      Map.take(materialized, [:arrival_time, :departure_time]),
      Map.take(timing_row, [:stop_headsign, :pickup_type, :drop_off_type, :timepoint])
    )
    |> Map.merge(%{
      trip_id: trip.trip_id,
      stop_id: occurrence.stop_id,
      stop_sequence: sequence,
      organization_id: trip.organization_id,
      gtfs_version_id: trip.gtfs_version_id,
      continuous_pickup: nil,
      continuous_drop_off: nil,
      shape_dist_traveled: nil
    })
  end

  defp update_timing_row!(timing, occurrence, attrs) do
    case Repo.one(
           from(r in TimedPatternStop,
             where: r.timed_pattern_id == ^timing.id and r.route_pattern_stop_id == ^occurrence.id
           )
         ) do
      nil ->
        insert_timing_rows!(timing, [occurrence], [attrs])

      row ->
        row
        |> Ecto.Changeset.change(
          Map.take(attrs, [
            :arrival_offset,
            :departure_offset,
            :timepoint,
            :pickup_type,
            :drop_off_type,
            :stop_headsign
          ])
        )
        |> update_or_rollback!()
    end
  end

  defp linked_pattern_trips(pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id and
          t.pattern_derivation_state == "linked",
      order_by: [asc: t.id]
    )
    |> Repo.all()
  end

  defp linked_timing_trips(pattern, timing_id) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id and t.timed_pattern_id == ^timing_id and
          t.pattern_derivation_state == "linked",
      order_by: [asc: t.id]
    )
    |> Repo.all()
  end

  defp pattern_trips(pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id,
      order_by: [asc: t.id]
    )
    |> Repo.all()
  end

  defp trip_stop_times(trip) do
    from(st in StopTime,
      where:
        st.organization_id == ^trip.organization_id and
          st.gtfs_version_id == ^trip.gtfs_version_id and st.trip_id == ^trip.trip_id,
      order_by: [asc: st.stop_sequence, asc: st.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  defp update_trip_direction!(pattern, direction_id) do
    trips = pattern_trips(pattern)

    Repo.update_all(from(t in Trip, where: t.id in ^Enum.map(trips, & &1.id)),
      set: [direction_id: direction_id, updated_at: DateTime.utc_now()]
    )

    length(trips)
  end

  defp update_trip_timestamps!([]), do: :ok

  defp update_trip_timestamps!(trips) do
    now = DateTime.utc_now()

    Repo.update_all(from(t in Trip, where: t.id in ^Enum.map(trips, & &1.id)),
      set: [updated_at: now]
    )

    :ok
  end

  defp unused_positive_values(occupied, count, final_count) do
    used = MapSet.new(occupied ++ Enum.to_list(1..max(final_count, 0)))
    take_unused(count, used, 1, [])
  end

  defp take_unused(0, _used, _candidate, acc), do: Enum.reverse(acc)

  defp take_unused(count, used, candidate, acc) do
    if MapSet.member?(used, candidate),
      do: take_unused(count, used, candidate + 1, acc),
      else: take_unused(count - 1, MapSet.put(used, candidate), candidate + 1, [candidate | acc])
  end

  @doc """
  Returns the scoped route when its version is published.

  A route outside the organization/version scope, or a route whose version is
  not published, is `{:error, :not_found}` so foreign and unpublished reads can
  never leak scoped data.
  """
  def published_route(organization_id, version_id, route_id) do
    query =
      from route in Route,
        join: version in GtfsVersion,
        on:
          version.id == route.gtfs_version_id and
            version.organization_id == route.organization_id,
        where:
          route.organization_id == ^organization_id and route.gtfs_version_id == ^version_id and
            route.route_id == ^route_id and version.publication_status == "published"

    case Repo.one(query) do
      %Route{} = route -> {:ok, route}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Locks one published route of the audit context's organization and version with `FOR UPDATE`.

  Call only inside `Repo.transaction/1`. This is a lock, not a transaction. It takes the
  organization-scoped version row `FOR SHARE` first, so a calendar mutation or a calendar
  combination that owns that version cannot commit fresh pattern input between a review and its
  apply, then the route `FOR UPDATE`, keeping the rule-table lock order. It rolls back
  `:not_found` when the version is outside the organization, the route does not exist, or the
  version is not published.
  """
  def lock_published_route!(%AuditContext{} = audit, route_id) do
    # The shared lock is a scope, not an authorization: callers that took it earlier in the same
    # transaction (the schedule writers) re-lock the row here without upgrading or reordering it.
    version = Versions.lock_for_input_write!(audit.organization_id, audit.gtfs_version_id)

    route =
      from(route in Route,
        where:
          route.organization_id == ^audit.organization_id and
            route.gtfs_version_id == ^audit.gtfs_version_id and route.route_id == ^route_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case route do
      %Route{} = row ->
        # The published requirement is applied after the shared lock, exactly as `Calendars` does,
        # because the shared lock itself takes no publication stance.
        if version.publication_status == "published" do
          row
        else
          Repo.rollback(:not_found)
        end

      nil ->
        Repo.rollback(:not_found)
    end
  end

  @doc """
  Locks every pattern of a locked route `FOR UPDATE` in stable UUID order.

  Call only inside `Repo.transaction/1`, after `lock_published_route!/2`. The
  R5 route-cascade lock order is version, route, sorted patterns, sorted trips;
  taking the whole set in one ordered statement keeps opposing lifecycle
  writers deadlock-free.
  """
  def lock_route_patterns!(%Route{} = route) do
    from(pattern in RoutePattern,
      where:
        pattern.organization_id == ^route.organization_id and
          pattern.gtfs_version_id == ^route.gtfs_version_id and
          pattern.route_id == ^route.route_id,
      order_by: [asc: pattern.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  @doc """
  Removes one route's owned patterns and descendants for the reviewed route
  cascade (R5), auditing each pattern with the existing single-delete
  semantics under one shared operation id.

  Call only inside the reviewed route-deletion transaction, after the route
  and its sorted patterns are locked and the deletion review has been
  recomputed and accepted. The patterns are removed in FK-safe set-based
  order (timing rows, timings, occurrences, patterns) and never through the
  public per-pattern delete. Returns the removed row counts keyed like the
  review categories so the caller can check them against the review.
  """
  def cascade_delete_patterns!(patterns, operation_id, %AuditContext{} = audit_context)
      when is_list(patterns) and is_binary(operation_id) do
    Enum.each(patterns, fn pattern ->
      snapshot = pattern_snapshot(load_pattern_for_audit!(pattern.id))

      audit!(audit_context, :route_pattern, pattern, "deleted", %{
        before: snapshot,
        operation_id: operation_id
      })
    end)

    pattern_ids = Enum.map(patterns, & &1.id)
    children = delete_pattern_children!(pattern_ids)
    {removed, nil} = Repo.delete_all(from(p in RoutePattern, where: p.id in ^pattern_ids))

    %{
      patterns: removed,
      pattern_stops: children.pattern_stops,
      timed_patterns: children.timed_patterns,
      timed_pattern_stops: children.timed_pattern_stops
    }
  end

  @doc """
  Locks one scoped pattern of a locked route with `FOR UPDATE`.

  Call only inside `Repo.transaction/1`, after `lock_published_route!/2`. This is a lock, not a
  transaction: it takes the row lock and rolls back `:not_found` when the pattern is out of scope.
  """
  def lock_pattern!(route, pattern_id) do
    case from(pattern in RoutePattern,
           where:
             pattern.organization_id == ^route.organization_id and
               pattern.gtfs_version_id == ^route.gtfs_version_id and
               pattern.route_id == ^route.route_id and pattern.id == ^pattern_id,
           lock: "FOR UPDATE"
         )
         |> Repo.one() do
      %RoutePattern{} = pattern -> pattern
      nil -> Repo.rollback(:not_found)
    end
  end

  defp lock_pattern_trips!(route, pattern) do
    from(trip in Trip,
      where:
        trip.organization_id == ^route.organization_id and
          trip.gtfs_version_id == ^route.gtfs_version_id and trip.route_id == ^route.route_id and
          trip.route_pattern_id == ^pattern.route_pattern_id,
      order_by: [asc: trip.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  defp trips_lock_required?(:delete), do: true
  defp trips_lock_required?({:delete_timing, _timing_id}), do: true
  defp trips_lock_required?({:stops, _, _}), do: true
  defp trips_lock_required?({:timing, _, _}), do: true

  defp trips_lock_required?({:details, attrs}) when is_map(attrs),
    do: Map.has_key?(attrs, :direction_id) or Map.has_key?(attrs, "direction_id")

  defp trips_lock_required?(_operation), do: false

  defp scoped_pattern(org_id, version_id, route_id, pattern_id) do
    Repo.one(
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^org_id and pattern.gtfs_version_id == ^version_id and
            pattern.route_id == ^route_id and pattern.id == ^pattern_id
      )
    )
  end

  defp selected_timing(_pattern, nil), do: {:ok, nil}

  defp selected_timing(pattern, timing_id) do
    case scoped_timing(pattern, timing_id) do
      %TimedPattern{} = timing -> {:ok, timing}
      nil -> {:error, :not_found}
    end
  end

  defp scoped_timing(pattern, timing_id) do
    Repo.one(
      from(timing in TimedPattern,
        where: timing.route_pattern_id == ^pattern.id and timing.id == ^timing_id,
        preload: [:route_pattern]
      )
    )
  end

  defp route_id_for_pattern(pattern_id, audit) do
    case Repo.one(
           from(pattern in RoutePattern,
             where:
               pattern.organization_id == ^audit.organization_id and
                 pattern.gtfs_version_id == ^audit.gtfs_version_id and pattern.id == ^pattern_id,
             select: pattern.route_id
           )
         ) do
      nil -> {:error, :not_found}
      route_id -> {:ok, route_id}
    end
  end

  defp load_eligible_stops!(route, stop_ids) do
    eligible =
      from(stop in Stop,
        where:
          stop.organization_id == ^route.organization_id and
            stop.gtfs_version_id == ^route.gtfs_version_id and stop.stop_id in ^stop_ids and
            (is_nil(stop.location_type) or stop.location_type == 0),
        select: stop.stop_id
      )
      |> Repo.all()
      |> MapSet.new()

    if MapSet.size(eligible) != length(Enum.uniq(stop_ids)) do
      Repo.rollback(:not_found)
    end

    Enum.map(stop_ids, & &1)
  end

  defp insert_occurrences!(pattern, stop_ids) do
    stop_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {stop_id, position} -> insert_occurrence!(pattern, stop_id, position) end)
  end

  defp insert_occurrence!(pattern, stop_id, position) do
    %RoutePatternStop{}
    |> RoutePatternStop.changeset(%{
      route_pattern_id: pattern.id,
      organization_id: pattern.organization_id,
      gtfs_version_id: pattern.gtfs_version_id,
      stop_id: stop_id,
      position: position,
      route_pattern: pattern
    })
    |> insert_or_rollback!()
  end

  defp insert_timing!(pattern, name, headsign) do
    %TimedPattern{}
    |> TimedPattern.changeset(%{
      route_pattern_id: pattern.id,
      organization_id: pattern.organization_id,
      gtfs_version_id: pattern.gtfs_version_id,
      route_pattern: pattern,
      name: name,
      headsign: headsign,
      derivation_key: nil
    })
    |> insert_or_rollback!()
  end

  defp insert_timing_rows!(timing, occurrences, rows) do
    occurrences
    |> Enum.zip(rows)
    |> Enum.each(fn {occurrence, attrs} ->
      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        Map.merge(attrs, %{
          timed_pattern_id: timing.id,
          route_pattern_stop_id: occurrence.id,
          timed_pattern: timing,
          route_pattern_stop: occurrence
        })
      )
      |> insert_or_rollback!()
    end)
  end

  defp copy_timing_rows!(timing, occurrences, source_rows) do
    Enum.each(occurrences, fn occurrence ->
      source = Enum.at(source_rows, occurrence.position - 1)

      attrs =
        case source do
          nil -> %{arrival_offset: 0, departure_offset: 0}
          row -> timing_row_attrs(row)
        end

      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        Map.merge(attrs, %{
          timed_pattern_id: timing.id,
          route_pattern_stop_id: occurrence.id,
          timed_pattern: timing,
          route_pattern_stop: occurrence
        })
      )
      |> insert_or_rollback!()
    end)
  end

  defp zero_timing_rows(count),
    do: List.duplicate(%{arrival_offset: 0, departure_offset: 0}, count)

  defp pattern_occurrences(%RoutePattern{id: pattern_id}), do: pattern_occurrences(pattern_id)

  defp pattern_occurrences(pattern_id) do
    from(occurrence in RoutePatternStop,
      where: occurrence.route_pattern_id == ^pattern_id,
      order_by: [asc: occurrence.position]
    )
    |> Repo.all()
  end

  defp pattern_timings(%RoutePattern{id: pattern_id}), do: pattern_timings(pattern_id)

  defp pattern_timings(pattern_id) do
    from(timing in TimedPattern,
      where: timing.route_pattern_id == ^pattern_id,
      order_by: [asc: timing.name, asc: timing.id]
    )
    |> Repo.all()
  end

  defp timing_rows(timing_id) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where: row.timed_pattern_id == ^timing_id,
      order_by: [asc: occurrence.position]
    )
    |> Repo.all()
  end

  defp timing_count(pattern_id),
    do:
      Repo.aggregate(
        from(timing in TimedPattern, where: timing.route_pattern_id == ^pattern_id),
        :count
      )

  defp timing_used?(_route, timing) do
    query =
      from(trip in Trip,
        where:
          trip.timed_pattern_id == ^timing.id and trip.organization_id == ^timing.organization_id and
            trip.gtfs_version_id == ^timing.gtfs_version_id
      )

    Repo.exists?(query)
  end

  defp pattern_used?(_route, pattern) do
    query =
      from(trip in Trip,
        where:
          trip.route_pattern_id == ^pattern.route_pattern_id and
            trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id
      )

    Repo.exists?(query)
  end

  defp count_timing_trips(pattern, timing_id) do
    Repo.aggregate(
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.timed_pattern_id == ^timing_id
      ),
      :count
    )
  end

  defp count_pattern_trips(pattern) do
    Repo.aggregate(
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_pattern_id == ^pattern.route_pattern_id
      ),
      :count
    )
  end

  defp load_pattern_for_audit!(pattern_id) do
    Repo.get!(RoutePattern, pattern_id)
    |> Repo.preload([:organization, :gtfs_version])
  end

  defp pattern_snapshot(pattern) do
    occurrences = pattern_occurrences(pattern)

    %{
      route_pattern_id: pattern.route_pattern_id,
      route_id: pattern.route_id,
      direction_id: pattern.direction_id,
      route_pattern_name: pattern.route_pattern_name,
      route_pattern_time_desc: pattern.route_pattern_time_desc,
      route_pattern_typicality: pattern.route_pattern_typicality,
      headsign: pattern.headsign,
      canonical_route_pattern: pattern.canonical_route_pattern,
      route_pattern_sort_order: pattern.route_pattern_sort_order,
      representative_trip_id: pattern.representative_trip_id,
      derivation_key: pattern.derivation_key,
      occurrences:
        Enum.map(occurrences, fn occurrence ->
          %{id: occurrence.id, stop_id: occurrence.stop_id, position: occurrence.position}
        end),
      timings:
        Enum.map(pattern_timings(pattern), fn timing ->
          %{
            id: timing.id,
            name: timing.name,
            headsign: timing.headsign,
            rows: Enum.map(timing_rows(timing.id), &timing_row_attrs/1)
          }
        end)
    }
  end

  defp timing_row_attrs(row) do
    Map.take(row, [
      :arrival_offset,
      :departure_offset,
      :timepoint,
      :pickup_type,
      :drop_off_type,
      :stop_headsign
    ])
  end

  defp timing_audit_attrs(pattern, timing, attrs) do
    Map.merge(attrs, %{
      pattern_route_pattern_id: pattern.route_pattern_id,
      timing_id: timing.id,
      timing_name: timing.name
    })
  end

  defp audit!(audit_context, type, entity, action, attrs) do
    context = %{audit_context | station_stop_id: nil}

    case Gtfs.record_change_in_transaction(context, type, entity, action, attrs) do
      {:ok, log} -> log
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp source_fingerprint(pattern) do
    if pattern && not Repo.in_transaction?() do
      Repo.transaction(fn -> source_fingerprint_in_transaction(pattern) end) |> elem(1)
    else
      source_fingerprint_in_transaction(pattern)
    end
  end

  defp source_fingerprint_in_transaction(pattern) do
    base = source_fingerprint_base(pattern)
    hash = :crypto.hash_update(:crypto.hash_init(:sha256), canonical_binary(base))

    hash
    |> stream_stop_time_fingerprint(pattern)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp source_fingerprint_base(nil), do: nil

  defp source_fingerprint_base(pattern) do
    trips =
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_id == ^pattern.route_id and
            trip.route_pattern_id == ^pattern.route_pattern_id,
        order_by: [asc: trip.id]
      )
      |> Repo.all()

    %{
      scope: {pattern.organization_id, pattern.gtfs_version_id, pattern.route_id},
      pattern: pattern_snapshot(pattern),
      trips: trips
    }
  end

  defp stream_stop_time_fingerprint(hash, nil), do: hash

  defp stream_stop_time_fingerprint(hash, pattern) do
    from(trip in Trip,
      join: stop_time in StopTime,
      on:
        stop_time.organization_id == trip.organization_id and
          stop_time.gtfs_version_id == trip.gtfs_version_id and
          stop_time.trip_id == trip.trip_id,
      where:
        trip.organization_id == ^pattern.organization_id and
          trip.gtfs_version_id == ^pattern.gtfs_version_id and
          trip.route_id == ^pattern.route_id and
          trip.route_pattern_id == ^pattern.route_pattern_id,
      order_by: [asc: trip.id, asc: stop_time.stop_sequence, asc: stop_time.id],
      select: {trip.id, stop_time}
    )
    |> Repo.stream()
    |> Enum.reduce(hash, fn record, acc ->
      :crypto.hash_update(acc, canonical_binary(record))
    end)
  end

  defp review_fingerprint(source, operation),
    do: source <> ":" <> digest({source, canonical(operation)})

  defp digest(value),
    do: :crypto.hash(:sha256, canonical_binary(value)) |> Base.encode16(case: :lower)

  defp canonical_binary(value),
    do: value |> canonical() |> :erlang.term_to_binary([:deterministic])

  defp canonical(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}
  defp canonical(%_{} = value), do: value |> Map.from_struct() |> canonical()

  defp canonical(value) when is_map(value) and not is_struct(value),
    do:
      value
      |> Enum.map(fn {key, val} -> {to_string(key), canonical(val)} end)
      |> Enum.sort_by(&elem(&1, 0))

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&canonical/1) |> List.to_tuple()

  defp canonical(value), do: value

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false

  defp normalize_pattern_attrs(attrs), do: normalize_allowed_attrs(attrs, @pattern_fields)

  defp normalize_allowed_attrs(attrs, allowed) when is_map(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)
      if key in allowed, do: Map.put(acc, String.to_existing_atom(key), value), else: acc
    end)
    |> then(&{:ok, &1})
  rescue
    ArgumentError -> {:error, :invalid_input}
  end

  defp normalize_allowed_attrs(_, _), do: {:error, :invalid_input}

  defp normalize_stop_ids(attrs) do
    case Map.get(attrs, :stops, Map.get(attrs, "stops")) do
      stops when is_list(stops) ->
        if Enum.all?(stops, &is_binary/1), do: {:ok, stops}, else: {:error, :invalid_input}

      _ ->
        {:error, :invalid_input}
    end
  end

  defp validate_occurrence_list(stops) do
    cond do
      length(stops) < 2 ->
        {:error, :at_least_two_stops}

      Enum.any?(Enum.chunk_every(stops, 2, 1, :discard), fn [a, b] -> a == b end) ->
        {:error, :adjacent_duplicate_stops}

      true ->
        :ok
    end
  end

  defp reject_forged_linkage(attrs) when is_map(attrs) do
    keys = Enum.map(Map.keys(attrs), &to_string/1)

    if Enum.any?(keys, &(&1 in @forbidden_linkage_fields)),
      do: {:error, :invalid_input},
      else: :ok
  end

  defp reject_forged_linkage(_), do: {:error, :invalid_input}

  defp validate_noop_or_pattern(pattern, attrs) do
    changeset = RoutePattern.changeset(pattern, attrs)
    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  defp validate_timing_attrs(attrs) do
    if Map.has_key?(attrs, :name) and (not is_binary(attrs.name) or String.trim(attrs.name) == "") do
      {:error, :invalid_input}
    else
      :ok
    end
  end

  defp same_values?(struct, attrs) do
    Enum.all?(attrs, fn {key, value} -> Map.get(struct, key) == value end)
  end

  @doc false
  def next_timing_name(pattern_id) do
    names = MapSet.new(Enum.map(pattern_timings(pattern_id), &String.downcase(&1.name)))

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = "Timing #{alpha_name(index)}"
      if MapSet.member?(names, String.downcase(name)), do: nil, else: name
    end)
  end

  @doc """
  Returns the first free pasted timing name for a pattern.

  `prefix` is the `"Pasted <Mon D>"` head (for example `"Pasted Sep 28"`);
  candidates are `"<prefix> · <suffix>"` with the suffix sequence reusing
  `alpha_name/1` (`A … Z, AA …`). Candidates compare case-insensitively
  against the pattern's existing timings plus `pending`, the names already
  assigned to this pattern in the current paste, so a second paste the same
  day with an existing `"Pasted Sep 28 · A"` names `"Pasted Sep 28 · B"`
  (R10, AC-12).

  Read-only; call any time.
  """
  @spec next_free_timing_name(Ecto.UUID.t(), String.t(), [String.t()]) :: String.t()
  def next_free_timing_name(pattern_id, prefix, pending) do
    taken =
      MapSet.new(
        Enum.map(
          Enum.map(pattern_timings(pattern_id), & &1.name) ++ List.wrap(pending),
          &String.downcase(to_string(&1))
        )
      )

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = "#{prefix} · #{alpha_name(index)}"
      unless MapSet.member?(taken, String.downcase(name)), do: name
    end)
  end

  @doc """
  Inserts a pasted timing with authored offsets inside the caller's transaction.

  Inserts one `TimedPattern` named `name` with `headsign` via `insert_timing!/3`,
  one row per pattern occurrence via `insert_timing_rows!/3` (`rows` zipped to
  `pattern_occurrences/1`; each row carries `arrival_offset`, `departure_offset`,
  `timepoint` and the service fields the paste resolved), and audits the
  `:timed_pattern` `"created"` entry with the timing `after` snapshot, sharing
  the caller's `operation_id` when one is set on the audit context (AC-22).

  Call only inside `Repo.transaction/1`, after `lock_published_route!/2` and
  `lock_pattern!/2`. A rows/occurrences count mismatch rolls the transaction
  back, as does any changeset failure, which is why this is a bang function:
  errors abort the enclosing transaction instead of returning tuples.
  """
  @spec create_pasted_timing!(
          RoutePattern.t(),
          String.t(),
          [map()],
          String.t() | nil,
          AuditContext.t(),
          String.t() | nil
        ) :: TimedPattern.t()
  def create_pasted_timing!(
        %RoutePattern{} = pattern,
        name,
        rows,
        headsign,
        %AuditContext{} = audit_context,
        operation_id \\ nil
      ) do
    occurrences = pattern_occurrences(pattern)

    if length(rows) != length(occurrences), do: Repo.rollback(:timing_rows_mismatch)

    timing = insert_timing!(pattern, name, headsign)
    insert_timing_rows!(timing, occurrences, rows)

    audit!(
      audit_context,
      :timed_pattern,
      timing,
      "created",
      timing_audit_attrs(pattern, timing, %{
        after: audit_timing_snapshot(timing),
        operation_id: operation_id
      })
    )

    timing
  end

  # Derivation persists a signature key on each derived pattern/timing so a retry
  # can reuse them. A staff edit that changes the pattern structure, the pattern
  # direction or a timing vector clears the affected keys so a retry can never
  # match obsolete content.
  defp clear_structure_signatures!(pattern) do
    from(timing in TimedPattern, where: timing.route_pattern_id == ^pattern.id)
    |> Repo.update_all(set: [derivation_key: nil])

    clear_pattern_signature!(pattern)
  end

  defp clear_pattern_signature!(pattern) do
    from(row in RoutePattern, where: row.id == ^pattern.id and not is_nil(row.derivation_key))
    |> Repo.update_all(set: [derivation_key: nil])
  end

  defp clear_timing_signature!(timing) do
    from(row in TimedPattern, where: row.id == ^timing.id and not is_nil(row.derivation_key))
    |> Repo.update_all(set: [derivation_key: nil])
  end

  defp maybe_clear_pattern_signature!(pattern, attrs) do
    direction = Map.get(attrs, :direction_id, Map.get(attrs, "direction_id"))

    if not is_nil(direction) and direction != pattern.direction_id do
      clear_pattern_signature!(pattern)
    end
  end

  defp alpha_name(index) when index < 26, do: <<?A + index>>
  defp alpha_name(index), do: alpha_name(div(index, 26) - 1) <> alpha_name(rem(index, 26))

  defp copy_name(nil), do: "Copy"
  defp copy_name(name), do: String.slice("#{name} copy", 0, 255)

  defp natural_pattern_id, do: "app-" <> Ecto.UUID.generate()

  defp insert_or_rollback!(%Ecto.Changeset{} = changeset) do
    case Repo.insert(changeset) do
      {:ok, struct} -> struct
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp update_or_rollback!(%Ecto.Changeset{} = changeset) do
    case Repo.update(changeset) do
      {:ok, struct} -> struct
      {:error, error} -> Repo.rollback(error)
    end
  end
end
