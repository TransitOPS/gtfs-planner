defmodule GtfsPlannerWeb.Gtfs.RoutePatternWorkspaceTest do
  @moduledoc """
  The editor's shell: the header and its tab chips, the Pattern actions menu and
  the page-wide save bar, which names the current task, stays unavailable until
  something is unsaved, and always says the save changes a published version.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.Gtfs.RoutePatternAlignmentComponents

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "route-pattern-shell-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "pattern-shell-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  # A route with a three-stop pattern and one timing; `timed?: false` leaves the
  # pattern without a timing.
  defp pattern_context(organization, version, route_id, opts \\ []) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: route_id,
        route_short_name: route_id,
        route_long_name: "#{route_id} corridor"
      })

    stops =
      for index <- 1..3 do
        stop_fixture(organization.id, version.id, %{
          stop_id: "#{route_id}_S#{index}",
          stop_name: "#{route_id} Stop #{index}",
          location_type: 0
        })
      end

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "P-#{route_id}",
        route_pattern_name: "Pattern #{route_id}",
        headsign: "Harbor",
        direction_id: 0
      })

    occurrences =
      stops
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, position} ->
        route_pattern_stop_fixture(pattern, stop.stop_id, position)
      end)

    if Keyword.get(opts, :timed?, true) do
      timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

      for {occurrence, {arrival, departure}} <-
            Enum.zip(occurrences, [{0, 0}, {240, 300}, {600, 660}]) do
        timed_pattern_stop_fixture(timing, occurrence, %{
          arrival_offset: arrival,
          departure_offset: departure
        })
      end
    end

    %{route: route, pattern: pattern, stops: stops}
  end

  defp pattern_path(version, %{route: route, pattern: pattern}, suffix) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{suffix}"
  end

  describe "the header" do
    setup :editor_scope

    test "names the route and pattern, and counts what the pattern holds",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "SHELL1")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=stops"))

      assert has_element?(view, "h1#pattern-title", "Pattern SHELL1")
      assert has_element?(view, "#pattern-crumbs", "SHELL1 corridor")
      assert has_element?(view, "#pattern-back", "Patterns")
      assert has_element?(view, "#pattern-direction", "Direction 0")
      assert has_element?(view, "#pattern-direction", "toward Harbor")
      assert has_element?(view, "#pattern-stop-count", "3 stops")
      assert has_element?(view, "#pattern-trip-total", "0 trips use this pattern")
      assert has_element?(view, "#pattern-timing-total", "1 timing")
      assert has_element?(view, "#edit-status", "Saved in this version")
    end

    test "counts on the tabs give way to an Unsaved chip while a task has changes",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "SHELL2")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=stops"))

      assert has_element?(view, "#pattern-task-stops", "3")
      refute has_element?(view, "#pattern-task-stops", "Unsaved")
      assert has_element?(view, "#pattern-task-timings", "Running times")

      render_click(view, "remove_stop", %{"index" => "3"})

      assert has_element?(view, "#pattern-task-stops", "Unsaved")
      assert has_element?(view, "#edit-status", "Unsaved changes")
      refute has_element?(view, "#pattern-task-details", "Unsaved")

      render_change(view, "validate_details", %{"pattern" => %{"name" => "Renamed"}})

      assert has_element?(view, "#pattern-task-details", "Unsaved")
    end

    test "Copy pattern and Delete pattern share one Pattern actions menu",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "SHELL3")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=stops"))

      assert has_element?(
               view,
               "#pattern-actions-trigger[aria-haspopup='menu']",
               "Pattern actions"
             )

      assert has_element?(
               view,
               "#pattern-actions-panel #pattern-copy[role='menuitem']",
               "Copy pattern"
             )

      assert has_element?(
               view,
               "#pattern-actions-panel #pattern-delete[role='menuitem']",
               "Delete pattern"
             )
    end

    test "a new pattern has a trail, a heading and no Pattern actions",
         %{conn: conn, organization: organization, version: version} do
      %{route: route} = pattern_context(organization, version, "SHELL4")

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/new")

      assert has_element?(view, "h1#pattern-title", "Create pattern")
      assert has_element?(view, "#pattern-crumbs [aria-current='page']", "New pattern")
      assert has_element?(view, "#edit-status", "New pattern")
      assert has_element?(view, "#pattern-trip-total", "No trips yet")
      refute has_element?(view, "#pattern-actions")
    end
  end

  describe "the save bar" do
    setup :editor_scope

    test "Save stops is unavailable until a stop change is staged",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "BAR1")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=stops"))

      assert has_element?(view, "#pattern-save-stops[disabled]", "Save stops")
      assert has_element?(view, "#pattern-save-status", "Nothing to save yet.")

      render_click(view, "remove_stop", %{"index" => "3"})

      refute has_element?(view, "#pattern-save-stops[disabled]")
      assert has_element?(view, "#pattern-save-status", "You have unsaved stop changes.")
    end

    test "every task's bar says the save changes a published version",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "BAR2")

      for {task, primary, label} <- [
            {"stops", "#pattern-save-stops", "Save stops"},
            {"timings", "#timing-save", "Save running times"},
            {"details", "#pattern-details-submit", "Save details"},
            {"alignment", "#alignment-save", "Save map line"}
          ] do
        {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=#{task}"))

        assert has_element?(view, "#pattern-save-bar #{primary}", label), "#{task} names its save"

        assert has_element?(
                 view,
                 "#pattern-save-bar #published-version-notice",
                 "#{version.name}, a published version"
               ),
               "#{task} names the published version"
      end
    end

    test "Save details is a submit for the details form and waits for a change",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "BAR3")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=details"))

      assert has_element?(
               view,
               "#pattern-details-submit[type='submit'][form='pattern-details-form'][disabled]"
             )

      render_change(view, "validate_details", %{"pattern" => %{"name" => "Renamed"}})

      refute has_element?(view, "#pattern-details-submit[disabled]")
      assert has_element?(view, "#pattern-save-status", "You have unsaved detail changes.")

      # Changing the name back is no longer a change.
      render_change(view, "validate_details", %{"pattern" => %{"name" => "Pattern BAR3"}})

      assert has_element?(view, "#pattern-details-submit[disabled]")
    end

    test "Save running times follows the selected timing's edits and offers to discard them",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "BAR4")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=timings"))

      assert has_element?(view, "#timing-save[disabled]")
      refute has_element?(view, "#discard-timing-drafts")

      render_change(view, "validate_timing_row", %{
        "_target" => ["timing", "2", "departure"],
        "timing" => %{"2" => %{"arrival" => "04:00", "departure" => "06:00"}}
      })

      refute has_element?(view, "#timing-save[disabled]")
      assert has_element?(view, "#pattern-save-status", "You have unsaved running-time edits.")

      assert has_element?(
               view,
               "#pattern-save-bar #discard-timing-drafts",
               "Discard timing edits"
             )

      view |> element("#discard-timing-drafts") |> render_click()

      assert has_element?(view, "#timing-save[disabled]")
      refute has_element?(view, "#discard-timing-drafts")
    end

    test "a rejected save keeps its reason in the bar where the person acted",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "BAR5")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=timings"))

      render_change(view, "validate_timing_row", %{
        "_target" => ["timing", "2", "departure"],
        "timing" => %{"2" => %{"arrival" => "04:00", "departure" => "03:00"}}
      })

      render_click(view, "save_timing")

      assert has_element?(
               view,
               "#pattern-save-status",
               "Departure must be at or after arrival"
             )

      assert has_element?(view, "#timing-err-2", "BAR5 Stop 2")
      assert has_element?(view, "#timing-departure-2[aria-describedby='timing-error-2']")
    end

    test "a pattern with no timing has nothing to save on Running times",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "BAR6", timed?: false)

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=timings"))

      assert has_element?(view, "#pattern-timings-empty", "No timings yet")
      assert has_element?(view, "#timing-add.btn-primary")
      refute has_element?(view, "#pattern-save-bar")
    end

    test "creating a pattern names what is still missing, then says it is ready",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, stops: [first, second, _third]} =
        pattern_context(organization, version, "BAR7")

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/new")

      assert has_element?(view, "#pattern-details-submit", "Create pattern")
      refute has_element?(view, "#pattern-details-submit[disabled]")

      assert has_element?(
               view,
               "#pattern-save-status",
               "add a pattern name and at least two stops"
             )

      render_change(view, "validate_details", %{"pattern" => %{"name" => "Harbor loop"}})

      assert has_element?(view, "#pattern-save-status", "add at least two stops")
      refute has_element?(view, "#pattern-save-status", "pattern name")

      render_click(view, "switch_task", %{"task" => "stops"})

      assert has_element?(view, "#pattern-create", "Create pattern")

      for stop <- [first, second] do
        render_change(view, "live_select_change", %{
          "id" => "pattern-stop-search",
          "text" => stop.stop_name
        })

        render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => stop.stop_id}})
      end

      assert has_element?(view, "#pattern-save-status", "Ready to create")
      assert has_element?(view, "#pattern-task-stops", "2")
      assert has_element?(view, "#pattern-task-details", "Started")
    end
  end

  describe "the stop list" do
    setup :editor_scope

    test "marks a staged stop as new and unsaved, and a saved stop as neither",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "LIST1")

      extra =
        stop_fixture(organization.id, version.id, %{
          stop_id: "LIST1_EXTRA",
          stop_name: "LIST1 Extra",
          location_type: 0
        })

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=stops"))

      refute has_element?(view, "#pattern-stops", "New · unsaved")

      render_change(view, "live_select_change", %{
        "id" => "pattern-stop-search",
        "text" => "Extra"
      })

      render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => extra.stop_id}})

      assert has_element?(view, "#pattern-stop-4", "New · unsaved")
      refute has_element?(view, "#pattern-stop-1", "New · unsaved")
    end

    test "says how many timings an edit reaches, in the singular for one",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "LIST2")

      [timing] = stored_timings(context.pattern.id)

      trip =
        trip_fixture(organization.id, version.id, context.route.route_id, %{trip_id: "LIST2_T"})

      trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: context.pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=stops"))

      assert has_element?(view, "#pattern-stops-impact", "1 trip across 1 timing.")
      refute has_element?(view, "#pattern-stop-2-move-up")
    end
  end

  describe "the alignment Save state" do
    test "is unavailable for a viewer, offline, while saving, while generating and with no draft" do
      base = %{
        alignment: %{status: %{missing: 0, blocked: 0, export: :current}},
        editable?: true,
        offline?: false,
        applying?: false,
        dirty_positions: [2],
        generating?: false
      }

      assert %{enabled?: true} = RoutePatternAlignmentComponents.save_state(base)

      viewer = RoutePatternAlignmentComponents.save_state(%{base | editable?: false})
      refute viewer.enabled?
      assert viewer.title == "Only editors can save the map line."

      offline = RoutePatternAlignmentComponents.save_state(%{base | offline?: true})
      refute offline.enabled?
      assert offline.title == "Reconnect before saving."

      applying = RoutePatternAlignmentComponents.save_state(%{base | applying?: true})
      refute applying.enabled?
      assert applying.title == "Saving your map line…"

      generating = RoutePatternAlignmentComponents.save_state(%{base | generating?: true})
      refute generating.enabled?
      assert generating.title == "Finish or cancel generation before saving."

      clean = RoutePatternAlignmentComponents.save_state(%{base | dirty_positions: []})
      refute clean.enabled?
      assert clean.title == "Edit a path to enable saving."
    end
  end
end
