defmodule GtfsPlanner.Gtfs.SchedulesTest do
  # The scope and outage cases below observe the production adapter resolved from
  # application config, so the module runs without a swapped adapter.
  use GtfsPlanner.DataCase

  import ExUnit.CaptureLog
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

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

  describe "canonical filters" do
    test "the calendar defaults to the most trips on this route, breaking ties by name",
         context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12c"})
      route_fixture(context.organization.id, context.version.id, %{route_id: "12ct"})

      big = weekly_calendar!(context, %{name: "Alpha Big"})
      aardvark = weekly_calendar!(context, %{name: "Aardvark"})
      bluebird = weekly_calendar!(context, %{name: "Bluebird"})

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12c",
          stops: [{"A", 0, 0, 1}]
        })

      for start_time <- ["06:00:00", "07:00:00", "08:00:00"] do
        schedule_trip_fixture(context.organization.id, context.version.id, "12c", bundle, %{
          service_id: big,
          start_time: start_time
        })
      end

      schedule_trip_fixture(context.organization.id, context.version.id, "12c", bundle, %{
        service_id: aardvark,
        start_time: "06:00:00"
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12c", bundle, %{
        service_id: bluebird,
        start_time: "06:00:00"
      })

      assert {:ok, payload} = load(context, "12c", %{})

      # The calendar list is name-ordered, and the count is this route's own.
      assert Enum.map(payload.calendars, &{&1.service_id, &1.route_trip_count}) == [
               {aardvark, 1},
               {big, 3},
               {bluebird, 1}
             ]

      assert payload.filters.service_id == big

      # An explicitly requested calendar is kept even with fewer trips.
      assert {:ok, requested} = load(context, "12c", %{service_id: bluebird})
      assert requested.filters.service_id == bluebird

      # An unknown calendar falls back to the most-trips calendar.
      assert {:ok, fallback} = load(context, "12c", %{service_id: "missing"})
      assert fallback.filters.service_id == big

      # Equal counts break the tie by name through the calendar list order.
      tied_bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12ct",
          stops: [{"A", 0, 0, 1}]
        })

      for service_id <- [bluebird, aardvark] do
        schedule_trip_fixture(context.organization.id, context.version.id, "12ct", tied_bundle, %{
          service_id: service_id,
          start_time: "06:00:00"
        })
      end

      assert {:ok, tied} = load(context, "12ct", %{})
      assert tied.filters.service_id == aardvark
    end

    test "the direction falls back to one with trips, else 0", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12da"})
      route_fixture(context.organization.id, context.version.id, %{route_id: "12db"})
      route_fixture(context.organization.id, context.version.id, %{route_id: "12dc"})
      service = weekly_calendar!(context, %{name: "Direction"})

      in_bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12da",
          direction_id: 1,
          stops: [{"B", 0, 0, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12da", in_bundle, %{
        service_id: service
      })

      both_out =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12db",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}]
        })

      both_in =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12db",
          direction_id: 1,
          stops: [{"B", 0, 0, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12db", both_out, %{
        service_id: service
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12db", both_in, %{
        service_id: service
      })

      # No trips at all falls back to 0.
      assert {:ok, empty_payload} = load(context, "12dc", %{})
      assert empty_payload.filters.direction_id == 0

      # Direction 0 has no trips, so direction 1 wins.
      assert {:ok, in_payload} = load(context, "12da", %{})
      assert in_payload.filters.direction_id == 1

      # Both directions have trips, so 0 wins.
      assert {:ok, both_payload} = load(context, "12db", %{})
      assert both_payload.filters.direction_id == 0

      # A requested direction is kept; an unrepresentable one falls back.
      assert {:ok, requested_zero} = load(context, "12da", %{direction_id: 0})
      assert requested_zero.filters.direction_id == 0

      assert {:ok, requested_one} = load(context, "12db", %{direction_id: "1"})
      assert requested_one.filters.direction_id == 1

      assert {:ok, requested_bogus} = load(context, "12da", %{direction_id: 7})
      assert requested_bogus.filters.direction_id == 1
    end

    test "the pattern filter accepts a UUID or a natural ID and otherwise falls back to all",
         context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12p"})
      service = weekly_calendar!(context, %{name: "Patterns"})

      downtown =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12p",
          direction_id: 0,
          route_pattern_name: "Downtown",
          stops: [{"A", 0, 0, 1}]
        })

      crosstown =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12p",
          direction_id: 0,
          route_pattern_name: "Crosstown",
          stops: [{"B", 0, 0, 1}]
        })

      inbound =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12p",
          direction_id: 1,
          route_pattern_name: "Inbound",
          stops: [{"C", 0, 0, 1}]
        })

      for bundle <- [downtown, crosstown, inbound] do
        schedule_trip_fixture(context.organization.id, context.version.id, "12p", bundle, %{
          service_id: service
        })
      end

      assert {:ok, all} = load(context, "12p", %{})
      assert all.filters.pattern == :all
      assert all.filters.direction_id == 0
      assert length(all.sections) == 2

      assert {:ok, by_uuid} = load(context, "12p", %{pattern: downtown.pattern.id})
      assert by_uuid.filters.pattern == downtown.pattern.id

      assert Enum.map(by_uuid.sections, & &1.pattern.route_pattern_id) == [
               downtown.pattern.route_pattern_id
             ]

      assert {:ok, by_natural_id} =
               load(context, "12p", %{pattern: crosstown.pattern.route_pattern_id})

      assert by_natural_id.filters.pattern == crosstown.pattern.id

      # A pattern of the other direction never resolves.
      assert {:ok, other_direction} = load(context, "12p", %{pattern: inbound.pattern.id})
      assert other_direction.filters.pattern == :all

      assert {:ok, unknown} = load(context, "12p", %{pattern: Ecto.UUID.generate()})
      assert unknown.filters.pattern == :all
    end

    test "stops defaults to timepoints and accepts all", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12st"})
      service = weekly_calendar!(context, %{name: "Stops"})

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12st",
          stops: [{"A", 0, 0, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12st", bundle, %{
        service_id: service
      })

      assert {:ok, default} = load(context, "12st", %{})
      assert default.filters.stops == :timepoints

      assert {:ok, atom_all} = load(context, "12st", %{stops: :all})
      assert atom_all.filters.stops == :all

      assert {:ok, string_all} = load(context, "12st", %{stops: "all"})
      assert string_all.filters.stops == :all

      assert {:ok, garbage} = load(context, "12st", %{stops: "garbage"})
      assert garbage.filters.stops == :timepoints
    end

    test "string keys are accepted so URL params pass straight through", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12k"})
      service = weekly_calendar!(context, %{name: "Keys"})

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12k",
          direction_id: 1,
          stops: [{"A", 0, 0, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12k", bundle, %{
        service_id: service
      })

      assert {:ok, payload} =
               load(context, "12k", %{
                 "service_id" => service,
                 "direction" => "1",
                 "pattern" => bundle.pattern.route_pattern_id,
                 "stops" => "all"
               })

      assert payload.filters == %{
               service_id: service,
               direction_id: 1,
               pattern: bundle.pattern.id,
               stops: :all
             }
    end
  end

  describe "sections over stored stop times" do
    test "orders sections, maps occurrences positionally and keeps custom, loop and frequency shapes",
         context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12s"})

      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "A",
        stop_name: "Alpha"
      })

      stop_fixture(context.organization.id, context.version.id, %{stop_id: "B", stop_name: "Beta"})

      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "C",
        stop_name: "Gamma"
      })

      service = weekly_calendar!(context, %{name: "Sections"})

      downtown =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12s",
          direction_id: 0,
          route_pattern_name: "Downtown",
          route_pattern_sort_order: 0,
          timing_name: "Standard",
          stops: [{"A", 0, 0, 1}, {"B", 300, 300, 0}, {"C", 900, 900, 1}]
        })

      crosstown =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12s",
          direction_id: 0,
          route_pattern_name: "Crosstown",
          route_pattern_sort_order: 1,
          timing_name: "Reverse",
          stops: [{"C", 0, 0, 1}, {"B", 300, 300, 1}, {"A", 900, 900, 1}]
        })

      loop =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12s",
          direction_id: 0,
          route_pattern_name: "Loop",
          route_pattern_sort_order: 2,
          timing_name: "Loop",
          stops: [{"A", 0, 0, 1}, {"B", 300, 300, 1}, {"A", 600, 600, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12s", downtown, %{
        service_id: service,
        trip_id: "12-0-0600",
        start_time: "06:00:00",
        trip_headsign: "Downtown"
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12s", downtown, %{
        service_id: service,
        trip_id: "12-0-0700",
        state: "custom",
        timed_pattern_id: nil,
        stop_times: [
          {"A", "07:00:00", "07:00:00"},
          {"B", "07:05:00", "07:05:00"},
          {"C", "07:15:00", "07:15:00"}
        ]
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12s", downtown, %{
        service_id: service,
        trip_id: "12-0-0730",
        state: "custom",
        timed_pattern_id: nil,
        stop_times: [
          {"A", "07:30:00", "07:30:00"},
          {"Z", "07:35:00", "07:35:00"},
          {"C", "07:45:00", "07:45:00"}
        ]
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12s", downtown, %{
        service_id: service,
        trip_id: "12-0-1000",
        start_time: "10:00:00",
        frequencies: [%{start_time: "09:00:00", end_time: "12:00:00", headway_secs: 1200}]
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12s", crosstown, %{
        service_id: service,
        trip_id: "12-0-0800",
        start_time: "08:00:00"
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12s", loop, %{
        service_id: service,
        trip_id: "12-0-0900",
        start_time: "09:00:00"
      })

      assert {:ok, payload} = load(context, "12s", %{})

      assert Enum.map(payload.sections, & &1.pattern.route_pattern_name) == [
               "Downtown",
               "Crosstown",
               "Loop"
             ]

      downtown_section = section_for(payload, downtown.pattern.route_pattern_id)

      assert Enum.map(downtown_section.rows, & &1.trip_id) == [
               "12-0-0600",
               "12-0-0700",
               "12-0-0730",
               "12-0-1000"
             ]

      # The modal timing "Standard" flags positions 1 and 3 as timepoints, so the
      # timepoints view omits Beta while all stops keeps every occurrence.
      assert Enum.map(downtown_section.all_columns, & &1.stop_id) == ["A", "B", "C"]
      assert Enum.map(downtown_section.columns, & &1.stop_id) == ["A", "C"]
      assert downtown_section.omitted_stop_count == 1

      custom_row = Enum.find(downtown_section.rows, &(&1.trip_id == "12-0-0700"))
      assert custom_row.custom? == true
      assert custom_row.timing == :custom
      assert custom_row.stops_differ? == false
      assert custom_row.cells[1].text == "07:00"

      incompatible_row = Enum.find(downtown_section.rows, &(&1.trip_id == "12-0-0730"))
      assert incompatible_row.stops_differ? == true
      assert incompatible_row.cells == %{}

      frequency_row = Enum.find(downtown_section.rows, &(&1.trip_id == "12-0-1000"))
      assert frequency_row.frequency? == true
      assert frequency_row.frequency_label == "Every 20 min, 09:00–12:00"
      assert frequency_row.timing == "Standard"

      assert downtown_section.custom_trip_count == 2
      assert [%{name: "Standard", trip_count: 2}] = downtown_section.timing_lines

      # Loop occurrences stay separate columns, including the repeated stop.
      loop_section = section_for(payload, loop.pattern.route_pattern_id)
      assert Enum.map(loop_section.all_columns, & &1.position) == [1, 2, 3]
      assert Enum.map(loop_section.all_columns, & &1.stop_id) == ["A", "B", "A"]
      assert Enum.map(loop_section.all_columns, & &1.stop_name) == ["Alpha", "Beta", "Alpha"]

      # The pattern filter narrows the sections to one.
      assert {:ok, filtered} = load(context, "12s", %{pattern: crosstown.pattern.id})
      assert Enum.map(filtered.sections, & &1.pattern.route_pattern_name) == ["Crosstown"]
    end
  end

  describe "planning summary" do
    test "the vehicle count uses half-open spans across both directions and parses 25:xx",
         context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12v"})
      service = weekly_calendar!(context, %{name: "Vehicles"})

      outbound =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12v",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}, {"B", 1800, 1800, 1}]
        })

      inbound =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12v",
          direction_id: 1,
          stops: [{"C", 0, 0, 1}, {"D", 1800, 1800, 1}]
        })

      for {bundle, start_time} <- [
            {outbound, "06:00:00"},
            {outbound, "06:15:00"},
            {outbound, "25:10:00"},
            {inbound, "06:15:00"}
          ] do
        schedule_trip_fixture(context.organization.id, context.version.id, "12v", bundle, %{
          service_id: service,
          start_time: start_time
        })
      end

      assert {:ok, payload} = load(context, "12v", %{})

      # 06:00–06:30, 06:15–06:45 and 06:15–06:45 overlap at 06:15; the 25:10 trip
      # is parsed numerically, not as a string.
      assert payload.summary.vehicles == %{count: 3, at_secs: 22_500}
      assert payload.summary.incomplete_trip_count == 0
    end

    test "frequency templates expand by headway for the vehicle count and trips per hour",
         context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12f"})
      service = weekly_calendar!(context, %{name: "Frequency"})

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12f",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}, {"B", 300, 300, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12f", bundle, %{
        service_id: service,
        start_time: "09:00:00",
        frequencies: [%{start_time: "09:00:00", end_time: "10:00:00", headway_secs: 600}]
      })

      assert {:ok, payload} = load(context, "12f", %{})

      # Six 5-minute departures at 09:00 … 09:50 never overlap, and the template's
      # own stored start is not counted twice.
      assert payload.summary.vehicles == %{count: 1, at_secs: 32_400}
      assert payload.summary.trips_per_hour == [{9, 6, true}]
    end

    test "incomplete trips are excluded from every summary and counted", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12i"})
      service = weekly_calendar!(context, %{name: "Incomplete"})

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12i",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}, {"B", 600, 600, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12i", bundle, %{
        service_id: service,
        start_time: "25:10:00"
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12i", bundle, %{
        service_id: service,
        state: "custom",
        timed_pattern_id: nil,
        stop_times: [{"A", "06:00:00", "06:00:00"}, {"B", nil, nil}]
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12i", bundle, %{
        service_id: service,
        state: "custom",
        timed_pattern_id: nil,
        stop_times: [{"A", "06:10:00", "06:10:00"}, {"B", "not-a-time", "not-a-time"}]
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12i", bundle, %{
        service_id: service,
        state: "custom",
        timed_pattern_id: nil,
        stop_times: []
      })

      assert {:ok, payload} = load(context, "12i", %{})

      assert payload.summary.incomplete_trip_count == 3
      assert payload.summary.vehicles == %{count: 1, at_secs: 90_600}
      assert payload.summary.trips_per_hour == [{25, 1, false}]
    end

    test "trips per hour includes zero hours and hours at or beyond 24", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12h"})
      service = weekly_calendar!(context, %{name: "Hours"})

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12h",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}, {"B", 60, 60, 1}]
        })

      for start_time <- ["05:00:00", "07:00:00", "25:00:00"] do
        schedule_trip_fixture(context.organization.id, context.version.id, "12h", bundle, %{
          service_id: service,
          start_time: start_time
        })
      end

      assert {:ok, payload} = load(context, "12h", %{})

      assert Enum.map(payload.summary.trips_per_hour, &elem(&1, 0)) == Enum.to_list(5..25)
      assert Enum.at(payload.summary.trips_per_hour, 0) == {5, 1, false}
      assert Enum.at(payload.summary.trips_per_hour, 1) == {6, 0, false}
      assert List.last(payload.summary.trips_per_hour) == {25, 1, false}
    end

    test "unlinked trips are counted but never placed in a section", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12u"})
      service = weekly_calendar!(context, %{name: "Unlinked"})

      outbound =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12u",
          direction_id: 0,
          route_pattern_name: "Out",
          stops: [{"A", 0, 0, 1}]
        })

      inbound =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12u",
          direction_id: 1,
          route_pattern_name: "In",
          stops: [{"B", 0, 0, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12u", outbound, %{
        service_id: service
      })

      schedule_trip_fixture(context.organization.id, context.version.id, "12u", inbound, %{
        service_id: service
      })

      # A nil pattern, a dangling pattern, a pattern of the other direction and a
      # nil direction.
      for attrs <- [
            %{route_pattern_id: nil},
            %{route_pattern_id: "dangling_pattern"},
            %{direction_id: 1},
            %{direction_id: nil}
          ] do
        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          "12u",
          outbound,
          Map.merge(%{service_id: service, state: "custom", timed_pattern_id: nil}, attrs)
        )
      end

      assert {:ok, payload} = load(context, "12u", %{})

      assert payload.filters.direction_id == 0
      assert payload.unlinked_trip_count == 4
      assert length(Enum.flat_map(payload.sections, & &1.rows)) == 1

      # The same trips stay unlinked whichever direction is in view.
      assert {:ok, inbound_view} = load(context, "12u", %{direction_id: 1})
      assert inbound_view.unlinked_trip_count == 4
      assert length(Enum.flat_map(inbound_view.sections, & &1.rows)) == 1
    end

    test "direction labels use the most common headsign or the neutral fallback", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12l"})
      service = weekly_calendar!(context, %{name: "Labels"})

      outbound =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12l",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}]
        })

      for {start_time, headsign} <- [
            {"06:00:00", "Downtown"},
            {"07:00:00", "Downtown"},
            {"08:00:00", "Airport"}
          ] do
        schedule_trip_fixture(context.organization.id, context.version.id, "12l", outbound, %{
          service_id: service,
          start_time: start_time,
          trip_headsign: headsign
        })
      end

      assert {:ok, payload} = load(context, "12l", %{})

      assert payload.direction_labels[0] == "To Downtown"
      assert payload.direction_labels[1] == "Direction 1"
      assert payload.block_suggestions == []
    end
  end

  describe "calendars in the version" do
    test "an unused dates-only calendar is selectable on a zero-trip route", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12z"})

      first = weekly_calendar!(context, %{name: "Aardvark"})
      second = dates_only_calendar!(context, %{name: "Bluebird"})

      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: "12z",
        stops: [{"A", 0, 0, 1}]
      })

      assert {:ok, payload} = load(context, "12z", %{})

      # A route with no trips resolves to the first calendar in list order.
      assert payload.filters.service_id == first
      assert Enum.map(payload.calendars, & &1.service_id) == [first, second]

      assert Enum.map(payload.calendars, &{&1.service_id, &1.kind}) == [
               {first, :weekly},
               {second, :dates_only}
             ]

      assert Enum.all?(payload.calendars, &(&1.route_trip_count == 0))
      assert payload.sections == []

      assert {:ok, selected} = load(context, "12z", %{service_id: second})
      assert selected.filters.service_id == second

      assert selected.summary == %{
               vehicles: %{count: 0, at_secs: nil},
               trips_per_hour: [],
               incomplete_trip_count: 0
             }

      # The unused calendar can still take the route's first trip on this pattern.
      assert [%{route_pattern_id: route_pattern_id}] = selected.patterns
      assert is_binary(route_pattern_id)
    end

    test "a version with no calendars yields the no-calendars inputs", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12n"})

      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: "12n",
        stops: [{"A", 0, 0, 1}]
      })

      assert {:ok, payload} = load(context, "12n", %{})

      assert payload.calendars == []
      assert payload.filters.service_id == nil
      assert payload.filters.direction_id == 0
      assert payload.sections == []
      assert payload.unlinked_trip_count == 0

      assert payload.summary == %{
               vehicles: %{count: 0, at_secs: nil},
               trips_per_hour: [],
               incomplete_trip_count: 0
             }

      assert length(payload.patterns) == 1
      assert payload.patterns |> hd() |> Map.fetch!(:timings) |> length() == 1
    end
  end

  describe "trip audit" do
    test "rollback refuses a trip log and the allowlist admits only the snapshot and operation",
         context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12a"})

      trip =
        trip_fixture(context.organization.id, context.version.id, "12a", %{
          trip_id: "12-0-audit",
          service_id: "svc_audit"
        })

      operation_id = Ecto.UUID.generate()

      assert {:ok, deleted_log} =
               Repo.transaction(fn ->
                 {:ok, log} =
                   Gtfs.record_change_in_transaction(context.audit, :trip, trip, "deleted", %{
                     before: %{"trip_id" => trip.trip_id, "start_time" => "06:00:00"},
                     operation_id: operation_id,
                     affected_trip_ids: [trip.id]
                   })

                 log
               end)

      assert %ChangeLog{} = deleted_log
      assert deleted_log.entity_type == "trip"
      assert deleted_log.entity_id == trip.id
      assert deleted_log.entity_external_id == trip.trip_id
      assert deleted_log.action == "deleted"

      assert deleted_log.changed_fields == %{
               "before" => %{"trip_id" => trip.trip_id, "start_time" => "06:00:00"},
               "after" => nil,
               "operation_id" => operation_id,
               "affected_trip_ids" => [trip.id]
             }

      assert Gtfs.rollback_entity(deleted_log, context.audit) == {:error, :audit_only_entity}
      assert Gtfs.rollback_target_snapshot(deleted_log) == {:error, :audit_only_entity}

      assert {:ok, updated_log} =
               Repo.transaction(fn ->
                 {:ok, log} =
                   Gtfs.record_change_in_transaction(context.audit, :trip, trip, "updated", %{
                     before: %{"trip_headsign" => "Old"},
                     after: %{"trip_headsign" => "New"},
                     operation_id: operation_id,
                     affected_trip_ids: [trip.id],
                     trip_headsign: "New",
                     stop_time_count: 5
                   })

                 log
               end)

      # The trip allowlist keeps only the explicit snapshot and operation keys; no
      # trip column is diffed field-by-field.
      assert Map.keys(updated_log.changed_fields) |> MapSet.new() ==
               MapSet.new(["before", "after", "operation_id", "affected_trip_ids"])

      refute Map.has_key?(updated_log.changed_fields, "trip_headsign")
      refute Map.has_key?(updated_log.changed_fields, "stop_time_count")

      assert updated_log.changed_fields["before"] == %{"trip_headsign" => "Old"}
      assert updated_log.changed_fields["after"] == %{"trip_headsign" => "New"}

      assert Gtfs.rollback_entity(updated_log, context.audit) == {:error, :audit_only_entity}
      assert Gtfs.rollback_target_snapshot(updated_log) == {:error, :audit_only_entity}
    end
  end

  describe "scope and outage" do
    test "foreign, unknown and unpublished scopes return not_found", context do
      route_fixture(context.organization.id, context.version.id, %{route_id: "12o"})
      service = weekly_calendar!(context, %{name: "Scope"})

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12o",
          stops: [{"A", 0, 0, 1}]
        })

      schedule_trip_fixture(context.organization.id, context.version.id, "12o", bundle, %{
        service_id: service
      })

      other_organization = organization_fixture()

      assert {:error, :not_found} =
               Gtfs.load_route_schedule(other_organization.id, context.version.id, "12o", %{})

      assert {:error, :not_found} =
               Gtfs.load_route_schedule(
                 context.organization.id,
                 Ecto.UUID.generate(),
                 "12o",
                 %{}
               )

      assert {:error, :not_found} =
               Gtfs.load_route_schedule(
                 context.organization.id,
                 context.version.id,
                 "unknown_route",
                 %{}
               )

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      route_fixture(context.organization.id, staging.id, %{route_id: "12stg"})

      assert {:error, :not_found} =
               Gtfs.load_route_schedule(context.organization.id, staging.id, "12stg", %{})
    end

    test "a lost database connection through the production adapter is unavailable", context do
      with_unreachable_repo(fn ->
        capture_log(fn ->
          assert Gtfs.load_route_schedule(
                   context.organization.id,
                   context.version.id,
                   "12o",
                   %{}
                 ) == {:error, :unavailable}
        end)
      end)
    end

    test "the facade read runs on the real Repo adapter and holds the version FOR SHARE" do
      assert Application.get_env(:gtfs_planner, :gtfs_catalog_read_adapter) in [
               nil,
               CatalogReadAdapter.Repo
             ]

      # The version row must be committed before a second session can lock it, so
      # this one scope is seeded outside the sandbox and removed on exit.
      lock_scope = seed_committed_lock_scope()
      on_exit(fn -> cleanup_committed_lock_scope(lock_scope) end)

      # Control: with no read transaction open, the same probe does take the row.
      assert {:ok, %{rows: [[_id]]}} = probe_version_lock(lock_scope.version.id)

      assert {:ok, payload} =
               Repo.transaction(fn ->
                 assert {:ok, payload} =
                          Gtfs.load_route_schedule(
                            lock_scope.organization.id,
                            lock_scope.version.id,
                            "12lock",
                            %{}
                          )

                 # The read transaction took the version row FOR SHARE through
                 # `Calendars.list_calendars/3` and still holds it, so a cooperating
                 # calendar write cannot take it meanwhile.
                 assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
                          probe_version_lock(lock_scope.version.id)

                 payload
               end)

      assert payload.route.route_id == "12lock"
      assert payload.calendars == []
      assert payload.filters.direction_id == 0
    end
  end

  defp load(context, route_id, filters) do
    Gtfs.load_route_schedule(context.organization.id, context.version.id, route_id, filters)
  end

  defp section_for(payload, route_pattern_id) do
    Enum.find(payload.sections, &(&1.pattern.route_pattern_id == route_pattern_id))
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

  defp weekly_calendar!(context, attrs) do
    attrs =
      Map.merge(
        %{
          service_id: "wk_#{System.unique_integer([:positive])}",
          name: "Weekday #{System.unique_integer([:positive])}",
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
        },
        Map.new(attrs)
      )

    assert {:ok, _payload} = Gtfs.create_calendar(attrs, context.audit)
    attrs.service_id
  end

  defp dates_only_calendar!(context, attrs) do
    attrs =
      Map.merge(
        %{
          service_id: "dt_#{System.unique_integer([:positive])}",
          name: "Dates Only #{System.unique_integer([:positive])}",
          kind: :dates_only,
          dates: [~D[2026-07-04]]
        },
        Map.new(attrs)
      )

    assert {:ok, _payload} = Gtfs.create_calendar(attrs, context.audit)
    attrs.service_id
  end

  # A committed published version and route: the read lock under test is taken on
  # the version row, so it must be visible to an independent session.
  defp seed_committed_lock_scope do
    unboxed(fn ->
      organization =
        organization_fixture(%{
          alias: "schedule-read-lock-#{System.unique_integer([:positive])}"
        })

      version = gtfs_version_fixture(organization.id)
      route_fixture(organization.id, version.id, %{route_id: "12lock"})

      %{organization: organization, version: version}
    end)
  end

  defp cleanup_committed_lock_scope(scope) do
    unboxed(fn ->
      Repo.delete_all(from(r in Route, where: r.organization_id == ^scope.organization.id))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^scope.organization.id))
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization.id))
      :ok
    end)
  end

  # Probes the version row from an independent committing connection. `NOWAIT`
  # resolves immediately instead of waiting, so the assertion stays deterministic.
  defp probe_version_lock(version_id) do
    Task.async(fn ->
      unboxed(fn ->
        Repo.query(
          "select id from gtfs_versions where id = $1::uuid for update nowait",
          [Ecto.UUID.dump!(version_id)]
        )
      end)
    end)
    |> Task.await(5_000)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp with_unreachable_repo(fun) do
    pid =
      start_supervised!(
        {GtfsPlanner.Repo,
         name: nil,
         hostname: "127.0.0.1",
         port: 1,
         username: "postgres",
         password: "postgres",
         database: "gtfs_planner_unreachable",
         pool: DBConnection.ConnectionPool,
         pool_size: 1,
         queue_target: 20,
         queue_interval: 20,
         connect_timeout: 100,
         log: false}
      )

    previous = GtfsPlanner.Repo.get_dynamic_repo()
    GtfsPlanner.Repo.put_dynamic_repo(pid)

    try do
      fun.()
    after
      GtfsPlanner.Repo.put_dynamic_repo(previous)
    end
  end
end
