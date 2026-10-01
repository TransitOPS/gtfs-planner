defmodule GtfsPlanner.Gtfs.Rosters.BaseWeek do
  @moduledoc """
  Resolves the base week: which day type each ISO weekday works.

  A roster line repeats every week of the service period, so each weekday needs
  exactly one day type to take its runs from. `blocking_settings.roster_day_types`
  stores that choice as `"1".."7"` → day-type key; a missing entry, a key that is
  no longer a day type, or a day type with no date on that weekday all fall back
  to the computed default: the day type with the most dates on that weekday, ties
  going to the day type that comes first in the `Blocking.DayTypes.derive/1` list.
  A weekday no day type dates has no base, and no slot can be set on it.

  A fallback is never silent. `missing_choice` names the stored key that could
  not be used, so the page can say "Base week changed" instead of quietly using
  another day's service (INV-6).

  Pure: it reads no repository, clock, file or network, and writes nothing. The
  day types arrive from `Blocking.DayTypes.derive/1` and the choices from
  `BlockingSetting.roster_day_types`.
  """

  alias GtfsPlanner.Gtfs.Blocking.DayTypes

  @weekdays 1..7
  @names ~w(Mon Tue Wed Thu Fri Sat Sun)

  @typedoc "One weekday's base day type, where it came from, and the stored key that failed."
  @type base :: %{
          day_type: DayTypes.day_type() | nil,
          chosen?: boolean(),
          missing_choice: String.t() | nil
        }

  @typedoc "The whole week, keyed by ISO weekday (1 = Monday)."
  @type t :: %{(1..7) => base()}

  @doc """
  Resolves each weekday's base day type from the day types and the stored choices.

  The choice map is `blocking_settings.roster_day_types`, keyed by the weekday as
  a string. A weekday with a usable stored choice is `chosen?`; every other
  weekday falls back to the default and carries the unusable key in
  `missing_choice`, or `nil` when there was no choice to begin with.
  """
  @spec resolve([DayTypes.day_type()], %{optional(String.t()) => String.t()}) :: t()
  def resolve(day_types, choices) do
    Map.new(@weekdays, fn weekday ->
      {weekday,
       base_for_weekday(day_types, Map.get(choices, Integer.to_string(weekday)), weekday)}
    end)
  end

  @doc """
  Groups the weekdays that share a base day type, each with a label.

  Weekdays with no base day type are left out. The groups come back in week
  order, and a label joins consecutive weekdays as a range ("Mon–Fri") and the
  rest with commas ("Mon, Wed").
  """
  @spec groups(t()) :: [%{day_type: DayTypes.day_type(), weekdays: [1..7], label: String.t()}]
  def groups(base_week) do
    base_week
    |> Enum.sort_by(fn {weekday, _base} -> weekday end)
    |> Enum.flat_map(fn
      {weekday, %{day_type: %{} = day_type}} -> [{weekday, day_type}]
      {_weekday, %{day_type: nil}} -> []
    end)
    |> Enum.group_by(fn {_weekday, day_type} -> day_type.key end, fn pair -> pair end)
    |> Enum.map(fn {_key, weekdays_and_types} ->
      weekdays = weekdays_and_types |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      {weekdays, weekdays_and_types |> hd() |> elem(1), label(weekdays)}
    end)
    |> Enum.sort_by(fn {weekdays, _day_type, _label} -> hd(weekdays) end)
    |> Enum.map(fn {weekdays, day_type, label} ->
      %{day_type: day_type, weekdays: weekdays, label: label}
    end)
  end

  defp base_for_weekday(day_types, nil, weekday) do
    %{day_type: default_day_type(day_types, weekday), chosen?: false, missing_choice: nil}
  end

  defp base_for_weekday(day_types, key, weekday) do
    case Enum.find(day_types, &(&1.key == key)) do
      %{dates: dates} = day_type ->
        if Enum.any?(dates, &(Date.day_of_week(&1) == weekday)) do
          %{day_type: day_type, chosen?: true, missing_choice: nil}
        else
          fallback(day_types, weekday, key)
        end

      nil ->
        fallback(day_types, weekday, key)
    end
  end

  defp fallback(day_types, weekday, key) do
    %{day_type: default_day_type(day_types, weekday), chosen?: false, missing_choice: key}
  end

  defp default_day_type(day_types, weekday) do
    case Enum.filter(day_types, &works_on?(&1, weekday)) do
      [] ->
        nil

      candidates ->
        # Enum.max_by/2 keeps the first of several maxima, so a tie resolves to the
        # day type that comes first in the DayTypes.derive/1 list.
        Enum.max_by(candidates, &date_count_on(&1, weekday))
    end
  end

  defp works_on?(day_type, weekday), do: date_count_on(day_type, weekday) > 0

  defp date_count_on(day_type, weekday) do
    Enum.count(day_type.dates, &(Date.day_of_week(&1) == weekday))
  end

  defp label(weekdays) do
    weekdays
    |> runs()
    |> Enum.map_join(", ", fn
      [weekday] -> name(weekday)
      [first | _] = run -> Enum.join([name(first), name(List.last(run))], "–")
    end)
  end

  # Splits sorted weekdays into consecutive runs. Each run is built in reverse, so
  # its head is the weekday just added.
  defp runs([]), do: []
  defp runs([weekday | rest]), do: extend_run([weekday], rest)

  defp extend_run(run, [weekday | rest] = all) do
    if weekday == hd(run) + 1 do
      extend_run([weekday | run], rest)
    else
      [Enum.reverse(run) | runs(all)]
    end
  end

  defp extend_run(run, []), do: [Enum.reverse(run)]

  defp name(weekday), do: Enum.at(@names, weekday - 1)
end
