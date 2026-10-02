defmodule GtfsPlanner.Gtfs.RoutePatterns.TimingRules do
  @moduledoc """
  Decides whether a timing's rows are valid, and is the only place that decides it.

  A timing is valid when its first and last stop both carry an arrival and a
  departure, every `timepoint = 1` stop carries both, every stop carries both or
  neither, and the timed rows are in chronological order. A blank is the absence
  of a time, never `0` and never an estimate, so a non-timepoint stop between two
  timepoints may hold no offsets at all.

  The module is pure: it takes rows, reads only `arrival_offset`,
  `departure_offset` and `timepoint`, and returns every violation with its
  zero-based index in index order. The database's both-or-neither check constraint
  is a backstop for the pair rule; the ends, the timepoints and the chronology are
  only enforced here.
  """

  @typedoc "One timing row. Only the three timing keys are read; other keys are ignored."
  @type row :: %{
          required(:arrival_offset) => integer() | nil,
          required(:departure_offset) => integer() | nil,
          required(:timepoint) => 0 | 1 | nil
        }

  @typedoc "A rejected row and the rule it broke."
  @type violation ::
          {non_neg_integer(), :half_timed | :terminal_blank | :timepoint_blank | :out_of_order}

  @doc """
  Returns `:ok`, or every violation the rows break in index order.

  A row is half timed when exactly one of its two offsets is nil. A row is blank
  when both are nil, and blank rows are skipped when checking chronology.
  """
  @spec validate([row()]) :: :ok | {:error, [violation()]}
  def validate(rows) do
    last_index = length(rows) - 1

    case scan(rows, last_index) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  defp scan(rows, last_index) do
    {_, violations} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({nil, []}, fn {row, index}, {previous_departure, acc} ->
        {departure, violation} = check_row(row, index, last_index, previous_departure)
        {departure, [violation | acc]}
      end)

    violations |> Enum.reverse() |> Enum.reject(&is_nil/1)
  end

  # A half pair is one rule, so it is reported on its own: the row is malformed
  # rather than blank, and naming it as a blank terminal or timepoint too would
  # report the same mistake twice.
  defp check_row(row, index, last_index, previous_departure) do
    cond do
      half_timed?(row) ->
        {previous_departure, {index, :half_timed}}

      untimed_row?(row) ->
        {previous_departure, blank_violation(row, index, last_index)}

      true ->
        check_chronology(row, index, previous_departure)
    end
  end

  # A blank is only a mistake at the two ends and at a timepoint; between them it
  # is the absence of a scheduled time, which the timing allows.
  defp blank_violation(row, index, last_index) do
    cond do
      index == 0 or index == last_index -> {index, :terminal_blank}
      timepoint?(row) -> {index, :timepoint_blank}
      true -> nil
    end
  end

  # Chronology is checked over the timed rows only, so a blank between two
  # timepoints does not break the sequence. A row that is timed still becomes
  # the row the next timed one is compared against, even when it is out of order
  # itself, so one bad row does not silently reset the sequence.
  defp check_chronology(row, index, previous_departure) do
    arrival = offset(row, :arrival_offset)
    departure = offset(row, :departure_offset)

    out_of_order? =
      (not is_nil(previous_departure) and arrival < previous_departure) or departure < arrival

    {departure, if(out_of_order?, do: {index, :out_of_order}, else: nil)}
  end

  defp half_timed?(row) do
    is_nil(offset(row, :arrival_offset)) != is_nil(offset(row, :departure_offset))
  end

  # Named exception: "untimed" here means neither offset is set, not blank text.
  defp untimed_row?(row) do
    is_nil(offset(row, :arrival_offset)) and is_nil(offset(row, :departure_offset))
  end

  defp timepoint?(row), do: offset(row, :timepoint) == 1

  defp offset(row, key), do: Map.get(row, key)
end
