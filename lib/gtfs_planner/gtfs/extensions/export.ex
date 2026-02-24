defmodule GtfsPlanner.Gtfs.Extensions.Export do
  @moduledoc """
  Builds zip entries for `_pathways_extensions.json` and diagram images.

  Returns `{:ok, [{charlist(), binary()}]}` suitable for appending to
  the standard GTFS zip entries before `:zip.create/3`.
  """

  import Ecto.Query

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.{Stop, StopLevel, Level, Route}
  alias GtfsPlanner.Gtfs.Extensions.Manifest

  require Logger

  @doc """
  Builds zip entries for extensions data.

  Returns `{:ok, entries}` where entries is a list of `{charlist_path, binary_content}` tuples,
  or `{:ok, []}` when no extensions data exists.
  """
  def build_zip_entries(organization_id, gtfs_version_id) do
    coords = query_stop_diagram_coordinates(organization_id, gtfs_version_id)
    stop_levels = query_stop_levels(organization_id, gtfs_version_id)
    route_flags = query_route_active_flags(organization_id, gtfs_version_id)

    if coords == [] and stop_levels == [] and route_flags == [] do
      {:ok, []}
    else
      image_manifest_entries = build_image_manifest(stop_levels)
      image_zip_entries = collect_image_entries(organization_id, image_manifest_entries)

      manifest =
        Manifest.build(coords, stop_levels, route_flags, image_manifest_entries)
        |> Manifest.encode()

      manifest_entry = {~c"_pathways_extensions.json", manifest}
      {:ok, [manifest_entry | image_zip_entries]}
    end
  end

  # -- DB queries -------------------------------------------------------------

  defp query_stop_diagram_coordinates(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          not is_nil(s.diagram_coordinate),
      select: {s.stop_id, s.diagram_coordinate},
      order_by: s.stop_id
    )
    |> Repo.all()
    |> Enum.map(fn {stop_id, coord} ->
      %{stop_id: stop_id, diagram_coordinate: normalize_coord(coord)}
    end)
  end

  defp query_stop_levels(organization_id, gtfs_version_id) do
    from(sl in StopLevel,
      join: s in Stop,
      on: sl.stop_id == s.id,
      join: l in Level,
      on: sl.level_id == l.id,
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id,
      select: %{
        stop_id: s.stop_id,
        level_id: l.level_id,
        diagram_filename: sl.diagram_filename,
        scale_point_a: sl.scale_point_a,
        scale_point_b: sl.scale_point_b,
        scale_distance_meters: sl.scale_distance_meters,
        scale_meters_per_unit: sl.scale_meters_per_unit
      },
      order_by: [s.stop_id, l.level_id]
    )
    |> Repo.all()
    |> Enum.map(&serialize_stop_level/1)
  end

  defp query_route_active_flags(organization_id, gtfs_version_id) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and
          r.gtfs_version_id == ^gtfs_version_id and
          r.active == false,
      select: {r.route_id, r.active},
      order_by: r.route_id
    )
    |> Repo.all()
    |> Enum.map(fn {route_id, active} ->
      %{route_id: route_id, active: active}
    end)
  end

  # -- serialization helpers --------------------------------------------------

  defp serialize_stop_level(sl) do
    %{
      stop_id: sl.stop_id,
      level_id: sl.level_id,
      diagram_filename: sl.diagram_filename,
      scale_point_a: normalize_coord(sl.scale_point_a),
      scale_point_b: normalize_coord(sl.scale_point_b),
      scale_distance_meters: decimal_to_string(sl.scale_distance_meters),
      scale_meters_per_unit: decimal_to_string(sl.scale_meters_per_unit)
    }
  end

  defp normalize_coord(%{"x" => x, "y" => y}), do: %{x: x, y: y}
  defp normalize_coord(%{x: _, y: _} = c), do: c
  defp normalize_coord(nil), do: nil

  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(nil), do: nil

  # -- image entries ----------------------------------------------------------

  defp build_image_manifest(stop_levels) do
    stop_levels
    |> Enum.filter(&(&1.diagram_filename != nil))
    |> Enum.map(fn sl ->
      %{
        station_stop_id: sl.stop_id,
        filename: sl.diagram_filename,
        zip_path: "_pathways_extensions/diagrams/#{sl.stop_id}/#{sl.diagram_filename}"
      }
    end)
  end

  defp collect_image_entries(organization_id, image_manifest_entries) do
    uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)

    Enum.flat_map(image_manifest_entries, fn entry ->
      disk_path =
        Path.join([
          uploads_path,
          "diagrams",
          organization_id,
          entry.station_stop_id,
          entry.filename
        ])

      case File.read(disk_path) do
        {:ok, binary} ->
          [{String.to_charlist(entry.zip_path), binary}]

        {:error, reason} ->
          Logger.warning("Extensions export: skipping image #{disk_path}: #{inspect(reason)}")

          []
      end
    end)
  end
end
