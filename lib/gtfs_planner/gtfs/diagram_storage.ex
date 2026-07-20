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

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.DiagramUploadValidator
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Repo

  require Logger

  import Ecto.Query

  @candidate_extensions [".png", ".jpg", ".jpeg"]
  @candidate_filename ~r/\A[0-9a-f]{32}\.candidate\.(?:png|jpg|jpeg)\z/

  @doc """
  Writes validated raster bytes to an unreferenced, exact-station candidate path.

  A candidate is intentionally not visible through a `StopLevel` until
  `commit_candidate/2` succeeds. Its random reserved name prevents a caller from
  selecting an existing diagram or a directory as a cleanup target.
  """
  @spec store_candidate(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def store_candidate(organization_id, gtfs_version_id, station_stop_id, extension, binary)
      when is_binary(organization_id) and is_binary(gtfs_version_id) and
             is_binary(station_stop_id) and is_binary(extension) and is_binary(binary) do
    with :ok <- validate_candidate_bytes(extension, binary),
         {:ok, org_dir} <- safe_org_dir(organization_id),
         {:ok, station_dir} <- safe_station_dir(station_stop_id),
         {:ok, dest_dir} <- versioned_dir(org_dir, gtfs_version_id, station_dir) do
      write_new_candidate(dest_dir, org_dir, gtfs_version_id, station_dir, extension, binary)
    end
  end

  def store_candidate(_, _, _, _, _), do: {:error, :badarg}

  @doc """
  Makes an existing candidate the diagram referenced by `stop_level`.

  The candidate's filesystem existence and the calibration-resetting database update
  are ordered under the same exact-scope advisory lock. They cannot be one atomic
  resource: if the update fails, the unreferenced file remains available for aged
  cleanup while the previous database filename is unchanged.
  """
  @spec commit_candidate(StopLevel.t(), String.t()) ::
          {:ok, StopLevel.t()} | {:error, :not_found | :not_candidate | term()}
  def commit_candidate(%StopLevel{} = stop_level, filename) when is_binary(filename) do
    with true <- candidate_filename?(filename),
         {:ok, scope} <- scope_for_stop_level(stop_level),
         {:ok, path} <- candidate_path(scope, filename) do
      Repo.transaction(fn ->
        commit_candidate_under_lock(stop_level.id, scope, filename, path)
      end)
      |> transaction_result()
    else
      false -> {:error, :not_candidate}
      {:error, reason} -> {:error, reason}
    end
  end

  def commit_candidate(_, _), do: {:error, :not_found}

  @doc """
  Idempotently removes one unreferenced candidate in the exact station scope.

  `:older_than` may be passed by aged cleanup to recheck the file timestamp after
  the lock is acquired. Missing files, references, and young candidates are retained.
  """
  @spec delete_unreferenced_candidate(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def delete_unreferenced_candidate(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        filename,
        opts \\ []
      )

  def delete_unreferenced_candidate(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        filename,
        opts
      )
      when is_binary(organization_id) and is_binary(gtfs_version_id) and
             is_binary(station_stop_id) and is_binary(filename) and is_list(opts) do
    scope = %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      station_stop_id: station_stop_id
    }

    case delete_candidate(scope, filename, opts) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_unreferenced_candidate(_, _, _, _, _), do: {:error, :badarg}

  @doc """
  Removes unreferenced reserved candidates at or older than `older_than` from one
  organization/version/station directory. It never enumerates sibling stations.
  """
  @spec cleanup_stale_candidates(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_stale_candidates(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        %DateTime{} = older_than
      )
      when is_binary(organization_id) and is_binary(gtfs_version_id) and
             is_binary(station_stop_id) do
    scope = %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      station_stop_id: station_stop_id
    }

    with {:ok, directory} <- candidate_directory(scope),
         {:ok, filenames} <- candidate_filenames(directory, older_than) do
      cleanup_candidates(filenames, scope, older_than)
    end
  end

  def cleanup_stale_candidates(_, _, _, _), do: {:error, :badarg}

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
    - `{:error, :badarg}` when either argument is not a binary
    - `{:error, reason}` when the filesystem removal fails
  """
  @spec delete_version_namespace(Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, term()}
  def delete_version_namespace(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    if PathSafety.safe_path_component?(organization_id) and
         PathSafety.safe_path_component?(gtfs_version_id) do
      org_dir = org_root(organization_id)
      version_dir = Path.join(org_dir, gtfs_version_id)

      case PathSafety.ensure_within_root(org_dir, version_dir) do
        :ok ->
          remove_version_namespace(version_dir)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unsafe_path}
    end
  end

  def delete_version_namespace(_, _), do: {:error, :badarg}

  defp remove_version_namespace(version_dir) do
    case File.rm_rf(version_dir) do
      {:ok, _removed} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @doc """
  Reports whether the exact organization/version diagram namespace exists.
  The same component and containment checks as deletion are applied.
  """
  @spec version_namespace_exists?(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, boolean()} | {:error, :unsafe_path | :path_traversal | :badarg}
  def version_namespace_exists?(organization_id, gtfs_version_id)
      when is_binary(organization_id) and is_binary(gtfs_version_id) do
    if PathSafety.safe_path_component?(organization_id) and
         PathSafety.safe_path_component?(gtfs_version_id) do
      org_dir = org_root(organization_id)
      version_dir = Path.join(org_dir, gtfs_version_id)

      case PathSafety.ensure_within_root(org_dir, version_dir) do
        :ok -> {:ok, File.dir?(version_dir)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unsafe_path}
    end
  end

  def version_namespace_exists?(_, _), do: {:error, :badarg}

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

  # -- candidate storage ----------------------------------------------------

  defp validate_candidate_bytes(extension, binary) when extension in @candidate_extensions do
    case DiagramUploadValidator.validate("candidate" <> extension, binary) do
      {:ok, %{extension: ^extension}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_candidate_bytes(_extension, _binary), do: {:error, :unsupported_type}

  defp write_new_candidate(dest_dir, org_dir, gtfs_version_id, station_dir, extension, binary) do
    filename = candidate_filename(extension)

    with {:ok, path} <- versioned_path(org_dir, gtfs_version_id, station_dir, filename),
         :ok <- PathSafety.ensure_within_root(org_dir, path),
         :ok <- File.mkdir_p(dest_dir),
         :ok <- File.write(path, binary, [:binary, :exclusive]) do
      {:ok, filename}
    else
      {:error, :eexist} ->
        # A 128-bit random collision is vanishingly unlikely, but never overwrite
        # a candidate if it happens.
        write_new_candidate(dest_dir, org_dir, gtfs_version_id, station_dir, extension, binary)

      {:error, reason} ->
        Logger.warning("diagram_storage: failed to stage candidate: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp candidate_filename(extension) do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".candidate" <> extension
  end

  defp candidate_filename?(filename) do
    PathSafety.safe_path_component?(filename) and Regex.match?(@candidate_filename, filename)
  end

  defp scope_for_stop_level(%StopLevel{} = stop_level) do
    query =
      from(s in Stop,
        where:
          s.id == ^stop_level.stop_id and s.organization_id == ^stop_level.organization_id and
            s.gtfs_version_id == ^stop_level.gtfs_version_id,
        select: s.stop_id
      )

    case Repo.one(query) do
      station_stop_id when is_binary(station_stop_id) ->
        {:ok,
         %{
           organization_id: stop_level.organization_id,
           gtfs_version_id: stop_level.gtfs_version_id,
           station_stop_id: station_stop_id
         }}

      _ ->
        {:error, :not_found}
    end
  end

  defp candidate_path(scope, filename) do
    with {:ok, org_dir} <- safe_org_dir(scope.organization_id),
         {:ok, station_dir} <- safe_station_dir(scope.station_stop_id),
         {:ok, path} <- versioned_path(org_dir, scope.gtfs_version_id, station_dir, filename),
         :ok <- PathSafety.ensure_within_root(org_dir, path) do
      {:ok, path}
    end
  end

  defp candidate_directory(scope) do
    with {:ok, org_dir} <- safe_org_dir(scope.organization_id),
         {:ok, station_dir} <- safe_station_dir(scope.station_stop_id),
         {:ok, directory} <- versioned_dir(org_dir, scope.gtfs_version_id, station_dir),
         :ok <- PathSafety.ensure_within_root(org_dir, directory) do
      {:ok, directory}
    end
  end

  defp candidate_filenames(directory, older_than) do
    case File.ls(directory) do
      {:ok, filenames} ->
        {:ok,
         Enum.filter(filenames, fn filename ->
           candidate_filename?(filename) and
             candidate_aged?(Path.join(directory, filename), older_than)
         end)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp candidate_aged?(path, older_than) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: modified_at}} ->
        modified_at <= DateTime.to_unix(older_than)

      _ ->
        false
    end
  end

  defp cleanup_candidates(filenames, scope, older_than) do
    Enum.reduce_while(filenames, {:ok, 0}, fn filename, {:ok, count} ->
      case delete_candidate(scope, filename, older_than: older_than) do
        {:ok, :deleted} -> {:cont, {:ok, count + 1}}
        {:ok, :retained} -> {:cont, {:ok, count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_candidate(scope, filename, opts) do
    case candidate_filename?(filename) do
      false ->
        {:error, :not_candidate}

      true ->
        case candidate_path(scope, filename) do
          {:ok, path} ->
            delete_candidate_at_path(scope, filename, path, opts)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp delete_candidate_at_path(scope, filename, path, opts) do
    Repo.transaction(fn -> delete_candidate_under_lock(scope, filename, path, opts) end)
    |> transaction_result()
  end

  defp commit_candidate_under_lock(stop_level_id, scope, filename, path) do
    with :ok <- advisory_lock(scope, filename),
         %StopLevel{} = current <- locked_stop_level(stop_level_id, scope),
         true <- File.regular?(path) do
      case Gtfs.update_stop_level_diagram(current, filename) do
        {:ok, updated} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      nil -> Repo.rollback(:not_found)
      false -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp delete_candidate_under_lock(scope, filename, path, opts) do
    case advisory_lock(scope, filename) do
      :ok -> delete_after_lock(scope, filename, path, opts)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp delete_after_lock(scope, filename, path, opts) do
    cond do
      candidate_referenced?(scope, filename) ->
        :retained

      not File.regular?(path) ->
        :retained

      Keyword.has_key?(opts, :older_than) and not candidate_aged?(path, opts[:older_than]) ->
        :retained

      true ->
        remove_candidate(path)
    end
  end

  defp remove_candidate(path) do
    case File.rm(path) do
      :ok -> :deleted
      {:error, :enoent} -> :retained
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp candidate_referenced?(scope, filename) do
    from(sl in StopLevel,
      join: s in Stop,
      on: s.id == sl.stop_id,
      where:
        sl.organization_id == ^scope.organization_id and
          sl.gtfs_version_id == ^scope.gtfs_version_id and
          s.stop_id == ^scope.station_stop_id and sl.diagram_filename == ^filename,
      select: true,
      limit: 1
    )
    |> Repo.one()
    |> Kernel.==(true)
  end

  defp locked_stop_level(stop_level_id, scope) do
    from(sl in StopLevel,
      join: s in Stop,
      on: s.id == sl.stop_id,
      where:
        sl.id == ^stop_level_id and sl.organization_id == ^scope.organization_id and
          sl.gtfs_version_id == ^scope.gtfs_version_id and s.stop_id == ^scope.station_stop_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp advisory_lock(scope, filename) do
    key =
      Enum.join(
        [
          "diagram-candidate-v1",
          scope.organization_id,
          scope.gtfs_version_id,
          scope.station_stop_id,
          filename
        ],
        ":"
      )

    case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

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
