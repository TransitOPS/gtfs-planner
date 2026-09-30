defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesCustomFilterTest do
  # EV-36: the Custom times filter on the Schedules page (spec 18, step 38; CL-13,
  # AC-22; FH-32).
  #
  # Every case mounts through the authenticated router with no injected assigns, so
  # the rows, the chip's count and the filtered view all come from the production
  # composition: RouteSchedulesLive -> Gtfs facade -> Schedules read ->
  # ScheduleComponents.filter_bar/1 and section/1. Expected values are literal and
  # hand-derived from the fixtures; none is computed by the code under test. The
  # chip's count is asserted from independent fixture knowledge (the number of
  # custom trips the read must show), and persisted clocks are re-read through
  # Repo by `stop_time_clocks/1`.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_custom_filter_test.exs`
  # (EV-36, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  @route_id "CF"
  @headsign "CF Dest"

  # The default scope stops are A, B and C in sequence, all timepoints, so every
  # stop is a column and position 2 is stop B.
  @custom_c_times [
    {"A", "10:00:00", "10:00:00"},
    {"B", "10:10:00", "10:10:00"},
    {"C", "10:20:00", "10:20:00"}
  ]
  @second_c_times [
    {"A", "11:00:00", "11:00:00"},
    {"B", "11:10:00", "11:10:00"},
    {"C", "11:20:00", "11:20:00"}
  ]

  setup context do
    scope = editing_scope!(@route_id)

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "the Custom times chip" do
    test "custom=1 shows only custom rows and hides the listed trips (FH-32)", %{
      conn: conn,
      scope: scope
    } do
      listed_trip!(scope, "CF_LISTED")
      custom_trip!(scope, @custom_c_times, %{trip_id: "CF_CUSTOM", trip_headsign: @headsign})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"custom" => "1"}))

      assert has_element?(view, "#custom-times-chip[aria-pressed='true']", "Custom times 1")
      assert has_element?(view, "#trip-CF_CUSTOM")
      refute has_element?(view, "#trip-CF_LISTED")
      # The view count follows the filtered rows, not the read's trips.
      assert has_element?(
               view,
               "#schedules-view-counts",
               "1 trip · #{scope.service} · To CF Dest"
             )

      refute has_element?(view, "#schedules-no-trips")
      refute has_element?(view, "#custom-empty")
    end

    test "the chip counts every custom row in view and toggles custom=1 both ways", %{
      conn: conn,
      scope: scope
    } do
      listed_trip!(scope, "CF_LISTED")
      custom_trip!(scope, @custom_c_times, %{trip_id: "CF_CUSTOM", trip_headsign: @headsign})
      second_pattern!(scope)

      {:ok, view, _html} = live(conn, schedules_path(scope))

      # Before filtering the count is the sum of both sections' custom rows.
      assert has_element?(view, "#custom-times-chip[aria-pressed='false']", "Custom times 2")
      assert has_element?(view, "#trip-CF_LISTED")
      assert has_element?(view, "#schedules-view-counts", "3 trips")

      filtered = schedules_path(scope, %{"custom" => "1", "service_id" => scope.service})
      view |> element("#custom-times-chip") |> render_click()
      assert_patch(view, filtered)
      follow(view, filtered)

      assert has_element?(view, "#custom-times-chip[aria-pressed='true']", "Custom times 2")
      assert has_element?(view, "#trip-CF_CUSTOM")
      assert has_element?(view, "#trip-CF_CUSTOM_2")
      refute has_element?(view, "#trip-CF_LISTED")
      assert has_element?(view, "#schedules-view-counts", "2 trips")

      # The chip toggles the filter back off, and the listed trip returns with it.
      bare = schedules_path(scope, %{"service_id" => scope.service})
      view |> element("#custom-times-chip") |> render_click()
      assert_patch(view, bare)
      follow(view, bare)

      assert has_element?(view, "#custom-times-chip[aria-pressed='false']", "Custom times 2")
      assert has_element?(view, "#trip-CF_LISTED")
      assert has_element?(view, "#schedules-view-counts", "3 trips")
    end

    test "the chip is hidden when nothing is custom and the filter is off", %{
      conn: conn,
      scope: scope
    } do
      listed_trip!(scope, "CF_LISTED")

      {:ok, view, _html} = live(conn, schedules_path(scope))

      refute has_element?(view, "#custom-times-chip")
      assert has_element?(view, "#schedules-view-counts", "1 trip")
    end

    test "only custom=1 is canonical; custom=0 and other spellings fall away", %{
      conn: conn,
      scope: scope
    } do
      listed_trip!(scope, "CF_LISTED")

      {:ok, view, _html} = live(conn, schedules_path(scope))
      requested = schedules_path(scope, %{"custom" => "0"})

      render_patch(view, requested)

      requested_patch = assert_patch(view)
      assert requested_patch =~ "custom=0"
      canonical = assert_patch(view)
      assert canonical == schedules_path(scope, %{"service_id" => scope.service})
      refute canonical =~ "custom"
      assert has_element?(view, "#trip-CF_LISTED")
    end
  end

  describe "the filtered-empty state" do
    test "no custom rows shows the empty card and Show all trips clears the parameter", %{
      conn: conn,
      scope: scope
    } do
      listed_trip!(scope, "CF_LISTED")

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"custom" => "1"}))

      assert has_element?(view, "#custom-times-chip[aria-pressed='true']", "Custom times 0")

      assert has_element?(
               view,
               "#custom-empty",
               "No trips with custom times on #{scope.service} · To CF Dest"
             )

      assert has_element?(
               view,
               "#custom-empty",
               "Every trip in this view follows a timing. The Custom times filter is on."
             )

      assert has_element?(view, "#clear-custom", "Show all trips")
      # The filtered-empty state is distinct from the route's first-use card.
      refute has_element?(view, "#schedules-no-trips")
      refute has_element?(view, "#trip-CF_LISTED")

      bare = schedules_path(scope, %{"service_id" => scope.service})
      view |> element("#clear-custom") |> render_click()
      assert_patch(view, bare)
      follow(view, bare)

      assert has_element?(view, "#trip-CF_LISTED")
      refute has_element?(view, "#custom-empty")
      # Nothing is custom now and the filter is off, so the chip hides too.
      refute has_element?(view, "#custom-times-chip")
    end
  end

  describe "the filtered view after a write" do
    test "a saved stop edit reloads with the filter still applied", %{conn: conn, scope: scope} do
      custom =
        custom_trip!(scope, @custom_c_times, %{trip_id: "CF_CUSTOM", trip_headsign: @headsign})

      listed_trip!(scope, "CF_LISTED")

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"custom" => "1"}))
      refute has_element?(view, "#trip-CF_LISTED")

      render_hook(grid(view), "cell_commit", cell(custom, 2, "10:12", "later"))
      assert_reply(view, %{ok: true})

      # The reload through the adapter keeps the URL's filter, so the hidden
      # listed trip stays hidden and the chip stays pressed.
      assert has_element?(view, "#custom-times-chip[aria-pressed='true']", "Custom times 1")
      assert has_element?(view, "#trip-CF_CUSTOM")
      refute has_element?(view, "#trip-CF_LISTED")
      refute has_element?(view, "#custom-empty")

      assert clocks(custom) == [
               {"10:00:00", "10:00:00"},
               {"10:12:00", "10:12:00"},
               {"10:22:00", "10:22:00"}
             ]
    end
  end

  # --- helpers ---------------------------------------------------------------

  # The second pattern carries its own custom row, so the chip's count is a sum
  # over sections rather than one section's count.
  defp second_pattern!(scope) do
    pattern =
      schedule_pattern_fixture(scope.organization.id, scope.version.id, %{
        route_id: @route_id,
        direction_id: 0,
        route_pattern_id: "CF_P2",
        route_pattern_name: "CF Secondary",
        timing_name: "All day",
        stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]
      })

    schedule_trip_fixture(
      scope.organization.id,
      scope.version.id,
      @route_id,
      pattern,
      %{
        service_id: scope.service,
        trip_id: "CF_CUSTOM_2",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: @headsign,
        stop_times: @second_c_times
      }
    )

    pattern
  end

  defp listed_trip!(scope, trip_id) do
    linked_trip!(scope, "06:00:00", %{trip_id: trip_id, trip_headsign: @headsign})
  end

  defp clocks(trip) do
    Enum.map(stop_time_clocks(trip), fn {arrival, departure, _timepoint, _pickup} ->
      {arrival, departure}
    end)
  end

  defp schedules_path(scope, params \\ %{}) do
    path = "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"

    case URI.encode_query(params) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp follow(view, path) do
    html = render_patch(view, path)
    assert_patched(view, path)
    html
  end

  defp grid(view), do: element(view, "#schedules-grid")

  defp cell(trip, position, text, mode) do
    %{"trip" => trip.id, "position" => position, "text" => text, "mode" => mode}
  end
end
