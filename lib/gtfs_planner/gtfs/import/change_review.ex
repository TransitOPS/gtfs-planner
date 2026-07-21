defmodule GtfsPlanner.Gtfs.Import.ChangeReview do
  @moduledoc false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Diff, ParseError, ParseFailure, ParsedEntity, RowParser}

  @spec compute(Ecto.UUID.t(), Ecto.UUID.t(), [map()]) :: map()
  def compute(organization_id, version_id, files) do
    {expanded, warnings} = Import.expand_archives(files)

    case categorize(expanded) do
      {:error, duplicates} -> review_with_blockers(duplicates ++ archive_blockers(warnings))
      {:ok, _files} when warnings != [] -> review_with_blockers(archive_blockers(warnings))
      {:ok, categorized} -> parsed_review(organization_id, version_id, categorized)
    end
  end

  defp parsed_review(organization_id, version_id, categorized) do
    levels =
      parse(categorized.levels, :level, "levels.txt", :level_id, organization_id, version_id, %{})

    stops =
      parse(categorized.stops, :stop, "stops.txt", :stop_id, organization_id, version_id, %{})

    db_stops = Gtfs.list_stops(organization_id, version_id)
    validation = stop_validation_map(db_stops, stops)

    pathways =
      parse(
        categorized.pathways,
        :pathway,
        "pathways.txt",
        :pathway_id,
        organization_id,
        version_id,
        validation
      )

    uploaded = %{levels: levels, stops: stops, pathways: pathways}

    db = %{
      levels: Gtfs.list_levels(organization_id, version_id),
      stops: db_stops,
      pathways: Gtfs.list_pathways(organization_id, version_id)
    }

    result = Diff.compute(uploaded, db)
    applicable = Enum.map(result.applicable, &sanitize_decision/1)

    preview =
      result.preview |> Enum.map(&%{&1 | status: :preview}) |> Enum.map(&sanitize_decision/1)

    %{
      decisions: applicable ++ preview,
      summary:
        Map.merge(Diff.summary(applicable), %{
          applicable: length(applicable),
          preview: length(preview)
        }),
      diagnostics: diagnostics([levels, stops, pathways])
    }
  end

  defp parse(file, :level, name, key, organization_id, version_id, _validation) do
    ParsedEntity.parse(
      file,
      :level,
      name,
      key,
      &RowParser.level_row_to_attrs(&1, organization_id, version_id)
    )
  end

  defp parse(file, :stop, name, key, organization_id, version_id, _validation) do
    ParsedEntity.parse(
      file,
      :stop,
      name,
      key,
      &RowParser.stop_row_to_attrs(&1, organization_id, version_id)
    )
  end

  defp parse(file, :pathway, name, key, organization_id, version_id, validation) do
    ParsedEntity.parse(
      file,
      :pathway,
      name,
      key,
      &RowParser.pathway_row_to_attrs(&1, organization_id, version_id, validation)
    )
  end

  defp review_with_blockers(blockers) do
    %{
      decisions: [],
      summary: %{applicable: 0, preview: 0, add: 0, modify: 0, remove: 0, conflict: 0},
      diagnostics: Enum.take(blockers, 100)
    }
  end

  defp categorize(files) do
    grouped = Enum.reduce(files, %{levels: [], stops: [], pathways: []}, &group_file/2)

    duplicates =
      grouped
      |> Enum.flat_map(fn {type, grouped_files} ->
        if length(grouped_files) > 1,
          do: [%{code: "duplicate_entity_file", detail: Atom.to_string(type)}],
          else: []
      end)

    if duplicates == [] do
      {:ok, Map.new(grouped, fn {type, grouped_files} -> {type, List.first(grouped_files)} end)}
    else
      {:error, duplicates}
    end
  end

  defp group_file(file, grouped) do
    normalized = %{file | filename: file.filename |> Path.basename() |> String.downcase()}

    case normalized.filename do
      "levels.txt" -> Map.update!(grouped, :levels, &[normalized | &1])
      "stops.txt" -> Map.update!(grouped, :stops, &[normalized | &1])
      "pathways.txt" -> Map.update!(grouped, :pathways, &[normalized | &1])
      _ -> grouped
    end
  end

  defp archive_blockers(warnings) do
    Enum.map(warnings, fn warning ->
      %{code: archive_code(warning.reason), detail: warning.filename}
    end)
  end

  defp archive_code(:archive_too_large), do: "archive_too_large"
  defp archive_code(:nested_archive), do: "nested_archive"
  defp archive_code(_), do: "archive_unreadable"

  defp diagnostics(results) do
    results
    |> Enum.flat_map(fn
      {:error, %ParseFailure{} = failure} ->
        Enum.map(failure.diagnostics, &diagnostic/1)

      _ ->
        []
    end)
    |> Enum.take(100)
  end

  defp diagnostic(%ParseError{} = error) do
    %{code: Atom.to_string(error.reason), detail: error.file, natural_key: nil, entity_type: nil}
  end

  defp stop_validation_map(db_stops, stops) do
    uploaded =
      case stops do
        {:ok, parsed} -> parsed |> ParsedEntity.records_by_key() |> Map.keys()
        {:error, failure} -> Map.keys(failure.preview_records_by_key)
        :not_uploaded -> []
      end

    (Enum.map(db_stops, & &1.stop_id) ++ uploaded)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Map.new(&{&1, true})
  end

  defp sanitize_decision(%{uploaded_attrs: attrs} = decision) when is_map(attrs) do
    allowed =
      case decision.entity_type do
        :level ->
          [:level_index, :level_name]

        :stop ->
          [
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

        :pathway ->
          [
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
      end

    %{decision | uploaded_attrs: Map.take(attrs, allowed)}
  end

  defp sanitize_decision(decision), do: decision
end
