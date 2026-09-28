defmodule GtfsPlanner.Agents.ScopeTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.AuditContext

  describe "authorize/1" do
    test "returns :ok for an active editor membership" do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization)

      assert Scope.authorize(scope_fixture(user, organization)) == :ok
    end

    test "returns {:error, :forbidden} once the membership is deactivated" do
      organization = organization_fixture()
      user = user_fixture()
      membership = organization_membership_fixture(user, organization)
      scope = scope_fixture(user, organization)

      assert Scope.authorize(scope) == :ok

      deactivate_membership_fixture(membership)

      assert Scope.authorize(scope) == {:error, :forbidden}
    end

    test "returns {:error, :forbidden} when the membership lacks the editor role" do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization, ["pathways_studio_admin"])

      assert Scope.authorize(scope_fixture(user, organization)) == {:error, :forbidden}
    end

    test "returns {:error, :forbidden} for a user with no membership in the organization" do
      organization = organization_fixture()
      user = user_fixture()

      assert Scope.authorize(scope_fixture(user, organization)) == {:error, :forbidden}
    end

    test "returns {:error, :forbidden} for an editor of another organization" do
      organization = organization_fixture()
      other_organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, other_organization)

      assert Scope.authorize(scope_fixture(user, organization)) == {:error, :forbidden}
    end

    test "returns {:error, :forbidden} for a non-UUID user_id without raising" do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization)

      scope = %{scope_fixture(user, organization) | user_id: "not-a-uuid"}

      assert Scope.authorize(scope) == {:error, :forbidden}
    end
  end

  describe "audit_context/1" do
    test "carries the actor identity and leaves the station unset" do
      organization = organization_fixture()
      user = user_fixture()
      version = gtfs_version_fixture(organization.id)

      scope = %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        user_id: user.id,
        user_email: user.email,
        pack_id: "calendars",
        version_name: version.name
      }

      assert %AuditContext{} = audit = Scope.audit_context(scope)

      assert audit.organization_id == organization.id
      assert audit.gtfs_version_id == version.id
      assert audit.station_stop_id == nil
      assert audit.actor_id == user.id
      assert audit.actor_email == user.email
    end
  end

  defp scope_fixture(user, organization) do
    version = gtfs_version_fixture(organization.id)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "calendars",
      version_name: version.name
    }
  end
end
