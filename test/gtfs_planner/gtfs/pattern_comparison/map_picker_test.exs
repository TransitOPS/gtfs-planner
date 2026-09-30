defmodule GtfsPlanner.Gtfs.PatternComparison.MapPickerTest do
  @moduledoc """
  Merge evidence (EV-9) for CL-20 and CL-22: `map_payload/3` classifies the two
  sides' sections and stops per R10, and `picker_patterns/3` lists exactly the
  version's published patterns with their stop names and ranks them by stops in
  common, then trips.

  Every expected coordinate, section, stop and count below is hand-derived from
  the fixtures. A saved section is drawn through its two visit anchors and its
  stored interior `[lon, lat]` points, a missing or blocked section is the
  straight two-anchor connector, sections equal on both sides are one `:both`
  line, and a section whose visit has no coordinates is dropped with its stop.
  The picker's `trips` follow R7 through the shared `Schedules.frequency_windows/1`
  and `Summary.trips_per_hour/2` expansion (end-exclusive: 10:00-13:30 at a
  30-minute headway is 7 departures, and the frequency trip's own row is not
  counted). The focused gate command is deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner/gtfs/pattern_comparison/map_picker_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.PatternComparison
  alias GtfsPlanner.Gtfs.PatternComparison.Usage
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # Interior points as stored: `[lon, lat]` only, the visits are the anchors.
  @shared_points [[-124.056, 44.635]]
  @override_points [[-124.061, 44.65]]
  @both_points [[-124.062, 44.7]]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "1",
        route_long_name: "Coast Line"
      })

    other_route =
      route_fixture(organization.id, version.id, %{
        route_id: "R11",
        route_short_name: "11",
        route_long_name: "City Center"
      })

    located_stop(organization, version, "s1", "City Hall", "44.63", "-124.05")
    located_stop(organization, version, "s2", "Nye Beach", "44.64", "-124.06")
    located_stop(organization, version, "s3", "Depoe Bay", "44.8", "-124.06")
    located_stop(organization, version, "s4", "Otter Rock", "44.75", "-124.07")
    located_stop(organization, version, "s5", "Newport", "44.62", "-124.04")
    located_stop(organization, version, "s6", "Toledo", "44.61", "-123.93")
    located_stop(organization, version, "s7", "Siletz", "44.72", "-123.92")

    # The unlocated stop the gap pattern calls at: no coordinates, so no marker
    # and no drawable section through it.
    stop_fixture(organization.id, version.id, %{
      stop_id: "s9",
      stop_name: "Unmapped",
      stop_lat: nil,
      stop_lon: nil
    })

    full =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "full", name: "Full", direction_id: 0, sort_order: 0, description: "All day"},
        [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 1},
          {"s4", 180, 180, 1},
          {"s5", 240, 240, 1}
        ]
      )

    via =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "via", name: "Via Otter Crest", direction_id: 0, sort_order: 1},
        [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 1},
          {"s4", 180, 180, 1},
          {"s6", 240, 240, 1}
        ]
      )

    other =
      schedule_pattern(
        organization,
        version,
        other_route,
        %{
          id: "other",
          name: "City Center",
          direction_id: 0,
          sort_order: 0,
          description: "Every day"
        },
        [{"s2", 0, 0, 1}, {"s3", 60, 60, 1}, {"s7", 120, 120, 1}]
      )

    gap =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "gap", name: "Gap", direction_id: 1, sort_order: 0},
        [{"s1", 0, 0, 1}, {"s9", 60, 60, 1}, {"s2", 120, 120, 1}]
      )

    # One shared row serves both patterns' first section; the (s3, s4) override
    # is saved identically on both, so R10 draws it once. The gap pattern's
    # saved (s1, s9) section is blocked by the unlocated visit.
    insert_shared(organization, version, "s1", "s2", @shared_points)

    insert_override(
      organization,
      version,
      Enum.at(full.occurrences, 1),
      "s2",
      "s3",
      @override_points
    )

    insert_override(organization, version, Enum.at(full.occurrences, 2), "s3", "s4", @both_points)
    insert_override(organization, version, Enum.at(via.occurrences, 2), "s3", "s4", @both_points)
    insert_override(organization, version, hd(gap.occurrences), "s1", "s9", [[-124.052, 44.635]])

    # WEEKDAY: full 3, other 1 scheduled + a repeating trip of 7 departures
    # (10:00-13:30 at a 30-minute headway, end-exclusive). SATURDAY: via 1.
    linked_trips(organization, version, route, full, "WEEKDAY", ~w(06:00:00 07:00:00 08:00:00))
    linked_trips(organization, version, other_route, other, "WEEKDAY", ~w(09:00:00))
    repeating_trip(organization, version, other_route, other)
    linked_trips(organization, version, route, via, "SATURDAY", ~w(10:00:00))

    # The same natural pattern ID in another organization, in another version of
    # this organization and in an unpublished staging version: none may appear.
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_route = route_fixture(foreign_organization.id, foreign_version.id, %{route_id: "R1"})

    _foreign_pattern =
      schedule_pattern(
        foreign_organization,
        foreign_version,
        foreign_route,
        %{id: "foreign", name: "Foreign", direction_id: 0, sort_order: 0},
        [{"s1", 0, 0, 1}]
      )

    other_version = gtfs_version_fixture(organization.id)
    other_version_route = route_fixture(organization.id, other_version.id, %{route_id: "R1"})

    _other_version_pattern =
      schedule_pattern(
        organization,
        other_version,
        other_version_route,
        %{id: "elsewhere", name: "Elsewhere", direction_id: 0, sort_order: 0},
        [{"s1", 0, 0, 1}]
      )

    {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})
    staging_route = route_fixture(organization.id, staging.id, %{route_id: "R1"})

    _staging_pattern =
      schedule_pattern(
        organization,
        staging,
        staging_route,
        %{id: "staged", name: "Staged", direction_id: 0, sort_order: 0},
        [{"s1", 0, 0, 1}]
      )

    %{
      scope: %{organization_id: organization.id, gtfs_version_id: version.id},
      organization: organization,
      version: version,
      route: route,
      via: via,
      other: other,
      foreign_scope: %{
        organization_id: foreign_organization.id,
        gtfs_version_id: foreign_version.id
      },
      other_version_scope: %{
        organization_id: organization.id,
        gtfs_version_id: other_version.id
      },
      staging_scope: %{organization_id: organization.id, gtfs_version_id: staging.id}
    }
  end

  test "draws an identical saved section once as :both and keeps each side's own", context do
    assert {:ok, payload} = PatternComparison.map_payload(context.scope, "full", "via")

    s1 = [-124.05, 44.63]
    s2 = [-124.06, 44.64]
    s3 = [-124.06, 44.8]
    s4 = [-124.07, 44.75]
    s5 = [-124.04, 44.62]
    s6 = [-123.93, 44.61]

    # A's sections in order (shared, override, identical override, missing), then
    # B's own sections (both missing) in B's order.
    assert payload.sections == [
             %{
               from_stop_id: "s1",
               to_stop_id: "s2",
               series: :both,
               style: :path,
               points: [s1, [-124.056, 44.635], s2]
             },
             %{
               from_stop_id: "s2",
               to_stop_id: "s3",
               series: :a,
               style: :path,
               points: [s2, [-124.061, 44.65], s3]
             },
             %{
               from_stop_id: "s3",
               to_stop_id: "s4",
               series: :both,
               style: :path,
               points: [s3, [-124.062, 44.7], s4]
             },
             %{
               from_stop_id: "s4",
               to_stop_id: "s5",
               series: :a,
               style: :connector,
               points: [s4, s5]
             },
             %{
               from_stop_id: "s2",
               to_stop_id: "s3",
               series: :b,
               style: :connector,
               points: [s2, s3]
             },
             %{
               from_stop_id: "s4",
               to_stop_id: "s6",
               series: :b,
               style: :connector,
               points: [s4, s6]
             }
           ]

    assert payload.ends == %{
             a: %{first_stop_id: "s1", last_stop_id: "s5"},
             b: %{first_stop_id: "s1", last_stop_id: "s6"}
           }

    assert payload.pins == []
  end

  test "marks served stops :both, :a or :b", context do
    assert {:ok, payload} = PatternComparison.map_payload(context.scope, "full", "via")

    assert payload.stops == [
             %{stop_id: "s1", name: "City Hall", coordinates: [-124.05, 44.63], served: :both},
             %{stop_id: "s2", name: "Nye Beach", coordinates: [-124.06, 44.64], served: :both},
             %{stop_id: "s3", name: "Depoe Bay", coordinates: [-124.06, 44.8], served: :both},
             %{stop_id: "s4", name: "Otter Rock", coordinates: [-124.07, 44.75], served: :both},
             %{stop_id: "s5", name: "Newport", coordinates: [-124.04, 44.62], served: :a},
             %{stop_id: "s6", name: "Toledo", coordinates: [-123.93, 44.61], served: :b}
           ]
  end

  test "omits a section touching a stop without coordinates and its stop", context do
    assert {:ok, payload} = PatternComparison.map_payload(context.scope, "gap", nil)

    # Both sections are blocked by the unlocated visit, so neither can reach two
    # points; the visits' own located stops remain markers.
    assert payload.sections == []

    assert payload.stops == [
             %{stop_id: "s1", name: "City Hall", coordinates: [-124.05, 44.63], served: :a},
             %{stop_id: "s2", name: "Nye Beach", coordinates: [-124.06, 44.64], served: :a}
           ]

    assert payload.ends == %{
             a: %{first_stop_id: "s1", last_stop_id: "s2"},
             b: nil
           }
  end

  test "keeps map reads inside the organization, version and published route", context do
    assert PatternComparison.map_payload(context.scope, "missing", nil) == {:error, :not_found}

    assert PatternComparison.map_payload(context.scope, "foreign", nil) == {:error, :not_found}

    assert PatternComparison.map_payload(context.scope, "elsewhere", nil) ==
             {:error, :not_found}

    assert PatternComparison.map_payload(context.scope, "staged", nil) == {:error, :not_found}

    assert PatternComparison.map_payload(context.foreign_scope, "full", nil) ==
             {:error, :not_found}

    assert PatternComparison.map_payload(context.other_version_scope, "full", nil) ==
             {:error, :not_found}

    assert PatternComparison.map_payload(context.staging_scope, "staged", nil) ==
             {:error, :not_found}

    # A B outside the scope contributes no geometry at all: the payload is the
    # same as the one without a B.
    assert PatternComparison.map_payload(context.scope, "full", "foreign") ==
             PatternComparison.map_payload(context.scope, "full", nil)

    assert PatternComparison.map_payload(context.scope, "full", "elsewhere") ==
             PatternComparison.map_payload(context.scope, "full", nil)

    assert PatternComparison.map_payload(context.scope, "full", "staged") ==
             PatternComparison.map_payload(context.scope, "full", nil)
  end

  test "lists the version's published patterns with route names, direction and stop names",
       context do
    assert {:ok, entries} = PatternComparison.picker_patterns(context.scope, "full", "WEEKDAY")

    # Ranked by stops in common with full, then trips on WEEKDAY: full 5/3,
    # via 4/0, other 2/8 (1 scheduled + 7 frequency departures), gap 2/0.
    assert entries == [
             %{
               route_pattern_id: "full",
               name: "Full",
               route_id: "R1",
               route_short_name: "1",
               route_long_name: "Coast Line",
               direction_id: 0,
               service_description: "All day",
               stop_ids: ~w(s1 s2 s3 s4 s5),
               stop_names: %{
                 "s1" => "City Hall",
                 "s2" => "Nye Beach",
                 "s3" => "Depoe Bay",
                 "s4" => "Otter Rock",
                 "s5" => "Newport"
               },
               shared: 5,
               trips: 3
             },
             %{
               route_pattern_id: "via",
               name: "Via Otter Crest",
               route_id: "R1",
               route_short_name: "1",
               route_long_name: "Coast Line",
               direction_id: 0,
               service_description: nil,
               stop_ids: ~w(s1 s2 s3 s4 s6),
               stop_names: %{
                 "s1" => "City Hall",
                 "s2" => "Nye Beach",
                 "s3" => "Depoe Bay",
                 "s4" => "Otter Rock",
                 "s6" => "Toledo"
               },
               shared: 4,
               trips: 0
             },
             %{
               route_pattern_id: "other",
               name: "City Center",
               route_id: "R11",
               route_short_name: "11",
               route_long_name: "City Center",
               direction_id: 0,
               service_description: "Every day",
               stop_ids: ~w(s2 s3 s7),
               stop_names: %{"s2" => "Nye Beach", "s3" => "Depoe Bay", "s7" => "Siletz"},
               shared: 2,
               trips: 8
             },
             %{
               route_pattern_id: "gap",
               name: "Gap",
               route_id: "R1",
               route_short_name: "1",
               route_long_name: "Coast Line",
               direction_id: 1,
               service_description: nil,
               stop_ids: ~w(s1 s9 s2),
               stop_names: %{"s1" => "City Hall", "s9" => "Unmapped", "s2" => "Nye Beach"},
               shared: 2,
               trips: 0
             }
           ]
  end

  test "ranks by stops in common with the other side, then trips on the calendar", context do
    # other shares 3 stops, full and via 2, gap 1; trips then break the 2-2 tie
    # for full (3) over via (0).
    assert {:ok, entries} = PatternComparison.picker_patterns(context.scope, "other", "WEEKDAY")

    assert Enum.map(entries, &{&1.route_pattern_id, &1.shared, &1.trips}) == [
             {"other", 3, 8},
             {"full", 2, 3},
             {"via", 2, 0},
             {"gap", 1, 0}
           ]

    # The picker's count is R7's count: the comparison's own Usage read counts
    # the same pattern on the same calendar as 8 (1 scheduled + 7 departures).
    assert Usage.usage(context.scope, [context.other.pattern], "WEEKDAY")["other"].total == 8

    # With no other side everything shares nothing and trips decide; the read
    # order breaks the last tie (route, direction, sort order, natural ID).
    assert {:ok, entries} = PatternComparison.picker_patterns(context.scope, nil, "WEEKDAY")

    assert Enum.map(entries, &{&1.route_pattern_id, &1.shared, &1.trips}) == [
             {"other", 0, 8},
             {"full", 0, 3},
             {"via", 0, 0},
             {"gap", 0, 0}
           ]

    # On SATURDAY via is the only pattern with trips, and gap precedes other on
    # the shared-2, trips-0 tie because R1 sorts before R11.
    assert {:ok, entries} = PatternComparison.picker_patterns(context.scope, "full", "SATURDAY")

    assert Enum.map(entries, &{&1.route_pattern_id, &1.shared, &1.trips}) == [
             {"full", 5, 0},
             {"via", 4, 1},
             {"gap", 2, 0},
             {"other", 2, 0}
           ]

    # An unknown calendar counts nothing but still lists the version's patterns;
    # the shared-2 tie keeps the read order (R1 before R11).
    assert {:ok, entries} = PatternComparison.picker_patterns(context.scope, "full", "SUNDAY")

    assert Enum.map(entries, &{&1.route_pattern_id, &1.trips}) == [
             {"full", 0},
             {"via", 0},
             {"gap", 0},
             {"other", 0}
           ]
  end

  test "counts plain trips and every window of a repeating trip in one pattern", context do
    # via on WEEKDAY: two plain trips, plus one repeating trip with two usable
    # windows (06:00-07:00 every 20 minutes is 3 departures, 16:00-17:00 every
    # 30 minutes is 2) and a row with an unparseable start that adds nothing.
    linked_trips(
      context.organization,
      context.version,
      context.route,
      context.via,
      "WEEKDAY",
      ~w(07:00:00 08:00:00)
    )

    frequency_trip(context, "WEEKDAY", [
      %{start_time: "06:00:00", end_time: "07:00:00", headway_secs: 1200},
      %{start_time: "16:00:00", end_time: "17:00:00", headway_secs: 1800},
      %{start_time: "later", end_time: "20:00:00", headway_secs: 600}
    ])

    assert picker_trips(context, "WEEKDAY") == %{
             "full" => 3,
             "via" => 7,
             "other" => 8,
             "gap" => 0
           }
  end

  test "counts a trip whose frequency rows are all unusable as one departure", context do
    # via on WEEKDAY: one plain trip and one trip whose two rows are unusable, an
    # unparseable start and an unparseable end, so each counts as 1.
    linked_trips(
      context.organization,
      context.version,
      context.route,
      context.via,
      "WEEKDAY",
      ~w(07:00:00)
    )

    frequency_trip(context, "WEEKDAY", [
      %{start_time: "later", end_time: "13:30:00", headway_secs: 1800},
      %{start_time: "10:00:00", end_time: "soon", headway_secs: 1800}
    ])

    assert picker_trips(context, "WEEKDAY") == %{
             "full" => 3,
             "via" => 2,
             "other" => 8,
             "gap" => 0
           }
  end

  test "counts a repeating trip only on its own calendar", context do
    # via has one plain SATURDAY trip; the repeating trip adds 7 departures there
    # and nothing on WEEKDAY.
    frequency_trip(context, "SATURDAY", [
      %{start_time: "10:00:00", end_time: "13:30:00", headway_secs: 1800}
    ])

    assert picker_trips(context, "WEEKDAY") == %{
             "full" => 3,
             "via" => 0,
             "other" => 8,
             "gap" => 0
           }

    assert picker_trips(context, "SATURDAY") == %{
             "full" => 0,
             "via" => 8,
             "other" => 0,
             "gap" => 0
           }
  end

  test "keeps a trip plain when only another organization or version has frequency rows for its ID",
       context do
    trip =
      linked_trip(context.organization, context.version, context.route, context.via, "WEEKDAY")

    frequency_fixture(
      context.foreign_scope.organization_id,
      context.foreign_scope.gtfs_version_id,
      trip.trip_id,
      %{start_time: "10:00:00", end_time: "13:30:00", headway_secs: 1800}
    )

    frequency_fixture(
      context.other_version_scope.organization_id,
      context.other_version_scope.gtfs_version_id,
      trip.trip_id,
      %{start_time: "10:00:00", end_time: "13:30:00", headway_secs: 1800}
    )

    assert picker_trips(context, "WEEKDAY") == %{
             "full" => 3,
             "via" => 1,
             "other" => 8,
             "gap" => 0
           }
  end

  test "lists no patterns outside the version's published routes", context do
    # The staging version and a pattern of another organization are outside this
    # scope; the read of their own scope stays inside itself.
    assert PatternComparison.picker_patterns(context.staging_scope, nil, "WEEKDAY") == {:ok, []}

    assert PatternComparison.picker_patterns(context.foreign_scope, nil, "WEEKDAY")
           |> elem(1)
           |> Enum.map(& &1.route_pattern_id) == ["foreign"]

    assert PatternComparison.picker_patterns(context.other_version_scope, nil, "WEEKDAY")
           |> elem(1)
           |> Enum.map(& &1.route_pattern_id) == ["elsewhere"]

    # A pattern ID from another organization or version is not a side: it shares
    # nothing and its stops never leak into a count.
    assert {:ok, entries} = PatternComparison.picker_patterns(context.scope, "foreign", "WEEKDAY")

    assert Enum.all?(entries, &(&1.shared == 0))

    assert Enum.map(entries, & &1.route_pattern_id) == ["other", "full", "via", "gap"]
  end

  defp located_stop(organization, version, stop_id, name, lat, lon) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: name,
      stop_lat: Decimal.new(lat),
      stop_lon: Decimal.new(lon)
    })
  end

  defp insert_shared(organization, version, from_stop_id, to_stop_id, points) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  defp insert_override(organization, version, occurrence, from_stop_id, to_stop_id, points) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      from_occurrence_id: occurrence.id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  # One named pattern with its own timing; `pattern` carries `:id`, `:name`,
  # `:direction_id`, `:sort_order` and an optional `:description`.
  defp schedule_pattern(organization, version, route, pattern, stops) do
    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: pattern.id,
        route_pattern_name: pattern.name,
        direction_id: pattern.direction_id,
        route_pattern_sort_order: pattern.sort_order,
        timing_name: "#{pattern.name} timing",
        stops: stops
      })

    Repo.update!(
      Ecto.Changeset.change(bundle.pattern, route_pattern_time_desc: pattern[:description])
    )

    bundle
  end

  defp linked_trips(organization, version, route, bundle, service_id, departures) do
    Enum.each(departures, fn departure ->
      trip = linked_trip(organization, version, route, bundle, service_id)

      stop_time_fixture(organization.id, version.id, trip.trip_id, "s1", %{
        arrival_time: departure,
        departure_time: departure,
        stop_sequence: 1
      })
    end)
  end

  defp picker_trips(context, service_id) do
    {:ok, entries} = PatternComparison.picker_patterns(context.scope, nil, service_id)

    Map.new(entries, &{&1.route_pattern_id, &1.trips})
  end

  # A trip of the via pattern with one frequency row per window.
  defp frequency_trip(context, service_id, windows) do
    trip =
      linked_trip(context.organization, context.version, context.route, context.via, service_id)

    Enum.each(windows, fn window ->
      frequency_fixture(context.organization.id, context.version.id, trip.trip_id, window)
    end)

    trip
  end

  defp repeating_trip(organization, version, route, bundle) do
    trip = linked_trip(organization, version, route, bundle, "WEEKDAY")

    frequency_fixture(organization.id, version.id, trip.trip_id, %{
      start_time: "10:00:00",
      end_time: "13:30:00",
      headway_secs: 1800
    })

    trip
  end

  defp linked_trip(organization, version, route, bundle, service_id) do
    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: "trip_#{System.unique_integer([:positive])}",
        service_id: service_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: bundle.pattern.route_pattern_id,
      timed_pattern_id: bundle.timing.id,
      pattern_derivation_state: "linked"
    })
  end
end
