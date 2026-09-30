defmodule GtfsPlanner.Gtfs.Runs.WorkTime do
  @moduledoc """
  Computes one run's sign-on, travel, reports, breaks, paid time, type and its
  ordered segments.

  Pure: it reads no repository, clock, file or network, and writes nothing. Every
  driving time comes from `Blocking.DeadheadTimes.lookup/5` over the version's
  context, so an entered time wins over an estimate and an unknown leg is never
  quietly read as reachable.

  ## What is paid

  Paid time is the operator's whole duty: every report, every minute of service,
  every travel leg, the sign-off allowance, and the breaks short enough to be
  paid. A longer break is unpaid, which is also what makes the run a split.

      paid = Σ reports + Σ pieces + Σ travel + sign-off + Σ paid breaks

  ## The segments

  The list is in time order and is what the page and the export draw:

      travel in → report → piece → [break → travel → report → piece]… →
      travel out → sign-off

  A travel leg is charged between the garage and a piece, or between two pieces,
  whenever the two ends are **different places**. A piece that starts a block in a
  garage already begins at the garage — `Runs.Pieces` gave it the pull-out's own
  start — so its travel in is the garage to itself and is skipped, and the same
  is true of the pull-back at the end. A piece that begins or ends at a handover does carry a
  real leg to or from the relief stop.

  A leg with no coordinates at one end is a zero-length `:travel` segment with
  `source: :unknown`, listed in `unknown_travel`, so a planner sees the gap
  instead of a leg that silently costs nothing.

  ## Where a break sits

  A break is the idle time between two pieces, measured from the end of the
  earlier one to the start of the later one less the later piece's report and the
  travel between them:

      break = next start − next report − travel between − previous end

  A negative break means the later piece cannot be reached. Its segment is emitted
  with that true negative span, kept in `breaks` as it is and counted as zero
  paid: raising `:cannot_reach_piece` is `Runs.Checks`' job, not this module's.
  """

  alias GtfsPlanner.Gtfs.Blocking.DeadheadTimes

  @type segment :: %{
          kind: :travel | :report | :piece | :break | :sign_off,
          start_secs: integer(),
          end_secs: integer(),
          from: GtfsPlanner.Gtfs.Blocking.Context.ref() | nil,
          to: GtfsPlanner.Gtfs.Blocking.Context.ref() | nil,
          source: :entered | :estimated | :unknown | nil,
          piece_index: pos_integer() | nil,
          paid?: boolean()
        }

  @type t :: %{
          garage_id: Ecto.UUID.t() | nil,
          sign_on_secs: integer(),
          sign_off_secs: integer(),
          spread_secs: integer(),
          vehicle_secs: non_neg_integer(),
          report_secs: non_neg_integer(),
          travel_secs: non_neg_integer(),
          sign_off_allowance_secs: non_neg_integer(),
          breaks: [%{secs: integer(), paid?: boolean(), after_piece: pos_integer()}],
          paid_secs: non_neg_integer(),
          type: :one_piece | :straight | :split,
          segments: [segment()],
          unknown_travel: [
            %{
              from: GtfsPlanner.Gtfs.Blocking.Context.ref(),
              to: GtfsPlanner.Gtfs.Blocking.Context.ref()
            }
          ]
        }

  @minute 60

  @doc """
  Computes one run's work time from its pieces, the version's context and the
  crew rules.

  `pieces` are the run's pieces in any order; they are sorted by start and
  numbered from 1 here, so a caller need not present them in time order. A run
  with no piece has no work: every figure is zero and there are no segments.
  """
  @spec compute([map()], GtfsPlanner.Gtfs.Blocking.Context.t(), map()) :: t()
  def compute([], _context, crew), do: empty(crew)

  def compute(pieces, context, crew) do
    pieces = pieces |> Enum.sort_by(& &1.start_secs) |> Enum.with_index(1)
    {first, _} = hd(pieces)
    {last, last_index} = List.last(pieces)

    garage_id = first.garage_id
    sign_off_allowance = crew.sign_off_minutes * @minute

    reports = reports(pieces, crew)
    travels = travels(pieces, garage_id, context, reports)
    breaks = breaks(pieces, crew, travels)

    travel_secs = travels |> Enum.map(& &1.secs) |> Enum.sum()
    report_secs = reports |> Enum.map(& &1.secs) |> Enum.sum()

    vehicle_secs =
      Enum.sum(Enum.map(pieces, fn {piece, _} -> piece.end_secs - piece.start_secs end))

    paid_breaks = breaks |> Enum.filter(& &1.paid?) |> Enum.map(& &1.secs) |> Enum.sum()

    sign_on_secs = first.start_secs - report(1, reports).secs - travel_for(travels, :travel_in, 1)

    sign_off_secs =
      last.end_secs + travel_for(travels, :travel_out, last_index) + sign_off_allowance

    %{
      garage_id: garage_id,
      sign_on_secs: sign_on_secs,
      sign_off_secs: sign_off_secs,
      spread_secs: sign_off_secs - sign_on_secs,
      vehicle_secs: vehicle_secs,
      report_secs: report_secs,
      travel_secs: travel_secs,
      sign_off_allowance_secs: sign_off_allowance,
      breaks: Enum.map(breaks, &Map.take(&1, [:secs, :paid?, :after_piece])),
      paid_secs: report_secs + vehicle_secs + travel_secs + sign_off_allowance + paid_breaks,
      type: type(pieces, breaks),
      segments: segments(pieces, reports, travels, breaks, last_index, sign_off_allowance),
      unknown_travel:
        travels
        |> Enum.filter(&(&1.source == :unknown))
        |> Enum.map(&%{from: &1.from, to: &1.to})
    }
  end

  defp empty(crew) do
    %{
      garage_id: nil,
      sign_on_secs: 0,
      sign_off_secs: 0,
      spread_secs: 0,
      vehicle_secs: 0,
      report_secs: 0,
      travel_secs: 0,
      sign_off_allowance_secs: crew.sign_off_minutes * @minute,
      breaks: [],
      paid_secs: 0,
      type: :one_piece,
      segments: [],
      unknown_travel: []
    }
  end

  # A piece that starts a block is charged the pull-out allowance whether or not
  # the block has a garage, and a split's second pull-out is a block start like
  # any other; a piece that starts at a handover is charged the relief allowance.
  # The report ends exactly where its piece starts, so the two meet without a gap.
  defp report_secs(:block_start, crew), do: crew.report_pull_out_minutes * @minute
  defp report_secs(:relief, crew), do: crew.report_relief_minutes * @minute

  defp report(index, reports), do: Enum.find(reports, &(&1.piece_index == index))

  defp reports(pieces, crew) do
    Enum.map(pieces, fn {piece, index} ->
      secs = report_secs(piece.start_kind, crew)

      %{
        secs: secs,
        piece_index: index,
        start_secs: piece.start_secs - secs,
        end_secs: piece.start_secs
      }
    end)
  end

  # Every leg the run's geometry implies, each already placed in time. A leg
  # between the same place twice is not a drive at all and is dropped: a
  # block-start piece in a garage begins and ends at the garage, because
  # `Runs.Pieces` gave it the pull-out's and the pull-back's own seconds.
  defp travels(pieces, garage_id, context, reports) do
    legs =
      in_leg(pieces, garage_id, context, reports) ++
        between_legs(pieces, context) ++ out_leg(pieces, garage_id, context)

    legs
    |> Enum.reject(&is_nil(&1))
    |> Enum.map(&place(&1, reports, pieces))
  end

  defp in_leg([{first, 1} | _], garage_id, context, _reports) when not is_nil(garage_id) do
    [
      leg(
        :travel_in,
        {:garage, garage_id},
        first.start_ref,
        garage_point(garage_id, context),
        point(first.start_stop),
        1,
        1,
        context
      )
    ]
  end

  defp in_leg(_pieces, _garage_id, _context, _reports), do: []

  defp between_legs(pieces, context) do
    pieces
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{previous, previous_index}, {next, next_index}] ->
      leg(
        :between,
        previous.end_ref,
        next.start_ref,
        point(previous.end_stop),
        point(next.start_stop),
        next_index,
        previous_index,
        context
      )
    end)
  end

  defp out_leg(pieces, garage_id, context) do
    case garage_id do
      nil ->
        []

      _ ->
        {last, last_index} = List.last(pieces)

        [
          leg(
            :travel_out,
            last.end_ref,
            {:garage, garage_id},
            point(last.end_stop),
            garage_point(garage_id, context),
            last_index,
            last_index,
            context
          )
        ]
    end
  end

  defp leg(kind, from, to, from_point, to_point, piece_index, after_index, context) do
    if from == to do
      nil
    else
      %{minutes: minutes, source: source} =
        DeadheadTimes.lookup(from, from_point, to, to_point, context)

      %{
        kind: kind,
        from: from,
        to: to,
        secs: if(is_nil(minutes), do: 0, else: minutes * @minute),
        source: source,
        piece_index: piece_index,
        after_index: after_index
      }
    end
  end

  # A leg runs immediately before the report of the piece it serves, so the
  # sequence travel → report → piece is contiguous, and the travel out runs
  # immediately after the last piece ends.
  defp place(leg, reports, pieces) do
    {last, _} = List.last(pieces)

    {start_secs, end_secs} =
      case leg.kind do
        :travel_out ->
          {last.end_secs, last.end_secs + leg.secs}

        _ ->
          {report(leg.piece_index, reports).start_secs - leg.secs,
           report(leg.piece_index, reports).start_secs}
      end

    Map.merge(leg, %{start_secs: start_secs, end_secs: end_secs})
  end

  defp travel_for(travels, kind, piece_index) do
    Enum.find_value(travels, 0, fn leg ->
      if leg.kind == kind and leg.piece_index == piece_index, do: leg.secs
    end)
  end

  defp travel_between(travels, after_index, next_index) do
    Enum.find_value(travels, 0, fn leg ->
      if leg.kind == :between and leg.after_index == after_index and leg.piece_index == next_index,
        do: leg.secs
    end)
  end

  # The idle time between two pieces, measured from the earlier piece's end to the
  # later piece's report and travel.
  defp breaks(pieces, crew, travels) do
    max_paid = crew.paid_break_max_minutes * @minute

    pieces
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{previous, previous_index}, {next, next_index}] ->
      travel = travel_between(travels, previous_index, next_index)
      allowance = report_secs(next.start_kind, crew)
      secs = next.start_secs - allowance - travel - previous.end_secs

      %{
        secs: secs,
        # A negative break is not a paid break and contributes nothing to paid
        # time; it is kept as it is so `Runs.Checks` can raise the finding against the
        # real number rather than a clamped one.
        paid?: secs >= 0 and secs <= max_paid,
        after_piece: previous_index,
        to_piece: next_index,
        start_secs: previous.end_secs,
        end_secs: previous.end_secs + secs
      }
    end)
  end

  defp segments(pieces, reports, travels, breaks, last_index, sign_off_allowance) do
    {body, _last} =
      Enum.reduce(pieces, {[], nil}, fn {piece, index}, {acc, _previous} ->
        acc =
          acc
          |> push_travel(travel_for_leg(travels, :travel_in, index))
          |> push_break(Enum.find(breaks, &(&1.to_piece == index)))
          |> push_travels(
            Enum.filter(travels, &(&1.kind == :between and &1.piece_index == index))
          )
          |> push_report(report(index, reports))
          |> push_piece(piece, index)

        {acc, piece}
      end)

    out = travel_for_leg(travels, :travel_out, last_index)
    {last, _} = List.last(pieces)
    sign_off_start = last.end_secs + travel_for(travels, :travel_out, last_index)

    body
    |> push_travel(out)
    |> Kernel.++([
      %{
        kind: :sign_off,
        start_secs: sign_off_start,
        end_secs: sign_off_start + sign_off_allowance,
        from: nil,
        to: nil,
        source: nil,
        piece_index: last_index,
        paid?: true
      }
    ])
  end

  defp travel_for_leg(travels, kind, piece_index) do
    Enum.find(travels, &(&1.kind == kind and &1.piece_index == piece_index))
  end

  defp push_travel(acc, nil), do: acc
  defp push_travel(acc, leg), do: acc ++ [to_segment(leg)]

  defp push_travels(acc, legs), do: Enum.reduce(legs, acc, &push_travel(&2, &1))

  defp push_report(acc, nil), do: acc

  defp push_report(acc, entry) do
    acc ++
      [
        %{
          kind: :report,
          start_secs: entry.start_secs,
          end_secs: entry.end_secs,
          from: nil,
          to: nil,
          source: nil,
          piece_index: entry.piece_index,
          paid?: true
        }
      ]
  end

  defp push_piece(acc, piece, index) do
    acc ++
      [
        %{
          kind: :piece,
          start_secs: piece.start_secs,
          end_secs: piece.end_secs,
          from: nil,
          to: nil,
          source: nil,
          piece_index: index,
          paid?: true
        }
      ]
  end

  defp push_break(acc, nil), do: acc

  defp push_break(acc, entry) do
    acc ++
      [
        %{
          kind: :break,
          # A negative break is emitted with its true negative span: the later
          # piece starts before the earlier one ends, and hiding that would
          # misreport the day.
          start_secs: entry.start_secs,
          end_secs: entry.end_secs,
          from: nil,
          to: nil,
          source: nil,
          piece_index: entry.to_piece,
          paid?: entry.paid?
        }
      ]
  end

  defp to_segment(leg) do
    %{
      kind: :travel,
      start_secs: leg.start_secs,
      end_secs: leg.end_secs,
      from: leg.from,
      to: leg.to,
      source: leg.source,
      piece_index: leg.piece_index,
      paid?: true
    }
  end

  # One piece is a one-piece run whatever its break count says. Otherwise a run is
  # straight when every break is paid and split when any break is not.
  defp type(_pieces, []), do: :one_piece
  defp type([_single], _breaks), do: :one_piece

  defp type(_pieces, breaks) do
    if Enum.all?(breaks, & &1.paid?), do: :straight, else: :split
  end

  defp point(nil), do: nil

  defp point(stop) do
    if is_nil(stop.lat) or is_nil(stop.lon), do: nil, else: {stop.lat, stop.lon}
  end

  defp garage_point(garage_id, context) do
    case context.garages[garage_id] do
      nil -> nil
      garage -> {garage.lat, garage.lon}
    end
  end
end
