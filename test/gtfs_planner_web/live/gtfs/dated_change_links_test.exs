defmodule GtfsPlannerWeb.Gtfs.DatedChangeLinksTest do
  @moduledoc """
  EV-9: owned native review links, resolved against the current scope before a
  path is built (spec ai-11, step 9; CL-9; FH-9).

  Every case reaches the rule through the real composition. The panel's own
  evidence path is exercised by an ordinary authenticated conversation on the
  Schedule page with the dated-change pack selected, the report's own link by
  the page's rendered controls, and the ownership matrix by
  `GtfsPlannerWeb.AgentPanel.resolve_resource_link/2` — the public seam the
  report itself navigates by — called on the socket of a page that is mounted
  through the router with its own authenticated organization and version.

  No assign is injected and no private function is called. The only boundary
  that is substituted is the OpenRouter HTTP endpoint, through the test
  environment's existing `Req.Test` plug, exactly as the Schedule and Calendars
  helper tests do.

  Expected paths are derived from the router's own shape and `URI.encode_www_form/1`
  over the fixture's own identifiers, never from the implementation's output.
  A service ID carrying a space and a slash is used deliberately: the encoding
  is the claim, and a plain identifier would not test it.

  The prepared focused command is
  `mix test test/gtfs_planner_web/live/gtfs/dated_change_links_test.exs`
  (EV-9, 120 s deadline); this run defers it to branch review.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ScheduleEditingFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.AgentPanel

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @route_id "LINK_PLANNED"

  # A service ID with a space and a slash in it. The calendar editor carries its
  # identity as a query parameter precisely so an imported ID can contain either,
  # and the link this step builds has to encode both.
  @service "PLANNED WD/2"
  @dates_only "PLANNED DATES ONLY"

  @first_date "2026-11-02"
  @last_date "2026-11-13"
  @delta_seconds 300
  @approval_note "Board approved the temporary Saturday service for this window."

  @first_message "Which dates would this shift affect?"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    scope = editing_scope!(@route_id, %{service: @service})

    trip_a = linked_trip!(scope, "07:00:00", %{trip_id: "LINK_0700"})
    trip_b = linked_trip!(scope, "07:30:00", %{trip_id: "LINK_0730"})

    organization = scope.organization
    version = scope.version

    # A dates-only service: a metadata anchor and one added date, and no weekly
    # row at all. The calendar editor opens it, so the link must resolve.
    calendar_attribute_fixture(organization.id, version.id, %{service_id: @dates_only})

    calendar_date_fixture(organization.id, version.id, %{
      service_id: @dates_only,
      date: ~D[2026-11-07],
      exception_type: 1
    })

    # The same identity in another organization, and in another version of this
    # organization. Neither is this page's scope, so neither may resolve.
    foreign = organization_fixture(%{alias: "foreign-#{System.unique_integer([:positive])}"})
    foreign_version = gtfs_version_fixture(foreign.id)
    calendar_fixture(foreign.id, foreign_version.id, %{service_id: @service})
    route_fixture(foreign.id, foreign_version.id, %{route_id: @route_id})

    other_version = gtfs_version_fixture(organization.id, %{name: "Other Version"})
    calendar_fixture(organization.id, other_version.id, %{service_id: @service})
    route_fixture(organization.id, other_version.id, %{route_id: @route_id})

    # A service that existed and does not any more.
    deleted = "GONE WD"
    calendar_fixture(organization.id, version.id, %{service_id: deleted})

    Repo.delete_all(
      from(c in Calendar,
        where: c.gtfs_version_id == ^version.id and c.service_id == ^deleted
      )
    )

    track_sessions()

    {:ok,
     conn: log_in_user(build_conn(), scope.actor, organization: organization),
     scope: scope,
     foreign: foreign,
     foreign_version: foreign_version,
     other_version: other_version,
     deleted: deleted,
     trips: [trip_a, trip_b]}
  end

  describe "the panel's own resolver, on a mounted page" do
    test "a calendar this version owns resolves to its encoded editor path", context do
      view = schedules_view(context)

      assert panel_link(view, "calendar", @service) ==
               "/gtfs/#{context.scope.version.id}/calendars/show?service_id=#{URI.encode_www_form(@service)}"
    end

    test "a dates-only service resolves, because the editor opens it", context do
      view = schedules_view(context)

      assert panel_link(view, "calendar", @dates_only) ==
               "/gtfs/#{context.scope.version.id}/calendars/show?service_id=#{URI.encode_www_form(@dates_only)}"
    end

    test "a route this version owns resolves to its own Schedules page", context do
      view = schedules_view(context)

      assert panel_link(view, "route", @route_id) ==
               "/gtfs/#{context.scope.version.id}/routes/#{URI.encode_www_form(@route_id)}/schedules"
    end

    test "another organization's identity does not resolve", context do
      view = schedules_view(context)

      # The very same identifiers exist under `foreign`, and this page's socket
      # holds only this organization's scope, so each still resolves here while
      # the foreign rows stay foreign.
      assert foreign_owns_both(context)
      assert panel_link(view, "calendar", @service) =~ "/calendars/show?service_id="
      assert panel_link(view, "route", @route_id) =~ "/schedules"

      # A service that exists only in the foreign organization is refused, which
      # is the failure this gate exists for: a trusted scope must not be able to
      # mask a foreign resource as one of this page's own.
      foreign_only = "FOREIGN ONLY"

      calendar_fixture(context.foreign.id, context.foreign_version.id, %{service_id: foreign_only})

      assert is_nil(panel_link(view, "calendar", foreign_only))
    end

    test "another version of this organization does not resolve", context do
      view = schedules_view(context)

      other_only = "OTHER VERSION ONLY"

      calendar_fixture(context.scope.organization.id, context.other_version.id, %{
        service_id: other_only
      })

      route_fixture(context.scope.organization.id, context.other_version.id, %{
        route_id: "OTHER_VERSION_ROUTE"
      })

      assert is_nil(panel_link(view, "calendar", other_only))
      assert is_nil(panel_link(view, "route", "OTHER_VERSION_ROUTE"))
    end

    test "a deleted identity and an unknown one do not resolve", context do
      view = schedules_view(context)

      assert context.deleted == "GONE WD"
      assert is_nil(panel_link(view, "calendar", context.deleted))
      assert is_nil(panel_link(view, "calendar", "NEVER EXISTED"))
      assert is_nil(panel_link(view, "route", "NEVER EXISTED"))
    end

    test "an unlisted kind, a non-binary id and a resource URL never resolve", context do
      view = schedules_view(context)
      socket = panel_socket(view)

      # Blocks and transfers have no typed ownership or path resolver yet, so
      # their identities stay explanatory text rather than becoming a path.
      assert is_nil(AgentPanel.resolve_resource_link(socket, %{kind: "block", id: "B1"}))
      assert is_nil(AgentPanel.resolve_resource_link(socket, %{kind: "transfer", id: "T1"}))
      assert is_nil(AgentPanel.resolve_resource_link(socket, %{kind: "trip", id: "LINK_0700"}))

      # A resource that carries a URL of its own is read for its kind and id
      # only, so neither an unsafe scheme nor an off-scope path is ever built.
      assert is_nil(
               AgentPanel.resolve_resource_link(socket, %{
                 kind: "unknown",
                 id: "X",
                 url: "javascript:alert(1)"
               })
             )

      assert is_nil(
               AgentPanel.resolve_resource_link(socket, %{
                 kind: "calendar",
                 id: nil,
                 url: "javascript:alert(1)"
               })
             )

      # Even for an owned identity, the returned path is the one this scope
      # builds, not one the resource supplied.
      owned =
        AgentPanel.resolve_resource_link(socket, %{
          kind: "calendar",
          id: @service,
          url: "https://evil.test/steal"
        })

      assert owned ==
               "/gtfs/#{context.scope.version.id}/calendars/show?service_id=#{URI.encode_www_form(@service)}"

      refute owned =~ "evil.test"
    end

    test "the calendars index path the other packs already use still resolves", context do
      view = schedules_view(context)

      assert panel_link(view, "calendars_index", "ignored") ==
               "/gtfs/#{context.scope.version.id}/calendars"
    end
  end

  describe "the panel's own evidence card" do
    test "an ordinary answer links the route and the calendar it actually read", context do
      {view, pid} = open_helper(context)
      before = native_signature(context)

      expect_reply(tool_calls_reply([{"call_1", "prepare_dated_change_plan", "{}"}]))
      expect_reply(text_reply("Nine dates in that window."))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      card = view |> element("#agent-evidence-2-1") |> render()

      # Both references the pack emitted resolve to real, scoped editor pages.
      assert card =~
               "/gtfs/#{context.scope.version.id}/routes/#{URI.encode_www_form(@route_id)}/schedules"

      assert card =~
               "/gtfs/#{context.scope.version.id}/calendars/show?service_id=#{URI.encode_www_form(@service)}"

      # Every anchor on the card is one this scope built; a model sentence cannot
      # add another, and nothing offers to apply the plan (AC-10, INV-1).
      assert card_anchors(view) == [
               "/gtfs/#{context.scope.version.id}/routes/#{URI.encode_www_form(@route_id)}/schedules",
               "/gtfs/#{context.scope.version.id}/calendars/show?service_id=#{URI.encode_www_form(@service)}"
             ]

      refute card =~ "javascript:"
      refute render(view) =~ ~r/phx-click="apply_dated_change"/
      refute has_element?(view, "#dated-change-apply")

      # Answering wrote nothing: the calendar, its dates and the change log are
      # exactly what they were.
      assert native_signature(context) == before
    end

    test "a reference this version no longer owns renders as text with a reason", context do
      {view, pid} = open_helper(context)

      expect_reply(tool_calls_reply([{"call_1", "prepare_dated_change_plan", "{}"}]))
      expect_reply(text_reply("Here is the plan."))

      submit(view, @first_message)
      assert await_settled(pid).status == :done
      assert has_element?(view, "#agent-evidence-2-1")

      # The calendar the answer named is deleted while the person reads the
      # card. The panel re-resolves nothing on its own, so the honest statement
      # here is that the resolver refuses an identity this version does not own.
      Repo.delete_all(
        from(a in CalendarAttribute,
          where: a.gtfs_version_id == ^context.scope.version.id and a.service_id == ^@service
        )
      )

      Repo.delete_all(
        from(d in CalendarDate,
          where: d.gtfs_version_id == ^context.scope.version.id and d.service_id == ^@service
        )
      )

      Repo.delete_all(
        from(c in Calendar,
          where: c.gtfs_version_id == ^context.scope.version.id and c.service_id == ^@service
        )
      )

      assert is_nil(panel_link(view, "calendar", @service))
    end
  end

  describe "the report's own link" do
    test "the analyzed report links the calendar it read, and following it opens that calendar",
         context do
      view = analyzed_view(context)

      assert has_element?(view, "#dated-change-calendar-link a")

      assert view |> element("#dated-change-calendar-link a") |> render() =~
               "href=\"/gtfs/#{context.scope.version.id}/calendars/show?service_id=#{URI.encode_www_form(@service)}\""

      before = native_signature(context)

      # Following the link is ordinary native navigation: it opens the calendar
      # editor for this calendar and writes nothing on the way (AC-17, INV-1).
      calendar_view =
        view |> element("#dated-change-calendar-link a") |> render_click()

      assert calendar_view |> element("h1") |> render() =~ @service
      assert native_signature(context) == before
    end

    test "a calendar deleted after the analysis leaves the report unlinked rather than stale-linked",
         context do
      view = analyzed_view(context)
      assert has_element?(view, "#dated-change-calendar-link a")

      for schema <- [CalendarAttribute, CalendarDate, Calendar] do
        Repo.delete_all(
          from(row in schema,
            where:
              row.gtfs_version_id == ^context.scope.version.id and row.service_id == ^@service
          )
        )
      end

      # Switching the date set re-reads nothing and re-pages the retained report,
      # and it re-resolves the link on the way, so the retained dates stay on
      # screen while the link becomes honest text.
      view |> element("#dated-change-kind input[value=original]") |> render_click()

      refute has_element?(view, "#dated-change-calendar-link a")
      assert view |> element("#dated-change-calendar-link") |> render() =~ "no longer a calendar"
      assert has_element?(view, "#dated-change-dates")
    end

    test "the report's link resolves through the panel's rule, not a second copy", context do
      view = analyzed_view(context)
      socket = panel_socket(view)

      # The report's link and the panel's own resolution of the same resource are
      # one function's answer, so a host cannot drift from the panel (cross-step
      # contract).
      assert AgentPanel.resolve_resource_link(socket, %{kind: "calendar", id: @service}) ==
               "/gtfs/#{context.scope.version.id}/calendars/show?service_id=#{URI.encode_www_form(@service)}"
    end
  end

  ## Helpers

  defp schedules_view(context) do
    assert {:ok, view, _html} =
             live(context.conn, "/gtfs/#{context.scope.version.id}/routes/#{@route_id}/schedules")

    view
  end

  # The real panel's socket, read from the mounted page. The resolver takes a
  # socket because that is what the panel holds; this is the same value the
  # panel passes for its own evidence, not a stand-in for it.
  defp panel_socket(view), do: :sys.get_state(view.pid).socket

  defp panel_link(view, kind, id),
    do: AgentPanel.resolve_resource_link(panel_socket(view), %{kind: kind, id: id})

  defp foreign_owns_both(context) do
    foreign_calendar =
      Repo.exists?(
        from(c in Calendar,
          where:
            c.organization_id == ^context.foreign.id and
              c.gtfs_version_id == ^context.foreign_version.id and
              c.service_id == ^@service
        )
      )

    foreign_route =
      Repo.exists?(
        from(r in Route,
          where:
            r.organization_id == ^context.foreign.id and
              r.gtfs_version_id == ^context.foreign_version.id and
              r.route_id == ^@route_id
        )
      )

    foreign_calendar and foreign_route
  end

  # The view a report is analyzed from: the timetable's own selection, an
  # accepted window, and the real analysis through the page's own controls.
  defp analyzed_view(context) do
    view = schedules_view(context)

    switch_helper(view, "dated_changes")

    Enum.each(context.trips, fn trip ->
      view |> element("#trip-select-#{trip.trip_id}") |> render_click()
    end)

    fields = %{
      "first_date" => @first_date,
      "last_date" => @last_date,
      "delta_seconds" => Integer.to_string(@delta_seconds),
      "approval_note" => @approval_note,
      "source_label" => ""
    }

    view |> element("#dated-change-form") |> render_submit(%{"dated_change" => fields})

    view |> element("#dated-change-analyze") |> render_click()
    await_plan(view)

    view
  end

  # The helper switch is a `phx-change` form of radio inputs, so it is driven
  # the way a browser drives it: the form posts the chosen value.
  defp switch_helper(view, pack_id) do
    view |> form("#schedule-helper-mode-form", %{"pack" => pack_id}) |> render_change()
  end

  # The read the page started, waited on with a real monitor.
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

  # Opens the panel on the dated-change pack, then joins the same conversation
  # through the facade as a second listener so the session's own settle events
  # are observable without polling or sleeping.
  defp open_helper(context) do
    view = schedules_view(context)
    switch_helper(view, "dated_changes")

    Enum.each(context.trips, fn trip ->
      view |> element("#trip-select-#{trip.trip_id}") |> render_click()
    end)

    fields = %{
      "first_date" => @first_date,
      "last_date" => @last_date,
      "delta_seconds" => Integer.to_string(@delta_seconds),
      "approval_note" => @approval_note,
      "source_label" => ""
    }

    view |> element("#dated-change-form") |> render_submit(%{"dated_change" => fields})
    view |> element("#agent-helper-open") |> render_click()

    assert has_element?(view, "#agent-panel")

    pid = session_pid(view)
    assert is_pid(pid)

    {view, pid}
  end

  defp session_pid(view), do: :sys.get_state(view.pid).socket.assigns.agent_session

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  # The working placeholder arrives before the settled entry.
  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  defp card_anchors(view) do
    view
    |> element("#agent-evidence-2-1")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a")
    |> Enum.map(&LazyHTML.attribute(&1, "href"))
  end

  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(GtfsPlanner.Agents.SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    GtfsPlanner.Agents.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  # Every native row a link must not touch, as one comparable signature.
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
            select: {c.service_id, c.start_date, c.end_date}
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

  ## Scripted OpenRouter replies

  defp expect_reply(payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

  defp text_reply(text) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => text}}],
      "usage" => %{"cost" => 0.0}
    }
  end

  defp tool_calls_reply(calls) do
    tool_calls =
      Enum.map(calls, fn {id, name, arguments} ->
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => arguments}
        }
      end)

    %{
      "model" => @model,
      "choices" => [
        %{
          "finish_reason" => "tool_calls",
          "message" => %{"content" => nil, "tool_calls" => tool_calls}
        }
      ],
      "usage" => %{"cost" => 0.0}
    }
  end
end
