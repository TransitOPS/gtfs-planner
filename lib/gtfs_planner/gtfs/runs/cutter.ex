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
  and the handovers between them. A handover's `start_ref`/`end_ref` is
  `{:stop, stop_id}` from the window, and its `start_stop`/`end_stop` is the full
  `stop_ref` **looked up from the segment's own trips** — the window carries only
  an ID, but the block's trips carry that stop's coordinates, and a piece whose
  handover stop is a real stop_ref can have its travel measured.

  That lookup is not cosmetic. A piece with a handover `ref` but no matching
  `stop` cannot be measured: the deadhead to and from it comes out as unknown or
  zero, and a run built from such pieces would be charged the wrong travel. The
  EV-10 sweep caught exactly that, in a run that reported a non-negative break to
  the pairing and a negative one once the day re-derived the same pieces with
  real coordinates. A stop the segment's trips do not mention is left `nil`,
  which `DeadheadTimes.lookup/5` answers as unknown — honest, and visible.

  What is still not here: the boundary structs and gap ownership, which
  `Runs.Pieces.derive/2` builds from the block once the assignments exist. The
  cut gap itself is the boundary between the two pieces returned here, and is
  recoverable from the last trip of the first and the first of the second.
  """

  alias GtfsPlanner.Gtfs.Blocking.Relief
  alias GtfsPlanner.Gtfs.Runs.Numbering
  alias GtfsPlanner.Gtfs.Runs.Pieces
  alias GtfsPlanner.Gtfs.Runs.WorkTime

  @minute 60

  @type scope :: :uncovered_only | :replace_all

  @doc """
  Scopes, cuts, pairs and numbers one day's runs, and returns the assignments a
  caller would write (domain rules 10 and 11).

  ## Scopes

  `:uncovered_only` takes only the segments no run currently covers and
  **changes no existing assignment**: the returned map is the one it was given
  plus the new work, so every run ID already in use survives with its trips.

  `:replace_all` ignores the assignments entirely and re-cuts every block's
  whole sequence, which is the rebuild a planner asks for when they want the
  whole day laid out again.

  ## Pairing

  Pieces sort by `(start_secs, block_id, first trip ID)`. Each unpaired piece
  takes the unpaired piece after it with the **shortest non-negative break**
  whose two-piece run still fits `max_spread_minutes`; ties go to the earlier
  start, then block, then first trip ID. Whatever is left unpaired is a
  one-piece run. Every number that decides this — the break and the spread —
  comes from the real `Runs.WorkTime.compute/3` over the pair, so pairing agrees
  with the work time the operator will actually be paid, by construction.

  ## The cost of the greedy

  Pairing is a scan of unpaired later pieces for each piece: **O(p²)** work time
  computations for `p` pieces. A single block yields at most one or two pieces,
  so a day of a few hundred blocks stays well inside a page load, and the
  quadratic is a deliberate ceiling rather than an oversight. It is written as a
  single pass with the candidate statistics computed once per pair, so the
  constant factor is one `compute/3` per candidate rather than two.

  ## Numbering

  New runs are numbered in **sign-on order**, which is the order `Day.derive/4`
  puts them in, so the page shows run 1, 2, 3 in the order it lists them. A
  rebuild starts from `rebuild_prefix/1` of the IDs already in use, because the
  day type already has a scheme; a suggestion on uncovered work starts from
  `highest_numeric/1`, because a hand-made run has to sit above everything
  already in use (rule 11).
  """
  @spec run(scope(), [map()], %{Ecto.UUID.t() => String.t()}, map(), map()) :: %{
          assignments: %{Ecto.UUID.t() => String.t()},
          new_run_ids: [String.t()]
        }
  def run(scope, blocks, assignments, context, crew) do
    segments = segments(scope, blocks, assignments)
    pieces = segments |> Enum.flat_map(&cut_segment(&1, context)) |> Enum.sort_by(&sort_key/1)
    groups = pair(pieces, context, crew)
    number(scope, groups, assignments, context, crew)
  end

  # `:uncovered_only` works on what is not covered; `:replace_all` starts from
  # the blocks themselves and ignores the assignments entirely.
  defp segments(:uncovered_only, blocks, assignments) do
    %{uncovered: uncovered} = Pieces.derive(blocks, assignments)
    Enum.map(uncovered, &%{segment: &1, windows: windows_for(blocks, &1.block_id)})
  end

  defp segments(:replace_all, blocks, _assignments) do
    Enum.map(blocks, fn block ->
      %{segment: block_segment(block), windows: block.windows}
    end)
  end

  defp windows_for(blocks, block_id) do
    case Enum.find(blocks, &(&1.block_id == block_id)) do
      nil -> []
      block -> block.windows
    end
  end

  # A block's whole sequence as one segment. Its ends are the same ends
  # `Runs.Pieces.derive/2` will give it — the pull-out's start and the
  # pull-back's end — and that matters rather than being tidiness: pairing
  # measures the break between segments with `WorkTime.compute/3`, so a segment
  # measured from the raw first departure would understate every piece by its
  # pull-out and pull-back buffer. The EV-10 sweep found that: pairs the cutter
  # accepted on raw departure and arrival times came back with negative breaks
  # once the day re-derived the same pieces with their buffers, which is FH-10
  # stated exactly. Its ends are the garage when it has one, which drops the
  # travel legs to and from it the same way step 5's same-place rule does.
  defp block_segment(block) do
    trips = block.trips
    first = hd(trips)
    last = List.last(trips)
    garage_id = block.movements.garage_id

    %{
      run_id: nil,
      block_id: block.block_id,
      garage_id: garage_id,
      route_id: first.route_id,
      trips: trips,
      start_secs: edge_start(block.movements.pull_out, first.first_departure),
      end_secs: edge_end(block.movements.pull_back, last.last_arrival),
      start_kind: :block_start,
      end_kind: :block_end,
      start_ref: edge_ref(garage_id, block.movements.pull_out, first.first_stop),
      end_ref: edge_ref(garage_id, block.movements.pull_back, last.last_stop),
      start_stop: first.first_stop,
      end_stop: last.last_stop,
      start_boundary: nil,
      end_boundary: nil,
      gaps: block.movements.gaps
    }
  end

  defp edge_start(nil, fallback), do: fallback
  defp edge_start(%{start_secs: start_secs}, _fallback), do: start_secs

  defp edge_end(nil, fallback), do: fallback
  defp edge_end(%{end_secs: end_secs}, _fallback), do: end_secs

  defp edge_ref(nil, _pull, stop), do: {:stop, stop.stop_id}
  defp edge_ref(garage_id, _pull, _stop), do: {:garage, garage_id}

  defp cut_segment(%{segment: segment, windows: windows}, context) do
    cut(segment, windows, context.max_piece_minutes)
  end

  defp sort_key(piece) do
    {piece.start_secs, piece.block_id, first_trip_id(piece)}
  end

  defp first_trip_id(piece), do: piece.trips |> hd() |> Map.fetch!(:trip_id)

  # One pass over the sorted pieces. Each unpaired piece either takes the best
  # later partner or is left as a one-piece run.
  defp pair(pieces, context, crew) do
    indexed = Enum.with_index(pieces)

    indexed
    |> pair_loop(context, crew, MapSet.new(), [])
    |> Enum.reverse()
  end

  defp pair_loop([], _context, _crew, _paired, groups), do: groups

  defp pair_loop([{piece, index} | rest], context, crew, paired, groups) do
    if MapSet.member?(paired, index) do
      pair_loop(rest, context, crew, paired, groups)
    else
      case best_partner(piece, rest, paired, context, crew) do
        nil ->
          # A group is always a list of pieces, so an unpaired piece is a
          # one-piece run rather than a bare piece.
          pair_loop(rest, context, crew, paired, [[piece] | groups])

        {_break_secs, _key, partner_index, partner} ->
          # Both pieces are now spoken for: this one took a partner, and the
          # partner is taken by being here.
          taken = paired |> MapSet.put(index) |> MapSet.put(partner_index)
          pair_loop(rest, context, crew, taken, [[piece, partner] | groups])
      end
    end
  end

  # The unpaired pieces after this one that can be run with it, cheapest break
  # first. `Enum.min_by/2` with a sorter breaks ties on the sort key, which is
  # the rule's "earlier start, block, first trip ID".
  defp best_partner(piece, rest, paired, context, crew) do
    rest
    |> Enum.reject(fn {_other, index} -> MapSet.member?(paired, index) end)
    |> Enum.flat_map(fn {other, index} ->
      case pair_stats(piece, other, context, crew) do
        {:ok, break_secs} -> [{break_secs, sort_key(other), index, other}]
        :error -> []
      end
    end)
    |> case do
      [] ->
        nil

      # Shortest break first, then the rule's tie-break: earlier start, then
      # block, then first trip ID.
      candidates ->
        Enum.min_by(candidates, fn {break_secs, key, _index, _piece} -> {break_secs, key} end)
    end
  end

  # A pair is usable when the real work time says the break is not negative and
  # the two-piece spread is inside the limit. Measuring it with
  # `WorkTime.compute/3` rather than with a simpler span is what keeps pairing
  # and the paid work in agreement.
  defp pair_stats(piece, other, context, crew) do
    work = WorkTime.compute([piece, other], context, crew)

    case work.breaks do
      [%{secs: secs}] ->
        if secs >= 0 and work.spread_secs <= crew.max_spread_minutes * @minute do
          {:ok, secs}
        else
          :error
        end

      _otherwise ->
        :error
    end
  end

  defp number(scope, groups, assignments, context, crew) do
    existing = assignments |> Map.values() |> Enum.uniq()

    base =
      if scope == :replace_all,
        do: Numbering.rebuild_prefix(existing),
        else: Numbering.highest_numeric(existing)

    ordered =
      groups
      |> Enum.map(fn group ->
        {WorkTime.compute(group, context, crew).sign_on_secs, sort_key(hd(group)), group}
      end)
      |> Enum.sort_by(fn {sign_on, key, _group} -> {sign_on, key} end)
      |> Enum.map(fn {_sign_on, _key, group} -> group end)

    run_ids = Numbering.numeric_after(base, length(ordered))

    # The assignment map is keyed by the trip's UUID, which is what the day load
    # and `Runs.Day.derive/4` read.
    written =
      Enum.zip(ordered, run_ids)
      |> Enum.flat_map(fn {group, run_id} ->
        Enum.flat_map(group, fn piece -> Enum.map(piece.trips, &{&1.id, run_id}) end)
      end)

    %{
      # `:uncovered_only` never changes an existing assignment; a rebuild has
      # already replaced them all.
      assignments: Map.merge(assignments, Map.new(written)),
      new_run_ids: run_ids
    }
  end

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
    ref = {:stop, window.stop_id}
    stop = handover_stop(segment, window.stop_id)

    [
      %{
        segment
        | trips: Enum.slice(segment.trips, 0, position + 1),
          end_secs: at,
          end_kind: :relief,
          end_ref: ref,
          end_stop: stop,
          gaps: Enum.filter(segment.gaps, &(&1.index in before))
      },
      %{
        segment
        | trips: Enum.slice(segment.trips, (position + 1)..-1//1),
          start_secs: at,
          start_kind: :relief,
          start_ref: ref,
          start_stop: stop,
          gaps: Enum.reject(segment.gaps, &(&1.index in before))
      }
    ]
  end

  # The window gives the handover's stop by ID; the segment's own trips give
  # that stop's point, so a piece leaving a handover can be measured. A stop the
  # segment never visits is left nil, which reads as unknown rather than free.
  defp handover_stop(segment, stop_id) do
    segment.trips
    |> Enum.flat_map(&[&1.first_stop, &1.last_stop])
    |> Enum.find(fn
      nil -> false
      stop -> stop.stop_id == stop_id
    end)
  end
end
