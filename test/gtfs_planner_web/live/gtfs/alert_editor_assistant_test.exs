defmodule GtfsPlannerWeb.Gtfs.AlertEditorAssistantTest do
  @moduledoc """
  Step 27: the assistant interview fills the same draft the form edits
  (AC-28, CL-28, EV-26).

  The editor, the conversation session and the turn task are separate processes,
  so the SQL sandbox and the `Req.Test` plug are shared (`async: false`) and only
  the OpenRouter HTTP boundary is scripted (INV-5). Every expectation is a
  literal from the specification, the prototype's own scenarios and this
  fixture's route and stops; nothing here recomputes an expectation with the
  module under test.

  The alert is written only through `Alerts.create_alert/2` and
  `Alerts.save_draft/4`, which is the property the whole file is about: the
  assistant prepares, this editor writes (INV-1, CR-6).
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  # The note from the prototype's own first scenario, shortened to the sentence
  # the start card asks for.
  @note "Route 12 detour, crash on SW 9th"
  @sample "Route 12 is detouring between Elm and 3rd"
  @draft_request "Draft the rider message from the answers so far."
  @header "Route 12 detour on SW 9th St"
  @description "Route 12 buses are detoured after a crash on SW 9th St. Board at SW 10th & Abbey."
  @prepared_text "The draft is ready to check."
  @interview_text "Tell me when service should recover, or that it is still unknown."
  @unavailable "The assistant is unavailable right now."

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    actor = editor_fixture(organization)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})

    [skipped, boarding] =
      stops(organization, version, [
        {"S9", "SW 9th St"},
        {"S10", "SW 10th & Abbey"}
      ])

    route = route(organization, version, skipped, boarding)

    track_sessions()

    %{
      organization: organization,
      version: version,
      actor: actor,
      route: route,
      skipped: skipped,
      boarding: boarding,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the start card on /alerts/new" do
    setup :log_in_editor

    test "it asks for the situation and writes nothing until it is sent", context do
      {:ok, view, _html} = live(context.conn, new_assistant_path())

      assert has_element?(view, "#alert-assistant")
      assert has_element?(view, "#alert-assistant-start-title", "Describe the situation")

      # "Saving", not "publishing": nothing in this package publishes.
      assert has_element?(
               view,
               "#alert-assistant-start-subtitle",
               "You check it before saving."
             )

      assert has_element?(view, "#alert-assistant-start-intro", "tell me what happened")
      assert has_element?(view, "#alert-assistant-note")
      assert has_element?(view, "#alert-assistant-send", "Send note")

      # There is no draft and no conversation yet, so nothing is rendered but the
      # card (AC-15, FH-15).
      refute has_element?(view, "#alert-assistant-panel")
      assert Repo.aggregate(Alert, :count) == 0
    end

    test "a sample situation fills the note instead of sending it", context do
      {:ok, view, _html} = live(context.conn, new_assistant_path())

      assert has_element?(view, "#alert-assistant-example-1", @sample)

      view |> element("#alert-assistant-example-1") |> render_click()

      assert has_element?(view, "#alert-assistant-note", @sample)
      assert Repo.aggregate(Alert, :count) == 0
    end

    test "sending the note creates the draft, opens its session and navigates to its own URL",
         context do
      # The reply itself is step 28's browser script; here it only has to answer,
      # because this case is about what the start card does before the interview.
      Req.Test.stub(@owner, fn conn -> respond(conn, text_reply(@interview_text)) end)

      {:ok, view, _html} = live(context.conn, new_assistant_path())

      view
      |> element("#alert-assistant-form")
      |> render_submit(%{"assistant" => %{"note" => @note}})

      assert [alert] = Repo.all(Alert)

      assert_redirect(
        view,
        "/alerts/#{alert.id}?mode=assistant&step=urgency"
      )

      assert alert.revision == 1
      assert alert.urgency == nil
      assert alert.organization_id == context.organization.id
      assert alert.source_gtfs_version_id == context.version.id

      # The conversation the navigation lands on is the one the start card began:
      # it is keyed by the alert and already holds the note.
      assert {:ok, _pid, snapshot} = Agents.open(scope(context, alert.id))
      assert Enum.any?(snapshot.entries, &(&1.text == @note))
    end

    test "a blank note creates nothing", context do
      {:ok, view, _html} = live(context.conn, new_assistant_path())

      assert view
             |> element("#alert-assistant-form")
             |> render_submit(%{"assistant" => %{"note" => "   "}}) =~ "alert-assistant-start"

      assert Repo.aggregate(Alert, :count) == 0
    end
  end

  describe "a prepared change" do
    setup :log_in_editor

    test "is applied through save_draft, and the preview shows what it wrote", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      {:ok, view, _html} = live(context.conn, assistant_path(alert))

      assert has_element?(view, "#alert-assistant-panel")
      assert has_element?(view, "#agent-composer-input")

      pid = attach(context, alert, view)
      script_prepared_turn(context)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => @note}})

      assert_receive {:agent_event, ^pid,
                      {:entry, %{status: :done, prepared: %{command: {:alert_changes, _params}}}}},
                     5_000

      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000

      # One write, at the revision this editor held, with the assistant's own
      # nested answers: the embeds are cast, not dropped.
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.revision == alert.revision + 1
      assert saved.situation == :detour
      assert saved.scope.route_ids == [context.route.id]
      assert saved.scope.stop_ids == [context.skipped.id]
      assert saved.message.header == @header
      assert saved.message.description == @description

      assert has_element?(view, "#alert-preview-effect", "Detour")
      assert has_element?(view, "#alert-preview-assistant", "Filled in by the assistant")
      assert view |> element("#alert-preview-message") |> render() =~ "Route 12"
      assert view |> element("#alert-preview-header") |> render() =~ @header
    end

    test "wording it prepared over generated wording is kept when a later answer changes a fact",
         context do
      alert = alert_with_answers(context)

      # Arriving at the message step generates wording marked as the script's.
      {:ok, view, _html} = live(context.conn, message_path(alert))

      assert {:ok, generated} = Alerts.get_alert(context.audit, alert.id)
      assert generated.message.customized == false

      view |> element("#draft-with-assistant") |> render_click()
      pid = attach(context, alert, view)
      script_prepared_turn(context)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => @note}})

      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000

      # Another editor then changes a fact the wording was written against.
      assert {:ok, applied} = Alerts.get_alert(context.audit, alert.id)
      assert applied.message.header == @header

      assert {:ok, _changed} =
               Alerts.save_draft(context.audit, alert.id, applied.revision, %{
                 "cause" => "weather"
               })

      {:ok, arrived, _html} = live(editor_conn(context), message_path(alert))

      assert {:ok, kept} = Alerts.get_alert(context.audit, alert.id)
      assert kept.message.header == @header
      assert kept.message.description == @description
      assert has_element?(arrived, "#review-wording")
    end

    test "wording prepared together with a changed answer is not flagged for review at once",
         context do
      alert = alert_with_answers(context)

      {:ok, view, _html} = live(context.conn, message_path(alert))

      view |> element("#draft-with-assistant") |> render_click()
      pid = attach(context, alert, view)
      script_prepared_turn(context, extra: %{"cause" => "weather"})

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => @note}})

      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000

      {:ok, arrived, _html} = live(editor_conn(context), message_path(alert))

      assert {:ok, kept} = Alerts.get_alert(context.audit, alert.id)
      assert kept.cause == :weather
      assert kept.message.header == @header
      refute has_element?(arrived, "#review-wording")
    end

    test "the card reads as applied and offers nothing to review again", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      {:ok, view, _html} = live(context.conn, assistant_path(alert))
      pid = attach(context, alert, view)
      script_prepared_turn(context)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => @note}})

      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000

      assert element(view, "#agent-prepared-2") |> render() =~ "Applied"
      refute has_element?(view, "#agent-review-prepared-2")
    end

    test "a candidate the form outran is offered as Apply changes and applied at the newest revision",
         context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      {:ok, view, _html} = live(context.conn, assistant_path(alert))
      pid = attach(context, alert, view)

      # The settling reply waits for this test, so the newer save below is
      # committed before the turn can finish. Nothing here sleeps.
      test_pid = self()
      script_prepared_turn(context, release_from: test_pid)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => @note}})

      assert_receive {:stub_waiting, stub}, 5_000

      # Another tab saved a newer answer before the assistant's change landed.
      assert {:ok, newer} =
               Alerts.save_draft(context.audit, alert.id, alert.revision, %{"cause" => "weather"})

      send(stub, {:release, self()})

      assert_receive {:agent_event, ^pid,
                      {:entry, %{status: :done, prepared: %{command: {:alert_changes, _params}}}}},
                     5_000

      # The stale candidate is kept and offered, not forced over the newer answer.
      _ = socket_assigns(view)

      assert {:ok, untouched} = Alerts.get_alert(context.audit, alert.id)
      assert untouched.revision == newer.revision
      assert untouched.situation == nil

      assert has_element?(view, "#apply-changes-2", "Apply changes")
      assert has_element?(view, "#alert-assistant-stale")

      view |> element("#apply-changes-2") |> render_click()

      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.revision == newer.revision + 1
      assert saved.situation == :detour

      # The operator's newer answer is kept: applying is one more write, not a
      # replacement of the row.
      assert saved.cause == :weather
      refute has_element?(view, "#apply-changes-2")
    end

    test "a late result from another alert's session changes nothing", context do
      first = alert_fixture(context.audit, %{"urgency" => "now"})
      second = alert_fixture(context.audit, %{"urgency" => "planned"})

      {:ok, first_view, _html} = live(context.conn, assistant_path(first))
      first_conversation = socket_assigns(first_view).agent_conversation_id

      {:ok, view, _html} = live(editor_conn(context), assistant_path(second))
      refute socket_assigns(view).agent_conversation_id == first_conversation

      # The message the panel hands over for the alert this editor has since
      # left names a conversation that is not its own.
      send(view.pid, {:agent_prepared, first_conversation, 2})

      assert socket_assigns(view).assistant_candidate == nil

      assert {:ok, untouched} = Alerts.get_alert(context.audit, second.id)
      assert untouched.revision == second.revision
      assert untouched.situation == nil

      assert {:ok, also_untouched} = Alerts.get_alert(context.audit, first.id)
      assert also_untouched.revision == first.revision
      assert also_untouched.situation == nil
    end
  end

  describe "when the provider cannot answer" do
    setup :log_in_editor

    test "the mode control says so and the form still saves", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now", "situation" => "detour"})

      {:ok, view, _html} = live(context.conn, assistant_path(alert))
      pid = attach(context, alert, view)

      Req.Test.expect(@owner, 1, fn conn -> unavailable(conn) end)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => @note}})

      assert_receive {:agent_event, ^pid, {:entry, %{status: :failed}}}, 5_000

      assert has_element?(view, "#alert-assistant-unavailable", @unavailable)
      refute has_element?(view, "#agent-prepared-2")

      # Form mode is untouched by the failure: the same answers, the same writer.
      view |> element("#alert-mode-control-form") |> render_change(%{"mode" => "form"})

      assert has_element?(view, "#alert-question")

      view
      |> element("#alert-form")
      |> render_change(%{
        "alert" => %{
          "revision" => to_string(alert.revision),
          "message" => %{"header" => @header, "description" => @description}
        }
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.message.header == @header
      assert saved.revision == alert.revision + 1
      assert has_element?(view, "#alert-assistant-unavailable", @unavailable)
    end
  end

  describe "the message step" do
    setup :log_in_editor

    test "Draft with assistant opens assistant mode with the request in the composer", context do
      alert = alert_with_answers(context)

      {:ok, view, _html} = live(context.conn, message_path(alert))

      assert has_element?(view, "#draft-with-assistant", "Draft with assistant")
      assert has_element?(view, "#alert-form")

      # Arriving at the message step may write generated wording; the revision
      # this test guards is the one the click starts from.
      assert {:ok, before_click} = Alerts.get_alert(context.audit, alert.id)

      view |> element("#draft-with-assistant") |> render_click()

      assert has_element?(view, "#alert-assistant-panel")
      assert view |> element("#agent-composer-input") |> render() =~ @draft_request

      # The request is typed into the composer, not sent: no turn has started.
      assert socket_assigns(view).agent_entries_empty?

      # The form and the assistant read the same row.
      assert {:ok, untouched} = Alerts.get_alert(context.audit, alert.id)
      assert untouched.revision == before_click.revision
    end
  end

  ## Helpers

  # The panel opens the conversation in the editor's own process; opening it here
  # as well makes this process a listener, so the test can wait on the same
  # events the panel renders.
  defp attach(context, alert, view) do
    pid = session_pid(view)
    assert {:ok, ^pid, _snapshot} = Agents.open(scope(context, alert.id))
    pid
  end

  # Two provider replies for one turn: the tool call that prepares the change,
  # and the sentence that settles it.
  defp script_prepared_turn(context, opts \\ []) do
    arguments =
      Jason.encode!(
        Map.merge(
          %{
            "urgency" => "now",
            "situation" => "detour",
            "scope" => %{
              "shape" => "route_stops",
              "route_ids" => [context.route.id],
              "stop_ids" => [context.skipped.id]
            },
            "message" => %{"header" => @header, "description" => @description}
          },
          Keyword.get(opts, :extra, %{})
        )
      )

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_1", "propose_changes", arguments}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      case Keyword.fetch(opts, :release_from) do
        {:ok, test_pid} -> wait_for_release(conn, test_pid)
        :error -> respond(conn, text_reply(@prepared_text))
      end
    end)
  end

  # The settling reply parks until the test has committed the newer save, which
  # is what makes the stale case a fact rather than a race: it tells the test it
  # is waiting, then answers once the test releases it.
  defp wait_for_release(conn, test_pid) do
    send(test_pid, {:stub_waiting, self()})

    receive do
      {:release, ^test_pid} -> :released
    after
      5_000 -> :timed_out
    end

    respond(conn, text_reply(@prepared_text))
  end

  defp alert_with_answers(context) do
    alert_fixture(context.audit, %{
      "urgency" => "now",
      "situation" => "detour",
      "scope" => %{
        "shape" => "route_stops",
        "route_ids" => [context.route.id],
        "stop_ids" => [context.skipped.id]
      },
      "cause" => "accident"
    })
  end

  defp log_in_editor(context), do: %{conn: editor_conn(context)}

  defp editor_conn(context) do
    log_in_user(build_conn(), context.actor, organization: context.organization)
  end

  defp new_assistant_path,
    do: "/alerts/new?mode=assistant"

  defp assistant_path(alert),
    do: "/alerts/#{alert.id}?mode=assistant"

  defp message_path(alert),
    do: "/alerts/#{alert.id}?mode=form&step=message"

  defp session_pid(view), do: socket_assigns(view).agent_session

  # A synchronous read of the LiveView's assigns. A message the LiveView sent to
  # itself is queued ahead of this call, so the assigns are already the ones that
  # message produced.
  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The scope the editor's panel builds: bound to the organization and the
  # alert, with no service version, because the alert belongs to the
  # organization rather than to the selected schedule.
  defp scope(context, alert_id) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: nil,
      user_id: context.actor.id,
      user_email: context.actor.email,
      pack_id: "alerts",
      version_name: nil,
      subject_id: alert_id,
      resource_context: Scope.context(nil)
    }
  end

  defp stops(organization, version, rows) do
    Enum.map(rows, fn {stop_id, stop_name} ->
      {:ok, stop} =
        insert_stop(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop_id,
          stop_name: stop_name,
          location_type: 0,
          stop_lat: Decimal.new("44.6210"),
          stop_lon: Decimal.new("-124.0490")
        })

      stop
    end)
  end

  defp route(organization, version, first, second) do
    {:ok, route} =
      insert_route(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        route_id: "R12",
        route_short_name: "Route 12",
        route_long_name: "Coast Highway",
        route_type: 3
      })

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: "R12",
        direction_id: 0,
        headsign: "Lincoln City",
        stops: Enum.map([first, second], &{&1.stop_id, 0, 0, 0})
      })

    service = calendar_fixture(organization.id, version.id)

    schedule_trip_fixture(organization.id, version.id, "R12", bundle, %{
      service_id: service.service_id,
      trip_id: "T-R12"
    })

    route
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

  # A provider that is not there: the model turns any non-200 into
  # `{:error, :unavailable}`, which settles the turn as failed.
  defp unavailable(conn) do
    conn
    |> Map.put(:status, 503)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => "service unavailable"}))
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
