defmodule GtfsPlanner.Otp.OsmPath do
  @moduledoc """
  Resolves and validates the fixed OSM input path used by OTP graph builds.
  """

  @type error_reason ::
          :missing_path
          | :invalid_path
          | :invalid_extension
          | :not_found
          | :not_regular_file
          | :not_readable

  @spec resolve() :: {:ok, String.t()} | {:error, error_reason()}
  def resolve do
    case Application.get_env(:gtfs_planner, :otp_osm_path) do
      path when is_binary(path) ->
        path
        |> String.trim()
        |> validate()

      _other ->
        {:error, :missing_path}
    end
  end

  @spec validate(String.t()) :: {:ok, String.t()} | {:error, error_reason()}
  def validate(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :missing_path}

      Path.type(path) != :absolute ->
        {:error, :invalid_path}

      not String.ends_with?(path, ".osm.pbf") ->
        {:error, :invalid_extension}

      not File.exists?(path) ->
        {:error, :not_found}

      not File.regular?(path) ->
        {:error, :not_regular_file}

      true ->
        validate_readable(path)
    end
  end

  def validate(_path), do: {:error, :invalid_path}

  defp validate_readable(path) do
    case File.open(path, [:read]) do
      {:ok, file} ->
        File.close(file)
        {:ok, path}

      {:error, _reason} ->
        {:error, :not_readable}
    end
  end
end
