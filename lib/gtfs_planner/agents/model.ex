defmodule GtfsPlanner.Agents.Model do
  @moduledoc """
  Minimal OpenRouter chat-completions client for one non-streaming model call.

  Configuration is read on every call: `:model` and `:base_url` from this
  module's application config, the API key from `:openrouter_api_key`, and
  additional Req options from `:agents_req_options` (the test plug). A missing
  or disallowed configuration fails before any request. Automatic POST retries
  are disabled, so one `Req.post/1` is exactly one provider attempt and
  authorization and attempt accounting stay at the turn boundary.

  A successful response is validated against OpenRouter's documented
  chat-completions shape. Truncated, filtered, malformed or empty answers become
  errors, never a partial reply with tool calls, so a caller can never dispatch
  a call from an answer the provider did not complete.
  """

  alias GtfsPlanner.Agents.Pack

  @config_app :gtfs_planner
  @req_options_key :agents_req_options

  # The whole serialized request envelope (system prompt, history and tools)
  # must fit this ceiling. Bounds are code constants, not configuration.
  @request_envelope_limit 131_072
  @max_tokens 8_192
  @receive_timeout 60_000

  # OpenRouter then routes only to providers that do not collect data and that
  # support the declared tools.
  @provider %{"data_collection" => "deny", "require_parameters" => true}

  @incomplete_reasons ["length", "content_filter"]
  @explicit_model_format ~r{^[^/\s]+/[^/\s]+$}

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: String.t()}

  @type reply :: %{
          content: String.t() | nil,
          tool_calls: [tool_call()],
          finish_reason: String.t(),
          model: String.t() | nil,
          cost: number() | nil
        }

  @type error ::
          :missing_api_key
          | :missing_model
          | :invalid_model
          | :rate_limited
          | :unavailable
          | :invalid_response
          | :incomplete_response
          | :context_limit
          | {:http_status, pos_integer()}

  @doc """
  Runs one non-streaming chat-completions call for `messages` and `tools`.

  Returns the validated reply or a mapped provider error. No request is sent
  when the key or model configuration is missing or disallowed, or when the
  serialized request exceeds 131,072 bytes.
  """
  @spec complete([map()], [Pack.tool()]) :: {:ok, reply()} | {:error, error()}
  def complete(messages, tools) when is_list(messages) and is_list(tools) do
    with {:ok, key} <- api_key(),
         {:ok, model} <- configured_model(),
         {:ok, body} <- request_body(model, messages, tools) do
      post(key, body)
    end
  end

  @doc """
  Validates one configured OpenRouter model ID.

  `:ok` means an explicit `provider/model` string that is not
  `openrouter/auto` and does not name a Sonnet model; there is no production
  default and no fallback list. A blank value is `:missing_model`; anything
  else is `:invalid_model`.
  """
  @spec validate_model(term()) :: :ok | {:error, :missing_model | :invalid_model}
  def validate_model(nil), do: {:error, :missing_model}

  def validate_model(model) when is_binary(model) do
    case String.trim(model) do
      "" ->
        {:error, :missing_model}

      model ->
        cond do
          String.downcase(model) =~ "sonnet" -> {:error, :invalid_model}
          model == "openrouter/auto" -> {:error, :invalid_model}
          not Regex.match?(@explicit_model_format, model) -> {:error, :invalid_model}
          true -> :ok
        end
    end
  end

  def validate_model(_model), do: {:error, :invalid_model}

  defp api_key do
    case Application.get_env(@config_app, :openrouter_api_key) do
      key when is_binary(key) ->
        case String.trim(key) do
          "" -> {:error, :missing_api_key}
          key -> {:ok, key}
        end

      _other ->
        {:error, :missing_api_key}
    end
  end

  defp configured_model do
    model =
      @config_app
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.get(:model)

    case validate_model(model) do
      :ok -> {:ok, String.trim(model)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_body(model, messages, tools) do
    body = %{
      "model" => model,
      "messages" => messages,
      "tools" => Enum.map(tools, &tool_payload/1),
      "tool_choice" => "auto",
      "max_tokens" => @max_tokens,
      "provider" => @provider,
      # OpenRouter returns `usage.cost` only when the request asks for usage
      # accounting; without this flag every turn would settle at cost nil.
      "usage" => %{"include" => true}
    }

    if byte_size(Jason.encode!(body)) <= @request_envelope_limit do
      {:ok, body}
    else
      {:error, :context_limit}
    end
  end

  defp tool_payload(%{name: name, description: description, parameters: parameters}) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => parameters
      }
    }
  end

  defp post(key, body) do
    options =
      [
        url: base_url() <> "/chat/completions",
        auth: {:bearer, key},
        json: body,
        receive_timeout: @receive_timeout,
        retry: false,
        max_retries: 2
      ] ++ Application.get_env(@config_app, @req_options_key, [])

    case Req.post(options) do
      {:ok, %Req.Response{status: 200, body: %{"error" => _error}}} ->
        {:error, :unavailable}

      {:ok, %Req.Response{status: 200, body: body}} ->
        normalize(body)

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status}} when status in [401, 402, 403] ->
        {:error, {:http_status, status}}

      {:ok, %Req.Response{}} ->
        {:error, :unavailable}

      {:error, %Jason.DecodeError{}} ->
        {:error, :invalid_response}

      {:error, _exception} ->
        {:error, :unavailable}
    end
  end

  defp base_url do
    @config_app
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:base_url)
  end

  defp normalize(%{"choices" => [%{"message" => message} = choice | _]} = body)
       when is_map(message) do
    with {:ok, content} <- content(message),
         {:ok, tool_calls} <- tool_calls(message),
         {:ok, finish_reason} <- finish_reason(choice),
         {:ok, cost} <- cost(body),
         {:ok, model} <- response_model(body) do
      build_reply(finish_reason, content, tool_calls, model, cost)
    end
  end

  defp normalize(_body), do: {:error, :invalid_response}

  defp content(message) do
    case Map.get(message, "content") do
      nil -> {:ok, nil}
      content when is_binary(content) -> {:ok, content}
      _other -> {:error, :invalid_response}
    end
  end

  defp tool_calls(message) do
    case Map.get(message, "tool_calls") do
      nil -> {:ok, []}
      calls when is_list(calls) -> validate_tool_calls(calls)
      _other -> {:error, :invalid_response}
    end
  end

  defp validate_tool_calls(calls) do
    calls
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn call, {:ok, acc, ids} ->
      case tool_call(call) do
        {:ok, %{id: id} = tool_call} -> add_tool_call(tool_call, id, acc, ids)
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed, _ids} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp add_tool_call(tool_call, id, acc, ids) do
    if MapSet.member?(ids, id) do
      {:halt, {:error, :invalid_response}}
    else
      {:cont, {:ok, [tool_call | acc], MapSet.put(ids, id)}}
    end
  end

  defp tool_call(%{
         "id" => id,
         "function" => %{"name" => name, "arguments" => arguments}
       })
       when is_binary(id) and is_binary(name) and is_binary(arguments) do
    if id == "" or name == "" do
      {:error, :invalid_response}
    else
      {:ok, %{id: id, name: name, arguments: arguments}}
    end
  end

  defp tool_call(_call), do: {:error, :invalid_response}

  defp finish_reason(choice) do
    case Map.get(choice, "finish_reason") do
      reason when is_binary(reason) -> {:ok, reason}
      _other -> {:error, :invalid_response}
    end
  end

  defp cost(body) do
    case Map.get(body, "usage") do
      nil ->
        {:ok, nil}

      usage when is_map(usage) ->
        case Map.get(usage, "cost") do
          nil -> {:ok, nil}
          cost when is_number(cost) and cost >= 0 -> {:ok, cost}
          _other -> {:error, :invalid_response}
        end

      _other ->
        {:error, :invalid_response}
    end
  end

  defp response_model(body) do
    case Map.get(body, "model") do
      nil -> {:ok, nil}
      model when is_binary(model) -> {:ok, model}
      _other -> {:error, :invalid_response}
    end
  end

  defp build_reply("tool_calls", content, [_ | _] = tool_calls, model, cost) do
    {:ok,
     %{
       content: content,
       tool_calls: tool_calls,
       finish_reason: "tool_calls",
       model: model,
       cost: cost
     }}
  end

  defp build_reply("stop", content, [], model, cost) when is_binary(content) do
    if String.trim(content) == "" do
      {:error, :invalid_response}
    else
      {:ok, %{content: content, tool_calls: [], finish_reason: "stop", model: model, cost: cost}}
    end
  end

  defp build_reply(reason, _content, _tool_calls, _model, _cost)
       when reason in @incomplete_reasons do
    {:error, :incomplete_response}
  end

  defp build_reply(_reason, _content, _tool_calls, _model, _cost), do: {:error, :invalid_response}
end
