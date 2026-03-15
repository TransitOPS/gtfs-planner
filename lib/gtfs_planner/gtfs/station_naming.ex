defmodule GtfsPlanner.Gtfs.StationNaming do
  @moduledoc """
  Pure functions for deriving deterministic child-stop names
  using the station naming convention.

  Pattern: `{station}_{type}_{feature}_{level}_{seq}`
  """

  alias GtfsPlanner.Gtfs.Stop

  @feature_priority [
    {5, "elevator"},
    {4, "escalator"},
    {2, "stairs"},
    {7, "exit_gate"},
    {6, "fare_gate"},
    {3, "moving_sidewalk"},
    {1, "walkway"}
  ]

  @doc """
  Builds a list of `%{old_id: string, new_id: string}` mappings
  for child stops under a station.

  `child_stops` must have `stop_id`, `location_type`, and `level_id`.
  `pathways` must have `from_stop_id`, `to_stop_id`, and `pathway_mode`.
  `station_stop_id` is the parent station's `stop_id`.
  """
  def build_naming_map(child_stops, pathways, station_stop_id) do
    station_slug = Stop.slugify(station_stop_id)
    stop_features = build_feature_map(child_stops, pathways)

    child_stops
    |> Enum.map(fn stop ->
      type = Stop.location_type_slug(stop.location_type)
      feature = Map.get(stop_features, stop.stop_id, "general")
      level = level_slug(stop.level_id)
      partition_key = "#{station_slug}_#{type}_#{feature}_#{level}"

      %{
        stop_id: stop.stop_id,
        type: type,
        feature: feature,
        level: level,
        partition_key: partition_key
      }
    end)
    |> Enum.group_by(& &1.partition_key)
    |> Enum.flat_map(fn {partition_key, stops} ->
      stops
      |> Enum.sort_by(& &1.stop_id)
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, seq} ->
        seq_str = String.pad_leading(Integer.to_string(seq), 2, "0")
        new_id = "#{partition_key}_#{seq_str}"
        %{old_id: stop.stop_id, new_id: new_id}
      end)
    end)
    |> Enum.sort_by(& &1.old_id)
  end

  @doc """
  Builds a list of `%{old_id: string, new_id: string}` mappings
  using kebab-case stop names with sequence numbers.

  Groups stops by their kebab-cased stop_name; within each group,
  stops are sorted by stop_id and assigned zero-padded 2-digit sequences.

  Pattern: `{kebab-name}-{seq}` (e.g., `platform-2-01`)
  """
  def build_kebab_naming_map(child_stops) do
    child_stops
    |> Enum.map(fn stop ->
      kebab = Stop.kebabify(stop.stop_name || stop.stop_id)
      %{stop_id: stop.stop_id, partition_key: kebab}
    end)
    |> Enum.group_by(& &1.partition_key)
    |> Enum.flat_map(fn {partition_key, stops} ->
      stops
      |> Enum.sort_by(& &1.stop_id)
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, seq} ->
        seq_str = String.pad_leading(Integer.to_string(seq), 2, "0")
        %{old_id: stop.stop_id, new_id: "#{partition_key}-#{seq_str}"}
      end)
    end)
    |> Enum.sort_by(& &1.old_id)
  end

  @doc """
  Returns a list of new IDs that collide with existing stop IDs
  outside the rename mapping.
  """
  def detect_collisions(naming_map, existing_stop_ids) do
    old_ids = MapSet.new(naming_map, & &1.old_id)

    # IDs that exist but are NOT being renamed (i.e., outside the mapping)
    external_ids = MapSet.difference(existing_stop_ids, old_ids)

    naming_map
    |> Enum.filter(fn %{new_id: new_id} -> MapSet.member?(external_ids, new_id) end)
    |> Enum.map(& &1.new_id)
  end

  defp build_feature_map(child_stops, pathways) do
    stop_ids = MapSet.new(child_stops, & &1.stop_id)

    # For each pathway, record the pathway_mode for both endpoints
    pathways
    |> Enum.flat_map(fn pw ->
      entries = []

      entries =
        if MapSet.member?(stop_ids, pw.from_stop_id),
          do: [{pw.from_stop_id, pw.pathway_mode} | entries],
          else: entries

      entries =
        if MapSet.member?(stop_ids, pw.to_stop_id),
          do: [{pw.to_stop_id, pw.pathway_mode} | entries],
          else: entries

      entries
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {stop_id, modes} ->
      {stop_id, highest_priority_feature(modes)}
    end)
  end

  defp highest_priority_feature(modes) do
    mode_set = MapSet.new(modes)

    Enum.find_value(@feature_priority, "general", fn {mode, token} ->
      if MapSet.member?(mode_set, mode), do: token
    end)
  end

  defp level_slug(nil), do: "nolvl"
  defp level_slug(""), do: "nolvl"

  defp level_slug(level_id) do
    case Stop.slugify(level_id) do
      "" -> "nolvl"
      slug -> slug
    end
  end
end
