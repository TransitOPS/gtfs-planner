defmodule GtfsPlannerWeb.Gtfs.RoutePathEncodingTest do
  @moduledoc """
  The production links for route, run and stop IDs that carry reserved
  characters (EV-21).

  GTFS identifiers are free text. A hand-built path can therefore name a
  different page than the record it meant: a `/` in an ID becomes another path
  segment, and `URI.encode_www_form/1` in a path segment turns a space into `+`,
  which the router reads back as a literal `+`. These tests assert the exact
  address a rendered production link carries, so an unencoded or www-form-encoded
  segment fails here rather than in a person's browser.

  The panel case runs the page, the conversation session and the turn task as
  separate processes, so the Req.Test plug and the SQL sandbox are shared
  (`async: false`) and only the OpenRouter HTTP boundary is scripted (INV-5).
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope

  @moduletag timeout: 120_000

  @slash_route_id "10/A"
  @space_route_id "10 A"
  @run_id "A&B"

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @thanksgiving "2026-11-26"
  @first_message "What leaves Central Station after 6pm on Thanksgiving?"
  @answer "Central Station has two departures after 6:00pm on Thanksgiving."

  @departure_arguments ~s({"service_date":"2026-11-26","stop_id":"CENTRAL","stop_sequence":1,"after":"18:00","include_after_midnight":false})

  setup {Req.Test, :verify_on_exit!}

  describe "a route ID with a slash" do
    setup :editor_scope

    test "the Schedules page links the pattern it has no timing for",
         %{conn: conn, version: version, organization: organization} do
      weekly_calendar(organization, version, "SLASH_WKD", "Weekday")

      route =
        route_fixture(organization.id, version.id, %{
          route_id: @slash_route_id,
          route_short_name: "10A"
        })

      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "10A-P1",
        route_pattern_name: "Untimed"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/10%2FA/schedules")

      # The route's own `/` is a path segment separator until it is encoded, so
      # this link has to be asserted exactly: `/routes/10/A/patterns/10A-P1` is
      # a different route's page and no page at all.
      assert has_element?(
               view,
               "#schedules-no-trips a[href='/gtfs/#{version.id}/routes/10%2FA/patterns/10A-P1']",
               "Add timing"
             )
    end

    test "the paste page canonicalizes to the encoded route's paste URL",
         %{conn: conn, version: version, organization: organization} do
      calendar = weekly_calendar(organization, version, "SLASH_WKD", "Weekday")

      route =
        route_fixture(organization.id, version.id, %{
          route_id: @slash_route_id,
          route_short_name: "10A"
        })

      for index <- 1..2 do
        stop_fixture(organization.id, version.id, %{
          stop_id: "SLASH_S#{index}",
          stop_name: "Slash Stop #{index}"
        })
      end

      pattern =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "10A-P1",
          route_pattern_name: "Main",
          route_pattern_typicality: 1,
          timing_name: "Standard",
          stops: [
            {"SLASH_S1", 0, 0, 1},
            {"SLASH_S2", 300, 360, 1}
          ]
        })

      schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
        service_id: calendar,
        trip_id: "10A-T0600",
        start_time: "06:00:00",
        trip_headsign: "Slash Stop 2"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/10%2FA/schedules/paste")

      # An invalid scope makes the page replace the URL with its canonical one,
      # through the same helper the version switch navigates with.
      render_patch(view, "/gtfs/#{version.id}/routes/10%2FA/schedules/paste?direction=9")

      requested = assert_patch(view)
      assert requested =~ "direction=9"

      canonical =
        "/gtfs/#{version.id}/routes/10%2FA/schedules/paste?" <>
          URI.encode_query([
            {"direction", "0"},
            {"pattern", pattern.pattern.id},
            {"service_id", calendar}
          ])

      assert assert_patch(view) == canonical
    end
  end

  describe "a run ID with an ampersand" do
    setup do
      %{user: user_fixture()}
    end

    test "a run named A&B round-trips through the Runs URL", %{conn: conn, user: user} do
      w = runs_version_fixture()
      [first | _rest] = w.blocks["101"]

      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: first,
        day_type_key: w.day_type_key,
        run_id: @run_id
      })

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: w.organization.id,
        roles: ["pathways_studio_editor"]
      })

      conn = log_in_user(conn, user, organization: w.organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&run=A%26B")

      # The URL opened this run, so the address and the screen agree on the run
      # named "A&B" before any patch is made.
      assert has_element?(view, "#run-drawer")
      assert text(view, "#run-drawer-title") == "Run #{@run_id}"

      # A patch that rebuilds the whole path keeps the run encoded, rather than
      # splitting it into a second query key at the raw "&".
      view |> element("#runs-tab-uncovered") |> render_click()

      assert_patch(
        view,
        "/gtfs/#{w.version.id}/runs?day=#{w.day_type_key}&panel=uncovered&run=A%26B"
      )
    end
  end

  describe "the Schedule helper on a route ID with a space" do
    setup do
      Req.Test.set_req_test_to_shared()

      organization =
        organization_fixture(%{alias: "path-encoding-#{System.unique_integer([:positive])}"})

      user = user_fixture()
      membership = organization_membership_fixture(user, organization)
      version = gtfs_version_fixture(organization.id, %{name: "Space Route Feed"})

      track_sessions()

      context = %{
        organization: organization,
        user: user,
        membership: membership,
        version: version
      }

      context
      |> space_route()
      |> Map.put(:conn, log_in_user(build_conn(), user, organization: organization))
    end

    test "the evidence card links the route's Schedules page with the space encoded", context do
      {view, pid} = open_helper(context)

      expect_reply(tool_calls_reply([{"call_1", "query_departures", @departure_arguments}]))
      expect_reply(text_reply(@answer))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      card = view |> element("#agent-evidence-2-1") |> render()

      # A path segment encodes a space as `%20`; `+` is the query-string form and
      # the router would read it as a route named "10+A".
      assert card =~ "/gtfs/#{context.version.id}/routes/10%20A/schedules"
      refute card =~ "10+A"
    end
  end

  ## Helpers

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "path-encoding-#{System.unique_integer([:positive])}"})

    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  defp weekly_calendar(organization, version, service_id, name) do
    calendar_fixture(organization.id, version.id, %{service_id: service_id})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name,
      service_schedule_name: name
    })

    service_id
  end

  # A cell's text, squashed: LazyHTML keeps the template's indentation, so an
  # exact match on "Run A&B" fails on the surrounding whitespace.
  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The route the panel's question is about: one route whose ID carries a space,
  # with the stops, calendar and trips a departure question reads, so the card's
  # answer comes from a schedule rather than from a fixture.
  defp space_route(context) do
    organization = context.organization
    version = context.version

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    for {stop_id, stop_name} <- [{"CENTRAL", "Central Station"}, {"HARBOR", "Harbor Yards"}] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route =
      route_fixture(organization.id, version.id, %{
        route_id: @space_route_id,
        route_short_name: "10"
      })

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

    calendar_fixture(organization.id, version.id, %{service_id: "HOLIDAY"})

    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "SPACE-P1",
        route_pattern_name: "Downtown",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"CENTRAL", 0, 0, 1},
          {"HARBOR", 600, 600, 1}
        ]
      })

    for {trip_id, start_time} <- [{"SPACE-1820", "18:20:00"}, {"SPACE-1910", "19:10:00"}] do
      schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
        service_id: "HOLIDAY",
        trip_id: trip_id,
        start_time: start_time,
        trip_headsign: "Harbor Yards"
      })
    end

    Map.merge(context, %{route: route})
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

  defp schedules_view(context) do
    assert {:ok, view, _html} =
             live(context.conn, "/gtfs/#{context.version.id}/routes/10%20A/schedules")

    view
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

  # The suite shares one session supervisor, so every session this test opened is
  # terminated here.
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
