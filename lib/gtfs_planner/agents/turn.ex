defmodule GtfsPlanner.Agents.Turn do
  @moduledoc """
  One bounded, authorized tool-use turn over a capability pack.

  The loop alternates model calls and tool calls: `Model.complete/2`, the pack's
  tool calls through `Dispatch.call/4`, one tool result message per call, and the
  next model call, at most sixteen model calls per turn. The scope is re-authorized
  before every provider request — membership, the server-owned resource context and
  the pack's own precondition — so access withdrawn mid-turn, a route or version
  this conversation no longer resolves, or a pack whose precondition is gone sends
  no further request, runs no further tool and delivers no result (INV-1). Only the
  pack the session chose is named here, and only through its behaviour: this module
  holds no domain code (INV-1).

  Messages use OpenAI's chat format with string keys. The system message is
  rebuilt from `Prompt.system/2` for every request and never stored in history.
  Tool call arguments pass through unchanged; `Dispatch` validates them and owns
  every tool error message, so exception text and raw arguments never reach the
  model. A tool may also return server evidence: it is collected on the turn and
  returned to the caller, never mixed into the model's tool message, so the panel
  can render the server answer the model's prose may contradict (INV-2). A raised pack exception is not rescued: it propagates to the caller,
  where the session's task boundary owns sanitizing and reporting it. The
  caller's `notify` receives `{:usage, model, cost}`, `{:tool, name}`
  and `{:activity, label}` events for partial outcome logging; tool names are
  declared names or the fixed `"unavailable_tool"` label, never arbitrary model
  output.

  A failed turn returns the progress it observed (`activity`, `tools`, `cost`,
  `cost_complete`) and keeps no prepared change, so a caller can log known cost
  without trusting a partial proposal. `cost_complete` is false whenever a model
  response omitted usage, and a failed model request marks the turn's billing
  incomplete because its usage never arrived.
  """

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Model
  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Prompt
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.UsageBudget

  # Bounds are code constants, not configuration (AC-30, FH-9). Every model call
  # is one provider attempt because `Model` disables automatic POST retries.
  @max_model_calls 16
  @unavailable_tool "unavailable_tool"
  @unavailable_tool_activity "Tried an unavailable tool"

  @typedoc "Progress the caller observes while a turn runs."
  @type event ::
          {:activity, String.t()}
          | {:tool, String.t()}
          | {:usage, String.t() | nil, number() | nil}

  @typedoc "A finished turn: its text, generated messages and observed outcome."
  @type result :: %{
          text: String.t(),
          messages: [map()],
          activity: [String.t()],
          prepared: Pack.prepared() | nil,
          evidence: [Pack.evidence()],
          tools: [String.t()],
          cost: number(),
          cost_complete: boolean(),
          response_models: [String.t()]
        }

  @typedoc "What a failed turn observed before it stopped."
  @type progress :: %{
          activity: [String.t()],
          tools: [String.t()],
          cost: number(),
          cost_complete: boolean()
        }

  @doc """
  Runs one turn for `pack` in `scope` over `messages`.

  `messages` is the conversation history in OpenAI chat format, ending with the
  new user message. `notify` is called once per event. Returns the finished turn
  or the error reason with the progress observed so far; a failed turn never
  carries a prepared change.
  """
  @spec run(module(), Scope.t(), [map()], (event() -> any())) ::
          {:ok, result()} | {:error, atom() | tuple(), progress()}
  def run(pack, %Scope{} = scope, messages, notify)
      when is_list(messages) and is_function(notify, 1) do
    loop(pack, scope, messages, new_acc(), 0, notify)
  end

  defp loop(pack, scope, history, acc, calls_made, notify) do
    if calls_made == @max_model_calls do
      {:error, :step_limit, progress(acc)}
    else
      authorize_and_request(pack, scope, history, acc, calls_made, notify)
    end
  end

  defp authorize_and_request(pack, scope, history, acc, calls_made, notify) do
    case authorized_context(pack, scope) do
      :ok ->
        consume_and_request(pack, scope, history, acc, calls_made, notify)

      {:error, reason} ->
        # Tagged so a context refusal stays distinct from a provider failure
        # that carries the same reason atom and settles only one turn.
        {:error, {:context, reason}, progress(acc)}
    end
  end

  defp consume_and_request(pack, scope, history, acc, calls_made, notify) do
    case UsageBudget.consume(scope.organization_id, scope.user_id) do
      :ok -> request(pack, scope, history, acc, calls_made, notify)
      {:error, :allowance_exhausted} -> {:error, :allowance_exhausted, progress(acc)}
    end
  end

  # The provider boundary and the pack boundary are one check, in the session's
  # order: membership, then the server-owned resource context, then the pack's own
  # precondition.
  defp authorized_context(pack, scope) do
    with :ok <- Scope.authorized_context(scope) do
      Pack.authorize_context(pack, scope)
    end
  end

  defp request(pack, scope, history, acc, calls_made, notify) do
    case Model.complete([Prompt.system(pack, scope) | history], pack.tools()) do
      {:ok, reply} ->
        acc = record_reply(acc, reply)
        notify.({:usage, reply.model, reply.cost})
        handle_reply(pack, scope, history, acc, calls_made, reply, notify)

      {:error, reason} ->
        # The failed attempt returned no usage, so its billing is unknown.
        {:error, reason, %{progress(acc) | cost_complete: false}}
    end
  end

  defp handle_reply(_pack, _scope, _history, acc, _calls_made, %{tool_calls: []} = reply, _notify) do
    acc = %{acc | appended: acc.appended ++ [assistant_message(reply.content)]}

    {:ok,
     %{
       text: reply.content || "",
       messages: acc.appended,
       activity: acc.activity,
       prepared: acc.prepared,
       evidence: acc.evidence,
       tools: acc.tools,
       cost: acc.cost,
       cost_complete: acc.cost_complete,
       response_models: acc.response_models
     }}
  end

  defp handle_reply(pack, scope, history, acc, calls_made, reply, notify) do
    assistant = assistant_tool_call_message(reply)
    acc = %{acc | appended: acc.appended ++ [assistant]}

    case run_tool_calls(pack, scope, reply.tool_calls, acc, notify) do
      {:forbidden, acc, _messages} ->
        {:error, {:context, :forbidden}, progress(acc)}

      {:unavailable, acc, _messages} ->
        {:error, {:context, :unavailable}, progress(acc)}

      {:ok, acc, tool_messages} ->
        loop(pack, scope, history ++ [assistant | tool_messages], acc, calls_made + 1, notify)
    end
  end

  # Each call in one reply runs in order. A forbidden call halts the whole turn
  # before the next request; every other outcome appends one tool message, and a
  # bounded tool error is a message the model may correct, not a failed turn.
  defp run_tool_calls(pack, scope, calls, acc, notify) do
    Enum.reduce_while(calls, {:ok, acc, []}, fn call, {:ok, acc, messages} ->
      tool = find_tool(pack, call.name)
      name = if tool, do: tool.name, else: @unavailable_tool
      label = if tool, do: tool.activity, else: @unavailable_tool_activity

      notify.({:tool, name})

      case Dispatch.call(pack, scope, call.name, call.arguments) do
        {:error, reason} when reason in [:forbidden, :unavailable] ->
          {:halt, {reason, acc, messages}}

        result ->
          {payload, prepared, evidence} = payload(result)
          message = tool_message(call.id, payload)
          notify.({:activity, label})

          acc = %{
            acc
            | appended: acc.appended ++ [message],
              activity: acc.activity ++ [label],
              tools: acc.tools ++ [name],
              prepared: prepared || acc.prepared,
              evidence: acc.evidence ++ evidence
          }

          {:cont, {:ok, acc, messages ++ [message]}}
      end
    end)
  end

  # Server evidence rides beside the tool result and never inside the model's
  # message: the panel renders it as the answer while the model keeps reading
  # only the result payload (INV-2).
  defp payload({:ok, result}), do: {result, nil, []}
  defp payload({:ok, result, evidence}), do: {result, nil, [evidence]}
  defp payload({:prepared, prepared, result}), do: {result, prepared, []}
  defp payload({:prepared, prepared, result, evidence}), do: {result, prepared, [evidence]}
  defp payload({:tool_error, message}), do: {%{"error" => message}, nil, []}

  defp find_tool(pack, name), do: Enum.find(pack.tools(), &(&1.name == name))

  defp assistant_message(content), do: %{"role" => "assistant", "content" => content}

  defp assistant_tool_call_message(reply) do
    %{
      "role" => "assistant",
      "content" => reply.content,
      "tool_calls" => Enum.map(reply.tool_calls, &tool_call_message/1)
    }
  end

  defp tool_call_message(call) do
    %{
      "id" => call.id,
      "type" => "function",
      "function" => %{"name" => call.name, "arguments" => call.arguments}
    }
  end

  defp tool_message(id, payload) do
    %{"role" => "tool", "tool_call_id" => id, "content" => Jason.encode!(payload)}
  end

  defp record_reply(acc, reply) do
    %{
      acc
      | cost: acc.cost + (reply.cost || 0),
        cost_complete: acc.cost_complete and is_number(reply.cost),
        response_models: response_models(acc.response_models, reply.model)
    }
  end

  defp response_models(models, nil), do: models
  defp response_models(models, model), do: models ++ [model]

  defp progress(acc) do
    %{
      activity: acc.activity,
      tools: acc.tools,
      cost: acc.cost,
      cost_complete: acc.cost_complete
    }
  end

  defp new_acc do
    %{
      appended: [],
      activity: [],
      tools: [],
      prepared: nil,
      evidence: [],
      cost: 0,
      cost_complete: true,
      response_models: []
    }
  end
end
