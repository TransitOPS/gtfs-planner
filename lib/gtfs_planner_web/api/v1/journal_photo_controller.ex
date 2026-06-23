defmodule GtfsPlannerWeb.Api.V1.JournalPhotoController do
  @moduledoc """
  Multipart upload of a station-journal photo. The binary is stored under
  `/uploads/field-captures/<org>/<station>/<file>` and served as a static
  absolute URL (mirroring the floorplan image flow); this endpoint creates the
  metadata row and returns the URL. See the companion app's
  `specs/api/station-journal.md`.

  Idempotent on the client-generated photo `id` — re-sending the same file is
  safe to retry on timeout.
  """
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Endpoint

  # 25 MB — a generous cap for a single field photo (modern phone cameras
  # produce ~5–15 MB JPEGs); large enough to never reject a real capture, small
  # enough to bound a single multipart request.
  @max_byte_size 25 * 1024 * 1024

  # content_type => storage extension. Anything else is rejected (422).
  @allowed_content_types %{
    "image/jpeg" => "jpg",
    "image/png" => "png"
  }

  @doc "POST /api/v1/versions/:version_id/stations/:station_id/journal-photos"
  def create(conn, %{"version_id" => version_id, "station_id" => station_id} = params) do
    org_id = conn.assigns[:current_organization_id]

    with {:ok, %Plug.Upload{} = upload} <- fetch_upload(params),
         {:ok, metadata} <- fetch_metadata(params),
         {:ok, content_type, ext} <- resolve_content_type(metadata, upload),
         :ok <- check_size(upload),
         %{} = station <- Gtfs.get_stop(station_id),
         true <- valid_station?(station, org_id, version_id),
         %JournalEntry{} = entry <-
           get_entry(metadata["journal_entry_id"], org_id, version_id, station_id),
         {:ok, filename, byte_size} <-
           store_file(upload, metadata["id"], ext, org_id, station.stop_id),
         {:ok, photo} <-
           Gtfs.upsert_journal_photo(%{
             "id" => metadata["id"],
             "organization_id" => org_id,
             "gtfs_version_id" => version_id,
             "journal_entry_id" => entry.id,
             "filename" => filename,
             "content_type" => content_type,
             "byte_size" => byte_size,
             "captured_at" => metadata["captured_at"]
           }) do
      conn
      |> put_status(201)
      |> json(%{data: %{photo: serialize_photo(photo, org_id, station.stop_id)}})
    else
      :missing_file ->
        error(conn, 422, "validation_error", "A 'file' part is required.")

      :missing_metadata ->
        error(conn, 422, "validation_error", "A 'metadata' part is required.")

      :invalid_metadata ->
        error(conn, 422, "validation_error", "Invalid 'metadata' JSON.")

      :unsupported_content_type ->
        error(
          conn,
          422,
          "validation_error",
          "Unsupported content type. Allowed: image/jpeg, image/png."
        )

      :over_size_cap ->
        error(conn, 413, "payload_too_large", "Photo exceeds the maximum allowed size.")

      :storage_failed ->
        error(conn, 422, "validation_error", "Failed to store photo.")

      nil ->
        error(conn, 404, "not_found", "Not found.")

      false ->
        error(conn, 404, "not_found", "Not found.")

      {:error, _changeset} ->
        error(conn, 422, "validation_error", "Failed to save photo.")
    end
  end

  defp fetch_upload(params) do
    case params["file"] do
      %Plug.Upload{} = upload -> {:ok, upload}
      _ -> :missing_file
    end
  end

  defp fetch_metadata(params) do
    case params["metadata"] do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{} = metadata} -> {:ok, metadata}
          _ -> :invalid_metadata
        end

      %{} = metadata ->
        {:ok, metadata}

      _ ->
        :missing_metadata
    end
  end

  # Prefer the client-declared content_type from metadata; fall back to the
  # upload part's content_type. Reject anything not in the allow-list.
  defp resolve_content_type(metadata, %Plug.Upload{content_type: upload_ct}) do
    content_type = metadata["content_type"] || upload_ct

    case Map.fetch(@allowed_content_types, content_type) do
      {:ok, ext} -> {:ok, content_type, ext}
      :error -> :unsupported_content_type
    end
  end

  defp check_size(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_byte_size -> :ok
      {:ok, _} -> :over_size_cap
      {:error, _} -> :storage_failed
    end
  end

  defp get_entry(nil, _org_id, _version_id, _station_id), do: nil

  defp get_entry(entry_id, org_id, version_id, station_id) when is_binary(entry_id) do
    case Ecto.UUID.cast(entry_id) do
      {:ok, _} ->
        Repo.get_by(JournalEntry,
          id: entry_id,
          organization_id: org_id,
          gtfs_version_id: version_id,
          station_id: station_id
        )

      :error ->
        nil
    end
  end

  defp get_entry(_entry_id, _org_id, _version_id, _station_id), do: nil

  # Stores the upload under <uploads>/field-captures/<org>/<station_dir>/<file>,
  # mirroring the floorplan file-copy pattern (PathSafety + ensure_within_root +
  # mkdir_p + cp). Returns {:ok, filename, byte_size} or :storage_failed.
  defp store_file(%Plug.Upload{path: src_path}, photo_id, ext, org_id, station_stop_id) do
    uploads_base = Application.get_env(:gtfs_planner, :uploads_path)
    station_dir = PathSafety.stop_storage_dir(station_stop_id)
    storage_filename = "#{photo_id}.#{ext}"

    with true <- is_binary(station_dir),
         true <- PathSafety.safe_path_component?(storage_filename),
         captures_root <- Path.join([uploads_base, "field-captures", to_string(org_id)]),
         dest_dir <- Path.join(captures_root, station_dir),
         dest_path <- Path.join(dest_dir, storage_filename),
         :ok <- PathSafety.ensure_within_root(captures_root, dest_dir),
         :ok <- PathSafety.ensure_within_root(captures_root, dest_path),
         :ok <- File.mkdir_p(dest_dir),
         :ok <- File.cp(src_path, dest_path),
         {:ok, %{size: byte_size}} <- File.stat(dest_path) do
      {:ok, storage_filename, byte_size}
    else
      _ -> :storage_failed
    end
  end

  defp serialize_photo(photo, org_id, station_stop_id) do
    %{
      id: photo.id,
      journal_entry_id: photo.journal_entry_id,
      url: field_capture_url(org_id, station_stop_id, photo.filename),
      content_type: photo.content_type,
      width: photo.width,
      height: photo.height,
      captured_at: photo.captured_at
    }
  end

  # Field-capture photos are served as static files under /uploads (like
  # floorplans), not via an /api/v1 endpoint. Returns an absolute URL.
  defp field_capture_url(org_id, station_stop_id, filename) do
    case PathSafety.stop_storage_dir(station_stop_id) do
      dir when is_binary(dir) ->
        encoded_filename = URI.encode(filename, &URI.char_unreserved?/1)

        "#{Endpoint.url()}/uploads/field-captures/#{org_id}/#{dir}/#{encoded_filename}"

      _ ->
        nil
    end
  end

  # Repeated variables enforce equality: matches only when the station's org and
  # version equal the request's. A nil station falls through to false.
  defp valid_station?(
         %{organization_id: org_id, gtfs_version_id: version_id},
         org_id,
         version_id
       ),
       do: true

  defp valid_station?(_station, _org_id, _version_id), do: false

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
