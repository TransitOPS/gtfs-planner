defmodule GtfsPlannerWeb.Api.V1.LevelAlignmentController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Endpoint

  @doc """
  PUT /api/v1/versions/:version_id/stations/:station_id/levels/:level_id/alignment

  Writes a level's floorplan alignment and atomically re-imputes geographic
  coordinates for the level's diagram-positioned nodes — the companion-app
  counterpart of the desktop Map tab's save-and-apply. Semantics are the
  manual-alignment convention (`center_lat`/`center_lon` = painted image
  center, `scale_mpp` = meters per natural image pixel, rotation clockwise
  about the center).

  Returns the updated level (with its floorplan) plus the re-imputed node
  coordinates so the client can update its local DB surgically (no station
  re-download). Contract: the companion app's `specs/api/level-alignment.md`.
  """
  def update(conn, %{
        "version_id" => version_id,
        "station_id" => station_id,
        "level_id" => level_id,
        "alignment" => alignment_params,
        "image_w" => image_w,
        "image_h" => image_h
      }) do
    org_id = conn.assigns[:current_organization_id]

    with {:ok, _} <- cast_uuid(version_id),
         {:ok, _} <- cast_uuid(station_id),
         {:ok, _} <- cast_uuid(level_id),
         %{} = version <- Versions.get_gtfs_version(version_id),
         true <- version.organization_id == org_id,
         %{} = station <- Gtfs.get_stop(station_id),
         true <- station.organization_id == org_id and station.gtfs_version_id == version_id,
         %{} = stop_level <- Gtfs.get_stop_level(org_id, version_id, station_id, level_id) do
      cond do
        is_nil(stop_level.diagram_filename) or stop_level.diagram_filename == "" ->
          error(conn, 422, "no_diagram", "The level has no diagram image to align.")

        not valid_alignment?(alignment_params) or not valid_dims?(image_w, image_h) ->
          error(conn, 422, "invalid_alignment", "Alignment values or image dimensions invalid.")

        true ->
          attrs = %{
            floorplan_center_lat: alignment_params["center_lat"],
            floorplan_center_lon: alignment_params["center_lon"],
            floorplan_scale_mpp: alignment_params["scale_mpp"],
            floorplan_rotation_deg: alignment_params["rotation_deg"]
          }

          case Gtfs.save_and_apply_stop_level_alignment(stop_level.id, attrs, image_w, image_h) do
            {:ok, %{active_stop_level: updated, updated_stops: stops}} ->
              level = Gtfs.get_level(level_id)

              json(conn, %{
                data: %{
                  level: %{
                    id: level.id,
                    level_id: level.level_id,
                    floorplan: serialize_floorplan(updated, org_id, station.stop_id)
                  },
                  stops:
                    Enum.map(stops, fn s ->
                      %{
                        id: s.id,
                        lat: decimal_to_number(s.stop_lat),
                        lon: decimal_to_number(s.stop_lon)
                      }
                    end)
                }
              })

            {:error, _reason} ->
              error(conn, 422, "invalid_alignment", "Alignment could not be applied.")
          end
      end
    else
      _ -> error(conn, 404, "not_found", "Version, station, or level not found.")
    end
  end

  def update(conn, _params) do
    error(
      conn,
      422,
      "invalid_alignment",
      "Request must include 'alignment' (center_lat, center_lon, scale_mpp, rotation_deg), 'image_w', and 'image_h'."
    )
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end

  defp valid_alignment?(%{} = a) do
    lat = a["center_lat"]
    lon = a["center_lon"]
    scale = a["scale_mpp"]
    rotation = a["rotation_deg"]

    is_number(lat) and lat >= -90 and lat <= 90 and
      is_number(lon) and lon >= -180 and lon <= 180 and
      is_number(scale) and scale > 0 and
      is_number(rotation)
  end

  defp valid_alignment?(_), do: false

  defp valid_dims?(w, h), do: is_integer(w) and is_integer(h) and w > 0 and h > 0

  # Mirrors StationController's bundle floorplan serialization (the alignment
  # is always complete here — we just wrote it).
  defp serialize_floorplan(stop_level, org_id, station_stop_id) do
    %{
      filename: stop_level.diagram_filename,
      url: floorplan_url(org_id, station_stop_id, stop_level.diagram_filename),
      center_lat: stop_level.floorplan_center_lat,
      center_lon: stop_level.floorplan_center_lon,
      scale_mpp: stop_level.floorplan_scale_mpp,
      rotation_deg: stop_level.floorplan_rotation_deg
    }
  end

  defp floorplan_url(org_id, station_stop_id, filename) do
    case PathSafety.stop_storage_dir(station_stop_id) do
      dir when is_binary(dir) ->
        encoded_filename = URI.encode(filename, &URI.char_unreserved?/1)
        "#{Endpoint.url()}/uploads/diagrams/#{org_id}/#{dir}/#{encoded_filename}"

      _ ->
        nil
    end
  end

  defp decimal_to_number(nil), do: nil
  defp decimal_to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_number(n) when is_number(n), do: n

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
