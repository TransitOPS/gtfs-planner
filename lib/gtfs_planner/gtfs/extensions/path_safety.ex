defmodule GtfsPlanner.Gtfs.Extensions.PathSafety do
  @moduledoc """
  Shared helpers for filesystem-safe path construction in GTFS extensions.
  """

  @safe_path_component ~r/^[A-Za-z0-9._-]+$/

  @doc """
  Validates a path component that must be used as-is on disk.
  """
  def safe_path_component?(value) when is_binary(value) do
    value != "" and
      value != "." and
      value != ".." and
      not String.contains?(value, ["/", "\\", <<0>>]) and
      String.match?(value, @safe_path_component)
  end

  def safe_path_component?(_), do: false

  @doc """
  Derives a stable filesystem-safe directory name for a stop_id.
  """
  def stop_storage_dir(stop_id) when is_binary(stop_id) and stop_id != "" do
    if safe_path_component?(stop_id) do
      stop_id
    else
      "sid_" <> Base.url_encode64(stop_id, padding: false)
    end
  end

  def stop_storage_dir(_), do: nil

  @doc """
  Ensures `path` is rooted under `root` after expansion.
  """
  def ensure_within_root(root, path) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)

    if expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/") do
      :ok
    else
      {:error, :path_traversal}
    end
  end
end
