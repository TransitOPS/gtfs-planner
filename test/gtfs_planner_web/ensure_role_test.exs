defmodule GtfsPlannerWeb.EnsureRoleTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlannerWeb.EnsureRole

  import GtfsPlanner.OrganizationsFixtures

  describe "editor_member?/2" do
    test "is true for an active editor of the organization" do
      organization = organization_fixture()
      user = editor_fixture(organization)

      assert EnsureRole.editor_member?(user.id, organization.id)
    end

    test "is false once the membership is deactivated" do
      organization = organization_fixture()
      user = editor_fixture(organization)

      user.id
      |> GtfsPlanner.Accounts.get_user_org_membership(organization.id)
      |> deactivate_membership_fixture()

      refute EnsureRole.editor_member?(user.id, organization.id)
    end

    test "is false for a member without the editor role" do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization, ["pathways_studio_admin"])

      refute EnsureRole.editor_member?(user.id, organization.id)
    end

    test "is false for an editor of another organization" do
      user = editor_fixture(organization_fixture())

      refute EnsureRole.editor_member?(user.id, organization_fixture().id)
    end

    test "is false, rather than raising, when the user or the organization is missing" do
      organization = organization_fixture()
      user = editor_fixture(organization)

      refute EnsureRole.editor_member?(nil, organization.id)
      refute EnsureRole.editor_member?(user.id, nil)
      refute EnsureRole.editor_member?(nil, nil)
    end
  end
end
