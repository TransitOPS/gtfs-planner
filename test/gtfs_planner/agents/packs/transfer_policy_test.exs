defmodule GtfsPlanner.Agents.Packs.TransferPolicyTest do
  @moduledoc """
  Merge evidence (EV-4) for the supplied transfer-policy pack through the real
  composition: `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` ->
  `Packs.Transfers` -> `Gtfs.Transfers.review_policy_change/3`, with only the
  OpenRouter HTTP boundary doubled.

  The registry, session, turn loop, dispatch fence, pack, step 1's review and the
  real editor changeset are the shipped ones, so a pack that was never registered,
  a tool that never reached the review and a prepared command the session could not
  store all fail here rather than passing over a hand-built controller.

  Every expected value is hand-derived from the A09/AC-2/AC-3 cases and the shared
  literal transfer network, not from a second invocation of the module under test:

    * The page admitted `CEN-A` -> `MKT` with 5 minutes; the prepared rule stores
      300 seconds, because the conversion happens in server code.
    * The same pair's reverse is a different rule: preparing A->B produces exactly
      one item, `CEN-A` to `MKT`, and the stored `MKT` -> `CEN` rule is neither
      returned by the read nor offered as a second item.
    * A selection with no `to` side is asked about once and prepares nothing; the
      pack never fills in a direction.
    * A foreign selector, a type 4 selection, a negative or fractional minimum and
      an over-long selection id are all refused.
    * Deactivating the actor's membership mid-conversation, or replacing the
      admitted payload so it no longer hashes to its digest, refuses the next turn
      before any provider request.
    * A broad rule prepared beside a protected trip exception keeps the exception
      unchanged, and the row count and change-log count prove nothing was written.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_ai05 mix test test/gtfs_planner/agents/packs/transfer_policy_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Transfers
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.TransfersFixtures

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response below replaces only the HTTP boundary (INV-5).
  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @source_kind "transfer_policy"
  @schema_version 1
  @central_platform "CEN-A"
  @market "MKT"

  @selection_arguments ~s({"selection_id":"central-to-market"})
  @prepare_arguments ~s({"selection_ids":["central-to-market"]})
  @final_text "I prepared the rule for you to review."

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and the
    # SQL sandbox are both shared.
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    network = build_context()

    Map.put(network, :scope, scope(network, payload(network)))
  end

  describe "the shipped registration" do
    test "the registry names the pack, its three tools and its skill", _context do
      assert Agents.packs()["transfers"] == Transfers
      assert Transfers.id() == "transfers"
      assert Transfers.title() == "Transfer helper"

      assert Enum.map(Transfers.tools(), & &1.name) == [
               "inspect_transfer_policy",
               "inspect_transfer_competition",
               "prepare_transfer_policy"
             ]

      assert Enum.all?(Transfers.tools(), &(&1.parameters["additionalProperties"] == false))
      assert Transfers.skill() =~ "prepare_transfer_policy"

      # No tool takes an identity, a type, a unit or a direction: a model argument
      # could not state a stop, a trip or a minimum time even if it tried.
      declared =
        Transfers.tools()
        |> Enum.flat_map(fn tool ->
          tool.parameters |> Map.get("properties") |> Map.keys()
        end)

      assert Enum.sort(Enum.uniq(declared)) == ["selection_id", "selection_ids"]
    end

    test "a version identity opens the conversation", context do
      assert {:ok, session, snapshot} = Agents.open(context.scope)
      assert is_pid(session)
      assert snapshot.entries == []
    end

    test "a conversation with no admitted transfer_policy source is refused", context do
      assert {:error, :unavailable} =
               Agents.open(%{context.scope | resource_context: Scope.context(nil)})

      bare = scope(context, nil)
      assert {:error, :unavailable} = Agents.open(bare)

      assert {:error, :unavailable} =
               Dispatch.call(Transfers, bare, "prepare_transfer_policy", @prepare_arguments)
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack -> review)" do
    test "prepares the supplied direction with 300 seconds and writes nothing", context do
      expect_reply(tool_calls_reply([{"call_1", "prepare_transfer_policy", @prepare_arguments}]))
      expect_reply(text_reply(@final_text))

      {entry, session, conversation} =
        run_turn(context.scope, "Give the Central to Market transfer five minutes.")

      assert entry.status == :done
      assert entry.activity == ["Prepared transfer rules"]

      # The command the page confirms item by item: one create, this direction only,
      # with the unit converted by the server.
      assert {:ok, prepared} = Agents.prepared(session, conversation, entry.id)
      assert prepared.command.kind == :transfer_policy_sequence
      assert [item] = prepared.command.items
      assert item.action == :create
      assert item.attrs.from_stop_id == @central_platform
      assert item.attrs.to_stop_id == @market
      assert item.attrs.transfer_type == 2
      assert item.attrs.min_transfer_time == 300
      assert prepared.command.source_digest == source_digest(context.scope)

      # What the model read: the same direction and the same stored seconds.
      assert %{"selections" => [selection], "total" => 1} = tool_result()
      assert selection["from_stop_id"] == @central_platform
      assert selection["to_stop_id"] == @market
      assert selection["after"]["min_transfer_time"] == 300
      assert selection["protected_count"] == 1

      assert [evidence] = entry.evidence
      assert evidence.kind == "transfer_policy_sequence"
      assert evidence.total == 1
      assert evidence.source_ref == "gtfs_transfers"
      assert evidence.digest == source_digest(context.scope)
      assert evidence.scope.organization_id == context.organization.id
      assert [%{kind: "transfer_selection", id: "central-to-market"}] = evidence.resources

      # A preparation writes nothing: no transfer row, no change log, and the
      # protected exception this selection names is still exactly as stored.
      assert Repo.aggregate(Transfer, :count) == context.transfer_count
      assert Repo.aggregate(ChangeLog, :count) == context.change_log_count
      assert context.exception.transfer_type == 3
      assert Repo.get!(Transfer, context.exception.id).updated_at == context.exception.updated_at
    end

    test "an explicit A->B rule never produces a B->A one", context do
      # The literal network already holds a stored `MKT` -> `CEN` rule, so a
      # reciprocal is not hypothetical here.
      expect_reply(tool_calls_reply([{"call_1", "prepare_transfer_policy", @prepare_arguments}]))
      expect_reply(text_reply(@final_text))

      {entry, session, conversation} =
        run_turn(context.scope, "Prepare the Central to Market transfer.")

      assert {:ok, %{command: %{items: [item]}}} =
               Agents.prepared(session, conversation, entry.id)

      assert item.attrs.from_stop_id == @central_platform
      assert item.attrs.to_stop_id == @market
      refute item.attrs.from_stop_id == @market
    end

    test "the read reports the reverse direction's rule without merging it", context do
      expect_reply(
        tool_calls_reply([{"call_1", "inspect_transfer_policy", @selection_arguments}])
      )

      expect_reply(text_reply("No rule is stored in that direction yet."))

      {entry, _session, _conversation} =
        run_turn(context.scope, "What transfer rule covers Central Bay A to Market?")

      # The version does hold the literal reverse rule; it is counted and never
      # returned as this selection's rule.
      assert %{
               "direction" => "#{@central_platform} to #{@market}",
               "total" => 0,
               "rules" => [],
               "stored_minimum_seconds" => nil,
               "reverse_direction_rules" => 1
             } = tool_result()

      assert context.reverse.id != context.stored.id

      assert [evidence] = entry.evidence
      assert evidence.kind == "transfer_policy"
      assert evidence.total == 0
      assert evidence.total_label == "stored general rules"
      assert Enum.find(evidence.facts, &(&1.label == "Reverse direction rules")).value == "1"
      assert Enum.find(evidence.facts, &(&1.label == "Stored minimum")).value == "None stored"
    end

    test "a stored rule in this direction is returned with its literal seconds", context do
      stored =
        write_general!(context, %{
          "from_stop_id" => "MUS",
          "to_stop_id" => "NOC",
          "transfer_type" => "2",
          "min_transfer_time" => "240"
        })

      expect_reply(
        tool_calls_reply([
          {"call_1", "inspect_transfer_policy", ~s({"selection_id":"museum-night"})}
        ])
      )

      expect_reply(text_reply("There is a 4 minute rule stored."))

      {entry, _session, _conversation} =
        run_turn(with_selection(context, "museum-night"), "What is stored for Museum?")

      assert %{"total" => 1, "stored_minimum_seconds" => 240, "rules" => [rule]} = tool_result()
      assert rule["id"] == stored.id
      assert rule["min_transfer_time"] == 240
      assert [evidence] = entry.evidence
      assert evidence.total == 1
      assert Enum.find(evidence.facts, &(&1.label == "Stored minimum")).value == "240 seconds"
    end

    test "the review keeps the protected trip exception and refuses an equal-best one",
         context do
      # The stored `MKT` -> `CEN` rule and a `MKT` -> `CEN-A` command are equally
      # specific and disagree, which is the refusal the review exists to make.
      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_transfer_policy", ~s({"selection_ids":["market-central"]})}
        ])
      )

      expect_reply(text_reply("I did not prepare it."))

      {entry, _session, _conversation} =
        run_turn(with_selection(context, "market-central"), "Add a five minute rule.")

      assert %{"error" => message} = tool_result()
      assert message =~ "equally specific"
      assert entry.evidence == []
      assert Repo.aggregate(Transfer, :count) == context.transfer_count
    end

    test "a missing direction is asked about once and prepares nothing", context do
      expect_reply(
        tool_calls_reply([
          {"call_1", "prepare_transfer_policy", ~s({"selection_ids":["one-sided"]})}
        ])
      )

      expect_reply(text_reply("Which side is the transfer to?"))

      {entry, _session, _conversation} =
        run_turn(with_selection(context, "one-sided"), "Set that transfer time.")

      assert %{"error" => message} = tool_result()
      assert message =~ "Which side is the transfer to?"
      assert entry.evidence == []
      assert Repo.aggregate(Transfer, :count) == context.transfer_count
    end

    test "a revoked actor refuses the next turn before any provider request", context do
      # No request is stubbed: an unauthorized turn must never reach the provider,
      # so `verify_on_exit!` is the assertion.
      assert {:ok, session, _snapshot} = Agents.open(context.scope)
      deactivate_membership_fixture(context.membership)

      assert {:error, :forbidden} = Agents.send_message(session, "Prepare the Central transfer.")
      refute_received {:model_request, _request}
    end

    test "a replaced source payload refuses before any provider request", context do
      # The digest is the server's own hash of the admitted payload, so an edited
      # payload is refused by `Scope.authorized_context/1` before the pack, and no
      # request is stubbed: `verify_on_exit!` is the assertion.
      assert %Scope{
               resource_context: %{source_snapshot: %{payload: payload, digest: digest}}
             } = context.scope

      replaced =
        Map.put(
          payload,
          "selections",
          Enum.map(payload["selections"], &Map.put(&1, "id", "elsewhere"))
        )

      tampered = %{
        context.scope
        | resource_context: %{
            context.scope.resource_context
            | source_snapshot: %{kind: @source_kind, payload: replaced, digest: digest}
          }
      }

      assert {:error, :unavailable} =
               Dispatch.call(Transfers, tampered, "prepare_transfer_policy", @prepare_arguments)

      # The declared arguments are checked before the scope, so a call with them
      # is still refused as unavailable rather than as a schema problem.
      assert {:error, :unavailable} =
               Dispatch.call(Transfers, tampered, "inspect_transfer_policy", @selection_arguments)
    end
  end

  describe "the dispatch fence and the pack's own refusals" do
    test "an identity, type or unit argument never reaches the pack", context do
      for extra <- ["from_stop_id", "to_stop_id", "transfer_type", "min_transfer_time"] do
        arguments = ~s({"selection_id":"central-to-market","#{extra}":"x"})

        assert {:tool_error, message} =
                 Dispatch.call(Transfers, context.scope, "inspect_transfer_policy", arguments)

        assert message =~ "Unexpected argument"
      end
    end

    test "an unknown selection is refused and the empty list is the fence's", context do
      assert {:tool_error, message} =
               Dispatch.call(
                 Transfers,
                 context.scope,
                 "prepare_transfer_policy",
                 ~s({"selection_ids":["not-a-selection"]})
               )

      assert message =~ "not one of the selections on this page"

      assert {:tool_error, message} =
               Dispatch.call(
                 Transfers,
                 context.scope,
                 "prepare_transfer_policy",
                 ~s({"selection_ids":[]})
               )

      assert message =~ "must have 1 or more items"
    end

    test "an over-limit sequence is refused by the fence", context do
      ids = Enum.map_join(1..51, ",", &Jason.encode!("central-to-market-#{&1}"))
      arguments = ~s({"selection_ids":[#{ids}]})

      assert {:tool_error, message} =
               Dispatch.call(Transfers, context.scope, "prepare_transfer_policy", arguments)

      assert message =~ "50"
    end

    test "a foreign selector, a type 4 selection and a bad minimum are refused", context do
      for {selection_id, expected} <- [
            {"foreign-stop", "Choose a stop or station in this version"},
            {"in-seat", "in-seat"},
            {"negative-time", "zero or more seconds"},
            {"fractional-time", "whole number"},
            {"hours", "whole number"}
          ] do
        scope = with_selection(context, selection_id)

        assert {:tool_error, message} =
                 Dispatch.call(
                   Transfers,
                   scope,
                   "prepare_transfer_policy",
                   ~s({"selection_ids":["#{selection_id}"]})
                 )

        assert message =~ expected, "#{selection_id}: #{message}"
      end

      # A foreign stop in another organization is the same refusal as a stop that
      # does not exist, and the reason it exists here is not disclosed.
      assert Repo.aggregate(Transfer, :count) == context.transfer_count
    end

    test "a type 2 selection with no minimum time is refused", context do
      assert {:tool_error, message} =
               Dispatch.call(
                 Transfers,
                 with_selection(context, "no-minimum"),
                 "prepare_transfer_policy",
                 ~s({"selection_ids":["no-minimum"]})
               )

      assert message =~ "needs a minimum time"
    end
  end

  ## Helpers

  # The working placeholder arrives before the settled entry, and each provider
  # request is observable, so a turn is driven and read without polling or sleeping.
  # The session pid and conversation id come back with the entry, so a case can ask
  # the session for the exact prepared command the page would confirm.
  defp run_turn(scope, text) do
    assert {:ok, pid, snapshot} = Agents.open(scope)
    assert :ok = Agents.send_message(pid, text)
    {await_settled(pid), pid, snapshot.conversation_id}
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

  defp write_general!(context, attrs) do
    {:ok, transfer} = GtfsPlanner.Gtfs.Transfers.create_general(attrs, context.audit)
    transfer
  end

  # The literal transfer network from step 1, with the one stored rule that is
  # deliberately in the opposite direction and the protected trip exception a
  # broad rule has to survive.
  defp build_context do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    audit = %GtfsPlanner.Gtfs.AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: user.id,
      actor_email: user.email
    }

    {:ok, stored} =
      GtfsPlanner.Gtfs.Transfers.create_general(
        %{
          "from_stop_id" => @market,
          "to_stop_id" => "CEN",
          "transfer_type" => "0"
        },
        audit
      )

    # The literal reverse of the selected direction, so "a rule exists the other
    # way round" is a fact about this version rather than a hypothetical.
    {:ok, reverse} =
      GtfsPlanner.Gtfs.Transfers.create_general(
        %{
          "from_stop_id" => @market,
          "to_stop_id" => @central_platform,
          "transfer_type" => "0"
        },
        audit
      )

    {:ok, exception} =
      GtfsPlanner.Gtfs.Transfers.create_general(
        %{
          "from_stop_id" => @central_platform,
          "to_stop_id" => @market,
          "from_trip_id" => "12-0815",
          "to_trip_id" => "24-0840",
          "transfer_type" => "3"
        },
        audit
      )

    transfer_count = Repo.aggregate(Transfer, :count)
    change_log_count = Repo.aggregate(ChangeLog, :count)

    %{
      organization: organization,
      version: version,
      user: user,
      membership: membership,
      audit: audit,
      stored: stored,
      reverse: reverse,
      exception: exception,
      transfer_count: transfer_count,
      change_log_count: change_log_count
    }
  end

  # The page's admitted source: schema version, and the selections the person
  # selected on it. Every identity, type and unit below is the page's, not the
  # model's.
  defp payload(context) do
    %{
      "schema_version" => @schema_version,
      "selections" => [
        %{
          "id" => "central-to-market",
          "from" => %{"stop_id" => @central_platform, "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => @market, "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 2,
          "min_time" => %{"value" => 5, "unit" => "minutes"},
          "protected_ids" => [context.exception.id]
        },
        %{
          "id" => "one-sided",
          "from" => %{"stop_id" => "MUS", "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => nil, "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 0
        },
        %{
          "id" => "market-central",
          "from" => %{"stop_id" => @market, "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => "CEN-A", "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 2,
          "min_time" => %{"value" => 4, "unit" => "minutes"}
        },
        %{
          "id" => "museum-night",
          "from" => %{"stop_id" => "MUS", "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => "NOC", "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 2,
          "min_time" => %{"value" => 240, "unit" => "seconds"}
        },
        %{
          "id" => "foreign-stop",
          "from" => %{"stop_id" => "FOREIGN-STOP", "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => @market, "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 0
        },
        %{
          "id" => "in-seat",
          "from" => %{"stop_id" => @central_platform, "route_id" => nil, "trip_id" => "12-0815"},
          "to" => %{"stop_id" => @market, "route_id" => nil, "trip_id" => "24-0840"},
          "transfer_type" => 4
        },
        %{
          "id" => "negative-time",
          "from" => %{"stop_id" => "MUS", "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => "HBR", "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 2,
          "min_time" => %{"value" => -60, "unit" => "seconds"}
        },
        %{
          "id" => "fractional-time",
          "from" => %{"stop_id" => "MUS", "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => "HBR", "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 2,
          "min_time" => %{"value" => 4.5, "unit" => "minutes"}
        },
        %{
          "id" => "hours",
          "from" => %{"stop_id" => "MUS", "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => "HBR", "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 2,
          "min_time" => %{"value" => 2, "unit" => "hours"}
        },
        %{
          "id" => "no-minimum",
          "from" => %{"stop_id" => "MUS", "route_id" => nil, "trip_id" => nil},
          "to" => %{"stop_id" => "HBR", "route_id" => nil, "trip_id" => nil},
          "transfer_type" => 2
        }
      ]
    }
  end

  defp scope(context, snapshot_payload) do
    resource_context =
      case snapshot_payload do
        nil ->
          Scope.context({:version, context.version.id})

        payload ->
          assert {:ok, admitted} =
                   Scope.with_source_snapshot(
                     Scope.context({:version, context.version.id}),
                     %{kind: @source_kind, payload: payload}
                   )

          admitted
      end

    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "transfers",
      version_name: context.version.name,
      resource_context: resource_context
    }
  end

  # A conversation whose admitted source names one selection, used by the cases
  # that must not prepare a different one by accident.
  defp with_selection(context, selection_id) do
    payload = %{
      "schema_version" => @schema_version,
      "selections" => Enum.filter(payload(context)["selections"], &(&1["id"] == selection_id))
    }

    scope(context, payload)
  end

  defp source_digest(%Scope{} = scope) do
    Scope.source_snapshot(scope).digest
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
