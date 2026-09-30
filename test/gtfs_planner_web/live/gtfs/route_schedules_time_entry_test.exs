defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesTimeEntryTest do
  # EV-2: the Add, Edit and Duplicate drawers read typed times with the page's
  # one R2 grammar (`GtfsPlanner.Gtfs.Schedules.TimeEntry`), so every form the
  # grid accepts is accepted in the drawers and an out-of-grammar value is
  # refused with the fixed copy and writes nothing.
  #
  # Every case mounts through the authenticated router, so the production
  # composition is exercised end to end: LiveView event -> `Gtfs` facade ->
  # `Gtfs.Schedules` transaction -> reload through the read adapter. Persisted
  # rows are asserted with independent `Repo` queries, never from rendered HTML
  # alone.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.ScheduleEditingFixtures

  @route_id "EDT_TE"

  setup context do
    scope = ScheduleEditingFixtures.editing_scope!(@route_id)

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "the Add trips drawer" do
    test "commits the compact form 605 as 06:05", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, schedules_path(scope))
      open_add_drawer(view)

      html = render_submit(view, "drawer_submit", %{"drawer" => add_params(scope, "605")})

      assert html =~ "Added 1 trip to"
      assert trip_count(scope) == 1

      assert clocks(only_trip(scope)) == [
               {"06:05:00", "06:05:00"},
               {"06:10:00", "06:10:30"},
               {"06:17:00", "06:17:00"}
             ]
    end

    test "reads the suffix form 6:05p as 18:05", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, schedules_path(scope))
      open_add_drawer(view)

      render_submit(view, "drawer_submit", %{"drawer" => add_params(scope, "6:05p")})

      assert trip_count(scope) == 1

      assert clocks(only_trip(scope)) == [
               {"18:05:00", "18:05:00"},
               {"18:10:00", "18:10:30"},
               {"18:17:00", "18:17:00"}
             ]
    end

    test "keeps the past-midnight form 25:10", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, schedules_path(scope))
      open_add_drawer(view)

      render_submit(view, "drawer_submit", %{"drawer" => add_params(scope, "25:10")})

      assert trip_count(scope) == 1

      assert clocks(only_trip(scope)) == [
               {"25:10:00", "25:10:00"},
               {"25:15:00", "25:15:30"},
               {"25:22:00", "25:22:00"}
             ]
    end

    test "refuses 7:75 with the fixed copy and writes nothing", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, schedules_path(scope))
      open_add_drawer(view)

      html = render_submit(view, "drawer_submit", %{"drawer" => add_params(scope, "7:75")})

      assert html =~ "Enter a time such as 6:05, 605, 6:05p or 25:10."
      refute html =~ ":invalid_time"

      assert_push_event(view, "focus_form_error", %{
        form_id: "trip-drawer-form",
        fallback_id: "trip-start"
      })

      assert trip_count(scope) == 0
    end
  end

  describe "the Edit and Duplicate drawers" do
    test "the Edit drawer retimes a linked trip from a suffixed reading", %{
      conn: conn,
      scope: scope
    } do
      trip = ScheduleEditingFixtures.linked_trip!(scope, "07:00:00")

      {:ok, view, _html} = live(conn, schedules_path(scope))
      render_click(view, "open_edit_drawer", %{"trip" => trip.id})

      render_submit(view, "drawer_submit", %{"drawer" => edit_params(scope, "6:05p")})

      assert clocks(ScheduleEditingFixtures.trip_row(trip)) == [
               {"18:05:00", "18:05:00"},
               {"18:10:00", "18:10:30"},
               {"18:17:00", "18:17:00"}
             ]
    end

    test "the Duplicate drawer copies from a compact reading", %{conn: conn, scope: scope} do
      source = ScheduleEditingFixtures.linked_trip!(scope, "07:00:00")

      {:ok, view, _html} = live(conn, schedules_path(scope))
      render_click(view, "open_duplicate_drawer", %{"trip" => source.id})

      render_submit(view, "drawer_submit", %{"drawer" => duplicate_params(scope, "605")})

      assert clocks(only_trip(scope, source.id)) == [
               {"06:05:00", "06:05:00"},
               {"06:10:00", "06:10:30"},
               {"06:17:00", "06:17:00"}
             ]

      assert clocks(ScheduleEditingFixtures.trip_row(source)) == [
               {"07:00:00", "07:00:00"},
               {"07:05:00", "07:05:30"},
               {"07:12:00", "07:12:00"}
             ]
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp schedules_path(scope) do
    "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"
  end

  defp open_add_drawer(view) do
    render_click(view, "open_add_drawer")
    assert has_element?(view, "#trip-drawer-overlay[data-open='true']")
  end

  defp add_params(scope, start_time) do
    %{
      "pattern_id" => scope.bundle.pattern.id,
      "timed_pattern_id" => scope.bundle.timing.id,
      "service_id" => scope.service,
      "start_time" => start_time,
      "repeat" => "false",
      "every" => "30",
      "until" => "09:00"
    }
  end

  defp edit_params(scope, start_time) do
    %{
      "pattern_id" => scope.bundle.pattern.id,
      "timed_pattern_id" => scope.bundle.timing.id,
      "service_id" => scope.service,
      "start_time" => start_time,
      "trip_headsign" => "",
      "trip_short_name" => "",
      "wheelchair_accessible" => "0",
      "bikes_allowed" => "0"
    }
  end

  defp duplicate_params(scope, start_time) do
    %{
      "pattern_id" => scope.bundle.pattern.id,
      "timed_pattern_id" => scope.bundle.timing.id,
      "service_id" => scope.service,
      "start_time" => start_time
    }
  end

  defp trip_count(scope), do: Repo.aggregate(trips(scope), :count)

  defp only_trip(scope, except_id \\ nil) do
    query = trips(scope)
    query = if except_id, do: where(query, [trip], trip.id != ^except_id), else: query

    Repo.one!(query)
  end

  defp trips(scope) do
    from(trip in Trip,
      where:
        trip.organization_id == ^scope.organization.id and
          trip.gtfs_version_id == ^scope.version.id
    )
  end

  defp clocks(trip) do
    trip
    |> ScheduleEditingFixtures.stop_time_clocks()
    |> Enum.map(fn {arrival, departure, _timepoint, _pickup_type} ->
      {arrival, departure}
    end)
  end
end
