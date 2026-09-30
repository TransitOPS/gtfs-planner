defmodule GtfsPlanner.Gtfs.Stations do
  @moduledoc "Station-scoped, authorized commands for GTFS station entities."

  import Ecto.Query

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.{Audit, AuditContext, Level, Stop, StopReferences}
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
    error in Ecto.ConstraintError -> {:error, error}
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

  defp lock_child!(audit, station, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Stop{} = stop <- child_query(audit, station, id) |> lock("FOR UPDATE") |> Repo.one() do
      stop
    else
      _ -> Repo.rollback(:not_found)
    end
  end

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
