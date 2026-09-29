defmodule GtfsPlannerWeb.Gtfs.CalendarsHelperLiveTest do
  @moduledoc """
  The Calendars helper panel through the ordinary route and the live session (EV-11).

  The page, the conversation session and the turn task are three processes, so
  the Req.Test plug and the SQL sandbox are shared (`async: false`). Only the
  OpenRouter HTTP boundary is scripted (INV-5); the panel, the facade, the
  session, the turn loop and the Calendars pack are the shipped ones, and every
  expectation comes from the domain fixtures rather than from implementation
  internals.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.TurnSupervisor

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @weekdays %{
    monday: 1,
    tuesday: 1,
    wednesday: 1,
    thursday: 1,
    friday: 1,
    saturday: 0,
    sunday: 0
  }

  @first_message "Do the school calendars run next Monday?"
  @unavailable_text "The helper is unavailable right now. Try again, or make the change yourself on this page."
  @forbidden_text "Your access changed. The helper stopped."
  @hostile "![x](https://evil.test/?d=1) <img src=x> [a](https://evil.test)"
  @get_calendar_arguments ~s({"service_id":"SCHOOL_WD","from":"2026-10-05","to":"2026-10-06"})

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Helper Version"})

    add_calendar(organization, version, "SCHOOL_WD", "School weekdays")
    add_calendar(organization, version, "SCHOOL_EX", "School express")

    track_sessions()

    %{organization: organization, user: user, membership: membership, version: version}
  end

  describe "the panel through the Calendars route" do
    test "opening shows the first conversation and closing returns focus to the button",
         context do
      view = helper_view(context)

      refute has_element?(view, "#agent-panel")
      assert element(view, "#agent-helper-open") |> render() =~ ~s(aria-expanded="false")
      assert element(view, "#agent-helper-open") |> render() =~ ~s(aria-controls="agent-panel")
      assert render(view) =~ ~s(phx-hook="GtfsPlannerWeb.Gtfs.CalendarsLive.CalendarHelperFocus")

      view |> element("#agent-helper-open") |> render_click()

      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})

      assert has_element?(view, "#agent-panel")
      assert element(view, "#agent-panel") |> render() =~ "Calendars · #{context.version.name}"
      assert has_element?(view, "#agent-first-conversation", "What needs to change?")
      assert has_element?(view, "#agent-example-1")
      assert has_element?(view, "#agent-example-2")
      assert has_element?(view, "#agent-composer-input")
      assert is_pid(session_pid(view))

      view |> element("#agent-panel-close") |> render_click()

      refute has_element?(view, "#agent-panel")
      assert has_element?(view, "#calendar-helper-focus")
      assert_push_event(view, "agent:focus", %{id: "agent-helper-open"})
    end

    test "the person's message and the working state appear before the reply", context do
      {view, pid} = open_helper(context)
      expect_blocked()

      submit(view, @first_message)

      html = render(view)
      assert html =~ @first_message
      assert element(view, "#agent-send") |> render() =~ "disabled"
      assert has_element?(view, "#agent-stop")
      assert has_element?(view, "#agent-entry-1", @first_message)
      assert has_element?(view, "#agent-status", "Working…")

      assert_receive {:blocked, stub}, 5_000
      release(stub, text_reply("Yes, both school calendars run next Monday."))

      entry = await_settled(pid)
      assert entry.status == :done
      assert entry.text == "Yes, both school calendars run next Monday."

      html = render(view)
      assert html =~ "Yes, both school calendars run next Monday."
      refute has_element?(view, "#agent-stop")
      refute html =~ "What needs to change?"
    end

    test "a hostile reply is literal text with no image or link", context do
      {view, pid} = open_helper(context)
      expect_reply(1, text_reply(@hostile))

      submit(view, @first_message)
      assert await_settled(pid).text == @hostile

      fragment = view |> element("#agent-entries") |> render() |> LazyHTML.from_fragment()

      assert LazyHTML.text(fragment) =~ "![x](https://evil.test/?d=1)"
      assert LazyHTML.text(fragment) =~ "<img src=x>"
      assert query_count(fragment, "img") == 0
      assert query_count(fragment, "a") == 0
      refute render(view) =~ "Applied"
    end

    test "closing and reopening keeps the same conversation", context do
      {view, pid} = open_helper(context)

      expect_reply(1, text_reply("Yes, both school calendars run next Monday."))
      submit(view, @first_message)
      assert await_settled(pid).status == :done

      view |> element("#agent-panel-close") |> render_click()
      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()

      html = render(view)
      assert has_element?(view, "#agent-panel")
      assert html =~ "Yes, both school calendars run next Monday."
      assert html =~ @first_message
      assert session_pid(view) == pid
      refute html =~ "What needs to change?"
    end

    test "a second editor in the same organization sees a first conversation", context do
      {view, pid} = open_helper(context)

      expect_reply(1, text_reply("Yes, both school calendars run next Monday."))
      submit(view, @first_message)
      assert await_settled(pid).status == :done

      other_user = user_fixture()
      organization_membership_fixture(other_user, context.organization)
      other_conn = log_in_user(build_conn(), other_user, organization: context.organization)
      assert {:ok, other_view, _html} = live(other_conn, "/gtfs/#{context.version.id}/calendars")

      other_view |> element("#agent-helper-open") |> render_click()

      html = render(other_view)
      assert html =~ "What needs to change?"
      refute html =~ @first_message
      refute html =~ "Yes, both school calendars run next Monday."
      refute session_pid(other_view) == pid
    end

    test "a version switch navigates to a page whose panel starts closed", context do
      {view, pid} = open_helper(context)
      conn = log_in_user(context.conn, context.user, organization: context.organization)
      other_version = gtfs_version_fixture(context.organization.id, %{name: "Other Version"})
      # The header offers the helper only once a version has calendars; an empty
      # version's first-use panel keeps Create calendar as its one action.
      add_calendar(context.organization, other_version, "OTHER_WD", "Other weekdays")

      assert {:error, {:live_redirect, %{to: path}}} =
               render_click(view, "gtfs_version_loaded", %{"version_id" => other_version.id})

      assert path == "/gtfs/#{other_version.id}/calendars"

      assert {:ok, other_view, _html} = live(conn, path)
      refute has_element?(other_view, "#agent-panel")
      assert is_nil(session_pid(other_view))

      other_view |> element("#agent-helper-open") |> render_click()

      assert element(other_view, "#agent-panel") |> render() =~ "Calendars · Other Version"
      refute session_pid(other_view) == pid
    end

    test "a capacity refusal keeps the composer text and adds no entry", context do
      {view, _pid} = open_helper(context)
      fill_turn_capacity()

      submit(view, @first_message)

      html = render(view)
      assert html =~ "The helper is busy. Try again shortly."
      assert has_element?(view, "#agent-composer-input", @first_message)
      refute has_element?(view, "#agent-entry-1")
      assert html =~ "What needs to change?"
    end
  end

  describe "membership changes mid-conversation" do
    test "a deactivated membership between two tool calls ends the conversation", context do
      {view, pid} = open_helper(context)

      expect_reply(1, tool_calls_reply([{"call_1", "list_calendars", "{}"}]))

      expect_reply_deactivating(
        context,
        tool_calls_reply([{"call_2", "get_calendar", @get_calendar_arguments}])
      )

      submit(view, @first_message)

      assert_receive {:agent_event, ^pid,
                      {:entry, %{role: :assistant, status: :forbidden} = entry}},
                     5_000

      assert entry.text == @forbidden_text
      assert_receive {:agent_event, ^pid, {:status, :forbidden}}, 5_000

      html = render(view)
      assert html =~ @forbidden_text
      assert element(view, "#agent-send") |> render() =~ "disabled"
      refute html =~ "agent-prepared-"
    end

    test "an idle expiry ends the conversation and New conversation opens a fresh one", context do
      {view, pid} = open_helper(context)

      expect_reply(1, text_reply("Yes, both school calendars run next Monday."))
      submit(view, @first_message)
      assert await_settled(pid).status == :done

      send(pid, {:idle_timeout, :sys.get_state(pid).idle_token})
      assert_receive {:agent_event, ^pid, {:status, :ended}}, 5_000

      assert render(view) =~ "This conversation ended. Start a new conversation."
      assert element(view, "#agent-send") |> render() =~ "disabled"

      view |> element("#agent-new-conversation") |> render_click()

      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})

      fresh = session_pid(view)
      assert is_pid(fresh)
      refute fresh == pid
      assert render(view) =~ "What needs to change?"

      assert {:ok, ^fresh, _snapshot} = Agents.open(scope(context))
      expect_reply(1, text_reply("A fresh answer."))
      submit(view, "A fresh question")
      assert await_settled(fresh).text == "A fresh answer."
    end

    test "a stale session event or down cannot overwrite the active conversation", context do
      {view, pid} = open_helper(context)

      send(pid, {:idle_timeout, :sys.get_state(pid).idle_token})
      assert_receive {:agent_event, ^pid, {:status, :ended}}, 5_000

      view |> element("#agent-new-conversation") |> render_click()
      active = session_pid(view)
      assert is_pid(active)
      refute active == pid

      stale_entry = %{
        id: 99,
        role: :assistant,
        text: "Stale reply",
        activity: [],
        prepared: nil,
        applied?: false,
        status: :done
      }

      send(view.pid, {:agent_event, pid, {:entry, stale_entry}})
      send(view.pid, {:agent_event, pid, {:status, :forbidden}})
      send(view.pid, {:DOWN, make_ref(), :process, pid, :noproc})

      html = render(view)
      refute html =~ "Stale reply"
      refute html =~ @forbidden_text
      assert html =~ "What needs to change?"
      assert session_pid(view) == active
    end

    test "a dead session refuses a forbidden New conversation and opens no session", context do
      {view, pid} = open_helper(context)

      send(pid, {:idle_timeout, :sys.get_state(pid).idle_token})
      assert_receive {:agent_event, ^pid, {:status, :ended}}, 5_000

      deactivate_membership_fixture(context.membership)

      view |> element("#agent-new-conversation") |> render_click()

      assert element(view, "#agent-send") |> render() =~ "disabled"
      assert render(view) =~ "Your access changed."
      assert is_nil(session_pid(view))
    end
  end

  describe "recovery through the panel" do
    test "Retry resubmits the failed entry's original text, not the latest message", context do
      {view, pid} = open_helper(context)

      expect_response(500, %{"error" => "provider unavailable"})
      submit(view, @first_message)
      assert await_settled(pid).status == :failed
      assert render(view) =~ @unavailable_text
      assert has_element?(view, "#agent-retry-2")

      expect_reply(1, text_reply("A later answer."))
      submit(view, "A later question")
      assert await_settled(pid).text == "A later answer."
      assert_receive {:model_request, _later_request}, 5_000

      expect_reply(1, text_reply("Yes, both school calendars run next Monday."))
      view |> element("#agent-retry-2") |> render_click()

      assert await_settled(pid).text == "Yes, both school calendars run next Monday."
      assert_receive {:model_request, retry_request}, 5_000
      assert last_user_text(retry_request) == @first_message
      assert render(view) =~ @first_message
    end
  end

  ## Helpers

  defp helper_view(context) do
    conn = log_in_user(context.conn, context.user, organization: context.organization)
    assert {:ok, view, _html} = live(conn, "/gtfs/#{context.version.id}/calendars")
    assert has_element?(view, "#agent-helper-open")
    view
  end

  # Opens the panel, then joins the same conversation through the facade as a
  # second listener: the session's own settle events are observable without
  # polling the render or sleeping.
  defp open_helper(context) do
    view = helper_view(context)
    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    pid = session_pid(view)
    assert {:ok, ^pid, _snapshot} = Agents.open(scope(context))

    {view, pid}
  end

  defp scope(context, pack_id \\ "calendars") do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: pack_id,
      version_name: context.version.name
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

  defp last_user_text(request) do
    request["messages"]
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> Map.fetch!("content")
  end

  # Sessions are started under the application's own supervisor and outlive the
  # test socket, so every session this test opened is terminated here.
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

  # The eight turn slots belong to the node, so filling them makes the next send
  # a capacity refusal without any provider request.
  defp fill_turn_capacity do
    pids =
      for _ <- 1..8 do
        {:ok, pid} =
          Task.Supervisor.start_child(TurnSupervisor, fn -> Process.sleep(:infinity) end)

        pid
      end

    on_exit(fn ->
      Enum.each(pids, &Task.Supervisor.terminate_child(TurnSupervisor, &1))
    end)
  end

  defp add_calendar(organization, version, service_id, name) do
    calendar_fixture(organization.id, version.id, @weekdays |> Map.put(:service_id, service_id))

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end

  ## Scripted OpenRouter replies

  defp expect_reply(count, payload) do
    test = self()
    Req.Test.expect(@owner, count, fn conn -> respond(conn, test, payload) end)
  end

  defp expect_response(status, payload) do
    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(payload))
    end)
  end

  # Answers with `payload` after deactivating the membership, so the turn's next
  # authorization check sees the revocation.
  defp expect_reply_deactivating(context, payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      deactivate_membership_fixture(context.membership)
      respond(conn, test, payload)
    end)
  end

  # Holds the model request open, so the working state is observable before the
  # reply arrives.
  defp expect_blocked do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      send(test, {:blocked, self()})

      receive do
        {:release, payload} -> respond(conn, test, payload)
      after
        30_000 -> respond(conn, test, text_reply("The stub gave up waiting."))
      end
    end)
  end

  defp release(stub, payload), do: send(stub, {:release, payload})

  defp respond(conn, test, payload) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test, {:model_request, Jason.decode!(body)})

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
