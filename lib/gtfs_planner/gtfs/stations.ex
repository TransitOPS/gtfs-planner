defmodule GtfsPlanner.Gtfs.Stations do
  @moduledoc "Station-scoped, authorized commands for GTFS station entities."

  import Ecto.Query

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs

  alias GtfsPlanner.Gtfs.{
    Audit,
    AuditContext,
    ChangeLog,
    Level,
    Pathway,
    PathwayEvolution,
    StationNaming,
    Stop,
    StopLevel,
    StopReferences,
    Translation
  }

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @companion_pathway_fields ~w(traversal_time stair_count min_width signposted_as reversed_signposted_as field_notes field_completed_at)a

  @doc "Returns a child stop only when it belongs to the selected station."
  def get_child_stop(%AuditContext{} = audit, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Stop{} = station <- station(audit) do
      child_query(audit, station, id)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  @doc "Lists the selected station's child stops, including boarding areas."
  def list_child_stops(%AuditContext{} = audit) do
    case station(audit) do
      %Stop{} = station ->
        from(s in child_query(audit, station),
          left_join: l in Level,
          on:
            l.level_id == s.level_id and
              l.organization_id == ^audit.organization_id and
              l.gtfs_version_id == ^audit.gtfs_version_id,
          order_by: [asc: s.stop_name, asc: s.id],
          select_merge: %{level: l}
        )
        |> Repo.all()

      nil ->
        []
    end
  end

  @doc "Returns a pathway and its endpoints only within the selected station."
  def get_pathway(%AuditContext{} = audit, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Stop{} = station <- station(audit),
         %Pathway{} = pathway <- pathway_query(audit, station, id) |> Repo.one() do
      {:ok, load_pathway_stops(audit, pathway)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Checks whether an entity is currently part of the selected station."
  def station_member?(%AuditContext{} = audit, type, id) do
    case station(audit) do
      %Stop{} = station -> rollback_preview_current_member?(audit, station, type, id)
      nil -> false
    end
  end

  @doc "Creates a station-scoped pathway and its change log in one transaction."
  def create_pathway(%AuditContext{} = audit, attrs) when is_map(attrs) do
    run(audit, :share, fn station ->
      changeset = Pathway.create_changeset(%Pathway{}, attrs, audit)

      write_pathway(
        audit,
        validate_pathway_endpoints(changeset, station_scope_ids(audit, station)),
        "created"
      )
    end)
  end

  @doc "Updates a station-scoped pathway at the expected revision."
  def update_pathway(%AuditContext{} = audit, id, attrs, expected_revision)
      when is_map(attrs) do
    run(audit, :share, fn station ->
      pathway = lock_pathway!(audit, station, id)
      stale_pathway!(pathway, expected_revision)

      changeset = Pathway.editor_changeset(pathway, attrs)

      write_pathway(
        audit,
        validate_pathway_endpoints(changeset, station_scope_ids(audit, station)),
        "updated"
      )
    end)
  end

  @doc "Updates only companion-editable pathway fields, allowing an exact endpoint swap."
  def update_pathway_fields(%AuditContext{} = audit, id, attrs, expected_revision)
      when is_map(attrs) do
    run(audit, :share, fn station ->
      pathway = lock_companion_pathway!(audit, station, id)
      stale_pathway!(pathway, expected_revision)

      case companion_endpoint_attrs(attrs, pathway) do
        {:ok, endpoint_attrs} ->
          write_companion_pathway_fields(audit, pathway, attrs, endpoint_attrs)

        {:error, :invalid_endpoints} ->
          Repo.rollback(:invalid_endpoints)
      end
    end)
  end

  defp write_companion_pathway_fields(audit, pathway, attrs, endpoint_attrs) do
    field_attrs =
      Enum.reduce(@companion_pathway_fields, endpoint_attrs, fn field, accepted ->
        case companion_attr(attrs, field) do
          {:ok, value} -> Map.put(accepted, field, value)
          :error -> accepted
        end
      end)

    changeset =
      pathway
      |> Pathway.editor_changeset(field_attrs)
      # The editor normalizes exit gates; the companion cannot change this field.
      |> Ecto.Changeset.delete_change(:is_bidirectional)

    write_pathway(audit, changeset, "updated")
  end

  @doc "Deletes a station-scoped pathway unless a scheduled evolution references it."
  def delete_pathway(%AuditContext{} = audit, id, expected_revision) do
    run(audit, :share, fn station ->
      pathway = lock_pathway!(audit, station, id)
      stale_pathway!(pathway, expected_revision)

      if Repo.exists?(
           from(e in PathwayEvolution,
             where:
               e.organization_id == ^audit.organization_id and
                 e.gtfs_version_id == ^audit.gtfs_version_id and
                 e.pathway_id == ^pathway.pathway_id
           )
         ) do
        Repo.rollback(:pathway_in_use)
      end

      with {:ok, deleted} <- Repo.delete(pathway),
           {:ok, _log} <- Audit.record_change_in_transaction(audit, :pathway, pathway, "deleted") do
        deleted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Creates a level and attaches it to the selected station atomically."
  def create_station_level(%AuditContext{} = audit, level_attrs, stop_level_attrs)
      when is_map(level_attrs) and is_map(stop_level_attrs) do
    run(audit, :share, fn station ->
      level_changeset =
        Level.editor_changeset(
          %Level{organization_id: audit.organization_id, gtfs_version_id: audit.gtfs_version_id},
          level_attrs
        )

      with {:ok, level} <- Repo.insert(level_changeset),
           {:ok, stop_level} <-
             insert_stop_level(audit, station, level, stop_level_attrs),
           {:ok, _level_log} <-
             Audit.record_change_in_transaction(audit, :level, level, "created"),
           {:ok, _association_log} <-
             Audit.record_change_in_transaction(audit, :stop_level, stop_level, "created") do
        %{level: level, stop_level: stop_level}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Attaches an existing level from the selected version to this station."
  def add_existing_level(%AuditContext{} = audit, level_uuid) do
    run(audit, :share, fn station ->
      level = scoped_level!(audit, level_uuid)

      with {:ok, stop_level} <- insert_stop_level(audit, station, level, %{}),
           {:ok, _log} <-
             Audit.record_change_in_transaction(audit, :stop_level, stop_level, "created") do
        stop_level
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Edits an attached level at its expected revision, cascading a natural ID rename."
  def update_level(%AuditContext{} = audit, level_uuid, attrs, expected_revision)
      when is_map(attrs) do
    rename? = Map.has_key?(attrs, :level_id) or Map.has_key?(attrs, "level_id")

    run(audit, if(rename?, do: :exclusive, else: :share), fn station ->
      level = lock_attached_level!(audit, station, level_uuid)
      stale_level!(level, expected_revision)
      changeset = Level.editor_changeset(level, attrs)
      changed_fields = changeset.changes
      new_id = Ecto.Changeset.get_field(changeset, :level_id)

      changeset =
        if changed_fields == %{} do
          Ecto.Changeset.force_change(changeset, :updated_at, DateTime.utc_now())
        else
          changeset
        end

      case Repo.update(changeset) do
        {:ok, updated} -> record_level_update(audit, level, updated, changed_fields, new_id)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp record_level_update(audit, level, updated, changed_fields, new_id) do
    audit_fields =
      if new_id != level.level_id do
        counts = cascade_level_id(audit, level.level_id, new_id)

        Map.merge(changed_fields, %{
          level_id: [level.level_id, new_id],
          references: counts
        })
      else
        changed_fields
      end

    case Audit.record_change_in_transaction(audit, :level, level, "updated", audit_fields) do
      {:ok, _log} -> updated
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Detaches a level at the stop-level revision and clears its station descendants."
  def remove_level_from_station(%AuditContext{} = audit, level_uuid, expected_revision) do
    run(audit, :share, fn station ->
      {stop_level, level} = lock_attached_stop_level!(audit, station, level_uuid)
      stale_stop_level!(stop_level, expected_revision)

      from(s in child_query(audit, station),
        where: s.level_id == ^level.level_id,
        order_by: [asc: s.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Enum.each(&clear_removed_level_from_stop!(audit, &1))

      with {:ok, _deleted} <- Repo.delete(stop_level),
           {:ok, _log} <-
             Audit.record_change_in_transaction(audit, :stop_level, stop_level, "deleted") do
        :removed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp clear_removed_level_from_stop!(audit, stop) do
    changes = %{level_id: nil, diagram_coordinate: nil}
    stop |> Ecto.Changeset.change(changes) |> Repo.update!()

    case Audit.record_change_in_transaction(audit, :stop, stop, "updated", changes) do
      {:ok, _log} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Saves calibration and recalculates derived pathway lengths in the selected station."
  def save_scale(%AuditContext{} = audit, stop_level_id, attrs, expected_revision)
      when is_map(attrs) do
    run(audit, :share, fn station ->
      stop_level = lock_stop_level!(audit, station, stop_level_id)
      stale_stop_level!(stop_level, expected_revision)
      level = scoped_level!(audit, stop_level.level_id)
      changeset = stop_level |> StopLevel.scale_changeset(attrs) |> force_stop_level_update()

      with {:ok, updated} <- Repo.update(changeset),
           {:ok, counts} <-
             Gtfs.recalculate_pathway_lengths_for_level(
               stop_level,
               updated,
               audit.organization_id,
               audit.gtfs_version_id,
               level.id,
               station.id,
               audit
             ),
           {:ok, _log} <-
             Audit.record_change_in_transaction(
               audit,
               :stop_level,
               stop_level,
               "updated",
               changeset.changes
             ) do
        Map.put(counts, :stop_level, updated)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Clears calibration at the expected stop-level revision."
  def clear_scale(%AuditContext{} = audit, stop_level_id, expected_revision) do
    run(audit, :share, fn station ->
      stop_level = lock_stop_level!(audit, station, stop_level_id)
      stale_stop_level!(stop_level, expected_revision)

      changeset =
        StopLevel.scale_changeset(stop_level, %{
          scale_point_a: nil,
          scale_point_b: nil,
          scale_distance_meters: nil,
          scale_meters_per_unit: nil
        })

      write_stop_level(audit, stop_level, changeset)
    end)
  end

  @doc "Saves a floorplan alignment at the expected stop-level revision."
  def save_alignment(%AuditContext{} = audit, stop_level_id, attrs, expected_revision)
      when is_map(attrs) do
    run(audit, :share, fn station ->
      stop_level = lock_stop_level!(audit, station, stop_level_id)
      stale_stop_level!(stop_level, expected_revision)
      write_stop_level(audit, stop_level, StopLevel.alignment_changeset(stop_level, attrs))
    end)
  end

  @doc "Applies a fingerprinted alignment review through the existing serializable station transaction."
  def apply_reviewed_alignment(%AuditContext{} = audit, stop_level_id, attrs, image_w, image_h)
      when is_map(attrs) do
    Gtfs.save_and_apply_stop_level_alignment(stop_level_id, attrs, image_w, image_h, audit)
  end

  @doc "Applies the saved alignment to child stops and records each changed stop."
  def apply_alignment_to_child_stops(
        %AuditContext{} = audit,
        %StopLevel{} = expected_stop_level,
        {image_w, image_h}
      ) do
    run(audit, :share, fn station ->
      apply_alignment_in_station(audit, station, expected_stop_level, image_w, image_h)
    end)
  end

  defp apply_alignment_in_station(audit, station, expected_stop_level, image_w, image_h) do
    stop_level = lock_stop_level!(audit, station, expected_stop_level.id)
    stale_stop_level!(stop_level, expected_stop_level.lock_version)

    # Lock all descendants before deriving coordinates so another editor cannot
    # move a point between the projection read and its audited write.
    from(s in child_query(audit, station), order_by: [asc: s.id], lock: "FOR UPDATE")
    |> Repo.all()

    case Gtfs.derive_child_stop_coords(stop_level, image_w, image_h) do
      {:ok, derived} ->
        Enum.reduce(derived, 0, fn coords, count ->
          apply_child_stop_coords(audit, station, coords, count)
        end)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp apply_child_stop_coords(audit, station, %{stop_id: id, lat: lat, lon: lon}, count) do
    stop = lock_child!(audit, station, id)
    changes = %{stop_lat: Decimal.from_float(lat), stop_lon: Decimal.from_float(lon)}

    if decimal_changed?(stop.stop_lat, changes.stop_lat) or
         decimal_changed?(stop.stop_lon, changes.stop_lon) do
      with {:ok, _updated} <- stop |> Stop.changeset(changes) |> Repo.update(),
           {:ok, _log} <-
             Audit.record_change_in_transaction(audit, :stop, stop, "updated", changes) do
        count + 1
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      count
    end
  end

  @doc false
  def put_stop_level_diagram!(%StopLevel{} = stop_level, filename) when is_binary(filename) do
    changeset =
      StopLevel.changeset(stop_level, %{
        diagram_filename: filename,
        scale_point_a: nil,
        scale_point_b: nil,
        scale_distance_meters: nil,
        scale_meters_per_unit: nil
      })

    Repo.update!(changeset)
  end

  @doc "Creates a child stop under the selected station and records its history."
  def create_child_stop(%AuditContext{} = audit, attrs) when is_map(attrs) do
    run(audit, :share, fn station ->
      platform = Map.get(attrs, :parent_platform) || Map.get(attrs, "parent_platform")
      parent = if platform in [nil, ""], do: station.stop_id, else: platform

      changeset =
        %Stop{parent_station: parent}
        |> Stop.child_stop_changeset(
          Map.drop(attrs, [:parent_station, "parent_station", :parent_platform, "parent_platform"]),
          audit
        )

      ensure_station_parent!(audit, station, changeset)
      ensure_scoped_level!(audit, changeset)
      write_stop(audit, changeset, "created")
    end)
  end

  @doc "Updates a child stop when its expected revision is current."
  def update_child_stop(%AuditContext{} = audit, id, attrs, expected_revision)
      when is_map(attrs) do
    rename? = Map.has_key?(attrs, :stop_id) or Map.has_key?(attrs, "stop_id")

    run(audit, if(rename?, do: :exclusive, else: :share), fn station ->
      stop = lock_child!(audit, station, id)
      stale!(stop, expected_revision)

      changeset =
        if rename?,
          do: Stop.child_stop_changeset(stop, attrs, audit),
          else: Stop.child_stop_changeset(stop, attrs)

      ensure_station_parent!(audit, station, changeset)
      ensure_scoped_level!(audit, changeset)

      if rename? do
        rename_child_stop(audit, stop, changeset)
      else
        write_stop(audit, changeset, "updated")
      end
    end)
  end

  @doc "Restores a station entity from a scoped change log at the previewed revision."
  def rollback_entity(%AuditContext{} = audit, log_id, expected_revision) do
    case Ecto.UUID.cast(log_id) do
      {:ok, log_id} -> rollback_cast_log(audit, log_id, expected_revision)
      _ -> {:error, :not_found}
    end
  end

  defp rollback_cast_log(audit, log_id, expected_revision) do
    # Any historical stop ID may need restoration after a later rename, so
    # select the exclusive version lock before entering the transaction.
    preview_log = Audit.get_change_log(audit.organization_id, audit.gtfs_version_id, log_id)
    lock_mode = if rollback_may_rename_stop?(preview_log), do: :exclusive, else: :share

    run(audit, lock_mode, fn station ->
      rollback_in_station(audit, station, lock_mode, log_id, expected_revision)
    end)
  end

  defp rollback_in_station(audit, station, lock_mode, log_id, expected_revision) do
    log =
      Audit.get_change_log(audit.organization_id, audit.gtfs_version_id, log_id) ||
        Repo.rollback(:not_found)

    if lock_mode == :share and rollback_may_rename_stop?(log),
      do: Repo.rollback(:not_found)

    target_result = rollback_target_snapshot(log)

    # The historical station match is sufficient to return a stored-log
    # error even when a deleted entity no longer has a row to lock.
    if log.station_stop_id == station.stop_id do
      case target_result do
        {:error, reason} when reason != :audit_only_entity -> Repo.rollback(reason)
        _ -> :ok
      end
    end

    entity = lock_rollback_entity!(audit, station, log)

    case target_result do
      {:ok, target} ->
        restore_rollback_target!(audit, station, log, entity, target, expected_revision)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp restore_rollback_target!(audit, station, log, entity, target, expected_revision) do
    stale_rollback!(entity, expected_revision)
    changeset = rollback_changeset(audit, station, entity, target)

    if not changeset.valid?, do: Repo.rollback(changeset)
    if changeset.changes == %{}, do: Repo.rollback(:already_matches_current)

    {updated, counts} = apply_rollback!(audit, entity, changeset)

    attrs =
      changeset.changes
      |> Map.delete(:stop_id)
      |> Map.put(:rolled_back_to_log_id, log.id)
      |> rollback_rename_metadata(entity, updated, counts)

    case Audit.record_change_in_transaction(
           audit,
           rollback_entity_type!(log.entity_type),
           entity,
           "rolled_back",
           attrs
         ) do
      {:ok, _log} -> updated
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Reads a scoped rollback preview without taking write locks or changing data."
  @spec rollback_preview(AuditContext.t(), Ecto.UUID.t()) ::
          {:ok,
           %{
             log: ChangeLog.t(),
             entity: Stop.t() | Pathway.t() | Level.t(),
             current: map(),
             target: map(),
             expected_revision: pos_integer()
           }}
          | {:error,
             :not_found
             | :audit_only_entity
             | :cannot_rollback_create_or_delete
             | :missing_rollback_snapshot}
  def rollback_preview(%AuditContext{} = audit, log_id) do
    with {:ok, log_id} <- Ecto.UUID.cast(log_id),
         %Stop{} = station <- station(audit),
         %ChangeLog{} = log <-
           Audit.get_change_log(audit.organization_id, audit.gtfs_version_id, log_id),
         :ok <- ensure_rollback_preview_scope(audit, station, log),
         {:ok, entity} <- rollback_preview_entity(audit, log),
         {:ok, target} <- rollback_target_snapshot(log) do
      current =
        log.entity_type
        |> Audit.entity_snapshot(entity)
        |> stringify_rollback_keys()

      current =
        if log.entity_type == "stop" and Map.has_key?(target, "stop_id"),
          do: Map.put(current, "stop_id", entity.stop_id),
          else: current

      {:ok,
       %{
         log: log,
         entity: entity,
         current: current,
         target: target,
         expected_revision: entity.lock_version
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp ensure_rollback_preview_scope(audit, station, %ChangeLog{} = log) do
    if log.entity_type in ["stop", "pathway", "level"] do
      ensure_rollback_preview_member(audit, station, log)
    else
      ensure_audit_only_preview_scope(audit, station, log)
    end
  end

  defp ensure_rollback_preview_member(audit, station, %ChangeLog{} = log) do
    if log.station_stop_id == station.stop_id or
         rollback_preview_current_member?(audit, station, log.entity_type, log.entity_id) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp ensure_audit_only_preview_scope(audit, station, %ChangeLog{} = log) do
    current_stop_level? =
      log.entity_type == "stop_level" and
        current_station_stop_level?(audit, station, log.entity_id)

    if log.station_stop_id == station.stop_id or current_stop_level?,
      do: {:error, :audit_only_entity},
      else: {:error, :not_found}
  end

  defp current_station_stop_level?(audit, station, entity_id) do
    case Ecto.UUID.cast(entity_id) do
      {:ok, id} ->
        Repo.exists?(
          from(sl in StopLevel,
            where:
              sl.id == ^id and sl.organization_id == ^audit.organization_id and
                sl.gtfs_version_id == ^audit.gtfs_version_id and sl.stop_id == ^station.id
          )
        )

      _ ->
        false
    end
  end

  defp rollback_preview_current_member?(audit, station, type, id) do
    case rollback_preview_entity(audit, %ChangeLog{entity_type: type, entity_id: id}) do
      {:ok, %Stop{} = stop} ->
        stop.stop_id in station_scope_ids(audit, station)

      {:ok, %Pathway{} = pathway} ->
        ids = station_scope_ids(audit, station)
        pathway.from_stop_id in ids or pathway.to_stop_id in ids

      {:ok, %Level{} = level} ->
        Repo.exists?(
          from(sl in StopLevel,
            where:
              sl.level_id == ^level.id and sl.organization_id == ^audit.organization_id and
                sl.gtfs_version_id == ^audit.gtfs_version_id and sl.stop_id == ^station.id
          )
        )

      _ ->
        false
    end
  end

  defp rollback_preview_entity(audit, %ChangeLog{entity_type: type, entity_id: id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         module when not is_nil(module) <- rollback_preview_module(type),
         entity when not is_nil(entity) <-
           Repo.one(
             from(e in module,
               where:
                 e.id == ^id and e.organization_id == ^audit.organization_id and
                   e.gtfs_version_id == ^audit.gtfs_version_id
             )
           ) do
      {:ok, entity}
    else
      _ -> {:error, :not_found}
    end
  end

  defp rollback_preview_module("stop"), do: Stop
  defp rollback_preview_module("pathway"), do: Pathway
  defp rollback_preview_module("level"), do: Level
  defp rollback_preview_module(_), do: nil

  @doc "Moves a child stop on the station diagram when its revision is current."
  def move_child_stop(%AuditContext{} = audit, id, %{x: x, y: y}, expected_revision)
      when is_number(x) and is_number(y) do
    # String keys, the shape a stored coordinate has: the returned stop is rendered
    # before any reload, and a no-op move is detected by comparing with the stored map.
    coordinate = %{"x" => x, "y" => y}

    run(audit, :share, fn station ->
      stop = lock_child!(audit, station, id)
      stale!(stop, expected_revision)

      write_stop(
        audit,
        Stop.child_stop_changeset(stop, %{diagram_coordinate: coordinate}),
        "updated"
      )
    end)
  end

  @doc "Deletes an unreferenced child stop, its pathways, and their history atomically."
  def delete_child_stop(%AuditContext{} = audit, id, expected_revision) do
    run(audit, :exclusive, fn station ->
      stop = lock_child!(audit, station, id)
      stale!(stop, expected_revision)

      child_ids =
        from(s in Stop,
          where:
            s.organization_id == ^audit.organization_id and
              s.gtfs_version_id == ^audit.gtfs_version_id and
              s.parent_station == ^stop.stop_id,
          select: s.stop_id
        )
        |> Repo.all()

      dependents =
        StopReferences.dependents(
          audit.organization_id,
          audit.gtfs_version_id,
          [stop.stop_id | child_ids]
        )

      if map_size(dependents) > 0, do: Repo.rollback({:in_use, dependents})

      delete_pathways_for_stop!(audit, stop.stop_id)

      with {:ok, deleted} <- Repo.delete(stop),
           {:ok, _log} <- Audit.record_change_in_transaction(audit, :stop, stop, "deleted") do
        deleted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Clears a child stop's diagram placement and deletes its pathways at one revision."
  def remove_child_stop_from_diagram(%AuditContext{} = audit, id, expected_revision) do
    run(audit, :share, fn station ->
      stop = lock_child!(audit, station, id)
      stale!(stop, expected_revision)
      delete_pathways_for_stop!(audit, stop.stop_id)
      clear_diagram_placement(audit, stop)
    end)
  end

  defp clear_diagram_placement(audit, stop) do
    if is_nil(stop.diagram_coordinate) and is_nil(stop.level_id) do
      stop
    else
      changes = %{diagram_coordinate: nil, level_id: nil}
      updated = stop |> Ecto.Changeset.change(changes) |> Repo.update!()

      case Audit.record_change_in_transaction(audit, :stop, stop, "updated", changes) do
        {:ok, _log} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  @doc "Previews the selected station's stop IDs and all affected natural references."
  def preview_station_naming(%AuditContext{} = audit, style \\ :structured, selected_ids \\ nil) do
    run(audit, :share, fn station -> naming_preview(audit, station, style, selected_ids) end)
    |> unwrap_preview()
  end

  @doc "Applies exactly the previewed mapping under the exclusive version lock."
  def apply_station_naming(%AuditContext{} = audit, style, selected_ids, fingerprint)
      when is_binary(fingerprint) do
    run(audit, :exclusive, fn station ->
      case naming_preview(audit, station, style, selected_ids) do
        {:ok, %{fingerprint: ^fingerprint} = preview} ->
          apply_naming_preview(audit, station, preview)

        {:ok, _preview} ->
          Repo.rollback(:stale_preview)

        {:error, :no_stops} ->
          Repo.rollback(:stale_preview)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def apply_station_naming(%AuditContext{}, _style, _selected_ids, _fingerprint),
    do: {:error, :stale_preview}

  @doc false
  def descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id) do
    direct_children =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.parent_station == ^station_stop_id,
        select: s.stop_id
      )

    from(s in Stop,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          (s.parent_station == ^station_stop_id or
             (s.location_type == 4 and s.parent_station in subquery(direct_children))),
      select: s.stop_id
    )
  end

  defp run(%AuditContext{} = audit, lock_mode, action) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit)
      station = lock_published_station!(audit, lock_mode)
      action.(station)
    end)
  rescue
    error in Ecto.ConstraintError ->
      if pathway_closure_violation?(error), do: {:error, :pathway_in_use}, else: {:error, error}

    error in Postgrex.Error ->
      if pathway_closure_violation?(error),
        do: {:error, :pathway_in_use},
        else: reraise(error, __STACKTRACE__)
  end

  # Runs inside the `run/3` transaction, after the membership lock: takes the
  # version lock, then the station share lock.
  defp lock_published_station!(%AuditContext{} = audit, lock_mode) do
    version = lock_version_for_write!(audit, lock_mode)

    if version.publication_status != "published" or is_nil(version.published_at) do
      Repo.rollback(:not_found)
    end

    unless is_binary(audit.station_stop_id) and audit.station_stop_id != "" do
      Repo.rollback(:not_found)
    end

    station =
      from(s in Stop,
        where:
          s.organization_id == ^audit.organization_id and
            s.gtfs_version_id == ^audit.gtfs_version_id and
            s.stop_id == ^audit.station_stop_id and s.location_type == 1,
        lock: "FOR SHARE"
      )
      |> Repo.one()

    if is_nil(station), do: Repo.rollback(:not_found)
    station
  end

  defp lock_version_for_write!(audit, :share),
    do: Versions.lock_for_input_write!(audit.organization_id, audit.gtfs_version_id)

  defp lock_version_for_write!(audit, :exclusive),
    do: Versions.lock_for_exclusive_write!(audit.organization_id, audit.gtfs_version_id)

  defp rollback_may_rename_stop?(%ChangeLog{entity_type: "stop"} = log) do
    case rollback_target_snapshot(log) do
      {:ok, target} -> Map.has_key?(target, "stop_id")
      _ -> false
    end
  end

  defp rollback_may_rename_stop?(_), do: false

  @doc "Returns reversible values captured by a station change log."
  def rollback_target_snapshot(%ChangeLog{entity_type: type})
      when type not in ["stop", "pathway", "level"],
      do: {:error, :audit_only_entity}

  def rollback_target_snapshot(%ChangeLog{action: action})
      when action in ["created", "deleted"],
      do: {:error, :cannot_rollback_create_or_delete}

  def rollback_target_snapshot(%ChangeLog{snapshot: nil}),
    do: {:error, :missing_rollback_snapshot}

  def rollback_target_snapshot(%ChangeLog{
        entity_type: type,
        action: action,
        snapshot: snapshot,
        changed_fields: changed_fields
      })
      when action in ["updated", "rolled_back"] do
    snapshot = stringify_rollback_keys(snapshot)
    changed_fields = stringify_rollback_keys(changed_fields || %{})

    snapshot =
      Enum.reduce(changed_fields, snapshot, fn {field, change}, acc ->
        case rollback_prior_value(change) do
          {:ok, old_value} -> Map.put_new(acc, field, old_value)
          :missing -> acc
        end
      end)

    target = Map.take(snapshot, Audit.reversible_fields_for(type))

    target =
      if type == "stop" and Map.has_key?(snapshot, "stop_id"),
        do: Map.put(target, "stop_id", snapshot["stop_id"]),
        else: target

    {:ok, target}
  end

  def rollback_target_snapshot(_), do: {:error, :cannot_rollback_create_or_delete}

  defp stringify_rollback_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp rollback_prior_value(value) when is_map(value) do
    value = stringify_rollback_keys(value)
    if Map.has_key?(value, "from"), do: {:ok, value["from"]}, else: :missing
  end

  defp rollback_prior_value([old, _new]), do: {:ok, old}
  defp rollback_prior_value(_), do: :missing

  defp lock_rollback_entity!(audit, station, %ChangeLog{entity_type: "stop", entity_id: id} = log) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Stop{} = stop <-
           from(s in Stop,
             where:
               s.id == ^id and s.organization_id == ^audit.organization_id and
                 s.gtfs_version_id == ^audit.gtfs_version_id,
             lock: "FOR UPDATE"
           )
           |> Repo.one() do
      ensure_rollback_station!(audit, station, log, stop)
      stop
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_rollback_entity!(
         audit,
         station,
         %ChangeLog{entity_type: "pathway", entity_id: id} = log
       ) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Pathway{} = pathway <-
           from(p in Pathway,
             where:
               p.id == ^id and p.organization_id == ^audit.organization_id and
                 p.gtfs_version_id == ^audit.gtfs_version_id,
             lock: "FOR UPDATE"
           )
           |> Repo.one() do
      ensure_rollback_station!(audit, station, log, pathway)
      pathway
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_rollback_entity!(
         audit,
         station,
         %ChangeLog{entity_type: "level", entity_id: id} = log
       ) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Level{} = level <-
           from(l in Level,
             where:
               l.id == ^id and l.organization_id == ^audit.organization_id and
                 l.gtfs_version_id == ^audit.gtfs_version_id,
             lock: "FOR UPDATE"
           )
           |> Repo.one() do
      ensure_rollback_station!(audit, station, log, level)
      level
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_rollback_entity!(
         audit,
         station,
         %ChangeLog{
           entity_type: "stop_level",
           entity_id: id
         } = log
       ) do
    current_member? =
      case Ecto.UUID.cast(id) do
        {:ok, id} ->
          Repo.exists?(
            from(sl in StopLevel,
              where:
                sl.id == ^id and sl.organization_id == ^audit.organization_id and
                  sl.gtfs_version_id == ^audit.gtfs_version_id and sl.stop_id == ^station.id
            )
          )

        _ ->
          false
      end

    if log.station_stop_id == station.stop_id or current_member?,
      do: Repo.rollback(:audit_only_entity),
      else: Repo.rollback(:not_found)
  end

  defp lock_rollback_entity!(_audit, station, %ChangeLog{} = log) do
    if log.station_stop_id == station.stop_id,
      do: Repo.rollback(:audit_only_entity),
      else: Repo.rollback(:not_found)
  end

  defp ensure_rollback_station!(_audit, station, log, _entity)
       when log.station_stop_id == station.stop_id,
       do: :ok

  defp ensure_rollback_station!(audit, station, _log, %Stop{} = stop) do
    unless stop.stop_id in station_scope_ids(audit, station), do: Repo.rollback(:not_found)
  end

  defp ensure_rollback_station!(audit, station, _log, %Pathway{} = pathway) do
    ids = station_scope_ids(audit, station)

    unless pathway.from_stop_id in ids or pathway.to_stop_id in ids,
      do: Repo.rollback(:not_found)
  end

  defp ensure_rollback_station!(audit, station, _log, %Level{} = level) do
    unless Repo.exists?(
             from(sl in StopLevel,
               where:
                 sl.level_id == ^level.id and sl.organization_id == ^audit.organization_id and
                   sl.gtfs_version_id == ^audit.gtfs_version_id and sl.stop_id == ^station.id
             )
           ),
           do: Repo.rollback(:not_found)
  end

  defp stale_rollback!(%{lock_version: current}, expected) when current == expected, do: :ok
  defp stale_rollback!(%{lock_version: current}, _expected), do: Repo.rollback({:stale, current})

  defp rollback_changeset(audit, station, %Stop{} = stop, target) do
    changeset =
      if Map.has_key?(target, "stop_id"),
        do: Stop.child_stop_changeset(stop, target, audit),
        else: Stop.child_stop_changeset(stop, target)

    if stop.id == station.id do
      if Ecto.Changeset.get_field(changeset, :location_type) != 1,
        do: Repo.rollback(:not_found)
    else
      ensure_station_parent!(audit, station, changeset)
    end

    ensure_scoped_level!(audit, changeset)
    changeset
  end

  defp rollback_changeset(_audit, _station, %Pathway{} = pathway, target),
    do: Pathway.editor_changeset(pathway, target)

  defp rollback_changeset(_audit, _station, %Level{} = level, target),
    do: Level.editor_changeset(level, target)

  defp apply_rollback!(audit, %Stop{} = stop, changeset) do
    if Ecto.Changeset.get_field(changeset, :stop_id) != stop.stop_id do
      apply_stop_rename!(audit, stop, changeset)
    else
      {update_rollback!(changeset), nil}
    end
  end

  defp apply_rollback!(_audit, _entity, changeset), do: {update_rollback!(changeset), nil}

  defp update_rollback!(changeset) do
    case Repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp rollback_rename_metadata(attrs, %Stop{} = before, %Stop{} = restored, counts)
       when not is_nil(counts),
       do: Map.merge(attrs, %{stop_id: [before.stop_id, restored.stop_id], references: counts})

  defp rollback_rename_metadata(attrs, _before, _after, _counts), do: attrs

  defp rollback_entity_type!("stop"), do: :stop
  defp rollback_entity_type!("pathway"), do: :pathway
  defp rollback_entity_type!("level"), do: :level

  defp station(%AuditContext{} = audit) do
    if is_binary(audit.station_stop_id) and audit.station_stop_id != "" and
         Versions.published_gtfs_version_for_org?(audit.organization_id, audit.gtfs_version_id) do
      from(s in Stop,
        where:
          s.organization_id == ^audit.organization_id and
            s.gtfs_version_id == ^audit.gtfs_version_id and
            s.stop_id == ^audit.station_stop_id and s.location_type == 1
      )
      |> Repo.one()
    end
  end

  defp child_query(audit, station, id \\ nil) do
    descendants =
      descendant_stop_ids_query(audit.organization_id, audit.gtfs_version_id, station.stop_id)

    query =
      from(s in Stop,
        where:
          s.organization_id == ^audit.organization_id and
            s.gtfs_version_id == ^audit.gtfs_version_id and
            s.stop_id in subquery(descendants)
      )

    if id, do: where(query, [s], s.id == ^id), else: query
  end

  defp station_scope_ids(audit, station) do
    [
      station.stop_id
      | Repo.all(
          descendant_stop_ids_query(audit.organization_id, audit.gtfs_version_id, station.stop_id)
        )
    ]
  end

  defp scoped_level!(audit, level_uuid) do
    with {:ok, id} <- Ecto.UUID.cast(level_uuid),
         %Level{} = level <-
           Repo.one(
             from(l in Level,
               where:
                 l.id == ^id and l.organization_id == ^audit.organization_id and
                   l.gtfs_version_id == ^audit.gtfs_version_id
             )
           ) do
      level
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_attached_level!(audit, station, level_uuid) do
    with {:ok, id} <- Ecto.UUID.cast(level_uuid),
         %Level{} = level <-
           Repo.one(
             from(l in Level,
               join: sl in StopLevel,
               on: sl.level_id == l.id,
               where:
                 l.id == ^id and l.organization_id == ^audit.organization_id and
                   l.gtfs_version_id == ^audit.gtfs_version_id and
                   sl.organization_id == ^audit.organization_id and
                   sl.gtfs_version_id == ^audit.gtfs_version_id and sl.stop_id == ^station.id,
               lock: "FOR UPDATE",
               select: l
             )
           ) do
      level
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_attached_stop_level!(audit, station, level_uuid) do
    with {:ok, id} <- Ecto.UUID.cast(level_uuid),
         {%StopLevel{} = stop_level, %Level{} = level} <-
           Repo.one(
             from(sl in StopLevel,
               join: l in Level,
               on: l.id == sl.level_id,
               where:
                 l.id == ^id and l.organization_id == ^audit.organization_id and
                   l.gtfs_version_id == ^audit.gtfs_version_id and
                   sl.organization_id == ^audit.organization_id and
                   sl.gtfs_version_id == ^audit.gtfs_version_id and sl.stop_id == ^station.id,
               lock: "FOR UPDATE",
               select: {sl, l}
             )
           ) do
      {stop_level, level}
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_stop_level!(audit, station, stop_level_uuid) do
    with {:ok, id} <- Ecto.UUID.cast(stop_level_uuid),
         %StopLevel{} = stop_level <-
           Repo.one(
             from(sl in StopLevel,
               where:
                 sl.id == ^id and sl.organization_id == ^audit.organization_id and
                   sl.gtfs_version_id == ^audit.gtfs_version_id and sl.stop_id == ^station.id,
               lock: "FOR UPDATE"
             )
           ) do
      stop_level
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp write_stop_level(audit, previous, changeset) do
    changeset = force_stop_level_update(changeset)

    with {:ok, updated} <- Repo.update(changeset),
         {:ok, _log} <-
           Audit.record_change_in_transaction(
             audit,
             :stop_level,
             previous,
             "updated",
             changeset.changes
           ) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp force_stop_level_update(%Ecto.Changeset{changes: changes} = changeset)
       when map_size(changes) == 0,
       do: Ecto.Changeset.force_change(changeset, :updated_at, DateTime.utc_now())

  defp force_stop_level_update(changeset), do: changeset

  defp insert_stop_level(audit, station, level, attrs) do
    %StopLevel{
      stop_id: station.id,
      level_id: level.id,
      organization_id: audit.organization_id,
      gtfs_version_id: audit.gtfs_version_id
    }
    |> StopLevel.editor_changeset(attrs)
    |> Repo.insert()
  end

  defp cascade_level_id(audit, old_id, new_id) do
    now = DateTime.utc_now()

    {stops, _} =
      from(s in Stop,
        where:
          s.organization_id == ^audit.organization_id and
            s.gtfs_version_id == ^audit.gtfs_version_id and s.level_id == ^old_id
      )
      |> Repo.update_all(set: [level_id: new_id, updated_at: now])

    {translations, _} =
      from(t in Translation,
        where:
          t.organization_id == ^audit.organization_id and
            t.gtfs_version_id == ^audit.gtfs_version_id and
            t.table_name == "levels" and t.record_id == ^old_id
      )
      |> Repo.update_all(set: [record_id: new_id, updated_at: now])

    %{stops: stops, translations: translations}
  end

  defp stale_level!(%Level{lock_version: current}, expected) when current == expected, do: :ok
  defp stale_level!(%Level{lock_version: current}, _), do: Repo.rollback({:stale, current})

  defp stale_stop_level!(%StopLevel{lock_version: current}, expected) when current == expected,
    do: :ok

  defp stale_stop_level!(%StopLevel{lock_version: current}, _),
    do: Repo.rollback({:stale, current})

  defp decimal_changed?(%Decimal{} = old, %Decimal{} = new), do: not Decimal.equal?(old, new)
  defp decimal_changed?(_, _), do: true

  defp pathway_query(audit, station, id) do
    ids = station_scope_ids(audit, station)

    from(p in Pathway,
      where:
        p.organization_id == ^audit.organization_id and
          p.gtfs_version_id == ^audit.gtfs_version_id and p.id == ^id and
          p.from_stop_id in ^ids and p.to_stop_id in ^ids
    )
  end

  defp lock_pathway!(audit, station, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Pathway{} = pathway <-
           pathway_query(audit, station, id) |> lock("FOR UPDATE") |> Repo.one() do
      pathway
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp lock_companion_pathway!(audit, station, id) do
    descendants =
      descendant_stop_ids_query(
        audit.organization_id,
        audit.gtfs_version_id,
        station.stop_id
      )

    scoped_stops =
      from(s in Stop,
        where:
          s.organization_id == ^audit.organization_id and
            s.gtfs_version_id == ^audit.gtfs_version_id,
        select: s.stop_id
      )

    with {:ok, id} <- Ecto.UUID.cast(id),
         %Pathway{} = pathway <-
           from(p in Pathway,
             where:
               p.id == ^id and p.organization_id == ^audit.organization_id and
                 p.gtfs_version_id == ^audit.gtfs_version_id and
                 p.from_stop_id in subquery(scoped_stops) and
                 p.to_stop_id in subquery(scoped_stops) and
                 (p.from_stop_id in subquery(descendants) or
                    p.to_stop_id in subquery(descendants)),
             lock: "FOR UPDATE"
           )
           |> Repo.one() do
      pathway
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp load_pathway_stops(audit, pathway) do
    stops =
      from(s in Stop,
        where:
          s.organization_id == ^audit.organization_id and
            s.gtfs_version_id == ^audit.gtfs_version_id and
            s.stop_id in ^[pathway.from_stop_id, pathway.to_stop_id]
      )
      |> Repo.all()
      |> Map.new(&{&1.stop_id, &1})

    %{
      pathway
      | from_stop: Map.fetch!(stops, pathway.from_stop_id),
        to_stop: Map.fetch!(stops, pathway.to_stop_id)
    }
  end

  defp validate_pathway_endpoints(changeset, scoped_ids) do
    ids = MapSet.new(scoped_ids)

    Enum.reduce([:from_stop_id, :to_stop_id], changeset, fn field, changeset ->
      value = Ecto.Changeset.get_field(changeset, field)

      if is_binary(value) and not MapSet.member?(ids, value) do
        Ecto.Changeset.add_error(changeset, field, "is outside this station")
      else
        changeset
      end
    end)
  end

  defp companion_endpoint_attrs(attrs, pathway) do
    case {companion_attr(attrs, :from_stop_id), companion_attr(attrs, :to_stop_id)} do
      {:error, :error} ->
        {:ok, %{}}

      {{:ok, from}, {:ok, to}} ->
        cond do
          {from, to} == {pathway.from_stop_id, pathway.to_stop_id} ->
            {:ok, %{}}

          {from, to} == {pathway.to_stop_id, pathway.from_stop_id} ->
            {:ok, %{from_stop_id: from, to_stop_id: to}}

          true ->
            {:error, :invalid_endpoints}
        end

      _ ->
        {:error, :invalid_endpoints}
    end
  end

  defp companion_attr(attrs, field) do
    case Map.fetch(attrs, Atom.to_string(field)) do
      :error -> Map.fetch(attrs, field)
      found -> found
    end
  end

  defp stale_pathway!(%Pathway{lock_version: current}, expected) when current == expected,
    do: :ok

  defp stale_pathway!(%Pathway{lock_version: current}, _expected),
    do: Repo.rollback({:stale, current})

  defp write_pathway(audit, changeset, action) do
    original = changeset.data
    changed_fields = changeset.changes

    changeset =
      if action == "updated" and changed_fields == %{} do
        Ecto.Changeset.force_change(changeset, :updated_at, DateTime.utc_now())
      else
        changeset
      end

    result = if action == "created", do: Repo.insert(changeset), else: Repo.update(changeset)

    with {:ok, pathway} <- result,
         {:ok, _log} <-
           Audit.record_change_in_transaction(
             audit,
             :pathway,
             if(action == "updated", do: original, else: pathway),
             action,
             changed_fields
           ) do
      pathway
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp naming_preview(audit, station, style, selected_ids) do
    child_stops =
      from(s in child_query(audit, station),
        where: s.location_type in [0, 2, 3, 4],
        order_by: [asc: s.stop_id]
      )
      |> Repo.all()

    selected_ids =
      case selected_ids do
        nil -> nil
        %MapSet{} = ids -> ids
        ids when is_list(ids) -> MapSet.new(ids)
      end

    if child_stops == [] and selected_ids != MapSet.new() do
      {:error, :no_stops}
    else
      child_stops_naming_preview(audit, station, style, child_stops, selected_ids)
    end
  end

  defp child_stops_naming_preview(audit, station, style, child_stops, selected_ids) do
    child_ids = Enum.map(child_stops, & &1.stop_id)

    pathways =
      from(p in Pathway,
        where:
          p.organization_id == ^audit.organization_id and
            p.gtfs_version_id == ^audit.gtfs_version_id and
            (p.from_stop_id in ^child_ids or p.to_stop_id in ^child_ids)
      )
      |> Repo.all()

    mapping =
      case style do
        :kebab -> StationNaming.build_kebab_naming_map(child_stops)
        _ -> StationNaming.build_naming_map(child_stops, pathways, station.stop_id)
      end

    rows =
      Enum.filter(mapping, fn %{old_id: old_id, new_id: new_id} ->
        old_id != new_id and (is_nil(selected_ids) or MapSet.member?(selected_ids, old_id))
      end)

    build_naming_preview(audit, rows, selected_ids)
  end

  defp build_naming_preview(audit, [], selected_ids) do
    if selected_ids == MapSet.new() do
      counts = StopReferences.count(audit.organization_id, audit.gtfs_version_id, [])

      {:ok,
       %{
         rows: [],
         renamed_stops_count: 0,
         updated_pathways_count: 0,
         updated_references_count: 0,
         fingerprint: :crypto.hash(:sha256, :erlang.term_to_binary({%{}, counts}))
       }}
    else
      {:error, :no_stops}
    end
  end

  defp build_naming_preview(audit, rows, _selected_ids) do
    old_ids = MapSet.new(rows, & &1.old_id)

    candidate_ids =
      rows
      |> Enum.map(& &1.new_id)
      |> MapSet.new()
      |> MapSet.difference(old_ids)
      |> MapSet.to_list()

    existing_ids =
      from(s in Stop,
        where:
          s.organization_id == ^audit.organization_id and
            s.gtfs_version_id == ^audit.gtfs_version_id and s.stop_id in ^candidate_ids,
        select: s.stop_id
      )
      |> Repo.all()
      |> MapSet.new()

    case StationNaming.detect_collisions(rows, existing_ids) do
      [] ->
        counts =
          StopReferences.count(
            audit.organization_id,
            audit.gtfs_version_id,
            MapSet.to_list(old_ids)
          )

        mapping = Map.new(rows, fn %{old_id: old_id, new_id: new_id} -> {old_id, new_id} end)

        {:ok,
         %{
           rows: rows,
           renamed_stops_count: length(rows),
           updated_pathways_count: counts.pathways_from + counts.pathways_to,
           updated_references_count: counts.total,
           fingerprint: :crypto.hash(:sha256, :erlang.term_to_binary({mapping, counts}))
         }}

      collisions ->
        {:error, {:naming_collision, collisions}}
    end
  end

  defp apply_naming_preview(audit, station, preview) do
    mapping = Map.new(preview.rows, fn %{old_id: old_id, new_id: new_id} -> {old_id, new_id} end)
    old_ids = Map.keys(mapping)

    original_stops =
      from(s in child_query(audit, station),
        where: s.stop_id in ^old_ids,
        order_by: [asc: s.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    if length(original_stops) != length(preview.rows), do: Repo.rollback(:stale_preview)

    reference_counts =
      Map.new(original_stops, fn stop ->
        {stop.stop_id,
         StopReferences.count(audit.organization_id, audit.gtfs_version_id, [stop.stop_id])}
      end)

    counts = StopReferences.rename!(audit.organization_id, audit.gtfs_version_id, mapping)

    if counts.total != preview.updated_references_count or
         counts.pathways_from + counts.pathways_to != preview.updated_pathways_count do
      Repo.rollback(:stale_preview)
    end

    Enum.each(original_stops, fn stop ->
      changes = %{
        stop_id: [stop.stop_id, Map.fetch!(mapping, stop.stop_id)],
        references: Map.fetch!(reference_counts, stop.stop_id)
      }

      case Audit.record_change_in_transaction(audit, :stop, stop, "updated", changes) do
        {:ok, _log} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)

    %{
      renamed_stops: length(original_stops),
      updated_pathways: counts.pathways_from + counts.pathways_to,
      updated_references: counts.total
    }
  end

  defp unwrap_preview({:ok, {:ok, preview}}), do: {:ok, preview}
  defp unwrap_preview({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_preview({:error, reason}), do: {:error, reason}

  defp lock_child!(audit, station, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Stop{} = stop <- child_query(audit, station, id) |> lock("FOR UPDATE") |> Repo.one() do
      stop
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp delete_pathways_for_stop!(audit, stop_id) do
    pathways =
      from(p in Pathway,
        where:
          p.organization_id == ^audit.organization_id and
            p.gtfs_version_id == ^audit.gtfs_version_id and
            (p.from_stop_id == ^stop_id or p.to_stop_id == ^stop_id),
        order_by: [asc: p.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    pathway_ids = Enum.map(pathways, & &1.pathway_id)

    if pathway_ids != [] and
         Repo.exists?(
           from(e in PathwayEvolution,
             where:
               e.organization_id == ^audit.organization_id and
                 e.gtfs_version_id == ^audit.gtfs_version_id and e.pathway_id in ^pathway_ids
           )
         ) do
      Repo.rollback(:pathway_in_use)
    end

    Enum.each(pathways, fn pathway ->
      with {:ok, _deleted} <- Repo.delete(pathway),
           {:ok, _log} <-
             Audit.record_change_in_transaction(audit, :pathway, pathway, "deleted") do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp pathway_closure_violation?(%Ecto.ConstraintError{
         type: :foreign_key,
         constraint: constraint
       }),
       do: to_string(constraint) == "pathway_evolutions_pathway_fkey"

  defp pathway_closure_violation?(%Postgrex.Error{postgres: postgres})
       when is_map(postgres),
       do:
         Map.get(postgres, :constraint) == "pathway_evolutions_pathway_fkey" and
           to_string(Map.get(postgres, :code)) in [
             "restrict_violation",
             "foreign_key_violation",
             "23001",
             "23503"
           ]

  defp pathway_closure_violation?(_), do: false

  defp stale!(%Stop{lock_version: current}, expected) when current == expected, do: :ok
  defp stale!(%Stop{lock_version: current}, _expected), do: Repo.rollback({:stale, current})

  defp ensure_station_parent!(audit, station, changeset) do
    parent = Ecto.Changeset.get_field(changeset, :parent_station)
    location_type = Ecto.Changeset.get_field(changeset, :location_type)

    if parent != station.stop_id do
      valid_parent? =
        location_type == 4 and
          Repo.exists?(
            from(s in Stop,
              where:
                s.organization_id == ^audit.organization_id and
                  s.gtfs_version_id == ^audit.gtfs_version_id and
                  s.parent_station == ^station.stop_id and s.stop_id == ^parent and
                  s.location_type == 0
            )
          )

      unless valid_parent?, do: Repo.rollback(:not_found)
    end
  end

  defp ensure_scoped_level!(audit, changeset) do
    if changeset.valid? do
      level_id = Ecto.Changeset.get_field(changeset, :level_id)

      if level_id &&
           not Repo.exists?(
             from(l in Level,
               where:
                 l.organization_id == ^audit.organization_id and
                   l.gtfs_version_id == ^audit.gtfs_version_id and l.level_id == ^level_id
             )
           ) do
        Repo.rollback(:not_found)
      end
    end
  end

  defp rename_child_stop(audit, stop, changeset) do
    if not changeset.valid?, do: Repo.rollback(changeset)

    new_id = Ecto.Changeset.get_field(changeset, :stop_id)

    if new_id == stop.stop_id do
      write_stop(audit, changeset, "updated")
    else
      {updated, counts} = apply_stop_rename!(audit, stop, changeset)
      editor_changes = Map.delete(changeset.changes, :stop_id)

      audit_changes =
        Map.merge(editor_changes, %{stop_id: [stop.stop_id, new_id], references: counts})

      case Audit.record_change_in_transaction(audit, :stop, stop, "updated", audit_changes) do
        {:ok, _log} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp apply_stop_rename!(audit, stop, changeset) do
    new_id = Ecto.Changeset.get_field(changeset, :stop_id)

    if Repo.exists?(
         from(s in Stop,
           where:
             s.organization_id == ^audit.organization_id and
               s.gtfs_version_id == ^audit.gtfs_version_id and s.stop_id == ^new_id
         )
       ) do
      Repo.rollback(Ecto.Changeset.add_error(changeset, :stop_id, "has already been taken"))
    end

    counts =
      StopReferences.rename!(audit.organization_id, audit.gtfs_version_id, %{
        stop.stop_id => new_id
      })

    editor_changes = Map.delete(changeset.changes, :stop_id)
    renamed = Repo.get!(Stop, stop.id)

    updated =
      if editor_changes == %{} do
        renamed
      else
        renamed
        |> Ecto.Changeset.change(editor_changes)
        |> Repo.update!()
      end

    {updated, counts}
  end

  defp write_stop(audit, changeset, action) do
    original_stop = changeset.data
    changed_fields = changeset.changes

    changeset =
      if action == "updated" and changed_fields == %{} do
        Ecto.Changeset.force_change(changeset, :updated_at, DateTime.utc_now())
      else
        changeset
      end

    with {:ok, stop} <- persist(changeset, action),
         {:ok, _log} <-
           Audit.record_change_in_transaction(
             audit,
             :stop,
             if(action == "updated", do: original_stop, else: stop),
             action,
             changed_fields
           ) do
      stop
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist(changeset, "created"), do: Repo.insert(changeset)
  defp persist(changeset, "updated"), do: Repo.update(changeset)
end
