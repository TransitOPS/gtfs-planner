defmodule GtfsPlanner.Gtfs.Extensions.Import do
  @moduledoc """
  Imports non-standard GTFS extension data from a decoded manifest and image binaries.

  Must be called **after** standard GTFS Phase 1 + Phase 2 imports complete,
  so that referenced stops, levels, and routes already exist.
  """

  import Ecto.Query

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.{Stop, StopLevel, Level, Route}
  alias GtfsPlanner.Gtfs.Extensions.Manifest

  require Logger

  @doc """
  Imports extensions data from manifest JSON and image binaries.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version
    - `manifest_json` - raw JSON binary of `_pathways_extensions.json`
    - `image_files_by_zip_path` - map of `%{zip_path => binary}`
    - `opts` - reserved for future use

  ## Returns

    - `{:ok, counts}` with keys `:extensions_stop_coordinates`, `:extensions_stop_levels`,
      `:extensions_route_flags`, `:extensions_images`
    - `{:error, reason}`
  """
  def import_extensions(organization_id, gtfs_version_id, manifest_json, image_files_by_zip_path, _opts \\ []) do
    with {:ok, manifest} <- Manifest.decode(manifest_json),
         lookups <- build_lookups(organization_id, gtfs_version_id),
         :ok <- validate_references(manifest, lookups) do
      apply_db_writes(organization_id, gtfs_version_id, manifest, lookups, image_files_by_zip_path)
    end
  end

  # -- lookup maps ------------------------------------------------------------

  defp build_lookups(organization_id, gtfs_version_id) do
    %{
      stop_id_to_uuid: build_lookup(Stop, :stop_id, organization_id, gtfs_version_id),
      level_id_to_uuid: build_lookup(Level, :level_id, organization_id, gtfs_version_id),
      route_id_to_uuid: build_lookup(Route, :route_id, organization_id, gtfs_version_id)
    }
  end

  defp build_lookup(schema, id_field, organization_id, gtfs_version_id) do
    schema
    |> where([r], r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id)
    |> select([r], {field(r, ^id_field), r.id})
    |> Repo.all()
    |> Map.new()
  end

  # -- reference validation ---------------------------------------------------

  defp validate_references(manifest, lookups) do
    missing_stops =
      (manifest.stop_diagram_coordinates |> Enum.map(& &1.stop_id)) ++
        (manifest.stop_levels |> Enum.map(& &1.stop_id))
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(lookups.stop_id_to_uuid, &1))

    missing_levels =
      manifest.stop_levels
      |> Enum.map(& &1.level_id)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(lookups.level_id_to_uuid, &1))

    missing_routes =
      manifest.route_active_flags
      |> Enum.map(& &1.route_id)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(lookups.route_id_to_uuid, &1))

    missing =
      %{}
      |> maybe_put(:stops, missing_stops)
      |> maybe_put(:levels, missing_levels)
      |> maybe_put(:routes, missing_routes)

    if map_size(missing) == 0 do
      :ok
    else
      {:error, {:missing_references, missing}}
    end
  end

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, list), do: Map.put(map, key, list)

  # -- DB writes in transaction -----------------------------------------------

  defp apply_db_writes(organization_id, gtfs_version_id, manifest, lookups, image_files_by_zip_path) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        coord_count = update_stop_coordinates(manifest.stop_diagram_coordinates, lookups)
        sl_count = upsert_stop_levels(organization_id, gtfs_version_id, manifest.stop_levels, lookups, now)
        flag_count = update_route_flags(manifest.route_active_flags, lookups)

        %{
          extensions_stop_coordinates: coord_count,
          extensions_stop_levels: sl_count,
          extensions_route_flags: flag_count
        }
      end)

    case result do
      {:ok, counts} ->
        image_count = restore_images(organization_id, manifest.diagram_images, image_files_by_zip_path)
        {:ok, Map.put(counts, :extensions_images, image_count)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_stop_coordinates(coords, lookups) do
    Enum.count(coords, fn %{stop_id: stop_id, diagram_coordinate: coord} ->
      uuid = Map.fetch!(lookups.stop_id_to_uuid, stop_id)

      {count, _} =
        from(s in Stop, where: s.id == ^uuid)
        |> Repo.update_all(set: [diagram_coordinate: coord, updated_at: DateTime.utc_now()])

      count > 0
    end)
  end

  defp upsert_stop_levels(organization_id, gtfs_version_id, stop_levels, lookups, now) do
    Enum.count(stop_levels, fn sl ->
      stop_uuid = Map.fetch!(lookups.stop_id_to_uuid, sl.stop_id)
      level_uuid = Map.fetch!(lookups.level_id_to_uuid, sl.level_id)

      attrs = %{
        stop_id: stop_uuid,
        level_id: level_uuid,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        diagram_filename: sl.diagram_filename,
        scale_point_a: sl.scale_point_a,
        scale_point_b: sl.scale_point_b,
        scale_distance_meters: parse_decimal(sl.scale_distance_meters),
        scale_meters_per_unit: parse_decimal(sl.scale_meters_per_unit),
        inserted_at: now,
        updated_at: now
      }

      Repo.insert!(
        StopLevel.changeset(%StopLevel{}, attrs),
        on_conflict: [
          set: [
            diagram_filename: sl.diagram_filename,
            scale_point_a: sl.scale_point_a,
            scale_point_b: sl.scale_point_b,
            scale_distance_meters: parse_decimal(sl.scale_distance_meters),
            scale_meters_per_unit: parse_decimal(sl.scale_meters_per_unit),
            updated_at: now
          ]
        ],
        conflict_target: [:organization_id, :gtfs_version_id, :stop_id, :level_id]
      )

      true
    end)
  end

  defp update_route_flags(flags, lookups) do
    Enum.count(flags, fn %{route_id: route_id, active: active} ->
      uuid = Map.fetch!(lookups.route_id_to_uuid, route_id)

      {count, _} =
        from(r in Route, where: r.id == ^uuid)
        |> Repo.update_all(set: [active: active, updated_at: DateTime.utc_now()])

      count > 0
    end)
  end

  # -- image restore ----------------------------------------------------------

  defp restore_images(organization_id, diagram_images, image_files_by_zip_path) do
    uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)

    Enum.count(diagram_images, fn entry ->
      case Map.fetch(image_files_by_zip_path, entry.zip_path) do
        {:ok, binary} ->
          dest_dir =
            Path.join([uploads_path, "diagrams", organization_id, entry.station_stop_id])

          dest_path = Path.join(dest_dir, entry.filename)

          case File.mkdir_p(dest_dir) do
            :ok ->
              case File.write(dest_path, binary) do
                :ok ->
                  true

                {:error, reason} ->
                  Logger.warning("Extensions import: failed to write image #{dest_path}: #{inspect(reason)}")
                  false
              end

            {:error, reason} ->
              Logger.warning("Extensions import: failed to create directory #{dest_dir}: #{inspect(reason)}")
              false
          end

        :error ->
          Logger.warning("Extensions import: missing image binary for #{entry.zip_path}")
          false
      end
    end)
  end

  # -- helpers ----------------------------------------------------------------

  defp parse_decimal(nil), do: nil
  defp parse_decimal(val) when is_binary(val), do: Decimal.new(val)
  defp parse_decimal(%Decimal{} = d), do: d
end
