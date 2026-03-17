defmodule GtfsPlanner.Gtfs.StationReport.LevelChecks do
  @moduledoc """
  Level validation checks for station report.

  Validates level referential integrity, platforms missing level
  assignments, and level naming consistency.
  """

  alias GtfsPlanner.Gtfs.StationReport.Helpers

  @doc """
  Returns level validation items for child stops and levels.

  `levels` is a list of `%{level: Level.t(), stop_count: integer()}` maps.
  """
  @spec validate([map()], [map()]) :: [map()]
  def validate(child_stops, levels) do
    level_map = Map.new(levels, fn %{level: level} -> {level.level_id, level} end)
    level_ids_set = MapSet.new(Map.keys(level_map))

    [
      referential_integrity(child_stops, level_ids_set, level_map),
      platforms_missing_level(child_stops),
      naming_consistency(levels)
    ]
  end

  defp referential_integrity(child_stops, level_ids_set, _level_map) do
    # Level IDs referenced by stops
    referenced_level_ids =
      child_stops
      |> Enum.map(& &1.level_id)
      |> Enum.filter(&Helpers.present?/1)
      |> MapSet.new()

    # Level IDs referenced by stops but not in levels list
    missing_levels =
      referenced_level_ids
      |> MapSet.difference(level_ids_set)
      |> Enum.map(&%{id: &1, reason: "referenced but missing"})

    # Level IDs in levels list but not referenced by any stop
    orphan_levels =
      level_ids_set
      |> MapSet.difference(referenced_level_ids)
      |> Enum.map(&%{id: &1, reason: "orphan"})

    all_issues = missing_levels ++ orphan_levels

    {status, category} =
      cond do
        missing_levels != [] -> {:fail, :error}
        orphan_levels != [] -> {:warn, :warning}
        true -> {:pass, :error}
      end

    Helpers.item(
      "level_referential_integrity",
      "Level referential integrity",
      status,
      category,
      length(all_issues),
      all_issues
    )
  end

  defp platforms_missing_level(child_stops) do
    flagged =
      child_stops
      |> Enum.filter(&(&1.location_type == 0 and not Helpers.present?(&1.level_id)))
      |> Enum.map(& &1.stop_id)

    Helpers.item(
      "platforms_missing_level",
      "Platforms assigned to a level",
      if(flagged == [], do: :pass, else: :warn),
      :warning,
      length(flagged),
      flagged
    )
  end

  defp naming_consistency(levels) do
    flagged =
      levels
      |> Enum.filter(fn %{level: level} ->
        level_id = level.level_id || ""
        level_name = level.level_name || ""

        id_has_level = String.contains?(String.downcase(level_id), "level")
        name_has_level = String.contains?(String.downcase(level_name), "level")

        # Flag when one has "level" but the other doesn't
        Helpers.present?(level_name) and id_has_level != name_has_level
      end)
      |> Enum.map(fn %{level: level} ->
        %{
          id: level.level_id,
          reason:
            "level_id #{if String.contains?(String.downcase(level.level_id || ""), "level"), do: "contains", else: "lacks"} 'level' but level_name #{if String.contains?(String.downcase(level.level_name || ""), "level"), do: "contains", else: "lacks"} it"
        }
      end)

    Helpers.item(
      "level_naming_consistency",
      "Level ID and name consistency",
      if(flagged == [], do: :pass, else: :warn),
      :convention,
      length(flagged),
      flagged
    )
  end
end
