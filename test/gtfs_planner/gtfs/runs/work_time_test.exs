defmodule GtfsPlanner.Gtfs.Runs.WorkTimeTest do
  @moduledoc """
  Work time for one run: sign-on, sign-off, travel, reports, breaks, paid time,
  type and the ordered segment list.

  Every figure here is computed by hand in the comment above each test, in
  minutes, and the code is seconds. The pieces are built as plain maps rather than
  through `Movements`, because this module's subject is what it charges for a
  run's shape — a garage piece, a piece that starts at a handover, a block with no
  garage at all — and not that the movement build produced it. `pieces_test.exs`
  is where that derivation is tested.

  The fixture is a garage on the same meridian as one marked station, so an
  estimated drive is a real drive rather than a rounding artefact, and an
  entered time can be planted over it to show which one wins.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Runs.WorkTime

  @garage "11111111-1111-1111-1111-111111111111"
  @riv "RIV"

  # Riverside Station, and a garage 0.0415 degrees north of it: about 4,619 m,
  # so at 30 km/h with 1.3 circuity that is round(4619 * 1.3 / 500) = 12 minutes.
  @riv_point %{stop_id: @riv, lat: 40.0, lon: -74.0}
  @garage_point %{lat: 40.0415, lon: -74.0}

  @crew %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 720
  }

  defp hms(h, m, s \\ 0), do: h * 3600 + m * 60 + s
  defp minutes(secs), do: div(secs, 60)

  defp context(opts \\ []) do
    %Context{
      min_layover_minutes: 5,
      deadhead_speed_kmh: 30,
      deadhead_circuity: 1.3,
      default_garage_id: Keyword.get(opts, :garage_id, @garage),
      garages: Keyword.get(opts, :garages, %{@garage => @garage_point}),
      entered_minutes: Keyword.get(opts, :entered_minutes, %{})
    }
  end

  defp crew(opts), do: Map.merge(@crew, Map.new(opts))

  # A whole garage block: it starts at the garage with the pull-out and ends there
  # with the pull-back, so `Runs.Pieces` gives it the garage's own seconds at both
  # ends and no travel leg is charged into or out of it.
  defp garage_piece(start, finish, opts \\ []) do
    %{
      run_id: Keyword.get(opts, :run_id, "1010"),
      start_secs: start,
      end_secs: finish,
      start_kind: :block_start,
      end_kind: :block_end,
      garage_id: Keyword.get(opts, :garage_id, @garage),
      start_ref: {:garage, Keyword.get(opts, :garage_id, @garage)},
      start_stop: nil,
      end_ref: {:garage, Keyword.get(opts, :garage_id, @garage)},
      end_stop: nil,
      gaps: []
    }
  end

  # A piece that starts at a handover at the station, so its first duty is a real
  # drive from the garage to where it was relieved.
  defp relief_piece(start, finish) do
    %{
      run_id: "2020",
      start_secs: start,
      end_secs: finish,
      start_kind: :relief,
      end_kind: :block_end,
      garage_id: @garage,
      start_ref: {:stop, @riv},
      start_stop: @riv_point,
      end_ref: {:stop, @riv},
      end_stop: @riv_point,
      gaps: []
    }
  end

  defp kinds(work), do: Enum.map(work.segments, & &1.kind)

  describe "run 1010, the worked example" do
    # Two whole garage blocks. 06:30–09:44 is 3 h 14 = 194 min; 15:00–18:10 is
    # 3 h 10 = 190 min. Both are block starts, so 15 + 15 of report. No travel:
    # every leg is the garage to itself. The break between them is
    # 15:00 − 15 min report − 0 travel − 09:44 = 5 h 16 − 0:15 = 5 h 1 = 301 min,
    # which is over the 30-minute paid maximum, so it is unpaid and the run is a
    # split. Sign-on is 06:30 − 15 = 06:15 and sign-off 18:10 + 5 = 18:15, a
    # spread of 12 h = 720 min. Paid is 15 + 15 + 194 + 190 + 5 = 419 min.
    test "signs on 06:15, signs off 18:15, spreads 720 and pays 419" do
      work =
        WorkTime.compute(
          [garage_piece(hms(15, 0), hms(18, 10)), garage_piece(hms(6, 30), hms(9, 44))],
          context(),
          @crew
        )

      # The two pieces arrive out of order and are still numbered 1 then 2.
      assert [one, two] =
               work.segments |> Enum.filter(&(&1.kind == :piece)) |> Enum.map(& &1.piece_index)

      assert {one, two} == {1, 2}
      assert minutes(hms(6, 30) - work.sign_on_secs) == 15
      assert work.sign_off_secs == hms(18, 15)
      assert work.spread_secs == hms(12, 0)
      assert minutes(work.spread_secs) == 720

      assert [%{secs: break_secs, paid?: false, after_piece: 1}] = work.breaks
      assert minutes(break_secs) == 301
      assert work.type == :split
      assert minutes(work.paid_secs) == 419
    end
  end

  describe "a one-piece run" do
    # 06:00–08:00 is 120 min, plus a 15-minute pull-out report and a 5-minute
    # sign-off, and no travel and no break to complicate it: 15 + 120 + 5 = 140.
    test "is paid its report plus its piece plus sign-off" do
      work = WorkTime.compute([garage_piece(hms(6, 0), hms(8, 0))], context(), @crew)

      assert work.type == :one_piece
      assert work.breaks == []
      assert work.travel_secs == 0
      assert minutes(work.paid_secs) == 140
      assert minutes(work.vehicle_secs) == 120
      assert work.sign_on_secs == hms(5, 45)
      assert work.sign_off_secs == hms(8, 5)
    end
  end

  describe "a piece that starts at a handover" do
    # The garage sits about 4,619 m from the station, so the drive in is an
    # estimated 12 minutes, and the relief report is 5. Sign-on is therefore
    # 17 minutes before the handover: the 12 to drive there and the 5 to report.
    test "charges the estimated drive before its relief report" do
      work = WorkTime.compute([relief_piece(hms(7, 0), hms(9, 0))], context(), @crew)

      assert minutes(work.sign_on_secs - hms(6, 43)) == 0
      assert work.sign_on_secs == hms(7, 0) - hms(0, 5) - hms(0, 12)
      assert minutes(hms(7, 0) - work.sign_on_secs) == 17

      assert [:travel, :report, :piece, :travel, :sign_off] = kinds(work)
      assert [travel_in, _report, _piece, travel_out, _sign_off] = work.segments
      assert travel_in.source == :estimated
      assert minutes(travel_in.end_secs - travel_in.start_secs) == 12
      assert travel_out.source == :estimated
      assert minutes(work.travel_secs) == 24
    end

    # The same geometry with a human-entered 20 minutes on that pair. The entered
    # time wins: the drive is 20 minutes, not the 12 the estimate would have
    # given, and the sign-on moves out with it.
    test "an entered time overrides the estimate" do
      ctx = context(entered_minutes: %{{{:garage, @garage}, {:stop, @riv}} => 20})
      work = WorkTime.compute([relief_piece(hms(7, 0), hms(9, 0))], ctx, @crew)

      [travel_in | _] = work.segments
      assert travel_in.source == :entered
      assert minutes(travel_in.end_secs - travel_in.start_secs) == 20
      assert work.sign_on_secs == hms(7, 0) - hms(0, 5) - hms(0, 20)
    end
  end

  describe "a block with no garage" do
    # Nothing to drive to and nothing to drive back to, so the only charge is the
    # pull-out report of 15 and the 5 to sign off: 15 + 120 + 5 = 140.
    test "is charged the pull-out and has no travel at all" do
      piece = garage_piece(hms(6, 0), hms(8, 0), garage_id: nil)
      work = WorkTime.compute([piece], context(garage_id: nil, garages: %{}), @crew)

      assert work.garage_id == nil
      assert work.travel_secs == 0
      assert :travel not in kinds(work)
      assert work.unknown_travel == []
      assert minutes(work.report_secs) == 15
      assert minutes(work.paid_secs) == 140
      assert work.sign_on_secs == hms(5, 45)
      assert work.sign_off_secs == hms(8, 5)
    end
  end

  describe "what makes a break paid" do
    # Two garage blocks with a break of exactly 30 minutes between them: the
    # second starts at 08:00 + 30 + a 15-minute report = 08:45, and runs 75 min
    # to 10:00.
    defp two_pieces(second_start) do
      [garage_piece(hms(6, 0), hms(8, 0)), garage_piece(second_start, hms(10, 0))]
    end

    test "a break of exactly the maximum is paid and the run is straight" do
      work = WorkTime.compute(two_pieces(hms(8, 45)), context(), @crew)

      assert [%{secs: 1800, paid?: true}] = work.breaks
      assert work.type == :straight
      # 15 + 15 reports, 120 + 75 pieces, 5 sign-off and the 30 paid break.
      assert minutes(work.paid_secs) == 15 + 15 + 120 + 75 + 5 + 30
    end

    test "a break one minute over the maximum is unpaid and the run is a split" do
      # 08:00 + 31 + 15 = 08:46.
      work = WorkTime.compute(two_pieces(hms(8, 46)), context(), @crew)

      assert [%{secs: 1860, paid?: false}] = work.breaks
      assert work.type == :split
      # The same 31 minutes are still a segment in the day, just not paid time.
      assert minutes(work.paid_secs) == 15 + 15 + 120 + 74 + 5
    end

    test "lowering the maximum makes the same 30-minute break unpaid" do
      work = WorkTime.compute(two_pieces(hms(8, 45)), context(), crew(paid_break_max_minutes: 29))

      assert [%{secs: 1800, paid?: false}] = work.breaks
      assert work.type == :split
      assert minutes(work.paid_secs) == 15 + 15 + 120 + 75 + 5
    end
  end

  describe "a break that cannot be real" do
    # The second block starts before the first one ends: 08:00 − 10 + 15 = 08:05.
    # The gap is −10 minutes. It is not paid and it does not take a negative out
    # of paid time, but it is kept as the negative number it is, because that is
    # what `Runs.Checks` raises :cannot_reach_piece against.
    test "is kept negative and adds nothing to paid time" do
      work =
        WorkTime.compute(
          [garage_piece(hms(6, 0), hms(8, 0)), garage_piece(hms(8, 5), hms(10, 0))],
          context(),
          @crew
        )

      assert [%{secs: -600, paid?: false, after_piece: 1}] = work.breaks
      assert minutes(work.paid_secs) == 15 + 15 + 120 + 115 + 5
      assert work.paid_secs > 0
    end
  end

  describe "a leg with no coordinates" do
    # The first block's last stop has no point at all, so nothing can be estimated
    # between it and the station. The leg is not silently free and not silently
    # impossible either: it is zero-length, marked :unknown, and listed.
    test "is a zero-length unknown segment and is listed" do
      broken = %{
        garage_piece(hms(6, 0), hms(8, 0))
        | end_ref: {:stop, "NOWHERE"},
          end_stop: %{stop_id: "NOWHERE", lat: nil, lon: nil}
      }

      second = garage_piece(hms(9, 0), hms(10, 0))
      work = WorkTime.compute([broken, second], context(), @crew)

      assert work.travel_secs == 0
      assert [%{from: {:stop, "NOWHERE"}, to: {:garage, @garage}}] = work.unknown_travel
      assert Enum.any?(work.segments, &(&1.kind == :travel and &1.source == :unknown))
    end
  end

  describe "the segment list" do
    test "is in time order and each report ends where its piece starts" do
      work =
        WorkTime.compute(
          [relief_piece(hms(7, 0), hms(9, 0)), garage_piece(hms(11, 0), hms(13, 0))],
          context(),
          @crew
        )

      assert work.segments == Enum.sort_by(work.segments, & &1.start_secs)
      assert Enum.all?(work.segments, fn s -> s.end_secs >= s.start_secs end)

      for segment <- work.segments, segment.kind == :report do
        piece =
          Enum.find(work.segments, &(&1.kind == :piece and &1.piece_index == segment.piece_index))

        assert piece.start_secs == segment.end_secs
      end
    end

    # The TODS export writes both location fields of every `run_events.txt` row and
    # the spec marks them required, so a report, a break and a sign-off each name
    # the place the run is: the piece they belong to, and the garage a closing
    # travel returned to. A report, a break and a sign-off last no time and move
    # nobody, so their two ends are the same place.
    test "a report, a break and the sign-off name the place the run is" do
      work =
        WorkTime.compute(
          [garage_piece(hms(6, 0), hms(8, 0)), relief_piece(hms(11, 0), hms(13, 0))],
          context(),
          @crew
        )

      assert [
               pull_out_report,
               _first_piece,
               break,
               _travel_between,
               relief_report,
               _second_piece,
               _travel_out,
               sign_off
             ] = work.segments

      assert pull_out_report.from == {:garage, @garage}
      assert pull_out_report.to == pull_out_report.from

      assert break.from == {:garage, @garage}
      assert break.to == break.from

      assert relief_report.from == {:stop, @riv}
      assert relief_report.to == relief_report.from

      assert sign_off.from == {:garage, @garage}
      assert sign_off.to == sign_off.from
    end

    test "a run with no travel out signs off where its last piece ended" do
      piece = %{
        run_id: "3030",
        start_secs: hms(6, 0),
        end_secs: hms(8, 0),
        start_kind: :relief,
        end_kind: :relief,
        garage_id: nil,
        start_ref: {:stop, @riv},
        start_stop: @riv_point,
        end_ref: {:stop, @riv},
        end_stop: @riv_point,
        gaps: []
      }

      work = WorkTime.compute([piece], context(garage_id: nil, garages: %{}), @crew)

      assert [report, _piece, sign_off] = work.segments
      assert report.from == {:stop, @riv}
      assert report.to == report.from
      assert sign_off.from == {:stop, @riv}
      assert sign_off.to == sign_off.from
    end
  end
end
