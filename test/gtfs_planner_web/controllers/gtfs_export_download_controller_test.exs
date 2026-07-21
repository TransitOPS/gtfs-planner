defmodule GtfsPlannerWeb.GtfsExportDownloadControllerTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup do
    root = Path.join(System.tmp_dir!(), "export-downloads-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if old_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, old_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    %{root: root}
  end

  test "sends a ready scoped artifact through the authenticated editor route and completes its claim",
       %{conn: conn} do
    %{organization: organization, version: version, user: user} = editor_context()
    run = ready_run!(organization.id, version.id, "exact export bytes")

    conn =
      conn
      |> log_in_user(user, organization: organization)
      |> get(download_path(version.id, run.id))

    assert conn.status == 200
    assert conn.resp_body == "exact export bytes"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/zip"
    assert get_resp_header(conn, "content-length") == ["18"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert [content_disposition] = get_resp_header(conn, "content-disposition")
    assert content_disposition =~ "attachment"
    assert content_disposition =~ "network.zip"

    assert %Run{download_count: 1, download_claimed_until: nil, last_downloaded_at: downloaded_at} =
             ExportRuns.get_for_version(organization.id, version.id, run.id)

    assert downloaded_at
  end

  test "redirects logged-out requests before artifact lookup", %{conn: conn} do
    conn = get(conn, download_path(Ecto.UUID.generate(), Ecto.UUID.generate()))

    assert redirected_to(conn) == "/users/log_in"
  end

  test "rejects deactivated members and members without the editor role before lookup", %{
    conn: conn
  } do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    {:ok, _membership} = Organizations.add_user_to_organization(user.id, organization.id, [])

    role_conn =
      conn
      |> log_in_user(user, organization: organization)
      |> get(download_path(version.id, Ecto.UUID.generate()))

    assert role_conn.status == 403

    {:ok, _membership} = Organizations.deactivate_user_in_organization(user.id, organization.id)

    deactivated_conn =
      build_conn()
      |> log_in_user(user, organization: organization)
      |> get(download_path(version.id, Ecto.UUID.generate()))

    assert deactivated_conn.status == 403
  end

  test "normalizes malformed, foreign, unpublished, non-ready, expired, corrupt, and missing artifacts to one 404",
       %{conn: conn} do
    %{organization: organization, version: version, user: user} = editor_context()
    ready_run = ready_run!(organization.id, version.id, "ready bytes")
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_run = ready_run!(foreign_organization.id, foreign_version.id, "foreign bytes")

    {:ok, unpublished_version} =
      Versions.create_staging_gtfs_version(organization.id, %{
        name: "Unpublished download version"
      })

    {:ok, pending_run} = ExportRuns.create_pending(organization.id, version.id, @actor, :pathways)

    expired_run = ready_run!(organization.id, version.id, "expired bytes")

    from(r in Run, where: r.id == ^expired_run.id)
    |> Repo.update_all(set: [artifact_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    corrupt_run = ready_run!(organization.id, version.id, "corrupt bytes")
    path = artifact_path!(organization.id, version.id, corrupt_run.id)
    File.write!(path, "altered bytes")

    rejected_paths = [
      download_path("not-a-uuid", ready_run.id),
      download_path(version.id, "not-a-uuid"),
      download_path(version.id, foreign_run.id),
      download_path(unpublished_version.id, ready_run.id),
      download_path(version.id, pending_run.id),
      download_path(version.id, expired_run.id),
      download_path(version.id, corrupt_run.id),
      download_path(version.id, Ecto.UUID.generate())
    ]

    responses =
      Enum.map(rejected_paths, fn path ->
        conn
        |> log_in_user(user, organization: organization)
        |> get(path)
      end)

    assert Enum.all?(responses, &(&1.status == 404))
    assert Enum.uniq(Enum.map(responses, & &1.resp_body)) == ["Not Found"]

    assert %Run{state: :failed, failure_code: "missing_or_corrupt_artifact"} =
             ExportRuns.get_for_version(organization.id, version.id, corrupt_run.id)
  end

  test "returns the same 404 while another download holds the scoped claim", %{conn: conn} do
    %{organization: organization, version: version, user: user} = editor_context()
    run = ready_run!(organization.id, version.id, "claimed bytes")

    assert {:ok, claim} = ExportRuns.claim_download(organization.id, version.id, run.id)

    conn =
      conn
      |> log_in_user(user, organization: organization)
      |> get(download_path(version.id, run.id))

    assert conn.status == 404
    assert conn.resp_body == "Not Found"

    assert :ok =
             ExportRuns.complete_download(
               organization.id,
               version.id,
               run.id,
               claim.claim_id
             )
  end

  defp editor_context do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()

    {:ok, _membership} =
      Organizations.add_user_to_organization(user.id, organization.id, ["pathways_studio_editor"])

    %{organization: organization, version: version, user: user}
  end

  defp ready_run!(organization_id, version_id, bytes) do
    {:ok, run} = ExportRuns.create_pending(organization_id, version_id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization_id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization_id, version_id, run.id, "network.zip", bytes)

    {:ok, ready} = ExportRuns.mark_ready(organization_id, run.id, generation, token, artifact)
    ready
  end

  defp artifact_path!(organization_id, version_id, run_id) do
    {:ok, claim} = ExportRuns.claim_download(organization_id, version_id, run_id)

    assert :ok =
             ExportRuns.complete_download(organization_id, version_id, run_id, claim.claim_id)

    claim.path
  end

  defp download_path(version_id, run_id), do: "/gtfs/#{version_id}/export-runs/#{run_id}/download"
end
