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

  describe "columns step" do
    # Step 24: the pasted grid with a Use-as select per column, status
    # badges with one-line reasons, Confirm match for close matches, the
    # Review-trips error summary, the all-unmatched layout hint and the
    # pattern stop strip. Select changes diff against the review's
    # effective values and recompute the review purely from the loaded
    # scope; confirming or mapping the last issue advances to the review
    # placeholder.
    setup :editor_scope

    defp columns_read_params(text) do
      %{"paste" => %{"text" => text, "layout" => "auto", "header" => "true"}}
    end

    defp columns_read(view, text) do
      render_submit(view, "read", columns_read_params(text))
    end

    defp close_text do
      "Trip\tPaste Stopp 1\tPaste Stop 2\tPaste Stop 3\n101\t06:00\t06:05\t06:10"
    end

    defp strip_text do
      "Trip\tPaste Stop 1\tMystery\tPaste Stop 3\n101\t06:00\t06:05\t06:10"
    end

    test "a close match shows Confirm match and blocks Review trips until confirmed",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      columns_read(view, close_text())

      assert has_element?(view, "#paste-columns")
      assert has_element?(view, "#paste-map-1")
      assert has_element?(view, "#paste-map-1[aria-invalid='true']")
      assert has_element?(view, "#paste-columns", "Column B")
      assert has_element?(view, "#paste-columns", "Close match")
      assert has_element?(view, "#paste-confirm-1", "Confirm match")
      assert has_element?(view, "#paste-columns", "Check that")
      assert has_element?(view, "#paste-to-review", "Review trips")
      # The error summary stays hidden until Review trips is pressed.
      refute has_element?(view, "#paste-column-errors")

      render_click(view, "to_review")

      assert has_element?(view, "#paste-column-errors", "1 column needs a decision")
      assert has_element?(view, "#paste-column-errors a[href='#paste-map-1']", "Column B")
      assert_push_event(view, "focus_scoped_target", %{id: "paste-column-errors"})

      # Confirming the close match clears the last issue and advances.
      render_click(view, "confirm_column", %{"col" => "1"})

      assert has_element?(view, "#paste-review")
      refute has_element?(view, "#paste-columns")
      refute has_element?(view, "#paste-column-errors")
    end

    test "an out-of-order paste focuses the error summary on Review trips",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      columns_read(view, "Trip\tPaste Stop 2\tPaste Stop 1\n101\t06:00\t06:05")

      assert has_element?(view, "#paste-columns", "Out of order")
      assert has_element?(view, "#paste-columns", "comes before")
      assert has_element?(view, "#paste-map-2[aria-invalid='true']")

      render_click(view, "to_review")

      assert has_element?(view, "#paste-column-errors", "out of order")
      assert_push_event(view, "focus_scoped_target", %{id: "paste-column-errors"})
      # The columns stay until the order is fixed.
      assert has_element?(view, "#paste-columns")
      refute has_element?(view, "#paste-review")
    end

    test "the strip marks pasted, filled-in and missing-column stops",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      columns_read(view, strip_text())

      assert has_element?(view, "#paste-columns", "No match")
      assert has_element?(view, "#paste-pattern-strip", "Main · where each column goes")
      # B maps Paste Stop 1, D maps Paste Stop 3, the middle stop is filled in.
      assert has_element?(view, "#paste-pattern-strip", "filled in")
      assert has_element?(view, "#paste-pattern-strip", "Paste Stop 2")
      assert has_element?(view, "#paste-pattern-strip [title='Column B']", "B")
      assert has_element?(view, "#paste-pattern-strip [title='Column D']", "D")
      # The grid shows the pasted header and a sample row.
      assert has_element?(view, "#columns-table", "Mystery")
      assert has_element?(view, "#columns-table", "06:05")
      # The selects offer the pattern stops in order, the trip fields and Not used.
      assert has_element?(view, "#paste-map-2", "Trip number")
      assert has_element?(view, "#paste-map-2", "Not used")
      assert has_element?(view, "#paste-map-2", "1 · Paste Stop 1")
    end

    test "choosing an earlier occurrence than its neighbour marks Out of order",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)
      first_id = Enum.at(paste.main.occurrences, 0).id

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      columns_read(view, strip_text())
      assert has_element?(view, "#paste-columns", "No match")

      # Mapping column D back onto the first occurrence breaks the order:
      # B already holds Paste Stop 1.
      render_change(view, "input", %{
        "paste" => %{
          "text" => strip_text(),
          "layout" => "auto",
          "header" => "true",
          "overrides" => %{"3" => "occ:#{first_id}"}
        }
      })

      assert has_element?(view, "#paste-columns", "Out of order")
      assert has_element?(view, "#paste-columns", "comes before")
      # The untouched selects never pinned their automatic picks: B still
      # reads Exact, not Chosen.
      assert has_element?(view, "#paste-columns", "Exact")
      # The columns stay until every issue is fixed.
      assert has_element?(view, "#paste-columns")
      refute has_element?(view, "#paste-review")
    end

    test "mapping the mystery column to its stop reaches the review",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)
      second_id = Enum.at(paste.main.occurrences, 1).id

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      columns_read(view, strip_text())
      assert has_element?(view, "#paste-columns")

      render_change(view, "input", %{
        "paste" => %{
          "text" => strip_text(),
          "layout" => "auto",
          "header" => "true",
          "overrides" => %{"2" => "occ:#{second_id}"}
        }
      })

      assert has_element?(view, "#paste-review")
      refute has_element?(view, "#paste-columns")
    end

    test "every time-bearing column unmatched shows the layout hint and no-column strip",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = canonical_path(view, version, paste.route, paste)

      columns_read(view, "Run\tDowntown\tMill & 5th\n1215\t09:30\t09:40")

      assert has_element?(view, "#paste-columns", "No match")
      assert has_element?(view, "#paste-layout-hint", "Stops down the side?")

      assert has_element?(
               view,
               "#paste-layout-hint a[href='#paste-layout']",
               "Change the layout."
             )

      # Nothing is mapped, so every endpoint reads no column.
      assert has_element?(view, "#paste-pattern-strip", "no column")

      render_click(view, "to_review")

      assert has_element?(view, "#paste-column-errors", "columns need a decision")
      assert has_element?(view, "#paste-column-errors", "Match at least two columns to stops.")
      assert_push_event(view, "focus_scoped_target", %{id: "paste-column-errors"})
    end
  end

  describe "review header" do
    # Step 25: How to apply, Fill other stops from, Stops view, the three
    # metrics, refusal/nothing callouts and the filter buttons. Mode and
    # template changes recompute the pure review from the loaded scope (no
    # database read); stops view and filter only restash for display. The
    # matrix (step 26), decisions (27) and apply (28) stay placeholders.
    setup :editor_scope

    # Seven weekday outbound trips on a zero-dwell Main pattern: exact
    # pasted rows refine to :unchanged (a lone column serves as both
    # arrival and departure, so minute-exact rows key-match the timing).
    defp review_setup(%{organization: organization, version: version}) do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE25",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE25_WKD", "Weekday")

      Enum.each(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "PASTE25_S#{index}",
          stop_name: "Review Stop #{index}"
        })
      end)

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE25-MAIN",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"PASTE25_S1", 0, 0, 1},
            {"PASTE25_S2", 300, 300, 1},
            {"PASTE25_S3", 600, 600, 1}
          ]
        })

      starts = [
        {"PASTE25_T0600", "06:00:00"},
        {"PASTE25_T0605", "06:05:00"},
        {"PASTE25_T0700", "07:00:00"},
        {"PASTE25_T0705", "07:05:00"},
        {"PASTE25_T0800", "08:00:00"},
        {"PASTE25_T0900", "09:00:00"},
        {"PASTE25_T1000", "10:00:00"}
      ]

      Enum.each(starts, fn {trip_id, start_time} ->
        schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
          service_id: weekday,
          trip_id: trip_id,
          start_time: start_time
        })
      end)

      %{route: route, weekday: weekday, main: main}
    end

    # Five exact rows, one retimed 09:00 row, two new starts; the 10:00
    # trip is unpaired. Replace gives 2 added, 1 removed, 1 changed and
    # 7 → 8 trips with 2 → 3 vehicles (the 06:07 add overlaps the 06:00
    # and 06:05 trips).
    defp review_text do
      "Review Stop 1\tReview Stop 2\tReview Stop 3\n" <>
        Enum.join(
          [
            "06:00\t06:05\t06:10",
            "06:05\t06:10\t06:15",
            "07:00\t07:05\t07:10",
            "07:05\t07:10\t07:15",
            "08:00\t08:05\t08:10",
            "09:00\t09:06\t09:11",
            "06:07\t06:12\t06:17",
            "11:00\t11:05\t11:10"
          ],
          "\n"
        )
    end

    defp review_params(text, overrides \\ %{}) do
      %{
        "paste" =>
          Map.merge(
            %{"text" => text, "layout" => "auto", "header" => "true"},
            overrides
          )
      }
    end

    defp review_read(view, text) do
      render_submit(view, "read", review_params(text))
    end

    defp review_open(view, version, route, setup) do
      follow(
        view,
        paste_path(version, route, %{
          "service_id" => setup.weekday,
          "direction" => "0",
          "pattern" => setup.main.pattern.id
        })
      )
    end

    test "an exact paste shows the review header with controls and add-mode metrics",
         %{conn: conn, version: version} = context do
      setup = review_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = review_open(view, version, setup.route, setup)

      review_read(view, review_text())

      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-review h2", "Review")
      assert has_element?(view, "#paste-review", "Not applied")
      assert has_element?(view, "#paste-review", "Weekday · Outbound · 8 pasted rows")

      assert has_element?(view, "#paste-mode", "How to apply")
      assert has_element?(view, "#paste-mode", "Add trips")
      assert has_element?(view, "#paste-mode", "Replace trips")
      assert has_element?(view, "#paste-mode-help", "Existing trips stay")

      assert has_element?(view, "#paste-template")
      assert has_element?(view, "#paste-review", "Fill other stops from")
      assert has_element?(view, "#paste-template option", "Standard · 10 min")

      assert has_element?(view, "#paste-stops-view", "Stops view")
      assert has_element?(view, "#paste-stops-view", "Pasted")
      assert has_element?(view, "#paste-stops-view", "All stops")

      # Add mode: the six repeats are Already exists, the two new starts add.
      assert has_element?(view, "#paste-metric-trips", "7 → 9")
      assert has_element?(view, "#paste-metric-trips", "2 added")
      assert has_element?(view, "#paste-metric-vehicles", "route 12 alone")
      assert has_element?(view, "#paste-metric-vehicles", "Weekday, both directions")

      assert has_element?(
               view,
               "#paste-metric-timings",
               "Every row matches an existing timing"
             )

      assert has_element?(view, "#paste-filters", "All rows")
      assert has_element?(view, "#paste-rows")
      refute has_element?(view, "#paste-nothing")
      refute has_element?(view, "#paste-refusal-frequency")
    end

    test "switching to Replace changes the consequence and the metrics to 7 → 8 and 2 → 3",
         %{conn: conn, version: version} = context do
      setup = review_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = review_open(view, version, setup.route, setup)

      review_read(view, review_text())

      render_change(view, "input", review_params(review_text(), %{"mode" => "replace"}))

      assert has_element?(view, "#paste-mode-help", "Weekday")
      assert has_element?(view, "#paste-mode-help", "outbound")
      assert has_element?(view, "#paste-mode-help", "Main")
      assert has_element?(view, "#paste-mode-help", "removed")

      assert has_element?(view, "#paste-metric-trips", "7 → 8")
      assert has_element?(view, "#paste-metric-trips", "2 added · 1 removed · 1 changed")

      assert has_element?(view, "#paste-metric-vehicles", "2 → 3")

      assert view |> element("#paste-metric-timings") |> render() =~ "Pasted"
    end

    test "a frequency trip in scope refuses Replace with a Use Add trips escape",
         %{conn: conn, organization: organization, version: version} do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE25F",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE25F_WKD", "Weekday")

      Enum.each(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "PASTE25F_S#{index}",
          stop_name: "Review Stop #{index}"
        })
      end)

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE25F-MAIN",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"PASTE25F_S1", 0, 0, 1},
            {"PASTE25F_S2", 300, 300, 1},
            {"PASTE25F_S3", 600, 600, 1}
          ]
        })

      schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
        service_id: weekday,
        trip_id: "PASTE25F_T0900",
        start_time: "09:00:00",
        frequencies: [
          %{start_time: "09:00:00", end_time: "12:00:00", headway_secs: 1200, exact_times: 0}
        ]
      })

      text = "Review Stop 1\tReview Stop 2\tReview Stop 3\n10:00\t10:05\t10:10"

      {:ok, view, _html} = live(conn, paste_path(version, route))

      _html =
        follow(
          view,
          paste_path(version, route, %{
            "service_id" => weekday,
            "direction" => "0",
            "pattern" => main.pattern.id
          })
        )

      review_read(view, text)
      assert has_element?(view, "#paste-review")
      refute has_element?(view, "#paste-refusal-frequency")

      render_change(view, "input", review_params(text, %{"mode" => "replace"}))

      assert has_element?(view, "#paste-refusal-frequency", "Replace can")
      assert has_element?(view, "#paste-use-add", "Use Add trips")

      html = view |> element("#paste-refusal-frequency") |> render()
      assert html =~ "Main"
      assert html =~ "every 20 min"
      assert html =~ "09:00"

      render_click(view, "use_add")

      assert has_element?(view, "#paste-mode-help", "Existing trips stay")
      refute has_element?(view, "#paste-refusal-frequency")
    end

    test "filters show counts, hide zero-count types and toggle",
         %{conn: conn, version: version} = context do
      setup = review_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = review_open(view, version, setup.route, setup)

      review_read(view, review_text())
      render_change(view, "input", review_params(review_text(), %{"mode" => "replace"}))

      assert has_element?(view, "#paste-filter-all", "All rows")
      assert view |> element("#paste-filter-all") |> render() =~ ">9<"
      assert has_element?(view, "#paste-filter-add", "2")
      assert has_element?(view, "#paste-filter-change", "1")
      assert has_element?(view, "#paste-filter-remove", "1")
      assert has_element?(view, "#paste-filter-unchanged", "5")
      refute has_element?(view, "#paste-filter-duplicate")
      refute has_element?(view, "#paste-filter-skipped")
      refute has_element?(view, "#paste-filter-needs_decision")

      render_click(view, "paste_filter", %{"filter" => "add"})

      assert has_element?(view, "#paste-filter-add[aria-pressed='true']")
      assert has_element?(view, "#paste-filter-all[aria-pressed='false']")

      render_click(view, "paste_filter", %{"filter" => "all"})

      assert has_element?(view, "#paste-filter-all[aria-pressed='true']")
    end

    test "a paste that repeats every trip shows the nothing-to-apply notice",
         %{conn: conn, version: version} = context do
      setup = review_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = review_open(view, version, setup.route, setup)

      review_read(
        view,
        "Review Stop 1\tReview Stop 2\tReview Stop 3\n06:00\t06:05\t06:10\n07:00\t07:05\t07:10"
      )

      assert has_element?(view, "#paste-nothing", "Nothing to apply")
      assert has_element?(view, "#paste-metric-trips", "no change")
    end

    test "stops view and template changes stay on the review",
         %{conn: conn, version: version} = context do
      setup = review_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = review_open(view, version, setup.route, setup)

      review_read(view, review_text())

      render_change(view, "input", review_params(review_text(), %{"stops_view" => "all"}))

      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-metric-trips", "7 → 9")
      assert view |> element("#paste-stops-view input[value='all']") |> render() =~ "checked"

      render_change(
        view,
        "input",
        review_params(review_text(), %{"template_timing_id" => setup.main.timing.id})
      )

      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-metric-trips", "7 → 9")
    end
  end

  describe "review matrix" do
    # Step 26: the `#paste-rows` stream with change badges, pasted and
    # estimated times, was-values, removals and the timing note. Mode and
    # template changes recompute and re-stream; stops view and filter only
    # restash and re-stream the same review.
    setup :editor_scope

    # Three weekday outbound trips on a zero-dwell Main pattern. The
    # matrix text refines to one unchanged row, one retimed 09:00 row (a
    # new Pasted timing with `was` values), one added row and — in Replace
    # mode — the struck 08:00 removal with its transfer note.
    defp matrix_setup(%{organization: organization, version: version}) do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE26",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE26_WKD", "Weekday")

      Enum.each(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "PASTE26_S#{index}",
          stop_name: "Matrix Stop #{index}"
        })
      end)

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE26-MAIN",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"PASTE26_S1", 0, 0, 1},
            {"PASTE26_S2", 300, 300, 1},
            {"PASTE26_S3", 600, 600, 1}
          ]
        })

      Enum.each(
        [
          {"PASTE26_T0700", "07:00:00"},
          {"PASTE26_T0800", "08:00:00"},
          {"PASTE26_T0900", "09:00:00"}
        ],
        fn {trip_id, start_time} ->
          schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
            service_id: weekday,
            trip_id: trip_id,
            start_time: start_time
          })
        end
      )

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "PASTE26_S3",
        to_stop_id: "PASTE26_S1",
        from_trip_id: "PASTE26_T0800",
        transfer_type: 0
      })

      %{route: route, weekday: weekday, main: main}
    end

    defp matrix_text do
      "Matrix Stop 1\tMatrix Stop 2\tMatrix Stop 3\n" <>
        "07:00\t07:05\t07:10\n" <>
        "09:00\t09:07\t09:12\n" <>
        "06:00\t06:05\t06:10"
    end

    defp matrix_open(view, version, route, setup) do
      follow(
        view,
        paste_path(version, route, %{
          "service_id" => setup.weekday,
          "direction" => "0",
          "pattern" => setup.main.pattern.id
        })
      )
    end

    defp replace_matrix(view, text) do
      review_read(view, text)
      render_change(view, "input", review_params(text, %{"mode" => "replace"}))
    end

    test "streams one row per change with badges, was-values and the struck removal",
         %{conn: conn, version: version} = context do
      setup = matrix_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = matrix_open(view, version, setup.route, setup)

      replace_matrix(view, matrix_text())

      assert has_element?(view, "#paste-rows #paste-row-1")
      assert has_element?(view, "#paste-rows #paste-row-2")
      assert has_element?(view, "#paste-rows #paste-row-3")
      assert has_element?(view, "#paste-rows #paste-remove-PASTE26_T0800")

      assert has_element?(view, "#paste-rows #paste-row-1", "07:00")
      assert has_element?(view, "#paste-rows #paste-row-1", "No change")
      assert has_element?(view, "#paste-rows #paste-row-1", "Matches trip")

      row2 = view |> element("#paste-rows #paste-row-2") |> render()
      assert row2 =~ "Change"
      assert row2 =~ "09:07"
      assert row2 =~ "was"
      assert row2 =~ "09:05"
      assert row2 =~ "Keeps trip ID PASTE26_T0900"
      assert row2 =~ "New ·"

      row3 = view |> element("#paste-rows #paste-row-3") |> render()
      assert row3 =~ "Add"
      assert row3 =~ "06:00"

      removal = view |> element("#paste-rows #paste-remove-PASTE26_T0800") |> render()
      assert removal =~ "Remove"
      assert removal =~ "<s"
      assert removal =~ "08:00"
      assert removal =~ "Trip ID PASTE26_T0800"
      assert removal =~ "1 transfer"
      assert removal =~ "removed with it"

      assert has_element?(view, "#paste-review-table", "Timing")
      assert has_element?(view, "#paste-review-table", "Details")
      refute has_element?(view, "#paste-filter-warnings")
    end

    test "filters narrow the streamed rows and the empty state offers Show all rows",
         %{conn: conn, version: version} = context do
      setup = matrix_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = matrix_open(view, version, setup.route, setup)

      replace_matrix(view, matrix_text())

      render_click(view, "paste_filter", %{"filter" => "remove"})

      assert has_element?(view, "#paste-rows #paste-remove-PASTE26_T0800")
      refute has_element?(view, "#paste-rows #paste-row-1")

      # Add mode has no removals, so the current filter matches nothing.
      render_change(view, "input", review_params(matrix_text(), %{"mode" => "add"}))

      assert has_element?(view, "#paste-review-table", "No rows match this filter.")
      refute has_element?(view, "#paste-rows #paste-row-1")

      view |> element("#paste-review-table button", "Show all rows") |> render_click()

      assert has_element?(view, "#paste-filter-all[aria-pressed='true']")
      assert has_element?(view, "#paste-rows #paste-row-1")
    end

    test "selecting a timing name opens the timing note with template and trip count",
         %{conn: conn, version: version} = context do
      setup = matrix_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = matrix_open(view, version, setup.route, setup)

      # The uneven middle stop forces a new timing with an estimate, so
      # the note names the template, the estimated stop and the trip count.
      review_read(
        view,
        "Matrix Stop 1\tMatrix Stop 2\tMatrix Stop 3\n06:00\t\t06:20"
      )

      view |> element("#paste-rows #paste-row-1 button") |> render_click()

      assert has_element?(view, "#paste-timing-note", "New timing")
      assert has_element?(view, "#paste-timing-note", "Standard")
      assert has_element?(view, "#paste-timing-note", "Matrix Stop 2")
      assert has_element?(view, "#paste-timing-note", "Applying creates it for 1 trip")

      render_click(view, "paste_timing_close")
      refute has_element?(view, "#paste-timing-note")
    end

    test "an estimated stop renders italic in All stops and is absent in Pasted view",
         %{conn: conn, version: version} = context do
      setup = matrix_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = matrix_open(view, version, setup.route, setup)

      text =
        "Matrix Stop 1\tMatrix Stop 2\tMatrix Stop 3\n" <>
          "06:00\t\t06:20"

      review_read(view, text)

      # The blank middle stop is estimated, so Pasted view has no column.
      refute view |> element("#paste-review-table thead") |> render() =~ "Matrix Stop 2"
      assert has_element?(view, "#paste-rows #paste-row-1", "06:20")

      render_change(view, "input", review_params(text, %{"stops_view" => "all"}))

      assert view |> element("#paste-review-table thead") |> render() =~ "Matrix Stop 2"

      row = view |> element("#paste-rows #paste-row-1") |> render()
      assert row =~ "06:10"
      assert row =~ "italic"
    end

    test "overnight times show +1 day", %{conn: conn, version: version} = context do
      setup = matrix_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = matrix_open(view, version, setup.route, setup)

      review_read(
        view,
        "Matrix Stop 1\tMatrix Stop 2\tMatrix Stop 3\n24:03\t24:08\t24:13"
      )

      assert has_element?(view, "#paste-rows #paste-row-1", "24:03")
      assert has_element?(view, "#paste-rows #paste-row-1", "+1 day")
    end

    test "arrival times render when arrival differs from departure",
         %{conn: conn, version: version} = context do
      setup = matrix_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = matrix_open(view, version, setup.route, setup)

      review_read(
        view,
        "Matrix Stop 1\tMatrix Stop 2 arr\tMatrix Stop 2 dep\tMatrix Stop 3\n" <>
          "07:00\t07:04\t07:05\t07:10"
      )

      assert has_element?(view, "#paste-rows #paste-row-1", "arr 07:04")
      assert has_element?(view, "#paste-rows #paste-row-1", "07:05")
    end

    test "rows on another pattern name it above the timing",
         %{conn: conn, organization: organization, version: version} do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE26X",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE26X_WKD", "Weekday")

      Enum.each(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "PASTE26X_S#{index}",
          stop_name: "Matrix Stop #{index}"
        })
      end)

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE26X-MAIN",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"PASTE26X_S1", 0, 0, 1},
            {"PASTE26X_S2", 300, 300, 1},
            {"PASTE26X_S3", 600, 600, 1}
          ]
        })

      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "PASTE26X-SHORT",
        route_pattern_name: "Short",
        route_pattern_typicality: 0,
        timing_name: "Standard",
        stops: [
          {"PASTE26X_S1", 0, 0, 1},
          {"PASTE26X_S3", 600, 600, 1}
        ]
      })

      {:ok, view, _html} = live(conn, paste_path(version, route))

      _html =
        follow(
          view,
          paste_path(version, route, %{
            "service_id" => weekday,
            "direction" => "0",
            "pattern" => main.pattern.id
          })
        )

      # The dash rules Main out, so the row takes the one pattern that fits.
      review_read(
        view,
        "Matrix Stop 1\tMatrix Stop 2\tMatrix Stop 3\n06:00\t–\t06:10"
      )

      row = view |> element("#paste-rows #paste-row-1") |> render()
      assert row =~ "Short"
      assert row =~ "Standard"
      assert row =~ "06:00"
      assert row =~ "06:10"

      refute view |> element("#paste-review-table thead") |> render() =~ "Matrix Stop 2"
    end

    test "the warnings filter lists rows whose trip number is already used",
         %{conn: conn, organization: organization, version: version} do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE26W",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE26W_WKD", "Weekday")

      Enum.each(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "PASTE26W_S#{index}",
          stop_name: "Matrix Stop #{index}"
        })
      end)

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE26W-MAIN",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"PASTE26W_S1", 0, 0, 1},
            {"PASTE26W_S2", 300, 300, 1},
            {"PASTE26W_S3", 600, 600, 1}
          ]
        })

      Enum.each(
        [
          {"PASTE26W_T0700", "07:00:00", "7"},
          {"PASTE26W_T0800", "08:00:00", "7"},
          {"PASTE26W_T0900", "09:00:00", nil}
        ],
        fn {trip_id, start_time, short} ->
          schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
            service_id: weekday,
            trip_id: trip_id,
            start_time: start_time,
            trip_short_name: short
          })
        end
      )

      text =
        "Matrix Stop 1\tMatrix Stop 2\tMatrix Stop 3\n" <>
          "07:00\t07:05\t07:10\n" <>
          "08:00\t08:05\t08:10\n" <>
          "09:00\t09:05\t09:10"

      {:ok, view, _html} = live(conn, paste_path(version, route))

      _html =
        follow(
          view,
          paste_path(version, route, %{
            "service_id" => weekday,
            "direction" => "0",
            "pattern" => main.pattern.id
          })
        )

      review_read(view, text)

      render_change(view, "input", review_params(text, %{"mode" => "replace"}))

      assert has_element?(view, "#paste-filter-warnings", "2")

      render_click(view, "paste_filter", %{"filter" => "warnings"})

      assert has_element?(view, "#paste-rows #paste-row-1", "already used")
      assert has_element?(view, "#paste-rows #paste-row-2")
      refute has_element?(view, "#paste-rows #paste-row-3")
    end
  end

  describe "row decisions" do
    # Step 27: the Details-cell decision controls (pattern select, cell
    # correction, twelve-hour choice, pairing radios, skip, restore, Add
    # anyway) and the `#paste-decisions` hidden field that restores them on
    # form recovery. Pattern, cell and pairing controls post through the
    # form's `input` event; the buttons arrive as discrete events. Every
    # decision recomputes the pure review from the loaded scope (no
    # database read).
    setup :editor_scope

    # A chosen Main pattern plus two identical short turns: a row that
    # skips the middle stop fits both shorts, so it needs a pattern
    # decision; choice, skip and restore all act on row 1.
    defp decision_setup(%{organization: organization, version: version}) do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE27",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE27_WKD", "Weekday")

      Enum.each(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "PASTE27_S#{index}",
          stop_name: "Decision Stop #{index}"
        })
      end)

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE27-MAIN",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"PASTE27_S1", 0, 0, 1},
            {"PASTE27_S2", 300, 300, 1},
            {"PASTE27_S3", 600, 600, 1}
          ]
        })

      short1 =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE27-SHORT1",
          route_pattern_name: "Short Turn",
          route_pattern_typicality: 0,
          timing_name: "Standard",
          stops: [
            {"PASTE27_S1", 0, 0, 1},
            {"PASTE27_S3", 600, 600, 1}
          ]
        })

      short2 =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE27-SHORT2",
          route_pattern_name: "Short North",
          route_pattern_typicality: 0,
          timing_name: "Standard",
          stops: [
            {"PASTE27_S1", 0, 0, 1},
            {"PASTE27_S3", 600, 600, 1}
          ]
        })

      %{route: route, weekday: weekday, main: main, short1: short1, short2: short2}
    end

    defp decision_open(view, version, route, setup) do
      follow(
        view,
        paste_path(version, route, %{
          "service_id" => setup.weekday,
          "direction" => "0",
          "pattern" => setup.main.pattern.id
        })
      )
    end

    defp decision_headers do
      "Decision Stop 1\tDecision Stop 2\tDecision Stop 3"
    end

    defp decision_read(view, text) do
      render_submit(view, "read", %{
        "paste" => %{"text" => text, "layout" => "auto", "header" => "true"}
      })
    end

    defp decision_params(text, decisions, extra \\ %{}) do
      %{
        "paste" =>
          Map.merge(
            %{
              "text" => text,
              "layout" => "auto",
              "header" => "true",
              "mode" => "add",
              "template_timing_id" => "",
              "stops_view" => "pasted",
              "decisions" => Jason.encode!(decisions)
            },
            extra
          )
      }
    end

    test "choosing a pattern for an ambiguous row adds it",
         %{conn: conn, version: version} = context do
      setup = decision_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = decision_open(view, version, setup.route, setup)

      text = decision_headers() <> "\n06:00\t–\t06:10"
      decision_read(view, text)

      assert has_element?(
               view,
               "#paste-rows #paste-row-1",
               "2 patterns fit. Choose the one this trip follows."
             )

      assert has_element?(view, "#paste-pattern-1")
      assert has_element?(view, "#paste-skip-1", "Skip row")

      render_change(
        view,
        "input",
        decision_params(text, %{}, %{
          "pattern_choices" => %{"1" => setup.short1.pattern.id}
        })
      )

      assert has_element?(view, "#paste-rows #paste-row-1", "Add")
      refute has_element?(view, "#paste-pattern-1")

      assert view |> element("#paste-decisions") |> render() =~ setup.short1.pattern.id
    end

    test "fixing the 12:1O cell resolves the row and names the letter",
         %{conn: conn, version: version} = context do
      setup = decision_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = decision_open(view, version, setup.route, setup)

      text = decision_headers() <> "\n06:00\t12:1O\t06:20"
      decision_read(view, text)

      assert has_element?(view, "#paste-rows #paste-row-1", "12:1O")
      assert has_element?(view, "#paste-rows #paste-row-1", "isn’t a time")
      assert has_element?(view, "#paste-rows #paste-row-1", "letter O")
      assert has_element?(view, "#paste-rows #paste-row-1", "Decision Stop 2")
      assert has_element?(view, "#paste-cell-1-1")

      render_change(
        view,
        "input",
        decision_params(text, %{}, %{"cells" => %{"1" => %{"1" => "12:10"}}})
      )

      assert has_element?(view, "#paste-rows #paste-row-1", "Add")
      assert has_element?(view, "#paste-rows #paste-row-1", "12:10")
      refute has_element?(view, "#paste-cell-1-1")
    end

    test "choosing after midnight resolves the owl row",
         %{conn: conn, version: version} = context do
      setup = decision_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = decision_open(view, version, setup.route, setup)

      text =
        decision_headers() <>
          "\n18:00\t18:05\t18:10\n19:00\t19:05\t19:10\n20:00\t20:05\t20:10\n1:15\t1:20\t1:25"

      decision_read(view, text)

      row = view |> element("#paste-rows #paste-row-4") |> render()
      assert row =~ "Starts at 01:15"
      assert row =~ "after midnight"
      assert has_element?(view, "#paste-twelve-4-after-midnight")
      assert has_element?(view, "#paste-twelve-4-plus-twelve")
      assert has_element?(view, "#paste-twelve-4-keep")

      # After-midnight reads first.
      {first, _} = :binary.match(row, "after-midnight")
      {second, _} = :binary.match(row, "plus-twelve")
      {third, _} = :binary.match(row, "4-keep")
      assert first < second and second < third

      view |> element("#paste-twelve-4-after-midnight") |> render_click()

      assert has_element?(view, "#paste-rows #paste-row-4", "Add")
      assert has_element?(view, "#paste-rows #paste-row-4", "25:15")
      assert has_element?(view, "#paste-rows #paste-row-4", "+1 day")
      refute has_element?(view, "#paste-twelve-4-after-midnight")
    end

    test "choosing a trip in a pairing group removes the other",
         %{conn: conn, organization: organization, version: version} do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE27P",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE27P_WKD", "Weekday")

      Enum.each(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "PASTE27P_S#{index}",
          stop_name: "Pair Stop #{index}"
        })
      end)

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE27P-MAIN",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"PASTE27P_S1", 0, 0, 1},
            {"PASTE27P_S2", 300, 300, 1},
            {"PASTE27P_S3", 600, 600, 1}
          ]
        })

      schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
        service_id: weekday,
        trip_id: "PASTE27P_T0700A",
        start_time: "07:00:00",
        trip_short_name: "101",
        block_id: "B1"
      })

      schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
        service_id: weekday,
        trip_id: "PASTE27P_T0700B",
        start_time: "07:00:00",
        trip_short_name: "102",
        block_id: "B2"
      })

      {:ok, view, _html} = live(conn, paste_path(version, route))

      _html =
        follow(
          view,
          paste_path(version, route, %{
            "service_id" => weekday,
            "direction" => "0",
            "pattern" => main.pattern.id
          })
        )

      text = "Pair Stop 1\tPair Stop 2\tPair Stop 3\n07:00\t07:06\t07:11"
      decision_read(view, text)

      render_change(
        view,
        "input",
        decision_params(text, %{}, %{"mode" => "replace"})
      )

      assert has_element?(
               view,
               "#paste-rows #paste-row-1",
               "Choose the one this row replaces"
             )

      assert has_element?(view, "#paste-rows #paste-row-1", "Trip 101 · Block B1")
      assert has_element?(view, "#paste-rows #paste-row-1", "Trip 102 · Block B2")
      assert has_element?(view, "#paste-rows #paste-row-1", "Neither · add as a new trip")

      render_change(
        view,
        "input",
        decision_params(text, %{}, %{
          "mode" => "replace",
          "pairs" => %{"1" => "PASTE27P_T0700A"}
        })
      )

      assert has_element?(view, "#paste-rows #paste-row-1", "Change")
      assert has_element?(view, "#paste-remove-PASTE27P_T0700B")
    end

    test "skipping and restoring a row needs no database read",
         %{conn: conn, version: version} = context do
      setup = decision_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = decision_open(view, version, setup.route, setup)

      text = decision_headers() <> "\n06:00\t–\t06:10"
      decision_read(view, text)
      assert has_element?(view, "#paste-pattern-1")

      render_click(view, "paste_skip", %{"row" => "1"})

      assert has_element?(view, "#paste-rows #paste-row-1", "Skipped")
      assert has_element?(view, "#paste-restore-1", "Restore row")
      refute has_element?(view, "#paste-pattern-1")

      render_click(view, "paste_restore", %{"row" => "1"})

      assert has_element?(view, "#paste-pattern-1")
      assert has_element?(view, "#paste-rows #paste-row-1", "Needs decision")
    end

    test "adding anyway promotes a duplicate and skipping it restores the duplicate",
         %{conn: conn, version: version} = context do
      setup = decision_setup(context)

      schedule_trip_fixture(
        context.organization.id,
        version.id,
        setup.route.route_id,
        setup.main,
        %{service_id: setup.weekday, trip_id: "PASTE27_T0600", start_time: "06:00:00"}
      )

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = decision_open(view, version, setup.route, setup)

      text = decision_headers() <> "\n06:00\t06:05\t06:10"
      decision_read(view, text)

      assert has_element?(view, "#paste-rows #paste-row-1", "Already exists")
      assert has_element?(view, "#paste-keep-1", "Add anyway")

      render_click(view, "paste_keep", %{"row" => "1"})

      assert has_element?(view, "#paste-rows #paste-row-1", "Add")
      assert has_element?(view, "#paste-unkeep-1", "Skip it")

      render_click(view, "paste_unkeep", %{"row" => "1"})

      assert has_element?(view, "#paste-rows #paste-row-1", "Already exists")
    end

    test "recovered form params restore decisions, including rows hidden by a filter",
         %{conn: conn, version: version} = context do
      setup = decision_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = decision_open(view, version, setup.route, setup)

      text =
        decision_headers() <> "\n06:00\t–\t06:10\n07:00\t–\t07:10"

      # A reconnect into a new process re-sends the form params with the
      # hidden decisions field populated; the text is still blank here, so
      # the review rebuilds purely with row 2's pattern choice applied.
      render_change(
        view,
        "input",
        decision_params(text, %{"2" => %{"pattern_id" => setup.short1.pattern.id}})
      )

      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-rows #paste-row-2", "Add")
      assert has_element?(view, "#paste-pattern-1")
      refute has_element?(view, "#paste-pattern-2")

      # Hiding the decided row behind a filter still round-trips it.
      render_click(view, "paste_filter", %{"filter" => "needs_decision"})
      refute has_element?(view, "#paste-rows #paste-row-2")

      render_change(
        view,
        "input",
        decision_params(text, %{"2" => %{"pattern_id" => setup.short1.pattern.id}})
      )

      render_click(view, "paste_filter", %{"filter" => "all"})
      assert has_element?(view, "#paste-rows #paste-row-2", "Add")
      assert has_element?(view, "#paste-pattern-1")
    end

    test "a stale choice shows the one-line discarded notice",
         %{conn: conn, version: version} = context do
      setup = decision_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = decision_open(view, version, setup.route, setup)

      text = decision_headers() <> "\n06:00\t06:05\t06:10"
      decision_read(view, text)
      refute has_element?(view, "#paste-decisions-notice")

      render_change(
        view,
        "input",
        decision_params(text, %{"1" => %{"pattern_id" => Ecto.UUID.generate()}})
      )

      assert has_element?(
               view,
               "#paste-decisions-notice",
               "1 saved choice no longer applies and was cleared."
             )

      assert has_element?(view, "#paste-rows #paste-row-1", "Add")
    end
  end

  describe "apply outcomes" do
    # Step 28: the apply bar, the Replace/Discard confirmations and every
    # apply outcome wired to the real `Gtfs.apply_timetable_paste/5` writer
    # (real database rows, `_paste04` partition). The success path writes
    # through the transaction; the failure paths keep the paste and the
    # decisions.
    setup :editor_scope

    alias GtfsPlanner.Gtfs.TimedPattern
    alias GtfsPlanner.Gtfs.Trip
    alias GtfsPlanner.Repo

    # Two Weekday outbound trips on a zero-dwell Main pattern, 07:00
    # (short 1207) and 08:00 (short 1209), with two transfers naming the
    # 08:00 trip — the production shape of the browser seed's 1209 pair.
    defp apply_setup(%{organization: organization, version: version}) do
      route =
        route_fixture(organization.id, version.id, %{
          route_id: "PASTE28",
          route_short_name: "12",
          route_long_name: "Downtown – Riverside"
        })

      weekday = weekly_calendar(organization, version, "PASTE28_WKD", "Weekday")

      Enum.each(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "PASTE28_S#{index}",
          stop_name: "Apply Stop #{index}"
        })
      end)

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "PASTE28-MAIN",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"PASTE28_S1", 0, 0, 1},
            {"PASTE28_S2", 300, 300, 1},
            {"PASTE28_S3", 600, 600, 1}
          ]
        })

      schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
        service_id: weekday,
        trip_id: "PASTE28_T0700",
        trip_short_name: "1207",
        start_time: "07:00:00"
      })

      schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
        service_id: weekday,
        trip_id: "PASTE28_T0800",
        trip_short_name: "1209",
        start_time: "08:00:00"
      })

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "PASTE28_S1",
        to_stop_id: "PASTE28_S2",
        from_trip_id: "PASTE28_T0700",
        to_trip_id: "PASTE28_T0800",
        transfer_type: 0
      })

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "PASTE28_S2",
        to_stop_id: "PASTE28_S3",
        from_trip_id: "PASTE28_T0800",
        to_trip_id: "PASTE28_T0700",
        transfer_type: 0
      })

      %{route: route, weekday: weekday, main: main}
    end

    defp apply_open(view, version, route, setup) do
      follow(
        view,
        paste_path(version, route, %{
          "service_id" => setup.weekday,
          "direction" => "0",
          "pattern" => setup.main.pattern.id
        })
      )
    end

    defp apply_headers do
      "Apply Stop 1\tApply Stop 2\tApply Stop 3"
    end

    defp apply_read(view, text) do
      render_submit(view, "read", %{
        "paste" => %{"text" => text, "layout" => "auto", "header" => "true"}
      })
    end

    defp apply_redirect_path(version, route, setup) do
      query =
        URI.encode_query([
          {"service_id", setup.weekday},
          {"direction", "0"},
          {"pattern", setup.main.pattern.id}
        ])

      "/gtfs/#{version.id}/routes/#{route.route_id}/schedules?#{query}"
    end

    defp service_trip_count(organization, version, service_id) do
      import Ecto.Query, only: [from: 2]

      Repo.aggregate(
        from(t in Trip,
          where:
            t.organization_id == ^organization.id and
              t.gtfs_version_id == ^version.id and t.service_id == ^service_id
        ),
        :count
      )
    end

    test "the apply bar names the change count and the ready status",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      text = apply_headers() <> "\n08:30\t08:35\t08:40\n09:00\t09:05\t09:10"
      apply_read(view, text)

      assert has_element?(view, "#paste-apply-bar")
      assert has_element?(view, "#paste-apply", "Apply 2 changes")
      assert has_element?(view, "#paste-apply-status", "Ready. Nothing has been saved yet.")
      assert has_element?(view, "#paste-discard", "Discard paste")
      assert view |> element("#paste-apply") |> render() =~ "Applying 2 changes…"
    end

    test "applying with open decisions shows the error summary and keeps the button enabled",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      apply_read(view, apply_headers() <> "\n07:00\t12:1O\t07:10")
      assert has_element?(view, "#paste-rows #paste-row-1", "isn’t a time")

      render_click(view, "paste_apply")
      refute_redirected(view)

      assert has_element?(
               view,
               "#paste-review-errors",
               "Nothing applied yet. 1 row needs a decision."
             )

      assert has_element?(view, "#paste-review-errors a[href=\"#paste-row-1\"]", "Row 1")
      assert has_element?(view, "#paste-review-errors", "fix a time")
      assert has_element?(view, "#paste-apply", "Apply 0 changes")
      refute view |> element("#paste-apply") |> render() =~ " disabled"
    end

    test "replace with a removal opens the confirmation naming the trip and transfers",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      # The 07:00 row repeats its trip; the 08:00 trip is unpaired and
      # becomes the removal with its two transfers.
      text = apply_headers() <> "\n07:00\t07:05\t07:10"
      apply_read(view, text)

      render_change(view, "input", %{
        "paste" => %{
          "text" => text,
          "layout" => "auto",
          "header" => "true",
          "mode" => "replace"
        }
      })

      assert has_element?(view, "#paste-apply", "Replace trips · 1 change")

      render_click(view, "paste_apply")
      refute_redirected(view)

      assert has_element?(
               view,
               "#paste-replace-confirm",
               "Replace Weekday outbound trips?"
             )

      assert has_element?(view, "#paste-replace-confirm", "PASTE28_T0800 at 08:00")
      assert has_element?(view, "#paste-replace-confirm", "2 transfers")
      assert has_element?(view, "#paste-replace-confirm-cancel", "Keep reviewing")
      assert has_element?(view, "#paste-replace-confirm-confirm", "Replace trips")

      # Cancelling keeps the review with nothing written.
      render_click(view, "paste_replace_cancel")
      refute has_element?(view, "#paste-replace-confirm")
      assert has_element?(view, "#paste-review")
      assert %Trip{} = Repo.get_by(Trip, trip_id: "PASTE28_T0800")

      # Confirming writes the removal and lands on Schedules.
      render_click(view, "paste_apply")
      redirect = render_click(view, "paste_replace_confirm")

      path = apply_redirect_path(version, setup.route, setup)
      assert {:error, {:live_redirect, %{to: ^path}}} = redirect
      assert Repo.get_by(Trip, trip_id: "PASTE28_T0800") == nil

      {:ok, _schedules, html} = follow_redirect(redirect, conn)
      assert html =~ "Removed 1 trip"
      assert html =~ "Removed 2 transfers"
      assert html =~ "Vehicles needed"
    end

    test "a successful apply writes the trips and lands on Schedules with the flash",
         %{conn: conn, organization: organization, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      before = service_trip_count(organization, version, setup.weekday)

      apply_read(
        view,
        apply_headers() <> "\n08:30\t08:35\t08:40\n09:00\t09:05\t09:10"
      )

      path = apply_redirect_path(version, setup.route, setup)
      redirect = render_click(view, "paste_apply")
      assert {:error, {:live_redirect, %{to: ^path}}} = redirect

      assert service_trip_count(organization, version, setup.weekday) == before + 2

      assert %Trip{trip_id: "PASTE28-0-PASTE28_WKD-0830"} =
               Repo.get_by(Trip, trip_id: "PASTE28-0-PASTE28_WKD-0830")

      assert %Trip{trip_id: "PASTE28-0-PASTE28_WKD-0900"} =
               Repo.get_by(Trip, trip_id: "PASTE28-0-PASTE28_WKD-0900")

      {:ok, _schedules, html} = follow_redirect(redirect, conn)
      assert html =~ "Added 2 trips"
      assert html =~ "Vehicles needed"
    end

    test "a new timing created through the page carries today's date stamp",
         %{conn: conn, organization: organization, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      # The 08:37 middle no longer matches Standard's five-minute dwell,
      # so the plan mints a new timing through the production input path
      # (no test-supplied stamp).
      text = apply_headers() <> "\n08:30\t08:37\t08:40"
      apply_read(view, text)
      assert has_element?(view, "#paste-apply", "Apply 1 change")

      path = apply_redirect_path(version, setup.route, setup)
      redirect = render_click(view, "paste_apply")
      assert {:error, {:live_redirect, %{to: ^path}}} = redirect

      stamp = Calendar.strftime(Date.utc_today(), "%b %-d")
      expected = "Pasted #{stamp} · A"
      assert expected =~ ~r/^Pasted [A-Z][a-z]{2} \d{1,2} · A$/

      {:ok, _schedules, html} = follow_redirect(redirect, conn)
      assert html =~ "Created timing: #{expected}."

      import Ecto.Query, only: [from: 2]

      assert Repo.one!(
               from(t in TimedPattern,
                 where:
                   t.organization_id == ^organization.id and
                     t.gtfs_version_id == ^version.id and t.name == ^expected
               )
             ) != nil
    end

    test "a demoted user sees the permission notice and nothing is written",
         %{conn: conn, organization: organization, user: user, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      apply_read(view, apply_headers() <> "\n08:30\t08:35\t08:40")
      assert has_element?(view, "#paste-apply", "Apply 1 change")

      before = service_trip_count(organization, version, setup.weekday)

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      assert {:ok, _membership} = Accounts.delete_user_org_membership(membership)

      render_click(view, "paste_apply")
      refute_redirected(view)

      assert has_element?(
               view,
               "#paste-notice-permission",
               "Nothing was applied. You can’t edit this version any more."
             )

      assert service_trip_count(organization, version, setup.weekday) == before
      assert Repo.get_by(Trip, trip_id: "PASTE28-0-PASTE28_WKD-0830") == nil
    end

    test "adds that would mix listed trips with frequency service show the refusal",
         %{conn: conn, organization: organization, version: version} = context do
      setup = apply_setup(context)

      # Saturday frequency service already runs on the Main pattern, so listed
      # Saturday trips would share its dates for the first time (R9).
      saturday_only = %{monday: 0, tuesday: 0, wednesday: 0, thursday: 0, friday: 0, saturday: 1}

      calendar_fixture(
        organization.id,
        version.id,
        Map.put(saturday_only, :service_id, "PASTE28_SATF")
      )

      calendar_fixture(
        organization.id,
        version.id,
        Map.put(saturday_only, :service_id, "PASTE28_SAT")
      )

      schedule_trip_fixture(organization.id, version.id, setup.route.route_id, setup.main, %{
        service_id: "PASTE28_SATF",
        trip_id: "PASTE28_FREQ",
        start_time: "09:00:00"
      })

      frequency_fixture(organization.id, version.id, "PASTE28_FREQ", %{
        start_time: "09:00:00",
        end_time: "12:00:00",
        headway_secs: 1200
      })

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))

      _html =
        follow(
          view,
          paste_path(version, setup.route, %{
            "service_id" => "PASTE28_SAT",
            "direction" => "0",
            "pattern" => setup.main.pattern.id
          })
        )

      apply_read(view, apply_headers() <> "\n08:30\t08:35\t08:40")
      assert has_element?(view, "#paste-apply", "Apply 1 change")

      render_click(view, "paste_apply")
      refute_redirected(view)

      assert has_element?(view, "#paste-notice-mixed-service", "Nothing was applied.")

      assert has_element?(
               view,
               "#paste-notice-mixed-service",
               "PASTE28_SAT, PASTE28_SATF already run frequency service on this pattern."
             )

      assert service_trip_count(organization, version, "PASTE28_SAT") == 0
    end

    test "a stale plan keeps the text and decisions and offers Review again",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      text = apply_headers() <> "\n08:30\t08:35\t08:40\n09:00\t09:05\t09:10"
      apply_read(view, text)
      render_click(view, "paste_skip", %{"row" => "2"})
      assert has_element?(view, "#paste-rows #paste-row-2", "Skipped")

      # An edit to the pattern timing after the review stales the plan.
      setup.main.rows
      |> hd()
      |> Ecto.Changeset.change(%{departure_offset: 61})
      |> Repo.update!()

      render_click(view, "paste_apply")
      refute_redirected(view)

      assert has_element?(view, "#paste-notice-stale", "Nothing was applied")
      assert has_element?(view, "#paste-review-again", "Review again")

      # The skip decision stays on the visible review.
      assert has_element?(view, "#paste-rows #paste-row-2", "Skipped")

      # The text stays behind the collapsed step.
      render_click(view, "edit_source")
      assert view |> element("#paste-source") |> render() =~ "08:30"
      assert view |> element("#paste-source") |> render() =~ "09:00"
      assert has_element?(view, "#paste-notice-stale", "Nothing was applied")

      # Review again rebuilds around the kept paste and clears the notice.
      render_click(view, "paste_review_again")
      refute has_element?(view, "#paste-notice-stale")
      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-rows #paste-row-2", "Skipped")
    end

    @tag :scope_security
    test "a deleted route refuses the apply with the failed notice and a reference",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      apply_read(view, apply_headers() <> "\n08:30\t08:35\t08:40")
      assert has_element?(view, "#paste-apply", "Apply 1 change")

      # The scope no longer resolves — the same `:not_found` a foreign
      # organization, version, route or calendar rolls back — so the
      # write is refused and the paste stays.
      Repo.delete!(setup.route)

      render_click(view, "paste_apply")
      refute_redirected(view)

      notice = view |> element("#paste-notice-failed") |> render()
      assert notice =~ "Nothing was applied. The schedule couldn’t be saved."
      assert notice =~ ~r/Reference [0-9a-f]{4}-[0-9a-f]{4}/
      assert has_element?(view, "#paste-try-again", "Try again")

      render_click(view, "edit_source")
      assert view |> element("#paste-source") |> render() =~ "08:30"
    end

    test "discarding asks first and clears the paste on confirm",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      apply_read(view, apply_headers() <> "\n08:30\t08:35\t08:40")
      assert has_element?(view, "#paste-review")

      render_click(view, "paste_discard")
      assert has_element?(view, "#paste-discard-confirm", "Discard this paste?")

      render_click(view, "paste_discard_cancel")
      refute has_element?(view, "#paste-discard-confirm")
      assert has_element?(view, "#paste-review")

      render_click(view, "paste_discard")
      render_click(view, "paste_discard_confirm")
      refute has_element?(view, "#paste-discard-confirm")
      refute has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-source")
      refute view |> element("#paste-source") |> render() =~ "08:30"
    end

    test "form recovery during an apply shows the unknown notice instead of re-applying",
         %{conn: conn, organization: organization, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      text = apply_headers() <> "\n08:30\t08:35\t08:40"
      apply_read(view, text)

      before = service_trip_count(organization, version, setup.weekday)

      # The reconnect re-sends the form with the Apply click's flag set;
      # the handler rebuilds nothing twice and writes nothing.
      render_change(view, "input", %{
        "paste" => %{
          "text" => text,
          "layout" => "auto",
          "header" => "true",
          "mode" => "add",
          "decisions" => Jason.encode!(%{}),
          "applying" => "true"
        }
      })

      refute_redirected(view)

      assert has_element?(
               view,
               "#paste-notice-unknown",
               "It isn’t known whether the changes were saved."
             )

      assert has_element?(view, "#paste-open-schedules", "Open Schedules")
      assert has_element?(view, "#paste-unknown-review-again", "Review again")
      assert service_trip_count(organization, version, setup.weekday) == before
      assert Repo.get_by(Trip, trip_id: "PASTE28-0-PASTE28_WKD-0830") == nil
    end

    test "form recovery without an apply in flight shows the reconnected notice",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      text = apply_headers() <> "\n08:30\t08:35\t08:40"

      # A reconnect into a new process re-sends the form with the text
      # still blank here, so the review rebuilds and the notice shows.
      render_change(view, "input", %{
        "paste" => %{
          "text" => text,
          "layout" => "auto",
          "header" => "true",
          "mode" => "add",
          "decisions" => Jason.encode!(%{"1" => %{"skip" => true}})
        }
      })

      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-rows #paste-row-1", "Skipped")

      assert has_element?(
               view,
               "#paste-notice-reconnected",
               "Reconnected. Your paste was restored."
             )
    end

    # Step 31: the textarea unmounts with the collapsed source step, so the
    # text, layout and header ride hidden backups that LiveView form
    # recovery replays on a socket reconnect (the browser journey asserts
    # the restore end to end; here the render contract).
    test "the collapsed source carries hidden text backups for form recovery",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      text = apply_headers() <> "\n08:30\t08:35\t08:40"
      _html = apply_read(view, text)

      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-source-summary")
      refute has_element?(view, "#paste-source")

      assert view |> element("#paste-source-text") |> render() =~ "08:30"
      assert has_element?(view, "#paste-source-layout")
      assert has_element?(view, "#paste-source-header")
    end
  end

  # Step 30: the leave and version-switch guards. A version switch with
  # pasted text opens `#paste-switch-confirm` and waits for confirmation;
  # the Schedules tab (via the `.PasteLeaveGuard` hook's
  # `paste_leave_guard`) opens `#paste-leave-confirm`; with no text both
  # navigate at once. The page's own Open Schedules link asks through
  # `data-confirm` while the unknown notice holds the paste.
  describe "leaving and version guards" do
    setup :editor_scope

    defp guard_open(view, version, route, paste) do
      follow(
        view,
        paste_path(version, route, %{
          "service_id" => paste.weekday,
          "direction" => "0",
          "pattern" => paste.main.pattern.id
        })
      )
    end

    defp guard_text(view) do
      render_change(view, "input", %{
        "paste" => %{
          "text" => "Trip\tPaste Stop 1\n101\t06:00",
          "layout" => "auto",
          "header" => "true"
        }
      })
    end

    defp guard_schedules(version, route, paste) do
      query =
        URI.encode_query([
          {"service_id", paste.weekday},
          {"direction", "0"},
          {"pattern", paste.main.pattern.id}
        ])

      "/gtfs/#{version.id}/routes/#{route.route_id}/schedules?#{query}"
    end

    test "switching versions with a paste opens the confirm and waits",
         %{conn: conn, organization: organization, version: version} = context do
      paste = paste_route(context)
      other = gtfs_version_fixture(organization.id)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = guard_open(view, version, paste.route, paste)
      guard_text(view)

      render_click(view, "switch_gtfs_version", %{"version" => other.id})
      refute_redirected(view)

      assert has_element?(
               view,
               "#paste-switch-confirm",
               "Switch to #{other.name}?"
             )

      assert has_element?(view, "#paste-switch-confirm-cancel", "Keep reviewing")
      assert has_element?(view, "#paste-switch-confirm-confirm", "Switch version")

      # Cancelling keeps the paste on the page.
      render_click(view, "paste_switch_cancel")
      refute has_element?(view, "#paste-switch-confirm")
      assert view |> element("#paste-source") |> render() =~ "06:00"

      # Confirming navigates to the other version's paste page.
      render_click(view, "switch_gtfs_version", %{"version" => other.id})

      {:error, {:live_redirect, %{to: path}}} =
        render_click(view, "paste_switch_confirm")

      assert path =~ "/gtfs/#{other.id}/routes/#{paste.route.route_id}/schedules/paste"
    end

    test "switching versions with no text navigates immediately",
         %{conn: conn, organization: organization, version: version} = context do
      paste = paste_route(context)
      other = gtfs_version_fixture(organization.id)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = guard_open(view, version, paste.route, paste)

      {:error, {:live_redirect, %{to: path}}} =
        render_click(view, "switch_gtfs_version", %{"version" => other.id})

      assert path =~ "/gtfs/#{other.id}/routes/#{paste.route.route_id}/schedules/paste"
    end

    test "leaving through the Schedules tab with text asks first",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = guard_open(view, version, paste.route, paste)
      guard_text(view)

      schedules = guard_schedules(version, paste.route, paste)
      render_click(view, "paste_leave_guard", %{"to" => schedules})
      refute_redirected(view)

      assert has_element?(
               view,
               "#paste-leave-confirm",
               "Leave without applying?"
             )

      assert has_element?(view, "#paste-leave-confirm-cancel", "Keep reviewing")
      assert has_element?(view, "#paste-leave-confirm-confirm", "Leave page")

      # Cancelling keeps the paste on the page.
      render_click(view, "paste_leave_cancel")
      refute has_element?(view, "#paste-leave-confirm")
      assert view |> element("#paste-source") |> render() =~ "06:00"

      # Confirming leaves for the intercepted path.
      render_click(view, "paste_leave_guard", %{"to" => schedules})

      {:error, {:live_redirect, %{to: ^schedules}}} =
        render_click(view, "paste_leave_confirm")
    end

    test "the leave guard navigates immediately with no text",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = guard_open(view, version, paste.route, paste)

      schedules = guard_schedules(version, paste.route, paste)

      {:error, {:live_redirect, %{to: ^schedules}}} =
        render_click(view, "paste_leave_guard", %{"to" => schedules})
    end

    test "the leave guard ignores a protocol-relative path",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = guard_open(view, version, paste.route, paste)

      render_click(view, "paste_leave_guard", %{"to" => "//evil.example/gtfs"})

      assert has_element?(view, "#paste-source")
      refute has_element?(view, "#paste-leave-confirm")
    end

    test "the leave guard hook watches the paste form",
         %{conn: conn, version: version} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(version, paste.route))
      _html = guard_open(view, version, paste.route, paste)

      # Colocated hooks render with the module-qualified hook name, so
      # match the stable id plus the ignore marker and the guard name.
      assert has_element?(view, "#paste-leave-guard[phx-update='ignore']")
      assert view |> element("#paste-leave-guard") |> render() =~ "PasteLeaveGuard"
    end

    test "Open Schedules asks first while the unknown notice holds the paste",
         %{conn: conn, version: version} = context do
      setup = apply_setup(context)

      {:ok, view, _html} = live(conn, paste_path(version, setup.route))
      _html = apply_open(view, version, setup.route, setup)

      text = apply_headers() <> "\n08:30\t08:35\t08:40"
      apply_read(view, text)

      render_change(view, "input", %{
        "paste" => %{
          "text" => text,
          "layout" => "auto",
          "header" => "true",
          "mode" => "add",
          "decisions" => Jason.encode!(%{}),
          "applying" => "true"
        }
      })

      assert has_element?(view, "#paste-notice-unknown")
      assert view |> element("#paste-open-schedules") |> render() =~ "data-confirm"

      assert view |> element("#paste-open-schedules") |> render() =~
               "Leave without applying?"

      {:error, {:live_redirect, %{to: path}}} =
        view |> element("#paste-open-schedules") |> render_click()

      assert path =~ "/routes/#{setup.route.route_id}/schedules?"
    end
  end
end
