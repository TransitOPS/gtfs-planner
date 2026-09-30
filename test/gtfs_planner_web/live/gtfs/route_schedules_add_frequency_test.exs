defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesAddFrequencyTest do
  # EV-32: adding frequency service from the Add trips drawer through the
  # production composition (spec 18, step 34; CL-4, CL-13; FH-10, FH-35).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so the drawer's events -> the editor role re-read -> the `:add_frequency`
  # command with the `:none` fence -> `Gtfs.apply_trip_change/4` ->
  # `Gtfs.Schedules` -> the reload through the read adapter is exercised end to
  # end. Frequency rows, stop-time clocks and trip fields are asserted with
  # independent `Repo` queries, never from the rendered HTML alone. Every
  # expected value is literal and hand-derived from R8, R9 and §4.4.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_add_frequency_test.exs`
  # (EV-32, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.GtfsFixtures, only: [calendar_attribute_fixture: 3]
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @route_id "AF"
  @service "AF_WEEKDAY"

  # Three occurrences: the first stop, an intermediate with dwell and the trailing
  # stop, so the template's literal clocks come straight from the timing offsets.
  @stops [
    {"AF_START", 0, 0, 1},
    {"AF_LIB", 300, 330, 1},
    {"AF_END", 720, 720, 1}
  ]

  # 10:00–10:30 every 10 min is three departures, 10:30–11:00 every 15 is two.
  @two_windows [{"10:00", "10:30", "10"}, {"10:30", "11:00", "15"}]

  setup context do
    scope =
      editing_scope!(@route_id, %{
        service: @service,
        stops: @stops,
        route_pattern_id: "AF-P1",
        route_pattern_name: "Main pattern",
        timing_name: "Base"
      })

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "How the trips run" do
    test "the Add drawer opens on Scheduled trips and offers the frequency mode", %{
      conn: conn,
      scope: scope
    } do
      named_calendar!(scope, @service, "Weekday")
      listed = linked_trip!(scope, "07:00:00", %{trip_id: "AF_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_add_drawer(view)

      # Scheduled trips is the default: the departure and its repeat are the
      # fields, the result card keeps the property's own sentence and the primary
      # counts the one trip.
      assert has_element?(view, "#how-trips-run")
      assert has_element?(view, "#trip-run-scheduled[checked]")
      refute has_element?(view, "#trip-run-frequency[checked]")
      assert has_element?(view, "#trip-start[value='06:00']")
      assert has_element?(view, "#add-result-card", "Adds 1 trip.")
      assert has_element?(view, "#trip-drawer-save:not([disabled])", "Add 1 trip")
      refute has_element?(view, "#frequency-windows")
      refute has_element?(view, "#riders-see")
      refute has_element?(view, "#add-refusal")

      choose_frequency(view)

      # Every N minutes replaces the departure and its repeat with the windows
      # editor, the riders-see choice and the frequency result card, whose legend
      # names the stop the windows depart from (R8, AC-17).
      refute has_element?(view, "#trip-start")
      refute has_element?(view, "#trip-repeat")
      assert has_element?(view, "#frequency-windows", "departures from AF_START")
      assert has_element?(view, "#windows-0-from[value='06:00']")
      assert has_element?(view, "#windows-0-until[value='09:00']")
      assert has_element?(view, "#windows-0-every[value='30']")
      assert has_element?(view, "#riders-see")
      assert has_element?(view, "#riders-each-departure[checked]")
      assert has_element?(view, "#add-result-card", "06:00–09:00")
      assert has_element?(view, "#add-result-card", "About 6 departures.")
      assert has_element?(view, "#trip-drawer-save:not([disabled])", "Add frequency service")

      # The page's own row stays the only trip.
      assert trip_ids(scope) == [listed.id]
    end

    test "Add window appends a touching row, Remove takes it away and keeps one", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_add_drawer(view)
      choose_frequency(view)
      type_windows(view, [{"10:00", "12:00", "30"}])

      # The only row cannot be removed: the editor always holds one window.
      assert has_element?(view, "#windows-remove-0[disabled]")

      view |> element("#win-add") |> render_click()

      # The new row starts where the last one ended and keeps its gap, so the two
      # windows touch and the list stays valid as typed (R8).
      assert_push_event(view, "focus_scoped_target", %{id: "windows-1-from"})
      assert has_element?(view, "#windows-1-from[value='12:00']")
      assert has_element?(view, "#windows-1-until[value='14:00']")
      assert has_element?(view, "#windows-1-every[value='30']")

      assert has_element?(
               view,
               "#windows-row-1",
               "4 departures · last 13:30; the next would be 14:00"
             )

      assert has_element?(view, "#windows-remove-0:not([disabled])")

      view |> element("#windows-remove-1") |> render_click()

      assert_push_event(view, "focus_scoped_target", %{id: "win-add"})
      refute has_element?(view, "#windows-row-1")
      assert has_element?(view, "#windows-remove-0[disabled]")
    end
  end

  describe "Adding frequency service" do
    test "two windows persist one frequency trip with exact_times 1 and a timing template", %{
      conn: conn,
      scope: scope
    } do
      named_calendar!(scope, @service, "Weekday")

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_add_drawer(view)
      choose_frequency(view)
      type_windows(view, @two_windows)

      # The card states the span and the departures before anything is written.
      assert has_element?(view, "#add-result-card", "10:00–11:00")
      assert has_element?(view, "#add-result-card", "About 5 departures.")

      submit_drawer(view, scope, @two_windows)

      # One linked trip on the chosen pattern, service and timing; allocated ID;
      # no block and no trip number (R7).
      assert [created] = trips_on(scope)
      assert created.trip_id == "AF-0-#{@service}-1000"
      assert created.service_id == @service
      assert created.route_pattern_id == "AF-P1"
      assert created.timed_pattern_id == scope.bundle.timing.id
      assert created.pattern_derivation_state == "linked"
      assert created.block_id == nil
      assert created.trip_short_name == nil

      # Both windows are stored with the riders-see choice: new service keeps
      # each departure time, so every row carries exact_times 1 (R8, AC-17).
      assert [
               %{start_time: "10:00:00", end_time: "10:30:00", headway_secs: 600, exact_times: 1},
               %{start_time: "10:30:00", end_time: "11:00:00", headway_secs: 900, exact_times: 1}
             ] = frequency_rows(created)

      # The template follows the timing materialized at the first window's start.
      assert clocks(created) == [
               {"10:00:00", "10:00:00"},
               {"10:05:00", "10:05:30"},
               {"10:12:00", "10:12:00"}
             ]

      # The write reports on the grid bar with Undo, and closes the drawer.
      view_assigns = assigns(view)
      assert view_assigns.drawer == nil

      assert view_assigns.outcome.text ==
               "Added frequency service to Weekday: 10:00–11:00. Riders see each departure time."

      assert view_assigns.outcome.tone == :info
      assert view_assigns.outcome.undo? == true
      assert [%{payload: _payload, message: message}] = view_assigns.undo_stack
      assert message == view_assigns.outcome.text
      assert view_assigns.just_changed == MapSet.new([created.id])
      refute has_element?(view, "#trip-drawer-overlay[data-open='true']")

      # Undo takes the created trip and its rows back out (R10, AC-21).
      view |> element("#undo-action") |> render_click()

      assert trips_on(scope) == []
      assert frequency_rows(created) == []
      assert stop_time_clocks(created) == []
    end

    test "windows typed out of order still start the template at the earliest one", %{
      conn: conn,
      scope: scope
    } do
      named_calendar!(scope, @service, "Weekday")

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_add_drawer(view)
      choose_frequency(view)
      type_windows(view, [{"10:30", "11:00", "15"}, {"10:00", "10:30", "10"}])

      assert has_element?(view, "#add-result-card", "10:00–11:00")
      assert has_element?(view, "#add-result-card", "About 5 departures.")

      submit_drawer(view, scope, [{"10:30", "11:00", "15"}, {"10:00", "10:30", "10"}])

      assert [created] = trips_on(scope)
      assert created.trip_id == "AF-0-#{@service}-1000"

      assert Enum.map(frequency_rows(created), &{&1.start_time, &1.end_time}) == [
               {"10:00:00", "10:30:00"},
               {"10:30:00", "11:00:00"}
             ]
    end

    test "an overlapping window keeps the typed text and writes nothing", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_add_drawer(view)
      choose_frequency(view)

      overlap = [{"06:00", "07:00", "10"}, {"06:30", "08:00", "15"}]
      type_windows(view, overlap)

      # The row states the overlap and the card points at it, so the primary that
      # would add the service is unavailable (R8).
      assert has_element?(
               view,
               "#windows-row-1",
               "Overlaps 06:00–07:00. Windows can touch but not overlap."
             )

      assert has_element?(
               view,
               "#add-result-card-error",
               "Fix the highlighted window to see a preview."
             )

      assert has_element?(view, "#trip-drawer-save[disabled]", "Add frequency service")
      refute has_element?(view, "#trip-drawer-save:not([disabled])")

      # A replayed or forged submit is refused too: the input stays exactly as
      # typed and no row is written.
      submit_drawer(view, scope, overlap)

      assert has_element?(view, "#windows-1-from[value='06:30']")
      assert has_element?(view, "#windows-1-until[value='08:00']")
      assert trips_on(scope) == []
      assert assigns(view).undo_stack == []

      # Fixing the window brings the primary back.
      type_windows(view, [{"06:00", "07:00", "10"}, {"07:00", "08:00", "15"}])

      assert has_element?(view, "#trip-drawer-save:not([disabled])", "Add frequency service")
      refute has_element?(view, "#add-result-card-error")
    end

    test "a listed trip on a shared date refuses the service day (FH-10, FH-35)", %{
      conn: conn,
      scope: scope
    } do
      %{daily: daily, school: school} = shared_dates_calendars!(scope)
      named_calendar!(scope, daily, "Daily")
      named_calendar!(scope, school, "School days")

      # The pattern's listed trip runs on School days, whose dates Daily shares.
      listed = linked_trip!(scope, "07:00:00", %{trip_id: "AF_SCHOOL", service_id: school})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => daily}))
      open_add_drawer(view)
      choose_frequency(view)

      windows = [{"10:00", "11:00", "20"}]
      type_windows(view, windows)
      assert has_element?(view, "#trip-drawer-save:not([disabled])", "Add frequency service")

      submit_drawer(view, scope, windows, %{"service_id" => daily})

      # The refusal is the choice's own error and names the selected service
      # day, the reference's copy; the primary stays but is unavailable until
      # something changes (FH-35), so a repeat cannot write.
      assert has_element?(
               view,
               "#add-refusal",
               "Daily already has listed trips on this pattern. Frequency service can't run on the same days. Add scheduled trips instead, or choose another service day."
             )

      assert has_element?(view, "#how-trips-run[aria-invalid='true']")
      assert has_element?(view, "#trip-drawer-save[disabled]", "Add frequency service")
      refute has_element?(view, "#trip-drawer-save:not([disabled])")
      assert assigns(view).drawer.values["run_as"] == "frequency"
      assert has_element?(view, "#windows-0-from[value='10:00']")

      submit_drawer(view, scope, windows, %{"service_id" => daily})

      assert trips_on(scope, daily) == []
      assert trip_ids(scope, school) == [listed.id]
      assert assigns(view).undo_stack == []

      # A change clears the refusal: the same drawer offers a primary again.
      render_change(view, "drawer_change", %{"drawer" => %{"run_as" => "scheduled"}})

      refute has_element?(view, "#add-refusal")
      assert has_element?(view, "#trip-drawer-save:not([disabled])", "Add 1 trip")
    end

    test "a pattern that already mixes stays editable (AC-20)", %{conn: conn, scope: scope} do
      named_calendar!(scope, @service, "Weekday")

      # The imported mix: listed trips and frequency service on the same pattern
      # and service day, which R9 leaves editable.
      listed = linked_trip!(scope, "07:00:00", %{trip_id: "AF_T0700"})

      existing =
        frequency_trip!(scope, [%{start_secs: 32_400, end_secs: 36_000, headway_secs: 1_200}])

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_add_drawer(view)
      choose_frequency(view)

      windows = [{"12:00", "13:00", "30"}]
      type_windows(view, windows)
      assert has_element?(view, "#trip-drawer-save:not([disabled])", "Add frequency service")

      submit_drawer(view, scope, windows)

      assert [created] = created_trips(scope, [listed.id, existing.id])
      assert created.trip_id == "AF-0-#{@service}-1200"

      assert Enum.map(frequency_rows(created), &{&1.start_time, &1.end_time, &1.exact_times}) == [
               {"12:00:00", "13:00:00", 1}
             ]
    end

    test "the scheduled path is unchanged by the choice", %{conn: conn, scope: scope} do
      named_calendar!(scope, @service, "Weekday")

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_add_drawer(view)

      render_submit(view, "drawer_submit", %{
        "drawer" => %{
          "pattern_id" => scope.bundle.pattern.id,
          "timed_pattern_id" => scope.bundle.timing.id,
          "service_id" => @service,
          "start_time" => "06:00",
          "repeat" => "false",
          "every" => "30",
          "until" => "09:00",
          "run_as" => "scheduled"
        }
      })

      assert [created] = trips_on(scope)
      assert created.trip_id == "AF-0-#{@service}-0600"
      assert frequency_rows(created) == []
      assert assigns(view).undo_stack == []
    end

    test "a pattern outside this route is refused and writes nothing", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_add_drawer(view)
      choose_frequency(view)

      forged = Ecto.UUID.generate()

      render_change(view, "drawer_change", %{
        "drawer" => %{"pattern_id" => forged, "run_as" => "frequency"}
      })

      # The full submit posts every control, so the forged pattern is what the
      # command carries; the drawer answers with the not-found refusal.
      submit_drawer(view, scope, [{"10:00", "11:00", "20"}], %{"pattern_id" => forged})

      assert has_element?(
               view,
               "#trip-drawer-error",
               "This trip or pattern no longer exists."
             )

      assert trips_on(scope) == []
      assert assigns(view).undo_stack == []
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp named_calendar!(scope, service_id, name) do
    calendar_attribute_fixture(scope.organization.id, scope.version.id, %{
      service_id: service_id,
      service_description: name,
      service_schedule_name: name
    })

    service_id
  end

  defp open_add_drawer(view) do
    render_click(view, "open_add_drawer")
    assert has_element?(view, "#trip-drawer-overlay[data-open='true']")
  end

  # The run-as choice posts the way the two design-system cards do.
  defp choose_frequency(view) do
    render_change(view, "drawer_change", %{"drawer" => %{"run_as" => "frequency"}})
    assert has_element?(view, "#trip-run-frequency[checked]")
  end

  # The editor's rows arrive as `drawer[windows][<index>][from|until|every]`: the
  # index-keyed map of typed text Phoenix builds from the form.
  defp type_windows(view, windows) do
    render_change(view, "drawer_change", %{"drawer" => %{"windows" => window_params(windows)}})
  end

  # The frequency form's full submit: a browser posts every control on the form,
  # so the command is built from posted text, never from anything the page holds
  # that the client did not send (CR-5). `overrides` names the fields a case
  # changed through the form, such as a service day.
  defp submit_drawer(view, scope, windows, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "pattern_id" => scope.bundle.pattern.id,
          "timed_pattern_id" => scope.bundle.timing.id,
          "service_id" => @service,
          "run_as" => "frequency",
          "exact_times" => "1",
          "windows" => window_params(windows)
        },
        overrides
      )

    render_submit(view, "drawer_submit", %{"drawer" => params})
  end

  defp window_params(windows) do
    windows
    |> Enum.with_index()
    |> Map.new(fn {{from, until, every}, index} ->
      {to_string(index), %{"from" => from, "until" => until, "every" => every}}
    end)
  end

  defp clocks(trip) do
    Enum.map(stop_time_clocks(trip), fn {arrival, departure, _timepoint, _pickup} ->
      {arrival, departure}
    end)
  end

  defp trip_ids(scope, service_id \\ @service), do: Enum.map(trips_on(scope, service_id), & &1.id)

  defp trips_on(scope, service_id \\ @service) do
    Repo.all(
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id and t.route_id == ^@route_id and
            t.service_id == ^service_id,
        order_by: [asc: t.trip_id]
      )
    )
  end

  # Every trip on the route that is not one of the trips a case created itself.
  defp created_trips(scope, existing_ids) do
    scope
    |> trips_on()
    |> Enum.reject(&(&1.id in existing_ids))
  end

  defp schedules_path(scope, params) do
    path = "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"

    case URI.encode_query(params) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
