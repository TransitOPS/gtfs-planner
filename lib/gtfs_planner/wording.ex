defmodule GtfsPlanner.Wording do
  @moduledoc """
  Canonical wording helpers for counts, plurals, percentages, durations and dates.

  Callers alias this module and call it qualified, so a module that keeps a local helper
  with different behavior does not collide with these names.
  """

  @doc """
  Returns an integer with thousands separators, or any other term via `to_string/1`.

  The sign is not grouped: `-123` reads `"-123"` and `-1234` reads `"-1,234"`.
  """
  @spec count(term()) :: String.t()
  def count(value) when is_integer(value) do
    sign = if value < 0, do: "-", else: ""

    digits =
      value
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    sign <> digits
  end

  def count(value), do: to_string(value)

  @doc """
  Returns the singular form for a count of one, otherwise the explicit plural or `one <> "s"`.

  Pass `many` for irregular nouns, as in `noun(2, "person", "people")`.
  """
  @spec noun(integer(), String.t(), String.t() | nil) :: String.t()
  def noun(count, one, many \\ nil)

  def noun(1, one, _many), do: one
  def noun(_count, one, nil), do: one <> "s"
  def noun(_count, _one, many), do: many

  @doc """
  Returns the grouped count and its noun, as in `"1,234 trips"`.
  """
  @spec count_noun(integer(), String.t(), String.t() | nil) :: String.t()
  def count_noun(value, one, many \\ nil), do: "#{count(value)} #{noun(value, one, many)}"

  @doc """
  Returns `part` as a rounded percentage of `whole`, or 0 when `whole` is not positive.

  Multiplies before dividing so exact halves round up: `percent(23, 40)` is 58.
  """
  @spec percent(number(), number()) :: non_neg_integer()
  def percent(part, whole) when is_number(whole) and whole > 0,
    do: round(part * 100 / whole)

  def percent(_part, _whole), do: 0

  @doc """
  Returns seconds as whole hours and/or minutes: `"45 min"`, `"1 h"`, `"1 h 5 min"`, `"0 min"`.
  """
  @spec duration(integer()) :: String.t()
  def duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    remaining = rem(minutes, 60)

    cond do
      hours == 0 -> "#{minutes} min"
      remaining == 0 -> "#{hours} h"
      true -> "#{hours} h #{remaining} min"
    end
  end

  @doc """
  Returns a `Date`, `DateTime` or `NaiveDateTime` as `"Oct 1, 2026"`.
  """
  @spec date(Date.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def date(value), do: Calendar.strftime(value, "%b %-d, %Y")

  @doc """
  Returns a `Date`, `DateTime` or `NaiveDateTime` as `"Oct 1"`.
  """
  @spec short_date(Date.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def short_date(value), do: Calendar.strftime(value, "%b %-d")

  @doc """
  Returns a `Date` as `"Thu, Oct 1"`.
  """
  @spec weekday_date(Date.t()) :: String.t()
  def weekday_date(value), do: Calendar.strftime(value, "%a, %b %-d")

  @doc """
  Returns a `Date` as `"Thu, Oct 1, 2026"`.

  Callers use this where a weekday date without the year would be ambiguous, such as
  calendar edits that span years.
  """
  @spec weekday_date_with_year(Date.t()) :: String.t()
  def weekday_date_with_year(value), do: Calendar.strftime(value, "%a, %b %-d, %Y")

  @doc """
  Returns the string with its first grapheme upcased and the rest unchanged.
  """
  @spec capitalize_first(String.t()) :: String.t()
  def capitalize_first(""), do: ""

  def capitalize_first(value) do
    {first, rest} = String.next_grapheme(value)
    String.upcase(first) <> rest
  end
end
