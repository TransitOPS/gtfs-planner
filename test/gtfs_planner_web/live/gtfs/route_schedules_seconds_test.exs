defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesSecondsTest do
  # EV-14: the Schedules time fields prefill and store `GtfsTime.format/1`
  # (`HH:MM:SS`), so a trip whose stored start carries seconds survives an
  # untouched drawer save and a typed seconds reading is stored rather than
  # floored to the minute (R5, FH-11).
  #
  # Every case mounts through the authenticated router, so the production
  # composition is exercised end to end: LiveView event -> `Gtfs` facade ->
  # `Gtfs.Schedules` transaction -> audit -> reload through the read adapter.
  # Stored times are read back through `Repo`, never from rendered HTML alone.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.ScheduleEditingFixtures

  @route_id "EDT_SEC"
  @start_secs 25_230

  setup context do
    scope = ScheduleEditingFixtures.editing_scope!(@route_id)

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "seconds in the Schedules time fields" do
    test "a 07:00:30 trip prefills 07:00:30 in its start time field", %{
      conn: conn,
      scope: scope
    } do
      trip = ScheduleEditingFixtures.linked_trip!(scope, @start_secs)

      {:ok, view, _html} = live(conn, schedules_path(scope))
      render_click(view, "open_edit_drawer", %{"trip" => trip.id})

      assert has_element?(view, "#trip-drawer-overlay[data-open='true']")
      assert has_element?(view, "#trip-start[value='07:00:30']")
    end

    test "saving the drawer untouched keeps the stored start at 25230", %{
      conn: conn,
      scope: scope
    } do
      trip = ScheduleEditingFixtures.linked_trip!(scope, @start_secs)

      {:ok, view, _html} = live(conn, schedules_path(scope))
      render_click(view, "open_edit_drawer", %{"trip" => trip.id})
      assert has_element?(view, "#trip-start[value='07:00:30']")

      render_submit(view, "drawer_submit", %{"drawer" => edit_params(scope, "07:00:30")})

      refute has_element?(view, "#trip-drawer-overlay[data-open='true']")
      assert departures(trip) == ["07:00:30", "07:06:00", "07:12:30"]
      assert first_departure_secs(trip) == @start_secs
    end

    test "a typed 6:05:30 stores 06:05:30", %{conn: conn, scope: scope} do
      trip = ScheduleEditingFixtures.linked_trip!(scope, @start_secs)

      {:ok, view, _html} = live(conn, schedules_path(scope))
      render_click(view, "open_edit_drawer", %{"trip" => trip.id})

      render_submit(view, "drawer_submit", %{"drawer" => edit_params(scope, "6:05:30")})

      refute has_element?(view, "#trip-drawer-overlay[data-open='true']")
      assert departures(trip) == ["06:05:30", "06:11:00", "06:17:30"]
      assert first_departure_secs(trip) == 21_930
    end

    test "duplicating a 07:00:30 trip prefills 07:30:30 and stores it", %{
      conn: conn,
      scope: scope
    } do
      source = ScheduleEditingFixtures.linked_trip!(scope, @start_secs)

      {:ok, view, _html} = live(conn, schedules_path(scope))
      render_click(view, "open_duplicate_drawer", %{"trip" => source.id})

      assert has_element?(view, "#trip-start[value='07:30:30']")

      render_submit(view, "drawer_submit", %{"drawer" => duplicate_params(scope, "07:30:30")})

      refute has_element?(view, "#trip-drawer-overlay[data-open='true']")

      copy = only_trip(scope, source.id)
      assert departures(copy) == ["07:30:30", "07:36:00", "07:42:30"]
      assert first_departure_secs(copy) == 27_030
      assert departures(source) == ["07:00:30", "07:06:00", "07:12:30"]
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp schedules_path(scope) do
    "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"
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

  defp only_trip(scope, except_id) do
    Repo.one!(
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id and t.id != ^except_id
      )
    )
  end

  defp departures(trip) do
    trip
    |> ScheduleEditingFixtures.stop_time_clocks()
    |> Enum.map(fn {_arrival, departure, _timepoint, _pickup_type} -> departure end)
  end

  defp first_departure_secs(trip) do
    [departure | _rest] = departures(trip)

    case GtfsTime.parse(departure) do
      {:ok, secs} -> secs
      {:error, :invalid_time} -> flunk("stored departure #{inspect(departure)} does not parse")
    end
  end
end
