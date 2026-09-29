defmodule GtfsPlannerWeb.Gtfs.TimetablePasteLiveTest do
  # Step 21: the Paste timetable page shell — its schedule line, its URL
  # canonicalization and its setup empty states.
  #
  # Mount-time patches are consumed by live/2, so a canonicalization is
  # observed by following a non-canonical path through the client with
  # render_patch/2.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "paste-live-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "paste-live-#{System.unique_integer([:positive])}@example.com"})

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

  defp paste_path(version, route, query \\ %{}) do
    path = "/gtfs/#{version.id}/routes/#{route.route_id}/schedules/paste"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  # The client follows one server patch. `render_patch/2` re-renders the view at
  # the path and leaves its own patch message in the mailbox.
  defp follow(view, path) do
    html = render_patch(view, path)
    assert_patched(view, path)
    html
  end

  defp weekly_calendar(organization, version, service_id, name) do
    calendar_fixture(organization.id, version.id, %{service_id: service_id})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name,
      service_schedule_name: name
    })

    service_id
  end

  # One route with a Weekday calendar, an outbound pattern with trips and an
  # inbound pattern without trips.
  defp paste_route(%{organization: organization, version: version}) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "PASTE1",
        route_short_name: "12",
        route_long_name: "Downtown – Riverside"
      })

    weekday = weekly_calendar(organization, version, "PASTE_WKD", "Weekday")

    Enum.each(1..3, fn index ->
      stop_fixture(organization.id, version.id, %{
        stop_id: "PASTE_S#{index}",
        stop_name: "Paste Stop #{index}"
      })
    end)

    main =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "PASTE-MAIN",
        route_pattern_name: "Main",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"PASTE_S1", 0, 0, 1},
          {"PASTE_S2", 300, 360, 1},
          {"PASTE_S3", 660, 720, 1}
        ]
      })

    schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
      service_id: weekday,
      trip_id: "PASTE_T0600",
      start_time: "06:00:00",
      trip_headsign: "Riverside Terminal"
    })

    schedule_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      direction_id: 1,
      route_pattern_id: "PASTE-INBOUND",
      route_pattern_name: "Return",
      route_pattern_typicality: 1,
      timing_name: "Standard",
      stops: [
        {"PASTE_S3", 0, 0, 1},
        {"PASTE_S1", 1500, 1500, 1}
      ]
    })

    %{route: route, weekday: weekday, main: main}
  end

  describe "page shell" do
    setup :editor_scope

    test "a bare URL renders the schedule line and canonicalizes the scope",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))

      canonical =
        paste_path(version, paste.route, %{
          "service_id" => paste.weekday,
          "direction" => "0",
          "pattern" => paste.main.pattern.id
        })

      _html = follow(view, canonical)

      assert has_element?(view, "#timetable-paste")
      assert has_element?(view, "#paste-title", "Paste timetable")
      assert has_element?(view, "#paste-scope-calendar", "Weekday")
      assert has_element?(view, "#paste-scope-direction", "Outbound")
      assert has_element?(view, "#paste-scope-pattern", "Main")
      assert has_element?(view, "#paste-scope-open", "Change schedule")
      refute has_element?(view, "#paste-setup-empty")
    end

    test "missing, unknown and invalid values are canonicalized with a replace patch",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))

      render_patch(
        view,
        paste_path(version, paste.route, %{
          "service_id" => "missing",
          "direction" => "9"
        })
      )

      requested = assert_patch(view)
      assert requested =~ "service_id=missing"
      assert requested =~ "direction=9"

      canonical = assert_patch(view)

      assert canonical ==
               paste_path(version, paste.route, %{
                 "service_id" => paste.weekday,
                 "direction" => "0",
                 "pattern" => paste.main.pattern.id
               })

      assert has_element?(view, "#paste-scope-calendar", "Weekday")
    end

    test "a direction with no pattern shows the setup empty state with a Patterns link",
         %{conn: conn, organization: organization, version: version} do
      # An outbound-only route: requesting direction 1 leaves no patterns.
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE_NOIN",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE_NI_WKD", "Weekday")

      stop_fixture(organization.id, version.id, %{
        stop_id: "PASTE_NI_S1",
        stop_name: "No Inbound Stop"
      })

      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "PASTE-NI-MAIN",
        route_pattern_name: "Main",
        timing_name: "Standard",
        stops: [{"PASTE_NI_S1", 0, 0, 1}]
      })

      {:ok, view, _html} =
        live(
          conn,
          paste_path(version, route, %{
            "service_id" => weekday,
            "direction" => "1"
          })
        )

      assert has_element?(view, "#paste-scope-direction", "Inbound")
      assert has_element?(view, "#paste-scope-pattern", "None in this direction")
      assert has_element?(view, "#paste-setup-empty", "has no inbound pattern yet")

      assert has_element?(
               view,
               "#paste-setup-empty a[href='/gtfs/#{version.id}/routes/#{route.route_id}/patterns/new']",
               "Create pattern"
             )
    end

    test "a version with no calendars shows the setup empty state with a Calendars link",
         %{conn: conn, organization: organization, version: version} do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE_NOCAL",
          route_short_name: "7",
          route_long_name: "No Calendar Line"
        })

      stop_fixture(organization.id, version.id, %{
        stop_id: "PASTE_NC_S1",
        stop_name: "No Calendar Stop"
      })

      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "PASTE-NC-MAIN",
        route_pattern_name: "Main",
        timing_name: "Standard",
        stops: [{"PASTE_NC_S1", 0, 0, 1}]
      })

      {:ok, view, _html} = live(conn, paste_path(version, route))

      assert has_element?(view, "#paste-scope-calendar", "None yet")
      assert has_element?(view, "#paste-setup-empty", "no calendars yet")

      assert has_element?(
               view,
               "#paste-setup-empty a[href='/gtfs/#{version.id}/calendars/new']",
               "Create calendar"
             )
    end

    test "a foreign route redirects back to Routes with a not-found flash",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)
      missing = %{paste.route | route_id: "PASTE_MISSING"}

      assert {:error, {:live_redirect, %{to: routes_path, flash: flash}}} =
               live(conn, paste_path(version, missing))

      assert routes_path == "/gtfs/#{version.id}/routes"
      assert is_binary(flash)
    end
  end
end
