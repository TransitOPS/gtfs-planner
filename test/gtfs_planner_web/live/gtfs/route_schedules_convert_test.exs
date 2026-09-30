defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesConvertTest do
  # EV-34: converting a frequency trip from the Schedules page through the
  # production composition (spec 18, step 36; CL-11; FH-29).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so the dialog's events -> the editor role re-read -> the `:convert_frequency`
  # command fenced by the reviewed fingerprint -> `Gtfs.apply_trip_change/4` ->
  # `Gtfs.Schedules` -> the reload through the read adapter is exercised end to
  # end. The frequency trip, its stop times, its frequency rows, the transfer
  # naming it, the created trips and the change logs are asserted with independent
  # `Repo` queries, never from the rendered HTML alone. Every expected value is
  # literal and hand-derived from R8, R10 and §4.4.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_convert_test.exs`
  # (EV-34, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.BlockingFixtures, only: [in_seat_transfer_fixture: 4]
  import GtfsPlanner.GtfsFixtures, only: [calendar_attribute_fixture: 3]
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  @route_id "CV"
  @service "CV_WEEKDAY"

  # Three occurrences: the first stop, an intermediate with dwell and the trailing
  # stop, so the template's literal clocks come straight from the timing offsets.
  @stops [
    {"CV_START", 0, 0, 1},
    {"CV_LIB", 300, 330, 1},
    {"CV_END", 720, 720, 1}
  ]

  # 06:00–07:00 every 10 min is the R8 example: six departures ending 06:50, none
  # at 07:00.
  @stored_window {"06:00:00", "07:00:00", 600, 0}
  @created_ids [
    "CV-0-CV_WEEKDAY-0600",
    "CV-0-CV_WEEKDAY-0610",
    "CV-0-CV_WEEKDAY-0620",
    "CV-0-CV_WEEKDAY-0630",
    "CV-0-CV_WEEKDAY-0640",
    "CV-0-CV_WEEKDAY-0650"
  ]

  setup context do
    scope =
      editing_scope!(@route_id, %{
        service: @service,
        stops: @stops,
        route_pattern_id: "CV-P1",
        route_pattern_name: "Main pattern",
        timing_name: "Base"
      })

    # Every case mounts the Schedules page for this service day, so the calendar
    # identity the read resolves must exist before the trips are created.
    named_calendar!(scope, @service, "Weekday")

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "the entry points" do
    test "a frequency row's menu offers Convert and a listed row's does not", %{
      conn: conn,
      scope: scope
    } do
      stored_frequency_trip!(scope)
      linked_trip!(scope, "08:00:00", %{trip_id: "CV_LISTED"})

      {:ok, view, _html} = live(conn, schedules_path(scope))

      assert has_element?(view, "#trip-CV_FREQ-convert", "Convert to scheduled trips…")
      assert has_element?(view, "#trip-CV_FREQ-menu-panel", "Convert to scheduled trips…")
      refute has_element?(view, "#trip-CV_LISTED-convert")
    end

    test "the frequency Edit drawer's Convert closes the drawer and opens the dialog", %{
      conn: conn,
      scope: scope
    } do
      frequency = stored_frequency_trip!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))
      open_edit_drawer(view, frequency)

      # The reference's footer action replaces Delete here; Delete stays in the
      # row menu, and a listed trip's drawer keeps it.
      assert has_element?(view, "#fw-convert", "Convert to scheduled trips…")
      refute has_element?(view, "#trip-drawer-delete")

      view |> element("#fw-convert") |> render_click()

      refute has_element?(view, "#trip-drawer-overlay[data-open='true']")
      assert has_element?(view, "#convert-review[data-open='true']")
      assert has_element?(view, "#convert-review-title", "Convert to 6 scheduled trips?")

      # Keeping the frequency service closes the dialog and writes nothing.
      view |> element("#convert-keep") |> render_click()

      assert assigns(view).change == nil
      refute has_element?(view, "#convert-review")
      assert rows(frequency) == [@stored_window]
      assert trip_logs(frequency) == []
    end

    test "a listed trip's Edit drawer keeps Delete and offers no Convert", %{
      conn: conn,
      scope: scope
    } do
      listed = linked_trip!(scope, "08:00:00", %{trip_id: "CV_LISTED"})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      open_edit_drawer(view, listed)

      assert has_element?(view, "#trip-drawer-delete", "Delete trip")
      refute has_element?(view, "#fw-convert")
    end
  end

  describe "the convert review" do
    test "lists every departure and the transfer count without writing", %{
      conn: conn,
      scope: scope
    } do
      frequency = stored_frequency_trip!(scope)
      later = linked_trip!(scope, "08:00:00", %{trip_id: "CV_LATER"})

      transfer =
        in_seat_transfer_fixture(scope.organization.id, scope.version.id, frequency, later)

      trips_before = route_trip_count(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      view |> element("#trip-CV_FREQ-convert") |> render_click()

      # The title, the context line and the three metric cells are the
      # reference's (AC-19).
      assert has_element?(view, "#convert-review[data-open='true']")
      assert has_element?(view, "#convert-review-title", "Convert to 6 scheduled trips?")

      assert has_element?(
               view,
               "#convert-context",
               "Main pattern · Weekday · every 10 min, 06:00–07:00"
             )

      assert has_element?(view, "#convert-review", "Trips created 6")
      assert has_element?(view, "#convert-review", "Frequency service removed 1")
      assert has_element?(view, "#convert-review", "Transfer records removed 1")

      # The departures table is the review's inserts: the six allocated trip IDs,
      # each with its own first departure, and nothing at 07:00 (FH-28's rule).
      html = render(element(view, "#convert-review"))

      for trip_id <- @created_ids do
        assert html =~ trip_id
      end

      refute html =~ "CV-0-CV_WEEKDAY-0700"
      assert has_element?(view, "#convert-review tbody", "06:00")
      assert has_element?(view, "#convert-review tbody", "06:50")

      assert has_element?(view, "#convert-review", "Departures, each a trip with Base timing")
      assert has_element?(view, "#convert-review", "Trip CV_FREQ and its windows are replaced")
      assert has_element?(view, "#convert-review", "Riders then see every departure time.")

      assert has_element?(
               view,
               "#convert-status",
               "This can't be undone. Nothing changes until you convert."
             )

      assert has_element?(view, "#convert-keep", "Keep frequency service")
      assert has_element?(view, "#convert-apply", "Convert to 6 trips")

      # The review writes nothing: the source, its rows and the transfer stay.
      assert rows(frequency) == [@stored_window]
      assert clocks(frequency) == stored_clocks()
      assert Repo.get(Trip, frequency.id) != nil
      assert Repo.get(Transfer, transfer.id) != nil
      assert route_trip_count(scope) == trips_before
      assert trip_logs(frequency) == []
    end

    test "applying replaces the frequency trip and its transfers with the listed trips (FH-29)",
         %{conn: conn, scope: scope} do
      frequency = stored_frequency_trip!(scope)
      later = linked_trip!(scope, "08:00:00", %{trip_id: "CV_LATER"})

      transfer =
        in_seat_transfer_fixture(scope.organization.id, scope.version.id, frequency, later)

      trips_before = route_trip_count(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      view |> element("#trip-CV_FREQ-convert") |> render_click()
      view |> element("#convert-apply") |> render_click()

      # The write reports the created trips and closes the dialog (AC-19).
      assert assigns(view).change == nil
      refute has_element?(view, "#convert-review")

      assert assigns(view).outcome == %{
               tone: :info,
               text: "Converted frequency service to 6 scheduled trips.",
               undo?: false
             }

      assert assigns(view).selected_count == 0

      # The source and everything its delete removes are gone.
      assert Repo.get(Trip, frequency.id) == nil
      assert stop_time_clocks(frequency) == []
      assert rows(frequency) == []
      assert Repo.get(Transfer, transfer.id) == nil

      assert Repo.one(
               from(t in Transfer,
                 where:
                   t.gtfs_version_id == ^scope.version.id and
                     (t.from_trip_id == ^frequency.trip_id or t.to_trip_id == ^frequency.trip_id),
                 select: count(t.id)
               )
             ) == 0

      # Every departure became one linked trip: the source's service, pattern and
      # headsign, an allocated trip ID, no block and no trip number.
      created =
        Repo.all(
          from(t in Trip,
            where: t.gtfs_version_id == ^scope.version.id and t.trip_id in ^@created_ids,
            order_by: t.trip_id
          )
        )

      assert Enum.map(created, & &1.trip_id) == @created_ids
      assert Enum.all?(created, &(&1.service_id == @service))
      assert Enum.all?(created, &(&1.route_id == @route_id))
      assert Enum.all?(created, &(&1.direction_id == 0))
      assert Enum.all?(created, &(&1.route_pattern_id == scope.bundle.pattern.route_pattern_id))
      assert Enum.all?(created, &(&1.timed_pattern_id == scope.bundle.timing.id))
      assert Enum.all?(created, &(&1.pattern_derivation_state == "linked"))
      assert Enum.all?(created, &(&1.pattern_derivation_reason == nil))
      assert Enum.all?(created, &(&1.block_id == nil))
      assert Enum.all?(created, &(&1.trip_short_name == nil))
      assert Enum.all?(created, &(frequency_rows(&1) == []))

      # The end departures carry the source timing's literal clocks.
      at_0600 = Enum.find(created, &(&1.trip_id == "CV-0-CV_WEEKDAY-0600"))

      assert stop_time_clocks(at_0600) == [
               {"06:00:00", "06:00:00", 1, nil},
               {"06:05:00", "06:05:30", 1, nil},
               {"06:12:00", "06:12:00", 1, nil}
             ]

      at_0650 = Enum.find(created, &(&1.trip_id == "CV-0-CV_WEEKDAY-0650"))

      assert stop_time_clocks(at_0650) == [
               {"06:50:00", "06:50:00", 1, nil},
               {"06:55:00", "06:55:30", 1, nil},
               {"07:02:00", "07:02:00", 1, nil}
             ]

      # One audit operation covers the created trips and the deleted source.
      logs = Enum.map(created, &trip_logs/1)
      assert Enum.all?(logs, fn [log] -> log.action == "created" end)

      operation_ids =
        logs
        |> Enum.flat_map(&Enum.map(&1, fn log -> log.changed_fields["operation_id"] end))
        |> Enum.uniq()

      assert [operation_id] = operation_ids

      assert [deleted_log] = trip_logs(frequency)
      assert deleted_log.action == "deleted"
      assert deleted_log.changed_fields["operation_id"] == operation_id
      assert deleted_log.changed_fields["after"] == nil

      affected = Enum.sort(Enum.map(created, & &1.id) ++ [frequency.id])
      assert deleted_log.changed_fields["affected_trip_ids"] |> Enum.sort() == affected

      assert route_trip_count(scope) == trips_before + 5
    end

    test "Convert is not undoable: no Undo entry is pushed and no Undo appears", %{
      conn: conn,
      scope: scope
    } do
      stored_frequency_trip!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      view |> element("#trip-CV_FREQ-convert") |> render_click()
      refute has_element?(view, "#undo-action")

      view |> element("#convert-apply") |> render_click()

      assert assigns(view).undo_stack == []
      assert assigns(view).outcome.undo? == false
      refute has_element?(view, "#undo-action")
    end

    test "cancelling keeps the frequency service and writes nothing", %{conn: conn, scope: scope} do
      frequency = stored_frequency_trip!(scope)
      trips_before = route_trip_count(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      view |> element("#trip-CV_FREQ-convert") |> render_click()
      view |> element("#convert-keep") |> render_click()

      assert assigns(view).change == nil
      refute has_element?(view, "#convert-review")
      assert rows(frequency) == [@stored_window]
      assert clocks(frequency) == stored_clocks()
      assert route_trip_count(scope) == trips_before
      assert trip_logs(frequency) == []
    end

    test "a source changed after the review shows Refresh and writes nothing", %{
      conn: conn,
      scope: scope
    } do
      frequency = stored_frequency_trip!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      view |> element("#trip-CV_FREQ-convert") |> render_click()
      fingerprint = assigns(view).change.review.fingerprint

      # Another editor changes the source after the review (FH-33).
      assert {:ok, _changed} =
               Gtfs.update_trip(
                 @route_id,
                 frequency.id,
                 %{"trip_headsign" => "From the other session"},
                 Repo.get!(Trip, frequency.id).updated_at,
                 scope.audit
               )

      view |> element("#convert-apply") |> render_click()

      assert has_element?(
               view,
               "#convert-stale[role='alert']",
               "These trips changed after this preview. Nothing was written."
             )

      assert has_element?(view, "#convert-refresh", "Refresh preview")
      refute has_element?(view, "#convert-apply")
      assert rows(frequency) == [@stored_window]
      assert Repo.get(Trip, frequency.id) != nil
      assert assigns(view).change.review.fingerprint != fingerprint
      assert assigns(view).undo_stack == []

      # Refreshing reviews the changed source again; applying it then converts.
      view |> element("#convert-refresh") |> render_click()

      assert has_element?(view, "#convert-apply", "Convert to 6 trips")
      refute has_element?(view, "#convert-stale")

      view |> element("#convert-apply") |> render_click()

      assert assigns(view).outcome.text == "Converted frequency service to 6 scheduled trips."
      assert Repo.get(Trip, frequency.id) == nil
    end
  end

  describe "the dialog's inputs" do
    test "a forged or listed trip opens nothing and a stray post cannot change the command", %{
      conn: conn,
      scope: scope
    } do
      frequency = stored_frequency_trip!(scope)
      listed = linked_trip!(scope, "08:00:00", %{trip_id: "CV_LISTED"})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "open_change", %{"kind" => "convert", "trip" => Ecto.UUID.generate()})
      assert assigns(view).change == nil

      render_click(view, "open_change", %{"kind" => "convert", "trip" => listed.id})
      assert assigns(view).change == nil

      render_click(view, "open_change", %{"kind" => "convert", "trip" => frequency.id})
      assert assigns(view).change.review.command == {:convert_frequency, frequency.id}

      # The dialog has no controls to post; a stray parameter leaves the reviewed
      # command on the change's own trip (CR-5).
      render_click(view, "change_params", %{"change" => %{"trip_id" => listed.id}})

      assert assigns(view).change.review.command == {:convert_frequency, frequency.id}
      assert assigns(view).change.ids == [frequency.id]
    end

    test "a revoked editor role converts nothing", %{conn: conn, scope: scope} do
      frequency = stored_frequency_trip!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      view |> element("#trip-CV_FREQ-convert") |> render_click()
      message = ScheduleComponents.error_message(:unauthorized)

      membership = Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      view |> element("#convert-apply") |> render_click()

      assert assigns(view).outcome.text == message
      assert Repo.get(Trip, frequency.id) != nil
      assert rows(frequency) == [@stored_window]
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

  defp stored_frequency_trip!(scope) do
    frequency_trip!(
      scope,
      [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 600}],
      %{trip_id: "CV_FREQ"}
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

  defp clocks(trip) do
    Enum.map(stop_time_clocks(trip), fn {arrival, departure, _timepoint, _pickup} ->
      {arrival, departure}
    end)
  end

  defp rows(trip) do
    trip
    |> frequency_rows()
    |> Enum.map(fn frequency ->
      {frequency.start_time, frequency.end_time, frequency.headway_secs, frequency.exact_times}
    end)
  end

  defp route_trip_count(scope) do
    Repo.one(
      from(t in Trip,
        where: t.gtfs_version_id == ^scope.version.id and t.route_id == ^@route_id,
        select: count(t.id)
      )
    )
  end

  defp schedules_path(scope, params \\ %{}) do
    path = "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"

    case URI.encode_query(params) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
