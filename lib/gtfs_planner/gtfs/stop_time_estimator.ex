defmodule GtfsPlanner.Gtfs.StopTimeEstimator do
  @moduledoc """
  Pure stop-time interpolation core (spec 23, R1–R7).

  Every estimation rule lives here: adapters translate inputs and outputs only
  (criteria "One rule core"). All times are integer seconds since the
  service-day start and are never wrapped past 24:00:00.

  Row coordinates are `{lat, lon}` tuples; straight-line spans call
  `Alignments.Materializer.length_m/1` with `[[lon, lat], [lon, lat]]` pairs.
  """

  alias GtfsPlanner.Gtfs.Alignments.Materializer

  @ms_per_mph 2.23694

  @type row :: %{
          required(:arrival) => non_neg_integer() | nil,
          required(:departure) => non_neg_integer() | nil,
          required(:timepoint) => 0 | 1 | nil,
          required(:distance) => number() | Decimal.t() | nil,
          required(:coord) => {float(), float()} | nil
        }
  @type opts :: [
          scope: :missing | :between,
          method: :distance | :even,
          distances: :strict | :non_decreasing,
          only_anchor: non_neg_integer() | nil
        ]
  @type problem ::
          {:no_first_time, 0}
          | {:no_last_time, non_neg_integer()}
          | {:timepoint_without_time, non_neg_integer()}
          | {:order, from :: non_neg_integer(), to :: non_neg_integer()}
  @type span :: %{
          from: non_neg_integer(),
          to: non_neg_integer(),
          seconds: integer(),
          metres: float() | nil,
          source: :distance | :straight_line | :even,
          mph: float() | nil,
          error: nil | :order | :after_order | :timepoint_without_time
        }
  @type out_row :: %{
          arrival: non_neg_integer() | nil,
          departure: non_neg_integer() | nil,
          estimated?: boolean(),
          previous: {non_neg_integer() | nil, non_neg_integer() | nil}
        }

  @doc """
  Estimates blank stop times between timed anchors.

  Returns `%{rows: [out_row()], spans: [span()], problems: [problem()]}`.
  Options default to `scope: :missing`, `method: :distance`,
  `distances: :strict`, `only_anchor: nil`. `only_anchor` is honored only
  with `scope: :between`: only spans ending or starting at that row are filled.
  """
  @spec estimate([row()], opts()) :: %{rows: [out_row()], spans: [span()], problems: [problem()]}
  def estimate(rows, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        scope: :missing,
        method: :distance,
        distances: :strict,
        only_anchor: nil
      )

    scope = option!(opts, :scope, [:missing, :between])
    method = option!(opts, :method, [:distance, :even])
    distances = option!(opts, :distances, [:strict, :non_decreasing])
    only_anchor = Keyword.fetch!(opts, :only_anchor)

    if not is_nil(only_anchor) and not (is_integer(only_anchor) and only_anchor >= 0) do
      raise ArgumentError, "only_anchor must be a non-negative integer or nil"
    end

    norm = Enum.map(rows, &normalize_row/1)
    count = length(norm)

    if count == 0 do
      %{rows: [], spans: [], problems: []}
    else
      gate_problems =
        if(timed?(hd(norm)), do: [], else: [{:no_first_time, 0}]) ++
          if timed?(List.last(norm)), do: [], else: [{:no_last_time, count - 1}]

      if gate_problems != [] do
        %{rows: Enum.map(norm, &out_row_unchanged/1), spans: [], problems: gate_problems}
      else
        estimate_spans(norm, scope, method, distances, only_anchor)
      end
    end
  end

  defp option!(opts, key, allowed) do
    value = Keyword.fetch!(opts, key)

    if value in allowed do
      value
    else
      raise ArgumentError, "#{key} must be one of #{inspect(allowed)}"
    end
  end

  defp normalize_row(row) do
    arrival = Map.get(row, :arrival)
    departure = Map.get(row, :departure)

    {arrival, departure} =
      case {arrival, departure} do
        {nil, nil} -> {nil, nil}
        {a, nil} -> {a, a}
        {nil, d} -> {d, d}
        {a, d} -> {a, d}
      end

    %{
      arrival: arrival,
      departure: departure,
      timepoint: Map.get(row, :timepoint),
      distance: normalize_distance(Map.get(row, :distance)),
      coord: Map.get(row, :coord),
      previous: {Map.get(row, :arrival), Map.get(row, :departure)}
    }
  end

  defp normalize_distance(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp normalize_distance(distance), do: distance

  defp timed?(%{arrival: arrival, departure: departure}),
    do: not is_nil(arrival) and not is_nil(departure)

  defp out_row_unchanged(%{arrival: arrival, departure: departure, previous: previous}) do
    %{arrival: arrival, departure: departure, estimated?: false, previous: previous}
  end

  defp estimate_spans(norm, scope, method, distances, only_anchor) do
    count = length(norm)
    indexed = Enum.with_index(norm)
    anchors = resolve_anchors(indexed, count, scope)

    order_pairs =
      anchors
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, b] ->
        Enum.at(norm, b).arrival < Enum.at(norm, a).departure
      end)

    order_tos = order_pairs |> Enum.map(fn [_a, b] -> b end) |> MapSet.new()

    order_problems = Enum.map(order_pairs, fn [a, b] -> {:order, a, b} end)

    spans =
      anchors
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, b] -> b > a + 1 end)
      |> Enum.map(&build_span(&1, norm, method, distances, order_tos))

    {filled, span_problems} =
      Enum.map_reduce(spans, [], fn span, acc ->
        fill_span(span, norm, scope, only_anchor, acc)
      end)

    filled_by_index =
      filled
      |> List.flatten()
      |> Map.new(fn {index, out} -> {index, out} end)

    rows =
      indexed
      |> Enum.map(fn {row, index} ->
        case Map.fetch(filled_by_index, index) do
          {:ok, out} -> out
          :error -> out_row_unchanged(row)
        end
      end)

    %{rows: rows, spans: spans, problems: order_problems ++ List.flatten(span_problems)}
  end

  defp resolve_anchors(indexed, _count, :missing) do
    indexed
    |> Enum.filter(fn {row, _index} -> timed?(row) end)
    |> Enum.map(fn {_row, index} -> index end)
  end

  defp resolve_anchors(indexed, count, :between) do
    indexed
    |> Enum.filter(fn {row, index} ->
      timed?(row) and (index == 0 or index == count - 1 or row.timepoint == 1)
    end)
    |> Enum.map(fn {_row, index} -> index end)
  end

  defp build_span([from, to], norm, method, distances, order_tos) do
    dep_from = Enum.at(norm, from).departure
    arr_to = Enum.at(norm, to).arrival
    seconds = arr_to - dep_from
    span_rows = Enum.slice(norm, from..to)

    source = pick_source(span_rows, method, distances)
    {metres, mph} = span_measures(span_rows, source, distances, seconds)

    error =
      cond do
        arr_to < dep_from -> :order
        MapSet.member?(order_tos, from) -> :after_order
        untimed_timepoint?(span_rows) -> :timepoint_without_time
        true -> nil
      end

    %{
      from: from,
      to: to,
      seconds: seconds,
      metres: metres,
      source: source,
      mph: mph,
      error: error
    }
  end

  defp untimed_timepoint?(span_rows) do
    span_rows
    |> Enum.slice(1..-2//1)
    |> Enum.any?(fn row -> row.timepoint == 1 and not timed?(row) end)
  end

  defp first_untimed_timepoint(norm, from, to) do
    (from + 1)..(to - 1)//1
    |> Enum.find(fn index ->
      row = Enum.at(norm, index)
      row.timepoint == 1 and not timed?(row)
    end)
  end

  defp pick_source(_span_rows, :even, _distances), do: :even

  defp pick_source(span_rows, :distance, distances) do
    cond do
      stored_usable?(span_rows, distances) -> :distance
      straight_line_usable?(span_rows) -> :straight_line
      true -> :even
    end
  end

  defp stored_usable?(span_rows, :strict) do
    distances = Enum.map(span_rows, & &1.distance)

    Enum.all?(distances, &(not is_nil(&1))) and
      strictly_increasing?(distances)
  end

  defp stored_usable?(span_rows, :non_decreasing) do
    distances = Enum.map(span_rows, & &1.distance)

    Enum.all?(distances, &(not is_nil(&1))) and
      non_decreasing?(distances) and
      List.last(distances) - hd(distances) > 0
  end

  defp strictly_increasing?([_single]), do: true

  defp strictly_increasing?([first, second | rest]) do
    second > first and strictly_increasing?([second | rest])
  end

  defp non_decreasing?([_single]), do: true

  defp non_decreasing?([first, second | rest]) do
    second >= first and non_decreasing?([second | rest])
  end

  defp straight_line_usable?(span_rows) do
    total_straight_m(span_rows) > 0
  end

  defp total_straight_m(span_rows) do
    if Enum.all?(span_rows, &has_coord?/1) do
      span_rows
      |> Enum.map(& &1.coord)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(0.0, fn [{lat1, lon1}, {lat2, lon2}], acc ->
        acc + Materializer.length_m([[lon1, lat1], [lon2, lat2]])
      end)
    else
      0.0
    end
  end

  defp has_coord?(%{coord: {lat, lon}})
       when is_number(lat) and is_number(lon),
       do: true

  defp has_coord?(_row), do: false

  defp span_measures(span_rows, :distance, distances, seconds) do
    metres = List.last(span_rows).distance - hd(span_rows).distance
    metres = metres * 1.0

    mph =
      if distances == :non_decreasing and seconds > 0 do
        metres / seconds * @ms_per_mph
      else
        nil
      end

    {metres, mph}
  end

  defp span_measures(span_rows, :straight_line, _distances, seconds) do
    metres = total_straight_m(span_rows)
    mph = if seconds > 0, do: metres / seconds * @ms_per_mph, else: nil
    {metres, mph}
  end

  defp span_measures(_span_rows, :even, _distances, _seconds), do: {nil, nil}

  defp fill_span(span, norm, scope, only_anchor, problems) do
    touched =
      scope == :missing or is_nil(only_anchor) or
        span.from == only_anchor or span.to == only_anchor

    cond do
      span.error != nil ->
        problems =
          if span.error == :timepoint_without_time do
            index = first_untimed_timepoint(norm, span.from, span.to)
            [[{:timepoint_without_time, index}] | problems]
          else
            problems
          end

        {[], problems}

      not touched ->
        {[], problems}

      true ->
        {fill_interior(span, norm), problems}
    end
  end

  defp fill_interior(span, norm) do
    dep_from = Enum.at(norm, span.from).departure
    span_rows = Enum.slice(norm, span.from..span.to)

    fractions = span_fractions(span, span_rows)

    (span.from + 1)..(span.to - 1)//1
    |> Enum.map(fn index ->
      fraction = Map.fetch!(fractions, index)
      time = dep_from + floor(span.seconds * fraction)
      row = Enum.at(norm, index)

      {index, %{arrival: time, departure: time, estimated?: true, previous: row.previous}}
    end)
  end

  defp span_fractions(%{source: :even, from: from, to: to}, _span_rows) do
    (from + 1)..(to - 1)//1
    |> Enum.map(fn index -> {index, (index - from) / (to - from)} end)
    |> Map.new()
  end

  defp span_fractions(%{source: :distance, from: from, to: to}, span_rows) do
    first = hd(span_rows).distance
    total = List.last(span_rows).distance - first

    (from + 1)..(to - 1)//1
    |> Enum.map(fn index ->
      {index, (Enum.at(span_rows, index - from).distance - first) / total}
    end)
    |> Map.new()
  end

  defp span_fractions(%{source: :straight_line, from: from}, span_rows) do
    hops =
      span_rows
      |> Enum.map(& &1.coord)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{lat1, lon1}, {lat2, lon2}] ->
        Materializer.length_m([[lon1, lat1], [lon2, lat2]])
      end)

    total = Enum.sum(hops)

    {fractions, _} =
      hops
      |> Enum.with_index()
      |> Enum.map_reduce(0.0, fn {hop, hop_index}, acc ->
        cumulative = acc + hop
        {{from + 1 + hop_index, cumulative / total}, cumulative}
      end)

    Map.new(fractions)
  end
end
