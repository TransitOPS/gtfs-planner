defmodule GtfsPlanner.Agents.SessionTest.SentinelPack do
  @moduledoc """
  Test-only pack for the session's failure paths.

  `explode` raises with its argument inside the exception message, so a test can
  prove the sentinel never reaches the log. `fill` returns a result just below
  the per-call byte limit, so a few of them in one turn push the next serialized
  request over the 131,072-byte envelope.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope

  @impl true
  def id, do: "sentinel"

  @impl true
  def title, do: "Sentinel helper"

  @impl true
  def intro, do: "I fail on purpose."

  @impl true
  def examples, do: ["Explode", "Fill the history."]

  @impl true
  def skill, do: "Fail deterministically for the session tests."

  @impl true
  def tools do
    [
      %{
        name: "explode",
        description: "Raises with its argument inside the exception message.",
        activity: "Exploded",
        parameters: %{
          "type" => "object",
          "properties" => %{"detail" => %{"type" => "string"}},
          "required" => ["detail"],
          "additionalProperties" => false
        }
      },
      %{
        name: "fill",
        description: "Returns a result just below the per-call byte limit.",
        activity: "Filled the history",
        parameters: %{
          "type" => "object",
          "properties" => %{"bytes" => %{"type" => "integer"}},
          "required" => ["bytes"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def call("explode", %{"detail" => detail}, %Scope{}) do
    raise "sentinel pack exploded with #{detail}"
  end

  def call("fill", %{"bytes" => bytes}, %Scope{}) do
    {:ok, %{"blob" => String.duplicate("x", bytes)}}
  end
end

defmodule GtfsPlanner.Agents.SessionTest do
  use GtfsPlanner.DataCase, async: false

  import ExUnit.CaptureLog
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.EchoPack
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.Session
  alias GtfsPlanner.Agents.SessionTest.SentinelPack

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response below replaces only the HTTP boundary (INV-5).
  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor
  @model "test/model-a"

  @stopped_text "Request stopped. No changes were saved."
  @incomplete_text "The helper couldn't finish this request. No changes were saved."
  @unavailable_text "The helper is unavailable right now. Try again, or make the change yourself on this page."
  @context_limit_text "This conversation is too large. Start a new conversation or narrow the request."
  @forbidden_text "Your access changed. The helper stopped."

  @weekdays %{
    monday: 1,
    tuesday: 1,
    wednesday: 1,
    thursday: 1,
    friday: 1,
    saturday: 0,
    sunday: 0
  }

  @prepare_arguments ~s|{"dates":["2026-10-12","2026-10-13"],"stop":["SCHOOL_EX","SCHOOL_WD"],"run":[]}|
  @prepared_command {:date_change, [~D[2026-10-12], ~D[2026-10-13]], ["SCHOOL_EX", "SCHOOL_WD"],
                     []}

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug must
    # be shared and the SQL sandbox must be shared too (`async: false`).
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    add_calendar(organization, version, "SCHOOL_WD", "School weekdays")
    add_calendar(organization, version, "SCHOOL_EX", "School express")

    %{organization: organization, version: version, user: user, membership: membership}
  end

  describe "attach and listeners" do
    test "attach returns the conversation snapshot and detach removes the listener", context do
      session = start_session(context, EchoPack)

      assert {:ok, snapshot} = Session.attach(session)
      assert is_binary(snapshot.conversation_id)
      assert snapshot.entries == []
      assert snapshot.status == :idle

      assert Map.keys(:sys.get_state(session).listeners) == [self()]

      assert :ok = Session.detach(session)
      assert :sys.get_state(session).listeners == %{}

      assert :ok = Session.detach(session)
      assert :sys.get_state(session).listeners == %{}
    end

    test "a listener that stops is removed and the conversation keeps running", context do
      session = start_session(context, EchoPack)
      attach(session)

      expect_blocked()
      stub = blocked_send(session, "A question")

      listener = start_remote_listener(session)

      assert Map.keys(:sys.get_state(session).listeners) |> Enum.sort() ==
               Enum.sort([self(), listener])

      Process.exit(listener, :kill)
      _ = :sys.get_state(session)
      assert Map.keys(:sys.get_state(session).listeners) == [self()]

      release(stub, text_reply("A question"))
      assert_receive {:agent_event, ^session, {:entry, %{role: :assistant, status: :done}}}, 5_000
      assert :sys.get_state(session).status == :idle
    end
  end

  describe "admission and bounds" do
    test "a send while a turn is running is refused and starts no second request", context do
      session = start_session(context, EchoPack)
      attach(session)
      expect_blocked()
      stub = blocked_send(session, "First question")

      assert {:error, :busy} = Session.send_message(session, "A second question")

      state = :sys.get_state(session)
      assert state.status == :working
      assert state.requests == 1

      assert Enum.map(state.entries, &{&1.role, &1.status}) == [
               {:user, :done},
               {:assistant, :working}
             ]

      release(stub, text_reply("First question"))
      assert_receive {:agent_event, ^session, {:entry, %{role: :assistant, status: :done}}}, 5_000
    end

    test "blank and overlong text never start a turn and 2,000 characters is accepted", context do
      session = start_session(context, EchoPack)
      attach(session)
      stub_echo()

      assert {:error, :empty} = Session.send_message(session, "   \n ")
      assert {:error, :empty} = Session.send_message(session, "")

      assert {:error, :too_long} = Session.send_message(session, String.duplicate("a", 2_001))

      state = :sys.get_state(session)
      assert state.requests == 0
      assert state.entries == []
      assert state.messages == []

      run_turn(session, String.duplicate("b", 2_000))
      assert :sys.get_state(session).requests == 1
      assert :sys.get_state(session).status == :idle
    end

    test "the twenty-first request is refused and a new conversation restores the allowance",
         context do
      session = start_session(context, EchoPack)
      attach(session)
      stub_echo()

      Enum.each(1..20, fn index -> run_turn(session, "Question #{index}") end)

      state = :sys.get_state(session)
      assert state.requests == 20
      assert state.status == :limit

      assert {:error, :limit} = Session.send_message(session, "One more question")

      state = :sys.get_state(session)
      assert state.requests == 20
      assert length(state.entries) == 40
      assert state.status == :limit

      assert :ok = Session.new_conversation(session)

      state = :sys.get_state(session)
      assert state.requests == 0
      assert state.entries == []
      assert state.messages == []
      assert state.status == :idle

      run_turn(session, "A fresh question")
      assert :sys.get_state(session).requests == 1
    end

    test "new conversation is refused while working and clears the transcript when idle",
         context do
      session = start_session(context, EchoPack)
      %{conversation_id: first_conversation} = attach(session)
      expect_blocked()
      stub = blocked_send(session, "First question")

      assert {:error, :busy} = Session.new_conversation(session)
      assert :sys.get_state(session).conversation_id == first_conversation

      release(stub, text_reply("First question"))
      assert_receive {:agent_event, ^session, {:entry, %{role: :assistant, status: :done}}}, 5_000

      assert :ok = Session.new_conversation(session)

      assert_receive {:agent_event, ^session, {:reset, new_conversation}}, 2_000
      assert_receive {:agent_event, ^session, {:status, :idle}}, 2_000

      assert is_binary(new_conversation)
      refute new_conversation == first_conversation

      state = :sys.get_state(session)
      assert state.conversation_id == new_conversation
      assert state.entries == []
      assert state.messages == []
      assert state.requests == 0
      assert state.retry_sources == %{}
    end
  end

  describe "stopping and ending one turn" do
    test "stop kills the running task and settles one stopped entry", context do
      session = start_session(context, EchoPack)
      attach(session)
      expect_blocked()
      _stub = blocked_send(session, "Stop this question")

      turn = :sys.get_state(session).turn
      assert is_reference(turn.turn_id)
      assert is_reference(turn.task_ref)
      refute turn.turn_id == turn.task_ref

      monitor = Process.monitor(turn.task_pid)

      assert :ok = Session.stop(session)

      assert_receive {:DOWN, ^monitor, :process, _, _reason}, 5_000

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :stopped} = entry}},
                     2_000

      assert entry.text == @stopped_text
      assert entry.prepared == nil
      assert entry.id == turn.entry_id

      assert_receive {:agent_event, ^session, {:status, :idle}}, 2_000

      state = :sys.get_state(session)
      assert state.turn == nil
      assert state.status == :idle
      assert state.requests == 1

      # No late event and no proposal can change the settled entry.
      refute_receive {:agent_event, ^session, {:entry, %{prepared: %{summary: _}}}}, 100

      assert :ok = Session.stop(session)
    end

    test "a turn past its wall time ends incomplete and its task is dead", context do
      session = start_session(context, EchoPack, turn_timeout_ms: 100)
      attach(session)
      expect_blocked()
      _stub = blocked_send(session, "A slow question")

      task_pid = :sys.get_state(session).turn.task_pid
      monitor = Process.monitor(task_pid)

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :incomplete} = entry}},
                     5_000

      assert entry.text == @incomplete_text
      assert entry.prepared == nil

      assert_receive {:DOWN, ^monitor, :process, ^task_pid, _reason}, 5_000
      assert_receive {:agent_event, ^session, {:status, :idle}}, 2_000

      state = :sys.get_state(session)
      assert state.turn == nil
      assert Enum.map(state.entries, & &1.status) == [:done, :incomplete]
      assert List.last(state.messages) == %{"role" => "assistant", "content" => @incomplete_text}
      refute Enum.any?(state.messages, &(&1["role"] == "tool"))
    end

    test "the eight-call loop bound also settles as incomplete", context do
      session = start_session(context, EchoPack)
      attach(session)

      expect_reply(calls_reply([{"call_1", "echo", ~s|{"text":"keep going"}|}], 0.0001), 8)

      assert :ok = Session.send_message(session, "Keep looking.")

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :incomplete} = entry}},
                     10_000

      assert entry.text == @incomplete_text
      assert entry.activity == List.duplicate("Echoed text", 8)
      assert length(collect_requests()) == 8
    end

    test "an idle conversation announces its end and stops normally", context do
      session = start_session(context, EchoPack, idle_timeout_ms: 50)
      attach(session)
      monitor = Process.monitor(session)

      assert_receive {:agent_event, ^session, {:status, :ended}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
    end

    test "a cancelled idle token cannot expire the session and completion rearms it", context do
      session = start_session(context, EchoPack, idle_timeout_ms: 100_000)
      attach(session)

      stale_token = :sys.get_state(session).idle_token
      assert is_reference(stale_token)

      expect_blocked()
      stub = blocked_send(session, "A question")

      send(session, {:idle_timeout, stale_token})
      _ = :sys.get_state(session)
      assert :sys.get_state(session).status == :working

      release(stub, text_reply("A question"))
      assert_receive {:agent_event, ^session, {:entry, %{role: :assistant, status: :done}}}, 5_000

      state = :sys.get_state(session)
      assert is_reference(state.idle_token)
      refute state.idle_token == stale_token

      monitor = Process.monitor(session)
      send(session, {:idle_timeout, state.idle_token})

      assert_receive {:agent_event, ^session, {:status, :ended}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
    end
  end

  describe "failures and access" do
    test "a pack exception ends the turn failed without a tool sequence", context do
      session = start_session(context, EchoPack)
      attach(session)

      expect_reply(calls_reply([{"call_1", "echo", ~s|{"text":"raise"}|}], 0.0001))

      assert :ok = Session.send_message(session, "Echo raise.")

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :failed} = entry}},
                     5_000

      assert entry.text == @unavailable_text
      assert entry.prepared == nil
      assert entry.activity == []

      state = :sys.get_state(session)
      assert state.status == :idle
      assert state.requests == 1
      assert Enum.map(state.messages, & &1["role"]) == ["user", "assistant"]
      assert List.last(state.messages) == %{"role" => "assistant", "content" => @unavailable_text}
    end

    test "a model error keeps the observed tools, activity and known cost", context do
      session = start_session(context, EchoPack)
      attach(session)

      expect_reply(calls_reply([{"call_1", "echo", ~s|{"text":"hello"}|}], 0.0001))
      expect_response(429, %{"error" => %{"message" => "slow down"}})

      log =
        capture_agent_log(fn ->
          assert :ok = Session.send_message(session, "Echo hello.")

          assert_receive {:agent_event, ^session,
                          {:entry, %{role: :assistant, status: :failed} = entry}},
                         5_000

          assert entry.text == @unavailable_text
          assert entry.activity == ["Echoed text"]
        end)

      assert log =~ "outcome=failed"
      assert log =~ "cost=0.0001"
      assert log =~ "cost_complete=false"
    end

    test "a revoked member cannot send a message", context do
      session = start_session(context, EchoPack)
      attach(session)
      deactivate_membership_fixture(context.membership)
      stub_reply(text_reply("Never sent."))

      monitor = Process.monitor(session)

      assert {:error, :forbidden} = Session.send_message(session, "A question")

      refute_received {:model_request, _request}
      assert_receive {:agent_event, ^session, {:status, :forbidden}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
    end

    test "a revocation during a turn ends forbidden and stops normally", context do
      session = start_session(context, EchoPack)
      attach(session)

      expect_reply_deactivating(
        context,
        calls_reply([{"call_1", "echo", ~s|{"text":"hello"}|}], 0.0001)
      )

      monitor = Process.monitor(session)
      assert :ok = Session.send_message(session, "Echo hello.")

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :forbidden} = entry}},
                     5_000

      assert entry.text == @forbidden_text
      assert entry.prepared == nil

      assert_receive {:agent_event, ^session, {:status, :forbidden}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
    end

    test "a revocation before delivery discards the answer and its proposal", context do
      session = start_session(context, Calendars)
      attach(session)

      expect_reply(calls_reply([{"call_1", "prepare_date_change", @prepare_arguments}], 0.0001))
      expect_reply_deactivating(context, text_reply("SHOULD-NOT-APPEAR", 0.0002))

      monitor = Process.monitor(session)
      assert :ok = Session.send_message(session, "Remove service on October 12 and 13.")

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :forbidden} = entry}},
                     5_000

      assert entry.text == @forbidden_text
      assert entry.prepared == nil
      refute_received {:agent_event, ^session, {:entry, %{text: "SHOULD-NOT-APPEAR"}}}

      assert_receive {:agent_event, ^session, {:status, :forbidden}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
    end

    test "an oversized accumulated context fails visibly with the narrowing copy", context do
      session = start_session(context, SentinelPack)
      attach(session)

      calls =
        for index <- 1..4 do
          {"call_#{index}", "fill", ~s|{"bytes":32750}|}
        end

      expect_reply(calls_reply(calls, 0.0001))

      assert :ok = Session.send_message(session, "Fill the history.")

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :incomplete} = entry}},
                     5_000

      assert entry.text == @context_limit_text
      assert entry.activity == List.duplicate("Filled the history", 4)
      assert length(collect_requests()) == 1

      state = :sys.get_state(session)
      assert Enum.map(state.messages, & &1["role"]) == ["user", "assistant"]
      assert state.status == :idle
    end
  end

  describe "history" do
    test "two successful turns keep every user message and tool sequence exactly once", context do
      session = start_session(context, EchoPack)
      attach(session)

      expect_reply(calls_reply([{"call_1", "echo", ~s|{"text":"one"}|}], 0.0001))
      expect_reply(text_reply("First answer.", 0.0001))
      expect_reply(calls_reply([{"call_2", "echo", ~s|{"text":"two"}|}], 0.0001))
      expect_reply(text_reply("Second answer.", 0.0001))
      expect_reply(text_reply("Third answer.", 0.0001))

      assert :ok = Session.send_message(session, "First question")
      await_answer(session, "First answer.")

      assert :ok = Session.send_message(session, "Second question")
      await_answer(session, "Second answer.")

      assert :ok = Session.send_message(session, "Third question")
      await_answer(session, "Third answer.")

      requests = collect_requests()
      assert length(requests) == 5

      messages = List.last(requests)["messages"]

      assert Enum.map(messages, & &1["role"]) == [
               "system",
               "user",
               "assistant",
               "tool",
               "assistant",
               "user",
               "assistant",
               "tool",
               "assistant",
               "user"
             ]

      users = for %{"role" => "user", "content" => content} <- messages, do: content
      assert users == ["First question", "Second question", "Third question"]

      tool_ids = for %{"role" => "tool", "tool_call_id" => id} <- messages, do: id
      assert tool_ids == ["call_1", "call_2"]

      call_ids =
        for %{"role" => "assistant", "tool_calls" => calls} <- messages,
            call <- calls,
            do: call["id"]

      assert call_ids == ["call_1", "call_2"]
    end

    test "late task and turn references cannot change the next turn", context do
      session = start_session(context, EchoPack)
      attach(session)
      expect_blocked(2)

      first_stub = blocked_send(session, "First question")
      first_turn = :sys.get_state(session).turn
      release(first_stub, text_reply("First answer."))
      assert_receive {:agent_event, ^session, {:entry, %{role: :assistant, status: :done}}}, 5_000

      second_stub = blocked_send(session, "Second question")
      second_turn = :sys.get_state(session).turn
      refute second_turn.turn_id == first_turn.turn_id
      refute second_turn.task_ref == first_turn.task_ref
      refute second_turn.task_ref == second_turn.turn_id

      send(session, {first_turn.task_ref, {:ok, late_result()}})
      send(session, {:DOWN, first_turn.task_ref, :process, first_turn.task_pid, :killed})
      send(session, {:turn_event, first_turn.turn_id, {:activity, "Late activity"}})
      send(session, {:turn_event, first_turn.turn_id, {:tool, "late_tool"}})
      send(session, {:turn_timeout, first_turn.turn_id})
      _ = :sys.get_state(session)

      state = :sys.get_state(session)
      assert state.turn.turn_id == second_turn.turn_id
      assert state.turn.activity == []
      assert state.turn.tools == []
      assert state.status == :working

      release(second_stub, text_reply("Second answer."))

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :done, text: "Second answer."}}},
                     5_000

      assert :sys.get_state(session).status == :idle
    end

    test "retry resends a failed entry's original text through admission", context do
      session = start_session(context, EchoPack)
      %{conversation_id: conversation_id} = attach(session)

      expect_reply(calls_reply([{"call_1", "echo", ~s|{"text":"raise"}|}], 0.0001))

      assert :ok = Session.send_message(session, "Echo raise please")

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :failed} = failed}},
                     5_000

      stub_echo()

      assert :ok = Session.retry(session, conversation_id, failed.id)

      assert_receive {:agent_event, ^session,
                      {:entry, %{role: :assistant, status: :done, text: "Echo raise please"}}},
                     5_000

      assert :sys.get_state(session).requests == 2
    end
  end

  describe "application receipts" do
    test "a receipt requires the exact command in the same conversation", context do
      session = start_session(context, Calendars)
      %{conversation_id: conversation_id} = attach(session)

      entry =
        expect_prepared_turn(
          session,
          "Remove service on October 12 and 13.",
          "I prepared the change."
        )

      assert {:ok, prepared} = Session.prepared(session, conversation_id, entry.id)

      assert prepared.command == @prepared_command
      assert prepared.summary.title == "Stop service"
      assert prepared.summary.lines == ["Stop · School express", "Stop · School weekdays"]

      assert {:error, :command_changed} =
               Session.record_applied(
                 session,
                 conversation_id,
                 entry.id,
                 {:date_change, [~D[2026-10-12]], [], ["SCHOOL_WD"]}
               )

      assert applied?(session, entry.id) == false

      assert {:error, :stale_origin} =
               Session.record_applied(
                 session,
                 "00000000-0000-0000-0000-000000000000",
                 entry.id,
                 prepared.command
               )

      refute_received {:agent_event, ^session, {:entry, %{applied?: true}}}

      assert :ok = Session.record_applied(session, conversation_id, entry.id, prepared.command)

      assert_receive {:agent_event, ^session, {:entry, %{id: entry_id, applied?: true}}}, 2_000
      assert entry_id == entry.id

      # An applied proposal is not offered again, and a receipt needs a proposal.
      assert :error = Session.prepared(session, conversation_id, entry.id)

      assert {:error, :stale_origin} =
               Session.record_applied(session, conversation_id, 1, prepared.command)
    end

    test "a reset elsewhere cannot mark a reused entry id applied", context do
      session = start_session(context, Calendars)
      %{conversation_id: first_conversation} = attach(session)

      first_entry = expect_prepared_turn(session, "Prepare the first change.", "First prepared.")

      assert :ok = Session.new_conversation(session)
      second_conversation = :sys.get_state(session).conversation_id
      refute second_conversation == first_conversation

      second_entry =
        expect_prepared_turn(session, "Prepare the second change.", "Second prepared.")

      assert second_entry.id == first_entry.id

      assert {:ok, second_prepared} =
               Session.prepared(session, second_conversation, second_entry.id)

      assert {:error, :stale_origin} =
               Session.record_applied(
                 session,
                 first_conversation,
                 first_entry.id,
                 second_prepared.command
               )

      refute_received {:agent_event, ^session, {:entry, %{applied?: true}}}

      assert :ok =
               Session.record_applied(
                 session,
                 second_conversation,
                 second_entry.id,
                 second_prepared.command
               )

      assert_receive {:agent_event, ^session, {:entry, %{id: entry_id, applied?: true}}}, 2_000
      assert entry_id == second_entry.id
    end

    test "a stale lookup or retry cannot reach a reused entry id", context do
      session = start_session(context, Calendars)
      %{conversation_id: old_conversation} = attach(session)

      old_entry = expect_prepared_turn(session, "Prepare the change.", "Prepared.")

      assert :ok = Session.new_conversation(session)
      new_conversation = :sys.get_state(session).conversation_id

      new_entry = expect_prepared_turn(session, "Prepare the change again.", "Prepared again.")
      assert new_entry.id == old_entry.id

      assert :error = Session.prepared(session, old_conversation, old_entry.id)
      assert {:error, :stale_origin} = Session.retry(session, old_conversation, old_entry.id)

      assert {:ok, prepared} = Session.prepared(session, new_conversation, new_entry.id)
      assert prepared.command == @prepared_command

      # Retry accepts only a failed entry.
      assert {:error, :stale_origin} = Session.retry(session, new_conversation, new_entry.id)
    end
  end

  describe "logging" do
    test "a finished turn logs outcome metadata without content", context do
      session = start_session(context, EchoPack)
      attach(session)

      user_text = "SENTINEL-USER-TEXT-6f1d please echo"
      arguments = ~s|{"text":"SENTINEL-ARGUMENT-2c8b"}|

      expect_reply(calls_reply([{"call_1", "echo", arguments}], 0.0001))
      expect_reply(text_reply("Echoed.", 0.0003))

      log =
        capture_agent_log(fn ->
          assert :ok = Session.send_message(session, user_text)

          assert_receive {:agent_event, ^session, {:entry, %{role: :assistant, status: :done}}},
                         5_000
        end)

      assert log =~ "agent turn finished"
      assert log =~ "pack=echo"
      assert log =~ "model=#{@model}"
      assert log =~ "organization_id=#{context.organization.id}"
      assert log =~ "outcome=done"
      assert log =~ "tools=echo"
      assert log =~ "duration_ms="
      assert log =~ "cost=" <> Float.to_string(0.0001 + 0.0003)
      assert log =~ "cost_complete=true"
      refute log =~ user_text
      refute log =~ "SENTINEL-ARGUMENT-2c8b"
    end

    test "a task exception logs only sanitized diagnostics and terminal metadata", context do
      session = start_session(context, SentinelPack)
      attach(session)

      user_text = "SENTINEL-USER-TEXT-4f8c1a"

      expect_reply(
        calls_reply([{"call_1", "explode", ~s|{"detail":"SENTINEL-ARGUMENT-9b2e"}|}], 0.0001)
      )

      log =
        capture_agent_log(fn ->
          assert :ok = Session.send_message(session, user_text)

          assert_receive {:agent_event, ^session, {:entry, %{role: :assistant, status: :failed}}},
                         5_000
        end)

      refute log =~ user_text
      refute log =~ "SENTINEL-ARGUMENT-9b2e"

      assert log =~ "agent turn task crashed"
      assert log =~ "failure_class=task_exception"

      assert log =~ "agent turn finished"
      assert log =~ "pack=sentinel"
      assert log =~ "model=#{@model}"
      assert log =~ "organization_id=#{context.organization.id}"
      assert log =~ "outcome=crashed"
      assert log =~ "tools=explode"
      assert log =~ "duration_ms="
      assert log =~ "cost=0.0001"
      assert log =~ "cost_complete=false"
    end
  end

  describe "turn capacity" do
    test "the eight-turn capacity rejects a ninth send and every release frees a slot", context do
      block_requests()

      sessions = Enum.map(1..8, fn _index -> start_session(context, EchoPack) end)
      Enum.each(sessions, &attach/1)
      stubs = Enum.map(sessions, fn session -> blocked_send(session, "A blocked question") end)

      ninth = start_session(context, EchoPack)
      attach(ninth)
      assert_capacity(ninth, "A ninth question")

      # A reset clears this conversation without bypassing the shared capacity.
      assert :ok = Session.new_conversation(ninth)
      assert_capacity(ninth, "A ninth question")

      # A completed turn frees one slot.
      [first | _rest] = sessions
      release_slot(first, Enum.at(stubs, 0), text_reply("A blocked question"))
      _ninth_stub = blocked_send(ninth, "After a completed turn")

      # A stop frees one slot.
      stop_slot(ninth)
      tenth = start_session(context, EchoPack)
      attach(tenth)
      tenth_stub = blocked_send(tenth, "After a stop")

      # A crashed turn frees one slot.
      release_slot(
        tenth,
        tenth_stub,
        calls_reply([{"call_1", "echo", ~s|{"text":"raise"}|}], 0.0001)
      )

      assert_receive {:agent_event, ^tenth, {:entry, %{role: :assistant, status: :failed}}}, 5_000

      # A timed-out turn frees one slot.
      twelfth = start_session(context, EchoPack, turn_timeout_ms: 100)
      attach(twelfth)
      _twelfth_stub = blocked_send(twelfth, "A slow question")
      twelfth_task = :sys.get_state(twelfth).turn.task_pid
      twelfth_monitor = Process.monitor(twelfth_task)

      assert_receive {:agent_event, ^twelfth, {:entry, %{role: :assistant, status: :incomplete}}},
                     5_000

      assert_receive {:DOWN, ^twelfth_monitor, :process, ^twelfth_task, _reason}, 5_000
      _ = :sys.get_state(@turn_supervisor)

      thirteenth = start_session(context, EchoPack)
      attach(thirteenth)
      _thirteenth_stub = blocked_send(thirteenth, "After a timeout")
    end
  end

  ## Fixtures and helpers

  defp start_session(context, pack, opts \\ []) do
    scope = %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: pack.id(),
      version_name: context.version.name
    }

    child =
      Supervisor.child_spec({Session, [scope: scope, pack: pack] ++ opts},
        id: {Session, System.unique_integer([:positive])}
      )

    start_supervised!(child)
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
  end

  defp attach(session) do
    assert {:ok, snapshot} = Session.attach(session)
    snapshot
  end

  defp run_turn(session, text) do
    assert :ok = Session.send_message(session, text)

    assert_receive {:agent_event, ^session,
                    {:entry, %{role: :assistant, status: :done, text: ^text}}},
                   5_000
  end

  defp await_answer(session, text) do
    assert_receive {:agent_event, ^session,
                    {:entry, %{role: :assistant, status: :done, text: ^text}}},
                   5_000
  end

  defp expect_prepared_turn(session, user_text, reply_text) do
    expect_reply(calls_reply([{"call_1", "prepare_date_change", @prepare_arguments}], 0.0001))
    expect_reply(text_reply(reply_text, 0.0001))

    assert :ok = Session.send_message(session, user_text)

    assert_receive {:agent_event, ^session, {:entry, %{role: :assistant, status: :done} = entry}},
                   5_000

    entry
  end

  # config/test.exs runs the logger at :warning, so the info outcome line is
  # dropped unless this assertion lowers the level for its duration.
  defp capture_agent_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp applied?(session, entry_id) do
    session
    |> :sys.get_state()
    |> Map.fetch!(:entries)
    |> Enum.find(&(&1.id == entry_id))
    |> Map.fetch!(:applied?)
  end

  defp assert_capacity(session, text) do
    assert {:error, :capacity} = Session.send_message(session, text)

    state = :sys.get_state(session)
    assert state.entries == []
    assert state.requests == 0
    assert state.status == :idle
    refute_received {:blocked, _stub}
  end

  defp release_slot(session, stub, payload) do
    task_pid = :sys.get_state(session).turn.task_pid
    monitor = Process.monitor(task_pid)
    release(stub, payload)
    assert_receive {:DOWN, ^monitor, :process, ^task_pid, _reason}, 5_000
    _ = :sys.get_state(@turn_supervisor)
  end

  defp stop_slot(session) do
    task_pid = :sys.get_state(session).turn.task_pid
    monitor = Process.monitor(task_pid)
    assert :ok = Session.stop(session)
    assert_receive {:DOWN, ^monitor, :process, ^task_pid, _reason}, 5_000
    _ = :sys.get_state(@turn_supervisor)
  end

  defp start_remote_listener(session) do
    parent = self()

    listener =
      spawn(fn ->
        receive do
          {:attach, session, parent} ->
            Session.attach(session)
            send(parent, {:attached, self()})

            receive do
              :stop -> :ok
            end
        end
      end)

    send(listener, {:attach, session, parent})
    assert_receive {:attached, ^listener}, 2_000
    listener
  end

  defp late_result do
    %{
      text: "A late answer.",
      messages: [%{"role" => "assistant", "content" => "A late answer."}],
      activity: [],
      prepared: nil,
      tools: [],
      cost: 0.0,
      cost_complete: true,
      response_models: [@model]
    }
  end

  ## Req.Test scripting

  defp text_reply(text, cost \\ 0.0), do: reply("stop", %{"content" => text}, cost)

  defp calls_reply(calls, cost) do
    tool_calls =
      Enum.map(calls, fn {id, name, arguments} ->
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => arguments}
        }
      end)

    reply("tool_calls", %{"content" => nil, "tool_calls" => tool_calls}, cost)
  end

  defp reply(finish_reason, message, cost) do
    usage = if is_nil(cost), do: %{}, else: %{"cost" => cost}

    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => finish_reason, "message" => message}],
      "usage" => usage
    }
  end

  defp expect_reply(payload, count \\ 1) do
    test = self()
    Req.Test.expect(@owner, count, fn conn -> respond(conn, test, payload) end)
  end

  defp expect_response(status, payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(payload))
    end)
  end

  # Answers with `payload` after deactivating the membership, so the turn's next
  # authorization check sees the revocation.
  defp expect_reply_deactivating(context, payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      deactivate_membership_fixture(context.membership)
      respond(conn, test, payload)
    end)
  end

  defp stub_reply(payload) do
    test = self()
    Req.Test.stub(@owner, fn conn -> respond(conn, test, payload) end)
  end

  defp stub_echo do
    test = self()

    Req.Test.stub(@owner, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test, {:model_request, request})
      send_json(conn, text_reply(last_user_text(request)))
    end)
  end

  defp block_requests do
    test = self()

    Req.Test.stub(@owner, fn conn -> block(conn, test) end)
  end

  defp expect_blocked(count \\ 1) do
    test = self()
    Req.Test.expect(@owner, count, fn conn -> block(conn, test) end)
  end

  defp block(conn, test) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test, {:model_request, Jason.decode!(body)})
    send(test, {:blocked, self()})

    receive do
      {:release, payload} -> send_json(conn, payload)
    after
      30_000 -> send_json(conn, text_reply("The stub gave up waiting."))
    end
  end

  defp blocked_send(session, text) do
    assert :ok = Session.send_message(session, text)
    assert_receive {:blocked, stub}, 5_000
    stub
  end

  defp release(stub, payload), do: send(stub, {:release, payload})

  defp respond(conn, test, payload) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test, {:model_request, Jason.decode!(body)})
    send_json(conn, payload)
  end

  defp send_json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp last_user_text(request) do
    request["messages"]
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> Map.fetch!("content")
  end

  defp collect_requests, do: collect_messages(:model_request)

  defp collect_messages(tag) do
    receive do
      {^tag, payload} -> [payload | collect_messages(tag)]
    after
      0 -> []
    end
  end

  defp add_calendar(organization, version, service_id, name) do
    calendar_fixture(organization.id, version.id, @weekdays |> Map.put(:service_id, service_id))

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end
end
