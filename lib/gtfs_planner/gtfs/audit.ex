defmodule GtfsPlanner.Gtfs.Audit do
  @moduledoc "Transactional change-log insertion, snapshots, and scoped history reads."

  import Ecto.Query, warn: false

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip

  @structured_audit_entity_types [
    :route_pattern,
    "route_pattern",
    :timed_pattern,
    "timed_pattern",
    :route_pattern_build,
    "route_pattern_build",
    :calendar,
    "calendar",
    :trip,
    "trip",
    :transfer,
    "transfer",
    :pathway_evolution,
    "pathway_evolution",
    :stop_level,
    "stop_level"
  ]

  @doc false
  @spec route_audit_snapshot(Route.t()) :: map()
  def route_audit_snapshot(%Route{} = route), do: snapshot_route(route)

  @doc false
  @spec record_change_in_transaction(AuditContext.t(), atom(), struct() | nil, String.t(), map()) ::
          {:ok, ChangeLog.t()} | {:error, Ecto.Changeset.t()}
  def record_change_in_transaction(
        %AuditContext{} = ctx,
        entity_type,
        entity_or_nil,
        action,
        attrs \\ %{}
      ) do
    snapshot = build_snapshot(entity_type, entity_or_nil)
    changed_fields_attrs = changed_fields_attrs(action, entity_type, attrs)
    changed_fields = build_changed_fields(entity_type, action, snapshot, changed_fields_attrs)

    %ChangeLog{}
    |> ChangeLog.changeset(%{
      entity_type: Atom.to_string(entity_type),
      entity_id: entity_id_for(entity_or_nil),
      entity_external_id: entity_external_id_for(entity_type, entity_or_nil, attrs),
      station_stop_id: ctx.station_stop_id,
      actor_id: ctx.actor_id,
      actor_email: ctx.actor_email,
      snapshot: snapshot,
      changed_fields: changed_fields,
      action: action,
      rolled_back_to_log_id:
        if(action == "rolled_back", do: Map.get(attrs, :rolled_back_to_log_id)),
      organization_id: ctx.organization_id,
      gtfs_version_id: ctx.gtfs_version_id
    })
    |> Repo.insert()
  end

  @doc """
  Returns change log entries for a specific entity, most recent first.
  """
  def list_change_logs_for_entity(organization_id, gtfs_version_id, entity_type, entity_id) do
    from(cl in ChangeLog,
      where:
        cl.organization_id == ^organization_id and
          cl.gtfs_version_id == ^gtfs_version_id and
          cl.entity_type == ^entity_type and
          cl.entity_id == ^entity_id,
      order_by: [desc: cl.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single change log entry.

  Raises `Ecto.NoResultsError` if the entry does not exist.
  """
  def get_change_log!(id), do: Repo.get!(ChangeLog, id)

  @doc """
  Gets a single change log entry, returning `nil` if it does not exist.
  """
  def get_change_log(id), do: Repo.get(ChangeLog, id)

  @doc """
  Returns the list of identity field names (as strings) for an entity type.

  Identity fields are preserved across rollback and excluded from rollback diffs.
  """
  def identity_fields_for("stop"), do: ~w(stop_id)
  def identity_fields_for("pathway"), do: ~w(pathway_id from_stop_id to_stop_id)
  def identity_fields_for("level"), do: ~w(level_id)

  @doc """
  Returns the list of reversible field names (as strings) for an entity type.
  """
  @spec reversible_fields_for(String.t() | atom()) :: [String.t()]
  def reversible_fields_for(:stop), do: reversible_fields_for("stop")

  def reversible_fields_for("stop"),
    do: ~w(
        stop_name
        stop_desc
        stop_lat
        stop_lon
        location_type
        wheelchair_boarding
        platform_code
        diagram_coordinate
        parent_station
        level_id
      )

  def reversible_fields_for(:pathway), do: reversible_fields_for("pathway")

  def reversible_fields_for("pathway"),
    do: ~w(
        pathway_mode
        is_bidirectional
        traversal_time
        length
        stair_count
        max_slope
        min_width
        signposted_as
        reversed_signposted_as
        field_notes
        field_completed_at
      )

  def reversible_fields_for(:level), do: reversible_fields_for("level")
  def reversible_fields_for("level"), do: ~w(level_name level_index)

  def reversible_fields_for(:stop_level), do: reversible_fields_for("stop_level")

  def reversible_fields_for("stop_level"),
    do:
      ~w(diagram_filename scale_point_a scale_point_b scale_distance_meters scale_meters_per_unit floorplan_center_lat floorplan_center_lon floorplan_scale_mpp floorplan_rotation_deg)

  def reversible_fields_for(type)
      when type in [:route_pattern, :timed_pattern, :route_pattern_build],
      do: []

  def reversible_fields_for(type)
      when type in ["route_pattern", "timed_pattern", "route_pattern_build"],
      do: []

  # Route audit entries are history records: generic rollback never applies to
  # them, so no route field is reversible.
  def reversible_fields_for(type) when type in [:route, "route"], do: []

  def reversible_fields_for(:calendar), do: reversible_fields_for("calendar")
  def reversible_fields_for("calendar"), do: []

  def reversible_fields_for(:pathway_evolution), do: reversible_fields_for("pathway_evolution")
  def reversible_fields_for("pathway_evolution"), do: []

  @doc """
  Builds a normalized snapshot map for a stop, pathway, or level entity.

  Used by rollback preview to compare a current entity against a stored snapshot
  with equivalent value normalization (e.g. Decimal → string).
  """
  def entity_snapshot(entity_type, entity), do: build_snapshot(entity_type, entity)

  # -- Snapshot helpers --

  defp build_snapshot(_entity_type, nil), do: nil

  defp build_snapshot(:stop, %Stop{} = stop), do: snapshot_stop(stop)
  defp build_snapshot(:pathway, %Pathway{} = pw), do: snapshot_pathway(pw)
  defp build_snapshot(:level, %Level{} = level), do: snapshot_level(level)
  defp build_snapshot(:stop_level, %StopLevel{} = stop_level), do: snapshot_stop_level(stop_level)

  defp build_snapshot(:route_pattern, %RoutePattern{} = pattern),
    do: snapshot_route_pattern(pattern)

  defp build_snapshot("route_pattern", %RoutePattern{} = pattern),
    do: snapshot_route_pattern(pattern)

  # A route's audit identity is its UUID plus its GTFS `route_id`; the snapshot
  # captures the persisted editor-owned fields so history and replay see the
  # route state at record time.
  defp build_snapshot(type, %Route{} = route) when type in [:route, "route"],
    do: snapshot_route(route)

  defp build_snapshot(:timed_pattern, %GtfsPlanner.Gtfs.TimedPattern{} = timing),
    do: snapshot_timed_pattern(timing)

  defp build_snapshot("timed_pattern", %GtfsPlanner.Gtfs.TimedPattern{} = timing),
    do: snapshot_timed_pattern(timing)

  defp build_snapshot("stop", %Stop{} = stop), do: snapshot_stop(stop)
  defp build_snapshot("pathway", %Pathway{} = pw), do: snapshot_pathway(pw)
  defp build_snapshot("level", %Level{} = level), do: snapshot_level(level)

  defp build_snapshot("stop_level", %StopLevel{} = stop_level),
    do: snapshot_stop_level(stop_level)

  # A calendar's audit identity is its metadata anchor. The complete aggregate
  # before/after snapshots are passed explicitly by Calendars, so the stored
  # anchor snapshot never has to be expanded into native weekly/date rows here.
  defp build_snapshot(:calendar, %CalendarAttribute{} = anchor),
    do: Calendars.audit_snapshot(anchor)

  defp build_snapshot("calendar", %CalendarAttribute{} = anchor),
    do: Calendars.audit_snapshot(anchor)

  # A closure's audit identity is the closure UUID; the structured create record
  # carries before=nil and after=the normalized closure snapshot.
  defp build_snapshot(:pathway_evolution, %PathwayEvolution{} = evolution),
    do: snapshot_pathway_evolution(evolution)

  defp build_snapshot("pathway_evolution", %PathwayEvolution{} = evolution),
    do: snapshot_pathway_evolution(evolution)

  # A trip's audit identity is the trip UUID plus its GTFS `trip_id`; the complete
  # aggregate before/after snapshots are passed explicitly by Schedules, so the
  # entity itself never yields a snapshot.
  defp build_snapshot(type, %Trip{}) when type in [:trip, "trip"], do: nil

  # A transfer's audit identity is the row UUID plus its GTFS external ID; the
  # complete before/after snapshots are passed explicitly by Transfers, so the
  # entity itself never yields a snapshot.
  defp build_snapshot(type, %Transfer{}) when type in [:transfer, "transfer"], do: nil
  # Alignment segments snapshot their scope, stop-pair identity, override
  # linkage, optimistic-lock revision and interior points. Pattern shapes
  # snapshot the owning pattern's shape identity; the replaced-shape detail
  # travels in the explicit before/after maps (INV-5).
  defp build_snapshot(type, %AlignmentSegment{} = segment)
       when type in [:alignment_segment, "alignment_segment"] do
    %{
      id: segment.id,
      scope: %{
        organization_id: segment.organization_id,
        gtfs_version_id: segment.gtfs_version_id
      },
      from_stop_id: segment.from_stop_id,
      to_stop_id: segment.to_stop_id,
      from_occurrence_id: segment.from_occurrence_id,
      lock_version: segment.lock_version,
      points: normalize_value(segment.points)
    }
  end

  defp build_snapshot(type, %RoutePattern{} = pattern)
       when type in [:pattern_shape, "pattern_shape"] do
    %{
      route_pattern_id: pattern.route_pattern_id,
      shape_id: pattern.shape_id,
      alignment_digest: pattern.alignment_digest
    }
  end

  defp build_snapshot(_, _), do: nil

  defp snapshot_stop(stop) do
    %{
      stop_name: stop.stop_name,
      stop_desc: stop.stop_desc,
      stop_lat: jsonify(stop.stop_lat),
      stop_lon: jsonify(stop.stop_lon),
      location_type: stop.location_type,
      wheelchair_boarding: stop.wheelchair_boarding,
      platform_code: stop.platform_code,
      diagram_coordinate: stop.diagram_coordinate,
      parent_station: stop.parent_station,
      level_id: stop.level_id
    }
  end

  defp snapshot_pathway(pw) do
    %{
      from_stop_id: pw.from_stop_id,
      to_stop_id: pw.to_stop_id,
      pathway_mode: pw.pathway_mode,
      is_bidirectional: pw.is_bidirectional,
      traversal_time: pw.traversal_time,
      length: jsonify(pw.length),
      stair_count: pw.stair_count,
      max_slope: jsonify(pw.max_slope),
      min_width: jsonify(pw.min_width),
      signposted_as: pw.signposted_as,
      reversed_signposted_as: pw.reversed_signposted_as,
      field_notes: pw.field_notes,
      field_completed_at: jsonify(pw.field_completed_at)
    }
  end

  defp snapshot_level(level) do
    %{level_name: level.level_name, level_index: level.level_index}
  end

  defp snapshot_stop_level(stop_level) do
    %{
      stop_id: stop_level.stop_id,
      level_id: stop_level.level_id,
      diagram_filename: stop_level.diagram_filename,
      scale_point_a: stop_level.scale_point_a,
      scale_point_b: stop_level.scale_point_b,
      scale_distance_meters: jsonify(stop_level.scale_distance_meters),
      scale_meters_per_unit: jsonify(stop_level.scale_meters_per_unit),
      floorplan_center_lat: stop_level.floorplan_center_lat,
      floorplan_center_lon: stop_level.floorplan_center_lon,
      floorplan_scale_mpp: stop_level.floorplan_scale_mpp,
      floorplan_rotation_deg: stop_level.floorplan_rotation_deg
    }
  end

  defp snapshot_route(route) do
    %{
      route_short_name: route.route_short_name,
      route_long_name: route.route_long_name,
      route_type: route.route_type,
      agency_id: route.agency_id,
      route_desc: route.route_desc,
      route_url: route.route_url,
      route_color: route.route_color,
      route_text_color: route.route_text_color,
      route_sort_order: route.route_sort_order,
      continuous_pickup: route.continuous_pickup,
      continuous_drop_off: route.continuous_drop_off,
      network_id: route.network_id,
      active: route.active
    }
  end

  defp snapshot_pathway_evolution(evolution) do
    %{
      pathway_id: evolution.pathway_id,
      service_id: evolution.service_id,
      start_time: evolution.start_time,
      end_time: evolution.end_time,
      note: evolution.note
    }
  end

  defp snapshot_route_pattern(pattern),
    do: RoutePatterns.audit_snapshot(pattern)

  defp snapshot_timed_pattern(timing),
    do: RoutePatterns.audit_timing_snapshot(timing)

  # -- Entity identity helpers --

  defp entity_id_for(nil), do: nil
  defp entity_id_for(%{id: id}), do: id

  defp entity_external_id_for(_entity_type, nil, attrs) do
    cond do
      attrs[:stop_id] -> attrs[:stop_id]
      attrs["stop_id"] -> attrs["stop_id"]
      attrs[:pathway_id] -> attrs[:pathway_id]
      attrs["pathway_id"] -> attrs["pathway_id"]
      attrs[:level_id] -> attrs[:level_id]
      attrs["level_id"] -> attrs["level_id"]
      true -> nil
    end
  end

  defp entity_external_id_for(:stop, %Stop{} = stop, _attrs), do: stop.stop_id
  defp entity_external_id_for(:pathway, %Pathway{} = pw, _attrs), do: pw.pathway_id
  defp entity_external_id_for(:level, %Level{} = level, _attrs), do: level.level_id

  defp entity_external_id_for(:stop_level, %StopLevel{} = stop_level, _attrs),
    do: stop_level.level_id

  defp entity_external_id_for(:route_pattern, %RoutePattern{} = pattern, _attrs),
    do: pattern.route_pattern_id

  defp entity_external_id_for(type, %Route{} = route, _attrs) when type in [:route, "route"],
    do: route.route_id

  defp entity_external_id_for(:timed_pattern, %GtfsPlanner.Gtfs.TimedPattern{} = timing, attrs) do
    pattern_natural_id =
      Map.get(attrs, :pattern_route_pattern_id) || Map.get(attrs, "pattern_route_pattern_id") ||
        "unknown"

    "#{timing.id}:#{pattern_natural_id}"
  end

  defp entity_external_id_for(:calendar, %CalendarAttribute{} = anchor, _attrs),
    do: anchor.service_id

  defp entity_external_id_for("calendar", %CalendarAttribute{} = anchor, _attrs),
    do: anchor.service_id

  defp entity_external_id_for(type, %PathwayEvolution{} = evolution, _attrs)
       when type in [:pathway_evolution, "pathway_evolution"],
       do: evolution.pathway_id

  defp entity_external_id_for(type, %Trip{} = trip, _attrs) when type in [:trip, "trip"],
    do: trip.trip_id

  defp entity_external_id_for(type, %Transfer{} = transfer, _attrs)
       when type in [:transfer, "transfer"],
       do: Transfer.audit_external_id(transfer)

  # A shared segment is addressed by its stop pair; an override also names the
  # visit it belongs to (INV-6). A pattern shape is addressed by the pattern's
  # natural GTFS ID.
  defp entity_external_id_for(type, %AlignmentSegment{} = segment, _attrs)
       when type in [:alignment_segment, "alignment_segment"] do
    pair = "#{segment.from_stop_id}>#{segment.to_stop_id}"

    if is_nil(segment.from_occurrence_id) do
      pair
    else
      "#{pair}@#{segment.from_occurrence_id}"
    end
  end

  defp entity_external_id_for(type, %RoutePattern{} = pattern, _attrs)
       when type in [:pattern_shape, "pattern_shape"],
       do: pattern.route_pattern_id

  defp entity_external_id_for(:route_pattern_build, %Route{} = route, _attrs), do: route.route_id

  defp entity_external_id_for(:route_pattern_build, nil, attrs),
    do: Map.get(attrs, :route_id) || Map.get(attrs, "route_id")

  defp changed_fields_attrs("updated", entity_type, attrs)
       when entity_type in [:stop, "stop"] do
    entity_type
    |> audited_attrs_for(attrs)
    |> Map.merge(Map.take(attrs, [:stop_id, :references]))
  end

  defp changed_fields_attrs("updated", entity_type, attrs)
       when entity_type in [:level, "level"] do
    entity_type
    |> audited_attrs_for(attrs)
    |> Map.merge(Map.take(attrs, [:level_id, :references]))
  end

  defp changed_fields_attrs("updated", entity_type, attrs),
    do: audited_attrs_for(entity_type, attrs)

  defp changed_fields_attrs(_action, _entity_type, attrs), do: attrs

  defp audited_attrs_for(type, attrs) when type in [:route_pattern, "route_pattern"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(
        route_pattern_name route_pattern_time_desc direction_id
        route_pattern_typicality headsign canonical_route_pattern route_pattern_sort_order
        occurrences timings before after affected_trips operation_id
      )
    end)
  end

  defp audited_attrs_for(type, attrs) when type in [:timed_pattern, "timed_pattern"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(name headsign rows before after affected_trips operation_id)
    end)
  end

  defp audited_attrs_for(:route_pattern_build, attrs), do: attrs
  defp audited_attrs_for("route_pattern_build", attrs), do: attrs

  # Calendar diffs are already explicit aggregate before/after snapshots.
  defp audited_attrs_for(type, attrs) when type in [:calendar, "calendar"], do: attrs

  # Route diffs are explicit before/after snapshots plus command provenance; no
  # route column is diffed field-by-field.
  defp audited_attrs_for(type, attrs) when type in [:route, "route"], do: attrs

  # A trip update carries the explicit before/after snapshots, its operation scope and - for a
  # reviewed calendar combination - the one optional combination envelope; no trip column is diffed
  # field-by-field. The per-trip `affected_trip_ids` list is deliberately unused by a combination,
  # whose complete member list lives once in the envelope (AC-26).
  defp audited_attrs_for(type, attrs) when type in [:trip, "trip"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(before after operation_id affected_trip_ids combination undoes)
    end)
  end

  # A transfer write carries the explicit before/after snapshots and its operation
  # scope; no transfer column is diffed field-by-field.
  defp audited_attrs_for(type, attrs) when type in [:transfer, "transfer"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(before after operation_id affected_transfer_ids)
    end)
  end

  # Alignment entries carry explicit before/after aggregates like trips and
  # calendars; no segment or shape column is diffed field-by-field.
  defp audited_attrs_for(type, attrs)
       when type in [:alignment_segment, "alignment_segment", :pattern_shape, "pattern_shape"] do
    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in ~w(before after)
    end)
  end

  # A closure update carries the explicit before/after snapshots; no closure
  # column is diffed field-by-field.
  defp audited_attrs_for(type, attrs) when type in [:pathway_evolution, "pathway_evolution"] do
    Map.filter(attrs, fn {key, _value} -> to_string(key) in ~w(before after) end)
  end

  defp audited_attrs_for(entity_type, attrs), do: reversible_attrs_for(entity_type, attrs)

  # -- Diff and rollback helpers --

  # Calendars diff two explicit aggregate snapshots instead of comparing the
  # anchor's own fields, so this clause must precede the generic update branch.
  defp build_changed_fields(entity_type, action, _snapshot, attrs)
       when entity_type in [:calendar, "calendar"] and
              action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
    |> put_calendar_operation(attrs)
  end

  # Routes, like calendars and trips, diff two explicit before/after snapshots.
  # The log carries the shared operation id, creation-attempt provenance and
  # affected identity/count metadata so create replay and reviewed deletion can
  # be reconstructed from the retained entry. A created route log whose caller
  # omits the explicit after value stores the entity snapshot (R3: the create
  # log keeps before/after alongside the attempt metadata).
  defp build_changed_fields(entity_type, action, snapshot, attrs)
       when entity_type in [:route, "route"] and action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(route_after_snapshot(action, attrs, snapshot))
    }
    |> put_route_operation(attrs)
  end

  # Trips, like calendars, diff two explicit aggregate snapshots. The log carries
  # no trip-column diff, and a bulk operation records its shared operation UUID
  # and affected trip UUIDs alongside the snapshot.
  defp build_changed_fields(entity_type, action, _snapshot, attrs)
       when entity_type in [:trip, "trip"] and action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
    |> put_trip_operation(attrs)
  end

  # A pasted timing's "created" log belongs to the same paste batch as the
  # trip logs, so it carries the caller's shared operation_id (AC-22) next to
  # its timing snapshot; without this clause the structured-create clause
  # below would drop the operation id.
  defp build_changed_fields(entity_type, action, snapshot, attrs)
       when entity_type in [:timed_pattern, "timed_pattern"] and action == "created" do
    after_snapshot = Map.get(attrs, :after, Map.get(attrs, "after", snapshot))

    %{"before" => nil, "after" => normalize_value(after_snapshot)}
    |> put_shared_operation(attrs)
  end

  # Transfers, like trips, diff two explicit snapshots supplied by the caller. The log
  # carries no transfer-column diff, and a bulk delete records its shared operation
  # UUID and affected transfer UUIDs alongside the snapshot.
  defp build_changed_fields(entity_type, action, _snapshot, attrs)
       when entity_type in [:transfer, "transfer"] and
              action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
    |> put_transfer_operation(attrs)
  end

  # Alignment entries, like trips, store the explicit before/after aggregates
  # (including INV-5 replaced-shape detail) rather than a column diff.
  defp build_changed_fields(entity_type, action, _snapshot, attrs)
       when entity_type in [
              :alignment_segment,
              "alignment_segment",
              :pattern_shape,
              "pattern_shape"
            ] and action in ["created", "updated", "deleted"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
  end

  # Closures, like calendars and trips, diff two explicit normalized snapshots:
  # the update log carries before/after while the entity snapshot stays the
  # after state.
  defp build_changed_fields(entity_type, "updated", _snapshot, attrs)
       when entity_type in [:pathway_evolution, "pathway_evolution"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after")))
    }
  end

  # A pattern or timing update diffs the audited fields against the live
  # snapshot and carries the shared operation id at the top level, exactly like
  # the trip rows a headsign save writes alongside it. Logs without an
  # operation id keep the previous shape unchanged.
  defp build_changed_fields(entity_type, "updated", snapshot, attrs)
       when entity_type in [:route_pattern, "route_pattern", :timed_pattern, "timed_pattern"] and
              not is_nil(snapshot) do
    snapshot
    |> updated_field_diffs(attrs)
    |> put_shared_operation(attrs)
  end

  defp build_changed_fields(entity_type, "updated", snapshot, attrs)
       when entity_type in [:stop, "stop"] and not is_nil(snapshot) do
    {metadata, fields} = Map.split(attrs, [:stop_id, :references, :rolled_back_to_log_id])
    changed = updated_field_diffs(snapshot, fields)

    case metadata do
      %{stop_id: [old_id, new_id], references: counts} ->
        changed
        |> Map.put("stop_id", [old_id, new_id])
        |> Map.put("references", stringify_map_keys(counts))

      _ ->
        changed
    end
  end

  defp build_changed_fields(entity_type, "rolled_back", snapshot, attrs)
       when entity_type in [:stop, "stop"] and not is_nil(snapshot),
       do: build_changed_fields(entity_type, "updated", snapshot, attrs)

  defp build_changed_fields(_entity_type, "rolled_back", snapshot, attrs)
       when not is_nil(snapshot),
       do: updated_field_diffs(snapshot, Map.delete(attrs, :rolled_back_to_log_id))

  defp build_changed_fields(entity_type, "updated", snapshot, attrs)
       when entity_type in [:level, "level"] and not is_nil(snapshot) do
    {metadata, fields} = Map.split(attrs, [:level_id, :references])
    changed = updated_field_diffs(snapshot, fields)

    case metadata do
      %{level_id: [old_id, new_id], references: counts} ->
        changed
        |> Map.put("level_id", [old_id, new_id])
        |> Map.put("references", stringify_map_keys(counts))

      _ ->
        changed
    end
  end

  defp build_changed_fields(_entity_type, action, snapshot, attrs)
       when action == "updated" and not is_nil(snapshot) do
    updated_field_diffs(snapshot, attrs)
  end

  defp build_changed_fields(entity_type, "created", snapshot, attrs)
       when entity_type in @structured_audit_entity_types and not is_nil(snapshot) do
    after_snapshot = Map.get(attrs, :after, Map.get(attrs, "after", snapshot))
    %{"before" => nil, "after" => normalize_value(after_snapshot)}
  end

  defp build_changed_fields(entity_type, "deleted", snapshot, attrs)
       when entity_type in @structured_audit_entity_types and not is_nil(snapshot),
       do:
         %{"before" => normalize_value(snapshot), "after" => nil}
         |> put_shared_operation(attrs)

  defp build_changed_fields(entity_type, "updated", _snapshot, attrs)
       when entity_type in [:route_pattern_build, "route_pattern_build"] do
    %{
      "before" => normalize_value(Map.get(attrs, :before, Map.get(attrs, "before"))),
      "after" => normalize_value(Map.get(attrs, :after, Map.get(attrs, "after"))),
      "patterns_created" =>
        normalize_value(Map.get(attrs, :patterns_created, Map.get(attrs, "patterns_created"))),
      "timings_created" =>
        normalize_value(Map.get(attrs, :timings_created, Map.get(attrs, "timings_created")))
    }
    |> put_grouped_trips(attrs)
  end

  defp build_changed_fields(_entity_type, _action, _snapshot, _attrs), do: nil

  defp updated_field_diffs(snapshot, attrs) do
    snapshot_str_keys = stringify_map_keys(snapshot)

    attrs
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn {field, new_value}, acc ->
      current_value = Map.get(snapshot_str_keys, field)

      if same_value?(current_value, new_value) do
        acc
      else
        Map.put(acc, field, %{
          "from" => normalize_value(current_value),
          "to" => normalize_value(new_value)
        })
      end
    end)
  end

  # A grouped apply lists each trip it moved and the direction that trip had
  # before, so the route's build history records what the review changed. A
  # build with no grouped trips keeps its previous shape.
  defp put_grouped_trips(changed, attrs) do
    case Map.get(attrs, :grouped_trips, Map.get(attrs, "grouped_trips")) do
      nil -> changed
      trips -> Map.put(changed, "grouped_trips", normalize_value(trips))
    end
  end

  # A reviewed bulk deletion shares one operation id across its route, trip and
  # pattern logs, so structured deleted entries carry it when provided. Logs
  # without an operation id keep their previous shape unchanged.
  defp put_shared_operation(changed, attrs) do
    case Map.get(attrs, :operation_id, Map.get(attrs, "operation_id")) do
      nil -> changed
      value -> Map.put(changed, "operation_id", normalize_value(value))
    end
  end

  defp route_after_snapshot("created", attrs, snapshot),
    do: Map.get(attrs, :after, Map.get(attrs, "after", snapshot))

  defp route_after_snapshot(_action, attrs, _snapshot),
    do: Map.get(attrs, :after, Map.get(attrs, "after"))

  # A bulk calendar operation records its shared operation UUID and scope alongside the
  # per-calendar before/after snapshots, so one log per changed calendar can be
  # reconstructed into the whole command.
  defp put_calendar_operation(changed, attrs) do
    keys = [:operation_id, :affected_service_ids, :selected_dates, :combination]

    Enum.reduce(keys, changed, fn key, acc ->
      case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), normalize_value(value))
      end
    end)
  end

  # A bulk trip operation records its shared operation UUID and the affected trip
  # UUIDs alongside the per-trip before/after snapshot, so one log per affected
  # trip can be reconstructed into the whole command.
  defp put_trip_operation(changed, attrs) do
    Enum.reduce([:operation_id, :affected_trip_ids, :combination, :undoes], changed, fn key, acc ->
      case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), normalize_value(value))
      end
    end)
  end

  # A bulk transfer delete records its shared operation UUID and every affected
  # transfer UUID alongside each row's before/after snapshot.
  defp put_transfer_operation(changed, attrs) do
    Enum.reduce([:operation_id, :affected_transfer_ids], changed, fn key, acc ->
      case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), normalize_value(value))
      end
    end)
  end

  # A route command records its shared operation id, creation-attempt provenance
  # and affected identity/count metadata alongside the before/after snapshots, so
  # one log per route can be reconstructed into the whole command.
  defp put_route_operation(changed, attrs) do
    Enum.reduce(
      [
        :operation_id,
        :creation_attempt_id,
        :request_digest,
        :affected_identities,
        :affected_counts
      ],
      changed,
      fn key, acc ->
        case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
          nil -> acc
          value -> Map.put(acc, Atom.to_string(key), normalize_value(value))
        end
      end
    )
  end

  @spec reversible_attrs_for(String.t() | atom(), map()) :: map()
  defp reversible_attrs_for(entity_type, attrs) when is_map(attrs) do
    change_log_fields = change_log_fields_for(entity_type)

    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in change_log_fields
    end)
  end

  defp change_log_fields_for(:pathway), do: change_log_fields_for("pathway")

  defp change_log_fields_for("pathway"),
    do: reversible_fields_for("pathway") ++ ~w(from_stop_id to_stop_id)

  defp change_log_fields_for(entity_type), do: reversible_fields_for(entity_type)

  @doc "Gets a change log within an organization and GTFS version."
  @spec get_change_log(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: ChangeLog.t() | nil
  def get_change_log(organization_id, gtfs_version_id, id) do
    Repo.get_by(ChangeLog,
      id: id,
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    )
  end

  defp same_value?(a, b), do: normalize_value(a) == normalize_value(b)

  defp normalize_value(nil), do: nil
  defp normalize_value(%Decimal{} = d), do: Decimal.to_string(d)

  defp normalize_value(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp normalize_value(%NaiveDateTime{} = ndt) do
    ndt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  end

  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value) when is_number(value), do: value
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(%_{} = struct), do: inspect(struct)
  defp normalize_value(value) when is_map(value), do: value
  defp normalize_value(value) when is_list(value), do: value

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp jsonify(nil), do: nil
  defp jsonify(value), do: normalize_value(value)
end
