defmodule GtfsPlanner.Gtfs.Schedules.Summary do
  @moduledoc """
  Pure planning summaries for one route's timetable.

  Every time is an integer second parsed by `GtfsPlanner.Gtfs.GtfsTime`; this
  module never reads the database and never parses stored clock strings itself.
  Trips whose first departure or last arrival is missing or unparseable are
  filtered by the caller before their spans or departures reach these functions.

  `peak_vehicles/1` counts the maximum number of half-open spans covering any
  instant, so a trip ending at 07:00 shares a vehicle with one starting at 07:00.
  A frequency template expands to one span per departure at `start + k · headway`
  while the departure is before the window end, each lasting the template's own
  duration, whether or not `exact_times` is set: the concurrent count depends only
  on duration and headway.
  """

  @seconds_per_minute 60
  @band_tolerance_seconds 60
  @band_tolerance_ratio 0.1
  @minimum_band_trips 3

  @typedoc """
  A trip span `[start_secs, end_secs)`; a zero-length span covers no instant.

  A span carrying `:headway_secs` and `:until_secs` is a frequency template: it
  expands to one span per departure at `start_secs + k · headway_secs` while the
  departure is before `until_secs`, each lasting `end_secs - start_secs`.
  """
  @type span :: %{
          required(:start_secs) => non_neg_integer(),
          required(:end_secs) => non_neg_integer(),
          optional(:headway_secs) => pos_integer(),
          optional(:until_secs) => non_neg_integer()
        }

  @typedoc "One frequencies.txt window reduced to integer seconds."
  @type frequency_window :: %{
          start_secs: non_neg_integer(),
          until_secs: non_neg_integer(),
          headway_secs: pos_integer()
        }

  @typedoc """
  One departure band.

  `:scheduled` bands carry the minimum and maximum of their headways rounded to
  whole minutes; `:irregular` bands have no headway; `:frequency` bands carry the
  window's headway rounded to whole minutes in both fields.
  """
  @type band :: %{
          kind: :scheduled | :irregular | :frequency,
          first_secs: non_neg_integer(),
          last_secs: non_neg_integer(),
          trip_count: non_neg_integer(),
          min_headway_minutes: non_neg_integer() | nil,
          max_headway_minutes: non_neg_integer() | nil
        }

  @typedoc "One hour's first-departure count and whether any of them is frequency-based."
  @type hour_count :: {non_neg_integer(), non_neg_integer(), boolean()}

  @typedoc "Minutes between displayed columns and the full first-to-last duration."
  @type segments :: %{segments: [integer()], total_secs: integer()}

  @doc """
  Counts the fewest vehicles that can run the spans with zero layover.

  Returns the maximum number of half-open spans covering any instant and the
  earliest instant where that maximum is reached. An empty list gives
  `%{count: 0, at_secs: nil}`.
  """
  @spec peak_vehicles([span()]) :: %{count: non_neg_integer(), at_secs: non_neg_integer() | nil}
  def peak_vehicles(spans) when is_list(spans) do
    events =
      spans
      |> Enum.flat_map(&expand_span/1)
      |> Enum.flat_map(fn {start_secs, end_secs} ->
        if end_secs > start_secs, do: [{start_secs, 1}, {end_secs, -1}], else: []
      end)
      |> Enum.sort()

    {count, at_secs, _in_service} =
      Enum.reduce(events, {0, nil, 0}, fn {instant, delta}, {count, at_secs, in_service} ->
        in_service = in_service + delta

        if in_service > count do
          {in_service, instant, in_service}
        else
          {count, at_secs, in_service}
        end
      end)

    %{count: count, at_secs: at_secs}
  end

  @doc """
  Builds the headway bands for one pattern section.

  `departures` are the section's scheduled first departures in seconds and
  `frequencies` are its frequencies.txt windows. A band's fixed reference headway
  is the first gap inside the run, so bands cannot drift; consecutive irregular
  departures merge into one irregular band. Frequency windows become their own
  bands, ordered in time with the scheduled bands. Bands partition the scheduled
  departures, so their trip counts add up to the section total.
  """
  @spec headway_bands([non_neg_integer()], [frequency_window()]) :: [band()]
  def headway_bands(departures, frequencies) when is_list(departures) and is_list(frequencies) do
    departures
    |> Enum.sort()
    |> scheduled_bands()
    |> Kernel.++(Enum.map(frequencies, &frequency_band/1))
    |> Enum.sort_by(& &1.first_secs)
  end

  @doc """
  Counts first departures per hour for the direction in view.

  Emits every hour from the first to the last, including zero hours and hours at
  or beyond 24 for after-midnight service. An hour is approximate when any
  departure counted in it comes from a frequency window.
  """
  @spec trips_per_hour([non_neg_integer()], [frequency_window()]) :: [hour_count()]
  def trips_per_hour(departures, frequencies) when is_list(departures) and is_list(frequencies) do
    starts = collect_starts(departures, frequencies)

    case starts do
      [] -> []
      _ -> start_hours(starts)
    end
  end

  defp collect_starts(departures, frequencies) do
    Enum.map(departures, &{&1, false}) ++
      Enum.flat_map(frequencies, fn window ->
        Enum.map(frequency_departures(window), &{&1, true})
      end)
  end

  defp start_hours(starts) do
    grouped = Enum.group_by(starts, fn {secs, _approximate?} -> div(secs, 3600) end)
    hours = Map.keys(grouped)

    Enum.map(Enum.min(hours)..Enum.max(hours), fn hour ->
      hour_count(Map.get(grouped, hour, []), hour)
    end)
  end

  defp hour_count(departures, hour) do
    {hour, length(departures),
     Enum.any?(departures, fn {_secs, approximate?} -> approximate? end)}
  end

  @doc """
  Computes the minutes between displayed columns for one timing.

  `timing_rows` are the timing's rows in occurrence order, each carrying its
  `:position` plus its `:arrival_offset` and `:departure_offset`; `columns` are the
  displayed timetable columns carrying `:position`. A segment is the arrival
  offset at one column minus the departure offset at the previous one, so a dwell
  at the earlier column is excluded. The total is the last column's arrival offset
  minus the first column's departure offset, so it includes dwell.
  """
  @spec timing_segments([map()], [map()]) :: segments()
  def timing_segments(timing_rows, columns) when is_list(timing_rows) and is_list(columns) do
    rows_by_position = Map.new(timing_rows, fn row -> {Map.fetch!(row, :position), row} end)

    points =
      columns
      |> Enum.map(&Map.get(rows_by_position, Map.fetch!(&1, :position)))
      |> Enum.reject(&is_nil/1)

    segments =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [previous, current] ->
        current.arrival_offset - previous.departure_offset
      end)

    total_secs =
      case points do
        [] -> 0
        [first | _] -> List.last(points).arrival_offset - first.departure_offset
      end

    %{segments: segments, total_secs: total_secs}
  end

  defp expand_span(%{start_secs: start_secs, end_secs: end_secs} = span) do
    case Map.get(span, :headway_secs) do
      headway_secs when is_integer(headway_secs) and headway_secs > 0 ->
        until_secs = Map.get(span, :until_secs) || end_secs
        duration = end_secs - start_secs

        if until_secs > start_secs do
          frequency_starts(start_secs, until_secs, headway_secs)
          |> Enum.map(&{&1, &1 + duration})
        else
          []
        end

      _ ->
        [{start_secs, end_secs}]
    end
  end

  defp frequency_starts(start_secs, until_secs, headway_secs) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&(start_secs + &1 * headway_secs))
    |> Enum.take_while(&(&1 < until_secs))
  end

  defp frequency_departures(%{
         start_secs: start_secs,
         until_secs: until_secs,
         headway_secs: headway_secs
       }) do
    frequency_starts(start_secs, until_secs, headway_secs)
  end

  defp scheduled_bands(departures), do: collect_bands(departures, [], [])

  defp collect_bands([], pending, bands), do: Enum.reverse(flush_irregular(pending) ++ bands)

  defp collect_bands(departures, pending, bands) do
    if length(departures) < @minimum_band_trips do
      collect_bands([], pending ++ departures, bands)
    else
      [first, second | _] = departures
      reference = second - first
      tolerance = band_tolerance(reference)
      run_length = run_length(departures, reference, tolerance)

      if run_length >= @minimum_band_trips do
        {run, rest} = Enum.split(departures, run_length)
        band = scheduled_band(run)
        collect_bands(rest, [], [band | flush_irregular(pending) ++ bands])
      else
        collect_bands(tl(departures), pending ++ [first], bands)
      end
    end
  end

  # The reference headway stays fixed for the whole run, so a band cannot drift.
  defp band_tolerance(reference) do
    max(@band_tolerance_seconds, reference * @band_tolerance_ratio)
  end

  defp run_length(departures, reference, tolerance) do
    departures
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [earlier, later] -> later - earlier end)
    |> Enum.reduce_while(1, fn headway, run_length ->
      if abs(headway - reference) <= tolerance do
        {:cont, run_length + 1}
      else
        {:halt, run_length}
      end
    end)
  end

  defp scheduled_band([first | _] = run) do
    headways =
      run
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [earlier, later] -> later - earlier end)

    %{
      kind: :scheduled,
      first_secs: first,
      last_secs: List.last(run),
      trip_count: length(run),
      min_headway_minutes: round(Enum.min(headways) / @seconds_per_minute),
      max_headway_minutes: round(Enum.max(headways) / @seconds_per_minute)
    }
  end

  defp flush_irregular([]), do: []

  defp flush_irregular(departures) do
    [
      %{
        kind: :irregular,
        first_secs: hd(departures),
        last_secs: List.last(departures),
        trip_count: length(departures),
        min_headway_minutes: nil,
        max_headway_minutes: nil
      }
    ]
  end

  defp frequency_band(%{
         start_secs: start_secs,
         until_secs: until_secs,
         headway_secs: headway_secs
       }) do
    headway_minutes = round(headway_secs / @seconds_per_minute)

    %{
      kind: :frequency,
      first_secs: start_secs,
      last_secs: until_secs,
      trip_count: length(frequency_starts(start_secs, until_secs, headway_secs)),
      min_headway_minutes: headway_minutes,
      max_headway_minutes: headway_minutes
    }
  end
end
