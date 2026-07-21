defmodule GtfsPlannerWeb.GtfsExportDownloadController do
  @moduledoc """
  Delivers one verified, organization- and version-scoped GTFS export.

  Artifact paths are never derived from request data. `ExportRuns` validates
  the durable ready row and final bytes before this controller receives a path.
  """

  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Versions

  @not_found_body "Not Found"

  def show(conn, %{"version" => version_id, "run_id" => run_id}) do
    organization_id = conn.assigns.current_organization.id

    with {:ok, version_id} <- Ecto.UUID.cast(version_id),
         {:ok, run_id} <- Ecto.UUID.cast(run_id),
         true <- Versions.published_gtfs_version_for_org?(organization_id, version_id),
         {:ok, claim} <- ExportRuns.claim_download(organization_id, version_id, run_id) do
      send_claimed_download(conn, organization_id, version_id, run_id, claim)
    else
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  defp send_claimed_download(conn, organization_id, version_id, run_id, claim) do
    conn =
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-disposition", content_disposition(claim.filename))
      |> put_resp_header("content-length", Integer.to_string(claim.size))
      |> send_file(200, claim.path, 0, claim.size)

    :ok = ExportRuns.complete_download(organization_id, version_id, run_id)
    conn
  end

  defp content_disposition(filename) do
    "attachment; filename=\"#{safe_filename(filename)}\""
  end

  defp safe_filename(filename) when is_binary(filename) do
    if String.match?(filename, ~r/\A[A-Za-z0-9._-]+\z/), do: filename, else: "export.zip"
  end

  defp safe_filename(_), do: "export.zip"

  defp not_found(conn), do: send_resp(conn, 404, @not_found_body)
end
