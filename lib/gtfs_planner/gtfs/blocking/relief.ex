defmodule GtfsPlanner.Gtfs.Blocking.Relief do
  @moduledoc """
  The instants a relief (operator) change may happen in one block, and the
  unrelieved stretches between them, as R5 and R6 define them.

  Relief is derived, never stored (INV-8): a relief point is a marked stop or
  station in the version's `relief_points` rows, `windows/3` turns a block's
  movements into the instants a change is possible, and `stretches/3` measures
  the time between the changes that were taken. The day load, the checks, the
  generator and the page all read this result rather than repeating the rule.

  A window is a half-open-in-spirit interval of service-day seconds in which one
  change may happen: a layover at a marked location gives `[arrival,
  departure]`, and a drive `d` with the origin marked gives `[arrival,
  departure - d]` while the destination marked gives `[arrival + d, departure]`.
  All arithmetic is in service-day seconds, so a negative arrival or an end
  above 86,400 is an ordinary value here, exactly as in `Movements`.

  A stop is marked when its own `stop_id` or its `parent_station` is in
  `context.relief_stop_ids`, so marking a station covers its child stops — the
  two bays of a Riverside Station are one relief point, not two. Only a
  *feasible* gap produces a window. An infeasible gap (the vehicle cannot get
  there in time) and an unknown drive (its duration was never computable) both
  produce none: there is no window a change could honestly be planned into, and
  a window invented from a drive the version cannot compute would be a lie the
  checks would then have to contradict.

  R6 asks for the schedule whose longest unrelieved stretch is as short as it can
  be, and that is what `stretches/3` returns: a block whose stretches all sit
  within the limit is genuinely staffable, and one that cannot be is reported at
  its true length rather than at the length a merely plausible schedule happened
  to produce. R5's same-gap spacing is honoured throughout, because the vehicle
  is behind the wheel for that drive and a change cannot happen inside it: a
  100-minute gap with an 80-minute drive, both ends marked and a 60-minute limit
  leaves an 80-minute stretch, which is over the limit and is exactly what the
  check should report. A change is placed in each window at most once, so a
  relief point is the place a vehicle is handed over rather than an interval a
  driver is swapped in and out of.

  The module is pure: it reads its arguments and calls no repository, clock,
  file or network (CR-1). `windows/3` takes the block's `Checks.sequence/1` trips,
  the `Movements.build/3` result for the same block and the planning context;
  `stretches/3` takes that movements map, the windows and the relief limit in
  seconds (`nil` for "no limit set").
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements

  @type window :: %{
          gap_index: non_neg_integer(),
          side: :same | :origin | :destination,
          stop_id: String.t(),
          start_secs: integer(),
          end_secs: integer(),
          drive_secs: non_neg_integer()
        }

  @type stretch :: %{from_secs: integer(), to_secs: integer(), secs: non_neg_integer()}

  @doc """
  Returns every instant a relief change may happen in one block, as R5 defines
  them.

  `movements` is the `Movements.build/3` result for the same trips, which
  carries each gap's arrival, departure, kind, drive and feasibility; the
  endpoint stops come from `trips`, which must be the block's trips in
  `Checks.sequence/1` order so the gaps line up with the pairs of consecutive
  trips. Windows are returned in gap order, and a gap with both ends marked
  returns its `:origin` window before its `:destination` one, so a caller
  walking them in order meets the origin before the change that must follow it.
  """
  @spec windows([Checks.trip_row()], Movements.t(), Context.t()) :: [window()]
  def windows(trips, movements, context) do
    sequence = Checks.sequence(trips)
    endpoints = Enum.zip(sequence, Enum.drop(sequence, 1))

    movements.gaps
    |> Enum.zip(endpoints)
    |> Enum.flat_map(fn {gap, {from, to}} -> gap_windows(gap, from, to, context) end)
  end

  @doc """
  Returns the unrelieved stretches of one block, in order, as R6 defines them.

  A stretch is the time from the platform start, or from the last change taken,
  to the next change or to the platform end. With a `limit_secs` the result is
  the schedule with the shortest achievable longest stretch, so a stretch that
  must span a drive is reported at its true length even when that puts it over
  the limit. With `nil` there is no contract to respect, so every window's start
  is used and the stretches are whatever the marked locations imply; the caller
  raises no finding in that case.

  A block with no trips has no platform span and therefore no stretch.
  """
  @spec stretches(Movements.t(), [window()], pos_integer() | nil) :: [stretch()]
  def stretches(movements, windows, limit_secs) do
    case {movements.platform_start_secs, movements.platform_end_secs} do
      {start, finish} when is_integer(start) and is_integer(finish) ->
        points =
          case limit_secs do
            nil -> earliest_points(windows, start)
            _limit -> optimal_points(windows, start, finish)
          end

        spans([start | points] ++ [finish])

      _no_platform ->
        []
    end
  end

  # --- windows ---------------------------------------------------------------

  # A gap and the pair of trips it joins. `Movements` already decided the kind,
  # the drive and the feasibility, so this reads that answer rather than
  # recomputing the handoff.
  defp gap_windows(gap, from, to, context) do
    if gap.feasible? == true do
      case gap.kind do
        :layover -> same_windows(gap, from, to, context)
        :drive -> drive_windows(gap, from, to, context)
        # An unknown drive has no `feasible?` claim at all and reaches this
        # clause only through a hand-assembled map, so it gets no window.
        :unknown -> []
      end
    else
      []
    end
  end

  # A layover keeps the vehicle in one place for the whole gap, so a marked
  # location opens the entire interval. The `stop_id` names the marked endpoint
  # so a caller can show where the change happens.
  defp same_windows(gap, from, to, context) do
    case marked_stop(from.last_stop, to.first_stop, context) do
      nil ->
        []

      stop_id ->
        [window(gap, :same, stop_id, gap.arrival_secs, gap.departure_secs, 0)]
    end
  end

  # A drive splits the gap into a wait at each end, so each marked end opens its
  # own window. The origin's window ends `d` before the departure (the vehicle
  # must still make the drive) and the destination's begins `d` after the
  # arrival.
  defp drive_windows(gap, from, to, context) do
    origin =
      if marked?(from.last_stop, context) do
        [
          window(
            gap,
            :origin,
            from.last_stop.stop_id,
            gap.arrival_secs,
            gap.departure_secs - gap.drive_secs,
            gap.drive_secs
          )
        ]
      else
        []
      end

    destination =
      if marked?(to.first_stop, context) do
        [
          window(
            gap,
            :destination,
            to.first_stop.stop_id,
            gap.arrival_secs + gap.drive_secs,
            gap.departure_secs,
            gap.drive_secs
          )
        ]
      else
        []
      end

    origin ++ destination
  end

  defp window(gap, side, stop_id, start_secs, end_secs, drive_secs) do
    %{
      gap_index: gap.index,
      side: side,
      stop_id: stop_id,
      start_secs: start_secs,
      end_secs: end_secs,
      drive_secs: drive_secs
    }
  end

  # A stop counts as marked through its own ID or through its parent station, so
  # marking a station covers every stop beneath it.
  defp marked?(nil, _context), do: false

  defp marked?(stop, context) do
    MapSet.member?(context.relief_stop_ids, stop.stop_id) or
      (is_binary(stop.parent_station) and
         MapSet.member?(context.relief_stop_ids, stop.parent_station))
  end

  # The marked endpoint of a layover, preferring the trip's last stop so the
  # window names where the vehicle actually is.
  defp marked_stop(from_stop, to_stop, context) do
    cond do
      marked?(from_stop, context) -> from_stop.stop_id
      marked?(to_stop, context) -> to_stop.stop_id
      true -> nil
    end
  end

  # --- stretches -------------------------------------------------------------

  # With no limit there is nothing to optimise against, so every window's start
  # is taken and the result is the marked locations themselves. Windows that do
  # not advance the clock are dropped, so two windows opening at the same instant
  # produce one change rather than a zero-length stretch.
  defp earliest_points(windows, start) do
    windows
    |> Enum.map(& &1.start_secs)
    |> Enum.filter(&(&1 > start))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The instants a change may be planned for sit on a 60 s grid inside each
  # window, which is the resolution EV-10's oracle searches.
  @change_step 60

  # R6's schedule, made exact.
  #
  # R6 asks for "the latest change instant reachable within the limit" and its
  # reconciliation calls that greedy optimal for "can every stretch be within the
  # limit". It is not. Taking the latest reachable instant spends a window near
  # its far end, so a window that could have closed the tail is left with nothing
  # to give. The smallest counterexample the test oracle produces is two windows
  # [120, 1260] and [1620, 2040] on a 0..3960 platform with a 1920 s limit: the
  # greedy changes at 1920 and then strands a 2040 s tail, while changing at 120
  # and 2040 gives stretches of 120, 1920 and 1920 -- within the limit. So this
  # returns the *best* schedule, which is what AC-11 and EV-10's oracle hold it
  # to, and a block that can be covered is never reported as uncoverable.
  #
  # The limit is the contract the schedule is judged against rather than a knob
  # that reshapes it: the search returns the plan with the shortest possible
  # longest stretch, and the caller raises a finding when that stretch is still
  # over the limit.
  defp optimal_points(windows, start, finish) do
    windows
    |> group_by_gap()
    |> Enum.reduce(%{start => {0, []}}, fn {_gap_index, group}, states ->
      states
      |> advance(group, finish)
      |> prune()
    end)
    |> Enum.map(fn {last, {worst, plan}} -> {max(worst, finish - last), plan} end)
    |> Enum.min_by(fn {worst, plan} -> {worst, plan} end)
    |> elem(1)
  end

  # Gaps in time order, so the search never revisits a gap it has passed: the
  # windows of gap `n` close where the windows of gap `n + 1` open.
  defp group_by_gap(windows) do
    windows
    |> Enum.group_by(& &1.gap_index)
    |> Enum.sort_by(fn {_gap_index, group} -> Enum.min(Enum.map(group, & &1.start_secs)) end)
  end

  # Every legal way to use one gap's windows: no change, one change in a single
  # window, or -- for a drive with both ends marked -- an origin change followed
  # by a destination change at least a drive later, because one operator drives
  # the whole of that drive and the drive is never inside a window (R5).
  defp gap_options(group) do
    origin = Enum.find(group, &(&1.side == :origin))
    destination = Enum.find(group, &(&1.side == :destination))

    singles =
      for window <- group, instant <- instants(window) do
        %{first: instant, last: instant, inner: 0, points: [instant]}
      end

    pairs =
      case {origin, destination} do
        # Both ends of the drive marked: the change after the origin one follows
        # the whole drive. The two windows are not always disjoint -- they
        # overlap whenever the wait outlasts the drive -- so the spacing rule is
        # the invariant, not a gap between them. A gap with only one end marked
        # has no pair to place and falls through to no case.
        {%{drive_secs: drive} = from, %{start_secs: _, end_secs: _} = to} ->
          for earlier <- instants(from), later <- instants(to), later >= earlier + drive do
            %{first: earlier, last: later, inner: later - earlier, points: [earlier, later]}
          end

        _no_paired_ends ->
          []
      end

    [%{first: nil, last: nil, inner: 0, points: []} | singles ++ pairs]
  end

  defp instants(window), do: Enum.to_list(window.start_secs..window.end_secs//@change_step)

  # Carry every state forward unchanged -- the gap may host no change -- and add
  # the transitions that do take one. Each window is used at most once because a
  # transition only ever reads the states that existed before this gap.
  defp advance(states, group, finish) do
    # Every transition reads the states as they were *before* this gap, never the
    # ones an earlier option in the same gap just added. That is what keeps a
    # window to a single change.
    before = states

    Enum.reduce(gap_options(group), states, fn
      %{first: nil}, acc ->
        acc

      option, acc ->
        Enum.reduce(before, acc, fn {prev, {worst, plan}}, acc ->
          if option.first > prev and option.first <= finish do
            worst = max(worst, max(option.first - prev, option.inner))
            candidate = {worst, plan ++ option.points}

            Map.update(acc, option.last, candidate, fn current ->
              if candidate < current, do: candidate, else: current
            end)
          else
            acc
          end
        end)
    end)
  end

  # A state at least as late and no worse than another can only help what comes
  # next, so the rest are dropped. That keeps the search proportional to the
  # instants a block actually offers instead of exponential in its gaps, and it
  # never removes a state that could have won.
  defp prune(states) do
    states
    |> Enum.sort_by(fn {last, _value} -> -last end)
    |> Enum.reduce({[], nil}, fn {_last, value} = state, {kept, best} ->
      worst = elem(value, 0)

      if is_nil(best) or worst < best do
        {[state | kept], worst}
      else
        {kept, best}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Map.new()
  end

  # The change points tile the platform, so each pair is a stretch. A change can
  # land exactly on the platform end, which leaves no stretch after it, so pairs
  # that run backwards or have no length are dropped rather than reported as a
  # negative duration.
  defp spans(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from_secs, to_secs] -> {from_secs, to_secs} end)
    |> Enum.filter(fn {from_secs, to_secs} -> to_secs > from_secs end)
    |> Enum.map(fn {from_secs, to_secs} ->
      %{from_secs: from_secs, to_secs: to_secs, secs: to_secs - from_secs}
    end)
  end
end
