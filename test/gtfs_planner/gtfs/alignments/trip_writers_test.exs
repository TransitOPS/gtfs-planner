defmodule GtfsPlanner.Gtfs.Alignments.TripWritersTest do
  # Step 17 / EV-16: trips created or duplicated through the real `Gtfs`
  # facade carry the pattern's shape ID and per-visit distances (R15).
  # A drawn pattern contributes its shape and visit distances by position;
  # an undrawn pattern contributes nil; duplicating a trip whose shape
  # differs from the pattern's keeps the source shape with nil distances.
  # Expected meridian distances are hand-derived haversine constants from
  # the independent oracle (see `MaterializerTest`), never computed with
  # the module under test.
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  @expected_distances [Decimal.new("0.00"), Decimal.new("111.20"), Decimal.new("333.59")]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
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

  # Meridian stops matching the materializer oracle: A→B is 111.20 m and
  # B→C (via interior [0.0, 0.002]) brings C to 333.59 m.
  defp meridian_stops(organization, version) do
    stop_with_coords(organization, version, "A", "0.000000", "0.000000")
    stop_with_coords(organization, version, "B", "0.001000", "0.000000")
    stop_with_coords(organization, version, "C", "0.003000", "0.000000")
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

  defp weekly_calendar!(context, name) do
    attrs = %{
      service_id: "wk_#{System.unique_integer([:positive])}",
      name: name,
      kind: :weekly,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-02-27]
    }

    assert {:ok, _payload} = Gtfs.create_calendar(attrs, context.audit)
    attrs.service_id
  end

  # Draws the meridian pattern through the real alignment save, so the
  # pattern owns shape "P1" (allocated from its natural ID) with the
  # oracle visit distances.
  defp draw_meridian_pattern!(context, route_id) do
    meridian_stops(context.organization, context.version)
    route_fixture(context.organization.id, context.version.id, %{route_id: route_id})

    bundle =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: route_id,
        route_pattern_id: "P1",
        stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]
      })

    insert_shared(context.organization, context.version, "A", "B", [])
    insert_shared(context.organization, context.version, "B", "C", [[0.0, 0.002]])

    assert {:ok, review} =
             Gtfs.review_alignment_save(bundle.pattern.id, [], context.audit)

    assert review.origin.complete? == true

    assert {:ok, result} =
             Gtfs.apply_alignment_save(
               bundle.pattern.id,
               [],
               %{},
               review.fingerprint,
               context.audit
             )

    assert result.materialized == ["P1"]

    pattern = Repo.reload!(bundle.pattern)
    assert pattern.shape_id == "P1"
    assert_distances(visit_distances(pattern.id), @expected_distances)

    %{bundle: bundle, pattern: pattern}
  end

  defp visit_distances(pattern_id) do
    Repo.all(
      from o in RoutePatternStop,
        where: o.route_pattern_id == ^pattern_id,
        order_by: [asc: o.position],
        select: o.shape_dist_traveled
    )
  end

  defp persisted_distances(organization, version, trip_id) do
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

  defp assert_distances(actual, expected) do
    assert length(actual) == length(expected)

    actual
    |> Enum.zip(expected)
    |> Enum.each(fn
      {nil, nil} -> :ok
      {got, want} -> assert Decimal.compare(got, want) == :eq
    end)
  end

  test "created trips on a drawn pattern carry its shape and visit distances", context do
    %{bundle: bundle} = draw_meridian_pattern!(context, "tw1")
    service = weekly_calendar!(context, "Weekday tw1")
    before = DateTime.utc_now()

    assert {:ok, %{trips: trips}} =
             Gtfs.create_trips(
               "tw1",
               %{
                 pattern_id: bundle.pattern.id,
                 timed_pattern_id: bundle.timing.id,
                 service_id: service,
                 start_time: "06:00:00",
                 repeat: %{every_minutes: 30, until: "06:30:00"}
               },
               context.audit
             )

    assert length(trips) == 2

    Enum.each(trips, fn trip ->
      assert trip.shape_id == "P1"
      # INV-4: the new trip rows carry a current `updated_at` for 03's
      # stale-plan fingerprint.
      assert DateTime.compare(trip.updated_at, before) in [:eq, :gt]

      assert_distances(
        persisted_distances(context.organization, context.version, trip.trip_id),
        @expected_distances
      )
    end)
  end

  test "created trips on a pattern without a shape keep nil shape and distances", context do
    route_fixture(context.organization.id, context.version.id, %{route_id: "tw2"})

    bundle =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: "tw2",
        stops: [{"X", 0, 0, 1}, {"Y", 300, 300, 1}]
      })

    service = weekly_calendar!(context, "Weekday tw2")

    assert {:ok, %{trips: [trip]}} =
             Gtfs.create_trips(
               "tw2",
               %{
                 pattern_id: bundle.pattern.id,
                 timed_pattern_id: bundle.timing.id,
                 service_id: service,
                 start_time: "06:00:00"
               },
               context.audit
             )

    assert trip.shape_id == nil

    assert_distances(
      persisted_distances(context.organization, context.version, trip.trip_id),
      [nil, nil]
    )
  end

  test "duplicating a trip on the pattern shape copies the shape and takes pattern distances",
       context do
    %{bundle: bundle} = draw_meridian_pattern!(context, "tw3")
    service = weekly_calendar!(context, "Weekday tw3")

    assert {:ok, %{trips: [source]}} =
             Gtfs.create_trips(
               "tw3",
               %{
                 pattern_id: bundle.pattern.id,
                 timed_pattern_id: bundle.timing.id,
                 service_id: service,
                 start_time: "06:00:00"
               },
               context.audit
             )

    assert source.shape_id == "P1"

    assert {:ok, copy} =
             Gtfs.duplicate_trip(
               "tw3",
               source.id,
               %{start_time: "07:00:00", timed_pattern_id: bundle.timing.id},
               context.audit
             )

    assert copy.id != source.id
    assert copy.shape_id == "P1"

    assert_distances(
      persisted_distances(context.organization, context.version, copy.trip_id),
      @expected_distances
    )
  end

  test "duplicating a trip on an imported shape keeps the shape and nils distances",
       context do
    %{bundle: bundle} = draw_meridian_pattern!(context, "tw4")
    service = weekly_calendar!(context, "Weekday tw4")

    source =
      schedule_trip_fixture(
        context.organization.id,
        context.version.id,
        "tw4",
        bundle,
        %{
          service_id: service,
          start_time: "06:00:00"
        }
      ).trip

    # An imported shape on the source trip: it differs from the pattern's
    # shape, so the duplicate must keep it with nil distances.
    source =
      source
      |> Ecto.Changeset.change(%{shape_id: "X"})
      |> Repo.update!()

    # A stale distance vector on the source must not leak onto the copy.
    source
    |> persisted_source_rows()
    |> Enum.each(fn row ->
      Repo.update!(Ecto.Changeset.change(row, shape_dist_traveled: Decimal.new("1.50")))
    end)

    assert {:ok, copy} =
             Gtfs.duplicate_trip(
               "tw4",
               source.id,
               %{start_time: "07:00:00", timed_pattern_id: bundle.timing.id},
               context.audit
             )

    assert copy.shape_id == "X"

    assert_distances(
      persisted_distances(context.organization, context.version, copy.trip_id),
      [nil, nil, nil]
    )
  end

  defp persisted_source_rows(source) do
    Repo.all(
      from st in StopTime,
        where: st.trip_id == ^source.trip_id,
        order_by: [asc: st.stop_sequence]
    )
  end
end
