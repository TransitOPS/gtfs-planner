defmodule GtfsPlanner.Agents.PackTurn do
  @moduledoc """
  Drives a helper conversation through the shipped composition for a pack test:
  `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> pack, with only the
  OpenRouter HTTP boundary (`GtfsPlanner.Agents.Model`'s `Req.Test` plug) doubled.

  A test module that uses it is `async: false`, calls `setup_conversations/0` from
  its `setup` and scripts each provider response with `expect_reply/1`. The tool
  message the turn sends back to the provider is the pack's own decoded result, so
  an assertion reads what the model read (`tool_result/0`) beside the evidence the
  panel will render (`entry.evidence`).
  """

  import ExUnit.Assertions

  alias GtfsPlanner.AccountsFixtures
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @doc """
  Shares the `Req.Test` plug and the SQL sandbox with the turn task, makes sure a
  turn supervisor runs, and terminates the sessions the test starts.
  """
  def setup_conversations do
    Req.Test.set_req_test_to_shared()

    if is_nil(Process.whereis(@turn_supervisor)) do
      ExUnit.Callbacks.start_supervised!(
        {Task.Supervisor, name: @turn_supervisor, max_children: 8}
      )
    end

    before = session_pids()

    ExUnit.Callbacks.on_exit(fn ->
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

  @doc "A scope for a new editor of the organization, bound to the whole version like a Fares page."
  def version_scope(organization, version, pack_id) do
    user = AccountsFixtures.user_fixture()
    AccountsFixtures.organization_membership_fixture(user, organization)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: pack_id,
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }
  end

  @doc "Opens the conversation for `scope`, sends `text` and returns the settled entry."
  def run_turn(scope, text) do
    assert {:ok, pid, _snapshot} = Agents.open(scope)
    assert :ok = Agents.send_message(pid, text)
    {pid, await_settled(pid)}
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working, do: await_settled(pid), else: entry
  end

  @doc """
  The decoded result of the last tool the turn answered, as the provider's next
  request carried it. Earlier requests are drained until one holds a tool message.
  """
  def tool_result do
    assert_receive {:model_request, request}, 5_000

    request["messages"]
    |> List.wrap()
    |> Enum.filter(&(&1["role"] == "tool"))
    |> case do
      [] -> tool_result()
      messages -> messages |> List.last() |> Map.fetch!("content") |> Jason.decode!()
    end
  end

  @doc "Queues one scripted provider response and forwards each request to the test."
  def expect_reply(payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

  @doc "A provider response that finishes the turn with `content`."
  def text_reply(content) do
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

  @doc "A provider response that calls tools: `{call_id, tool_name, arguments_json}` tuples."
  def tool_calls_reply(calls) do
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
