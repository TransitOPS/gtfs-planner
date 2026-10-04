defmodule GtfsPlanner.Agents.Packs.FlexPolicyTest do
  @moduledoc """
  Merge evidence (EV-3) for the registered Flex policy pack: the three tools, the
  one `flex_policy` source snapshot they are bound to, and the prepared command
  the host's own typed handler receives.

  The expectations are hand-derived from the acceptance cases and from the
  native Flex wording, not from a second invocation of the pack under test:

    * The representative fixture's "Newport Dial-a-Ride" is an area service with
      two areas (`a1` Newport, `a2` Toledo) and the calendars `weekday`,
      `saturday` and `office`. A proposal of `08:00`–`17:00` for `a1` on the
      weekday calendar and one business day by 15:00 therefore reads as "Newport
      only: Weekdays 8:00 am–5:00 pm" and "Book Monday trips by 3:00 pm the
      Friday before", and exports as booking type 2 with
      `prior_notice_service_id` `office`.
    * The service is named by the accepted source snapshot and never by a tool
      argument, so a payload naming another organization's service is the same
      `unavailable` answer as a deleted one and discloses nothing.
    * A calendar the saved policy does not depend on is refused by name only.
    * An answer that does not fit one tool result is refused whole. Nothing is
      truncated into a plausible complete review.
    * Read and prepare write nothing: no entity, audit or job row changes.

  The provider HTTP boundary is the only scripted part. The session, the turn
  task, the dispatch fence, `GtfsPlanner.Gtfs.Flex.Assistant` and the real
  organization and version fixtures are the production ones.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.FlexPolicy
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.Session
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Agents.TurnSupervisor
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Flex.Assistant
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo

  @owner GtfsPlanner.Agents.Model
  @result_cap 32_768

  @read_call "read_1"
  @prepare_call "prepare_1"
  @read_arguments ~s({})

  @prepare_arguments ~s({"scope":"all_supported","hours":[{"area_key":"a1","service_id":"weekday","start":"08:00","end":"17:00"},{"area_key":"a2","service_id":"weekday","start":"09:00","end":"15:00"},{"area_key":"a1","service_id":"saturday","start":"18:00","end":"01:00"},{"area_key":"a2","service_id":"saturday","start":"09:00","end":"15:00"}],"booking_rules":[{"service_id":null,"when":"earlier_day","days":1,"by":"15:00","business_days":true,"office_service_id":"office"},{"service_id":"saturday","when":"earlier_day","days":2,"by":"12:00"}]})

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The session and its turn task are separate processes, so the Req.Test plug
    # and the SQL sandbox are both shared.
    Req.Test.set_req_test_to_shared()
    on_exit(&terminate_sessions/0)
    ensure_turn_supervisor()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Flex Policy Version"})
    other_version = gtfs_version_fixture(organization.id)

    feed = flex_representative_fixture(organization, version)

    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign = flex_representative_fixture(foreign_organization, foreign_version)

    context = %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      other_version: other_version,
      area: feed.services.area,
      detour: feed.services.detour,
      foreign_area: foreign.services.area,
      scope: editor_scope(organization, version, user) |> with_source(feed.services.area.id)
    }

    Map.put(context, :before, row_counts(context))
  end

  describe "an ordinary Agents session" do
    test "dispatch reaches the assistant and prepares a reviewable command", context do
      session = start_session(context.scope)
      assert {:ok, _snapshot} = Session.attach(session)

      stub_turn([
        {@read_call, "get_flex_policy_context", @read_arguments},
        {@prepare_call, "prepare_flex_policy", @prepare_arguments}
      ])

      assert :ok = Session.send_message(session, "Move weekday hours to 8am to 5pm.")

      entry = await_settled(session)
      assert entry.status == :done

      # The read result the model was given is the workspace's own projection:
      # the selected service's hours, its area keys, the calendars and the
      # native generated wording, with no geometry and no other service.
      %{"read_1" => [read], "prepare_1" => [prepare]} = tool_payloads()

      assert read["service"]["name"] == "Newport Dial-a-Ride"
      assert Enum.map(read["areas"], & &1["key"]) == ["a1", "a2"]

      assert read["hours"] |> Enum.map(& &1["service_id"]) |> Enum.uniq() |> Enum.sort() ==
               ["saturday", "weekday"]

      assert "Newport only: Weekdays 7:00 am–6:00 pm" in read["rider_text"]["hours_lines"]

      assert "Newport only: Saturdays 6:00 pm–1:00 am (next day)" in read["rider_text"][
               "hours_lines"
             ]

      refute Jason.encode!(read) =~ context.detour.name
      refute Map.has_key?(hd(read["areas"]), "geojson")
      refute Jason.encode!(read) =~ "South Ridge"

      # The prepared command is the host's own typed value: the accepted source
      # digest, the conversation context digest, the saved dependency
      # fingerprint, the patch, the prepare scope and the exclusions, and
      # nothing else.
      conversation_id = :sys.get_state(session).conversation_id

      assert {:ok, %{summary: summary, command: command}} =
               Session.prepared(session, conversation_id, entry.id)

      assert {:flex_policy, prepared} = command

      assert prepared |> Map.keys() |> Enum.sort() ==
               [
                 :context_digest,
                 :exclusions,
                 :patch,
                 :saved_fingerprint,
                 :scope,
                 :source_digest
               ]

      assert prepared.scope == :all_supported
      assert prepared.source_digest == source_digest(context.scope)
      assert prepared.context_digest == Scope.context_digest(context.scope)
      assert prepared.saved_fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert prepared.patch |> Map.keys() |> Enum.sort() == ["booking_rules", "hours"]
      assert prepared.exclusions != []

      assert summary.title == "Prepare hours and booking rules for Newport Dial-a-Ride"
      assert summary.detail =~ "2 rows changed"
      assert summary.detail =~ "saved version #{context.area.lock_version}"

      assert "Saves nothing. Review the comparison, then Save on the service page." in summary.lines

      # The candidate's own native comparison, as the model read it.
      assert prepare["prepare_scope"] == "all_supported"
      assert prepare["replaced"] == ["hours", "booking_rules"]
      assert Enum.map(prepare["hours"]["changed"], & &1["ordinal"]) == [0]
      assert Enum.sort(prepare["hours"]["unchanged"]) == [1, 2, 3]
      assert Enum.map(prepare["booking_rules"]["changed"], & &1["ordinal"]) == [0]

      assert "Newport only: Weekdays 8:00 am–5:00 pm" in prepare["rider_text"]["candidate"][
               "hours_lines"
             ]

      assert "Book Monday trips by 3:00 pm the Friday before" in prepare["rider_text"][
               "candidate"
             ]["deadline_lines"]

      [main_rule, _saturday_rule] = prepare["export"]["booking_rule_fields"]
      assert main_rule["booking_type"] == 2
      assert main_rule["prior_notice_last_day"] == 1
      assert main_rule["prior_notice_last_time"] == "15:00:00"
      assert main_rule["prior_notice_service_id"] == "office"

      # The server evidence cards ride beside the results, never inside them.
      assert Enum.map(entry.evidence, & &1.kind) ==
               ["flex_policy_workspace", "flex_policy_preparation"]

      assert Enum.map(entry.evidence, & &1.resources) |> List.flatten() |> Enum.uniq() ==
               [%{kind: "flex_service", id: context.area.id, label: "Newport Dial-a-Ride"}]

      # Read and prepare wrote nothing at all.
      assert row_counts(context) == context.before
    end

    test "a calendar fact answer is scoped to the saved policy's own calendars", context do
      assert {:ok, result, evidence} =
               Dispatch.call(
                 FlexPolicy,
                 context.scope,
                 "get_flex_calendar_facts",
                 Jason.encode!(%{"service_id" => "office"})
               )

      assert result["service_id"] == "office"
      assert result["weekly"]["monday"] == 1
      assert result["weekly"]["saturday"] == 0
      assert result["weekly"]["start_date"] == "2026-01-01"
      assert result["exceptions"] == []
      assert result["used_by"]["business_day_office_calendar"] == true
      assert Enum.any?(result["used_by"]["booking_rules"], &(&1 =~ "earlier_day"))

      assert evidence.kind == "flex_calendar_facts"
      assert evidence.source_ref == "gtfs_flex_policy_workspace"
      assert evidence.source_revision == Integer.to_string(context.area.lock_version)
      assert evidence.scope.organization_id == context.organization.id

      assert fact(evidence, "Days it runs") == "Mon, Tue, Wed, Thu, Fri"
      assert fact(evidence, "Used by hours rows") == "No saved hours row"

      assert row_counts(context) == context.before
    end
  end

  describe "refusals" do
    test "an unknown argument key or an undeclared tool never reaches the assistant", context do
      assert Dispatch.call(
               FlexPolicy,
               context.scope,
               "get_flex_policy_context",
               Jason.encode!(%{"organization_id" => context.organization.id})
             ) == {:tool_error, "Unexpected argument: organization_id"}

      assert Dispatch.call(
               FlexPolicy,
               context.scope,
               "prepare_flex_policy",
               Jason.encode!(%{"scope" => "all_supported", "service_id" => context.area.id})
             ) == {:tool_error, "Unexpected argument: service_id"}

      # A source cannot ask for a save, an apply or an export: the pack declares
      # no such tool, so the fence refuses the name before the pack runs.
      for name <- ~w(save_flex_service apply_flex_policy export_flex_service) do
        assert Dispatch.call(FlexPolicy, context.scope, name, @read_arguments) ==
                 {:tool_error, "Unknown tool: " <> name}
      end

      assert row_counts(context) == context.before
    end

    test "an unknown row field, area or calendar is refused with the assistant's own reason",
         context do
      assert {:error, message} =
               prepare(
                 %{"scope" => "all_supported", "hours" => [hours_row(%{"phone" => "555"})]},
                 context.scope
               )

      assert message ==
               "That proposal cannot be prepared: hours row 0 has a field this page does not own."

      assert {:error, message} =
               prepare(
                 %{"scope" => "all_supported", "hours" => [hours_row(%{"area_key" => "a9"})]},
                 context.scope
               )

      assert message == "That proposal cannot be prepared: a9 is not an area of this service."

      assert {:error, message} =
               prepare(
                 %{
                   "scope" => "all_supported",
                   "hours" => [hours_row(%{"service_id" => "RETIRED"})]
                 },
                 context.scope
               )

      assert message ==
               "That proposal cannot be prepared: RETIRED is not a calendar in service_id."

      assert {:error, message} =
               prepare(
                 %{"scope" => "all_supported", "hours" => [hours_row(%{"start" => "0800"})]},
                 context.scope
               )

      assert message =~ "That proposal cannot be prepared: hours row 0 is not valid:"

      assert {:error, message} =
               prepare(
                 %{
                   "scope" => "all_supported",
                   "booking_rules" => [Map.delete(business_day_rule(), "office_service_id")]
                 },
                 context.scope
               )

      assert message ==
               "That proposal cannot be prepared: booking rule 0 counts business days but has " <>
                 "no office_service_id; name the office calendar from the policy context or " <>
                 "leave business_days out."

      assert {:error, message} =
               prepare(%{"scope" => "partly", "hours" => [hours_row()]}, context.scope)

      assert message ==
               "That proposal cannot be prepared: scope must be all_supported or hours_only."

      assert {:error, message} = prepare(%{"scope" => "all_supported"}, context.scope)

      assert message == "That proposal cannot be prepared: send hours, booking_rules, or both."

      assert {:error, message} =
               prepare(%{"scope" => "all_supported", "hours" => []}, context.scope)

      assert message ==
               "That proposal cannot be prepared: hours must be a complete, non-empty list of at most 100 rows."

      # Discretionary booking prose is reported, never turned into a rule.
      assert {:error, message} =
               prepare(
                 %{
                   "scope" => "all_supported",
                   "hours" => [hours_row()],
                   "unsupported" => ["same-day if the dispatcher permits"]
                 },
                 context.scope
               )

      assert message ==
               "This policy cannot be represented here: the source states policy this helper " <>
                 "cannot represent: same-day if the dispatcher permits."

      assert {:tool_error, message} =
               Dispatch.call(
                 FlexPolicy,
                 context.scope,
                 "get_flex_calendar_facts",
                 Jason.encode!(%{"service_id" => "RETIRED"})
               )

      assert message =~ "is not one this service's saved hours or booking rules depend on"

      assert row_counts(context) == context.before
    end

    test "a payload naming another organization's service is the single unavailable answer",
         context do
      foreign_scope = with_source(context.scope, context.foreign_area.id)
      assert Scope.authorized_context(foreign_scope) == :ok

      assert Dispatch.call(FlexPolicy, foreign_scope, "get_flex_policy_context", @read_arguments) ==
               {:tool_error, "This Flex service is not available."}

      assert Dispatch.call(FlexPolicy, foreign_scope, "prepare_flex_policy", @prepare_arguments) ==
               {:tool_error, "This Flex service is not available."}

      # A service of this organization in another version is the same answer: no
      # metadata about what this version holds either.
      other_version_scope =
        context.organization
        |> scope_for(context.other_version, context.user)
        |> with_source(context.area.id)

      assert Dispatch.call(
               FlexPolicy,
               other_version_scope,
               "get_flex_policy_context",
               @read_arguments
             ) == {:tool_error, "This Flex service is not available."}

      # A service this organization and version no longer holds is the same
      # answer, and the workspace refuses it before the pack turns it into a
      # message.
      absent = with_source(context.scope, Ecto.UUID.generate())

      assert Assistant.workspace(absent) == {:error, :unavailable}
      assert {:error, message} = prepare(hours_only_input(), absent)
      assert message == "This Flex service is not available."

      assert row_counts(context) == context.before
    end

    test "a saved policy that does not fit one answer is explicitly incomplete", context do
      # A service with more hours windows than one bounded projection may carry is
      # refused as incomplete, never answered with a shorter complete review.
      many =
        Enum.map(1..600, fn _index ->
          %{"area_key" => "a1", "service_id" => "weekday", "start" => "00:00", "end" => "23:59"}
        end)

      {:ok, _service} =
        context.area |> FlexService.changeset(%{"hours" => many}) |> Repo.update()

      assert {:error, {:incomplete, :workspace_too_large}} =
               Assistant.workspace(context.scope)

      assert Dispatch.call(FlexPolicy, context.scope, "get_flex_policy_context", @read_arguments) ==
               {:tool_error,
                "This service's saved policy does not fit in one answer. Narrow the request, or " <>
                  "shorten the policy on the Flex page."}

      # The incomplete service is a fixture, not a write the helper made.
      assert row_counts(context) == %{context.before | services: context.before.services}
    end

    test "a prepared answer that does not fit one tool result is refused whole", context do
      oversized = %{
        "scope" => "all_supported",
        "hours" => [hours_row()],
        "booking_rules" => Enum.map(1..100, fn _index -> business_day_rule() end)
      }

      # The pack prepares it and the fence refuses the whole pair: no truncated
      # comparison and no truncated evidence card.
      assert {:prepared, _prepared, result, _evidence} =
               FlexPolicy.call("prepare_flex_policy", oversized, context.scope)

      assert byte_size(Jason.encode!(result)) > @result_cap

      assert Dispatch.call(
               FlexPolicy,
               context.scope,
               "prepare_flex_policy",
               Jason.encode!(oversized)
             ) == {:tool_error, "Too much data for one result. Narrow the request."}

      assert row_counts(context) == context.before
    end

    test "a revoked membership refuses the tool, the prepared lookup and the next request",
         context do
      session = start_session(context.scope)
      assert {:ok, _snapshot} = Session.attach(session)

      stub_turn([{@prepare_call, "prepare_flex_policy", @prepare_arguments}])
      assert :ok = Session.send_message(session, "Move weekday hours to 8am to 5pm.")
      entry = await_settled(session)
      assert entry.status == :done

      conversation_id = :sys.get_state(session).conversation_id
      assert {:ok, _prepared} = Session.prepared(session, conversation_id, entry.id)

      requests = collect_requests()
      assert length(requests) == 2

      deactivate_membership_fixture(context.membership)

      assert Dispatch.call(FlexPolicy, context.scope, "get_flex_policy_context", @read_arguments) ==
               {:error, :forbidden}

      assert FlexPolicy.call("get_flex_policy_context", %{}, context.scope) ==
               {:error, "Access to Flex services changed."}

      monitor = Process.monitor(session)

      assert Session.prepared(session, conversation_id, entry.id) == {:error, :forbidden}
      assert_receive {:agent_event, ^session, {:status, :forbidden}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000

      # No further provider request, no tool read and no write.
      assert collect_requests() == []
      assert row_counts(context) == context.before
    end
  end

  describe "one conversation per accepted source" do
    test "a replaced source is a different conversation with no old prepared intent", context do
      assert {:ok, first, _snapshot} = Agents.open(context.scope)

      stub_turn([{@prepare_call, "prepare_flex_policy", @prepare_arguments}])
      assert :ok = Session.send_message(first, "Move weekday hours to 8am to 5pm.")
      entry = await_settled(first)
      assert entry.status == :done

      conversation_id = :sys.get_state(first).conversation_id

      assert {:ok, %{command: {:flex_policy, prepared}}} =
               Session.prepared(first, conversation_id, entry.id)

      # The editor accepted different policy text, so the page replaces the
      # context. The prepared command was bound to the old source digest and the
      # old context digest, and neither is reachable from the new conversation.
      replaced = with_source(context.scope, context.area.id, "Weekdays 9 am to 6 pm")

      refute prepared.source_digest == source_digest(replaced)
      refute prepared.context_digest == Scope.context_digest(replaced)

      assert {:ok, second, snapshot} = Agents.open(replaced)
      assert snapshot.entries == []
      assert second != first
      assert Session.prepared(second, conversation_id, entry.id) == :error

      # A second tab with the replaced source is that conversation, and the one
      # still holding the old source is a different one.
      assert {:ok, ^second, _snapshot} = Agents.open(replaced)
      assert {:ok, ^first, _snapshot} = Agents.open(context.scope)

      assert row_counts(context) == context.before
    end

    test "a conversation with no accepted source makes no request and reads nothing", context do
      # The page's own version context, carried by a Flex conversation that has
      # no accepted policy source.
      unsourced = %{
        context.scope
        | resource_context: Scope.context({:version, context.version.id})
      }

      assert Scope.source_snapshot(unsourced) == nil
      assert FlexPolicy.authorize_context(unsourced) == {:error, :unavailable}

      assert Dispatch.call(FlexPolicy, unsourced, "get_flex_policy_context", @read_arguments) ==
               {:error, :unavailable}

      assert Dispatch.call(FlexPolicy, unsourced, "prepare_flex_policy", @prepare_arguments) ==
               {:error, :unavailable}

      session = start_session(unsourced)
      monitor = Process.monitor(session)

      # The pack's own precondition fails at the first boundary, so the
      # conversation ends before the provider request, the tool read or any
      # history of its own.
      assert Session.send_message(session, "Move weekday hours to 8am to 5pm.") ==
               {:error, :unavailable}

      assert_receive {:DOWN, ^monitor, :process, ^session, _reason}, 2_000

      assert collect_requests() == []
      assert row_counts(context) == context.before
    end
  end

  ## Helpers

  defp prepare(args, scope), do: FlexPolicy.call("prepare_flex_policy", args, scope)

  defp hours_row(overrides \\ %{}) do
    Map.merge(
      %{"area_key" => "a1", "service_id" => "weekday", "start" => "08:00", "end" => "17:00"},
      overrides
    )
  end

  defp hours_only_input do
    %{"scope" => "hours_only", "hours" => [hours_row()]}
  end

  defp business_day_rule do
    %{
      "service_id" => nil,
      "when" => "earlier_day",
      "days" => 1,
      "by" => "15:00",
      "business_days" => true,
      "office_service_id" => "office"
    }
  end

  defp source_digest(%Scope{} = scope), do: Scope.source_snapshot(scope).digest

  defp scope_for(organization, version, user) do
    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: FlexPolicy.id(),
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }
  end

  defp editor_scope(organization, version, user), do: scope_for(organization, version, user)

  # The `flex_policy` snapshot a host freezes after explicit editor acceptance.
  # The service is the one the native page had already loaded, so no tool can
  # name a different one.
  defp with_source(
         %Scope{} = scope,
         service_id,
         text \\ "Weekdays 8 am to 5 pm, booked one business day ahead by 3 pm"
       ) do
    {:ok, resource_context} =
      Scope.with_source_snapshot(scope.resource_context, %{
        kind: "flex_policy",
        payload: %{
          "service_id" => service_id,
          "section" => "hours_booking",
          "source" => %{
            "text" => text,
            "label" => "Approved hours and booking policy",
            "accepted" => true
          }
        }
      })

    %{scope | resource_context: resource_context}
  end

  defp start_session(%Scope{} = scope) do
    start_supervised!(
      Supervisor.child_spec({Session, [scope: scope, pack: FlexPolicy]},
        id: {Session, System.unique_integer([:positive])}
      )
    )
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(TurnSupervisor)),
      do: start_supervised!({Task.Supervisor, name: TurnSupervisor, max_children: 8})
  end

  defp await_settled(session) do
    assert_receive {:agent_event, ^session, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working, do: await_settled(session), else: entry
  end

  # One scripted turn: the given tool calls first, then the text that settles the
  # entry with whatever the tools returned. Every request body is handed to the
  # test, so the result the model actually read can be asserted.
  defp stub_turn(calls) do
    test = self()

    Req.Test.stub(@owner, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test, {:model_request, request})

      payload =
        if Enum.any?(request["messages"], &(&1["role"] == "tool")) do
          text_reply("I prepared the change for you to review.")
        else
          tool_calls_reply(calls)
        end

      send_json(conn, payload)
    end)
  end

  # The tool results the model actually read, keyed by the call id that
  # produced them and decoded from the request that carried them rather than read
  # out of the module under test.
  defp tool_payloads do
    :model_request
    |> collect_messages()
    |> Enum.reverse()
    |> Enum.flat_map(& &1["messages"])
    |> Enum.filter(&(&1["role"] == "tool"))
    |> Enum.map(&{&1["tool_call_id"], Jason.decode!(&1["content"])})
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp collect_requests, do: collect_messages(:model_request)

  defp collect_messages(tag) do
    receive do
      {^tag, payload} -> [payload | collect_messages(tag)]
    after
      0 -> []
    end
  end

  defp fact(evidence, label) do
    Enum.find_value(evidence.facts, fn fact -> if fact.label == label, do: fact.value end)
  end

  defp row_counts(context) do
    organization_id = context.organization.id

    %{
      services:
        Repo.aggregate(
          from(s in FlexService, where: s.organization_id == ^organization_id),
          :count
        ),
      areas:
        Repo.aggregate(from(a in FlexArea, where: a.organization_id == ^organization_id), :count),
      audit:
        Repo.aggregate(from(l in ChangeLog, where: l.organization_id == ^organization_id), :count)
    }
  end

  defp tool_calls_reply(calls) do
    %{
      "id" => "gen-test-tool",
      "object" => "chat.completion",
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
      "usage" => %{"cost" => 0.0001, "total_tokens" => 10}
    }
  end

  defp text_reply(text) do
    %{
      "id" => "gen-test-text",
      "object" => "chat.completion",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => text}
        }
      ],
      "usage" => %{"cost" => 0.0001, "total_tokens" => 10}
    }
  end

  defp send_json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  # Sessions started under the application's supervisor outlive the test
  # process, so every session this test opened is terminated here.
  defp terminate_sessions do
    Enum.each(session_pids(), &DynamicSupervisor.terminate_child(SessionSupervisor, &1))
  end

  defp session_pids do
    SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end
