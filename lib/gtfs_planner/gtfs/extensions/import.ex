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
  alias GtfsPlanner.Gtfs.DiagramStorage

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
    - `{:error, reason}` when the manifest cannot be decoded, references are
      missing, or the extension database transaction rolls back (no extension
      writes are durable)
    - `{:error, reason, committed_counts}` when the extension database transaction
      committed but image restoration failed afterward. `committed_counts` carries
      the durable `:extensions_stop_coordinates`, `:extensions_stop_levels`,
      `:extensions_route_flags`, and `:extensions_images` (files written before
      the failure) counts.
  """
  def import_extensions(
        organization_id,
        gtfs_version_id,
        manifest_json,
        image_files_by_zip_path,
        _opts \\ []
      ) do
    with {:ok, manifest} <- Manifest.decode(manifest_json),
         lookups <- build_lookups(organization_id, gtfs_version_id),
         :ok <- validate_references(manifest, lookups) do
      apply_db_writes(
        organization_id,
        gtfs_version_id,
        manifest,
        lookups,
        image_files_by_zip_path
      )
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
    expected_image_pairs = expected_image_pairs(manifest.stop_levels)
    image_pairs = diagram_image_pairs(manifest.diagram_images)

    missing_stops =
      ((manifest.stop_diagram_coordinates |> Enum.map(& &1.stop_id)) ++
         (manifest.stop_levels |> Enum.map(& &1.stop_id)) ++
         (manifest.diagram_images |> Enum.map(& &1.station_stop_id)))
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

    invalid_diagram_images =
      image_pairs
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(expected_image_pairs, &1))
      |> Enum.map(fn {station_stop_id, filename} ->
        %{station_stop_id: station_stop_id, filename: filename}
      end)

    missing =
      %{}
      |> maybe_put(:stops, missing_stops)
      |> maybe_put(:levels, missing_levels)
      |> maybe_put(:routes, missing_routes)
      |> maybe_put(:diagram_images, invalid_diagram_images)

    if map_size(missing) == 0 do
      :ok
    else
      {:error, {:missing_references, missing}}
    end
  end

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, list), do: Map.put(map, key, list)

  defp expected_image_pairs(stop_levels) do
    stop_levels
    |> Enum.filter(&(is_binary(&1.diagram_filename) and &1.diagram_filename != ""))
    |> Enum.map(&{&1.stop_id, &1.diagram_filename})
    |> MapSet.new()
  end

  defp diagram_image_pairs(diagram_images) do
    Enum.map(diagram_images, &{&1.station_stop_id, &1.filename})
  end

  # -- DB writes in transaction -----------------------------------------------

  defp apply_db_writes(
         organization_id,
         gtfs_version_id,
         manifest,
         lookups,
         image_files_by_zip_path
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        coord_count = update_stop_coordinates(manifest.stop_diagram_coordinates, lookups)

        sl_count =
          upsert_stop_levels(organization_id, gtfs_version_id, manifest.stop_levels, lookups, now)

        flag_count = update_route_flags(manifest.route_active_flags, lookups)

        %{
          extensions_stop_coordinates: coord_count,
          extensions_stop_levels: sl_count,
          extensions_route_flags: flag_count
        }
      end)

    case result do
      {:ok, counts} ->
        # Image writes happen AFTER the extension DB transaction commits, so the
        # DB counts are already durable here. `restore_images/4` reports how many
        # image files it wrote, so a mid-restore failure still returns the exact
        # committed extension counts (INV-3, AC-3).
        {written, image_result} =
          restore_images(
            organization_id,
            gtfs_version_id,
            manifest.diagram_images,
            image_files_by_zip_path
          )

        committed = Map.put(counts, :extensions_images, written)

        case image_result do
          :ok ->
            {:ok, committed}

          {:error, reason} ->
            {:error, {:image_restore_failed, reason}, committed}
        end

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

  # Returns `{files_written, :ok | {:error, reason}}`. The count is the number of
  # image files successfully written before any failure, so callers can report the
  # exact durable image count even when restoration stops midway.
  defp restore_images(
         organization_id,
         gtfs_version_id,
         diagram_images,
         image_files_by_zip_path
       ) do
    Enum.reduce_while(diagram_images, {0, :ok}, fn entry, {written, :ok} ->
      case Map.fetch(image_files_by_zip_path, entry.zip_path) do
        {:ok, binary} ->
          case DiagramStorage.store_import_image(
                 organization_id,
                 gtfs_version_id,
                 entry.station_stop_id,
                 entry.filename,
                 binary
               ) do
            :ok ->
              {:cont, {written + 1, :ok}}

            {:error, reason} ->
              {:halt, {written, {:error, {:write_failed, entry.zip_path, reason}}}}
          end

        :error ->
          {:halt, {written, {:error, {:missing_binary, entry.zip_path}}}}
      end
    end)
  end

  # -- helpers ----------------------------------------------------------------

  defp parse_decimal(nil), do: nil

  defp parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {decimal, ""} ->
        decimal

      {decimal, rest} ->
        Logger.warning(
          "Extensions import: decimal value #{inspect(val)} has unparsed remainder #{inspect(rest)}, skipping"
        )

        decimal

      :error ->
        Logger.warning(
          "Extensions import: invalid decimal value #{inspect(val)} in manifest, skipping"
        )

        nil
    end
  end

  defp parse_decimal(%Decimal{} = d), do: d
end
