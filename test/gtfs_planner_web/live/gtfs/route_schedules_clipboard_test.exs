defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesClipboardTest do
  # EV-30: Copy trips, Paste copied trips and Duplicate trips through the
  # production composition — the server-held clipboard, the paste dialog and its
  # apply behind the review fingerprint (spec 18, step 32; CL-13; FH-32).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so the grid hook's events -> the editor role re-read -> the reviewed `:copy`
  # command -> `Gtfs.apply_trip_change/4` -> `Gtfs.Schedules` -> the reload
  # through the read adapter is exercised end to end. Persisted rows and clocks
  # are asserted with independent `Repo` queries, never from the rendered HTML
  # alone. Every expected value is literal and hand-derived from R7 and §4.4.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_clipboard_test.exs`
  # (EV-30, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.GtfsFixtures, only: [calendar_attribute_fixture: 3]
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @route_id "EDT_CLIP"

  # Three occurrences: two timepoints and a trailing stop, so each copied
  # position stores its own clock (the same shape step 31's copy cases use).
  @stops [
    {"CLIP_START", 0, 0, 1},
    {"CLIP_LIB", 480, 540, 1},
    {"CLIP_END", 1_500, 1_500, 0}
  ]

  # The 07:00 source trip's stored clocks; every copy moves these by the offset.
  @t0700_clocks [
    {"07:00:00", "07:00:00", nil, nil},
    {"07:08:00", "07:09:00", nil, nil},
    {"07:25:00", "07:25:00", nil, nil}
  ]

  # 07:00 to 16:30 is 570 minutes.
  @paste_offset_secs 34_200

  setup context do
    scope = editing_scope!(@route_id, %{stops: @stops, timing_name: "Base"})

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "Copy trips" do
    test "stores the visible selection in the page's clipboard", %{conn: conn, scope: scope} do
      named_calendar!(scope, scope.service, "Weekday")
      first = linked_trip!(scope, "07:00:00", %{trip_id: "CLIP_T0700"})
      second = linked_trip!(scope, "07:15:00", %{trip_id: "CLIP_T0715"})
      ids = Enum.sort([first.id, second.id])

      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, [first, second])
      render_hook(grid(view), "copy_trips", %{})

      # The clipboard holds the trip UUIDs and the source service day, never a
      # payload (INV-6); copying writes nothing, so the outcome offers no Undo.
      assert assigns(view).clipboard == %{trip_ids: ids, service_id: scope.service}
      assert assigns(view).outcome.text == "2 trips copied. Press ⌘V in the grid to paste."
      assert assigns(view).outcome.undo? == false
      assert assigns(view).outcome.tone == :info
      assert assigns(view).undo_stack == []
      assert trip_row(first).service_id == scope.service
      assert stop_time_clocks(first) == @t0700_clocks

      # Clearing the selection keeps the clipboard: the reference's paste state
      # clears it before pasting.
      render_click(view, "clear_selection")

      assert assigns(view).clipboard.trip_ids == ids
      assert assigns(view).selected_count == 0
    end
  end

  describe "Paste copied trips" do
    test "copy_trips then paste_trips at 16:30 on Saturday persists shifted copies (FH-32)", %{
      conn: conn,
      scope: scope
    } do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")
      named_calendar!(scope, scope.service, "Weekday")

      first = linked_trip!(scope, "07:00:00", %{trip_id: "CLIP_T0700", trip_short_name: "1"})
      second = linked_trip!(scope, "07:15:00", %{trip_id: "CLIP_T0715"})
      ids = Enum.sort([first.id, second.id])

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [first, second])
      render_hook(grid(view), "copy_trips", %{})
      render_hook(grid(view), "paste_trips", %{})

      # The dialog opens on the clipboard, not the (now irrelevant) selection.
      change = assigns(view).change
      assert change.kind == :paste
      assert change.ids == ids
      assert change.params.mode == :same
      assert change.params.anchor_secs == 7 * 3_600
      assert change.params.skip_existing == true

      assert has_element?(view, "#paste-dialog[data-open='true']")
      assert has_element?(view, "#paste-dialog-title", "Paste 2 trips")
      assert has_element?(view, "#paste-context", "Copied from Weekday: 07:00–07:15")
      assert has_element?(view, "#paste-service")
      assert has_element?(view, "#paste-same[checked]")
      assert has_element?(view, "#paste-skip[checked]")

      # Same times is offset 0, so the review plans both copies on the target.
      view
      |> element("#paste-form")
      |> render_change(%{"change" => %{"service_id" => saturday}})

      change = assigns(view).change
      assert change.review.command == {:copy, ids, saturday, 0, true}
      assert change.review.counts.created == 2
      assert has_element?(view, "#paste-result", "Adds 2 trips on Saturday: 07:00, 07:15.")
      assert has_element?(view, "#paste-apply:not([disabled])", "Paste 2 trips")
      assert trips_on(scope, saturday) == []

      # A new first departure re-reviews through the facade: the copies keep the
      # source spacing, moved by 570 minutes.
      view
      |> element("#paste-form")
      |> render_change(%{"change" => %{"mode" => "at", "first_departure" => "16:30"}})

      change = assigns(view).change
      assert change.params.mode == :at
      assert change.params.first_departure == "16:30"
      assert change.review.command == {:copy, ids, saturday, @paste_offset_secs, true}
      assert change.review.counts.created == 2
      assert change.review.counts.skipped == 0

      assert has_element?(
               view,
               "#paste-result",
               "Adds 2 trips on Saturday: 16:30, 16:45. They start without a block."
             )

      view |> element("#paste-apply") |> render_click()

      # R7: the copies carry the source's clocks moved by the offset, no block,
      # and the trip number because the service day differs.
      created = trips_on(scope, saturday)

      assert Enum.map(created, & &1.trip_id) == [
               "#{@route_id}-0-#{saturday}-1630",
               "#{@route_id}-0-#{saturday}-1645"
             ]

      [copy_1630, copy_1645] = created
      assert copy_1630.service_id == saturday
      assert copy_1630.block_id == nil
      assert copy_1630.trip_short_name == "1"

      assert stop_time_clocks(copy_1630) == [
               {"16:30:00", "16:30:00", nil, nil},
               {"16:38:00", "16:39:00", nil, nil},
               {"16:55:00", "16:55:00", nil, nil}
             ]

      assert stop_time_clocks(copy_1645) == [
               {"16:45:00", "16:45:00", nil, nil},
               {"16:53:00", "16:54:00", nil, nil},
               {"17:10:00", "17:10:00", nil, nil}
             ]

      # The sources stay on Weekday with their clocks and no copy is left on the
      # source service day.
      assert trip_row(first).service_id == scope.service
      assert stop_time_clocks(first) == @t0700_clocks

      assert trips_on(scope, scope.service) |> Enum.map(& &1.trip_id) |> Enum.sort() ==
               ["CLIP_T0700", "CLIP_T0715"]

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.selected_ids == MapSet.new()
      assert assigns.undo_stack != []

      assert assigns.outcome.text == "Pasted 2 trips on Saturday. They start without a block."
      assert assigns.outcome.undo? == true
      refute has_element?(view, "#paste-dialog")
    end

    test "paste_trips with no clipboard shows the spreadsheet message and writes nothing", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CLIP_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope))

      # The hook asks first; with nothing on this page's clipboard no dialog
      # opens and no review is built.
      render_hook(grid(view), "paste_trips", %{})

      assert assigns(view).change == nil
      refute has_element?(view, "#paste-dialog")

      # The hook then reports the spreadsheet text (AC-16).
      render_hook(grid(view), "paste_text", %{})

      assert assigns(view).outcome.text ==
               "Copied trips from this page can be pasted here. To paste a timetable " <>
                 "from a spreadsheet, use Paste timetable."

      assert assigns(view).outcome.undo? == false
      assert assigns(view).undo_stack == []
      assert trip_row(trip).service_id == scope.service
      assert stop_time_clocks(trip) == @t0700_clocks
    end

    test "a first departure that is not a time keeps the input and writes nothing", %{
      conn: conn,
      scope: scope
    } do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")

      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CLIP_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      render_hook(grid(view), "copy_trips", %{})
      render_hook(grid(view), "paste_trips", %{})

      view
      |> element("#paste-form")
      |> render_change(%{
        "change" => %{"service_id" => saturday, "mode" => "at", "first_departure" => "7:75"}
      })

      # The typed value stays in the input with the dialog's own error, and no
      # review exists to apply (R2's grammar via TimeEntry).
      change = assigns(view).change
      assert change.params.first_departure == "7:75"
      assert change.review == nil
      assert has_element?(view, "#paste-at[value='7:75']")

      assert has_element?(
               view,
               "#paste-at-error",
               "Enter the time the first trip leaves, for example 16:30."
             )

      assert has_element?(view, "#paste-apply[disabled]")
      assert trips_on(scope, saturday) == []

      # A seconds-precision reading parses but cannot become the engine's
      # whole-minute offset, so it is refused the same way.
      view
      |> element("#paste-form")
      |> render_change(%{"change" => %{"mode" => "at", "first_departure" => "16:30:30"}})

      assert assigns(view).change.review == nil
      assert has_element?(view, "#paste-at-error")

      # Correcting it reviews again and enables the primary.
      view
      |> element("#paste-form")
      |> render_change(%{"change" => %{"mode" => "at", "first_departure" => "16:30"}})

      change = assigns(view).change
      assert change.review.command == {:copy, [trip.id], saturday, @paste_offset_secs, true}
      refute has_element?(view, "#paste-at-error")
      assert has_element?(view, "#paste-apply:not([disabled])", "Paste 1 trip")
    end

    test "skips a trip that already leaves at that time and ignores forged fields", %{
      conn: conn,
      scope: scope
    } do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")

      # A Saturday trip already leaves at 16:30 on the pattern, so the default
      # skip choice leaves that copy out and the review counts it.
      _existing =
        linked_trip!(scope, "16:30:00", %{service_id: saturday, trip_id: "CLIP_SAT1630"})

      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CLIP_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      render_hook(grid(view), "copy_trips", %{})
      render_hook(grid(view), "paste_trips", %{})

      view
      |> element("#paste-form")
      |> render_change(%{
        "change" => %{"service_id" => saturday, "mode" => "at", "first_departure" => "16:30"}
      })

      change = assigns(view).change
      assert change.review.counts.skipped == 1
      assert change.review.counts.created == 0

      assert has_element?(
               view,
               "#paste-skip-help",
               "1 trip already runs at the same time on Saturday."
             )

      refute has_element?(view, "#paste-result")
      assert has_element?(view, "#paste-apply[disabled]", "Paste 0 trips")

      # A forged service day and a malformed skip value never widen the reviewed
      # command (CR-5, FH-30).
      view
      |> element("#paste-form")
      |> render_change(%{
        "change" => %{"service_id" => "not-a-service", "skip_existing" => "maybe"}
      })

      change = assigns(view).change
      assert change.params.service_id == saturday
      assert change.params.skip_existing == true
      assert change.review.command == {:copy, [trip.id], saturday, @paste_offset_secs, true}

      # Unchecking skip copies the trip that already leaves at that time.
      view
      |> element("#paste-form")
      |> render_change(%{"change" => %{"skip_existing" => "false"}})

      change = assigns(view).change
      assert change.params.skip_existing == false
      assert change.review.counts.skipped == 0
      assert change.review.counts.created == 1
      refute has_element?(view, "#paste-skip-help")
      assert has_element?(view, "#paste-apply:not([disabled])", "Paste 1 trip")
    end

    test "a paste refused by the running frequency service writes nothing (R9)", %{
      conn: conn,
      scope: scope
    } do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      %{daily: daily} = shared_dates_calendars!(scope)
      named_calendar!(scope, saturday, "Saturday")
      named_calendar!(scope, daily, "Daily")
      named_calendar!(scope, scope.service, "Weekday")

      # The pattern runs frequency service on Saturday; the every-day service
      # shares dates with it, so a paste of listed trips onto Daily newly mixes
      # those dates (R9).
      _frequency =
        frequency_trip!(
          scope,
          [%{start_secs: 28_800, end_secs: 32_400, headway_secs: 600}],
          %{service_id: saturday, trip_id: "CLIP_FREQ"}
        )

      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CLIP_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      render_hook(grid(view), "copy_trips", %{})
      render_hook(grid(view), "paste_trips", %{})

      view
      |> element("#paste-form")
      |> render_change(%{
        "change" => %{"service_id" => daily, "mode" => "at", "first_departure" => "16:30"}
      })

      change = assigns(view).change

      assert {:error, {:mixed_service, details}} =
               Enum.find(change.review.change_set.consequences, &match?({:error, _}, &1))

      assert Enum.sort(details.service_ids) == Enum.sort([daily, saturday])

      assert has_element?(
               view,
               "#paste-refusal[role='alert']",
               "Daily already runs frequency service on this pattern."
             )

      assert has_element?(view, "#paste-apply[disabled]")

      assert has_element?(
               view,
               "#paste-status",
               "Nothing can be added while that frequency service runs on these days."
             )

      # A refused review adds nothing, so the dialog states no departures.
      refute has_element?(view, "#paste-result")

      # The engine refuses the command even if a client posts it anyway.
      view |> element("#paste-apply") |> render_click()

      assert assigns(view).change.refusal == [{:error, {:mixed_service, details}}]
      assert trips_on(scope, daily) == []
      assert assigns(view).undo_stack == []
    end

    test "a paste that changed after the preview writes nothing until Refresh", %{
      conn: conn,
      scope: scope
    } do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")

      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CLIP_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      render_hook(grid(view), "copy_trips", %{})
      render_hook(grid(view), "paste_trips", %{})

      view
      |> element("#paste-form")
      |> render_change(%{
        "change" => %{"service_id" => saturday, "mode" => "at", "first_departure" => "16:30"}
      })

      # Another editor retimes the copied trip after the review: the fingerprint
      # no longer matches, so the apply returns the stale result and writes
      # nothing (FH-33, AC-15).
      {:ok, _retimed} =
        Gtfs.update_trip(
          @route_id,
          trip.id,
          %{"start_time" => "08:00"},
          Repo.get!(Trip, trip.id).updated_at,
          scope.audit
        )

      retimed = stop_time_clocks(trip)

      view |> element("#paste-apply") |> render_click()

      assert has_element?(
               view,
               "#paste-stale[role='alert']",
               "These trips changed after this preview. Nothing was written."
             )

      assert has_element?(view, "#paste-refresh", "Refresh preview")
      refute has_element?(view, "#paste-apply")
      assert trips_on(scope, saturday) == []
      assert assigns(view).undo_stack == []
      assert stop_time_clocks(trip) == retimed

      view |> element("#paste-refresh") |> render_click()

      assert has_element?(view, "#paste-apply:not([disabled])", "Paste 1 trip")
      refute has_element?(view, "#paste-stale")

      view |> element("#paste-apply") |> render_click()

      assert [copy] = trips_on(scope, saturday)

      # The refreshed review copies the trip's current 08:00 clocks with the same
      # reviewed offset (+570 min), because the refresh replans the same command.
      assert stop_time_clocks(copy) == [
               {"17:30:00", "17:30:00", nil, nil},
               {"17:38:00", "17:39:00", nil, nil},
               {"17:55:00", "17:55:00", nil, nil}
             ]
    end
  end

  describe "Duplicate trips" do
    test "Duplicate trips creates same-service copies at +30 min without trip numbers", %{
      conn: conn,
      scope: scope
    } do
      named_calendar!(scope, scope.service, "Weekday")
      first = linked_trip!(scope, "07:00:00", %{trip_id: "CLIP_T0700", trip_short_name: "1"})
      second = linked_trip!(scope, "07:15:00", %{trip_id: "CLIP_T0715"})
      ids = Enum.sort([first.id, second.id])

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [first, second])
      view |> element("#bulk-duplicate") |> render_click()

      # The dialog is pinned to the current service day and opens on the
      # selection's earliest first departure 30 minutes later (R7).
      change = assigns(view).change
      assert change.kind == :duplicate
      assert change.ids == ids
      assert change.params.service_id == scope.service
      assert change.params.mode == :at
      assert change.params.first_departure == "07:30"
      assert change.params.anchor_secs == 7 * 3_600

      assert has_element?(view, "#duplicate-dialog[data-open='true']")
      assert has_element?(view, "#duplicate-dialog-title", "Duplicate 2 trips")
      assert has_element?(view, "#duplicate-context", "Weekday · 07:00–07:15")
      refute has_element?(view, "#duplicate-service")
      assert has_element?(view, "#duplicate-at[value='07:30']")
      assert has_element?(view, "#duplicate-skip[checked]")
      assert change.review.command == {:copy, ids, scope.service, 1_800, true}
      assert change.review.counts.created == 2

      assert has_element?(
               view,
               "#duplicate-result",
               "Adds 2 trips on Weekday: 07:30, 07:45. They start without a block."
             )

      assert has_element?(view, "#duplicate-apply:not([disabled])", "Duplicate 2 trips")
      assert length(trips_on(scope, scope.service)) == 2

      view |> element("#duplicate-apply") |> render_click()

      # A same-service copy repeats no trip number (FH-25) and starts unblocked.
      created = trips_on(scope, scope.service)
      assert length(created) == 4

      copies =
        created
        |> Enum.reject(&(&1.trip_id in ["CLIP_T0700", "CLIP_T0715"]))
        |> Enum.sort_by(& &1.trip_id)

      assert Enum.map(copies, & &1.trip_id) == [
               "#{@route_id}-0-#{scope.service}-0730",
               "#{@route_id}-0-#{scope.service}-0745"
             ]

      assert Enum.all?(copies, &is_nil(&1.trip_short_name))
      assert Enum.all?(copies, &is_nil(&1.block_id))

      assert stop_time_clocks(hd(copies)) == [
               {"07:30:00", "07:30:00", nil, nil},
               {"07:38:00", "07:39:00", nil, nil},
               {"07:55:00", "07:55:00", nil, nil}
             ]

      # The sources stay untouched.
      assert stop_time_clocks(first) == @t0700_clocks
      assert trip_row(first).trip_short_name == "1"

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.outcome.text == "Duplicated 2 trips on Weekday. They start without a block."
      assert assigns.outcome.undo? == true
      refute has_element?(view, "#duplicate-dialog")
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

  defp select_trips(view, trips) do
    Enum.each(trips, fn trip ->
      render_click(view, "toggle_trip", %{"trip" => trip.id})
    end)
  end

  defp trips_on(scope, service_id) do
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

  defp schedules_path(scope, params \\ %{}) do
    path = "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"

    case URI.encode_query(params) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp grid(view), do: element(view, "#schedules-grid")

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
