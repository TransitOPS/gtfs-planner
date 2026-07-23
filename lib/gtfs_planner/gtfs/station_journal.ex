defmodule GtfsPlanner.Gtfs.StationJournal do
  @moduledoc false

  import Ecto.Query

  alias GtfsPlanner.Gtfs

  alias GtfsPlanner.Gtfs.{
    Coordinates,
    FloorplanTransform,
    JournalEntry,
    JournalPhoto,
    Stop,
    StopLevel
  }

  alias GtfsPlanner.Gtfs.StationJournal.{PhotoStorage, Scope}
  alias GtfsPlanner.Repo

  require Logger

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
        nil ->
          {:error, :not_found}

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
      :error ->
        {:error, :invalid_id}
    end
  end

  @spec subscribe(Scope.t()) :: :ok | {:error, term()}
  def subscribe(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic(scope))
  end

  @spec sync_entries(Scope.t(), [map()]) :: %{
          synced_count: non_neg_integer(),
          errors: [sync_error()]
        }
  def sync_entries(%Scope{} = scope, entries) when is_list(entries) do
    targets = target_index(scope)

    result =
      Enum.reduce(entries, %{synced_count: 0, errors: []}, fn attrs, result ->
        case sync_entry(scope, targets, attrs) do
          :ok ->
            %{result | synced_count: result.synced_count + 1}

          {:error, code} ->
            %{result | errors: [%{id: error_id(attrs), code: code} | result.errors]}
        end
      end)

    result = %{result | errors: Enum.reverse(result.errors)}

    if result.synced_count > 0 do
      broadcast_changed(scope)
    end

    result
  end

  @spec list_entries(Scope.t(), keyword()) :: [JournalEntry.t()]
  def list_entries(%Scope{} = scope, opts \\ []) when is_list(opts) do
    opts = validate_list_opts!(opts)

    status = Keyword.get(opts, :status, :all)
    order = Keyword.get(opts, :order, :asc)
    limit = Keyword.get(opts, :limit, nil)
    target = Keyword.get(opts, :target, nil)

    scope
    |> base_entries_query()
    |> filter_by_target(target)
    |> filter_by_status(status)
    |> sort_by_order(order)
    |> limit_entries(limit)
    |> Repo.all()
  end

  @spec close_entry(Scope.t(), Ecto.UUID.t()) ::
          {:ok, JournalEntry.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def close_entry(%Scope{} = scope, entry_id) do
    case cast_uuid(entry_id) do
      {:ok, id} ->
        case apply_transition(scope, id, :close) do
          {:ok, {entry, _tag}} -> {:ok, entry}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @spec reopen_entry(Scope.t(), Ecto.UUID.t()) ::
          {:ok, JournalEntry.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def reopen_entry(%Scope{} = scope, entry_id) do
    case cast_uuid(entry_id) do
      {:ok, id} ->
        case apply_transition(scope, id, :reopen) do
          {:ok, {entry, _tag}} -> {:ok, entry}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @spec refresh_pin_coordinates_for_stop_level(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh_pin_coordinates_for_stop_level(%StopLevel{} = stop_level, image_w, image_h)
      when is_integer(image_w) and image_w > 0 and is_integer(image_h) and image_h > 0 do
    with {:ok, alignment} <- StopLevel.alignment_transform(stop_level) do
      from(entry in JournalEntry,
        where:
          entry.organization_id == ^stop_level.organization_id and
            entry.gtfs_version_id == ^stop_level.gtfs_version_id and
            entry.station_id == ^stop_level.stop_id and entry.target_type == "pin" and
            entry.stop_level_id == ^stop_level.id,
        lock: "FOR UPDATE"
      )
      |> Repo.all()
      |> Enum.reduce_while({:ok, 0}, fn entry, {:ok, count} ->
        case Coordinates.normalize_point(%{x: entry.diagram_x, y: entry.diagram_y}) do
          nil ->
            {:cont, {:ok, count}}

          point ->
            with {:ok, {lat, lon}} <-
                   FloorplanTransform.svg_to_lat_lon(alignment, image_w, image_h, point),
                 {:ok, _entry} <-
                   entry
                   |> JournalEntry.derived_coordinates_changeset(%{lat: lat, lon: lon})
                   |> Repo.update() do
              {:cont, {:ok, count + 1}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)
    end
  end

  def refresh_pin_coordinates_for_stop_level(_, _, _), do: {:error, :invalid_input}

  @spec create_photo(Scope.t(), map(), %{
          path: String.t(),
          filename: String.t(),
          content_type: String.t() | nil
        }) ::
          {:ok, JournalPhoto.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_photo(%Scope{} = scope, attrs, upload) when is_map(attrs) and is_map(upload) do
    with {:ok, photo_id} <- cast_uuid(attr(attrs, :id)),
         {:ok, entry_id} <- cast_uuid(attr(attrs, :journal_entry_id)),
         {:ok, staged} <- PhotoStorage.stage(scope, photo_id, upload),
         {:ok, photo} <- create_staged_photo(scope, photo_id, entry_id, attrs, staged) do
      broadcast_changed(scope)
      {:ok, photo}
    else
      :error -> {:error, :invalid_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_photo(_scope, _attrs, _upload), do: {:error, :validation_error}

  defp create_staged_photo(scope, photo_id, entry_id, attrs, staged) do
    with :ok <- validate_captured_at(attr(attrs, :captured_at)) do
      result = Repo.transaction(fn -> persist_photo(scope, photo_id, entry_id, attrs, staged) end)

      case result do
        {:ok, {:ok, photo}} ->
          {:ok, photo}

        {:ok, {:error, reason}} ->
          PhotoStorage.discard(staged)
          {:error, reason}

        {:error, %Ecto.Changeset{} = changeset} ->
          PhotoStorage.discard(staged)
          {:error, changeset}

        {:error, reason} ->
          PhotoStorage.discard(staged)
          {:error, reason}
      end
    else
      {:error, reason} ->
        PhotoStorage.discard(staged)
        {:error, reason}
    end
  end

  defp persist_photo(scope, photo_id, entry_id, attrs, staged) do
    with %JournalEntry{} = entry <- locked_scoped_entry(scope, entry_id) do
      case Repo.one(from(photo in JournalPhoto, where: photo.id == ^photo_id, lock: "FOR UPDATE")) do
        nil ->
          with :ok <- validate_create_photo_metadata(attrs, staged) do
            create_or_adopt_photo(entry, photo_id, attrs, staged)
          end

        photo ->
          retry_photo(entry, photo, staged)
      end
    else
      nil -> {:error, :not_found}
    end
  end

  defp locked_scoped_entry(scope, entry_id) do
    Repo.one(
      from(entry in JournalEntry,
        where:
          entry.id == ^entry_id and entry.organization_id == ^scope.organization_id and
            entry.gtfs_version_id == ^scope.gtfs_version_id and
            entry.station_id == ^scope.station_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp create_or_adopt_photo(entry, photo_id, attrs, staged) do
    if PhotoStorage.canonical_conflict?(staged) do
      log_storage(:orphan_conflict, photo_id, entry.id)
      {:error, :id_conflict}
    else
      photo_attrs = trusted_photo_attrs(photo_id, entry.id, attrs, staged)

      case JournalPhoto.create_changeset(%JournalPhoto{}, photo_attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: :id) do
        {:ok, _photo} ->
          case Repo.one(
                 from(photo in JournalPhoto, where: photo.id == ^photo_id, lock: "FOR UPDATE")
               ) do
            nil ->
              Repo.rollback(:photo_not_found)

            photo ->
              if photo.journal_entry_id == entry.id and photo.sha256 == staged.sha256 and
                   photo.content_type == staged.content_type do
                if File.exists?(staged.final_path) do
                  PhotoStorage.discard(staged)
                  log_storage(:orphan_adopted, photo_id, entry.id)
                else
                  finalize_or_rollback(photo_id, entry.id, staged)
                end

                {:ok, photo}
              else
                log_storage(:id_conflict, photo_id, entry.id)
                {:error, :id_conflict}
              end
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end
  end

  defp retry_photo(entry, photo, staged) do
    if photo.journal_entry_id == entry.id and photo.sha256 == staged.sha256 and
         photo.content_type == staged.content_type do
      if PhotoStorage.final_matches?(staged) do
        PhotoStorage.discard(staged)
      else
        log_storage(:file_repaired, photo.id, entry.id)

        case PhotoStorage.finalize(staged) do
          :ok ->
            :ok

          {:error, reason} ->
            log_storage(:rename_failed, photo.id, entry.id)
            Repo.rollback(reason)
        end
      end

      {:ok, photo}
    else
      log_storage(:id_conflict, photo.id, entry.id)
      {:error, :id_conflict}
    end
  end

  defp finalize_or_rollback(photo_id, entry_id, staged) do
    case PhotoStorage.finalize(staged) do
      :ok ->
        :ok

      {:error, reason} ->
        log_storage(:rename_failed, photo_id, entry_id)
        Repo.rollback(reason)
    end
  end

  defp trusted_photo_attrs(photo_id, entry_id, attrs, staged) do
    %{
      id: photo_id,
      journal_entry_id: entry_id,
      filename: staged.filename,
      content_type: staged.content_type,
      byte_size: staged.byte_size,
      sha256: staged.sha256,
      width: attr(attrs, :width),
      height: attr(attrs, :height),
      captured_at: attr(attrs, :captured_at)
    }
  end

  defp validate_content_type_hint(nil, _detected), do: :ok
  defp validate_content_type_hint(hint, detected) when hint == detected, do: :ok
  defp validate_content_type_hint(_hint, _detected), do: {:error, :validation_error}
  defp validate_captured_at(nil), do: {:error, :validation_error}

  defp validate_captured_at(value) do
    case Ecto.Type.cast(:utc_datetime_usec, value) do
      {:ok, _captured_at} -> :ok
      :error -> {:error, :validation_error}
    end
  end

  defp validate_create_photo_metadata(attrs, staged) do
    with :ok <- validate_content_type_hint(attr(attrs, :content_type), staged.content_type),
         :ok <- validate_dimension(attr(attrs, :width)),
         :ok <- validate_dimension(attr(attrs, :height)) do
      :ok
    end
  end

  defp validate_dimension(nil), do: :ok
  defp validate_dimension(value) when is_integer(value) and value > 0, do: :ok
  defp validate_dimension(_value), do: {:error, :validation_error}

  defp log_storage(state, photo_id, entry_id) do
    Logger.warning(
      "station_journal_photo_storage",
      state: state,
      photo_id: photo_id,
      journal_entry_id: entry_id
    )
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
    case cast_uuid(attr(attrs, :id)) do
      {:ok, id} ->
        case Repo.get(JournalEntry, id) do
          nil -> sync_new_entry(scope, targets, id, attrs)
          entry -> sync_existing_entry(scope, targets, id, entry, attrs)
        end

      :error ->
        {:error, :invalid_id}
    end
  end

  defp sync_entry(_scope, _targets, _attrs), do: {:error, :validation_error}

  defp sync_new_entry(scope, targets, id, attrs) do
    with :ok <- validate_target(targets, attrs) do
      changeset = JournalEntry.create_changeset(%JournalEntry{}, attrs, scope)

      if changeset.valid? do
        sync_entry_transaction(fn -> persist_entry(scope, id, attrs, changeset) end)
      else
        {:error, :validation_error}
      end
    end
  end

  defp sync_existing_entry(scope, targets, id, entry, attrs) do
    if owned_by_scope?(entry, scope) do
      sync_entry_transaction(fn -> persist_existing_entry(scope, targets, id, attrs) end)
    else
      {:error, :id_conflict}
    end
  end

  defp sync_entry_transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, :ok} -> :ok
      {:ok, {:error, code}} -> {:error, code}
      {:error, _reason} -> {:error, :validation_error}
    end
  end

  defp persist_entry(scope, id, attrs, changeset) do
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :id) do
      {:ok, _entry} ->
        case Repo.one(from(entry in JournalEntry, where: entry.id == ^id, lock: "FOR UPDATE")) do
          nil -> Repo.rollback(:entry_not_found)
          entry -> update_or_conflict(scope, entry, attrs)
        end

      {:error, changeset} ->
        if changeset.errors == [],
          do: Repo.rollback(:insert_failed),
          else: {:error, :validation_error}
    end
  end

  defp persist_existing_entry(scope, targets, id, attrs) do
    case Repo.one(from(entry in JournalEntry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        {:error, :validation_error}

      entry ->
        if owned_by_scope?(entry, scope) do
          changeset = JournalEntry.sync_changeset(entry, attrs)

          with true <- changeset.valid?,
               :ok <- validate_target(targets, target_attrs(changeset)) do
            case Repo.update(changeset) do
              {:ok, _entry} -> :ok
              {:error, _changeset} -> {:error, :validation_error}
            end
          else
            false -> {:error, :validation_error}
            {:error, :invalid_target} -> {:error, :invalid_target}
          end
        else
          {:error, :id_conflict}
        end
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

  defp target_attrs(changeset) do
    Map.new([:target_type, :target_id, :stop_level_id, :diagram_x, :diagram_y], fn field ->
      {field, Ecto.Changeset.get_field(changeset, field)}
    end)
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
      finite_non_negative?(attr(attrs, :diagram_x)) and
      finite_non_negative?(attr(attrs, :diagram_y))
  end

  defp member_target?(set, value) do
    case cast_uuid(value) do
      {:ok, uuid} -> MapSet.member?(set, uuid)
      :error -> false
    end
  end

  defp finite_non_negative?(value) when is_integer(value), do: value >= 0
  defp finite_non_negative?(value) when is_float(value), do: value >= 0
  defp finite_non_negative?(_value), do: false
  defp blank?(value), do: is_nil(value)
  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  defp error_id(attrs) when is_map(attrs), do: attr(attrs, :id)
  defp error_id(_attrs), do: nil
  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp owned_by_scope?(entry, scope) do
    entry.organization_id == scope.organization_id and
      entry.gtfs_version_id == scope.gtfs_version_id and
      entry.station_id == scope.station_id
  end

  defp apply_transition(scope, entry_id, transition) do
    result =
      Repo.transaction(fn ->
        case locked_scoped_entry(scope, entry_id) do
          nil ->
            Repo.rollback(:not_found)

          %JournalEntry{} = entry ->
            case transition do
              :close ->
                if is_nil(entry.closed_at) do
                  changeset =
                    JournalEntry.close_changeset(entry, DateTime.utc_now(), scope.actor_id)

                  case Repo.update(changeset) do
                    {:ok, updated} -> {:updated, updated}
                    {:error, cs} -> Repo.rollback(cs)
                  end
                else
                  {:noop, entry}
                end

              :reopen ->
                if not is_nil(entry.closed_at) do
                  changeset = JournalEntry.reopen_changeset(entry)

                  case Repo.update(changeset) do
                    {:ok, updated} -> {:updated, updated}
                    {:error, cs} -> Repo.rollback(cs)
                  end
                else
                  {:noop, entry}
                end
            end
        end
      end)

    case result do
      {:ok, {:updated, entry}} ->
        broadcast_changed(scope)
        {:ok, {entry, :updated}}

      {:ok, {:noop, entry}} ->
        {:ok, {entry, :noop}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} ->
        raise "unexpected journal transition error: #{inspect(reason)}"
    end
  end

  defp base_entries_query(%Scope{} = scope) do
    photos =
      from(photo in JournalPhoto,
        order_by: [asc: photo.captured_at, asc: photo.inserted_at, asc: photo.id]
      )

    from(entry in JournalEntry,
      where:
        entry.organization_id == ^scope.organization_id and
          entry.gtfs_version_id == ^scope.gtfs_version_id and
          entry.station_id == ^scope.station_id,
      preload: [photos: ^photos]
    )
  end

  defp filter_by_target(query, nil), do: query

  defp filter_by_target(query, {type, id}) do
    {:ok, uuid} = cast_uuid(id)

    from(entry in query,
      where: entry.target_type == ^type and entry.target_id == ^uuid
    )
  end

  defp filter_by_status(query, :all), do: query
  defp filter_by_status(query, :open), do: where(query, [entry], is_nil(entry.closed_at))

  defp sort_by_order(query, :asc) do
    order_by(query, [entry],
      asc: entry.captured_at,
      asc: entry.inserted_at,
      asc: entry.id
    )
  end

  defp sort_by_order(query, :desc) do
    order_by(query, [entry],
      desc: entry.captured_at,
      desc: entry.inserted_at,
      desc: entry.id
    )
  end

  defp limit_entries(query, nil), do: query
  defp limit_entries(query, limit) when is_integer(limit) and limit > 0, do: limit(query, ^limit)

  defp validate_list_opts!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "options must be a keyword list"
    end

    allowed_keys = [:status, :order, :limit, :target]

    for {key, val} <- opts do
      if key not in allowed_keys do
        raise ArgumentError, "unknown option: #{inspect(key)}"
      end

      validate_opt!(key, val)
    end

    opts
  end

  defp validate_opt!(:status, val) do
    if val not in [:open, :all] do
      raise ArgumentError, "invalid :status option: #{inspect(val)}"
    end
  end

  defp validate_opt!(:order, val) do
    if val not in [:asc, :desc] do
      raise ArgumentError, "invalid :order option: #{inspect(val)}"
    end
  end

  defp validate_opt!(:limit, val) do
    unless is_nil(val) or (is_integer(val) and val > 0) do
      raise ArgumentError, "invalid :limit option: #{inspect(val)}"
    end
  end

  defp validate_opt!(:target, {type, id}) when type in ["node", "pathway"] do
    case cast_uuid(id) do
      {:ok, _uuid} ->
        :ok

      :error ->
        raise ArgumentError, "invalid :target id: #{inspect(id)}"
    end
  end

  defp validate_opt!(:target, val) do
    raise ArgumentError, "invalid :target option: #{inspect(val)}"
  end

  defp topic(%Scope{} = scope) do
    "station_journal:#{scope.organization_id}:#{scope.gtfs_version_id}:#{scope.station_id}"
  end

  defp broadcast_changed(%Scope{} = scope) do
    case Phoenix.PubSub.broadcast(
           GtfsPlanner.PubSub,
           topic(scope),
           {:station_journal_changed, scope.station_id}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("station_journal_pubsub_broadcast_failed", reason: reason)
        :ok
    end
  end
end
