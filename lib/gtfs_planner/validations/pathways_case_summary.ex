defmodule GtfsPlanner.Validations.PathwaysCaseSummary do
  @moduledoc """
  Shared, pure helpers for pathways case status classification and
  trip-level status aggregation.
  """

  @type case_status :: String.t()

  @type trip_overview :: %{
          total_tests: non_neg_integer(),
          pass_count: non_neg_integer(),
          warning_count: non_neg_integer(),
          fail_count: non_neg_integer()
        }

  @spec case_display_status(map()) :: case_status
  def case_display_status(row) when is_map(row) do
    mismatch_map = mismatch_map(Map.get(row, :details_json))

    traversable_failed? = Map.has_key?(mismatch_map, "expected_traversable")

    other_criteria_failed? =
      mismatch_map
      |> Map.drop(["expected_traversable"])
      |> map_has_entries?()

    failure_category = normalize_failure_category(Map.get(row, :failure_category))

    cond do
      failure_category == "query_failure" -> "failed"
      traversable_failed? -> "failed"
      other_criteria_failed? -> "warning"
      true -> "pass"
    end
  end

  def case_display_status(_row), do: "pass"

  @spec trip_overview([map()]) :: trip_overview
  def trip_overview(pathways_case_results) when is_list(pathways_case_results) do
    Enum.reduce(
      pathways_case_results,
      %{total_tests: 0, pass_count: 0, warning_count: 0, fail_count: 0},
      fn row, acc ->
        status = case_display_status(row)

        acc
        |> Map.update!(:total_tests, &(&1 + 1))
        |> increment_trip_status(status)
      end
    )
  end

  def trip_overview(_pathways_case_results) do
    %{total_tests: 0, pass_count: 0, warning_count: 0, fail_count: 0}
  end

  defp increment_trip_status(acc, "pass"), do: Map.update!(acc, :pass_count, &(&1 + 1))
  defp increment_trip_status(acc, "warning"), do: Map.update!(acc, :warning_count, &(&1 + 1))
  defp increment_trip_status(acc, "failed"), do: Map.update!(acc, :fail_count, &(&1 + 1))
  defp increment_trip_status(acc, _status), do: acc

  defp mismatch_map(details_json) when is_map(details_json) do
    details_json
    |> map_value(:mismatches)
    |> ensure_list()
    |> Enum.reduce(%{}, fn mismatch, acc ->
      case mismatch_kind(mismatch) do
        nil -> acc
        kind -> Map.put(acc, kind, mismatch)
      end
    end)
  end

  defp mismatch_map(_details_json), do: %{}

  defp mismatch_kind(mismatch) when is_map(mismatch) do
    case map_value(mismatch, :kind) do
      kind when is_atom(kind) -> Atom.to_string(kind)
      kind when is_binary(kind) -> kind
      _other -> nil
    end
  end

  defp mismatch_kind(_mismatch), do: nil

  defp map_value(map, key) when is_map(map) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp map_value(_map, _key), do: nil

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_value), do: []

  defp map_has_entries?(map) when is_map(map), do: map_size(map) > 0
  defp map_has_entries?(_map), do: false

  defp normalize_failure_category(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_failure_category(value) when is_binary(value), do: value
  defp normalize_failure_category(_value), do: nil
end
