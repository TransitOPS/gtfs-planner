defmodule GtfsPlanner.Gtfs.StationJournal do
  @moduledoc false

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{JournalEntry, JournalPhoto, Stop}
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlanner.Repo

  @type sync_error :: %{
          id: term(),
          code: :invalid_id | :invalid_target | :id_conflict | :validation_error
        }

  @spec resolve_scope(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Scope.t()} | {:error, :not_found | :invalid_id}
  def resolve_scope(organization_id, gtfs_version_id, station_id, actor_id) do
    with {:ok, organization_id} <- cast_uuid(organization_id),
         {:ok, gtfs_version_id} <- cast_uuid(gtfs_version_id),
         {:ok, station_id} <- cast_uuid(station_id),
         {:ok, actor_id} <- cast_uuid(actor_id) do
      case Repo.one(
             from(stop in Stop,
               where:
                 stop.id == ^station_id and stop.organization_id == ^organization_id and
                   stop.gtfs_version_id == ^gtfs_version_id and stop.location_type == 1 and
                   is_nil(stop.parent_station)
             )
           ) do
        nil -> {:error, :not_found}

        station ->
          {:ok,
           %Scope{
             organization_id: organization_id,
             gtfs_version_id: gtfs_version_id,
             station_id: station.id,
             station_stop_id: station.stop_id,
             actor_id: actor_id
           }}
      end
    else
      :error -> {:error, :invalid_id}
    end
  end

  @spec sync_entries(Scope.t(), [map()]) :: %{
          synced_count: non_neg_integer(),
          errors: [sync_error()]
        }
  def sync_entries(%Scope{} = scope, entries) when is_list(entries) do
    targets = target_index(scope)

    entries
    |> Enum.reduce(%{synced_count: 0, errors: []}, fn attrs, result ->
      case sync_entry(scope, targets, attrs) do
        :ok -> %{result | synced_count: result.synced_count + 1}
        {:error, code} ->
          %{result | errors: result.errors ++ [%{id: attr(attrs, :id), code: code}]}
      end
    end)
  end

  @spec list_entries(Scope.t()) :: [JournalEntry.t()]
  def list_entries(%Scope{} = scope) do
    photos =
      from(photo in JournalPhoto,
        order_by: [asc: photo.captured_at, asc: photo.inserted_at, asc: photo.id]
      )

    from(entry in JournalEntry,
      where:
        entry.organization_id == ^scope.organization_id and
          entry.gtfs_version_id == ^scope.gtfs_version_id and entry.station_id == ^scope.station_id,
      order_by: [asc: entry.captured_at, asc: entry.inserted_at, asc: entry.id],
      preload: [photos: ^photos]
    )
    |> Repo.all()
  end

  defp target_index(scope) do
    %{
      node_ids:
        scope.organization_id
        |> Gtfs.list_child_stops_for_parent(scope.gtfs_version_id, scope.station_id)
        |> Enum.map(& &1.id)
        |> MapSet.new(),
      pathway_ids:
        scope.organization_id
        |> Gtfs.list_pathways_for_station(scope.gtfs_version_id, scope.station_id)
        |> Enum.map(& &1.id)
        |> MapSet.new(),
      stop_level_ids:
        scope.organization_id
        |> Gtfs.list_stop_levels_for_station(scope.gtfs_version_id, scope.station_id)
        |> Enum.map(& &1.id)
        |> MapSet.new()
    }
  end

  defp sync_entry(scope, targets, attrs) when is_map(attrs) do
    with {:ok, id} <- cast_uuid(attr(attrs, :id)),
         :ok <- validate_target(targets, attrs) do
      changeset = JournalEntry.create_changeset(%JournalEntry{}, Map.put(attrs, :id, id), scope)

      if changeset.valid? do
        case Repo.transaction(fn -> persist_entry(scope, id, attrs, changeset) end) do
          {:ok, :ok} -> :ok
          {:ok, {:error, code}} -> {:error, code}
          {:error, _reason} -> {:error, :validation_error}
        end
      else
        {:error, :validation_error}
      end
    else
      :error -> {:error, :invalid_id}
      {:error, :invalid_target} -> {:error, :invalid_target}
    end
  end

  defp sync_entry(_scope, _targets, _attrs), do: {:error, :validation_error}

  defp persist_entry(scope, id, attrs, changeset) do
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :id) do
      {:ok, _entry} ->
        case Repo.one(from(entry in JournalEntry, where: entry.id == ^id, lock: "FOR UPDATE")) do
          nil -> Repo.rollback(:entry_not_found)
          entry -> update_or_conflict(scope, entry, attrs)
        end

      {:error, changeset} ->
        if changeset.errors == [], do: Repo.rollback(:insert_failed), else: {:error, :validation_error}
    end
  end

  defp update_or_conflict(scope, entry, attrs) do
    if owned_by_scope?(entry, scope) do
      case Repo.update(JournalEntry.sync_changeset(entry, attrs)) do
        {:ok, _entry} -> :ok
        {:error, _changeset} -> {:error, :validation_error}
      end
    else
      {:error, :id_conflict}
    end
  end

  defp validate_target(targets, attrs) do
    case attr(attrs, :target_type) do
      "station" -> valid_station_target?(attrs)
      "node" -> valid_reference_target?(targets.node_ids, attrs)
      "pathway" -> valid_reference_target?(targets.pathway_ids, attrs)
      "pin" -> valid_pin_target?(targets.stop_level_ids, attrs)
      _ -> false
    end
    |> case do
      true -> :ok
      false -> {:error, :invalid_target}
    end
  end

  defp valid_station_target?(attrs) do
    blank?(attr(attrs, :target_id)) and blank?(attr(attrs, :stop_level_id)) and
      blank?(attr(attrs, :diagram_x)) and blank?(attr(attrs, :diagram_y))
  end

  defp valid_reference_target?(ids, attrs) do
    member_target?(ids, attr(attrs, :target_id)) and blank?(attr(attrs, :stop_level_id)) and
      blank?(attr(attrs, :diagram_x)) and blank?(attr(attrs, :diagram_y))
  end

  defp valid_pin_target?(ids, attrs) do
    blank?(attr(attrs, :target_id)) and member_target?(ids, attr(attrs, :stop_level_id)) and
      finite_non_negative?(attr(attrs, :diagram_x)) and finite_non_negative?(attr(attrs, :diagram_y))
  end

  defp member_target?(set, value) do
    case cast_uuid(value) do
      {:ok, uuid} -> MapSet.member?(set, uuid)
      :error -> false
    end
  end

  defp finite_non_negative?(value) when is_integer(value), do: value >= 0
  defp finite_non_negative?(value) when is_float(value), do: value >= 0 and value == value
  defp finite_non_negative?(_value), do: false
  defp blank?(value), do: is_nil(value)
  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp owned_by_scope?(entry, scope) do
    entry.organization_id == scope.organization_id and entry.gtfs_version_id == scope.gtfs_version_id and
      entry.station_id == scope.station_id
  end
end
