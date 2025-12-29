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

      assert redirect_path != "/organizations"
      assert flash["error"] =~ "authorized"
    end
  end
end
