defmodule GtfsPlanner.Agents.Packs.AlertsPublicationBoundaryTest do
  @moduledoc """
  The alerts conversation is organization-owned and reads the organization's
  active schedule (AC-9, AC-10, AC-26, CL-5, CL-6, CL-13; FH-5, FH-6, FH-13).

  The subject of a conversation is one alert of one organization. The version the
  navbar names is not part of that identity, and the alert's own source version is
  not the schedule its tools read, so this file drives the editor that builds the
  scope, the fence the session uses and the pack's own tools, and proves four
  things:

    * selecting another service version in the navigation leaves the conversation
      and the alert it reads alone, and the session prompt names no service
      version at all;
    * the tools read the active schedule's own natural targets, and an alert whose
      source version was deleted, or an organization with no active schedule,
      keeps a readable draft, refuses every schedule lookup the schedule cannot
      answer and every schedule-validated proposal, and offers no publication
      field to accept;
    * a provider reply that arrives after the alert was deleted, after the
      membership was revoked or after the active schedule moved, including back to
      the same version, is never delivered and never applied;
    * a change the helper prepared and the editor applied is a private save: it
      never accepts anything for publication.

  Only the OpenRouter HTTP boundary is scripted; the editor, the session, the
  turn, `Agents.Dispatch` and every command and authorization check are the real
  ones (INV-5). The editor, the session and the turn task are separate processes,
  so the SQL sandbox and the `Req.Test` plug are shared (`async: false`).
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
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Alerts, as: AlertsPack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Publication
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @source_name "Fall 2026 service"
  @selected_name "Winter 2027 service"
  @note "Route 12 is detouring between Elm and 3rd"
  @no_active "No schedule is active, so there is nothing to search. Name the ids this alert already holds."

  # No answer of this pack may carry a publication field; step 12 owns the
  # explicit public intent and this pack is not where it lives (AC-16, CR-1).
  @publication_keys ~w(publication publish published served served_from publish_now)

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization = organization_fixture()
    source = gtfs_version_fixture(organization.id, %{name: @source_name})
    selected = gtfs_version_fixture(organization.id, %{name: @selected_name})
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    agency_fixture(organization.id, source.id, %{agency_timezone: "America/Los_Angeles"})
    agency_fixture(organization.id, selected.id, %{agency_timezone: "America/Los_Angeles"})

    source_route = route(organization, source, "R12", "Route 12")
    selected_route = route(organization, selected, "R12", "Route 12")

    # Only the selected schedule has Route 99, so a search for it shows which
    # schedule a tool read.
    selected_only_route = route(organization, selected, "R99", "Route 99")

    calendar_fixture(organization.id, source.id)
    calendar_fixture(organization.id, selected.id)

    audit = audit_context(organization, source, actor)
    selected_audit = audit_context(organization, selected, actor)

    track_sessions()

    %{
      organization: organization,
      source: source,
      selected: selected,
      actor: actor,
      membership: membership,
      source_route: source_route,
      selected_route: selected_route,
      selected_only_route: selected_only_route,
      audit: audit,
      selected_audit: selected_audit
    }
  end

  describe "the conversation subject" do
    setup :log_in_editor

    test "is the alert, so the selected version does not open a second conversation", context do
      alert = answered_alert(context)
      scope = scope(context, alert)

      # One conversation about this alert, opened with the scope the editor
      # builds: the organization and the alert, with no service version.
      assert {:ok, pid, _snapshot} = Agents.open(scope)

      {:ok, view, _html} = live(context.conn, assistant_path(alert))

      # The navbar names the other version on this very page, and the editor
      # still attaches to the one conversation this alert owns.
      assert socket_assigns(view).current_gtfs_version.id == context.selected.id
      assert socket_assigns(view).agent_session == pid

      # Reloading the page is what the version switcher does on this path: the
      # selection is recorded and the same URL is requested again. The reader
      # lands on the same alert, in the same conversation, still reading that
      # alert's own source.
      {:ok, reloaded, _html} = live(editor_conn(context), assistant_path(alert))

      assert socket_assigns(reloaded).agent_session == pid

      assert socket_assigns(reloaded).agent_conversation_id ==
               socket_assigns(view).agent_conversation_id

      assert pid in alert_session_pids()
    end

    test "the prompt names no service version and no schedule the pack may not read", context do
      alert = answered_alert(context)

      {:ok, view, _html} = live(context.conn, assistant_path(alert))

      pid = attach(context, alert)

      test = self()

      Req.Test.expect(@owner, 1, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:model_request, Jason.decode!(body)})
        respond(conn, text_reply("Reading the draft."))
      end)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => @note}})

      assert_receive {:model_request, request}, 5_000
      assert_receive {:agent_event, ^pid, {:entry, %{status: :done}}}, 5_000

      system = system_message(request)

      assert system =~ "No service version is selected for this conversation"
      refute system =~ @selected_name
      refute system =~ @source_name
      refute system =~ context.selected.id
      refute system =~ context.source.id
    end
  end

  describe "an alert whose source version was deleted" do
    test "reads the active schedule, which is not the deleted source", context do
      alert = answered_alert(context)

      activate_version!(context.organization, context.selected, context.actor)
      delete_version!(context.source)

      # The retained reference is nulled, not cascaded, and the helper does not need
      # it: its tools read the schedule the organization has selected.
      {:ok, kept} = Alerts.get_alert(context.audit, alert.id)
      assert kept.source_gtfs_version_id == nil

      scope = scope(context, alert)

      assert {:ok, %{"routes" => [%{"id" => "R99"}]}} =
               Dispatch.call(AlertsPack, scope, "search_routes", ~s|{"query":"99"}|)

      assert {:ok, %{"urgency" => "now", "situation" => "detour"}} =
               Dispatch.call(AlertsPack, scope, "get_draft", "{}")
    end
  end

  describe "an organization with no active schedule" do
    test "keeps its draft and refuses every schedule lookup", context do
      alert = answered_alert(context)
      scope = scope(context, alert)

      # The draft reads before the schedule is gone, and keeps reading after it: the
      # alert is the organization's, and its labels simply have nothing to read.
      assert {:ok, %{"urgency" => "now", "situation" => "detour"}} =
               Dispatch.call(AlertsPack, scope, "get_draft", "{}")

      clear_pointer(context)
      scope = scope(context, alert)

      assert {:ok, %{"urgency" => "now", "situation" => "detour"} = draft} =
               Dispatch.call(AlertsPack, scope, "get_draft", "{}")

      assert draft["labels"] == %{"routes" => %{}, "stops" => %{}, "trips" => %{}}

      assert {:ok, %{"complete" => _complete, "outstanding" => _outstanding}} =
               Dispatch.call(AlertsPack, scope, "check_draft", "{}")

      assert Dispatch.call(AlertsPack, scope, "search_routes", ~s|{"query":"12"}|) ==
               {:tool_error, @no_active}

      assert Dispatch.call(AlertsPack, scope, "search_stops", ~s|{"query":"Elm"}|) ==
               {:tool_error, @no_active}

      assert Dispatch.call(
               AlertsPack,
               scope,
               "route_stops",
               Jason.encode!(%{"route_id" => context.source_route.route_id})
             ) == {:tool_error, @no_active}

      assert Dispatch.call(
               AlertsPack,
               scope,
               "departures_on",
               Jason.encode!(%{"route_id" => "R12", "date" => "2026-10-05"})
             ) == {:tool_error, @no_active}

      # The other tools still answer from the alert and the organization.
      assert {:ok, %{"scripts" => _scripts}} =
               Dispatch.call(AlertsPack, scope, "list_scripts", "{}")

      assert {:ok, %{"guidelines" => _text, "revision" => _revision}} =
               Dispatch.call(AlertsPack, scope, "get_guidelines", "{}")
    end

    test "keeps wording and timing but refuses a selection it cannot validate", context do
      alert = answered_alert(context)

      clear_pointer(context)
      scope = scope(context, alert)

      assert {:prepared, %{command: {:alert_changes, wording}}, %{"status" => "prepared"}} =
               Dispatch.call(
                 AlertsPack,
                 scope,
                 "propose_changes",
                 Jason.encode!(%{"message" => %{"header" => "Route 12 detour"}})
               )

      assert wording == %{"message" => %{"header" => "Route 12 detour"}}

      # A changed selection would be validated against a schedule the organization
      # does not have, so it is refused rather than checked against nothing.
      selection =
        Jason.encode!(%{
          "scope" => %{"shape" => "routes", "route_ids" => ["R99"]}
        })

      assert Dispatch.call(AlertsPack, scope, "propose_changes", selection) ==
               {:tool_error, @no_active}
    end

    test "accepts no publication field from any tool or proposal", context do
      alert = answered_alert(context)

      clear_pointer(context)
      scope = scope(context, alert)

      publication_keys = ~w(publication publish published served served_from publish_now)

      for tool <- AlertsPack.tools() do
        assert tool.parameters["type"] == "object"
        assert tool.parameters["additionalProperties"] == false
        declared = tool.parameters["properties"] |> Map.keys()

        refute Enum.any?(declared, &(&1 in @publication_keys)),
               "#{tool.name} declares a publication field"
      end

      # The fence refuses such an argument before the pack sees it, whether or
      # not the organization has a schedule.
      for key <- publication_keys do
        assert {:tool_error, _message} =
                 Dispatch.call(
                   AlertsPack,
                   scope,
                   "propose_changes",
                   Jason.encode!(%{key => true})
                 )
      end
    end
  end

  describe "the active schedule the conversation was opened under" do
    test "a real turn's tool reads the active schedule's natural targets", context do
      alert = answered_alert(context)
      activate_version!(context.organization, context.selected, context.actor)

      pid = attach(context, alert)
      test = self()

      # Reply one asks for Route 99, which only the selected schedule has; reply two
      # carries the tool result back, so the request shows what the tool read.
      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, tool_call_reply("search_routes", %{"query" => "99"}))
      end)

      Req.Test.expect(@owner, 1, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:second_request, Jason.decode!(body)})
        respond(conn, text_reply("Route 99 is in the active schedule."))
      end)

      assert :ok = Agents.send_message(pid, @note)

      assert_receive {:second_request, request}, 5_000
      assert_receive {:agent_event, ^pid, {:entry, %{status: :done}}}, 5_000

      tool_message = Enum.find(request["messages"], &(&1["role"] == "tool"))

      assert %{"routes" => [%{"id" => "R99", "route_id" => "R99"}]} =
               Jason.decode!(tool_message["content"])
    end

    test "a reply that arrives after the schedule went A to B to A is never delivered",
         context do
      alert = answered_alert(context)
      pid = attach(context, alert)
      ref = Process.monitor(pid)
      opened_under = scope(context, alert).alert_schedule_token

      park_next_provider_request()
      assert :ok = Agents.send_message(pid, @note)
      assert_receive {:blocked, stub}, 5_000

      activate_version!(context.organization, context.selected, context.actor)
      returned = activate_version!(context.organization, context.source, context.actor)

      # Back on the schedule the conversation was opened on, under a later token.
      assert returned.version.id == context.source.id
      assert returned.token.revision > opened_under.revision

      send(stub, {:release, tool_call_reply("propose_changes", %{"urgency" => "planned"})})

      assert_receive {:agent_event, ^pid, {:entry, %{status: :unavailable, prepared: nil}}}, 5_000
      assert_receive {:agent_event, ^pid, {:status, :unavailable}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      assert {:ok, untouched} = Alerts.get_alert(context.audit, alert.id)
      assert untouched.revision == alert.revision
      assert untouched.urgency == :now
    end
  end

  describe "a change the helper prepared" do
    setup :log_in_editor

    test "is a private save that accepts nothing for publication", context do
      alert = accepted_alert(context)
      before = publication_row(alert)

      assert before.desired_revision == alert.revision

      {:ok, view, _html} = live(context.conn, assistant_path(alert))
      pid = attach(context, alert)

      Req.Test.expect(@owner, 1, fn conn ->
        respond(
          conn,
          tool_call_reply("propose_changes", %{"message" => %{"header" => "Route 12 reroute"}})
        )
      end)

      Req.Test.expect(@owner, 1, fn conn -> respond(conn, text_reply("I prepared it.")) end)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => @note}})

      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000

      # The row moved on, the accepted snapshot did not: auto-apply is the private
      # save, and the explicit publish command the review's checkbox calls is the
      # only path to a new accepted revision.
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.revision == alert.revision + 1
      assert saved.message.header == "Route 12 reroute"

      assert publication_row(alert) == before

      assert {:ok, %{publication: publication}} =
               Alerts.save_review(
                 context.audit,
                 alert.id,
                 saved.revision,
                 %{},
                 publish?: true,
                 expected_schedule: current_token!(context.audit)
               )

      assert publication in [:pending, :scheduled]
      assert publication_row(alert).desired_revision == saved.revision
    end
  end

  describe "access withdrawn while the provider is answering" do
    test "a reply that arrives after the alert was deleted is never delivered", context do
      alert = answered_alert(context)
      pid = attach(context, alert)
      ref = Process.monitor(pid)

      park_next_provider_request()
      assert :ok = Agents.send_message(pid, @note)
      assert_receive {:blocked, stub}, 5_000

      Repo.delete!(alert)

      send(stub, {:release, tool_call_reply("propose_changes", %{"urgency" => "planned"})})

      assert_receive {:agent_event, ^pid, {:entry, %{status: :unavailable, prepared: nil}}}, 5_000
      assert_receive {:agent_event, ^pid, {:status, :unavailable}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      # Nothing the reply carried was applied: the conversation is gone, so there
      # is no proposal left to hand to a host.
      assert Agents.prepared(pid, Ecto.UUID.generate(), 2) == :error
      assert Repo.aggregate(Alert, :count) == 0
    end

    test "a reply that arrives after the membership was revoked is never delivered", context do
      alert = answered_alert(context)
      pid = attach(context, alert)
      ref = Process.monitor(pid)

      park_next_provider_request()
      assert :ok = Agents.send_message(pid, @note)
      assert_receive {:blocked, stub}, 5_000

      revoke(context.membership)

      send(stub, {:release, tool_call_reply("propose_changes", %{"urgency" => "planned"})})

      assert_receive {:agent_event, ^pid, {:entry, %{status: :forbidden, prepared: nil}}}, 5_000
      assert_receive {:agent_event, ^pid, {:status, :forbidden}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      # The alert itself is untouched: a revoked member's proposal is never
      # applied, so the row keeps the revision it already had. It is read back by
      # an editor who is still a member, because the revoked one is not.
      reader = user_fixture()
      organization_membership_fixture(reader, context.organization)

      assert {:ok, untouched} =
               Alerts.get_alert(
                 audit_context(context.organization, context.source, reader),
                 alert.id
               )

      assert untouched.revision == alert.revision
      assert untouched.urgency == :now
    end
  end

  ## Helpers

  # An alert with answers, written through the real command with its own source
  # version, so the retained reference and the stored labels are real.
  defp answered_alert(context) do
    alert = alert_fixture(context.audit, %{"urgency" => "now"})

    {:ok, saved} =
      Alerts.save_draft(
        context.audit,
        alert.id,
        alert.revision,
        %{
          "situation" => "detour",
          "scope" => %{
            "shape" => "routes",
            "route_ids" => [context.source_route.route_id]
          },
          "message" => %{"header" => "Route 12 detour"}
        },
        schedule_opts(context.audit)
      )

    saved
  end

  # A complete alert, accepted for publication through the explicit command the
  # review's checkbox calls, so its accepted snapshot exists before a helper edits it.
  defp accepted_alert(context) do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "now",
        "situation" => "delay",
        "cause" => "construction",
        "scope" => %{"shape" => "routes", "route_ids" => [context.source_route.route_id]},
        "timing" => %{
          "start_date" => "2026-10-05",
          "start_time" => "08:00:00",
          "end_kind" => "confirmed",
          "end_date" => "2026-10-06",
          "end_time" => "20:00:00"
        },
        "message" => %{
          "header" => "Route 12 buses delayed",
          "description" => "Construction on Main St. Use Route 2 instead."
        }
      })

    assert {:ok, %{alert: accepted, publication: state}} =
             Alerts.save_review(
               context.audit,
               alert.id,
               alert.revision,
               %{},
               publish?: true,
               expected_schedule: current_token!(context.audit)
             )

    assert state in [:pending, :scheduled]
    accepted
  end

  defp publication_row(alert), do: Repo.get_by(Publication, alert_id: alert.id)

  # The organization has no active schedule: the pointer is cleared the way a test
  # models a legacy nil selection, keeping the revision the token carries.
  defp clear_pointer(context) do
    Repo.update_all(
      from(o in Organization, where: o.id == ^context.organization.id),
      set: [active_gtfs_version_id: nil]
    )
  end

  # The scope the alerts editor's panel builds: bound to the organization, the
  # alert and the selection token it is opened under, and to no service version at
  # all.
  defp scope(context, alert) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: nil,
      user_id: context.actor.id,
      user_email: context.actor.email,
      pack_id: "alerts",
      version_name: nil,
      subject_id: alert.id,
      alert_schedule_token: current_token!(context.audit),
      resource_context: Scope.context(nil)
    }
  end

  defp log_in_editor(context), do: %{conn: editor_conn(context)}

  defp editor_conn(context) do
    log_in_user(build_conn(), context.actor, organization: context.organization)
  end

  defp assistant_path(alert), do: "/alerts/#{alert.id}?mode=assistant"

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Opening the scope again attaches this process to the same conversation the
  # editor opened, so the test observes the events the panel renders.
  defp attach(context, alert) do
    assert {:ok, pid, _snapshot} = Agents.open(scope(context, alert))
    pid
  end

  defp revoke(membership), do: deactivate_membership_fixture(membership)

  # The GTFS rows and then the version itself, exactly as step 7's own test
  # deletes a source version: a route, a stop and an agency reference the
  # version with a plain foreign key, so the schedule rows go first.
  defp delete_version!(version) do
    # Every child row that names the version must go first: calendars carry a
    # `calendars_version_owner_fkey` to `gtfs_versions`, so a version whose
    # agency/route/stop rows are gone but whose calendar rows remain cannot be
    # deleted. `service_alerts` is deliberately absent - its source-version key
    # is `ON DELETE SET NULL`, which is the retained provenance this suite proves.
    for schema <- [
          GtfsPlanner.Gtfs.Route,
          GtfsPlanner.Gtfs.Stop,
          GtfsPlanner.Gtfs.Agency,
          GtfsPlanner.Gtfs.Calendar
        ] do
      Repo.delete_all(from(row in schema, where: row.gtfs_version_id == ^version.id))
    end

    Repo.get!(GtfsPlanner.Versions.GtfsVersion, version.id) |> Repo.delete!()
  end

  defp alert_session_pids do
    SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.sort()
  end

  defp track_sessions do
    before = alert_session_pids()

    on_exit(fn ->
      for pid <- alert_session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end
    end)
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp route(organization, version, route_id, short_name) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: short_name,
      route_long_name: "Coast Highway",
      route_type: 3
    })
  end

  defp system_message(request) do
    request["messages"]
    |> Enum.find(&(&1["role"] == "system"))
    |> Map.fetch!("content")
  end

  # Parks the next provider request until this test releases it, so the deletion
  # and the revocation below are committed before the answer is read back. It only
  # registers the expectation: the request itself is made by
  # `Agents.send_message/2`, so the caller must trigger it first and then wait for
  # `{:blocked, pid}` before it can `send(pid, {:release, payload})`.
  defp park_next_provider_request do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(test, {:blocked, self()})

      receive do
        {:release, payload} -> send_json(conn, payload)
      after
        30_000 -> send_json(conn, text_reply("The stub gave up waiting."))
      end
    end)
  end

  defp text_reply(text), do: reply("stop", %{"content" => text})

  defp tool_call_reply(name, arguments) do
    reply(
      "tool_calls",
      %{
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
          }
        ]
      }
    )
  end

  defp reply(finish_reason, message) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => finish_reason, "message" => message}],
      "usage" => %{"cost" => 0.0}
    }
  end

  defp respond(conn, payload), do: send_json(conn, payload)

  defp send_json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end
end
