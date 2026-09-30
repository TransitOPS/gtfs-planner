defmodule GtfsPlanner.Gtfs.TimetablePaste.TimeToken do
  @moduledoc """
  Classifies pasted timetable clock cells and resolves rows to GTFS seconds.

  `classify/1` reads one trimmed cell. Clock literals use the application's
  one time grammar, owned by `GtfsPlanner.Gtfs.Schedules.TimeEntry`
  (`TimeEntry.read_clock/2`), with the same kinds: `:h24` for a zero-padded
  hour, hour 0, or an hour of 13 and above; `:h12` for an `a`/`am`/`p`/`pm`
  marker (dotted forms such as `p.m.` included); `:ambiguous` otherwise. Paste
  is stricter than the Schedules grid: an hour on its own (`6`, `18`, `6p`) and
  a relative form (`+3`) are `{:error, :unrecognized}`, because a stray number
  in a pasted timetable is more likely a route or footnote number than a time.
  The not-served markers are `:not_served`, and anything else is
  `{:error, :unrecognized}`. Seconds are plain GTFS clock arithmetic, so every
  classified reading round-trips through `GtfsPlanner.Gtfs.GtfsTime.format/1`.

  `resolve_row/2` walks a row left to right per rule R2: a time earlier than
  the previous one tries +12 h (ambiguous tokens only), then +24 h. A time
  that still goes backwards is `{:error, {:time_goes_backwards, index}}`,
  where `index` is the 0-based position in the input token list. The optional
  `shift` (0, 43_200 or 86_400) records the R3 twelve-hour decision and is
  added to the row's first time only; later cells roll forward from there.
  `:not_served` and `{:error, :unrecognized}` tokens pass through unchanged so
  positions stay aligned with the pasted columns.

  `twelve_hour_question?/2` answers rule R3: a row whose first time is
  ambiguous and before 04:00, in a paste whose median start is after 12:00,
  needs a decision before it is applied.
  """

  alias GtfsPlanner.Gtfs.Schedules.TimeEntry

  @type kind :: TimeEntry.clock_kind()

  @type token ::
          {:time, non_neg_integer(), kind()} | :not_served | {:error, :unrecognized}

  @type cell ::
          %{secs: non_neg_integer(), rolled: nil | :h12 | :h24}
          | :not_served
          | {:error, :unrecognized}

  # Not-served markers per the contract: hyphen-minus, en dash (U+2013),
  # em dash (U+2014), ellipsis (U+2026), pipe, x, n/a. Compared case-insensitively.
  @not_served ["-", "–", "—", "…", "|", "x", "n/a"]

  @spec classify(String.t()) :: token()
  def classify(cell) when is_binary(cell) do
    trimmed = String.trim(cell)

    cond do
      trimmed == "" -> :not_served
      String.downcase(trimmed) in @not_served -> :not_served
      true -> read_clock(trimmed)
    end
  end

  def classify(_cell), do: {:error, :unrecognized}

  @spec resolve_row([token()], non_neg_integer()) ::
          {:ok, [cell()]} | {:error, {:time_goes_backwards, non_neg_integer()}}
  def resolve_row(tokens, shift \\ 0)
      when is_list(tokens) and shift in [0, 43_200, 86_400] do
    result =
      Enum.reduce_while(Enum.with_index(tokens), {[], nil, false}, fn
        {token, index}, {cells, prev, seen?} ->
          case advance(token, prev, seen?, shift, index) do
            {:halt, failed_index} -> {:halt, {:backwards, failed_index}}
            {:ok, cell, next_prev, next_seen?} -> {:cont, {[cell | cells], next_prev, next_seen?}}
          end
      end)

    case result do
      {:backwards, index} -> {:error, {:time_goes_backwards, index}}
      {cells, _prev, _seen?} -> {:ok, Enum.reverse(cells)}
    end
  end

  @spec twelve_hour_question?(token(), non_neg_integer() | nil) :: boolean()
  def twelve_hour_question?({:time, secs, :ambiguous}, median) when is_integer(median) do
    secs < 4 * 3_600 and median > 12 * 3_600
  end

  def twelve_hour_question?(_token, _median), do: false

  defp advance(:not_served, prev, seen?, _shift, _index),
    do: {:ok, :not_served, prev, seen?}

  defp advance({:error, :unrecognized} = error, prev, seen?, _shift, _index),
    do: {:ok, error, prev, seen?}

  defp advance({:time, base, _kind}, _prev, false, shift, _index) do
    secs = base + shift
    {:ok, %{secs: secs, rolled: nil}, secs, true}
  end

  defp advance({:time, base, kind}, prev, true, _shift, index) do
    cond do
      base >= prev ->
        {:ok, %{secs: base, rolled: nil}, base, true}

      kind == :ambiguous and base + 43_200 >= prev ->
        {:ok, %{secs: base + 43_200, rolled: :h12}, base + 43_200, true}

      base + 86_400 >= prev ->
        {:ok, %{secs: base + 86_400, rolled: :h24}, base + 86_400, true}

      true ->
        {:halt, index}
    end
  end

  defp read_clock(text) do
    case TimeEntry.read_clock(text, hour_only: false) do
      {:ok, secs, kind} -> {:time, secs, kind}
      :error -> {:error, :unrecognized}
    end
  end
end
