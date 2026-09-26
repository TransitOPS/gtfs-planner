defmodule GtfsPlannerWeb.Api.V1.PathwaysExportController do
  @moduledoc """
  Companion-API request, status and download for one version's pathways export.

  Organization, actor, export type, lifecycle state and artifact facts come only
  from authenticated assigns and durable database reads. Request parameters
  supply route identifiers and nothing else, and are canonicalized with
  `Ecto.UUID.cast/1` before any lookup so a malformed identifier is a 400 rather
  than a hidden 404.

  Every returned error from `GtfsPlanner.Gtfs.ExportRuns.create_pending/4` or
  `GtfsPlanner.Gtfs.Export.Runner.ensure_started/2` maps to the sanitized
  response table. No arbitrary exception is rescued, no inspected tuple or
  changeset is serialized, and no possibly claimed run is mutated here.
  """

  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.Export.Runner
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.ExportArtifactResponse

  @export_type :pathways

  @not_found_message "Export resource not found."
  @not_ready_message "Export is not ready. Check export status before retrying."
  @unavailable_message "Export is unavailable. Check export status before retrying."
  @service_message "Export service is unavailable. Try again later."

  @doc "POST /api/v1/versions/:version_id/pathways-exports — request or reuse the active run."
  def create(conn, %{"version_id" => version_id}) do
    with {:ok, version_id} <- cast_uuid(version_id),
         %{} = _version <- published_version(conn, version_id) do
      start_export(conn, version_id)
    else
      :error -> bad_request(conn)
      nil -> not_found(conn)
    end
  end

  @doc "GET /api/v1/versions/:version_id/pathways-exports/:export_id — current lifecycle state."
  def show(conn, params) do
    with {:ok, version_id} <- cast_uuid(params["version_id"]),
         {:ok, export_id} <- cast_uuid(params["export_id"]),
         %{} = _version <- published_version(conn, version_id),
         %Run{export_type: @export_type} = run <- scoped_run(conn, version_id, export_id) do
      json(conn, %{data: serialize(run)})
    else
      :error -> bad_request(conn)
      %Run{} -> not_found(conn)
      nil -> not_found(conn)
    end
  end

  @doc "GET /api/v1/versions/:version_id/pathways-exports/:export_id/download — claim and send bytes."
  def download(conn, params) do
    with {:ok, version_id} <- cast_uuid(params["version_id"]),
         {:ok, export_id} <- cast_uuid(params["export_id"]),
         %{} = _version <- published_version(conn, version_id),
         %Run{export_type: @export_type} = run <- scoped_run(conn, version_id, export_id),
         {:ok, claim} <- claim_ready_download(conn, version_id, run) do
      ExportArtifactResponse.send_claimed(conn, organization_id(conn), version_id, run.id, claim)
    else
      :error -> bad_request(conn)
      {:error, :not_ready} -> conflict(conn, "export_not_ready", @not_ready_message)
      {:error, :unavailable} -> conflict(conn, "download_unavailable", @unavailable_message)
      %Run{} -> not_found(conn)
      nil -> not_found(conn)
    end
  end

  # -- create -----------------------------------------------------------------

  defp start_export(conn, version_id) do
    organization_id = organization_id(conn)

    case ExportRuns.create_pending(organization_id, version_id, actor(conn), @export_type) do
      {:ok, run} -> ensure_started(conn, organization_id, run)
      {:error, :not_found} -> not_found(conn)
      {:error, _reason} -> service_unavailable(conn)
    end
  end

  defp ensure_started(conn, organization_id, run) do
    case Runner.ensure_started(organization_id, run) do
      :ok -> accepted(conn, run)
      {:error, _reason} -> service_unavailable(conn)
    end
  end

  defp accepted(conn, run) do
    conn
    |> put_status(202)
    |> put_resp_header("location", status_path(run.gtfs_version_id, run.id))
    |> json(%{data: serialize(run)})
  end

  defp status_path(version_id, run_id),
    do: ~p"/api/v1/versions/#{version_id}/pathways-exports/#{run_id}"

  # -- scope ------------------------------------------------------------------

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  defp organization_id(conn), do: conn.assigns.current_organization_id

  defp actor(conn) do
    user = conn.assigns.current_user
    %{id: user.id, email: user.email}
  end

  defp published_version(conn, version_id) do
    Versions.get_published_gtfs_version_for_org(organization_id(conn), version_id)
  end

  defp scoped_run(conn, version_id, run_id) do
    ExportRuns.get_for_version(organization_id(conn), version_id, run_id)
  end

  # -- download ---------------------------------------------------------------

  # A denied or rejected download never starts a build: it either reports the
  # durable non-ready state or asks the client to check status first, because
  # `claim_download/3` deliberately merges contention, expiry and missing or
  # corrupt bytes into one answer.
  #
  # The two 409 codes separate a run that is still building (`export_not_ready`:
  # keep polling) from a download that cannot be served now
  # (`download_unavailable`). A terminal run never becomes downloadable, and a
  # failed claim on a ready run may be temporary contention or a lost artifact,
  # so that code asks the client to read status before deciding.
  defp claim_ready_download(_conn, _version_id, %Run{state: state})
       when state in [:pending, :building],
       do: {:error, :not_ready}

  defp claim_ready_download(_conn, _version_id, %Run{state: state})
       when state in [:failed, :interrupted, :cancelled, :expired],
       do: {:error, :unavailable}

  defp claim_ready_download(conn, version_id, %Run{} = run) do
    case ExportRuns.claim_download(organization_id(conn), version_id, run.id) do
      {:ok, claim} -> {:ok, claim}
      {:error, :not_found} -> {:error, :unavailable}
    end
  end

  # -- serialization ----------------------------------------------------------

  defp serialize(%Run{} = run) do
    %{
      id: run.id,
      version_id: run.gtfs_version_id,
      export_type: Atom.to_string(run.export_type),
      state: Atom.to_string(run.state),
      failure_code: run.failure_code,
      created_at: iso8601(run.inserted_at),
      finished_at: iso8601(run.finished_at),
      expires_at: ready_value(run, iso8601(run.artifact_expires_at)),
      size_bytes: ready_value(run, run.artifact_size_bytes),
      sha256: ready_value(run, run.artifact_sha256),
      download_path: ready_download_path(run)
    }
  end

  defp ready_value(%Run{state: :ready}, value), do: value
  defp ready_value(%Run{}, _value), do: nil

  defp ready_download_path(%Run{state: :ready} = run),
    do: ~p"/api/v1/versions/#{run.gtfs_version_id}/pathways-exports/#{run.id}/download"

  defp ready_download_path(%Run{}), do: nil

  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)

  # -- errors -----------------------------------------------------------------

  defp bad_request(conn), do: error(conn, 400, "bad_request", "Invalid ID format.")

  defp not_found(conn), do: error(conn, 404, "not_found", @not_found_message)

  defp conflict(conn, code, message), do: error(conn, 409, code, message)

  defp service_unavailable(conn), do: error(conn, 503, "export_unavailable", @service_message)

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
