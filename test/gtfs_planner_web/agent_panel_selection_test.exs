defmodule GtfsPlannerWeb.AgentPanelSelectionTest do
  @moduledoc """
  The host-owned helper selection `GtfsPlannerWeb.AgentPanel` grew for EV-3.

  A host names the whole set of helpers it offers once, at mount, and switches
  between them with `AgentPanel.select_pack/3`. The cases are the ones the step's
  execution card names:

    * mounting once and switching helpers copies the new pack's own copy,
      detaches only this panel, keeps the native form's value, and never attaches
      a second set of hooks or stream configuration;
    * a selection the host never allowed, a selection of a pack the application
      does not ship, and re-selecting the pack and context already held are
      refused or are a no-op, and none of them touches the running conversation,
      its transcript or the page's own input;
    * two tabs on one conversation, where switching in one tab leaves the other
      tab's conversation and results alone, and a late event or down from the
      session this panel left changes nothing in the panel that switched.

  The host is the shipped panel, the shipped components, the shipped session
  registry and the packs the application registers; only the final OpenRouter
  HTTP boundary is scripted (INV-5). The Calendars page — a real production host
  — mounts the panel through `mount/2` and covers the single-helper case,
  including the native approval input a helper selection must not consume.

  The card names `service_queries` → `connections` for the switch. `connections`
  is registered by a later step of this package, so the switch here runs between
  the two helpers this application ships today; the panel contract, the hooks it
  attaches and the allowlist it enforces are the same either way.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Packs.ServiceQueries
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.TurnSupervisor
  alias GtfsPlannerWeb.AgentPanel

  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  # A pack the application does not ship at all. `in_seat` stopped being one in
  # step 11, so this name stays outside the registry for the whole branch.
  @forged_pack "blocking"
  @approval_text "Extend the weekday calendar through the fall term."

  # A host in the shape step 8's Schedule host takes: it names its whole set of
  # helpers once at mount, renders one control per allowed helper, and hands the
  # chosen id to `AgentPanel.select_pack/3` with a context it owns. Everything
  # below the host — the panel, its hooks and entries stream, the components, the
  # session registry and the packs — is the shipped code. It binds one route's
  # Schedules, as `RouteSchedulesLive` does, because the Schedule pack is
  # route-bound: a whole-version context would be refused by the pack itself.
  defmodule SelectionHostLive do
    use Phoenix.LiveView

    import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

    alias GtfsPlanner.Agents.Scope
    alias GtfsPlanner.Repo
    alias GtfsPlannerWeb.AgentPanel

    @allowed_packs ["service_queries", "calendars"]

    def mount(_params, session, socket) do
      organization =
        Repo.get!(GtfsPlanner.Organizations.Organization, session["organization_id"])

      version = Repo.get!(GtfsPlanner.Versions.GtfsVersion, session["version_id"])

      {:ok,
       socket
       |> Phoenix.Component.assign(:current_organization, organization)
       |> Phoenix.Component.assign(:current_gtfs_version, version)
       |> Phoenix.Component.assign(
         :current_user,
         Repo.get!(GtfsPlanner.Accounts.User, session["user_id"])
       )
       |> Phoenix.Component.assign(:route_id, session["route_id"])
       |> Phoenix.Component.assign(:note, "")
       |> AgentPanel.mount("service_queries", allowed_packs: @allowed_packs)
       |> AgentPanel.set_context(Scope.context({:route, session["route_id"]}))}
    end

    def handle_event("note_changed", %{"note" => note}, socket) do
      {:noreply, Phoenix.Component.assign(socket, :note, note)}
    end

    # The helper a person picked. The host owns the context and passes the pack
    # id through unchanged, so the panel's stored allowlist is what decides.
    def handle_event("select_helper", %{"pack" => pack_id}, socket) do
      {:noreply,
       AgentPanel.select_pack(socket, pack_id, Scope.context({:route, socket.assigns.route_id}))}
    end

    def handle_event(_event, _params, socket), do: {:noreply, socket}

    def render(assigns) do
      ~H"""
      <div>
        <form id="native-note-form" phx-change="note_changed">
          <input type="text" name="note" value={@note} />
        </form>

        <button id="agent-helper-open" type="button" phx-click="agent_open">Open helper</button>

        <button
          :for={pack_id <- @agent_allowed_packs}
          id={"select-helper-#{pack_id}"}
          type="button"
          phx-click="select_helper"
          phx-value-pack={pack_id}
        >
          Use {pack_id}
        </button>

        <.agent_panel
          :if={@agent_open?}
          id="agent-panel"
          title={@agent_title}
          intro={@agent_intro}
          examples={@agent_examples}
          scope_line="Selection host"
          status={@agent_status}
          entries={@streams.agent_entries}
          form={@agent_form}
          notice={@agent_notice}
          entries_empty?={@agent_entries_empty?}
          composer_hint="Answers only. Nothing on this page changes."
        />
      </div>
      """
    end
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and
    # the SQL sandbox must both be shared.
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()

    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Selection Version"})

    add_calendar(organization, version, "SCHOOL_WD", "School weekdays")

    route = route_fixture(organization.id, version.id, %{route_id: "SEL1"})

    track_sessions()

    %{
      organization: organization,
      user: user,
      version: version,
      route: route,
      host_session: %{
        "organization_id" => organization.id,
        "version_id" => version.id,
        "user_id" => user.id,
        "route_id" => route.id
      }
    }
  end

  describe "switching helpers on a host that offers two" do
    test "one mount and one hook set: switching copies the new pack and keeps the native form",
         context do
      view = mount_host(context)

      assert panel_assigns(view).agent_allowed_packs == ["service_queries", "calendars"]
      assert panel_assigns(view).agent_title == ServiceQueries.title()

      # The person typed into the page's own form before switching helpers.
      render_change(view, "note_changed", %{"note" => "Keep this note"})

      open_panel(view)
      first = observe(context, view, "service_queries")

      expect_reply(text_reply("The first helper answered."))
      send_message(view, "What runs on Tuesday?")

      assert await_settled(first).text == "The first helper answered."
      assert has_element?(view, "#agent-entry-2")

      mounted_hooks = hook_ids(view)
      assert mounted_hooks[:handle_event] == [:agent_panel_events]
      assert mounted_hooks[:handle_info] == [:agent_panel_info]

      # The host's own control selects the other helper it allows.
      render_click(view, "select_helper", %{"pack" => "calendars"})

      assert panel_assigns(view).agent_pack_id == "calendars"
      assert panel_assigns(view).agent_title == Calendars.title()
      assert panel_assigns(view).agent_intro == Calendars.intro()
      assert panel_assigns(view).agent_examples == Calendars.examples()

      # This panel's transcript is gone and it holds a different conversation,
      # while the session it left keeps running.
      refute has_element?(view, "#agent-entry-2")
      assert has_element?(view, "#agent-first-conversation")
      assert session_pid(view) != first
      assert Process.alive?(first)

      # Switching never remounts: the same hooks, each attached once.
      assert hook_ids(view) == mounted_hooks

      # The page's own input is exactly where the person left it.
      assert view |> element("#native-note-form") |> render() =~ "Keep this note"

      # The new conversation is the one the registry holds for this pack.
      assert {:ok, second, _snapshot} =
               Agents.open(host_scope(panel_assigns(view), "calendars"))

      assert second == session_pid(view)
      Agents.detach(second)
    end

    test "a helper this host never allowed changes nothing", context do
      view = mount_host(context)
      open_panel(view)

      render_change(view, "note_changed", %{"note" => "Keep this note"})

      session = observe(context, view, "service_queries")

      expect_reply(text_reply("An answer that must survive a refused selection."))
      send_message(view, "What runs on Tuesday?")

      assert await_settled(session).text == "An answer that must survive a refused selection."

      # A pack outside the host's set, and a pack the application does not ship
      # at all, are the same refusal.
      for forged <- ["unknown_helper", @forged_pack] do
        render_click(view, "select_helper", %{"pack" => forged})

        assert has_element?(view, "#agent-notice", "This helper is not available on this page.")
        assert panel_assigns(view).agent_pack_id == "service_queries"
        assert panel_assigns(view).agent_title == ServiceQueries.title()
        assert session_pid(view) == session
        assert has_element?(view, "#agent-entry-2")
      end

      assert view |> element("#native-note-form") |> render() =~ "Keep this note"
    end

    test "re-selecting the helper and context already held restarts nothing", context do
      view = mount_host(context)
      open_panel(view)

      session = observe(context, view, "service_queries")
      conversation = panel_assigns(view).agent_conversation_id

      expect_reply(text_reply("An answer that must survive the same selection."))
      send_message(view, "What runs on Tuesday?")

      assert await_settled(session).text == "An answer that must survive the same selection."

      render_click(view, "select_helper", %{"pack" => "service_queries"})

      assert session_pid(view) == session
      assert panel_assigns(view).agent_conversation_id == conversation
      assert panel_assigns(view).agent_title == ServiceQueries.title()
      assert has_element?(view, "#agent-entry-2")
    end
  end

  describe "two tabs on one conversation" do
    test "switching one tab detaches only that panel; the other tab keeps its result",
         context do
      view = mount_host(context)
      second_tab = mount_host(context)

      open_panel(view)
      open_panel(second_tab)

      shared = observe(context, view, "service_queries")
      assert session_pid(second_tab) == shared

      expect_reply(text_reply("An answer for both tabs."))
      send_message(view, "What runs on Tuesday?")

      assert await_settled(shared).text == "An answer for both tabs."
      assert has_element?(view, "#agent-entry-2")
      assert has_element?(second_tab, "#agent-entry-2")

      render_click(view, "select_helper", %{"pack" => "calendars"})

      assert session_pid(view) != shared
      assert session_pid(second_tab) == shared
      assert Process.alive?(shared)

      # The tab that stayed still receives the conversation's next result.
      expect_reply(text_reply("A later answer for the tab that stayed."))
      send_message(second_tab, "And on Wednesday?")

      assert await_settled(shared).text == "A later answer for the tab that stayed."
      assert has_element?(second_tab, "#agent-entry-4")

      # A late entry and a late down from the session this panel left cannot
      # restore its transcript.
      send(view.pid, {:agent_event, shared, {:entry, entry(9, "A late answer.")}})
      send(view.pid, {:DOWN, make_ref(), :process, shared, :normal})
      render(view)

      refute render(view) =~ "A late answer."
      assert session_pid(view) != shared
      assert panel_assigns(view).agent_pack_id == "calendars"
    end
  end

  describe "a host that names one helper" do
    test "the single-helper delegate stores only that helper and refuses a forged selection",
         context do
      conn = log_in_user(context.conn, context.user, organization: context.organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{context.version.id}/calendars")

      assert panel_assigns(view).agent_pack_id == "calendars"
      assert panel_assigns(view).agent_allowed_packs == ["calendars"]

      # The editor's own approval is on the page before and after the refusal.
      view
      |> element("#calendar-extension-form")
      |> render_submit(%{
        "extension" => %{
          "service_id" => "SCHOOL_WD",
          "end_date" => "2027-01-30",
          "approval_text" => @approval_text
        }
      })

      assert render(view) =~ @approval_text

      select_pack(view, "service_queries", Scope.context({:version, context.version.id}))

      assert panel_assigns(view).agent_pack_id == "calendars"
      assert has_element?(view, "#calendar-extension-approve")
      assert render(view) =~ @approval_text
    end

    test "a host naming a helper the application does not ship fails the mount", context do
      socket = %Phoenix.LiveView.Socket{assigns: %{current_gtfs_version: context.version}}

      # Every shipped pack but one is named by some host, so a pack the
      # application does not ship is one no host names either.
      assert_raise ArgumentError, ~r/does not ship/, fn ->
        AgentPanel.mount(socket, @forged_pack, allowed_packs: [@forged_pack])
      end

      assert_raise ArgumentError, ~r/does not ship/, fn ->
        AgentPanel.mount(socket, "calendars", allowed_packs: ["calendars", @forged_pack])
      end

      assert_raise ArgumentError, ~r/must be one of the packs this host allows/, fn ->
        AgentPanel.mount(socket, "calendars", allowed_packs: ["service_queries"])
      end

      assert_raise ArgumentError, ~r/allowed_packs must be a list/, fn ->
        AgentPanel.mount(socket, "calendars", allowed_packs: "calendars")
      end
    end
  end

  ## Helpers

  defp mount_host(context) do
    {:ok, view, _html} =
      live_isolated(context.conn, SelectionHostLive, session: context.host_session)

    view
  end

  defp open_panel(view), do: render_click(view, "agent_open", %{})

  # The test process joins the conversation as a second listener, so the
  # session's own settle events are observable without polling the render.
  defp observe(_context, view, pack_id) do
    assert {:ok, pid, _snapshot} = Agents.open(host_scope(view_context(view), pack_id))
    assert pid == session_pid(view)
    pid
  end

  defp send_message(view, text) do
    view |> element("#agent-composer") |> render_submit(%{"agent" => %{"message" => text}})
  end

  # The host's own production call, run against this page's mounted socket. The
  # panel function is the shipped one, so the selection this performs is the one
  # a host performs when its own control names another helper.
  defp select_pack(view, pack_id, context) do
    :sys.replace_state(view.pid, fn state ->
      %{state | socket: AgentPanel.select_pack(state.socket, pack_id, context)}
    end)

    _ = :sys.get_state(view.pid)
    :ok
  end

  defp panel_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp session_pid(view), do: panel_assigns(view).agent_session

  defp view_context(view), do: panel_assigns(view)

  defp host_scope(assigns, pack_id) do
    %Scope{
      organization_id: assigns.current_organization.id,
      gtfs_version_id: assigns.current_gtfs_version.id,
      user_id: assigns.current_user.id,
      user_email: assigns.current_user.email,
      pack_id: pack_id,
      version_name: assigns.current_gtfs_version.name,
      resource_context: Scope.context({:route, assigns.route_id})
    }
  end

  # The lifecycle hooks this LiveView holds, by stage. LiveView attaches each
  # hook once and refuses a second hook with the same id, so this is how a test
  # sees a panel that was mounted twice rather than switched.
  defp hook_ids(view) do
    lifecycle = :sys.get_state(view.pid).socket.private[:lifecycle]

    Map.new([:handle_event, :handle_info], fn stage ->
      {stage, Enum.map(Map.fetch!(lifecycle, stage), & &1.id)}
    end)
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working, do: await_settled(pid), else: entry
  end

  defp entry(id, text) do
    %{
      id: id,
      role: :assistant,
      text: text,
      activity: [],
      prepared: nil,
      evidence: [],
      applied?: false,
      status: :done
    }
  end

  defp add_calendar(organization, version, service_id, name) do
    weekdays = %{
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    }

    calendar_fixture(organization.id, version.id, Map.put(weekdays, :service_id, service_id))

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(TurnSupervisor)) do
      start_supervised!({Task.Supervisor, name: TurnSupervisor, max_children: 8})
    end
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

  defp expect_reply(payload, count \\ 1) do
    test = self()
    Req.Test.expect(@owner, count, fn conn -> respond(conn, test, payload) end)
  end

  defp respond(conn, test, payload) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test, {:model_request, Jason.decode!(body)})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp text_reply(text, cost \\ 0.0) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => text}}],
      "usage" => %{"cost" => cost}
    }
  end
end
