defmodule GtfsPlannerWeb.ExportArtifactResponse do
  @moduledoc """
  Single claimed-download response path shared by the web and API callers.

  Callers pass a claim returned by `GtfsPlanner.Gtfs.ExportRuns.claim_download/3`;
  this module owns the private artifact headers, the file send, and the
  completion of the download claim. No caller may fork its own send path.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, put_resp_header: 3, send_file: 5]

  alias GtfsPlanner.Gtfs.ExportRuns

  @spec send_claimed(Plug.Conn.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          Plug.Conn.t()
  def send_claimed(conn, organization_id, version_id, run_id, claim) do
    conn =
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-disposition", content_disposition(claim.filename))
      |> put_resp_header("content-length", Integer.to_string(claim.size))
      |> send_file(200, claim.path, 0, claim.size)

    :ok = ExportRuns.complete_download(organization_id, version_id, run_id, claim.claim_id)
    conn
  end

  defp content_disposition(filename) do
    "attachment; filename=\"#{safe_filename(filename)}\""
  end

  defp safe_filename(filename) when is_binary(filename) do
    if String.match?(filename, ~r/\A[A-Za-z0-9._-]+\z/), do: filename, else: "export.zip"
  end

  defp safe_filename(_), do: "export.zip"
end
