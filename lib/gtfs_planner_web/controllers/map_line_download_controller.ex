defmodule GtfsPlannerWeb.MapLineDownloadController do
  @moduledoc """
  Serves one pattern's, or a whole route's, map lines as a downloadable file.

  `GET /gtfs/:version/routes/:route_id/map-lines?pattern=<route_pattern_id>|all&format=geojson|kml`
  is authenticated and organization- and version-scoped like every other
  `/gtfs` download: the version must be published for the requesting
  organization, the route and pattern must belong to that version, and
  anything else is the same plain 404. The bytes come from
  `GtfsPlanner.Gtfs.Alignments.line_file/4` written by
  `GtfsPlanner.Gtfs.MapLineFiles.encode/2`, so a line is never drawn across a
  missing or blocked section (AC-27).
  """

  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.MapLineFiles
  alias GtfsPlanner.Versions

  @not_found_body "Not Found"

  @formats %{
    "geojson" => {:geojson, "geojson", "application/geo+json"},
    "kml" => {:kml, "kml", "application/vnd.google-earth.kml+xml"}
  }

  def show(conn, %{"version" => version_id, "route_id" => route_id} = params) do
    organization_id = conn.assigns.current_organization.id
    pattern = params["pattern"] || "all"

    with {:ok, {format, extension, content_type}} <- requested_format(params["format"]),
         {:ok, version_id} <- Ecto.UUID.cast(version_id),
         true <- Versions.published_gtfs_version_for_org?(organization_id, version_id),
         {:ok, file} <- Alignments.line_file(organization_id, version_id, route_id, pattern),
         {:ok, body} <- MapLineFiles.encode(format, file) do
      send_download(
        conn,
        {:binary, body},
        filename: "#{safe_name(route_id)}-#{safe_name(pattern)}.#{extension}",
        content_type: content_type
      )
    else
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  defp requested_format(format) when is_binary(format) do
    case Map.fetch(@formats, String.downcase(format)) do
      {:ok, found} -> {:ok, found}
      :error -> :error
    end
  end

  defp requested_format(_format), do: :error

  # The route and pattern IDs are GTFS strings, so a name that could end the
  # content-disposition header or a path segment is reduced to a safe form
  # rather than being written raw.
  defp safe_name(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "map-lines"
      safe -> safe
    end
  end

  defp safe_name(_value), do: "map-lines"

  defp not_found(conn), do: send_resp(conn, 404, @not_found_body)
end
