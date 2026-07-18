defmodule GtfsPlanner.Gtfs.DiagramStorage do
  @moduledoc """
  Versioned, organization-scoped diagram storage.

  Diagram files live under:

      <uploads_path>/diagrams/<organization_id>/<gtfs_version_id>/<station_dir>/<filename>

  Legacy files (written before versioning) live under:

      <uploads_path>/diagrams/<organization_id>/<station_dir>/<filename>

  The directory is not a visibility signal: the database publication status of the
  GTFS version is the only read gate. This module never renames directories so it
  works on object-backed mounts (e.g. AWS S3 Files) that do not support atomic
  directory moves.
  """

  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Repo

  require Logger

  import Ecto.Query

  @doc """
  Writes an imported diagram image directly into the immutable organization/version
  namespace. Returns `:ok` or `{:error, term()}`.
  """
  @spec store_import_image(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t(), binary()) ::
          :ok | {:error, term()}
  def store_import_image(organization_id, gtfs_version_id, station_stop_id, filename, binary)
      when is_binary(organization_id) and is_binary(gtfs_version_id) and
             is_binary(station_stop_id) and is_binary(filename) and is_binary(binary) do
    with {:ok, org_dir} <- safe_org_dir(organization_id),
         {:ok, station_dir} <- safe_station_dir(station_stop_id),
         {:ok, dest_dir} <- versioned_dir(org_dir, gtfs_version_id, station_dir),
         {:ok, dest_path} <- versioned_path(org_dir, gtfs_version_id, station_dir, filename) do
      case PathSafety.ensure_within_root(org_dir, dest_path) do
        :ok ->
          write_file(dest_dir, dest_path, binary)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def store_import_image(_, _, _, _, _), do: {:error, :badarg}

  @doc """
  Idempotently removes the exact organization/version diagram namespace
  (`<uploads>/diagrams/<organization_id>/<gtfs_version_id>`).

  Both path components are validated against path-traversal, and the version
  directory is verified to be contained within the organization root before any
  removal. A missing namespace returns `:ok` (idempotent). A validation or
  containment error returns `{:error, reason}` and never broadens the path.

  ## Returns

    - `:ok` when the version namespace is absent or was removed
    - `{:error, :unsafe_path}` when an organization or version component is invalid
    - `{:error, :path_traversal}` when the computed directory escapes the org root
  """
  @spec delete_version_namespace(Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :unsafe_path | :path_traversal}
  def delete_version_namespace(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    if PathSafety.safe_path_component?(organization_id) and
         PathSafety.safe_path_component?(gtfs_version_id) do
      org_dir = Path.join([uploads_root(), "diagrams", organization_id])
      version_dir = Path.join([org_dir, gtfs_version_id])

      case PathSafety.ensure_within_root(org_dir, version_dir) do
        :ok ->
          File.rm_rf(version_dir)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unsafe_path}
    end
  end

  def delete_version_namespace(_, _), do: {:error, :badarg}

  @doc """
  Returns the absolute on-disk path of a versioned diagram file, or an error when the
  versioned file does not exist.
  """
  @spec published_path(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def published_path(organization_id, gtfs_version_id, station_stop_id, filename) do
    with {:ok, org_dir} <- safe_org_dir(organization_id),
         {:ok, station_dir} <- safe_station_dir(station_stop_id),
         {:ok, dest_path} <- versioned_path(org_dir, gtfs_version_id, station_dir, filename),
         :ok <- PathSafety.ensure_within_root(org_dir, dest_path) do
      if File.exists?(dest_path) do
        {:ok, dest_path}
      else
        {:error, :not_found}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a public URL for a diagram file. Prefers the versioned file and falls back to
  the legacy historical URL only when a referenced historical file has not yet been copied.
  """
  @spec public_url_path(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def public_url_path(organization_id, gtfs_version_id, station_stop_id, filename) do
    case published_path(organization_id, gtfs_version_id, station_stop_id, filename) do
      {:ok, _path} ->
        {:ok,
         "#{endpoint_url()}/uploads/diagrams/#{organization_id}/#{gtfs_version_id}/#{encoded_station_dir(station_stop_id)}/#{URI.encode(filename, &URI.char_unreserved?/1)}"}

      {:error, :not_found} ->
        case referenced_legacy_path(
               organization_id,
               gtfs_version_id,
               station_stop_id,
               filename
             ) do
          {:ok, _legacy_path} ->
            {:ok, legacy_url(organization_id, station_stop_id, filename)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Copies every legacy diagram file referenced by a published `StopLevel` into each
  referenced versioned destination. Idempotent: an existing versioned file is never
  overwritten, and legacy source files are left in place. Returns
  `{:ok, count}` of copied files, or `{:error, term()}`.
  """
  @spec migrate_legacy_assets(Ecto.Repo.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def migrate_legacy_assets(repo) when is_atom(repo) or is_map(repo) do
    repo.transaction(fn ->
      references = published_diagram_references(repo)

      Enum.reduce(references, 0, fn ref, acc ->
        legacy =
          legacy_path(ref.organization_id, ref.station_stop_id, ref.diagram_filename)

        case legacy do
          {:ok, legacy_path} ->
            if File.exists?(legacy_path) do
              dest =
                versioned_path(
                  org_root(ref.organization_id),
                  ref.gtfs_version_id,
                  PathSafety.stop_storage_dir(ref.station_stop_id),
                  ref.diagram_filename
                )

              case dest do
                {:ok, dest_path} ->
                  if File.exists?(dest_path) do
                    acc
                  else
                    with :ok <- File.mkdir_p(Path.dirname(dest_path)),
                         {:ok, _} <- File.copy(legacy_path, dest_path) do
                      acc + 1
                    else
                      {:error, reason} -> repo.rollback(reason)
                    end
                  end

                _ ->
                  acc
              end
            else
              acc
            end

          _ ->
            acc
        end
      end)
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- path construction -----------------------------------------------------

  defp safe_org_dir(organization_id) do
    if PathSafety.safe_path_component?(organization_id) do
      {:ok, Path.join([uploads_root(), "diagrams", organization_id])}
    else
      {:error, :unsafe_path}
    end
  end

  defp safe_station_dir(station_stop_id) do
    case PathSafety.stop_storage_dir(station_stop_id) do
      dir when is_binary(dir) -> {:ok, dir}
      _ -> {:error, :unsafe_path}
    end
  end

  defp versioned_dir(org_dir, gtfs_version_id, station_dir) do
    if PathSafety.safe_path_component?(gtfs_version_id) do
      dir = Path.join([org_dir, gtfs_version_id, station_dir])

      case PathSafety.ensure_within_root(org_dir, dir) do
        :ok -> {:ok, dir}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unsafe_path}
    end
  end

  defp versioned_path(org_dir, gtfs_version_id, station_dir, filename) do
    if PathSafety.safe_path_component?(gtfs_version_id) and
         PathSafety.safe_path_component?(filename) do
      path = Path.join([org_dir, gtfs_version_id, station_dir, filename])

      case PathSafety.ensure_within_root(org_dir, path) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unsafe_path}
    end
  end

  defp legacy_path(organization_id, station_stop_id, filename) do
    with {:ok, org_dir} <- safe_org_dir(organization_id),
         {:ok, station_dir} <- safe_station_dir(station_stop_id),
         {:ok, path} <- legacy_path_ok(org_dir, station_dir, filename) do
      {:ok, path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_path_ok(org_dir, station_dir, filename) do
    if PathSafety.safe_path_component?(filename) do
      path = Path.join([org_dir, station_dir, filename])

      case PathSafety.ensure_within_root(org_dir, path) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unsafe_path}
    end
  end

  defp encoded_station_dir(station_stop_id) do
    station_stop_id |> PathSafety.stop_storage_dir() |> URI.encode(&URI.char_unreserved?/1)
  end

  defp legacy_url(organization_id, station_stop_id, filename) do
    "#{endpoint_url()}/uploads/diagrams/#{organization_id}/#{encoded_station_dir(station_stop_id)}/#{URI.encode(filename, &URI.char_unreserved?/1)}"
  end

  @doc """
  Reads the bytes of a diagram image, preferring the versioned file and falling back to a
  referenced historical legacy file only when the versioned file is absent. Returns
  `{:ok, binary}` or `{:error, term()}`.
  """
  @spec read_image(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def read_image(organization_id, gtfs_version_id, station_stop_id, filename) do
    case published_path(organization_id, gtfs_version_id, station_stop_id, filename) do
      {:ok, path} ->
        File.read(path)

      {:error, :not_found} ->
        case referenced_legacy_path(
               organization_id,
               gtfs_version_id,
               station_stop_id,
               filename
             ) do
          {:ok, legacy_path} ->
            File.read(legacy_path)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp org_root(organization_id) do
    Path.join([uploads_root(), "diagrams", organization_id])
  end

  defp uploads_root do
    Application.fetch_env!(:gtfs_planner, :uploads_path) |> Path.expand()
  end

  defp write_file(dest_dir, dest_path, binary) do
    with :ok <- File.mkdir_p(dest_dir),
         :ok <- File.write(dest_path, binary) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("diagram_storage: failed to write #{dest_path}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp endpoint_url do
    GtfsPlannerWeb.Endpoint.url()
  end

  defp referenced_legacy_path(organization_id, gtfs_version_id, station_stop_id, filename) do
    if published_diagram_reference?(
         organization_id,
         gtfs_version_id,
         station_stop_id,
         filename
       ) do
      case legacy_path(organization_id, station_stop_id, filename) do
        {:ok, path} -> if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp published_diagram_reference?(
         organization_id,
         gtfs_version_id,
         station_stop_id,
         filename
       ) do
    from(sl in GtfsPlanner.Gtfs.StopLevel,
      join: v in GtfsPlanner.Versions.GtfsVersion,
      on: sl.gtfs_version_id == v.id,
      join: s in GtfsPlanner.Gtfs.Stop,
      on: sl.stop_id == s.id,
      where:
        v.id == ^gtfs_version_id and
          v.organization_id == ^organization_id and
          v.publication_status == "published" and
          sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          s.stop_id == ^station_stop_id and
          sl.diagram_filename == ^filename,
      select: true,
      limit: 1
    )
    |> Repo.one()
    |> Kernel.==(true)
  end

  # -- legacy backfill query ------------------------------------------------

  defp published_diagram_references(repo) do
    base =
      from(sl in GtfsPlanner.Gtfs.StopLevel,
        join: v in GtfsPlanner.Versions.GtfsVersion,
        on: sl.gtfs_version_id == v.id,
        join: s in GtfsPlanner.Gtfs.Stop,
        on: sl.stop_id == s.id
      )

    query =
      from([sl, v, s] in base,
        where: v.publication_status == "published" and not is_nil(sl.diagram_filename),
        select: %{
          organization_id: sl.organization_id,
          gtfs_version_id: sl.gtfs_version_id,
          station_stop_id: s.stop_id,
          diagram_filename: sl.diagram_filename
        }
      )

    repo.all(query)
  end
end
