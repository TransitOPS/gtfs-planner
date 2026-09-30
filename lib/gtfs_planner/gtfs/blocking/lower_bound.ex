defmodule GtfsPlanner.Gtfs.Blocking.LowerBound do
  @moduledoc """
  The fewest vehicles the day could possibly need.

  A planner asks "how low could this go?" as a sanity check on a plan, and the
  honest answer is a bound rather than a target. Counting every plottable trip as
  one vehicle, or counting blocks, gives a number that can be *above* what any
  feasible plan needs, and a number above the truth is worse than no number: it
  reads as "you cannot do better" when the plan in front of the planner already
  does better. So this is a floor, never a quality score, and never something to
  optimize towards.

  The rule is the smallest number of vehicles that covers the day's trips, with
  no garage travel, no relief rule and no route or vehicle-type constraint: each
  eligible trip is the half-open span `[first_departure, last_arrival +
  min_layover)`, and the answer is the largest number of those spans open at one
  instant (`Schedules.Summary.peak_vehicles/1`). Because the layover extends the
  end rather than the start, three trips that touch exactly at 06:30 and 07:00
  need one vehicle with a zero layover and two with a five-minute one.

  The trips that count are the plottable, non-frequency ones, read from
  `Checks.sequence/1` so this module and the block checks agree on what a
  schedulable trip is. Frequency-based trips repeat and would be counted as a
  single run rather than as the concurrent demand they represent; an unplottable
  trip has no times to span. Both are reported as notices by
  `Checks.block_findings/3` instead.

  Attainability is deliberately not claimed. A plan that respects garage travel,
  relief opportunities and vehicle types can need more vehicles than this, and
  the difference is the interesting number, not this one.

  The module is pure: it computes from its arguments and calls no repository,
  clock, file or network.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Schedules, as: Schedules

  @seconds_per_minute 60

  @doc """
  Returns the fewest vehicles the day's trips could need.

  `trips` are the day type's `Checks.trip_row/0` maps and
  `min_layover_minutes` the context's minimum layover, which extends each trip's
  end. Empty or fully excluded input gives `0`. The result is a lower bound on any
  feasible plan's vehicle count, not an estimate of it.
  """
  @spec compute([Checks.trip_row()], 0..120) :: non_neg_integer()
  def compute(trips, min_layover_minutes)
      when is_list(trips) and min_layover_minutes in 0..120 do
    layover_secs = min_layover_minutes * @seconds_per_minute

    trips
    |> Checks.sequence()
    |> Enum.map(&span(&1, layover_secs))
    |> Schedules.Summary.peak_vehicles()
    |> Map.fetch!(:count)
  end

  defp span(trip, layover_secs) do
    %{start_secs: trip.first_departure, end_secs: trip.last_arrival + layover_secs}
  end
end
