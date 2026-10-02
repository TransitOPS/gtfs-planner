defmodule GtfsPlanner.Gtfs.Fares.PeriodCalendar do
  @moduledoc "Builds fare-only weekday service calendars for pricing and export."
  @weekday_bits %{
    monday: 1,
    tuesday: 2,
    wednesday: 4,
    thursday: 8,
    friday: 16,
    saturday: 32,
    sunday: 64
  }

  # The span the fare-only services run over: the version's own weekly range,
  # and otherwise the range its exception dates cover. A version with neither
  # has no span to state, and a period with no span is left out rather than
  # written with dates the feed never had.
  def build(periods, rows) do
    periods = Enum.sort_by(periods, & &1.timeframe_group_id)

    case span(rows) do
      nil ->
        {[], %{}}

      {first, last} ->
        {ids, renames} = service_ids(periods, rows)
        {Enum.zip_with(periods, ids, &row(&1, &2, first, last)), renames}
    end
  end

  def span(rows) do
    starts = Enum.map(rows.calendars, & &1.start_date) ++ Enum.map(rows.calendar_dates, & &1.date)
    ends = Enum.map(rows.calendars, & &1.end_date) ++ Enum.map(rows.calendar_dates, & &1.date)

    case {Enum.reject(starts, &is_nil/1), Enum.reject(ends, &is_nil/1)} do
      {[], _} -> nil
      {_, []} -> nil
      {from, to} -> {Enum.min(from), Enum.max(to)}
    end
  end

  def row(period, service_id, start_date, end_date) do
    weekdays =
      Map.new(@weekday_bits, fn {day, bit} -> {day, weekday(period.weekdays, bit)} end)

    Map.merge(weekdays, %{service_id: service_id, start_date: start_date, end_date: end_date})
  end

  # A blank mask is every day, which is what `FareTimePeriod.changeset/2` says a
  # mask of no bits means.
  defp weekday(nil, _bit), do: 1
  defp weekday(mask, bit), do: if(Bitwise.band(mask, bit) == bit, do: 1, else: 0)
  @service_suffix_limit 999

  # R10's re-check. A period's own stored service id is not a collision with
  # itself, and every other period's id is taken, so two periods can never
  # share one in the output.
  def service_ids(periods, rows) do
    taken =
      MapSet.new(
        Enum.map(rows.calendars, & &1.service_id) ++
          Enum.map(rows.calendar_dates, & &1.service_id)
      )

    {assigned, _taken, renames} =
      Enum.reduce(periods, {[], taken, %{}}, fn period, {assigned, taken, renames} ->
        {service_id, taken} = free_service_id(period.service_id, taken)

        renames =
          if service_id == period.service_id,
            do: renames,
            else: Map.put(renames, period.service_id, service_id)

        {[service_id | assigned], MapSet.put(taken, service_id), renames}
      end)

    {Enum.reverse(assigned), renames}
  end

  defp free_service_id(nil, taken), do: {nil, taken}

  defp free_service_id(service_id, taken) do
    if MapSet.member?(taken, service_id) do
      suffixed_service_id(service_id, taken, 2)
    else
      {service_id, taken}
    end
  end

  defp suffixed_service_id(base, taken, suffix) when suffix <= @service_suffix_limit do
    candidate = "#{base}_#{suffix}"

    if MapSet.member?(taken, candidate) do
      suffixed_service_id(base, taken, suffix + 1)
    else
      {candidate, taken}
    end
  end

  # Past the limit the id is left as it is: a version needing 998 suffixes is a
  # configuration problem, and a service id that collides is reported by
  # `Fares.Checks.run/2` rather than silently rewritten here.
  defp suffixed_service_id(base, taken, _suffix), do: {base, taken}
end
