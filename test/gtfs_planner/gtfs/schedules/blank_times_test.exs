defmodule GtfsPlanner.Gtfs.Schedules.BlankTimesTest do
  # EV-7: Schedules reads a stop with no scheduled time as absence. A blank is
  # never 0 and never an estimate: the summary's arithmetic uses the timed rows
  # only, a timetable cell carries the muted label, and the route's Schedules
  # page shows that label instead of a time of day.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Gtfs.Schedules.Timetable

  # A five stop timing whose interior rows 2 to 4 have no scheduled time. Only the
  # first and last stop are timepoints, so the blanks are legal under rule 1.
  @blank_timing_rows [
    %{position: 1, arrival_offset: 0, departure_offset: 0, timepoint: 1},
    %{position: 2, arrival_offset: nil, departure_offset: nil, timepoint: 0},
    %{position: 3, arrival_offset: nil, departure_offset: nil, timepoint: 0},
    %{position: 4, arrival_offset: nil, departure_offset: nil, timepoint: 0},
    %{position: 5, arrival_offset: 900, departure_offset: 900, timepoint: 1}
  ]

  @columns [%{position: 1}, %{position: 2}, %{position: 3}, %{position: 4}, %{position: 5}]

  describe "Summary.timing_segments/2 with blank rows" do
    test "a blank at rows 2 to 4 gives a total of the last arrival minus the first departure" do
      assert Summary.timing_segments(@blank_timing_rows, @columns) ==
               %{segments: [900], total_secs: 900}
    end

    test "between-stop values span from the timed row before a blank to the one after it" do
      rows = [
        %{position: 1, arrival_offset: 0, departure_offset: 120},
        %{position: 2, arrival_offset: nil, departure_offset: nil},
        %{position: 3, arrival_offset: 600, departure_offset: 660}
      ]

      # The blank row leaves one segment, measured from stop 1's departure
      # across it to stop 3's arrival, and the total keeps stop 1's dwell.
      assert Summary.timing_segments(rows, [%{position: 1}, %{position: 2}, %{position: 3}]) ==
               %{segments: [480], total_secs: 480}
    end

    test "a blank-only timing has no segments and no total, and does not raise" do
      rows = [
        %{position: 1, arrival_offset: nil, departure_offset: nil},
        %{position: 2, arrival_offset: nil, departure_offset: nil}
      ]

      assert Summary.timing_segments(rows, [%{position: 1}, %{position: 2}]) ==
               %{segments: [], total_secs: 0}
    end

    test "a half-timed row is skipped like a blank one rather than read as zero" do
      rows = [
        %{position: 1, arrival_offset: 0, departure_offset: 0},
        %{position: 2, arrival_offset: 240, departure_offset: nil},
        %{position: 3, arrival_offset: 600, departure_offset: 600}
      ]

      assert Summary.timing_segments(rows, [%{position: 1}, %{position: 2}, %{position: 3}]) ==
               %{segments: [600], total_secs: 600}
    end

    test "columns with no timing row at all are still ignored" do
      assert Summary.timing_segments([hd(@blank_timing_rows)], @columns) ==
               %{segments: [], total_secs: 0}
    end
  end

  describe "Timetable.build/5 with blank stop times" do
    test "a row's blank cells carry the label, and the timing line needs no raise" do
      section =
        Timetable.build(
          %{headsign: "Downtown"},
          occurrences(),
          stops_by_id(),
          [%{id: "timing-1", name: "Standard", headsign: nil, rows: @blank_timing_rows}],
          [
            trip_fields("BLANK-0700", %{
              timed_pattern_id: "timing-1",
              stop_times: blank_stop_times()
            })
          ]
        )

      cells = Enum.at(section.rows, 0).cells

      assert Map.fetch!(cells, 1).text == "07:00"

      assert Enum.map([2, 3, 4], &Map.fetch!(cells, &1)) |> Enum.map(& &1.text) ==
               ["No scheduled time", "No scheduled time", "No scheduled time"]

      assert Enum.all?([2, 3, 4], &Map.fetch!(cells, &1).missing?)
      assert Map.fetch!(cells, 5).text == "07:15"
      refute Map.fetch!(cells, 5).missing?

      assert Enum.map(section.timing_lines, & &1.total_secs) == [900]
      assert Enum.map(section.timing_lines, & &1.segments) == [[900]]
    end

    test "an unparseable stored time still reads as the em dash glyph, not the label" do
      section =
        Timetable.build(
          %{headsign: "Downtown"},
          occurrences(),
          stops_by_id(),
          [],
          [
            trip_fields(
              "BAD-0700",
              %{
                stop_times: [
                  stop_time(1, "S1", "07:00:00"),
                  stop_time(2, "S2", "not-a-time"),
                  stop_time(3, "S3", "07:10:00"),
                  stop_time(4, "S4", "07:12:00"),
                  stop_time(5, "S5", "07:15:00")
                ]
              }
            )
          ]
        )

      cells = Enum.at(section.rows, 0).cells

      assert Map.fetch!(cells, 2).text == "—"
      assert Map.fetch!(cells, 2).missing?
      assert Map.fetch!(cells, 3).text == "07:10"
    end
  end

  describe "Route Schedules for a route with blank stops" do
    setup :editor_scope

    test "a blank stop reads as no scheduled time, never 0:00",
         %{conn: conn, version: version} = context do
      route = blank_route(context)

      {:ok, view, _html} =
        live(conn, schedules_path(version, route.route, %{"stops" => "all"}))

      assert has_element?(view, "#section-#{route.pattern.pattern.route_pattern_id}")
      assert has_element?(view, "#trip-BLK_T0700", "No scheduled time")
      refute has_element?(view, "#trip-BLK_T0700", "0:00")

      # The summary's arithmetic is the same: one segment spanning the blanks and
      # the last arrival less the first departure as its total.
      assert has_element?(
               view,
               "#section-#{route.pattern.pattern.route_pattern_id}-timing-detail",
               "15 min total"
             )
    end
  end

  # --- route fixtures --------------------------------------------------------

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "schedules-blank-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "schedules-blank-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  defp schedules_path(version, route, query) do
    path = "/gtfs/#{version.id}/routes/#{route.route_id}/schedules"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  # One route, one weekly calendar, one pattern whose interior stops have no
  # scheduled time, and one linked trip materialized with the same blanks.
  defp blank_route(%{organization: organization, version: version}) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "BLK",
        route_short_name: "B1",
        route_long_name: "Blanks"
      })

    service_id = "BLK_WKD"

    calendar_fixture(organization.id, version.id, %{service_id: service_id})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: "Weekday",
      service_schedule_name: "Weekday"
    })

    Enum.each(1..5, fn index ->
      stop_fixture(organization.id, version.id, %{
        stop_id: "BLK_S#{index}",
        stop_name: "Blank Stop #{index}"
      })
    end)

    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "BLK-P1",
        route_pattern_name: "Downtown",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"BLK_S1", 0, 0, 1},
          {"BLK_S2", nil, nil, 0},
          {"BLK_S3", nil, nil, 0},
          {"BLK_S4", nil, nil, 0},
          {"BLK_S5", 900, 900, 1}
        ]
      })

    schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
      service_id: service_id,
      trip_id: "BLK_T0700",
      start_time: "07:00:00",
      trip_headsign: "Downtown",
      stop_times: [
        {"BLK_S1", "07:00:00", "07:00:00"},
        {"BLK_S2", nil, nil},
        {"BLK_S3", nil, nil},
        {"BLK_S4", nil, nil},
        {"BLK_S5", "07:15:00", "07:15:00"}
      ]
    })

    %{route: route, pattern: pattern}
  end

  # --- view model fixtures ---------------------------------------------------

  defp occurrences do
    for position <- 1..5,
        do: %{id: "occ-#{position}", position: position, stop_id: "S#{position}"}
  end

  defp stops_by_id do
    Map.new(for position <- 1..5, do: {"S#{position}", stop(position)})
  end

  defp stop(position),
    do: %{stop_name: "Stop #{position}", stop_code: "#{position}"}

  defp blank_stop_times do
    [
      stop_time(1, "S1", "07:00:00"),
      stop_time(2, "S2", nil),
      stop_time(3, "S3", nil),
      stop_time(4, "S4", nil),
      stop_time(5, "S5", "07:15:00")
    ]
  end

  defp stop_time(sequence, stop_id, time) do
    %{
      id: "st-#{sequence}",
      stop_sequence: sequence,
      stop_id: stop_id,
      arrival_time: time,
      departure_time: time
    }
  end

  defp trip_fields(trip_id, attrs) do
    Map.merge(
      %{
        id: "uuid-" <> trip_id,
        trip_id: trip_id,
        timed_pattern_id: nil,
        pattern_derivation_state: "custom",
        trip_headsign: nil,
        trip_short_name: nil,
        block_id: nil,
        updated_at: nil,
        frequencies: [],
        stop_times: []
      },
      attrs
    )
  end
end
