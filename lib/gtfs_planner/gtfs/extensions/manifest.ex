defmodule GtfsPlanner.Gtfs.Extensions.Manifest do
  @moduledoc """
  Encodes and decodes the `_pathways_extensions.json` manifest
  used to round-trip non-standard GTFS extension data.
  """

  @current_version 1

  @doc """
  Builds a manifest map from the four extension data lists.
  """
  def build(stop_diagram_coordinates, stop_levels, route_active_flags, diagram_images) do
    %{
      version: @current_version,
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      stop_diagram_coordinates: stop_diagram_coordinates,
      stop_levels: stop_levels,
      route_active_flags: route_active_flags,
      diagram_images: diagram_images
    }
  end

  @doc """
  Encodes a manifest map to a JSON binary.
  """
  def encode(manifest) when is_map(manifest) do
    Jason.encode!(manifest, pretty: true)
  end

  @doc """
  Decodes a JSON binary into a validated manifest with atom keys.

  Returns `{:ok, manifest}` or `{:error, reason}`.
  """
  def decode(json) when is_binary(json) do
    with {:ok, raw} <- Jason.decode(json),
         :ok <- validate_version(raw) do
      {:ok, normalize(raw)}
    end
  end

  def decode(_), do: {:error, :invalid_manifest}

  # -- private ----------------------------------------------------------------

  defp validate_version(%{"version" => @current_version}), do: :ok
  defp validate_version(%{"version" => v}), do: {:error, {:unsupported_version, v}}
  defp validate_version(_), do: {:error, :missing_version}

  defp normalize(raw) do
    %{
      version: raw["version"],
      exported_at: raw["exported_at"],
      stop_diagram_coordinates: normalize_coordinates(raw["stop_diagram_coordinates"] || []),
      stop_levels: normalize_stop_levels(raw["stop_levels"] || []),
      route_active_flags: normalize_route_flags(raw["route_active_flags"] || []),
      diagram_images: normalize_images(raw["diagram_images"] || [])
    }
  end

  defp normalize_coordinates(list) when is_list(list) do
    Enum.map(list, fn entry ->
      %{
        stop_id: entry["stop_id"],
        diagram_coordinate: normalize_point(entry["diagram_coordinate"])
      }
    end)
  end

  defp normalize_stop_levels(list) when is_list(list) do
    Enum.map(list, fn entry ->
      %{
        stop_id: entry["stop_id"],
        level_id: entry["level_id"],
        diagram_filename: entry["diagram_filename"],
        scale_point_a: normalize_point(entry["scale_point_a"]),
        scale_point_b: normalize_point(entry["scale_point_b"]),
        scale_distance_meters: entry["scale_distance_meters"],
        scale_meters_per_unit: entry["scale_meters_per_unit"]
      }
    end)
  end

  defp normalize_route_flags(list) when is_list(list) do
    Enum.map(list, fn entry ->
      %{route_id: entry["route_id"], active: entry["active"]}
    end)
  end

  defp normalize_images(list) when is_list(list) do
    Enum.map(list, fn entry ->
      %{
        station_stop_id: entry["station_stop_id"],
        filename: entry["filename"],
        zip_path: entry["zip_path"]
      }
    end)
  end

  defp normalize_point(%{"x" => x, "y" => y}), do: %{x: x, y: y}
  defp normalize_point(nil), do: nil
  defp normalize_point(_), do: nil
end
