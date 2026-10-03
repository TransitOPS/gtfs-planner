defmodule GtfsPlanner.Gtfs.Alignments.PatternDeleteTest do
  # Step 16 / EV-15: deleting a drawn pattern through the 01 `:delete` writer
  # removes its owned shape rows (when no trip references them) and its
  # override rows (via the route_pattern_stops FK cascade), while a shape_id
  # still referenced by a custom trip on another pattern is kept.
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  defp audit(organization, version) do
    actor = editor_fixture(organization)

    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
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

  defp setup_context do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_with_coords(organization, version, "B", "40.713800", "-74.005000")
    stop_with_coords(organization, version, "C", "40.714800", "-74.004000")

    %{
      organization: organization,
      version: version,
      route: route,
      audit: audit(organization, version)
    }
  end

  defp create_service!(context, stops) do
    {:ok, pattern} =
      Gtfs.create_pattern(
        context.route.route_id,
        %{route_pattern_name: "Service", direction_id: 0, stops: stops},
        context.audit
      )

    Repo.reload!(pattern)
  end

  defp occurrences(pattern_id) do
    Repo.all(
      from o in RoutePatternStop,
        where: o.route_pattern_id == ^pattern_id,
        order_by: [asc: o.position]
    )
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

  defp override_for(organization, version, occurrence_id) do
    Repo.one(
      from s in AlignmentSegment,
        where:
          s.organization_id == ^organization.id and
            s.gtfs_version_id == ^version.id and
            s.from_occurrence_id == ^occurrence_id
    )
  end

  defp shared_count(organization, version, from_id, to_id) do
    Repo.aggregate(
      from(s in AlignmentSegment,
        where:
          s.organization_id == ^organization.id and
            s.gtfs_version_id == ^version.id and
            is_nil(s.from_occurrence_id) and
            s.from_stop_id == ^from_id and s.to_stop_id == ^to_id
      ),
      :count
    )
  end

  defp shape_rows(organization, version, shape_id) do
    from(s in Shape,
      where:
        s.organization_id == ^organization.id and
          s.gtfs_version_id == ^version.id and
          s.shape_id == ^shape_id,
      order_by: [asc: s.shape_pt_sequence],
      select: {s.shape_pt_sequence, s.shape_pt_lat, s.shape_pt_lon, s.shape_dist_traveled}
    )
    |> Repo.all()
  end

  # Draws the pattern through the real alignment save (segments resolve, so
  # the save materializes the pattern under its own shape id).
  defp draw_pattern!(context, pattern) do
    assert {:ok, review} = Gtfs.review_alignment_save(pattern.id, [], context.audit)
    assert review.origin.complete? == true

    assert {:ok, _} =
             Gtfs.apply_alignment_save(pattern.id, [], %{}, review.fingerprint, context.audit)

    drawn = Repo.reload!(pattern)
    assert drawn.shape_id != nil
    drawn
  end

  # Deletes through the real 01 writer composition:
  # `Gtfs.review/4` + `Gtfs.apply_review/4` with operation `:delete`.
  defp delete_pattern!(context, pattern) do
    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, :delete, source, context.audit)

    assert {:ok, %{pattern: nil, trips_updated: 0}} =
             Gtfs.apply_review(pattern.id, :delete, fingerprint, context.audit)

    :ok
  end

  test "deleting an unused drawn pattern removes its shape rows and overrides" do
    context = setup_context()
    pattern = create_service!(context, ["A", "B", "C"])
    [first | _] = occurrences(pattern.id)

    insert_override(
      context.organization,
      context.version,
      first,
      "A",
      "B",
      [[-74.0055, 40.7131]]
    )

    insert_shared(context.organization, context.version, "B", "C", [[-74.0045, 40.7143]])

    drawn = draw_pattern!(context, pattern)
    shape_id = drawn.shape_id
    assert shape_rows(context.organization, context.version, shape_id) != []

    delete_pattern!(context, drawn)

    assert Repo.get(RoutePattern, pattern.id) == nil
    assert Repo.all(from o in RoutePatternStop, where: o.route_pattern_id == ^pattern.id) == []

    # The owned shape rows are gone.
    assert shape_rows(context.organization, context.version, shape_id) == []

    # The pattern's override row disappears with its occurrences (FK cascade).
    assert is_nil(override_for(context.organization, context.version, first.id))

    # Version-scoped shared geometry is not owned by the pattern, so it stays.
    assert shared_count(context.organization, context.version, "B", "C") == 1
  end

  test "deleting a pattern keeps shapes rows still referenced by a custom trip" do
    context = setup_context()
    pattern = create_service!(context, ["A", "B", "C"])
    [first | _] = occurrences(pattern.id)

    insert_override(
      context.organization,
      context.version,
      first,
      "A",
      "B",
      [[-74.0055, 40.7131]]
    )

    insert_shared(context.organization, context.version, "B", "C", [[-74.0045, 40.7143]])

    drawn = draw_pattern!(context, pattern)
    shape_id = drawn.shape_id
    before_rows = shape_rows(context.organization, context.version, shape_id)
    assert before_rows != []

    # A custom trip on another pattern still references the owned shape_id,
    # so 01's `:pattern_in_use` guard (which only counts the deleted
    # pattern's own trips) lets this delete through.
    other = create_service!(context, ["A", "B"])

    trip =
      trip_fixture(context.organization.id, context.version.id, context.route.route_id, %{
        trip_id: "referencing-trip",
        shape_id: shape_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: other.route_pattern_id,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "stops_differ"
    })

    delete_pattern!(context, drawn)

    assert Repo.get(RoutePattern, pattern.id) == nil
    assert is_nil(override_for(context.organization, context.version, first.id))

    # The referenced shape rows survive the delete byte-for-byte.
    assert shape_rows(context.organization, context.version, shape_id) == before_rows
  end
end
