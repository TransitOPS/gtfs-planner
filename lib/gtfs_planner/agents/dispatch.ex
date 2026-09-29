defmodule GtfsPlanner.Agents.Dispatch do
  @moduledoc """
  The authority fence for one tool call.

  Checks run in a fixed order: the name must be declared by the pack, the raw
  arguments must decode to a JSON object of declared keys inside the byte limit,
  the declared schema subset must validate, fresh authorization must pass, and
  only then does the pack run. Scope-bearing arguments such as `organization_id`
  are undeclared for every tool and are rejected before the pack sees them.

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

  @spec call(module(), Scope.t(), String.t(), String.t() | nil) ::
          {:ok, map()}
          | {:prepared, Pack.prepared(), map()}
          | {:tool_error, String.t()}
          | {:error, :forbidden}
  def call(pack, %Scope{} = scope, name, arguments_json) when is_binary(name) do
    with {:ok, tool} <- find_tool(pack, name),
         {:ok, args} <- decode_arguments(arguments_json),
         :ok <- reject_undeclared_keys(tool, args),
         :ok <- validate_declared_types(tool, args),
         :ok <- Scope.authorize(scope) do
      invoke(pack, name, args, scope)
    end
  end

  defp find_tool(pack, name) do
    case Enum.find(pack.tools(), &(&1.name == name)) do
      nil -> {:tool_error, "Unknown tool: " <> name}
      tool -> {:ok, tool}
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
    declared = tool.parameters |> Map.get("properties", %{}) |> Map.keys()

    case args |> Map.keys() |> Kernel.--(declared) |> Enum.sort() do
      [] -> :ok
      [key | _rest] -> {:tool_error, "Unexpected argument: " <> key}
    end
  end

  defp validate_declared_types(tool, args) do
    with :ok <- validate_required(required_keys(tool), args) do
      tool.parameters
      |> Map.get("properties", %{})
      |> Enum.reduce_while(:ok, fn {key, schema}, :ok ->
        check_declared_value(args, key, schema)
      end)
    end
  end

  defp check_declared_value(args, key, schema) do
    case Map.fetch(args, key) do
      :error ->
        {:cont, :ok}

      {:ok, value} ->
        halt_on_tool_error(validate_value(key, schema, value))
    end
  end

  defp halt_on_tool_error(:ok), do: {:cont, :ok}
  defp halt_on_tool_error({:tool_error, _message} = error), do: {:halt, error}

  defp required_keys(tool), do: Map.get(tool.parameters, "required", [])

  defp validate_required(required, args) do
    case Enum.find(required, &(not Map.has_key?(args, &1))) do
      nil -> :ok
      key -> {:tool_error, "Missing required argument: " <> key}
    end
  end

  defp validate_value(key, %{"type" => _type}, nil),
    do: {:tool_error, "Argument #{key} must not be null."}

  defp validate_value(key, %{"type" => "string"} = schema, value) when is_binary(value),
    do: validate_string(key, schema, value)

  defp validate_value(key, %{"type" => "string"}, _value),
    do: {:tool_error, "Argument #{key} must be a string."}

  defp validate_value(key, %{"type" => "integer"} = schema, value) when is_integer(value),
    do: validate_integer(key, schema, value)

  defp validate_value(key, %{"type" => "integer"}, _value),
    do: {:tool_error, "Argument #{key} must be an integer."}

  defp validate_value(key, %{"type" => "array"} = schema, value) when is_list(value),
    do: validate_array(key, schema, value)

  defp validate_value(key, %{"type" => "array"}, _value),
    do: {:tool_error, "Argument #{key} must be an array."}

  defp validate_value(_key, %{"type" => "object"}, value) when is_map(value), do: :ok

  defp validate_value(key, %{"type" => "object"}, _value),
    do: {:tool_error, "Argument #{key} must be an object."}

  defp validate_value(_key, %{"type" => type}, _value) do
    raise ArgumentError,
          "unsupported JSON Schema type #{inspect(type)} in a pack tool definition"
  end

  defp validate_value(_key, _schema, _value), do: :ok

  defp validate_string(key, schema, value) do
    case Map.get(schema, "maxLength") do
      nil ->
        :ok

      max_length ->
        # The cap counts characters, not bytes; the decoded argument is already
        # bounded by the request body size limit.
        if String.length(value) > max_length do
          {:tool_error, "Argument #{key} must be at most #{max_length} characters."}
        else
          :ok
        end
    end
  end

  defp validate_integer(key, schema, value) do
    case Map.get(schema, "minimum") do
      nil ->
        :ok

      minimum when value < minimum ->
        {:tool_error, "Argument #{key} must be at least #{minimum}."}

      _minimum ->
        :ok
    end
  end

  defp validate_array(key, schema, value) do
    min_items = Map.get(schema, "minItems")
    max_items = Map.get(schema, "maxItems")
    count = length(value)

    cond do
      is_integer(min_items) and count < min_items ->
        {:tool_error, "Argument #{key} must have #{min_items} or more items."}

      is_integer(max_items) and count > max_items ->
        {:tool_error, "Argument #{key} must have #{max_items} or fewer items."}

      true ->
        validate_items(key, get_in(schema, ["items", "type"]), value)
    end
  end

  defp validate_items(_key, nil, _value), do: :ok

  defp validate_items(key, item_type, value) do
    if Enum.all?(value, &item_type?(item_type, &1)) do
      :ok
    else
      {:tool_error, "Argument #{key} must contain only #{item_type} values."}
    end
  end

  defp item_type?("string", value), do: is_binary(value)
  defp item_type?("integer", value), do: is_integer(value)
  defp item_type?("array", value), do: is_list(value)
  defp item_type?("object", value), do: is_map(value)

  defp item_type?(type, _value) do
    raise ArgumentError,
          "unsupported JSON Schema item type #{inspect(type)} in a pack tool definition"
  end

  defp invoke(pack, name, args, scope) do
    case pack.call(name, args, scope) do
      {:ok, result} -> bounded_result({:ok, result}, result)
      {:prepared, prepared, result} -> bounded_result({:prepared, prepared, result}, result)
      {:error, message} when is_binary(message) -> {:tool_error, message}
    end
  end

  defp bounded_result(tagged_result, result) when is_map(result) do
    if byte_size(Jason.encode!(result)) > @max_result_bytes do
      {:tool_error, @oversized_result}
    else
      tagged_result
    end
  end
end
