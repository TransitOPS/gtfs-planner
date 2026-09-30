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

  defp dates_only_calendar(organization, version, service_id, name) do
    calendar_date_fixture(organization.id, version.id, %{
      service_id: service_id,
      date: ~D[2026-07-04],
      exception_type: 1
    })

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name,
      service_schedule_name: name
    })

    service_id
  end

  # One route with a Weekday calendar, an unused dates-only calendar, an
  # outbound pattern with trips and an inbound pattern without trips.
  defp paste_route(%{organization: organization, version: version}) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "PASTE1",
        route_short_name: "12",
        route_long_name: "Downtown – Riverside"
      })

    weekday = weekly_calendar(organization, version, "PASTE_WKD", "Weekday")
    special = dates_only_calendar(organization, version, "PASTE_SPECIAL", "Special")

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

    inbound =
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

    %{route: route, weekday: weekday, special: special, main: main, inbound: inbound}
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

  describe "scope drawer" do
    # Step 22: the Change schedule drawer — its fields, its direction
    # refiltering and its patch that keeps the paste. The paste itself is
    # still blank (step 23 owns the timetable step), so the review re-runs
    # to nil and the rebuild warning stays hidden; the positive-text and
    # warning cases land with step 23's textarea.
    setup :editor_scope

    defp open_drawer(view) do
      view |> element("#paste-scope-open") |> render_click()
    end

    defp draft_params(params) do
      %{"scope" => params}
    end

    test "opening the drawer offers every calendar, labelled directions and the direction patterns with trip counts",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))

      _html =
        follow(
          view,
          paste_path(version, paste.route, %{
            "service_id" => paste.weekday,
            "direction" => "0",
            "pattern" => paste.main.pattern.id
          })
        )

      open_drawer(view)

      assert has_element?(view, "#paste-scope-drawer-overlay[data-open='true']")

      assert has_element?(
               view,
               "#paste-scope-drawer-overlay[data-return-focus-id='paste-scope-open']"
             )

      assert has_element?(view, "#paste-scope-form")
      assert has_element?(view, "#paste-scope-drawer", "Route 12")
      assert has_element?(view, "#paste-scope-drawer", "the trips your paste adds")

      assert has_element?(
               view,
               "#paste-scope-calendar-field option[value='#{paste.weekday}']",
               "Weekday"
             )

      assert has_element?(
               view,
               "#paste-scope-calendar-field option[value='#{paste.special}']",
               "Specific dates"
             )

      assert has_element?(view, "#paste-scope-direction-field-0")
      assert has_element?(view, "#paste-scope-direction-field-1")

      assert has_element?(
               view,
               "#paste-scope-direction-field",
               "Outbound · to Riverside Terminal"
             )

      assert has_element?(view, "#paste-scope-direction-field", "Inbound")

      assert has_element?(
               view,
               "#paste-scope-pattern-field option[value='#{paste.main.pattern.id}']",
               "Main · 1 trip"
             )

      refute has_element?(view, "#paste-scope-pattern-field option", "Return")
      refute has_element?(view, "#paste-scope-rebuild-warning")
    end

    test "changing the direction refilters the pattern options and reselects",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))

      _html =
        follow(
          view,
          paste_path(version, paste.route, %{
            "service_id" => paste.weekday,
            "direction" => "0",
            "pattern" => paste.main.pattern.id
          })
        )

      open_drawer(view)

      render_change(
        view,
        "scope_draft_change",
        draft_params(%{
          "service_id" => paste.weekday,
          "direction" => "1",
          "pattern" => paste.main.pattern.id
        })
      )

      assert has_element?(
               view,
               "#paste-scope-pattern-field option[value='#{paste.inbound.pattern.id}']",
               "Return · 0 trips"
             )

      refute has_element?(view, "#paste-scope-pattern-field option", "Main")
      assert has_element?(view, "#paste-scope-drawer", "another inbound pattern")
    end

    test "using a schedule patches the URL, rebuilds the scope and closes the drawer",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))

      _html =
        follow(
          view,
          paste_path(version, paste.route, %{
            "service_id" => paste.weekday,
            "direction" => "0",
            "pattern" => paste.main.pattern.id
          })
        )

      open_drawer(view)

      render_submit(
        view,
        "change_schedule",
        draft_params(%{
          "service_id" => paste.weekday,
          "direction" => "1",
          "pattern" => paste.inbound.pattern.id
        })
      )

      inbound_path =
        paste_path(version, paste.route, %{
          "service_id" => paste.weekday,
          "direction" => "1",
          "pattern" => paste.inbound.pattern.id
        })

      assert_patch(view, inbound_path)
      _html = follow(view, inbound_path)

      assert has_element?(view, "#paste-scope-direction", "Inbound")
      assert has_element?(view, "#paste-scope-pattern", "Return")
      assert has_element?(view, "#paste-scope-drawer-overlay[data-open='false']")
      refute has_element?(view, "#paste-scope-form")
      refute has_element?(view, "#paste-scope-rebuild-warning")

      # The rebuilt scope drafts cleanly: reopening offers the new schedule.
      open_drawer(view)
      assert has_element?(view, "#paste-scope-drawer-overlay[data-open='true']")

      assert has_element?(
               view,
               "#paste-scope-pattern-field option[value='#{paste.inbound.pattern.id}']",
               "Return · 0 trips"
             )
    end

    test "closing the drawer discards the draft without changing the scope",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))

      _html =
        follow(
          view,
          paste_path(version, paste.route, %{
            "service_id" => paste.weekday,
            "direction" => "0",
            "pattern" => paste.main.pattern.id
          })
        )

      open_drawer(view)

      render_change(
        view,
        "scope_draft_change",
        draft_params(%{
          "service_id" => paste.weekday,
          "direction" => "1",
          "pattern" => paste.inbound.pattern.id
        })
      )

      render_click(view, "close_scope_drawer")

      assert has_element?(view, "#paste-scope-drawer-overlay[data-open='false']")
      assert has_element?(view, "#paste-scope-direction", "Outbound")
      assert has_element?(view, "#paste-scope-pattern", "Main")
    end
  end

  describe "timetable step" do
    # Step 23: the paste form textarea, hint, Layout disclosure, Read
    # timetable, inline errors and the collapsed summary. Reads go through
    # `Gtfs.prepare_timetable_paste/5` with the full current input; failures
    # keep the text and name the fix; success collapses the step and
    # auto-advances to the review placeholder when no column issues remain
    # (the columns/review UI lands in steps 24-28, so the placeholders mark
    # their seams). This describe also covers step 22's deferred asks: a
    # real paste surviving the schedule-change patch and the rebuild warning
    # with a review in place.
    setup :editor_scope

    defp canonical_path(view, version, route, paste) do
      follow(
        view,
        paste_path(version, route, %{
          "service_id" => paste.weekday,
          "direction" => "0",
          "pattern" => paste.main.pattern.id
        })
      )
    end

    defp exact_text do
      "Trip\tPaste Stop 1\tPaste Stop 2\tPaste Stop 3\n" <>
        "101\t06:00\t06:05\t06:10\n102\t07:00\t07:05\t07:10"
    end

    defp read_params(overrides \\ %{}) do
      %{
        "paste" =>
          Map.merge(
            %{"text" => exact_text(), "layout" => "auto", "header" => "true"},
            overrides
          )
      }
    end

    defp read(view, overrides \\ %{}) do
      render_submit(view, "read", read_params(overrides))
    end

    test "the first-use step shows the labelled textarea, hint, layout and read button",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      assert has_element?(view, "#paste-form")
      assert has_element?(view, "#paste-source")
      assert has_element?(view, "#paste-source-hint", "Up to 500 trips")

      assert has_element?(
               view,
               "#paste-form label",
               "Timetable copied from your spreadsheet"
             )

      assert has_element?(view, "#paste-source[phx-debounce='blur']")
      assert has_element?(view, "#paste-layout", "Layout")
      assert has_element?(view, "#paste-layout-auto")
      assert has_element?(view, "#paste-layout-header")
      assert has_element?(view, "#paste-read", "Read timetable")
      assert has_element?(view, "#paste-read[phx-disable-with='Reading…']")
      refute has_element?(view, "#paste-source-error")
      refute has_element?(view, "#paste-source-summary")
    end

    test "reading 612 trip rows shows the 500-row message and keeps the text",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      rows = for index <- 1..612, do: "#{1300 + index}\t06:00\t06:05\t06:10"

      text =
        "Trip\tPaste Stop 1\tPaste Stop 2\tPaste Stop 3\n" <> Enum.join(rows, "\n")

      read(view, %{"text" => text})

      # The raw scanner stops past 501 records, so the count names the
      # early stop while the message names the 500-row cap.
      assert has_element?(view, "#paste-source-error", "trip rows")
      assert has_element?(view, "#paste-source-error", "Paste up to 500")
      assert has_element?(view, "#paste-source[aria-invalid='true']")

      # The text stays in the textarea for the fix.
      assert view |> element("#paste-source") |> render() =~ "1301"
      assert view |> element("#paste-source") |> render() =~ "06:05"
      refute has_element?(view, "#paste-source-summary")
    end

    test "a paste with no times shows No times found inline",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      read(view, %{"text" => "Trip\tPaste Stop 1\nfoo\tbar"})

      assert has_element?(view, "#paste-source-error", "No times found")
      assert view |> element("#paste-source") |> render() =~ "foo"
      refute has_element?(view, "#paste-source-summary")
    end

    test "reading an empty timetable asks for a paste first",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      read(view, %{"text" => "   "})

      assert has_element?(view, "#paste-source-error", "Paste a timetable first")
      refute has_element?(view, "#paste-source-summary")
    end

    test "an unclosed quote names its starting line",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      read(view, %{"text" => "Trip\tPaste Stop 1\n\"06:00\t06:05"})

      assert has_element?(view, "#paste-source-error", "starts on line 2")
      refute has_element?(view, "#paste-source-summary")
    end

    test "an exact paste collapses the step and shows the review placeholder",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      read(view)

      assert has_element?(view, "#paste-source-summary", "2 trip rows")
      assert has_element?(view, "#paste-source-summary", "trips in rows")
      assert has_element?(view, "#paste-source-edit", "Edit timetable")
      assert has_element?(view, "#paste-review")
      refute has_element?(view, "#paste-source")
      refute has_element?(view, "#paste-source-error")
      refute has_element?(view, "#paste-columns")
    end

    test "a paste with an unmatched column shows the columns placeholder",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      read(view, %{
        "text" => "Trip\tMystery Stop\tPaste Stop 2\tPaste Stop 3\n101\t06:00\t06:05\t06:10"
      })

      assert has_element?(view, "#paste-source-summary")
      assert has_element?(view, "#paste-columns")
      refute has_element?(view, "#paste-review")
    end

    test "Edit timetable reopens the step with the text intact",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      read(view)
      assert has_element?(view, "#paste-source-summary")

      render_click(view, "edit_source")

      assert has_element?(view, "#paste-source")
      assert view |> element("#paste-source") |> render() =~ "06:00"
      refute has_element?(view, "#paste-source-summary")
      # Reopening hides the later stages until the next Read, like the
      # prototype returning to its source stage.
      refute has_element?(view, "#paste-review")
    end

    test "changing the schedule keeps a real paste and rebuilds the review",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      # Typing stashes the paste without reviewing it.
      render_change(view, "input", read_params())
      refute has_element?(view, "#paste-source-summary")

      read(view)
      assert has_element?(view, "#paste-source-summary")

      # Step 22's deferred positive case: a review now warns about the rebuild.
      view |> element("#paste-scope-open") |> render_click()
      assert has_element?(view, "#paste-scope-rebuild-warning")

      render_submit(
        view,
        "change_schedule",
        %{
          "scope" => %{
            "service_id" => paste.weekday,
            "direction" => "1",
            "pattern" => paste.inbound.pattern.id
          }
        }
      )

      inbound_path =
        paste_path(version, paste.route, %{
          "service_id" => paste.weekday,
          "direction" => "1",
          "pattern" => paste.inbound.pattern.id
        })

      assert_patch(view, inbound_path)
      _html = follow(view, inbound_path)

      assert has_element?(view, "#paste-scope-direction", "Inbound")
      # The rebuilt review collapses the step again on the new schedule.
      assert has_element?(view, "#paste-source-summary")

      # And the pasted text survived the patch.
      render_click(view, "edit_source")
      assert view |> element("#paste-source") |> render() =~ "06:00"
    end
  end
end
