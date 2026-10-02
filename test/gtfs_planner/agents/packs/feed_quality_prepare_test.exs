defmodule GtfsPlanner.Agents.Packs.FeedQualityPrepareTest do
  @moduledoc """
  Merge evidence (EV-7) for the FeedQuality pack's memory-only preparation and
  navigation-only remedies, through the real composition: `Agents.open/1` ->
  `Session` -> `Turn` -> `Dispatch` -> `Packs.FeedQuality` -> `Evidence`, with
  only the model HTTP boundary doubled.

  Every expectation is hand-derived from the stored report and the defaults this
  file inserts, never recomputed from the module under test:

    * a preparation turn returns the code-owned
      `{:feed_quality_export_options, %{...}}` command through
      `Agents.prepared/3`, and the counts of `Export.Run`, `ValidationRun`,
      `ChangeLog` and the stored defaults are exactly what they were before;
    * an instance the person has not requested gets discovery and no handoff;
      the same instance with the server snapshot's `requested_instance_ref`
      gets navigation only (no operation id, no command); an unresolvable
      instance and the supported-remedy list name no correction;
    * a default saved after the snapshot makes the prepared lookup
      `{:error, :unavailable}` while the saved default itself and every native
      row stay exactly as the person left them.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.FeedQuality
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Evidence
  alias GtfsPlanner.Validations.ValidationRun

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

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
    organization_membership_fixture(user, organization)
    stop_fixture(organization.id, version.id, %{stop_id: "STOP-1", stop_name: "Central"})
    run = completed_run(organization, version)

    %{
      organization: organization,
      version: version,
      user: user,
      run: run,
      defaults: ExportDefaults.get(organization.id)
    }
  end

  describe "preparing a native export selection" do
    test "the type command reaches Agents.prepared/3 and writes nothing", context do
      scope = export_scope(context, context.defaults)

      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_export_options", ~s({"export_type":"pathways"})}
        ])
      )

      expect_reply(text_reply("I prepared the Pathways selection for Review options."))

      {pid, conversation_id, entry} = run_prepared_turn(scope, "Prepare the Pathways export.")

      assert entry.status == :done
      assert entry.activity == ["Prepared export options"]

      result = tool_result()
      assert result["export_type"] == "pathways"
      assert result["command_proposed"] == true
      assert result["defaults"]["include_flex"] == context.defaults.include_flex

      assert %{summary: summary, command: command} = entry.prepared
      assert summary.title == "Review export options"
      assert summary.detail =~ "Pathways"
      assert Enum.any?(summary.lines, &(&1 =~ "Export type: Pathways"))

      assert command ==
               {:feed_quality_export_options,
                %{
                  export_type: :pathways,
                  defaults_digest: defaults_digest(context.defaults),
                  context_digest: Scope.context_digest(scope)
                }}

      # The host's own lookup returns the same command and nothing else.
      assert {:ok, prepared} = Agents.prepared(pid, conversation_id, entry.id)
      assert prepared == entry.prepared

      # Preparing is memory-only: no export, no validation, no audit row and no
      # saved default changed.
      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(ValidationRun, :count) == 1
      assert Repo.aggregate(ChangeLog, :count) == 0
      assert ExportDefaults.get(context.organization.id) == context.defaults
    end

    test "a default saved after the snapshot makes the lookup unavailable", context do
      scope = export_scope(context, context.defaults)

      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_export_options", ~s({"export_type":"full"})}
        ])
      )

      expect_reply(text_reply("Prepared."))

      {pid, conversation_id, entry} = run_prepared_turn(scope, "Prepare the full export.")

      assert %{command: _command} = entry.prepared

      # The person saves a new default on the native form. The conversation's
      # snapshot no longer matches the settings truth it was opened against.
      assert {:ok, saved} =
               ExportDefaults.update(
                 context.organization.id,
                 context.user,
                 %{"estimate_missing_times" => false}
               )

      assert saved.estimate_missing_times == false
      assert {:error, :unavailable} = Agents.prepared(pid, conversation_id, entry.id)

      # The person's own save and every native row stay exactly as they were.
      assert ExportDefaults.get(context.organization.id).estimate_missing_times == false
      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(ValidationRun, :count) == 1
      assert Repo.aggregate(ChangeLog, :count) == 0
    end

    test "a scope without a matching snapshot cannot prepare anything", context do
      stale =
        export_scope(context, %{
          context.defaults
          | estimate_missing_times: !context.defaults.estimate_missing_times
        })

      assert {:error, :unavailable} =
               Dispatch.call(
                 FeedQuality,
                 stale,
                 "prepare_export_options",
                 ~s({"export_type":"operations"})
               )
    end
  end

  describe "navigation-only remedies" do
    test "an unapproved instance gets discovery, an approved one navigates only", context do
      resolvable = instance_ref(context, 0)
      unapproved = validation_scope(context, %{})

      assert {:ok, discovery, discovery_evidence} =
               Dispatch.call(
                 FeedQuality,
                 unapproved,
                 "prepare_remedy_handoff",
                 Jason.encode!(%{"run_ref" => context.run.id, "instance_ref" => resolvable})
               )

      assert discovery["requested"] == false
      assert discovery["handoff"] == nil

      assert [%{"kind" => "stop", "id" => "STOP-1"}] =
               discovery["navigation"]["targets"] |> Enum.map(&Map.take(&1, ["kind", "id"]))

      assert discovery_evidence.kind == "remedy_handoff"
      assert discovery_evidence.total == 1
      assert discovery_evidence.resources == [%{kind: "stop", id: "STOP-1", label: "Central"}]

      approved =
        validation_scope(context, %{"requested_instance_ref" => resolvable})

      assert {:ok, handoff, handoff_evidence} =
               Dispatch.call(
                 FeedQuality,
                 approved,
                 "prepare_remedy_handoff",
                 Jason.encode!(%{"run_ref" => context.run.id, "instance_ref" => resolvable})
               )

      assert handoff["requested"] == true
      assert handoff["handoff"]["navigable"] == true
      assert handoff["handoff"]["unresolved"] == []

      assert [%{"kind" => "stop", "id" => "STOP-1"}] =
               handoff["handoff"]["targets"] |> Enum.map(&Map.take(&1, ["kind", "id"]))

      # Navigation only: no operation id, no command and no correction anywhere.
      refute Map.has_key?(handoff, "operation_id")
      refute Map.has_key?(handoff, "command")
      assert handoff_evidence.kind == "remedy_handoff"
    end

    test "an unresolvable finding and the remedy list name no correction", context do
      row_only = instance_ref(context, 2)
      scope = validation_scope(context, %{"requested_instance_ref" => row_only})

      assert {:ok, handoff, evidence} =
               Dispatch.call(
                 FeedQuality,
                 scope,
                 "prepare_remedy_handoff",
                 Jason.encode!(%{"run_ref" => context.run.id, "instance_ref" => row_only})
               )

      assert handoff["requested"] == true
      assert handoff["handoff"]["targets"] == []
      assert handoff["handoff"]["navigable"] == false
      assert [%{"reason" => reason} | _rest] = handoff["handoff"]["unresolved"]
      assert is_binary(reason)
      assert evidence.total == 0

      assert {:ok, %{"corrections" => [], "navigation" => true}, list_evidence} =
               Dispatch.call(FeedQuality, scope, "list_supported_remedies", "{}")

      assert list_evidence.kind == "supported_remedies"
      assert list_evidence.total == 0

      # An unapproved row-only reference still returns discovery, never a handoff.
      plain = validation_scope(context, %{})

      assert {:ok, %{"requested" => false, "handoff" => nil}, _evidence} =
               Dispatch.call(
                 FeedQuality,
                 plain,
                 "prepare_remedy_handoff",
                 Jason.encode!(%{"run_ref" => context.run.id, "instance_ref" => row_only})
               )
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp completed_run(organization, version) do
    {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

    run
    |> ValidationRun.system_changeset(%{
      status: "completed",
      completed_at: DateTime.utc_now(),
      result_json: %{"notices" => notices()}
    })
    |> Repo.update!()
  end

  # Three retained instances: a resolvable stop, a stop that names no current
  # record, and one that carries only CSV row numbers.
  defp notices do
    [
      %{
        "code" => "missing_required_field",
        "severity" => "WARNING",
        "total_notices" => 3,
        "notices" => [
          %{
            "filename" => "stops.txt",
            "csvRowNumber" => 1,
            "fieldName" => "stop_id",
            "stopId" => "STOP-1"
          },
          %{
            "filename" => "stops.txt",
            "csvRowNumber" => 2,
            "fieldName" => "stop_id",
            "stopId" => "NOPE"
          },
          %{"filename" => "stops.txt", "csvRowNumber" => 3, "fieldName" => "stop_id"}
        ],
        "retained_notices" => 3,
        "sample_completeness" => "complete"
      }
    ]
  end

  defp validation_scope(context, extra_payload) do
    payload =
      Map.merge(
        %{
          "schema_version" => 1,
          "section" => "validation",
          "run_ref" => context.run.id
        },
        extra_payload
      )

    scope(context, payload)
  end

  defp export_scope(context, defaults) do
    scope(context, %{
      "schema_version" => 1,
      "section" => "export",
      "type" => "full",
      "defaults_digest" => defaults_digest(defaults)
    })
  end

  defp scope(context, payload) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "feed_quality",
      version_name: context.version.name,
      resource_context: snapshot_context(context.version.id, payload)
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

  # The digest contract the step defines for the current defaults.
  defp defaults_digest(defaults) do
    {:export_defaults, defaults.include_flex, defaults.realtime_source,
     defaults.estimate_missing_times, defaults.estimate_method}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp instance_ref(context, index) do
    scope = validation_scope(context, %{})
    assert {:ok, report} = Evidence.findings(scope, %{run_id: context.run.id})
    assert [group] = report.groups
    group.instances |> Enum.at(index) |> Map.fetch!(:ref)
  end

  ## Composed-turn helpers (the same shape as the FeedQuality findings test)

  defp run_prepared_turn(scope, text) do
    assert {:ok, pid, snapshot} = Agents.open(scope)
    assert :ok = Agents.send_message(pid, text)
    {pid, snapshot.conversation_id, await_settled(pid)}
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

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
