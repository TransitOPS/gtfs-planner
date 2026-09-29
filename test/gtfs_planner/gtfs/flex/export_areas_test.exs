defmodule GtfsPlanner.Gtfs.Flex.ExportAreasTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Flex.Export.Areas
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexHours
  alias GtfsPlanner.Gtfs.FlexService

  # Every expected trip, row, window and rule field in this file is hand-derived
  # from R11 and R12 (spec §4), the R12 worked example and the GTFS
  # booking_rules.txt reference; none is read back from `Areas.rows/4`.

  @agency "NCT"

  describe "rows/4" do
    test "writes the worked example's three trips, rows and windows" do
      service =
        service(
          hours: [
            hours("a1", "weekday", "07:00", "18:00"),
            hours("a2", "weekday", "09:00", "15:00")
          ],
          booking_rules: [rule(when: :same_day, minutes: 60)]
        )

      rows = rows(service, [newport(), toledo()])

      assert rows.trips == [
               trip("flex-ncdar-weekday-0700", "weekday"),
               trip("flex-ncdar-weekday-0900", "weekday"),
               trip("flex-ncdar-weekday-1500", "weekday")
             ]

      assert stop_times(rows) == [
               {"flex-ncdar-weekday-0700", 1, "flex-ncdar-a1", nil, "07:00:00", "09:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-0700", 2, "flex-ncdar-a1", nil, "07:00:00", "09:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-0900", 1, "flex-ncdar-a1", nil, "09:00:00", "15:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-0900", 2, "flex-ncdar-a2", nil, "09:00:00", "15:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-0900", 3, "flex-ncdar-a1", nil, "09:00:00", "15:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-0900", 4, "flex-ncdar-a2", nil, "09:00:00", "15:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-1500", 1, "flex-ncdar-a1", nil, "15:00:00", "18:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-1500", 2, "flex-ncdar-a1", nil, "15:00:00", "18:00:00", 1, 2,
                nil, "flex-ncdar-book"}
             ]

      assert rows.routes == [
               %{
                 route_id: "flex-ncdar",
                 agency_id: @agency,
                 route_long_name: "North County Dial-a-Ride",
                 route_type: 3
               }
             ]

      assert rows.locations == [
               %{id: "flex-ncdar-a1", stop_name: "Newport", geometry: polygon(1)},
               %{id: "flex-ncdar-a2", stop_name: "Toledo", geometry: polygon(2)}
             ]

      assert rows.location_groups == []
      assert rows.location_group_stops == []
      refute Enum.any?(rows.trips, &String.ends_with?(&1.trip_id, "-from-stops"))
    end

    test "writes a windowed row with no fixed stop, time or unused booking side" do
      service =
        service(
          hours: [hours("a1", "weekday", "07:00", "18:00")],
          booking_rules: [rule(when: :same_day, minutes: 60)]
        )

      assert [row | _rest] = rows(service, [newport()]).stop_times

      assert row == %{
               trip_id: "flex-ncdar-weekday-0700",
               arrival_time: nil,
               departure_time: nil,
               stop_id: nil,
               location_group_id: nil,
               location_id: "flex-ncdar-a1",
               stop_sequence: 1,
               start_pickup_drop_off_window: "07:00:00",
               end_pickup_drop_off_window: "18:00:00",
               pickup_type: 2,
               drop_off_type: 1,
               pickup_booking_rule_id: "flex-ncdar-book",
               drop_off_booking_rule_id: nil
             }
    end

    test "adds the connecting-stops group to trip A's drop-offs and as trip B's pickup" do
      service =
        service(
          hours: [hours("a1", "weekday", "07:00", "09:00")],
          booking_rules: [rule(when: :same_day, minutes: 60)],
          hub_stop_ids: ["S1", "S2"]
        )

      rows = rows(service, [newport(), toledo()])

      assert rows.trips == [
               trip("flex-ncdar-weekday-0700", "weekday"),
               trip("flex-ncdar-weekday-0700-from-stops", "weekday")
             ]

      assert stop_times(rows) == [
               {"flex-ncdar-weekday-0700", 1, "flex-ncdar-a1", nil, "07:00:00", "09:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-0700", 2, "flex-ncdar-a1", nil, "07:00:00", "09:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-0700", 3, nil, "flex-ncdar-stops", "07:00:00", "09:00:00", 1,
                2, nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-0700-from-stops", 1, nil, "flex-ncdar-stops", "07:00:00",
                "09:00:00", 2, 1, "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-0700-from-stops", 2, "flex-ncdar-a1", nil, "07:00:00",
                "09:00:00", 1, 2, nil, "flex-ncdar-book"}
             ]

      assert rows.location_groups == [
               %{
                 location_group_id: "flex-ncdar-stops",
                 location_group_name: "North County Dial-a-Ride connecting stops"
               }
             ]

      assert rows.location_group_stops == [
               %{location_group_id: "flex-ncdar-stops", stop_id: "S1"},
               %{location_group_id: "flex-ncdar-stops", stop_id: "S2"}
             ]

      # FH-13: no trip may board and alight at the connecting-stops group, or a
      # rider could travel from one connecting stop to another.
      by_trip = Enum.group_by(rows.stop_times, & &1.trip_id)

      refute Enum.any?(by_trip, fn {_trip_id, trip_rows} ->
               Enum.any?(trip_rows, &(&1.location_group_id && &1.pickup_type == 2)) and
                 Enum.any?(trip_rows, &(&1.location_group_id && &1.drop_off_type == 2))
             end)
    end

    test "references the calendar's own booking rule, not the service-wide one" do
      service =
        service(
          hours: [
            hours("a1", "weekday", "07:00", "09:00"),
            hours("a1", "saturday", "10:00", "12:00")
          ],
          booking_rules: [
            rule(when: :same_day, minutes: 30),
            rule(service_id: "saturday", when: :earlier_day, days: 2, by: "12:00")
          ]
        )

      rows = rows(service, [newport()])

      assert rows.trips == [
               trip("flex-ncdar-weekday-0700", "weekday"),
               trip("flex-ncdar-saturday-1000", "saturday")
             ]

      assert Enum.map(rows.booking_rules, & &1.booking_rule_id) == [
               "flex-ncdar-book",
               "flex-ncdar-book-saturday"
             ]

      assert rule_of(rows, "flex-ncdar-weekday-0700") == ["flex-ncdar-book"]
      assert rule_of(rows, "flex-ncdar-saturday-1000") == ["flex-ncdar-book-saturday"]

      saturday_rule =
        Enum.find(rows.booking_rules, &(&1.booking_rule_id == "flex-ncdar-book-saturday"))

      assert Map.take(saturday_rule, [
               :booking_type,
               :prior_notice_last_day,
               :prior_notice_last_time
             ]) == %{
               booking_type: 2,
               prior_notice_last_day: 2,
               prior_notice_last_time: "12:00:00"
             }
    end

    test "exports an overnight window as 25:00:00" do
      service =
        service(
          hours: [hours("a1", "saturday", "18:00", "01:00")],
          booking_rules: [rule(when: :same_day, minutes: 60)]
        )

      rows = rows(service, [newport()])

      assert rows.trips == [trip("flex-ncdar-saturday-1800", "saturday")]

      assert stop_times(rows) == [
               {"flex-ncdar-saturday-1800", 1, "flex-ncdar-a1", nil, "18:00:00", "25:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-saturday-1800", 2, "flex-ncdar-a1", nil, "18:00:00", "25:00:00", 1, 2,
                nil, "flex-ncdar-book"}
             ]
    end

    test "covers every area when an hours row names none and skips the gap" do
      service =
        service(
          hours: [
            hours(nil, "weekday", "07:00", "09:00"),
            hours(nil, "weekday", "15:00", "18:00")
          ],
          booking_rules: [rule(when: :same_day, minutes: 60)]
        )

      rows = rows(service, [newport(), toledo()])

      assert rows.trips == [
               trip("flex-ncdar-weekday-0700", "weekday"),
               trip("flex-ncdar-weekday-1500", "weekday")
             ]

      assert stop_times(rows) == [
               {"flex-ncdar-weekday-0700", 1, "flex-ncdar-a1", nil, "07:00:00", "09:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-0700", 2, "flex-ncdar-a2", nil, "07:00:00", "09:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-0700", 3, "flex-ncdar-a1", nil, "07:00:00", "09:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-0700", 4, "flex-ncdar-a2", nil, "07:00:00", "09:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-1500", 1, "flex-ncdar-a1", nil, "15:00:00", "18:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-1500", 2, "flex-ncdar-a2", nil, "15:00:00", "18:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-1500", 3, "flex-ncdar-a1", nil, "15:00:00", "18:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-1500", 4, "flex-ncdar-a2", nil, "15:00:00", "18:00:00", 1, 2,
                nil, "flex-ncdar-book"}
             ]
    end

    test "splits overlapping windows of one area at every boundary" do
      service =
        service(
          hours: [
            hours("a1", "weekday", "07:00", "12:00"),
            hours("a1", "weekday", "10:00", "18:00")
          ],
          booking_rules: [rule(when: :same_day, minutes: 60)]
        )

      rows = rows(service, [newport()])

      assert Enum.map(rows.trips, & &1.trip_id) == [
               "flex-ncdar-weekday-0700",
               "flex-ncdar-weekday-1000",
               "flex-ncdar-weekday-1200"
             ]

      assert windows(rows) == [
               {"flex-ncdar-weekday-0700", "07:00:00", "10:00:00"},
               {"flex-ncdar-weekday-0700", "07:00:00", "10:00:00"},
               {"flex-ncdar-weekday-1000", "10:00:00", "12:00:00"},
               {"flex-ncdar-weekday-1000", "10:00:00", "12:00:00"},
               {"flex-ncdar-weekday-1200", "12:00:00", "18:00:00"},
               {"flex-ncdar-weekday-1200", "12:00:00", "18:00:00"}
             ]
    end

    test "keeps an interval that starts after midnight, past 24:00" do
      service =
        service(
          hours: [
            hours("a1", "weekday", "18:00", "01:00"),
            hours("a2", "weekday", "20:00", "02:00")
          ],
          booking_rules: [rule(when: :same_day, minutes: 60)]
        )

      rows = rows(service, [newport(), toledo()])

      assert Enum.map(rows.trips, & &1.trip_id) == [
               "flex-ncdar-weekday-1800",
               "flex-ncdar-weekday-2000",
               "flex-ncdar-weekday-2500"
             ]

      assert stop_times(rows) == [
               {"flex-ncdar-weekday-1800", 1, "flex-ncdar-a1", nil, "18:00:00", "20:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-1800", 2, "flex-ncdar-a1", nil, "18:00:00", "20:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-2000", 1, "flex-ncdar-a1", nil, "20:00:00", "25:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-2000", 2, "flex-ncdar-a2", nil, "20:00:00", "25:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-2000", 3, "flex-ncdar-a1", nil, "20:00:00", "25:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-2000", 4, "flex-ncdar-a2", nil, "20:00:00", "25:00:00", 1, 2,
                nil, "flex-ncdar-book"},
               {"flex-ncdar-weekday-2500", 1, "flex-ncdar-a2", nil, "25:00:00", "26:00:00", 2, 1,
                "flex-ncdar-book", nil},
               {"flex-ncdar-weekday-2500", 2, "flex-ncdar-a2", nil, "25:00:00", "26:00:00", 1, 2,
                nil, "flex-ncdar-book"}
             ]
    end

    test "references no booking rule when the service has none" do
      service = service(hours: [hours("a1", "weekday", "09:00", "15:00")])

      rows = rows(service, [newport()])

      assert rows.booking_rules == []
      assert rows.trips == [trip("flex-ncdar-weekday-0900", "weekday")]

      assert Enum.all?(rows.stop_times, fn row ->
               is_nil(row.pickup_booking_rule_id) and is_nil(row.drop_off_booking_rule_id)
             end)
    end

    test "orders the areas, and their rows, by position" do
      service =
        service(
          hours: [
            hours("a1", "weekday", "07:00", "09:00"),
            hours("a2", "weekday", "07:00", "09:00")
          ],
          booking_rules: [rule(when: :same_day, minutes: 60)]
        )

      rows = rows(service, [toledo(), newport()])

      assert Enum.map(rows.locations, & &1.id) == ["flex-ncdar-a1", "flex-ncdar-a2"]

      assert Enum.map(rows.stop_times, & &1.location_id) == [
               "flex-ncdar-a1",
               "flex-ncdar-a2",
               "flex-ncdar-a1",
               "flex-ncdar-a2"
             ]
    end

    test "numbers every trip's rows from 1 in rider order" do
      service =
        service(
          hours: [
            hours("a1", "weekday", "07:00", "18:00"),
            hours("a2", "weekday", "09:00", "15:00")
          ],
          booking_rules: [rule(when: :same_day, minutes: 60)],
          hub_stop_ids: ["S1"]
        )

      rows = rows(service, [newport(), toledo()])

      assert Enum.all?(Enum.group_by(rows.stop_times, & &1.trip_id), fn {_trip_id, trip_rows} ->
               Enum.map(trip_rows, & &1.stop_sequence) == Enum.to_list(1..length(trip_rows))
             end)

      assert Enum.all?(rows.stop_times, fn row ->
               is_nil(row.pickup_booking_rule_id) != is_nil(row.drop_off_booking_rule_id)
             end)
    end

    test "names a registered service's route for trip planners" do
      service =
        service(
          name: "Newport Dial-a-Ride",
          riders: :registered,
          include_registered: true,
          eligibility: "Adults 60 and older.",
          info_url: "https://example.org/riders"
        )

      assert [%{route_long_name: route_name}] = rows(service).routes
      assert route_name == "Newport Dial-a-Ride (registered riders)"
      assert route_name == RiderText.rider_name(service)
    end
  end

  describe "booking rules" do
    test "maps a real-time rule, its message and the contact fields" do
      service =
        service(
          booking_rules: [rule(when: :now, max_days: 7)],
          phone: "(541) 555-0142",
          booking_url: "https://example.org/book",
          info_url: "https://example.org/info"
        )

      assert [row] = rows(service).booking_rules

      assert row == %{
               booking_rule_id: "flex-ncdar-book",
               booking_type: 0,
               prior_notice_duration_min: nil,
               prior_notice_duration_max: nil,
               prior_notice_last_day: nil,
               prior_notice_last_time: nil,
               prior_notice_start_day: nil,
               prior_notice_start_time: nil,
               prior_notice_service_id: nil,
               message: RiderText.message(service, calendars()),
               phone_number: "(541) 555-0142",
               info_url: "https://example.org/info",
               booking_url: "https://example.org/book"
             }

      assert row.message ==
               "Book now, or up to 7 days ahead. Call (541) 555-0142 or book online."
    end

    test "maps a same-day rule's minimum and maximum advance notice" do
      service = service(booking_rules: [rule(when: :same_day, minutes: 90, max_days: 7)])

      assert [row] = rows(service).booking_rules

      assert Map.take(row, [
               :booking_type,
               :prior_notice_duration_min,
               :prior_notice_duration_max
             ]) == %{
               booking_type: 1,
               prior_notice_duration_min: 90,
               prior_notice_duration_max: 10_080
             }
    end

    test "maps an earlier-day rule's fields and the R7 message" do
      service =
        service(
          booking_rules: [
            rule(
              when: :earlier_day,
              days: 1,
              by: "16:00",
              business_days: true,
              office_service_id: "office"
            )
          ],
          phone: "(541) 555-0142",
          booking_url: "https://example.org/book"
        )

      assert [row] = rows(service).booking_rules

      assert Map.take(row, [
               :booking_type,
               :prior_notice_duration_min,
               :prior_notice_duration_max,
               :prior_notice_last_day,
               :prior_notice_last_time,
               :prior_notice_start_day,
               :prior_notice_start_time,
               :prior_notice_service_id
             ]) == %{
               booking_type: 2,
               prior_notice_duration_min: nil,
               prior_notice_duration_max: nil,
               prior_notice_last_day: 1,
               prior_notice_last_time: "16:00:00",
               prior_notice_start_day: nil,
               prior_notice_start_time: nil,
               prior_notice_service_id: "office"
             }

      assert row.message ==
               "Book by 4:00 pm 1 business day before. Book Monday trips by 4:00 pm the Friday " <>
                 "before. Call (541) 555-0142 or book online."
    end

    test "writes a start day and midnight time only when the horizon is set" do
      service =
        service(
          booking_rules: [
            rule(service_id: "saturday", when: :earlier_day, days: 3, by: "12:00", max_days: 14)
          ]
        )

      assert [row] = rows(service).booking_rules

      assert Map.take(row, [
               :booking_rule_id,
               :prior_notice_last_day,
               :prior_notice_last_time,
               :prior_notice_start_day,
               :prior_notice_start_time,
               :prior_notice_service_id
             ]) == %{
               booking_rule_id: "flex-ncdar-book-saturday",
               prior_notice_last_day: 3,
               prior_notice_last_time: "12:00:00",
               prior_notice_start_day: 14,
               prior_notice_start_time: "00:00:00",
               prior_notice_service_id: nil
             }
    end
  end

  defp rows(service, areas \\ []), do: Areas.rows(service, areas, calendars(), @agency)

  defp service(attrs) do
    struct!(
      FlexService,
      Enum.into(attrs, %{kind: :area, key: "ncdar", name: "North County Dial-a-Ride"})
    )
  end

  defp trip(trip_id, service_id) do
    %{route_id: "flex-ncdar", service_id: service_id, trip_id: trip_id}
  end

  defp stop_times(rows) do
    Enum.map(rows.stop_times, fn row ->
      {
        row.trip_id,
        row.stop_sequence,
        row.location_id,
        row.location_group_id,
        row.start_pickup_drop_off_window,
        row.end_pickup_drop_off_window,
        row.pickup_type,
        row.drop_off_type,
        row.pickup_booking_rule_id,
        row.drop_off_booking_rule_id
      }
    end)
  end

  defp windows(rows) do
    Enum.map(rows.stop_times, fn row ->
      {row.trip_id, row.start_pickup_drop_off_window, row.end_pickup_drop_off_window}
    end)
  end

  defp rule_of(rows, trip_id) do
    rows.stop_times
    |> Enum.filter(&(&1.trip_id == trip_id))
    |> Enum.map(&(&1.pickup_booking_rule_id || &1.drop_off_booking_rule_id))
    |> Enum.uniq()
  end

  defp calendars do
    %{
      "weekday" => %{name: "Weekday", plural: "Weekdays"},
      "saturday" => %{name: "Saturday", plural: "Saturdays"}
    }
  end

  defp newport, do: area("a1", "Newport", 1)
  defp toledo, do: area("a2", "Toledo", 2)

  defp area(key, name, position) do
    %{area: %FlexArea{key: key, name: name, position: position}, geojson: polygon(position)}
  end

  defp polygon(index) do
    lon = -124.05 + index / 100

    %{
      "type" => "Polygon",
      "coordinates" => [
        [[lon, 44.6], [lon + 0.01, 44.6], [lon + 0.01, 44.61], [lon, 44.61], [lon, 44.6]]
      ]
    }
  end

  defp hours(area_key, service_id, start, finish) do
    %FlexHours{area_key: area_key, service_id: service_id, start: start, end: finish}
  end

  defp rule(attrs), do: struct!(FlexBookingRule, attrs)
end
