defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesBulkReviewTest do
  # EV-28: the bulk review lifecycle — `open_change`, `change_params`,
  # `apply_change`, `refresh_change` and `cancel_change` — through the production
  # composition (spec 18, step 29; CL-12, CL-13; FH-30, FH-33).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so LiveView event -> editor role re-read -> `Gtfs.review_trip_change/3` and
  # `Gtfs.apply_trip_change/4` -> `Gtfs.Schedules` -> the reload through the read
  # adapter is exercised end to end. Persisted stop times are asserted with
  # independent `Repo` queries, never from the rendered HTML alone. Every expected
  # clock is literal and hand-derived from R1, R3, R4, R5 and §4.4 (§4.5 for the
  # preview); nothing here computes an expectation with the code under test.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_bulk_review_test.exs`
  # (EV-28, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  @route_id "EDT_BULK"

  # Four occurrences, two of them timepoints at 0 s and +10 min and two hidden
  # stops, so a whole-trip shift moves every stored clock by the same delta and
  # the default Timepoints view previews two columns per row.
  @stops [
    {"BULK_START", 0, 0, 1},
    {"BULK_LIB", 600, 600, 1},
    {"BULK_OAK", 1_020, 1_020, 0},
    {"BULK_END", 2_220, 2_220, 0}
  ]

  @starts %{
    "BULK_T0700" => "07:00:00",
    "BULK_T0715" => "07:15:00",
    "BULK_T0730" => "07:30:00"
  }

  @t0700_before [
    {"07:00:00", "07:00:00", nil, nil},
    {"07:10:00", "07:10:00", nil, nil},
    {"07:17:00", "07:17:00", nil, nil},
    {"07:37:00", "07:37:00", nil, nil}
  ]

  @t0715_before [
    {"07:15:00", "07:15:00", nil, nil},
    {"07:25:00", "07:25:00", nil, nil},
    {"07:32:00", "07:32:00", nil, nil},
    {"07:52:00", "07:52:00", nil, nil}
  ]

  @t0700_after [
    {"07:05:00", "07:05:00", nil, nil},
    {"07:15:00", "07:15:00", nil, nil},
    {"07:22:00", "07:22:00", nil, nil},
    {"07:42:00", "07:42:00", nil, nil}
  ]

  @t0715_after [
    {"07:20:00", "07:20:00", nil, nil},
    {"07:30:00", "07:30:00", nil, nil},
    {"07:37:00", "07:37:00", nil, nil},
    {"07:57:00", "07:57:00", nil, nil}
  ]

  # The Peak timing's offsets: a +8 min second stop, a +15 min third and a
  # +30 min last, so its clocks cannot be confused with Base's.
  @peak_offsets [{0, 0, 1}, {480, 480, 1}, {900, 900, 0}, {1_800, 1_800, 0}]

  setup context do
    scope = editing_scope!(@route_id, %{stops: @stops, timing_name: "Base"})

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "a reviewed shift" do
    test "previews the reviewed times without writing", %{conn: conn, scope: scope} do
      trips = bulk_trips!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, trips, ["BULK_T0700", "BULK_T0715"])
      render_hook(grid(view), "open_change", %{"kind" => "shift"})

      change = assigns(view).change
      ids = Enum.sort([trips["BULK_T0700"].id, trips["BULK_T0715"].id])

      assert change.kind == :shift
      assert change.ids == ids
      assert change.params == %{direction: 1, minutes: 5, from_position: nil}
      assert change.refusal == nil
      refute change.stale?
      refute change.applying?
      assert change.review.command == {:shift, ids, 300, nil}

      assert change.review.counts == %{
               changed: 2,
               created: 0,
               deleted: 0,
               excluded: 0,
               skipped: 0
             }

      assert is_binary(change.review.fingerprint)

      # The reviewed times are on screen in the preview state and the stored
      # clocks are untouched (R3: a review writes nothing).
      assert has_element?(view, "td#cell-BULK_T0700-1.is-preview[title='Was 07:00']", "07:05")
      assert has_element?(view, "td#cell-BULK_T0700-2.is-preview[title='Was 07:10']", "07:15")
      assert has_element?(view, "td#cell-BULK_T0715-2.is-preview[title='Was 07:25']", "07:30")
      refute has_element?(view, "tr#trip-BULK_T0700.is-changed")
      assert stop_time_clocks(trips["BULK_T0700"]) == @t0700_before
      assert stop_time_clocks(trips["BULK_T0715"]) == @t0715_before

      # The same values re-reviewed write nothing either.
      render_hook(grid(view), "change_params", %{
        "change" => %{"direction" => "1", "minutes" => "5"}
      })

      change = assigns(view).change
      assert change.params == %{direction: 1, minutes: 5, from_position: nil}
      assert change.review.command == {:shift, ids, 300, nil}
      assert has_element?(view, "td#cell-BULK_T0700-2.is-preview", "07:15")
      assert stop_time_clocks(trips["BULK_T0700"]) == @t0700_before
      assert assigns(view).undo_stack == []
    end

    test "re-reviews with the posted direction, minutes and position", %{
      conn: conn,
      scope: scope
    } do
      trips = bulk_trips!(scope)
      trip = trips["BULK_T0700"]
      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, trips, ["BULK_T0700"])
      render_hook(grid(view), "open_change", %{"kind" => "shift"})

      render_hook(grid(view), "change_params", %{
        "change" => %{"direction" => "-1", "minutes" => "10"}
      })

      change = assigns(view).change
      assert change.params == %{direction: -1, minutes: 10, from_position: nil}
      assert change.review.command == {:shift, [trip.id], -600, nil}
      assert has_element?(view, "td#cell-BULK_T0700-1.is-preview[title='Was 07:00']", "06:50")

      # Position 2 is the second timepoint the default view shows, so a shift
      # from it moves that stop and the later ones and leaves the first alone.
      render_hook(grid(view), "change_params", %{"change" => %{"from_position" => "2"}})

      change = assigns(view).change
      assert change.params == %{direction: -1, minutes: 10, from_position: 2}
      assert change.review.command == {:shift, [trip.id], -600, 2}
      assert has_element?(view, "td#cell-BULK_T0700-1.is-preview[title='Was 07:00']", "07:00")
      assert has_element?(view, "td#cell-BULK_T0700-2.is-preview[title='Was 07:10']", "07:00")
      assert stop_time_clocks(trip) == @t0700_before

      # Applying persists only the later stops and makes the trip custom (R1's
      # relink rule finds no timing that matches the new rows).
      render_hook(grid(view), "apply_change", %{})

      assert stop_time_clocks(trip) == [
               {"07:00:00", "07:00:00", nil, nil},
               {"07:00:00", "07:00:00", nil, nil},
               {"07:07:00", "07:07:00", nil, nil},
               {"07:27:00", "07:27:00", nil, nil}
             ]

      row = trip_row(trip)
      assert row.pattern_derivation_state == "custom"
      assert row.pattern_derivation_reason == "edited_in_schedules"
      assert assigns(view).outcome.text == "Shifted 1 trip 10 min earlier."
    end

    test "an incomplete parameter set keeps the surface open without a review", %{
      conn: conn,
      scope: scope
    } do
      trips = bulk_trips!(scope)
      trip = trips["BULK_T0700"]
      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, trips, ["BULK_T0700"])
      render_hook(grid(view), "open_change", %{"kind" => "shift"})
      assert has_element?(view, ".is-preview")

      render_hook(grid(view), "change_params", %{"change" => %{"minutes" => "0"}})

      change = assigns(view).change
      assert change.params.minutes == 0
      assert change.review == nil
      assert change.refusal == nil
      refute has_element?(view, ".is-preview")

      render_hook(grid(view), "apply_change", %{})
      assert assigns(view).change.params.minutes == 0
      assert stop_time_clocks(trip) == @t0700_before
      assert assigns(view).undo_stack == []
    end

    test "applies the reviewed command and persists the literal clocks", %{
      conn: conn,
      scope: scope
    } do
      trips = bulk_trips!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, trips, ["BULK_T0700", "BULK_T0715"])
      render_hook(grid(view), "open_change", %{"kind" => "shift"})
      render_hook(grid(view), "apply_change", %{})

      assert stop_time_clocks(trips["BULK_T0700"]) == @t0700_after
      assert stop_time_clocks(trips["BULK_T0715"]) == @t0715_after
      # The trip that was not selected did not move.
      assert stop_time_clocks(trips["BULK_T0730"]) == [
               {"07:30:00", "07:30:00", nil, nil},
               {"07:40:00", "07:40:00", nil, nil},
               {"07:47:00", "07:47:00", nil, nil},
               {"08:07:00", "08:07:00", nil, nil}
             ]

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.selected_ids == MapSet.new()
      assert assigns.selected_count == 0
      assert assigns.outcome == %{tone: :info, text: "Shifted 2 trips 5 min later.", undo?: true}

      assert [%{payload: %{trips: restored}, message: "Shifted 2 trips 5 min later."}] =
               assigns.undo_stack

      assert Enum.sort(Enum.map(restored, & &1.id)) ==
               Enum.sort([trips["BULK_T0700"].id, trips["BULK_T0715"].id])

      assert assigns.just_changed ==
               MapSet.new([trips["BULK_T0700"].id, trips["BULK_T0715"].id])

      assert assigns.cell_error == nil
      assert has_element?(view, "tr#trip-BULK_T0700.is-changed")
      refute has_element?(view, ".is-preview")
      refute has_element?(view, "#selection-count")
    end

    test "a refused change keeps its refusal and writes nothing", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "00:02:00", %{trip_id: "BULK_EARLY"})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trip.id})
      render_hook(grid(view), "open_change", %{"kind" => "shift"})

      # The review plans the -5 min move, and R4's own `:negative_time`
      # consequence refuses the apply (INV-3: nothing is written).
      render_hook(grid(view), "change_params", %{
        "change" => %{"direction" => "-1", "minutes" => "5"}
      })

      change = assigns(view).change
      assert change.refusal == nil
      assert [{:error, :negative_time}] = change.review.change_set.consequences

      render_hook(grid(view), "apply_change", %{})

      change = assigns(view).change
      assert change.refusal == [{:error, :negative_time}]
      assert change.review.change_set.consequences == [{:error, :negative_time}]
      refute change.stale?

      assert stop_time_clocks(trip) == [
               {"00:02:00", "00:02:00", nil, nil},
               {"00:12:00", "00:12:00", nil, nil},
               {"00:19:00", "00:19:00", nil, nil},
               {"00:39:00", "00:39:00", nil, nil}
             ]

      assert assigns(view).undo_stack == []
    end
  end

  describe "a stale review" do
    test "never applies, and Refresh re-reviews the current rows", %{conn: conn, scope: scope} do
      trips = bulk_trips!(scope)
      trip = trips["BULK_T0700"]
      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, trips, ["BULK_T0700"])
      render_hook(grid(view), "open_change", %{"kind" => "shift"})

      reviewed = assigns(view).change.review
      assert reviewed.fingerprint

      # An independent editor retimes the same trip through the production
      # facade after the review — the state the reviewed fence must catch.
      {:ok, _retimed} =
        Gtfs.update_trip(
          @route_id,
          trip.id,
          %{"start_time" => "07:40"},
          Repo.get!(Trip, trip.id).updated_at,
          scope.audit
        )

      retimed = stop_time_clocks(trip)

      assert retimed == [
               {"07:40:00", "07:40:00", nil, nil},
               {"07:50:00", "07:50:00", nil, nil},
               {"07:57:00", "07:57:00", nil, nil},
               {"08:17:00", "08:17:00", nil, nil}
             ]

      render_hook(grid(view), "apply_change", %{})

      change = assigns(view).change
      assert change.stale?
      assert change.refusal == nil
      assert change.review.fingerprint != reviewed.fingerprint
      # The fresh review is the current state's: the trip now starts at 07:40,
      # so the +5 min preview is 07:45 and 07:55.
      assert change.review.preview[trip.id][2] == 7 * 3_600 + 55 * 60
      assert has_element?(view, "td#cell-BULK_T0700-2.is-preview", "07:55")
      # The stale review wrote nothing.
      assert stop_time_clocks(trip) == retimed
      assert assigns(view).undo_stack == []

      # Apply refuses while the review is stale, so Refresh cannot be skipped.
      render_hook(grid(view), "apply_change", %{})
      assert stop_time_clocks(trip) == retimed
      assert assigns(view).change.stale?

      # Refresh re-reviews the same state and clears the stale flag; the apply
      # then writes the literal clocks.
      stale_review = assigns(view).change.review

      render_hook(grid(view), "refresh_change", %{})

      change = assigns(view).change
      refute change.stale?
      assert change.review.fingerprint == stale_review.fingerprint
      assert change.review.fingerprint != reviewed.fingerprint
      assert change.review.preview[trip.id][2] == 7 * 3_600 + 55 * 60

      render_hook(grid(view), "apply_change", %{})

      assert stop_time_clocks(trip) == [
               {"07:45:00", "07:45:00", nil, nil},
               {"07:55:00", "07:55:00", nil, nil},
               {"08:02:00", "08:02:00", nil, nil},
               {"08:22:00", "08:22:00", nil, nil}
             ]

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.outcome.text == "Shifted 1 trip 5 min later."
      refute has_element?(view, ".is-preview")
    end
  end

  describe "forged parameters" do
    test "ignore a foreign trip, timing and position", %{conn: conn, scope: scope} do
      trips = bulk_trips!(scope)
      trip = trips["BULK_T0700"]
      other = trips["BULK_T0730"]
      {:ok, view, _html} = live(conn, schedules_path(scope))
      forged = Ecto.UUID.generate()

      # A timing change on a trip this page never loaded opens nothing.
      render_hook(grid(view), "open_change", %{"kind" => "timing", "trip" => forged})

      assert assigns(view).change == nil

      assert assigns(view).outcome == %{
               tone: :warning,
               text: ScheduleComponents.error_message(:not_found),
               undo?: false
             }

      # A shift names the selection; the trip in the payload changes nothing.
      select_trips(view, trips, ["BULK_T0700"])
      render_hook(grid(view), "open_change", %{"kind" => "shift", "trip" => other.id})

      change = assigns(view).change
      assert change.ids == [trip.id]
      assert change.review.command == {:shift, [trip.id], 300, nil}

      # A foreign timing, an unreadable position and a malformed value are all
      # ignored: the reviewed command keeps its own trips and parameters.
      render_hook(grid(view), "change_params", %{"change" => %{"timing_id" => forged}})
      assert assigns(view).change.params == %{direction: 1, minutes: 5, from_position: nil}

      render_hook(grid(view), "change_params", %{"change" => %{"from_position" => "999"}})
      assert assigns(view).change.params == %{direction: 1, minutes: 5, from_position: nil}

      render_hook(grid(view), "change_params", %{
        "change" => %{"minutes" => "7 minutes", "direction" => "9"}
      })

      assert assigns(view).change.params == %{direction: 1, minutes: 5, from_position: nil}
      assert assigns(view).change.review.command == {:shift, [trip.id], 300, nil}

      render_hook(grid(view), "apply_change", %{})

      assert stop_time_clocks(trip) == @t0700_after

      assert stop_time_clocks(other) == [
               {"07:30:00", "07:30:00", nil, nil},
               {"07:40:00", "07:40:00", nil, nil},
               {"07:47:00", "07:47:00", nil, nil},
               {"08:07:00", "08:07:00", nil, nil}
             ]
    end
  end

  describe "a reviewed timing change" do
    test "reviews and applies the named trip's new timing", %{conn: conn, scope: scope} do
      trips = bulk_trips!(scope)
      trip = trips["BULK_T0715"]
      peak = extra_timing!(scope.bundle, @peak_offsets, "Peak")
      {:ok, view, _html} = live(conn, schedules_path(scope))

      # Nothing is selected: the trip the Timing cell named opens the change
      # (step 23's hook posts `open_change` with kind and trip).
      render_hook(grid(view), "open_change", %{"kind" => "timing", "trip" => trip.id})

      change = assigns(view).change
      assert change.kind == :timing
      assert change.ids == [trip.id]
      assert change.params == %{timing_id: peak.id}
      assert change.review.command == {:set_timing, [trip.id], peak.id}
      assert has_element?(view, "td#cell-BULK_T0715-2.is-preview[title='Was 07:25']", "07:23")
      assert stop_time_clocks(trip) == @t0715_before

      render_hook(grid(view), "apply_change", %{})

      # The target timing's own rows carry its timepoint flags, so the trip's
      # stored flags become Peak's (1, 1, 0, 0) with its clocks.
      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", 1, nil},
               {"07:23:00", "07:23:00", 1, nil},
               {"07:30:00", "07:30:00", 0, nil},
               {"07:45:00", "07:45:00", 0, nil}
             ]

      row = trip_row(trip)
      assert row.pattern_derivation_state == "linked"
      assert row.timed_pattern_id == peak.id

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.outcome.text == "1 trip now uses Peak."
      assert assigns.outcome.undo?
      assert assigns.selected_count == 0
      refute has_element?(view, ".is-preview")
    end
  end

  describe "closing a review" do
    test "cancel clears the preview and keeps the selection", %{conn: conn, scope: scope} do
      trips = bulk_trips!(scope)
      trip = trips["BULK_T0700"]
      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, trips, ["BULK_T0700"])
      render_hook(grid(view), "open_change", %{"kind" => "shift"})
      assert has_element?(view, ".is-preview")

      render_hook(grid(view), "cancel_change", %{})

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.selected_ids == MapSet.new([trip.id])
      assert assigns.selected_count == 1
      assert assigns.outcome == nil
      refute has_element?(view, ".is-preview")
      assert stop_time_clocks(trip) == @t0700_before
    end

    test "a filter patch closes the review with the selection", %{conn: conn, scope: scope} do
      trips = bulk_trips!(scope)
      trip = trips["BULK_T0700"]
      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, trips, ["BULK_T0700"])
      render_hook(grid(view), "open_change", %{"kind" => "shift"})
      assert has_element?(view, ".is-preview")

      render_patch(view, schedules_path(scope, %{"direction" => "0"}))

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.selected_ids == MapSet.new()
      assert assigns.selected_count == 0
      assert assigns.outcome.text == "Selection cleared because the filter changed."
      refute has_element?(view, ".is-preview")
      assert stop_time_clocks(trip) == @t0700_before
    end

    test "a cancel or refresh with no change open is a no-op", %{conn: conn, scope: scope} do
      linked_trip!(scope, "07:00:00", %{trip_id: "BULK_T0700"})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "cancel_change", %{})
      render_hook(grid(view), "refresh_change", %{})
      render_hook(grid(view), "apply_change", %{})
      render_hook(grid(view), "open_change", %{"kind" => "convert"})

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.outcome == nil
      assert assigns.grid_revision == 0
    end
  end

  describe "the editor authority" do
    test "a revoked editor role reviews and applies nothing", %{conn: conn, scope: scope} do
      trips = bulk_trips!(scope)
      trip = trips["BULK_T0700"]
      {:ok, view, _html} = live(conn, schedules_path(scope))

      select_trips(view, trips, ["BULK_T0700"])
      render_hook(grid(view), "open_change", %{"kind" => "shift"})
      fingerprint = assigns(view).change.review.fingerprint

      membership = Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})
      message = ScheduleComponents.error_message(:unauthorized)

      # The open review is still process state; the apply re-reads the role and
      # refuses before the facade.
      render_hook(grid(view), "apply_change", %{})

      assigns = assigns(view)
      assert assigns.outcome.text == message
      assert assigns.change.review.fingerprint == fingerprint
      assert assigns.undo_stack == []
      assert stop_time_clocks(trip) == @t0700_before

      render_hook(grid(view), "cancel_change", %{})
      render_hook(grid(view), "open_change", %{"kind" => "shift"})

      assigns = assigns(view)
      assert assigns.change == nil
      assert assigns.outcome.text == message
      assert stop_time_clocks(trip) == @t0700_before
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp bulk_trips!(scope) do
    Map.new(@starts, fn {trip_id, start} ->
      {trip_id, linked_trip!(scope, start, %{trip_id: trip_id})}
    end)
  end

  defp select_trips(view, trips, names) do
    Enum.each(names, fn name ->
      render_click(view, "toggle_trip", %{"trip" => trips[name].id})
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

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
