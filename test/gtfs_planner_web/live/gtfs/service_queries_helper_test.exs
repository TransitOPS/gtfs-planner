defmodule GtfsPlannerWeb.Gtfs.ServiceQueriesHelperTest do
  @moduledoc """
  The Schedule helper panel on a route's Schedules page through the ordinary
  route and the live session (EV-1).

  The page, the conversation session and the turn task are three processes, so
  the Req.Test plug and the SQL sandbox are shared (`async: false`). Only the
  OpenRouter HTTP boundary is scripted (INV-5); the page, the panel, the facade,
  the session, the turn loop, the Schedule pack and the domain query are the
  shipped ones.

  The fixture is Harbor Transit's A02/A19 dataset: `WEEKDAY` is removed on
  Thanksgiving and `HOLIDAY` takes over, one trip visits Central Station twice,
  one trip is frequency-based and one carries no time. Those facts are what the
  page's own rows and the panel's card are asserted against, so a card whose
  count drifted from the schedule behind it fails here.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @thanksgiving "2026-11-26"
  @first_message "What leaves Central Station after 6pm on Thanksgiving?"
  @answer "Central Station has two departures after 6:00pm on Thanksgiving."
  @departure_arguments ~s({"service_date":"2026-11-26","stop_id":"CENTRAL","stop_sequence":1,"after":"18:00","include_after_midnight":false})

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization =
      organization_fixture(%{alias: "harbor-transit-#{System.unique_integer([:positive])}"})

    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Harbor Feed"})

    track_sessions()

    context = %{
      organization: organization,
      user: user,
      membership: membership,
      version: version
    }

    context
    |> harbor_route()
    |> Map.put(:conn, log_in_user(build_conn(), user, organization: organization))
  end

  describe "opening and closing the panel" do
    test "the Schedules page offers the helper closed and the panel opens on this route",
         context do
      view = schedules_view(context)

      refute has_element?(view, "#agent-panel")
      assert element(view, "#agent-helper-open") |> render() =~ ~s(aria-expanded="false")
      assert element(view, "#agent-helper-open") |> render() =~ ~s(aria-controls="agent-panel")

      assert render(view) =~
               ~s(phx-hook="GtfsPlannerWeb.Gtfs.RouteSchedulesLive.RouteSchedulesHelperFocus")

      view |> element("#agent-helper-open") |> render_click()

      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})
      assert has_element?(view, "#agent-panel")
      assert element(view, "#agent-panel") |> render() =~ "H8 · #{context.version.name}"
      assert has_element?(view, "#agent-first-conversation")
      assert has_element?(view, "#agent-composer-input")
      assert is_pid(session_pid(view))

      view |> element("#agent-panel-close") |> render_click()

      refute has_element?(view, "#agent-panel")
      assert_push_event(view, "agent:focus", %{id: "agent-helper-open"})
    end

    test "navigating to another route replaces the conversation", context do
      view = schedules_view(context)
      view |> element("#agent-helper-open") |> render_click()
      first = session_pid(view)
      assert is_pid(first)

      assert {:ok, other_view, _html} =
               live(context.conn, "/gtfs/#{context.version.id}/routes/H12/schedules")

      # The page for H12 holds its own conversation, so the H8 transcript never
      # appears beside another route's rows.
      other = session_pid(other_view)
      assert is_pid(other)
      refute other == first
    end
  end

  describe "the composed answer" do
    test "a departure question renders one card whose count matches the schedule",
         context do
      {view, pid} = open_helper(context)

      expect_reply(tool_calls_reply([{"call_1", "query_departures", @departure_arguments}]))
      expect_reply(text_reply(@answer))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      assert has_element?(view, "#agent-entry-2", @answer)
      assert has_element?(view, "#agent-entry-2 [data-evidence-kind='service_departures']")
      assert has_element?(view, "#agent-entry-2 [data-evidence-completeness='complete']")

      card = view |> element("#agent-evidence-2-1") |> render()
      assert card =~ "Server result"
      assert card =~ "2 departures"
      assert card =~ "gtfs_service_queries"

      # The card's link is this route's own Schedules page, the page the helper
      # is bound to, so following it never leaves the scope the panel holds.
      assert card =~ "/gtfs/#{context.version.id}/routes/H8/schedules"

      # The prose stays prose next to the card, so a model sentence can never
      # replace the server's count.
      assert has_element?(view, "#agent-prose-2", @answer)

      fragment = view |> element("#agent-entries") |> render() |> LazyHTML.from_fragment()
      assert query_count(fragment, "a") == 1
    end

    test "an ambiguous stop renders no card at all", context do
      {view, pid} = open_helper(context)

      arguments =
        ~s({"service_date":"2026-11-26","stop_id":"CENTRAL","after":"18:00","include_after_midnight":false})

      expect_reply(tool_calls_reply([{"call_1", "query_departures", arguments}]))
      expect_reply(text_reply("Which visit did you mean?"))

      submit(view, "When does the 8 leave Central Station after 6pm?")
      assert await_settled(pid).status == :done

      assert has_element?(view, "#agent-entry-2", "Which visit did you mean?")
      refute has_element?(view, "[data-evidence-kind]")
    end

    test "the card keeps its facts and its exclusions visible", context do
      {view, pid} = open_helper(context)

      expect_reply(
        tool_calls_reply([
          {"call_1", "list_boarding_occurrences", ~s({"service_date":"2026-11-26"})}
        ])
      )

      expect_reply(text_reply("This route boards at two stops."))

      submit(view, "Which stops does this route board at on Thanksgiving?")
      assert await_settled(pid).status == :done

      assert has_element?(view, "#agent-entry-2 [data-evidence-kind='boarding_occurrences']")
      card = view |> element("#agent-evidence-2-1") |> render()
      assert card =~ "2 stops to board at"
      assert card =~ "Stops with more than one visit"
    end
  end

  describe "the schedule behind the panel is untouched" do
    test "asking a question writes no schedule change", context do
      {view, pid} = open_helper(context)

      before = schedule_signature(view)

      expect_reply(tool_calls_reply([{"call_1", "query_departures", @departure_arguments}]))
      expect_reply(text_reply(@answer))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      assert schedule_signature(view) == before
      refute render(view) =~ "Saved"
    end
  end

  ## Helpers

  # A compact read of what the page itself shows, so the helper's presence and
  # answers can be compared against the schedule rather than against a fixture.
  defp schedule_signature(view), do: view |> element("#schedules-sections") |> render()

  defp schedules_view(context) do
    assert {:ok, view, _html} =
             live(context.conn, "/gtfs/#{context.version.id}/routes/H8/schedules")

    view
  end

  # Opens the panel, then joins the same conversation through the facade as a
  # second listener: the session's own settle events are observable without
  # polling the render or sleeping.
  defp open_helper(context) do
    view = schedules_view(context)
    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    pid = session_pid(view)
    assert {:ok, ^pid, _snapshot} = Agents.open(route_scope(context, context.route))

    {view, pid}
  end

  defp route_scope(context, route) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "service_queries",
      version_name: context.version.name,
      resource_context: Scope.context({:route, route.id})
    }
  end

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  defp session_pid(view), do: :sys.get_state(view.pid).socket.assigns.agent_session

  # The working placeholder arrives before the settled entry.
  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  defp query_count(fragment, selector) do
    fragment |> LazyHTML.query(selector) |> Enum.to_list() |> length()
  end

  # Harbor Transit's A02/A19 dataset: `WEEKDAY` is removed on Thanksgiving,
  # `HOLIDAY` takes over, and H8 carries a listed pair, a frequency trip and one
  # trip with no recorded time.
  defp harbor_route(context) do
    organization = context.organization
    version = context.version

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    for {stop_id, stop_name} <- [{"CENTRAL", "Central Station"}, {"HARBOR", "Harbor Yards"}] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route = route_fixture(organization.id, version.id, %{route_id: "H8", route_short_name: "8"})
    route_fixture(organization.id, version.id, %{route_id: "H12", route_short_name: "12"})

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAY"})

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      date: Date.from_iso8601!(@thanksgiving),
      exception_type: 2
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "HOLIDAY",
      date: Date.from_iso8601!(@thanksgiving),
      exception_type: 1
    })

    holiday = calendar_fixture(organization.id, version.id, %{service_id: "HOLIDAY"})

    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "H8-P1",
        route_pattern_name: "Downtown",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"CENTRAL", 0, 0, 1},
          {"HARBOR", 600, 600, 1}
        ]
      })

    for {trip_id, start_time} <- [
          {"H8-1820", "18:20:00"},
          {"H8-1910", "19:10:00"}
        ] do
      schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
        service_id: holiday,
        trip_id: trip_id,
        start_time: start_time,
        trip_headsign: "Harbor Yards"
      })
    end

    schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
      service_id: holiday,
      trip_id: "H8-FREQ",
      start_time: "20:00:00",
      trip_headsign: "Harbor Yards",
      frequencies: [%{start_time: "20:00:00", end_time: "22:00:00", headway_secs: 1200}]
    })

    Map.merge(context, %{route: route})
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
