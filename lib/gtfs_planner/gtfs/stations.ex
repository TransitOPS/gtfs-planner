defmodule GtfsPlanner.Gtfs.Stations do
  @moduledoc "Station-scoped, authorized commands for GTFS station entities."

  import Ecto.Query

  alias GtfsPlanner.Authorization

  alias GtfsPlanner.Gtfs.{
    Audit,
    AuditContext,
    Level,
    Pathway,
    PathwayEvolution,
    StationNaming,
    Stop,
    StopReferences
  }

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

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

  @doc "Creates a child stop under the selected station and records its history."
  def create_child_stop(%AuditContext{} = audit, attrs) when is_map(attrs) do
    run(audit, :share, fn station ->
      changeset =
        %Stop{parent_station: station.stop_id}
        |> Stop.create_changeset(Map.drop(attrs, [:parent_station, "parent_station"]), audit)

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
          do: Stop.create_changeset(stop, attrs, audit),
          else: Stop.editor_changeset(stop, attrs)

      ensure_station_parent!(audit, station, changeset)
      ensure_scoped_level!(audit, changeset)

      if rename? do
        rename_child_stop(audit, stop, changeset)
      else
        write_stop(audit, changeset, "updated")
      end
    end)
  end

  @doc "Moves a child stop on the station diagram when its revision is current."
  def move_child_stop(%AuditContext{} = audit, id, %{x: x, y: y} = coordinate, expected_revision)
      when is_number(x) and is_number(y) do
    run(audit, :share, fn station ->
      stop = lock_child!(audit, station, id)
      stale!(stop, expected_revision)
      write_stop(audit, Stop.editor_changeset(stop, %{diagram_coordinate: coordinate}), "updated")
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
    end)
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

      version =
        case lock_mode do
          :share ->
            Versions.lock_for_input_write!(audit.organization_id, audit.gtfs_version_id)

          :exclusive ->
            Versions.lock_for_exclusive_write!(audit.organization_id, audit.gtfs_version_id)
        end

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

    cond do
      child_stops == [] and selected_ids != MapSet.new() ->
        {:error, :no_stops}

      true ->
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
                  s.parent_station == ^station.stop_id and s.stop_id == ^parent
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

      audit_changes =
        Map.merge(editor_changes, %{stop_id: [stop.stop_id, new_id], references: counts})

      case Audit.record_change_in_transaction(audit, :stop, stop, "updated", audit_changes) do
        {:ok, _log} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end
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
