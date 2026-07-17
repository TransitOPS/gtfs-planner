defmodule GtfsPlannerWeb.UploadsPlug do
  @moduledoc """
  Serves uploaded files from the configured uploads directory.

  This plug intercepts requests to `/uploads/*` and serves files from the
  directory specified by the `:uploads_path` application configuration.
  If a file is not found, the request is passed to the next plug.

  ## CORS

  Uploaded files (e.g. floorplan diagrams) are fetched cross-origin by the
  companion web app, so the same CORS policy used by the API
  (`GtfsPlannerWeb.Plugs.CORS`) is applied here. Without it the browser blocks
  the response and the image can't be read. Other endpoints get CORS via the
  router's `:api_cors` pipeline, but this plug runs at the endpoint level,
  before the router, so it applies CORS itself.

  ## Security

  This plug implements path traversal protection by validating that the
  resolved file path strictly resides within the configured uploads directory.
  Requests attempting to access files outside this directory (e.g., using `..`)
  will receive a 403 Forbidden response.

  ## Versioned diagram delivery

  Diagram assets written by the versioned pipeline live under the five-segment
  shape `/uploads/diagrams/<organization_id>/<gtfs_version_id>/<station_dir>/<filename>`.
  For that shape the plug validates the organization/version identity and confirms
  the pair is published in the database **before** touching the filesystem, and
  returns 404 for malformed, foreign-organization, staging, importing, or failed
  identities. Historical four-segment
  `/uploads/diagrams/<organization_id>/<station_dir>/<filename>` URLs (and any other
  upload path) keep their existing static-file delivery and CORS behavior.
  """

  import Plug.Conn

  alias GtfsPlanner.Versions

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["uploads" | rest]} = conn, _opts) do
    # Apply the shared CORS policy (echoes allowed origins, answers OPTIONS
    # preflight by halting). For a cross-origin GET it adds the
    # access-control-allow-origin header the browser requires.
    conn = GtfsPlannerWeb.Plugs.CORS.call(conn, [])

    if conn.halted do
      conn
    else
      serve_upload(conn, rest)
    end
  end

  def call(conn, _opts), do: conn

  defp serve_upload(conn, rest) do
    case versioned_diagram_request(rest) do
      {:versioned, organization_id, gtfs_version_id} ->
        # Fail closed: validate the organization/version identity and confirm the
        # pair is published in the database before any filesystem access. A
        # malformed, foreign-organization, staging, importing, or failed identity
        # is denied with 404 exactly like a missing resource.
        if Versions.published_gtfs_version_for_org?(organization_id, gtfs_version_id) do
          serve_static_upload(conn, rest)
        else
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(404, "Not Found")
          |> halt()
        end

      :legacy ->
        serve_static_upload(conn, rest)
    end
  end

  # The versioned diagram grammar is exactly five segments after `uploads`:
  # `diagrams/<organization_id>/<gtfs_version_id>/<station_dir>/<filename>`. A real
  # organization id is a UUID, so a five-segment diagram path whose organization
  # segment is a UUID is treated as versioned and gated by publication state. The
  # version segment is validated by the published-version predicate (which fails
  # closed on a non-UUID), so a malformed version id is denied rather than served.
  # Any other shape — including historical four-segment diagram URLs and legacy
  # nested paths whose organization segment is not a UUID — keeps static delivery.
  defp versioned_diagram_request(["diagrams", organization_id, gtfs_version_id, _station, _filename]) do
    case Ecto.UUID.cast(organization_id) do
      {:ok, _} -> {:versioned, organization_id, gtfs_version_id}
      :error -> :legacy
    end
  end

  defp versioned_diagram_request(_rest), do: :legacy

  defp serve_static_upload(conn, rest) do
    uploads_base = Application.fetch_env!(:gtfs_planner, :uploads_path)
    uploads_base_expanded = Path.expand(uploads_base)

    file_path = Path.join([uploads_base | rest])
    file_path_expanded = Path.expand(file_path)

    cond do
      not String.starts_with?(file_path_expanded, uploads_base_expanded <> "/") and
          file_path_expanded != uploads_base_expanded ->
        # Path traversal attempt detected
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Forbidden")
        |> halt()

      File.regular?(file_path_expanded) ->
        conn
        |> put_field_capture_headers(rest)
        |> send_file(200, file_path_expanded)
        |> halt()

      true ->
        conn
    end
  end

  # Field captures are the only files whose type and cache lifetime are a
  # public API contract. Existing diagram and other upload delivery keeps its
  # historical behavior, while this strict grammar prevents a filename from
  # selecting headers for an arbitrary file under the uploads root.
  defp put_field_capture_headers(conn, ["field-captures", organization_id, station_dir, filename]) do
    case field_capture_type(organization_id, station_dir, filename) do
      {:ok, content_type} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("x-content-type-options", "nosniff")

      :error ->
        conn
    end
  end

  defp put_field_capture_headers(conn, _rest), do: conn

  defp field_capture_type(organization_id, station_dir, filename) do
    with true <- safe_component?(organization_id),
         true <- safe_component?(station_dir),
         [id, extension] <- String.split(filename, ".", parts: 2),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         content_type when is_binary(content_type) <- extension_type(extension) do
      {:ok, content_type}
    else
      _ -> :error
    end
  end

  defp safe_component?(value),
    do: GtfsPlanner.Gtfs.Extensions.PathSafety.safe_path_component?(value)

  defp extension_type("jpg"), do: "image/jpeg"
  defp extension_type("png"), do: "image/png"
  defp extension_type(_extension), do: nil
end
