defmodule GtfsPlannerWeb.Api.V1.VersionControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  @password "valid user password 123456"
  @unauthorized_json %{"error" => %{"code" => "unauthorized"}}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_user_with_org(_context) do
    user = user_fixture(%{password: @password})
    org = organization_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    %{user: user, org: org}
  end

  defp authed_conn(conn, user, org_id \\ nil) do
    token = Accounts.generate_api_session_token(user)

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> then(fn conn ->
      if org_id, do: put_req_header(conn, "x-organization-id", org_id), else: conn
    end)
  end

  defp session_conn(conn, token, org_id) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-organization-id", org_id)
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

    test "login session token plus X-Organization-Id returns only the selected org versions",
         %{conn: conn, user: user, org: org} do
      selected_version = gtfs_version_fixture(org.id, %{name: "Selected Org Version"})

      other_org = organization_fixture()

      {:ok, _other_membership} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: other_org.id,
          roles: ["pathways_studio_editor"]
        })

      other_version = gtfs_version_fixture(other_org.id, %{name: "Other Org Version"})

      login =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> post("/api/v1/auth/login", %{"email" => user.email, "password" => @password})

      assert %{"data" => %{"token" => token}} = json_response(login, 200)

      versions =
        build_conn()
        |> session_conn(token, org.id)
        |> get("/api/v1/versions")

      assert %{"data" => data} = json_response(versions, 200)
      ids = Enum.map(data, & &1["id"])
      assert selected_version.id in ids
      refute other_version.id in ids

      entry = Enum.find(data, &(&1["id"] == selected_version.id))
      assert entry["name"] == "Selected Org Version"
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
      assert json_response(conn, 401) == @unauthorized_json
    end

    test "returns 401 for Bearer GtfsPlanner.V1.<payload> with no authenticated assigns",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer GtfsPlanner.V1.some-legacy-key-material")
        |> get("/api/v1/versions")

      assert conn.status == 401
      assert json_response(conn, 401) == @unauthorized_json
      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :current_user_id)
      refute Map.has_key?(conn.assigns, :api_session_token)
      refute Map.has_key?(conn.assigns, :current_api_key)
    end
  end
end
