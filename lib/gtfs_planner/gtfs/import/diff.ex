defmodule GtfsPlanner.Gtfs.Import.Diff do
  @moduledoc """
  Pure diff engine for station-data GTFS imports.
  """

  alias GtfsPlanner.Gtfs.Import.DiffDecision

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

  @doc """
  Computes diff decisions between uploaded station files and current DB records.
  """
  def compute(
        %{levels: uploaded_levels, stops: uploaded_stops, pathways: uploaded_pathways},
        %{levels: db_levels, stops: db_stops, pathways: db_pathways}
      ) do
    diff_entity(:level, uploaded_levels, db_levels) ++
      diff_entity(:stop, uploaded_stops, db_stops) ++
      diff_entity(:pathway, uploaded_pathways, db_pathways)
  end

  @doc """
  Returns action counts across all decisions.
  """
  def summary(decisions) when is_list(decisions) do
    Enum.reduce(decisions, %{add: 0, modify: 0, remove: 0, conflict: 0}, fn decision, acc ->
      Map.update!(acc, decision.action, &(&1 + 1))
    end)
  end

  defp diff_entity(_entity_type, :not_uploaded, _db_records), do: []

  defp diff_entity(entity_type, uploaded_records, db_records)
       when is_list(uploaded_records) and is_list(db_records) do
    natural_key_field = natural_key_field(entity_type)

    uploaded_by_key =
      Map.new(uploaded_records, fn attrs -> {Map.fetch!(attrs, natural_key_field), attrs} end)

    db_by_key =
      Map.new(db_records, fn record -> {Map.fetch!(record, natural_key_field), record} end)

    uploaded_keys = uploaded_by_key |> Map.keys() |> MapSet.new()
    db_keys = db_by_key |> Map.keys() |> MapSet.new()

    add_keys =
      uploaded_keys
      |> MapSet.difference(db_keys)
      |> sorted_keys()

    remove_keys =
      db_keys
      |> MapSet.difference(uploaded_keys)
      |> sorted_keys()

    intersection_keys =
      uploaded_keys
      |> MapSet.intersection(db_keys)
      |> sorted_keys()

    add_decisions =
      Enum.map(add_keys, fn natural_key ->
        uploaded_attrs = Map.fetch!(uploaded_by_key, natural_key)

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
        uploaded_attrs = Map.fetch!(uploaded_by_key, natural_key)

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
