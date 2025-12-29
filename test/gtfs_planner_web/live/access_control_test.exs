defmodule GtfsPlannerWeb.AccessControlTest do
  @moduledoc """
  Tests for role-based access control across LiveViews.
  """
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts

  setup %{conn: conn} do
    # Create organization and user fixtures
    organization = organization_fixture()
    user = user_fixture()

    # Log in the user
    conn = log_in_user(conn, user)

    %{conn: conn, user: user, organization: organization}
  end

  @doc """
  Helper function to add roles to a user for an organization.

  Creates a new membership if one doesn't exist, or updates the existing one.

  ## Role Format

  Roles should be passed as atoms (e.g., `:pathways_studio_admin`, `:administrator`)
  even though they are stored as strings in the database. This helper function automatically
  converts the atom roles to strings to align with the storage format used by the
  `GtfsPlanner.Authorization.Roles` module.

  ## Examples

      add_role(user, organization, [:pathways_studio_admin])
      add_role(user, organization, [:pathways_studio_editor, :pathways_studio_viewer])
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
    test "administrator can access /organizations", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:administrator])

      {:ok, _view, html} = live(conn, ~p"/organizations")

      assert html =~ "Organizations"
    end

    test "non-administrator cannot access /organizations", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_viewer])

      assert {:error, {:redirect, %{to: redirect_path, flash: flash}}} =
               live(conn, ~p"/organizations")

      assert redirect_path == "/"
      assert flash["error"] =~ "authorized"
    end
  end

  describe "pathways_studio_admin role" do
    test "admin can access /organizations/:org/admin/users", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_admin])

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.alias}/admin/users")

      assert html =~ "Manage Users"
    end

    test "viewer cannot access /organizations/:org/admin/users", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_viewer])

      assert {:error, {:redirect, %{to: redirect_path, flash: flash}}} =
               live(conn, ~p"/organizations/#{organization.alias}/admin/users")

      assert redirect_path != "/organizations/#{organization.alias}/admin/users"
      assert flash["error"] =~ "authorized"
    end
  end

  describe "GTFS editor role" do
    test "editor can access import", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_editor])

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.alias}/gtfs/v1/import")

      assert html =~ "Import GTFS"
    end

    test "viewer cannot access import", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_viewer])

      assert {:error, {:redirect, %{to: redirect_path, flash: flash}}} =
               live(conn, ~p"/organizations/#{organization.alias}/gtfs/v1/import")

      assert redirect_path != "/organizations/#{organization.alias}/gtfs/v1/import"
      assert flash["error"] =~ "authorized"
    end
  end

  describe "GTFS viewer role" do
    test "viewer can access stops", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_viewer])

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.alias}/gtfs/v1/stops")

      assert html =~ "Stations"
    end

    test "viewer can access export", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_viewer])

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.alias}/gtfs/v1/export")

      assert html =~ "Export GTFS"
    end

    test "editor can also access stops", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_editor])

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.alias}/gtfs/v1/stops")

      assert html =~ "Stations"
    end
  end

  describe "navigation visibility" do
    test "administrator sees Organizations link", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:administrator])

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "a", "Organizations")
    end

    test "viewer does not see Import link", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_viewer])

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.alias}/gtfs/v1/stops")

      refute has_element?(view, "a", "Import")
    end

    test "editor sees Import link", %{conn: conn, user: user, organization: organization} do
      add_role(user, organization, [:pathways_studio_editor])

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.alias}/gtfs/v1/stops")

      assert has_element?(view, "a", "Import")
    end
  end
end
