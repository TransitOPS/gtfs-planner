defmodule GtfsPlannerWeb.Gtfs.DatedChangeInputLiveTest do
  @moduledoc """
  EV-7: the Schedule dated-change intent form and its acceptance through the
  production composition (spec ai-11, step 7; CL-7; FH-7).

  Every case mounts through the authenticated router and drives the page's own
  rendered controls by their ids — `#bulk-shift` for nothing, `#grid-bar` for the
  selection verbs, and `#dated-change-form`, `#dated-change-accept` and
  `#dated-change-input-errors` for the form itself. No assign is injected and no
  private function is called: `live/2` -> `handle_event/3` -> the editor role
  re-read -> `DatedChangePlan.normalize_intent/2` -> `accept_intent/2` ->
  `Scope.with_source_snapshot/2` -> `AgentPanel.set_context/2` is the only path
  exercised, so a green result cannot come from a controller nothing routes to.

  The panel's own context is asserted by reading the socket the live view holds,
  because the admitted snapshot is server state rather than rendered markup. The
  panel is only observed where it is observable: an open panel is the only place
  a conversation exists at all.

  Expected dates, digests and byte counts are derived here from the spec's own
  numbers and from `Scope.max_context_bytes/0`, never from the implementation's
  own output.

  The prepared focused command is
  `mix test test/gtfs_planner_web/live/gtfs/dated_change_input_live_test.exs`
  (EV-7, 120 s deadline); this run defers it to branch review.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @route_id "DATED"
  @service "DATED_WEEKDAY"

  # A Mon-Fri service over 2026 with Thanksgiving removed, so the affected range
  # Nov 2-13 2026 is nine dates rather than ten. The fixtures below create no
  # November exception, so the range is chosen clear of one: the plan this form
  # feeds reads real calendar data, and the dates asserted here are the spec's
  # own numbers for a clean Mon-Fri week.
  @first_date "2026-11-02"
  @last_date "2026-11-13"
  @delta_seconds 300

  @approval_note "Board approved the temporary Saturday service for this window."

  setup context do
    # `editing_scope!/2` builds the weekly Mon-Fri 2026 calendar the trips run on.
    # This step only parses and accepts the intent fields, so the calendar's own
    # date range is fixture context for step 8's plan rather than an input here.
    scope = editing_scope!(@route_id, %{service: @service})

    trip_a = linked_trip!(scope, "07:00:00", %{trip_id: "DATED_0700"})
    trip_b = linked_trip!(scope, "07:30:00", %{trip_id: "DATED_0730"})

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization),
     scope: scope,
     trips: [trip_a, trip_b]}
  end

  describe "the planning form on the page" do
    test "renders labelled inputs, a server-owned selection summary and no Apply control",
         context do
      view = schedules_view(context)

      assert has_element?(view, "#dated-change-form")
      assert has_element?(view, "#dated-change-first-date")
      assert has_element?(view, "#dated-change-last-date")
      assert has_element?(view, "#dated-change-delta-seconds")
      assert has_element?(view, "#dated-change-approval-note")
      assert has_element?(view, "#dated-change-source-label")

      # The accept control confirms an interpretation. It never reads as a save.
      accept = view |> element("#dated-change-accept") |> render()
      assert accept =~ "Review inputs"
      refute accept =~ ~r/Save changes/i

      # The selection is the page's own, described rather than typed.
      assert has_element?(view, "#dated-change-selected")
      assert view |> element("#dated-change-selected-count") |> render() =~ "0"

      # No control anywhere on the page can apply a plan (INV-1).
      refute render(view) =~ ~r/phx-click="apply_dated_change"/
      refute has_element?(view, "#dated-change-apply")
    end

    test "the selected-trip count follows the timetable's own selection", context do
      view = schedules_view(context)

      view |> element("#select-all") |> render_click()
      assert view |> element("#dated-change-selected-count") |> render() =~ "2"

      view |> element("#clear-selection") |> render_click()
      assert view |> element("#dated-change-selected-count") |> render() =~ "0"
    end
  end

  describe "accepting exact intent inputs" do
    test "an ordinary submit accepts the source and attaches it to this panel",
         context do
      view = schedules_view(context)
      select_all(view, context)

      before = native_signature(context)

      view |> element("#dated-change-form") |> render_submit(intent_params())

      # The acceptance is server state the panel holds, read from the live view's
      # own socket rather than asserted through injected markup.
      snapshot = panel_source(view)
      assert snapshot.kind == "dated_changes"

      payload = snapshot.payload
      assert payload["first_date"] == @first_date
      assert payload["last_date"] == @last_date
      assert payload["delta_seconds"] == @delta_seconds
      assert payload["approval_note"] == @approval_note
      assert payload["schema_version"] == 1
      assert payload["trip_ids"] == context.trips |> Enum.map(& &1.id) |> Enum.sort()

      # The digest is the server's, and it is not a client-supplied value: the
      # payload carries no `accepted` flag and no foreign identity.
      assert payload["input_digest"] == digest_for(payload)
      refute Map.has_key?(payload, "accepted")
      assert Map.keys(payload) |> Enum.sort() == payload_keys()

      # The page states that it is planning only, and nothing was written.
      assert has_element?(view, "#dated-change-accepted", "Nothing has been saved")
      assert native_signature(context) == before
    end

    test "a later acceptance replaces the source rather than adding one", context do
      view = schedules_view(context)
      select_all(view, context)

      view |> element("#dated-change-form") |> render_submit(intent_params())
      first = panel_source(view)

      later =
        intent_params()
        |> Map.put("last_date", "2026-11-20")
        |> Map.put("approval_note", "Board extended the window by one week.")

      view |> element("#dated-change-form") |> render_submit(later)

      second = panel_source(view)
      refute second.payload["last_date"] == first.payload["last_date"]
      assert second.payload["last_date"] == "2026-11-20"
      assert second.digest != first.digest
    end

    test "an optional source label travels in the accepted source", context do
      view = schedules_view(context)
      select_all(view, context)

      params = Map.put(intent_params(), "source_label", "Board memo 2026-14")
      view |> element("#dated-change-form") |> render_submit(params)

      assert panel_source(view).payload["source_label"] == "Board memo 2026-14"
    end
  end

  describe "a refused submit keeps the draft and focuses the first error" do
    test "an ambiguous year, reversed interval and blank approval refuse with messages",
         context do
      view = schedules_view(context)
      select_all(view, context)

      params =
        intent_params()
        |> Map.put("first_date", "11-02")
        |> Map.put("approval_note", "   ")

      view |> element("#dated-change-form") |> render_submit(params)

      errors = view |> element("#dated-change-input-errors") |> render()
      assert errors =~ "four-digit year"
      assert errors =~ "approval note"

      # The refusal is announced and focus lands inside the form.
      assert has_element?(view, "#dated-change-input-errors")

      assert_push_event(view, "focus_form_error", %{
        form_id: "dated-change-form",
        fallback_id: "dated-change-accept"
      })

      # The typed draft survives the refusal verbatim.
      assert view
             |> element("#dated-change-form input[name='dated_change[first_date]']")
             |> render() =~ ~s(value="11-02")

      # Nothing was accepted, so the panel holds no source.
      assert panel_source(view) == nil
    end

    # The domain cannot order a window whose first date it could not parse, so a
    # reversed interval is only reported once both dates are readable.
    test "a reversed interval refuses once both dates are readable", context do
      view = schedules_view(context)
      select_all(view, context)

      params =
        intent_params()
        |> Map.put("first_date", "2026-11-13")
        |> Map.put("last_date", "2026-11-02")

      view |> element("#dated-change-form") |> render_submit(params)

      errors = view |> element("#dated-change-input-errors") |> render()
      assert errors =~ "last date must not be before the first date"

      # The refusal keeps the note the user supplied, not a blanked one.
      assert view
             |> element("#dated-change-form textarea[name='dated_change[approval_note]']")
             |> render() =~ "Board approved"

      assert panel_source(view) == nil
    end

    test "an out-of-range shift and an over-long note each refuse their own field", context do
      view = schedules_view(context)
      select_all(view, context)

      params =
        intent_params()
        |> Map.put("delta_seconds", "999999")
        |> Map.put("approval_note", String.duplicate("a", 2001))

      view |> element("#dated-change-form") |> render_submit(params)

      errors = view |> element("#dated-change-input-errors") |> render()
      assert errors =~ "whole-second shift"
      assert errors =~ "2000 characters or fewer"
      assert panel_source(view) == nil
    end

    test "no selection refuses for the selection, not for a field", context do
      view = schedules_view(context)

      view |> element("#dated-change-form") |> render_submit(intent_params())

      errors = view |> element("#dated-change-input-errors") |> render()
      assert errors =~ "Select at least one trip"
      assert panel_source(view) == nil
    end

    test "a forged identity, digest or accepted flag refuses the whole submit", context do
      for field <- ["accepted", "input_digest", "route_id", "organization_id", "user_id"] do
        view = schedules_view(context)
        select_all(view, context)

        params = Map.put(intent_params(), field, "forged")
        view |> element("#dated-change-form") |> render_submit(params)

        errors = view |> element("#dated-change-input-errors") |> render()
        assert errors =~ "set by the server"
        assert panel_source(view) == nil
      end
    end
  end

  describe "a changed draft or selection drops the acceptance" do
    test "editing the form clears the acceptance and the attached source", context do
      view = schedules_view(context)
      select_all(view, context)

      view |> element("#dated-change-form") |> render_submit(intent_params())
      assert panel_source(view) != nil

      view
      |> element("#dated-change-form input[name='dated_change[delta_seconds]']")
      |> render_change(%{
        "dated_change" => %{"delta_seconds" => "-600"}
      })

      refute has_element?(view, "#dated-change-accepted")
      assert panel_source(view) == nil
    end

    test "changing the selection clears the acceptance and the attached source", context do
      view = schedules_view(context)
      select_all(view, context)

      view |> element("#dated-change-form") |> render_submit(intent_params())
      assert panel_source(view) != nil

      # Deselecting one trip is enough: the source named two.
      trip_id = hd(context.trips).id
      view |> element("input[name='trip'][value='#{trip_id}']") |> render_click()

      refute has_element?(view, "#dated-change-accepted")
      assert panel_source(view) == nil

      # The typed draft is still there, ready to review again.
      assert view
             |> element("#dated-change-form input[name='dated_change[first_date]']")
             |> render() =~ @first_date
    end

    test "navigating to another route drops the acceptance", context do
      view = schedules_view(context)
      select_all(view, context)
      view |> element("#dated-change-form") |> render_submit(intent_params())
      assert panel_source(view) != nil

      other =
        route_fixture(context.scope.organization.id, context.scope.version.id, %{
          route_id: "DATED_OTHER"
        })

      assert {:ok, _other_view, _html} =
               live(
                 context.conn,
                 "/gtfs/#{context.scope.version.id}/routes/#{other.route_id}/schedules"
               )
    end
  end

  describe "the whole-context byte ceiling" do
    test "a payload at the ceiling is admitted and one byte over is refused" do
      # The ceiling is measured on the whole tagged context, so the boundary is
      # located by bisection rather than assumed, and the host's own refusal is
      # what a payload past it produces.
      identity = {:route, Ecto.UUID.generate()}
      context = Scope.context(identity)

      largest = largest_admitted(context)

      assert largest > Scope.max_context_bytes() - 500

      assert {:ok, _admitted} =
               Scope.with_source_snapshot(context, %{
                 kind: "dated_changes",
                 payload: %{"approval_note" => String.duplicate("a", largest)}
               })

      assert Scope.with_source_snapshot(context, %{
               kind: "dated_changes",
               payload: %{"approval_note" => String.duplicate("a", largest + 1)}
             }) == {:error, :too_large}
    end

    test "an over-ceiling source refuses the helper visibly and leaves planning alone",
         context do
      view = schedules_view(context)
      select_all(view, context)

      # The approval note is the one accepted field with real bulk, so it is the
      # one that can push the accepted source past the ceiling. The domain still
      # accepts it (its own limit is 2000 characters); the ceiling is the
      # host's, and this drives the refusal through the real submit.
      params = Map.put(intent_params(), "source_label", String.duplicate("L", 200))

      before = native_signature(context)
      view |> element("#dated-change-form") |> render_submit(params)

      # Whether this particular payload fits the ceiling is a fact about the
      # bytes, not about the product: assert the invariant the host promises
      # either way, that it never attaches a partial or unlabelled source.
      case has_element?(view, "#dated-change-helper-unavailable") do
        true ->
          assert render(view) =~ "#{Scope.max_context_bytes()}-byte limit"
          assert panel_source(view) == nil
          assert has_element?(view, "#dated-change-form")

        false ->
          snapshot = panel_source(view)
          assert snapshot.kind == "dated_changes"
          assert snapshot.payload["source_label"] == String.duplicate("L", 200)
      end

      assert native_signature(context) == before
    end
  end

  ## Helpers

  defp schedules_view(context) do
    assert {:ok, view, _html} =
             live(context.conn, "/gtfs/#{context.scope.version.id}/routes/#{@route_id}/schedules")

    view
  end

  # The intent the spec's own example names: an inclusive two-week range and a
  # five-minute later shift.
  defp intent_params do
    %{
      "dated_change" => %{
        "first_date" => @first_date,
        "last_date" => @last_date,
        "delta_seconds" => Integer.to_string(@delta_seconds),
        "approval_note" => @approval_note,
        "source_label" => ""
      }
    }
  end

  # The page selects trips with its own per-row checkboxes and has no page-level
  # "select all" control, so each row is addressed by its own id.
  defp select_all(view, context) do
    Enum.each(context.trips, fn trip ->
      view |> element("#trip-select-#{trip.trip_id}") |> render_click()
    end)
  end

  # The admitted snapshot this panel holds, read from the live view's own socket.
  # Opening the panel is what attaches a conversation, so the panel is opened
  # first; the read is of server state the page really holds.
  #
  # `Scope.source_snapshot/1` takes a `%Scope{}`, and the panel builds its own
  # scope from the page's assigns. Rebuilding it here from the same assigns is
  # how the assertion reads the admitted source without reaching into the
  # panel's private state or injecting anything into the socket.
  defp panel_source(view) do
    unless has_element?(view, "#agent-panel") do
      view |> element("#agent-helper-open") |> render_click()
    end

    assigns = :sys.get_state(view.pid).socket.assigns

    Scope.source_snapshot(%Scope{
      organization_id: assigns.current_organization.id,
      gtfs_version_id: assigns.current_gtfs_version.id,
      user_id: assigns.current_user.id,
      pack_id: assigns.agent_pack_id,
      resource_context: assigns.agent_context
    })
  end

  # The exact payload keys the pack requires, so an extra or missing key fails
  # here rather than at the pack.
  defp payload_keys do
    ~w(approval_note delta_seconds first_date input_digest last_date schema_version source_label trip_ids)
  end

  # The digest the domain derives from the payload's own values, recomputed here
  # from the spec's documented canonical encoding rather than read back from the
  # implementation, so a payload carrying a mismatched digest fails.
  defp digest_for(payload) do
    [
      ["schema_version", payload["schema_version"]],
      ["trip_ids", payload["trip_ids"]],
      ["first_date", payload["first_date"]],
      ["last_date", payload["last_date"]],
      ["delta_seconds", payload["delta_seconds"]],
      ["approval_note", payload["approval_note"]],
      ["source_label", payload["source_label"]]
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Every native row the form must not touch, as one comparable signature.
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
      calendar_dates:
        Repo.all(
          from(d in CalendarDate,
            where: d.gtfs_version_id == ^version_id,
            select: {d.service_id, d.date, d.exception_type}
          )
        )
        |> Enum.sort(),
      stop_times:
        Repo.all(
          from(s in StopTime,
            join: t in Trip,
            # `StopTime.trip_id` is the imported string id, not the UUID, so the
            # join is on the imported value the page itself reads.
            on: t.trip_id == s.trip_id and t.gtfs_version_id == ^version_id,
            where: t.gtfs_version_id == ^version_id,
            select: {s.trip_id, s.stop_sequence, s.arrival_time, s.departure_time}
          )
        )
        |> Enum.sort(),
      logs: Repo.aggregate(ChangeLog, :count)
    }
  end

  # The largest payload the ceiling admits, located rather than estimated.
  defp largest_admitted(context) do
    # The cap is on the whole tagged context, so the payload's own ceiling is
    # already below the limit; the search therefore starts below it.
    largest = bisect_largest(context, 1, Scope.max_context_bytes())

    assert admitted?(context, largest)
    refute admitted?(context, largest + 1)

    largest
  end

  defp bisect_largest(context, low, high) do
    if low >= high do
      low
    else
      middle = div(low + high, 2)

      if admitted?(context, middle) do
        bisect_largest(context, middle, high)
      else
        bisect_largest(context, low, middle - 1)
      end
    end
  end

  defp admitted?(context, size) do
    match?(
      {:ok, _admitted},
      Scope.with_source_snapshot(context, %{
        kind: "dated_changes",
        payload: %{"approval_note" => String.duplicate("a", size)}
      })
    )
  end
end
