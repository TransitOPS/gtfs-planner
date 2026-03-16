defmodule GtfsPlanner.Gtfs.StationReport.PathwayChecks do
  @moduledoc """
  Pathway validation checks for station report.

  Validates traversal_time, min_width, bidirectional flags, stair_count,
  max_slope, sign consistency, outliers, speed plausibility, signage
  formatting, dangling refs, self-refs, and duplicates.
  """

  alias GtfsPlanner.Gtfs.StationReport.Helpers

  @doc """
  Returns pathway validation items for a list of pathways.
  """
  @spec validate([map()], map(), map()) :: [map()]
  def validate(pathways, stop_index, level_index) do
    [
      missing_traversal_time(pathways),
      gates_missing_width(pathways),
      bidirectional_mechanical(pathways),
      bidirectional_gates(pathways),
      stairs_zero_count(pathways),
      wrong_max_slope(pathways),
      stair_sign_consistency(pathways, stop_index, level_index),
      traversal_time_outliers(pathways),
      speed_plausibility(pathways),
      signage_formatting(pathways),
      signage_commas(pathways),
      dangling_refs(pathways, stop_index),
      self_referencing(pathways),
      duplicate_routes(pathways),
      duplicate_ids(pathways)
    ]
  end

  # 1. Missing traversal_time
  defp missing_traversal_time(pathways) do
    flagged =
      pathways
      |> Enum.filter(&is_nil(&1.traversal_time))
      |> Enum.map(& &1.pathway_id)

    Helpers.item(
      "pathway_missing_traversal_time",
      "Pathways with traversal_time",
      if(flagged == [], do: :pass, else: :warn),
      :warning,
      length(flagged),
      flagged
    )
  end

  # 2. Gates missing width
  defp gates_missing_width(pathways) do
    gate_modes = MapSet.new([6, 7])

    flagged =
      pathways
      |> Enum.filter(&(MapSet.member?(gate_modes, &1.pathway_mode) and is_nil(&1.min_width)))
      |> Enum.map(& &1.pathway_id)

    Helpers.item(
      "pathway_gates_missing_width",
      "Gate pathways with min_width",
      if(flagged == [], do: :pass, else: :warn),
      :warning,
      length(flagged),
      flagged
    )
  end

  # 3. Bidirectional mechanical (mode 3/4)
  defp bidirectional_mechanical(pathways) do
    mechanical_modes = MapSet.new([3, 4])

    flagged =
      pathways
      |> Enum.filter(&(MapSet.member?(mechanical_modes, &1.pathway_mode) and &1.is_bidirectional))
      |> Enum.map(& &1.pathway_id)

    Helpers.item(
      "pathway_bidirectional_mechanical",
      "Mechanical pathways not bidirectional",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  # 4. Bidirectional gates (mode 6/7)
  defp bidirectional_gates(pathways) do
    gate_modes = MapSet.new([6, 7])

    flagged =
      pathways
      |> Enum.filter(&(MapSet.member?(gate_modes, &1.pathway_mode) and &1.is_bidirectional))
      |> Enum.map(& &1.pathway_id)

    Helpers.item(
      "pathway_bidirectional_gates",
      "Gate pathways not bidirectional",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  # 5. Stairs with zero count
  defp stairs_zero_count(pathways) do
    flagged =
      pathways
      |> Enum.filter(&(&1.pathway_mode == 2 and (&1.stair_count == 0 or is_nil(&1.stair_count))))
      |> Enum.map(& &1.pathway_id)

    Helpers.item(
      "pathway_stairs_zero_count",
      "Stair pathways have stair_count",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  # 6. Wrong max_slope (not on mode 1 or 3)
  defp wrong_max_slope(pathways) do
    valid_slope_modes = MapSet.new([1, 3])

    flagged =
      pathways
      |> Enum.filter(fn pw ->
        not MapSet.member?(valid_slope_modes, pw.pathway_mode) and
          slope_present?(pw.max_slope)
      end)
      |> Enum.map(& &1.pathway_id)

    Helpers.item(
      "pathway_wrong_max_slope",
      "max_slope only on walkways/moving sidewalks",
      if(flagged == [], do: :pass, else: :warn),
      :warning,
      length(flagged),
      flagged
    )
  end

  # 7. Stair sign consistency
  defp stair_sign_consistency(pathways, stop_index, level_index) do
    flagged =
      pathways
      |> Enum.filter(
        &(&1.pathway_mode == 2 and is_integer(&1.stair_count) and &1.stair_count != 0)
      )
      |> Enum.filter(fn pw ->
        from_idx = level_index_for(pw.from_stop_id, stop_index, level_index)
        to_idx = level_index_for(pw.to_stop_id, stop_index, level_index)
        is_number(from_idx) and is_number(to_idx)
      end)
      |> Enum.filter(fn pw ->
        from_idx = level_index_for(pw.from_stop_id, stop_index, level_index)
        to_idx = level_index_for(pw.to_stop_id, stop_index, level_index)
        going_up = to_idx > from_idx

        cond do
          going_up and pw.stair_count < 0 -> true
          not going_up and pw.stair_count > 0 -> true
          true -> false
        end
      end)
      |> Enum.map(& &1.pathway_id)

    Helpers.item(
      "pathway_stair_sign_consistency",
      "Stair count sign matches direction",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  # 8. Traversal time outliers
  defp traversal_time_outliers(pathways) do
    flagged =
      pathways
      |> Enum.filter(&is_integer(&1.traversal_time))
      |> Enum.group_by(& &1.pathway_mode)
      |> Enum.flat_map(fn {_mode, mode_pathways} ->
        keyed = Enum.map(mode_pathways, &{&1.pathway_id, &1.traversal_time})
        outliers = Helpers.find_outliers(keyed)

        if outliers == [] do
          []
        else
          mean =
            mode_pathways
            |> Enum.map(& &1.traversal_time)
            |> then(&(Enum.sum(&1) / length(&1)))
            |> Float.round(1)

          Enum.map(outliers, fn {id, time} ->
            %{id: id, reason: "#{time}s vs mean #{mean}s"}
          end)
        end
      end)

    Helpers.item(
      "pathway_traversal_time_outliers",
      "Traversal time outliers by mode",
      if(flagged == [], do: :info, else: :warn),
      :analysis,
      length(flagged),
      flagged
    )
  end

  # 9. Speed plausibility (mode 1 walkways)
  defp speed_plausibility(pathways) do
    flagged =
      pathways
      |> Enum.filter(fn pw ->
        pw.pathway_mode == 1 and
          is_integer(pw.traversal_time) and pw.traversal_time > 0 and
          pw.length != nil
      end)
      |> Enum.map(fn pw ->
        length_m = Helpers.decimal_to_float(pw.length)
        speed = length_m / pw.traversal_time
        {pw.pathway_id, Float.round(speed, 2)}
      end)
      |> Enum.filter(fn {_id, speed} -> speed < 0.5 or speed > 2.0 end)
      |> Enum.map(fn {id, speed} -> %{id: id, reason: "#{speed} m/s"} end)

    Helpers.item(
      "pathway_speed_plausibility",
      "Walkway implied speed (0.5-2.0 m/s)",
      if(flagged == [], do: :pass, else: :warn),
      :analysis,
      length(flagged),
      flagged
    )
  end

  # 10. Signage formatting
  defp signage_formatting(pathways) do
    flagged =
      pathways
      |> Enum.flat_map(fn pw ->
        issues = []

        issues =
          issues ++ check_signage_format(pw.pathway_id, "signposted_as", pw.signposted_as)

        issues ++
          check_signage_format(
            pw.pathway_id,
            "reversed_signposted_as",
            pw.reversed_signposted_as
          )
      end)

    Helpers.item(
      "pathway_signage_formatting",
      "Signage text formatting",
      if(flagged == [], do: :pass, else: :warn),
      :convention,
      length(flagged),
      flagged
    )
  end

  # 11. Signage commas
  defp signage_commas(pathways) do
    flagged =
      pathways
      |> Enum.flat_map(fn pw ->
        issues = []

        issues =
          if is_binary(pw.signposted_as) and String.contains?(pw.signposted_as, ",") do
            [%{id: pw.pathway_id, reason: "signposted_as contains comma"} | issues]
          else
            issues
          end

        if is_binary(pw.reversed_signposted_as) and
             String.contains?(pw.reversed_signposted_as, ",") do
          [%{id: pw.pathway_id, reason: "reversed_signposted_as contains comma"} | issues]
        else
          issues
        end
      end)

    Helpers.item(
      "pathway_signage_commas",
      "Signage fields without commas",
      if(flagged == [], do: :pass, else: :warn),
      :warning,
      length(flagged),
      flagged
    )
  end

  # 12. Dangling refs
  defp dangling_refs(pathways, stop_index) do
    flagged =
      pathways
      |> Enum.filter(fn pw ->
        not Map.has_key?(stop_index, pw.from_stop_id) or
          not Map.has_key?(stop_index, pw.to_stop_id)
      end)
      |> Enum.map(fn pw ->
        missing =
          []
          |> then(
            &if(not Map.has_key?(stop_index, pw.from_stop_id),
              do: [pw.from_stop_id | &1],
              else: &1
            )
          )
          |> then(
            &if(not Map.has_key?(stop_index, pw.to_stop_id),
              do: [pw.to_stop_id | &1],
              else: &1
            )
          )
          |> Enum.join(", ")

        %{id: pw.pathway_id, reason: "missing: #{missing}"}
      end)

    Helpers.item(
      "pathway_dangling_refs",
      "Pathway endpoints reference known stops",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  # 13. Self-referencing
  defp self_referencing(pathways) do
    flagged =
      pathways
      |> Enum.filter(&(&1.from_stop_id == &1.to_stop_id))
      |> Enum.map(& &1.pathway_id)

    Helpers.item(
      "pathway_self_referencing",
      "Pathways do not self-reference",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  # 14. Duplicate routes
  defp duplicate_routes(pathways) do
    flagged =
      pathways
      |> Enum.group_by(&{&1.from_stop_id, &1.to_stop_id, &1.pathway_mode})
      |> Enum.flat_map(fn {_key, group} ->
        if length(group) > 1 do
          sorted = Enum.sort_by(group, & &1.pathway_id)
          first = List.first(sorted)

          sorted
          |> Enum.drop(1)
          |> Enum.map(&%{id: &1.pathway_id, reason: "duplicate of #{first.pathway_id}"})
        else
          []
        end
      end)

    Helpers.item(
      "pathway_duplicate_routes",
      "Unique pathway routes (from/to/mode)",
      if(flagged == [], do: :pass, else: :warn),
      :warning,
      length(flagged),
      flagged
    )
  end

  # 15. Duplicate pathway IDs
  defp duplicate_ids(pathways) do
    flagged =
      pathways
      |> Enum.group_by(& &1.pathway_id)
      |> Enum.filter(fn {_id, group} -> length(group) > 1 end)
      |> Enum.flat_map(fn {_id, group} -> Enum.map(group, & &1.pathway_id) end)
      |> Enum.uniq()

    Helpers.item(
      "pathway_duplicate_ids",
      "Unique pathway_id values",
      if(flagged == [], do: :pass, else: :fail),
      :error,
      length(flagged),
      flagged
    )
  end

  # Helpers

  defp slope_present?(%Decimal{} = d) do
    Decimal.compare(d, Decimal.new("0")) != :eq
  end

  defp slope_present?(nil), do: false
  defp slope_present?(_), do: true

  defp level_index_for(stop_id, stop_index, level_index) do
    case Map.get(stop_index, stop_id) do
      nil ->
        nil

      stop ->
        case Map.get(level_index, stop.level_id) do
          nil -> nil
          level -> level.level_index
        end
    end
  end

  defp check_signage_format(_pathway_id, _field, nil), do: []
  defp check_signage_format(_pathway_id, _field, ""), do: []

  defp check_signage_format(pathway_id, field, value) when is_binary(value) do
    issues = []

    issues =
      if String.trim_leading(value) != value or String.trim_trailing(value) != value do
        [%{id: pathway_id, reason: "#{field}: leading/trailing whitespace"} | issues]
      else
        issues
      end

    if Regex.match?(~r/\s{2,}/, value) do
      [%{id: pathway_id, reason: "#{field}: consecutive spaces"} | issues]
    else
      issues
    end
  end
end
