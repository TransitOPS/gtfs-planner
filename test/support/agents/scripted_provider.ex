defmodule GtfsPlanner.Agents.ScriptedProvider do
  @moduledoc """
  Scripted OpenRouter replies for helper tests that drive a real page.

  The only boundary a helper test replaces is the provider's HTTP call, through
  the `Req.Test` owner `GtfsPlanner.Agents.Model` the test environment routes the
  client through. A test using these helpers sets
  `Req.Test.set_req_test_to_shared/0`, because the page, the session and the turn
  task are separate processes.
  """

  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @doc "Expects one provider request and answers it with `payload`."
  def expect_reply(payload) do
    Req.Test.expect(@owner, 1, fn conn -> respond(conn, payload) end)
  end

  @doc "Scripts one tool-calling turn: a tool call, then the closing text."
  def expect_tool_turn(name, arguments, final_text) do
    expect_reply(tool_calls_reply([{"call_1", name, arguments}]))
    expect_reply(text_reply(final_text))
  end

  @doc "Answers every provider request with a server error, as an outage does."
  def stub_outage do
    Req.Test.stub(@owner, fn conn -> Plug.Conn.send_resp(conn, 500, "provider unavailable") end)
  end

  def respond(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  def text_reply(text), do: reply("stop", %{"content" => text})

  def tool_calls_reply(calls) do
    tool_calls =
      Enum.map(calls, fn {id, name, arguments} ->
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => arguments}
        }
      end)

    reply("tool_calls", %{"content" => nil, "tool_calls" => tool_calls})
  end

  defp reply(finish_reason, message) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => finish_reason, "message" => message}],
      "usage" => %{"cost" => 0.0}
    }
  end

  @doc """
  Terminates every session a test opened, once the test ends.

  Sessions are started under the application's own supervisor and outlive the
  test's sockets.
  """
  def track_sessions do
    before = session_pids()

    ExUnit.Callbacks.on_exit(fn ->
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
end
