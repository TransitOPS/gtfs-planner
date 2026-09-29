defmodule GtfsPlanner.Gtfs.Blocking.LowerBoundTest do
  @moduledoc """
  EV-4: the minimum possible follows R8. The expectations come from R8's own
  three-trip example, from the exclusions `Checks.sequence/1` already makes, and
  from an exhaustive enumeration of the smallest number of chains that is
  feasible under the layover rule alone — the independent check behind AC-13 and
  the answer to FH-4, that the minimum is overstated.

  The oracle is not the interval count under another name. It partitions the
  day's trips into blocks of trips one vehicle could chain, and reports the
  fewest such blocks: every partition of up to seven trips is enumerated, and a
  block counts as one vehicle when its trips, taken in order of departure, chain
  — trip j may follow trip i only when j departs at or after i arrives plus the
  layover. In the travel-free case the fewest chains equals the peak, which is
  what makes the equality assertion meaningful; garage travel, relief and vehicle
  types, which no chain models, can only raise the count a feasible plan needs,
  never lower it below this bound.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.LowerBound

  # Service-day seconds. The three trips touch exactly at 06:30 and 07:00.
  @t0600 6 * 3600
  @t0630 @t0600 + 30 * 60
  @t0700 @t0600 + 3600
  @t0730 @t0600 + 90 * 60

  @seconds_per_minute 60

  defp trip(trip_id, first_departure, last_arrival, opts \\ []) do
    %{
      trip_id: trip_id,
      id: trip_id,
      first_departure: first_departure,
      last_arrival: last_arrival,
      first_arrival: first_departure,
      last_departure: last_arrival,
      frequency?: Keyword.get(opts, :frequency?, false),
      plottable?: Keyword.get(opts, :plottable?, true)
    }
  end

  defp three_trips do
    [
      trip("t1", @t0600, @t0630),
      trip("t2", @t0630, @t0700),
      trip("t3", @t0700, @t0730)
    ]
  end

  describe "compute/2" do
    test "a zero layover lets one vehicle cover three trips that touch" do
      assert LowerBound.compute(three_trips(), 0) == 1
    end

    test "a five-minute layover splits the same day across two vehicles" do
      # Each trip's end moves five minutes later, so no two of the three spans
      # nest: the peak is two, at 06:30 and again at 07:00.
      assert LowerBound.compute(three_trips(), 5) == 2
    end

    test "a layover longer than any gap needs one vehicle per trip" do
      assert LowerBound.compute(three_trips(), 60) == 3
    end

    test "excludes frequency-based and unplottable trips" do
      trips = [
        trip("t1", @t0600, @t0630),
        trip("t2", @t0630, @t0700, frequency?: true),
        trip("t3", @t0700, @t0730, plottable?: false)
      ]

      assert LowerBound.compute(trips, 0) == 1
      assert LowerBound.compute([trip("f1", @t0600, @t0630, frequency?: true)], 0) == 0
      assert LowerBound.compute([trip("u1", @t0600, @t0630, plottable?: false)], 10) == 0
    end

    test "overlapping trips count once each" do
      trips = [trip("t1", @t0600, @t0700), trip("t2", @t0630, @t0730)]

      assert LowerBound.compute(trips, 0) == 2
    end

    test "a day with no eligible trip is zero" do
      assert LowerBound.compute([], 10) == 0
    end

    test "is not above the chain cover, and equals it, on 200 seeded instances" do
      for {trips, layover} <- instances(200, 12) do
        feasible = min_chains(trips, layover * @seconds_per_minute)
        bound = LowerBound.compute(rows(trips), layover)

        assert feasible >= bound,
               "chain cover #{feasible} is below the bound #{bound} for #{inspect(trips)}"

        assert bound == feasible,
               "bound #{bound} is not the chain cover #{feasible} for #{inspect(trips)} at layover #{layover}"
      end
    end
  end

  # Seeded instances, so a failure reproduces: `:exsss` with a fixed seed gives
  # the same sequence on every run. Departures land on whole minutes inside four
  # hours and durations run from 10 to 40 minutes, which mixes touching,
  # overlapping, nesting and cleanly separated trips.
  defp instances(count, seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    Enum.map(1..count, fn index ->
      size = :rand.uniform(7)

      trips =
        Enum.map(1..size, fn position ->
          start_secs = :rand.uniform(240) * 60
          duration = (10 + :rand.uniform(31)) * 60

          {"trip-#{index}-#{position}", start_secs, start_secs + duration}
        end)

      {trips, :rand.uniform(31) - 1}
    end)
  end

  defp rows(trips) do
    Enum.map(trips, fn {trip_id, start_secs, end_secs} -> trip(trip_id, start_secs, end_secs) end)
  end

  # The fewest vehicles whose trips can be chained: every partition of the day's
  # trips into chains is enumerated, and a chain is feasible when consecutive
  # trips, in order of departure, satisfy the layover rule.
  defp min_chains(trips, layover_secs) do
    indexed =
      trips
      |> Enum.with_index()
      |> Enum.map(fn {trip, index} -> {index, elem(trip, 1), elem(trip, 2)} end)

    partitions(indexed)
    |> Enum.filter(fn partition -> Enum.all?(partition, &chain?(&1, layover_secs)) end)
    |> case do
      [] -> length(trips)
      found -> found |> Enum.map(&length/1) |> Enum.min()
    end
  end

  # All set partitions of the given elements, as lists of groups in creation
  # order. Each element either joins one of the groups already opened, or opens
  # a group of its own, so every partition is produced exactly once: seven
  # elements give 877 of them.
  defp partitions(list), do: assign(list, [])

  defp assign([], groups), do: [groups]

  defp assign([element | rest], groups) do
    joined =
      groups
      |> Enum.with_index()
      |> Enum.flat_map(fn {group, index} ->
        assign(rest, List.replace_at(groups, index, [element | group]))
      end)

    joined ++ assign(rest, groups ++ [[element]])
  end

  # A group is one vehicle's day when its trips chain. Sorting by departure is
  # the order to test, and it is the only candidate: a link needs the later trip
  # to depart at or after the earlier trip's arrival plus the layover, which is
  # after the earlier trip's own departure, so a chain's departures strictly
  # increase and the sorted order is it. A trip whose arrival equalled its
  # departure would break that argument, but such a trip has no duration and is
  # not schedulable data.
  defp chain?([_single], _layover_secs), do: true

  defp chain?(group, layover_secs) do
    group
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [earlier, later] -> elem(later, 1) >= elem(earlier, 2) + layover_secs end)
  end
end
