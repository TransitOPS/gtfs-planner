defmodule GtfsPlanner.Gtfs.Runs.Pieces do
  @moduledoc """
  Derives one day's pieces, handovers and uncovered segments from its blocks.

  Pure: it reads no repository, clock, file or network, and writes nothing. Every
  block is cut from what `GtfsPlanner.Gtfs.Blocking` already derived — the day's
  `Checks.trip_row` maps, the block's `Movements.t()` and its `Relief.window()`s —
  so relief, garages and driving times have one source.

  A piece is a maximal run of consecutive sequence trips of one block that share a
  run assignment, plus the block's own ends. Pieces are derived, never stored:
  nothing here is persisted, and a run exists only as far as its
  assignments do.

  ## The handover rule

  A change of run at gap *g* hands over at that gap's **first** window, because
  `Relief.windows/3` returns a gap's `:origin` window before its `:destination` one
  and the origin is the earlier of the two instants. With no window at *g* — both
  ends unmarked, the gap infeasible, or its drive unknown — the handover happens
  where the incoming trip ends, at its last arrival and last stop, and the
  boundary says so with `at_relief?: false` so `Runs.Checks` can raise the finding.

  ## Which piece owns the deadhead

  The gap's drive belongs to whichever operator actually drives the vehicle
  between the two stops, which follows from where the handover happens:

    * `:destination` — the handover is at the gap's *later* stop, so the vehicle
      has to get there first. The operator who held it at the earlier stop drives,
      so the gap is the piece that ends at the boundary — the incoming one.
    * `:origin` — the handover is at the gap's *earlier* stop, where the vehicle
      already is. The outgoing operator takes it from there, so the gap is the
      piece that starts at the boundary.
    * `:same` and no window — the vehicle never moves between the two trips, and
      the gap is the incoming piece's.

  The 6104 → 8106 example pins the `:destination` case: 6104 ends 07:40 at Valley
  College, the entered drive to the marked Market Square takes 14 minutes, and
  8106 leaves 08:20, so the only window is `:destination` [07:54, 08:20]. The
  vehicle can only be at Market Square at 07:54 if the operator who held it at
  Valley College drove it, so that gap is the incoming piece's.

  ## Service-day arithmetic

  Times are service-day seconds throughout, so a pull-out starting at −900 and a
  trip arriving at 25:10 are ordinary values carried through unchanged.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks

  @type block_input :: %{
          block_id: String.t(),
          trips: [Checks.trip_row()],
          movements: GtfsPlanner.Gtfs.Blocking.Movements.t(),
          windows: [GtfsPlanner.Gtfs.Blocking.Relief.window()]
        }

  @type boundary :: %{
          gap_index: non_neg_integer(),
          at_secs: integer(),
          stop: Checks.stop_ref() | nil,
          at_relief?: boolean(),
          side: :same | :origin | :destination | nil,
          from_trip_id: String.t(),
          to_trip_id: String.t(),
          from_run: String.t() | nil,
          to_run: String.t() | nil,
          block_id: String.t()
        }

  @type piece :: %{
          run_id: String.t() | nil,
          block_id: String.t(),
          garage_id: Ecto.UUID.t() | nil,
          trips: [Checks.trip_row()],
          route_id: String.t(),
          start_secs: integer(),
          end_secs: integer(),
          start_kind: :block_start | :relief,
          end_kind: :block_end | :relief,
          start_ref: GtfsPlanner.Gtfs.Blocking.Context.ref(),
          end_ref: GtfsPlanner.Gtfs.Blocking.Context.ref(),
          start_stop: Checks.stop_ref() | nil,
          end_stop: Checks.stop_ref() | nil,
          start_boundary: boundary() | nil,
          end_boundary: boundary() | nil,
          gaps: [GtfsPlanner.Gtfs.Blocking.Movements.gap()]
        }

  @spec derive([block_input()], %{String.t() => String.t()}) :: %{
          pieces: [piece()],
          uncovered: [piece()],
          boundaries: [boundary()]
        }
  def derive(blocks, assignments) do
    Enum.reduce(blocks, %{pieces: [], uncovered: [], boundaries: []}, fn block, acc ->
      {pieces, boundaries} = cut(block, assignments)

      # An unassigned run of trips is the same shape of segment as a piece, with
      # no run, and the caller keeps the two apart: uncovered work is never part
      # of any run's time.
      {assigned, uncovered} = Enum.split_with(pieces, & &1.run_id)

      %{
        pieces: acc.pieces ++ assigned,
        uncovered: acc.uncovered ++ uncovered,
        boundaries: acc.boundaries ++ boundaries
      }
    end)
  end

  # One block's sequence trips cut into maximal runs of equal assignment. A block
  # with no usable trip has no piece and no boundary, and its frequency-based and
  # unplottable rows are already gone by `Checks.sequence/1`.
  defp cut(block, assignments) do
    groups =
      block.trips
      |> Checks.sequence()
      |> Enum.with_index()
      |> Enum.chunk_by(fn {trip, _index} -> Map.get(assignments, trip.trip_id) end)

    case groups do
      [] ->
        {[], []}

      _ ->
        boundaries = boundaries(groups, block, assignments)
        last = length(groups) - 1

        pieces =
          groups
          |> Enum.with_index()
          |> Enum.map(fn {group, position} ->
            piece(
              block,
              group,
              position,
              last,
              boundary_before(groups, boundaries, position),
              boundary_after(boundaries, position, last),
              assignments
            )
          end)

        {pieces, boundaries}
    end
  end

  # The block's first piece starts the block, so it has no boundary before it.
  # `Enum.at/2` cannot be used for that: a negative index answers the last
  # element, not `nil`.
  defp boundary_before(_groups, _boundaries, 0), do: nil
  defp boundary_before(_groups, boundaries, position), do: Enum.at(boundaries, position - 1)

  # The block's last piece ends the block, so it has no boundary after it.
  defp boundary_after(_boundaries, position, last) when position == last, do: nil
  defp boundary_after(boundaries, position, _last), do: Enum.at(boundaries, position)

  # One boundary per change of assignment, in order: the change between group *p*
  # and group *p + 1* happens at the gap joining the last trip of *p* to the first
  # trip of *p + 1*, which is the gap at that trip pair's index.
  defp boundaries(groups, block, assignments) do
    groups
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [incoming, [{next, _index} | _rest]] ->
      {from_trip, gap_index} = List.last(incoming)

      boundary(block, gap_index, from_trip, next, assignments)
    end)
  end

  defp boundary(block, gap_index, from_trip, to_trip, assignments) do
    base = %{
      gap_index: gap_index,
      block_id: block.block_id,
      from_trip_id: from_trip.trip_id,
      to_trip_id: to_trip.trip_id,
      from_run: Map.get(assignments, from_trip.trip_id),
      to_run: Map.get(assignments, to_trip.trip_id)
    }

    case first_window(block.windows, gap_index) do
      # No window: the change happens where the incoming trip ends, and the
      # boundary says it is not a relief so the finding can name both trips.
      nil ->
        Map.merge(base, %{
          at_secs: from_trip.last_arrival,
          stop: from_trip.last_stop,
          at_relief?: false,
          side: nil
        })

      window ->
        Map.merge(base, %{
          at_secs: window.start_secs,
          stop: endpoint(window.stop_id, from_trip, to_trip),
          at_relief?: true,
          side: window.side
        })
    end
  end

  # `Relief.windows/3` returns a gap's `:origin` window before its `:destination`
  # one, so the first match is the origin — the earlier of the two instants.
  defp first_window(windows, gap_index) do
    Enum.find(windows, &(&1.gap_index == gap_index))
  end

  # The window names the stop the change happens at, which is one of the two trips'
  # own endpoints; a child stop is named by its own ID, never by its station.
  defp endpoint(stop_id, from_trip, to_trip) do
    [from_trip.last_stop, to_trip.first_stop]
    |> Enum.find(&(&1 && &1.stop_id == stop_id))
  end

  defp piece(block, group, _position, _last, start_boundary, end_boundary, assignments) do
    {trips, indices} = Enum.unzip(group)
    movements = block.movements

    start_of(movements, trips, start_boundary)
    |> Map.merge(end_of(movements, trips, end_boundary))
    |> Map.merge(%{
      run_id: Map.get(assignments, hd(trips).trip_id),
      block_id: block.block_id,
      garage_id: movements.garage_id,
      trips: trips,
      route_id: hd(trips).route_id,
      gaps: gaps(movements, indices, start_boundary, end_boundary)
    })
  end

  # The piece's start is the block's own start when it is the block's first piece,
  # and otherwise the handover that put it there.
  defp start_of(movements, trips, nil) do
    case movements.pull_out do
      nil ->
        first = hd(trips)

        %{
          start_secs: first.first_departure,
          start_kind: :block_start,
          start_ref: {:stop, first.first_stop.stop_id},
          start_stop: first.first_stop,
          start_boundary: nil
        }

      # The clock starts at the garage, where the pull-out begins; the first stop
      # is where service begins, and the drive between them is the run's travel in.
      pull_out ->
        %{
          start_secs: pull_out.start_secs,
          start_kind: :block_start,
          start_ref: pull_out.from,
          start_stop: hd(trips).first_stop,
          start_boundary: nil
        }
    end
  end

  defp start_of(_movements, trips, boundary) do
    stop = boundary_stop(boundary, hd(trips).first_stop)

    %{
      start_secs: boundary.at_secs,
      start_kind: :relief,
      start_ref: {:stop, stop.stop_id},
      start_stop: stop,
      start_boundary: boundary
    }
  end

  defp end_of(movements, trips, nil) do
    case movements.pull_back do
      nil ->
        last = List.last(trips)

        %{
          end_secs: last.last_arrival,
          end_kind: :block_end,
          end_ref: {:stop, last.last_stop.stop_id},
          end_stop: last.last_stop,
          end_boundary: nil
        }

      pull_back ->
        %{
          end_secs: pull_back.end_secs,
          end_kind: :block_end,
          end_ref: pull_back.to,
          end_stop: List.last(trips).last_stop,
          end_boundary: nil
        }
    end
  end

  defp end_of(_movements, trips, boundary) do
    stop = boundary_stop(boundary, List.last(trips).last_stop)

    %{
      end_secs: boundary.at_secs,
      end_kind: :relief,
      end_ref: {:stop, stop.stop_id},
      end_stop: stop,
      end_boundary: boundary
    }
  end

  # A window always names a stop and the no-window case carries the incoming
  # trip's last stop, so a boundary stop is present; the trip's own endpoint is
  # the fallback that keeps the ref total.
  defp boundary_stop(%{stop: nil}, fallback), do: fallback
  defp boundary_stop(%{stop: stop}, _fallback), do: stop

  # Every gap between two of the piece's own trips, in order, plus the one
  # boundary gap this piece's own operator drives.
  defp gaps(movements, indices, start_boundary, end_boundary) do
    [first | _] = indices
    internal = Enum.slice(movements.gaps, first, length(indices) - 1)

    owned =
      []
      |> owned_by(movements, start_boundary, owns_start?(start_boundary))
      |> owned_by(movements, end_boundary, owns_end?(end_boundary))

    Enum.sort_by(internal ++ owned, & &1.index)
  end

  defp owned_by(acc, movements, boundary, owns?) do
    if owns?, do: acc ++ [Enum.at(movements.gaps, boundary.gap_index)], else: acc
  end

  # `:origin` hands over at the earlier stop, where the vehicle already is, so
  # the outgoing operator takes it from there and this gap is the piece that
  # starts here.
  defp owns_start?(boundary), do: not is_nil(boundary) and boundary.side == :origin

  # `:destination`, `:same` and no window at all hand over at or after the
  # earlier stop, so the vehicle has to reach the later stop first and the gap is
  # the piece that ends here.
  defp owns_end?(boundary), do: not is_nil(boundary) and boundary.side != :origin
end
