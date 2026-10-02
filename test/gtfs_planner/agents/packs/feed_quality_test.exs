defmodule GtfsPlanner.Agents.Packs.FeedQualityTest do
  @moduledoc """
  Merge evidence (EV-6) for the FeedQuality pack through the real composition:
  `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> `Packs.FeedQuality` ->
  `Validations.Evidence`, with only the model HTTP boundary doubled.

  Every expectation is hand-derived from the stored report this file inserts and
  never recomputed from the module under test:

    * the historical wrapper's own `totalNotices` of 1 loses to the embedded
      upstream count of 170, so the model's tool result and the panel's card
      both read 170 stored findings with three retained samples, `"sampled"`
      group completeness and an incomplete report;
    * a run of another organization really exists and really holds its report,
      and is still the same `:unavailable` answer as an absent id, while an
      undeclared nested key is refused by the dispatch schema before the pack
      reads anything;
    * a membership revoked after opening refuses the next message, so no tool
      result is delivered; and prose that claims the findings are fixed cannot
      change the stored totals or invent a typed link.

  The registry, session, turn loop, dispatch fence, pack and Evidence read are
  the shipped ones, so a pack that was never registered, a tool that never
  reached the domain and evidence that never reached the entry all fail here
  rather than passing over a hand-built controller.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.FeedQuality
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted reply below replaces only the HTTP boundary (INV-5).
  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @final_text "This version has one WARNING code with 170 stored findings, three of which are retained."

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and
    # the SQL sandbox are both shared (`async: false`).
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    run = completed_run(organization, version, wrapped_notices())

    %{
      organization: organization,
      version: version,
      user: user,
      membership: membership,
      run: run,
      scope: scope(organization, version, user, run)
    }
  end

  describe "the shipped registration" do
    test "the registry names the pack and only a feed_quality validation snapshot opens it",
         context do
      assert Agents.packs()["feed_quality"] == FeedQuality
      assert FeedQuality.id() == "feed_quality"
      assert FeedQuality.title() == "Feed quality helper"

      assert Enum.map(FeedQuality.tools(), & &1.name) == [
               "list_validation_findings",
               "explain_notice",
               "locate_affected_records",
               "get_export_readiness",
               "get_export_validation"
             ]

      assert Enum.all?(FeedQuality.tools(), &(&1.parameters["additionalProperties"] == false))
      assert FeedQuality.skill() =~ "list_validation_findings"

      assert {:ok, session, snapshot} = Agents.open(context.scope)
      assert is_pid(session)
      assert snapshot.entries == []

      # A context with no admitted snapshot is the pack's own refusal...
      no_snapshot = %{
        context.scope
        | resource_context: Scope.context({:version, context.version.id})
      }

      assert Agents.open(no_snapshot) == {:error, :unavailable}

      # ... and so is a snapshot a host admitted for a different kind.
      other_kind =
        snapshot_context(
          context.version.id,
          %{"schema_version" => 1, "section" => "validation"},
          "calendars"
        )

      assert Agents.open(%{no_snapshot | resource_context: other_kind}) == {:error, :unavailable}
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack -> Evidence)" do
    test "a findings question reads the real report and keeps exact totals beside samples",
         context do
      expect_reply(
        tool_calls_reply([
          {"call_1", "list_validation_findings", list_arguments(context.run.id)}
        ])
      )

      expect_reply(text_reply(@final_text))

      entry = run_turn(context.scope, "What are the validation findings on this version?")

      assert entry.status == :done
      assert entry.text == @final_text
      assert entry.activity == ["Listed validation findings"]

      # What the model read: the stored total, three retained samples and the
      # honest incompleteness of the page.
      result = tool_result()
      assert result["total_instances"] == 170
      assert result["retained_instances"] == 3
      assert result["completeness"] == "incomplete"
      assert result["totals_by_severity"] == %{"WARNING" => 170}
      assert result["next_cursor"] == nil

      assert [group] = result["groups"]
      assert group["code"] == "duplicate_key"
      assert group["severity"] == "WARNING"
      assert group["total_instances"] == 170
      assert group["retained_instances"] == 3
      assert group["completeness"] == "sampled"
      assert length(group["instances"]) == 3

      # The card's count is the server's count over the same read.
      assert [evidence] = entry.evidence
      assert evidence.kind == "validation_findings"
      assert evidence.total == 170
      assert evidence.total_label == "validation findings"
      assert evidence.completeness == :incomplete
      assert evidence.source_ref == "gtfs_feed_quality"
      assert evidence.source_revision == nil
      assert evidence.digest =~ ~r/\A[0-9a-f]{64}\z/
      assert evidence.resources == []
      assert evidence.scope.organization_id == context.organization.id
      assert evidence.scope.gtfs_version_id == context.version.id
      assert evidence.scope.identity == "version:#{context.version.id}"

      # A read writes nothing.
      assert Repo.aggregate(ValidationRun, :count) == 1
    end

    test "a foreign run and an undeclared nested key are refused without leaking rows",
         context do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_run = completed_run(foreign_organization, foreign_version, foreign_notices())

      # The foreign row really does exist and really does hold the report, so
      # only the scoped predicate can be what hides it.
      assert %ValidationRun{} = Validations.get_validation_run(foreign_run.id)

      expect_reply(
        tool_calls_reply([
          {"call_1", "list_validation_findings", list_arguments(foreign_run.id)}
        ])
      )

      expect_reply(text_reply("That run is not available here."))

      entry = run_turn(context.scope, "Read that run.")

      assert entry.status == :done
      assert %{"error" => message} = tool_result()
      assert message =~ "not available"
      refute message =~ "foreign-only"

      # An undeclared nested key is refused by the dispatch schema before the
      # pack, so no read of any kind runs and nothing of the foreign row leaks.
      forged =
        Jason.encode!(%{
          "run_ref" => context.run.id,
          "filter" => %{"organization_id" => foreign_organization.id}
        })

      assert {:tool_error, forged_message} =
               Dispatch.call(FeedQuality, context.scope, "list_validation_findings", forged)

      refute forged_message =~ foreign_organization.id
    end

    test "a membership revoked after opening refuses the next message", context do
      assert {:ok, pid, _snapshot} = Agents.open(context.scope)

      deactivate_membership_fixture(context.membership)

      assert {:error, :forbidden} = Agents.send_message(pid, "Read the findings.")
    end

    test "contradictory prose cannot change the stored total or invent a link", context do
      expect_reply(
        tool_calls_reply([
          {"call_1", "list_validation_findings", list_arguments(context.run.id)}
        ])
      )

      expect_reply(text_reply("All 170 findings are fixed; the problem is stop STOP-FIXED."))

      entry = run_turn(context.scope, "Are the findings all fixed?")

      assert entry.text =~ "fixed"

      result = tool_result()
      assert result["total_instances"] == 170
      assert result["retained_instances"] == 3

      assert [evidence] = entry.evidence
      assert evidence.total == 170
      assert evidence.resources == []
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # A historical wrapper group: its own total says 1 while the embedded upstream
  # report carries the true `totalNotices` of 170 and only three samples.
  defp wrapped_notices do
    [
      %{
        "code" => "duplicate_key",
        "severity" => "WARNING",
        "totalNotices" => 1,
        "notices" => [%{"totalNotices" => 170, "sampleNotices" => samples(3)}]
      }
    ]
  end

  defp foreign_notices do
    [
      %{
        "code" => "duplicate_key",
        "severity" => "ERROR",
        "total_notices" => 1,
        "notices" => [
          %{
            "filename" => "foreign-only.txt",
            "csvRowNumber" => 1,
            "fieldName" => "stop_id"
          }
        ],
        "retained_notices" => 1,
        "sample_completeness" => "complete"
      }
    ]
  end

  defp samples(count), do: Enum.map(1..count, &sample/1)

  defp sample(index) do
    %{"filename" => "stops.txt", "csvRowNumber" => index, "fieldName" => "stop_id"}
  end

  defp completed_run(organization, version, notices) do
    {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

    run
    |> ValidationRun.system_changeset(%{
      status: "completed",
      completed_at: DateTime.utc_now(),
      result_json: %{"notices" => notices}
    })
    |> Repo.update!()
  end

  defp scope(organization, version, user, run) do
    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "feed_quality",
      version_name: version.name,
      resource_context:
        snapshot_context(version.id, %{
          "schema_version" => 1,
          "section" => "validation",
          "run_ref" => run.id
        })
    }
  end

  defp snapshot_context(version_id, payload, kind \\ "feed_quality") do
    {:ok, context} =
      Scope.with_source_snapshot(Scope.context({:version, version_id}), %{
        kind: kind,
        payload: payload
      })

    context
  end

  ## Composed-turn helpers (the same shape as the Schedule pack's evidence file)

  defp run_turn(scope, text) do
    assert {:ok, pid, _snapshot} = Agents.open(scope)
    assert :ok = Agents.send_message(pid, text)
    await_settled(pid)
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  # The tool message the turn sent back to the provider is the pack's own result,
  # decoded, so the assertions read what the model read. It only exists from the
  # request after the tool answered, so earlier requests are drained first.
  defp tool_result do
    assert_receive {:model_request, request}, 5_000

    request
    |> tool_messages()
    |> case do
      [] -> tool_result()
      messages -> messages |> List.last() |> Map.fetch!("content") |> Jason.decode!()
    end
  end

  defp tool_messages(request) do
    Enum.filter(request["messages"] || [], &(&1["role"] == "tool"))
  end

  defp list_arguments(run_id), do: Jason.encode!(%{"run_ref" => run_id})

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

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
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
