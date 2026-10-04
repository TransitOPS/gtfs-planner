defmodule GtfsPlannerWeb.Gtfs.StationResultsHelperTest do
  @moduledoc """
  Merge evidence (EV-8) for the recorded-result helper through the two ordinary
  hosts: the station report and the selected reachability result.

  The page, the conversation session and the turn task are three processes, so
  the Req.Test plug and the SQL sandbox are shared (`async: false`). Only the
  OpenRouter HTTP boundary is scripted: the panel, the facade, the session, the
  turn loop, the dispatch fence, the registered `station_results` pack and the
  station projection are the shipped ones, and no agent assign is injected. The
  station, the run and every recorded fact come from the domain fixtures.

  The claims are the ones the hosts are responsible for: a recorded check is
  only explained when a person selects it, the panel's server evidence carries
  the recorded and current facts with the links this scope can still prove, and
  a replaced station, run, version, session or membership cannot leave an old
  card on the screen. No host action on these pages starts a check, and the
  result card offers no action at all.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Reachability.Envelope
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Validations.ValidationRun

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor
  @recorded_schema_version 1
  @first_message "What did the recorded check say about this station?"
  @reply "The recorded check found one walking pair with no recorded path."
  @tool_arguments ~s({})

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()
    RunnerSlots.await_idle()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Station helper"})

    _level = level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})
    station = station_stop(organization.id, version.id, "STATION_A")
    entrance = child_stop(organization.id, version.id, station, "ENT_A", "Entrance A")
    platform = child_stop(organization.id, version.id, station, "PLAT_A", "Platform A")

    _pathway =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_A",
        pathway_mode: 1,
        traversal_time: 45,
        min_width: Decimal.new("1.05")
      })

    # A second station of this version, for a switch that must reset the panel,
    # and a second version and organization, for the forged cases.
    other_station = station_stop(organization.id, version.id, "STATION_B")
    other_version = gtfs_version_fixture(organization.id, %{name: "Other version"})
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_station = station_stop(foreign_organization.id, foreign_version.id, "STATION_A")

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      station: station,
      other_station: other_station,
      other_version: other_version,
      foreign_organization: foreign_organization,
      foreign_version: foreign_version,
      foreign_station: foreign_station,
      conn: build_conn()
    }
  end

  describe "the report host" do
    test "mounts the registered result pack and starts with no recorded check selected", ctx do
      run = recorded_run(ctx)
      view = report_view(ctx, ctx.station)

      # No agent assign was injected: the panel is on the page because the host
      # mounted it, and the selector exists because the station resolved.
      assert has_element?(view, "#station-helper-open")
      assert has_element?(view, "#station-result-run-select")
      assert has_element?(view, "#station-helper-freshness", "No recorded check is selected")
      assert has_element?(view, "#station-report-2")
      assert has_element?(view, "#report-expand-all")

      refute has_element?(view, "#agent-panel")

      # The panel's own context is the whole version plus this station's server
      # built snapshot, with no run selected: the latest run is never silently
      # treated as the person's choice.
      assert %{source_snapshot: %{kind: "station_results", payload: payload}} =
               panel_context(view)

      assert payload == %{
               "station_id" => ctx.station.id,
               "station_stop_id" => "STATION_A",
               "run_id" => nil
             }

      assert Enum.map(runs_offered(view), & &1) == [run.id]
    end

    test "opening the helper focuses its composer and closing it returns focus to the station button",
         ctx do
      view = report_view(ctx, ctx.station)

      view |> element("#station-helper-open") |> render_click()
      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})

      view |> element("#agent-panel-close") |> render_click()
      refute has_element?(view, "#agent-panel")
      assert_push_event(view, "agent:focus", %{id: "station-helper-open"})
    end

    test "a selected recorded check becomes a new conversation with its own snapshot", ctx do
      run = recorded_run(ctx)
      view = report_view(ctx, ctx.station)

      view
      |> form("#station-result-run-select", %{"run_id" => run.id})
      |> render_change()

      assert has_element?(view, "#station-helper-freshness", "recorded its input")
      assert panel_context(view).source_snapshot.payload["run_id"] == run.id

      # Selecting nothing again returns the page to the facts-only conversation.
      view
      |> form("#station-result-run-select", %{"run_id" => ""})
      |> render_change()

      assert is_nil(panel_context(view).source_snapshot.payload["run_id"])
    end

    test "a run the page never offered cannot be selected", ctx do
      foreign_run =
        insert_run(ctx, ctx.foreign_organization.id, ctx.foreign_version.id, ctx.station)

      view = report_view(ctx, ctx.station)

      # The form only offers the page's own runs, so the forged value is sent as
      # the raw event a modified client could push.
      render_hook(view, "select_result_run", %{"run_id" => foreign_run.id})

      assert panel_context(view).source_snapshot.payload["run_id"] == nil
      assert has_element?(view, "#station-helper-freshness", "No recorded check is selected")
    end

    test "an explained check shows the recorded facts and this scope's own links", ctx do
      run = recorded_run(ctx)
      {view, pid} = open_helper(ctx, ctx.station, run)

      expect_reply(tool_calls_reply([{"call_1", "get_station_result", @tool_arguments}]))
      expect_reply(text_reply(@reply))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      card = view |> element("[data-evidence-kind=recorded_result]") |> render()

      # The server owns the headline, the recorded digest and the equality
      # verdict; the model's sentence never becomes one of them.
      assert card =~ "Recorded station check"
      assert card =~ "Recorded input digest"
      assert card =~ "match"
      assert card =~ short_digest(input_digest(ctx))
      assert render(view) =~ "Model reply"

      # The two typed references resolve only because this panel still holds
      # their station and their selected run.
      assert card =~ "/gtfs/#{ctx.version.id}/stops/STATION_A/report"
      assert card =~ "/gtfs/#{ctx.version.id}/station-reachability/#{run.id}"

      # A read carries no action: nothing to review, confirm or apply.
      refute card =~ "agent-review-prepared"
      refute render(view) =~ "Apply"
    end

    test "the current facts stay readable with no recorded check selected", ctx do
      _run = recorded_run(ctx)
      {view, pid} = open_helper(ctx, ctx.station, nil)

      expect_reply(tool_calls_reply([{"call_1", "get_station_report_facts", @tool_arguments}]))
      expect_reply(text_reply("No failing data-quality checks right now."))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      card = view |> element("[data-evidence-kind=station_report_facts]") |> render()
      assert card =~ "Current station report facts"
      assert card =~ "Separate source"
      assert card =~ "/gtfs/#{ctx.version.id}/stops/STATION_A/report"
    end

    test "switching station retires the conversation and the previous evidence", ctx do
      run = recorded_run(ctx)
      {view, pid} = open_helper(ctx, ctx.station, run)

      expect_reply(tool_calls_reply([{"call_1", "get_station_result", @tool_arguments}]))
      expect_reply(text_reply(@reply))

      submit(view, @first_message)
      assert await_settled(pid).status == :done
      assert has_element?(view, "[data-evidence-kind]")

      render_async(view, 5_000)

      # A different station is a different conversation: the old card and the old
      # run selection are gone, and this station has no recorded check of its own.
      render_patch(view, "/gtfs/#{ctx.version.id}/stops/#{ctx.other_station.stop_id}/report")
      render_async(view, 5_000)

      payload = panel_context(view).source_snapshot.payload
      assert payload["station_stop_id"] == "STATION_B"
      assert is_nil(payload["run_id"])
      refute has_element?(view, "[data-evidence-kind]")
      assert runs_offered(view) == []

      # An answer read under the replaced station cannot come back through the
      # session this panel released.
      send(view.pid, {:agent_event, pid, {:entry, stale_entry(ctx.station.stop_id)}})
      refute has_element?(view, "[data-evidence-kind]")
    end

    test "a close and reopen after a late exit shows only its own conversation, never an injected entry",
         ctx do
      run = recorded_run(ctx)
      {view, pid} = open_helper(ctx, ctx.station, run)

      expect_reply(tool_calls_reply([{"call_1", "get_station_result", @tool_arguments}]))
      expect_reply(text_reply(@reply))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      view |> element("#agent-panel-close") |> render_click()
      refute has_element?(view, "#agent-panel")

      # An entry delivered by the session this panel just released, and the
      # session's own end, cannot repaint the panel.
      send(view.pid, {:agent_event, pid, {:entry, stale_entry(ctx.station.stop_id)}})
      send(view.pid, {:agent_event, pid, {:status, :ended}})
      send(view.pid, {:DOWN, make_ref(), :process, pid, :normal})

      refute has_element?(view, "[data-evidence-kind]")

      view |> element("#station-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")

      # Reopening rejoins the same conversation about the same source, so its own
      # answered turn is still there; the entry injected after the close is not.
      assert has_element?(view, "[data-evidence-kind=recorded_result]")
      refute render(view) =~ "An answer from the replaced conversation."

      # The same conversation can explain the same run again.
      expect_reply(tool_calls_reply([{"call_2", "get_station_result", @tool_arguments}]))
      expect_reply(text_reply(@reply))

      submit(view, @first_message)
      assert await_settled(pid).status == :done
      assert has_element?(view, "[data-evidence-kind]")
    end

    test "a revoked membership stops the panel and leaves the report complete", ctx do
      run = recorded_run(ctx)
      {view, pid} = open_helper(ctx, ctx.station, run)

      # Access is withdrawn between the tool call and the model's next turn.
      deactivate_during(
        tool_calls_reply([{"call_2", "get_station_report_facts", @tool_arguments}]),
        ctx
      )

      submit(view, @first_message)

      assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant, status: :forbidden}}},
                     5_000

      assert_receive {:agent_event, ^pid, {:status, :forbidden}}, 5_000

      # The native report is untouched: every section is still rendered and the
      # selector still works, so a person without the helper keeps the page.
      assert has_element?(view, "#station-report-2")
      assert has_element?(view, "#station-result-run-select")
      assert element(view, "#agent-panel") |> render() =~ "Your access changed"
    end
  end

  describe "the selected result host" do
    test "derives its station from the scoped run, not from a query parameter", ctx do
      run = recorded_run(ctx)
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)

      # A forged parameter names a station this run was never recorded for; the
      # page and its conversation still follow the run's own metadata.
      assert {:ok, view, _html} =
               live(
                 conn,
                 "/gtfs/#{ctx.version.id}/station-reachability/#{run.id}?stop_id=STATION_B"
               )

      assert render(view) =~ ctx.station.stop_id
      refute render(view) =~ ctx.other_station.stop_id
      assert has_element?(view, "#station-helper-open")
      assert has_element?(view, "#station-helper-freshness", "recorded its input")

      payload = panel_context(view).source_snapshot.payload

      assert payload == %{
               "station_id" => ctx.station.id,
               "station_stop_id" => "STATION_A",
               "run_id" => run.id
             }
    end

    test "closing the helper returns focus to the result page's own button", ctx do
      view = result_view(ctx, recorded_run(ctx))

      view |> element("#station-helper-open") |> render_click()
      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})

      view |> element("#agent-panel-close") |> render_click()
      assert_push_event(view, "agent:focus", %{id: "station-helper-open"})
    end

    test "explains the result on screen and starts no check", ctx do
      run = recorded_run(ctx)
      view = result_view(ctx, run)

      run_count_before = Repo.aggregate(ValidationRun, :count)

      {view, pid} = open_panel(view)
      assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(ctx, ctx.station, run))

      expect_reply(tool_calls_reply([{"call_1", "get_station_result", @tool_arguments}]))
      expect_reply(text_reply(@reply))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      card = view |> element("[data-evidence-kind=recorded_result]") |> render()
      assert card =~ "Recorded station check"
      assert card =~ "/gtfs/#{ctx.version.id}/station-reachability/#{run.id}"

      # A read explains; it never starts a check, prepares a change or offers an
      # apply action, and the run's own row is untouched.
      assert Repo.aggregate(ValidationRun, :count) == run_count_before
      assert Repo.get!(ValidationRun, run.id).status == "completed"
      refute render(view) =~ "agent-review-prepared"
      refute render(view) =~ "request_apply"
    end

    test "a legacy run with no recorded input reads as unknown, not as a match", ctx do
      legacy =
        insert_run(ctx, ctx.organization.id, ctx.version.id, ctx.station, %{
          engine: nil,
          result_json: %{"pairs" => []}
        })

      view = result_view(ctx, legacy)

      assert has_element?(view, "#station-helper-freshness", "recorded no input digest")

      {view, pid} = open_panel(view)
      assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(ctx, ctx.station, legacy))

      expect_reply(tool_calls_reply([{"call_1", "get_station_result", @tool_arguments}]))
      expect_reply(text_reply("This check predates the recorded schema."))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      card = view |> element("[data-evidence-kind=recorded_result]") |> render()
      assert card =~ "unknown"
    end

    test "a run from another organization is refused without disclosing its station", ctx do
      foreign_run =
        insert_run(ctx, ctx.foreign_organization.id, ctx.foreign_version.id, ctx.foreign_station)

      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)

      assert {:error, {:live_redirect, %{to: to_path}}} =
               live(conn, "/gtfs/#{ctx.version.id}/station-reachability/#{foreign_run.id}")

      # The refusal names only the version this person is already in: no station,
      # no outcome and no run id of the other organization reached the page.
      assert to_path == "/gtfs/#{ctx.version.id}/export"
    end

    test "a run with no station record leaves the helper visibly unavailable", ctx do
      run =
        insert_run(ctx, ctx.organization.id, ctx.version.id, nil, %{result_json: %{"pairs" => []}})

      view = result_view(ctx, run)

      assert has_element?(view, "#reachability-station-unknown")
      assert has_element?(view, "#station-helper-notice", "helper has nothing to read")

      {view, _pid} = open_panel(view)
      assert element(view, "#agent-panel") |> render() =~ "unavailable"
    end
  end

  ## Hosts

  defp report_view(ctx, station) do
    conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)

    assert {:ok, view, _html} =
             live(conn, "/gtfs/#{ctx.version.id}/stops/#{station.stop_id}/report")

    render_async(view, 5_000)
    view
  end

  defp result_view(ctx, run) do
    conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)

    assert {:ok, view, _html} =
             live(conn, "/gtfs/#{ctx.version.id}/station-reachability/#{run.id}")

    view
  end

  defp open_panel(view) do
    view |> element("#station-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")
    pid = session_pid(view)
    {view, pid}
  end

  # Opens the panel and joins the same conversation through the facade as a
  # second listener, so the session's own settle events are observable without
  # polling the render or sleeping.
  defp open_helper(ctx, station, run) do
    view = report_view(ctx, station)

    view
    |> form("#station-result-run-select", %{"run_id" => run && run.id})
    |> render_change()

    {view, pid} = open_panel(view)
    assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(ctx, station, run))

    {view, pid}
  end

  defp panel_context(view) do
    :sys.get_state(view.pid).socket.assigns.agent_context
  end

  defp runs_offered(view) do
    view
    |> element("#station-result-run-select-input")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option[value]")
    |> Enum.map(fn option -> option |> LazyHTML.attribute("value") |> to_string() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp session_pid(view), do: :sys.get_state(view.pid).socket.assigns.agent_session

  # The same scope the host built: the whole-version identity plus the station
  # snapshot, so the facade resolves this panel's own conversation.
  defp panel_scope(ctx, station, run) do
    {:ok, resource_context} =
      Scope.context({:version, ctx.version.id})
      |> Scope.with_source_snapshot(%{
        kind: "station_results",
        payload: %{
          "station_id" => station.id,
          "station_stop_id" => station.stop_id,
          "run_id" => run && run.id
        }
      })

    %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.user.id,
      user_email: ctx.user.email,
      pack_id: "station_results",
      version_name: ctx.version.name,
      resource_context: resource_context
    }
  end

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  ## Fixtures

  defp station_stop(organization_id, version_id, stop_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Station #{stop_id}",
      location_type: 1,
      stop_lat: Decimal.new("39.9526"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  defp child_stop(organization_id, version_id, station, stop_id, name) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: name,
      location_type: if(stop_id =~ "ENT_", do: 2, else: 0),
      parent_station: station.stop_id,
      stop_lat: Decimal.new("39.9526"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  # The digest the production `Envelope` computes over this station's current
  # input, so the equality the projection reports is the one a real run records.
  defp input_digest(ctx) do
    {:ok, snapshot} =
      Gtfs.get_station_report_snapshot(ctx.organization.id, ctx.version.id, ctx.station.stop_id)

    Envelope.input_provenance(snapshot)["digest"]
  end

  defp short_digest(digest), do: binary_part(digest, 0, 12)

  # The envelope is hand-written: its pairs, indices and recorded reason are
  # stated here, so the panel is compared against an expected answer.
  defp recorded_run(ctx) do
    insert_run(ctx, ctx.organization.id, ctx.version.id, ctx.station, %{
      result_json:
        Map.put(
          envelope(ctx, ctx.station.stop_id),
          "input_provenance",
          %{
            "version" => 1,
            "digest" => input_digest(ctx),
            "closure_evaluation" => "not_evaluated"
          }
        )
    })
  end

  defp envelope(_ctx, station_stop_id) do
    %{
      "engine" => "pathways_router",
      "engine_ref" => "f1bf1b58e29307d410742af95dfde18111bcb07a",
      "result_schema_version" => @recorded_schema_version,
      "preferences" => "default",
      "metadata" => %{"station_stop_id" => station_stop_id},
      "outcome" => "passed",
      "topology" => %{
        "entrance_count" => 1,
        "platform_count" => 1,
        "pathway_count" => 1,
        "level_count" => 1
      },
      "totals" => %{"pair_count" => 1, "reachable" => 0, "unreachable" => 1, "invalid" => 0},
      "diagnostics" => [],
      "pairs" => [pair(0, "walking", "unreachable", "no_path")],
      "started_at" => "2026-10-02T09:00:00Z",
      "completed_at" => "2026-10-02T09:00:12Z",
      "duration_ms" => 12
    }
  end

  defp pair(index, mode, outcome, reason) do
    %{
      "index" => index,
      "kind" => "entrance_platform",
      "mode" => mode,
      "from_stop_id" => "ENT_A",
      "from_stop_name" => "Entrance A",
      "to_stop_id" => "PLAT_A",
      "to_stop_name" => "Platform A",
      "outcome" => outcome,
      "reason" => reason,
      "duration_seconds" => nil,
      "distance_meters" => nil,
      "step_count" => nil
    }
  end

  defp insert_run(_ctx, organization_id, version_id, station, overrides \\ %{}) do
    attrs =
      %{
        organization_id: organization_id,
        gtfs_version_id: version_id,
        run_type: "station_reachability",
        status: "completed",
        engine: "pathways_router",
        result_schema_version: @recorded_schema_version,
        started_at: DateTime.utc_now(),
        result_json: %{}
      }
      |> Map.merge(Map.new(overrides))

    attrs
    |> Map.put(:result_json, with_station_metadata(attrs.result_json, station))
    |> then(&struct!(ValidationRun, &1))
    |> Repo.insert!()
  end

  defp with_station_metadata(%{"metadata" => _} = result_json, _station), do: result_json

  defp with_station_metadata(result_json, nil) when is_map(result_json), do: result_json

  defp with_station_metadata(result_json, station) when is_map(result_json),
    do: Map.put(result_json, "metadata", %{"station_stop_id" => station.stop_id})

  defp with_station_metadata(_result_json, _station),
    do: %{"metadata" => %{}}

  # An assistant entry carrying one evidence card for this station, delivered by
  # a session the panel no longer owns.
  defp stale_entry(station_stop_id) do
    %{
      id: 99,
      role: :assistant,
      text: "An answer from the replaced conversation.",
      status: :done,
      activity: [],
      prepared: nil,
      applied?: false,
      evidence: [
        %{
          kind: "recorded_result",
          title: "Recorded station check",
          total: 1,
          total_label: "pairs in this answer",
          completeness: :complete,
          completeness_reason: nil,
          source_ref: "gtfs_station_assistant",
          digest: String.duplicate("a", 64),
          source_revision: nil,
          scope: %{
            organization_id: nil,
            gtfs_version_id: nil,
            identity: "station:#{station_stop_id}"
          },
          exclusions: [],
          resources: [%{kind: "station", id: station_stop_id}],
          facts: [%{label: "Run state", value: "recorded"}]
        }
      ]
    }
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

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
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

  # Withdraws access at the moment the next provider request is made, so the
  # turn that follows it is refused by the session's own membership check.
  defp deactivate_during(payload, ctx) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      deactivate_membership_fixture(ctx.membership)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)

    payload
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
