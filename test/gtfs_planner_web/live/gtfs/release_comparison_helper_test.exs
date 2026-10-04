defmodule GtfsPlannerWeb.Gtfs.ReleaseComparisonHelperTest do
  @moduledoc """
  Focused evidence for CL-12/FH-12: the comparison helper on the ordinary Export
  page, from the native form to the evidence card, and the scoped link it may
  render.

  Every case drives the production path. The routed `/gtfs/:version_id/export`
  page runs a real `ReleaseComparison.Runner` over two retained ZIPs published
  through `ExportRuns`/`ArtifactStorage`, the page freezes the delivered result
  through the shared snapshot seam, `AgentPanel` binds that context, and
  `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> `Packs.ReleaseComparison`
  answers. Only the OpenRouter HTTP boundary is doubled, and no case injects an
  assign into the page.

  The expected values are counted by hand from `GtfsPlanner.ReleaseComparisonFixtures`
  over Wed 2026-11-25 and Thu 2026-11-26: R1 runs 2 trips on the 25th and 1 on the
  26th against 2 in the earlier file, so exactly one trip is lost, and the
  renamed route R2/R2X keeps its service. What these cases reject (FH-12) is a
  historical identifier opening a current page, a stale or foreign digest linking
  at all, and a provider failure or a replaced context touching the native page,
  another tab's conversation or anyone's job.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ReleaseComparisonFixtures
  import GtfsPlanner.VersionsFixtures
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @from "2026-11-25"
  @to "2026-11-26"
  @question "Did we lose any service between these two files?"
  @answer "One route lost a trip on Thanksgiving."

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()
    track_sessions()

    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    host = gtfs_version_fixture(organization.id)
    left_version = gtfs_version_fixture(organization.id)
    right_version = gtfs_version_fixture(organization.id)

    root =
      Path.join(
        System.tmp_dir!(),
        "release-comparison-helper-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    %{
      user: user,
      organization: organization,
      host: host,
      left_version: left_version,
      right_version: right_version,
      left: publish_run!(organization, left_version, left_zip()),
      right: publish_run!(organization, right_version, right_zip(twins?: true))
    }
  end

  describe "the ordinary journey from the Export form to the evidence card" do
    test "an editor compares two files, opens the helper and reads the server's answer",
         context do
      view = view(context)

      # Nothing to ask about yet: the comparison helper is offered for a
      # finished, admitted comparison and for nothing else.
      refute has_element?(view, "#comparison-helper-open")
      refute has_element?(view, "#agent-panel")

      compare!(view, context.left, context.right)

      assert has_element?(view, "#comparison-helper-entry", "Ask about this comparison")
      assert element(view, "#comparison-helper-open") |> render() =~ ~s(aria-expanded="false")

      assert element(view, "#comparison-helper-open") |> render() =~
               ~s(aria-controls="agent-panel")

      refute has_element?(view, "#agent-panel")

      view |> element("#comparison-helper-open") |> render_click()

      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})
      assert has_element?(view, "#agent-panel")

      assert element(view, "#agent-panel") |> render() =~
               "#{context.host.name} · whole comparison"

      assert has_element?(view, "#agent-first-conversation")
      assert is_pid(session_pid(view))

      pid = listen(view, context)

      expect_reply(tool_calls_reply([{"call_1", "get_export_comparison", "{}"}]))
      expect_reply(text_reply(@answer))

      submit(view, @question)
      entry = await_settled(pid)
      assert entry.status == :done

      assert has_element?(view, "#agent-entry-2", @answer)
      assert has_element?(view, "#agent-entry-2 [data-evidence-kind='export_comparison']")

      # The card states the server's own numbers: (2+1+1+1) - (2+2+1+1) = -1.
      card = view |> element("#agent-evidence-2-1") |> render()
      assert card =~ "Server result"
      assert card =~ "-1"
      assert card =~ "4 of 4"
      assert card =~ "gtfs_release_comparison"

      # The incomplete comparison is never shown as a complete one: three
      # unresolved stop matches keep it incomplete.
      assert has_element?(view, "#agent-entry-2 [data-evidence-completeness='incomplete']")

      # The one resource is this comparison, and it links to this Export page and
      # nowhere else. No historical identifier became a link.
      assert [link] = card |> fragment() |> query_attributes("a", "href")
      assert link == "/gtfs/#{context.host.id}/export"
      refute card =~ "/routes/"
      refute card =~ "R2X"

      # Asking changed nothing on the native page.
      assert has_element?(view, "#comparison-totals")
      assert has_element?(view, "#comparison-exact-delta", "-1")
    end

    test "the Export page mounts one panel that offers both helpers", context do
      view = view(context)
      assigns = socket_assigns(view)

      assert assigns.agent_pack_id == "feed_quality"
      assert assigns.agent_allowed_packs == ["feed_quality", "release_comparison"]
      refute has_element?(view, "#export-helper-mode")

      compare!(view, context.left, context.right)

      html = render(view)
      assert query_count(fragment(html), "#agent-helper-open") == 1
      assert query_count(fragment(html), "#comparison-helper-open") == 1
      assert query_count(fragment(html), "[phx-hook$='ExportHelperFocus']") == 1
      assert has_element?(view, "#export-helper-mode-feed_quality[aria-pressed='true']")
      assert has_element?(view, "#export-helper-mode-release_comparison[aria-pressed='false']")
    end
  end

  describe "one panel serves the feed quality and the comparison helpers" do
    test "switching binds each helper only to the context it owns", context do
      {view, comparison_pid} = open_helper(context)
      comparison_context = socket_assigns(view).agent_context

      assert socket_assigns(view).agent_pack_id == "release_comparison"
      assert %{source_snapshot: %{kind: "release_comparison"}} = comparison_context

      view |> element("#export-helper-mode-feed_quality") |> render_click()

      assigns = socket_assigns(view)
      assert assigns.agent_pack_id == "feed_quality"
      assert assigns.agent_open?
      assert %{source_snapshot: %{kind: "feed_quality"}} = assigns.agent_context
      assert is_pid(assigns.agent_session) and assigns.agent_session != comparison_pid
      assert element(view, "#agent-panel") |> render() =~ "Feed quality helper"
      assert has_element?(view, "#agent-first-conversation")
      assert query_count(fragment(render(view)), "#agent-panel") == 1

      # The comparison conversation was only released, so the same copy reaches
      # the same conversation again, with the comparison's own context.
      view |> element("#export-helper-mode-release_comparison") |> render_click()

      assert socket_assigns(view).agent_pack_id == "release_comparison"
      assert socket_assigns(view).agent_context == comparison_context
      assert session_pid(view) == comparison_pid
      assert element(view, "#agent-panel") |> render() =~ "Comparison helper"
    end

    test "a feed quality refresh leaves the comparison helper's context bound", context do
      {view, pid} = open_helper(context)
      comparison_context = socket_assigns(view).agent_context

      view |> element("#feed-quality-refresh") |> render_click()

      assert socket_assigns(view).agent_pack_id == "release_comparison"
      assert socket_assigns(view).agent_context == comparison_context
      assert session_pid(view) == pid
    end

    test "a forged selection cannot bind a helper that has nothing to read", context do
      view = view(context)
      before_context = socket_assigns(view).agent_context

      render_hook(view, "export_helper_mode", %{"pack" => "release_comparison"})
      render_hook(view, "export_helper_mode", %{"pack" => "alerts"})
      render_hook(view, "comparison_helper_open", %{})

      assigns = socket_assigns(view)
      assert assigns.agent_pack_id == "feed_quality"
      assert assigns.agent_context == before_context
      refute assigns.agent_open?
    end
  end

  describe "a comparison too large for the helper" do
    test "keeps the native result, says why, and narrowing admits the helper", context do
      organization = context.organization
      left = publish_run!(organization, context.left_version, many_routes_zip(oversized_routes()))

      right =
        publish_run!(organization, context.right_version, many_routes_zip(oversized_routes()))

      view = view(context) |> compare!(left, right)

      # One row per route and date is more than the shared context can hold. The
      # helper is refused; the comparison is not.
      assert has_element?(view, "#comparison-helper-notice", "more rows than the helper can hold")
      assert has_element?(view, "#comparison-helper-narrow", "Choose routes and dates")
      refute has_element?(view, "#comparison-helper-open")
      refute has_element?(view, "#export-helper-mode")
      refute has_element?(view, "#agent-panel")
      assert socket_assigns(view).comparison_context == nil
      assert socket_assigns(view).comparison_context_notice == :source_too_large

      assert has_element?(view, "#comparison-results")
      assert has_element?(view, "#comparison-totals")
      assert has_element?(view, "#comparison-differences")
      assert has_element?(view, "#comparison-scope-form")

      # An explicit narrower scope is the only way to a smaller copy.
      narrow!(view, ["M001/M001"], [@from])

      assert has_element?(view, "#comparison-scope-applied")
      refute has_element?(view, "#comparison-helper-notice")
      assert has_element?(view, "#comparison-helper-open")

      view |> element("#comparison-helper-open") |> render_click()
      assert element(view, "#agent-panel") |> render() =~ "narrowed comparison"

      assert %{source_snapshot: %{payload: payload}} = socket_assigns(view).agent_context
      assert payload["selected_route_pairs"] == ["M001/M001"]
      assert payload["selected_dates"] == [@from]
      assert payload["selected_digest"] != payload["result_digest"]
    end
  end

  describe "the states the browser journeys choose from" do
    test "a trip that becomes a non-exact frequency window is never a measured total",
         context do
      earlier = publish_run!(context.organization, context.left_version, frequency_zip(false))
      later = publish_run!(context.organization, context.right_version, frequency_zip(true))

      view = view(context) |> compare!(earlier, later)

      assert has_element?(view, "#comparison-totals-unknown", "was not measured")
      assert has_element?(view, "#comparison-total-reasons", "frequency windows")
      assert has_element?(view, "#comparison-completeness", "Incomplete")
      refute has_element?(view, "#comparison-exact-delta")

      # The helper is still offered: an incomplete comparison is explained, not hidden.
      assert has_element?(view, "#agent-helper-open")
    end

    test "two identical files are a complete comparison with nothing to report", context do
      first = publish_run!(context.organization, context.left_version, simple_zip())
      second = publish_run!(context.organization, context.right_version, simple_zip())

      view = view(context) |> compare!(first, second)

      assert has_element?(view, "#comparison-totals", "no change")
      assert has_element?(view, "#comparison-completeness", "Complete")
      assert has_element?(view, "#comparison-differences-empty")
      assert has_element?(view, "#comparison-structural-empty")
      assert has_element?(view, "#comparison-unresolved-empty")
    end
  end

  describe "a helper failure or a replaced context leaves the page and other tabs alone" do
    test "a provider failure keeps the native controls and chosen files, and Retry recovers",
         context do
      {view, pid} = open_helper(context)

      chosen = chosen_values(view)
      assert chosen == [to_string(context.left.id), to_string(context.right.id), @from, @to]

      expect_status(500, %{"error" => "provider unavailable"})
      submit(view, @question)
      assert await_settled(pid).status == :failed

      # The failure is announced beside Retry; the page behind it never changed.
      assert has_element?(view, "#agent-retry-2")
      assert render(view) =~ "The helper is unavailable right now"
      refute has_element?(view, "[data-evidence-kind]")

      assert has_element?(view, "#export-workspace")
      assert has_element?(view, "#export-comparison-form")
      assert has_element?(view, "#comparison-results")
      assert has_element?(view, "#comparison-exact-delta", "-1")
      assert chosen_values(view) == chosen

      expect_reply(tool_calls_reply([{"call_1", "get_export_comparison", "{}"}]))
      expect_reply(text_reply(@answer))

      view |> element("#agent-retry-2") |> render_click()
      assert await_settled(pid).status == :done
      assert has_element?(view, "[data-evidence-kind='export_comparison']")
    end

    test "narrowing replaces this panel's conversation; the old session and a late event stay out",
         context do
      {view, old_pid} = open_helper(context)
      old_context = socket_assigns(view).agent_context

      narrow!(view, ["R1/R1"], [@to])

      new_pid = session_pid(view)
      assert is_pid(new_pid)
      refute new_pid == old_pid
      assert has_element?(view, "#agent-panel")
      assert element(view, "#agent-panel") |> render() =~ "narrowed comparison"
      assert has_element?(view, "#agent-first-conversation")

      # A late entry and a late down from the replaced session reach nothing.
      stale = assistant_entry(7, "A late answer from the replaced conversation.", [])
      send(view.pid, {:agent_event, old_pid, {:entry, stale}})
      send(view.pid, {:DOWN, make_ref(), :process, old_pid, :normal})

      refute render(view) =~ "A late answer from the replaced conversation."
      assert socket_assigns(view).agent_session == new_pid
      assert socket_assigns(view).agent_status == :idle

      # The replaced conversation itself was not stopped: another tab holding the
      # same comparison still reaches it, and this panel never cancelled it.
      assert {:ok, ^old_pid, _snapshot} = Agents.open(scope(context, old_context))

      # Nor did the native page change: the narrowed rows and the file choices.
      assert has_element?(view, "#comparison-scope-applied")
      assert has_element?(view, "#comparison-results")
    end

    test "choosing different files releases the copy and closes the helper", context do
      {view, _pid} = open_helper(context)
      assert %{source_snapshot: %{}} = socket_assigns(view).agent_context

      view
      |> form("form#export-comparison-form",
        comparison: %{
          "left_run_id" => context.right.id,
          "right_run_id" => context.left.id,
          "from" => @from,
          "to" => @to
        }
      )
      |> render_change()

      refute has_element?(view, "#agent-panel")
      refute has_element?(view, "#comparison-helper-open")
      refute has_element?(view, "#export-helper-mode")
      refute has_element?(view, "#comparison-results")

      # The panel falls back to the feed quality helper and its own context, so
      # nothing of the released copy is left bound.
      assert socket_assigns(view).comparison_context == nil
      assert socket_assigns(view).agent_pack_id == "feed_quality"

      refute match?(
               %{source_snapshot: %{kind: "release_comparison"}},
               socket_assigns(view).agent_context
             )

      assert socket_assigns(view).agent_session == nil

      # The editor's new choice is the draft now on the form.
      assert chosen_values(view) == [
               to_string(context.right.id),
               to_string(context.left.id),
               @from,
               @to
             ]
    end

    test "closing and reopening the panel keeps the result and the conversation", context do
      {view, pid} = open_helper(context)

      view |> element("#agent-panel-close") |> render_click()

      refute has_element?(view, "#agent-panel")
      assert_push_event(view, "agent:focus", %{id: "agent-helper-open"})
      assert has_element?(view, "#comparison-results")
      assert has_element?(view, "#agent-helper-open")

      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")
      assert session_pid(view) == pid
    end

    test "a membership withdrawn after the answer stops the next question", context do
      {view, pid} = open_helper(context)

      Repo.update_all(
        from(m in UserOrgMembership, where: m.user_id == ^context.user.id),
        set: [deactivated_at: DateTime.utc_now()]
      )

      # No request is stubbed: a refused turn must never reach the provider.
      submit(view, @question)
      assert_receive {:agent_event, ^pid, {:status, :forbidden}}, 5_000

      assert render(view) =~ "Your access changed"
      assert has_element?(view, "#comparison-results")
    end
  end

  describe "the scoped evidence link" do
    test "only the current snapshot's digest links, after a fresh authorization", context do
      {view, pid} = open_helper(context)
      digest = socket_assigns(view).agent_context.source_snapshot.payload["selected_digest"]
      version_id = context.host.id

      send(
        view.pid,
        {:agent_event, pid,
         {:entry,
          assistant_entry(10, "Current.", [evidence(context, resources: [resource(digest)])])}}
      )

      assert_link(view, "#agent-evidence-10-1", "/gtfs/#{version_id}/export")

      # A digest of another comparison - stale after a narrowing, or foreign - and
      # a historical route identifier from the compared files stay plain text.
      stale = String.duplicate("0", 64)

      send(
        view.pid,
        {:agent_event, pid,
         {:entry,
          assistant_entry(11, "Stale.", [
            evidence(context,
              resources: [resource(stale), %{kind: "historical", id: "R2", label: "R2"}]
            )
          ])}}
      )

      stale_card = view |> element("#agent-evidence-11-1") |> render()
      assert stale_card |> fragment() |> query_attributes("a", "href") == []
      assert stale_card =~ "no link for this reference"
      refute stale_card =~ "/export"

      # An answer read under another version never reaches the screen at all.
      foreign = evidence(context, resources: [resource(digest)], version_id: Ecto.UUID.generate())

      send(view.pid, {:agent_event, pid, {:entry, assistant_entry(12, "Foreign.", [foreign])}})
      refute has_element?(view, "#agent-evidence-12-1")
    end

    test "a deleted compared version turns the link to text", context do
      assert_link_turns_to_text(context, fn -> Repo.delete!(context.left_version) end)
    end

    test "a withdrawn membership turns the link to text", context do
      assert_link_turns_to_text(context, fn ->
        Repo.update_all(
          from(m in UserOrgMembership, where: m.user_id == ^context.user.id),
          set: [deactivated_at: DateTime.utc_now()]
        )
      end)
    end
  end

  ## Helpers

  defp view(context) do
    {:ok, view, _html} =
      live(
        log_in_user(build_conn(), context.user, organization: context.organization),
        "/gtfs/#{context.host.id}/export"
      )

    view
  end

  # The comparison is asynchronous, so the case waits for the band to leave its
  # running state with a finite deadline rather than a sleep.
  defp compare!(view, left, right) do
    view
    |> form("form#export-comparison-form",
      comparison: %{
        "left_run_id" => left.id,
        "right_run_id" => right.id,
        "from" => @from,
        "to" => @to
      }
    )
    |> render_submit()

    wait_until(60_000, fn ->
      has_element?(view, "#comparison-status-title", "Comparison finished") or
        has_element?(view, "#comparison-status-title", "couldn’t finish")
    end)

    assert has_element?(view, "#comparison-results")
    view
  end

  defp narrow!(view, keys, dates) do
    render_submit(view, "narrow_comparison", %{
      "comparison_scope" => %{"route_pair_keys" => keys, "dates" => dates}
    })
  end

  # Runs the comparison through the ordinary form, opens the helper from its own
  # button and joins the conversation as a second listener, so the session's
  # settle events are observable without polling the render.
  defp open_helper(context) do
    view = view(context) |> compare!(context.left, context.right)
    view |> element("#comparison-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    {view, listen(view, context)}
  end

  defp listen(view, context) do
    pid = session_pid(view)

    assert {:ok, ^pid, _snapshot} =
             Agents.open(scope(context, socket_assigns(view).agent_context))

    pid
  end

  defp scope(context, resource_context) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.host.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "release_comparison",
      version_name: context.host.name,
      resource_context: resource_context
    }
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp session_pid(view), do: socket_assigns(view).agent_session

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  # The working placeholder arrives before the settled entry.
  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000
    if entry.status == :working, do: await_settled(pid), else: entry
  end

  defp wait_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("the comparison never finished")
      true -> Process.sleep(20) && do_wait_until(deadline, fun)
    end
  end

  # The four values the editor chose on the native form, as the server holds them.
  defp chosen_values(view) do
    html = view |> element("form#export-comparison-form") |> render()
    document = fragment(html)

    selected =
      for id <- ["#comparison-left", "#comparison-right"] do
        document |> LazyHTML.query("#{id} option[selected]") |> attribute_values("value") |> hd()
      end

    selected ++
      for id <- ["#comparison-from", "#comparison-to"] do
        document |> LazyHTML.query(id) |> attribute_values("value") |> hd()
      end
  end

  # The same current digest links before the change and is plain text after it,
  # because the panel authorizes the person and both compared versions again each
  # time it resolves a reference.
  defp assert_link_turns_to_text(context, change) do
    {view, pid} = open_helper(context)
    digest = socket_assigns(view).agent_context.source_snapshot.payload["selected_digest"]

    send(
      view.pid,
      {:agent_event, pid,
       {:entry,
        assistant_entry(10, "Before.", [evidence(context, resources: [resource(digest)])])}}
    )

    assert_link(view, "#agent-evidence-10-1", "/gtfs/#{context.host.id}/export")

    change.()

    send(
      view.pid,
      {:agent_event, pid,
       {:entry, assistant_entry(11, "After.", [evidence(context, resources: [resource(digest)])])}}
    )

    card = view |> element("#agent-evidence-11-1") |> render()
    assert card |> fragment() |> query_attributes("a", "href") == []
    assert card =~ "no link for this reference"
  end

  defp assert_link(view, selector, href) do
    card = view |> element(selector) |> render()
    assert card |> fragment() |> query_attributes("a", "href") == [href]
    assert card =~ "Release comparison"
  end

  defp attribute_values(nodes, name),
    do: nodes |> Enum.map(&(&1 |> LazyHTML.attribute(name) |> hd() |> to_string()))

  defp query_attributes(document, selector, name),
    do: document |> LazyHTML.query(selector) |> attribute_values(name)

  defp query_count(fragment, selector),
    do: fragment |> LazyHTML.query(selector) |> Enum.to_list() |> length()

  defp fragment(html), do: LazyHTML.from_fragment(html)

  # An entry as the session delivers it, for a late or crafted event the real
  # conversation would not produce.
  defp assistant_entry(id, text, evidence) do
    %{
      id: id,
      role: :assistant,
      status: :done,
      text: text,
      activity: [],
      evidence: evidence,
      prepared: nil,
      applied?: false
    }
  end

  defp resource(id), do: %{kind: "export_comparison", id: id, label: "Release comparison"}

  defp evidence(context, opts) do
    %{
      kind: "export_comparison",
      title: "Release comparison",
      total: 1,
      total_label: "effective service differences",
      completeness: :complete,
      completeness_reason: nil,
      facts: [],
      exclusions: [],
      source_ref: "gtfs_release_comparison",
      digest: String.duplicate("a", 64),
      source_revision: nil,
      scope: %{
        organization_id: context.organization.id,
        gtfs_version_id: Keyword.get(opts, :version_id, context.host.id),
        identity: "version:#{Keyword.get(opts, :version_id, context.host.id)}"
      },
      resources: Keyword.fetch!(opts, :resources)
    }
  end

  ## Provider boundary and process hygiene

  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp expect_reply(payload), do: expect_status(200, payload)

  # A non-200 answer from the provider boundary, so a failing request reaches the
  # panel as the real transport outcome it is.
  defp expect_status(status, payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(payload))
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
