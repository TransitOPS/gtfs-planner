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

    * a model is never shown a run id, so the Result page's attached run is the
      default `run_ref`, a different run of the same version is refused, and the
      Export page (no attached run) still resolves a named run inside the scope;
    * the two export tools read a ready artifact and its checks without raising,
      return only the artifact's digest, size, expiry and profile (never its file
      name or its run's id), and mark a card incomplete whenever a cursor remains
      or only the last five checks are listed.

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
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted reply below replaces only the HTTP boundary (INV-5).
  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @final_text "This version has one WARNING code with 170 stored findings, three of which are retained."

  @digest String.duplicate("a", 64)

  @profile %{
    "schema_version" => 1,
    "export_type" => "full",
    "include_flex" => false,
    "artifact_kind" => "primary",
    "estimate_method" => nil
  }

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
               "get_export_validation",
               "prepare_export_options",
               "list_supported_remedies",
               "inspect_remedy_targets",
               "prepare_remedy_handoff"
             ]

      assert Enum.all?(FeedQuality.tools(), &(&1.parameters["additionalProperties"] == false))

      # The skill names every tool the pack registers, so a model is told about
      # the preparation and navigation tools as well as the five reads.
      for tool <- FeedQuality.tools(), do: assert(FeedQuality.skill() =~ tool.name)
      refute FeedQuality.skill() =~ "exactly five tools"

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

      # A group page is its header; the samples come from a code-filtered page.
      assert group["instances"] == []

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
      # only the scoped predicate can be what hides it. The Export page attaches
      # no run, so the named reference reaches that predicate.
      assert %ValidationRun{} = Validations.get_validation_run(foreign_run.id)

      expect_reply(
        tool_calls_reply([
          {"call_1", "list_validation_findings", list_arguments(foreign_run.id)}
        ])
      )

      expect_reply(text_reply("That run is not available here."))

      entry = run_turn(export_scope(context), "Read that run.")

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

  describe "the attached run is the default run_ref" do
    test "an omitted run_ref reads the run the page shows", context do
      expect_reply(tool_calls_reply([{"call_1", "list_validation_findings", "{}"}]))
      expect_reply(text_reply(@final_text))

      entry = run_turn(context.scope, "What did the last check find?")

      assert entry.status == :done
      result = tool_result()
      assert result["total_instances"] == 170
      assert result["retained_instances"] == 3
    end

    test "explaining a code needs no run_ref either", context do
      expect_reply(tool_calls_reply([{"call_1", "explain_notice", ~s({"code":"duplicate_key"})}]))
      expect_reply(text_reply("That code is stored."))

      assert run_turn(context.scope, "What does duplicate_key mean?").status == :done

      result = tool_result()
      assert result["code"] == "duplicate_key"
      assert result["findings"]["total_instances"] == 170
    end

    test "a different run of the same version is refused, and the Export page needs a name",
         context do
      other = completed_run(context.organization, context.version, wrapped_notices())

      assert {:tool_error, message} =
               Dispatch.call(
                 FeedQuality,
                 context.scope,
                 "list_validation_findings",
                 list_arguments(other.id)
               )

      assert message =~ "not available"

      # No run is attached on the Export page: omitting run_ref is a request to
      # name one, and a named run of this version resolves.
      assert {:tool_error, named} =
               Dispatch.call(FeedQuality, export_scope(context), "list_validation_findings", "{}")

      assert named =~ "run_ref"

      assert {:ok, %{"total_instances" => 170}, _evidence} =
               Dispatch.call(
                 FeedQuality,
                 export_scope(context),
                 "list_validation_findings",
                 list_arguments(other.id)
               )
    end
  end

  describe "the export tools" do
    test "get_export_readiness projects the selected artifact and states the relationship",
         context do
      run = ready_export_run(context)
      completed_check(context, checked_zip_sha256: @digest, checked_export_profile: @profile)

      expect_reply(
        tool_calls_reply([{"call_1", "get_export_readiness", ~s({"export_type":"full"})}])
      )

      expect_reply(text_reply("The export's bytes were checked."))

      assert run_turn(export_scope(context), "Was the full export checked?").status == :done

      result = tool_result()
      assert result["relationship"] == "checked"
      assert result["digest"] == @digest

      # Only what compares bytes: no file name and no export run id.
      assert result["selected_artifact"] == %{
               "artifact_kind" => "primary",
               "sha256" => @digest,
               "size_bytes" => 1024,
               "expires_at" => DateTime.to_iso8601(Repo.reload!(run).artifact_expires_at),
               "available" => true,
               "profile" => @profile
             }
    end

    test "with no export the selected artifact is null, not a string", context do
      expect_reply(
        tool_calls_reply([{"call_1", "get_export_readiness", ~s({"export_type":"full"})}])
      )

      expect_reply(text_reply("There is no export yet."))

      assert run_turn(export_scope(context), "Was the full export checked?").status == :done

      result = tool_result()
      assert result["relationship"] == "unavailable"
      assert result["selected_artifact"] == nil
    end

    test "get_export_validation names the checks and the selected artifact", context do
      ready_export_run(context)
      check = completed_check(context, checked_zip_sha256: @digest)

      expect_reply(tool_calls_reply([{"call_1", "get_export_validation", "{}"}]))
      expect_reply(text_reply("One check read these bytes without a known profile."))

      entry = run_turn(export_scope(context), "Which checks cover this export?")
      assert entry.status == :done

      # The setup's own completed run is the second check: it recorded no digest.
      result = tool_result()
      assert result["relationship"] == "unknown"
      assert result["selected_artifact"]["sha256"] == @digest

      assert [@digest, nil] ==
               result["recent_checks"]
               |> Enum.sort_by(&(&1["checked_digest"] == nil))
               |> Enum.map(& &1["checked_digest"])

      assert check.id in Enum.map(result["recent_checks"], & &1["id"])

      assert [evidence] = entry.evidence
      assert evidence.kind == "export_validation"
      assert evidence.total == 2
      assert evidence.completeness == :complete
    end

    test "the last five checks are never shown as the whole history", context do
      ready_export_run(context)
      for _index <- 1..5, do: completed_check(context, [])

      expect_reply(tool_calls_reply([{"call_1", "get_export_validation", "{}"}]))
      expect_reply(text_reply("Five checks are listed."))

      assert [evidence] = run_turn(export_scope(context), "How many checks are there?").evidence

      assert evidence.total == 5
      assert evidence.completeness == :incomplete
      assert evidence.exclusions == ["older_checks_not_listed · last 5 shown"]
      assert evidence.completeness_reason =~ "excluded"
    end
  end

  describe "a bounded findings page is never a complete answer" do
    test "a fully retained report read at the default limit is incomplete while a cursor remains",
         context do
      run = completed_run(context.organization, context.version, complete_groups(25))

      expect_reply(
        tool_calls_reply([{"call_1", "list_validation_findings", list_arguments(run.id)}])
      )

      expect_reply(text_reply("The first twenty groups."))

      entry = run_turn(export_scope(context), "What are the findings?")

      result = tool_result()
      assert length(result["groups"]) == 20
      assert result["completeness"] == "complete"
      assert is_binary(result["next_cursor"])

      # Every group retains all of its findings, yet the page left five groups
      # out, so the card must not read as complete.
      assert [evidence] = entry.evidence
      assert evidence.total == 25
      assert evidence.completeness == :incomplete
      assert evidence.exclusions == ["groups_not_on_this_page · 5"]
      assert evidence.completeness_reason =~ "next_cursor"
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp complete_groups(count) do
    Enum.map(0..(count - 1), fn index ->
      %{
        "code" => "code_#{String.pad_leading(Integer.to_string(index), 2, "0")}",
        "severity" => "WARNING",
        "total_notices" => 1,
        "notices" => [sample(index)],
        "retained_notices" => 1,
        "sample_completeness" => "complete"
      }
    end)
  end

  defp export_scope(%{scope: %Scope{} = scope} = context) do
    %{
      scope
      | resource_context:
          snapshot_context(context.version.id, %{
            "schema_version" => 1,
            "section" => "export",
            "type" => "full"
          })
    }
  end

  # A ready export run with its artifact metadata already committed; readiness
  # reads the run's stored digest, size and expiry, not the host's storage.
  defp ready_export_run(context) do
    now = DateTime.utc_now()

    Repo.insert!(
      Run.system_changeset(%Run{}, %{
        export_type: :full,
        state: :ready,
        include_flex: false,
        estimate_missing_times: false,
        artifact_key: "runs/#{context.organization.id}/main.zip",
        artifact_filename: "gtfs.zip",
        artifact_sha256: @digest,
        artifact_size_bytes: 1024,
        artifact_expires_at: DateTime.add(now, 3_600, :second),
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        started_at: now,
        finished_at: now
      })
    )
  end

  defp completed_check(context, provenance) do
    {:ok, run} =
      Validations.create_validation_run(
        context.organization.id,
        context.version.id,
        "mobility_data"
      )

    updates =
      Keyword.merge([status: "completed", completed_at: DateTime.utc_now()], provenance)

    {1, _} =
      Repo.update_all(from(stored in ValidationRun, where: stored.id == ^run.id), set: updates)

    Repo.get!(ValidationRun, run.id)
  end

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
