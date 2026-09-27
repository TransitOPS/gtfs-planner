defmodule GtfsPlanner.Gtfs.Schedules.Timetable do
  @timepoint_fallback_columns 12

  @moduledoc """
  Pure view model for one pattern's timetable on one calendar and direction.

  `build/5` turns the rows a schedule read already loaded into the columns, rows,
  cells, headway bands and timing lines the Schedules page renders. It reads the
  stored stop times exactly as they are: a cell shows the stored departure (or the
  stored arrival at the last column), never a value recomputed from a timing, so
  the screen and the exported feed stay equal even if an invariant were broken.
  This module reads no database and takes no lock.

  All times are integer seconds parsed by `GtfsPlanner.Gtfs.GtfsTime`; stored clock
  strings may continue past midnight and are never compared or sorted as strings.

  ## Input shapes

    * `pattern` is a `GtfsPlanner.Gtfs.RoutePattern` or an equivalent map. Only its
      `:headsign` is read.
    * `occurrences` are the pattern's ordered `route_pattern_stops`, each carrying
      `:position` and `:stop_id`. A loop keeps one occurrence per visit, so the same
      stop id can appear twice.
    * `stops_by_id` maps `stop_id` to a `GtfsPlanner.Gtfs.Stop` or equivalent map
      with `:stop_name` and optional `:stop_code`.
    * `timings` are the pattern's timings, each with `:id`, `:name`, optional
      `:headsign` and `:rows`. A timing row carries `:position`, `:arrival_offset`,
      `:departure_offset` and `:timepoint`; rows are zipped positionally to the
      occurrences.
    * `trips` are the section's trips, each carrying its ordered `:stop_times` (by
      `:stop_sequence`, then `:id`) and its `:frequencies` rows, plus `:id`,
      `:trip_id`, `:timed_pattern_id`, `:trip_headsign`, `:trip_short_name`,
      `:block_id` and `:updated_at`.

  A trip is linked when its `:timed_pattern_id` names one of the section's timings;
  otherwise it is custom. A linked trip, or a custom trip whose ordered stop ids
  equal the occurrences' stop ids, maps stop time *n* to occurrence *n*. Any other
  custom trip is flagged `stops_differ?: true` with no cells.
  """

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules.Summary

  @seconds_per_day 86_400
  @seconds_per_hour 3_600
  @seconds_per_minute 60

  @typedoc "A pattern occurrence, one per visit and in position order."
  @type occurrence :: %{
          required(:position) => pos_integer(),
          required(:stop_id) => String.t(),
          optional(:id) => term()
        }

  @typedoc "A displayed column: one occurrence with its header text."
  @type column :: %{
          position: pos_integer(),
          stop_id: String.t(),
          stop_name: String.t(),
          stop_code: String.t()
        }

  @typedoc """
  One formatted time cell.

  `:text` is `HH:MM` (with `:SS` only when seconds are nonzero), `:marker` is the
  visible `+N` day marker when `div(secs, 86_400) >= 1`, and `:title` is the
  matching "…, next day" / "…, N days later" label.
  """
  @type cell :: %{
          text: String.t(),
          marker: String.t() | nil,
          title: String.t() | nil,
          missing?: boolean()
        }

  @typedoc "One timetable row."
  @type row :: %{
          id: term(),
          trip_id: String.t() | nil,
          start_secs: non_neg_integer() | nil,
          start_cell: cell(),
          timing: String.t() | :custom,
          headsign: String.t() | nil,
          trip_short_name: String.t() | nil,
          block_id: String.t() | nil,
          trip_headsign: String.t() | nil,
          timed_pattern_id: term(),
          service_id: String.t() | nil,
          direction_id: integer() | nil,
          route_pattern_id: String.t() | nil,
          wheelchair_accessible: integer() | nil,
          bikes_allowed: integer() | nil,
          frequency_label: String.t() | nil,
          frequency?: boolean(),
          custom?: boolean(),
          stops_differ?: boolean(),
          updated_at: term(),
          cells: %{optional(pos_integer()) => cell()}
        }

  @typedoc "One timing used by the section, with its segments for the displayed columns."
  @type timing_line :: %{
          timing_id: term(),
          name: String.t() | nil,
          trip_count: non_neg_integer(),
          segments: [integer()],
          total_secs: integer()
        }

  @typedoc """
  One pattern section.

  `:columns` is the timepoints view, `:all_columns` is every occurrence and
  `:omitted_stop_count` is how many occurrences the timepoints view leaves out.
  `:timing_lines` are computed for `:columns`; a caller showing `:all_columns`
  recomputes them with `Summary.timing_segments/2`.
  """
  @type section :: %{
          pattern: term(),
          columns: [column()],
          all_columns: [column()],
          omitted_stop_count: non_neg_integer(),
          rows: [row()],
          bands: [Summary.band()],
          timing_lines: [timing_line()],
          custom_trip_count: non_neg_integer()
        }

  @doc """
  Builds the section for one pattern from its occurrences, timings and trips.

  The timepoints view keeps the first occurrence, the last occurrence and every
  occurrence the modal timing flags `timepoint == 1`. When nothing is flagged it
  keeps the first `#{@timepoint_fallback_columns - 1}` positions plus the last, or
  every occurrence when there are `#{@timepoint_fallback_columns}` or fewer.
  `all_columns` always keeps every occurrence.
  """
  @spec build(map(), [occurrence()], map(), [map()], [map()]) :: section()
  def build(pattern, occurrences, stops_by_id, timings, trips)
      when is_list(occurrences) and is_list(timings) and is_list(trips) do
    occurrences = Enum.sort_by(occurrences, &Map.fetch!(&1, :position))

    all_columns = Enum.map(occurrences, &column(&1, stops_by_id))

    modal_timing = modal_timing(timings, trips)
    columns = timepoint_columns(all_columns, modal_timing)

    rows =
      trips
      |> Enum.map(&build_row(&1, pattern, occurrences, all_columns, timings))
      |> Enum.sort_by(&row_sort_key/1)

    complete_trips = Enum.filter(trips, &complete_times?/1)

    scheduled_departures =
      for trip <- complete_trips, Map.get(trip, :frequencies, []) == [] do
        trip |> Map.get(:stop_times, []) |> sort_stop_times() |> first_departure()
      end

    frequency_windows = Enum.flat_map(complete_trips, &frequency_windows/1)

    %{
      pattern: pattern,
      columns: columns,
      all_columns: all_columns,
      omitted_stop_count: length(all_columns) - length(columns),
      rows: rows,
      bands: Summary.headway_bands(scheduled_departures, frequency_windows),
      timing_lines: timing_lines(timings, trips, columns),
      custom_trip_count: Enum.count(rows, & &1.custom?)
    }
  end

  defp column(occurrence, stops_by_id) do
    stop_id = Map.fetch!(occurrence, :stop_id)
    stop = Map.get(stops_by_id, stop_id) || %{}

    %{
      position: Map.fetch!(occurrence, :position),
      stop_id: stop_id,
      stop_name: Map.get(stop, :stop_name) || stop_id,
      stop_code: Map.get(stop, :stop_code) || stop_id
    }
  end

  # The timing with the most linked trips wins; ties fall back to the
  # case-insensitive name and then the timing id. With no linked trips, the
  # pattern's first timing by name is the modal one.
  defp modal_timing([], _trips), do: nil

  defp modal_timing(timings, trips) do
    trip_counts =
      trips
      |> Enum.map(&Map.get(&1, :timed_pattern_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    used = Enum.filter(timings, &(Map.get(trip_counts, Map.get(&1, :id), 0) > 0))

    case used do
      [] ->
        Enum.min_by(timings, &timing_sort_key/1)

      used ->
        Enum.min_by(used, fn timing ->
          {-Map.get(trip_counts, Map.get(timing, :id), 0), timing_sort_key(timing)}
        end)
    end
  end

  defp timing_sort_key(timing) do
    {String.downcase(Map.get(timing, :name) || ""), to_string(Map.get(timing, :id))}
  end

  defp timepoint_columns([], _modal_timing), do: []
  defp timepoint_columns(columns, nil), do: fallback_columns(columns)

  defp timepoint_columns(columns, modal_timing) do
    timepoint_positions =
      modal_timing
      |> Map.get(:rows, [])
      |> Enum.filter(&(Map.get(&1, :timepoint) == 1))
      |> Enum.map(&Map.fetch!(&1, :position))
      |> MapSet.new()

    flagged = Enum.filter(columns, &MapSet.member?(timepoint_positions, &1.position))

    case flagged do
      [] ->
        fallback_columns(columns)

      _ ->
        [hd(columns), List.last(columns) | flagged]
        |> Enum.uniq_by(& &1.position)
        |> Enum.sort_by(& &1.position)
    end
  end

  defp fallback_columns(columns) do
    if length(columns) <= @timepoint_fallback_columns do
      columns
    else
      Enum.take(columns, @timepoint_fallback_columns - 1) ++ [List.last(columns)]
    end
  end

  defp build_row(trip, pattern, occurrences, all_columns, timings) do
    stop_times = trip |> Map.get(:stop_times, []) |> sort_stop_times()
    timing = find_timing(trip, timings)
    custom? = is_nil(timing)
    start_secs = first_departure(stop_times)
    frequencies = Map.get(trip, :frequencies, [])

    stops_differ? =
      custom? and occurrences != [] and not compatible?(stop_times, occurrences)

    cells = if stops_differ? or occurrences == [], do: %{}, else: cells(stop_times, all_columns)

    %{
      id: Map.get(trip, :id),
      trip_id: Map.get(trip, :trip_id),
      start_secs: start_secs,
      start_cell: start_cell(start_secs),
      timing: if(custom?, do: :custom, else: Map.get(timing, :name)),
      headsign: display_headsign(trip, timing, pattern),
      trip_short_name: Map.get(trip, :trip_short_name),
      block_id: Map.get(trip, :block_id),
      # The editable source behind the display row: the drawer needs the trip's
      # own fields, not the display substitutions above.
      trip_headsign: Map.get(trip, :trip_headsign),
      timed_pattern_id: Map.get(trip, :timed_pattern_id),
      service_id: Map.get(trip, :service_id),
      direction_id: Map.get(trip, :direction_id),
      route_pattern_id: Map.get(trip, :route_pattern_id),
      wheelchair_accessible: Map.get(trip, :wheelchair_accessible),
      bikes_allowed: Map.get(trip, :bikes_allowed),
      frequency_label: frequency_label(frequencies),
      frequency?: frequencies != [],
      custom?: custom?,
      stops_differ?: stops_differ?,
      updated_at: Map.get(trip, :updated_at),
      cells: cells
    }
  end

  defp find_timing(trip, timings) do
    case Map.get(trip, :timed_pattern_id) do
      nil -> nil
      timed_pattern_id -> Enum.find(timings, &(Map.get(&1, :id) == timed_pattern_id))
    end
  end

  defp sort_stop_times(stop_times) do
    Enum.sort_by(stop_times, &{Map.get(&1, :stop_sequence, 0), Map.get(&1, :id)})
  end

  defp first_departure([]), do: nil

  defp first_departure([first | _]) do
    case GtfsTime.parse(Map.get(first, :departure_time)) do
      {:ok, start_secs} -> start_secs
      {:error, :invalid_time} -> nil
    end
  end

  # Keep incomplete trips visible, but exclude them from planning summaries.
  defp complete_times?(trip) do
    stop_times = trip |> Map.get(:stop_times, []) |> sort_stop_times()

    case stop_times do
      [] ->
        false

      [first | _] ->
        match?({:ok, _}, GtfsTime.parse(Map.get(first, :departure_time))) and
          match?({:ok, _}, GtfsTime.parse(Map.get(List.last(stop_times), :arrival_time)))
    end
  end

  defp compatible?(stop_times, occurrences) do
    Enum.map(stop_times, &Map.get(&1, :stop_id)) ==
      Enum.map(occurrences, &Map.get(&1, :stop_id))
  end

  defp cells(stop_times, all_columns) do
    last_position = all_columns |> List.last() |> Map.fetch!(:position)

    all_columns
    |> Enum.with_index()
    |> Map.new(fn {column, index} ->
      stop_time = Enum.at(stop_times, index)
      {column.position, cell(stop_time, column.position == last_position)}
    end)
  end

  defp cell(nil, _last?), do: missing_cell()

  defp cell(stop_time, last?) do
    value =
      if last?, do: Map.get(stop_time, :arrival_time), else: Map.get(stop_time, :departure_time)

    case GtfsTime.parse(value) do
      {:ok, secs} -> time_cell(secs)
      {:error, :invalid_time} -> missing_cell()
    end
  end

  defp start_cell(nil) do
    %{text: "No time", marker: nil, title: nil, missing?: true}
  end

  defp start_cell(start_secs), do: time_cell(start_secs)

  defp missing_cell, do: %{text: "—", marker: nil, title: nil, missing?: true}

  defp time_cell(secs) do
    days = div(secs, @seconds_per_day)

    %{
      text: clock(secs),
      marker: if(days >= 1, do: "+#{days}", else: nil),
      title: if(days >= 1, do: day_title(secs, days), else: nil),
      missing?: false
    }
  end

  defp clock(secs) do
    base = hhmm(secs)
    seconds = rem(secs, 60)
    if seconds == 0, do: base, else: base <> ":" <> pad(seconds)
  end

  defp hhmm(secs) do
    pad(div(secs, @seconds_per_hour)) <> ":" <> pad(div(rem(secs, @seconds_per_hour), 60))
  end

  defp day_title(secs, days) do
    suffix = if days == 1, do: "next day", else: "#{days} days later"
    human_clock(secs) <> ", " <> suffix
  end

  defp human_clock(secs) do
    hours = div(secs, @seconds_per_hour)
    minutes = div(rem(secs, @seconds_per_hour), 60)
    hour = rem(hours, 24)

    {display_hour, meridiem} =
      cond do
        hour == 0 -> {12, "AM"}
        hour < 12 -> {hour, "AM"}
        hour == 12 -> {12, "PM"}
        true -> {hour - 12, "PM"}
      end

    "#{display_hour}:#{pad(minutes)} #{meridiem}"
  end

  defp display_headsign(trip, timing, pattern) do
    headsign = Map.get(trip, :trip_headsign)
    reference = (timing && Map.get(timing, :headsign)) || Map.get(pattern, :headsign)

    cond do
      headsign in [nil, ""] -> nil
      headsign == reference -> nil
      true -> headsign
    end
  end

  defp frequency_label([]), do: nil

  defp frequency_label(frequencies) do
    frequencies
    |> Enum.sort_by(&frequency_sort_key/1)
    |> Enum.map_join("; ", fn frequency ->
      minutes = round((Map.get(frequency, :headway_secs) || 0) / @seconds_per_minute)

      "Every #{minutes} min, #{hhmm_value(Map.get(frequency, :start_time))}–" <>
        hhmm_value(Map.get(frequency, :end_time))
    end)
  end

  defp frequency_sort_key(frequency) do
    case GtfsTime.parse(Map.get(frequency, :start_time)) do
      {:ok, secs} -> {0, secs, ""}
      {:error, :invalid_time} -> {1, 0, to_string(Map.get(frequency, :start_time))}
    end
  end

  defp hhmm_value(value) do
    case GtfsTime.parse(value) do
      {:ok, secs} -> hhmm(secs)
      {:error, :invalid_time} -> if(is_binary(value), do: value, else: "—")
    end
  end

  defp frequency_windows(trip) do
    for frequency <- Map.get(trip, :frequencies, []),
        {:ok, start_secs} <- [GtfsTime.parse(Map.get(frequency, :start_time))],
        {:ok, until_secs} <- [GtfsTime.parse(Map.get(frequency, :end_time))],
        headway_secs = Map.get(frequency, :headway_secs),
        is_integer(headway_secs) and headway_secs > 0 do
      %{start_secs: start_secs, until_secs: until_secs, headway_secs: headway_secs}
    end
  end

  defp timing_lines(timings, trips, columns) do
    trip_counts =
      trips
      |> Enum.map(&Map.get(&1, :timed_pattern_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    timings
    |> Enum.filter(&(Map.get(trip_counts, Map.get(&1, :id), 0) > 0))
    |> Enum.sort_by(&timing_sort_key/1)
    |> Enum.map(fn timing ->
      segments = Summary.timing_segments(Map.get(timing, :rows, []), columns)

      %{
        timing_id: Map.get(timing, :id),
        name: Map.get(timing, :name),
        trip_count: Map.get(trip_counts, Map.get(timing, :id), 0),
        segments: segments.segments,
        total_secs: segments.total_secs
      }
    end)
  end

  defp row_sort_key(row) do
    {row.start_secs == nil, row.start_secs || 0, row.trip_id}
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
