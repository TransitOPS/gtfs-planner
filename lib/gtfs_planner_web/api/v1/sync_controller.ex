defmodule GtfsPlannerWeb.Api.V1.SyncController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Pathway

  @editable_fields ~w(traversal_time stair_count min_width signposted_as reversed_signposted_as field_notes field_completed_at)a
  @max_journal_entries 100

  # from_stop_id/to_stop_id are accepted ONLY as a swap of the pathway's own
  # endpoints (the field "Reverse direction" action). Sync can reverse a
  # pathway, never rewire one.

  @doc "POST /api/v1/versions/:version_id/stations/:station_id/sync"
  def create(conn, params) do
    with {:ok, pathway_updates} <- required_list(params, "pathways"),
         {:ok, journal_entries} <- optional_list(params, "journal_entries"),
         :ok <- journal_batch_within_limit(journal_entries),
         {:ok, scope} <- resolve_scope(conn, params),
         {:ok, allowed_pathway_ids} <- allowed_pathway_ids(scope) do
      pathway_results = sync_pathways(pathway_updates, allowed_pathway_ids)
      journal_results = sync_journal(scope, journal_entries)

      conn
      |> json(
        sync_response(pathway_results, journal_results, Map.has_key?(params, "journal_entries"))
      )
    else
      {:error, :invalid_pathways} ->
        bad_request(conn, "Request must include a 'pathways' array.")

      {:error, :invalid_journal_entries} ->
        bad_request(conn, "Request must include a 'journal_entries' array when provided.")

      {:error, :journal_batch_too_large} ->
        bad_request(conn, "Request may include at most 100 journal entries.")

      {:error, :invalid_id} ->
        bad_request(conn, "Invalid ID format.")

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  defp required_list(params, key) do
    case Map.fetch(params, key) do
      {:ok, values} when is_list(values) -> {:ok, values}
      _ -> {:error, :invalid_pathways}
    end
  end

  defp optional_list(params, key) do
    case Map.fetch(params, key) do
      :error -> {:ok, nil}
      {:ok, values} when is_list(values) -> {:ok, values}
      _ -> {:error, :invalid_journal_entries}
    end
  end

  defp journal_batch_within_limit(nil), do: :ok
  defp journal_batch_within_limit(entries) when length(entries) <= @max_journal_entries, do: :ok
  defp journal_batch_within_limit(_entries), do: {:error, :journal_batch_too_large}

  defp resolve_scope(conn, %{"version_id" => version_id, "station_id" => station_id}) do
    case Gtfs.resolve_station_journal_scope(
           conn.assigns.current_organization_id,
           version_id,
           station_id,
           conn.assigns.current_user_id
         ) do
      {:ok, scope} -> {:ok, scope}
      {:error, :invalid_id} -> {:error, :invalid_id}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp resolve_scope(_conn, _params), do: {:error, :invalid_id}

  defp allowed_pathway_ids(scope) do
    pathways_by_id =
      scope.organization_id
      |> Gtfs.list_pathways_for_station(scope.gtfs_version_id, scope.station_id)
      |> Map.new(&{&1.id, &1})

    {:ok, pathways_by_id}
  end

  defp sync_pathways(updates, allowed_pathways) do
    Enum.reduce(updates, %{synced_count: 0, errors: []}, fn update, results ->
      sync_pathway(update, allowed_pathways, results)
    end)
  end

  defp sync_pathway(update, allowed_pathways, results) when is_map(update) do
    raw_id = Map.get(update, "id")

    with {:ok, pathway_id} <- Ecto.UUID.cast(raw_id),
         %Pathway{} = pathway <- Map.get(allowed_pathways, pathway_id),
         {:ok, endpoint_changes} <- endpoint_attrs(update, pathway),
         {:ok, _pathway} <- update_pathway(pathway, update, endpoint_changes) do
      %{results | synced_count: results.synced_count + 1}
    else
      :error ->
        add_pathway_error(results, raw_id, "invalid_id", "Pathway id must be a valid UUID.")

      false ->
        add_pathway_error(results, raw_id, "not_found", "Pathway not found.")

      nil ->
        add_pathway_error(results, raw_id, "not_found", "Pathway not found.")

      :invalid_endpoints ->
        add_pathway_error(
          results,
          raw_id,
          "invalid_endpoints",
          "from_stop_id/to_stop_id may only swap the pathway's own endpoints."
        )

      {:error, :validation_error} ->
        add_pathway_error(results, raw_id, "validation_error", "Failed to update pathway.")
    end
  end

  defp sync_pathway(_update, _allowed_pathways, results),
    do: add_pathway_error(results, nil, "validation_error", "Pathway update must be an object.")

  defp update_pathway(pathway, update, endpoint_changes) do
    attrs =
      update
      |> Map.take(Enum.map(@editable_fields, &Atom.to_string/1))
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Map.merge(endpoint_changes)

    case Gtfs.update_pathway(pathway, attrs) do
      {:ok, updated_pathway} -> {:ok, updated_pathway}
      {:error, _changeset} -> {:error, :validation_error}
    end
  end

  defp sync_journal(_scope, nil), do: %{synced_count: 0, errors: []}
  defp sync_journal(scope, entries), do: Gtfs.sync_journal_entries(scope, entries)

  defp sync_response(pathway_results, journal_results, journal_requested?) do
    data = %{
      synced_count: pathway_results.synced_count,
      synced_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    data =
      if journal_requested?,
        do: Map.put(data, :journal_synced_count, journal_results.synced_count),
        else: data

    errors = pathway_results.errors ++ Enum.map(journal_results.errors, &journal_error/1)
    data = if errors == [], do: data, else: Map.put(data, :errors, errors)

    %{data: data}
  end

  defp journal_error(%{id: id, code: code}) do
    %{id: id, code: Atom.to_string(code), message: journal_error_message(code)}
  end

  defp journal_error_message(:invalid_id), do: "Journal entry id must be a valid UUID."

  defp journal_error_message(:invalid_target),
    do: "Journal entry target is invalid for this station."

  defp journal_error_message(:id_conflict),
    do: "Journal entry id conflicts with an existing entry."

  defp journal_error_message(:validation_error), do: "Journal entry is invalid."

  defp add_pathway_error(results, id, code, message) do
    %{results | errors: results.errors ++ [%{id: id, code: code, message: message}]}
  end

  # Validates the swap-only endpoint rule. Returns {:ok, changes} where
  # changes are empty (pair absent or unchanged) or the stored pair swapped.
  defp endpoint_attrs(update, pathway) do
    has_from = Map.has_key?(update, "from_stop_id")
    has_to = Map.has_key?(update, "to_stop_id")

    cond do
      not has_from and not has_to ->
        {:ok, %{}}

      not (has_from and has_to) ->
        :invalid_endpoints

      {update["from_stop_id"], update["to_stop_id"]} ==
          {pathway.from_stop_id, pathway.to_stop_id} ->
        {:ok, %{}}

      {update["from_stop_id"], update["to_stop_id"]} ==
          {pathway.to_stop_id, pathway.from_stop_id} ->
        {:ok, %{from_stop_id: pathway.to_stop_id, to_stop_id: pathway.from_stop_id}}

      true ->
        :invalid_endpoints
    end
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(400)
    |> json(%{
      error: %{
        code: "bad_request",
        message: message
      }
    })
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{error: %{code: "not_found"}})
  end
end
