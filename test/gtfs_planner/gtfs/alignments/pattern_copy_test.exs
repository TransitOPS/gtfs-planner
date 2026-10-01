defmodule GtfsPlanner.Gtfs.Alignments.PatternCopyTest do
  # Step 15 / EV-14: copying a pattern through the 01 `:copy` writer carries
  # the source's overrides onto the copy's visits (shared paths stay shared
  # by stop pair) and, when the source is drawn and the copy complete,
  # materializes the copy under its own shape id.
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.TimedPattern
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

  defp base_stops(organization, version) do
    stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_with_coords(organization, version, "B", "40.713800", "-74.005000")
    stop_with_coords(organization, version, "C", "40.714800", "-74.004000")
  end

  defp setup_context do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    base_stops(organization, version)

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

  defp visit_distances(pattern_id) do
    Repo.all(
      from o in RoutePatternStop,
        where: o.route_pattern_id == ^pattern_id,
        order_by: [asc: o.position],
        select: o.shape_dist_traveled
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

  defp version_shape_count(organization, version) do
    Repo.aggregate(
      from(s in Shape,
        where:
          s.organization_id == ^organization.id and
            s.gtfs_version_id == ^version.id
      ),
      :count
    )
  end

  # Copies through the real 01 writer composition:
  # `Gtfs.review/4` + `Gtfs.apply_review/4` with operation `:copy`.
  defp copy_pattern!(context, pattern) do
    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, :copy, source, context.audit)

    assert {:ok, %{pattern: copied}} =
             Gtfs.apply_review(pattern.id, :copy, fingerprint, context.audit)

    Repo.reload!(copied)
  end

  # Draws the source with production functions only (segments plus the step-11
  # materializer in a transaction); the copy itself always goes through the
  # 01 facade via `copy_pattern!/2`.
  defp materialize_source!(context, pattern) do
    pattern = Repo.reload!(pattern)
    resolved = Alignments.resolve(pattern)
    assert resolved.status.missing == 0
    assert resolved.status.blocked == 0
    plan = Alignments.shape_plan(pattern, length(resolved.visits))

    {:ok, _} =
      Repo.transaction(fn ->
        Alignments.materialize_pattern!(Repo.reload!(pattern), resolved, plan, context.audit)
      end)

    Repo.reload!(pattern)
  end

  test "copying a pattern copies its override onto the copy's visit with a created audit" do
    context = setup_context()
    source = create_service!(context, ["A", "B", "C"])
    [_first, second, _third] = occurrences(source.id)

    points = [[-74.0045, 40.7143]]
    insert_shared(context.organization, context.version, "A", "B", [])

    source_override =
      insert_override(context.organization, context.version, second, "B", "C", points)

    copied = copy_pattern!(context, source)
    [copied_first, copied_second, copied_third] = occurrences(copied.id)

    assert Enum.map([copied_first, copied_second, copied_third], & &1.stop_id) == ["A", "B", "C"]

    copied_override = override_for(context.organization, context.version, copied_second.id)

    assert copied_override.from_stop_id == source_override.from_stop_id
    assert copied_override.to_stop_id == source_override.to_stop_id
    assert copied_override.points == source_override.points
    assert copied_override.points == points

    # No override leaks onto the copy's other visits.
    assert is_nil(override_for(context.organization, context.version, copied_first.id))
    assert is_nil(override_for(context.organization, context.version, copied_third.id))

    # Shared geometry stays shared: the A→B row is not duplicated.
    assert shared_count(context.organization, context.version, "A", "B") == 1

    # The source override row is untouched.
    assert Repo.reload!(source_override).points == points

    assert Repo.one(
             from cl in ChangeLog,
               where:
                 cl.organization_id == ^context.organization.id and
                   cl.gtfs_version_id == ^context.version.id and
                   cl.entity_type == "alignment_segment" and
                   cl.entity_id == ^copied_override.id and
                   cl.action == "created"
           ) != nil

    # The undrawn source leaves the copy without a shape.
    assert is_nil(Repo.reload!(copied).shape_id)
    assert version_shape_count(context.organization, context.version) == 0
  end

  test "copying a drawn complete pattern materializes the copy under its own shape id" do
    context = setup_context()
    source = create_service!(context, ["A", "B", "C"])
    [first | _] = occurrences(source.id)

    override_points = [[-74.0055, 40.7131]]
    insert_override(context.organization, context.version, first, "A", "B", override_points)
    insert_shared(context.organization, context.version, "B", "C", [[-74.0045, 40.7143]])

    source = materialize_source!(context, source)
    assert source.shape_id != nil
    source_distances = visit_distances(source.id)
    source_rows = shape_rows(context.organization, context.version, source.shape_id)
    assert source_rows != []

    copied = copy_pattern!(context, source)

    assert copied.shape_id != nil
    assert copied.shape_id != source.shape_id

    # Same geometry under the copy's own id, same per-visit distances.
    assert shape_rows(context.organization, context.version, copied.shape_id) == source_rows
    assert visit_distances(copied.id) == source_distances

    # The copied override resolves on the copy's first visit.
    [copied_first | _] = occurrences(copied.id)

    assert override_for(context.organization, context.version, copied_first.id).points ==
             override_points

    assert Repo.one(
             from cl in ChangeLog,
               where:
                 cl.organization_id == ^context.organization.id and
                   cl.gtfs_version_id == ^context.version.id and
                   cl.entity_type == "pattern_shape" and
                   cl.entity_id == ^copied.id and
                   cl.action == "updated"
           ) != nil

    # The source keeps its shape id and byte-equal shape rows.
    assert Repo.reload!(source).shape_id == source.shape_id
    assert shape_rows(context.organization, context.version, source.shape_id) == source_rows
  end

  test "copying a pattern with nil shape_id leaves the copy without shape rows" do
    context = setup_context()
    source = create_service!(context, ["A", "B"])
    assert is_nil(source.shape_id)

    copied = copy_pattern!(context, source)

    assert is_nil(Repo.reload!(copied).shape_id)
    assert version_shape_count(context.organization, context.version) == 0
  end

  test "copying a stale drawn pattern copies overrides but allocates no shape" do
    context = setup_context()
    source = create_service!(context, ["A", "B", "C"])
    [a, b, c] = occurrences(source.id)

    points = [[-74.0055, 40.7131]]
    insert_override(context.organization, context.version, a, "A", "B", points)
    insert_shared(context.organization, context.version, "B", "C", [])

    assert {:ok, review} = Gtfs.review_alignment_save(source.id, [], context.audit)
    assert review.origin.complete? == true

    assert {:ok, _} =
             Gtfs.apply_alignment_save(source.id, [], %{}, review.fingerprint, context.audit)

    source = Repo.reload!(source)
    assert source.shape_id != nil
    source_row_count = length(shape_rows(context.organization, context.version, source.shape_id))
    assert source_row_count > 0

    timing = Repo.one!(from t in TimedPattern, where: t.route_pattern_id == ^source.id)

    operation =
      {:stops,
       [
         %{id: a.id, stop_id: a.stop_id},
         %{id: c.id, stop_id: c.stop_id},
         %{id: b.id, stop_id: b.stop_id}
       ], %{timing.id => %{}}}

    {:ok, %{source_fingerprint: stale_source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        source.id
      )

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(source.id, operation, stale_source, context.audit)

    assert {:ok, _} = Gtfs.apply_review(source.id, operation, fingerprint, context.audit)

    stale = Repo.reload!(source)
    assert stale.shape_id == source.shape_id
    assert Alignments.resolve(stale).status.export == :stale

    copied = copy_pattern!(context, stale)
    [copied_first | _] = occurrences(copied.id)

    # The stale override row copies verbatim onto the copy's position-1 visit.
    assert override_for(context.organization, context.version, copied_first.id).points == points

    # Incomplete copies keep nil shape_id with no new shape rows (INV-3).
    assert is_nil(Repo.reload!(copied).shape_id)
    assert version_shape_count(context.organization, context.version) == source_row_count
  end
end
