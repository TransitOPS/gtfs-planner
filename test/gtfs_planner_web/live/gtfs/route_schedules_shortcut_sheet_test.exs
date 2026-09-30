defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesShortcutSheetTest do
  # EV-37: the keyboard shortcut sheet on the Schedules page (spec 18, step 39;
  # CL-14, AC-7; FH-46).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so the button and the sheet come from the production composition:
  # RouteSchedulesLive -> ScheduleComponents.filter_bar/1 ->
  # ScheduleChangeComponents.shortcut_sheet/1. Expected values are literal,
  # hand-derived from the reference
  # (`references/advanced-trip-editing-prototype.html`, state `shortcuts`): the
  # four group headings, the key rows, the copy and the ids are written out here,
  # never computed by the code under test.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_shortcut_sheet_test.exs`
  # (EV-37, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.ScheduleEditingFixtures

  @route_id "SKS"
  @trip_id "SKS_T1"
  @heads "SKS Dest"

  # The reference's four groups, in its order.
  @groups ["Move around", "Change times", "Trips", "Copy and undo"]

  setup context do
    scope = editing_scope!(@route_id)

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "opening the shortcut sheet" do
    test "the grid hook's toggle_shortcuts opens it (FH-46)", %{conn: conn, scope: scope} do
      trip!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      refute has_element?(view, "#shortcut-sheet[data-open='true']")

      render_hook(grid(view), "toggle_shortcuts", %{})

      assert has_element?(view, "#shortcut-sheet[data-open='true'][role='alertdialog']")
      assert has_element?(view, "#shortcut-sheet-title", "Keyboard shortcuts")
    end

    test "the filter-bar button opens it and it returns focus to the button", %{
      conn: conn,
      scope: scope
    } do
      trip!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      assert has_element?(
               view,
               "#schedules-toolbar #keyboard-shortcuts-button",
               "Keyboard shortcuts"
             )

      view |> element("#keyboard-shortcuts-button") |> render_click()

      assert has_element?(view, "#shortcut-sheet[data-open='true']")

      # The button names itself, so Close and Escape hand focus back to it.
      assert has_element?(
               view,
               "#shortcut-sheet[data-return-focus-id='keyboard-shortcuts-button']"
             )
    end
  end

  describe "the sheet's content" do
    test "carries the reference's groups, keys and copy", %{conn: conn, scope: scope} do
      trip!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "toggle_shortcuts", %{})

      for heading <- @groups do
        assert has_element?(view, "#shortcut-sheet h3", heading)
      end

      assert has_element?(view, "#shortcut-sheet", "On Windows, use Ctrl for ⌘.")

      # The key caps: chords read as one cap, alt forms keep their own caps.
      for cap <- ["⌘Z", "⌘↑", "⇧↓", "?", "+3", "0–9", "Enter"] do
        assert has_element?(view, "#shortcut-sheet kbd", cap)
      end

      for label <- [
            "Move the cursor",
            "First or last column",
            "Start typing; it replaces the time",
            "Save; only this stop",
            "Extend the selection",
            "Shift 1 min later or earlier",
            "Undo the last change",
            "Nothing to save: changes save as you go"
          ] do
        assert has_element?(view, "#shortcut-sheet dd", label)
      end

      # Four groups and every key cap the reference shows, none of the page's
      # other keycaps (the grid bar's idle hint) counted here.
      document = LazyHTML.from_fragment(render(view))

      assert Enum.count(LazyHTML.query(document, "#shortcut-sheet section")) == 4
      assert Enum.count(LazyHTML.query(document, "#shortcut-sheet kbd")) == 34
    end
  end

  describe "closing the shortcut sheet" do
    test "Close dismisses it and a grid-opened sheet keeps the dialog's own focus restore", %{
      conn: conn,
      scope: scope
    } do
      trip!(scope)
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "toggle_shortcuts", %{})

      # The grid's `?` opener is the focused cell, so the sheet overrides no
      # focus target: the modal chrome restores focus to that opener.
      refute has_element?(view, "#shortcut-sheet[data-return-focus-id]")
      # Escape is the modal chrome's own dismiss click on this button.
      assert has_element?(view, "#shortcuts-close[data-dialog-dismiss]", "Close")

      view |> element("#shortcuts-close") |> render_click()

      assert has_element?(view, "#shortcut-sheet[data-open='false'][aria-hidden='true']")
      refute has_element?(view, "#shortcut-sheet[data-open='true']")
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp trip!(scope) do
    linked_trip!(scope, "07:00:00", %{trip_id: @trip_id, trip_headsign: @heads})
  end

  defp schedules_path(scope) do
    "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"
  end

  defp grid(view), do: element(view, "#schedules-grid")
end
