defmodule GtfsPlanner.Gtfs.Flex.RiderTextTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexHours
  alias GtfsPlanner.Gtfs.FlexService

  # The expected strings in this file are literals from spec §4 R5 and R7 and
  # its examples, never values read back from the implementation.

  @weekday %{name: "Weekday", plural: "Weekdays"}
  @saturday %{name: "Saturday", plural: "Saturdays"}
  @sunday %{name: "Sunday", plural: "Sundays"}

  @transit_note "Its own line from the rule; your text is not shown on the trip screen."
  @otp_note "Then your text, which is where riders see the clock time."
  @oba_note "Then your text as a footnote, so the deadline appears twice."
  @told "To get off away from the route, tell the driver when you board."

  describe "hours_lines/3" do
    test "names each area that has its own hours" do
      service =
        area_service(
          hours: [
            hours(nil, "weekday", "07:00", "18:00"),
            hours("a1", "weekday", "09:00", "15:00")
          ]
        )

      assert RiderText.hours_lines(service, [area("a1", "Toledo")], calendars()) == [
               "Weekdays 7:00 am–6:00 pm",
               "Toledo only: Weekdays 9:00 am–3:00 pm"
             ]
    end

    test "reads an end at or before the start as the next day" do
      service = area_service(hours: [hours(nil, "saturday", "18:00", "01:00")])

      assert RiderText.hours_lines(service, [], calendars()) == [
               "Saturdays 6:00 pm–1:00 am (next day)"
             ]
    end

    test "joins several windows for one area and calendar in stored order" do
      service =
        area_service(
          hours: [
            hours(nil, "weekday", "07:00", "09:00"),
            hours(nil, "weekday", "15:00", "18:00"),
            hours(nil, "saturday", "10:00", "14:00")
          ]
        )

      assert RiderText.hours_lines(service, [], calendars()) == [
               "Weekdays 7:00 am–9:00 am and 3:00 pm–6:00 pm",
               "Saturdays 10:00 am–2:00 pm"
             ]
    end

    test "says when an area service or a detour service has nothing yet" do
      assert RiderText.hours_lines(area_service(hours: []), [], calendars()) == ["No hours yet"]

      assert RiderText.hours_lines(detour(calendar_service_ids: []), [], calendars()) ==
               ["No trips chosen"]
    end

    test "names the calendars and the band of a detour service" do
      service = detour(calendar_service_ids: ["weekday", "saturday"])

      assert RiderText.hours_lines(service, [], calendars()) == [
               "On Route 20 trips: weekdays and Saturdays"
             ]

      banded =
        detour(
          calendar_service_ids: ["weekday", "saturday"],
          band_start: "09:00",
          band_end: "15:00"
        )

      assert RiderText.hours_lines(banded, [], calendars()) == [
               "On Route 20 trips: weekdays and Saturdays, 9:00 am–3:00 pm only"
             ]
    end

    test "words a school-days calendar the way the prototype did" do
      service = detour(calendar_service_ids: ["school"], route_id: "20")

      assert RiderText.hours_lines(service, [], %{"school" => %{name: "School"}}) == [
               "On Route 20 trips: school days"
             ]
    end

    test "falls back to the calendar id and the area key the map does not name" do
      service = area_service(hours: [hours("a3", "WEEKDAY", "07:00", "18:00")])

      assert RiderText.hours_lines(service, [area("a1", "Toledo")], %{}) == [
               "a3 only: WEEKDAY 7:00 am–6:00 pm"
             ]

      unknown = detour(calendar_service_ids: ["special"])

      assert RiderText.hours_lines(unknown, [], %{}) == ["On Route 20 trips: special"]
    end
  end

  describe "deadline_lines/2" do
    test "states one business day ahead with the Monday case" do
      service =
        area_service(
          booking_rules: [rule(when: :earlier_day, days: 1, by: "16:00", business_days: true)]
        )

      assert RiderText.deadline_lines(service, calendars()) == [
               "Book by 4:00 pm 1 business day before",
               "Book Monday trips by 4:00 pm the Friday before"
             ]
    end

    test "states minutes ahead and a booking horizon" do
      same_day = area_service(booking_rules: [rule(when: :same_day, minutes: 60)])

      assert RiderText.deadline_lines(same_day, calendars()) == [
               "Book at least 1 hour before pickup"
             ]

      horizon = area_service(booking_rules: [rule(when: :now, max_days: 7)])
      assert RiderText.deadline_lines(horizon, calendars()) == ["Book now, or up to 7 days ahead"]

      ready = area_service(booking_rules: [rule(when: :now)])
      assert RiderText.deadline_lines(ready, calendars()) == ["Book when you’re ready to travel"]
    end

    test "states calendar days and a horizon without the office-days sentence" do
      service =
        area_service(
          booking_rules: [rule(when: :earlier_day, days: 3, by: "16:00", max_days: 14)]
        )

      assert RiderText.deadline_lines(service, calendars()) == [
               "Book by 4:00 pm 3 days before, up to 14 days ahead"
             ]
    end

    test "states a calendar-scoped rule of an area service" do
      service =
        area_service(
          booking_rules: [
            rule(when: :earlier_day, days: 1, by: "16:00"),
            rule(service_id: "saturday", when: :earlier_day, days: 2, by: "12:00")
          ]
        )

      assert RiderText.deadline_lines(service, calendars()) == [
               "Book by 4:00 pm 1 day before",
               "Saturday trips: book by 12:00 pm 2 days before"
             ]
    end

    test "renders the one rule of a detour service and no calendar-scoped rule" do
      service =
        detour(
          booking_rules: [
            rule(when: :same_day, minutes: 120),
            rule(service_id: "saturday", when: :same_day, minutes: 120)
          ]
        )

      assert RiderText.deadline_lines(service, calendars()) == [
               "Book at least 2 hours before pickup"
             ]
    end

    test "has no lines without a service-wide rule" do
      assert RiderText.deadline_lines(area_service(booking_rules: []), calendars()) == []
    end
  end

  describe "message/2" do
    test "states the deadline, the Monday case and how to book" do
      service =
        area_service(
          phone: "(541) 555-0142",
          booking_url: "https://book.example/ride",
          booking_rules: [rule(when: :earlier_day, days: 1, by: "16:00", business_days: true)]
        )

      assert RiderText.message(service, calendars()) ==
               "Book by 4:00 pm 1 business day before. Book Monday trips by 4:00 pm the Friday before. Call (541) 555-0142 or book online."
    end

    test "adds the phone's own hours to the call" do
      service =
        area_service(
          phone: "(541) 555-0142",
          booking_url: "https://book.example/ride",
          phone_hours: %{"days" => "Mon–Fri", "from" => "08:00", "to" => "17:00"},
          booking_rules: [rule(when: :now)]
        )

      assert RiderText.message(service, calendars()) ==
               "Book when you’re ready to travel. Call (541) 555-0142 (Mon–Fri 8 am–5 pm) or book online."
    end

    test "states the booking types on their own" do
      same_day = area_service(booking_rules: [rule(when: :same_day, minutes: 60)])
      assert RiderText.message(same_day, calendars()) == "Book at least 1 hour before pickup."

      horizon = area_service(booking_rules: [rule(when: :now, max_days: 7)])
      assert RiderText.message(horizon, calendars()) == "Book now, or up to 7 days ahead."
    end

    test "books online or by phone alone" do
      online = area_service(booking_url: "https://book.example/ride")
      assert RiderText.message(online, calendars()) == "Book online."

      phone = area_service(phone: "(541) 555-0142")
      assert RiderText.message(phone, calendars()) == "Call (541) 555-0142."
    end

    test "leaves the how-to sentence out when no contact is saved" do
      assert RiderText.message(area_service(), calendars()) == ""

      assert RiderText.message(area_service(phone: "", booking_url: ""), calendars()) == ""
    end

    test "starts a registered-riders service with who can ride" do
      service =
        area_service(
          riders: :registered,
          eligibility: "Adults 60 and older",
          include_registered: true
        )

      assert RiderText.message(service, calendars()) ==
               "For registered riders only: adults 60 and older."

      ada =
        area_service(
          riders: :registered,
          eligibility: "ADA paratransit card holders",
          include_registered: true
        )

      assert RiderText.message(ada, calendars()) ==
               "For registered riders only: ADA paratransit card holders."
    end

    test "drops a trailing period from the eligibility and states it without one" do
      service =
        area_service(
          riders: :registered,
          eligibility: "Adults 60 and older.",
          booking_rules: [rule(when: :now, max_days: 3)]
        )

      assert RiderText.message(service, calendars()) ==
               "For registered riders only: adults 60 and older. Book now, or up to 3 days ahead."

      unnamed = area_service(riders: :registered)

      assert RiderText.message(unnamed, calendars()) == "For registered riders only."
    end

    test "ends with the staff note exactly as written" do
      service =
        area_service(
          phone: "(541) 555-0142",
          note: "Tell the dispatcher if you use a wheelchair."
        )

      assert RiderText.message(service, calendars()) ==
               "Call (541) 555-0142. Tell the dispatcher if you use a wheelchair."
    end
  end

  describe "rider_name/1" do
    test "qualifies a registered-riders service that is included" do
      service =
        area_service(riders: :registered, include_registered: true, name: "Newport Dial-a-Ride")

      assert RiderText.rider_name(service) == "Newport Dial-a-Ride (registered riders)"
    end

    test "leaves a name that already says who it is for" do
      for name <- [
            "Newport ADA Paratransit",
            "North County paratransit",
            "Newport Senior Shuttle",
            "Eligibility-based rides"
          ] do
        service = area_service(riders: :registered, include_registered: true, name: name)

        assert RiderText.rider_name(service) == name
      end
    end

    test "leaves the name alone when the service is not registered or not included" do
      anyone = area_service(name: "Newport Dial-a-Ride")
      assert RiderText.rider_name(anyone) == "Newport Dial-a-Ride"

      excluded =
        area_service(
          riders: :registered,
          include_registered: false,
          name: "Newport Dial-a-Ride"
        )

      assert RiderText.rider_name(excluded) == "Newport Dial-a-Ride"
    end

    test "answers an empty name for a draft that has none" do
      assert RiderText.rider_name(area_service()) == ""
    end
  end

  describe "drop_off_message/1" do
    test "tells riders to tell the driver for a detour that takes them" do
      assert RiderText.drop_off_message(detour(dropoffs: :tell_driver)) == @told
      assert RiderText.drop_off_message(detour(dropoffs: :dropoff_only)) == @told
    end

    test "has no message for a booked drop-off or an area service" do
      assert RiderText.drop_off_message(detour(dropoffs: :book)) == nil
      assert RiderText.drop_off_message(area_service(dropoffs: :tell_driver)) == nil
    end
  end

  describe "app_renderings/1" do
    test "words a one-day rule for each app" do
      rule = rule(when: :earlier_day, days: 1, by: "16:00")

      assert RiderText.app_renderings(rule) == [
               {"Transit app", "Book by 4 PM the day before", @transit_note},
               {"OpenTripPlanner planners", "Reservation required at least 1 day in advance",
                @otp_note},
               {"OneBusAway (in development)", "Book by 4:00 pm the day before your ride",
                @oba_note}
             ]
    end

    test "counts the days of a longer deadline" do
      rule = rule(when: :earlier_day, days: 3, by: "16:00")

      assert app_lines(rule) == [
               {"Transit app", "Book by 4 PM 3 days before"},
               {"OpenTripPlanner planners", "Reservation required at least 3 days in advance"},
               {"OneBusAway (in development)", "Book by 4:00 pm the day before your ride"}
             ]
    end

    test "words the business-days Friday case without a fixed date" do
      rule = rule(when: :earlier_day, days: 1, by: "16:00", business_days: true)

      assert app_lines(rule) == [
               {"Transit app", "Book by 4 PM the day before"},
               {"OpenTripPlanner planners", "Reservation required at least 1 day in advance"},
               {"OneBusAway (in development)", "Book by 4:00 pm the Friday before"}
             ]

      refute Enum.any?(RiderText.app_renderings(rule), fn {_app, line, _note} ->
               line =~ ~r/Mon,|Fri,|Oct|Jan|2026/
             end)
    end

    test "words the same-day and on-the-spot rules" do
      assert app_lines(rule(when: :same_day, minutes: 90)) == [
               {"Transit app", "Book 1 hour 30 minutes ahead"},
               {"OpenTripPlanner planners", "Reservation required"},
               {"OneBusAway (in development)", "Same-day booking"}
             ]

      assert app_lines(rule(when: :now)) == [
               {"Transit app", "Book now"},
               {"OpenTripPlanner planners", "Reservation required"},
               {"OneBusAway (in development)", "No notice needed"}
             ]
    end
  end

  describe "changes/3" do
    test "words an hours difference per calendar" do
      saved = area_service(hours: [hours(nil, "weekday", "07:00", "18:00")])
      draft = %{saved | hours: [hours(nil, "weekday", "07:00", "17:00")]}

      assert RiderText.changes(saved, draft, calendars()) == [
               "Weekdays: 7:00 am–6:00 pm → 7:00 am–5:00 pm"
             ]
    end

    test "joins the windows a calendar keeps in one line, and names a calendar it dropped" do
      saved =
        area_service(
          hours: [
            hours(nil, "weekday", "07:00", "18:00"),
            hours("a1", "weekday", "09:00", "15:00"),
            hours(nil, "saturday", "09:00", "16:00")
          ]
        )

      draft =
        %{
          saved
          | hours: [
              hours(nil, "weekday", "07:00", "18:00"),
              hours("a1", "weekday", "09:00", "15:00")
            ]
        }

      assert RiderText.changes(saved, draft, calendars()) == [
               "Saturdays: 9:00 am–4:00 pm → no service"
             ]
    end

    test "reports a booking rule that appeared, changed or went away" do
      saved = area_service(booking_rules: [rule(when: :same_day, minutes: 30)])
      draft = %{saved | booking_rules: [rule(when: :same_day, minutes: 60)]}

      assert RiderText.changes(saved, draft, calendars()) == [
               "Booking: book at least 1 hour before pickup",
               "Text for riders changed"
             ]

      with_rule = %{
        saved
        | booking_rules: [
            rule(when: :same_day, minutes: 30),
            rule(service_id: "saturday", when: :earlier_day, days: 2, by: "12:00")
          ]
      }

      assert RiderText.changes(saved, with_rule, calendars()) == [
               "New rule for Saturday trips: book by 12:00 pm 2 days before",
               "Text for riders changed"
             ]

      assert RiderText.changes(with_rule, saved, calendars()) == [
               "Saturday booking rule removed",
               "Text for riders changed"
             ]
    end

    test "words a phone, a booking link and a note in the editor's terms" do
      saved = area_service(phone: "(541) 555-0142")

      draft = %{
        saved
        | phone: nil,
          booking_url: "https://example.org/book",
          note: "Tell the dispatcher about a wheelchair."
      }

      assert RiderText.changes(saved, draft, calendars()) == [
               "Phone: removed",
               "Booking link added",
               "Note for riders added"
             ]
    end

    test "words a detour's hours difference as one line" do
      saved = detour(calendar_service_ids: ["weekday"], band_start: "09:00", band_end: "15:00")
      draft = %{saved | band_end: "12:00"}

      assert RiderText.changes(saved, draft, calendars()) == [
               "Trips with detours: On Route 20 trips: weekdays, 9:00 am–3:00 pm only → On Route 20 trips: weekdays, 9:00 am–12:00 pm only"
             ]
    end

    test "has nothing to report for an unchanged service" do
      saved = area_service(hours: [hours(nil, "weekday", "07:00", "18:00")])

      assert RiderText.changes(saved, saved, calendars()) == []
    end
  end

  describe "range_text/2 and window/1" do
    test "words one window as riders read it" do
      assert RiderText.range_text(hours(nil, "weekday", "07:00", "18:00")) == "7:00 am–6:00 pm"

      assert RiderText.range_text(hours(nil, "saturday", "18:00", "01:00")) ==
               "6:00 pm–1:00 am (next day)"

      assert RiderText.range_text(hours(nil, "weekday", "07:00", "18:00"), compact: true) ==
               "7 am–6 pm"
    end

    test "places a window on the strip's axis, with the next day counted on" do
      assert RiderText.window(hours(nil, "weekday", "07:00", "18:00")) ==
               %{start: 420, finish: 1_080}

      assert RiderText.window(hours(nil, "saturday", "18:00", "01:00")) ==
               %{start: 1_080, finish: 1_500}

      assert RiderText.window(hours(nil, "weekday", "", "18:00")) == nil
    end
  end

  defp calendars do
    %{"weekday" => @weekday, "saturday" => @saturday, "sunday" => @sunday}
  end

  defp app_lines(rule) do
    rule
    |> RiderText.app_renderings()
    |> Enum.map(fn {app, line, _note} -> {app, line} end)
  end

  # The areas are loaded: `changes/3` and `hours_lines/3` read the service's
  # areas for the words that name them, as every production caller has them.
  defp area_service(attrs \\ []) do
    struct!(FlexService, Enum.into(attrs, %{kind: :area, areas: []}))
  end

  defp detour(attrs) do
    struct!(FlexService, Enum.into(attrs, %{kind: :detour, route_id: "20", areas: []}))
  end

  defp hours(area_key, service_id, start, finish) do
    %FlexHours{area_key: area_key, service_id: service_id, start: start, end: finish}
  end

  defp rule(attrs), do: struct!(FlexBookingRule, attrs)

  defp area(key, name), do: %FlexArea{key: key, name: name, position: 1}
end
