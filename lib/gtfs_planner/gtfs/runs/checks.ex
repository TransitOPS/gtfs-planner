defmodule GtfsPlanner.Gtfs.Runs.Checks do
  @moduledoc """
  The findings a plan raises about its runs, its handovers and its uncovered work.

  Pure: it reads its arguments and calls no repository, clock, file or network,
  and it writes nothing. Every finding is a plain map so the page, the export and
  the day summary can count and group them without this module knowing about any
  of those.

      %{
        code:      :too_many_pieces | :cannot_reach_piece | :piece_too_long |
                   :spread_too_long | :travel_unknown | :not_at_relief | :uncovered_work,
        severity:  :error | :warning | :notice,
        run_ids:   [String.t()],
        block_id:  String.t() | nil,
        trip_ids:  [Ecto.UUID.t()],
        detail:    map()
      }

  Severity is what the page paints: `:error` red, `:warning` amber, `:notice`
  neutral. Findings come out errors first, then warnings, then notices, so a
  caller that truncates keeps the ones that stop a plan being published.

  ## What is deliberately not here

  This module reports; it does not repair. A run whose spread is too long still
  computes its work time and still appears, carrying a warning, and nothing is
  truncated, dropped or re-cut to make a limit pass (rule 9, AC-10).

  `:orphan_assignments` is the one code this module never raises. It is not a
  property of any run, piece or boundary: it counts assignment rows that belong
  to no current day type, which only a version's day can know. Step 12's
  `Runs.load_runs/3` appends it.
  """

  @minute 60

  @type finding :: %{
          code:
            :not_at_relief
            | :too_many_pieces
            | :cannot_reach_piece
            | :piece_too_long
            | :spread_too_long
            | :travel_unknown
            | :uncovered_work
            | :orphan_assignments,
          severity: :error | :warning | :notice,
          run_ids: [String.t()],
          block_id: String.t() | nil,
          trip_ids: [Ecto.UUID.t()],
          detail: map()
        }

  @doc """
  Findings about one run: too many pieces, pieces that cannot be reached, pieces
  or a spread over their limits, and travel that could not be resolved.

  `run_id` is the run's own identifier, `pieces` its pieces in any order and
  `work` the result of `Runs.WorkTime.compute/3` over them. A run with no piece
  has no findings.
  """
  @spec run_findings(String.t(), [map()], map(), map(), map()) :: [finding()]
  def run_findings(_run_id, [], _work, _context, _crew), do: []

  def run_findings(run_id, pieces, work, context, crew) do
    pieces = Enum.sort_by(pieces, & &1.start_secs)
    block_id = first(pieces).block_id

    errors =
      too_many_pieces(run_id, block_id, pieces) ++
        cannot_reach_piece(run_id, block_id, pieces, work)

    warnings =
      piece_too_long(run_id, block_id, pieces, context) ++
        spread_too_long(run_id, block_id, work, crew)

    notices = travel_unknown(run_id, block_id, work)

    errors ++ warnings ++ notices
  end

  @doc """
  Findings about a day's handovers.

  A boundary whose `at_relief?` is false is a change the plan had to make away
  from a relief point, and it is an error (rule 4). It names only the run that is
  actually there: a change *into* uncovered work has no run on the far side, and
  naming a run that is not involved would point a planner at the wrong operator.
  A boundary between two uncovered segments raises nothing here — the
  `:uncovered_work` warning is the page-level statement about them, and
  `:orphan_assignments` is step 12's.
  """
  @spec boundary_findings([map()]) :: [finding()]
  def boundary_findings(boundaries) do
    boundaries
    |> Enum.filter(&(not &1.at_relief? and change_of_run?(&1)))
    |> Enum.map(&not_at_relief/1)
  end

  @doc """
  The page-level warning about work no run covers, or `[]` when everything is
  covered.

  It is one finding for the whole set rather than one per segment: a planner
  needs to know that trips are unassigned and roughly how much duty they are
  worth, and a list of a dozen near-identical warnings buries that.
  """
  @spec uncovered_finding([map()]) :: [finding()]
  def uncovered_finding([]), do: []

  def uncovered_finding(segments) do
    trip_ids = Enum.flat_map(segments, & &1.trips) |> Enum.map(& &1.trip_id)
    secs = Enum.sum(Enum.map(segments, &(&1.end_secs - &1.start_secs)))

    [
      %{
        code: :uncovered_work,
        severity: :warning,
        run_ids: [],
        block_id: nil,
        trip_ids: trip_ids,
        detail: %{trips: length(trip_ids), secs: secs}
      }
    ]
  end

  # More than two pieces is a split the plan should not be carrying silently
  # (rule 9).
  defp too_many_pieces(run_id, block_id, pieces) when length(pieces) > 2 do
    [
      %{
        code: :too_many_pieces,
        severity: :error,
        run_ids: [run_id],
        block_id: block_id,
        trip_ids: [],
        detail: %{pieces: length(pieces)}
      }
    ]
  end

  defp too_many_pieces(_run_id, _block_id, _pieces), do: []

  defp first([piece | _]), do: piece

  # A negative break means the next piece cannot be reached (rule 8). The work
  # time already measured the gap, so the two numbers are read off it rather than
  # re-derived: what is available is the span between the two pieces, and what
  # is needed is whatever is left of it, which is the difference. That keeps
  # `needed_secs` and `available_secs` describing the same arithmetic the day was
  # built from even if a report or a drive is later tuned.
  defp cannot_reach_piece(run_id, block_id, pieces, work) do
    negative =
      work.breaks
      |> Enum.filter(&(&1.secs < 0))
      |> Map.new(&{&1.after_piece, &1.secs})

    pieces
    |> Enum.with_index(1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{previous, previous_index}, {next, _next_index}] ->
      case Map.fetch(negative, previous_index) do
        {:ok, secs} -> [cannot_reach(run_id, block_id, previous, next, previous_index, secs)]
        :error -> []
      end
    end)
  end

  defp cannot_reach(run_id, block_id, previous, next, index, secs) do
    available = next.start_secs - previous.end_secs

    %{
      code: :cannot_reach_piece,
      severity: :error,
      run_ids: [run_id],
      block_id: block_id,
      trip_ids: trip_ids(previous) ++ trip_ids(next),
      detail: %{
        piece: next.run_id,
        needed_secs: available - secs,
        available_secs: available,
        secs: secs,
        stop_id: stop_id(next, previous),
        after_piece: index
      }
    }
  end

  defp trip_ids(piece), do: Enum.map(piece.trips, & &1.trip_id)

  defp stop_id(next, previous) do
    cond do
      not is_nil(next.start_stop) -> next.start_stop.stop_id
      not is_nil(previous.end_stop) -> previous.end_stop.stop_id
      true -> nil
    end
  end

  # A piece over spec 07's own piece limit is a warning, and no check at all when
  # that limit is unset (rule 9).
  defp piece_too_long(run_id, block_id, pieces, context) do
    case context.max_piece_minutes do
      nil ->
        []

      limit ->
        limit_secs = limit * @minute

        pieces
        |> Enum.with_index(1)
        |> Enum.filter(fn {piece, _} -> piece.end_secs - piece.start_secs > limit_secs end)
        |> Enum.map(fn {piece, index} ->
          %{
            code: :piece_too_long,
            severity: :warning,
            run_ids: [run_id],
            block_id: block_id,
            trip_ids: trip_ids(piece),
            detail: %{
              piece: index,
              secs: piece.end_secs - piece.start_secs,
              limit_secs: limit_secs
            }
          }
        end)
    end
  end

  defp spread_too_long(run_id, block_id, work, crew) do
    limit_secs = crew.max_spread_minutes * @minute

    if work.spread_secs > limit_secs do
      [
        %{
          code: :spread_too_long,
          severity: :warning,
          run_ids: [run_id],
          block_id: block_id,
          trip_ids: [],
          detail: %{secs: work.spread_secs, limit_secs: limit_secs}
        }
      ]
    else
      []
    end
  end

  # One notice per leg the context could not answer. `Runs.WorkTime` already
  # charged it zero minutes; this is what stops that zero reading as reachable.
  defp travel_unknown(run_id, block_id, work) do
    work.unknown_travel
    |> Enum.map(fn leg ->
      %{
        code: :travel_unknown,
        severity: :notice,
        run_ids: [run_id],
        block_id: block_id,
        trip_ids: [],
        detail: %{from: leg.from, to: leg.to}
      }
    end)
  end

  # A boundary only matters here when a run actually changes hands across it.
  defp change_of_run?(boundary) do
    boundary.from_run != boundary.to_run and
      (not is_nil(boundary.from_run) or not is_nil(boundary.to_run))
  end

  defp not_at_relief(boundary) do
    stop = boundary.stop

    %{
      code: :not_at_relief,
      severity: :error,
      run_ids: [boundary.from_run, boundary.to_run] |> Enum.reject(&is_nil/1),
      block_id: boundary.block_id,
      trip_ids: [boundary.from_trip_id, boundary.to_trip_id],
      detail: %{
        stop_id: stop_id_of(stop),
        stop_name: name_of(stop),
        from_trip_id: boundary.from_trip_id,
        to_trip_id: boundary.to_trip_id
      }
    }
  end

  defp stop_id_of(nil), do: nil
  defp stop_id_of(stop), do: stop.stop_id

  defp name_of(nil), do: nil
  defp name_of(stop), do: stop.name
end
