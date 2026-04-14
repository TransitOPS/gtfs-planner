defmodule GtfsPlannerWeb.Api.V1.StationController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  @doc "GET /api/v1/versions/:version_id/stations — list stations with counts."
  def index(conn, %{"version_id" => version_id}) do
    org_id = conn.assigns[:current_organization_id]

    # Verify version belongs to org
    case Versions.get_gtfs_version(version_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "Version not found."}})

      version ->
        if version.organization_id != org_id do
          conn |> put_status(403) |> json(%{error: %{code: "forbidden", message: "Access denied."}})
        else
          stations = Gtfs.list_stations(org_id, version_id)

          data =
            Enum.map(stations, fn station ->
              child_stops = Gtfs.list_child_stops_for_parent(org_id, version_id, station.id)
              levels = Gtfs.list_levels_for_station(org_id, version_id, station.id)
              pathways = Gtfs.list_pathways_for_station(org_id, version_id, station.id)

              %{
                id: station.id,
                stop_id: station.stop_id,
                stop_name: station.stop_name,
                child_stop_count: length(child_stops),
                pathway_count: length(pathways),
                level_count: length(levels)
              }
            end)

          json(conn, %{data: data})
        end
    end
  end

  @doc "GET /api/v1/versions/:version_id/stations/:id/bundle — full station data bundle."
  def bundle(conn, %{"version_id" => version_id, "id" => station_id}) do
    org_id = conn.assigns[:current_organization_id]

    # Verify version belongs to org
    case Versions.get_gtfs_version(version_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "Version not found."}})

      version ->
        if version.organization_id != org_id do
          conn |> put_status(403) |> json(%{error: %{code: "forbidden", message: "Access denied."}})
        else
          case Gtfs.get_stop(station_id) do
            nil ->
              conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "Station not found."}})

            station when station.organization_id != org_id ->
              conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "Station not found."}})

            station ->
              child_stops = Gtfs.list_child_stops_for_parent(org_id, version_id, station.id)
              levels = Gtfs.list_levels_for_station(org_id, version_id, station.id)
              pathways = Gtfs.list_pathways_for_station(org_id, version_id, station.id)

              json(conn, %{
                data: %{
                  station: %{
                    id: station.id,
                    stop_id: station.stop_id,
                    stop_name: station.stop_name
                  },
                  levels: Enum.map(levels, &serialize_level/1),
                  stops: Enum.map(child_stops, &serialize_stop/1),
                  pathways: Enum.map(pathways, &serialize_pathway/1),
                  diagrams: [],
                  downloaded_at: DateTime.utc_now()
                }
              })
          end
        end
    end
  end

  defp serialize_level(%{level: level}) do
    serialize_level(level)
  end

  defp serialize_level(%{id: _} = level) do
    %{
      id: level.id,
      level_id: level.level_id,
      level_index: level.level_index,
      level_name: level.level_name
    }
  end

  defp serialize_stop(stop) do
    %{
      id: stop.id,
      stop_id: stop.stop_id,
      stop_name: stop.stop_name,
      location_type: stop.location_type,
      level_id: stop.level_id,
      parent_station: stop.parent_station,
      wheelchair_boarding: stop.wheelchair_boarding,
      platform_code: stop.platform_code,
      diagram_coordinate: stop.diagram_coordinate
    }
  end

  defp serialize_pathway(pathway) do
    %{
      id: pathway.id,
      pathway_id: pathway.pathway_id,
      pathway_mode: pathway.pathway_mode,
      is_bidirectional: pathway.is_bidirectional,
      from_stop_id: pathway.from_stop_id,
      to_stop_id: pathway.to_stop_id,
      length: pathway.length,
      traversal_time: pathway.traversal_time,
      stair_count: pathway.stair_count,
      max_slope: pathway.max_slope,
      min_width: pathway.min_width,
      signposted_as: pathway.signposted_as,
      reversed_signposted_as: pathway.reversed_signposted_as,
      field_notes: pathway.field_notes,
      field_completed_at: pathway.field_completed_at
    }
  end
end
