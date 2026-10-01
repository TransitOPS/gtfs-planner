defmodule GtfsPlanner.Gtfs.Alignments.AuthorizationTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments
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

    first =
      stop_fixture(organization.id, version.id, %{
        stop_lat: Decimal.new("40.712800"),
        stop_lon: Decimal.new("-74.006000")
      })

    second =
      stop_fixture(organization.id, version.id, %{
        stop_lat: Decimal.new("40.713800"),
        stop_lon: Decimal.new("-74.005000")
      })

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

    section =
      pattern |> Alignments.resolve() |> Map.fetch!(:sections) |> Enum.find(&(&1.position == 1))

    draft = [
      %{
        "position" => section.position,
        "from_occurrence_id" => section.from_occurrence_id,
        "to_stop_id" => section.to_stop_id,
        "op" => "set",
        "points" => [[-74.0056, 40.7132]],
        "base" => %{
          "segment_id" => section.revision.segment_id,
          "lock_version" => section.revision.lock_version
        }
      }
    ]

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review_alignment_save(pattern.id, draft, audit)

    before_pattern = Repo.reload!(pattern)
    before_segments = count(AlignmentSegment, organization.id)
    before_shapes = count(Shape, organization.id)
    before_logs = count(ChangeLog, organization.id)
    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Gtfs.apply_alignment_save(pattern.id, draft, %{}, fingerprint, audit)

    assert Repo.reload!(pattern) == before_pattern
    assert count(AlignmentSegment, organization.id) == before_segments
    assert count(Shape, organization.id) == before_shapes
    assert count(ChangeLog, organization.id) == before_logs
  end

  defp count(schema, organization_id) do
    Repo.aggregate(from(row in schema, where: row.organization_id == ^organization_id), :count)
  end
end
