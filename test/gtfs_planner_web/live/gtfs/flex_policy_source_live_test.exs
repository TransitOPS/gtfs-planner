defmodule GtfsPlannerWeb.Gtfs.FlexPolicySourceLiveTest do
  @moduledoc """
  The approved policy source intake on the Flex service page (AC-1–AC-7, AC-12).

  The intake is judged through the ordinary route and the live session, never
  through private assign injection: the editor pastes the policy text their
  agency authorized, names it, and accepts it explicitly, and the server freezes
  that text with the service this page already loaded before any provider
  request exists. The registered `flex_policy` pack then answers on the ordinary
  page route through the one OpenRouter HTTP boundary this module scripts
  (INV-5).

  The refusals are judged as refusals, not as errors: an over-limit whole
  context, a source the server will not admit and a membership that is no longer
  an active editor all leave the editor's whole text, the native hours and
  booking fields and the one Save exactly where they were (AC-12).

  The staleness is judged by replacing the source, by leaving for another
  service and by letting a slow provider answer into a page that has already
  moved on, so nothing restores the old source or the old prepared review
  (AC-2, AC-7).

  The focused command is deferred to branch review:
  `mix test test/gtfs_planner_web/live/gtfs/flex_policy_source_live_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Assistant

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @policy_text "Newport Dial-a-Ride runs weekdays 7:00 am to 6:00 pm. " <>
                 "Riders must call at least 30 minutes ahead."
  @replacement_text "Riders call ahead on weekdays only."
  @too_large_text String.duplicate("a", 65_537)
  @first_question "Which hours does this service have saved?"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    conn = build_conn()
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id, %{name: "Helper Version"})
    flex_representative_fixture(organization, version)

    track_sessions()

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      user: user,
      version: version,
      service: service_named(organization.id, version.id, "Newport Dial-a-Ride")
    }
  end

  describe "the source intake beside the hours and booking sections" do
    test "the section, the form and the helper control are all on the ready page", context do
      view = service_view(context)
      loaded(view)

      document = doc(view)

      # The intake is its own section beside the hours and booking sections, and
      # its own form: nothing in it is a field of the service draft.
      assert positions(document, ["sec-when", "sec-booking", "sec-flex-policy-source"]) ==
               ["sec-when", "sec-booking", "sec-flex-policy-source"]

      assert has_element?(view, "#flex-policy-source-form")
      assert has_element?(view, "#flex-policy-source-label")
      assert has_element?(view, "#flex-policy-source-revision")
      assert has_element?(view, "#flex-policy-source-text")
      assert has_element?(view, "#flex-policy-accept")
      assert has_element?(view, "#agent-helper-open")

      # The status region announces the empty state, and nothing claims a source
      # has been accepted.
      assert has_element?(view, "#flex-policy-source-state", "No policy source accepted yet.")
      assert has_element?(view, "#flex-policy-source-state[role=status]")
      assert has_element?(view, "#flex-policy-source-state[aria-live=polite]")
      refute has_element?(view, "#flex-policy-source-accepted")

      # Acceptance is the editor's statement about their own authorized text,
      # never an agency or legal certification.
      copy = text_of(document, "#sec-flex-policy-source")
      assert copy =~ "statement that this is the authorized text"
      assert copy =~ "nothing is saved until you review"

      # The panel's focus listener outlives both of the panel's states, and the
      # panel itself is closed until the editor opens it.
      assert has_element?(view, "#flex-policy-helper-focus")
      refute has_element?(view, "#agent-panel")
    end

    test "an unaccepted source is refused in the form and the page is not dirtied", context do
      view = service_view(context)
      loaded(view)

      view
      |> element("#flex-policy-source-form")
      |> render_submit(%{
        "flex_policy" => %{"label" => "", "revision" => "", "text" => @policy_text}
      })

      document = doc(view)
      assert has_element?(view, "#flex-policy-source-refusal")

      assert has_element?(
               view,
               "#flex-policy-source-label-error",
               "Name the policy document"
             )

      assert_push_event(view, "focus_form_error", %{form_id: "flex-policy-source-form"})

      # The whole text is still here to be fixed, and accepting a source is never
      # a service change, so the one Save does not appear (INV-1).
      assert area_value_of(document, "#flex-policy-source-text") == @policy_text
      refute has_element?(view, "#flex-policy-source-accepted")
      refute has_element?(view, "#save-bar")
    end

    test "accepting freezes the source and mounts the registered pack on this route", context do
      view = service_view(context)
      loaded(view)

      accept_source(view, "Newport flex policy", "rev 3", @policy_text)

      document = doc(view)
      assert has_element?(view, "#flex-policy-source-accepted")
      assert text_of(document, "#flex-policy-source-accepted") =~ "Newport flex policy"
      assert text_of(document, "#flex-policy-source-accepted") =~ "Revision rev 3"
      assert text_of(document, "#flex-policy-source-state") =~ "Accepted Newport flex policy"
      refute has_element?(view, "#flex-policy-source-refusal")

      # The pack that answers is the real registered one, reached by opening the
      # helper on this page with no assign injection of any kind.
      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      assert element(view, "#agent-panel") |> render() =~ "Flex policy helper"
      assert element(view, "#agent-panel") |> render() =~ "Helper Version"
      assert is_pid(session_pid(view))

      # Closing returns focus to the control that opened it, so the panel's own
      # focus contract holds on this page too.
      view |> element("#agent-panel-close") |> render_click()
      refute has_element?(view, "#agent-panel")
      assert_push_event(view, "agent:focus", %{id: "agent-helper-open"})
    end

    test "a question reaches the pack's own bounded read of the saved service", context do
      view = service_view(context)
      loaded(view)
      accept_source(view, "Newport flex policy", nil, @policy_text)

      view |> element("#agent-helper-open") |> render_click()
      pid = join_session(view)

      expect_reply(1, tool_calls_reply([{"call_1", "get_flex_policy_context", "{}"}]))
      expect_reply(1, text_reply("It runs weekdays 7:00 am to 6:00 pm."))

      submit(view, @first_question)

      # The pack's own bounded read is the first tool the model may call, and it
      # is the only one this answer needed.
      assert_receive {:model_request, request}, 5_000
      assert "get_flex_policy_context" in tool_names(request)
      assert_receive {:model_request, _tool_result_request}, 5_000

      entry = await_settled(pid)
      assert entry.text == "It runs weekdays 7:00 am to 6:00 pm."
      assert has_element?(view, "#agent-entry-#{entry.id}", "weekdays 7:00 am to 6:00 pm")
    end
  end

  describe "the refusals" do
    test "an over-limit whole context stays visible in the form and admits no helper", context do
      view = service_view(context)
      loaded(view)

      accept_source(view, "Oversized policy", nil, @too_large_text)

      document = doc(view)
      assert has_element?(view, "#flex-policy-source-refusal")
      assert text_of(document, "#flex-policy-source-refusal") =~ "65,536 bytes"
      assert has_element?(view, "#flex-policy-source-refusal", "65,536 bytes")
      refute has_element?(view, "#flex-policy-source-accepted")

      # The whole text is retained, so the editor can shorten it in place.
      assert String.length(area_value_of(document, "#flex-policy-source-text")) ==
               String.length(@too_large_text)

      # No accepted source means the pack admits no conversation, so opening the
      # helper reaches the panel's own refusal rather than a provider request.
      view |> element("#agent-helper-open") |> render_click()

      assert is_nil(session_pid(view))
      assert has_element?(view, "#agent-panel", "helper is unavailable")
    end

    test "a membership that is no longer an active editor refuses the source", context do
      view = service_view(context)
      loaded(view)

      membership = Accounts.get_user_org_membership(context.user.id, context.organization.id)

      # The membership stops being an active editor's, which is the one
      # authorization change the acceptance must refuse.
      {:ok, _membership} =
        Accounts.update_user_org_membership(membership, %{roles: ["pathways_studio_admin"]})

      accept_source(view, "Newport flex policy", nil, @policy_text)

      document = doc(view)
      assert has_element?(view, "#flex-policy-source-refusal")
      assert text_of(document, "#flex-policy-source-refusal") =~ "access to flex services changed"
      refute has_element?(view, "#flex-policy-source-accepted")

      # The text and the native hours fields are exactly where they were.
      assert area_value_of(document, "#flex-policy-source-text") == @policy_text
      assert has_element?(view, "#service_hours_0_start")
      refute has_element?(view, "#save-bar")
    end

    test "the panel's own provider failure leaves the accepted source on screen", context do
      view = service_view(context)
      loaded(view)
      accept_source(view, "Newport flex policy", nil, @policy_text)

      view |> element("#agent-helper-open") |> render_click()
      pid = join_session(view)

      expect_response(500, %{"error" => "provider unavailable"})
      submit(view, @first_question)

      assert await_settled(pid).status == :failed
      assert has_element?(view, "#agent-panel", "helper is unavailable")

      # The panel reports its own failure; the accepted source and the editor's
      # native page are untouched (AC-12).
      assert has_element?(view, "#flex-policy-source-accepted", "Newport flex policy")
      assert has_element?(view, "#sec-flex-policy-source")
    end
  end

  describe "the whole-context admission boundary" do
    test "a context of exactly 65,536 bytes is accepted and one byte more is refused", context do
      view = service_view(context)
      loaded(view)

      # The boundary is the whole serialized context, not the text: the envelope,
      # the service id and the frozen saved fingerprint all count. The exact fit
      # is computed against this page's own context through the same
      # `Scope.with_source_snapshot/2` the host calls, so the case states the
      # equality the server enforces rather than a guessed text length.
      base = Scope.context({:version, context.version.id})
      exact = text_filling_the_context(context, base, 65_536)
      over = text_filling_the_context(context, base, 65_536) <> "a"

      accept_source(view, "Exact fit", nil, exact)

      assert has_element?(view, "#flex-policy-source-accepted", "Exact fit")
      refute has_element?(view, "#flex-policy-source-refusal")

      # One byte past the cap stays visible in the form and admits no helper.
      accept_source(view, "One byte over", nil, over)

      document = doc(view)
      assert has_element?(view, "#flex-policy-source-refusal")
      assert text_of(document, "#flex-policy-source-refusal") =~ "65,536 bytes"
      refute has_element?(view, "#flex-policy-source-accepted")

      # The rejected text is retained whole, so the editor can shorten it here.
      assert area_value_of(document, "#flex-policy-source-text") == over
    end
  end

  describe "moving on" do
    test "a slow provider answer cannot restore a source the editor replaced", context do
      view = service_view(context)
      loaded(view)
      accept_source(view, "First policy", nil, @policy_text)

      view |> element("#agent-helper-open") |> render_click()
      first = join_session(view)
      expect_blocked()

      submit(view, @first_question)
      assert_receive {:blocked, stub}, 5_000

      # The editor replaces the source while that answer is still in flight.
      accept_source(view, "Second policy", nil, @replacement_text)

      assert has_element?(view, "#flex-policy-source-accepted", "Second policy")
      refute has_element?(view, "#flex-policy-source-accepted", "First policy")

      release(stub, text_reply("Weekdays 7:00 am to 6:00 pm."))

      # The answer really is produced — the old session finishes its turn — but
      # this page detached from it, so it reaches nothing on screen and cannot
      # put the replaced source back (AC-2, AC-7).
      assert await_settled(first).text == "Weekdays 7:00 am to 6:00 pm."

      assert has_element?(view, "#flex-policy-source-accepted", "Second policy")
      refute has_element?(view, "#flex-policy-source-accepted", "First policy")
      refute has_element?(view, "#agent-entry-1")
    end

    test "another service's page carries no accepted source and no conversation", context do
      other =
        Enum.find(
          Flex.list_services(context.organization.id, context.version.id),
          &(&1.id != context.service.id)
        )

      view = service_view(context)
      loaded(view)
      accept_source(view, "Newport flex policy", nil, @policy_text)
      view |> element("#agent-helper-open") |> render_click()
      assert is_pid(session_pid(view))

      {:ok, other_view, _html} = live(context.conn, service_path(context.version, other))
      loaded(other_view)

      document = doc(other_view)
      assert text_of(document, "#flex-policy-source-state") == "No policy source accepted yet."
      refute has_element?(other_view, "#flex-policy-source-accepted")
      refute has_element?(other_view, "#agent-panel")
      assert is_nil(session_pid(other_view))
    end
  end

  # --- the intake ------------------------------------------------------------

  defp accept_source(view, label, revision, text) do
    view
    |> element("#flex-policy-source-form")
    |> render_submit(%{
      "flex_policy" => %{"label" => label, "revision" => revision || "", "text" => text}
    })
  end

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  # The text length that makes this page's own accepted context exactly `target`
  # bytes. The cap is the whole serialized context rather than the text, so the
  # length is found by doubling then bisecting against the same
  # `Scope.with_source_snapshot/2` the host calls; the assertions then state the
  # equality the server enforces rather than a guessed text length.
  defp text_filling_the_context(context, base, target) do
    service = context.service
    fingerprint = saved_fingerprint(context)

    envelope = fn text ->
      %{
        kind: "flex_policy",
        payload: %{
          "service_id" => service.id,
          "section" => "hours_booking",
          "source" => %{
            "text" => text,
            "label" => "Exact fit",
            "revision" => nil,
            "accepted" => true
          },
          "saved_fingerprint" => fingerprint
        }
      }
    end

    # `over?` answers whether a text of that length puts this page's own
    # context past the cap, measured through the same admission the host calls.
    over? = fn length ->
      Scope.with_source_snapshot(base, envelope.(String.duplicate("a", length))) ==
        {:error, :too_large}
    end

    # The cap admits a text far shorter than itself, because the envelope, the
    # service id and the frozen fingerprint already occupy part of the budget,
    # so the boundary is found by bisection rather than assumed.
    refute over?.(0)
    assert over?.(target)
    best = greatest_admitted(over?, 0, target)

    refute over?.(best)
    assert over?.(best + 1)

    String.duplicate("a", best)
  end

  # The greatest length in `0..ceiling` that is not over the cap, by bisection
  # over a range whose ends are already known.
  defp greatest_admitted(_over?, admitted, refused) when refused - admitted <= 1, do: admitted

  defp greatest_admitted(over?, admitted, refused) do
    middle = div(admitted + refused, 2)

    if over?.(middle) do
      greatest_admitted(over?, admitted, middle)
    else
      greatest_admitted(over?, middle, refused)
    end
  end

  # The same scoped workspace read the host freezes before acceptance.
  defp saved_fingerprint(context) do
    scope = %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "flex_policy",
      version_name: context.version.name,
      resource_context: Scope.context({:version, context.version.id})
    }

    assert {:ok, workspace, _evidence} = Assistant.workspace(scope, context.service.id)
    workspace.fingerprint
  end

  # --- helpers ---------------------------------------------------------------

  defp service_view(context) do
    {:ok, view, _html} = live(context.conn, service_path(context.version, context.service))
    view
  end

  defp service_path(version, service), do: "/gtfs/#{version.id}/flex/#{service.id}"

  defp session_pid(view), do: :sys.get_state(view.pid).socket.assigns.agent_session

  # The panel's own scope, read back so this module can join the same
  # conversation as a second listener and observe the turn's settle event without
  # polling the render or sleeping.
  defp panel_scope(view) do
    assigns = :sys.get_state(view.pid).socket.assigns

    %Scope{
      organization_id: assigns.current_organization.id,
      gtfs_version_id: assigns.current_gtfs_version.id,
      user_id: assigns.current_user.id,
      user_email: assigns.current_user.email,
      pack_id: assigns.agent_pack_id,
      version_name: assigns.current_gtfs_version.name,
      resource_context: assigns.agent_context
    }
  end

  defp join_session(view) do
    pid = session_pid(view)
    assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(view))
    pid
  end

  defp service_named(organization_id, version_id, name) do
    organization_id
    |> Flex.list_services(version_id)
    |> Enum.find(&(&1.name == name))
  end

  defp tool_names(request), do: Enum.map(request["tools"], & &1["function"]["name"])

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  defp loaded(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp area_value_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp positions(document, ids) do
    html = LazyHTML.to_html(document)

    ids
    |> Enum.map(fn id -> {id, :binary.match(html, "id=\"#{id}\"") |> elem(0)} end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # Sessions are started under the application's own supervisor and outlive the
  # test socket, so every session this module opened is terminated here.
  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(Agents.SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    Agents.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

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

  # A scripted reply for the next `count` model requests, without blocking the
  # turn on a hand-released stub, so a tool round trip is two ordinary replies.
  defp expect_reply(count, payload) do
    test = self()

    Req.Test.expect(@owner, count, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

  defp expect_response(status, payload) do
    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(payload))
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
