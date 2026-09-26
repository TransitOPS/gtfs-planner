defmodule GtfsPlannerWeb.Api.V1.PathwaysExportControllerTest do
  @moduledoc """
  Contract tests for the three companion-API pathways export routes.

  Each focused group carries exactly one `export_gate` tag so the prepared
  EV-2/3/4/5/6/8 commands select it. Nothing here fakes the database, the
  artifact filesystem, or the real `Export.Runner`/`Export.Worker`: only the
  real production composition runs.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}
  @password "valid user password 123456"
  @wait_ms 5_000
  @child_deadline_ms 5_000

  @not_found_message "Export resource not found."
  @not_ready_message "Export is not ready. Check export status before retrying."
  @unavailable_message "Export is unavailable. Check export status before retrying."
  @service_message "Export service is unavailable. Try again later."

  @serialized_keys ~w(
    created_at download_path expires_at failure_code finished_at id
    sha256 size_bytes state version_id export_type
  )

  setup do
    root =
      Path.join(System.tmp_dir!(), "pathways-export-api-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      # A real worker must finish before the sandbox connection and the
      # temporary artifact root disappear.
      wait_for_runner_children()
      File.rm_rf(root)

      if old_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, old_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture(%{password: @password})

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: []
      })

    %{
      root: root,
      organization: organization,
      version: version,
      user: user,
      membership: membership
    }
  end

  # ---------------------------------------------------------------------------
  # dedup group — EV-2
  # ---------------------------------------------------------------------------

  describe "active run reuse" do
    @tag export_gate: :dedup
    test "repeated POSTs reuse a run held in building without a second build claim", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      stop_fixture(organization.id, version.id)

      {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :pathways)
      {:ok, building, generation, _token} = ExportRuns.claim(organization.id, run.id, :build)
      children_before = runner_children()

      first = conn |> api_conn(user, organization) |> post(create_path(version.id))
      second = build_conn() |> api_conn(user, organization) |> post(create_path(version.id))
      third = build_conn() |> api_conn(user, organization) |> post(create_path(version.id))

      assert %{"data" => %{"id" => first_id, "state" => "building"}} = json_response(first, 202)
      assert %{"data" => %{"id" => ^first_id, "state" => "building"}} = json_response(second, 202)
      assert %{"data" => %{"id" => ^first_id, "state" => "building"}} = json_response(third, 202)

      assert get_resp_header(first, "location") == [status_path(version.id, first_id)]
      assert get_resp_header(second, "location") == [status_path(version.id, first_id)]

      current = Repo.get!(Run, run.id)
      assert current.lease_generation == generation
      assert current.state == :building
      assert version_runs(organization.id, version.id) == [building.id]
      assert runner_children() == children_before
    end

    @tag export_gate: :dedup
    test "a POST after a terminal run creates a new run under the existing lifecycle", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      {:ok, first} = ExportRuns.create_pending(organization.id, version.id, @actor, :pathways)
      {:ok, _building, generation, token} = ExportRuns.claim(organization.id, first.id, :build)

      {:ok, _failed} =
        ExportRuns.fail_build(organization.id, first.id, generation, token, "no_data")

      response = conn |> api_conn(user, organization) |> post(create_path(version.id))

      assert %{"data" => %{"id" => new_id, "state" => "pending"}} = json_response(response, 202)
      refute new_id == first.id

      assert version_runs(organization.id, version.id) |> Enum.sort() ==
               Enum.sort([first.id, new_id])

      assert get_resp_header(response, "location") == [status_path(version.id, new_id)]
    end
  end

  # ---------------------------------------------------------------------------
  # scope group — EV-3
  # ---------------------------------------------------------------------------

  describe "resource scope" do
    @tag export_gate: :scope
    test "show hides foreign, unknown, wrong-version, full-type and unpublished runs", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_run = ready_run!(foreign_organization.id, foreign_version.id, "foreign bytes")

      other_version = gtfs_version_fixture(organization.id)
      wrong_version_run = ready_run!(organization.id, other_version.id, "wrong version bytes")
      full_run = ready_run!(organization.id, version.id, "full export bytes", :full)

      {:ok, unpublished} =
        Versions.create_staging_gtfs_version(organization.id, %{
          name: "Unpublished export version"
        })

      assert foreign_run.export_type == :pathways
      assert wrong_version_run.export_type == :pathways
      assert full_run.export_type == :full

      foreign_show =
        conn |> api_conn(user, organization) |> get(status_path(version.id, foreign_run.id))

      unknown_show =
        conn |> api_conn(user, organization) |> get(status_path(version.id, Ecto.UUID.generate()))

      wrong_version_show =
        conn |> api_conn(user, organization) |> get(status_path(version.id, wrong_version_run.id))

      full_type_show =
        conn |> api_conn(user, organization) |> get(status_path(version.id, full_run.id))

      unpublished_show =
        conn
        |> api_conn(user, organization)
        |> get(status_path(unpublished.id, full_run.id))

      for response <- [
            foreign_show,
            unknown_show,
            wrong_version_show,
            full_type_show,
            unpublished_show
          ] do
        assert %{"error" => %{"code" => "not_found", "message" => @not_found_message}} =
                 json_response(response, 404)
      end

      # The hidden rows are untouched by a rejected read.
      assert %Run{state: :ready} = Repo.get!(Run, full_run.id)
      assert %Run{state: :ready} = Repo.get!(Run, wrong_version_run.id)

      assert %Run{state: :ready} =
               ExportRuns.get_for_version(
                 foreign_organization.id,
                 foreign_version.id,
                 foreign_run.id
               )

      assert %Run{download_count: 0} = Repo.get!(Run, full_run.id)
    end

    @tag export_gate: :scope
    test "download hides foreign, unknown, wrong-version, full-type and unpublished runs", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_run = ready_run!(foreign_organization.id, foreign_version.id, "foreign bytes")

      other_version = gtfs_version_fixture(organization.id)
      wrong_version_run = ready_run!(organization.id, other_version.id, "wrong version bytes")
      full_run = ready_run!(organization.id, version.id, "full export bytes", :full)

      {:ok, unpublished} =
        Versions.create_staging_gtfs_version(organization.id, %{
          name: "Unpublished export version"
        })

      foreign_download =
        conn |> api_conn(user, organization) |> get(download_path(version.id, foreign_run.id))

      unknown_download =
        conn
        |> api_conn(user, organization)
        |> get(download_path(version.id, Ecto.UUID.generate()))

      wrong_version_download =
        conn
        |> api_conn(user, organization)
        |> get(download_path(version.id, wrong_version_run.id))

      full_type_download =
        conn |> api_conn(user, organization) |> get(download_path(version.id, full_run.id))

      unpublished_download =
        conn
        |> api_conn(user, organization)
        |> get(download_path(unpublished.id, full_run.id))

      for response <- [
            foreign_download,
            unknown_download,
            wrong_version_download,
            full_type_download,
            unpublished_download
          ] do
        assert %{"error" => %{"code" => "not_found", "message" => @not_found_message}} =
                 json_response(response, 404)
      end

      assert %Run{state: :ready, download_count: 0, download_claimed_until: nil} =
               Repo.get!(Run, full_run.id)

      assert %Run{state: :ready, download_count: 0, download_claimed_until: nil} =
               Repo.get!(Run, wrong_version_run.id)

      assert %Run{state: :ready, download_count: 0, download_claimed_until: nil} =
               Repo.get!(Run, foreign_run.id)
    end

    @tag export_gate: :scope
    test "denied POSTs insert no run row", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)

      {:ok, unpublished} =
        Versions.create_staging_gtfs_version(organization.id, %{
          name: "Unpublished create version"
        })

      before = run_count(organization.id)

      foreign = conn |> api_conn(user, organization) |> post(create_path(foreign_version.id))

      unpublished_create =
        conn |> api_conn(user, organization) |> post(create_path(unpublished.id))

      unknown = conn |> api_conn(user, organization) |> post(create_path(Ecto.UUID.generate()))

      for response <- [foreign, unpublished_create, unknown] do
        assert %{"error" => %{"code" => "not_found", "message" => @not_found_message}} =
                 json_response(response, 404)
      end

      assert run_count(organization.id) == before
      assert version_runs(organization.id, version.id) == []
      assert run_count(foreign_organization.id) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # policy group — EV-4
  # ---------------------------------------------------------------------------

  describe "membership policy" do
    @tag export_gate: :policy
    test "an active member without roles uses create, show and download", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user,
      membership: membership
    } do
      stop_fixture(organization.id, version.id)
      run = ready_run!(organization.id, version.id, "member bytes")

      assert membership.roles == []

      created = conn |> api_conn(user, organization) |> post(create_path(version.id))

      assert %{"data" => %{"id" => _id, "export_type" => "pathways"}} =
               json_response(created, 202)

      shown = build_conn() |> api_conn(user, organization) |> get(status_path(version.id, run.id))
      assert %{"data" => %{"state" => "ready"}} = json_response(shown, 200)

      downloaded =
        build_conn() |> api_conn(user, organization) |> get(download_path(version.id, run.id))

      assert downloaded.status == 200
      assert downloaded.resp_body == "member bytes"
    end

    @tag export_gate: :policy
    test "an anonymous request is denied on every route", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      run = ready_run!(organization.id, version.id, "denied bytes")
      before = run_count(organization.id)

      created = conn |> anonymous_conn() |> post(create_path(version.id))
      shown = conn |> anonymous_conn() |> get(status_path(version.id, run.id))
      downloaded = conn |> anonymous_conn() |> get(download_path(version.id, run.id))

      for response <- [created, shown, downloaded] do
        assert %{"error" => %{"code" => "unauthorized"}} = json_response(response, 401)
      end

      assert run_count(organization.id) == before
    end

    @tag export_gate: :policy
    test "an invalid bearer is denied on every route", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      run = ready_run!(organization.id, version.id, "invalid token bytes")
      before = run_count(organization.id)

      created = conn |> invalid_bearer_conn() |> post(create_path(version.id))
      shown = conn |> invalid_bearer_conn() |> get(status_path(version.id, run.id))
      downloaded = conn |> invalid_bearer_conn() |> get(download_path(version.id, run.id))

      for response <- [created, shown, downloaded] do
        assert %{"error" => %{"code" => "unauthorized"}} = json_response(response, 401)
      end

      assert run_count(organization.id) == before
    end

    @tag export_gate: :policy
    test "a deactivated member is denied on every route", %{
      organization: organization,
      version: version,
      user: user
    } do
      run = ready_run!(organization.id, version.id, "deactivated bytes")
      other_version = gtfs_version_fixture(organization.id)
      ready_run!(organization.id, other_version.id, "untouched bytes")
      before = run_count(organization.id)

      assert {:ok, _membership} =
               Organizations.deactivate_user_in_organization(user.id, organization.id)

      created = build_conn() |> api_conn(user, organization) |> post(create_path(version.id))
      shown = build_conn() |> api_conn(user, organization) |> get(status_path(version.id, run.id))

      downloaded =
        build_conn() |> api_conn(user, organization) |> get(download_path(version.id, run.id))

      for response <- [created, shown, downloaded] do
        assert %{"error" => %{"code" => "forbidden"}} = json_response(response, 403)
      end

      assert run_count(organization.id) == before
    end

    @tag export_gate: :policy
    test "an explicitly selected non-member organization is denied on every route", %{
      organization: organization,
      version: version,
      user: user
    } do
      run = ready_run!(organization.id, version.id, "other tenant bytes")
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      created =
        build_conn() |> api_conn(user, other_organization) |> post(create_path(other_version.id))

      shown =
        build_conn()
        |> api_conn(user, other_organization)
        |> get(status_path(version.id, run.id))

      downloaded =
        build_conn()
        |> api_conn(user, other_organization)
        |> get(download_path(version.id, run.id))

      for response <- [created, shown, downloaded] do
        assert %{"error" => %{"code" => "forbidden"}} = json_response(response, 403)
      end

      assert run_count(organization.id) == 1
      assert run_count(other_organization.id) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # serialization group — EV-5
  # ---------------------------------------------------------------------------

  describe "serialization" do
    @tag export_gate: :serialization
    test "create returns 202, a status Location, the allowlisted body, and a durable ready run",
         %{conn: conn, organization: organization, version: version, user: user} do
      stop_fixture(organization.id, version.id)

      response = conn |> api_conn(user, organization) |> post(create_path(version.id))

      assert %{"data" => data} = json_response(response, 202)
      run_id = data["id"]
      assert get_resp_header(response, "location") == [status_path(version.id, run_id)]
      assert Map.keys(data) |> Enum.sort() == Enum.sort(@serialized_keys)
      assert data["version_id"] == version.id
      assert data["export_type"] == "pathways"
      assert data["state"] in ["pending", "building"]

      ready = await_terminal_run(organization.id, version.id, run_id)
      assert ready.state == :ready

      shown = build_conn() |> api_conn(user, organization) |> get(status_path(version.id, run_id))
      assert %{"data" => shown_data} = json_response(shown, 200)
      assert Map.keys(shown_data) |> Enum.sort() == Enum.sort(@serialized_keys)
      assert shown_data["state"] == "ready"
      assert shown_data["finished_at"]
      assert shown_data["download_path"] == download_path(version.id, run_id)
      assert shown_data["size_bytes"] == ready.artifact_size_bytes
      assert shown_data["size_bytes"] > 0
      assert shown_data["sha256"] == ready.artifact_sha256
      assert shown_data["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert shown_data["expires_at"] == DateTime.to_iso8601(ready.artifact_expires_at)
    end

    @tag export_gate: :serialization
    test "show emits exactly the documented keys for all seven stored states", %{
      conn: conn,
      organization: organization,
      user: user
    } do
      pending_version = gtfs_version_fixture(organization.id)
      building_version = gtfs_version_fixture(organization.id)
      ready_version = gtfs_version_fixture(organization.id)
      failed_version = gtfs_version_fixture(organization.id)
      interrupted_version = gtfs_version_fixture(organization.id)
      cancelled_version = gtfs_version_fixture(organization.id)
      expired_version = gtfs_version_fixture(organization.id)

      pending_run = state_run!(organization.id, pending_version, :pending)
      building_run = state_run!(organization.id, building_version, :building)
      ready_run = state_run!(organization.id, ready_version, :ready)
      failed_run = state_run!(organization.id, failed_version, :failed)
      interrupted_run = state_run!(organization.id, interrupted_version, :interrupted)
      cancelled_run = state_run!(organization.id, cancelled_version, :cancelled)
      expired_run = state_run!(organization.id, expired_version, :expired)

      pending =
        conn
        |> api_conn(user, organization)
        |> get(status_path(pending_version.id, pending_run.id))

      building =
        conn
        |> api_conn(user, organization)
        |> get(status_path(building_version.id, building_run.id))

      ready =
        conn |> api_conn(user, organization) |> get(status_path(ready_version.id, ready_run.id))

      failed =
        conn |> api_conn(user, organization) |> get(status_path(failed_version.id, failed_run.id))

      interrupted =
        conn
        |> api_conn(user, organization)
        |> get(status_path(interrupted_version.id, interrupted_run.id))

      cancelled =
        conn
        |> api_conn(user, organization)
        |> get(status_path(cancelled_version.id, cancelled_run.id))

      expired =
        conn
        |> api_conn(user, organization)
        |> get(status_path(expired_version.id, expired_run.id))

      assert %{"data" => pending_data} = json_response(pending, 200)
      assert %{"data" => building_data} = json_response(building, 200)
      assert %{"data" => ready_data} = json_response(ready, 200)
      assert %{"data" => failed_data} = json_response(failed, 200)
      assert %{"data" => interrupted_data} = json_response(interrupted, 200)
      assert %{"data" => cancelled_data} = json_response(cancelled, 200)
      assert %{"data" => expired_data} = json_response(expired, 200)

      for {data, version, run, state} <- [
            {pending_data, pending_version, pending_run, "pending"},
            {building_data, building_version, building_run, "building"},
            {ready_data, ready_version, ready_run, "ready"},
            {failed_data, failed_version, failed_run, "failed"},
            {interrupted_data, interrupted_version, interrupted_run, "interrupted"},
            {cancelled_data, cancelled_version, cancelled_run, "cancelled"},
            {expired_data, expired_version, expired_run, "expired"}
          ] do
        assert Map.keys(data) |> Enum.sort() == Enum.sort(@serialized_keys)
        assert data["id"] == run.id
        assert data["version_id"] == version.id
        assert data["export_type"] == "pathways"
        assert data["state"] == state
        assert data["created_at"] == DateTime.to_iso8601(run.inserted_at)
      end

      assert pending_data["finished_at"] == nil
      assert building_data["finished_at"] == nil
      assert ready_data["finished_at"] == DateTime.to_iso8601(ready_run.finished_at)
      assert failed_data["finished_at"] == DateTime.to_iso8601(failed_run.finished_at)
      assert interrupted_data["finished_at"] == DateTime.to_iso8601(interrupted_run.finished_at)
      assert cancelled_data["finished_at"] == DateTime.to_iso8601(cancelled_run.finished_at)
      assert expired_data["finished_at"] == DateTime.to_iso8601(expired_run.finished_at)

      assert pending_data["failure_code"] == nil
      assert building_data["failure_code"] == nil
      assert ready_data["failure_code"] == nil
      assert failed_data["failure_code"] == "no_data"
      assert interrupted_data["failure_code"] == "lease_expired"
      assert cancelled_data["failure_code"] == "cancel_requested"
      assert expired_data["failure_code"] == "artifact_expired"

      assert ready_data["expires_at"] == DateTime.to_iso8601(ready_run.artifact_expires_at)
      assert ready_data["size_bytes"] == ready_run.artifact_size_bytes
      assert ready_data["sha256"] == ready_run.artifact_sha256
      assert ready_data["download_path"] == download_path(ready_version.id, ready_run.id)

      for data <- [
            pending_data,
            building_data,
            failed_data,
            interrupted_data,
            cancelled_data,
            expired_data
          ] do
        assert data["expires_at"] == nil
        assert data["size_bytes"] == nil
        assert data["sha256"] == nil
        assert data["download_path"] == nil
      end
    end

    @tag export_gate: :serialization
    test "an expired row reports artifact_expired with null ready-only fields", %{
      organization: organization,
      user: user
    } do
      version = gtfs_version_fixture(organization.id)
      run = state_run!(organization.id, version, :expired)
      assert run.failure_code == "artifact_expired"

      response =
        build_conn() |> api_conn(user, organization) |> get(status_path(version.id, run.id))

      assert %{"data" => data} = json_response(response, 200)
      assert data["state"] == "expired"
      assert data["failure_code"] == "artifact_expired"
      assert data["sha256"] == nil
      assert data["size_bytes"] == nil
      assert data["expires_at"] == nil
      assert data["download_path"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # download group — EV-6
  # ---------------------------------------------------------------------------

  describe "download" do
    @tag export_gate: :download
    test "streams the stored bytes with private headers and completes the claim", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      bytes = "stored pathways zip bytes"
      run = ready_run!(organization.id, version.id, bytes)

      response =
        conn |> api_conn(user, organization) |> get(download_path(version.id, run.id))

      assert response.status == 200
      assert response.resp_body == bytes
      assert [content_type] = get_resp_header(response, "content-type")
      assert content_type =~ "application/zip"
      assert get_resp_header(response, "content-length") == [Integer.to_string(byte_size(bytes))]
      assert get_resp_header(response, "cache-control") == ["private, no-store"]
      assert [disposition] = get_resp_header(response, "content-disposition")
      assert disposition == ~s(attachment; filename="network.zip")

      assert %Run{download_count: 1, download_claimed_until: nil, last_downloaded_at: stamp} =
               ExportRuns.get_for_version(organization.id, version.id, run.id)

      assert stamp

      assert Base.encode16(:crypto.hash(:sha256, response.resp_body), case: :lower) ==
               run.artifact_sha256
    end

    @tag export_gate: :download
    test "a held claim gives status-first 409 guidance and the same run downloads afterwards", %{
      organization: organization,
      version: version,
      user: user
    } do
      run = ready_run!(organization.id, version.id, "contended bytes")
      before = run_count(organization.id)

      assert {:ok, claim} = ExportRuns.claim_download(organization.id, version.id, run.id)

      response =
        build_conn() |> api_conn(user, organization) |> get(download_path(version.id, run.id))

      assert %{"error" => %{"code" => "download_unavailable", "message" => @unavailable_message}} =
               json_response(response, 409)

      assert run_count(organization.id) == before
      assert %Run{state: :ready} = ExportRuns.get_for_version(organization.id, version.id, run.id)

      assert :ok =
               ExportRuns.complete_download(organization.id, version.id, run.id, claim.claim_id)

      retried =
        build_conn() |> api_conn(user, organization) |> get(download_path(version.id, run.id))

      assert retried.status == 200
      assert retried.resp_body == "contended bytes"
    end

    @tag export_gate: :download
    test "pending and building runs give the not-ready 409 and start no build", %{
      organization: organization,
      version: version,
      user: user
    } do
      stop_fixture(organization.id, version.id)
      other_version = gtfs_version_fixture(organization.id)
      {:ok, pending} = ExportRuns.create_pending(organization.id, version.id, @actor, :pathways)

      {:ok, building} =
        ExportRuns.create_pending(organization.id, other_version.id, @actor, :pathways)

      {:ok, _run, _generation, _token} = ExportRuns.claim(organization.id, building.id, :build)
      before = run_count(organization.id)

      pending_response =
        build_conn() |> api_conn(user, organization) |> get(download_path(version.id, pending.id))

      building_response =
        build_conn()
        |> api_conn(user, organization)
        |> get(download_path(other_version.id, building.id))

      assert %{"error" => %{"code" => "export_not_ready", "message" => @not_ready_message}} =
               json_response(pending_response, 409)

      assert %{"error" => %{"code" => "export_not_ready", "message" => @not_ready_message}} =
               json_response(building_response, 409)

      assert run_count(organization.id) == before
      assert DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Export.RunnerSupervisor) == []
    end

    @tag export_gate: :download
    test "a terminal non-ready run gives the unavailable 409, creates no run and starts no build",
         %{
           organization: organization,
           user: user
         } do
      before = run_count(organization.id)

      for state <- [:failed, :interrupted, :cancelled, :expired] do
        version = gtfs_version_fixture(organization.id)
        run = state_run!(organization.id, version, state)

        response =
          build_conn() |> api_conn(user, organization) |> get(download_path(version.id, run.id))

        assert %{
                 "error" => %{"code" => "download_unavailable", "message" => @unavailable_message}
               } =
                 json_response(response, 409)

        assert %Run{state: ^state, download_count: 0, download_claimed_until: nil} =
                 ExportRuns.get_for_version(organization.id, version.id, run.id)
      end

      assert run_count(organization.id) == before + 4
      assert runner_children() == []
    end

    @tag export_gate: :download
    test "an expired artifact gives the terminal 409 code", %{
      organization: organization,
      version: version,
      user: user
    } do
      run = ready_run!(organization.id, version.id, "expired bytes")
      force_state(run, :ready, %{artifact_expires_at: past()})

      response =
        build_conn() |> api_conn(user, organization) |> get(download_path(version.id, run.id))

      assert %{"error" => %{"code" => "download_unavailable", "message" => @unavailable_message}} =
               json_response(response, 409)

      assert %Run{state: :ready, download_count: 0, download_claimed_until: nil} =
               Repo.get!(Run, run.id)
    end

    @tag export_gate: :download
    test "a corrupt artifact gives the terminal 409 code and turns the row failed", %{
      organization: organization,
      version: version,
      user: user
    } do
      run = ready_run!(organization.id, version.id, "corrupt bytes")
      path = artifact_path!(organization.id, version.id, run.id)
      File.write!(path, "altered bytes")

      response =
        build_conn() |> api_conn(user, organization) |> get(download_path(version.id, run.id))

      assert %{"error" => %{"code" => "download_unavailable", "message" => @unavailable_message}} =
               json_response(response, 409)

      assert %Run{state: :failed, failure_code: "missing_or_corrupt_artifact"} =
               ExportRuns.get_for_version(organization.id, version.id, run.id)

      shown =
        build_conn() |> api_conn(user, organization) |> get(status_path(version.id, run.id))

      assert %{"data" => %{"state" => "failed", "failure_code" => "missing_or_corrupt_artifact"}} =
               json_response(shown, 200)
    end

    @tag export_gate: :download
    test "a bare application/zip Accept header keeps the existing 406", %{
      organization: organization,
      version: version,
      user: user
    } do
      run = ready_run!(organization.id, version.id, "zip accept bytes")

      assert_error_sent 406, fn ->
        build_conn()
        |> api_conn(user, organization)
        |> put_req_header("accept", "application/zip")
        |> get(download_path(version.id, run.id))
      end

      assert %Run{download_count: 0, download_claimed_until: nil} =
               ExportRuns.get_for_version(organization.id, version.id, run.id)
    end
  end

  # ---------------------------------------------------------------------------
  # errors group — EV-8
  # ---------------------------------------------------------------------------

  describe "errors" do
    @tag export_gate: :errors
    test "malformed route identifiers return 400 bad_request JSON", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      unknown_id = Ecto.UUID.generate()

      create_malformed = conn |> api_conn(user, organization) |> post(create_path("not-a-uuid"))

      show_malformed_version =
        conn |> api_conn(user, organization) |> get(status_path("not-a-uuid", unknown_id))

      show_malformed_id =
        conn |> api_conn(user, organization) |> get(status_path(version.id, "not-a-uuid"))

      download_malformed_version =
        conn
        |> api_conn(user, organization)
        |> get(download_path("not-a-uuid", unknown_id))

      download_malformed_id =
        conn |> api_conn(user, organization) |> get(download_path(version.id, "not-a-uuid"))

      for response <- [
            create_malformed,
            show_malformed_version,
            show_malformed_id,
            download_malformed_version,
            download_malformed_id
          ] do
        assert %{"error" => %{"code" => "bad_request", "message" => "Invalid ID format."}} =
                 json_response(response, 400)
      end
    end

    @tag export_gate: :errors
    test "unavailable artifact storage returns 503 and inserts no pending row", %{
      root: root,
      organization: organization,
      version: version,
      user: user
    } do
      blocker = Path.join(root, "not-a-directory")
      File.write!(blocker, "regular file")
      put_artifacts_root(Path.join(blocker, "artifacts"))

      response = build_conn() |> api_conn(user, organization) |> post(create_path(version.id))

      assert %{"error" => %{"code" => "export_unavailable", "message" => @service_message}} =
               json_response(response, 503)

      assert version_runs(organization.id, version.id) == []
      assert run_count(organization.id) == 0
    end

    @tag export_gate: :errors
    test "a tiny capacity limit reaches a durable failed run after 202", %{
      organization: organization,
      version: version,
      user: user
    } do
      stop_fixture(organization.id, version.id)
      put_max_total_bytes(1)

      response = build_conn() |> api_conn(user, organization) |> post(create_path(version.id))
      assert %{"data" => %{"id" => run_id, "state" => state}} = json_response(response, 202)
      assert state in ["pending", "building"]

      failed = await_terminal_run(organization.id, version.id, run_id)
      assert failed.state == :failed
      assert failed.failure_code == "artifact_capacity_exceeded"

      shown = build_conn() |> api_conn(user, organization) |> get(status_path(version.id, run_id))

      assert %{"data" => %{"state" => "failed", "failure_code" => "artifact_capacity_exceeded"}} =
               json_response(shown, 200)
    end

    @tag export_gate: :errors
    test "an empty version reaches a durable failed run with no_data", %{
      organization: organization,
      version: version,
      user: user
    } do
      response = build_conn() |> api_conn(user, organization) |> post(create_path(version.id))
      assert %{"data" => %{"id" => run_id}} = json_response(response, 202)

      failed = await_terminal_run(organization.id, version.id, run_id)
      assert failed.state == :failed
      assert failed.failure_code == "no_data"

      shown = build_conn() |> api_conn(user, organization) |> get(status_path(version.id, run_id))

      assert %{"data" => %{"state" => "failed", "failure_code" => "no_data"}} =
               json_response(shown, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp api_conn(conn, user, organization) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{Accounts.generate_api_session_token(user)}")
    |> put_req_header("x-organization-id", organization.id)
  end

  defp anonymous_conn(conn), do: put_req_header(conn, "accept", "application/json")

  defp invalid_bearer_conn(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer not-a-real-token")
  end

  defp create_path(version_id), do: "/api/v1/versions/#{version_id}/pathways-exports"

  defp status_path(version_id, export_id),
    do: "/api/v1/versions/#{version_id}/pathways-exports/#{export_id}"

  defp download_path(version_id, export_id), do: "#{status_path(version_id, export_id)}/download"

  defp ready_run!(organization_id, version_id, bytes, export_type \\ :pathways) do
    {:ok, run} = ExportRuns.create_pending(organization_id, version_id, @actor, export_type)
    {:ok, _building, generation, token} = ExportRuns.claim(organization_id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization_id, version_id, run.id, "network.zip", bytes)

    {:ok, ready} = ExportRuns.mark_ready(organization_id, run.id, generation, token, artifact)
    ready
  end

  defp state_run!(organization_id, version, state) do
    {:ok, run} = ExportRuns.create_pending(organization_id, version.id, @actor, :pathways)

    case state do
      :pending ->
        run

      :building ->
        {:ok, _building, _generation, _token} = ExportRuns.claim(organization_id, run.id, :build)
        Repo.get!(Run, run.id)

      :ready ->
        ready_run!(organization_id, version.id, "ready export bytes")

      other ->
        force_state(run, other, %{
          failure_code: failure_code_for(other),
          started_at: now(),
          finished_at: now(),
          lease_token: nil,
          lease_expires_at: nil,
          artifact_key: nil,
          artifact_filename: nil,
          artifact_sha256: nil,
          artifact_size_bytes: nil,
          artifact_expires_at: nil,
          download_claimed_until: nil
        })
    end
  end

  defp failure_code_for(:failed), do: "no_data"
  defp failure_code_for(:interrupted), do: "lease_expired"
  defp failure_code_for(:cancelled), do: "cancel_requested"
  defp failure_code_for(:expired), do: "artifact_expired"

  defp force_state(run, state, attrs) do
    run
    |> Run.system_changeset(%{state: state} |> Map.merge(attrs))
    |> Repo.update!()
  end

  defp past, do: ~U[2000-01-01 00:00:00.000000Z]
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp artifact_path!(organization_id, version_id, run_id) do
    {:ok, claim} = ExportRuns.claim_download(organization_id, version_id, run_id)
    assert :ok = ExportRuns.complete_download(organization_id, version_id, run_id, claim.claim_id)
    claim.path
  end

  defp version_runs(organization_id, version_id) do
    from(r in Run,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id
    )
    |> Repo.all()
    |> Enum.map(& &1.id)
  end

  defp run_count(organization_id) do
    from(r in Run, where: r.organization_id == ^organization_id) |> Repo.aggregate(:count)
  end

  defp runner_children,
    do: DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Export.RunnerSupervisor)

  defp wait_for_runner_children do
    for {_id, pid, _type, _mods} <-
          DynamicSupervisor.which_children(GtfsPlanner.Gtfs.Export.RunnerSupervisor) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        @child_deadline_ms -> kill_runner_child(pid, ref)
      end
    end

    :ok
  end

  # :kill is untrappable, so both DOWNs below are guaranteed to arrive. The
  # runner's build task (its `task_pid`) holds the sandboxed DB connection, so
  # it must be confirmed dead too before teardown reclaims the connection and
  # the temporary artifact root.
  defp kill_runner_child(pid, ref) do
    task_pid = runner_task_pid(pid)
    task_ref = task_pid && Process.monitor(task_pid)

    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    if task_ref do
      receive do
        {:DOWN, ^task_ref, :process, ^task_pid, _reason} -> :ok
      end
    end
  end

  defp runner_task_pid(pid) do
    %{task_pid: task_pid} = :sys.get_state(pid, @child_deadline_ms)
    task_pid
  catch
    :exit, _ -> nil
  end

  # Durable-state wait. Subscribing before the first read and re-reading after
  # every broadcast keeps this deterministic. The deadline bounds a lost
  # message, but once it passes with the run still non-terminal, that is a
  # failure: flunk with the run's current state instead of spinning.
  defp await_terminal_run(organization_id, version_id, run_id, timeout \\ @wait_ms) do
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ExportRuns.topic(run_id))
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(organization_id, version_id, run_id, deadline)
  end

  defp do_await(organization_id, version_id, run_id, deadline) do
    run = ExportRuns.get_for_version(organization_id, version_id, run_id)

    cond do
      run.state in [:ready, :failed, :interrupted, :cancelled, :expired] ->
        run

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "pathways export run #{run_id} did not reach a terminal state before the deadline; " <>
            "state=#{inspect(run.state)} failure_code=#{inspect(run.failure_code)}"
        )

      true ->
        wait_for_change(run_id, deadline)
        do_await(organization_id, version_id, run_id, deadline)
    end
  end

  defp wait_for_change(run_id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:export_run_changed, ^run_id} -> :ok
    after
      remaining -> :ok
    end
  end

  defp put_artifacts_root(path) do
    old = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, path)

    on_exit(fn ->
      if old,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, old),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)
  end

  defp put_max_total_bytes(value) do
    old = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes, value)

    on_exit(fn ->
      if old,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes, old),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes)
    end)
  end
end
