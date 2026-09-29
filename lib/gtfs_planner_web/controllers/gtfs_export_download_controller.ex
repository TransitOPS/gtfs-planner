defmodule GtfsPlannerWeb.GtfsExportDownloadController do
  @moduledoc """
  Delivers one verified, organization- and version-scoped GTFS export.

  Artifact paths are never derived from request data. `ExportRuns` validates
  the durable ready row and final bytes before this controller receives a path.
  `?file=flex` selects the run's flex feed; every other request is the run's
  main feed, and a run without the requested file is a 404.
  """

  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.ExportArtifactResponse

  @not_found_body "Not Found"

  def show(conn, %{"version" => version_id, "run_id" => run_id} = params) do
    organization_id = conn.assigns.current_organization.id
    file = if params["file"] == "flex", do: :flex, else: :main

    with {:ok, version_id} <- Ecto.UUID.cast(version_id),
         {:ok, run_id} <- Ecto.UUID.cast(run_id),
         true <- Versions.published_gtfs_version_for_org?(organization_id, version_id),
         {:ok, claim} <- ExportRuns.claim_download(organization_id, version_id, run_id, file) do
      ExportArtifactResponse.send_claimed(conn, organization_id, version_id, run_id, claim)
    else
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  defp not_found(conn), do: send_resp(conn, 404, @not_found_body)
end
