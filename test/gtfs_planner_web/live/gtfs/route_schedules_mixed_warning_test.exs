defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesMixedWarningTest do
  # EV-35: the imported-mix warning on the Schedules page (spec 18, step 37; CL-4,
  # AC-20; FH-11).
  #
  # Every case mounts through the authenticated router with no injected assigns, so
  # the band's data comes from the production composition: RouteSchedulesLive ->
  # Gtfs facade -> Schedules read -> ScheduleComponents.section/1, and its Convert
  # action goes back through open_change -> the reviewed `:convert_frequency`
  # command -> Gtfs.apply_trip_change/4. Expected values are literal and
  # hand-derived from R9 ("an imported mix stays editable") and R8's window
  # arithmetic; none is computed by the code under test.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_mixed_warning_test.exs`
  # (EV-35, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.ScheduleEditingFixtures

  @route_id "MW"
  @title "This pattern runs listed trips and frequency service on the same days."
  @body "Trip planners may show only one kind. Convert the frequency service to scheduled trips."

  # No dwell, so a typed departure shifts the later stops by exact minutes.
  @stops [{"MW_A", 0, 0, 1}, {"MW_B", 300, 300, 1}, {"MW_C", 720, 720, 1}]

  # 06:00–07:00 every 10 min is the R8 example: six departures ending 06:50.
  @early_window %{start_secs: 21_600, end_secs: 25_200, headway_secs: 600}
  @late_window %{start_secs: 25_200, end_secs: 27_000, headway_secs: 600}

  setup context do
    scope = editing_scope!(@route_id, %{stops: @stops})

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "the imported-mix warning" do
    test "a mixed section shows the band and its Convert action", %{conn: conn, scope: scope} do
      frequency = stored_frequency!(scope)
      linked_trip!(scope, "07:00:00", %{trip_id: "MW_LISTED"})

      {:ok, view, _html} = live(conn, schedules_path(scope))

      assert has_element?(view, "#mixed-service-warning[role='alert']", @title)
      assert has_element?(view, "#mixed-service-warning", @body)
      assert has_element?(view, "#mixed-convert[phx-value-kind='convert']", "Convert…")
      assert has_element?(view, "#mixed-convert[phx-value-trip='#{frequency.id}']")
    end

    test "Convert opens the review for the section's first frequency row", %{
      conn: conn,
      scope: scope
    } do
      early = stored_frequency!(scope)
      frequency_trip!(scope, [@late_window], %{trip_id: "MW_FREQ_LATE"})
      linked_trip!(scope, "07:00:00", %{trip_id: "MW_LISTED"})

      {:ok, view, _html} = live(conn, schedules_path(scope))

      # The early row is first in the section, so its six departures, not the later
      # row's three, are the ones the dialog reviews.
      assert has_element?(view, "#mixed-convert[phx-value-trip='#{early.id}']")
      view |> element("#mixed-convert") |> render_click()

      assert has_element?(view, "#convert-review[data-open='true']")
      assert has_element?(view, "#convert-review-title", "Convert to 6 scheduled trips?")
      assert has_element?(view, "#convert-review tbody", "06:00")
      assert has_element?(view, "#convert-review tbody", "06:50")
      refute has_element?(view, "#convert-review tbody", "07:10")
    end

    test "keeping the frequency service writes nothing", %{conn: conn, scope: scope} do
      frequency = stored_frequency!(scope)
      linked_trip!(scope, "07:00:00", %{trip_id: "MW_LISTED"})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      view |> element("#mixed-convert") |> render_click()
      view |> element("#convert-keep") |> render_click()

      refute has_element?(view, "#convert-review")
      assert has_element?(view, "#mixed-service-warning")
      assert trip_row(frequency).id == frequency.id
      assert rows(frequency) == [{"06:00:00", "07:00:00", 600, 0}]
      assert assigns(view).undo_stack == []
    end

    test "a listed-only section shows no band", %{conn: conn, scope: scope} do
      linked_trip!(scope, "07:00:00", %{trip_id: "MW_LISTED"})

      {:ok, view, _html} = live(conn, schedules_path(scope))

      refute has_element?(view, "#mixed-service-warning")
      refute has_element?(view, "#mixed-convert")
    end

    test "a frequency-only section shows no band", %{conn: conn, scope: scope} do
      stored_frequency!(scope)

      {:ok, view, _html} = live(conn, schedules_path(scope))

      refute has_element?(view, "#mixed-service-warning")
      refute has_element?(view, "#mixed-convert")
    end
  end

  describe "editing a mixed section" do
    test "a listed trip's cell edit still saves and leaves the frequency row alone (FH-11)", %{
      conn: conn,
      scope: scope
    } do
      frequency = stored_frequency!(scope)
      listed = linked_trip!(scope, "07:00:00", %{trip_id: "MW_LISTED"})

      {:ok, view, _html} = live(conn, schedules_path(scope))
      assert has_element?(view, "#mixed-service-warning")

      render_hook(grid(view), "cell_commit", cell(listed, 2, "07:07", "later"))
      assert_reply(view, %{ok: true})

      assert clocks(listed) == [
               {"07:00:00", "07:00:00"},
               {"07:07:00", "07:07:00"},
               {"07:14:00", "07:14:00"}
             ]

      assert rows(frequency) == [{"06:00:00", "07:00:00", 600, 0}]
      assert has_element?(view, "#mixed-service-warning")
      assert assigns(view).outcome.text =~ "07:07"
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp stored_frequency!(scope) do
    frequency_trip!(scope, [@early_window], %{trip_id: "MW_FREQ"})
  end

  defp rows(trip) do
    trip
    |> frequency_rows()
    |> Enum.map(fn frequency ->
      {frequency.start_time, frequency.end_time, frequency.headway_secs, frequency.exact_times}
    end)
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

  defp grid(view), do: element(view, "#schedules-grid")

  defp cell(trip, position, text, mode) do
    %{"trip" => trip.id, "position" => position, "text" => text, "mode" => mode}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
