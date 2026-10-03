defmodule GtfsPlanner.Gtfs.Alignments.StopEditDistancesTest do
  # R14: a 01 structural stop edit that reorders retained visits, or changes a
  # retained visit's stop, on a pattern with a drawn shape clears the visit
  # distances and the linked trips' stop-time distances in the same
  # transaction, keeps `shape_id`, and leaves the pattern `:stale`.
  #
  # Adaptation (repository evidence, probed before writing): 01's structural
  # validation rejects a retained reorder whenever linked trips exist
  # (`:invalid_occurrence_order`) and rejects a retained stop change always
  # (`:invalid_occurrence_identity`). The reorder and nil-shape cases below
  # therefore run without linked trips; the linked-trip stop-time half is
  # covered by the append case (no spurious clear with trips present) and by
  # calling `clear_visit_distances!/1` directly on a drawn pattern with a
  # linked trip. The boundary rejections are pinned so a future 01 relaxation
  # surfaces here.
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
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

  defp insert_shared(organization, version, from_id, to_id) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id
    }
    |> AlignmentSegment.changeset(%{points: []})
    |> Repo.insert!()
  end

  defp occurrences(pattern_id), do: stored_occurrences(pattern_id)

  defp timing_for(pattern_id), do: pattern_id |> stored_timings() |> hd()

  defp source_for(context, pattern) do
    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    source
  end

  defp visit_distances(pattern_id),
    do: pattern_id |> stored_occurrences() |> Enum.map(& &1.shape_dist_traveled)

  defp trip_distances(organization, version, trip_id) do
    Repo.all(
      from st in StopTime,
        where:
          st.organization_id == ^organization.id and
            st.gtfs_version_id == ^version.id and
            st.trip_id == ^trip_id,
        order_by: [asc: st.stop_sequence],
        select: st.shape_dist_traveled
    )
  end

  defp setup_context do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    stops = base_stops(organization, version)

    %{
      organization: organization,
      version: version,
      route: route,
      stops: stops,
      audit: audit(organization, version)
    }
  end

  # Draws A,B,C through the real alignment save (empty-draft materialize-only
  # path): inserts straight shared sections, reviews, and applies.
  defp draw_pattern!(context) do
    {:ok, pattern} =
      Gtfs.create_pattern(
        context.route.route_id,
        %{
          route_pattern_name: "Service",
          direction_id: 0,
          stops: ["A", "B", "C"]
        },
        context.audit
      )

    insert_shared(context.organization, context.version, "A", "B")
    insert_shared(context.organization, context.version, "B", "C")

    assert {:ok, review} = Gtfs.review_alignment_save(pattern.id, [], context.audit)
    assert review.origin.complete? == true

    assert {:ok, result} =
             Gtfs.apply_alignment_save(pattern.id, [], %{}, review.fingerprint, context.audit)

    assert result.materialized == [Repo.reload!(pattern).route_pattern_id]

    pattern = Repo.reload!(pattern)
    assert pattern.shape_id != nil

    distances = visit_distances(pattern.id)
    assert length(distances) == 3
    assert Enum.all?(distances, &(&1 != nil))
    assert distances == Enum.sort(distances, Decimal)

    {pattern, distances}
  end

  defp link_trip_with_distances!(context, pattern, distances) do
    timing = timing_for(pattern.id)

    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    trip =
      trip
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
      |> Repo.update!()

    ["A", "B", "C"]
    |> Enum.zip(distances)
    |> Enum.with_index(1)
    |> Enum.each(fn {{stop_id, dist}, sequence} ->
      stop_time_fixture(context.organization.id, context.version.id, trip.trip_id, stop_id, %{
        stop_sequence: sequence,
        shape_dist_traveled: dist
      })
    end)

    Repo.reload!(trip)
  end

  defp shape_row_count(organization, version, shape_id) do
    Repo.aggregate(
      from(s in GtfsPlanner.Gtfs.Shape,
        where:
          s.organization_id == ^organization.id and
            s.gtfs_version_id == ^version.id and
            s.shape_id == ^shape_id
      ),
      :count
    )
  end

  test "reordering a drawn pattern clears visit distances, keeps shape_id and reports stale" do
    context = setup_context()
    {pattern, _drawn} = draw_pattern!(context)

    [a, b, c] = occurrences(pattern.id)
    timing = timing_for(pattern.id)
    shape_id = pattern.shape_id
    shape_count = shape_row_count(context.organization, context.version, shape_id)

    operation =
      {:stops,
       [
         %{id: a.id, stop_id: a.stop_id},
         %{id: c.id, stop_id: c.stop_id},
         %{id: b.id, stop_id: b.stop_id}
       ], %{timing.id => %{}}}

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, operation, source_for(context, pattern), context.audit)

    assert {:ok, %{trips_updated: 0}} =
             Gtfs.apply_review(pattern.id, operation, fingerprint, context.audit)

    assert visit_distances(pattern.id) == [nil, nil, nil]

    assert Repo.reload!(pattern).shape_id == shape_id
    assert shape_row_count(context.organization, context.version, shape_id) == shape_count

    assert %{status: %{export: :stale}} = Alignments.resolve(Repo.reload!(pattern))
  end

  test "a retained reorder is rejected while linked trips exist" do
    context = setup_context()
    {pattern, drawn} = draw_pattern!(context)
    trip = link_trip_with_distances!(context, pattern, drawn)

    [a, b, c] = occurrences(pattern.id)
    timing = timing_for(pattern.id)

    operation =
      {:stops,
       [
         %{id: a.id, stop_id: a.stop_id},
         %{id: c.id, stop_id: c.stop_id},
         %{id: b.id, stop_id: b.stop_id}
       ], %{timing.id => %{}}}

    assert {:error, :invalid_occurrence_order} =
             Gtfs.review(pattern.id, operation, source_for(context, pattern), context.audit)

    assert visit_distances(pattern.id) == drawn
    assert trip_distances(context.organization, context.version, trip.trip_id) == drawn
  end

  test "appending a visit keeps retained visit and stop-time distances, with nil for the new visit" do
    context = setup_context()
    {pattern, drawn} = draw_pattern!(context)
    trip = link_trip_with_distances!(context, pattern, drawn)

    stop_with_coords(context.organization, context.version, "D", "40.715800", "-74.003000")
    [a, b, c] = occurrences(pattern.id)
    timing = timing_for(pattern.id)
    shape_id = Repo.reload!(pattern).shape_id

    operation =
      {:stops,
       [
         %{id: a.id, stop_id: a.stop_id},
         %{id: b.id, stop_id: b.stop_id},
         %{id: c.id, stop_id: c.stop_id},
         %{key: "new-d", stop_id: "D"}
       ], %{timing.id => %{acknowledged: true, rows: append_rows()}}}

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, operation, source_for(context, pattern), context.audit)

    assert {:ok, %{trips_updated: 1}} =
             Gtfs.apply_review(pattern.id, operation, fingerprint, context.audit)

    assert visit_distances(pattern.id) == drawn ++ [nil]
    assert trip_distances(context.organization, context.version, trip.trip_id) == drawn ++ [nil]
    assert Repo.reload!(pattern).shape_id == shape_id
  end

  test "clearing a drawn pattern with a linked trip nils visits and stop times but keeps shape_id" do
    context = setup_context()
    {pattern, drawn} = draw_pattern!(context)
    trip = link_trip_with_distances!(context, pattern, drawn)

    [a, b, c] = occurrences(pattern.id)
    timing = timing_for(pattern.id)
    shape_id = pattern.shape_id

    # The prepared in-place replacement cannot go through the 01 facade: a
    # retained occurrence keeps its stop identity there.
    assert {:error, :invalid_occurrence_identity} =
             Gtfs.review(
               pattern.id,
               {:stops,
                [
                  %{id: a.id, stop_id: a.stop_id},
                  %{id: b.id, stop_id: "C"},
                  %{id: c.id, stop_id: c.stop_id}
                ], %{timing.id => %{}}},
               source_for(context, pattern),
               context.audit
             )

    :ok = Alignments.clear_visit_distances!(Repo.reload!(pattern))

    assert visit_distances(pattern.id) == [nil, nil, nil]
    assert trip_distances(context.organization, context.version, trip.trip_id) == [nil, nil, nil]
    assert Repo.reload!(pattern).shape_id == shape_id

    # Clearing alone touches no geometry or anchors, so the digest still
    # matches and the complete pattern stays `:current`; the `:stale` status
    # in production follows from the structural change that triggered the
    # clear (reordered or replaced sections no longer resolve).
    assert %{status: %{export: :current}} = Alignments.resolve(Repo.reload!(pattern))
  end

  test "reordering a pattern without shape_id leaves its visit distances unchanged" do
    context = setup_context()

    {:ok, pattern} =
      Gtfs.create_pattern(
        context.route.route_id,
        %{
          route_pattern_name: "Service",
          direction_id: 0,
          stops: ["A", "B", "C"]
        },
        context.audit
      )

    [a, b, c] = occurrences(pattern.id)

    [d0, d1, d2] = [Decimal.new("0.00"), Decimal.new("400.00"), Decimal.new("900.00")]

    Enum.zip([a, b, c], [d0, d1, d2])
    |> Enum.each(fn {occurrence, dist} ->
      Repo.update_all(
        from(o in RoutePatternStop, where: o.id == ^occurrence.id),
        set: [shape_dist_traveled: dist]
      )
    end)

    timing = timing_for(pattern.id)

    operation =
      {:stops,
       [
         %{id: a.id, stop_id: a.stop_id},
         %{id: c.id, stop_id: c.stop_id},
         %{id: b.id, stop_id: b.stop_id}
       ], %{timing.id => %{}}}

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, operation, source_for(context, pattern), context.audit)

    assert {:ok, %{trips_updated: 0}} =
             Gtfs.apply_review(pattern.id, operation, fingerprint, context.audit)

    after_by_id =
      Map.new(occurrences(pattern.id), &{&1.id, &1.shape_dist_traveled})

    assert after_by_id == %{a.id => d0, b.id => d1, c.id => d2}
    assert Repo.reload!(pattern).shape_id == nil
  end

  # The appended terminal visit has no following anchor to interpolate from,
  # so 01 requires explicit clock values matched by the entry's key.
  defp append_rows do
    [%{key: "new-d", arrival_offset: 900, departure_offset: 960}]
  end
end
