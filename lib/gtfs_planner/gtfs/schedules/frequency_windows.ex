defmodule GtfsPlanner.Gtfs.Schedules.FrequencyWindows do
  @moduledoc """
  Validates one frequency trip's windows and expands their departures (R8).

  A window is a half-open first-stop interval `[From, Until)`: a departure exactly at
  `Until` belongs to the next window, if any, not to this one. Windows of one trip may
  touch but not overlap, `Until` must be later than `From`, and a headway must be a
  whole number of minutes, so `headway_secs` is a positive multiple of 60. Times are
  integer seconds and may pass 24:00 (`25:00–26:00` is valid).

  `validate/1` reports every offending window with its 0-based index. Overlap is judged
  in start order among windows whose own span is well formed, like the prototype
  validator: a later window overlaps when it starts before any earlier one ends. An
  empty or reversed window already carries `:until_not_after_from` and contributes no
  overlap of its own.

  `departures/1` lists `From + k * headway` while the value stays strictly below
  `Until`, so 06:00–07:00 every 10 min gives six departures ending 06:50 and never
  07:00. `summary/1` adds the departure count, the last departure and the next
  departure the same headway would produce even at or past `Until` ("the next would be
  07:00"), plus `longer_than_window?` for a well-formed window shorter than one
  headway — the editor's warning.

  The module is pure: it reads only its arguments. `Schedules.TripChanges.Frequency`
  validates new and edited windows with it, `Schedules.TripChanges.Convert` expands
  `departures/1`, and the windows editor renders `summary/1`.
  """

  @typedoc "One half-open window `[start_secs, end_secs)` at the trip's first stop."
  @type window :: %{
          start_secs: non_neg_integer(),
          end_secs: non_neg_integer(),
          headway_secs: pos_integer()
        }

  @typedoc "One offending window; `index` is its 0-based position in the submitted list."
  @type error :: %{
          index: non_neg_integer(),
          reason: :until_not_after_from | :invalid_headway | :overlap
        }

  @typedoc "One window's editor line."
  @type summary :: %{
          count: non_neg_integer(),
          last_secs: non_neg_integer() | nil,
          next_secs: non_neg_integer() | nil,
          longer_than_window?: boolean()
        }

  @doc """
  Validates the windows of one trip; an empty list is valid.

  Every offending window is reported, sorted by `index`; one window can carry more
  than one reason.
  """
  @spec validate([window()]) :: :ok | {:error, [error()]}
  def validate(windows) when is_list(windows) do
    windows
    |> intrinsic_errors()
    |> Kernel.++(overlap_errors(windows))
    |> Enum.sort_by(& &1.index)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp intrinsic_errors(windows) do
    windows
    |> Enum.with_index()
    |> Enum.flat_map(fn {window, index} ->
      for {valid?, reason} <- [
            {until_after_from?(window), :until_not_after_from},
            {valid_headway?(window), :invalid_headway}
          ],
          not valid?,
          do: %{index: index, reason: reason}
    end)
  end

  defp overlap_errors(windows) do
    windows
    |> Enum.with_index()
    |> Enum.filter(fn {window, _index} -> until_after_from?(window) end)
    |> Enum.sort_by(fn {window, _index} -> window.start_secs end)
    |> Enum.map_reduce(nil, fn {window, index}, latest_end ->
      error =
        if latest_end && window.start_secs < latest_end, do: %{index: index, reason: :overlap}

      {error, max(latest_end || window.end_secs, window.end_secs)}
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp until_after_from?(%{start_secs: start, end_secs: finish}), do: finish > start

  defp valid_headway?(%{headway_secs: headway}) do
    is_integer(headway) and headway > 0 and rem(headway, 60) == 0
  end

  @doc """
  Lists one window's departures: `From`, `From + headway`, … while strictly below
  `Until`.

  A window whose `Until` is not later than its `From` has no departures.
  """
  @spec departures(window()) :: [non_neg_integer()]
  def departures(%{start_secs: start, end_secs: finish, headway_secs: headway})
      when is_integer(start) and is_integer(finish) and is_integer(headway) and headway > 0 do
    if finish <= start do
      []
    else
      Enum.map(0..div(finish - start - 1, headway), &(start + &1 * headway))
    end
  end

  @doc """
  Summarizes one window for the editor.

  `next_secs` is one headway after the last departure, even when that value is at or
  past `Until`; it is `nil` when the window has no departures. `longer_than_window?`
  is true only for a well-formed window shorter than one headway.
  """
  @spec summary(window()) :: summary()
  def summary(%{start_secs: start, end_secs: finish, headway_secs: headway} = window)
      when is_integer(start) and is_integer(finish) and is_integer(headway) and headway > 0 do
    times = departures(window)
    last = List.last(times)

    %{
      count: length(times),
      last_secs: last,
      next_secs: next_secs(last, headway),
      longer_than_window?: until_after_from?(window) and headway > finish - start
    }
  end

  defp next_secs(nil, _headway), do: nil
  defp next_secs(last_secs, headway), do: last_secs + headway
end
