defmodule GtfsPlannerWeb.Api.V1.SyncController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{AuditContext, Stations}

  @max_pathway_entries 100
  @max_journal_entries 100

  @doc "POST /api/v1/versions/:version_id/stations/:station_id/sync"
  def create(conn, params) do
    with {:ok, pathway_updates} <- required_list(params, "pathways"),
         {:ok, journal_entries} <- optional_list(params, "journal_entries"),
         :ok <- pathway_batch_within_limit(pathway_updates),
         :ok <- unique_pathway_ids(pathway_updates),
         :ok <- journal_batch_within_limit(journal_entries),
         {:ok, scope} <- resolve_scope(conn, params) do
      audit = %AuditContext{
        organization_id: conn.assigns.current_organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        station_stop_id: scope.station_stop_id,
        actor_id: conn.assigns.current_user.id,
        actor_email: conn.assigns.current_user.email
      }

      pathway_results = sync_pathways(pathway_updates, audit)
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

      {:error, :pathway_batch_too_large} ->
        bad_request(conn, "Request may include at most 100 pathways.")

      {:error, :duplicate_pathway_id} ->
        bad_request(conn, "Each pathway may appear once per request.")

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

  defp pathway_batch_within_limit(entries) when length(entries) <= @max_pathway_entries,
    do: :ok

  defp pathway_batch_within_limit(_entries), do: {:error, :pathway_batch_too_large}

  defp unique_pathway_ids(entries) do
    ids =
      entries
      |> Enum.flat_map(fn
        %{"id" => id} when is_binary(id) ->
          [
            case Ecto.UUID.cast(id) do
              {:ok, canonical} -> canonical
              :error -> id
            end
          ]

        _ ->
          []
      end)

    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: {:error, :duplicate_pathway_id}
  end

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

  defp sync_pathways(updates, audit) do
    results =
      Enum.reduce(
        updates,
        %{synced_count: 0, errors: [], revisions: [], forbidden?: false},
        &sync_pathway(&1, &2, audit)
      )

    results
    |> Map.update!(:errors, &Enum.reverse/1)
    |> Map.update!(:revisions, &Enum.reverse/1)
    |> Map.delete(:forbidden?)
  end

  defp sync_pathway(update, %{forbidden?: true} = results, _audit),
    do: add_pathway_error(results, pathway_id(update), "forbidden", "Editor access was revoked.")

  defp sync_pathway(update, results, audit) when is_map(update) do
    raw_id = Map.get(update, "id")

    with {:ok, pathway_id} <- Ecto.UUID.cast(raw_id),
         {:ok, revision} <- valid_revision(update),
         {:ok, updated_pathway} <-
           Stations.update_pathway_fields(audit, pathway_id, update, revision) do
      %{
        results
        | synced_count: results.synced_count + 1,
          revisions: [
            %{id: pathway_id, revision: updated_pathway.lock_version} | results.revisions
          ]
      }
    else
      :error ->
        add_pathway_error(results, raw_id, "invalid_id", "Pathway id must be a valid UUID.")

      {:error, :invalid_revision} ->
        add_pathway_error(
          results,
          raw_id,
          "invalid_revision",
          "Revision must be an integer of at least 1."
        )

      {:error, :invalid_endpoints} ->
        add_pathway_error(
          results,
          raw_id,
          "invalid_endpoints",
          "from_stop_id/to_stop_id may only swap the pathway's own endpoints."
        )

      {:error, {:stale, current_revision}} ->
        add_pathway_error(
          results,
          raw_id,
          "stale",
          "This pathway changed on the server.",
          %{current_revision: current_revision}
        )

      {:error, :forbidden} ->
        results
        |> add_pathway_error(raw_id, "forbidden", "Editor access was revoked.")
        |> Map.put(:forbidden?, true)

      {:error, :not_found} ->
        add_pathway_error(results, raw_id, "not_found", "Pathway not found.")

      {:error, _reason} ->
        add_pathway_error(results, raw_id, "validation_error", "Failed to update pathway.")
    end
  end

  defp sync_pathway(_update, results, _audit),
    do: add_pathway_error(results, nil, "validation_error", "Pathway update must be an object.")

  defp valid_revision(%{"revision" => revision}) when is_integer(revision) and revision >= 1,
    do: {:ok, revision}

  defp valid_revision(_update), do: {:error, :invalid_revision}

  defp pathway_id(update) when is_map(update), do: Map.get(update, "id")
  defp pathway_id(_update), do: nil

  defp sync_journal(_scope, nil), do: %{synced_count: 0, errors: []}
  defp sync_journal(scope, entries), do: Gtfs.sync_journal_entries(scope, entries)

  defp sync_response(pathway_results, journal_results, journal_requested?) do
    data = %{
      synced_count: pathway_results.synced_count,
      revisions: pathway_results.revisions,
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
  defp journal_error_message(:forbidden), do: "Editor access was revoked."
  defp journal_error_message(_code), do: "Journal entry could not be synchronized."

  defp add_pathway_error(results, id, code, message, extra \\ %{}) do
    error = Map.merge(%{id: id, code: code, message: message}, extra)
    %{results | errors: [error | results.errors]}
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
