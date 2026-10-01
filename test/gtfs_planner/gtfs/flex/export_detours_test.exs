defmodule GtfsPlanner.Gtfs.Flex.ExportDetoursTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.FlexFixtures, only: [flex_audit_fixture: 2]
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.Export
  alias GtfsPlanner.Gtfs.Flex.Export.Detours
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.StopTime

  @zone_geojson %{
    "type" => "MultiPolygon",
    "coordinates" => [
      [[[-124.05, 44.6], [-124.04, 44.6], [-124.04, 44.61], [-124.05, 44.61], [-124.05, 44.6]]]
    ]
  }
  @drop_off_message "To get off away from the route, tell the driver when you board."
  @rule_id "flex-valley-line-detours-book"

  describe "rows/4" do
    test "writes the zone row between the stretch's stops with the stored window and an odd sequence" do
      service = detour_service(%{last_stop_id: "B"})

      trips = [
        trip("20-0712", [
          stop("A", 2, %{arrival_time: "07:20:58", departure_time: "07:21:14"}),
          stop("B", 3, %{arrival_time: "07:29:40", departure_time: "07:29:52"})
        ])
      ]

      assert {%{stop_times: [row], locations: [location]}, []} =
               Detours.rows(service, zones([{"A", "B"}]), trips, @rule_id)

      assert row == %{
               trip_id: "20-0712",
               arrival_time: nil,
               departure_time: nil,
               stop_id: nil,
               location_group_id: nil,
               location_id: "flex-valley-line-detours-A-B",
               stop_sequence: 5,
               start_pickup_drop_off_window: "07:21:14",
               end_pickup_drop_off_window: "07:29:40",
               pickup_type: 2,
               drop_off_type: 3,
               pickup_booking_rule_id: @rule_id,
               drop_off_booking_rule_id: nil,
               drop_off_message: @drop_off_message
             }

      assert location == %{
               id: "flex-valley-line-detours-A-B",
               stop_name: "Route 20 detour area",
               geometry: @zone_geojson
             }
    end

    test "writes one row per consecutive pair of the stretch and none outside it" do
      service = detour_service()

      trips = [
        trip("20-0712", [
          stop("Z", 1, %{arrival_time: "07:20:00", departure_time: "07:20:10"}),
          stop("A", 2, %{arrival_time: "07:20:58", departure_time: "07:21:14"}),
          stop("B", 3, %{arrival_time: "07:22:00", departure_time: "07:22:10"}),
          stop("C", 4, %{arrival_time: "07:29:40", departure_time: "07:29:52"}),
          stop("D", 5, %{arrival_time: "07:31:00", departure_time: "07:31:10"})
        ])
      ]

      assert {%{stop_times: rows, locations: _locations}, []} =
               Detours.rows(service, zones([{"A", "B"}, {"B", "C"}]), trips, @rule_id)

      assert Enum.map(rows, &{&1.stop_sequence, &1.location_id}) == [
               {5, "flex-valley-line-detours-A-B"},
               {7, "flex-valley-line-detours-B-C"}
             ]

      assert Enum.map(rows, &{&1.start_pickup_drop_off_window, &1.end_pickup_drop_off_window}) ==
               [
                 {"07:21:14", "07:22:00"},
                 {"07:22:10", "07:29:40"}
               ]
    end

    test "runs an inbound trip in visit order with the same unordered-pair zones" do
      service = detour_service()

      trips = [
        trip("20-0812", [
          stop("C", 2, %{arrival_time: "07:20:58", departure_time: "07:21:14"}),
          stop("B", 3, %{arrival_time: "07:25:00", departure_time: "07:25:10"}),
          stop("A", 5, %{arrival_time: "07:29:40", departure_time: "07:29:52"})
        ])
      ]

      assert {%{stop_times: rows, locations: _locations}, []} =
               Detours.rows(service, zones([{"A", "B"}, {"B", "C"}]), trips, @rule_id)

      assert Enum.map(rows, &{&1.stop_sequence, &1.location_id}) == [
               {5, "flex-valley-line-detours-B-C"},
               {7, "flex-valley-line-detours-A-B"}
             ]

      assert Enum.map(rows, &{&1.start_pickup_drop_off_window, &1.end_pickup_drop_off_window}) ==
               [
                 {"07:21:14", "07:25:00"},
                 {"07:25:10", "07:29:40"}
               ]
    end

    test "covers the part of the stretch a trip that visits one named stop runs" do
      service = detour_service()

      trips = [
        trip("20-0712", [
          stop("A", 2, %{arrival_time: "07:20:58", departure_time: "07:21:14"}),
          stop("B", 3, %{arrival_time: "07:22:00", departure_time: "07:22:10"}),
          stop("D", 4, %{arrival_time: "07:29:40", departure_time: "07:29:52"})
        ])
      ]

      assert {%{stop_times: rows, locations: _locations}, []} =
               Detours.rows(service, zones([{"A", "B"}, {"B", "D"}]), trips, @rule_id)

      assert Enum.map(rows, & &1.location_id) == [
               "flex-valley-line-detours-A-B",
               "flex-valley-line-detours-B-D"
             ]
    end

    test "skips a same-time pair in every trip, with one warning naming the pair and the trip count" do
      service = detour_service()

      trips = [
        trip("20-0712", [
          stop("A", 1, %{arrival_time: "12:49:00", departure_time: "12:50:00"}),
          stop("B", 2, %{arrival_time: "12:50:00", departure_time: "12:50:30"}),
          stop("C", 3, %{arrival_time: "12:56:00", departure_time: "12:56:10"})
        ]),
        trip("20-0812", [
          stop("A", 1, %{arrival_time: "13:49:00", departure_time: "13:50:00"}),
          stop("B", 2, %{arrival_time: "13:50:00", departure_time: "13:50:30"}),
          stop("C", 3, %{arrival_time: "13:56:00", departure_time: "13:56:10"})
        ])
      ]

      assert {%{stop_times: rows, locations: _locations}, warnings} =
               Detours.rows(service, zones([{"A", "B"}, {"B", "C"}]), trips, @rule_id)

      # The equal-time pair never merges into the next one: each trip still has
      # its own B-C row.
      assert Enum.map(rows, &{&1.trip_id, &1.stop_sequence, &1.location_id}) == [
               {"20-0712", 5, "flex-valley-line-detours-B-C"},
               {"20-0812", 5, "flex-valley-line-detours-B-C"}
             ]

      assert warnings == [
               %{
                 code: "flex_detour_same_time",
                 detail:
                   "Valley Line detours: no detour row for 2 trips between stops A and B: " <>
                     "the departure and arrival times are equal.",
                 file: "stop_times.txt",
                 entity_type: "stop_time"
               }
             ]
    end

    test "skips a pair missing its departure or arrival and warns once per pair" do
      service = detour_service()

      trips = [
        trip("20-0712", [
          stop("A", 1, %{arrival_time: "07:20:58", departure_time: nil}),
          stop("B", 2, %{arrival_time: "07:22:00", departure_time: "07:22:10"}),
          stop("C", 3, %{arrival_time: "07:29:40", departure_time: "07:29:52"})
        ]),
        trip("20-0812", [
          stop("A", 1, %{arrival_time: "08:20:58", departure_time: "08:21:14"}),
          stop("B", 2, %{arrival_time: "08:22:00", departure_time: "08:22:10"}),
          stop("C", 3, %{arrival_time: nil, departure_time: "08:29:52"})
        ])
      ]

      assert {%{stop_times: rows, locations: _locations}, warnings} =
               Detours.rows(service, zones([{"A", "B"}, {"B", "C"}]), trips, @rule_id)

      assert Enum.map(rows, &{&1.trip_id, &1.stop_sequence, &1.location_id}) == [
               {"20-0712", 5, "flex-valley-line-detours-B-C"},
               {"20-0812", 3, "flex-valley-line-detours-A-B"}
             ]

      assert Enum.map(warnings, &{&1.code, &1.detail}) == [
               {"flex_detour_missing_time",
                "Valley Line detours: no detour row for 1 trip between stops A and B: " <>
                  "a departure or arrival time is missing."},
               {"flex_detour_missing_time",
                "Valley Line detours: no detour row for 1 trip between stops B and C: " <>
                  "a departure or arrival time is missing."}
             ]
    end

    test "leaves a frequency trip without rows, warning once per trip" do
      service = detour_service(%{last_stop_id: "B"})

      trips = [
        %{
          trip_id: "20-0712",
          service_id: "weekday",
          frequency?: true,
          stops: [
            stop("A", 1, %{arrival_time: "07:20:58", departure_time: "07:21:14"}),
            stop("B", 2, %{arrival_time: "07:29:40", departure_time: "07:29:52"})
          ]
        },
        trip("20-0730", [
          stop("A", 1, %{arrival_time: "07:30:58", departure_time: "07:31:14"}),
          stop("B", 2, %{arrival_time: "07:39:40", departure_time: "07:39:52"})
        ])
      ]

      assert {%{stop_times: [row], locations: _locations}, warnings} =
               Detours.rows(service, zones([{"A", "B"}]), trips, @rule_id)

      assert row.trip_id == "20-0730"

      assert warnings == [
               %{
                 code: "flex_detour_frequency_trip",
                 detail:
                   "Valley Line detours: trip 20-0712 runs on a frequency and gets no " <>
                     "detour rows.",
                 file: "stop_times.txt",
                 entity_type: "stop_time"
               }
             ]
    end

    test "keeps only trips whose departure at the first stretch stop is in the band" do
      service = detour_service(%{last_stop_id: "B", band_start: "09:00", band_end: "15:00"})

      trips = [
        banded_trip("20-0712", "08:59:59"),
        banded_trip("20-0730", "09:00:00"),
        banded_trip("20-1400", "14:59:59"),
        banded_trip("20-1500", "15:00:00")
      ]

      assert {%{stop_times: rows, locations: _locations}, []} =
               Detours.rows(service, zones([{"A", "B"}]), trips, @rule_id)

      assert Enum.map(rows, & &1.trip_id) == ["20-0730", "20-1400"]
    end

    test "reads the band from the first stretch stop, not the trip's first stop" do
      service = detour_service(%{band_start: "09:00", band_end: "15:00"})

      trips = [
        trip("20-0712", [
          stop("Z", 1, %{arrival_time: "08:58:50", departure_time: "08:59:00"}),
          stop("A", 2, %{arrival_time: "09:29:50", departure_time: "09:30:00"}),
          stop("B", 3, %{arrival_time: "10:00:00", departure_time: "10:00:10"}),
          stop("C", 4, %{arrival_time: "10:30:00", departure_time: "10:30:10"}),
          stop("D", 5, %{arrival_time: "15:10:00", departure_time: "15:10:10"})
        ])
      ]

      assert {%{stop_times: rows, locations: _locations}, []} =
               Detours.rows(service, zones([{"A", "B"}, {"B", "C"}]), trips, @rule_id)

      assert Enum.map(rows, & &1.location_id) == [
               "flex-valley-line-detours-A-B",
               "flex-valley-line-detours-B-C"
             ]
    end

    test "reads the band from the first stretch stop the trip reaches in visit order" do
      service = detour_service(%{band_start: "09:00", band_end: "15:00"})

      trips = [
        trip("20-0712", [
          stop("C", 2, %{arrival_time: "08:59:50", departure_time: "08:59:59"}),
          stop("B", 3, %{arrival_time: "09:10:00", departure_time: "09:10:10"}),
          stop("A", 4, %{arrival_time: "09:20:00", departure_time: "09:20:10"})
        ]),
        trip("20-0812", [
          stop("C", 2, %{arrival_time: "09:00:00", departure_time: "09:00:00"}),
          stop("B", 3, %{arrival_time: "09:10:00", departure_time: "09:10:10"}),
          stop("A", 4, %{arrival_time: "09:20:00", departure_time: "09:20:10"})
        ])
      ]

      assert {%{stop_times: rows, locations: _locations}, []} =
               Detours.rows(service, zones([{"A", "B"}, {"B", "C"}]), trips, @rule_id)

      assert Enum.map(rows, & &1.trip_id) == ["20-0812", "20-0812"]
    end

    test "leaves out a banded trip whose first stretch departure is unreadable and reports it" do
      service = detour_service(%{last_stop_id: "B", band_start: "09:00", band_end: "15:00"})

      trips = [
        trip("20-0712", [
          stop("A", 1, %{arrival_time: "08:59:00", departure_time: nil}),
          stop("B", 2, %{arrival_time: "09:10:00", departure_time: "09:10:10"})
        ])
      ]

      assert {%{stop_times: [], locations: _locations}, warnings} =
               Detours.rows(service, zones([{"A", "B"}]), trips, @rule_id)

      assert [%{code: "flex_detour_missing_time"}] = warnings
    end

    test "skips a covered pair with no derived zone and warns" do
      service = detour_service(%{last_stop_id: "B"})

      trips = [
        trip("20-0712", [
          stop("A", 1, %{arrival_time: "07:20:58", departure_time: "07:21:14"}),
          stop("B", 2, %{arrival_time: "07:29:40", departure_time: "07:29:52"})
        ])
      ]

      assert {%{stop_times: [], locations: [location]}, warnings} =
               Detours.rows(service, zones([{"X", "Y"}]), trips, @rule_id)

      assert location.id == "flex-valley-line-detours-X-Y"

      assert warnings == [
               %{
                 code: "flex_detour_no_zone",
                 detail: "Valley Line detours: no detour area covers stops A and B for 1 trip.",
                 file: "stop_times.txt",
                 entity_type: "stop_time"
               }
             ]
    end

    test "takes a tell-driver detour with the pickup rule and the drop-off message" do
      row = only_row(detour_service(%{last_stop_id: "B", dropoffs: :tell_driver}))

      assert row.pickup_type == 2
      assert row.drop_off_type == 3
      assert row.pickup_booking_rule_id == @rule_id
      assert row.drop_off_booking_rule_id == nil
      assert row.drop_off_message == @drop_off_message
    end

    test "books both sides of a book detour with the one rule and no drop-off message" do
      row = only_row(detour_service(%{last_stop_id: "B", dropoffs: :book}))

      assert row.pickup_type == 2
      assert row.drop_off_type == 2
      assert row.pickup_booking_rule_id == @rule_id
      assert row.drop_off_booking_rule_id == @rule_id
      assert row.drop_off_message == nil
    end

    test "takes a dropoff-only detour with no rule references and the drop-off message" do
      row = only_row(detour_service(%{last_stop_id: "B", dropoffs: :dropoff_only}))

      assert row.pickup_type == 1
      assert row.drop_off_type == 3
      assert row.pickup_booking_rule_id == nil
      assert row.drop_off_booking_rule_id == nil
      assert row.drop_off_message == @drop_off_message
    end

    test "generates no rows for a trip outside the service's calendars" do
      service = detour_service(%{last_stop_id: "B", calendar_service_ids: ["weekday"]})

      trips = [
        %{
          trip("20-0712", [
            stop("A", 1, %{arrival_time: "07:20:58", departure_time: "07:21:14"}),
            stop("B", 2, %{arrival_time: "07:29:40", departure_time: "07:29:52"})
          ])
          | service_id: "saturday"
        }
      ]

      assert {%{stop_times: [], locations: _locations}, []} =
               Detours.rows(service, zones([{"A", "B"}]), trips, @rule_id)
    end
  end

  describe "sequence_mapper/2" do
    test "doubles the sequence of every trip on an active detour service's route" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, version.id, %{route_id: "20"})
      trip_fixture(organization.id, version.id, "20", %{trip_id: "20-0712"})
      trip_fixture(organization.id, version.id, "20", %{trip_id: "20-0812"})

      {:ok, service} =
        Flex.create_service(flex_audit_fixture(organization.id, version.id), %{
          name: "Valley Line detours",
          kind: :detour,
          route_id: "20"
        })

      # R3 doubles this route whether or not the service is ready: it has no
      # distance, wording or chosen trips yet and derives no zones.
      assert Enum.any?(checks(service, version), &(&1.level == :error))

      mapper = Export.sequence_mapper(organization.id, version.id)

      assert mapper.(%StopTime{trip_id: "20-0712", stop_sequence: 3}) ==
               %StopTime{trip_id: "20-0712", stop_sequence: 6}

      assert mapper.(%{trip_id: "20-0812", stop_sequence: 4}) ==
               %{trip_id: "20-0812", stop_sequence: 8}
    end

    test "leaves trips on other routes, inactive services and other versions unchanged" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, version.id, %{route_id: "20"})
      route_fixture(organization.id, version.id, %{route_id: "1"})
      route_fixture(organization.id, other_version.id, %{route_id: "20"})

      trip_fixture(organization.id, version.id, "20", %{trip_id: "20-0712"})
      trip_fixture(organization.id, version.id, "1", %{trip_id: "1-0700"})
      trip_fixture(organization.id, other_version.id, "20", %{trip_id: "20-9999"})

      {:ok, _route_20} =
        Flex.create_service(flex_audit_fixture(organization.id, version.id), %{
          name: "Valley Line detours",
          kind: :detour,
          route_id: "20"
        })

      {:ok, route_1} =
        Flex.create_service(flex_audit_fixture(organization.id, version.id), %{
          name: "Route 1 detours",
          kind: :detour,
          route_id: "1"
        })

      {:ok, _inactive} = Flex.set_active(flex_audit_fixture(organization.id, version.id), route_1.id, false)

      mapper = Export.sequence_mapper(organization.id, version.id)

      assert mapper.(%StopTime{trip_id: "20-0712", stop_sequence: 3}) ==
               %StopTime{trip_id: "20-0712", stop_sequence: 6}

      assert mapper.(%StopTime{trip_id: "1-0700", stop_sequence: 4}) ==
               %StopTime{trip_id: "1-0700", stop_sequence: 4}

      assert mapper.(%StopTime{trip_id: "20-9999", stop_sequence: 5}) ==
               %StopTime{trip_id: "20-9999", stop_sequence: 5}
    end

    test "is the identity when the version has no active detour services" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, version.id, %{route_id: "20"})
      trip_fixture(organization.id, version.id, "20", %{trip_id: "20-0712"})

      {:ok, _area} =
        Flex.create_service(flex_audit_fixture(organization.id, version.id), %{
          name: "Newport Dial-a-Ride",
          kind: :area
        })

      mapper = Export.sequence_mapper(organization.id, version.id)
      stop_time = %StopTime{trip_id: "20-0712", stop_sequence: 3}

      assert mapper.(stop_time) == stop_time

      assert mapper.(%{trip_id: "20-0712", stop_sequence: 3}) ==
               %{trip_id: "20-0712", stop_sequence: 3}
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp only_row(service) do
    trips = [
      trip("20-0712", [
        stop("A", 1, %{arrival_time: "07:20:58", departure_time: "07:21:14"}),
        stop("B", 2, %{arrival_time: "07:29:40", departure_time: "07:29:52"})
      ])
    ]

    assert {%{stop_times: [row]}, []} =
             Detours.rows(service, zones([{"A", "B"}]), trips, @rule_id)

    row
  end

  defp detour_service(attrs \\ %{}) do
    struct!(
      %FlexService{
        kind: :detour,
        key: "valley-line-detours",
        name: "Valley Line detours",
        route_id: "20",
        first_stop_id: "A",
        last_stop_id: "C",
        distance_m: 1_200,
        wording: "up to ¾ mile from the route",
        dropoffs: :tell_driver,
        calendar_service_ids: ["weekday"]
      },
      attrs
    )
  end

  defp trip(trip_id, stops) do
    %{trip_id: trip_id, service_id: "weekday", frequency?: false, stops: stops}
  end

  defp banded_trip(trip_id, departure) do
    trip(trip_id, [
      stop("A", 2, %{arrival_time: departure, departure_time: departure}),
      stop("B", 3, %{arrival_time: "15:20:00", departure_time: "15:20:10"})
    ])
  end

  defp stop(stop_id, stop_sequence, times) do
    Map.merge(%{stop_id: stop_id, stop_sequence: stop_sequence}, times)
  end

  defp zones(pairs) do
    Enum.map(pairs, fn {stop_a, stop_b} ->
      %{
        zone_id: "flex-valley-line-detours-#{stop_a}-#{stop_b}",
        stop_a: stop_a,
        stop_b: stop_b,
        geojson: @zone_geojson
      }
    end)
  end

  defp checks(service, version) do
    facts = Checks.version_facts(version.organization_id, version.id)
    Checks.run(Repo.preload(service, :areas, force: true), facts, [])
  end
end
