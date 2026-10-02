defmodule GtfsPlanner.Gtfs.Export.MissingTimes do
  @moduledoc """
  Record adapter between exported stop-time rows and `StopTimeEstimator`
  (spec 23-stop-time-interpolation, R8–R10).

  Every estimation rule lives in `StopTimeEstimator`; this module only
  translates record inputs and outputs (criteria "One rule core"). It never
  writes `stop_times` rows: `fill_trip/3` transforms in-memory records,
  `stop_coordinates/2` only reads stops, and `summary/2` only reads
  stop times, trips and routes (INV-1). `stop_coordinates/2` and `summary/2`
  are scoped to one organization and version (INV-2).
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.Export.StreamBuilder
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.StopTimeEstimator
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values

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
    case classify(records, method, coords) do
      :unchanged ->
        {records, :unchanged}

      {:filled, out_rows} ->
        {apply_estimates(records, out_rows), :filled}

      {:not_estimated, problems} ->
        {records, {:not_estimated, not_estimated_warning(records, problems)}}
    end
  end

  @doc """
  Caps missing-times warnings at `limit` entries (100 by default): the first
  `limit - 1` stay actionable and one `missing_times_not_estimated_more`
  summary names the rest. A limit of zero or less leaves no room.
  """
  @spec cap_warnings([warning()], integer()) :: [warning()]
  def cap_warnings(warnings, limit \\ @max_warnings)

  def cap_warnings(_warnings, limit) when limit <= 0, do: []

  def cap_warnings(warnings, limit) when is_list(warnings) do
    if length(warnings) > limit do
      remaining = length(warnings) - (limit - 1)

      Enum.take(warnings, limit - 1) ++
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

  @doc "Whether `warning` is a per-trip `missing_times_not_estimated` warning."
  @spec warning?(map()) :: boolean()
  def warning?(%{code: "missing_times_not_estimated"}), do: true
  def warning?(_warning), do: false

  # The single classifier behind `fill_trip/3` and `summary/2` (criteria
  # "One classifier"): a trip with no blank cell is `:unchanged` without
  # touching the estimator, otherwise the estimator verdict decides `:filled`
  # versus `{:not_estimated, problems}` with `distances: :strict` and the
  # given stop coordinates, exactly as the export uses it.
  defp classify([], _method, _coords), do: :unchanged

  defp classify(records, method, coords) do
    if Enum.all?(records, &complete?/1) do
      :unchanged
    else
      rows = Enum.map(records, &estimator_row(&1, coords))

      %{rows: out_rows, problems: problems} =
        StopTimeEstimator.estimate(rows, method: method, distances: :strict)

      if problems == [], do: {:filled, out_rows}, else: {:not_estimated, problems}
    end
  end

  @doc """
  Returns the primary not-estimable reason for one trip's stop-time records,
  or nil when the trip needs no estimate or can be estimated.

  Uses the same shared `classify` verdict behind `fill_trip/3` (criteria
  "One classifier"), so display callers such as the Schedules timetable name
  the same reason the export warning reports first. Only reads; never writes
  `stop_times` (INV-1).
  """
  @spec estimate_problem([struct() | map()], :distance | :even, coords()) ::
          nil | :no_first_time | :no_last_time | :timepoint_without_time | :order
  def estimate_problem(records, method, coords) do
    case classify(records, method, coords) do
      {:not_estimated, problems} -> primary_reason(problems)
      _ -> nil
    end
  end

  @doc """
  Counts a version's missing stop times and classifies trips exactly as the
  export does (spec 23, AC-16).

  Trips are selected by one query for `trip_id`s with a blank time through
  the same organization, version and inactive-route-closure filters
  `StreamBuilder.stream_records/4` applies to `StopTime`; each selected trip
  is classified with the shared `classify` verdict behind `fill_trip/3`
  using the method from `ExportDefaults.get/1`. `missing_times` and
  `estimable_times` count blank arrival/departure cells, so every blank cell
  of a filled trip is an estimable time. `straight_line?` is true for a
  route with a blank cell on a row without a stored distance, whose span
  therefore cannot use stored distances (R5). Only reads; never writes
  `stop_times` (INV-1).
  """
  @spec summary(Ecto.UUID.t(), Ecto.UUID.t()) :: %{
          trips: non_neg_integer(),
          missing_times: non_neg_integer(),
          estimable_trips: non_neg_integer(),
          estimable_times: non_neg_integer(),
          not_estimable: [
            %{
              trip_id: String.t(),
              route_id: String.t(),
              service_id: String.t(),
              first_departure: String.t() | nil,
              reason: :no_first_time | :no_last_time | :timepoint_without_time | :order
            }
          ],
          routes: [
            %{
              route_id: String.t(),
              route_short_name: String.t() | nil,
              route_long_name: String.t() | nil,
              route_color: String.t() | nil,
              trips: non_neg_integer(),
              missing_times: non_neg_integer(),
              straight_line?: boolean()
            }
          ]
        }
  def summary(organization_id, gtfs_version_id) do
    method = ExportDefaults.get(organization_id).estimate_method
    coords = stop_coordinates(organization_id, gtfs_version_id)

    case blank_trip_ids(organization_id, gtfs_version_id) do
      [] -> empty_summary()
      trip_ids -> build_summary(organization_id, gtfs_version_id, trip_ids, method, coords)
    end
  end

  defp complete?(record) do
    Values.present?(Map.get(record, :arrival_time)) and
      Values.present?(Map.get(record, :departure_time))
  end

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
    if Values.present?(stored), do: stored, else: format_or_nil(seconds)
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

  defp empty_summary do
    %{
      trips: 0,
      missing_times: 0,
      estimable_trips: 0,
      estimable_times: 0,
      not_estimable: [],
      routes: []
    }
  end

  # Trip IDs with a blank arrival or departure cell, through the same
  # organization, version and inactive-route-closure filters the export
  # applies to `StopTime`; `exclude_inactive/4` is already public, so no
  # `StreamBuilder` change is needed. Stored blanks are NULL or "" (writes
  # trim strings); the query uses the `:row` binding the filter requires.
  defp blank_trip_ids(organization_id, gtfs_version_id) do
    from(s in StopTime,
      as: :row,
      where: s.organization_id == ^organization_id,
      where: s.gtfs_version_id == ^gtfs_version_id,
      where:
        is_nil(s.arrival_time) or s.arrival_time == "" or
          is_nil(s.departure_time) or s.departure_time == "",
      select: s.trip_id,
      distinct: true,
      order_by: s.trip_id
    )
    |> StreamBuilder.exclude_inactive(StopTime, organization_id, gtfs_version_id)
    |> Repo.all()
  end

  defp build_summary(organization_id, gtfs_version_id, trip_ids, method, coords) do
    records =
      from(s in StopTime,
        where: s.organization_id == ^organization_id,
        where: s.gtfs_version_id == ^gtfs_version_id,
        where: s.trip_id in ^trip_ids,
        order_by: [asc: s.trip_id, asc: s.stop_sequence]
      )
      |> Repo.all()

    trip_meta =
      from(t in Trip,
        where: t.organization_id == ^organization_id,
        where: t.gtfs_version_id == ^gtfs_version_id,
        where: t.trip_id in ^trip_ids,
        select: {t.trip_id, t.route_id, t.service_id}
      )
      |> Repo.all()
      |> Map.new(fn {trip_id, route_id, service_id} ->
        {trip_id, %{route_id: route_id, service_id: service_id}}
      end)

    route_meta =
      trip_meta
      |> Map.values()
      |> Enum.map(& &1.route_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> case do
        [] ->
          %{}

        route_ids ->
          from(r in Route,
            where: r.organization_id == ^organization_id,
            where: r.gtfs_version_id == ^gtfs_version_id,
            where: r.route_id in ^route_ids,
            select: {r.route_id, r.route_short_name, r.route_long_name, r.route_color}
          )
          |> Repo.all()
          |> Map.new(fn {route_id, short, long, color} ->
            {route_id,
             %{
               route_short_name: short,
               route_long_name: long,
               route_color: color
             }}
          end)
      end

    by_trip = Enum.group_by(records, & &1.trip_id)

    classified =
      Enum.map(trip_ids, fn trip_id ->
        trip_records =
          by_trip |> Map.fetch!(trip_id) |> Enum.sort_by(& &1.stop_sequence)

        {trip_id, trip_records, blank_cells(trip_records), classify(trip_records, method, coords)}
      end)

    not_estimable =
      for {trip_id, trip_records, _blanks, {:not_estimated, problems}} <- classified do
        meta = Map.get(trip_meta, trip_id, %{route_id: nil, service_id: nil})

        %{
          trip_id: trip_id,
          route_id: meta.route_id,
          service_id: meta.service_id,
          first_departure: first_departure(trip_records),
          reason: primary_reason(problems)
        }
      end

    {estimable_trips, estimable_times} =
      Enum.reduce(classified, {0, 0}, fn
        {_trip_id, _records, blanks, {:filled, _}}, {trips, times} ->
          {trips + 1, times + blanks}

        {_trip_id, _records, _blanks, _status}, acc ->
          acc
      end)

    routes =
      classified
      |> Enum.group_by(fn {trip_id, _records, _blanks, _status} ->
        Map.get(trip_meta, trip_id, %{route_id: nil}) |> Map.get(:route_id)
      end)
      |> Enum.reject(fn {route_id, _} -> is_nil(route_id) end)
      |> Enum.map(fn {route_id, group} ->
        meta =
          Map.get(route_meta, route_id, %{
            route_short_name: nil,
            route_long_name: nil,
            route_color: nil
          })

        %{
          route_id: route_id,
          route_short_name: meta.route_short_name,
          route_long_name: meta.route_long_name,
          route_color: meta.route_color,
          trips: length(group),
          missing_times:
            Enum.sum(Enum.map(group, fn {_id, _records, blanks, _status} -> blanks end)),
          straight_line?:
            Enum.any?(group, fn {_id, trip_records, _blanks, _status} ->
              Enum.any?(trip_records, &blank_without_distance?/1)
            end)
        }
      end)
      |> Enum.sort_by(& &1.route_id)

    %{
      trips: length(classified),
      missing_times:
        Enum.sum(Enum.map(classified, fn {_id, _records, blanks, _status} -> blanks end)),
      estimable_trips: estimable_trips,
      estimable_times: estimable_times,
      not_estimable: not_estimable,
      routes: routes
    }
  end

  defp blank_cells(records) do
    Enum.sum(
      Enum.map(records, fn record ->
        if(Values.present?(Map.get(record, :arrival_time)), do: 0, else: 1) +
          if Values.present?(Map.get(record, :departure_time)), do: 0, else: 1
      end)
    )
  end

  defp blank_without_distance?(record) do
    (not Values.present?(Map.get(record, :arrival_time)) or
       not Values.present?(Map.get(record, :departure_time))) and
      is_nil(Map.get(record, :shape_dist_traveled))
  end

  defp first_departure(records) do
    case records |> List.first() |> Map.get(:departure_time) do
      nil -> nil
      "" -> nil
      departure -> departure
    end
  end

  # The first estimator problem decides the summary reason, matching the
  # order `fill_trip/3` reports them in its warning (`classify` guarantees a
  # non-empty list here).
  defp primary_reason([first | _]), do: problem_reason(first)

  defp problem_reason({:no_first_time, _}), do: :no_first_time
  defp problem_reason({:no_last_time, _}), do: :no_last_time
  defp problem_reason({:timepoint_without_time, _}), do: :timepoint_without_time
  defp problem_reason({:order, _, _}), do: :order
end
