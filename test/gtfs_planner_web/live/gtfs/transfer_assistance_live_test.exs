defmodule GtfsPlannerWeb.Gtfs.TransferAssistanceLiveTest do
  @moduledoc """
  The transfer helper's native review flow on the transfers page (EV-5).

  The page, the conversation session and the turn task that prepares the change
  are separate processes, so this file shares the SQL sandbox and the Req.Test
  plug (`async: false`) and scripts only the OpenRouter HTTP boundary (INV-5).
  Every expectation comes from the domain fixtures and the domain's own
  review/apply contracts — stored rows, the audit actor, stale and conflict
  refusals — never from the handoff's implementation.

  The flow under test is the operator's own: the draft they are writing becomes
  the one selection the helper may read, the prepared card hands its proposal to
  this page's review, and only "Apply reviewed change" writes, through
  `Transfers.apply_reviewed_policy_change/2` (INV-3). A refusal keeps the review
  and the draft, and a partly applied sequence says so (AC-5).
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @blank_draft %{
    "from_stop_id" => "",
    "to_stop_id" => "",
    "from_route_id" => "",
    "to_route_id" => "",
    "from_trip_id" => "",
    "to_trip_id" => "",
    "transfer_type" => "2",
    "min_transfer_time" => ""
  }

  @prepared_notice "That prepared change is no longer in this conversation. Ask the helper again."
  @edited_notice "Only part of the helper's proposal was saved. Ask the helper again for the rest."

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id, %{name: "Assistance Version"})
    transfer_network_fixture(organization.id, version.id)

    track_sessions()

    %{organization: organization, user: user, version: version}
  end

  describe "the source the helper may read" do
    test "an incomplete draft is refused before any conversation is opened", ctx do
      {:ok, view, _html} = live(log_in(ctx), transfers_path(ctx))

      view |> element("#transfers-first-use-create") |> render_click()
      assert has_element?(view, "#transfer-policy-select")

      view |> element("#transfer-policy-select") |> render_click()

      assert element(view, "#transfer-policy-source-notice") |> render() =~
               "Choose both stops"

      assigns = socket_assigns(view)
      assert assigns.policy_selections == []
      assert assigns.agent_context.source_snapshot == nil
    end

    test "the operator's own draft becomes one admitted selection", ctx do
      {:ok, view, _html} = live(log_in(ctx), transfers_path(ctx))

      view |> element("#transfers-first-use-create") |> render_click()

      change_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "MKT",
        "min_transfer_time" => "300"
      })

      view |> element("#transfer-policy-select") |> render_click()

      assert has_element?(view, "#transfer-policy-selections")
      assert element(view, "#transfer-policy-selection-selection-1") |> render() =~ "CEN-A"
      assert element(view, "#transfer-policy-selection-selection-1") |> render() =~ "MKT"

      assigns = socket_assigns(view)

      assert [%{"id" => "selection-1", "min_time" => %{"value" => 300, "unit" => "seconds"}}] =
               assigns.policy_selections

      # The source snapshot is the server's own envelope, hashed by the scope module.
      assert %{
               kind: "transfer_policy",
               payload: %{"schema_version" => 1, "selections" => [selection]}
             } =
               assigns.agent_context.source_snapshot

      assert selection["from"]["stop_id"] == "CEN-A"
      assert selection["to"]["stop_id"] == "MKT"
      assert selection["transfer_type"] == 2

      # The draft stays open and stays on screen: staging a selection saves nothing.
      assert has_element?(view, "#transfer-editor")
      assert stored_transfers(ctx) == []
    end

    test "each draft becomes its own selection and either can be taken back", ctx do
      {:ok, view, _html} = live(log_in(ctx), transfers_path(ctx))

      view |> element("#transfers-first-use-create") |> render_click()

      change_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "MKT",
        "min_transfer_time" => "300"
      })

      view |> element("#transfer-policy-select") |> render_click()

      change_draft(view, :stops, %{
        "from_stop_id" => "MKT",
        "to_stop_id" => "CEN-A",
        "min_transfer_time" => "180"
      })

      view |> element("#transfer-policy-select") |> render_click()

      assert has_element?(view, "#transfer-policy-selection-selection-2")

      assert [%{"id" => "selection-1"}, %{"id" => "selection-2"}] =
               socket_assigns(view).policy_selections

      view |> element("#transfer-policy-remove-selection-1") |> render_click()

      assert [%{"id" => "selection-2"}] = socket_assigns(view).policy_selections
      refute has_element?(view, "#transfer-policy-selection-selection-1")
    end
  end

  describe "the prepared handoff into this page's review" do
    test "the card hands its proposal to the review and writes nothing", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])

      assert has_element?(view, "#agent-prepared-2")
      assert has_element?(view, "#agent-review-prepared-2", "Review prepared transfer rule")
      refute has_element?(view, "#transfer-policy-review")

      view |> element("#agent-review-prepared-2") |> render_click()

      # The reviewed change is shown scoped: what is stored now, and what Apply
      # would write under this version's own fence.
      assert has_element?(view, "#transfer-policy-review")
      assert element(view, "#transfer-policy-before") |> render() =~ "No stored rule"
      assert element(view, "#transfer-policy-after") |> render() =~ "CEN-A"
      assert element(view, "#transfer-policy-after") |> render() =~ "300 seconds"

      assert socket_assigns(view).policy_review.scope.gtfs_version_id == ctx.version.id
      assert stored_transfers(ctx) == []
    end

    test "the reviewed command is the draft's own direction, type and seconds", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])
      view |> element("#agent-review-prepared-2") |> render_click()

      attrs = socket_assigns(view).policy_review.command.attrs

      assert attrs.from_stop_id == "CEN-A"
      assert attrs.to_stop_id == "MKT"
      assert attrs.transfer_type == 2
      assert attrs.min_transfer_time == 300
      assert attrs.from_route_id == nil
    end

    test "a proposal prepared against a different source is refused", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])

      # The operator stages another draft after the turn prepared against the first
      # one, so the admitted source digest no longer matches the proposal's.
      change_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "HBR",
        "min_transfer_time" => "600"
      })

      view |> element("#transfer-policy-select") |> render_click()

      # A source change ends the conversation, so the card the proposal lived on is
      # gone and nothing on this page can review it (INV-2).
      refute has_element?(view, "#agent-review-prepared-2")
      refute has_element?(view, "#transfer-policy-review")
      assert stored_transfers(ctx) == []
    end

    test "a forged handoff for an entry this conversation does not hold is refused", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])

      render_click(view, "agent_review_prepared", %{"entry" => "9999"})

      assert notice_text(view) == @prepared_notice
      refute has_element?(view, "#transfer-policy-review")
      assert stored_transfers(ctx) == []
    end

    test "an entry id this page cannot parse is refused without reaching the session", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])

      render_click(view, "agent_review_prepared", %{"entry" => "not-an-id"})

      refute has_element?(view, "#transfer-policy-review")
      assert stored_transfers(ctx) == []
    end
  end

  describe "applying the reviewed change" do
    test "confirming writes exactly the reviewed row and audits the user", ctx do
      {view, pid} = prepared_view(ctx, [forward_draft()])
      view |> element("#agent-review-prepared-2") |> render_click()

      render_click(view, "transfer_policy_apply", %{})
      settle(view, &String.contains?(&1, "id=\"transfer-policy-status\""))

      assert [transfer] = stored_transfers(ctx)
      assert transfer.from_stop_id == "CEN-A"
      assert transfer.to_stop_id == "MKT"
      assert transfer.transfer_type == 2
      assert transfer.min_transfer_time == 300

      logs = Repo.all(from(l in ChangeLog, where: l.gtfs_version_id == ^ctx.version.id))
      assert logs != []
      assert Enum.all?(logs, &(&1.actor_id == ctx.user.id))

      # The receipt is settled by the session's own entry event, not by the page.
      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000
      assert element(view, "#agent-prepared-2") |> render() =~ "Applied"
    end

    test "the editor's own save path still writes without any helper step", ctx do
      {:ok, view, _html} = live(log_in(ctx), transfers_path(ctx))

      view |> element("#transfers-first-use-create") |> render_click()

      render_submit(
        element(view, "#transfer-form"),
        %{
          "scope" => "stops",
          "transfer" =>
            Map.merge(@blank_draft, %{
              "from_stop_id" => "CEN-A",
              "to_stop_id" => "MKT",
              "min_transfer_time" => "300"
            })
        }
      )

      assert [%{from_stop_id: "CEN-A", to_stop_id: "MKT", min_transfer_time: 300}] =
               stored_transfers(ctx)
    end

    test "a competitor's committed rule makes the apply stale and writes nothing", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])
      view |> element("#agent-review-prepared-2") |> render_click()

      # Another session commits a rule under the same dependency fingerprint the
      # review read.
      transfer_fixture(ctx.organization.id, ctx.version.id, %{
        from_stop_id: "CEN-A",
        to_stop_id: "HBR",
        transfer_type: 0
      })

      render_click(view, "transfer_policy_apply", %{})
      settle(view, &String.contains?(&1, "id=\"transfer-policy-status\""))

      assert element(view, "#transfer-policy-status") |> render() =~
               "Not applied: a competing transfer rule changed."

      # The review and the operator's draft both survive the refusal, and the
      # rejected row was never written.
      assert has_element?(view, "#transfer-policy-review")
      assert has_element?(view, "#transfer-editor")
      assert length(stored_transfers(ctx)) == 1
      assert socket_assigns(view).policy_counts.not_applied == 1
    end

    test "skipping writes nothing and says so", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#transfer-policy-skip") |> render_click()

      # The drawer leaves the page with the review, and what the skip did stays on
      # the page where the reviewer can still read it.
      refute has_element?(view, "#transfer-policy-drawer")

      assert element(view, "#transfer-policy-outcome #transfer-policy-status") |> render() =~
               "Skipped"

      assert element(view, "#transfer-policy-outcome #transfer-policy-counts") |> render() =~
               "Skipped 1"

      assert stored_transfers(ctx) == []
      assert socket_assigns(view).policy_counts.skipped == 1
    end

    test "the review drawer is on the page only while a review is open", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])

      refute has_element?(view, "#transfer-policy-drawer")
      refute has_element?(view, "#transfer-policy-outcome")

      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#transfer-policy-drawer #transfer-policy-confirm")
      refute has_element?(view, "#transfer-policy-outcome")

      render_click(view, "transfer_policy_close", %{})
      refute has_element?(view, "#transfer-policy-drawer")
    end
  end

  describe "a partly applied sequence" do
    test "the first save re-reviews the rest and the last save settles the whole proposal", ctx do
      {view, pid} = prepared_view(ctx, [forward_draft(), reverse_draft()])

      view |> element("#agent-review-prepared-2") |> render_click()
      render_click(view, "transfer_policy_apply", %{})
      settle(view, &String.contains?(&1, "Review the next rule"))

      # The drawer stays open on the second rule, read against the catalog the
      # first save changed, and the status says what was saved and what is next.
      assert has_element?(view, "#transfer-policy-drawer #transfer-policy-review")
      assert element(view, "#transfer-policy-status") |> render() =~ "Saved transfer type 2"
      assert socket_assigns(view).policy_review.command.attrs.from_stop_id == "MKT"

      assert socket_assigns(view).policy_counts == %{
               saved: 1,
               skipped: 0,
               conflict: 0,
               not_applied: 0
             }

      assert [%{from_stop_id: "CEN-A", to_stop_id: "MKT"}] = stored_transfers(ctx)

      render_click(view, "transfer_policy_apply", %{})
      settle(view, &String.contains?(&1, "from MKT to CEN-A."))

      # Both rules landed, each through its own confirmation, and only now is the
      # entry's whole sequence applied.
      assert [%{from_stop_id: "CEN-A"}, %{from_stop_id: "MKT"}] = stored_transfers(ctx)

      assert socket_assigns(view).policy_counts == %{
               saved: 2,
               skipped: 0,
               conflict: 0,
               not_applied: 0
             }

      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000

      refute has_element?(view, "#transfer-policy-drawer")

      assert element(view, "#transfer-policy-outcome #transfer-policy-counts") |> render() =~
               "Saved 2"
    end

    test "a rest the saved rule now conflicts with is counted and the proposal stays unconfirmed",
         ctx do
      {view, pid} = prepared_view(ctx, [station_draft(), platform_draft()])

      view |> element("#agent-review-prepared-2") |> render_click()
      render_click(view, "transfer_policy_apply", %{})
      settle(view, &(&1 =~ "id=\"transfer-policy-outcome\""))

      # The second rule disagrees with the first once the first is stored, so it is
      # refused where it was re-reviewed instead of being applied from the old read.
      counts = socket_assigns(view).policy_counts
      assert counts == %{saved: 1, skipped: 0, conflict: 1, not_applied: 1}

      assert [%{from_stop_id: "MKT", to_stop_id: "CEN"}] = stored_transfers(ctx)
      refute has_element?(view, "#transfer-policy-drawer")

      # The counts stay on the page after the drawer closes.
      assert element(view, "#transfer-policy-outcome #transfer-policy-counts") |> render() =~
               "Conflicts 1 · Not applied 1"

      assert_receive {:agent_event, ^pid, {:entry, %{applied?: false}}}, 5_000
      assert notice_text(view) == @edited_notice
      assert element(view, "#agent-prepared-2") |> render() =~ "Ready to review"
    end

    test "a skipped first item leaves the sequence unapplied and the draft open", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft(), reverse_draft()])

      view |> element("#agent-review-prepared-2") |> render_click()
      view |> element("#transfer-policy-skip") |> render_click()

      counts = socket_assigns(view).policy_counts
      assert counts.saved == 0
      assert counts.skipped == 2
      assert counts.not_applied == 1

      assert stored_transfers(ctx) == []
      assert has_element?(view, "#transfer-editor")
    end
  end

  describe "the async lifecycle of a reviewed apply" do
    test "a result that lands after the review was closed and reopened changes nothing",
         ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])
      view |> element("#agent-review-prepared-2") |> render_click()

      hold_apply(ctx)

      view |> element("#transfer-policy-confirm") |> render_click()
      task = apply_pid()

      # The reviewer closes the review and opens it again while the answer is in
      # flight, so the generation this page carries has moved on. The drawer
      # disables its own close control while a confirmation is pending, so the
      # close arrives the way a stale client or a restored tab sends it: as the
      # event itself.
      render_click(view, "transfer_policy_close", %{})
      view |> element("#agent-review-prepared-2") |> render_click()

      generation = socket_assigns(view).policy_generation
      release_apply(task, :continue)

      settle(view, &(&1 =~ "went unanswered"))

      assigns = socket_assigns(view)

      # The late result rewrote no review: the reopened one is still on screen with
      # its own item, and nothing claims a save that this page never confirmed.
      assert assigns.policy_generation == generation
      assert assigns.policy_review.command.attrs.to_stop_id == "MKT"
      refute assigns.policy_counts.saved == 1
    end

    test "an exit after close and reopen leaves the reopened review untouched", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])
      view |> element("#agent-review-prepared-2") |> render_click()

      hold_apply(ctx)

      view |> element("#transfer-policy-confirm") |> render_click()
      task = apply_pid()

      render_click(view, "transfer_policy_close", %{})
      view |> element("#agent-review-prepared-2") |> render_click()

      generation = socket_assigns(view).policy_generation
      release_apply(task, :exit)

      settle(view, &(&1 =~ "went unanswered"))

      assigns = socket_assigns(view)

      assert assigns.policy_generation == generation
      assert assigns.policy_review.command.attrs.from_stop_id == "CEN-A"
      assert assigns.policy_status == nil
      assert stored_transfers(ctx) == []
    end

    test "a second confirmation while the first is in flight writes one row", ctx do
      {view, _pid} = prepared_view(ctx, [forward_draft()])
      view |> element("#agent-review-prepared-2") |> render_click()

      hold_apply(ctx)

      view |> element("#transfer-policy-confirm") |> render_click()
      task = apply_pid()

      # The button is disabled for the reviewer, and the event is refused even when
      # it is forged, so the reviewed change is applied once.
      assert has_element?(view, "#transfer-policy-confirm[disabled]")
      render_click(view, "transfer_policy_apply", %{})

      release_apply(task, :continue)
      settle(view, &String.contains?(&1, "Saved transfer type"))

      assert length(stored_transfers(ctx)) == 1
    end
  end

  ## Helpers

  # The reviewed apply runs in this page's own async task, so these cases hold the
  # write transaction itself: the adapter reports that it started, waits for the
  # test to release it, and only then runs the page's own transaction. Nothing here
  # decides an outcome; it only controls when the answer exists.
  defp hold_apply(_ctx) do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)
    test_pid = self()

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransactionMock)

    stub(ReviewedApplyTransactionMock, :run, fn transaction, options ->
      send(test_pid, {:apply_started, self()})

      receive do
        :apply_exit -> exit(:apply_crashed)
        :apply_continue -> ReviewedApplyTransaction.Sandbox.run(transaction, options)
      after
        5_000 -> exit(:apply_never_released)
      end
    end)
  end

  defp release_apply(pid, :continue), do: send(pid, :apply_continue)
  defp release_apply(pid, :exit), do: send(pid, :apply_exit)

  defp apply_pid, do: receive(do: ({:apply_started, pid} -> pid))

  defp log_in(ctx) do
    log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
  end

  # Opens the editor, writes each draft this case offers the helper, stages them
  # in order, and opens the panel that may read them.
  defp helper_view(ctx, drafts) do
    {:ok, view, _html} = live(log_in(ctx), transfers_path(ctx))

    view |> element("#transfers-first-use-create") |> render_click()

    for draft <- drafts do
      change_draft(view, :stops, draft)
      view |> element("#transfer-policy-select") |> render_click()
    end

    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    # The panel opened the session itself, from the context this page admitted;
    # this process attaches to the same conversation so the turn events are
    # observable here rather than only inside the page.
    pid = socket_assigns(view).agent_session

    scope = %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.user.id,
      user_email: ctx.user.email,
      pack_id: "transfers",
      version_name: ctx.version.name,
      resource_context: socket_assigns(view).agent_context
    }

    assert {:ok, ^pid, _snapshot} = Agents.open(scope)

    {view, pid}
  end

  # Scripts the deterministic prepare turn: one model reply calls
  # `prepare_transfer_policy` for the staged selections, the second settles it.
  defp prepared_view(ctx, drafts) do
    {view, pid} = helper_view(ctx, drafts)

    selection_ids = Enum.map(1..length(drafts), &"selection-#{&1}")
    arguments = Jason.encode!(%{"selection_ids" => selection_ids})

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_1", "prepare_transfer_policy", arguments}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, text_reply("I prepared the change. Review it before applying."))
    end)

    submit(view, "Give CEN-A to MKT a five minute connection.")
    assert_receive {:agent_event, ^pid, {:entry, %{status: :working}}}, 5_000

    assert_receive {:agent_event, ^pid,
                    {:entry, %{status: :done, prepared: %{command: command}}} = _entry},
                   5_000

    assert %{kind: :transfer_policy_sequence, items: items} = command
    assert length(items) == length(drafts)

    {view, pid}
  end

  # The direction the case confirms, and the reverse direction a second selection
  # covers, so a sequence carries two independent rules.
  defp forward_draft do
    %{"from_stop_id" => "CEN-A", "to_stop_id" => "MKT", "min_transfer_time" => "300"}
  end

  defp reverse_draft do
    %{"from_stop_id" => "MKT", "to_stop_id" => "CEN-A", "min_transfer_time" => "180"}
  end

  # Two rules that agree until the first is stored: the station-wide prohibition
  # covers the platform the second one names, at the same specificity, with a
  # different effect.
  defp station_draft do
    %{"from_stop_id" => "MKT", "to_stop_id" => "CEN", "transfer_type" => "0"}
  end

  defp platform_draft do
    %{
      "from_stop_id" => "MKT",
      "to_stop_id" => "CEN-A",
      "transfer_type" => "2",
      "min_transfer_time" => "300"
    }
  end

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  defp change_draft(view, scope, values) do
    render_change(
      element(view, "#transfer-form"),
      %{
        "_target" => "editor",
        "scope" => to_string(scope),
        "transfer" => Map.merge(@blank_draft, values)
      }
    )
  end

  # `start_async/3` settles the reviewed apply in the page's own task, so the
  # test reads the page until the server's own outcome is on it.
  defp settle(view, ready, attempts \\ 200) when is_function(ready, 1) do
    _ = render_async(view, 5_000)

    Enum.reduce_while(1..attempts, render(view), fn _attempt, html ->
      if ready.(html) do
        {:halt, html}
      else
        Process.sleep(10)
        {:cont, render(view)}
      end
    end)
  end

  # The panel's notice is HTML-escaped in the rendered page, so the case reads
  # the text a person reads rather than the markup around it.
  defp notice_text(view) do
    view
    |> element("#agent-notice")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp transfers_path(ctx, params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/gtfs/#{ctx.version.id}/transfers#{query}"
  end

  # The test database can hold rows this case did not create, so every stored-row
  # assertion reads only this case's organization and version.
  defp stored_transfers(ctx) do
    Repo.all(
      from(t in Transfer,
        where: t.organization_id == ^ctx.organization.id and t.gtfs_version_id == ^ctx.version.id,
        order_by: [asc: t.from_stop_id, asc: t.to_stop_id]
      )
    )
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
