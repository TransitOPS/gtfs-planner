defmodule GtfsPlannerWeb.Gtfs.StationObservationMappingTest do
  @moduledoc """
  Merge evidence (EV-9) for native accepted-measurement capture on the import page.

  Everything here runs through the ordinary page: the real upload form starts the
  real compute worker, the real review holds the real decisions, and the mapping
  form is the shipped one. The only doubled boundary is the final OpenRouter HTTP
  request, through `Req.Test`; the panel, the session, the dispatch fence, the
  registered `station_imports` pack and the `StationAssistant` projection are the
  shipped ones, and no agent assign, snapshot or registration is injected.

  The claims are the host's own:

    * a station is chosen from the rows this review actually changes, and a
      measurement is checked against the run before the helper can read it;
    * an accepted measurement freezes into the page's own `station_imports`
      snapshot, so the real pack answers with it, and changing the captured
      source starts a different conversation;
    * a refused write - a foreign station, a foreign journal note, an unsupported
      unit or a missing meaning, a withdrawn membership - keeps the draft,
      changes no decision status and moves no context;
    * no measurement at all still opens the helper as a summary, and the native
      review works with the helper never opened.
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
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlannerWeb.AgentPanel

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor
  @first_message "Which of this station's widths do the accepted measurements support?"
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
    version = gtfs_version_fixture(organization.id, %{name: "Station import"})

    level = level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})

    station = station_stop(organization.id, version.id, "STATION_A", level.level_id)

    entrance =
      child_stop(organization.id, version.id, station, "ENT_A", level.level_id, "Entrance A")

    platform =
      child_stop(organization.id, version.id, station, "PLAT_A", level.level_id, "Platform A")

    # The disputed W12 width and the accepted W14 width of the same station, plus
    # a second station whose pathway this review also changes.
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

    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)

    foreign_station =
      station_stop(foreign_organization.id, foreign_version.id, "STATION_A", level.level_id)

    foreign_platform =
      child_stop(
        foreign_organization.id,
        foreign_version.id,
        foreign_station,
        "PLAT_F",
        level.level_id,
        "Platform F"
      )

    pathway_fixture(
      foreign_organization.id,
      foreign_version.id,
      entrance.stop_id,
      foreign_platform.stop_id,
      %{
        pathway_id: "PW_FOREIGN",
        pathway_mode: 1,
        traversal_time: 30,
        min_width: Decimal.new("0.70")
      }
    )

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      station: station,
      other_station: other_station,
      foreign_organization: foreign_organization,
      foreign_version: foreign_version,
      foreign_station: foreign_station,
      conn: build_conn()
    }
  end

  describe "the native mapping form" do
    test "offers only the stations this review changes, and nothing is captured yet", ctx do
      view = computed_import_view(ctx)

      assert has_element?(view, "#station-observation-scope-form")
      assert has_element?(view, "#station-helper-open")
      assert has_element?(view, "#station-observation-list")
      assert has_element?(view, "#station-observation-empty", "No measurement is captured")
      refute has_element?(view, "#station-observation-form")
      refute has_element?(view, "#station-observation-error")

      # STATION_A and STATION_B own a pathway this review changes; the foreign
      # station belongs to another organization and is never offered.
      assert offered_stations(view) == ["STATION_A", "STATION_B"]

      # Nothing is selected, so the helper is bound to the whole version only and
      # the pack would refuse - visibly, without taking anything away.
      assert %{source_snapshot: nil} = panel_context(view)

      assert has_element?(
               view,
               "#station-helper-freshness",
               "Choose a station to use the import helper"
             )
    end

    test "a selected station renders its own review pathways and freezes no measurement", ctx do
      view = computed_import_view(ctx)

      choose_station(view, "STATION_A")

      assert has_element?(view, "#station-observation-form")
      # PW_OTHER runs from this station's entrance to the other station's
      # platform, so this review changes it and it is offered here too.
      assert offered_pathways(view) == ["PW_OTHER", "PW_W12", "PW_W14"]
      assert has_element?(view, "#station-observation-unit")
      assert has_element?(view, "#station-observation-meaning")
      assert has_element?(view, "#station-observation-accepted")
      assert has_element?(view, "#station-observation-conflict")
      assert has_element?(view, "#station-observation-save", "Save measurement")

      # The snapshot names this station and this run, with no observations yet:
      # the helper can summarize the run and prepare nothing (AC-8).
      assert %{kind: "station_imports", payload: payload} = station_imports_snapshot(view)
      assert payload["station_id"] == ctx.station.id
      assert payload["station_stop_id"] == "STATION_A"
      assert payload["observations"] == []
      assert is_binary(payload["observations_digest"])
    end

    test "an accepted measurement is normalized, listed and frozen for the helper", ctx do
      view = computed_import_view(ctx)
      run_id = run_id(ctx)

      choose_station(view, "STATION_A")
      capture_measurement(view, measurement("PW_W14", "105", "cm"))

      assert has_element?(view, "#station-observation-row-0", "PW_W14 · 1.05 m")
      assert has_element?(view, "#station-observation-row-0", "Measured 105 cm")
      assert has_element?(view, "#station-observation-notice", "Nothing is approved")
      refute has_element?(view, "#station-observation-error")

      # The frozen row is the server's normalized, still-raw-for-the-domain
      # measurement, and it is bound to this run's own station.
      assert %{kind: "station_imports", payload: payload} = station_imports_snapshot(view)
      assert payload["station_id"] == ctx.station.id
      assert payload["change_run_id"] == run_id

      assert [row] = payload["observations"]
      assert row["target"] == %{"pathway_id" => "PW_W14"}
      assert row["field"] == "min_width"
      assert row["original_value"] == "105"
      assert row["unit"] == "cm"
      assert row["meaning"] == "minimum_clear_width"
      assert row["accepted"] == true
      assert row["conflict"] == false

      # Capturing a measurement is not approving one (INV-2).
      assert decision_status(ctx, run_id, "pathway:PW_W14") == :pending
    end

    test "the accepted source is read by the real pack through the panel this page mounted",
         ctx do
      view = computed_import_view(ctx)

      choose_station(view, "STATION_A")
      capture_measurement(view, measurement("PW_W14", "105", "cm"))

      pid = open_helper(view)
      expect_reply(tool_calls_reply([{"call_1", "get_observation_provenance", @tool_arguments}]))
      expect_reply(text_reply("One accepted measurement supports a review."))

      submit(view, @first_message)
      assert await_settled(pid).status == :done

      card = view |> element("[data-evidence-kind=station_observation_provenance]") |> render()
      assert card =~ "Accepted field observations"
      assert card =~ "1 accepted observation"

      # The measurement reaches the model converted and exactly as captured.
      assert_receive {:model_request, request}, 5_000
      encoded = Jason.encode!(request)
      assert encoded =~ "PW_W14"
      assert encoded =~ "1.05"
      assert encoded =~ "minimum_clear_width"
    end

    test "a captured journal note is frozen by identity and never by its text", ctx do
      view = computed_import_view(ctx)
      entry = journal_entry(ctx, "SENTINEL-JOURNAL-PROSE-DO-NOT-SEND")

      choose_station(view, "STATION_A")

      capture_measurement(
        view,
        measurement("PW_W14", "105", "cm") |> Map.put("journal_entry_id", entry.id)
      )

      assert [row] = snapshot_payload(view)["observations"]
      assert row["source_ref"] == entry.id

      pid = open_helper(view)
      expect_reply(tool_calls_reply([{"call_1", "get_observation_provenance", @tool_arguments}]))
      expect_reply(text_reply("One accepted measurement."))
      submit(view, @first_message)
      assert await_settled(pid).status == :done

      assert_receive {:model_request, request}, 5_000
      encoded = Jason.encode!(request)
      refute encoded =~ "SENTINEL-JOURNAL-PROSE-DO-NOT-SEND"
      refute encoded =~ ctx.user.email
    end

    test "an unsupported unit, a missing meaning and a nonpositive value each keep the draft",
         ctx do
      view = computed_import_view(ctx)
      run_id = run_id(ctx)

      choose_station(view, "STATION_A")

      for {params, message, forged_value} <- [
            {%{"unit" => "ft"}, "only units", "105"},
            {%{"meaning" => "door_width"}, "the minimum clear width", "105"},
            {%{"original_value" => "0"}, "greater than zero", "0"}
          ] do
        forge_measurement(
          view,
          "station-observation-save",
          Map.merge(measurement("PW_W14", "105", "cm"), params)
        )

        assert has_element?(view, "#station-observation-error", message)
        assert has_element?(view, "#station-observation-error", "your entry is still here")
        # The draft survives the refusal rather than being cleared.
        assert has_element?(view, "#station-observation-value[value='#{forged_value}']")
        assert has_element?(view, "#station-observation-date")
        # Nothing was captured, and no decision changed.
        assert snapshot_payload(view)["observations"] == []
        assert decision_status(ctx, run_id, "pathway:PW_W14") == :pending
      end
    end

    test "a pathway this review does not change, or another station's, is refused", ctx do
      view = computed_import_view(ctx)
      run_id = run_id(ctx)

      choose_station(view, "STATION_A")
      forge_measurement(view, "station-observation-save", measurement("PW_UNKNOWN", "105", "cm"))

      assert has_element?(
               view,
               "#station-observation-error",
               "Choose a pathway this review changes"
             )

      assert snapshot_payload(view)["observations"] == []

      # The station select accepts only the rows it offers: a foreign stop id
      # resolves to no station at all.
      forge_station(view, "STATION_FOREIGN")
      refute has_element?(view, "#station-observation-form")

      assert has_element?(
               view,
               "#station-observation-error",
               "Choose one of the stations this review changes"
             )

      assert decision_status(ctx, run_id, "pathway:PW_W14") == :pending
    end

    test "another station's journal note is refused and the draft is kept", ctx do
      view = computed_import_view(ctx)

      choose_station(view, "STATION_A")

      foreign_entry = foreign_journal_entry(ctx, "FOREIGN-NOTE")

      # The rendered select can only offer this station's notes, so the foreign
      # id arrives as the forged event it really is - and the page refuses it.
      forge_measurement(
        view,
        "station-observation-save",
        measurement("PW_W14", "105", "cm") |> Map.put("journal_entry_id", foreign_entry.id)
      )

      assert has_element?(view, "#station-observation-error", "name a note of this station")
      assert has_element?(view, "#station-observation-value[value='105']")
      assert snapshot_payload(view)["observations"] == []
    end

    test "a withdrawn membership refuses the write, keeps the draft and changes no status", ctx do
      view = computed_import_view(ctx)
      run_id = run_id(ctx)

      choose_station(view, "STATION_A")
      deactivate_membership_fixture(ctx.membership)

      capture_measurement(view, measurement("PW_W14", "105", "cm"))

      assert has_element?(view, "#station-observation-error", "no longer have permission")
      assert has_element?(view, "#station-observation-value[value='105']")
      assert snapshot_payload(view)["observations"] == []
      assert decision_status(ctx, run_id, "pathway:PW_W14") == :pending
    end

    test "changing the captured source starts a different conversation", ctx do
      view = computed_import_view(ctx)

      choose_station(view, "STATION_A")
      capture_measurement(view, measurement("PW_W14", "105", "cm"))

      # The conversation this frozen source opened.
      open_helper(view)
      first = conversation_id(view)
      assert is_binary(first)

      capture_measurement(view, measurement("PW_W12", "120", "cm"))

      # Same station, same run, different measurement: the frozen source changed,
      # so this panel's own context is a different conversation.
      assert is_binary(conversation_id(view))
      assert conversation_id(view) != first
      assert [first_row, second_row] = snapshot_payload(view)["observations"]
      assert first_row["original_value"] == "105"
      assert second_row["original_value"] == "120"
      assert second_row["target"]["pathway_id"] == "PW_W12"
      assert has_element?(view, "#station-observation-row-0")
      assert has_element?(view, "#station-observation-row-1")
    end

    test "switching station keeps the other station's measurements out of the context", ctx do
      view = computed_import_view(ctx)

      choose_station(view, "STATION_A")
      capture_measurement(view, measurement("PW_W14", "105", "cm"))

      choose_station(view, "STATION_B")

      assert has_element?(
               view,
               "#station-observation-notice",
               "Measurements captured for Station A"
             )

      assert has_element?(view, "#station-observation-notice", "not part of Station B")
      assert has_element?(view, "#station-observation-empty", "No measurement is captured")

      # The other station's capture is neither dropped nor reinterpreted: it is
      # kept, listed, and out of this station's helper context.
      assert has_element?(view, "#station-observation-captures", "Station A (STATION_A)")
      assert [%{"station_stop_id" => "STATION_B"}] = [snapshot_payload(view)]
      assert snapshot_payload(view)["observations"] == []
      assert offered_pathways(view) == ["PW_OTHER"]

      # Choosing it again restores exactly what was captured there.
      choose_station(view, "STATION_A")
      capture_measurement(view, measurement("PW_W12", "120", "cm"))
      choose_station(view, "STATION_B")
      choose_station(view, "STATION_A")

      assert [
               %{"target" => %{"pathway_id" => "PW_W14"}},
               %{"target" => %{"pathway_id" => "PW_W12"}}
             ] =
               snapshot_payload(view)["observations"]
    end

    test "a new review does not carry the previous one's measurements", ctx do
      view = computed_import_view(ctx)

      choose_station(view, "STATION_A")
      capture_measurement(view, measurement("PW_W14", "105", "cm"))
      assert [%{"target" => %{"pathway_id" => "PW_W14"}}] = snapshot_payload(view)["observations"]

      view |> element("#diff-reset-btn") |> render_click()

      # The reset drops this page's own frozen snapshot with the review it named.
      assert station_imports_snapshot(view) == nil

      # A new review computed in the same page starts from no measurement: the
      # previous review's capture is neither carried over nor reinterpreted.
      view = compute_import(view)

      assert station_imports_snapshot(view) == nil
      assert has_element?(view, "#station-observation-scope-form")
    end

    test "the native review works with the helper never opened", ctx do
      view = computed_import_view(ctx)
      run_id = run_id(ctx)

      choose_station(view, "STATION_A")
      capture_measurement(view, measurement("PW_W14", "105", "cm"))

      view
      |> element("button[phx-click='approve-decision'][phx-value-id='pathway:PW_W14']")
      |> render_click()

      assert decision_status(ctx, run_id, "pathway:PW_W14") == :approved
      refute has_element?(view, "#agent-panel")

      # The measurement is still only a measurement: approving the row is the
      # separate native act, and the helper never entered it.
      assert [row] = snapshot_payload(view)["observations"]
      assert row["accepted"] == true
    end
  end

  ## Views and interaction

  # The ordinary page: the real upload form, the real compute worker and the real
  # review the person is looking at.
  defp computed_import_view(ctx) do
    conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{ctx.version.id}/import")
    compute_import(view)
  end

  defp compute_import(view) do
    view
    |> element("#import-source-form")
    |> render_change(%{"source" => "station"})

    select_diff_file(
      view,
      "pathways.txt",
      "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,traversal_time,min_width\n" <>
        "PW_W14,ENT_A,PLAT_A,1,1,45,1.05\n" <>
        "PW_W12,ENT_A,PLAT_A,1,1,60,1.2\n" <>
        "PW_OTHER,ENT_A,PLAT_B,1,1,30,0.9\n"
    )

    view |> form("#diff-upload-form") |> render_submit()
    await_change_task(view)
    view
  end

  defp choose_station(view, stop_id) do
    view
    |> form("#station-observation-scope-form", %{
      "station_observation_scope" => %{"station_stop_id" => stop_id}
    })
    |> render_change()
  end

  defp measurement(pathway_id, value, unit) do
    %{
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
  end

  # A forged event: the rendered select cannot offer a value the page does not
  # list, so the payload is sent as the event the client would have sent. This is
  # the shape a hand-written event takes, and the page must refuse it on its own.
  defp forge_measurement(view, event, params) do
    render_submit(view, event, %{"station_observation" => params})
  end

  defp forge_station(view, stop_id) do
    render_change(view, "station-observation-scope", %{
      "station_observation_scope" => %{"station_stop_id" => stop_id}
    })
  end

  defp capture_measurement(view, params) do
    view
    |> form("#station-observation-form", %{"station_observation" => params})
    |> render_submit()
  end

  defp open_helper(view) do
    view |> element("#station-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")
    pid = session_pid(view)

    # Join the same conversation through the facade as a second listener, so the
    # session's own settle events are observable without polling the render or
    # sleeping.
    assert {:ok, ^pid, _snapshot} = Agents.open(AgentPanel.scope(:sys.get_state(view.pid).socket))
    pid
  end

  defp submit(view, text) do
    view |> element("#agent-composer") |> render_submit(%{"agent" => %{"message" => text}})
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
    render(view)
  end

  defp select_diff_file(view, filename, content) do
    view
    |> file_input("#diff-upload-form", :diff_files, [
      %{name: filename, content: content, type: "text/plain"}
    ])
    |> render_upload(filename)
  end

  defp run_id(ctx) do
    ChangeRuns.latest_for_version(ctx.organization.id, ctx.version.id).id
  end

  defp decision_status(ctx, run_id, decision_id) do
    ctx.organization.id
    |> ChangeRuns.list_decisions(run_id)
    |> Enum.find(&(&1.decision_id == decision_id))
    |> Map.fetch!(:status)
  end

  ## Reading the page's own state

  defp panel_context(view), do: :sys.get_state(view.pid).socket.assigns.agent_context

  # The frozen payload of this panel's own `station_imports` source snapshot, or
  # nil when the page installed no snapshot of that kind.
  defp station_imports_snapshot(view), do: panel_context(view)[:source_snapshot]

  defp snapshot_payload(view) do
    case panel_context(view) do
      %{source_snapshot: %{kind: "station_imports", payload: payload}} -> payload
      _other -> nil
    end
  end

  defp conversation_id(view), do: :sys.get_state(view.pid).socket.assigns.agent_conversation_id

  defp session_pid(view), do: :sys.get_state(view.pid).socket.assigns.agent_session

  defp offered_stations(view) do
    view
    |> element("#station-observation-scope-input")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option[value]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> to_string()))
    |> Enum.reject(&(&1 == ""))
  end

  defp offered_pathways(view) do
    view
    |> element("#station-observation-pathway")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option[value]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> to_string()))
    |> Enum.reject(&(&1 == ""))
  end

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

  # A real note, created through the production path a station host uses.
  defp journal_entry(ctx, body, opts \\ []) do
    organization = Keyword.get(opts, :organization, ctx.organization)
    version = Keyword.get(opts, :version, ctx.version)
    station = Keyword.get(opts, :station, ctx.station)

    {:ok, scope} =
      Gtfs.resolve_station_journal_scope(organization.id, version.id, station.id, ctx.user.id)

    id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(scope, [
               %{
                 id: id,
                 target_type: "station",
                 body: body,
                 captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
               }
             ])

    Repo.get!(JournalEntry, id)
  end

  # A note of another organization's station. The fixture route resolves the
  # journal scope through the current user, so the row is written directly: what
  # the page must refuse is the forged id, not a note nobody can create.
  defp foreign_journal_entry(ctx, body) do
    id = Ecto.UUID.generate()

    Repo.insert!(%JournalEntry{
      id: id,
      organization_id: ctx.foreign_organization.id,
      gtfs_version_id: ctx.foreign_version.id,
      station_id: ctx.foreign_station.id,
      author_id: ctx.user.id,
      target_type: "station",
      body: body,
      captured_at: DateTime.utc_now()
    })

    Repo.get!(JournalEntry, id)
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
