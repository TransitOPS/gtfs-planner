defmodule GtfsPlanner.Agents.ModelTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Agents.Model

  @owner GtfsPlanner.Agents.Model
  @test_key "test-openrouter-key"
  @messages [%{"role" => "user", "content" => "Which calendars run next Monday?"}]

  @parameters %{
    "type" => "object",
    "properties" => %{"query" => %{"type" => "string", "maxLength" => 100}},
    "required" => [],
    "additionalProperties" => false
  }

  @tools [
    %{
      name: "list_calendars",
      description: "List calendars in this service version.",
      activity: "Looked up calendars",
      parameters: @parameters
    }
  ]

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_config = Application.get_env(:gtfs_planner, Model)

    on_exit(fn ->
      if is_nil(previous_config) do
        Application.delete_env(:gtfs_planner, Model)
      else
        Application.put_env(:gtfs_planner, Model, previous_config)
      end
    end)

    :ok
  end

  describe "complete/2 request" do
    test "posts the configured model, messages, tools, token budget and privacy preferences to chat completions" do
      Req.Test.expect(@owner, 1, fn conn -> respond(conn, 200, content_body("Hello")) end)

      assert {:ok, %{content: "Hello", tool_calls: [], finish_reason: "stop"}} =
               Model.complete(@messages, @tools)

      assert_received {:model_request, request}
      assert request.method == "POST"
      assert request.scheme == :https
      assert request.host == "openrouter.ai"
      assert request.path == "/api/v1/chat/completions"
      assert request.headers["authorization"] == "Bearer #{@test_key}"

      assert request.body == %{
               "model" => "test/model-a",
               "messages" => @messages,
               "tools" => [
                 %{
                   "type" => "function",
                   "function" => %{
                     "name" => "list_calendars",
                     "description" => "List calendars in this service version.",
                     "parameters" => @parameters
                   }
                 }
               ],
               "tool_choice" => "auto",
               "max_tokens" => 8_192,
               "provider" => %{"data_collection" => "deny", "require_parameters" => true},
               "usage" => %{"include" => true}
             }
    end

    test "requests usage accounting so the reply can carry a known cost" do
      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 200, reply_body("stop", %{"content" => "Hello"}, %{"cost" => 0.01}))
      end)

      assert {:ok, %{cost: 0.01}} = Model.complete(@messages, @tools)

      assert_received {:model_request, request}
      assert request.body["usage"] == %{"include" => true}
    end

    test "changing the configured model changes only the model field" do
      Req.Test.expect(@owner, 1, fn conn -> respond(conn, 200, content_body("Hello")) end)
      Req.Test.expect(@owner, 1, fn conn -> respond(conn, 200, content_body("Hello")) end)

      assert {:ok, _reply} = Model.complete(@messages, @tools)

      assert {:ok, _reply} =
               with_model("test/model-b", fn -> Model.complete(@messages, @tools) end)

      assert_received {:model_request, first}
      assert_received {:model_request, second}

      assert first.body["model"] == "test/model-a"
      assert second.body["model"] == "test/model-b"
      assert Map.delete(first.body, "model") == Map.delete(second.body, "model")
    end

    test "transmits the 8,192-token budget and returns a 366-date tool call completely" do
      dates = Date.range(~D[2028-01-01], ~D[2028-12-31]) |> Enum.map(&Date.to_iso8601/1)
      arguments = Jason.encode!(%{"dates" => dates, "stop" => ["SCHOOL_WD"], "run" => []})
      calls = [tool_call_payload("call_366", "prepare_date_change", arguments)]

      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 200, reply_body("tool_calls", %{"content" => nil, "tool_calls" => calls}))
      end)

      assert {:ok, reply} = Model.complete(@messages, @tools)

      assert reply.finish_reason == "tool_calls"

      assert [%{id: "call_366", name: "prepare_date_change", arguments: ^arguments}] =
               reply.tool_calls

      assert length(Jason.decode!(arguments)["dates"]) == 366

      assert_received {:model_request, request}
      assert request.body["max_tokens"] == 8_192
    end
  end

  describe "complete/2 response mapping" do
    test "maps a tool-calls finish reason to a normalized reply with its cost" do
      Req.Test.expect(@owner, 1, fn conn ->
        respond(
          conn,
          200,
          reply_body(
            "tool_calls",
            %{"content" => nil, "tool_calls" => [tool_call_payload()]},
            %{"cost" => 0.0002}
          )
        )
      end)

      assert {:ok, reply} = Model.complete(@messages, @tools)

      assert_received {:model_request, request}
      assert request.body["usage"] == %{"include" => true}

      assert reply == %{
               content: nil,
               tool_calls: [%{id: "call_1", name: "list_calendars", arguments: "{}"}],
               finish_reason: "tool_calls",
               model: "test/model-a",
               cost: 0.0002
             }
    end

    test "maps a stop finish reason with text to a reply with no calls" do
      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 200, reply_body("stop", %{"content" => "Hello"}, %{"cost" => 0}))
      end)

      assert {:ok, reply} = Model.complete(@messages, @tools)

      assert reply == %{
               content: "Hello",
               tool_calls: [],
               finish_reason: "stop",
               model: "test/model-a",
               cost: 0
             }
    end

    test "accepts a reply without a returned model or cost" do
      body = %{
        "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => "Hello"}}]
      }

      Req.Test.expect(@owner, 1, fn conn -> respond(conn, 200, body) end)

      assert {:ok, reply} = Model.complete(@messages, @tools)
      assert reply.model == nil
      assert reply.cost == nil
    end
  end

  describe "complete/2 provider error mapping" do
    test "maps a 200 response carrying an error to :unavailable" do
      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 200, %{"error" => %{"message" => "provider down"}})
      end)

      assert {:error, :unavailable} = Model.complete(@messages, @tools)
    end

    test "maps 429 to :rate_limited" do
      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 429, %{"error" => %{"message" => "slow down"}})
      end)

      assert {:error, :rate_limited} = Model.complete(@messages, @tools)
    end

    test "maps 401 and 402 to {:http_status, status}" do
      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 401, %{"error" => %{"message" => "bad key"}})
      end)

      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 402, %{"error" => %{"message" => "no credit"}})
      end)

      assert {:error, {:http_status, 401}} = Model.complete(@messages, @tools)
      assert {:error, {:http_status, 402}} = Model.complete(@messages, @tools)
    end

    test "does not retry a 503 and maps it to :unavailable" do
      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 503, %{"error" => %{"message" => "overloaded"}})
      end)

      assert {:error, :unavailable} = Model.complete(@messages, @tools)
    end

    test "does not retry a transport error and maps it to :unavailable" do
      Req.Test.expect(@owner, 1, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, :unavailable} = Model.complete(@messages, @tools)
    end

    test "maps a 200 body without choices to :invalid_response" do
      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, 200, %{"model" => "test/model-a", "usage" => %{}})
      end)

      assert {:error, :invalid_response} = Model.complete(@messages, @tools)
    end

    test "maps a 200 body that is not valid JSON to :invalid_response" do
      Req.Test.expect(@owner, 1, fn conn ->
        conn = record_request(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{not json")
      end)

      assert {:error, :invalid_response} = Model.complete(@messages, @tools)
    end
  end

  describe "complete/2 configuration guards" do
    test "returns :missing_api_key and sends no request when the key is nil or blank" do
      Req.Test.stub(@owner, fn conn -> respond(conn, 200, content_body("Hello")) end)

      assert with_key(nil, fn -> Model.complete(@messages, @tools) end) ==
               {:error, :missing_api_key}

      assert with_key("", fn -> Model.complete(@messages, @tools) end) ==
               {:error, :missing_api_key}

      assert with_key("   ", fn -> Model.complete(@messages, @tools) end) ==
               {:error, :missing_api_key}

      refute_received {:model_request, _}
    end

    test "refuses a missing, Sonnet, automatic or fallback model without a request" do
      Req.Test.stub(@owner, fn conn -> respond(conn, 200, content_body("Hello")) end)

      complete = fn -> Model.complete(@messages, @tools) end

      assert with_model(nil, complete) == {:error, :missing_model}
      assert with_model("", complete) == {:error, :missing_model}
      assert with_model("test/Sonnet-cheap", complete) == {:error, :invalid_model}
      assert with_model("openrouter/auto", complete) == {:error, :invalid_model}
      assert with_model("test-model-without-a-provider", complete) == {:error, :invalid_model}
      assert with_model(["test/model-a", "test/model-b"], complete) == {:error, :invalid_model}

      refute_received {:model_request, _}
    end

    test "sends no request when the serialized envelope exceeds 131,072 bytes" do
      Req.Test.stub(@owner, fn conn -> respond(conn, 200, content_body("Hello")) end)

      oversized = [%{"role" => "user", "content" => String.duplicate("x", 131_072)}]

      assert {:error, :context_limit} = Model.complete(oversized, @tools)
      refute_received {:model_request, _}
    end
  end

  describe "complete/2 response validation" do
    test "rejects invalid content shapes" do
      assert_error(reply_body("stop", %{"content" => 123}), :invalid_response)
      assert_error(reply_body("stop", %{"content" => nil}), :invalid_response)
      assert_error(reply_body("stop", %{"content" => ["part"]}), :invalid_response)
    end

    test "rejects malformed or duplicate tool calls" do
      duplicate_ids = %{
        "content" => nil,
        "tool_calls" => [tool_call_payload("call_1"), tool_call_payload("call_1")]
      }

      blank_id = %{"content" => nil, "tool_calls" => [tool_call_payload("")]}
      blank_name = %{"content" => nil, "tool_calls" => [tool_call_payload("call_1", "")]}

      map_arguments = %{
        "content" => nil,
        "tool_calls" => [tool_call_payload("call_1", "list_calendars", %{"query" => "a"})]
      }

      no_function = %{"content" => nil, "tool_calls" => [%{"id" => "call_1"}]}
      empty_calls = %{"content" => nil, "tool_calls" => []}
      calls_with_stop = %{"content" => "Done", "tool_calls" => [tool_call_payload()]}

      assert_error(reply_body("tool_calls", duplicate_ids), :invalid_response)
      assert_error(reply_body("tool_calls", blank_id), :invalid_response)
      assert_error(reply_body("tool_calls", blank_name), :invalid_response)
      assert_error(reply_body("tool_calls", map_arguments), :invalid_response)
      assert_error(reply_body("tool_calls", no_function), :invalid_response)
      assert_error(reply_body("tool_calls", empty_calls), :invalid_response)
      assert_error(reply_body("stop", calls_with_stop), :invalid_response)
    end

    test "rejects invalid cost shapes" do
      assert_error(
        reply_body("stop", %{"content" => "Hello"}, %{"cost" => -0.1}),
        :invalid_response
      )

      assert_error(
        reply_body("stop", %{"content" => "Hello"}, %{"cost" => "0.1"}),
        :invalid_response
      )

      assert_error(reply_body("stop", %{"content" => "Hello"}, "free"), :invalid_response)
    end

    test "rejects blank final text and unknown finish reasons" do
      assert_error(reply_body("stop", %{"content" => ""}), :invalid_response)
      assert_error(reply_body("stop", %{"content" => "   "}), :invalid_response)
      assert_error(reply_body("surprise", %{"content" => "Hello"}), :invalid_response)
      assert_error(reply_body(nil, %{"content" => "Hello"}), :invalid_response)
    end

    test "maps truncated or filtered answers to :incomplete_response without tool calls" do
      truncated =
        reply_body("length", %{"content" => "half", "tool_calls" => [tool_call_payload()]})

      filtered =
        reply_body("content_filter", %{"content" => nil, "tool_calls" => [tool_call_payload()]})

      assert_error(truncated, :incomplete_response)
      assert_error(filtered, :incomplete_response)
    end
  end

  describe "ordinary test configuration" do
    test "routes requests through the Req.Test plug with dummy credentials despite sentinel environment variables" do
      previous_key = System.get_env("OPENROUTER_API_KEY")
      previous_model = System.get_env("OPENROUTER_MODEL")

      System.put_env("OPENROUTER_API_KEY", "sentinel-live-key")
      System.put_env("OPENROUTER_MODEL", "test/sentinel-model")

      on_exit(fn ->
        restore_env("OPENROUTER_API_KEY", previous_key)
        restore_env("OPENROUTER_MODEL", previous_model)
      end)

      assert Application.get_env(:gtfs_planner, :agents_req_options)[:plug] == {Req.Test, Model}

      Req.Test.expect(@owner, 1, fn conn -> respond(conn, 200, content_body("Hello")) end)

      assert {:ok, %{content: "Hello"}} = Model.complete(@messages, @tools)

      assert_received {:model_request, %{headers: headers, body: body}}
      assert body["model"] == "test/model-a"
      assert headers["authorization"] == "Bearer #{@test_key}"
    end
  end

  defp respond(conn, status, payload) do
    conn = record_request(conn)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp record_request(conn) do
    request = %{
      method: conn.method,
      scheme: conn.scheme,
      host: conn.host,
      path: conn.request_path,
      headers: Map.new(conn.req_headers),
      body: captured_json(conn)
    }

    send(self(), {:model_request, request})

    conn
  end

  defp captured_json(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  defp content_body(text), do: reply_body("stop", %{"content" => text})

  defp reply_body(finish_reason, message, usage \\ %{}) do
    %{
      "model" => "test/model-a",
      "choices" => [%{"finish_reason" => finish_reason, "message" => message}],
      "usage" => usage
    }
  end

  defp tool_call_payload(id \\ "call_1", name \\ "list_calendars", arguments \\ "{}") do
    %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => arguments}}
  end

  defp assert_error(payload, expected) do
    Req.Test.expect(@owner, 1, fn conn -> respond(conn, 200, payload) end)

    assert {:error, ^expected} = Model.complete(@messages, @tools)
  end

  defp with_model(model, fun) do
    config = Application.fetch_env!(:gtfs_planner, Model)
    Application.put_env(:gtfs_planner, Model, Keyword.put(config, :model, model))

    try do
      fun.()
    after
      Application.put_env(:gtfs_planner, Model, config)
    end
  end

  defp with_key(key, fun) do
    previous = Application.get_env(:gtfs_planner, :openrouter_api_key)
    Application.put_env(:gtfs_planner, :openrouter_api_key, key)

    try do
      fun.()
    after
      restore_key(previous)
    end
  end

  defp restore_key(nil), do: Application.delete_env(:gtfs_planner, :openrouter_api_key)
  defp restore_key(key), do: Application.put_env(:gtfs_planner, :openrouter_api_key, key)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
