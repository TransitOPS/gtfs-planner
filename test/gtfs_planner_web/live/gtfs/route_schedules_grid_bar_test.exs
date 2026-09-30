defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesGridBarTest do
  # EV-27: the sticky grid bar's states through the production composition (spec
  # 18, step 28; CL-13, FH-34).
  #
  # Every mounted case goes through the authenticated router with no injected
  # assigns, so the bar renders the server's own assigns: `selected_count`,
  # `outcome` and `undo_stack`. The nudge and undo cases write through the real
  # `Gtfs` facade, and the hand-off case counts the rendered primary buttons, so
  # "the selection bar shows two primaries" fails here rather than in review.
  # Expected sentences are literal, hand-derived from the reference and the
  # step's own copy; none is computed by the code under test.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_grid_bar_test.exs`
  # (EV-27, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.ScheduleChangeComponents

  @route_id "EDT_GRIDBAR"
  @trip_id "BAR_T1"
  @other_id "BAR_T2"

  @hint "Select trips to shift, copy or change them."

  setup context do
    scope = editing_scope!(@route_id)

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "the idle bar" do
    test "reads its hint with no selection and no outcome", %{conn: conn, scope: scope} do
      linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      assert has_element?(view, "#grid-bar[data-tone='idle']")
      assert has_element?(view, "#grid-bar", @hint)
      # The hint names the shortcut sheet's key, as the reference does.
      assert has_element?(view, "#grid-bar", "Press ? for keyboard shortcuts.")
      refute has_element?(view, "#selection-count")
      refute has_element?(view, "#grid-bar-outcome")
      refute has_element?(view, "#undo-action")
      refute assigns(view).outcome

      # Nothing else carries a primary, so Add trips is the page's one.
      assert primaries(view) == ["schedules-add-trips"]
    end
  end

  describe "selection mode" do
    test "carries one primary and steps the scope bar's Add trips back (FH-34)",
         %{conn: conn, scope: scope} do
      first = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      second = linked_trip!(scope, "08:15:00", %{trip_id: @other_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => first.id})
      render_click(view, "toggle_trip", %{"trip" => second.id})

      assert has_element?(view, "#grid-bar[data-tone='sel']")
      assert has_element?(view, "#selection-count", "2 trips selected")
      assert has_element?(view, "#bulk-shift", "Shift times")
      assert has_element?(view, "#bulk-timing", "Change timing")
      assert has_element?(view, "#bulk-copy", "Copy to calendar")
      assert has_element?(view, "#bulk-more", "More")
      assert has_element?(view, "#bulk-delete", "Delete 2 trips")
      assert has_element?(view, "#clear-selection", "Clear selection")
      refute has_element?(view, "#grid-bar-message")

      # Shift times is the page's one primary; Add trips steps back to the
      # design system's secondary control while the bar carries it.
      assert has_element?(view, "#bulk-shift.btn-primary")
      assert has_element?(view, "#schedules-add-trips.btn-outline")
      refute has_element?(view, "#schedules-add-trips.btn-primary")
      assert primaries(view) == ["bulk-shift"]

      # The bar widens to the prototype's 980 px while it holds the verbs.
      assert render(view) =~ "max-w-[980px]"

      # Clearing the selection returns the primary and the hint.
      render_click(element(view, "#clear-selection"))

      refute has_element?(view, "#selection-count")
      assert has_element?(view, "#grid-bar[data-tone='idle']", @hint)
      assert primaries(view) == ["schedules-add-trips"]
    end

    test "Delete N trips opens the existing delete confirmation",
         %{conn: conn, scope: scope} do
      first = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      second = linked_trip!(scope, "08:15:00", %{trip_id: @other_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => first.id})
      render_click(view, "toggle_trip", %{"trip" => second.id})
      render_click(element(view, "#bulk-delete"))

      assert has_element?(view, "#delete-dialog[data-open='true']")
      assert renders(view, "#delete-dialog-title") =~ "Delete 2 trips from"
      assert renders(view, "#delete-dialog") =~ "You can&#39;t undo this."
    end

    test "the More menu renders its items through the row-menu popover",
         %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trip.id})

      assert has_element?(view, "#bulk-more[popovertarget='bulk-menu'][aria-haspopup='menu']")

      assert has_element?(view, "#bulk-menu[popover='auto'][role='menu']")
      assert has_element?(view, "#bulk-move", "Change calendar…")
      assert has_element?(view, "#bulk-duplicate", "Duplicate trips…")
      assert has_element?(view, "#bulk-clip", "Copy trips")
      # The popover opens upward: the anchor puts its bottom at the trigger's top.
      assert render(view) =~ "bottom: anchor(top)"
    end
  end

  describe "the outcome" do
    test "renders above the verbs with Undo after a nudge", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trip.id})
      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})

      # A nudge keeps the selection, so the outcome takes the rule-separated line
      # above the verbs and the bar keeps its selection tone.
      assert has_element?(view, "#grid-bar[data-tone='sel']")
      assert has_element?(view, "#grid-bar-outcome", "Moved 1 trip 1 min later.")
      assert has_element?(view, "#undo-action", "Undo")
      refute has_element?(view, "#undo-action[disabled]")
      assert has_element?(view, "#selection-count", "1 trip selected")
      assert has_element?(view, "#bulk-shift.btn-primary")
      # The same sentence is announced through the page's existing live region.
      assert has_element?(view, "#schedules-live-region", "Moved 1 trip 1 min later.")
    end

    test "reports the undo and drops the affordance when the stack empties",
         %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trip.id})
      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})
      render_hook(grid(view), "undo", %{})

      assert has_element?(view, "#grid-bar-outcome", "Undid: Moved 1 trip 1 min later.")
      assert assigns(view).undo_stack == []
      # The outcome is no longer undoable, so the bar offers no Undo at all.
      refute has_element?(view, "#undo-action")
      assert has_element?(view, "#selection-count", "1 trip selected")
    end

    test "shows a refused undo as a warning without offering Undo", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trip.id})
      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})

      # An independent editor retimes the trip after the nudge: the state R10's
      # restore fence refuses.
      {:ok, _retimed} =
        Gtfs.update_trip(
          @route_id,
          trip.id,
          %{"start_time" => "07:40"},
          Repo.get!(Trip, trip.id).updated_at,
          scope.audit
        )

      render_hook(grid(view), "undo", %{})

      assert has_element?(view, "#grid-bar[data-tone='sel']")
      assert has_element?(view, "#grid-bar-outcome", "Nothing was undone.")
      assert renders(view, "#grid-bar-outcome") =~ "text-warning-fg"
      refute has_element?(view, "#undo-action")
      refute has_element?(view, "#undo-action[disabled]")
      assert assigns(view).outcome.tone == :warning
    end

    test "an outcome without a selection takes the whole bar", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "nudge", %{"minutes" => 1, "trip" => trip.id})

      refute has_element?(view, "#selection-count")
      assert has_element?(view, "#grid-bar[data-tone='info']")
      assert has_element?(view, "#grid-bar-outcome", "Moved 1 trip 1 min later.")
      assert has_element?(view, "#undo-action", "Undo")
      # The outcome takes the bar and keeps Add trips' primary hand-off.
      assert primaries(view) == ["schedules-add-trips"]
    end
  end

  describe "grid_bar/1" do
    test "renders the warning ground for a warning outcome with no Undo" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleChangeComponents.grid_bar
          selected_count={0}
          outcome={
            %{tone: :warning, text: "Nothing was undone. Its current times are shown.", undo?: false}
          }
          undo_stack={[]}
        />
        """)

      document = doc(html)

      assert bar_attribute(document, "data-tone") == ["warn"]
      assert bar_class(document) =~ "bg-warning-bg"

      assert text(document, "#grid-bar-message") ==
               "Nothing was undone. Its current times are shown."

      assert Enum.empty?(LazyHTML.query(document, "#undo-action"))
    end

    test "renders Undo disabled when the outcome is undoable but the stack is empty" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleChangeComponents.grid_bar
          selected_count={0}
          outcome={%{tone: :info, text: "Moved 1 trip 1 min later.", undo?: true}}
          undo_stack={[]}
        />
        """)

      document = doc(html)

      assert bar_attribute(document, "data-tone") == ["info"]
      assert bar_class(document) =~ "bg-soft"
      assert text(document, "#undo-action") == "Undo"
      refute Enum.empty?(LazyHTML.query(document, "#undo-action[disabled]"))
    end

    test "renders the selection verbs on the design system's selection ground" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleChangeComponents.grid_bar selected_count={2} outcome={nil} undo_stack={[]} />
        """)

      document = doc(html)

      assert bar_attribute(document, "data-tone") == ["sel"]
      assert bar_class(document) =~ "bg-selection"
      assert bar_class(document) =~ "max-w-[980px]"
      assert text(document, "#selection-count") == "2 trips selected"
      assert text(document, "#bulk-delete") == "Delete 2 trips"
      assert text(document, "#clear-selection") == "Clear selection"

      assert LazyHTML.query(document, "#grid-bar .btn-primary")
             |> LazyHTML.attribute("id") == ["bulk-shift"]
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

  defp renders(view, selector), do: view |> element(selector) |> render()

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Every rendered primary button, by id, wherever it sits on the page: the
  # hand-off means the loaded view has exactly one.
  defp primaries(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".btn-primary")
    |> LazyHTML.attribute("id")
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp bar_attribute(document, name) do
    document |> LazyHTML.query("#grid-bar") |> LazyHTML.attribute(name)
  end

  defp bar_class(document) do
    document |> LazyHTML.query("#grid-bar") |> LazyHTML.attribute("class") |> Enum.join(" ")
  end
end
