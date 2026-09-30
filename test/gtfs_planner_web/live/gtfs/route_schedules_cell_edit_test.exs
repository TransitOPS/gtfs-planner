defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesCellEditTest do
  # EV-24: the grid's in-cell events — `cell_preview`, `cell_commit` and
  # `cell_clear` — through the production composition (spec 18, step 25;
  # CL-12, CL-13; FH-30, FH-31, FH-32).
  #
  # Every case mounts through the authenticated router with no injected assigns,
  # so LiveView event -> editor role re-read -> `Gtfs.apply_trip_change/4` ->
  # `Gtfs.Schedules` transaction -> audit -> reload through the read adapter is
  # exercised end to end. Persisted stop times are asserted with independent
  # `Repo` queries, never from the rendered HTML alone. Every expected clock is
  # literal and hand-derived from R1, R2 and section 4.5; nothing here computes
  # an expectation with the code under test.
  #
  # The prepared focused command is
  # `mix test test/gtfs_planner_web/live/gtfs/route_schedules_cell_edit_test.exs`
  # (EV-24, 120 s deadline); the card defers it to branch review.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  @route_id "EDT_CELL"
  @trip_id "CELL_T1"
  @library "CELL_LIB"

  # Cedar Library is the second occurrence, so it is a timepoint and visible in
  # the default Timepoints view; a trip starting at 07:15 leaves it at 07:25 with
  # later stops at 07:32 and 07:52. A `:later` commit of 07:28 must therefore
  # persist 07:28, 07:35 and 07:55.
  @stops [
    {"CELL_START", 0, 0, 1},
    {@library, 600, 600, 1},
    {"CELL_OAK", 1_020, 1_020, 0},
    {"CELL_END", 2_220, 2_220, 0}
  ]

  setup context do
    scope = editing_scope!(@route_id, %{stops: @stops})
    create_named_stops(scope)

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  describe "a committed stop time" do
    test "persists the later stops through the facade", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      render_hook(grid(view), "cell_commit", cell(trip, 2, "07:28", "later"))
      assert_reply(view, %{ok: true})

      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", nil, nil},
               {"07:28:00", "07:28:00", nil, nil},
               {"07:35:00", "07:35:00", nil, nil},
               {"07:55:00", "07:55:00", nil, nil}
             ]

      assigns = assigns(view)
      assert assigns.outcome.text =~ "Cedar Library on the 07:15 trip is now 07:28"
      assert assigns.outcome.text =~ "2 later stops moved +3 min"
      assert assigns.outcome.text =~ "The trip now has custom times."
      assert assigns.outcome.undo?
      assert [%{payload: %{trips: [%{id: trip_id}], created: []}}] = assigns.undo_stack
      assert trip_id == trip.id
      assert assigns.just_changed == MapSet.new([trip.id])
      assert assigns.cell_error == nil
      assert assigns.grid_revision == 1

      assert has_element?(view, "tr#trip-#{@trip_id}.is-changed")
      refute has_element?(view, "#trip-#{@trip_id}-error")
    end

    test "moves the whole trip for an anchor commit and ignores forged parameters", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      forged =
        Map.merge(cell(trip, 2, "07:28", "anchor"), %{
          "value" => 99_999,
          "updated_at" => "2000-01-01T00:00:00Z",
          "payload" => %{"trips" => []},
          "fingerprint" => "forged"
        })

      render_hook(grid(view), "cell_commit", forged)
      assert_reply(view, %{ok: true})

      assert stop_time_clocks(trip) == [
               {"07:18:00", "07:18:00", nil, nil},
               {"07:28:00", "07:28:00", nil, nil},
               {"07:35:00", "07:35:00", nil, nil},
               {"07:55:00", "07:55:00", nil, nil}
             ]

      assigns = assigns(view)
      assert assigns.outcome.text =~ "The 07:15 trip now leaves at 07:18."
      assert assigns.outcome.text =~ "Every stop moved +3 min"
    end

    test "refuses an out-of-order commit and leaves the clocks unchanged", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)

      render_hook(grid(view), "cell_commit", cell(trip, 2, "0705", "later"))

      assert_reply(view, %{ok: false, message: message})
      assert message == ScheduleComponents.error_message({:out_of_order, 2})
      assert has_element?(view, "#trip-#{@trip_id}-error", message)
      assert has_element?(view, "#cell-#{@trip_id}-2.is-error")
      assert assigns(view).cell_error.position == 2
      assert stop_time_clocks(trip) == before
    end

    test "refuses a frequency trip's cell", %{conn: conn, scope: scope} do
      trip = frequency_trip!(scope, [{21_600, 25_200, 900}], %{trip_id: "CELL_FREQ"})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)

      render_hook(grid(view), "cell_commit", cell(trip, 2, "06:10", "later"))

      assert_reply(view, %{ok: false, message: message})
      assert message == ScheduleComponents.error_message(:frequency_trip)
      assert has_element?(view, "#trip-CELL_FREQ-error", message)
      assert stop_time_clocks(trip) == before
    end

    test "refuses a trip changed after the page loaded", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      trip
      |> then(&Repo.get!(Trip, &1.id))
      |> Ecto.Changeset.change(%{trip_headsign: "Elsewhere"})
      |> Repo.update!()

      before = stop_time_clocks(trip)

      render_hook(grid(view), "cell_commit", cell(trip, 2, "07:28", "later"))

      assert_reply(view, %{ok: false, message: message})
      assert message == ScheduleComponents.error_message(:stale)
      assert has_element?(view, "#trip-#{@trip_id}-error", message)
      assert stop_time_clocks(trip) == before
    end
  end

  describe "a preview" do
    test "reads an ambiguous time onto the next half day and writes nothing", %{
      conn: conn,
      scope: scope
    } do
      trip = linked_trip!(scope, "18:50:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)

      render_hook(grid(view), "cell_preview", %{
        "trip" => trip.id,
        "position" => 2,
        "text" => "705"
      })

      assert_reply(view, %{
        ok: true,
        reading: "19:05",
        note: "12 hours later",
        effect: "later stops move +5 min"
      })

      assert stop_time_clocks(trip) == before
    end

    test "refuses an unreadable entry without writing", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)

      render_hook(grid(view), "cell_preview", %{
        "trip" => trip.id,
        "position" => 2,
        "text" => "7:75"
      })

      message = ScheduleComponents.error_message(:invalid_time)
      assert_reply(view, %{ok: false, message: ^message})
      assert stop_time_clocks(trip) == before
    end
  end

  describe "clearing a stop" do
    test "clears an intermediate stop's time", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      set_timepoint!(trip, 3, 0)
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"stops" => "all"}))

      render_hook(grid(view), "cell_clear", %{"trip" => trip.id, "position" => 3})

      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", nil, nil},
               {"07:25:00", "07:25:00", nil, nil},
               {nil, nil, 0, nil},
               {"07:52:00", "07:52:00", nil, nil}
             ]

      assigns = assigns(view)
      assert assigns.outcome.text =~ "Cleared Oak Avenue on the 07:15 trip."
      assert assigns.just_changed == MapSet.new([trip.id])
      assert assigns.cell_error == nil
    end

    test "refuses to clear a timepoint stop", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)

      render_hook(grid(view), "cell_clear", %{"trip" => trip.id, "position" => 2})

      message = ScheduleComponents.error_message(:clear_not_allowed)
      assert has_element?(view, "#trip-#{@trip_id}-error", message)
      assert assigns(view).cell_error.position == 2
      assert stop_time_clocks(trip) == before
    end
  end

  describe "an estimated cell" do
    # Oak Avenue has no stored time, so Schedules shows the export estimate in
    # italics; the stored value is still blank.
    @blank_oak [
      {"CELL_START", "07:15:00", "07:15:00"},
      {@library, "07:25:00", "07:25:00"},
      {"CELL_OAK", nil, nil},
      {"CELL_END", "07:52:00", "07:52:00"}
    ]

    test "previews and saves a typed time as filling the blank", %{conn: conn, scope: scope} do
      trip = custom_trip!(scope, @blank_oak, %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"stops" => "all"}))

      assert has_element?(view, "#cell-#{@trip_id}-3[data-estimated]")

      render_hook(grid(view), "cell_preview", %{
        "trip" => trip.id,
        "position" => 3,
        "text" => "7:40"
      })

      assert_reply(view, %{ok: true, reading: "07:40", note: nil, effect: nil})

      render_hook(grid(view), "cell_commit", cell(trip, 3, "7:40", "later"))
      assert_reply(view, %{ok: true})

      assert stop_time_clocks(trip) == [
               {"07:15:00", "07:15:00", nil, nil},
               {"07:25:00", "07:25:00", nil, nil},
               {"07:40:00", "07:40:00", nil, nil},
               {"07:52:00", "07:52:00", nil, nil}
             ]

      assert assigns(view).outcome.text == "Oak Avenue on the 07:15 trip is now 07:40."
    end

    test "Delete writes nothing and adds no undo entry", %{conn: conn, scope: scope} do
      trip = custom_trip!(scope, @blank_oak, %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope, %{"stops" => "all"}))
      before = stop_time_clocks(trip)
      updated_at = trip_row(trip).updated_at

      render_hook(grid(view), "cell_clear", %{"trip" => trip.id, "position" => 3})
      assert_reply(view, %{})

      assert stop_time_clocks(trip) == before
      assert trip_row(trip).updated_at == updated_at
      assert assigns(view).undo_stack == []
      assert assigns(view).outcome == nil
    end
  end

  describe "a trip whose stops differ from the pattern" do
    test "renders a read-only Departs cell and a clear there says the cell is unavailable", %{
      conn: conn,
      scope: scope
    } do
      trip =
        custom_trip!(
          scope,
          [{"CELL_START", "07:15:00", "07:15:00"}, {"CELL_END", "07:52:00", "07:52:00"}],
          %{trip_id: @trip_id}
        )

      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)

      assert has_element?(view, "#trip-#{@trip_id}-stops-differ")
      assert has_element?(view, "#cell-#{@trip_id}-1[data-readonly]")

      render_hook(grid(view), "cell_clear", %{"trip" => trip.id, "position" => 1})
      assert_reply(view, %{})

      assert assigns(view).outcome == %{
               tone: :warning,
               text: ScheduleComponents.error_message(:not_found),
               undo?: false
             }

      assert stop_time_clocks(trip) == before
    end
  end

  describe "the editor authority" do
    test "a revoked editor role writes nothing", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)

      membership = Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})
      message = ScheduleComponents.error_message(:unauthorized)

      render_hook(grid(view), "cell_commit", cell(trip, 2, "07:28", "later"))
      assert_reply(view, %{ok: false, message: ^message})

      render_hook(grid(view), "cell_clear", %{"trip" => trip.id, "position" => 3})

      render_hook(grid(view), "cell_preview", %{
        "trip" => trip.id,
        "position" => 2,
        "text" => "705"
      })

      assert_reply(view, %{ok: false, message: ^message})
      assert stop_time_clocks(trip) == before
    end

    test "a forged trip or position writes nothing", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))
      before = stop_time_clocks(trip)
      forged = Ecto.UUID.generate()
      message = ScheduleComponents.error_message(:not_found)

      render_hook(grid(view), "cell_commit", %{
        "trip" => forged,
        "position" => 2,
        "text" => "07:28",
        "mode" => "later"
      })

      assert_reply(view, %{ok: false, message: ^message})

      render_hook(grid(view), "cell_commit", cell(trip, 99, "07:28", "later"))
      assert_reply(view, %{ok: false, message: ^message})

      render_hook(grid(view), "cell_clear", %{"trip" => forged, "position" => 2})

      render_hook(grid(view), "cell_preview", %{
        "trip" => forged,
        "position" => 2,
        "text" => "705"
      })

      assert_reply(view, %{ok: false, message: ^message})
      refute has_element?(view, "#trip-#{@trip_id}-error")
      assert stop_time_clocks(trip) == before
    end
  end

  describe "the ordinary entry" do
    test "mounts through the router with no injected grid state", %{conn: conn, scope: scope} do
      trip = linked_trip!(scope, "07:15:00", %{trip_id: @trip_id})
      {:ok, view, _html} = live(conn, schedules_path(scope))

      assert has_element?(view, "#schedules-grid[data-grid-revision='0']")
      assert has_element?(view, "#cell-#{@trip_id}-2[data-trip='#{trip.id}'][data-pos='2']")
      refute has_element?(view, "#trip-#{@trip_id}-error")
      refute has_element?(view, "tr#trip-#{@trip_id}.is-changed")

      assigns = assigns(view)
      assert assigns.cell_error == nil
      assert assigns.undo_stack == []
      assert assigns.outcome == nil
      assert assigns.just_changed == MapSet.new()
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

  defp cell(trip, position, text, mode) do
    %{"trip" => trip.id, "position" => position, "text" => text, "mode" => mode}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp create_named_stops(scope) do
    for {stop_id, stop_name} <- [
          {"CELL_START", "Cedar Street"},
          {@library, "Cedar Library"},
          {"CELL_OAK", "Oak Avenue"},
          {"CELL_END", "Valley College"}
        ] do
      stop_fixture(scope.organization.id, scope.version.id, %{
        stop_id: stop_id,
        stop_name: stop_name
      })
    end
  end

  # R1 clears only a stop whose stored timepoint is 0; the materializing fixture
  # leaves the column NULL, so the case stores the flag the rule reads.
  defp set_timepoint!(trip, sequence, timepoint) do
    Repo.update!(Ecto.Changeset.change(stop_time_row(trip, sequence), %{timepoint: timepoint}))
  end

  defp stop_time_row(trip, sequence) do
    Repo.one!(
      from(st in StopTime,
        where: st.trip_id == ^trip.trip_id and st.stop_sequence == ^sequence
      )
    )
  end
end
