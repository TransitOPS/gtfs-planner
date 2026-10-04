defmodule GtfsPlannerWeb.Gtfs.FeedQualityResultTest do
  @moduledoc """
  The Feed quality helper on the Validation Result page through the ordinary
  route and the live session (EV-9).

  The page, the conversation session and the turn task are three processes, so
  the Req.Test plug and the SQL sandbox are shared (`async: false`). Only the
  model HTTP boundary is scripted (INV-5); the page, the panel, the facade, the
  session, the turn loop, the FeedQuality pack and the real Evidence reads are
  the shipped ones.

  Every expectation is hand-derived from the stored report this file inserts:

    * the ordinary result route shows the native disclosures and the
      authoritative 170 total with 3 retained WARNING samples, and the helper's
      card carries the same count through the real composition;
    * a foreign or absent run UUID redirects without rendering or reading that
      report, while another engine keeps its native report and no helper;
    * an explanation request approves nothing by itself; only the page's native
      Inspect target action pins the approved instance, and no write happens;
    * a provider failure and a close/reopen leave the native report and the
      current helper state intact;
    * an unknown total reads "Total unknown" rather than 0 findings, an exclusion
      is described by what it is, and the unmapped line is derived from the
      samples' own resolution (two of the three samples name no current record);
    * the helper panel sits inside the design-system page, and a page of groups
      that retain 100 samples each still shows its section;
    * a forged Inspect target for a sample that names no record, and a forged
      prepared-change event, approve and change nothing.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"
  @answer "This version has one WARNING code with 170 stored findings, three retained."

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization =
      organization_fixture(%{alias: "feed-result-#{System.unique_integer([:positive])}"})

    user = user_fixture()
    organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Result Feed"})
    stop_fixture(organization.id, version.id, %{stop_id: "STOP-1", stop_name: "Central"})
    run = completed_run(organization, version, "mobility_data", wrapped_notices())

    track_sessions()

    %{
      organization: organization,
      user: user,
      version: version,
      run: run,
      conn: log_in_user(build_conn(), user, organization: organization)
    }
  end

  describe "the result page and the helper" do
    test "shows the stored 170/3 report and the helper answers from the same read", context do
      view = result_view(context, context.run)

      assert has_element?(view, "#validation-result-page")
      assert has_element?(view, "#feed-quality-evidence")
      assert has_element?(view, "#feed-quality-samples")
      assert has_element?(view, "#feed-quality-provenance")
      assert has_element?(view, "#feed-quality-unmapped")
      assert has_element?(view, "#feed-quality-inspect-target")
      assert render(element(view, "#feed-quality-samples")) =~ "170"
      assert render(element(view, "#feed-quality-samples")) =~ "3"

      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")

      expect_reply(
        tool_calls_reply([
          {
            "call_1",
            "list_validation_findings",
            Jason.encode!(%{"run_ref" => context.run.id})
          }
        ])
      )

      expect_reply(text_reply(@answer))

      submit(view, "What did the last check find?")
      assert await_settled(attach_listener(view)).status == :done

      assert has_element?(view, "#agent-entry-2 [data-evidence-kind='validation_findings']")
      card = view |> element("#agent-evidence-2-1") |> render()
      assert card =~ "170"
      assert card =~ "gtfs_feed_quality"

      # The native disclosures the page already had are untouched.
      assert has_element?(view, "#validation-summary")
      assert Repo.aggregate(ChangeLog, :count) == 0
    end

    test "a foreign or absent run redirects and another engine keeps its native report",
         context do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_run = completed_run(foreign_organization, foreign_version, "mobility_data", %{})

      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => message}}}} =
               live(context.conn, "/gtfs/#{context.version.id}/validation/#{foreign_run.id}")

      assert to == "/gtfs/#{context.version.id}/export"
      assert message =~ "Unauthorized"

      assert {:error, {:live_redirect, %{to: missing_to}}} =
               live(
                 context.conn,
                 "/gtfs/#{context.version.id}/validation/#{Ecto.UUID.generate()}"
               )

      assert missing_to == "/gtfs/#{context.version.id}/export"

      # Another engine keeps its own native report and offers no helper.
      walk_run = completed_run(context.organization, context.version, "pathways_tests", %{})

      {:ok, walk_view, _html} =
        live(context.conn, "/gtfs/#{context.version.id}/validation/#{walk_run.id}")

      assert has_element?(walk_view, "#validation-result-page")
      refute has_element?(walk_view, "#feed-quality-evidence")
      refute has_element?(walk_view, "#agent-helper-open")

      walk_view |> element("#open-history") |> render_click()
      assert has_element?(walk_view, "#validation-history")
    end

    test "an explanation approves nothing until the native Inspect target does", context do
      view = result_view(context, context.run)
      view |> element("#agent-helper-open") |> render_click()

      expect_reply(
        tool_calls_reply([
          {
            "call_1",
            "explain_notice",
            Jason.encode!(%{"run_ref" => context.run.id, "code" => "duplicate_key"})
          }
        ])
      )

      expect_reply(text_reply("That code names a field the feed requires."))
      submit(view, "What does duplicate_key mean?")
      assert await_settled(attach_listener(view)).status == :done

      assert has_element?(view, "#agent-entry-2 [data-evidence-kind='notice_explanation']")

      # Nothing was approved by the explanation, and nothing was written.
      assigns = :sys.get_state(view.pid).socket.assigns
      refute Map.has_key?(assigns.agent_context.source_snapshot.payload, "requested_instance_ref")
      assert Repo.aggregate(ChangeLog, :count) == 0

      # The page's own native action is the approval; it pins the exact ref the
      # server resolved, and the pack still returns navigation only.
      view |> element("#feed-quality-inspect-0") |> render_click()

      assigns = :sys.get_state(view.pid).socket.assigns

      assert Map.has_key?(assigns.agent_context.source_snapshot.payload, "requested_instance_ref")
      assert has_element?(view, "#agent-notice")
      assert Repo.aggregate(ChangeLog, :count) == 0
      assert Repo.aggregate(ValidationRun, :count) == 1
    end

    test "a provider failure and a close/reopen keep the report and helper state", context do
      view = result_view(context, context.run)
      view |> element("#agent-helper-open") |> render_click()

      expect_status(401, %{"error" => "provider key rejected"})
      submit(view, "What did the last check find?")
      assert await_settled(attach_listener(view)).status == :failed

      # The native report and section never disappear because the provider failed.
      assert has_element?(view, "#validation-result-page")
      assert has_element?(view, "#feed-quality-samples")
      assert render(element(view, "#feed-quality-samples")) =~ "170"

      view |> element("#agent-panel-close") |> render_click()
      refute has_element?(view, "#agent-panel")
      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#feed-quality-evidence")
    end
  end

  describe "what the section states" do
    test "an unknown total is never a clean zero and the unmapped line reads the samples",
         context do
      countless = %{
        "notices" => [
          %{
            "code" => "duplicate_key",
            "severity" => "WARNING",
            "totalNotices" => 1,
            "notices" => [%{"sampleNotices" => samples(3)}]
          }
        ]
      }

      run = completed_run(context.organization, context.version, "mobility_data", countless)
      view = result_view(context, run)

      samples = render(element(view, "#feed-quality-samples"))
      assert samples =~ "Total unknown"
      refute samples =~ "0 finding"
      assert samples =~ "3 retained samples"
      assert render(element(view, "#feed-quality-limits")) =~ "Groups with no stored total: 1."

      # The first sample names the seeded stop; the other two carry only a row.
      unmapped = render(element(view, "#feed-quality-unmapped"))
      assert unmapped =~ "2 of 3 sampled findings name no current record"
      assert unmapped =~ "only a file row"
      refute unmapped =~ "groups_not_on_this_page"

      assert has_element?(view, "#feed-quality-inspect-0")
      refute has_element?(view, "#feed-quality-inspect-1")
    end

    test "more groups than the section reads never show a page disclosure as unmapped",
         context do
      notices =
        Enum.map(1..5, fn index ->
          %{
            "code" => "code_#{index}",
            "severity" => "WARNING",
            "total_notices" => 1,
            "notices" => [sample(index)],
            "retained_notices" => 1,
            "sample_completeness" => "complete"
          }
        end)

      run =
        completed_run(context.organization, context.version, "mobility_data", %{
          "notices" => notices
        })

      view = result_view(context, run)

      assert render(element(view, "#feed-quality-samples")) =~ "5 findings"
      refute has_element?(view, "#feed-quality-limits")
      refute render(element(view, "#feed-quality-unmapped")) =~ "not_on_this_page"
    end

    test "groups that retain 100 samples each still show the section and the panel", context do
      wide = fn code ->
        %{
          "code" => code,
          "severity" => "WARNING",
          "total_notices" => 100,
          "notices" =>
            Enum.map(1..100, fn index ->
              %{
                "filename" => "stops.txt",
                "csvRowNumber" => index,
                "stopId" => String.duplicate("s", 128)
              }
            end),
          "retained_notices" => 100,
          "sample_completeness" => "complete"
        }
      end

      run =
        completed_run(context.organization, context.version, "mobility_data", %{
          "notices" => [wide.("duplicate_key"), wide.("stop_name")]
        })

      view = result_view(context, run)

      assert has_element?(view, "#agent-helper-open")
      assert render(element(view, "#feed-quality-samples")) =~ "200 findings"

      # The panel stays inside the design-system page, so it takes the page's
      # colours and focus rings.
      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#validation-result-page.ds-page #agent-panel")
    end

    test "a forged Inspect target for an unmapped sample and a prepared-change event change nothing",
         context do
      view = result_view(context, context.run)

      unmapped = Enum.find(feed_quality_samples(view), &(not &1.resolved?))
      assert is_binary(unmapped.ref)

      render_click(view, "feed_quality_inspect", %{"instance_ref" => unmapped.ref})

      payload = :sys.get_state(view.pid).socket.assigns.agent_context.source_snapshot.payload
      refute Map.has_key?(payload, "requested_instance_ref")

      render_click(view, "agent_review_prepared", %{"entry" => "1"})
      assert has_element?(view, "#feed-quality-evidence")
    end
  end

  ## Fixtures and helpers

  defp feed_quality_samples(view) do
    :sys.get_state(view.pid).socket.assigns.feed_quality_samples
  end

  defp completed_run(organization, version, run_type, result) do
    {:ok, run} = Validations.create_validation_run(organization.id, version.id, run_type)

    run
    |> ValidationRun.system_changeset(%{
      status: "completed",
      completed_at: DateTime.utc_now(),
      result_json: result
    })
    |> Repo.update!()
  end

  # The historical wrapper: its own total is 1 while the embedded upstream count
  # is 170 and only three samples are retained.
  defp wrapped_notices do
    %{
      "notices" => [
        %{
          "code" => "duplicate_key",
          "severity" => "WARNING",
          "totalNotices" => 1,
          "notices" => [%{"totalNotices" => 170, "sampleNotices" => samples(3)}]
        }
      ]
    }
  end

  defp samples(count), do: Enum.map(1..count, &sample/1)

  defp sample(1) do
    %{
      "filename" => "stops.txt",
      "csvRowNumber" => 1,
      "fieldName" => "stop_id",
      "stopId" => "STOP-1"
    }
  end

  defp sample(index) do
    %{"filename" => "stops.txt", "csvRowNumber" => index, "fieldName" => "stop_id"}
  end

  defp result_view(context, run) do
    assert {:ok, view, _html} =
             live(context.conn, "/gtfs/#{context.version.id}/validation/#{run.id}")

    view
  end

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

  defp expect_reply(payload), do: expect_status(200, payload)

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
