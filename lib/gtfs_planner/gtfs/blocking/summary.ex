defmodule GtfsPlanner.Gtfs.Blocking.Summary do
  @moduledoc """
  Pure block summaries, natural ordering, the day's exact peak and its bins (R7).

  Every function computes from its arguments only: no database, clock, files or
  network (CR-1).

  A block's span is the earliest first departure to the latest last arrival of its
  plottable, non-frequency trips, so a gap between two trips stays inside the span
  and the block counts once while it is out. A block with no such trip has no span
  and is left out of the peak and the bins.

  `peak/1` delegates to `GtfsPlanner.Gtfs.Schedules.Summary.peak_vehicles/1`, which
  already treats spans as half-open and reports the earliest maximum, so two blocks
  touching at one instant count once. `bins/2` reports each bin's own maximum
  rather than its start's count, so a five-minute block inside a bin is visible.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Schedules, as: Schedules

  @seconds_per_hour 3600

  @sort_keys [:block, :trips, :start, :end, :hours, :status]

  # Worst first: error, then warning, then notice, then a block with no finding.
  @status_rank %{error: 0, warning: 1, notice: 2, ok: 3}

  # The code reported for the worst severity is the first one in this order
  # (Copy: Overlap, Short layover, In-seat row, Empty move, Frequency, Time
  # missing, Can't confirm).
  @status_order [
    :overlap,
    :short_layover,
    :in_seat_stale,
    :repositions,
    :frequency_trip,
    :unplottable,
    :in_seat_unconfirmed
  ]

  @type sort :: :block | :trips | :start | :end | :hours | :status

  @type block_summary :: %{
          block_id: String.t(),
          trip_count: pos_integer(),
          start_secs: integer() | nil,
          end_secs: integer() | nil,
          hours: float() | nil,
          status: :error | :warning | :notice | :ok,
          status_code: Checks.code() | nil,
          route_ids: [String.t()]
        }

  @doc """
  Summarizes one block from its trips and its findings.

  `start_secs` and `end_secs` come from `Checks.sequence/1` of the block's trips,
  so frequency-based and unplottable trips contribute no span and a block without
  a plottable, non-frequency trip has `nil` for both. `hours` is the span in hours
  rounded to one decimal, `route_ids` the sorted, unique routes of every trip
  given, and `trip_count` every trip given.

  `status` is the worst severity among the block's findings and `status_code` the
  first code of that severity in the fixed order, or `:ok` with no code when there
  is no finding. Only findings naming this block are considered, so a caller may
  hand over a whole day's findings.
  """
  @spec block_summary(String.t(), [Checks.trip_row()], [Checks.finding()]) :: block_summary()
  def block_summary(block_id, trips, findings) do
    {start_secs, end_secs} = span(trips)
    {status, status_code} = status(Enum.filter(findings, &(&1.block_id == block_id)))

    %{
      block_id: block_id,
      trip_count: length(trips),
      start_secs: start_secs,
      end_secs: end_secs,
      hours: hours(start_secs, end_secs),
      status: status,
      status_code: status_code,
      route_ids: trips |> Enum.map(& &1.route_id) |> Enum.uniq() |> Enum.sort()
    }
  end

  @doc """
  Returns the natural sort key of a block ID.

  Digit runs become `{0, integer}` and every other run `{1, downcased text}`, with
  the raw ID appended, so `2 < 10 < 101 < A1` and a key is unique for its ID.
  """
  @spec natural_key(String.t()) :: list()
  def natural_key(id) when is_binary(id) do
    id
    |> runs()
    |> Enum.map(&run_key/1)
    |> Kernel.++([id])
  end

  @doc """
  Sorts block summaries by one timeline column.

  `:block` compares `natural_key/1`, `:status` ranks error, warning, notice and ok,
  and the other keys compare their number. `nil` values sort last in both
  directions, and ties break by `natural_key/1` ascending so a page keeps the
  natural block order whatever the column shows.
  """
  @spec sort_blocks([block_summary()], sort(), :asc | :desc) :: [block_summary()]
  def sort_blocks(blocks, key, direction)
      when key in @sort_keys and direction in [:asc, :desc] do
    Enum.sort(blocks, fn a, b -> before?(a, b, key, direction) end)
  end

  @doc """
  Counts the day's peak vehicles out and the earliest instant it is reached.

  Blocks without a span are dropped and the rest become half-open `%{start_secs,
  end_secs}` spans for `Schedules.Summary.peak_vehicles/1`. Unassigned and
  frequency-based trips are not blocks here, so they are never counted.
  """
  @spec peak([block_summary()]) :: %{count: non_neg_integer(), at_secs: integer() | nil}
  def peak(blocks), do: blocks |> spans() |> Schedules.Summary.peak_vehicles()

  @doc """
  Returns one count per `bin_secs`-long bin from the floor hour of the earliest
  start to the ceiling hour of the latest end.

  A bin's count is the number of spans covering its start plus the highest running
  change of the span starts and ends strictly inside it, so it is the exact
  maximum inside the bin. A block running only 08:01-08:06 therefore appears with
  count 1 in the 08:00 bin. No span at all gives no bins.
  """
  @spec bins([block_summary()], pos_integer()) ::
          [%{start_secs: integer(), count: non_neg_integer()}]
  def bins(blocks, bin_secs) when is_integer(bin_secs) and bin_secs > 0 do
    case spans(blocks) do
      [] ->
        []

      spans ->
        first = spans |> Enum.map(& &1.start_secs) |> Enum.min()
        last = spans |> Enum.map(& &1.end_secs) |> Enum.max()

        Enum.map(bin_starts(floor_hour(first), ceil_hour(last), bin_secs), fn start_secs ->
          %{start_secs: start_secs, count: bin_count(spans, start_secs, bin_secs)}
        end)
    end
  end

  defp span(trips) do
    case Checks.sequence(trips) do
      [] ->
        {nil, nil}

      sequence ->
        starts = Enum.map(sequence, & &1.first_departure)
        ends = Enum.map(sequence, & &1.last_arrival)

        {Enum.min(starts), Enum.max(ends)}
    end
  end

  defp hours(nil, _end_secs), do: nil
  defp hours(_start_secs, nil), do: nil

  defp hours(start_secs, end_secs) do
    Float.round((end_secs - start_secs) / @seconds_per_hour, 1)
  end

  defp status([]), do: {:ok, nil}

  defp status(findings) do
    severity = findings |> Enum.map(& &1.severity) |> Enum.min_by(&Map.fetch!(@status_rank, &1))

    code =
      Enum.find(@status_order, fn code ->
        Enum.any?(findings, &(&1.code == code and &1.severity == severity))
      end)

    {severity, code}
  end

  defp runs(id), do: Regex.scan(~r/\d+|\D+/u, id) |> List.flatten()

  defp run_key(run) do
    case Integer.parse(run) do
      {number, ""} -> {0, number}
      _ -> {1, String.downcase(run)}
    end
  end

  defp before?(a, b, key, direction) do
    a_value = sort_value(a, key)
    b_value = sort_value(b, key)

    cond do
      is_nil(a_value) -> false
      is_nil(b_value) -> true
      a_value == b_value -> natural_before?(a, b)
      direction == :asc -> a_value < b_value
      true -> a_value > b_value
    end
  end

  defp natural_before?(a, b), do: natural_key(a.block_id) <= natural_key(b.block_id)

  defp sort_value(block, :block), do: natural_key(block.block_id)
  defp sort_value(block, :trips), do: block.trip_count
  defp sort_value(block, :start), do: block.start_secs
  defp sort_value(block, :end), do: block.end_secs
  defp sort_value(block, :hours), do: block.hours
  defp sort_value(block, :status), do: Map.fetch!(@status_rank, block.status)

  defp spans(blocks) do
    for %{start_secs: start_secs, end_secs: end_secs} <- blocks,
        is_integer(start_secs),
        is_integer(end_secs),
        end_secs > start_secs do
      %{start_secs: start_secs, end_secs: end_secs}
    end
  end

  defp floor_hour(secs), do: div(secs, @seconds_per_hour) * @seconds_per_hour

  defp ceil_hour(secs) do
    if rem(secs, @seconds_per_hour) == 0 do
      secs
    else
      floor_hour(secs) + @seconds_per_hour
    end
  end

  defp bin_starts(from, to, bin_secs), do: Enum.to_list(from..(to - 1)//bin_secs)

  defp bin_count(spans, start_secs, bin_secs) do
    bin_end = start_secs + bin_secs

    covering =
      Enum.count(spans, fn span ->
        span.start_secs <= start_secs and span.end_secs > start_secs
      end)

    {highest, _running} =
      spans
      |> Enum.flat_map(fn span -> inside_events(span, start_secs, bin_end) end)
      |> Enum.sort()
      |> Enum.reduce({0, 0}, fn {_secs, delta}, {highest, running} ->
        running = running + delta
        {max(highest, running), running}
      end)

    covering + highest
  end

  # Ends sort before starts at the same instant, so a span ending where another
  # begins is never counted twice.
  defp inside_events(span, bin_start, bin_end) do
    start_event =
      if span.start_secs > bin_start and span.start_secs < bin_end,
        do: [{span.start_secs, 1}],
        else: []

    end_event =
      if span.end_secs > bin_start and span.end_secs < bin_end,
        do: [{span.end_secs, -1}],
        else: []

    start_event ++ end_event
  end
end
