defmodule GtfsPlanner.Gtfs.Alignments.AuthorizationTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  test "alignment apply rechecks membership after review and leaves rows unchanged" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)
    membership = GtfsPlanner.Accounts.get_user_org_membership(actor.id, organization.id)
    first = stop_fixture(organization.id, version.id)
    second = stop_fixture(organization.id, version.id)

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: route.route_id})

    route_pattern_stop_fixture(pattern, first.stop_id, 1)
    route_pattern_stop_fixture(pattern, second.stop_id, 2)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review_alignment_save(pattern.id, [], audit)

    before_pattern = Repo.reload!(pattern)
    before_segments = count(AlignmentSegment, organization.id)
    before_shapes = count(Shape, organization.id)
    before_logs = count(ChangeLog, organization.id)
    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Gtfs.apply_alignment_save(pattern.id, [], %{}, fingerprint, audit)

    assert Repo.reload!(pattern) == before_pattern
    assert count(AlignmentSegment, organization.id) == before_segments
    assert count(Shape, organization.id) == before_shapes
    assert count(ChangeLog, organization.id) == before_logs
  end

  defp count(schema, organization_id) do
    Repo.aggregate(from(row in schema, where: row.organization_id == ^organization_id), :count)
  end
end
