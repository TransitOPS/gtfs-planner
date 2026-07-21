defmodule GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer do
  @moduledoc "Versioned, bounded conversion for durable diff decisions."

  alias GtfsPlanner.Gtfs.Import.DiffDecision

  @version 1
  @max_id 512
  @max_key 255
  @max_value 4_096
  @fields %{
    level: [:level_index, :level_name],
    stop: [
      :stop_name,
      :stop_desc,
      :stop_lat,
      :stop_lon,
      :location_type,
      :wheelchair_boarding,
      :platform_code,
      :level_id,
      :parent_station
    ],
    pathway: [
      :pathway_mode,
      :is_bidirectional,
      :traversal_time,
      :length,
      :stair_count,
      :max_slope,
      :min_width,
      :signposted_as,
      :reversed_signposted_as,
      :from_stop_id,
      :to_stop_id
    ]
  }
  @actions [:add, :modify, :remove, :conflict]
  @statuses [:pending, :approved, :rejected, :preview, :applied, :failed, :stale]

  def serializer_version, do: @version

  def serialize(%DiffDecision{} = decision) do
    with :ok <- validate_identity(decision),
         {:ok, current_values} <-
           normalize_values(decision.current_record, decision.entity_type, :current_values),
         {:ok, uploaded_values} <-
           normalize_values(decision.uploaded_attrs, decision.entity_type, :uploaded_values),
         {:ok, changed_fields} <-
           normalize_changed_fields(decision.changed_fields, decision.entity_type),
         {:ok, dependency_keys} <- normalize_dependencies(decision.dependency_keys) do
      {:ok,
       %{
         serializer_version: @version,
         decision_id: decision.id,
         entity_type: decision.entity_type,
         action: decision.action,
         status: decision.status,
         natural_key: decision.natural_key,
         current_values: current_values,
         uploaded_values: uploaded_values,
         changed_fields: changed_fields,
         dependency_keys: dependency_keys,
         current_fingerprint: current_fingerprint(current_values),
         user_edited: decision.user_edited == true
       }}
    end
  end

  def deserialize(serialized) when is_map(serialized) do
    with {:ok, version} <- fetch(serialized, :serializer_version),
         :ok <- validate_version(version),
         {:ok, id} <- fetch(serialized, :decision_id),
         {:ok, entity_type} <- fetch_enum(serialized, :entity_type, Map.keys(@fields)),
         {:ok, action} <- fetch_enum(serialized, :action, @actions),
         {:ok, status} <- fetch_enum(serialized, :status, @statuses),
         {:ok, natural_key} <- fetch(serialized, :natural_key),
         :ok <- validate_string(id, @max_id, :decision_id),
         :ok <- validate_string(natural_key, @max_key, :natural_key),
         {:ok, current_values} <-
           load_values(
             fetch_value(serialized, :current_values, %{}),
             entity_type,
             :current_values
           ),
         {:ok, uploaded_values} <-
           load_values(
             fetch_value(serialized, :uploaded_values, %{}),
             entity_type,
             :uploaded_values
           ),
         {:ok, changed_fields} <-
           load_changed_fields(fetch_value(serialized, :changed_fields, []), entity_type),
         {:ok, dependencies} <-
           normalize_dependencies(fetch_value(serialized, :dependency_keys, [])) do
      {:ok,
       %DiffDecision{
         id: id,
         entity_type: entity_type,
         action: action,
         status: status,
         natural_key: natural_key,
         current_record: atomize_keys(current_values),
         uploaded_attrs: atomize_keys(uploaded_values),
         changed_fields: changed_fields,
         dependency_keys: dependencies,
         user_edited: fetch_value(serialized, :user_edited, false) == true
       }}
    end
  end

  def deserialize(_), do: {:error, :invalid_serialized_decision}

  def current_fingerprint(values) when is_map(values) do
    values
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_identity(%DiffDecision{
         id: id,
         entity_type: entity_type,
         action: action,
         status: status,
         natural_key: natural_key
       }) do
    with :ok <- validate_string(id, @max_id, :decision_id),
         true <- entity_type in Map.keys(@fields),
         true <- action in @actions,
         true <- status in @statuses,
         :ok <- validate_string(natural_key, @max_key, :natural_key) do
      :ok
    else
      false -> {:error, :invalid_decision_identity}
      error -> error
    end
  end

  defp normalize_values(nil, _entity_type, _kind), do: {:ok, %{}}

  defp normalize_values(values, entity_type, kind) when is_map(values) do
    allowed = Map.fetch!(@fields, entity_type)

    unknown = Enum.find(Map.keys(values), &(normalize_field(&1, allowed) == :unknown))

    case {kind, unknown} do
      {:uploaded_values, invalid} when not is_nil(invalid) ->
        {:error, {:unsupported_field, invalid}}

      _ ->
        Enum.reduce_while(allowed, {:ok, %{}}, fn field, {:ok, normalized} ->
          case Map.fetch(values, field) do
            :error ->
              {:cont, {:ok, normalized}}

            {:ok, value} ->
              case normalize_value(value) do
                {:ok, value} -> {:cont, {:ok, Map.put(normalized, Atom.to_string(field), value)}}
                :error -> {:halt, {:error, {:unsafe_value, kind}}}
              end
          end
        end)
    end
  end

  defp normalize_values(_, _, kind), do: {:error, {:unsafe_value, kind}}

  defp load_values(values, entity_type, kind) when is_map(values),
    do: values |> atomize_keys() |> normalize_values(entity_type, kind)

  defp load_values(_, _, kind), do: {:error, {:unsafe_value, kind}}

  defp normalize_changed_fields(fields, entity_type) when is_list(fields) do
    allowed = Map.fetch!(@fields, entity_type)

    if length(fields) > length(allowed) do
      {:error, :too_many_changed_fields}
    else
      result =
        Enum.reduce_while(fields, {:ok, []}, fn
          {field, {before, after_value}}, {:ok, acc} ->
            if field in allowed do
              with {:ok, before} <- normalize_value(before),
                   {:ok, after_value} <- normalize_value(after_value) do
                {:cont,
                 {:ok,
                  [
                    %{
                      "field" => Atom.to_string(field),
                      "before" => before,
                      "after" => after_value
                    }
                    | acc
                  ]}}
              else
                :error -> {:halt, {:error, {:unsafe_value, :changed_fields}}}
              end
            else
              {:halt, {:error, {:unsupported_field, field}}}
            end

          _, _ ->
            {:halt, {:error, :invalid_changed_fields}}
        end)

      case result do
        {:ok, normalized} -> {:ok, Enum.sort_by(normalized, & &1["field"])}
        error -> error
      end
    end
  end

  defp normalize_changed_fields(_, _), do: {:error, :invalid_changed_fields}

  defp load_changed_fields(fields, entity_type) when is_list(fields) do
    result =
      Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
        with {:ok, name} <- fetch(field, :field),
             {:ok, before} <- fetch(field, :before),
             {:ok, after_value} <- fetch(field, :after),
             atom when is_atom(atom) <- normalize_field(name, Map.fetch!(@fields, entity_type)),
             false <- atom == :unknown do
          {:cont, {:ok, [{atom, {before, after_value}} | acc]}}
        else
          _ -> {:halt, {:error, :invalid_changed_fields}}
        end
      end)

    case result do
      {:ok, changed} ->
        changed = Enum.reverse(changed)

        case normalize_changed_fields(changed, entity_type) do
          {:ok, _} -> {:ok, changed}
          error -> error
        end

      error ->
        error
    end
  end

  defp load_changed_fields(_, _), do: {:error, :invalid_changed_fields}

  defp normalize_dependencies(keys) when is_list(keys) and length(keys) <= 100 do
    if Enum.all?(keys, &(is_binary(&1) and String.length(&1) <= @max_key)),
      do: {:ok, keys |> Enum.uniq() |> Enum.sort()},
      else: {:error, :invalid_dependency_keys}
  end

  defp normalize_dependencies(_), do: {:error, :invalid_dependency_keys}

  defp normalize_value(value) when is_binary(value) and byte_size(value) <= @max_value,
    do: {:ok, value}

  defp normalize_value(value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize_value(%Decimal{} = value),
    do: {:ok, value |> Decimal.normalize() |> Decimal.to_string(:normal)}

  defp normalize_value(_), do: :error

  defp validate_version(@version), do: :ok
  defp validate_version(_), do: {:error, :unsupported_serializer_version}
  defp validate_string(value, max, _) when is_binary(value) and byte_size(value) <= max, do: :ok
  defp validate_string(_, _, field), do: {:error, {:invalid_string, field}}

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch_value(map, key, default) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_enum(map, key, values) do
    with {:ok, value} <- fetch(map, key) do
      value =
        if is_binary(value), do: Enum.find(values, &(Atom.to_string(&1) == value)), else: value

      if value in values, do: {:ok, value}, else: {:error, :invalid_serialized_decision}
    end
  end

  defp normalize_field(value, allowed) when is_atom(value),
    do: if(value in allowed, do: value, else: :unknown)

  defp normalize_field(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value)) || :unknown

  defp normalize_field(_, _), do: :unknown

  defp atomize_keys(map) do
    fields = Map.values(@fields) |> List.flatten() |> Enum.uniq()

    Enum.reduce(map, %{}, fn {key, value}, acc ->
      field = Enum.find(fields, &(Atom.to_string(&1) == to_string(key)))
      Map.put(acc, field || key, value)
    end)
  end
end
