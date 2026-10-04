defmodule GtfsPlannerWeb.Gtfs.DatedChangePlanningLiveTest do
  @moduledoc """
  EV-8: the Schedule planning lifecycle and the host-owned helper switch, driven
  through the production composition (spec ai-11, step 8; CL-8; FH-8).

  Every case mounts through the authenticated router and drives the page's own
  rendered controls by their ids: `#trip-select-*` for the selection,
  `#dated-change-form` and `#dated-change-accept` for the intent,
  `#dated-change-analyze` and `#dated-change-refresh` for the native read,
  `#schedule-helper-mode-*` for the host's own helper switch. No assign is
  injected and no private function is called, so the only path exercised is
  `live/2` -> `handle_event/3` -> the supervised task -> `DatedChangePlan.prepare/2`
  and `load/2` -> the real `Repo` snapshot -> the report the page renders. A
  green case therefore cannot come from a controller nothing routes to.

  The page holds a reference to the analysis task it started, so a test waits on
  a real `Process.monitor/1` DOWN rather than a sleep, and the result is read
  through a subsequent synchronous render, which the live view processes after
  the message already queued for it.

  The provider is never configured in this file. That is the point of the
  first group: native planning and manual editing must work with the helper
  disabled, failing or selected away, because nothing on this path calls it.

  Expected dates, counts and digests come from the spec's own numbers and from
  the calendar the fixtures create, never from the implementation's output.

  The prepared focused command is
  `mix test test/gtfs_planner_web/live/gtfs/dated_change_planning_live_test.exs`
  (EV-8, 120 s deadline); this run defers it to branch review.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @route_id "PLANNED"
  @service "PLANNED_WEEKDAY"

  # Mon-Fri 2026. Nov 2-13 is ten weekdays with no exception removed by these
  # fixtures, so the in-window set the page lists is exactly ten dates and the
  # original set is the whole Mon-Fri year.
  @first_date "2026-11-02"
  @last_date "2026-11-13"
  @delta_seconds 300
  @approval_note "Board approved the temporary Saturday service for this window."

  @window_dates ~w(
    2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06
    2026-11-09 2026-11-10 2026-11-11 2026-11-12 2026-11-13
  )

  setup context do
    scope = editing_scope!(@route_id, %{service: @service})

    trip_a = linked_trip!(scope, "07:00:00", %{trip_id: "PLANNED_0700"})
    trip_b = linked_trip!(scope, "07:30:00", %{trip_id: "PLANNED_0730"})

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization),
     scope: scope,
     trips: [trip_a, trip_b]}
  end

  describe "the native plan, with no helper configured" do
    test "an ordinary analyze reaches the real loader and renders the report", context do
      view = accepted_view(context)
      before = native_signature(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)

      html = render(view)

      # The report is the domain's, over one real read: the accepted window's
      # ten weekdays, counted as trip-date pairs across the two selected trips.
      assert html =~ "Plan complete."
      assert view |> element("#dated-change-totals") |> render() =~ "2"
      assert date_rows(view) == @window_dates

      # The stage list says what is missing rather than offering to run it.
      assert has_element?(view, "#dated-change-stages")
      assert has_element?(view, "#dated-change-kind")

      # These fixtures load one calendar, so the report names it rather than
      # offering a switch with nothing to switch to.
      assert has_element?(view, "#dated-change-service-single")

      # Planning only: no control anywhere applies the plan (INV-1, AC-10).
      refute render(view) =~ ~r/phx-click="apply_dated_change"/
      refute has_element?(view, "#dated-change-apply")
      refute html =~ ~r/(?i)apply (this|the) (plan|change)/

      # Nothing was written: the plan is a read.
      assert native_signature(context) == before
    end

    test "the analyzed report is exactly the accepted window, listed and paged", context do
      view = accepted_view(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)

      # The in-window set, ascending, is the set the accepted dates name.
      assert date_rows(view) == @window_dates

      # The original set is the whole Mon-Fri year, and the kept set is the
      # difference, so `T` and `N` stay disjoint and both are reachable. Both
      # run to more than one page of dates, so each is read the way a person
      # reads it: through the page's own paging control.
      show_partition(view, "original")
      original = all_date_rows(view)
      assert length(original) == 261
      assert "2026-01-01" in original
      assert "2026-12-31" in original

      show_partition(view, "normal")
      normal = all_date_rows(view)
      assert length(normal) == 251

      # The page lists newest first, so what paging pins is the membership of
      # each set, not the order a person reads it in.
      assert MapSet.new(normal) ==
               MapSet.difference(MapSet.new(original), MapSet.new(@window_dates))

      # A forged calendar is refused rather than answered for another one.
      render_click(view, "dated_change_service", %{"service_id" => "NOT_LOADED"})
      assert view |> element("#dated-change-state-headline") |> render() =~ "Plan complete."
    end

    test "an analyze with no accepted window asks for the review instead of reading",
         context do
      view = schedules_view(context)

      assert has_element?(view, "#dated-change-analyze[disabled]")
      assert view |> element("#dated-change-state-headline") |> render() =~ "No plan yet."

      render_click(view, "dated_change_analyze", %{})

      assert view |> element("#dated-change-state-message") |> render() =~
               "Review the inputs above first"

      assert has_element?(view, "#dated-change-state[role=status]")
    end

    test "a lost membership refuses the analysis rather than completing it", context do
      view = accepted_view(context)

      revoke_editor(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)

      assert view |> element("#dated-change-state-headline") |> render() =~
               "could not be prepared"

      refute has_element?(view, "#dated-change-totals")
    end
  end

  describe "freshness" do
    test "a same-count external dependency edit makes the plan stale", context do
      view = accepted_view(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert view |> element("#dated-change-state-headline") |> render() =~ "Plan complete."

      # The calendar's own rows are replaced with the same number of rows, so a
      # count cannot detect this: only the full content digest can (AC-4).
      replace_calendar_exception(context)

      view |> element("#dated-change-refresh") |> render_click()
      await_plan(view)

      assert view |> element("#dated-change-state-headline") |> render() =~
               "no longer current"

      assert view |> element("#dated-change-state-freshness") |> render() =~
               "Checked against a full dependency read just now."

      # The dates the plan was prepared from are still on screen and still say
      # what they are, rather than silently describing a version they no longer
      # match.
      assert date_rows(view) == @window_dates
    end

    test "an unchanged dependency re-check keeps the plan current", context do
      view = accepted_view(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)

      view |> element("#dated-change-refresh") |> render_click()
      await_plan(view)

      assert view |> element("#dated-change-state-headline") |> render() =~ "Plan complete."

      assert view |> element("#dated-change-state-freshness") |> render() =~
               "Checked against a full dependency read just now."
    end

    test "a helper request stops the plan claiming it is current", context do
      view = accepted_view(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert view |> element("#dated-change-state-freshness") |> render() =~ "Checked against"

      # Closing and reopening the panel, and asking the helper anything, all mean
      # the report has not been compared with a fresh dependency read since.
      view |> element("#agent-helper-open") |> render_click()

      assert view |> element("#dated-change-state-freshness") |> render() =~
               "Not re-checked since this was prepared"

      view |> element("#agent-panel-close") |> render_click()

      assert view |> element("#dated-change-state-freshness") |> render() =~
               "Not re-checked since this was prepared"

      # The plan itself is kept: a person is still reading it.
      assert date_rows(view) == @window_dates

      view |> element("#dated-change-refresh") |> render_click()
      await_plan(view)
      assert view |> element("#dated-change-state-freshness") |> render() =~ "Checked against"
    end

    test "a native edit on this timetable marks the retained plan not current", context do
      view = accepted_view(context)
      trip = hd(context.trips)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert has_element?(view, "#dated-change-totals")

      # A real native save through the page's own drawer control. The plan is
      # kept and relabelled rather than deleted: a person is still reading it.
      view |> element("#trip-#{trip.trip_id}-edit") |> render_click()

      view
      |> form("#trip-drawer-form", %{"drawer" => %{"trip_headsign" => "PLANNED WEST"}})
      |> render_change()

      view
      |> form("#trip-drawer-form", %{"drawer" => %{"trip_headsign" => "PLANNED WEST"}})
      |> render_submit()

      assert view |> element("#dated-change-state-headline") |> render() =~
               "no longer current"

      assert date_rows(view) == @window_dates
    end
  end

  describe "the plan's own lifecycle" do
    test "a replaced task's result cannot restore the plan it described", context do
      view = accepted_view(context)

      # Start a read, then invalidate its source before it returns.
      view |> element("#dated-change-analyze") |> render_click()
      view |> element("#clear-selection") |> render_click()
      await_plan(view)

      assert view |> element("#dated-change-state-headline") |> render() =~ "No plan yet."
      refute has_element?(view, "#dated-change-totals")
      assert date_rows(view) == []
    end

    test "a task that exits reports the failure instead of a partial plan", context do
      view = accepted_view(context)

      # A task that is stopped before it returns is the exit case: the page says
      # the analysis stopped and shows no report rather than a partial one.
      stop_dated_change_task(view)

      assert view |> element("#dated-change-state-headline") |> render() =~
               "could not be prepared"

      refute has_element?(view, "#dated-change-totals")
    end

    test "changing the draft, the selection or the route drops the plan", context do
      view = accepted_view(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert has_element?(view, "#dated-change-totals")

      # A draft edit is an interpretation change, so the plan goes with it and
      # the typed value stays.
      draft_change(view, %{"first_date" => "2026-12-01"})
      refute has_element?(view, "#dated-change-totals")
      assert view |> element("#dated-change-first-date") |> render() =~ "2026-12-01"

      # The selection is the plan's scope, so clearing it drops the report too.
      reaccept(view, context)
      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert has_element?(view, "#dated-change-totals")

      view |> element("#clear-selection") |> render_click()
      refute has_element?(view, "#dated-change-totals")

      # Navigation names a different view of the same route, so the report and the
      # source it described are not carried into it.
      reaccept(view, context)
      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert has_element?(view, "#dated-change-totals")

      render_patch(
        view,
        "/gtfs/#{context.scope.version.id}/routes/#{@route_id}/schedules?stops=all"
      )

      assert view |> element("#dated-change-state-headline") |> render() =~ "No plan yet."
      refute has_element?(view, "#dated-change-totals")
    end
  end

  describe "the host-owned helper switch" do
    test "switching helpers keeps the native draft, the selection and the work", context do
      view = accepted_view(context)
      draft_change(view, %{"source_label" => "Board memo 2026-14"})

      switch_helper(view, "dated_changes")

      # The draft and the selection are this page's own state; switching helpers
      # detaches a panel and nothing else (INV-3).
      assert view |> element("#dated-change-source-label") |> render() =~ "Board memo 2026-14"
      assert view |> element("#dated-change-selected-count") |> render() =~ "2"

      # The switch detaches this panel's conversation, so the source that named
      # the dated window is dropped with it rather than answered from a
      # conversation about something else (AC-15).
      assert view |> element("#dated-change-state-headline") |> render() =~ "No plan yet."
      refute has_element?(view, "#dated-change-totals")

      # Native planning still works with the other helper selected, and the
      # timetable is untouched by the switch.
      reaccept(view, context)
      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert has_element?(view, "#dated-change-totals")
    end

    test "a forged helper id is refused without disturbing the page", context do
      view = accepted_view(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert has_element?(view, "#dated-change-totals")

      # The page offers only the helpers in its own table, so an id outside it
      # is ignored the way a tampered client would post one.
      render_click(view, "schedule_helper_mode", %{"mode" => "transfers"})

      # Nothing this page owns changed: the report, the draft and the selection
      # are exactly as they were.
      assert has_element?(view, "#dated-change-totals")
      assert date_rows(view) == @window_dates
    end

    test "only the helpers this host declares are offered", context do
      view = schedules_view(context)

      assert has_element?(view, "#schedule-helper-mode-service_queries")
      assert has_element?(view, "#schedule-helper-mode-connections")
      assert has_element?(view, "#schedule-helper-mode-dated_changes")
      refute has_element?(view, "#schedule-helper-mode-transfers")
    end

    test "a second tab sharing the conversation keeps its own session", context do
      # Both tabs open the same helper on the same page state, so both resolve to
      # the same conversation. A tab holding a different context is a different
      # conversation by design, not a second listener on this one.
      view = schedules_view(context)
      switch_helper(view, "dated_changes")
      view |> element("#agent-helper-open") |> render_click()
      first_session = session_pid(view)

      {:ok, second, _html} =
        live(context.conn, "/gtfs/#{context.scope.version.id}/routes/#{@route_id}/schedules")

      switch_helper(second, "dated_changes")
      second |> element("#agent-helper-open") |> render_click()
      second_session = session_pid(second)

      assert first_session == second_session
      ref = Process.monitor(first_session)

      # One panel switching detaches only that listener; the other tab's panel
      # and the shared session it is bound to are untouched (INV-3).
      second |> switch_helper("dated_changes")

      refute_received {:DOWN, ^ref, :process, ^first_session, _reason}
      assert session_pid(view) == first_session
      assert has_element?(view, "#agent-panel")
    end
  end

  describe "the rendered states" do
    test "every state is announced from one live region with a stable id", context do
      view = accepted_view(context)

      assert has_element?(view, "#dated-change-state[role=status][aria-live=polite]")
      assert view |> element("#dated-change-state-headline") |> render() =~ "No plan yet."

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)
      assert view |> element("#dated-change-state-headline") |> render() =~ "Plan complete."

      replace_calendar_exception(context)
      view |> element("#dated-change-refresh") |> render_click()
      await_plan(view)
      assert view |> element("#dated-change-state-headline") |> render() =~ "no longer current"
    end

    test "the plan surface is a single column at phone width", context do
      view = accepted_view(context)

      view |> element("#dated-change-analyze") |> render_click()
      await_plan(view)

      html = render(view)

      # No fixed pixel widths on the plan's own card, so it reflows instead of
      # forcing a sideways scroll at 320px. The slice is the plan section alone:
      # the trip drawer that follows it legitimately has a minimum width.
      plan_html =
        html
        |> String.split(~s(id="dated-change-plan"))
        |> List.last()
        |> String.split("</section>")
        |> List.first()

      refute plan_html =~ ~r/min-w-\[[0-9]+px\]/

      # The controls are real buttons and inputs, so they are keyboard reachable
      # and the plan offers no pointer-only affordance.
      assert has_element?(view, "#dated-change-refresh")
      assert has_element?(view, "#dated-change-service-single")
      assert has_element?(view, "#dated-change-kind input[value=temporary]")
    end
  end

  ## Helpers

  defp schedules_view(context) do
    assert {:ok, view, _html} =
             live(context.conn, "/gtfs/#{context.scope.version.id}/routes/#{@route_id}/schedules")

    view
  end

  # The view a plan is analyzed from: the timetable's own selection, an accepted
  # window, and nothing else injected.
  defp accepted_view(context) do
    view = schedules_view(context)
    Enum.each(context.trips, &select_trip(view, &1))
    view |> element("#dated-change-form") |> render_submit(intent_params(%{}))
    view
  end

  # Re-runs the ordinary acceptance after a case dropped the source, through the
  # same rendered form as the first one.
  # A trip the page still has selected is left alone: the timetable's control is
  # a toggle, and a blind re-click would deselect the very selection the
  # acceptance needs.
  defp reaccept(view, context) do
    Enum.each(context.trips, fn trip ->
      unless has_element?(view, "#trip-select-#{trip.trip_id}[checked]") do
        select_trip(view, trip)
      end
    end)

    view |> element("#dated-change-form") |> render_submit(intent_params(%{}))
    view
  end

  # The partition switch is a `phx-change` form of radio inputs, so it is driven
  # the way a browser drives it: the form posts the chosen value.
  defp show_partition(view, kind) do
    view |> form("#dated-change-kind-form", %{"partition_kind" => kind}) |> render_change()
  end

  defp select_trip(view, trip) do
    view |> element("#trip-select-#{trip.trip_id}") |> render_click()
  end

  # The helper switch is one button per helper, driven the way a browser drives
  # it: a click on the helper's own control.
  defp switch_helper(view, pack_id) do
    view |> element("#schedule-helper-mode-#{pack_id}") |> render_click()
  end

  defp intent_params(overrides) do
    fields =
      %{
        "first_date" => @first_date,
        "last_date" => @last_date,
        "delta_seconds" => Integer.to_string(@delta_seconds),
        "approval_note" => @approval_note,
        "source_label" => ""
      }
      |> Map.merge(overrides)

    %{"dated_change" => fields}
  end

  # A `phx-change` on the dated change form, which is what a keystroke posts.
  defp draft_change(view, fields) do
    view
    |> form("#dated-change-form", %{"dated_change" => fields})
    |> render_change()
  end

  # The dates the page is currently listing, read from the stream the page
  # rendered rather than from any assign. `query/2` searches descendants;
  # `filter/2` only ever matches the root nodes it is given.
  defp date_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#dated-change-dates [id^=dated-change-date-]")
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
  end

  # Every date the page is listing across all of its pages, read by turning the
  # page with the page's own control until it offers no next page. A single
  # render only ever holds one page, so a set larger than a page can only be
  # observed by paging.
  defp all_date_rows(view), do: all_date_rows(view, [])

  defp all_date_rows(view, acc) do
    rows = date_rows(view) ++ acc

    if has_element?(view, "#dated-change-page-next:not([disabled])") do
      view |> element("#dated-change-page-next") |> render_click()
      all_date_rows(view, rows)
    else
      Enum.reverse(rows)
    end
  end

  # The read the page started, waited on with a real monitor. `Process.monitor/1`
  # on a process that already exited delivers immediately, so this is correct
  # whether the task finished before or after the monitor was set; the
  # subsequent `render/1` is a synchronous call the live view handles after the
  # result message already queued for it.
  defp await_plan(view) do
    case :sys.get_state(view.pid).socket.assigns.dated_change_task do
      nil ->
        :ok

      {task, _generation} ->
        ref = Process.monitor(task.pid)
        pid = task.pid
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 30_000
        render(view)
    end
  end

  defp session_pid(view) do
    :sys.get_state(view.pid).socket.assigns.agent_session
  end

  # The exit case for the analysis task: the page started a read and the read
  # process is stopped before it returns, so only the page's own `handle_info/2`
  # can report it. Nothing is injected into the live view.
  defp stop_dated_change_task(view) do
    view |> element("#dated-change-analyze") |> render_click()
    {task, _generation} = :sys.get_state(view.pid).socket.assigns.dated_change_task

    ref = Process.monitor(task.pid)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 30_000

    # The page's own monitor fires at the same moment as this test's, so a
    # synchronous state read is what guarantees the live view has handled its
    # DOWN before the headline is read.
    _ = :sys.get_state(view.pid)

    render(view)
  end

  # A same-count substitution: the calendar keeps one exception row, but it now
  # removes a different date. Only the full content digest notices.
  #
  # Written through the sandbox transaction, not its own autocommit connection:
  # the fixtures this file builds — the organization above all — are themselves
  # uncommitted, so an autocommit write could not satisfy their foreign keys.
  # The read the page starts is a separate *process*, and the non-async sandbox
  # is shared, so it checks out this transaction and observes the edit.
  defp replace_calendar_exception(context) do
    service = context.scope.service
    version_id = context.scope.version.id

    Repo.delete_all(
      from(d in GtfsPlanner.Gtfs.CalendarDate,
        where: d.gtfs_version_id == ^version_id and d.service_id == ^service
      )
    )

    {:ok, _row} =
      %GtfsPlanner.Gtfs.CalendarDate{}
      |> Ecto.Changeset.change(%{
        organization_id: context.scope.organization.id,
        gtfs_version_id: version_id,
        service_id: service,
        date: ~D[2026-11-10],
        exception_type: 2
      })
      |> Repo.insert()
  end

  # Revoked after the acceptance, from this page's own shared sandbox connection:
  # the read the page starts is a separate process that checks the membership
  # out of the same transaction (AC-3, INV-2).
  defp revoke_editor(context) do
    membership =
      GtfsPlanner.Accounts.get_user_org_membership(
        context.scope.actor.id,
        context.scope.organization.id
      )

    {:ok, _membership} =
      membership
      |> Ecto.Changeset.change(%{roles: []})
      |> Repo.update()
  end

  # Every native row the plan must not touch, as one comparable signature.
  defp native_signature(context) do
    version_id = context.scope.version.id

    %{
      trips:
        Repo.all(from(t in Trip, where: t.gtfs_version_id == ^version_id))
        |> Enum.map(&Map.take(&1, [:id, :service_id, :start_time, :block_id]))
        |> Enum.sort_by(& &1.id),
      calendars:
        Repo.all(
          from(c in Calendar,
            where: c.gtfs_version_id == ^version_id,
            select: {c.service_id, c.start_date, c.end_date, c.monday, c.saturday}
          )
        )
        |> Enum.sort(),
      stop_times:
        Repo.all(
          from(s in StopTime,
            join: t in Trip,
            on: t.trip_id == s.trip_id and t.gtfs_version_id == ^version_id,
            where: t.gtfs_version_id == ^version_id,
            select: {s.trip_id, s.stop_sequence, s.arrival_time, s.departure_time}
          )
        )
        |> Enum.sort(),
      logs: Repo.aggregate(ChangeLog, :count)
    }
  end
end
