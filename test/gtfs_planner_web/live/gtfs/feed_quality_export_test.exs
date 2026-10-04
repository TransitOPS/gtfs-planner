defmodule GtfsPlannerWeb.Gtfs.FeedQualityExportTest do
  @moduledoc """
  The Feed quality helper on the Export page through the ordinary route and the
  live session (EV-8).

  The page, the conversation session and the turn task are three processes, so
  the Req.Test plug and the SQL sandbox are shared (`async: false`). Only the
  model HTTP boundary is scripted (INV-5); the page, the panel, the facade, the
  session, the turn loop, the FeedQuality pack and the Evidence read are the
  shipped ones.

  Every expectation is hand-derived from the stored defaults and the prepared
  command contract, never from a second invocation of the host:

    * the ordinary `/gtfs/:version/export` route offers the helper, prepares a
      type through the real pack and selects it with the page's own native form
      patch while creating no export, validation, audit or defaults row;
    * a forged or ended entry and a settings change are refused with feedback
      while the native selection the person already made stays where it was;
    * this installation ships one helper pack, so no multipack selector is
      rendered;
    * a native type change rebinds the panel's source snapshot, so the old
      prepared card is gone and only the current conversation remains;
    * Review options closes the panel, so the selection is visible at every
      width, and puts focus on the chosen type's radio;
    * a finished or newer export, a refresh after the saved defaults changed and
      a withdrawn membership each leave the section and the panel's snapshot
      describing the current selection, and a late event from a replaced
      session reaches nothing.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Packs.FeedQuality
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"
  @message "Prepare the Pathways export for me."

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization =
      organization_fixture(%{alias: "feed-quality-#{System.unique_integer([:positive])}"})

    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Quality Feed"})

    track_sessions()

    %{
      organization: organization,
      membership: membership,
      user: user,
      version: version,
      defaults: ExportDefaults.get(organization.id),
      conn: log_in_user(build_conn(), user, organization: organization)
    }
  end

  describe "the Export helper and Review options" do
    test "the ordinary route prepares a type through the real pack and selects it", context do
      view = export_view(context)

      # The provider-independent section is present before any helper opens.
      assert has_element?(view, "#feed-quality-evidence")
      assert has_element?(view, "#feed-quality-relationship")
      assert has_element?(view, "#feed-quality-refresh")

      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")
      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})

      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_export_options", ~s({"export_type":"pathways"})}
        ])
      )

      expect_reply(text_reply("I prepared the Pathways selection for Review options."))

      submit(view, @message)
      pid = attach_listener(view)
      assert await_settled(pid).status == :done

      assert has_element?(view, "#agent-prepared-2")
      assert has_element?(view, "#agent-review-prepared-2", "Review options")

      # The page's own native patch owns the selected type.
      assert has_element?(view, "#export-type-full[checked]")

      view |> element("#agent-review-prepared-2") |> render_click()

      assert_patch(view, "/gtfs/#{context.version.id}/export?type=pathways")
      assert has_element?(view, "#export-type-pathways[checked]")
      refute has_element?(view, "#export-type-full[checked]")

      # The panel closes so the form shows the selection at every width, and
      # focus lands on the radio that was chosen (a form is not focusable).
      refute has_element?(view, "#agent-panel")
      assert_push_event(view, "agent:focus", %{id: "export-type-pathways"})

      # Preparing is memory-only: no job, no validation, no audit and no default.
      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(ValidationRun, :count) == 0
      assert Repo.aggregate(ChangeLog, :count) == 0
      assert ExportDefaults.get(context.organization.id) == context.defaults
    end

    test "a forged entry and a changed default are refused with feedback", context do
      view = export_view(context)
      view |> element("#agent-helper-open") |> render_click()

      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_export_options", ~s({"export_type":"pathways"})}
        ])
      )

      expect_reply(text_reply("Prepared."))
      submit(view, @message)
      assert await_settled(attach_listener(view)).status == :done

      # A forged entry id can never become a selection.
      view
      |> render_click("agent_review_prepared", %{"entry" => "9999"})

      assert render(view) =~ "no longer available"
      assert has_element?(view, "#export-type-full[checked]")
      refute has_element?(view, "#export-type-pathways[checked]")

      # The person saves a new default after the helper answered; the exact
      # command no longer matches the settings truth it prepared against.
      assert {:ok, saved} =
               ExportDefaults.update(
                 context.organization.id,
                 context.user,
                 %{"include_flex" => false}
               )

      assert saved.include_flex == false

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-notice")
      assert has_element?(view, "#export-type-full[checked]")
      refute has_element?(view, "#export-type-pathways[checked]")

      # The person's own save stays saved and nothing else was written.
      assert ExportDefaults.get(context.organization.id).include_flex == false
      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(ChangeLog, :count) == 0
    end

    test "this installation ships no comparison pack, so no multipack selector", context do
      view = export_view(context)

      refute has_element?(view, "#export-helper-mode")
      refute Agents.packs()["release_comparison"]
      assert Agents.packs()["feed_quality"] == FeedQuality
    end

    test "a native type change rebinds the panel source and drops the old card", context do
      view = export_view(context)
      view |> element("#agent-helper-open") |> render_click()

      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_export_options", ~s({"export_type":"pathways"})}
        ])
      )

      expect_reply(text_reply("Prepared."))
      submit(view, @message)
      assert await_settled(attach_listener(view)).status == :done
      assert has_element?(view, "#agent-prepared-2")

      # The page's own native change is the refresh: the snapshot it pins is of
      # the new section, so the conversation that answered about the old one is
      # not reused.
      view
      |> element("#gtfs-export-form")
      |> render_change(%{"export" => %{"type" => "operations"}})

      assert_patch(view, "/gtfs/#{context.version.id}/export?type=operations")
      assert has_element?(view, "#export-type-operations[checked]")
      refute has_element?(view, "#agent-prepared-2")
      assert has_element?(view, "#agent-first-conversation")
      assert has_element?(view, "#feed-quality-evidence")

      # Closing and reopening keeps the current conversation, not the old one.
      view |> element("#agent-panel-close") |> render_click()
      refute has_element?(view, "#agent-panel")
      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")
      refute has_element?(view, "#agent-prepared-2")
    end
  end

  describe "the section and the panel follow the selected export" do
    test "a finished export and a newer one each replace the panel's selected export",
         context do
      view = export_view(context)

      assert selected_export_ref(view) == nil
      assert render(element(view, "#feed-quality-relationship")) =~ "not available"

      first = ready_export_run(context)
      send(view.pid, {:export_run_changed, first.id})

      # The first export finished: the sentence now says the history cannot be
      # compared (no check read these bytes), and the panel pins that export.
      assert render(element(view, "#feed-quality-relationship")) =~ "cannot be compared"
      assert selected_export_ref(view) == first.id

      second = ready_export_run(context)
      send(view.pid, {:export_run_changed, second.id})
      render(view)

      assert selected_export_ref(view) == second.id
    end

    test "Refresh check reloads defaults saved elsewhere so the helper opens again", context do
      view = export_view(context)
      stale_digest = defaults_digest(view)

      # Defaults saved on the Export defaults page reach this page by no message.
      assert {:ok, saved} =
               ExportDefaults.update(
                 context.organization.id,
                 context.user,
                 %{"include_flex" => !context.defaults.include_flex}
               )

      view |> element("#feed-quality-refresh") |> render_click()

      current_digest = defaults_digest(view)
      assert current_digest == FeedQuality.defaults_digest(saved)
      refute current_digest == stale_digest

      # A snapshot pinned to the stale digest would stop the helper as unavailable.
      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")
      refute has_element?(view, "#agent-status", "stopped")

      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_export_options", ~s({"export_type":"pathways"})}
        ])
      )

      expect_reply(text_reply("Prepared."))
      submit(view, @message)
      assert await_settled(attach_listener(view)).status == :done
      assert has_element?(view, "#agent-prepared-2")
    end

    test "a withdrawn membership refuses Review options and leaves the form alone", context do
      view = export_view(context)
      view |> element("#agent-helper-open") |> render_click()

      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_export_options", ~s({"export_type":"pathways"})}
        ])
      )

      expect_reply(text_reply("Prepared."))
      submit(view, @message)
      assert await_settled(attach_listener(view)).status == :done

      deactivate_membership_fixture(context.membership)

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-notice")
      assert has_element?(view, "#export-type-full[checked]")
      refute has_element?(view, "#export-type-pathways[checked]")
    end

    test "a forged entry that is not a string and a late event from a replaced session change nothing",
         context do
      view = export_view(context)
      view |> element("#agent-helper-open") |> render_click()
      old_session = :sys.get_state(view.pid).socket.assigns.agent_session

      render_click(view, "agent_review_prepared", %{"entry" => %{"id" => 1}})
      assert has_element?(view, "#export-type-full[checked]")

      # The native type change replaces the panel's source and its session.
      view
      |> element("#gtfs-export-form")
      |> render_change(%{"export" => %{"type" => "operations"}})

      assert_patch(view, "/gtfs/#{context.version.id}/export?type=operations")
      refute :sys.get_state(view.pid).socket.assigns.agent_session == old_session

      send(
        view.pid,
        {:agent_event, old_session,
         {:entry, %{id: 77, role: :assistant, status: :done, text: "late answer"}}}
      )

      send(view.pid, {:DOWN, make_ref(), :process, old_session, :killed})

      refute render(view) =~ "late answer"
      assert has_element?(view, "#export-type-operations[checked]")
    end
  end

  ## Fixtures and helpers

  defp selected_export_ref(view) do
    :sys.get_state(view.pid).socket.assigns.agent_context.source_snapshot.payload[
      "selected_export_ref"
    ]
  end

  defp defaults_digest(view) do
    :sys.get_state(view.pid).socket.assigns.agent_context.source_snapshot.payload[
      "defaults_digest"
    ]
  end

  # A ready export run with its artifact metadata committed; the section reads
  # the run's stored digest and expiry, never the host's storage.
  defp ready_export_run(context) do
    now = DateTime.utc_now()

    Repo.insert!(
      Run.system_changeset(%Run{}, %{
        export_type: :full,
        state: :ready,
        include_flex: false,
        estimate_missing_times: false,
        artifact_key: "runs/#{context.organization.id}/#{System.unique_integer([:positive])}.zip",
        artifact_filename: "gtfs.zip",
        artifact_sha256: String.duplicate("a", 64),
        artifact_size_bytes: 1024,
        artifact_expires_at: DateTime.add(now, 3_600, :second),
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        started_at: now,
        finished_at: now
      })
    )
  end

  defp export_view(context) do
    assert {:ok, view, _html} = live(context.conn, "/gtfs/#{context.version.id}/export")
    view
  end

  # Joins the panel's own conversation through the facade as a second listener,
  # so the session's settle events are observable without polling the render.
  # The context is the panel's own, which is what makes this the same session.
  defp attach_listener(view) do
    assigns = :sys.get_state(view.pid).socket.assigns

    scope = %GtfsPlanner.Agents.Scope{
      organization_id: assigns.current_organization.id,
      gtfs_version_id: assigns.current_gtfs_version.id,
      user_id: assigns.current_user.id,
      user_email: assigns.current_user.email,
      pack_id: "feed_quality",
      version_name: assigns.current_gtfs_version.name,
      resource_context: assigns.agent_context
    }

    {:ok, pid, _snapshot} = Agents.open(scope)
    pid
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

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

  ## Scripted model replies (only the HTTP boundary is doubled)

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
