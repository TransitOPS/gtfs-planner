defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesSelectionTest do
  # EV-26: keyboard selection on the Schedules grid — `select_range`, `select_all`
  # and the filter-change message — through the production composition (spec 18,
  # step 27; AC-8; CL-13; rejects FH-34's hidden-row half).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so LiveView event -> the scoped read through `Gtfs.load_route_schedule/4` ->
  # the server-held selection -> the re-streamed section is exercised end to end.
  # The rows are asserted against the rendered checkboxes as well as the assigns,
  # and a row the current filters hid — another calendar, another pattern, a
  # forged UUID — never enters the selection. The expected sets are literal trip
  # UUIDs the fixtures created, never derived from the code under test.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_selection_test.exs`
  # (EV-26, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.GtfsFixtures, only: [schedule_pattern_fixture: 3, schedule_trip_fixture: 5]
  import GtfsPlanner.ScheduleEditingFixtures

  @route_id "EDT_SEL"
  @pattern_name "SEL-A Main"
  @cross_pattern_name "SEL-B Cross"
  @stops [{"SEL_A", 0, 0, 1}, {"SEL_B", 300, 330, 1}, {"SEL_C", 720, 720, 1}]

  # One row per trip, 30 minutes apart, so a range between two of them is
  # unambiguous and every expected selected id is literal.
  @starts %{
    "SEL_T0600" => "06:00:00",
    "SEL_T0630" => "06:30:00",
    "SEL_T0700" => "07:00:00",
    "SEL_T0730" => "07:30:00",
    "SEL_T0800" => "08:00:00"
  }

  setup context do
    scope = editing_scope!(@route_id, %{route_pattern_name: @pattern_name, stops: @stops})

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "select_range" do
    test "selects the visible rows between the two ends inclusive", %{conn: conn, scope: scope} do
      trips = selection_trips!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "select_range", %{
        "from" => trips["SEL_T0600"].id,
        "to" => trips["SEL_T0700"].id
      })

      assigns = assigns(view)

      assert assigns.selected_ids ==
               MapSet.new([
                 trips["SEL_T0600"].id,
                 trips["SEL_T0630"].id,
                 trips["SEL_T0700"].id
               ])

      assert assigns.selected_count == 3
      assert checked?(view, "SEL_T0600")
      assert checked?(view, "SEL_T0630")
      assert checked?(view, "SEL_T0700")
      refute checked?(view, "SEL_T0730")
      refute checked?(view, "SEL_T0800")
      assert renders(view, "#schedules-view-counts") =~ "5 trips"
    end

    test "a reversed range selects the same rows and replaces the previous selection",
         %{conn: conn, scope: scope} do
      trips = selection_trips!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trips["SEL_T0800"].id})
      assert assigns(view).selected_count == 1

      render_hook(grid(view), "select_range", %{
        "from" => trips["SEL_T0730"].id,
        "to" => trips["SEL_T0630"].id
      })

      assigns = assigns(view)

      assert assigns.selected_ids ==
               MapSet.new([
                 trips["SEL_T0630"].id,
                 trips["SEL_T0700"].id,
                 trips["SEL_T0730"].id
               ])

      assert assigns.selected_count == 3
      refute checked?(view, "SEL_T0800")
      refute checked?(view, "SEL_T0600")
    end

    test "a clamped range at one row selects that row", %{conn: conn, scope: scope} do
      trips = selection_trips!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "select_range", %{
        "from" => trips["SEL_T0700"].id,
        "to" => trips["SEL_T0700"].id
      })

      assigns = assigns(view)
      assert assigns.selected_ids == MapSet.new([trips["SEL_T0700"].id])
      assert assigns.selected_count == 1
      assert checked?(view, "SEL_T0700")
    end

    test "a forged, hidden or malformed end selects nothing", %{conn: conn, scope: scope} do
      trips = selection_trips!(scope)
      %{saturday: saturday} = weekday_and_saturday!(scope)
      hidden = linked_trip!(scope, "09:00:00", %{trip_id: "SEL_SAT", service_id: saturday})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      # The trip on the other calendar is not part of this page at all.
      refute has_element?(view, "#trip-select-SEL_SAT")

      render_hook(grid(view), "select_range", %{
        "from" => hidden.id,
        "to" => trips["SEL_T0700"].id
      })

      render_hook(grid(view), "select_range", %{
        "from" => Ecto.UUID.generate(),
        "to" => trips["SEL_T0700"].id
      })

      render_hook(grid(view), "select_range", %{})
      render_hook(grid(view), "select_range", %{"from" => 7, "to" => trips["SEL_T0700"].id})

      assigns = assigns(view)
      assert assigns.selected_ids == MapSet.new()
      assert assigns.selected_count == 0
      refute checked?(view, "SEL_T0700")

      # A valid range still works after the refusals.
      render_hook(grid(view), "select_range", %{
        "from" => trips["SEL_T0700"].id,
        "to" => trips["SEL_T0730"].id
      })

      assert assigns(view).selected_count == 2
    end

    test "a range that crosses sections selects the rows between in document order",
         %{conn: conn, scope: scope} do
      trips = selection_trips!(scope)
      {cross_trip, _bundle} = cross_pattern_trip!(scope, "SEL_CROSS", "09:30:00")
      {:ok, view, _html} = live(conn, schedules_path(scope))

      # The cross-pattern section is rendered after the main one.
      assert [
               %{pattern: %{route_pattern_name: @pattern_name}},
               %{pattern: %{route_pattern_name: @cross_pattern_name}}
             ] = assigns(view).sections_list

      render_hook(grid(view), "select_range", %{
        "from" => trips["SEL_T0730"].id,
        "to" => cross_trip.id
      })

      assigns = assigns(view)

      assert assigns.selected_ids ==
               MapSet.new([trips["SEL_T0730"].id, trips["SEL_T0800"].id, cross_trip.id])

      assert assigns.selected_count == 3
      assert checked?(view, "SEL_T0730")
      assert checked?(view, "SEL_T0800")
      assert checked?(view, "SEL_CROSS")
      refute checked?(view, "SEL_T0700")
    end
  end

  describe "select_all" do
    test "selects every visible row and no hidden row", %{conn: conn, scope: scope} do
      trips = selection_trips!(scope)
      %{saturday: saturday} = weekday_and_saturday!(scope)
      hidden = linked_trip!(scope, "09:00:00", %{trip_id: "SEL_SAT", service_id: saturday})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      # The page shows the calendar with the most trips, so the Saturday trip is
      # not on screen and cannot be reached by name.
      refute has_element?(view, "#trip-select-SEL_SAT")

      render_hook(grid(view), "select_all", %{})

      assigns = assigns(view)
      assert assigns.selected_ids == MapSet.new(Enum.map(Map.values(trips), & &1.id))
      assert assigns.selected_count == 5
      refute MapSet.member?(assigns.selected_ids, hidden.id)

      assert render(view) =~ "5 trips selected"

      assert has_element?(
               view,
               "input#section-#{scope.bundle.pattern.route_pattern_id}-select-all[checked]"
             )

      assert Enum.all?(@starts |> Map.keys(), &checked?(view, &1))
    end

    test "selects only the rows the current filter shows", %{conn: conn, scope: scope} do
      selection_trips!(scope)
      {cross_trip, bundle} = cross_pattern_trip!(scope, "SEL_CROSS", "09:30:00")

      {:ok, view, _html} =
        live(conn, schedules_path(scope, %{"pattern" => bundle.pattern.id}))

      # The main pattern's rows are hidden by the pattern filter.
      refute has_element?(view, "#trip-select-SEL_T0700")

      render_hook(grid(view), "select_all", %{})

      assigns = assigns(view)
      assert assigns.selected_ids == MapSet.new([cross_trip.id])
      assert assigns.selected_count == 1
      assert checked?(view, "SEL_CROSS")
    end
  end

  describe "a filter change" do
    test "a calendar change with a selection shows the cleared message", %{
      conn: conn,
      scope: scope
    } do
      trips = selection_trips!(scope)
      %{saturday: saturday} = weekday_and_saturday!(scope)
      linked_trip!(scope, "09:00:00", %{trip_id: "SEL_SAT", service_id: saturday})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trips["SEL_T0600"].id})
      render_click(view, "toggle_trip", %{"trip" => trips["SEL_T0700"].id})
      assert has_element?(view, "#schedules-bulk-toolbar")

      render_patch(view, schedules_path(scope, %{"service_id" => saturday}))

      assigns = assigns(view)
      assert assigns.selected_ids == MapSet.new()
      assert assigns.selected_count == 0

      assert assigns.outcome == %{
               tone: :info,
               text: "Selection cleared because the filter changed.",
               undo?: false
             }

      refute has_element?(view, "#schedules-bulk-toolbar")
      refute checked?(view, "SEL_T0600")
      assert has_element?(view, "#trip-select-SEL_SAT")
    end

    test "a patch with nothing selected reports nothing", %{conn: conn, scope: scope} do
      selection_trips!(scope)
      %{saturday: saturday} = weekday_and_saturday!(scope)

      saturday_trip =
        linked_trip!(scope, "09:00:00", %{trip_id: "SEL_SAT", service_id: saturday})

      {:ok, view, _html} = live(conn, schedules_path(scope))

      # The first render reports nothing.
      assert assigns(view).outcome == nil

      # A filter change with an empty selection says nothing about a selection.
      render_patch(view, schedules_path(scope, %{"service_id" => saturday}))
      assert assigns(view).outcome == nil

      # Neither does a dispatch after the selection was cleared explicitly.
      render_click(view, "toggle_trip", %{"trip" => saturday_trip.id})
      render_click(view, "clear_selection")
      render_patch(view, schedules_path(scope, %{"direction" => "0"}))
      assert assigns(view).outcome == nil
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp selection_trips!(scope) do
    Map.new(@starts, fn {trip_id, start} ->
      {trip_id, linked_trip!(scope, start, %{trip_id: trip_id})}
    end)
  end

  defp cross_pattern_trip!(scope, trip_id, start) do
    bundle =
      schedule_pattern_fixture(scope.organization.id, scope.version.id, %{
        route_id: @route_id,
        route_pattern_name: @cross_pattern_name,
        route_pattern_sort_order: 1,
        stops: @stops
      })

    %{trip: trip} =
      schedule_trip_fixture(scope.organization.id, scope.version.id, @route_id, bundle, %{
        service_id: scope.service,
        state: "linked",
        trip_id: trip_id,
        start_time: start
      })

    {trip, bundle}
  end

  defp schedules_path(scope, params \\ %{}) do
    path = "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"

    case URI.encode_query(params) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp grid(view), do: element(view, "#schedules-grid")

  defp checked?(view, trip_id), do: has_element?(view, "input#trip-select-#{trip_id}[checked]")

  defp renders(view, selector), do: view |> element(selector) |> render()

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
