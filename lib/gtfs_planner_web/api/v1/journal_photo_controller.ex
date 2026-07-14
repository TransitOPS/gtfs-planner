defmodule GtfsPlannerWeb.Api.V1.JournalPhotoController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs
  alias GtfsPlannerWeb.Api.V1.JournalJSON

  @doc "POST /api/v1/versions/:version_id/stations/:station_id/journal-photos"
  def create(conn, %{"version_id" => version_id, "station_id" => station_id} = params) do
    with {:ok, scope} <- resolve_scope(conn, version_id, station_id),
         {:ok, metadata} <- metadata(params["metadata"]),
         {:ok, upload} <- upload(params["file"]),
         {:ok, photo} <- Gtfs.create_journal_photo(scope, metadata, upload) do
      conn
      |> put_status(:created)
      |> json(%{data: %{photo: JournalJSON.photo(photo, scope)}})
    else
      {:error, :bad_request} ->
        bad_request(conn)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :id_conflict} ->
        error(conn, 409, "id_conflict")

      {:error, :payload_too_large} ->
        error(conn, 413, "payload_too_large")

      {:error, reason} when reason in [:unsafe_path, :storage_error, :rename_failed] ->
        error(conn, 500, "storage_error")

      {:error, _reason} ->
        error(conn, 422, "validation_error")
    end
  end

  def create(conn, _params), do: bad_request(conn)

  defp resolve_scope(conn, version_id, station_id) do
    case Gtfs.resolve_station_journal_scope(
           conn.assigns.current_organization_id,
           version_id,
           station_id,
           conn.assigns.current_user_id
         ) do
      {:ok, scope} -> {:ok, scope}
      {:error, :invalid_id} -> {:error, :bad_request}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp metadata(value) when is_map(value), do: {:ok, value}

  defp metadata(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :validation_error}
    end
  end

  defp metadata(_value), do: {:error, :validation_error}

  defp upload(%Plug.Upload{} = upload) do
    {:ok, %{path: upload.path, filename: upload.filename, content_type: upload.content_type}}
  end

  defp upload(_value), do: {:error, :validation_error}

  defp bad_request(conn), do: error(conn, 400, "bad_request")
  defp not_found(conn), do: error(conn, 404, "not_found")

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code}})
  end
end
