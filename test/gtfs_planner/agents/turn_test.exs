defmodule GtfsPlanner.Agents.TurnTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.EchoPack
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.Turn

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response below replaces only the HTTP boundary (INV-5).
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

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
  @get_calendar_arguments ~s|{"service_id":"SCHOOL_WD","from":"2026-10-05","to":"2026-10-06"}|
  @final_text "I prepared the change. Review it before applying."

  setup {Req.Test, :verify_on_exit!}

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "calendars",
      version_name: version.name
    }

    add_calendar(organization, version, "SCHOOL_WD", "School weekdays")
    add_calendar(organization, version, "SCHOOL_EX", "School express")

    %{
      organization: organization,
      version: version,
      user: user,
      membership: membership,
      scope: scope
    }
  end

  describe "run/4 with the Calendars pack" do
    test "runs a list, a prepare and a final text", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))
      expect_reply(calls_reply([{"call_2", "prepare_date_change", @prepare_arguments}], 0.0002))
      expect_reply(text_reply(@final_text, 0.0003))

      assert {:ok, result} =
               Turn.run(
                 Calendars,
                 scope,
                 [user_message("Remove service from School weekdays and School express.")],
                 notify()
               )

      assert result.prepared.command ==
               {:date_change, [~D[2026-10-12], ~D[2026-10-13]], ["SCHOOL_EX", "SCHOOL_WD"], []}

      assert result.prepared.summary.title == "Stop service"
      assert result.tools == ["list_calendars", "prepare_date_change"]
      assert result.activity == ["Looked up calendars", "Prepared a date change"]
      assert result.text == @final_text
      assert_in_delta result.cost, 0.0006, 1.0e-12
      assert result.cost_complete
      assert result.response_models == [@model, @model, @model]
    end

    test "returns the generated assistant and tool messages in order without the system message",
         %{
           scope: scope
         } do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))
      expect_reply(calls_reply([{"call_2", "prepare_date_change", @prepare_arguments}], 0.0002))
      expect_reply(text_reply(@final_text, 0.0003))

      assert {:ok, result} =
               Turn.run(Calendars, scope, [user_message("Prepare the date change.")], notify())

      assert [
               assistant_list,
               tool_list,
               assistant_prepare,
               tool_prepare,
               final
             ] = result.messages

      assert assistant_list == %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => "call_1",
                   "type" => "function",
                   "function" => %{"name" => "list_calendars", "arguments" => "{}"}
                 }
               ]
             }

      assert assistant_prepare == %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => "call_2",
                   "type" => "function",
                   "function" => %{
                     "name" => "prepare_date_change",
                     "arguments" => @prepare_arguments
                   }
                 }
               ]
             }

      assert final == %{"role" => "assistant", "content" => @final_text}

      assert {tool_list["role"], tool_list["tool_call_id"]} == {"tool", "call_1"}
      assert {tool_prepare["role"], tool_prepare["tool_call_id"]} == {"tool", "call_2"}

      refute Enum.any?(result.messages, &(&1["role"] in ["system", "user"]))

      assert tool_ids(tool_list) == ["SCHOOL_EX", "SCHOOL_WD"]
      assert tool_ids(tool_prepare) == ["SCHOOL_EX", "SCHOOL_WD"]
    end

    test "sends each previous tool result in the next request exactly once", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))
      expect_reply(calls_reply([{"call_2", "prepare_date_change", @prepare_arguments}], 0.0002))
      expect_reply(text_reply(@final_text, 0.0003))

      assert {:ok, _result} =
               Turn.run(Calendars, scope, [user_message("Prepare the date change.")], notify())

      assert [first, second, third] = collect_requests()

      assert [%{"role" => "system"}, %{"role" => "user"}] = first["messages"]

      assert [
               %{"role" => "system"},
               %{"role" => "user"},
               %{"role" => "assistant", "tool_calls" => [%{"id" => "call_1"}]},
               %{"role" => "tool", "tool_call_id" => "call_1"}
             ] = second["messages"]

      assert [
               %{"role" => "system"},
               %{"role" => "user"},
               %{"role" => "assistant", "tool_calls" => [%{"id" => "call_1"}]},
               %{"role" => "tool", "tool_call_id" => "call_1"},
               %{"role" => "assistant", "tool_calls" => [%{"id" => "call_2"}]},
               %{"role" => "tool", "tool_call_id" => "call_2"}
             ] = third["messages"]

      assert Enum.count(third["messages"], &(&1["role"] == "user")) == 1
      assert Enum.count(third["messages"], &(&1["role"] == "system")) == 1
    end

    test "answers an unknown tool with a bounded tool message and continues", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "delete_route", "{}"}], 0.0001))
      expect_reply(text_reply("That isn't available in Calendars.", 0.0001))

      assert {:ok, result} =
               Turn.run(Calendars, scope, [user_message("Delete route 12.")], notify())

      assert result.text == "That isn't available in Calendars."
      assert result.tools == ["unavailable_tool"]
      assert result.activity == ["Tried an unavailable tool"]

      assert [_, tool, _] = result.messages
      assert tool["tool_call_id"] == "call_1"
      assert tool["content"] =~ "Unknown tool: delete_route"

      events = collect_events()
      assert Enum.filter(events, &match?({:tool, _name}, &1)) == [{:tool, "unavailable_tool"}]
      assert {:activity, "Tried an unavailable tool"} in events
    end

    test "returns an undeclared argument as a tool error and never calls the pack", %{
      scope: scope
    } do
      set_echo_pack_pid(self())

      arguments = Jason.encode!(%{"text" => "hello", "organization_id" => scope.organization_id})
      expect_reply(calls_reply([{"call_1", "echo", arguments}], 0.0001))
      expect_reply(text_reply("Echoed hello.", 0.0001))

      assert {:ok, result} = Turn.run(EchoPack, scope, [user_message("Echo hello.")], notify())

      assert [_, tool, _] = result.messages

      assert Jason.decode!(tool["content"]) == %{
               "error" => "Unexpected argument: organization_id"
             }

      assert result.tools == ["echo"]
      refute_received {:echo_pack_called, _name}
    end

    test "stops with forbidden when the membership is deactivated before the next tool call", %{
      scope: scope,
      membership: membership
    } do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))

      Req.Test.expect(@owner, 1, fn conn ->
        deactivate_membership_fixture(membership)

        respond(
          conn,
          calls_reply([{"call_2", "prepare_date_change", @prepare_arguments}], 0.0002)
        )
      end)

      assert {:error, {:context, :forbidden}, progress} =
               Turn.run(Calendars, scope, [user_message("Prepare the date change.")], notify())

      assert progress.activity == ["Looked up calendars"]
      assert progress.tools == ["list_calendars"]
      assert_in_delta progress.cost, 0.0003, 1.0e-12
      refute Map.has_key?(progress, :prepared)
    end

    test "does not turn a pack exception into a tool message", %{scope: scope} do
      set_echo_pack_pid(self())
      expect_reply(calls_reply([{"call_1", "echo", ~s|{"text":"raise"}|}], 0.0001))

      assert_raise RuntimeError, "echo pack was asked to raise", fn ->
        Turn.run(EchoPack, scope, [user_message("Echo raise.")], notify())
      end

      assert_received {:echo_pack_called, "echo"}
      assert_received {:notify, {:tool, "echo"}}
      refute_received {:notify, {:activity, _label}}
    end

    test "ends with :step_limit after exactly sixteen model calls", %{scope: scope} do
      Req.Test.expect(@owner, 16, fn conn ->
        respond(conn, calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))
      end)

      assert {:error, :step_limit, progress} =
               Turn.run(Calendars, scope, [user_message("Keep looking.")], notify())

      assert length(collect_requests()) == 16
      assert progress.tools == List.duplicate("list_calendars", 16)
      assert progress.activity == List.duplicate("Looked up calendars", 16)
      assert_in_delta progress.cost, 0.0016, 1.0e-12
      assert progress.cost_complete
    end

    test "returns a model error with the tools, activity and known cost observed so far", %{
      scope: scope
    } do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))
      expect_response(429, %{"error" => %{"message" => "slow down"}})

      assert {:error, :rate_limited, progress} =
               Turn.run(Calendars, scope, [user_message("Which calendars run Monday?")], notify())

      assert progress.activity == ["Looked up calendars"]
      assert progress.tools == ["list_calendars"]
      assert_in_delta progress.cost, 0.0001, 1.0e-12
      refute progress.cost_complete
      refute Map.has_key?(progress, :prepared)
    end

    test "returns :context_limit without a request when the history exceeds the envelope", %{
      scope: scope
    } do
      oversized = [user_message(String.duplicate("x", 131_072))]

      assert {:error, :context_limit, progress} = Turn.run(Calendars, scope, oversized, notify())

      assert progress.tools == []
      assert progress.activity == []
      refute progress.cost_complete
      refute_received {:model_request, _body}
    end

    test "notifies each tool name, activity label and usage once, in order", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))
      expect_reply(calls_reply([{"call_2", "prepare_date_change", @prepare_arguments}], 0.0002))
      expect_reply(text_reply(@final_text, 0.0003))

      assert {:ok, _result} =
               Turn.run(Calendars, scope, [user_message("Prepare the date change.")], notify())

      assert collect_events() == [
               {:usage, @model, 0.0001},
               {:tool, "list_calendars"},
               {:activity, "Looked up calendars"},
               {:usage, @model, 0.0002},
               {:tool, "prepare_date_change"},
               {:activity, "Prepared a date change"},
               {:usage, @model, 0.0003}
             ]
    end

    test "sends no provider request when access was revoked before a new turn", %{
      scope: scope,
      membership: membership
    } do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))
      expect_reply(text_reply("Two calendars run weekdays.", 0.0001))

      assert {:ok, first} =
               Turn.run(Calendars, scope, [user_message("Which calendars run Monday?")], notify())

      assert length(collect_requests()) == 2

      deactivate_membership_fixture(membership)
      Req.Test.stub(@owner, fn conn -> respond(conn, text_reply("A second answer.")) end)

      history =
        [user_message("Which calendars run Monday?")] ++
          first.messages ++ [user_message("And Tuesday?")]

      assert {:error, {:context, :forbidden}, progress} =
               Turn.run(Calendars, scope, history, notify())

      assert progress.activity == []
      assert progress.tools == []
      assert progress.cost == 0
      assert progress.cost_complete
      refute_received {:model_request, _body}
    end

    test "sends no request and transmits no stored tool result when access is revoked after a read",
         %{scope: scope, membership: membership} do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], 0.0001))
      Req.Test.stub(@owner, fn conn -> respond(conn, text_reply("A second answer.")) end)

      notify = fn event ->
        if event == {:activity, "Looked up calendars"} do
          deactivate_membership_fixture(membership)
        end

        send(self(), {:notify, event})
      end

      assert {:error, {:context, :forbidden}, progress} =
               Turn.run(Calendars, scope, [user_message("Which calendars run Monday?")], notify)

      assert progress.activity == ["Looked up calendars"]
      assert progress.tools == ["list_calendars"]
      assert length(collect_requests()) == 1
      refute_received {:model_request, _body}
    end

    test "discards the prepared change on an incomplete answer and keeps cost and tool names", %{
      scope: scope
    } do
      expect_reply(calls_reply([{"call_1", "prepare_date_change", @prepare_arguments}], 0.0002))
      expect_reply(reply("length", %{"content" => "half"}, 0.5))

      assert {:error, :incomplete_response, progress} =
               Turn.run(Calendars, scope, [user_message("Prepare the date change.")], notify())

      assert progress.tools == ["prepare_date_change"]
      assert progress.activity == ["Prepared a date change"]
      assert_in_delta progress.cost, 0.0002, 1.0e-12
      refute progress.cost_complete
      refute Map.has_key?(progress, :prepared)
    end

    test "marks cost incomplete when a completed response omits usage", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "list_calendars", "{}"}], nil))
      expect_reply(text_reply("Two calendars run weekdays.", 0.0003))

      assert {:ok, result} =
               Turn.run(Calendars, scope, [user_message("Which calendars run Monday?")], notify())

      assert_in_delta result.cost, 0.0003, 1.0e-12
      refute result.cost_complete
    end
  end

  describe "server evidence over the turn" do
    test "carries the Calendar pack's evidence beside the model prose", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "get_calendar", @get_calendar_arguments}], 0.0001))
      expect_reply(text_reply("Three dates run service.", 0.0002))

      assert {:ok, result} =
               Turn.run(
                 Calendars,
                 scope,
                 [user_message("Does School weekdays run next week?")],
                 notify()
               )

      assert [evidence] = result.evidence
      assert evidence.kind == "calendar_dates"
      assert evidence.title == "School weekdays"
      # 2026-10-05 and 2026-10-06 are Monday and Tuesday, and the seeded
      # School weekdays calendar runs both.
      assert evidence.total == 2
      assert evidence.total_label == "dates run"
      assert evidence.completeness == :complete
      assert is_nil(evidence.source_revision)
      assert evidence.source_ref == "gtfs_calendars"
      assert evidence.scope.organization_id == scope.organization_id
      assert evidence.scope.gtfs_version_id == scope.gtfs_version_id

      assert evidence.resources == [
               %{kind: "calendar", id: "SCHOOL_WD", label: "School weekdays"}
             ]

      assert %{label: "Dates evaluated", value: "2"} in evidence.facts
      assert %{label: "Window", value: "2026-10-05 to 2026-10-06"} in evidence.facts

      # The model's sentence contradicts the server count and stays plain text.
      assert result.text == "Three dates run service."
    end

    test "sends the evidence to no model message", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "get_calendar", @get_calendar_arguments}], 0.0001))
      expect_reply(text_reply("Two dates run service.", 0.0002))

      assert {:ok, result} =
               Turn.run(
                 Calendars,
                 scope,
                 [user_message("Does School weekdays run next week?")],
                 notify()
               )

      assert result.messages |> Enum.map(& &1["role"]) == ["assistant", "tool", "assistant"]
      refute result.messages |> Enum.any?(&(Jason.encode!(&1) =~ "gtfs_calendars"))

      [_, tool, _] = result.messages
      assert Jason.decode!(tool["content"])["service_id"] == "SCHOOL_WD"
    end

    test "keeps no evidence when a turn fails after the tool answered", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "get_calendar", @get_calendar_arguments}], 0.0001))
      expect_reply(reply("length", %{"content" => "half"}, 0.5))

      assert {:error, :incomplete_response, progress} =
               Turn.run(
                 Calendars,
                 scope,
                 [user_message("Does School weekdays run next week?")],
                 notify()
               )

      assert progress.tools == ["get_calendar"]
      refute Map.has_key?(progress, :evidence)
    end
  end

  describe "run/4 with the echo pack" do
    test "runs two successive turns over the same loop", %{scope: scope} do
      expect_reply(calls_reply([{"call_1", "echo", ~s|{"text":"hello"}|}], 0.0001))
      expect_reply(text_reply("Echoed hello.", 0.0001))

      assert {:ok, first} = Turn.run(EchoPack, scope, [user_message("Echo hello.")], notify())
      assert first.tools == ["echo"]
      assert first.activity == ["Echoed text"]

      assert Jason.decode!(tool_content(first.messages, "call_1")) ==
               %{"text" => "hello", "organization_id" => scope.organization_id}

      assert length(collect_requests()) == 2

      history =
        [user_message("Echo hello.")] ++ first.messages ++ [user_message("Echo again.")]

      expect_reply(calls_reply([{"call_2", "echo", ~s|{"text":"again"}|}], 0.0001))
      expect_reply(text_reply("Echoed again.", 0.0001))

      assert {:ok, second} = Turn.run(EchoPack, scope, history, notify())
      assert second.tools == ["echo"]
      assert second.text == "Echoed again."

      [request, _second_request] = collect_requests()

      assert Enum.count(request["messages"], fn message ->
               message["role"] == "user" and message["content"] == "Echo hello."
             end) == 1

      assert Enum.count(request["messages"], &(&1["role"] == "assistant")) == 2
      assert Enum.count(request["messages"], &(&1["role"] == "tool")) == 1
    end
  end

  defp notify, do: fn event -> send(self(), {:notify, event}) end

  defp user_message(content), do: %{"role" => "user", "content" => content}

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

  defp expect_reply(payload) do
    Req.Test.expect(@owner, 1, fn conn -> respond(conn, payload) end)
  end

  defp expect_response(status, payload) do
    Req.Test.expect(@owner, 1, fn conn -> respond(conn, payload, status) end)
  end

  defp respond(conn, payload, status \\ 200) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(self(), {:model_request, Jason.decode!(body)})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp collect_requests, do: collect_messages(:model_request)

  defp collect_events do
    receive do
      {:notify, event} -> [event | collect_events()]
    after
      0 -> []
    end
  end

  defp collect_messages(tag) do
    receive do
      {^tag, payload} -> [payload | collect_messages(tag)]
    after
      0 -> []
    end
  end

  defp tool_content(messages, id) do
    Enum.find_value(messages, fn
      %{"role" => "tool", "tool_call_id" => ^id, "content" => content} -> content
      _message -> nil
    end)
  end

  defp tool_ids(message) do
    message
    |> Map.fetch!("content")
    |> Jason.decode!()
    |> Map.fetch!("calendars")
    |> Enum.map(& &1["service_id"])
  end

  defp set_echo_pack_pid(pid) do
    previous_pid = Application.get_env(:gtfs_planner, :echo_pack_test_pid)
    Application.put_env(:gtfs_planner, :echo_pack_test_pid, pid)

    on_exit(fn ->
      if is_nil(previous_pid) do
        Application.delete_env(:gtfs_planner, :echo_pack_test_pid)
      else
        Application.put_env(:gtfs_planner, :echo_pack_test_pid, previous_pid)
      end
    end)
  end

  defp add_calendar(organization, version, service_id, name) do
    calendar_fixture(
      organization.id,
      version.id,
      @weekdays |> Map.put(:service_id, service_id)
    )

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end
end
