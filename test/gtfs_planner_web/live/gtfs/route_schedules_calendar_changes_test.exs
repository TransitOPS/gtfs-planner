defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesCalendarChangesTest do
  # EV-29: Copy to calendar and Change calendar through the production
  # composition — the reviewed drawer, its target and skip controls, and the
  # apply behind the review fingerprint (spec 18, step 31; CL-13; FH-33, FH-35).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so LiveView event -> editor role re-read -> `Gtfs.review_trip_change/3` and
  # `Gtfs.apply_trip_change/4` -> `Gtfs.Schedules` -> the reload through the read
  # adapter is exercised end to end. Persisted rows and clocks are asserted with
  # independent `Repo` queries, never from the rendered HTML alone. Every expected
  # value is literal and hand-derived from R6, R7 and §4.4.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_calendar_changes_test.exs`
  # (EV-29, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.GtfsFixtures, only: [calendar_attribute_fixture: 3]
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @route_id "EDT_CAL"

  # Three occurrences: two timepoints and a trailing stop, so each copied
  # position stores its own clock.
  @stops [
    {"CAL_START", 0, 0, 1},
    {"CAL_LIB", 480, 540, 1},
    {"CAL_END", 1_500, 1_500, 0}
  ]

  # A linked trip starting at 07:15 on @stops.
  @t0715_clocks [
    {"07:15:00", "07:15:00", nil, nil},
    {"07:23:00", "07:24:00", nil, nil},
    {"07:40:00", "07:40:00", nil, nil}
  ]

  setup context do
    scope = editing_scope!(@route_id, %{stops: @stops, timing_name: "Base"})

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "Copy to calendar" do
    test "persists the copies and reports the skipped count", %{conn: conn, scope: scope} do
      %{saturday: saturday, weekday: weekday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")
      named_calendar!(scope, scope.service, "Weekday")

      # A Saturday trip already leaves at 07:00 on the pattern, so the default
      # skip choice leaves that copy out.
      _existing = linked_trip!(scope, "07:00:00", %{service_id: saturday, trip_id: "CAL_SAT0700"})

      first = linked_trip!(scope, "07:00:00", %{trip_id: "CAL_T0700"})
      second = linked_trip!(scope, "07:15:00", %{trip_id: "CAL_T0715"})
      ids = Enum.sort([first.id, second.id])

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [first, second])
      view |> element("#bulk-copy") |> render_click()

      change = assigns(view).change
      assert change.kind == :copy
      assert change.ids == ids
      assert change.params.service_id in [saturday, weekday]
      assert change.params.skip_existing == true

      assert has_element?(view, "#change-review-title", "Copy 2 trips to")
      assert has_element?(view, "#change-review", "Preview · not saved")
      assert has_element?(view, "#review-skip[checked]")
      assert has_element?(view, "#review-form", "Copy to")

      # The review writes nothing: the stored clocks are still the source's.
      assert stop_time_clocks(first) == [
               {"07:00:00", "07:00:00", nil, nil},
               {"07:08:00", "07:09:00", nil, nil},
               {"07:25:00", "07:25:00", nil, nil}
             ]

      assert stop_time_clocks(second) == @t0715_clocks

      # Choosing Saturday re-reviews through the facade: the 07:00 copy is
      # skipped because a trip already leaves at that time on that service day.
      view
      |> element("#review-form")
      |> render_change(%{"change" => %{"service_id" => saturday}})

      change = assigns(view).change
      assert change.params.service_id == saturday
      assert change.review.command == {:copy, ids, saturday, 0, true}

      assert change.review.counts == %{
               changed: 0,
               created: 1,
               deleted: 0,
               excluded: 0,
               skipped: 1
             }

      assert has_element?(view, "#change-review", "Skipped · already leaves at this time")

      assert has_element?(
               view,
               "#change-review",
               "1 trip already runs at the same time on Saturday."
             )

      assert has_element?(view, "#review-apply:not([disabled])", "Copy 1 trip")

      assert has_element?(
               view,
               "#review-status",
               "Nothing changes until you copy. Then it saves to #{scope.version.name} right away."
             )

      # Weekday and Saturday run on disjoint dates, so the drawer has no
      # "Also changes" card.
      refute has_element?(view, "#change-review", "Also changes")

      view |> element("#review-apply") |> render_click()

      # R7: one new trip on Saturday at the source's clocks, no block, and the
      # trip number is kept because the service day differs.
      created = trips_on(scope, saturday)

      assert Enum.map(created, & &1.trip_id) == [
               "CAL_SAT0700",
               "#{@route_id}-0-#{saturday}-0715"
             ]

      copy = Enum.find(created, &(&1.trip_id != "CAL_SAT0700"))
      assert copy.service_id == saturday
      assert copy.block_id == nil
      assert stop_time_clocks(copy) == @t0715_clocks

      # The source trips stay on Weekday with their clocks and blocks.
      assert trip_row(first).service_id == scope.service

      assert stop_time_clocks(first) == [
               {"07:00:00", "07:00:00", nil, nil},
               {"07:08:00", "07:09:00", nil, nil},
               {"07:25:00", "07:25:00", nil, nil}
             ]

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.selected_ids == MapSet.new()
      assert assigns.selected_count == 0
      assert assigns.undo_stack != []

      assert assigns.outcome.text ==
               "Copied 1 trip to Saturday. 1 trip was skipped because it already leaves at the same time."

      assert assigns.outcome.undo? == true
      refute has_element?(view, "#change-review")
    end

    test "unchecking skip copies the trip that already leaves at that time", %{
      conn: conn,
      scope: scope
    } do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")

      _existing = linked_trip!(scope, "07:00:00", %{service_id: saturday, trip_id: "CAL_SAT0700"})
      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CAL_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      view |> element("#bulk-copy") |> render_click()

      view
      |> element("#review-form")
      |> render_change(%{"change" => %{"service_id" => saturday, "skip_existing" => "false"}})

      change = assigns(view).change
      assert change.params.skip_existing == false
      assert change.review.counts.skipped == 0
      assert change.review.counts.created == 1
      assert has_element?(view, "#review-apply:not([disabled])", "Copy 1 trip")

      view |> element("#review-apply") |> render_click()

      assert length(trips_on(scope, saturday)) == 2

      assert assigns(view).outcome.text ==
               "Copied 1 trip to Saturday. They start without a block."
    end

    test "a service day that shares dates gets its own card", %{conn: conn, scope: scope} do
      %{daily: daily} = shared_dates_calendars!(scope)
      named_calendar!(scope, daily, "Daily")
      named_calendar!(scope, scope.service, "Weekday")

      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CAL_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      view |> element("#bulk-copy") |> render_click()

      view
      |> element("#review-form")
      |> render_change(%{"change" => %{"service_id" => daily}})

      # Every weekday of 2026 is shared with the every-day service.
      assert has_element?(view, "#change-review", "Also changes · Weekday")
      assert has_element?(view, "#change-review", "Weekday and Daily both run on 261 dates.")
      refute has_element?(view, "#review-refusal")

      # A target the drawer never offered is ignored: the reviewed command keeps
      # the offered service day (FH-30).
      view
      |> element("#review-form")
      |> render_change(%{"change" => %{"service_id" => "not-a-service"}})

      assert assigns(view).change.params.service_id == daily
      assert assigns(view).change.review.command == {:copy, [trip.id], daily, 0, true}
    end

    test "with one service day the bar says there is nowhere to copy or move to", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CAL_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      view |> element("#bulk-copy") |> render_click()

      assert assigns(view).change == nil

      assert has_element?(
               view,
               "#grid-bar-message",
               "There is no other service day to copy or move trips to."
             )

      refute has_element?(view, "#change-review")
    end
  end

  describe "Change calendar" do
    test "a move keeps a block when every trip of the block moves", %{conn: conn, scope: scope} do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")
      named_calendar!(scope, scope.service, "Weekday")

      first = linked_trip!(scope, "07:00:00", %{trip_id: "CAL_T103A", block_id: "103"})
      second = linked_trip!(scope, "07:30:00", %{trip_id: "CAL_T103B", block_id: "103"})
      ids = Enum.sort([first.id, second.id])

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [first, second])
      view |> element("#bulk-move") |> render_click()

      change = assigns(view).change
      assert change.kind == :move
      assert change.ids == ids
      refute Map.has_key?(change.params, :skip_existing)

      # A move has no skip choice; its table shows the block each trip keeps.
      refute has_element?(view, "#review-skip")
      assert has_element?(view, "#change-review-title", "Move 2 trips to")
      assert has_element?(view, "#review-form", "Move to")
      assert has_element?(view, "#review-apply", "Move 2 trips")

      view
      |> element("#review-form")
      |> render_change(%{"change" => %{"service_id" => saturday}})

      change = assigns(view).change
      assert change.params.service_id == saturday
      assert change.review.command == {:move_calendar, ids, saturday}
      assert change.review.counts.changed == 2
      assert change.review.change_set.consequences == []

      # R6: both trips move together, so the projection keeps block 103 and the
      # card says no block problems were added.
      assert has_element?(view, "#change-review", "103 → 103")
      assert has_element?(view, "#change-review", "No new block problems.")

      view |> element("#review-apply") |> render_click()

      moved = trips_on(scope, saturday) |> Map.new(&{&1.trip_id, &1})
      assert Map.keys(moved) |> Enum.sort() == ["CAL_T103A", "CAL_T103B"]

      for id <- ["CAL_T103A", "CAL_T103B"] do
        assert moved[id].service_id == saturday
        assert moved[id].block_id == "103"
        assert moved[id].route_pattern_id == scope.bundle.pattern.route_pattern_id
      end

      # The moved trips keep their clocks: a move changes no stop time.
      assert stop_time_clocks(moved["CAL_T103A"]) == [
               {"07:00:00", "07:00:00", nil, nil},
               {"07:08:00", "07:09:00", nil, nil},
               {"07:25:00", "07:25:00", nil, nil}
             ]

      assert assigns(view).outcome.text == "Moved 2 trips to Saturday. Blocks are kept."
    end

    test "a trip whose companions stay leaves its block", %{conn: conn, scope: scope} do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")

      first = linked_trip!(scope, "07:00:00", %{trip_id: "CAL_T103A", block_id: "103"})
      _second = linked_trip!(scope, "07:30:00", %{trip_id: "CAL_T103B", block_id: "103"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [first])
      view |> element("#bulk-move") |> render_click()

      view
      |> element("#review-form")
      |> render_change(%{"change" => %{"service_id" => saturday}})

      change = assigns(view).change
      assert change.review.command == {:move_calendar, [first.id], saturday}

      assert change.review.change_set.consequences == [
               {:note, {:cleared_block, first.id, "103"}}
             ]

      assert has_element?(view, "#change-review", "103 → none")
      assert has_element?(view, "#change-review", "1 trip leaves block 103")
      assert has_element?(view, "#review-apply", "Move 1 trip")

      view |> element("#review-apply") |> render_click()

      assert trip_row(first).service_id == saturday
      assert trip_row(first).block_id == nil
      assert assigns(view).outcome.text == "Moved 1 trip to Saturday. 1 trip left block 103."
    end
  end

  describe "R9 mixing (FH-35)" do
    test "the refusal renders the banner and disables the primary", %{conn: conn, scope: scope} do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      %{daily: daily} = shared_dates_calendars!(scope)
      named_calendar!(scope, saturday, "Saturday")
      named_calendar!(scope, daily, "Daily")
      named_calendar!(scope, scope.service, "Weekday")

      # The pattern runs frequency service on Saturday; the every-day service
      # shares dates with it, so copying listed trips there newly mixes those
      # dates (R9).
      _frequency =
        frequency_trip!(
          scope,
          [%{start_secs: 28_800, end_secs: 32_400, headway_secs: 600}],
          %{service_id: saturday, trip_id: "CAL_FREQ"}
        )

      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CAL_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      view |> element("#bulk-copy") |> render_click()

      view
      |> element("#review-form")
      |> render_change(%{"change" => %{"service_id" => daily}})

      change = assigns(view).change

      assert {:error, {:mixed_service, details}} =
               Enum.find(change.review.change_set.consequences, &match?({:error, _}, &1))

      assert Enum.sort(details.service_ids) == Enum.sort([daily, saturday])
      assert details.date_count > 0

      assert has_element?(
               view,
               "#review-refusal[role='alert']",
               "Daily already runs frequency service on this pattern."
             )

      assert has_element?(
               view,
               "#review-refusal",
               "Listed trips can't run on the same days. Convert the frequency service to scheduled trips first."
             )

      assert has_element?(view, "#review-apply[disabled]", "Copy 1 trip")

      assert has_element?(
               view,
               "#review-status",
               "Nothing can be added while that frequency service runs on these days."
             )

      refute has_element?(view, "#review-stale")

      # The primary is disabled, and the engine still refuses the command if a
      # client posts the event anyway: no row is written.
      render_click(view, "apply_change", %{})

      assert assigns(view).change.refusal == [{:error, {:mixed_service, details}}]
      assert trips_on(scope, daily) == []
      assert assigns(view).undo_stack == []
    end
  end

  describe "the changed-elsewhere state (FH-33)" do
    test "a copy that changed after the preview writes nothing until Refresh", %{
      conn: conn,
      scope: scope
    } do
      %{saturday: saturday} = weekday_and_saturday!(scope)
      named_calendar!(scope, saturday, "Saturday")

      trip = linked_trip!(scope, "07:00:00", %{trip_id: "CAL_T0700"})

      {:ok, view, _html} = live(conn, schedules_path(scope, %{"service_id" => scope.service}))

      select_trips(view, [trip])
      view |> element("#bulk-copy") |> render_click()

      view
      |> element("#review-form")
      |> render_change(%{"change" => %{"service_id" => saturday}})

      # Another editor retimes the trip after the review: the fingerprint no
      # longer matches, so the apply returns the stale result and writes nothing.
      {:ok, _retimed} =
        Gtfs.update_trip(
          @route_id,
          trip.id,
          %{"start_time" => "08:00:00"},
          Repo.get!(Trip, trip.id).updated_at,
          scope.audit
        )

      retimed = stop_time_clocks(trip)

      view |> element("#review-apply") |> render_click()

      assert has_element?(
               view,
               "#review-stale[role='alert']",
               "These trips changed after this preview. Nothing was written."
             )

      assert has_element?(view, "#review-refresh.btn-primary", "Refresh preview")
      refute has_element?(view, "#review-apply")
      assert trips_on(scope, saturday) == []
      assert assigns(view).undo_stack == []

      view |> element("#review-refresh") |> render_click()

      assert has_element?(view, "#review-apply:not([disabled])", "Copy 1 trip")
      refute has_element?(view, "#review-stale")

      view |> element("#review-apply") |> render_click()

      assert [copy] = trips_on(scope, saturday)
      assert stop_time_clocks(copy) == retimed
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

  defp schedules_path(scope, params) do
    path = "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"

    case URI.encode_query(params) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
