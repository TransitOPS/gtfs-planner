defmodule GtfsPlanner.Gtfs.Alignments.ApplyTest do
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  defp audit_context(organization, version) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: Ecto.UUID.generate(),
      actor_email: "alignment-apply@example.com"
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

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route_id,
        route_pattern_id: pattern_id
      })

    stops
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

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

    Repo.reload!(trip)
  end

  defp set_entry(section, points) do
    %{
      "position" => section.position,
      "from_occurrence_id" => section.from_occurrence_id,
      "to_stop_id" => section.to_stop_id,
      "op" => "set",
      "points" => points,
      "base" => %{
        "segment_id" => section.revision.segment_id,
        "lock_version" => section.revision.lock_version
      }
    }
  end

  defp delete_entry(section) do
    %{
      "position" => section.position,
      "from_occurrence_id" => section.from_occurrence_id,
      "to_stop_id" => section.to_stop_id,
      "op" => "delete",
      "base" => %{
        "segment_id" => section.revision.segment_id,
        "lock_version" => section.revision.lock_version
      }
    }
  end

  defp section_at(pattern, position) do
    pattern |> Alignments.resolve() |> Map.fetch!(:sections) |> Enum.find(&(&1.position == position))
  end

  defp first_occurrence(pattern) do
    Repo.one!(
      from(o in GtfsPlanner.Gtfs.RoutePatternStop,
        where: o.route_pattern_id == ^pattern.id,
        order_by: [asc: o.position],
        limit: 1
      )
    )
  end

  defp review!(pattern_id, draft, audit) do
    {:ok, review} = Gtfs.review_alignment_save(pattern_id, draft, audit)
    review
  end

  defp apply(pattern_id, draft, choices, fingerprint, audit) do
    Gtfs.apply_alignment_save(pattern_id, draft, choices, fingerprint, audit)
  end

  defp shared_row(organization, version, from_id, to_id) do
    Repo.one(
      from(s in AlignmentSegment,
        where:
          s.organization_id == ^organization.id and
            s.gtfs_version_id == ^version.id and
            is_nil(s.from_occurrence_id) and
            s.from_stop_id == ^from_id and s.to_stop_id == ^to_id
      )
    )
  end

  defp override_row(organization, version, occurrence_id, to_id) do
    Repo.one(
      from(s in AlignmentSegment,
        where:
          s.organization_id == ^organization.id and
            s.gtfs_version_id == ^version.id and
            s.from_occurrence_id == ^occurrence_id and s.to_stop_id == ^to_id
      )
    )
  end

  defp shape_points(organization, version, shape_id) do
    from(s in Shape,
      where:
        s.organization_id == ^organization.id and
          s.gtfs_version_id == ^version.id and
          s.shape_id == ^shape_id,
      order_by: [asc: s.shape_pt_sequence],
      select: {s.shape_pt_lat, s.shape_pt_lon, s.shape_dist_traveled}
    )
    |> Repo.all()
  end

  defp trip_row(organization, version, trip_id) do
    Repo.one!(
      from(t in Trip,
        where:
          t.organization_id == ^organization.id and
            t.gtfs_version_id == ^version.id and
            t.trip_id == ^trip_id
      )
    )
  end

  defp trip_distances(organization, version, trip_id) do
    from(st in StopTime,
      where:
        st.organization_id == ^organization.id and
          st.gtfs_version_id == ^version.id and
          st.trip_id == ^trip_id,
      order_by: [asc: st.stop_sequence],
      select: st.shape_dist_traveled
    )
    |> Repo.all()
  end

  defp segment_count(organization, version) do
    from(s in AlignmentSegment,
      where: s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id,
      select: count(s.id)
    )
    |> Repo.one()
  end

  defp audit_counts(organization, version) do
    from(cl in ChangeLog,
      where:
        cl.organization_id == ^organization.id and
          cl.gtfs_version_id == ^version.id and
          cl.entity_type in ["alignment_segment", "pattern_shape"],
      group_by: [cl.entity_type, cl.action],
      select: {cl.entity_type, cl.action, count(cl.id)}
    )
    |> Repo.all()
  end

  test "local scope creates an override and leaves the other route's rows byte-equal" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    other = routed_pattern(organization, version, "R2", "P2", ["A", "B"])
    insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])
    other_trip = link_trip(organization, version, Repo.reload!(other), "OTHER", nil, [Decimal.new("0"), Decimal.new("0")])
    audit = audit_context(organization, version)

    draft = [set_entry(section_at(origin, 1), [[-74.0055, 40.7131]])]
    review = review!(origin.id, draft, audit)
    assert [%{action: :choose_scope}] = review.sections

    before_shared = shared_row(organization, version, "A", "B")
    before_trip = trip_row(organization, version, "OTHER")
    before_distances = trip_distances(organization, version, "OTHER")

    assert {:ok, result} =
             apply(origin.id, draft, %{"scopes" => %{"1" => "local"}}, review.fingerprint, audit)

    assert result.segments_written == 1
    assert result.materialized == ["P1"]
    assert result.trips_updated == 0

    override = override_row(organization, version, first_occurrence(origin).id, "B")
    assert override.points == [[-74.0055, 40.7131]]

    # A fresh resolve sees the new override as the section revision.
    assert %{kind: :override, points: [[-74.0055, 40.7131]]} = section_at(Repo.reload!(origin), 1)

    # The shared row is untouched by a local save.
    assert shared_row(organization, version, "A", "B").points == before_shared.points
    assert shared_row(organization, version, "A", "B").lock_version == before_shared.lock_version

    # The other route's pattern rows are byte-equal before and after.
    assert trip_row(organization, version, "OTHER").shape_id == before_trip.shape_id
    assert trip_row(organization, version, "OTHER").updated_at == before_trip.updated_at
    assert trip_distances(organization, version, "OTHER") == before_distances
    assert Repo.reload!(other).shape_id == nil
    assert other_trip.id != nil
  end

  test "shared scope updates the shared row, drops the origin override and rematerializes the shape owner" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    holder = routed_pattern(organization, version, "R2", "P2", ["A", "B"])
    custom = routed_pattern(organization, version, "R3", "P3", ["A", "B"])
    imported = routed_pattern(organization, version, "R4", "P4", ["A", "B"])

    insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])
    # A stale-identity override for the origin visit (its stop moved on): the
    # section resolves shared, and the shared choice cleans the lingerer up.
    insert_override(organization, version, first_occurrence(origin), "X", "B", [[-74.0059, 40.7133]])

    holder |> Ecto.Changeset.change(%{shape_id: "P2"}) |> Repo.update!()
    insert_shape(organization, version, "P2", 0, "40.700000", "-74.020000", "0")
    insert_shape(organization, version, "P2", 1, "40.701000", "-74.019000", "100.0")
    holder_trip = link_trip(organization, version, Repo.reload!(holder), "H1", "P2", [Decimal.new("0"), Decimal.new("100.0")])

    [custom_first | _] =
      Repo.all(
        from(o in GtfsPlanner.Gtfs.RoutePatternStop,
          where: o.route_pattern_id == ^custom.id,
          order_by: [asc: o.position]
        )
      )

    insert_override(organization, version, custom_first, "A", "B", [[-74.0051, 40.7135]])

    insert_shape(organization, version, "IMP", 0, "40.712800", "-74.006000", "0")
    insert_shape(organization, version, "IMP", 1, "40.713800", "-74.005000", "139.53")
    link_trip(organization, version, Repo.reload!(imported), "I1", "IMP", [Decimal.new("0"), Decimal.new("139.53")])

    audit = audit_context(organization, version)
    draft = [set_entry(section_at(origin, 1), [[-74.0055, 40.7131]])]
    review = review!(origin.id, draft, audit)
    assert [%{action: :choose_scope, affected: affected}] = review.sections
    assert Enum.map(affected, & &1.route_pattern_id) |> Enum.sort() == ["P2", "P4"]

    before_holder_shapes = shape_points(organization, version, "P2")
    before_imported_shapes = shape_points(organization, version, "IMP")
    before_imported_distances = trip_distances(organization, version, "I1")

    assert {:ok, result} =
             apply(origin.id, draft, %{"scopes" => %{"1" => "shared"}}, review.fingerprint, audit)

    assert result.segments_written == 2
    assert Enum.sort(result.materialized) == ["P1", "P2"]
    assert result.trips_updated == 1
    assert result.shapes_deleted == []

    assert shared_row(organization, version, "A", "B").points == [[-74.0055, 40.7131]]
    assert override_row(organization, version, first_occurrence(origin).id, "B") == nil

    # The shape-owning pattern on the other route is re-materialized.
    assert shape_points(organization, version, "P2") != before_holder_shapes
    assert shape_points(organization, version, "P2") != []
    assert trip_row(organization, version, "H1").shape_id == "P2"
    assert trip_row(organization, version, "H1").updated_at != holder_trip.updated_at
    assert holder_trip.id != nil

    # The custom-path pattern and the imported-shape pattern are unchanged.
    assert override_row(organization, version, custom_first.id, "B").points == [[-74.0051, 40.7135]]
    assert trip_row(organization, version, "I1").shape_id == "IMP"
    assert trip_distances(organization, version, "I1") == before_imported_distances
    assert shape_points(organization, version, "IMP") == before_imported_shapes
    assert Repo.reload!(imported).shape_id == nil
  end

  test "a partial save writes one section and leaves exported rows unchanged" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B", "C"])
    insert_shared(organization, version, "B", "C", [])
    link_trip(organization, version, pattern, "T1", nil, [Decimal.new("1.5"), Decimal.new("2.5"), Decimal.new("3.5")])
    audit = audit_context(organization, version)

    draft = [
      set_entry(section_at(pattern, 1), [[-74.0055, 40.7131]]),
      delete_entry(section_at(pattern, 2))
    ]

    review = review!(pattern.id, draft, audit)
    assert review.origin.complete? == false
    assert review.origin.plan == nil

    assert {:ok, result} = apply(pattern.id, draft, %{}, review.fingerprint, audit)

    assert result.segments_written == 2
    assert result.materialized == []
    assert result.trips_updated == 0

    assert shared_row(organization, version, "A", "B").points == [[-74.0055, 40.7131]]
    assert shared_row(organization, version, "B", "C") == nil

    assert shape_points(organization, version, "P1") == []
    assert trip_row(organization, version, "T1").shape_id == nil
    assert trip_distances(organization, version, "T1") == [Decimal.new("1.5"), Decimal.new("2.5"), Decimal.new("3.5")]
  end

  test "a fingerprint from an earlier review returns stale_review and writes nothing" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    audit = audit_context(organization, version)

    draft = [set_entry(section_at(origin, 1), [[-74.0055, 40.7131]])]
    review = review!(origin.id, draft, audit)

    # A new pattern on the same pair changes the review without moving bases.
    _other = routed_pattern(organization, version, "R2", "P2", ["A", "B"])

    assert {:error, :stale_review} = apply(origin.id, draft, %{}, review.fingerprint, audit)
    assert segment_count(organization, version) == 0
  end

  test "omitting a scope for a choose_scope position returns missing_scope and writes nothing" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    _other = routed_pattern(organization, version, "R2", "P2", ["A", "B"])
    insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])
    audit = audit_context(organization, version)

    draft = [set_entry(section_at(origin, 1), [[-74.0055, 40.7131]])]
    review = review!(origin.id, draft, audit)
    assert [%{action: :choose_scope}] = review.sections

    assert {:error, :missing_scope} = apply(origin.id, draft, %{"scopes" => %{}}, review.fingerprint, audit)
    assert shared_row(organization, version, "A", "B").points == [[-74.0057, 40.7130]]
    assert segment_count(organization, version) == 1
  end

  test "a delete_shared with users needs the shared scope" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    origin = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    _other = routed_pattern(organization, version, "R2", "P2", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])
    audit = audit_context(organization, version)

    draft = [delete_entry(section_at(origin, 1))]
    review = review!(origin.id, draft, audit)
    assert [%{action: :delete_shared, affected: [_]}] = review.sections

    assert {:error, :missing_scope} = apply(origin.id, draft, %{}, review.fingerprint, audit)
    assert {:error, :missing_scope} =
             apply(origin.id, draft, %{"scopes" => %{"1" => "local"}}, review.fingerprint, audit)

    assert shared_row(organization, version, "A", "B") != nil

    assert {:ok, result} =
             apply(origin.id, draft, %{"scopes" => %{"1" => "shared"}}, review.fingerprint, audit)

    assert result.segments_written == 1
    assert result.materialized == []
    assert shared_row(organization, version, "A", "B") == nil
  end

  test "a replacement review without confirmation returns confirmation_required and writes nothing" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])
    insert_shape(organization, version, "X", 0, "40.712800", "-74.006000", "0")
    insert_shape(organization, version, "X", 1, "40.713800", "-74.005000", "812.4")

    link_trip(organization, version, Repo.reload!(pattern), "T1", "X", [
      Decimal.new("0"),
      Decimal.new("812.4")
    ])

    audit = audit_context(organization, version)
    draft = [set_entry(section_at(pattern, 1), [[-74.0055, 40.7131]])]
    review = review!(pattern.id, draft, audit)
    assert review.requires_confirmation? == true

    assert {:error, :confirmation_required} =
             apply(pattern.id, draft, %{}, review.fingerprint, audit)

    assert shared_row(organization, version, "A", "B").points == [[-74.0057, 40.7130]]
    assert trip_row(organization, version, "T1").shape_id == "X"

    assert {:ok, result} =
             apply(pattern.id, draft, %{"confirm_replacements" => true}, review.fingerprint, audit)

    assert result.materialized == ["P1"]
    assert result.trips_updated == 1
    assert trip_row(organization, version, "T1").shape_id == "X"
  end

  test "a foreign organization audit context returns not_found" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    audit = audit_context(organization, version)
    draft = [set_entry(section_at(pattern, 1), [[-74.0055, 40.7131]])]
    review = review!(pattern.id, draft, audit)

    foreign = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign.id)
    foreign_audit = audit_context(foreign, foreign_version)

    assert {:error, :not_found} = apply(pattern.id, draft, %{}, review.fingerprint, foreign_audit)
    assert segment_count(organization, version) == 0
  end

  test "a base older than the current row returns conflict and writes nothing" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    segment = insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])
    audit = audit_context(organization, version)

    stale_section = section_at(pattern, 1)
    draft = [set_entry(stale_section, [[-74.0050, 40.7132]])]
    review = review!(pattern.id, draft, audit)

    segment
    |> AlignmentSegment.changeset(%{points: [[-74.0051, 40.7135]]})
    |> Repo.update!()

    assert {:error, {:conflict, [current]}} = apply(pattern.id, draft, %{}, review.fingerprint, audit)
    assert current.position == 1
    assert current.revision.lock_version == stale_section.revision.lock_version + 1

    assert shared_row(organization, version, "A", "B").points == [[-74.0051, 40.7135]]
    assert segment_count(organization, version) == 1
  end

  test "successful applies audit one segment row per write and one shape row per materialization" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    audit = audit_context(organization, version)

    draft = [set_entry(section_at(pattern, 1), [[-74.0055, 40.7131]])]
    review = review!(pattern.id, draft, audit)

    assert {:ok, result} = apply(pattern.id, draft, %{}, review.fingerprint, audit)

    assert result == %{
             materialized: ["P1"],
             trips_updated: 0,
             shapes_deleted: [],
             segments_written: 1
           }

    counts = audit_counts(organization, version)
    assert {"alignment_segment", "created", 1} in counts
    assert {"pattern_shape", "updated", 1} in counts
    assert length(counts) == 2
  end
end
