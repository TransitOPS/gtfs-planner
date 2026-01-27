defmodule GtfsPlannerWeb.AccessControlTest do
  @moduledoc """
  Tests for role-based access control across LiveViews.
  """
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  setup %{conn: conn} do
    # Create organization and user fixtures
    organization = organization_fixture()
    user = user_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    # Create initial membership (will be updated by individual tests)
    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: []
    })

    # Log in the user and set organization in session
    conn =
      conn
      |> log_in_user(user)
      |> Plug.Conn.put_session(:organization_id, organization.id)

    %{conn: conn, user: user, organization: organization, gtfs_version: gtfs_version}
  end

  @doc """
  Helper function to add roles to a user for an organization.

  Creates a new membership if one doesn't exist, or updates existing one.

  ## Examples

      add_role(user, organization, [:pathways_studio_admin])
      add_role(user, organization, [:pathways_studio_editor])
  """
  def add_role(user, organization, roles) when is_list(roles) do
    role_strings = Enum.map(roles, &Atom.to_string/1)

    case Accounts.get_user_org_membership(user.id, organization.id) do
      nil ->
        {:ok, membership} =
          Accounts.create_user_org_membership(%{
            user_id: user.id,
            organization_id: organization.id,
            roles: role_strings
          })

        membership

      membership ->
        {:ok, membership} =
          Accounts.update_user_org_membership(membership, %{roles: role_strings})

        membership
    end
  end

  describe "administrator role" do
    test "administrator can access /admin/organizations", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      add_role(user, organization, [:administrator])

      {:ok, _view, html} = live(conn, ~p"/admin/organizations")

      assert html =~ "Organizations"
    end

    test "non-administrator cannot access /admin/organizations", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      add_role(user, organization, [:pathways_studio_admin])

      assert {:error, {:redirect, %{to: redirect_path, flash: flash}}} =
               live(conn, ~p"/admin/organizations")

      assert redirect_path == "/"
      assert flash["error"] =~ "authorized"
    end
  end

  describe "pathways_studio_admin role" do
    test "admin can access /admin/users", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_admin])

      {:ok, _view, html} = live(conn, ~p"/admin/users")

      assert html =~ "Manage Users"
    end

    test "editor cannot access /admin/users", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      add_role(user, organization, [:pathways_studio_editor])

      assert {:error, {:redirect, %{to: redirect_path, flash: flash}}} =
               live(conn, ~p"/admin/users")

      assert redirect_path != "/admin/users"
      assert flash["error"] =~ "authorized"
    end
  end

  describe "GTFS editor role" do
    test "editor can access import", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      add_role(user, organization, [:pathways_studio_editor])

      {:ok, _view, html} = live(conn, ~p"/gtfs/#{gtfs_version.id}/import")

      assert html =~ "Import GTFS"
    end
    test "editor can access stops", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      add_role(user, organization, [:pathways_studio_editor])

      {:ok, _view, html} = live(conn, ~p"/gtfs/#{gtfs_version.id}/stops")

      assert html =~ "Stations"
    end

    test "editor can access export", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      add_role(user, organization, [:pathways_studio_editor])

      {:ok, _view, html} = live(conn, ~p"/gtfs/#{gtfs_version.id}/export")

      assert html =~ "Export GTFS"
    end
  end

  describe "navigation visibility" do
    test "administrator sees Organizations link", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      add_role(user, organization, [:administrator])

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a", "Organizations")
    end

    test "editor sees Import link", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      add_role(user, organization, [:pathways_studio_editor])

      {:ok, view, _html} = live(conn, ~p"/gtfs/#{gtfs_version.id}/stops")

      assert has_element?(view, "a", "Import")
    end
  end
end
