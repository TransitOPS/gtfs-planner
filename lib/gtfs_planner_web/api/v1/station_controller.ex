defmodule GtfsPlannerWeb.Api.V1.StationController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Api.V1.JournalJSON
  alias GtfsPlannerWeb.Endpoint

  @default_page 1
  @default_per_page 25
  @max_per_page 100

  @doc "GET /api/v1/versions/:version_id/stations — list stations with counts."
  def index(conn, %{"version_id" => version_id} = params) do
    org_id = conn.assigns[:current_organization_id]

    with {:ok, _} <- Ecto.UUID.cast(version_id),
         %{} = _version <- Versions.get_published_gtfs_version_for_org(org_id, version_id) do
      search = params["search"]
      page = parse_page(params)
      per_page = parse_per_page(params)

      list_opts = [search: search, page: page, per_page: per_page, location_type: 1]
      count_opts = [search: search, location_type: 1]

      stations = Gtfs.list_stations(org_id, version_id, list_opts)
      total = Gtfs.count_stations(org_id, version_id, count_opts)

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

      json(conn, %{data: data, meta: %{total: total, page: page, per_page: per_page}})
    else
      :error ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "bad_request", message: "Invalid version ID."}})

      nil ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "not_found", message: "Version not found."}})
    end
  end

  @doc "GET /api/v1/versions/:version_id/stations/:station_id/bundle — full station data bundle."
  def bundle(conn, %{"version_id" => version_id, "station_id" => station_id}) do
    org_id = conn.assigns[:current_organization_id]

    with {:ok, _} <- Ecto.UUID.cast(version_id),
         {:ok, _} <- Ecto.UUID.cast(station_id),
         %{} = _version <- Versions.get_published_gtfs_version_for_org(org_id, version_id),
         %{} = station <- Gtfs.get_stop(station_id),
         true <- station.organization_id == org_id,
         true <- station.gtfs_version_id == version_id,
         true <- station.location_type == 1,
         true <- is_nil(station.parent_station) do
      journal_scope = %Scope{
        organization_id: org_id,
        gtfs_version_id: version_id,
        station_id: station.id,
        station_stop_id: station.stop_id,
        actor_id: conn.assigns.current_user_id
      }

      child_stops = Gtfs.list_child_stops_for_parent(org_id, version_id, station.id)
      levels = Gtfs.list_levels_for_station(org_id, version_id, station.id)
      pathways = Gtfs.list_pathways_for_station(org_id, version_id, station.id)
      journal_entries = Gtfs.list_station_journal(journal_scope)

      entries_by_target =
        Enum.group_by(journal_entries, &entry_target/1, &JournalJSON.entry(&1, journal_scope))

      {station_lat, station_lon} =
        serialize_coordinates(station.stop_lat, station.stop_lon)

      json(conn, %{
        data: %{
          station: %{
            id: station.id,
            stop_id: station.stop_id,
            stop_name: station.stop_name,
            # The station stop's own GTFS coordinates — the canonical station
            # location, present even when no level is aligned. The companion
            # uses this as the camera fallback for geographic views of
            # un-aligned stations.
            lat: station_lat,
            lon: station_lon
          },
          levels:
            Enum.map(
              levels,
              &serialize_level(&1, org_id, station.stop_id, entries_by_target)
            ),
          stops:
            Enum.map(
              child_stops,
              &serialize_stop(&1, Map.get(entries_by_target, {"node", &1.id}, []))
            ),
          pathways:
            Enum.map(
              pathways,
              &serialize_pathway(&1, Map.get(entries_by_target, {"pathway", &1.id}, []))
            ),
          journal_entries: Map.get(entries_by_target, {"station", nil}, []),
          diagrams: [],
          downloaded_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }
      })
    else
      :error ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "bad_request", message: "Invalid ID format."}})

      nil ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "Not found."}})

      false ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "Not found."}})
    end
  end

  defp serialize_level(%{level: level} = level_data, org_id, station_stop_id, entries_by_target) do
    serialize_level(
      level,
      Map.get(level_data, :stop_level),
      org_id,
      station_stop_id,
      entries_by_target
    )
  end

  defp serialize_level(%{id: _} = level, stop_level, org_id, station_stop_id, entries_by_target) do
    stop_level_id = stop_level_id(stop_level)

    %{
      id: level.id,
      level_id: level.level_id,
      level_index: level.level_index,
      level_name: level.level_name,
      stop_level_id: stop_level_id,
      floorplan: serialize_floorplan(stop_level, org_id, station_stop_id),
      journal_entries: Map.get(entries_by_target, {"pin", stop_level_id}, [])
    }
  end

  defp stop_level_id(%StopLevel{id: id}), do: id
  defp stop_level_id(_stop_level), do: nil

  # The diagram image is the primary spatial artifact, so emit the floorplan
  # whenever a level has an image — independent of geographic alignment. The
  # alignment transform (center/scale/rotation) is optional enrichment: present
  # together only when the alignment is complete, otherwise all four are null
  # (the client then renders the image in diagram space). See the companion app's
  # specs/principles.md "Diagram is primary, geo-alignment is enrichment".
  # Null is emitted only when there is no image, or its URL can't be built.
  defp serialize_floorplan(
         %StopLevel{diagram_filename: filename} = stop_level,
         org_id,
         station_stop_id
       )
       when is_binary(filename) and filename != "" do
    case floorplan_url(org_id, station_stop_id, filename) do
      nil ->
        nil

      url ->
        aligned? = StopLevel.alignment_complete?(stop_level)

        %{
          filename: filename,
          url: url,
          center_lat: if(aligned?, do: stop_level.floorplan_center_lat),
          center_lon: if(aligned?, do: stop_level.floorplan_center_lon),
          scale_mpp: if(aligned?, do: stop_level.floorplan_scale_mpp),
          rotation_deg: if(aligned?, do: stop_level.floorplan_rotation_deg)
        }
    end
  end

  defp serialize_floorplan(_stop_level, _org_id, _station_stop_id), do: nil

  # Floorplan images are served as static files under /uploads (see UploadsPlug),
  # not via an /api/v1 endpoint. Return an absolute URL the client can GET directly.
  defp floorplan_url(org_id, station_stop_id, filename) do
    case PathSafety.stop_storage_dir(station_stop_id) do
      dir when is_binary(dir) ->
        encoded_filename = URI.encode(filename, &URI.char_unreserved?/1)

        "#{Endpoint.url()}/uploads/diagrams/#{org_id}/#{dir}/#{encoded_filename}"

      _ ->
        nil
    end
  end

  defp serialize_stop(stop, journal_entries) do
    {lat, lon} = serialize_coordinates(stop.stop_lat, stop.stop_lon)

    %{
      id: stop.id,
      stop_id: stop.stop_id,
      stop_name: stop.stop_name,
      location_type: stop.location_type,
      level_id: stop.level_id,
      parent_station: stop.parent_station,
      wheelchair_boarding: stop.wheelchair_boarding,
      platform_code: stop.platform_code,
      diagram_coordinate: stop.diagram_coordinate,
      lat: lat,
      lon: lon,
      journal_entries: journal_entries
    }
  end

  defp serialize_coordinates(nil, _lon), do: {nil, nil}
  defp serialize_coordinates(_lat, nil), do: {nil, nil}
  defp serialize_coordinates(lat, lon), do: {decimal_to_number(lat), decimal_to_number(lon)}

  defp decimal_to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_number(nil), do: nil
  defp decimal_to_number(n) when is_number(n), do: n

  defp parse_page(params) do
    case params["page"] do
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, ""} when n >= 1 -> n
          {n, ""} when n < 1 -> @default_page
          _ -> @default_page
        end

      _ ->
        @default_page
    end
  end

  defp parse_per_page(params) do
    case params["per_page"] do
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, ""} when n < 1 -> @default_per_page
          {n, ""} when n > @max_per_page -> @max_per_page
          {n, ""} -> n
          _ -> @default_per_page
        end

      _ ->
        @default_per_page
    end
  end

  defp serialize_pathway(pathway, journal_entries) do
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
      field_completed_at: pathway.field_completed_at,
      journal_entries: journal_entries
    }
  end

  defp entry_target(%{target_type: "pin", stop_level_id: stop_level_id}),
    do: {"pin", stop_level_id}

  defp entry_target(%{target_type: target_type, target_id: target_id}),
    do: {target_type, target_id}
end
