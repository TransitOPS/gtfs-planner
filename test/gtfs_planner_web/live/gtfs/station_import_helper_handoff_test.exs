defmodule GtfsPlannerWeb.Gtfs.StationImportHelperHandoffTest do
  @moduledoc """
  Merge evidence (EV-10) for reviewing and confirming a prepared station-import
  suggestion on the ordinary import page.

  Everything here runs through the ordinary page: the real upload form starts the
  real compute worker, the real review holds the real decisions, the helper panel
  is the one this page mounted, and the prepared entry is produced by the shipped
  `station_imports` pack calling the shipped `StationAssistant` projection. The
  only doubled boundary is the final OpenRouter HTTP request, through `Req.Test`.

  The claims are the host's own:

    * opening a prepared suggestion is a read - no decision status changes, and
      the rows shown are the server's own projection of them;
    * cancelling writes nothing and hands focus back to the card it came from;
    * an explicit Confirm approves exactly the reviewed rows and records the
      captured provenance, while Apply stays a separate native act whose scope
      includes every approved row, measured or not;
    * a forged entry, a stale source and a revoked membership all refuse the
      confirmation and keep the review and the drafts;
    * a reload rebuilds the review's evidence from PostgreSQL, not from the
      conversation, and the ordinary no-helper flow still works.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlannerWeb.AgentPanel

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor
  @ask "Prepare a review of the widths these measurements support."
  @w14_decision "pathway:PW_W14"
  @other_decision "pathway:PW_OTHER"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()
    RunnerSlots.await_idle()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Station import"})

    level = level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})
    station = station_stop(organization.id, version.id, "STATION_A", level.level_id)

    entrance =
      child_stop(organization.id, version.id, station, "ENT_A", level.level_id, "Entrance A")

    platform =
      child_stop(organization.id, version.id, station, "PLAT_A", level.level_id, "Platform A")

    # A second station whose pathway the same review also changes: its approval is
    # part of the apply scope even though no suggestion ever names it.
    other_station = station_stop(organization.id, version.id, "STATION_B", level.level_id)

    other_platform =
      child_stop(
        organization.id,
        version.id,
        other_station,
        "PLAT_B",
        level.level_id,
        "Platform B"
      )

    # The accepted W14 width, the disputed W12 width of the same station, and a
    # width of the other station.
    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_W14",
      pathway_mode: 1,
      traversal_time: 45,
      min_width: Decimal.new("0.95")
    })

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_W12",
      pathway_mode: 1,
      traversal_time: 60,
      min_width: Decimal.new("1.10")
    })

    pathway_fixture(organization.id, version.id, entrance.stop_id, other_platform.stop_id, %{
      pathway_id: "PW_OTHER",
      pathway_mode: 1,
      traversal_time: 30,
      min_width: Decimal.new("0.80")
    })

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      station: station,
      conn: build_conn()
    }
  end

  describe "opening a prepared suggestion" do
    test "reads the run and offers the review without writing anything", ctx do
      view = prepared_view(ctx)
      run_id = run_id(ctx)

      assert has_element?(view, "#station-suggestion-review")
      assert has_element?(view, "#station-suggestion-confirm", "Confirm decisions")
      assert has_element?(view, "#station-suggestion-cancel", "Cancel")

      # The row is the server's own projection: this decision, its old and new
      # width, and the measurement it was reviewed against.
      assert has_element?(view, "#station-suggestion-rows [data-suggestion-row]")
      assert has_element?(view, "[data-decision-id='#{@w14_decision}']", "PW_W14")
      assert has_element?(view, "[data-decision-id='#{@w14_decision}']", "0.95")
      assert has_element?(view, "[data-decision-id='#{@w14_decision}']", "1.05")
      assert has_element?(view, "[data-decision-id='#{@w14_decision}']", "Measured 105 cm")
      assert has_element?(view, "[data-decision-id='#{@w14_decision}']", "SURVEY-88")

      # Reading a suggestion prepares nothing: no status moved (INV-2).
      assert decision_status(ctx, run_id, @w14_decision) == :pending
      assert reviewed_entries(ctx) == []
      assert has_element?(view, "#diff-review-summary", "Approve at least one change to apply")
    end

    test "cancelling writes nothing and leaves the proposal in its conversation", ctx do
      view = prepared_view(ctx)
      run_id = run_id(ctx)
      entry_id = prepared_entry_id(view, session_pid(view))

      view |> element("#station-suggestion-cancel") |> render_click()

      refute has_element?(view, "#station-suggestion-review")
      assert decision_status(ctx, run_id, @w14_decision) == :pending
      assert reviewed_entries(ctx) == []

      # Cancelling released nothing: the exact proposal is still retrievable from
      # the conversation it was prepared in.
      assert {:ok, %{command: %{kind: :station_import_selection}}} =
               Agents.prepared(session_pid(view), conversation_id(view), entry_id)
    end

    test "a malformed entry id and an entry this conversation never issued open nothing", ctx do
      view = prepared_view(ctx)
      run_id = run_id(ctx)
      _cancelled = view |> element("#station-suggestion-cancel") |> render_click()

      # A value that is not an entry id never reaches the session.
      render_click(view, "agent_review_prepared", %{"entry" => "not-an-entry"})
      refute has_element?(view, "#station-suggestion-review")

      # An entry id no turn produced is one refusal, and it discloses nothing.
      render_click(view, "agent_review_prepared", %{"entry" => "999999"})

      refute has_element?(view, "#station-suggestion-review")
      assert has_element?(view, "#agent-notice", "no longer part of this review")
      assert decision_status(ctx, run_id, @w14_decision) == :pending
      assert reviewed_entries(ctx) == []
    end

    test "a proposal from another frozen source is refused rather than shown", ctx do
      view = prepared_view(ctx)
      run_id = run_id(ctx)
      entry_id = prepared_entry_id(view, session_pid(view))
      _cancelled = view |> element("#station-suggestion-cancel") |> render_click()

      # Computing a new review replaces the run and the page's frozen source with
      # one this conversation never prepared against. The old proposal no longer
      # describes what this page would confirm, so it is refused.
      # A second accepted measurement changes the page's frozen source, so the
      # stored proposal no longer describes what this page would confirm.
      _captured = capture_measurement(view, "PW_W12", "120", "cm")
      assert run_id == run_id(ctx)
      render_click(view, "agent_review_prepared", %{"entry" => to_string(entry_id)})

      refute has_element?(view, "#station-suggestion-review")
      assert has_element?(view, "#agent-notice", "no longer part of this review")
      assert decision_status(ctx, run_id, @w14_decision) == :pending
      assert reviewed_entries(ctx) == []
    end
  end

  describe "confirming a suggestion" do
    test "approves exactly the reviewed row and records its captured provenance", ctx do
      view = prepared_view(ctx)
      run_id = run_id(ctx)

      _confirmed = view |> element("#station-suggestion-confirm") |> render_click()

      assert decision_status(ctx, run_id, @w14_decision) == :approved
      assert decision_status(ctx, run_id, "pathway:PW_W12") == :pending
      assert decision_status(ctx, run_id, @other_decision) == :pending

      # The captured measurement is persisted beside the approval, so it survives
      # this page and this conversation.
      assert [entry] = reviewed_entries(ctx)
      assert entry["decision_id"] == @w14_decision
      assert entry["station_id"] == ctx.station.id
      assert [observation] = entry["observations"]
      assert observation["original_value"] == "105"
      assert observation["normalized_value"] == "1.05"
      assert observation["source_ref"] == "SURVEY-88"

      # Confirming approved; it did not apply, and the page says so rather than
      # claiming an applied receipt the helper never earned.
      refute has_element?(view, "#station-suggestion-review")
      assert has_element?(view, "#station-suggestion-status", "Nothing has been applied yet")
      assert has_element?(view, "#diff-apply-btn", "Apply 1 change")
    end

    test "the approved apply scope names every approved row, measured or not", ctx do
      view = prepared_view(ctx)

      # A native approval of another station's pathway, made before the
      # confirmation. It belongs to the apply scope the suggestion never mentions.
      approve_natively(view, @other_decision)

      _confirmed = view |> element("#station-suggestion-confirm") |> render_click()

      assert has_element?(
               view,
               "#station-approved-apply-scope",
               "Approved changes Apply will make"
             )

      assert has_element?(view, "#station-approved-apply-scope-list", "PW_OTHER")
      assert has_element?(view, "#station-approved-apply-scope-list", "PW_W14")

      assert has_element?(
               view,
               "#station-approved-apply-scope-list [data-reviewed='true']",
               "PW_W14"
             )

      assert has_element?(
               view,
               "#station-approved-apply-scope-list [data-reviewed='false']",
               "PW_OTHER"
             )

      assert has_element?(view, "#diff-apply-btn", "Apply 2 changes")
    end

    test "a revoked membership refuses and keeps the review and every draft", ctx do
      view = prepared_view(ctx)
      run_id = run_id(ctx)

      deactivate_membership_fixture(ctx.membership)

      _confirmed = view |> element("#station-suggestion-confirm") |> render_click()

      assert has_element?(view, "#station-suggestion-error", "Nothing was approved")
      assert has_element?(view, "#station-suggestion-error", "no longer have permission")

      # The review and the captured measurement are still here, and nothing was
      # approved.
      assert has_element?(view, "#station-suggestion-row-pathway-PW_W14")
      assert has_element?(view, "#station-observation-row-0", "PW_W14")
      assert decision_status(ctx, run_id, @w14_decision) == :pending
      assert reviewed_entries(ctx) == []
    end

    test "a status change on the reviewed decision refuses the confirmation", ctx do
      view = prepared_view(ctx)
      run_id = run_id(ctx)

      # Somebody approved the very decision under review in another session. The
      # page's refresh keeps the open review, and the confirmation refuses it
      # rather than re-approving a row that is no longer pending.
      approve_decision_directly(ctx, run_id, @w14_decision, :approved)

      view
      |> element("button[phx-click='approve-decision'][phx-value-id='#{@w14_decision}']")
      |> render_click()

      _confirmed = view |> element("#station-suggestion-confirm") |> render_click()

      assert has_element?(view, "#station-suggestion-error", "Nothing was approved")
      assert decision_status(ctx, run_id, @w14_decision) == :approved

      # The other session's approval recorded no captured provenance, and this
      # refusal added none: the history is still empty.
      assert reviewed_entries(ctx) == []
    end
  end

  describe "applying after a confirmation" do
    test "the separate Apply writes the measured width and reports the actual outcome", ctx do
      view = confirmed_view(ctx)

      _applied = view |> element("#diff-apply-btn") |> render_click()
      await_change_task(view)

      # The real fenced apply wrote exactly what was reviewed.
      pathway = Gtfs.get_pathway_by_pathway_id(ctx.organization.id, ctx.version.id, "PW_W14")
      assert Decimal.equal?(pathway.min_width, Decimal.new("1.05"))

      # The outcome is told apart from what was approved before the run ran.
      assert has_element?(view, "#station-apply-outcome", "PW_W14")

      assert has_element?(
               view,
               "#station-apply-outcome [data-outcome='applied'][data-reviewed='true']",
               "confirmed against a captured measurement"
             )

      # The captured evidence is still exactly what the confirmation recorded.
      assert [%{"decision_id" => @w14_decision}] = reviewed_entries(ctx)
    end
  end

  describe "reloading and the helper-free flow" do
    test "a page reload rebuilds the evidence from PostgreSQL, not the conversation", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      view = prepared_view(%{ctx | conn: conn})
      _confirmed = view |> element("#station-suggestion-confirm") |> render_click()

      assert decision_status(ctx, run_id(ctx), @w14_decision) == :approved

      # The reload never opens the helper, and still knows which approval carries
      # captured provenance.
      {:ok, reloaded, _html} = live(conn, "/gtfs/#{ctx.version.id}/import")

      assert has_element?(
               reloaded,
               "#station-approved-apply-scope-list [data-reviewed='true']",
               "PW_W14"
             )

      assert has_element?(reloaded, "#diff-apply-btn", "Apply 1 change")
      refute has_element?(reloaded, "#agent-panel")
      refute has_element?(reloaded, "#station-suggestion-review")
    end

    test "the native approval and apply flow still works with the helper never opened", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{ctx.version.id}/import")
      view = compute_import(view, "1.05")

      refute has_element?(view, "#agent-panel")

      approve_natively(view, @w14_decision)

      assert has_element?(view, "#diff-apply-btn", "Apply 1 change")

      # An approval with no captured measurement says so rather than borrowing the
      # helper's provenance.
      assert has_element?(
               view,
               "#station-approved-apply-scope-list [data-reviewed='false']",
               "approved natively"
             )

      _applied = view |> element("#diff-apply-btn") |> render_click()
      await_change_task(view)

      pathway = Gtfs.get_pathway_by_pathway_id(ctx.organization.id, ctx.version.id, "PW_W14")
      assert Decimal.equal?(pathway.min_width, Decimal.new("1.05"))
      assert reviewed_entries(ctx) == []
    end
  end

  ## Views and interaction

  # The ordinary page with a real computed review, this station selected, one
  # accepted measurement captured and a real prepared suggestion on screen.
  defp prepared_view(ctx) do
    conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{ctx.version.id}/import")
    view = compute_import(view, "1.05")

    choose_station(view, "STATION_A")
    capture_measurement(view, "PW_W14", "105", "cm")

    prepare_suggestion(view, [@w14_decision])
  end

  defp confirmed_view(ctx) do
    view = prepared_view(ctx)
    _confirmed = view |> element("#station-suggestion-confirm") |> render_click()
    view
  end

  defp compute_import(view, w14_width) do
    view
    |> element("#import-source-form")
    |> render_change(%{"source" => "station"})

    select_diff_file(
      view,
      "pathways.txt",
      "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,traversal_time,min_width\n" <>
        "PW_W14,ENT_A,PLAT_A,1,1,45,#{w14_width}\n" <>
        "PW_W12,ENT_A,PLAT_A,1,1,60,1.2\n" <>
        "PW_OTHER,ENT_A,PLAT_B,1,1,30,0.9\n"
    )

    view |> form("#diff-upload-form") |> render_submit()
    await_change_task(view)
  end

  defp choose_station(view, stop_id) do
    _chosen =
      view
      |> form("#station-observation-scope-form", %{
        "station_observation_scope" => %{"station_stop_id" => stop_id}
      })
      |> render_change()

    view
  end

  defp capture_measurement(view, pathway_id, value, unit) do
    _saved =
      view
      |> form("#station-observation-form", %{
        "station_observation" => %{
          "pathway_id" => pathway_id,
          "original_value" => value,
          "unit" => unit,
          "captured_date" => "2026-09-18",
          "meaning" => "minimum_clear_width",
          "source_ref" => "SURVEY-88",
          "journal_entry_id" => "",
          "accepted" => "true",
          "conflict" => "false"
        }
      })
      |> render_submit()

    view
  end

  defp approve_natively(view, decision_id) do
    _approved =
      view
      |> element("button[phx-click='approve-decision'][phx-value-id='#{decision_id}']")
      |> render_click()

    view
  end

  # A real turn in a real conversation: the shipped pack runs its real
  # preparation and only the provider's HTTP reply is doubled.
  defp prepare_suggestion(view, decision_ids) do
    pid = open_helper(view)

    expect_reply(
      tool_calls_reply([
        {"call_1", "prepare_station_import_decisions",
         Jason.encode!(%{decision_ids: decision_ids})}
      ])
    )

    expect_reply(text_reply("One width decision is prepared for your review."))

    _submitted =
      view |> element("#agent-composer") |> render_submit(%{"agent" => %{"message" => @ask}})

    assert await_settled(pid).status == :done

    entry_id = prepared_entry_id(view, pid)
    assert has_element?(view, "#agent-review-prepared-#{entry_id}", "Review")

    _opened = view |> element("#agent-review-prepared-#{entry_id}") |> render_click()
    view
  end

  # Opening the panel and joining the conversation as a second listener, so the
  # session's own settle events are observable without polling or sleeping.
  defp open_helper(view) do
    _opened = view |> element("#station-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")
    pid = session_pid(view)

    assert {:ok, ^pid, _snapshot} = Agents.open(AgentPanel.scope(:sys.get_state(view.pid).socket))
    pid
  end

  # The id of the entry this conversation actually prepared, read back from the
  # session rather than assumed.
  defp prepared_entry_id(view, pid) do
    assert {:ok, ^pid, snapshot} = Agents.open(AgentPanel.scope(:sys.get_state(view.pid).socket))

    assert [entry_id] =
             snapshot.entries
             |> Enum.filter(&(&1.prepared != nil))
             |> Enum.map(& &1.id)

    entry_id
  end

  defp run_id(ctx) do
    case ChangeRuns.latest_for_version(ctx.organization.id, ctx.version.id) do
      nil -> nil
      run -> run.id
    end
  end

  defp decision_status(ctx, run_id, decision_id) do
    ctx.organization.id
    |> ChangeRuns.list_decisions(run_id)
    |> Enum.find(&(&1.decision_id == decision_id))
    |> Map.fetch!(:status)
  end

  defp reviewed_entries(ctx) do
    ctx.organization.id
    |> ChangeRuns.get_for_version(ctx.version.id, run_id(ctx))
    |> ChangeRuns.reviewed_evidence()
  end

  # Another session's approval of the same decision: the page's own refresh does
  # not learn of it until an event arrives, which is exactly the interleaving the
  # confirmation has to refuse.
  defp approve_decision_directly(ctx, run_id, decision_id, status) do
    {:ok, _decision} =
      ChangeRuns.set_decision_status(ctx.organization.id, run_id, decision_id, status)
  end

  defp select_diff_file(view, filename, content) do
    view
    |> file_input("#diff-upload-form", :diff_files, [
      %{name: filename, content: content, type: "text/plain"}
    ])
    |> render_upload(filename)
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working, do: await_settled(pid), else: entry
  end

  defp await_change_task(view) do
    for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    RunnerSlots.await_idle()
    view
  end

  defp conversation_id(view), do: :sys.get_state(view.pid).socket.assigns.agent_conversation_id

  defp session_pid(view), do: :sys.get_state(view.pid).socket.assigns.agent_session

  ## Fixtures

  defp station_stop(organization_id, version_id, stop_id, level_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Station #{String.replace_prefix(stop_id, "STATION_", "")}",
      location_type: 1,
      level_id: level_id,
      stop_lat: Decimal.new("39.9526"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  defp child_stop(organization_id, version_id, station, stop_id, level_id, name) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: name,
      location_type: if(stop_id =~ "ENT_", do: 2, else: 0),
      parent_station: station.stop_id,
      level_id: level_id,
      stop_lat: Decimal.new("39.9526"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
  end

  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for session <- Enum.reject(session_pids(), &(&1 in before)) do
        DynamicSupervisor.terminate_child(SessionSupervisor, session)
      end
    end)
  end

  defp session_pids do
    SessionSupervisor
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

  defp text_reply(content) do
    %{
      "id" => "gen-test-text",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 16, "cost" => 0.0}
    }
  end

  defp tool_calls_reply(calls) do
    %{
      "id" => "gen-test-tool",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" =>
              Enum.map(calls, fn {id, name, arguments} ->
                %{
                  "id" => id,
                  "type" => "function",
                  "function" => %{"name" => name, "arguments" => arguments}
                }
              end)
          }
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 32, "cost" => 0.0}
    }
  end
end
