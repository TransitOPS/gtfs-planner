defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesFrequencyEditTest do
  # EV-33: editing a frequency trip's windows from the Edit trip drawer through
  # the production composition (spec 18, step 35; CL-3; FH-9).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so the drawer's events -> the editor role re-read -> the `:update_frequency`
  # command fenced by the drawer row's `{:expected, _}` -> `Gtfs.apply_trip_change/4`
  # -> `Gtfs.Schedules` -> the reload through the read adapter is exercised end to
  # end. Frequency rows, stop-time clocks, trip fields and change logs are asserted
  # with independent `Repo` queries, never from the rendered HTML alone. Every
  # expected value is literal and hand-derived from R8, R10 and §4.4.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_frequency_edit_test.exs`
  # (EV-33, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.GtfsFixtures, only: [calendar_attribute_fixture: 3]
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  @route_id "FE"
  @service "FE_WEEKDAY"

  # Three occurrences: the first stop, an intermediate with dwell and the trailing
  # stop, so the template's literal clocks come straight from the timing offsets.
  @stops [
    {"FE_START", 0, 0, 1},
    {"FE_LIB", 300, 330, 1},
    {"FE_END", 720, 720, 1}
  ]

  # 06:00–07:00 every 10 min is the R8 example: six departures ending 06:50.
  @stored_from "06:00"
  @stored_window {"06:00", "07:00", "10"}
  @stored_row {"06:00:00", "07:00:00", 600, nil}

  setup context do
    scope =
      editing_scope!(@route_id, %{
        service: @service,
        stops: @stops,
        route_pattern_id: "FE-P1",
        route_pattern_name: "Main pattern",
        timing_name: "Base"
      })

    # Every case mounts the Schedules page for this service day, so the calendar
    # identity the read resolves must exist before the trips are created.
    named_calendar!(scope, @service, "Weekday")

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "The Edit drawer's frequency windows" do
    test "the stored windows and the default riders-see choice prefill the editor", %{
      conn: conn,
      scope: scope
    } do
      trip = stored_frequency_trip!(scope, exact_times: nil)

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      # The frequency notice is gone; the Windows section and What riders see
      # replace it, prefilled from the stored rows (AC-18).
      refute has_element?(view, "#trip-drawer", "Frequency times are shown for reference")

      assert has_element?(view, "#frequency-windows", "departures from FE_START")
      assert has_element?(view, "#windows-0-from[value='06:00']")
      assert has_element?(view, "#windows-0-until[value='07:00']")
      assert has_element?(view, "#windows-0-every[value='10']")

      assert has_element?(
               view,
               "#windows-row-0",
               "6 departures · last 06:50; the next would be 07:00"
             )

      # A blank stored choice shows the default without writing one.
      assert has_element?(view, "#riders-each-departure[checked]")
      refute has_element?(view, "#riders-every-n-minutes[checked]")

      # The result card reads the typed windows (the reference's card) and the
      # primary is the drawer's one enabled Save trip.
      assert has_element?(view, "#trip-preview", "Main pattern · Weekday")
      assert has_element?(view, "#trip-preview", "06:00–07:00")
      assert has_element?(view, "#trip-preview", "About 6 departures.")
      assert has_element?(view, "#trip-drawer-save:not([disabled])", "Save trip")

      # Opening the drawer writes nothing.
      assert rows(trip) == [@stored_row]
      assert clocks(trip) == stored_clocks()
    end

    test "a stored headway choice shows as Every N minutes with its note", %{
      conn: conn,
      scope: scope
    } do
      trip =
        frequency_trip!(scope, [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 900}],
          exact_times: 0
        )

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      assert has_element?(view, "#riders-every-n-minutes[checked]")
      refute has_element?(view, "#riders-each-departure[checked]")
      assert has_element?(view, "#riders-see", "Above 10 minutes")
      assert has_element?(view, "#windows-0-every[value='15']")
    end

    test "an overlapping window disables Save and a replayed submit writes nothing", %{
      conn: conn,
      scope: scope
    } do
      trip = stored_frequency_trip!(scope)
      before = rows(trip)
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      overlap = [{"06:00", "07:00", "10"}, {"06:30", "08:00", "15"}]
      type_windows(view, overlap)

      # The row states the overlap and the card points at it, so the primary that
      # would save the windows is unavailable (R8).
      assert has_element?(
               view,
               "#windows-row-1",
               "Overlaps 06:00–07:00. Windows can touch but not overlap."
             )

      assert has_element?(
               view,
               "#trip-preview-error",
               "Fix the highlighted window to see a preview."
             )

      assert has_element?(view, "#trip-drawer-save[disabled]", "Save trip")
      refute has_element?(view, "#trip-drawer-save:not([disabled])")

      # A replayed or forged submit is refused too: the typed text stays and no row
      # is written.
      submit_drawer(view, scope, trip, overlap)

      assert has_element?(view, "#windows-1-from[value='06:30']")
      assert has_element?(view, "#windows-1-until[value='08:00']")
      assert rows(trip) == before
      assert clocks(trip) == stored_clocks()

      # Fixing the window brings the primary back.
      type_windows(view, [{"06:00", "07:00", "10"}, {"07:00", "08:00", "15"}])

      assert has_element?(view, "#trip-drawer-save:not([disabled])", "Save trip")
      refute has_element?(view, "#trip-preview-error")
    end
  end

  describe "Saving a window edit" do
    test "a window edit persists, moves the template and is undoable", %{
      conn: conn,
      scope: scope
    } do
      trip = stored_frequency_trip!(scope, exact_times: 1)
      before = rows(trip)
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      windows = [{"07:00", "08:00", "15"}]
      type_windows(view, windows)

      # The card states the new span and its departures before anything is written.
      assert has_element?(view, "#trip-preview", "07:00–08:00")
      assert has_element?(view, "#trip-preview", "About 4 departures.")

      submit_drawer(view, scope, trip, windows)

      # The stored rows are replaced and the template follows the first window's
      # start as one linked move (R8).
      assert rows(trip) == [{"07:00:00", "08:00:00", 900, 1}]

      assert clocks(trip) == [
               {"07:00:00", "07:00:00"},
               {"07:05:00", "07:05:30"},
               {"07:12:00", "07:12:00"}
             ]

      updated = trip_row(trip)
      assert updated.pattern_derivation_state == "linked"
      assert updated.timed_pattern_id == scope.bundle.timing.id
      assert DateTime.compare(updated.updated_at, trip.updated_at) == :gt

      # The contract's combined windows+details submit is two writes (windows
      # first, then metadata), so the action records one update log per write.
      logs = trip_logs(trip)
      assert logs != []
      assert Enum.all?(logs, &(&1.action == "updated"))

      # The write reports on the grid bar with Undo and closes the drawer.
      view_assigns = assigns(view)
      assert view_assigns.drawer == nil
      assert view_assigns.outcome.text == "Saved the frequency service 07:00–08:00."
      assert view_assigns.outcome.tone == :info
      assert view_assigns.outcome.undo? == true
      assert [%{payload: _payload, message: message}] = view_assigns.undo_stack
      assert message == view_assigns.outcome.text
      assert MapSet.member?(view_assigns.just_changed, trip.id)

      # Undo puts the stored windows and template back (R10).
      view |> element("#undo-action") |> render_click()

      assert rows(trip) == before
      assert clocks(trip) == stored_clocks()
    end

    test "a blank exact_times stays blank when the choice is untouched (FH-9)", %{
      conn: conn,
      scope: scope
    } do
      trip = stored_frequency_trip!(scope, exact_times: nil)
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      # The stored blank choice displays the default card, so a browser submit
      # posts "1" for it (R8).
      assert has_element?(view, "#riders-each-departure[checked]")

      windows = [{"06:00", "08:00", "15"}]
      type_windows(view, windows)

      submit_drawer(view, scope, trip, windows)

      # The window edit went through - the span and the headway moved - but the
      # stored blank exact_times is untouched (FH-9, AC-18).
      assert rows(trip) == [{"06:00:00", "08:00:00", 900, nil}]
      assert clocks(trip) == stored_clocks()
    end

    test "changing the choice writes it on every row (R8)", %{conn: conn, scope: scope} do
      trip = stored_frequency_trip!(scope, exact_times: 1)
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      render_change(view, "drawer_change", %{"drawer" => %{"exact_times" => "0"}})
      assert has_element?(view, "#riders-every-n-minutes[checked]")

      windows = [{"06:00", "07:00", "10"}]
      type_windows(view, windows)
      submit_drawer(view, scope, trip, windows, %{"exact_times" => "0"})

      assert rows(trip) == [{"06:00:00", "07:00:00", 600, 0}]
    end

    test "a details-only submit keeps the metadata path and leaves the rows alone", %{
      conn: conn,
      scope: scope
    } do
      trip = stored_frequency_trip!(scope, exact_times: 1)
      stored_ids = trip |> frequency_rows() |> Enum.map(& &1.id)
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      render_change(view, "drawer_change", %{
        "drawer" => %{"trip_headsign" => "Kept heading"}
      })

      submit_drawer(view, scope, trip, [@stored_window], %{"trip_headsign" => "Kept heading"})

      # The details saved through today's `update_trip/5` path: the stored
      # frequency rows keep their identities, so no window write replaced them.
      assert trip_row(trip).trip_headsign == "Kept heading"
      assert frequency_rows(trip) |> Enum.map(& &1.id) == stored_ids
      assert rows(trip) == [{"06:00:00", "07:00:00", 600, 1}]
      assert clocks(trip) == stored_clocks()

      # A metadata edit is not undoable (R10) and closes the drawer as before.
      assert assigns(view).drawer == nil
      assert assigns(view).undo_stack == []
    end

    test "a combined submit writes the windows first and then the details", %{
      conn: conn,
      scope: scope
    } do
      trip = stored_frequency_trip!(scope, exact_times: 1)
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      windows = [{"07:00", "08:00", "15"}]
      type_windows(view, windows)

      render_change(view, "drawer_change", %{
        "drawer" => %{"trip_headsign" => "Later outbound"}
      })

      submit_drawer(view, scope, trip, windows, %{"trip_headsign" => "Later outbound"})

      assert rows(trip) == [{"07:00:00", "08:00:00", 900, 1}]

      assert clocks(trip) == [
               {"07:00:00", "07:00:00"},
               {"07:05:00", "07:05:30"},
               {"07:12:00", "07:12:00"}
             ]

      assert trip_row(trip).trip_headsign == "Later outbound"
      assert assigns(view).outcome.text == "Saved the frequency service 07:00–08:00."
      assert assigns(view).drawer == nil

      # Undo restores the windows and template; the details stay, because the
      # restore capture never held them (R10).
      view |> element("#undo-action") |> render_click()

      assert rows(trip) == [{"06:00:00", "07:00:00", 600, 1}]
      assert clocks(trip) == stored_clocks()
      assert trip_row(trip).trip_headsign == "Later outbound"
    end

    test "a stale trip shows the reload copy and writes nothing", %{conn: conn, scope: scope} do
      trip = stored_frequency_trip!(scope, exact_times: 1)
      before = rows(trip)
      before_clocks = clocks(trip)
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => @service}))
      open_edit_drawer(view, trip)

      # Another editor saves the same trip first.
      assert {:ok, _changed} =
               Gtfs.update_trip(
                 @route_id,
                 trip.id,
                 %{"trip_headsign" => "From the other session"},
                 Repo.get!(Trip, trip.id).updated_at,
                 scope.audit
               )

      windows = [{"07:00", "08:00", "15"}]
      type_windows(view, windows)
      submit_drawer(view, scope, trip, windows)

      # The drawer shows the page's own reload copy, keeps the typed windows and
      # wrote nothing.
      assert has_element?(view, "#trip-drawer-error", ScheduleComponents.error_message(:stale))
      assert has_element?(view, "#trip-drawer-reload")
      assert has_element?(view, "#windows-0-from[value='07:00']")
      refute has_element?(view, "#trip-preview-error")

      assert rows(trip) == before
      assert clocks(trip) == before_clocks
      assert [%{action: "updated"}] = trip_logs(trip)
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

  defp stored_frequency_trip!(scope, attrs \\ []) do
    frequency_trip!(
      scope,
      [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 600}],
      Map.new(attrs)
    )
  end

  defp stored_clocks do
    [
      {"06:00:00", "06:00:00"},
      {"06:05:00", "06:05:30"},
      {"06:12:00", "06:12:00"}
    ]
  end

  defp open_edit_drawer(view, trip) do
    render_click(view, "open_edit_drawer", %{"trip" => trip.id})
    assert has_element?(view, "#trip-drawer-overlay[data-open='true']")
  end

  # The editor's rows arrive as `drawer[windows][<index>][from|until|every]`: the
  # index-keyed map of typed text Phoenix builds from the form.
  defp type_windows(view, windows) do
    render_change(view, "drawer_change", %{"drawer" => %{"windows" => window_params(windows)}})
  end

  # The frequency form's full submit: a browser posts every control on the form,
  # so the command is built from posted text, never from anything the page holds
  # that the client did not send (CR-5). `overrides` names the fields a case
  # changed through the form, such as the riders-see choice or the headsign.
  defp submit_drawer(view, scope, _trip, windows, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "pattern_id" => scope.bundle.pattern.id,
          "timed_pattern_id" => scope.bundle.timing.id,
          "service_id" => @service,
          "start_time" => @stored_from,
          "trip_headsign" => "",
          "trip_short_name" => "",
          "wheelchair_accessible" => "0",
          "bikes_allowed" => "0",
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

  defp rows(trip) do
    trip
    |> frequency_rows()
    |> Enum.map(&row_values/1)
  end

  defp row_values(frequency) do
    {frequency.start_time, frequency.end_time, frequency.headway_secs, frequency.exact_times}
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
