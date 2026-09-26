defmodule GtfsPlanner.Gtfs.RoutePatterns do
  @moduledoc "Scoped reads and audited lifecycle writes for editable route patterns."

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @pattern_fields ~w(route_pattern_name route_pattern_time_desc route_pattern_typicality direction_id headsign canonical_route_pattern)
  @timing_fields ~w(name headsign)
  @forbidden_linkage_fields ~w(timed_pattern_id pattern_derivation_state pattern_derivation_reason trip_id trip_ids)

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

  def create_pattern(route_id, attrs, %AuditContext{} = audit_context) when is_map(attrs) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_pattern_attrs(attrs),
         {:ok, stops} <- normalize_stop_ids(attrs),
         :ok <- validate_occurrence_list(stops) do
      transact(fn ->
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
    with {:ok, %{pattern: pattern} = loaded} <-
           get_pattern(
             audit_context.organization_id,
             audit_context.gtfs_version_id,
             pattern_route_id(pattern_id, audit_context),
             pattern_id
           ),
         true <- is_nil(source_fingerprint) or source_fingerprint == loaded.source_fingerprint,
         :ok <- validate_lifecycle_operation(pattern, operation, loaded) do
      {:ok,
       %{
         fingerprint: review_fingerprint(loaded.source_fingerprint, operation),
         impact: operation_impact(operation, loaded),
         proposed: operation_proposal(operation, pattern)
       }}
    else
      false -> {:error, :stale_review}
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def review(_, _, _, _), do: {:error, :invalid_input}

  def apply_review(pattern_id, operation, review_fingerprint, %AuditContext{} = audit_context)
      when is_binary(pattern_id) and is_binary(review_fingerprint) do
    with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context),
         do:
           apply_review_with_retries(
             pattern_id,
             operation,
             route_id,
             review_fingerprint,
             audit_context,
             3
           )
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
         :ok <- reject_direction_change(attrs, pattern),
         :ok <- validate_noop_or_pattern(pattern, attrs) do
      if same_values?(pattern, attrs) do
        %{pattern: pattern, trips_updated: 0}
      else
        updated = pattern |> RoutePattern.changeset(attrs) |> update_or_rollback!()
        audit!(audit_context, :route_pattern, pattern, "updated", attrs)
        %{pattern: load_pattern_for_audit!(updated.id), trips_updated: 0}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_lifecycle_operation!(_route, pattern, {:timing, timing_id, attrs}, audit_context) do
    with {:ok, attrs} <- normalize_allowed_attrs(attrs, @timing_fields),
         %TimedPattern{} = timing <- scoped_timing(pattern, timing_id),
         :ok <- validate_timing_attrs(attrs) do
      cond do
        same_values?(timing, attrs) ->
          %{pattern: pattern, trips_updated: 0}

        true ->
          _changed = timing |> TimedPattern.changeset(attrs) |> update_or_rollback!()

          audit!(
            audit_context,
            :timed_pattern,
            timing,
            "updated",
            timing_audit_attrs(pattern, timing, attrs)
          )

          %{pattern: pattern, trips_updated: 0}
      end
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_lifecycle_operation!(_route, pattern, {:add_timing, attrs}, audit_context) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values) do
      name = Map.get(values, :name) || next_timing_name(pattern.id)
      timing = insert_timing!(pattern, name, Map.get(values, :headsign))
      occurrences = pattern_occurrences(pattern.id)
      insert_timing_rows!(timing, occurrences, zero_timing_rows(length(occurrences)))

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
      delete_pattern_children!(pattern.id)
      Repo.delete!(pattern)
      %{pattern: nil, trips_updated: 0}
    end
  end

  defp apply_lifecycle_operation!(_route, _pattern, _operation, _audit_context),
    do: Repo.rollback(:invalid_operation)

  defp delete_pattern_children!(pattern_id) do
    timing_ids =
      from(timing in TimedPattern,
        where: timing.route_pattern_id == ^pattern_id,
        select: timing.id
      )
      |> Repo.all()

    Repo.delete_all(from(row in TimedPatternStop, where: row.timed_pattern_id in ^timing_ids))
    Repo.delete_all(from(timing in TimedPattern, where: timing.id in ^timing_ids))

    Repo.delete_all(
      from(occurrence in RoutePatternStop, where: occurrence.route_pattern_id == ^pattern_id)
    )
  end

  defp apply_review_with_retries(
         pattern_id,
         operation,
         route_id,
         fingerprint,
         audit_context,
         attempts
       ) do
    transaction = fn ->
      route = lock_published_route!(audit_context, route_id)
      pattern = lock_pattern!(route, pattern_id)

      if trips_lock_required?(operation) do
        _trips = lock_pattern_trips!(route, pattern)
      end

      loaded = load_pattern_for_audit!(pattern.id)
      current_fingerprint = source_fingerprint(loaded)

      unless secure_equal?(fingerprint, review_fingerprint(current_fingerprint, operation)) do
        Repo.rollback(:stale_review)
      end

      apply_lifecycle_operation!(route, loaded, operation, audit_context)
    end

    case run_apply_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:serialization_failure, _error} when attempts > 1 ->
        apply_review_with_retries(
          pattern_id,
          operation,
          route_id,
          fingerprint,
          audit_context,
          attempts - 1
        )

      {:serialization_failure, _error} ->
        {:error, :busy}

      {:error, %Postgrex.Error{} = error} ->
        if serialization_failure?(error) and attempts > 1 do
          apply_review_with_retries(
            pattern_id,
            operation,
            route_id,
            fingerprint,
            audit_context,
            attempts - 1
          )
        else
          if serialization_failure?(error), do: {:error, :busy}, else: {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_apply_transaction(transaction) do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    ).run(transaction)
  rescue
    error in Postgrex.Error ->
      if serialization_failure?(error),
        do: {:serialization_failure, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp serialization_failure?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:serialization_failure, "40001"],
       do: true

  defp serialization_failure?(_), do: false

  defp validate_lifecycle_operation(pattern, {:details, attrs}, _loaded) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @pattern_fields),
         :ok <- reject_direction_change(values, pattern),
         :ok <- validate_noop_or_pattern(pattern, values) do
      :ok
    end
  end

  defp validate_lifecycle_operation(pattern, {:timing, timing_id, attrs}, _loaded) do
    with %TimedPattern{} <- scoped_timing(pattern, timing_id),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values) do
      :ok
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp validate_lifecycle_operation(_pattern, {:add_timing, attrs}, _loaded) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values),
         do: :ok
  end

  defp validate_lifecycle_operation(pattern, {:delete_timing, timing_id}, _loaded) do
    timing = scoped_timing(pattern, timing_id)

    cond do
      is_nil(timing) -> {:error, :not_found}
      timing_count(pattern.id) <= 1 -> {:error, :last_timing}
      timing_used?(nil, timing) -> {:error, :timing_in_use}
      true -> :ok
    end
  end

  defp validate_lifecycle_operation(pattern, :copy, _loaded) do
    if is_nil(pattern), do: {:error, :not_found}, else: :ok
  end

  defp validate_lifecycle_operation(pattern, :delete, _loaded) do
    if pattern_used?(nil, pattern), do: {:error, :pattern_in_use}, else: :ok
  end

  defp validate_lifecycle_operation(_pattern, _, _), do: {:error, :invalid_operation}

  defp operation_impact({:delete_timing, timing_id}, %{pattern: pattern}) do
    %{trips_affected: count_timing_trips(pattern, timing_id)}
  end

  defp operation_impact(:delete, %{pattern: pattern}),
    do: %{trips_affected: count_pattern_trips(pattern)}

  defp operation_impact(_, _), do: %{trips_affected: 0}

  defp operation_proposal({:details, attrs}, _pattern), do: attrs
  defp operation_proposal({:timing, _id, attrs}, _pattern), do: attrs
  defp operation_proposal({:add_timing, attrs}, _pattern), do: attrs
  defp operation_proposal(operation, _pattern), do: operation

  defp published_route(organization_id, version_id, route_id) do
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

  defp lock_published_route!(%AuditContext{} = audit, route_id) do
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
        if Repo.get!(GtfsVersion, row.gtfs_version_id).publication_status == "published" do
          row
        else
          Repo.rollback(:not_found)
        end

      nil ->
        Repo.rollback(:not_found)
    end
  end

  defp lock_pattern!(route, pattern_id) do
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

  defp pattern_route_id(pattern_id, audit) do
    case route_id_for_pattern(pattern_id, audit) do
      {:ok, route_id} -> route_id
      {:error, _} -> nil
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
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_id == ^pattern.route_id
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
    data =
      if pattern do
        %{
          scope: {pattern.organization_id, pattern.gtfs_version_id, pattern.route_id},
          pattern: pattern_snapshot(pattern),
          trips:
            from(trip in Trip,
              where:
                trip.organization_id == ^pattern.organization_id and
                  trip.gtfs_version_id == ^pattern.gtfs_version_id and
                  trip.route_id == ^pattern.route_id and
                  trip.route_pattern_id == ^pattern.route_pattern_id,
              order_by: [asc: trip.id],
              select:
                {trip.id, trip.timed_pattern_id, trip.pattern_derivation_state,
                 trip.pattern_derivation_reason}
            )
            |> Repo.all()
        }
      else
        nil
      end

    digest(data)
  end

  defp review_fingerprint(source, operation), do: digest({source, canonical(operation)})

  defp digest(value),
    do:
      value
      |> canonical()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp canonical(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}

  defp canonical(value) when is_map(value),
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

  defp reject_direction_change(attrs, pattern) do
    if Map.has_key?(attrs, :direction_id) and attrs.direction_id != pattern.direction_id,
      do: {:error, :trip_affecting_operation_not_available},
      else: :ok
  end

  defp same_values?(struct, attrs) do
    Enum.all?(attrs, fn {key, value} -> Map.get(struct, key) == value end)
  end

  defp next_timing_name(pattern_id) do
    names = MapSet.new(Enum.map(pattern_timings(pattern_id), &String.downcase(&1.name)))

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = "Timing #{alpha_name(index)}"
      if MapSet.member?(names, String.downcase(name)), do: nil, else: name
    end)
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

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
