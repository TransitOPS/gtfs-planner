defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesUndoTest do
  # EV-25: the grid's `nudge`, `undo` and `save_shortcut` events through the
  # production composition (spec 18, step 26; CL-10, CL-12; FH-26, FH-28, FH-31).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so LiveView event -> editor role re-read -> `Gtfs.apply_trip_change/4` or
  # `Gtfs.restore_trips/3` -> `Gtfs.Schedules` transaction -> audit -> reload
  # through the read adapter is exercised end to end. Persisted clocks and rows
  # are asserted with independent `Repo` reads, never from the rendered HTML
  # alone, and every expected clock is literal and hand-derived: the default
  # fixture timing materializes a 07:15 trip as A 07:15, B 07:20:00/07:20:30,
  # C 07:27, so a one-minute whole-trip nudge moves it to 07:16, 07:21:00/07:21:30
  # and 07:28 (R4, R1).
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_undo_test.exs`
  # (EV-25, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  @route_id "EDT_UNDO"
  @trip_id "UNDO_T1"
  @other_id "UNDO_T2"

  # The literal clocks the default fixture timing materializes at 07:15 and then
  # at 07:16 after a one-minute nudge.
  @original [
    {"07:15:00", "07:15:00", nil, nil},
    {"07:20:00", "07:20:30", nil, nil},
    {"07:27:00", "07:27:00", nil, nil}
  ]
  @nudged [
    {"07:16:00", "07:16:00", nil, nil},
    {"07:21:00", "07:21:30", nil, nil},
    {"07:28:00", "07:28:00", nil, nil}
  ]

  setup context do
    scope = editing_scope!(@route_id)

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "a nudge" do
    test "moves the named trip and its undo restores the literal clocks", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})

      assert stop_time_clocks(trip) == @nudged

      assigns = assigns(view)
      assert assigns.outcome == %{tone: :info, text: "Moved 1 trip 1 min later.", undo?: true}
      assert assigns.just_changed == MapSet.new([trip.id])
      assert assigns.cell_error == nil
      assert assigns.grid_revision == 1
      assert [%{message: "Moved 1 trip 1 min later."}] = assigns.undo_stack

      render_hook(grid(view), "undo", %{})

      assert stop_time_clocks(trip) == @original

      assigns = assigns(view)
      assert assigns.outcome.text == "Undid: Moved 1 trip 1 min later."
      assert assigns.outcome.tone == :info
      refute assigns.outcome.undo?
      assert assigns.undo_stack == []
      assert assigns.just_changed == MapSet.new([trip.id])
      assert assigns.grid_revision == 2
    end

    test "shifts the selection instead of the named trip", %{conn: conn, scope: scope} do
      first = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      second = linked_trip!(scope, "08:15:00", %{trip_id: @other_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => first.id})
      render_click(view, "toggle_trip", %{"trip" => second.id})

      render_hook(grid(view), "nudge", %{"minutes" => 5, "trip" => first.id})

      assert stop_time_clocks(first) == [
               {"07:20:00", "07:20:00", nil, nil},
               {"07:25:00", "07:25:30", nil, nil},
               {"07:32:00", "07:32:00", nil, nil}
             ]

      assert stop_time_clocks(second) == [
               {"08:20:00", "08:20:00", nil, nil},
               {"08:25:00", "08:25:30", nil, nil},
               {"08:32:00", "08:32:00", nil, nil}
             ]

      assigns = assigns(view)
      assert assigns.outcome.text == "Moved 2 trips 5 min later."
      assert length(assigns.undo_stack) == 1
      # A nudge keeps the selection, so the bar can repeat it.
      assert assigns.selected_count == 2
    end

    test "a forged trip, a forged count or no target writes nothing", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => Ecto.UUID.generate()})

      assert stop_time_clocks(trip) == @original
      assert assigns(view).outcome.text == ScheduleComponents.error_message(:not_found)
      assert assigns(view).undo_stack == []

      render_hook(grid(view), "nudge", %{"minutes" => 1_000, "trip" => trip.id})
      render_hook(grid(view), "nudge", %{"minutes" => "1", "trip" => trip.id})
      render_hook(grid(view), "nudge", %{"trip" => trip.id})

      assert stop_time_clocks(trip) == @original
      assert assigns(view).undo_stack == []
    end

    test "refuses a move before midnight and writes nothing", %{conn: conn, scope: scope} do
      # 00:03 is inside the five-minute nudge, so -5 crosses midnight and the
      # engine's `:negative_time` refusal is the path under test.
      trip = linked_trip!(scope, "00:03:00", %{trip_id: "UNDO_EARLY"})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)

      render_hook(grid(view), "nudge", %{"minutes" => -5, "trip" => trip.id})

      assert stop_time_clocks(trip) == before

      assigns = assigns(view)
      assert assigns.outcome.tone == :warning
      assert assigns.outcome.text == "Nothing was shifted. A trip can't start before 00:00."
      assert assigns.undo_stack == []
    end
  end

  describe "an undo" do
    test "writes nothing when another writer changed the trip and says so", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})

      # An independent editor retimes the same trip through the production facade
      # after the nudge — the exact state the R10 restore fence must catch.
      {:ok, _retimed} =
        Gtfs.update_trip(
          @route_id,
          trip.id,
          %{"start_time" => "07:40:00"},
          Repo.get!(Trip, trip.id).updated_at,
          scope.audit
        )

      after_edit = stop_time_clocks(trip)
      updated_at = trip_row(trip).updated_at

      render_hook(grid(view), "undo", %{})

      assert stop_time_clocks(trip) == after_edit
      assert trip_row(trip).updated_at == updated_at

      assigns = assigns(view)
      assert assigns.outcome.tone == :warning

      assert assigns.outcome.text ==
               "Nothing was undone. The 07:40 trip changed after your change. " <>
                 "Its current times are shown."

      refute assigns.outcome.undo?
      # A payload is single-use: the refused entry is consumed, not retried.
      assert assigns.undo_stack == []
      assert assigns.just_changed == MapSet.new()
      assert assigns.grid_revision == 2
      # The refusal reloaded the page, so the current times are on screen.
      assert has_element?(view, "#cell-#{@trip_id}-1", "07:40")
    end

    test "ignores forged params and restores the entry the process holds", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      other = linked_trip!(scope, "08:15:00", %{trip_id: @other_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})

      forged = %{
        "payload" => %{"operation_id" => Ecto.UUID.generate(), "trips" => [], "created" => []},
        "message" => "Moved 1 trip 5 min later.",
        "minutes" => -5,
        "trip" => other.id,
        "expected" => %{trip.id => "2000-01-01T00:00:00Z"}
      }

      render_hook(grid(view), "undo", forged)

      assert stop_time_clocks(trip) == @original

      assert stop_time_clocks(other) == [
               {"08:15:00", "08:15:00", nil, nil},
               {"08:20:00", "08:20:30", nil, nil},
               {"08:27:00", "08:27:00", nil, nil}
             ]

      assigns = assigns(view)
      assert assigns.outcome.text == "Undid: Moved 1 trip 1 min later."
      assert assigns.undo_stack == []
    end

    test "keeps 20 entries and drops the oldest", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      for _nudge <- 1..21 do
        render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})
      end

      assigns = assigns(view)
      assert length(assigns.undo_stack) == 20

      # The first nudge's capture (a 07:15 departure) was dropped: the oldest
      # surviving entry is the second nudge's, whose captured departure is 07:16.
      assert [%{stop_times: [first_stop | _rest]}] = List.last(assigns.undo_stack).payload.trips
      assert first_stop.departure_time == "07:16:00"

      render_hook(grid(view), "undo", %{})

      # One undo returns to the 20th nudge's state, not the starting 07:15.
      assert stop_time_clocks(trip) == [
               {"07:35:00", "07:35:00", nil, nil},
               {"07:40:00", "07:40:30", nil, nil},
               {"07:47:00", "07:47:00", nil, nil}
             ]

      assert length(assigns(view).undo_stack) == 19
    end

    test "a revoked role cannot undo or nudge", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})
      moved = stop_time_clocks(trip)

      membership = Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      render_hook(grid(view), "undo", %{})
      assert stop_time_clocks(trip) == moved

      assigns = assigns(view)

      assert assigns.outcome == %{
               tone: :warning,
               text: ScheduleComponents.error_message(:unauthorized),
               undo?: false
             }

      # The refused role leaves the entry alone.
      assert [%{message: "Moved 1 trip 1 min later."}] = assigns.undo_stack

      render_hook(grid(view), "nudge", %{"minutes" => 5, "trip" => trip.id})
      assert stop_time_clocks(trip) == moved
    end

    test "an empty stack does nothing", %{conn: conn, scope: scope} do
      linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "undo", %{"payload" => %{"trips" => []}})

      assigns = assigns(view)
      assert assigns.undo_stack == []
      assert assigns.outcome == nil
      assert assigns.grid_revision == 0
    end
  end

  describe "the save shortcut" do
    test "reports that every action is already saved", %{conn: conn, scope: scope} do
      linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "save_shortcut", %{})

      assert assigns(view).outcome == %{
               tone: :info,
               text: "All changes are saved.",
               undo?: false
             }
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp schedules_path(scope, params \\ %{}) do
    path = "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"

    case params do
      %{} when map_size(params) == 0 -> path
      _params -> path <> "?" <> URI.encode_query(params)
    end
  end

  defp grid(view), do: element(view, "#schedules-grid")

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
