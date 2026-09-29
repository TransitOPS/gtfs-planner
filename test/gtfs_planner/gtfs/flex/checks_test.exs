defmodule GtfsPlanner.Gtfs.Flex.ChecksTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.BookingRule
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  # A 0.01° square at 44.6°N: about 0.88 km², the fixture steps 5 and 14 measure
  # with.
  @square %{
    "type" => "Polygon",
    "coordinates" => [
      [[-124.05, 44.6], [-124.04, 44.6], [-124.04, 44.61], [-124.05, 44.61], [-124.05, 44.6]]
    ]
  }

  describe "version_facts/2" do
    test "reads the version's calendars, stops, routes and existing IDs" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      other_org_version = gtfs_version_fixture(other_organization.id)

      insert_calendar(version, "weekday")
      calendar_date_fixture(organization.id, version.id, %{service_id: "special"})
      insert_stop(version, "S1", "-124.045", "44.605")
      insert_route(version, "R1", continuous_pickup: 0)
      insert_route(version, "R2")
      insert_trip(version, "R2", "T1")
      insert_booking_rule(version, "imported-book")

      # The same natural IDs in a sibling version and in another organization.
      insert_calendar(other_version, "weekday")
      insert_stop(other_version, "S1", "-124.045", "44.605")
      insert_route(other_version, "R1")
      insert_trip(other_version, "R1", "T1")
      insert_booking_rule(other_version, "imported-book")
      insert_stop(other_org_version, "S1", "-124.045", "44.605")

      facts = Checks.version_facts(organization.id, version.id)

      # A weekly calendar and a dates-only calendar are both service IDs.
      assert facts.service_ids == MapSet.new(["weekday", "special"])
      assert facts.stop_ids == MapSet.new(["S1"])
      assert facts.routes == %{"R1" => %{continuous?: true}, "R2" => %{continuous?: false}}

      assert facts.gtfs_ids == %{
               routes: MapSet.new(["R1", "R2"]),
               trips: MapSet.new(["T1"]),
               stops: MapSet.new(["S1"]),
               booking_rules: MapSet.new(["imported-book"])
             }
    end

    test "marks a route continuous for every GTFS value that allows boarding anywhere" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      insert_route(version, "P0", continuous_pickup: 0)
      insert_route(version, "P1", continuous_pickup: 1)
      insert_route(version, "P2", continuous_pickup: 2)
      insert_route(version, "P3", continuous_pickup: 3)
      insert_route(version, "D0", continuous_drop_off: 0)
      insert_route(version, "D1", continuous_drop_off: 1)
      insert_route(version, "D2", continuous_drop_off: 2)
      insert_route(version, "D3", continuous_drop_off: 3)

      facts = Checks.version_facts(organization.id, version.id)

      assert facts.routes["P0"].continuous?
      refute facts.routes["P1"].continuous?
      assert facts.routes["P2"].continuous?
      assert facts.routes["P3"].continuous?
      assert facts.routes["D0"].continuous?
      refute facts.routes["D1"].continuous?
      assert facts.routes["D2"].continuous?
      assert facts.routes["D3"].continuous?
    end
  end

  describe "run/3 when checks" do
    test "reports an area service with no hours" do
      {service, version} = area_service_fixture(hours: [])

      assert [check] = checks_for(service, version, :when, :hours)

      assert check.level == :error
      assert check.text == "Add the hours riders can travel."
    end

    test "reports a detour service whose trips are not chosen" do
      {service, version} = detour_service_fixture(calendar_service_ids: [])

      assert [check] = checks_for(service, version, :when, :hours)

      assert check.level == :error
      assert check.text == "Choose which trips offer detours."
    end

    test "reports hours that run for more than 16 hours" do
      {service, version} = area_service_fixture(hours: [hours("weekday", "07:00", "23:59")])

      assert [check] = checks_for(service, version, :when, :"hours-0")

      assert check.level == :error
      assert check.text == "These hours run 17 hours, into the next day. Check the end time."
    end

    test "accepts hours up to 16 hours and an overnight window" do
      {service, version} =
        area_service_fixture(
          hours: [
            hours("weekday", "07:00", "23:00"),
            hours("saturday", "18:00", "01:00")
          ]
        )

      assert checks_for(service, version, :when, :"hours-0") == []
      assert checks_for(service, version, :when, :"hours-1") == []
    end

    test "warns when areas run at different hours" do
      {service, version} =
        area_service_fixture(hours: [hours("weekday", "07:00", "18:00", "a1")])

      assert [check] = checks_for(service, version, :when, :zone_hours)

      assert check.level == :warning

      assert check.text ==
               "Areas in this service run at different hours. Riders read each area’s hours " <>
                 "separately (“Toledo only: …”); check the rider text says it plainly."
    end

    test "does not warn when every hours row covers all areas" do
      {service, version} = area_service_fixture(hours: [hours("weekday", "07:00", "18:00")])

      assert checks_for(service, version, :when, :zone_hours) == []
    end

    test "reports a calendar the version does not have" do
      {service, version} = area_service_fixture(hours: [hours("weekday", "07:00", "18:00")])

      detour =
        insert_service(version, %{
          "key" => "ridge-detours",
          "name" => "Ridge Road detours",
          "kind" => "detour",
          "route_id" => "R99",
          "calendar_service_ids" => ["school"],
          "booking_rules" => [%{"when" => "now"}]
        })

      assert [check] = checks_for(service, version, :when, :hours)
      assert check.level == :error

      assert check.text ==
               "The calendar “weekday” is not in this version. Choose a calendar this version has."

      assert [detour_check] = checks_for(detour, version, :when, :hours)

      assert detour_check.text ==
               "The calendar “school” is not in this version. Choose a calendar this version has."
    end

    test "accepts a calendar the version has only as an exception date" do
      {service, version} = area_service_fixture(hours: [hours("special", "07:00", "18:00")])

      calendar_date_fixture(version.organization_id, version.id, %{service_id: "special"})

      assert checks_for(service, version, :when, :hours) == []
    end
  end

  describe "run/3 where checks" do
    test "reports an area service with no areas" do
      {service, version} = area_service_fixture()

      assert [check] = checks_for(service, version, :where, :area)
      assert check.level == :error
      assert check.text == "Add the area riders can travel in."
    end

    test "warns when an area name looks like data" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)

      assert checks_for(service, version, :where, :area) == []

      rename_area(service, "a1", "NNS_ZONE_A")

      assert [check] = checks_for(service, version, :where, :area)
      assert check.level == :warning

      assert check.text ==
               "Riders see the area name “NNS_ZONE_A”. Use a place name riders know, such as the " <>
                 "town."
    end

    test "reports areas of one service that overlap while both are in service" do
      {service, version} = area_service_fixture(hours: [hours("weekday", "07:00", "18:00")])
      draw_area(service, "a1", 1, named: "Newport")
      draw_area(service, "a2", 2, named: "Toledo", geojson: shift_east(@square, 0.002))

      assert [check] = checks_for(service, version, :where, :area)
      assert check.level == :error

      assert check.text ==
               "The areas “Newport” and “Toledo” overlap while both are in service. Redraw one " <>
                 "so they do not."
    end

    test "accepts areas that overlap at different hours" do
      {service, version} =
        area_service_fixture(
          hours: [
            hours("weekday", "07:00", "12:00", "a1"),
            hours("saturday", "07:00", "12:00", "a2")
          ]
        )

      insert_calendar(version, "weekday")
      insert_calendar(version, "saturday")
      draw_area(service, "a1", 1, geojson: @square)
      draw_area(service, "a2", 2, geojson: shift_east(@square, 0.002))

      assert checks_for(service, version, :where, :area) == []
    end

    test "accepts areas that do not overlap" do
      {service, version} = area_service_fixture(hours: [hours("weekday", "07:00", "18:00")])
      draw_area(service, "a1", 1, geojson: @square)
      draw_area(service, "a2", 2, geojson: shift_east(@square, 1.0))

      assert checks_for(service, version, :where, :area) == []
    end

    test "counts an overnight window and the next morning as one hours window" do
      {service, version} =
        area_service_fixture(
          hours: [
            hours("weekday", "20:00", "02:00", "a1"),
            hours("weekday", "01:00", "06:00", "a2")
          ]
        )

      draw_area(service, "a1", 1, geojson: @square)
      draw_area(service, "a2", 2, geojson: shift_east(@square, 0.002))

      assert [%{level: :error}] = checks_for(service, version, :where, :area)
    end

    test "reports stops the version does not have" do
      {service, version} = area_service_fixture(hub_stop_ids: ["S1", "S9"])
      insert_stop(version, "S1", "-124.045", "44.605")

      assert [check] = checks_for(service, version, :where, :stops)
      assert check.level == :error
      assert check.text == "The stop “S9” is not in this version."
    end

    test "reports detour stretch stops the version does not have" do
      {service, version} =
        detour_service_fixture(first_stop_id: "S1", last_stop_id: "S9")

      insert_stop(version, "S1", "-124.045", "44.605")

      assert [check] = checks_for(service, version, :where, :stops)
      assert check.text == "The stop “S9” is not in this version."
    end

    test "reports a detour service that has not chosen a route" do
      draft = %FlexService{
        kind: :detour,
        active: true,
        areas: [],
        hours: [],
        booking_rules: [],
        hub_stop_ids: [],
        calendar_service_ids: []
      }

      {_service, version} = detour_service_fixture()

      assert [check] = checks_for(draft, version, :where, :route)
      assert check.level == :error
      assert check.text == "Choose the route that detours."
    end

    test "reports a detour route the version does not have" do
      {service, version} = detour_service_fixture(route_id: "R99")

      assert [check] = checks_for(service, version, :where, :route)
      assert check.level == :error
      assert check.text == "Route “R99” is not in this version. Choose a route this version has."
    end

    test "reports routes an area's route distance names but the version does not have" do
      {service, version} = area_service_fixture()
      insert_area(service, "a1", 1, source: "route_distance", route_ids: ["R99", "R1"])
      insert_route(version, "R1")

      assert [check] = checks_for(service, version, :where, :routes)
      assert check.level == :error
      assert check.text == "Route “R99” is not in this version. Choose a route this version has."
    end

    test "reports a detour service that has not chosen a distance" do
      {service, version} = detour_service_fixture(distance_m: nil)

      assert [check] = checks_for(service, version, :where, :distance)
      assert check.level == :error
      assert check.text == "Choose the detour distance your agency publishes."
    end

    test "reports a detour service without timetable wording" do
      {service, version} = detour_service_fixture(wording: nil)

      assert [check] = checks_for(service, version, :where, :wording)
      assert check.level == :error

      assert check.text ==
               "Enter how your timetable and website describe detours, so the text riders read " <>
                 "matches them."
    end

    test "warns when an ADA-only detour reaches less than ¾ mile" do
      {service, version} = detour_service_fixture(ada_only: true, distance_m: 800)

      assert [check] = checks_for(service, version, :where, :distance)
      assert check.level == :warning

      assert check.text ==
               "Detours for ADA-eligible riders only replace paratransit, which must reach ¾ mile " <>
                 "from the route. A shorter distance leaves some eligible riders without service."
    end

    test "accepts an ADA-only detour at ¾ mile" do
      {service, version} = detour_service_fixture(ada_only: true, distance_m: 1_200)

      assert checks_for(service, version, :where, :distance) == []
    end

    test "reports a route that lets riders board anywhere" do
      {service, version} = detour_service_fixture()
      insert_route(version, "R20", continuous_pickup: 0)

      assert [check] = checks_for(service, version, :where, :route)
      assert check.level == :error

      assert check.text ==
               "Route R20 lets riders board anywhere along the street. Exports can’t combine " <>
                 "that with detours. In Route R20, set Continuous Pickup and Continuous Drop Off " <>
                 "to 1 (only at stops)."
    end

    test "reports continuous boarding that only the drop-off field turns on" do
      {service, version} = detour_service_fixture()
      insert_route(version, "R20", continuous_drop_off: 2)

      assert [check] = checks_for(service, version, :where, :route)
      assert check.text =~ "Route R20 lets riders board anywhere along the street."
    end

    test "accepts a route with continuous boarding turned off" do
      {service, version} = detour_service_fixture()
      insert_route(version, "R20")

      assert checks_for(service, version, :where, :route) == []
    end
  end

  describe "run/3 booking checks" do
    test "reports a service with no way to book" do
      {service, version} = area_service_fixture(phone: nil, booking_url: nil)

      assert [check] = checks_for(service, version, :booking, :contact)
      assert check.level == :error
      assert check.text == "Add a phone number or booking link so riders know how to book."
    end

    test "reports a phone number that is not ten digits" do
      draft = %FlexService{
        kind: :area,
        active: true,
        areas: [],
        hours: [],
        booking_rules: [],
        phone: "555-0142"
      }

      {_service, version} = area_service_fixture()

      assert [check] = checks_for(draft, version, :booking, :phone)
      assert check.level == :error
      assert check.text == "Enter the phone number as 10 digits, for example (541) 555-0142."
    end

    test "reports a booking link that is not an https address" do
      draft = %FlexService{
        kind: :area,
        active: true,
        areas: [],
        hours: [],
        booking_rules: [],
        booking_url: "ride.example.com/toledo"
      }

      {_service, version} = area_service_fixture()

      assert [check] = checks_for(draft, version, :booking, :url)
      assert check.level == :error
      assert check.text == "Enter the full booking link, starting with https://"
    end

    test "reports a same-day rule without minutes" do
      {service, version} = area_service_fixture(booking_rules: [%{"when" => "same_day"}])

      assert [check] = checks_for(service, version, :booking, :minutes)
      assert check.level == :error
      assert check.text == "Enter how many minutes ahead riders must book."
    end

    test "reports an earlier-day rule without days" do
      {service, version} =
        area_service_fixture(booking_rules: [%{"when" => "earlier_day", "by" => "16:00"}])

      assert [check] = checks_for(service, version, :booking, :days)
      assert check.level == :error
      assert check.text == "Enter how many days ahead riders must book."
    end

    test "reports an earlier-day rule without a time to book by" do
      {service, version} =
        area_service_fixture(booking_rules: [%{"when" => "earlier_day", "days" => 1}])

      assert [check] = checks_for(service, version, :booking, :by)
      assert check.level == :error
      assert check.text == "Enter the time riders must book by."
    end

    test "reports a detour service with more than one booking rule" do
      {service, version} =
        detour_service_fixture(
          booking_rules: [%{"when" => "now"}, %{"when" => "same_day", "minutes" => 30}]
        )

      assert [check] = checks_for(service, version, :booking, :booking_rules)
      assert check.level == :error

      assert check.text ==
               "A detour service has exactly one booking rule, and it covers every trip. Remove " <>
                 "the extra or calendar-scoped rules."
    end

    test "reports a detour service with a calendar-scoped booking rule" do
      {service, version} =
        detour_service_fixture(booking_rules: [%{"service_id" => "weekday", "when" => "now"}])

      insert_calendar(version, "weekday")

      assert [%{level: :error, field: :booking_rules}] =
               checks_for(service, version, :booking, :booking_rules)
    end

    test "reports a booking rule scoped to a calendar the version does not have" do
      {service, version} =
        area_service_fixture(booking_rules: [%{"service_id" => "saturday", "when" => "now"}])

      assert [check] = checks_for(service, version, :booking, :service_id)
      assert check.level == :error

      assert check.text ==
               "The calendar “saturday” is not in this version. Choose a calendar this version has."
    end

    test "warns when the note contradicts the minutes the rule requires" do
      {service, version} =
        area_service_fixture(
          note: "Book 2 hours ahead by phone.",
          booking_rules: [%{"when" => "same_day", "minutes" => 30}]
        )

      assert [check] = checks_for(service, version, :booking, :note)
      assert check.level == :warning

      assert check.text ==
               "The note says “2 hours”, but the rule says at least 30 minutes. Trip planners " <>
                 "show both."
    end

    test "warns when the note contradicts the days the rule requires" do
      {service, version} =
        area_service_fixture(
          note: "Please book 3 days ahead.",
          booking_rules: [%{"when" => "earlier_day", "days" => 1, "by" => "16:00"}]
        )

      assert [check] = checks_for(service, version, :booking, :note)
      assert check.text == "The note says “3 days”, but the rule says 1 day."
    end

    test "accepts a note that agrees with the rule" do
      {service, version} =
        area_service_fixture(
          note: "Book 30 minutes ahead.",
          booking_rules: [%{"when" => "same_day", "minutes" => 30}]
        )

      assert checks_for(service, version, :booking, :note) == []
    end

    test "warns when the note mentions booking online without a link" do
      {service, version} = area_service_fixture(note: "You can book online or call us.")

      assert [check] = checks_for(service, version, :booking, :note)
      assert check.level == :warning

      assert check.text ==
               "The note mentions booking online, but there is no booking link. Add the link so " <>
                 "trip planners can offer it."
    end

    test "warns when the note repeats times" do
      {service, version} = area_service_fixture(note: "Call the office at 8 am for a ride.")

      assert [check] = checks_for(service, version, :booking, :note)

      assert check.text ==
               "The note repeats times. Trip planners already show service hours, and phone-line " <>
                 "hours have their own field."
    end

    test "warns when the note lists fares" do
      {service, version} = area_service_fixture(note: "The fare is $2 each way.")

      assert [check] = checks_for(service, version, :booking, :note)

      assert check.text ==
               "The note lists fares. Put fares on the page with fares and details, so the note " <>
                 "stays about booking."
    end

    test "warns when the note looks like code or data" do
      {service, version} = area_service_fixture(note: "Set zone_code_A before booking.")

      assert [check] = checks_for(service, version, :booking, :note)
      assert check.text == "The note looks like code or data. Riders see it exactly as written."
    end

    test "warns when the text riders read is over 250 characters" do
      note = String.duplicate("Call the office to book your ride. ", 6)
      {service, version} = area_service_fixture(note: note)

      message = "Book when you’re ready to travel. Call (541) 555-0142. " <> String.trim(note)

      assert [check] = checks_for(service, version, :booking, :note)
      assert check.level == :warning

      assert check.text ==
               "The text riders read is #{String.length(message)} characters. Keep it near 250: " <>
                 "the spec asks for a short note about what riders must do."
    end

    test "accepts a short note" do
      {service, version} = area_service_fixture(note: "Call to book.")

      assert checks_for(service, version, :booking, :note) == []
    end
  end

  describe "run/3 rider checks" do
    test "reports a registered service without eligibility" do
      {service, version} = area_service_fixture(riders: "registered")

      assert [check] = checks_for(service, version, :riders, :eligibility)
      assert check.level == :error

      assert check.text ==
               "Say who can register, for example “Adults 60 and older and riders with " <>
                 "disabilities.”"
    end

    test "reports an included registered service without an info page" do
      {service, version} =
        area_service_fixture(
          riders: "registered",
          eligibility: "Adults 60 and older.",
          include_registered: true
        )

      assert [check] = checks_for(service, version, :riders, :info)
      assert check.level == :error

      assert check.text ==
               "Add a page with fares and details under How riders book. Riders who aren’t " <>
                 "registered need to learn how to sign up."
    end

    test "accepts an included registered service with eligibility and an info page" do
      {service, version} =
        area_service_fixture(
          riders: "registered",
          eligibility: "Adults 60 and older.",
          info_url: "https://northcoast.example/dial-a-ride",
          include_registered: true
        )

      assert checks_for(service, version, :riders, :info) == []
      assert checks_for(service, version, :riders, :eligibility) == []
    end

    test "tells the page how trip planners treat a registered service" do
      {included, version} =
        area_service_fixture(
          riders: "registered",
          eligibility: "Adults 60 and older.",
          info_url: "https://northcoast.example/dial-a-ride",
          include_registered: true
        )

      excluded =
        insert_service(version, %{
          "key" => "toledo-dial-a-ride",
          "name" => "Toledo Dial-a-Ride",
          "kind" => "area",
          "phone" => "(541) 555-0142",
          "riders" => "registered",
          "eligibility" => "Adults 60 and older.",
          "hours" => [%{"service_id" => "weekday", "start" => "07:00", "end" => "18:00"}],
          "booking_rules" => [%{"when" => "now"}]
        })

      assert [check] = checks_for(included, version, :riders, :riders)
      assert check.level == :info

      assert check.text ==
               "Trip planners can’t check who is registered. They show this service to everyone, " <>
                 "with your statement of who can ride."

      assert [excluded_check] = checks_for(excluded, version, :riders, :riders)

      assert excluded_check.text ==
               "Left out of the flex feed. Riders won’t find it in trip planners; your website " <>
                 "and phone line stay the way to reach it."
    end
  end

  describe "run/3 overlap information" do
    test "reports another active area service that serves part of a stored area" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1, named: "Newport")

      other = insert_area_service(version, "Toledo Flex", shift_east(@square, 0.002), "a1")

      assert [check] = checks_for(service, version, :where, :area, others: [other])
      assert check.level == :info
      assert check.text =~ "Part of Newport (0.7 km²) is also served by Toledo Flex."
      assert check.text =~ "Riders there may see both services."
    end

    test "leaves out inactive, detour, other-version and small-overlap services" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)

      inactive =
        insert_area_service(version, "Inactive Flex", shift_east(@square, 0.002), "a1",
          active: false
        )

      detour_overlap =
        insert_area_service(version, "Detour Flex", shift_east(@square, 0.002), "a1",
          kind: "detour"
        )

      other_version = gtfs_version_fixture(version.organization_id)

      other_version_overlap =
        insert_area_service(other_version, "Other Version Flex", shift_east(@square, 0.002), "a1")

      touching = insert_area_service(version, "Edge Flex", shift_east(@square, 0.01), "a1")

      others = [inactive, detour_overlap, other_version_overlap, touching]

      assert checks_for(service, version, :where, :area, others: others) == []
    end

    test "measures no other service when the caller passes none" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)
      insert_area_service(version, "Toledo Flex", shift_east(@square, 0.002), "a1")

      assert checks_for(service, version, :where, :area, others: []) == []
    end
  end

  describe "run/3 generated ID collisions" do
    test "reports a generated route ID the version already uses" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)
      insert_route(version, "flex-newport-dial-a-ride")

      assert [check] = checks_for(service, version, :where, :id)
      assert check.level == :error

      assert check.text ==
               "The generated route ID “flex-newport-dial-a-ride” is already used in routes.txt. " <>
                 "A feed can’t have two routes with the same ID."
    end

    test "reports a generated location ID the version already uses as a stop ID" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)
      insert_stop(version, "flex-newport-dial-a-ride-a1", "-124.045", "44.605")

      assert [check] = checks_for(service, version, :where, :id)
      assert check.level == :error

      assert check.text ==
               "The generated location ID “flex-newport-dial-a-ride-a1” is already used as a " <>
                 "stop ID. GTFS IDs must be unique across stops, locations and location groups."
    end

    test "reports a generated booking rule ID the version already uses" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)
      insert_booking_rule(version, "flex-newport-dial-a-ride-book")

      assert [check] = checks_for(service, version, :where, :id)
      assert check.level == :error

      assert check.text ==
               "The generated booking rule ID “flex-newport-dial-a-ride-book” is already used in " <>
                 "booking_rules.txt. A feed can’t have two booking rules with the same ID."
    end

    test "reports a generated booking rule ID that a scoped rule makes" do
      {service, version} =
        area_service_fixture(booking_rules: [%{"service_id" => "saturday", "when" => "now"}])

      draw_area(service, "a1", 1)
      insert_calendar(version, "saturday")
      insert_booking_rule(version, "flex-newport-dial-a-ride-book-saturday")

      assert [check] = checks_for(service, version, :where, :id)
      assert check.text =~ "flex-newport-dial-a-ride-book-saturday"
    end

    test "reports an existing trip that uses the generated trip prefix" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)
      insert_route(version, "R1")
      insert_trip(version, "R1", "flex-newport-dial-a-ride-weekday-0700")

      assert [check] = checks_for(service, version, :where, :id)
      assert check.level == :error

      assert check.text ==
               "This version already has the trip “flex-newport-dial-a-ride-weekday-0700”, and " <>
                 "the flex file generates trip IDs starting with the same prefix. Two trips with " <>
                 "the same ID can’t be published."
    end

    test "reports no collision for a version without flex IDs" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)
      insert_route(version, "R1")
      insert_trip(version, "R1", "T1")

      assert checks_for(service, version, :where, :id) == []
    end
  end

  describe "run/3 a ready service" do
    test "returns no checks for an area service that is ready to export" do
      {service, version} = area_service_fixture()
      draw_area(service, "a1", 1)
      insert_calendar(version, "weekday")

      assert checks(service, version) == []
    end

    test "returns no checks for a detour service that is ready to export" do
      {service, version} = detour_service_fixture()
      insert_route(version, "R20")
      insert_calendar(version, "weekday")
      insert_stop(version, "S1", "-124.045", "44.605")
      insert_stop(version, "S2", "-124.035", "44.605")

      assert checks(service, version) == []
    end
  end

  describe "status/2" do
    test "is Ready with no checks" do
      service = ready_service()

      assert Checks.status(service, []) == %{
               tone: :success,
               label: "Ready",
               errors: 0,
               warnings: 0
             }
    end

    test "counts suggestions for warnings alone" do
      service = ready_service()

      assert Checks.status(service, [check(:warning), check(:warning)]) == %{
               tone: :warning,
               label: "Ready · 2 suggestions",
               errors: 0,
               warnings: 2
             }
    end

    test "counts problems for errors" do
      service = ready_service()

      assert Checks.status(service, [check(:error)]) == %{
               tone: :error,
               label: "1 problem",
               errors: 1,
               warnings: 0
             }

      assert Checks.status(service, [check(:error), check(:error)]) == %{
               tone: :error,
               label: "2 problems",
               errors: 2,
               warnings: 0
             }
    end

    test "is Inactive without checking a deactivated service" do
      service = %{ready_service() | active: false}

      assert Checks.status(service, [check(:error)]) == %{
               tone: :neutral,
               label: "Inactive",
               errors: 1,
               warnings: 0
             }
    end

    test "is Not in trip planners for a registered service that is left out" do
      service = %{ready_service() | riders: :registered, include_registered: false}

      assert Checks.status(service, []) == %{
               tone: :neutral,
               label: "Not in trip planners",
               errors: 0,
               warnings: 0
             }
    end
  end

  # --- fixtures ---------------------------------------------------------------

  defp area_service_fixture(attrs \\ []) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    service =
      insert_service(
        version,
        Map.merge(
          %{
            "key" => "newport-dial-a-ride",
            "name" => "Newport Dial-a-Ride",
            "kind" => "area",
            "phone" => "(541) 555-0142",
            "hours" => [hours("weekday", "07:00", "18:00")],
            "booking_rules" => [%{"when" => "now"}]
          },
          string_keys(attrs)
        )
      )

    {service, version}
  end

  defp detour_service_fixture(attrs \\ []) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    service =
      insert_service(
        version,
        Map.merge(
          %{
            "key" => "valley-line-detours",
            "name" => "Valley Line detours",
            "kind" => "detour",
            "route_id" => "R20",
            "distance_m" => 1_200,
            "wording" => "up to ¾ mile from the route",
            "phone" => "(541) 555-0142",
            "calendar_service_ids" => ["weekday"],
            "booking_rules" => [%{"when" => "now"}]
          },
          string_keys(attrs)
        )
      )

    {service, version}
  end

  # `attrs` are the caller's string-keyed overrides; the fixtures above turn a
  # keyword list into that shape so a test reads as the field it changes.
  defp insert_service(version, attrs) do
    %FlexService{organization_id: version.organization_id, gtfs_version_id: version.id}
    |> FlexService.create_changeset(attrs)
    |> Repo.insert!()
  end

  defp string_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp draw_area(service, key, position, opts \\ []) do
    insert_area(service, key, position,
      name: Keyword.get(opts, :named, "Area #{key}"),
      geojson: Keyword.get(opts, :geojson, @square)
    )
  end

  defp insert_area(service, key, position, opts) do
    area =
      %FlexArea{
        flex_service_id: service.id,
        organization_id: service.organization_id,
        gtfs_version_id: service.gtfs_version_id
      }
      |> FlexArea.changeset(%{
        "key" => key,
        "position" => position,
        "name" => Keyword.get(opts, :name, "Area #{key}"),
        "source" => Keyword.get(opts, :source, "drawn"),
        "route_ids" => Keyword.get(opts, :route_ids, []),
        "distance_m" => Keyword.get(opts, :distance_m)
      })
      |> Repo.insert!()

    case Keyword.get(opts, :geojson) do
      nil -> :ok
      geojson -> :ok = Geometry.put_geom(area.id, geojson)
    end

    area
  end

  defp insert_area_service(version, name, geojson, key, opts \\ []) do
    service =
      insert_service(version, %{
        "key" => Flex.slugify(name) <> "-#{System.unique_integer([:positive])}",
        "name" => name,
        "kind" => Keyword.get(opts, :kind, "area"),
        "active" => Keyword.get(opts, :active, true),
        "route_id" => "R1"
      })

    insert_area(service, key, 1, geojson: geojson)

    service
  end

  defp rename_area(service, key, name) do
    from(a in FlexArea,
      where: a.flex_service_id == ^service.id and a.key == ^key
    )
    |> Repo.one!()
    |> Ecto.Changeset.change(name: name)
    |> Repo.update!()
  end

  defp insert_route(version, route_id, opts \\ []) do
    route_fixture(version.organization_id, version.id, %{
      route_id: route_id,
      continuous_pickup: Keyword.get(opts, :continuous_pickup, 1),
      continuous_drop_off: Keyword.get(opts, :continuous_drop_off, 1)
    })
  end

  defp insert_trip(version, route_id, trip_id) do
    trip_fixture(version.organization_id, version.id, route_id, %{
      trip_id: trip_id,
      service_id: "weekday"
    })
  end

  defp insert_stop(version, stop_id, lon, lat) do
    stop_fixture(version.organization_id, version.id, %{
      stop_id: stop_id,
      stop_lon: lon && Decimal.new(lon),
      stop_lat: lat && Decimal.new(lat)
    })
  end

  defp insert_calendar(version, service_id) do
    calendar_fixture(version.organization_id, version.id, %{service_id: service_id})

    version
  end

  defp insert_booking_rule(version, booking_rule_id) do
    %BookingRule{organization_id: version.organization_id, gtfs_version_id: version.id}
    |> BookingRule.changeset(%{booking_rule_id: booking_rule_id, booking_type: 0})
    |> Repo.insert!()
  end

  defp hours(service_id, start, finish, area_key \\ nil) do
    %{"service_id" => service_id, "start" => start, "end" => finish, "area_key" => area_key}
  end

  defp checks(service, version, others \\ []) do
    Checks.run(reload(service), Checks.version_facts(version.organization_id, version.id), others)
  end

  defp checks_for(service, version, section, field, opts \\ []) do
    service
    |> checks(version, Keyword.get(opts, :others, []))
    |> Enum.filter(&(&1.section == section and &1.field == field))
  end

  defp reload(%FlexService{id: id} = service) when is_binary(id),
    do: Repo.preload(service, :areas, force: true)

  defp reload(service), do: service

  defp ready_service do
    %FlexService{
      active: true,
      riders: :anyone,
      include_registered: false,
      areas: [],
      hours: [],
      booking_rules: []
    }
  end

  defp check(level), do: %{level: level, section: :booking, field: :note, text: "text"}

  defp shift_east(%{"type" => "Polygon", "coordinates" => [ring]} = geojson, degrees) do
    %{geojson | "coordinates" => [Enum.map(ring, fn [lon, lat] -> [lon + degrees, lat] end)]}
  end
end
