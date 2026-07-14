defmodule GtfsPlannerWeb.Plugs.RequireApiEditorTest do
  use GtfsPlannerWeb.ConnCase, async: true

  alias GtfsPlannerWeb.Plugs.RequireApiEditor
  alias GtfsPlanner.Accounts

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  defp membership_fixture(attrs) do
    attrs = Map.new(attrs)
    user = user_fixture()
    organization = organization_fixture()

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: Map.get(attrs, :roles, [])
      })

    membership
  end

  test "continues for an active selected editor membership", %{conn: conn} do
    membership = membership_fixture(roles: ["pathways_studio_editor"])

    conn =
      conn
      |> assign(:current_organization_membership, membership)
      |> RequireApiEditor.call([])

    refute conn.halted
  end

  test "halts with the API forbidden envelope for a selected non-editor membership", %{conn: conn} do
    membership = membership_fixture(roles: [])

    conn =
      conn
      |> assign(:current_organization_membership, membership)
      |> RequireApiEditor.call([])

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "forbidden"}}
  end

  test "fails closed when the selected membership is absent or deactivated", %{conn: conn} do
    missing = RequireApiEditor.call(conn, [])

    assert missing.halted
    assert missing.status == 403

    deactivated = %{
      membership_fixture(roles: ["pathways_studio_editor"])
      | deactivated_at: DateTime.utc_now()
    }

    deactivated_conn =
      conn
      |> assign(:current_organization_membership, deactivated)
      |> RequireApiEditor.call([])

    assert deactivated_conn.halted
    assert deactivated_conn.status == 403
  end
end
