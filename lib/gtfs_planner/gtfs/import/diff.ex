defmodule GtfsPlanner.Gtfs.Import.Diff do
  @moduledoc """
  Pure diff engine for station-data GTFS imports.

  Consumes capability-bearing reviewed parse results and returns separate
  applicable and read-only preview decision collections with dependency tainting.
  """

  alias GtfsPlanner.Gtfs.Import.{DiffDecision, ParsedEntity, ParseFailure}

  @level_fields [:level_index, :level_name]

  @stop_fields [
    :stop_name,
    :stop_desc,
    :stop_lat,
    :stop_lon,
    :location_type,
    :wheelchair_boarding,
    :platform_code,
    :level_id,
    :parent_station
  ]

  @pathway_fields [
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

  @entity_order [:level, :stop, :pathway]

  @type uploaded :: %{
          levels: ParsedEntity.result(),
          stops: ParsedEntity.result(),
          pathways: ParsedEntity.result()
        }

  @type result :: %{
          applicable: [DiffDecision.t()],
          preview: [DiffDecision.t()],
          blocked_entities: %{optional(:level | :stop | :pathway) => atom()}
        }

  @doc """
  Computes applicable and read-only preview diff decisions between reviewed
  upload results and current DB records.

  Dependency taint (conservative, entity-wide, transitive): a failed uploaded
  levels source makes uploaded stop decisions read-only; a failed uploaded
  stops source makes uploaded pathway decisions read-only. `:not_uploaded` is
  intentional omission and does not taint a downstream file.
  """
  @spec compute(uploaded(), %{levels: [struct()], stops: [struct()], pathways: [struct()]}) ::
          result()
  def compute(uploaded, db) do
    taint = compute_taint(uploaded)

    results =
      Enum.flat_map(@entity_order, fn entity_type ->
        uploaded_key = entity_key(entity_type)
        uploaded_result = Map.fetch!(uploaded, uploaded_key)
        db_records = Map.fetch!(db, uploaded_key)
        block_reason = Map.get(taint, uploaded_key)

        entity_decisions(entity_type, uploaded_result, db_records, block_reason)
      end)

    applicable = Enum.filter(results, &(&1.source == :applicable)) |> Enum.map(& &1.decision)
    preview = Enum.filter(results, &(&1.source == :preview)) |> Enum.map(& &1.decision)

    blocked_entities =
      Enum.reduce(@entity_order, %{}, fn entity_type, acc ->
        uploaded_key = entity_key(entity_type)
        reason = Map.get(taint, uploaded_key)

        if reason && reason in [:parse_failed, :dependency_failed] do
          Map.put(acc, entity_type, reason)
        else
          acc
        end
      end)

    %{applicable: applicable, preview: preview, blocked_entities: blocked_entities}
  end

  defp entity_key(:level), do: :levels
  defp entity_key(:stop), do: :stops
  defp entity_key(:pathway), do: :pathways

  defp compute_taint(uploaded) do
    levels_failed = failed_reason(Map.fetch!(uploaded, :levels))
    stops_failed = failed_reason(Map.fetch!(uploaded, :stops))
    pathways_failed = failed_reason(Map.fetch!(uploaded, :pathways))

    dependency_taint =
      %{}
      |> then(fn acc ->
        if levels_failed and Map.fetch!(uploaded, :stops) != :not_uploaded,
          do: Map.put(acc, :stops, :dependency_failed),
          else: acc
      end)
      |> then(fn acc ->
        if stops_failed and Map.fetch!(uploaded, :pathways) != :not_uploaded,
          do: Map.put(acc, :pathways, :dependency_failed),
          else: acc
      end)

    parse_failed =
      %{}
      |> then(fn acc -> if levels_failed, do: Map.put(acc, :levels, :parse_failed), else: acc end)
      |> then(fn acc -> if stops_failed, do: Map.put(acc, :stops, :parse_failed), else: acc end)
      |> then(fn acc ->
        if pathways_failed, do: Map.put(acc, :pathways, :parse_failed), else: acc
      end)

    Map.merge(dependency_taint, parse_failed)
  end

  defp failed_reason({:error, _failure}), do: true
  defp failed_reason(_), do: false

  defp entity_decisions(_entity_type, :not_uploaded, _db_records, _block_reason), do: []

  defp entity_decisions(
         entity_type,
         {:ok, %ParsedEntity{records_by_key: records_by_key}},
         db_records,
         block_reason
       ) do
    decisions = diff_entity(entity_type, records_by_key, db_records)

    case block_reason do
      :dependency_failed ->
        Enum.map(decisions, &%{source: :preview, decision: &1})

      _ ->
        Enum.map(decisions, &%{source: :applicable, decision: &1})
    end
  end

  defp entity_decisions(
         entity_type,
         {:error, %ParseFailure{preview_records_by_key: preview_records_by_key}},
         db_records,
         _block_reason
       ) do
    decisions =
      diff_preview_entity(entity_type, preview_records_by_key, db_records)

    Enum.map(decisions, &%{source: :preview, decision: &1})
  end

  @doc """
  Returns action counts across all decisions.
  """
  def summary(decisions) when is_list(decisions) do
    Enum.reduce(decisions, %{add: 0, modify: 0, remove: 0, conflict: 0}, fn decision, acc ->
      Map.update!(acc, decision.action, &(&1 + 1))
    end)
  end

  defp diff_entity(entity_type, records_by_key, db_records) when records_by_key == %{},
    do: remove_decisions(entity_type, db_records)

  defp diff_entity(entity_type, records_by_key, db_records) do
    db_by_key =
      Map.new(db_records, fn record ->
        {Map.fetch!(record, natural_key_field(entity_type)), record}
      end)

    uploaded_keys = records_by_key |> Map.keys() |> MapSet.new()
    db_keys = db_by_key |> Map.keys() |> MapSet.new()

    add_keys = MapSet.difference(uploaded_keys, db_keys) |> sorted_keys()
    remove_keys = MapSet.difference(db_keys, uploaded_keys) |> sorted_keys()
    intersection_keys = MapSet.intersection(uploaded_keys, db_keys) |> sorted_keys()

    add_decisions =
      Enum.map(add_keys, fn natural_key ->
        uploaded_attrs = Map.fetch!(records_by_key, natural_key)

        build_decision(entity_type, natural_key, :add,
          uploaded_attrs: uploaded_attrs,
          dependency_keys: dependency_keys(entity_type, :add, uploaded_attrs)
        )
      end)

    remove_decisions =
      Enum.map(remove_keys, fn natural_key ->
        current_record = Map.fetch!(db_by_key, natural_key)

        build_decision(entity_type, natural_key, :remove,
          current_record: current_record,
          dependency_keys: []
        )
      end)

    intersection_decisions =
      Enum.flat_map(intersection_keys, fn natural_key ->
        current_record = Map.fetch!(db_by_key, natural_key)
        uploaded_attrs = Map.fetch!(records_by_key, natural_key)

        changed_fields = changed_fields(entity_type, current_record, uploaded_attrs)

        if changed_fields == [] do
          []
        else
          user_edited = user_edited?(current_record)
          action = if user_edited, do: :conflict, else: :modify

          [
            build_decision(entity_type, natural_key, action,
              current_record: current_record,
              uploaded_attrs: uploaded_attrs,
              changed_fields: changed_fields,
              user_edited: user_edited,
              dependency_keys: dependency_keys(entity_type, action, uploaded_attrs)
            )
          ]
        end
      end)

    add_decisions ++ remove_decisions ++ intersection_decisions
  end

  defp remove_decisions(entity_type, db_records) do
    natural_key_field = natural_key_field(entity_type)

    Enum.map(db_records, fn record ->
      natural_key = Map.fetch!(record, natural_key_field)

      build_decision(entity_type, natural_key, :remove,
        current_record: record,
        dependency_keys: []
      )
    end)
  end

  defp diff_preview_entity(_entity_type, preview_records_by_key, _db_records)
       when preview_records_by_key == %{},
       do: []

  defp diff_preview_entity(entity_type, preview_records_by_key, db_records) do
    db_by_key =
      Map.new(db_records, fn record ->
        {Map.fetch!(record, natural_key_field(entity_type)), record}
      end)

    uploaded_keys = preview_records_by_key |> Map.keys() |> MapSet.new()
    db_keys = db_by_key |> Map.keys() |> MapSet.new()

    add_keys = MapSet.difference(uploaded_keys, db_keys) |> sorted_keys()
    intersection_keys = MapSet.intersection(uploaded_keys, db_keys) |> sorted_keys()

    add_decisions =
      Enum.map(add_keys, fn natural_key ->
        uploaded_attrs = Map.fetch!(preview_records_by_key, natural_key)

        build_decision(entity_type, natural_key, :add,
          uploaded_attrs: uploaded_attrs,
          dependency_keys: dependency_keys(entity_type, :add, uploaded_attrs)
        )
      end)

    intersection_decisions =
      Enum.flat_map(intersection_keys, fn natural_key ->
        current_record = Map.fetch!(db_by_key, natural_key)
        uploaded_attrs = Map.fetch!(preview_records_by_key, natural_key)

        changed_fields = changed_fields(entity_type, current_record, uploaded_attrs)

        if changed_fields == [] do
          []
        else
          user_edited = user_edited?(current_record)
          action = if user_edited, do: :conflict, else: :modify

          [
            build_decision(entity_type, natural_key, action,
              current_record: current_record,
              uploaded_attrs: uploaded_attrs,
              changed_fields: changed_fields,
              user_edited: user_edited,
              dependency_keys: dependency_keys(entity_type, action, uploaded_attrs)
            )
          ]
        end
      end)

    add_decisions ++ intersection_decisions
  end

  defp build_decision(entity_type, natural_key, action, attrs) do
    %DiffDecision{
      id: "#{entity_type}:#{natural_key}",
      action: action,
      entity_type: entity_type,
      natural_key: natural_key,
      current_record: Keyword.get(attrs, :current_record),
      uploaded_attrs: Keyword.get(attrs, :uploaded_attrs),
      changed_fields: Keyword.get(attrs, :changed_fields, []),
      user_edited: Keyword.get(attrs, :user_edited, false),
      dependency_keys: Keyword.get(attrs, :dependency_keys, [])
    }
  end

  defp sorted_keys(set) do
    set
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp natural_key_field(:level), do: :level_id
  defp natural_key_field(:stop), do: :stop_id
  defp natural_key_field(:pathway), do: :pathway_id

  defp managed_fields(:level), do: @level_fields
  defp managed_fields(:stop), do: @stop_fields
  defp managed_fields(:pathway), do: @pathway_fields

  defp changed_fields(entity_type, current_record, uploaded_attrs) do
    managed_fields(entity_type)
    |> Enum.reduce([], fn field, acc ->
      old_value = Map.fetch!(current_record, field)
      new_value = Map.get(uploaded_attrs, field)

      if equal_value?(old_value, new_value) do
        acc
      else
        [{field, {old_value, new_value}} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp equal_value?(%Decimal{} = left, %Decimal{} = right), do: Decimal.equal?(left, right)
  defp equal_value?(left, right), do: left == right

  defp user_edited?(record) do
    case {record.inserted_at, record.updated_at} do
      {%DateTime{} = inserted_at, %DateTime{} = updated_at} ->
        DateTime.compare(updated_at, inserted_at) == :gt

      _ ->
        false
    end
  end

  defp dependency_keys(:stop, action, uploaded_attrs) when action in [:add, :modify, :conflict] do
    [
      build_dependency_key("level", Map.get(uploaded_attrs, :level_id)),
      build_dependency_key("stop", Map.get(uploaded_attrs, :parent_station))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp dependency_keys(:pathway, action, uploaded_attrs)
       when action in [:add, :modify, :conflict] do
    [
      build_dependency_key("stop", Map.get(uploaded_attrs, :from_stop_id)),
      build_dependency_key("stop", Map.get(uploaded_attrs, :to_stop_id))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp dependency_keys(_entity_type, _action, _uploaded_attrs), do: []

  defp build_dependency_key(_type, nil), do: nil
  defp build_dependency_key(_type, ""), do: nil
  defp build_dependency_key(type, key), do: "#{type}:#{key}"
end
