defmodule GtfsPlanner.Gtfs.TimingFill do
  @moduledoc """
  Pure editor glue between staged timing rows and `StopTimeEstimator`
  (spec 23-stop-time-interpolation, step 11; AC-20, AC-21).

  Every estimation rule lives in `StopTimeEstimator` (criteria "One rule
  core"); this module only translates staged editor values in and out. It is
  pure and never touches the database. `RoutePatternLive` (step 12) owns the
  events, assigns and distance lifecycle.

  Conventions used throughout:

  - Staged rows carry 1-indexed `position` values. All `preview/4` output
    (`rows`, `problems`, `spans`, `fast_spans`) and `retime_candidates/5`
    report positions, except `only_anchor`, which is the estimator's 0-based
    row index passed straight through (callers convert with
    `position - 1`).
  - Staged arrival/departure strings are parsed with
    `GtfsTime.parse_offset/1`. Blank values parse to nil; unparsable values
    are treated as blank for the estimator and additionally reported as
    `:invalid_time` problem entries (advisory only, the fill still runs).
  - The estimator always runs with `distances: :non_decreasing`, so stored
    editor distances may contain 0 m hops and pace (`mph`) is known
    whenever metres are.
  - A preview row is marked `estimated` only when the estimator filled or
    recalculated it to a value that differs from the staged value, so
    `apply_preview/2` never marks an unchanged row estimated (FH-11).
  - The pace check is advisory: spans above 60 mph appear in `fast_spans`
    but never block the fill.
  """

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.StopTimeEstimator
  alias GtfsPlanner.Wording

  @mph_warn 60.0

  @type staged_row :: %{
          required(:position) => pos_integer(),
          required(:arrival) => String.t(),
          required(:departure) => String.t(),
          required(:timepoint) => boolean(),
          required(:estimated) => boolean()
        }

  @type preview_row :: %{
          position: pos_integer(),
          arrival: integer() | nil,
          departure: integer() | nil,
          estimated: boolean(),
          previous: {integer() | nil, integer() | nil}
        }

  @type problem :: %{
          position: pos_integer(),
          kind: :no_first_time | :no_last_time | :timepoint_without_time | :order | :invalid_time,
          message: String.t()
        }

  @type preview_span :: %{
          from_position: pos_integer(),
          to_position: pos_integer(),
          seconds: integer(),
          metres: float() | nil,
          source: :distance | :straight_line | :even,
          mph: float() | nil,
          error: nil | :order | :after_order | :timepoint_without_time
        }

  @type fast_span :: %{
          from_position: pos_integer(),
          to_position: pos_integer(),
          seconds: integer(),
          metres: float() | nil,
          source: :distance | :straight_line | :even,
          mph: float()
        }

  @type preview :: %{
          rows: [preview_row()],
          spans: [preview_span()],
          problems: [problem()],
          changed: non_neg_integer(),
          fast_spans: [fast_span()],
          summary: String.t()
        }

  @doc """
  Returns the scope a fill should open with: `:missing` when any middle
  (non-first, non-last) non-timepoint row lacks a valid arrival or
  departure, else `:between`.
  """
  @spec default_scope([map()]) :: :missing | :between
  def default_scope(rows) do
    count = length(rows)

    missing? =
      rows
      |> Enum.with_index()
      |> Enum.any?(fn {row, index} ->
        index != 0 and index != count - 1 and Map.get(row, :timepoint) == false and
          (missing_value?(Map.get(row, :arrival)) or
             missing_value?(Map.get(row, :departure)))
      end)

    if missing?, do: :missing, else: :between
  end

  @doc """
  Runs the estimator over staged rows and returns the preview.

  `distances` is cumulative metres per visit (step 10
  `Alignments.estimate_distances/1` output) and `coords` is `{lat, lon}`
  tuples or nil per visit; either list may be shorter than `rows` and missing
  entries read as nil. Options are `scope: :missing | :between` (default
  `:missing`), `method: :distance | :even` (default `:distance`) and
  `only_anchor:` (default nil, the estimator's 0-based row index, honored
  only with `scope: :between`).
  """
  @spec preview([map()], [float() | nil], [{float(), float()} | nil], keyword()) ::
          preview()
  def preview(rows, distances, coords, opts \\ []) do
    opts = Keyword.validate!(opts, scope: :missing, method: :distance, only_anchor: nil)
    scope = Keyword.fetch!(opts, :scope)
    method = Keyword.fetch!(opts, :method)
    only_anchor = Keyword.fetch!(opts, :only_anchor)

    parsed = Enum.map(rows, &parse_staged/1)

    estimator_rows =
      parsed
      |> Enum.with_index()
      |> Enum.map(fn {{arrival, departure, _bad}, index} ->
        %{
          arrival: arrival,
          departure: departure,
          timepoint: if(Map.get(Enum.at(rows, index), :timepoint), do: 1, else: 0),
          distance: Enum.at(distances, index),
          coord: Enum.at(coords, index)
        }
      end)

    result =
      StopTimeEstimator.estimate(estimator_rows,
        scope: scope,
        method: method,
        distances: :non_decreasing,
        only_anchor: only_anchor
      )

    preview_rows =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        {arrival, departure, _bad} = Enum.at(parsed, index)
        out = Enum.at(result.rows, index)

        estimated =
          out.estimated? and (out.arrival != arrival or out.departure != departure)

        %{
          position: Map.get(row, :position, index + 1),
          arrival: out.arrival,
          departure: out.departure,
          estimated: estimated,
          previous: out.previous
        }
      end)

    problems =
      invalid_entries(rows, parsed) ++ Enum.map(result.problems, &problem_entry(rows, &1))

    spans = Enum.map(result.spans, &preview_span(rows, &1))

    fast_spans =
      spans
      |> Enum.filter(fn span -> not is_nil(span.mph) and span.mph > @mph_warn end)
      |> Enum.map(fn span ->
        %{
          from_position: span.from_position,
          to_position: span.to_position,
          seconds: span.seconds,
          metres: span.metres,
          source: span.source,
          mph: span.mph
        }
      end)

    changed = Enum.count(preview_rows, & &1.estimated)
    filled_spans = Enum.count(result.spans, &filled_span?(&1, scope, only_anchor))

    %{
      rows: preview_rows,
      spans: spans,
      problems: problems,
      changed: changed,
      fast_spans: fast_spans,
      summary: summary(scope, changed, filled_spans)
    }
  end

  @doc """
  Writes a preview back onto staged rows: rows the preview marks estimated
  get `GtfsTime.format_offset/1` strings and `estimated: true`; every other
  row keeps its staged strings and gets `estimated: false`. All other keys
  on each row are preserved.
  """
  @spec apply_preview([map()], preview()) :: [map()]
  def apply_preview(rows, preview) do
    by_position = Map.new(preview.rows, &{&1.position, &1})

    Enum.map(rows, fn row ->
      case Map.get(by_position, Map.get(row, :position)) do
        %{estimated: true, arrival: arrival, departure: departure}
        when not is_nil(arrival) and not is_nil(departure) ->
          row
          |> Map.put(:arrival, GtfsTime.format_offset(arrival))
          |> Map.put(:departure, GtfsTime.format_offset(departure))
          |> Map.put(:estimated, true)

        _ ->
          Map.put(row, :estimated, false)
      end
    end)
  end

  @doc """
  Compares staged rows before and after a timepoint edit and reports the
  re-estimate candidate: the single changed timepoint row, its signed change
  in seconds, and how many stops a `:between` preview limited to that anchor
  would move. Returns nil when the row count differs, when no timepoint row
  changed, when more than one changed, or when the move cannot be resolved
  to integer times.
  """
  @spec retime_candidates(
          [map()],
          [map()],
          [float() | nil],
          [{float(), float()} | nil],
          keyword()
        ) ::
          %{anchor: pos_integer(), moved_seconds: integer(), stops: non_neg_integer()} | nil
  def retime_candidates(base_rows, edited_rows, distances, coords, opts \\ []) do
    opts = Keyword.validate!(opts, method: :distance)
    method = Keyword.fetch!(opts, :method)

    if method not in [:distance, :even] do
      raise ArgumentError, "method must be one of #{inspect([:distance, :even])}"
    end

    if length(base_rows) != length(edited_rows) or edited_rows == [] do
      nil
    else
      base_times = Enum.map(base_rows, &staged_times/1)
      edited_times = Enum.map(edited_rows, &staged_times/1)

      changed =
        edited_rows
        |> Enum.with_index()
        |> Enum.filter(fn {row, index} ->
          Map.get(row, :timepoint) == true and
            Enum.at(edited_times, index) != Enum.at(base_times, index)
        end)

      case changed do
        [{row, index}] ->
          retime_single_change(
            row,
            index,
            base_times,
            edited_times,
            edited_rows,
            distances,
            coords,
            method
          )

        _ ->
          nil
      end
    end
  end

  defp retime_single_change(
         row,
         index,
         base_times,
         edited_times,
         edited_rows,
         distances,
         coords,
         method
       ) do
    {base_arrival, base_departure} = Enum.at(base_times, index)
    {edited_arrival, edited_departure} = Enum.at(edited_times, index)

    with moved when is_integer(moved) <-
           move_delta(base_arrival, base_departure, edited_arrival, edited_departure),
         true <- moved != 0 do
      sub =
        preview(edited_rows, distances, coords,
          scope: :between,
          method: method,
          only_anchor: index
        )

      %{
        anchor: Map.get(row, :position, index + 1),
        moved_seconds: moved,
        stops: sub.changed
      }
    else
      _ -> nil
    end
  end

  defp missing_value?(value) when is_binary(value) do
    match?({:error, _}, GtfsTime.parse_offset(value))
  end

  defp missing_value?(_value), do: true

  defp parse_staged(row) do
    {arrival, bad_arrival} = parse_cell(Map.get(row, :arrival))
    {departure, bad_departure} = parse_cell(Map.get(row, :departure))
    {arrival, departure, bad_arrival ++ bad_departure}
  end

  defp parse_cell(nil), do: {nil, []}
  defp parse_cell(""), do: {nil, []}

  defp parse_cell(value) when is_binary(value) do
    case GtfsTime.parse_offset(value) do
      {:ok, seconds} -> {seconds, []}
      {:error, _} -> {nil, [value]}
    end
  end

  defp parse_cell(_value), do: {nil, []}

  defp staged_times(row) do
    {arrival, _} = parse_cell(Map.get(row, :arrival))
    {departure, _} = parse_cell(Map.get(row, :departure))
    {arrival, departure}
  end

  defp move_delta(base_arrival, base_departure, edited_arrival, edited_departure) do
    cond do
      not is_nil(base_departure) and not is_nil(edited_departure) ->
        edited_departure - base_departure

      not is_nil(base_arrival) and not is_nil(edited_arrival) ->
        edited_arrival - base_arrival

      true ->
        nil
    end
  end

  defp invalid_entries(rows, parsed) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} ->
      {_arrival, _departure, bad} = Enum.at(parsed, index)
      position = Map.get(row, :position, index + 1)

      Enum.map(bad, fn value ->
        %{
          position: position,
          kind: :invalid_time,
          message: "#{value} at stop #{position} is not a valid time and was treated as blank."
        }
      end)
    end)
  end

  defp problem_entry(rows, {:no_first_time, _index}) do
    %{
      position: position_at(rows, 0),
      kind: :no_first_time,
      message: "The first stop needs a time before missing times can be filled."
    }
  end

  defp problem_entry(rows, {:no_last_time, index}) do
    %{
      position: position_at(rows, index),
      kind: :no_last_time,
      message: "The last stop needs a time before missing times can be filled."
    }
  end

  defp problem_entry(rows, {:timepoint_without_time, index}) do
    position = position_at(rows, index)

    %{
      position: position,
      kind: :timepoint_without_time,
      message:
        "Stop #{position} is a timepoint without a time, so the stops around it were left blank."
    }
  end

  defp problem_entry(rows, {:order, from, to}) do
    %{
      position: position_at(rows, to),
      kind: :order,
      message:
        "Stop #{position_at(rows, to)} is timed before stop #{position_at(rows, from)} departs, so the stops between them were left blank."
    }
  end

  defp preview_span(rows, span) do
    %{
      from_position: position_at(rows, span.from),
      to_position: position_at(rows, span.to),
      seconds: span.seconds,
      metres: span.metres,
      source: span.source,
      mph: span.mph,
      error: span.error
    }
  end

  defp position_at(rows, index) do
    case Enum.at(rows, index) do
      %{position: position} when is_integer(position) -> position
      _ -> index + 1
    end
  end

  defp filled_span?(span, scope, only_anchor) do
    span.error == nil and
      (scope == :missing or is_nil(only_anchor) or span.from == only_anchor or
         span.to == only_anchor)
  end

  defp summary(:missing, 0, _spans), do: "Nothing to fill. Every stop already has a time."

  defp summary(:between, 0, _spans),
    do: "Nothing to recalculate. Every stop already matches the timepoints."

  defp summary(:missing, changed, spans) do
    "Fills #{Wording.count_noun(changed, "stop")} in #{Wording.count_noun(spans, "section")} between timepoints. Every time already here stays as it is."
  end

  defp summary(:between, changed, spans) do
    "Recalculates #{Wording.count_noun(changed, "stop")} in #{Wording.count_noun(spans, "section")} between timepoints. Timepoint times never change."
  end
end
