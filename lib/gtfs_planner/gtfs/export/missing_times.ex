defmodule GtfsPlanner.Gtfs.Export.MissingTimes do
  @moduledoc """
  Record adapter between exported stop-time rows and `StopTimeEstimator`
  (spec 23-stop-time-interpolation, R8–R10).

  Every estimation rule lives in `StopTimeEstimator`; this module only
  translates record inputs and outputs (criteria "One rule core"). It never
  writes `stop_times` rows: `fill_trip/3` transforms in-memory records and
  `stop_coordinates/2` only reads stops (INV-1). `stop_coordinates/2` is
  scoped to one organization and version (INV-2).
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTimeEstimator
  alias GtfsPlanner.Repo

  @max_warnings 100

  @type coords :: %{String.t() => {float(), float()}}
  @type warning :: GtfsPlanner.Gtfs.Export.warning()

  @doc """
  Returns natural `stop_id => {lat, lon}` coordinates for one organization
  and version, skipping stops without coordinates.
  """
  @spec stop_coordinates(Ecto.UUID.t(), Ecto.UUID.t()) :: coords()
  def stop_coordinates(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: {s.stop_id, s.stop_lat, s.stop_lon}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn
      {_stop_id, nil, _lon}, acc ->
        acc

      {_stop_id, _lat, nil}, acc ->
        acc

      {stop_id, lat, lon}, acc ->
        Map.put(acc, stop_id, {to_float(lat), to_float(lon)})
    end)
  end

  @doc """
  Fills one trip's stop-time records (ordered by `stop_sequence`) in memory.

  A trip with no blank row returns its records identically with `:unchanged`
  without calling the estimator. Otherwise estimator rows are built with
  `distances: :strict` and stop coordinates from `coords`:

  - no problems: blank runs are filled with `GtfsTime.format/1` strings,
    filled rows get `timepoint = 0`, timed rows with a nil flag get `1`, and
    every other field stays as stored (`:filled`);
  - any problem: the records return unchanged with one
    `missing_times_not_estimated` warning naming the trip and reason
    (`{:not_estimated, warning}`).
  """
  @spec fill_trip([struct() | map()], :distance | :even, coords()) ::
          {[struct() | map()], :unchanged | :filled | {:not_estimated, warning()}}
  def fill_trip([], _method, _coords), do: {[], :unchanged}

  def fill_trip(records, method, coords) do
    if Enum.all?(records, &complete?/1) do
      {records, :unchanged}
    else
      rows = Enum.map(records, &estimator_row(&1, coords))

      %{rows: out_rows, problems: problems} =
        StopTimeEstimator.estimate(rows, method: method, distances: :strict)

      case problems do
        [] -> {apply_estimates(records, out_rows), :filled}
        _ -> {records, {:not_estimated, not_estimated_warning(records, problems)}}
      end
    end
  end

  @doc """
  Caps missing-times warnings at 100 entries: the first 99 stay actionable
  and one `missing_times_not_estimated_more` summary names the rest.
  """
  @spec cap_warnings([warning()]) :: [warning()]
  def cap_warnings(warnings) when is_list(warnings) do
    if length(warnings) > @max_warnings do
      remaining = length(warnings) - (@max_warnings - 1)

      Enum.take(warnings, @max_warnings - 1) ++
        [
          %{
            code: "missing_times_not_estimated_more",
            detail:
              "#{remaining} more trips with missing times were left blank. Fix timepoint times or add times at the first and last stops.",
            file: "stop_times.txt",
            entity_type: "trip"
          }
        ]
    else
      warnings
    end
  end

  defp complete?(record) do
    present?(Map.get(record, :arrival_time)) and present?(Map.get(record, :departure_time))
  end

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  defp estimator_row(record, coords) do
    %{
      arrival: parse_time(Map.get(record, :arrival_time)),
      departure: parse_time(Map.get(record, :departure_time)),
      timepoint: Map.get(record, :timepoint),
      distance: Map.get(record, :shape_dist_traveled),
      coord: coords[Map.get(record, :stop_id)]
    }
  end

  defp parse_time(nil), do: nil
  defp parse_time(""), do: nil

  defp parse_time(value) when is_binary(value) do
    case value |> String.trim() |> GtfsTime.parse() do
      {:ok, seconds} -> seconds
      {:error, _} -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp apply_estimates(records, out_rows) do
    records
    |> Enum.zip(out_rows)
    |> Enum.map(fn {record, out} -> apply_estimate(record, out) end)
  end

  # Filled rows get formatted times on both sides with timepoint 0 (R3, R8).
  defp apply_estimate(record, %{estimated?: true} = out) do
    record
    |> Map.put(:arrival_time, GtfsTime.format(out.arrival))
    |> Map.put(:departure_time, GtfsTime.format(out.departure))
    |> Map.put(:timepoint, 0)
  end

  # Kept rows are written as stored, except the R1 one-sided copy and the
  # nil-flag normalization to 1 (R8).
  defp apply_estimate(record, out) do
    record
    |> Map.put(:arrival_time, keep_or_copy(Map.get(record, :arrival_time), out.arrival))
    |> Map.put(:departure_time, keep_or_copy(Map.get(record, :departure_time), out.departure))
    |> Map.put(:timepoint, keep_or_normalize_flag(Map.get(record, :timepoint)))
  end

  defp keep_or_copy(stored, seconds) do
    if present?(stored), do: stored, else: format_or_nil(seconds)
  end

  defp format_or_nil(nil), do: nil
  defp format_or_nil(seconds), do: GtfsTime.format(seconds)

  defp keep_or_normalize_flag(nil), do: 1
  defp keep_or_normalize_flag(flag), do: flag

  defp not_estimated_warning(records, problems) do
    trip_id = records |> List.first() |> Map.get(:trip_id)

    %{
      code: "missing_times_not_estimated",
      detail:
        "Trip #{inspect(trip_id)} was left blank: #{Enum.map_join(problems, "; ", &reason_for(&1, records))}.",
      file: "stop_times.txt",
      entity_type: "trip"
    }
  end

  defp reason_for({:no_first_time, _index}, _records), do: "the first stop has no time"

  defp reason_for({:no_last_time, _index}, _records), do: "the last stop has no time"

  defp reason_for({:timepoint_without_time, index}, records) do
    "the stop at stop_sequence #{sequence_at(records, index)} is a timepoint without times"
  end

  defp reason_for({:order, from, to}, records) do
    "times run backwards between stop_sequence #{sequence_at(records, from)} and stop_sequence #{sequence_at(records, to)}"
  end

  defp sequence_at(records, index) do
    case Enum.at(records, index) do
      nil -> "position #{index + 1}"
      record -> Map.get(record, :stop_sequence, "position #{index + 1}")
    end
  end

  defp to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value / 1
end
