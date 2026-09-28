defmodule GtfsPlanner.Gtfs.Alignments.ReviewTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  defp audit_context(organization, version) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: Ecto.UUID.generate(),
      actor_email: "alignment-review@example.com"
    }
  end

  defp stop_with_coords(organization, version, stop_id, lat_s, lon_s) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: "Stop #{stop_id}",
      stop_lat: Decimal.new(lat_s),
      stop_lon: Decimal.new(lon_s)
    })
  end

  defp base_stops(organization, version) do
    stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_with_coords(organization, version, "B", "40.713800", "-74.005000")
    stop_with_coords(organization, version, "C", "40.714800", "-74.004000")
  end

  defp routed_pattern(organization, version, route_id, pattern_id, stops) do
    route_fixture(organization.id, version.id, %{route_id: route_id})
    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: route_id, route_pattern_id: pattern_id})

    stops
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} -> route_pattern_stop_fixture(pattern, stop_id, position) end)

    Repo.reload!(pattern)
  end

  defp insert_shared(organization, version, from_id, to_id, points) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  defp insert_override(organization, version, occurrence, from_id, to_id, points) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id,
      from_occurrence_id: occurrence.id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  defp insert_shape(organization, version, shape_id, sequence, lat_s, lon_s, dist_s) do
    %Shape{}
    |> Shape.changeset(%{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      shape_id: shape_id,
      shape_pt_sequence: sequence,
      shape_pt_lat: lat_s,
      shape_pt_lon: lon_s,
      shape_dist_traveled: dist_s
    })
    |> Repo.insert!()
  end

  defp link_trip(organization, version, pattern, trip_id, shape_id, dists) do
    timing = timed_pattern_fixture(pattern)
    trip = trip_fixture(organization.id, version.id, pattern.route_id, %{trip_id: trip_id, shape_id: shape_id})

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    Enum.with_index(dists, 1)
    |> Enum.each(fn {dist, sequence} ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, "A", %{
        stop_sequence: sequence,
        shape_dist_traveled: dist
      })
    end)

    trip
  end

  defp set_entry(section, points) do
    %{
      "position" => section.position,
      "from_occurrence_id" => section.from_occurrence_id,
      "to_stop_id" => section.to_stop_id,
      "op" => "set",
      "points" => points,
      "base" => %{"segment_id" => section.revision.segment_id, "lock_version" => section.revision.lock_version}
    }
  end

  defp delete_entry(section) do
    %{
      "position" => section.position,
      "from_occurrence_id" => section.from_occurrence_id,
      "to_stop_id" => section.to_stop_id,
      "op" => "delete",
      "base" => %{"segment_id" => section.revision.segment_id, "lock_version" => section.revision.lock_version}
    }
  end

  defp section_at(pattern, position) do
    pattern |> Alignments.resolve() |> Map.fetch!(:sections) |> Enum.find(&(&1.position == position))
  end

  test "a set on a sole-user missing section writes shared without a choice" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    audit = audit_context(organization, version)

    assert {:ok, review} =
             Gtfs.review_alignment_save(pattern.id, [set_entry(section_at(pattern, 1), [[-74.0055, 40.7131]])], audit)

    assert [%{position: 1, op: :set, action: :write_shared, affected: [], from_name: "Stop A", to_name: "Stop B"}] =
             review.sections

    assert review.origin.complete? == true
    assert review.requires_confirmation? == false
    assert review.blockers == []
    assert is_binary(review.fingerprint)
  end

  test "a set on an override section writes the override without a choice" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B", "C"])

    [first | _] = Repo.all(Ecto.Query.from(o in GtfsPlanner.Gtfs.RoutePatternStop, where: o.route_pattern_id == ^pattern.id, order_by: [asc: o.position]))
    insert_override(organization, version, first, "A", "B", [[-74.0055, 40.7131]])
    insert_shared(organization, version, "B", "C", [])

    audit = audit_context(organization, version)

    assert {:ok, review} =
             Gtfs.review_alignment_save(pattern.id, [set_entry(section_at(pattern, 1), [[-74.0051, 40.7135]])], audit)

    assert [%{position: 1, op: :set, action: :write_override, affected: []}] = review.sections
    assert review.origin.complete? == true
  end

  test "a set on a shared section used by another route asks scope and lists custom holders" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    other = routed_pattern(organization, version, "R2", "P2", ["A", "B"])
    custom = routed_pattern(organization, version, "R3", "P3", ["A", "B"])

    insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])

    [custom_first | _] =
      Repo.all(Ecto.Query.from(o in GtfsPlanner.Gtfs.RoutePatternStop, where: o.route_pattern_id == ^custom.id, order_by: [asc: o.position]))

    insert_override(organization, version, custom_first, "A", "B", [[-74.0051, 40.7135]])

    audit = audit_context(organization, version)

    assert {:ok, review} =
             Gtfs.review_alignment_save(origin.id, [set_entry(section_at(origin, 1), [[-74.0055, 40.7131]])], audit)

    assert [%{action: :choose_scope, affected: affected, custom_unchanged: custom_unchanged}] = review.sections
    assert Enum.map(affected, & &1.route_pattern_id) == ["P2"]
    assert [%{visit_positions: [1], custom_positions: []}] = affected
    assert other.id in Enum.map(affected, & &1.pattern_id)
    assert Enum.map(custom_unchanged, & &1.route_pattern_id) == ["P3"]
    assert [%{visit_positions: [], custom_positions: [1]}] = custom_unchanged
  end

  test "a set on section 1 of a loop lists this pattern's position 4 as affected" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B", "C", "A", "B"])
    insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])
    insert_shared(organization, version, "B", "C", [])
    insert_shared(organization, version, "C", "A", [])
    audit = audit_context(organization, version)

    assert {:ok, review} =
             Gtfs.review_alignment_save(pattern.id, [set_entry(section_at(pattern, 1), [[-74.0055, 40.7131]])], audit)

    assert [%{action: :choose_scope, affected: affected}] = review.sections
    assert [%{pattern_id: affected_id, visit_positions: [4]}] = affected
    assert affected_id == pattern.id
  end

  test "a delete on a shared section used elsewhere lists affected; alone it is empty" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    _other = routed_pattern(organization, version, "R2", "P2", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])
    audit = audit_context(organization, version)

    assert {:ok, review} = Gtfs.review_alignment_save(origin.id, [delete_entry(section_at(origin, 1))], audit)
    assert [%{op: :delete, action: :delete_shared, affected: [%{route_pattern_id: "P2", visit_positions: [1]}]}] = review.sections
    assert review.origin.complete? == false
    assert review.origin.plan == nil

    solo_org = organization_fixture()
    solo_version = gtfs_version_fixture(solo_org.id)
    base_stops(solo_org, solo_version)
    solo = routed_pattern(solo_org, solo_version, "R1", "P1", ["A", "B"])
    insert_shared(solo_org, solo_version, "A", "B", [])
    solo_audit = audit_context(solo_org, solo_version)

    assert {:ok, solo_review} = Gtfs.review_alignment_save(solo.id, [delete_entry(section_at(solo, 1))], solo_audit)
    assert [%{action: :delete_shared, affected: []}] = solo_review.sections
  end

  test "a stale base conflicts, a changed identity is stale, a foreign scope is not found" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    segment = insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])
    audit = audit_context(organization, version)

    stale_section = section_at(pattern, 1)

    segment
    |> AlignmentSegment.changeset(%{points: [[-74.0055, 40.7131]]})
    |> Repo.update!()

    assert {:error, {:conflict, [current]}} =
             Gtfs.review_alignment_save(pattern.id, [set_entry(stale_section, [[-74.0050, 40.7132]])], audit)

    assert current.position == 1
    assert current.revision.lock_version == stale_section.revision.lock_version + 1

    fresh = section_at(pattern, 1)
    tampered = set_entry(fresh, [[-74.0050, 40.7132]]) |> Map.put("to_stop_id", "C")

    assert {:error, :stale_stops} = Gtfs.review_alignment_save(pattern.id, [tampered], audit)

    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)
    foreign_audit = audit_context(foreign_org, foreign_version)

    assert {:error, :not_found} =
             Gtfs.review_alignment_save(pattern.id, [set_entry(fresh, [[-74.0050, 40.7132]])], foreign_audit)
  end

  test "a complete pattern on imported shapes plans replacements and requires confirmation" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B", "C"])
    insert_shared(organization, version, "A", "B", [[-74.0055, 40.7131]])
    insert_shared(organization, version, "B", "C", [])
    insert_shape(organization, version, "X", 0, "40.712800", "-74.006000", "0")
    insert_shape(organization, version, "X", 1, "40.713800", "-74.005000", "812.4")

    link_trip(organization, version, Repo.reload!(pattern), "T1", "X", [
      Decimal.new("0"),
      Decimal.new("812.4"),
      Decimal.new("1200.0")
    ])

    audit = audit_context(organization, version)

    assert {:ok, review} =
             Gtfs.review_alignment_save(pattern.id, [set_entry(section_at(pattern, 1), [[-74.0055, 40.7131]])], audit)

    assert review.origin.complete? == true
    assert review.origin.plan.mode == :adopt
    assert review.origin.plan.shape_id == "X"
    assert [%{shape_id: "X", trip_count: 1, action: :adopted}] = review.replaced_shapes
    assert review.requires_confirmation? == true
    assert review.blockers == []
  end

  test "trip count mismatches appear in blockers and shared blockers" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B", "C"])
    insert_shared(organization, version, "A", "B", [])
    insert_shared(organization, version, "B", "C", [])

    link_trip(organization, version, Repo.reload!(origin), "BAD", nil, [Decimal.new("0"), Decimal.new("1")])

    audit = audit_context(organization, version)

    assert {:ok, review} =
             Gtfs.review_alignment_save(origin.id, [set_entry(section_at(origin, 1), [[-74.0055, 40.7131]])], audit)

    assert [%{trip_id: "BAD", stop_time_count: 2, visit_count: 3, route_pattern_id: "P1"}] = review.blockers

    affected_org = organization_fixture()
    affected_version = gtfs_version_fixture(affected_org.id)
    base_stops(affected_org, affected_version)

    saver = routed_pattern(affected_org, affected_version, "R1", "P1", ["A", "B"])
    holder = routed_pattern(affected_org, affected_version, "R2", "P2", ["A", "B"])
    insert_shared(affected_org, affected_version, "A", "B", [])

    holder
    |> Ecto.Changeset.change(%{shape_id: "P2"})
    |> Repo.update!()

    link_trip(affected_org, affected_version, Repo.reload!(holder), "SHARED-BAD", nil, [Decimal.new("0")])

    holder_audit = audit_context(affected_org, affected_version)

    assert {:ok, shared_review} =
             Gtfs.review_alignment_save(
               saver.id,
               [set_entry(section_at(saver, 1), [[-74.0055, 40.7131]])],
               holder_audit
             )

    assert [%{action: :choose_scope, affected: [%{route_pattern_id: "P2"}], shared_rematerialize: [remat], shared_blockers: [%{trip_id: "SHARED-BAD"}]}] =
             shared_review.sections

    assert remat.route_pattern_id == "P2"
    assert remat.trips == 1
  end

  test "equal inputs share a fingerprint and a changed affected visit changes it" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    other = routed_pattern(organization, version, "R2", "P2", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])
    audit = audit_context(organization, version)

    draft = [set_entry(section_at(origin, 1), [[-74.0055, 40.7131]])]

    assert {:ok, first} = Gtfs.review_alignment_save(origin.id, draft, audit)
    assert {:ok, second} = Gtfs.review_alignment_save(origin.id, draft, audit)
    assert first.fingerprint == second.fingerprint

    route_pattern_stop_fixture(Repo.reload!(other), "C", 3)
    route_pattern_stop_fixture(Repo.reload!(other), "A", 4)
    route_pattern_stop_fixture(Repo.reload!(other), "B", 5)

    assert {:ok, third} = Gtfs.review_alignment_save(origin.id, draft, audit)
    assert third.fingerprint != first.fingerprint
    assert [%{affected: [%{visit_positions: [1, 4]}]}] = third.sections
  end
end
