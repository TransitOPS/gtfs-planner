defmodule GtfsPlanner.Gtfs.RoutePatterns.GroupingPreviewTest do
  @moduledoc """
  The grouping preview answers what the review would offer, without writing.

  The fixture is the North Coast Transit scenario from the trip-grouping
  prototype: 24 direction-less supplement trips over two stop orders (18 over
  the route's full 13-stop order, 6 over its first six stops), 2 out-of-order
  trips and one station-only trip. Every expected value is a literal from that
  scenario, the GTFS reference and the spec's rules; no production function
  computes one.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # The route runs due north on one meridian, so an offset stop's distance from
  # the drawn line is its own northing offset and no projection error competes
  # with the fixture's number.
  @line_lon -124.0
  @line_lat 44.0
  @line_step 0.001
  @drawn_legs 11
  @offset_stop_m 60.0
  @meters_per_degree_lat 111_320.0

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      version: version,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: Ecto.UUID.generate(),
        actor_email: "editor@example.com"
      }
    }
  end

  test "groups the direction-less trips and blocks the ones derivation would refuse", context do
    build_scenario(context)

    preview = preview!(context, "1")

    assert preview.groups |> Enum.map(& &1.trip_count) |> Enum.sort() == [6, 18]

    assert Enum.map(preview.blocked, &{&1.reason, length(&1.trip_ids)}) == [
             {:invalid_chronology, 2},
             {:unusable_stops, 1}
           ]
  end

  test "suggests the pattern's own direction and names the timing after its service", context do
    scenario = build_scenario(context)

    group = group_of(preview!(context, "1"), 18)

    assert group.suggestion == {:suggested, 0, {:same_endpoints, scenario.pattern.id}}
    assert group.direction_id == 0
    assert [%{id: pattern_id} | _rest] = group.candidates
    assert pattern_id == scenario.pattern.id
    assert group.timing_names == ["Summer weekday supplement"]
  end

  test "reports each stop's distance from the target's saved map line", context do
    scenario = build_scenario(context)
    save_line(context, scenario)

    group = group_of(preview!(context, "1"), 18)

    assert length(group.stop_distances_m) == 13
    assert Enum.map(group.stop_distances_m, &elem(&1, 0)) == scenario.stop_ids

    distance = Map.new(group.stop_distances_m)

    for stop_id <- Enum.take(scenario.stop_ids, 12) do
      assert_in_delta Map.fetch!(distance, stop_id), 0.0, 5.0
    end

    # The thirteenth stop was never drawn, so it sits 60 m beyond the line's end.
    assert_in_delta Map.fetch!(distance, List.last(scenario.stop_ids)), @offset_stop_m, 5.0
  end

  test "a candidate with no saved map line reports no distances", context do
    build_scenario(context)

    assert group_of(preview!(context, "1"), 18).stop_distances_m == nil
  end

  test "a labelled child's group is answered by its owner", context do
    owner = build_labelled_scenario(context)

    group = group_of(preview!(context, "1"), 3)

    # The owner has no derivation key and the child does, so rule 5 would rank
    # the child first: only the child's real `label_pattern_id` in the preview's
    # pattern refs makes the owner the answer instead.
    assert group.suggestion == {:suggested, 0, {:same_endpoints, owner.id}}
  end

  test "the fingerprint covers the trips' linkage", context do
    build_scenario(context)

    first = preview!(context, "1").fingerprint
    assert first == preview!(context, "1").fingerprint

    assert {:ok, %{fingerprint: same}} =
             Derivation.preview_left_out(context.organization.id, context.version.id, "1")

    assert first == same

    trip = Repo.one!(from(t in Trip, where: t.route_id == "1", order_by: t.trip_id, limit: 1))

    Repo.update_all(from(t in Trip, where: t.id == ^trip.id),
      set: [updated_at: DateTime.add(trip.updated_at, 1, :microsecond)]
    )

    refute first == preview!(context, "1").fingerprint
  end

  test "opening the review writes nothing", context do
    build_scenario(context)

    before = counts()
    preview!(context, "1")

    assert counts() == before
  end

  test "a route of another organization is not found", context do
    build_scenario(context)

    other = organization_fixture()
    other_version = gtfs_version_fixture(other.id)
    audit = %{context.audit | organization_id: other.id, gtfs_version_id: other_version.id}

    assert Gtfs.preview_left_out("1", audit) == {:error, :not_found}
    assert Derivation.preview_left_out(other.id, other_version.id, "1") == {:error, :not_found}
  end

  test "a version that is not published is not found", context do
    build_scenario(context)

    # `staging` is the lifecycle's own non-published state; `published_at` must
    # clear with it, which the migration's paired check requires.
    Repo.update_all(from(v in GtfsVersion, where: v.id == ^context.version.id),
      set: [publication_status: "staging", published_at: nil]
    )

    assert Gtfs.preview_left_out("1", context.audit) == {:error, :not_found}
  end

  # Two patterns over one stop order: an owner with no derivation key and a
  # label child that carries one, so the child is the pattern rule 5 would answer
  # with first. Only the child's real `label_pattern_id` makes the owner the
  # answer instead, which is what this preview has to carry.
  defp build_labelled_scenario(context) do
    org_id = context.organization.id
    version_id = context.version.id

    route_fixture(org_id, version_id, %{route_id: "1"})

    stop_ids =
      for index <- 1..6 do
        stop_fixture(org_id, version_id, %{
          stop_id: "stop_label_#{index}",
          stop_name: "Label Stop #{index}",
          stop_lat: @line_lat + index * @line_step,
          stop_lon: @line_lon
        }).stop_id
      end

    owner = insert_order_pattern(org_id, version_id, "pattern_owner", nil, stop_ids, nil)
    insert_order_pattern(org_id, version_id, "pattern_child", "d0-child", stop_ids, owner.id)

    calendar_attribute_fixture(org_id, version_id, %{
      service_id: "LB1",
      service_description: "Label benchmark"
    })

    insert_supplement(org_id, version_id, stop_ids, "label", stop_ids, 3, "LB1", 0)

    owner
  end

  # `label_pattern_id` is not cast by the changeset, so a child is linked the
  # same way derivation links one.
  defp insert_order_pattern(
         org_id,
         version_id,
         route_pattern_id,
         derivation_key,
         stop_ids,
         owner_id
       ) do
    pattern =
      route_pattern_fixture(org_id, version_id, %{
        route_pattern_id: route_pattern_id,
        route_id: "1",
        direction_id: 0,
        derivation_key: derivation_key,
        representative_trip_id: "supplement_label_1"
      })

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    Ecto.Changeset.change(pattern, label_pattern_id: owner_id) |> Repo.update!()
  end

  defp preview!(context, route_id) do
    {:ok, preview} = Gtfs.preview_left_out(route_id, context.audit)
    preview
  end

  defp group_of(preview, trip_count) do
    Enum.find(preview.groups, &(&1.trip_count == trip_count))
  end

  # --- fixture ---------------------------------------------------------------

  # The North Coast Transit supplement: 18 trips over the route's full order and
  # 6 over its first six stops, both with no direction, plus the two trips
  # derivation refuses for chronology and the one it refuses for a station stop.
  defp build_scenario(context) do
    org_id = context.organization.id
    version_id = context.version.id

    route_fixture(org_id, version_id, %{route_id: "1"})

    stop_ids = insert_line_stops(org_id, version_id)
    station_id = insert_station(org_id, version_id)

    pattern = insert_pattern(org_id, version_id, "1", stop_ids)

    for {service_id, description} <- [
          {"SU1", "Summer weekday supplement"},
          {"SU2", "Weekend connector"}
        ] do
      calendar_attribute_fixture(org_id, version_id, %{
        service_id: service_id,
        service_description: description
      })
    end

    insert_supplement(org_id, version_id, stop_ids, "full", stop_ids, 18, "SU1", 0)
    insert_supplement(org_id, version_id, stop_ids, "short", Enum.take(stop_ids, 6), 6, "SU2", 1)
    insert_out_of_order(org_id, version_id, stop_ids, 2)
    insert_station_trip(org_id, version_id, station_id)

    %{pattern: pattern, stop_ids: stop_ids}
  end

  # Twelve stops sit on the meridian at even spacing. The thirteenth is the same
  # meridian 60 m beyond the twelfth, so the distance the preview reports for it
  # is the fixture's own offset.
  defp insert_line_stops(org_id, version_id) do
    drawn =
      for index <- 0..11 do
        stop_fixture(org_id, version_id, %{
          stop_id: "stop_line_#{index}",
          stop_name: "Line Stop #{index}",
          stop_lat: @line_lat + index * @line_step,
          stop_lon: @line_lon
        }).stop_id
      end

    offset =
      stop_fixture(org_id, version_id, %{
        stop_id: "stop_line_12",
        stop_name: "Line Stop 12",
        stop_lat: @line_lat + 11 * @line_step + @offset_stop_m / @meters_per_degree_lat,
        stop_lon: @line_lon
      })

    drawn ++ [offset.stop_id]
  end

  # A station is not a boarding stop, so no editable pattern can contain one.
  defp insert_station(org_id, version_id) do
    stop_fixture(org_id, version_id, %{
      stop_id: "station_only",
      stop_name: "Depoe Bay Station",
      location_type: 1,
      stop_lat: @line_lat,
      stop_lon: @line_lon
    }).stop_id
  end

  defp insert_pattern(org_id, version_id, route_id, stop_ids) do
    pattern =
      route_pattern_fixture(org_id, version_id, %{
        route_pattern_id: "pattern_full",
        route_id: route_id,
        direction_id: 0,
        route_pattern_name: "Newport Transit Center – Lincoln City",
        derivation_key: "d0-full",
        representative_trip_id: "supplement_full_1"
      })

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  # One shared segment per drawn leg, carrying the meridian's midpoint as its
  # interior geometry. The twelfth leg is left undrawn, so the last stop is
  # measured against where the saved line actually ends.
  defp save_line(context, scenario) do
    org_id = context.organization.id
    version_id = context.version.id

    scenario.stop_ids
    |> Enum.take(@drawn_legs + 1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.each(fn {[from, to], index} ->
      from_lat = @line_lat + index * @line_step
      to_lat = @line_lat + (index + 1) * @line_step

      insert_segment(org_id, version_id, from, to, [[@line_lon, (from_lat + to_lat) / 2]])
    end)
  end

  # Scope fields are set on the struct, never cast: `AlignmentSegment.changeset/2`
  # casts only `:points` so a caller cannot write geometry into another scope.
  defp insert_segment(org_id, version_id, from_stop_id, to_stop_id, points) do
    %AlignmentSegment{
      organization_id: org_id,
      gtfs_version_id: version_id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  defp insert_supplement(org_id, version_id, all_stops, label, stop_ids, count, service, hour) do
    for index <- 1..count do
      trip_id = "supplement_#{label}_#{index}"

      insert_custom_trip(org_id, version_id, trip_id, service, "missing_direction")

      insert_vector(org_id, version_id, trip_id, stop_ids, hour * 60, length(all_stops))
    end
  end

  # Two trips whose second stop is served before the first departs: derivation
  # refuses them for chronology, so the preview blocks them for the same reason.
  defp insert_out_of_order(org_id, version_id, stop_ids, count) do
    [first, second | _rest] = stop_ids

    for index <- 1..count do
      trip_id = "out_of_order_#{index}"

      insert_custom_trip(org_id, version_id, trip_id, "SU1", "invalid_chronology")

      insert_vector(org_id, version_id, trip_id, [first, second], 7 * 60, 20,
        times: ["08:05:00", "08:00:00"]
      )
    end
  end

  # A trip served only from a station: the stop is not boarding-eligible, so
  # derivation classifies it `unusable_stops` and so does the preview.
  defp insert_station_trip(org_id, version_id, station_id) do
    trip_id = "station_trip_1"

    insert_custom_trip(org_id, version_id, trip_id, "SU1", "unusable_stops")

    insert_vector(org_id, version_id, trip_id, [station_id], 9 * 60, 30)
  end

  defp insert_custom_trip(org_id, version_id, trip_id, service_id, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Trip{}
    |> Ecto.Changeset.change(%{
      id: Ecto.UUID.generate(),
      trip_id: trip_id,
      route_id: "1",
      service_id: service_id,
      shape_id: "shape_#{trip_id}",
      direction_id: nil,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: reason,
      organization_id: org_id,
      gtfs_version_id: version_id,
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  # One minute per stop from `base`, so a trip's own times are chronological
  # unless the fixture deliberately makes them otherwise. `band` keeps each
  # group's `stop_sequence` values apart, which is what makes two stop orders
  # two groups rather than one merged order.
  defp insert_vector(org_id, version_id, trip_id, stop_ids, base, band, opts \\ []) do
    times = Keyword.get(opts, :times)

    stop_ids
    |> Enum.with_index()
    |> Enum.each(fn {stop_id, index} ->
      time = if times, do: Enum.at(times, index), else: hhmm(base + index)

      stop_time_fixture(org_id, version_id, trip_id, stop_id, %{
        stop_sequence: band * 1000 + index + 1,
        arrival_time: time,
        departure_time: time
      })
    end)
  end

  defp hhmm(minutes) do
    :io_lib.format("~2..0B:~2..0B:00", [div(minutes, 60), rem(minutes, 60)])
    |> to_string()
  end

  # The preview is read-only, so the mutation that must not happen is measured by
  # the row counts it would change and by the trip timestamps it would bump.
  defp counts do
    %{
      route_patterns: Repo.aggregate(RoutePattern, :count),
      timed_patterns: Repo.aggregate(TimedPattern, :count),
      route_pattern_stops: Repo.aggregate(RoutePatternStop, :count),
      stops: Repo.aggregate(Stop, :count),
      trips: Repo.aggregate(Trip, :count),
      max_trip_updated_at: Repo.one(from(t in Trip, select: max(t.updated_at)))
    }
  end
end
