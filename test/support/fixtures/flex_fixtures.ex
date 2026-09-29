defmodule GtfsPlanner.FlexFixtures do
  @moduledoc """
  The representative GTFS-flex fixture and its feed (step 15).

  `flex_representative_fixture/2` seeds one version with the feed the flex
  export extends and the three authored services the prepared cases use:

  - stops around Newport and Toledo, Oregon; an agency; weekday, Saturday and
    office-days calendars with their attributes;
  - Route 1 (fixed) and Route 20 with outbound and inbound patterns, shapes and
    trips, including one same-time pair on the Saturday outbound trip;
  - "Newport Dial-a-Ride", an area service with a Newport and a Toledo area,
    per-zone weekday hours, an overnight Saturday window, connecting stops, a
    Saturday-scoped booking rule and one business-day rule;
  - "Valley Line detours", a `tell_driver` detour service on Route 20 with a
    09:00–15:00 band and one business-day rule;
  - "Newport Access", an included registered-riders service.

  `flex_feed_fixture/2` seeds only the feed and `flex_services_fixture/2`
  creates only the services, so a caller can measure the version with and
  without flex authoring (AC-26). The returned map carries the created structs
  (`:stops`, `:calendars`, `:route_1`, `:route_20`, `:trips`, `:patterns` and
  `:services`) plus `:same_time_stop_time`, the row `fix_same_time_pair/1`
  changes.
  """

  import GtfsPlanner.GtfsFixtures
  import Ecto.Query, only: [from: 2]

  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  @calendar_span {~D[2026-01-01], ~D[2026-12-31]}
  @newport_area %{
    "type" => "Polygon",
    "coordinates" => [
      [
        [-124.075, 44.595],
        [-124.045, 44.595],
        [-124.045, 44.625],
        [-124.075, 44.625],
        [-124.075, 44.595]
      ]
    ]
  }
  @toledo_area %{
    "type" => "Polygon",
    "coordinates" => [
      [
        [-123.97, 44.60],
        [-123.90, 44.60],
        [-123.90, 44.65],
        [-123.97, 44.65],
        [-123.97, 44.60]
      ]
    ]
  }
  @access_area %{
    "type" => "Polygon",
    "coordinates" => [
      [
        [-124.04, 44.585],
        [-124.005, 44.585],
        [-124.005, 44.60],
        [-124.04, 44.60],
        [-124.04, 44.585]
      ]
    ]
  }

  @doc """
  Seeds the representative feed and its three flex services in one call.
  """
  def flex_representative_fixture(organization, version) do
    organization
    |> flex_feed_fixture(version)
    |> Map.put(:services, flex_services_fixture(organization, version))
  end

  @doc """
  Seeds the representative feed: agency, stops, calendars, Route 1 and Route 20
  with patterns, shapes, trips and stop times. No flex service is created.
  """
  def flex_feed_fixture(organization, version) do
    agency =
      agency_fixture(organization.id, version.id, %{
        agency_id: "NPT",
        agency_name: "Newport Transit",
        agency_url: "https://example.org",
        agency_timezone: "America/Los_Angeles"
      })

    stops = stops(organization, version)
    calendars = calendars(organization, version)

    route_1 =
      route_fixture(organization.id, version.id, %{
        route_id: "1",
        agency_id: "NPT",
        route_short_name: "1",
        route_long_name: "Bayfront",
        route_type: 3
      })

    route_20 =
      route_fixture(organization.id, version.id, %{
        route_id: "20",
        agency_id: "NPT",
        route_short_name: "20",
        route_long_name: "Valley Line",
        route_type: 3
      })

    trips = %{
      "1-weekday" => route_1_trip(organization, version, "1-weekday", "weekday", "06:00:00"),
      "1-saturday" => route_1_trip(organization, version, "1-saturday", "saturday", "09:00:00"),
      "20-out-am" =>
        route_20_trip(organization, version, "20-out-am", "weekday", 0, "shape-20-out", [
          {"NP1", 1, "07:00:00", "07:00:00"},
          {"NP2", 2, "07:20:58", "07:21:14"},
          {"TLD1", 3, "07:29:40", "07:29:52"},
          {"TLD2", 4, "07:45:00", "07:45:00"}
        ]),
      "20-in-am" =>
        route_20_trip(organization, version, "20-in-am", "weekday", 1, "shape-20-in", [
          {"TLD2", 1, "11:00:00", "11:00:00"},
          {"TLD1", 2, "11:20:00", "11:20:10"},
          {"NP2", 3, "11:29:40", "11:29:52"},
          {"NP1", 4, "11:45:00", "11:45:00"}
        ]),
      "20-out-sat" =>
        route_20_trip(organization, version, "20-out-sat", "saturday", 0, "shape-20-out", [
          {"NP1", 1, "12:30:00", "12:30:00"},
          {"NP2", 2, "12:50:00", "12:50:00"},
          {"TLD1", 3, "12:50:00", "12:51:00"},
          {"TLD2", 4, "13:05:00", "13:05:00"}
        ])
    }

    patterns = route_20_patterns(organization, version)

    %{
      agency: agency,
      stops: stops,
      calendars: calendars,
      route_1: route_1,
      route_20: route_20,
      trips: trips,
      patterns: patterns,
      same_time_stop_time: same_time_stop_time(organization.id, version.id)
    }
  end

  @doc """
  Creates the three flex services of the representative fixture on a version
  that already holds `flex_feed_fixture/2`'s feed:

  - `:area` — Newport Dial-a-Ride;
  - `:detour` — Valley Line detours;
  - `:registered` — Newport Access (registered riders, included).
  """
  def flex_services_fixture(organization, version) do
    %{
      area: area_service(organization, version),
      detour: detour_service(organization, version),
      registered: registered_service(organization, version)
    }
  end

  @doc """
  Fixes the fixture's one same-time pair: the Saturday outbound trip's Toledo
  Library row moves from 12:50:00 to 12:55:00.

  The pair is the trip's NP2 departure and TLD1 arrival; the fix gives their
  detour pair a real window without changing any other time or sequence.
  """
  def fix_same_time_pair(feed) do
    feed.same_time_stop_time
    |> Ecto.Changeset.change(arrival_time: "12:55:00", departure_time: "12:55:00")
    |> Repo.update!()
  end

  # --- feed -------------------------------------------------------------------

  defp stops(organization, version) do
    [
      {"NP1", "Newport Transit Center", "-124.05", "44.605"},
      {"NP2", "Newport City Hall", "-124.06", "44.61"},
      {"TLD1", "Toledo Library", "-123.93", "44.62"},
      {"TLD2", "Toledo City Hall", "-123.94", "44.615"},
      {"OTR", "Otter Rock", "-124.07", "44.60"},
      {"DPB", "Depoe Bay", "-124.06", "44.59"},
      {"R1A", "Bayfront North", "-124.04", "44.60"},
      {"R1B", "Bayfront South", "-124.03", "44.61"}
    ]
    |> Map.new(fn {stop_id, name, lon, lat} ->
      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: stop_id,
          stop_name: name,
          stop_lon: Decimal.new(lon),
          stop_lat: Decimal.new(lat)
        })

      {stop_id, stop}
    end)
  end

  defp calendars(organization, version) do
    {start_date, end_date} = @calendar_span
    calendar_attributes(organization, version)

    weekdays = %{
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    }

    %{
      "weekday" =>
        calendar_fixture(
          organization.id,
          version.id,
          Map.merge(weekdays, %{
            service_id: "weekday",
            start_date: start_date,
            end_date: end_date
          })
        ),
      "saturday" =>
        calendar_fixture(organization.id, version.id, %{
          service_id: "saturday",
          monday: 0,
          tuesday: 0,
          wednesday: 0,
          thursday: 0,
          friday: 0,
          saturday: 1,
          sunday: 0,
          start_date: start_date,
          end_date: end_date
        }),
      "office" =>
        calendar_fixture(
          organization.id,
          version.id,
          Map.merge(weekdays, %{
            service_id: "office",
            start_date: start_date,
            end_date: end_date
          })
        )
    }
  end

  defp calendar_attributes(organization, version) do
    [
      {"weekday", "Weekday", "Weekdays"},
      {"saturday", "Saturday", "Saturdays"},
      {"office", "Office day", "Office days"}
    ]
    |> Enum.map(fn {service_id, name, description} ->
      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_schedule_name: name,
        service_description: description,
        service_schedule_type: nil,
        rating_start_date: nil,
        rating_end_date: nil,
        rating_description: nil
      })
    end)
  end

  defp route_1_trip(organization, version, trip_id, service_id, start_time) do
    trip =
      trip_fixture(organization.id, version.id, "1", %{
        trip_id: trip_id,
        service_id: service_id,
        block_id: "B1",
        direction_id: 0
      })

    finish_time = plus_minutes(start_time, 15)

    stop_time(organization, version, trip_id, "R1A", 1, start_time, start_time)
    stop_time(organization, version, trip_id, "R1B", 2, finish_time, finish_time)

    trip
  end

  defp plus_minutes(time, minutes) do
    [hours, mins, seconds] = time |> String.split(":") |> Enum.map(&String.to_integer/1)
    total = hours * 3600 + mins * 60 + seconds + minutes * 60

    [div(total, 3600), div(rem(total, 3600), 60), rem(total, 60)]
    |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end

  defp route_20_trip(organization, version, trip_id, service_id, direction_id, shape_id, rows) do
    trip =
      trip_fixture(organization.id, version.id, "20", %{
        trip_id: trip_id,
        service_id: service_id,
        direction_id: direction_id,
        block_id: "B20",
        shape_id: shape_id
      })

    Enum.each(rows, fn {stop_id, sequence, arrival, departure} ->
      stop_time(organization, version, trip_id, stop_id, sequence, arrival, departure)
    end)

    trip
  end

  defp stop_time(organization, version, trip_id, stop_id, sequence, arrival, departure) do
    stop_time_fixture(organization.id, version.id, trip_id, stop_id, %{
      stop_sequence: sequence,
      arrival_time: arrival,
      departure_time: departure
    })
  end

  defp same_time_stop_time(organization_id, version_id) do
    Repo.one(
      from(st in StopTime,
        where:
          st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id and
            st.trip_id == "20-out-sat" and st.stop_id == "TLD1"
      )
    )
  end

  # --- Route 20 patterns and shapes -------------------------------------------

  defp route_20_patterns(organization, version) do
    insert_shape(organization, version, "shape-20-out", [
      {"-124.05", "44.605", 1, 0},
      {"-124.06", "44.61", 2, 1500},
      {"-123.93", "44.62", 3, 12_000},
      {"-123.94", "44.615", 4, 13_000}
    ])

    insert_shape(organization, version, "shape-20-in", [
      {"-123.94", "44.615", 1, 0},
      {"-123.93", "44.62", 2, 1000},
      {"-124.06", "44.61", 3, 11_500},
      {"-124.05", "44.605", 4, 13_000}
    ])

    %{
      "20-out" =>
        insert_pattern(organization, version, "20-out", "shape-20-out", 0, [
          {"NP1", 1, 0},
          {"NP2", 2, 1500},
          {"TLD1", 3, 12_000},
          {"TLD2", 4, 13_000}
        ]),
      "20-in" =>
        insert_pattern(organization, version, "20-in", "shape-20-in", 1, [
          {"TLD2", 1, 0},
          {"TLD1", 2, 1000},
          {"NP2", 3, 11_500},
          {"NP1", 4, 13_000}
        ])
    }
  end

  defp insert_shape(organization, version, shape_id, points) do
    now = DateTime.utc_now()

    rows =
      Enum.map(points, fn {lon, lat, sequence, distance} ->
        %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          shape_id: shape_id,
          shape_pt_lon: Decimal.new(lon),
          shape_pt_lat: Decimal.new(lat),
          shape_pt_sequence: sequence,
          shape_dist_traveled: distance && Decimal.new(distance),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Shape, rows)
  end

  # `route_pattern_fixture/3` cannot cast `shape_id` and
  # `route_pattern_stop_fixture/4` cannot cast `shape_dist_traveled`: the
  # alignment materializer owns both columns, so the fixture writes them the way
  # `GtfsPlanner.Gtfs.Flex.Geometry`'s detour derivation reads them.
  defp insert_pattern(organization, version, pattern_id, shape_id, direction_id, stops) do
    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: pattern_id,
        route_id: "20",
        direction_id: direction_id
      })

    {1, _} =
      Repo.update_all(
        from(p in RoutePattern, where: p.id == ^pattern.id),
        set: [shape_id: shape_id]
      )

    Enum.each(stops, fn {stop_id, position, distance} ->
      occurrence = route_pattern_stop_fixture(pattern, stop_id, position)

      {1, _} =
        Repo.update_all(
          from(o in RoutePatternStop, where: o.id == ^occurrence.id),
          set: [shape_dist_traveled: Decimal.new(distance)]
        )
    end)

    pattern
  end

  # --- flex services ----------------------------------------------------------

  defp area_service(organization, version) do
    {:ok, service} =
      Flex.create_service(organization.id, version.id, %{
        name: "Newport Dial-a-Ride",
        kind: :area
      })

    {:ok, service} =
      Flex.save_service(
        organization.id,
        version.id,
        service,
        %{
          phone: "(541) 555-0142",
          booking_url: "https://example.org/book",
          hub_stop_ids: ["OTR", "DPB"],
          hours: [
            %{area_key: "a1", service_id: "weekday", start: "07:00", end: "18:00"},
            %{area_key: "a2", service_id: "weekday", start: "09:00", end: "15:00"},
            %{area_key: "a1", service_id: "saturday", start: "18:00", end: "01:00"},
            %{area_key: "a2", service_id: "saturday", start: "09:00", end: "15:00"}
          ],
          booking_rules: [
            %{
              when: :earlier_day,
              days: 1,
              by: "16:00",
              business_days: true,
              office_service_id: "office"
            },
            %{service_id: "saturday", when: :earlier_day, days: 2, by: "12:00"}
          ]
        },
        [
          %{key: "a1", name: "Newport", source: :drawn, geojson: @newport_area},
          %{key: "a2", name: "Toledo", source: :drawn, geojson: @toledo_area}
        ]
      )

    service
  end

  defp detour_service(organization, version) do
    {:ok, service} =
      Flex.create_service(organization.id, version.id, %{
        name: "Valley Line detours",
        kind: :detour,
        route_id: "20"
      })

    {:ok, service} =
      Flex.save_service(
        organization.id,
        version.id,
        service,
        %{
          phone: "(541) 555-0142",
          distance_m: 400,
          measure: :route,
          wording: "For example, up to ¼ mile from the route",
          dropoffs: :tell_driver,
          band_start: "09:00",
          band_end: "15:00",
          calendar_service_ids: ["weekday", "saturday"],
          first_stop_id: "NP1",
          last_stop_id: "TLD2",
          booking_rules: [
            %{
              when: :earlier_day,
              days: 1,
              by: "16:00",
              business_days: true,
              office_service_id: "office"
            }
          ]
        },
        []
      )

    service
  end

  defp registered_service(organization, version) do
    {:ok, service} =
      Flex.create_service(organization.id, version.id, %{
        name: "Newport Access",
        kind: :area
      })

    {:ok, service} =
      Flex.save_service(
        organization.id,
        version.id,
        service,
        %{
          riders: :registered,
          include_registered: true,
          eligibility: "Adults 60 and older",
          info_url: "https://example.org/access",
          phone: "(541) 555-0143",
          hours: [%{area_key: "a1", service_id: "weekday", start: "08:00", end: "17:00"}],
          booking_rules: [%{when: :same_day, minutes: 120}]
        },
        [%{key: "a1", name: "Newport Access Area", source: :drawn, geojson: @access_area}]
      )

    service
  end
end
