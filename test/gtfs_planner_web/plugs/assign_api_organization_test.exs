defmodule GtfsPlannerWeb.Plugs.AssignApiOrganizationTest do
  use GtfsPlannerWeb.ConnCase, async: true

  alias GtfsPlannerWeb.Plugs.AssignApiOrganization

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    conn = assign(conn, :current_user, user)
    {:ok, conn: conn, user: user}
  end

  describe "single-org user without header" do
    test "assigns their org", %{conn: conn, user: user} do
      org = organization_fixture()

      {:ok, membership} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org.id,
          roles: ["pathways_studio_editor"]
        })

      conn =
        conn
        |> AssignApiOrganization.call([])

      refute conn.halted
      assert conn.assigns[:current_organization_id] == org.id
      assert conn.assigns[:current_organization_membership].id == membership.id
    end
  end

  describe "multi-org user with valid X-Organization-Id" do
    test "assigns that org", %{conn: conn, user: user} do
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, _} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org1.id,
          roles: ["pathways_studio_editor"]
        })

      {:ok, membership2} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org2.id,
          roles: ["pathways_studio_editor"]
        })

      conn =
        conn
        |> put_req_header("x-organization-id", org2.id)
        |> AssignApiOrganization.call([])

      refute conn.halted
      assert conn.assigns[:current_organization_id] == org2.id
      assert conn.assigns[:current_organization_membership].id == membership2.id
    end
  end

  describe "multi-org user without header" do
    test "returns 403 with available org IDs", %{conn: conn, user: user} do
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, _membership1} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org1.id,
          roles: ["pathways_studio_editor"]
        })

      {:ok, _membership2} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org2.id,
          roles: ["pathways_studio_editor"]
        })

      conn = AssignApiOrganization.call(conn, [])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "organization_required"
      assert is_list(body["error"]["available_organization_ids"])
      assert org1.id in body["error"]["available_organization_ids"]
      assert org2.id in body["error"]["available_organization_ids"]
    end
  end

  describe "user with X-Organization-Id for an org they don't belong to" do
    test "returns 403", %{conn: conn, user: user} do
      org = organization_fixture()
      other_org = organization_fixture()

      {:ok, membership1} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org.id,
          roles: ["pathways_studio_editor"]
        })

      conn =
        conn
        |> put_req_header("x-organization-id", other_org.id)
        |> AssignApiOrganization.call([])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "forbidden"
    end
  end

  describe "user with no org memberships" do
    test "returns 403", %{conn: conn} do
      conn = AssignApiOrganization.call(conn, [])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "no_organization"
    end
  end

  describe "user with deactivated membership" do
    test "returns 403 when sole membership is deactivated", %{conn: conn, user: user} do
      org = organization_fixture()

      {:ok, membership} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org.id,
          roles: ["pathways_studio_editor"]
        })

      membership
      |> Ecto.Changeset.change(%{
        deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> GtfsPlanner.Repo.update!()

      conn = AssignApiOrganization.call(conn, [])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "no_organization"
    end

    test "excludes deactivated membership from available orgs", %{conn: conn, user: user} do
      org1 = organization_fixture()
      org2 = organization_fixture()

      {:ok, membership1} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org1.id,
          roles: ["pathways_studio_editor"]
        })

      {:ok, membership2} =
        GtfsPlanner.Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org2.id,
          roles: ["pathways_studio_editor"]
        })

      membership2
      |> Ecto.Changeset.change(%{
        deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> GtfsPlanner.Repo.update!()

      conn = AssignApiOrganization.call(conn, [])

      # Only one active membership, so it auto-assigns
      refute conn.halted
      assert conn.assigns[:current_organization_id] == org1.id
      assert conn.assigns[:current_organization_membership].id == membership1.id
    end
  end
end
