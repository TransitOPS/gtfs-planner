defmodule GtfsPlanner.Gtfs.Schedules.TimeEntry do
  @moduledoc """
  Parses typed stop times on the Schedules page (R2).

  This is the page's single time grammar: the grid cells and the trip drawers
  all read typed text through `parse/2`, so a form accepted in one place is
  accepted in every place. Times are integer seconds; GTFS service times may
  pass 24:00, so they never use Elixir's `Time` type.

  Accepted forms:

    * `6` / `18` — an hour
    * `605` — `H MM`
    * `0605` / `1805` / `2510` — `HH MM`
    * `6:05` / `06:05` / `6:05:30` / `25:10`
    * `6:05p` / `6p` / `12:05a` — a 12-hour suffix `a`, `am`, `p`, `pm` (any
      case, optional space) on an hour of 1–12
    * `+3` / `-10` — whole minutes relative to `:current`

  Minutes and seconds stay below 60. A reading earlier than `:previous` is
  adjusted onto the next service day when the form allows it: an ambiguous
  reading (no suffix, no leading-zero hour, hour at most 12) tries +12 h and
  then +24 h, a suffixed reading tries +24 h, and the first candidate at or
  after `:previous` wins. A reading with no candidate keeps its literal value
  and is left for the caller's chronology check to refuse; only a relative
  reading below zero is refused here.
  """

  alias GtfsPlanner.Gtfs.GtfsTime

  @seconds_per_hour 3_600
  @seconds_per_day 86_400
  @max_relative_minutes 999

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
    with {suffix, clock} <- split_suffix(text),
         {:ok, {hour, minute, second}} <- parse_parts(clock),
         true <- hour_in_suffix_range?(hour, suffix) do
      secs = apply_suffix(hour * @seconds_per_hour + minute * 60 + second, hour, suffix)
      place(secs, suffix, clock, hour, opts)
    else
      _ -> {:error, :invalid_time}
    end
  end

  defp place(secs, suffix, clock, hour, opts) do
    previous = opts[:previous]

    cond do
      not adjustable?(suffix, clock, hour) -> {:ok, reading(secs, nil)}
      previous == nil -> {:ok, reading(secs, nil)}
      secs >= previous -> {:ok, reading(secs, nil)}
      suffixed?(suffix) -> next_day(secs, previous)
      true -> plus_twelve(secs, previous)
    end
  end

  defp split_suffix(text) do
    case Regex.run(~r/\A(.*?)\s?(am|pm|a|p)\z/i, text) do
      [_, clock, suffix] -> {String.downcase(suffix), clock}
      _ -> {nil, text}
    end
  end

  defp parse_parts(clock) do
    case Regex.run(~r/\A(\d{1,2}):(\d{2})(?::(\d{2}))?\z/, clock) do
      [_, hour, minute, second] -> clock_parts(hour, minute, second)
      [_, hour, minute] -> clock_parts(hour, minute, "0")
      nil -> parse_compact(clock)
    end
  end

  defp parse_compact(clock) do
    case Regex.run(~r/\A(\d{1,2})(\d{2})?\z/, clock) do
      [_, hour] -> clock_parts(hour, "0", "0")
      [_, hour, minute] -> clock_parts(hour, minute, "0")
      nil -> {:error, :invalid_time}
    end
  end

  defp clock_parts(hour, minute, second) do
    with {:ok, hour} <- to_integer(hour),
         {:ok, minute} <- to_integer(minute),
         {:ok, second} <- to_integer(second),
         true <- minute < 60 and second < 60 do
      {:ok, {hour, minute, second}}
    else
      _ -> {:error, :invalid_time}
    end
  end

  defp hour_in_suffix_range?(_hour, suffix) when suffix in [nil, ""], do: true
  defp hour_in_suffix_range?(hour, _suffix), do: hour in 1..12

  defp apply_suffix(secs, hour, suffix) when suffix in ["a", "am"],
    do: if(hour == 12, do: secs - 12 * @seconds_per_hour, else: secs)

  defp apply_suffix(secs, hour, suffix) when suffix in ["p", "pm"],
    do: if(hour == 12, do: secs, else: secs + 12 * @seconds_per_hour)

  defp apply_suffix(secs, _hour, _suffix), do: secs

  defp suffixed?(suffix), do: suffix in ["a", "am", "p", "pm"]

  defp adjustable?(suffix, clock, hour) do
    suffixed?(suffix) or
      (not String.match?(clock, ~r/\A0\d/) and hour <= 12)
  end

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

  defp to_integer(value), do: {:ok, String.to_integer(value)}
end
