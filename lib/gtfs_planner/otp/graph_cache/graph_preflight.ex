defmodule GtfsPlanner.Otp.GraphPreflight do
  @moduledoc """
  Preflight checks for OTP graph build dependencies.

  Validates Java, OTP jar, OSM input, GTFS artifact input, and workspace
  readiness before graph materialization starts.
  """

  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.GraphPath
  alias GtfsPlanner.Otp.OsmPath

  @type issue :: %{
          code: atom(),
          severity: :error,
          message: String.t(),
          details: map()
        }

  @spec run(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, [issue()]}
  def run(organization_id, gtfs_version_id) do
    issues =
      java_issues() ++
        jar_issues() ++
        osm_issues() ++
        gtfs_issues(organization_id, gtfs_version_id) ++
        workspace_issues(organization_id, gtfs_version_id)

    case issues do
      [] -> :ok
      _ -> {:error, issues}
    end
  end

  defp java_issues do
    case Application.get_env(:gtfs_planner, :java_path) do
      path when is_binary(path) ->
        trimmed_path = String.trim(path)

        cond do
          trimmed_path == "" ->
            [issue(:missing_java_path, "Java path is not configured", %{})]

          Path.type(trimmed_path) == :absolute and not File.regular?(trimmed_path) ->
            [
              issue(:java_not_found, "Configured Java binary was not found", %{path: trimmed_path})
            ]

          Path.type(trimmed_path) != :absolute and is_nil(System.find_executable(trimmed_path)) ->
            [
              issue(:java_not_found, "Configured Java command was not found in PATH", %{
                command: trimmed_path
              })
            ]

          true ->
            []
        end

      _other ->
        [issue(:missing_java_path, "Java path is not configured", %{})]
    end
  end

  defp jar_issues do
    case Application.get_env(:gtfs_planner, :otp_jar_path) do
      path when is_binary(path) ->
        trimmed_path = String.trim(path)

        cond do
          trimmed_path == "" ->
            [issue(:missing_otp_jar_path, "OTP jar path is not configured", %{})]

          Path.type(trimmed_path) != :absolute ->
            [issue(:invalid_otp_jar_path, "OTP jar path must be absolute", %{path: trimmed_path})]

          not String.ends_with?(trimmed_path, ".jar") ->
            [
              issue(:invalid_otp_jar_extension, "OTP jar must end with .jar", %{
                path: trimmed_path
              })
            ]

          not File.exists?(trimmed_path) ->
            [issue(:otp_jar_not_found, "OTP jar file was not found", %{path: trimmed_path})]

          not File.regular?(trimmed_path) ->
            [
              issue(:otp_jar_not_regular_file, "OTP jar path is not a regular file", %{
                path: trimmed_path
              })
            ]

          not readable_file?(trimmed_path) ->
            [issue(:otp_jar_not_readable, "OTP jar file is not readable", %{path: trimmed_path})]

          true ->
            []
        end

      _other ->
        [issue(:missing_otp_jar_path, "OTP jar path is not configured", %{})]
    end
  end

  defp osm_issues do
    case OsmPath.resolve() do
      {:ok, _path} ->
        []

      {:error, reason} ->
        [
          issue(:invalid_otp_osm_path, "OTP OSM path validation failed", %{reason: reason})
        ]
    end
  end

  defp gtfs_issues(organization_id, gtfs_version_id) do
    case Otp.fetch_artifact(organization_id, gtfs_version_id) do
      {:ok, artifact} ->
        gtfs_path = artifact.zip_path

        cond do
          gtfs_path == nil or String.trim(gtfs_path) == "" ->
            [issue(:missing_gtfs_zip_path, "GTFS artifact zip path is missing", %{})]

          Path.type(gtfs_path) != :absolute ->
            [
              issue(:invalid_gtfs_zip_path, "GTFS artifact zip path must be absolute", %{
                path: gtfs_path
              })
            ]

          not File.exists?(gtfs_path) ->
            [
              issue(:gtfs_zip_not_found, "GTFS artifact zip file was not found", %{
                path: gtfs_path
              })
            ]

          not File.regular?(gtfs_path) ->
            [
              issue(:gtfs_zip_not_regular_file, "GTFS artifact zip path is not a regular file", %{
                path: gtfs_path
              })
            ]

          not readable_file?(gtfs_path) ->
            [
              issue(:gtfs_zip_not_readable, "GTFS artifact zip file is not readable", %{
                path: gtfs_path
              })
            ]

          true ->
            []
        end

      {:error, :not_found} ->
        [
          issue(:missing_gtfs_artifact, "OTP GTFS artifact record was not found", %{
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          })
        ]
    end
  end

  defp workspace_issues(organization_id, gtfs_version_id) do
    workspace_dir = GraphPath.workspace_dir(organization_id, gtfs_version_id)
    data_dir = GraphPath.data_dir(organization_id, gtfs_version_id)

    case File.mkdir_p(data_dir) do
      :ok ->
        []

      {:error, reason} ->
        [
          issue(:workspace_unavailable, "Graph workspace directory is not writable", %{
            workspace_dir: workspace_dir,
            data_dir: data_dir,
            reason: inspect(reason)
          })
        ]
    end
  end

  defp readable_file?(path) do
    case File.open(path, [:read]) do
      {:ok, file} ->
        File.close(file)
        true

      {:error, _reason} ->
        false
    end
  end

  defp issue(code, message, details) do
    %{
      code: code,
      severity: :error,
      message: message,
      details: details
    }
  end
end
