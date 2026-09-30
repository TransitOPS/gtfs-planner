defmodule GtfsPlanner.Gtfs.Schedules.TimeEntry do
  @moduledoc """
  Parses typed stop times on the Schedules page (R2).

  This module owns the application's one time-literal grammar. The grid cells
  and the trip drawers read typed text through `parse/2`, and timetable paste
  (`GtfsPlanner.Gtfs.TimetablePaste.TimeToken`) reads each pasted cell through
  `read_clock/2`, so a clock literal means the same thing everywhere. Times
  are integer seconds; GTFS service times may pass 24:00, so they never use
  Elixir's `Time` type.

  Accepted forms:

    * `6` / `18` — an hour (not in paste)
    * `605` — `H MM`
    * `0605` / `1805` / `2510` — `HH MM`
    * `6:05` / `06:05` / `6:05:30` / `25:10`
    * `6:05p` / `6p` / `12:05a` / `6:05 p.m.` — a 12-hour marker `a`, `am`,
      `p`, `pm`, `a.m.` or `p.m.` (any case, optional spaces) on an hour of
      1–12
    * `+3` / `-10` — whole minutes relative to `:current` (not in paste)

  Paste accepts only the clock literals with minutes: an hour on its own and a
  relative form are refused there, because a stray number in a pasted
  timetable is more likely a route or footnote number than a time.

  Minutes and seconds stay below 60. Each literal has a kind: `:h12` when it
  carries a marker, `:h24` when its hour has a leading zero, is 0, or is 13 or
  more, and `:ambiguous` otherwise. A reading earlier than `:previous` is
  adjusted onto the next service day when its kind allows it: an ambiguous
  reading tries +12 h and then +24 h, a marked reading or an hour-0 reading
  tries +24 h, and the first candidate at or after `:previous` wins. Any other
  24-hour reading keeps its literal value. A reading with no candidate keeps
  its literal value and is left for the caller's chronology check to refuse;
  only a relative reading below zero is refused here.
  """

  alias GtfsPlanner.Gtfs.GtfsTime

  @seconds_per_hour 3_600
  @seconds_per_day 86_400
  @max_relative_minutes 999

  # A 12-hour marker: a/am/p/pm, optionally dotted (a.m., p.m.), any case.
  @meridiem ~r/\A(.*?)\s*([ap])\.?\s*m?\.?\z/i
  @colon_clock ~r/\A(\d{1,2}):(\d{2})(?::(\d{2}))?\z/
  @compact_clock ~r/\A(\d{1,2})(\d{2})?\z/

  @typedoc "How a clock literal reads: marked 12-hour, explicit 24-hour, or either."
  @type clock_kind :: :h24 | :h12 | :ambiguous

  @typedoc """
  One accepted reading.

  `:secs` is the value the cell commits, `:reading` is `GtfsTime.format/1`
  without a zero seconds part, and `:note` names a service-day adjustment:
  `:plus_12h` for a candidate 12 h later, `:next_day` for one 24 h later.
  """
  @type reading :: %{
          secs: non_neg_integer(),
          reading: String.t(),
          note: nil | :plus_12h | :next_day
        }

  @typedoc "Relative readings are taken from `:current`; the other options stand alone."
  @type opts :: [previous: non_neg_integer() | nil, current: non_neg_integer() | nil]

  @doc """
  Reads one typed time.

  `:previous` is the trip's preceding stored time and `:current` the cell's own
  current time; the first stop of a trip has neither. A relative reading
  without `:current`, a reading below zero, and every form outside the grammar
  return an error.
  """
  @spec parse(term(), opts()) :: {:ok, reading()} | {:error, :invalid_time | :negative_time}
  def parse(text, opts \\ [])

  def parse(text, opts) when is_binary(text) do
    text = String.trim(text)

    if Regex.match?(~r/\A[+-]\d+\z/, text) do
      parse_relative(text, opts)
    else
      parse_clock(text, opts)
    end
  end

  def parse(_text, _opts), do: {:error, :invalid_time}

  defp parse_relative(text, opts) do
    [_, sign, digits] = Regex.run(~r/\A([+-])(\d+)\z/, text)
    minutes = String.to_integer(digits)
    current = opts[:current]

    cond do
      current == nil -> {:error, :invalid_time}
      minutes < 1 or minutes > @max_relative_minutes -> {:error, :invalid_time}
      true -> reading_or_negative(current + sign_value(sign) * minutes * 60)
    end
  end

  defp parse_clock(text, opts) do
    case read_clock(text) do
      {:ok, secs, kind} -> place(secs, kind, opts[:previous])
      :error -> {:error, :invalid_time}
    end
  end

  defp place(secs, _kind, previous) when is_nil(previous) or secs >= previous,
    do: {:ok, reading(secs, nil)}

  defp place(secs, :ambiguous, previous), do: plus_twelve(secs, previous)
  defp place(secs, :h12, previous), do: next_day(secs, previous)
  # A 24-hour reading below one hour has hour 0: it can only mean after midnight.
  defp place(secs, :h24, previous) when secs < @seconds_per_hour, do: next_day(secs, previous)
  defp place(secs, :h24, _previous), do: {:ok, reading(secs, nil)}

  @doc """
  Reads one trimmed clock literal into seconds and a kind.

  The kind is `:h12` for a literal with an `a`/`p` marker, `:h24` for one
  whose hour has a leading zero, is 0, or is 13 or more, and `:ambiguous`
  otherwise. `hour_only: false` refuses the hour-only forms (`6`, `18`, `6p`);
  they are accepted by default. Relative forms are not clock literals and are
  always refused.
  """
  @spec read_clock(String.t(), hour_only: boolean()) ::
          {:ok, non_neg_integer(), clock_kind()} | :error
  def read_clock(text, opts \\ []) when is_binary(text) do
    {meridiem, clock} = split_meridiem(text)

    with {:ok, hour_text, hour, minute, second} <-
           split_clock(clock, Keyword.get(opts, :hour_only, true)) do
      clock_reading(hour_text, hour, minute * 60 + second, meridiem)
    end
  end

  defp split_meridiem(text) do
    case Regex.run(@meridiem, text) do
      [_, clock, letter] when clock != "" -> {String.downcase(letter), clock}
      _ -> {nil, text}
    end
  end

  defp split_clock(clock, hour_only?) do
    case Regex.run(@colon_clock, clock) || Regex.run(@compact_clock, clock) do
      [_, hour, minute, second] -> clock_parts(hour, minute, second)
      [_, hour, minute] -> clock_parts(hour, minute, "0")
      [_, hour] when hour_only? -> clock_parts(hour, "0", "0")
      _ -> :error
    end
  end

  defp clock_parts(hour_text, minute, second) do
    minute = String.to_integer(minute)
    second = String.to_integer(second)

    if minute < 60 and second < 60,
      do: {:ok, hour_text, String.to_integer(hour_text), minute, second},
      else: :error
  end

  defp clock_reading(hour_text, hour, rest, nil) do
    kind =
      if String.starts_with?(hour_text, "0") or hour >= 13,
        do: :h24,
        else: :ambiguous

    {:ok, hour * @seconds_per_hour + rest, kind}
  end

  defp clock_reading(_hour_text, hour, rest, meridiem) when hour in 1..12 do
    hour = if meridiem == "p", do: rem(hour, 12) + 12, else: rem(hour, 12)
    {:ok, hour * @seconds_per_hour + rest, :h12}
  end

  defp clock_reading(_hour_text, _hour, _rest, _meridiem), do: :error

  defp plus_twelve(secs, previous) do
    candidate = secs + 12 * @seconds_per_hour

    if candidate >= previous do
      {:ok, reading(candidate, :plus_12h)}
    else
      next_day(secs, previous)
    end
  end

  defp next_day(secs, previous) do
    candidate = secs + @seconds_per_day

    if candidate >= previous do
      {:ok, reading(candidate, :next_day)}
    else
      {:ok, reading(secs, nil)}
    end
  end

  defp reading(secs, note) do
    reading = secs |> GtfsTime.format() |> String.replace_suffix(":00", "")
    %{secs: secs, reading: reading, note: note}
  end

  defp reading_or_negative(secs) when secs < 0, do: {:error, :negative_time}
  defp reading_or_negative(secs), do: {:ok, reading(secs, nil)}

  defp sign_value("-"), do: -1
  defp sign_value(_sign), do: 1
end
