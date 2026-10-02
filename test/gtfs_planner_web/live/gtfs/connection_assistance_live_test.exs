defmodule GtfsPlannerWeb.Gtfs.ConnectionAssistanceLiveTest do
  @moduledoc """
  Merge evidence (EV-10) for the Schedules page's official connection comparison:
  the exact numbers the server read beside the helper panel, the reasons a pair
  cannot be answered exactly, and the promise that none of it touches the page.

  Every expectation is hand-derived from the acceptance cases and the GTFS
  reference rather than from a second call of the code under test. The seeded
  version has route 1 arriving at `CENTRAL-P1` (the platform under station
  `CENTRAL`) at 09:02:00 and route 2 leaving `HARBOR` at 09:08:00, so
  32,880 - 32,520 = 360 seconds are available against the stored 300 second
  minimum and the margin is 60 seconds. A supplied candidate arriving at 09:07:00
  and departing at 09:08:00 leaves 60 seconds, a -240 second margin and a
  -240 - 60 = -300 delta. `AWAY` is covered by no stored rule, so a pair that
  touches it has no stated minimum and is unresolved rather than comparable.

  The path under test is the production one: this page's own approval form, the
  admitted source, `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` ->
  `Packs.Connections` -> `Gtfs.ConnectionComparison.compare/4`, and the evidence
  the panel delivers to this page. Only the OpenRouter HTTP boundary is doubled
  (INV-5). Nothing here prepares or applies anything, and the row and audit
  counts are asserted on both sides of every turn (CR-1, CR-4).

  The focused command is
  `MIX_ENV=test MIX_TEST_PARTITION=_s10 mix test test/gtfs_planner_web/live/gtfs/connection_assistance_live_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.AgentPanel

  @service_date ~D[2026-11-26]
  @service_date_text Date.to_iso8601(@service_date)
  @station "CENTRAL"
  @platform "CENTRAL-P1"
  @harbor "HARBOR"
  @away "AWAY"
  @arrival_trip "R1-0902"
  @departure_trip "R2-0908"
  @away_trip "R1-AWAY"
  @stored_minimum 300
  @candidate_arrival "09:07:00"
  @candidate_departure "09:08:00"
  @candidate_approval "Dispatch sheet 2026-11-26"

  # The test environment routes `GtfsPlanner.Agents.Model` through the Req.Test
  # plug, so every scripted reply below replaces only the HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor
  @model "test/model-a"

  setup {Req.Test, :verify_on_exit!}

  setup %{conn: conn} do
    # The turn task is not in this process's callers, so the Req.Test plug and
    # the SQL sandbox are both shared.
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    organization = organization_fixture(%{alias: unique_alias()})
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id, %{name: "Connection Results Version"})

    network = seed_version(organization, version)

    Map.merge(network, %{
      organization: organization,
      user: user,
      version: version,
      conn: log_in_user(conn, user, organization: organization)
    })
  end

  describe "the official comparison beside the panel" do
    test "an approved pair shows the server's before, after and delta with the minimum's provenance",
         ctx do
      {view, _pid} = compare_view(ctx, [pair(ctx)])

      results = results(view)

      # The connection this version states, in this version's own clocks.
      assert results =~ "09:02:00 → 09:08:00"
      assert results =~ "360 s available"
      assert results =~ "margin 60 s"

      # The candidate is the person's own external clock, measured against the
      # same stated minimum, and the difference between the two is named.
      assert results =~ "09:07:00 → 09:08:00"
      assert results =~ "60 s available"
      assert results =~ "margin -240 s"
      assert results =~ "-300 s"

      # The minimum is named with the stored rule that supplied it, so a reader
      # can tell this version's policy from an operator's supplied number.
      assert results =~ "Stored minimum 300 s"
      assert results =~ "best-ranked type 2 rule"
      assert results =~ "Comparable"

      # The totals are the report's own, and the card says where it was read.
      assert results =~ "1 approved connection pairs"
      assert results =~ "Complete"
      assert results =~ "gtfs_connections"

      # The model's own sentence is prose and the card says so.
      assert results =~ "not a guarantee"
    end

    test "the supplied candidate is reported as the operator's own approved evidence", ctx do
      pair =
        uncovered_pair(ctx)
        |> Map.put("minimum", %{
          "origin" => "supplied",
          "seconds" => to_string(@stored_minimum),
          "approval" => "Approved timetable sheet"
        })
        |> Map.put("candidate", %{
          "arrival" => @candidate_arrival,
          "departure" => @candidate_departure,
          "approval" => "Approved timetable sheet"
        })

      {view, _pid} = compare_view(ctx, [pair])

      # Where the stored policy states no minimum, the operator's supplied one
      # is used and named as their own evidence, never as this version's policy.
      assert element(view, "#connection-comparison-row-away-uncovered-minimum") |> render() =~
               "Supplied minimum 300 s, approved as"

      assert element(view, "#connection-comparison-row-away-uncovered-status") |> render() =~
               "Comparable"
    end

    test "a pair with no stated minimum is listed with its reason beside the one that answered",
         ctx do
      {view, _pid} = compare_view(ctx, [pair(ctx), uncovered_pair(ctx)])

      results = results(view)

      # Both approved pairs are classified: one answered, one not.
      assert results =~ "2 approved connection pairs"
      assert results =~ "Incomplete"
      assert results =~ "Only 1 of 2 approved pairs could be compared"

      assert has_element?(view, "#connection-comparison-row-pair-1-status")
      assert element(view, "#connection-comparison-row-pair-1-status") |> render() =~ "Comparable"

      assert has_element?(view, "#connection-comparison-row-away-uncovered-status")

      assert element(view, "#connection-comparison-row-away-uncovered-status") |> render() =~
               "Unresolved"

      assert element(view, "#connection-comparison-row-away-uncovered-reason") |> render() =~
               "no_stated_minimum"

      # The totals cover every requested pair even though one is unanswered.
      assert element(view, "#connection-comparison-totals") |> render() =~ "Approved pairs"

      assert element(view, "#connection-comparison-exclusions") |> render() =~
               "away-uncovered: no_stated_minimum"
    end

    test "a comparison writes nothing and leaves the native timetable and its audit alone", ctx do
      before = row_counts(ctx)

      {view, _pid} = compare_view(ctx, [pair(ctx)])

      assert row_counts(ctx) == before
      assert has_element?(view, "#schedules-grid")
      assert results(view) =~ "Connection comparison"
    end
  end

  describe "the states around the comparison" do
    test "closing the panel by keyboard returns focus to the control that opened it", ctx do
      {view, _pid} = compare_view(ctx, [pair(ctx)])

      assert has_element?(view, "#connection-comparison-results")

      view |> element("#agent-panel-close") |> render_click()

      refute has_element?(view, "#agent-panel")
      assert_push_event(view, "agent:focus", %{id: "agent-helper-open"})
    end

    test "a provider failure keeps the accepted inputs and reports no comparison", ctx do
      before = row_counts(ctx)

      view = approved_view(ctx, [pair(ctx)])
      script_failure()
      ask(view, "Can riders make the connection I approved?")

      assert_receive {:agent_event, _pid, {:entry, %{status: :failed} = entry}}, 5_000
      assert entry.evidence == []

      # The panel reports the failure in the transcript, and this page's own
      # card says there is no comparison rather than showing one.
      assert element(view, "#agent-entries") |> render() =~ "unavailable"
      assert has_element?(view, "#connection-comparison-results")
      refute has_element?(view, "#connection-comparison-rows")

      # Everything the operator accepted is still accepted: the receipt, the
      # draft and the native timetable, and no row moved.
      assert has_element?(view, "#connection-approval-receipt")

      assert has_element?(
               view,
               ~s(input#connection-pair-1-candidate-arrival[value="#{@candidate_arrival}"])
             )

      assert row_counts(ctx) == before
    end

    test "an edited approval removes the report it was read against", ctx do
      {view, _pid} = compare_view(ctx, [pair(ctx)])

      assert has_element?(view, "#connection-comparison-rows")

      view
      |> form("#connection-approval-form", %{
        "connection" => %{
          "service_date" => "2026-11-27",
          "pairs" => indexed([pair(ctx)])
        }
      })
      |> render_change()

      # The source and the conversation that read it go together, so the card
      # goes with them and names what to do next (INV-2).
      refute has_element?(view, "#connection-comparison-rows")
      assert element(view, "#connection-comparison-status") |> render() =~ "Nothing is approved"

      # The operator's edit is still the draft on screen.
      assert has_element?(view, ~s(input#connection-service-date[value="2026-11-27"]))
    end
  end

  ## The page under test

  defp approved_view(ctx, pairs) do
    {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

    submit(view, pairs)

    assert has_element?(view, "#connection-approval-receipt")

    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    # The panel opened the session itself from the admitted context; this process
    # attaches to the same conversation so the turn events are observable here.
    pid = socket_assigns(view).agent_session

    scope = %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.user.id,
      user_email: ctx.user.email,
      pack_id: "connections",
      version_name: ctx.version.name,
      resource_context: socket_assigns(view).agent_context
    }

    assert {:ok, ^pid, _snapshot} = Agents.open(scope)

    view
  end

  # Approves the pairs, asks the composer the question this page exists for, and
  # returns once the session has delivered the settled entry the card reads.
  defp compare_view(ctx, pairs) do
    view = approved_view(ctx, pairs)
    script_comparison()

    ask(view, "Can riders make the connections I approved?")

    assert_receive {:agent_event, pid, {:entry, %{status: :working}}}, 5_000

    assert_receive {:agent_event, ^pid, {:entry, %{status: :done, evidence: [evidence]}}}, 5_000

    assert evidence.kind == "connection_comparison"
    assert evidence.total == length(pairs)

    # The page renders the card from the evidence the session delivered.
    assert has_element?(view, "#connection-comparison-rows")

    shown = AgentPanel.latest_evidence(view_socket(view), "connection_comparison")
    assert shown.kind == evidence.kind
    assert shown.digest == evidence.digest

    {view, pid}
  end

  defp ask(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  defp results(view) do
    view
    |> element("#connection-comparison-results")
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
  end

  # The form this page posts: one service date and one pair per entry.
  defp submit(view, pairs) do
    # A second pair needs its own fieldset, which is what this page's own
    # control adds; the form posts every pair it renders.
    for _pair <- 2..length(pairs)//1, do: element(view, "#connection-pair-add") |> render_click()

    view
    |> form("#connection-approval-form", %{
      "connection" => %{"service_date" => @service_date_text, "pairs" => indexed(pairs)}
    })
    |> render_submit()

    view
  end

  defp indexed(pairs) do
    pairs
    |> Enum.with_index()
    |> Map.new(fn {pair, index} -> {Integer.to_string(index), pair} end)
  end

  defp pair(ctx, opts \\ []) do
    supplied = Keyword.get(opts, :candidate_approval, @candidate_approval)

    %{
      "id" => Keyword.get(opts, :id, "pair-1"),
      "from" => endpoint(ctx.from_route, ctx.arrival_trip, @platform),
      "to" => endpoint(ctx.to_route, ctx.departure_trip, @harbor),
      "minimum" =>
        Keyword.get(opts, :minimum, %{"origin" => "stored", "seconds" => "", "approval" => ""}),
      "candidate" => %{
        "arrival" => Keyword.get(opts, :candidate_arrival, @candidate_arrival),
        "departure" => Keyword.get(opts, :candidate_departure, @candidate_departure),
        "approval" => supplied
      }
    }
  end

  # A pair at `AWAY`, which no stored rule covers, so this version states no
  # minimum for it and the comparison has nothing exact to compute.
  defp uncovered_pair(ctx) do
    %{
      "id" => "away-uncovered",
      "from" => endpoint(ctx.from_route, ctx.away_trip, @away),
      "to" => endpoint(ctx.to_route, ctx.departure_trip, @harbor),
      "minimum" => %{"origin" => "stored", "seconds" => "", "approval" => ""},
      "candidate" => %{"arrival" => "", "departure" => "", "approval" => ""}
    }
  end

  defp endpoint(route, trip, stop_id) do
    %{
      "route_id" => label(route),
      "trip_id" => label(trip),
      "stop_id" => stop_id,
      "stop_sequence" => "1",
      "service_date_offset" => "0"
    }
  end

  defp label(%{trip: trip}), do: trip.trip_id
  defp label(%{route_id: route_id}), do: route_id
  defp label(value), do: value

  ## Fixtures

  defp seed_version(organization, version) do
    agency_fixture(organization.id, version.id, %{
      agency_id: "CONN",
      agency_timezone: "America/New_York"
    })

    calendar_fixture(organization.id, version.id, %{service_id: "WEEK"})
    calendar_attribute_fixture(organization.id, version.id, %{service_id: "WEEK"})

    stop_fixture(organization.id, version.id, %{
      stop_id: @station,
      stop_name: "Central Station",
      location_type: 1
    })

    # The platform is a child of the station, which is what lets a rule that
    # names the station cover the platform the pair actually reads.
    child_stop_fixture(organization.id, version.id, @station, %{
      stop_id: @platform,
      stop_name: "Central Platform 1"
    })

    stop_fixture(organization.id, version.id, %{stop_id: @harbor, stop_name: "Harbor Yards"})
    stop_fixture(organization.id, version.id, %{stop_id: @away, stop_name: "Away Track"})

    from_route = route_fixture(organization.id, version.id, %{route_id: "R1", agency_id: "CONN"})
    to_route = route_fixture(organization.id, version.id, %{route_id: "R2", agency_id: "CONN"})

    arrival_trip =
      timed_trip(organization, version, from_route, @arrival_trip, @platform, "09:02:00")

    departure_trip =
      timed_trip(organization, version, to_route, @departure_trip, @harbor, "09:08:00")

    away_trip = timed_trip(organization, version, from_route, @away_trip, @away, "09:02:00")

    # The stored rule names the parent station, which is what lets it cover the
    # platform, and it states the 300 seconds the comparison is measured against.
    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @station,
      to_stop_id: @harbor,
      transfer_type: 2,
      min_transfer_time: @stored_minimum
    })

    %{
      from_route: from_route,
      to_route: to_route,
      arrival_trip: arrival_trip,
      departure_trip: departure_trip,
      away_trip: away_trip
    }
  end

  defp timed_trip(organization, version, route, trip_id, stop_id, clock) do
    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_name: "#{trip_id} pattern",
        stops: [{stop_id, 0, 0, 1}]
      })

    schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
      service_id: "WEEK",
      trip_id: trip_id,
      start_time: clock,
      trip_headsign: "Test"
    })
  end

  defp unique_alias,
    do: "conn-results-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # Everything a comparison could write, counted before and after each turn: this
  # step prepares nothing and applies nothing, so every count holds (CR-1).
  defp row_counts(ctx) do
    %{
      trips: scoped(ctx, Trip),
      stop_times: scoped(ctx, StopTime),
      transfers: scoped(ctx, Transfer),
      change_log: scoped(ctx, ChangeLog)
    }
  end

  defp scoped(ctx, schema) do
    Repo.aggregate(
      from(row in schema,
        where:
          row.organization_id == ^ctx.organization.id and
            row.gtfs_version_id == ^ctx.version.id
      ),
      :count
    )
  end

  defp schedules_path(ctx) do
    "/gtfs/#{ctx.version.id}/routes/#{ctx.from_route.route_id}/schedules"
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp view_socket(view), do: :sys.get_state(view.pid).socket

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
  end

  # Sessions are started under the application's own supervisor and outlive the
  # test socket, so every session this file opened is terminated here.
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

  # The tool takes no arguments, so the model's only decision is whether to call
  # it; the second reply is prose that contradicts the card on purpose, which is
  # what proves the card and not the prose is the answer.
  defp script_comparison do
    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_1", "compare_connection_margins", "{}"}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, text_reply("Every approved connection has plenty of slack."))
    end)
  end

  # A real provider failure on the final request, so the settled entry is the
  # shipped rendering of a rejected call rather than a scripted refusal.
  defp script_failure do
    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_1", "compare_connection_margins", "{}"}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        500,
        Jason.encode!(%{"error" => %{"message" => "provider unavailable"}})
      )
    end)
  end

  defp respond(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp text_reply(text), do: reply("stop", %{"content" => text})

  defp tool_calls_reply(calls) do
    tool_calls =
      Enum.map(calls, fn {id, name, arguments} ->
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => arguments}
        }
      end)

    reply("tool_calls", %{"content" => nil, "tool_calls" => tool_calls})
  end

  defp reply(finish_reason, message) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => finish_reason, "message" => message}],
      "usage" => %{"cost" => 0.0}
    }
  end
end
