defmodule GtfsPlanner.Agents.Dispatch do
  @moduledoc """
  The authority fence for one tool call.

  Checks run in a fixed order: the name must be declared by the pack, the raw
  arguments must decode to a JSON object of declared keys inside the byte limit,
  the declared schema subset must validate, fresh authorization must pass, and
  only then does the pack run. Scope-bearing arguments such as `organization_id`
  are undeclared for every tool and are rejected before the pack sees them.

  Authorization here is the whole chain: the membership, the server-owned
  resource context and the pack's own precondition, so no tool reads anything for
  a route or version this conversation no longer resolves (INV-1). A refusal is
  `{:error, :unavailable}`, the same single result a foreign resource produces.

  The schema subset is enforced recursively, so a nested object rejects its own
  undeclared keys, nulls, wrong types and over-limit values, and an array checks
  its items' schemas rather than only their types (AC-3). A declared keyword the
  fence does not implement is a pack defect and raises, because a constraint
  silently skipped would be a constraint the model could exceed.

  A pack may return `{:ok, result, evidence}` or `{:prepared, prepared, result,
  evidence}`. The result and its evidence share the one existing tool byte limit
  and an oversized pair is refused whole, never truncated (AC-4, INV-2).

  A pack exception is not rescued: it crashes the calling task, which the session
  owns and reports as a failed turn.
  """

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope

  @max_arguments_bytes 32_768
  @max_result_bytes 32_768
  @oversized_arguments "Arguments are too large."
  @invalid_arguments "Arguments must be a JSON object."
  @oversized_result "Too much data for one result. Narrow the request."

  # The whole declared subset, and nothing else. A pack is code-owned, so a
  # keyword outside this list is a defect to raise about rather than a
  # constraint to silently skip.
  @schema_keywords ~w(
    type
    description
    properties
    required
    additionalProperties
    items
    minItems
    maxItems
    minLength
    maxLength
    minimum
    maximum
  )

  @spec call(module(), Scope.t(), String.t(), String.t() | nil) ::
          {:ok, map()}
          | {:ok, map(), Pack.evidence()}
          | {:prepared, Pack.prepared(), map()}
          | {:prepared, Pack.prepared(), map(), Pack.evidence()}
          | {:tool_error, String.t()}
          | {:error, :forbidden | :unavailable}
  def call(pack, %Scope{} = scope, name, arguments_json) when is_binary(name) do
    with {:ok, tool} <- find_tool(pack, name),
         {:ok, args} <- decode_arguments(arguments_json),
         :ok <- reject_undeclared_keys(tool, args),
         :ok <- validate_declared_types(tool, args),
         :ok <- Scope.authorized_context(scope),
         :ok <- Pack.authorize_context(pack, scope) do
      invoke(pack, name, args, scope)
    end
  end

  defp find_tool(pack, name) do
    case Enum.find(pack.tools(), &(&1.name == name)) do
      nil ->
        {:tool_error, "Unknown tool: " <> name}

      tool ->
        check_supported_keywords!(tool.parameters, tool.name)
        {:ok, tool}
    end
  end

  defp decode_arguments(""), do: {:ok, %{}}
  defp decode_arguments(nil), do: {:ok, %{}}

  defp decode_arguments(arguments_json) when is_binary(arguments_json) do
    if byte_size(arguments_json) > @max_arguments_bytes do
      {:tool_error, @oversized_arguments}
    else
      case Jason.decode(arguments_json) do
        {:ok, args} when is_map(args) -> {:ok, args}
        _other -> {:tool_error, @invalid_arguments}
      end
    end
  end

  defp reject_undeclared_keys(tool, args) do
    declared = properties(tool.parameters) |> Map.keys()

    case args |> Map.keys() |> Kernel.--(declared) |> Enum.sort() do
      [] -> :ok
      [key | _rest] -> {:tool_error, "Unexpected argument: " <> key}
    end
  end

  defp validate_declared_types(tool, args) do
    declared = properties(tool.parameters)

    with :ok <- validate_required(Map.get(tool.parameters, "required", []), args, declared, nil) do
      Enum.reduce_while(declared, :ok, fn {key, schema}, :ok ->
        case Map.fetch(args, key) do
          :error ->
            {:cont, :ok}

          {:ok, value} ->
            case validate_value(value, schema, key) do
              :ok -> {:cont, :ok}
              {:tool_error, _message} = error -> {:halt, error}
            end
        end
      end)
    end
  end

  defp properties(schema), do: Map.get(schema, "properties", %{})

  # `path` names the argument in the bounded message the model reads, so a
  # nested failure is reported at its own depth instead of at the tool's.
  defp validate_value(value, schema, path) do
    check_supported_keywords!(schema, path)

    case {Map.get(schema, "type"), value} do
      {nil, _value} ->
        :ok

      {_type, nil} ->
        {:tool_error, "Argument #{path} must not be null."}

      {"string", value} ->
        validate_string(value, schema, path)

      {"integer", value} ->
        validate_integer(value, schema, path)

      {"boolean", value} ->
        validate_boolean(value, schema, path)

      {"array", value} ->
        validate_array(value, schema, path)

      {"object", value} ->
        validate_object(value, schema, path)

      {type, _value} ->
        raise ArgumentError,
              "unsupported JSON Schema type #{inspect(type)} at #{path} in a pack tool definition"
    end
  end

  defp validate_string(value, schema, path) when is_binary(value),
    do: validate_length(value, schema, path)

  defp validate_string(_value, _schema, path),
    do: {:tool_error, "Argument #{path} must be a string."}

  defp validate_integer(value, schema, path) when is_integer(value),
    do: validate_integer_bounds(value, schema, path)

  defp validate_integer(_value, _schema, path),
    do: {:tool_error, "Argument #{path} must be an integer."}

  defp validate_boolean(value, _schema, _path) when is_boolean(value), do: :ok

  defp validate_boolean(_value, _schema, path),
    do: {:tool_error, "Argument #{path} must be true or false."}

  defp validate_array(value, schema, path) when is_list(value),
    do: validate_array_items(value, schema, path)

  defp validate_array(_value, _schema, path),
    do: {:tool_error, "Argument #{path} must be an array."}

  defp validate_object(value, schema, path) when is_map(value),
    do: validate_object_keys(value, schema, path)

  defp validate_object(_value, _schema, path),
    do: {:tool_error, "Argument #{path} must be an object."}

  # A required key the schema does not declare could never be validated, so the
  # tool definition is wrong and the fence says so instead of trusting it.
  defp validate_required(required, args, declared, path) do
    case Enum.find(required, &(not Map.has_key?(args, &1))) do
      nil -> :ok
      key -> {:tool_error, "Missing required argument: " <> argument_path(path, key)}
    end
    |> reject_undeclared_required(required, declared)
  end

  defp reject_undeclared_required(:ok, required, declared) do
    case Enum.find(required, &(not Map.has_key?(declared, &1))) do
      nil ->
        :ok

      key ->
        raise ArgumentError,
              "required key #{inspect(key)} is not declared in a pack tool definition"
    end
  end

  defp reject_undeclared_required(error, _required, _declared), do: error

  defp argument_path(nil, key), do: key
  defp argument_path(path, key), do: "#{path}.#{key}"

  defp check_supported_keywords!(schema, path) do
    case schema |> Map.keys() |> Enum.reject(&(&1 in @schema_keywords)) do
      [] ->
        :ok

      [keyword | _rest] ->
        raise ArgumentError,
              "unsupported JSON Schema keyword #{keyword} at #{path} in a pack tool definition"
    end
  end

  defp validate_length(value, schema, path) do
    length = String.length(value)
    min_length = Map.get(schema, "minLength")
    max_length = Map.get(schema, "maxLength")

    cond do
      is_integer(min_length) and length < min_length ->
        {:tool_error, "Argument #{path} must be at least #{min_length} characters."}

      is_integer(max_length) and length > max_length ->
        # The cap counts characters, not bytes; the decoded argument is already
        # bounded by the request body size limit.
        {:tool_error, "Argument #{path} must be at most #{max_length} characters."}

      true ->
        :ok
    end
  end

  defp validate_integer_bounds(value, schema, path) do
    minimum = Map.get(schema, "minimum")
    maximum = Map.get(schema, "maximum")

    cond do
      is_integer(minimum) and value < minimum ->
        {:tool_error, "Argument #{path} must be at least #{minimum}."}

      is_integer(maximum) and value > maximum ->
        {:tool_error, "Argument #{path} must be at most #{maximum}."}

      true ->
        :ok
    end
  end

  defp validate_array_items(value, schema, path) do
    with :ok <- validate_item_count(length(value), schema, path) do
      validate_each_item(value, path, Map.get(schema, "items"))
    end
  end

  defp validate_item_count(count, schema, path) do
    min_items = Map.get(schema, "minItems")
    max_items = Map.get(schema, "maxItems")

    cond do
      is_integer(min_items) and count < min_items ->
        {:tool_error, "Argument #{path} must have #{min_items} or more items."}

      is_integer(max_items) and count > max_items ->
        {:tool_error, "Argument #{path} must have #{max_items} or fewer items."}

      true ->
        :ok
    end
  end

  defp validate_each_item(_value, _path, nil), do: :ok

  defp validate_each_item(values, path, items) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case validate_value(value, items, "#{path}[#{index}]") do
        :ok -> {:cont, :ok}
        {:tool_error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp validate_object_keys(value, schema, path) do
    declared = properties(schema)

    if Map.get(schema, "additionalProperties") == true do
      raise ArgumentError,
            "additionalProperties must be false at every level in a pack tool definition"
    end

    with :ok <- validate_required(Map.get(schema, "required", []), value, declared, path) do
      case value |> Map.keys() |> Kernel.--(Map.keys(declared)) |> Enum.sort() |> List.first() do
        nil -> validate_object_values(value, declared, path)
        key -> {:tool_error, "Unexpected argument: " <> argument_path(path, key)}
      end
    end
  end

  # A nested object that opted into extra keys is not a bounded argument, so the
  # fence refuses to invent a rule for it.
  defp validate_object_values(value, declared, path) do
    Enum.reduce_while(declared, :ok, fn {key, schema}, :ok ->
      case Map.fetch(value, key) do
        :error ->
          {:cont, :ok}

        {:ok, nested} ->
          case validate_value(nested, schema, argument_path(path, key)) do
            :ok -> {:cont, :ok}
            {:tool_error, _message} = error -> {:halt, error}
          end
      end
    end)
  end

  defp invoke(pack, name, args, scope) do
    case pack.call(name, args, scope) do
      {:ok, result} ->
        bounded_result({:ok, result}, result)

      {:ok, result, evidence} ->
        bounded_evidence({:ok, result, evidence}, result, evidence)

      {:prepared, prepared, result} ->
        case Map.get(prepared, :evidence) do
          evidence when is_list(evidence) and evidence != [] ->
            prepared_with(prepared, result, evidence)

          _none ->
            bounded_result({:prepared, prepared, result}, result)
        end

      {:prepared, prepared, result, evidence} ->
        bounded_evidence({:prepared, prepared, result, evidence}, result, evidence)

      {:error, message} when is_binary(message) ->
        {:tool_error, message}
    end
  end

  defp bounded_result(tagged_result, result) when is_map(result) do
    if byte_size(Jason.encode!(result)) > @max_result_bytes do
      {:tool_error, @oversized_result}
    else
      tagged_result
    end
  end

  # A prepared result may carry its own evidence. It is lifted into the same
  # transport every other evidence uses, so one turn delivers the panel's cards
  # and the model a tool message that never contains them.
  defp prepared_with(prepared, result, evidence) do
    bounded_evidence(
      {:prepared, Map.delete(prepared, :evidence), result, evidence},
      result,
      evidence
    )
  end

  # The result and the evidence describing it share the one existing tool limit.
  # An oversized pair is refused whole: a truncated evidence payload would leave
  # a plausible card holding fewer rows than the answer it claims to describe.
  defp bounded_evidence(tagged, result, evidence) when is_map(result) and is_map(evidence) do
    bytes = byte_size(Jason.encode!(result)) + byte_size(Jason.encode!(evidence))

    if bytes > @max_result_bytes do
      {:tool_error, @oversized_result}
    else
      tagged
    end
  end

  defp bounded_evidence(_tagged, _result, evidence) do
    raise ArgumentError, "tool evidence must be a map, got: #{inspect(evidence)}"
  end
end
