defmodule GtfsPlanner.Gtfs.Runs.Cutter do
  @moduledoc """
  Cuts one segment of a block into pieces at relief handovers (domain rule 10).

  ## The greedy ceiling, and why it is here on purpose

  Given a piece limit, this cuts at the **latest** handover that keeps the piece
  within the limit — not the earliest. That is a deliberate ceiling, and it is
  the one place in the runs derivation where a worse answer is chosen on
  purpose.

  A greedy earliest cut would produce the shortest possible first piece, which
  sounds better and is not. It hands the operator away as soon as the limit
  allows and gives the remainder a second break to recover from, and over a long
  block it produces a run chopped into pieces that are each comfortably short
  and collectively worse to work. Cutting as late as the limit allows keeps an
  operator on duty for as long as the rules permit, and only splits when a split
  is actually forced.

  The ceiling is the other half, and it is where this gives up. When **no**
  handover keeps the piece within the limit, this cuts at the *earliest* one
  anyway and accepts a first piece longer than the limit. It does not search for
  a shorter arrangement, because there is none: the handovers are where they are
  and the limit is what it is. An over-long first piece is then reported as
  `:piece_too_long` by `Runs.Checks` and a planner sees it, which is a better
  outcome than refusing to cut and leaving a segment that cannot be a piece at
  all.

  ## Measuring from the segment, not the block

  The limit is measured from the **segment's** own start, not the block's. A
  segment that begins mid-block — because earlier trips were already assigned —
  has a shorter remaining duty, and measuring from the block's start would
  shorten its allowance by hours and cut it far earlier than the rule intends.

  ## What a candidate is

  A candidate is one of the segment's **internal** gaps — a gap between two
  trips the segment actually contains — and each gap contributes **at most one**
  candidate: its first window, in the order `Blocking.Relief.windows/3` lists
  them, which puts an `:origin` window before a `:destination` one. A gap
  outside the segment, or between two trips that are not both in it, is not a
  place this segment can be handed over and is not a candidate.

  The candidate instant is the window's `start_secs`, which is the same instant
  `Runs.Pieces.derive/2` hands over at. A cut and a later derivation therefore
  agree on where a change happens, which is what lets a cut be applied and then
  re-derived without moving.

  ## What the pieces are, and are not

  `cut/3` returns the segment split into pieces with their trips, their times
  and the handovers between them. It does **not** return fully-formed pieces,
  and cannot: a `Relief.window` carries a stop **ID** and no coordinates, so a
  hand-over's `stop`, `start_stop` or `end_stop` cannot be filled in here without
  inventing them. Inventing a coordinate would be worse than leaving it out —
  it would produce a piece that looks complete and measures a drive from a
  fabricated position.

  So this module decides **where** the cut is, and `Runs.Pieces.derive/2` builds
  the real pieces from the block's stops once the assignments exist. Stop
  coordinates, the boundary structs and gap ownership are all that module's
  business; the cut gap itself is the boundary between the two pieces returned
  here, and is recoverable from the last trip of the first and the first of the
  second.
  """

  alias GtfsPlanner.Gtfs.Blocking.Relief

  @minute 60

  @type scope :: :uncovered_only | :replace_all

  @doc """
  Cuts one segment into pieces at the relief handovers inside it.

  `segment` is the piece-shaped segment to cut, `windows` its block's windows
  from `Blocking.Relief.windows/3`, and `max_piece_minutes` the version's piece
  limit or `nil` when none is set.

  Returns a list of one or more pieces in time order. One segment with no
  internal window, and any segment at all with a `nil` limit, comes back
  unchanged as a single piece.
  """
  @spec cut(map(), [Relief.window()], pos_integer() | nil) :: [map()]
  def cut(segment, windows, max_piece_minutes) do
    internal = internal_gap_indices(segment)
    candidates = candidates(windows, internal)

    case choose(candidates, segment.start_secs, max_piece_minutes) do
      nil -> [segment]
      window -> split(segment, window, internal)
    end
  end

  # The first window of each of the segment's internal gaps, in time order. A
  # gap contributes one candidate however many windows it has, so an `:origin`
  # and a `:destination` window on the same gap are one handover, not two
  # competing cut points.
  defp candidates(windows, internal) do
    windows
    |> Enum.filter(&(&1.gap_index in internal))
    |> Enum.uniq_by(& &1.gap_index)
    |> Enum.sort_by(& &1.start_secs)
  end

  # A gap is internal when it joins two trips that are consecutive *inside this
  # segment*. Matching on the trip pair rather than on a range of gap indices is
  # what makes a segment that starts mid-block behave: the block's earlier gaps
  # exist but are not places this segment can be handed over.
  defp internal_gap_indices(segment) do
    by_pair = Map.new(segment.gaps, &{{&1.from_id, &1.to_id}, &1.index})

    segment.trips
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [from, to] ->
      case Map.fetch(by_pair, {from.id, to.id}) do
        {:ok, index} -> [index]
        :error -> []
      end
    end)
  end

  # The greedy ceiling: the latest candidate that still fits, and otherwise the
  # earliest one, accepting that the piece will be over the limit.
  defp choose(_candidates, _start_secs, nil), do: nil

  defp choose([], _start_secs, _limit), do: nil

  defp choose(candidates, start_secs, limit) do
    limit_secs = limit * @minute

    case Enum.filter(candidates, &(&1.start_secs - start_secs <= limit_secs)) do
      [] -> hd(candidates)
      fitting -> List.last(fitting)
    end
  end

  # The chosen window names one of the segment's internal gaps, and the *k*-th
  # internal gap is the one between the segment's *k*-th and (*k*+1)-th trips —
  # which is what turns a handover instant into a place to split.
  defp split(segment, window, internal) do
    position = Enum.find_index(internal, &(&1 == window.gap_index))
    before = Enum.take(internal, position + 1)
    at = window.start_secs
    stop = {:stop, window.stop_id}

    [
      %{
        segment
        | trips: Enum.slice(segment.trips, 0, position + 1),
          end_secs: at,
          end_kind: :relief,
          end_ref: stop,
          gaps: Enum.filter(segment.gaps, &(&1.index in before))
      },
      %{
        segment
        | trips: Enum.slice(segment.trips, (position + 1)..-1//1),
          start_secs: at,
          start_kind: :relief,
          start_ref: stop,
          gaps: Enum.reject(segment.gaps, &(&1.index in before))
      }
    ]
  end
end
