defmodule GtfsPlanner.Gtfs.AlignmentAuditTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    pattern = route_pattern_fixture(organization.id, version.id)
    occurrence = route_pattern_stop_fixture(pattern, "S1", 1)
    _second = route_pattern_stop_fixture(pattern, "S2", 2)

    %{
      organization: organization,
      version: version,
      pattern: pattern,
      occurrence: occurrence,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp insert_segment(organization, version, attrs) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: "S1",
      to_stop_id: "S2"
    }
    |> AlignmentSegment.changeset(attrs)
    |> Repo.insert!()
  end

  test "recording :alignment_segment 'created' for a shared row stores the pair identity and before/after",
       %{organization: organization, version: version, audit: audit} do
    segment = insert_segment(organization, version, %{points: [[-74.006, 40.7128]]})

    assert {:ok, log} =
             Repo.transaction(fn ->
               {:ok, log} =
                 Gtfs.record_change_in_transaction(audit, :alignment_segment, segment, "created", %{
                   before: nil,
                   after: %{points: [[-74.006, 40.7128]]}
                 })

               log
             end)

    assert %ChangeLog{} = log
    assert log.entity_type == "alignment_segment"
    assert log.entity_id == segment.id
    assert log.entity_external_id == "S1>S2"
    assert log.action == "created"

    assert log.changed_fields == %{
             "before" => nil,
             "after" => %{points: [[-74.006, 40.7128]]}
           }
  end

  test "an override row names its visit in the external id",
       %{organization: organization, version: version, occurrence: occurrence, audit: audit} do
    segment =
      %AlignmentSegment{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        from_stop_id: "S1",
        to_stop_id: "S2",
        from_occurrence_id: occurrence.id
      }
      |> AlignmentSegment.changeset(%{points: [[-74.006, 40.7128]]})
      |> Repo.insert!()

    assert {:ok, log} =
             Repo.transaction(fn ->
               {:ok, log} =
                 Gtfs.record_change_in_transaction(audit, :alignment_segment, segment, "created", %{
                   before: nil,
                   after: %{points: [[-74.006, 40.7128]]}
                 })

               log
             end)

    assert log.entity_type == "alignment_segment"
    assert log.entity_external_id == "S1>S2@#{occurrence.id}"
  end

  test "recording :pattern_shape 'updated' keeps nested replaced-shape detail in before",
       %{pattern: pattern, audit: audit} do
    before = %{
      shape_id: "imported-shape",
      replaced_shapes: [
        %{shape_id: "imported-shape", points: [[-74.006, 40.7128], [-74.005, 40.713]]}
      ],
      previous_distances: [%{trip_id: "t1", distances: [0.0, 412.55]}]
    }

    after_snapshot = %{shape_id: pattern.route_pattern_id, replaced_shapes: []}

    assert {:ok, log} =
             Repo.transaction(fn ->
               {:ok, log} =
                 Gtfs.record_change_in_transaction(audit, :pattern_shape, pattern, "updated", %{
                   before: before,
                   after: after_snapshot
                 })

               log
             end)

    assert %ChangeLog{} = log
    assert log.entity_type == "pattern_shape"
    assert log.entity_id == pattern.id
    assert log.entity_external_id == pattern.route_pattern_id
    assert log.action == "updated"

    assert log.changed_fields == %{
             "before" => before,
             "after" => after_snapshot
           }
  end

  test "the changeset accepts the new entity types and still rejects unknown ones" do
    for entity_type <- ["alignment_segment", "pattern_shape"] do
      changeset =
        ChangeLog.changeset(%ChangeLog{}, %{
          entity_type: entity_type,
          entity_id: Ecto.UUID.generate(),
          entity_external_id: "S1>S2",
          actor_id: Ecto.UUID.generate(),
          actor_email: "user@example.com",
          action: "created",
          organization_id: Ecto.UUID.generate(),
          gtfs_version_id: Ecto.UUID.generate()
        })

      assert changeset.valid?, inspect(changeset.errors)
    end

    changeset =
      ChangeLog.changeset(%ChangeLog{}, %{
        entity_type: "unknown_type",
        entity_id: Ecto.UUID.generate(),
        entity_external_id: "S1>S2",
        actor_id: Ecto.UUID.generate(),
        actor_email: "user@example.com",
        action: "created",
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      })

    refute changeset.valid?
    assert %{entity_type: ["is invalid"]} = errors_on(changeset)
  end
end
