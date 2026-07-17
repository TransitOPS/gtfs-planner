defmodule GtfsPlannerWeb.Api.V1.VersionControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_user_with_org(_context) do
    user = user_fixture()
    org = organization_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    %{user: user, org: org}
  end

  defp authed_conn(conn, user) do
    token = Accounts.generate_api_session_token(user)

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/versions
  # ---------------------------------------------------------------------------

  describe "index/2" do
    setup [:setup_user_with_org]

    test "returns versions for the authenticated user's org", %{conn: conn, user: user, org: org} do
      v1 = gtfs_version_fixture(org.id, %{name: "Version A"})
      v2 = gtfs_version_fixture(org.id, %{name: "Version B"})

      conn = conn |> authed_conn(user) |> get("/api/v1/versions")

      assert %{"data" => data} = json_response(conn, 200)
      ids = Enum.map(data, & &1["id"])
      assert v1.id in ids
      assert v2.id in ids

      # Verify shape of each entry
      entry = Enum.find(data, &(&1["id"] == v1.id))
      assert entry["name"] == "Version A"
      assert is_binary(entry["created_at"])
    end

    test "does not return versions from other orgs", %{conn: conn, user: user} do
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      conn = conn |> authed_conn(user) |> get("/api/v1/versions")

      assert %{"data" => data} = json_response(conn, 200)
      ids = Enum.map(data, & &1["id"])
      refute other_version.id in ids
    end

    test "lists only published versions, excluding staging, importing, and failed", %{
      conn: conn,
      user: user,
      org: org
    } do
      published = gtfs_version_fixture(org.id, %{name: "Published"})

      {:ok, staging} = Versions.create_staging_gtfs_version(org.id, %{name: "Staging"})

      {:ok, importing_staging} =
        Versions.create_staging_gtfs_version(org.id, %{name: "Importing"})

      {:ok, importing} = Versions.claim_staging_gtfs_version(org.id, importing_staging.id)

      {:ok, failed_staging} = Versions.create_staging_gtfs_version(org.id, %{name: "Failed"})
      {:ok, failed} = Versions.fail_unpublished_gtfs_version(org.id, failed_staging.id)

      conn = conn |> authed_conn(user) |> get("/api/v1/versions")

      assert %{"data" => data} = json_response(conn, 200)
      ids = Enum.map(data, & &1["id"])

      assert published.id in ids
      refute staging.id in ids
      refute importing.id in ids
      refute failed.id in ids
    end

    test "returns 401 without auth token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/versions")

      assert conn.status == 401
    end
  end
end
