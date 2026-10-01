defmodule GtfsPlanner.Gtfs.ExportDefaultsAuthorizationTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.ExportDefault
  alias GtfsPlanner.Gtfs.ExportDefaults

  import GtfsPlanner.OrganizationsFixtures

  test "a revoked editor cannot insert or change any export default" do
    organization = organization_fixture()
    actor = editor_fixture(organization)

    assert {:ok, created} =
             ExportDefaults.update(organization.id, actor, %{
               include_flex: false,
               realtime_source: :own,
               estimate_missing_times: false,
               estimate_method: :even
             })

    actor |> membership_for(organization) |> deactivate_membership_fixture()

    assert {:error, :forbidden} =
             ExportDefaults.update(organization.id, actor, %{
               include_flex: true,
               realtime_source: :main,
               estimate_missing_times: true,
               estimate_method: :distance
             })

    assert Repo.get(ExportDefault, created.id) == created

    empty_organization = organization_fixture()
    empty_actor = editor_fixture(empty_organization)
    empty_actor |> membership_for(empty_organization) |> deactivate_membership_fixture()

    assert {:error, :forbidden} =
             ExportDefaults.update(empty_organization.id, empty_actor, %{include_flex: false})

    refute Repo.get_by(ExportDefault, organization_id: empty_organization.id)
  end

  test "foreign membership and forged ownership fields cannot redirect an update" do
    organization = organization_fixture()
    other = organization_fixture()
    actor = editor_fixture(organization)
    foreign_actor = editor_fixture(other)

    assert {:error, :forbidden} =
             ExportDefaults.update(organization.id, foreign_actor, %{include_flex: false})

    assert {:ok, saved} =
             ExportDefaults.update(organization.id, actor, %{
               organization_id: other.id,
               include_flex: false,
               realtime_source: :flex,
               estimate_missing_times: false,
               estimate_method: :even
             })

    assert saved.organization_id == organization.id
    assert Repo.get_by!(ExportDefault, organization_id: organization.id).id == saved.id
    refute Repo.get_by(ExportDefault, organization_id: other.id)
  end

  defp membership_for(actor, organization) do
    Repo.get_by!(UserOrgMembership, user_id: actor.id, organization_id: organization.id)
  end
end
