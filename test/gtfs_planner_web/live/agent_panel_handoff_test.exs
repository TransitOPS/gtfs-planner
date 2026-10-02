defmodule GtfsPlannerWeb.AgentPanelHandoffTest do
  @moduledoc """
  The panel's handoff of a settled prepared change to its host (EV-24).

  A host that opts into `auto_apply: true` is told once per prepared entry, and a
  host that does not — the Calendar page — is told nothing and keeps its own
  review (INV-3). The panel, the session, the turn and the prepared change are
  production code driven through a real session; only the OpenRouter HTTP boundary
  is scripted, so the SQL sandbox and the `Req.Test` plug are shared
  (`async: false`).

  The host that opts in is `GtfsPlannerWeb.AgentPanelHostLive`, which only
  records what the panel hands it, so these tests do not depend on how the
  alerts editor applies a change. The echo pack the card offers cannot reach
  this path: `Agents.packs/0` is production configuration and does not register
  it, so a session opened by the panel is a real `"calendars"` conversation.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.AgentPanelHostLive

  @test_pid_key :agent_panel_handoff_test_pid

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @model_owner GtfsPlanner.Agents.Model
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

  @stop_arguments ~s({"dates":["2026-10-05","2026-10-06"],"stop":["SCHOOL_WD"],"run":[]})

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()
    Application.put_env(:gtfs_planner, @test_pid_key, self())
    on_exit(fn -> Application.delete_env(:gtfs_planner, @test_pid_key) end)

    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Handoff Host Version"})

    add_calendar(organization, version, "SCHOOL_WD", "School weekdays")

    track_sessions()

    %{organization: organization, user: user, version: version}
  end

  describe "the handoff to an auto-applying host" do
    test "a settled prepared entry is handed over exactly once", context do
      {view, _html} = mount_host(context, auto_apply: true)
      view |> element("#host-open") |> render_click()

      assert socket_assigns(view).agent_open?
      session = socket_assigns(view).agent_session
      assert is_pid(session)

      # The session sends its events only to attached listeners, so the test
      # attaches to the conversation the panel holds.
      assert {:ok, ^session, _snapshot} = Agents.open(scope(context, nil))

      {view, session, entry} = prepare_stop_change(view, session)

      conversation_id = socket_assigns(view).agent_conversation_id

      assert_receive {:host_received_prepared, ^conversation_id, 2}, 5_000
      refute_receive {:host_received_prepared, _conversation_id, _entry_id}, 200

      # The session re-broadcasts an entry whenever its state changes, so the same
      # settled entry arriving again must not become a second handoff.
      send(view.pid, {:agent_event, session, {:entry, entry}})
      _ = :sys.get_state(view.pid)

      refute_receive {:host_received_prepared, _conversation_id, _entry_id}, 200
      assert socket_assigns(view).received_prepared == [2]
    end

    test "an entry from a session this panel no longer owns is not handed over", context do
      {view, _html} = mount_host(context, auto_apply: true)
      view |> element("#host-open") |> render_click()

      session = socket_assigns(view).agent_session
      assert {:ok, ^session, _snapshot} = Agents.open(scope(context, nil))

      {view, session, entry} = prepare_stop_change(view, session)

      assert_receive {:host_received_prepared, _conversation_id, 2}, 5_000

      # A second conversation for another subject is a real session, and its
      # events are not this panel's. The entry id is one the panel has never
      # forwarded, so only the session check can stop it.
      {:ok, other_session, _snapshot} = Agents.open(scope(context, Ecto.UUID.generate()))
      assert other_session != session

      send(view.pid, {:agent_event, other_session, {:entry, %{entry | id: 99}}})
      _ = :sys.get_state(view.pid)

      refute_receive {:host_received_prepared, _conversation_id, _entry_id}, 200
      assert socket_assigns(view).received_prepared == [2]
    end

    test "a new conversation hands over its own first prepared entry", context do
      {view, _html} = mount_host(context, auto_apply: true)
      view |> element("#host-open") |> render_click()

      session = socket_assigns(view).agent_session
      assert {:ok, ^session, _snapshot} = Agents.open(scope(context, nil))

      {view, session, _entry} = prepare_stop_change(view, session)
      first_conversation_id = socket_assigns(view).agent_conversation_id
      assert_receive {:host_received_prepared, ^first_conversation_id, 2}, 5_000

      # The new conversation numbers its entries from one again, so its first
      # prepared entry is entry 2 once more and must not be taken for the one
      # already handed over.
      render_click(view, "agent_new", %{})
      assert_receive {:agent_event, ^session, {:reset, second_conversation_id}}, 5_000
      assert second_conversation_id != first_conversation_id
      flush_agent_events(session)

      {view, _session, _entry} = prepare_stop_change(view, session)

      assert_receive {:host_received_prepared, ^second_conversation_id, 2}, 5_000
      assert socket_assigns(view).received_prepared == [2, 2]
    end
  end

  describe "a host that does not opt in" do
    test "the Calendar page keeps its own review and is told nothing", context do
      conn = log_in_user(context.conn, context.user, organization: context.organization)
      assert {:ok, view, _html} = live(conn, "/gtfs/#{context.version.id}/calendars")

      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")

      session = socket_assigns(view).agent_session
      assert {:ok, ^session, _snapshot} = Agents.open(scope(context, nil))

      {view, _session, _entry} = prepare_stop_change(view, session)

      assert has_element?(view, "#agent-review-prepared-2")
      assert scoped_date_count(context) == 0

      # The panel never opted in, so it forwarded nothing to the page.
      assigns = socket_assigns(view)
      refute assigns.agent_auto_apply?
      assert assigns.agent_forwarded == MapSet.new()
    end
  end

  describe "open/1" do
    test "a host opens the same conversation the open button does, for its subject", context do
      alert = alert_fixture(audit_context(context))
      {view, _html} = mount_host(context, auto_apply: true, subject_id: alert.id)

      refute has_element?(view, "#agent-panel")

      view |> element("#host-open-button") |> render_click()
      assert has_element?(view, "#agent-panel")
      button_session = socket_assigns(view).agent_session
      assert is_pid(button_session)

      view |> element("#host-open") |> render_click()
      assigns = socket_assigns(view)
      assert assigns.agent_open?
      assert assigns.agent_session == button_session
      assert assigns.agent_subject_id == alert.id

      # The panel attached to the conversation keyed by the alert, and to no other.
      assert {:ok, ^button_session, _snapshot} = Agents.open(scope(context, alert.id))
      assert {:ok, subjectless_session, _snapshot} = Agents.open(scope(context, nil))
      assert subjectless_session != button_session
    end
  end

  ## Helpers

  defp mount_host(context, opts) do
    session = %{
      "organization_id" => context.organization.id,
      "gtfs_version_id" => context.version.id,
      "user_id" => context.user.id,
      "auto_apply" => to_string(Keyword.get(opts, :auto_apply, false)),
      "subject_id" => Keyword.get(opts, :subject_id)
    }

    {:ok, view, html} = live_isolated(context.conn, AgentPanelHostLive, session: session)
    {view, html}
  end

  # Scripts the deterministic prepare turn: one model reply calls
  # `prepare_date_change`, the second settles the turn.
  defp prepare_stop_change(view, session) do
    Req.Test.expect(@model_owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_1", "prepare_date_change", @stop_arguments}]))
    end)

    Req.Test.expect(@model_owner, 1, fn conn ->
      respond(conn, text_reply("I prepared the change. Review it before applying."))
    end)

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "No school service on October 5 and 6, 2026."}})

    assert_receive {:agent_event, ^session, {:entry, %{status: :working}}}, 5_000

    assert_receive {:agent_event, ^session, {:entry, %{prepared: %{} = prepared} = entry}},
                   5_000

    assert prepared.command == {:date_change, [~D[2026-10-05], ~D[2026-10-06]], ["SCHOOL_WD"], []}

    {view, session, entry}
  end

  defp scope(context, subject_id) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "calendars",
      version_name: context.version.name,
      subject_id: subject_id,
      # The host binds the whole version as the conversation's page.
      resource_context: Scope.context({:version, context.version.id})
    }
  end

  defp audit_context(context) do
    %AuditContext{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      station_stop_id: nil,
      actor_id: context.user.id,
      actor_email: context.user.email
    }
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Drops the events of the conversation that just ended, so the next
  # assertion waits for the new conversation's own.
  defp flush_agent_events(session) do
    receive do
      {:agent_event, ^session, _event} -> flush_agent_events(session)
    after
      0 -> :ok
    end
  end

  defp add_calendar(organization, version, service_id, name) do
    calendar_fixture(organization.id, version.id, @weekdays |> Map.put(:service_id, service_id))

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end

  defp scoped_date_count(%{organization: organization, version: version}) do
    Repo.aggregate(
      from(cd in CalendarDate,
        where: cd.organization_id == ^organization.id,
        where: cd.gtfs_version_id == ^version.id
      ),
      :count
    )
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

  ## Scripted OpenRouter replies

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
