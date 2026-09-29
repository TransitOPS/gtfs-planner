defmodule GtfsPlanner.Gtfs.Runs.ChecksTest do
  @moduledoc """
  The findings a plan raises about runs, handovers and uncovered work (rules 4, 8
  and 9, EV-5).

  Each test pins a **boundary value** rather than a typical one, because these
  are all comparisons against a limit and the interesting case is the one sitting
  exactly on it. A piece of exactly `max_piece_minutes` is fine and one second
  more is a warning; a spread of exactly 720 minutes is fine and 721 is not; a
  break of 30 minutes is straight and 31 is not. A test in the middle of the
  range would pass whether the comparison were `>`, `>=` or off by a factor of
  sixty, and these are exactly the comparisons a run's publishability turns on.

  The work time handed to `run_findings/5` is built by the real
  `Runs.WorkTime.compute/3` over hand-built pieces, so the `breaks` a finding
  reads are the ones the day's arithmetic actually produced.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Runs.Checks
  alias GtfsPlanner.Gtfs.Runs.WorkTime

  @garage "11111111-1111-1111-1111-111111111111"
  @riv %{stop_id: "RIV", name: "Riverside Station", parent_station: nil, lat: 40.0, lon: -74.0}
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
      default_garage_id: @garage,
      max_piece_minutes: Keyword.get(opts, :max_piece_minutes, 240),
      garages: %{@garage => %{lat: 40.0415, lon: -74.0}},
      entered_minutes: %{}
    }
  end

  defp crew(opts), do: Map.merge(@crew, Map.new(opts))

  defp piece(start, finish, opts \\ []) do
    %{
      run_id: Keyword.get(opts, :run_id, "1010"),
      block_id: Keyword.get(opts, :block_id, "101"),
      garage_id: @garage,
      route_id: "R1",
      trips:
        Keyword.get(opts, :trips, [%{trip_id: "00000000-0000-0000-0000-00000000000#{start}"}]),
      start_secs: start,
      end_secs: finish,
      start_kind: :block_start,
      end_kind: :block_end,
      start_ref: {:garage, @garage},
      start_stop: nil,
      end_ref: {:garage, @garage},
      end_stop: nil,
      start_boundary: nil,
      end_boundary: nil,
      gaps: []
    }
  end

  defp work_of(pieces, opts \\ []) do
    WorkTime.compute(pieces, context(opts), Keyword.get(opts, :crew, @crew))
  end

  defp findings(pieces, opts \\ []) do
    Checks.run_findings(
      "1010",
      pieces,
      work_of(pieces, opts),
      context(opts),
      Keyword.get(opts, :crew, @crew)
    )
  end

  defp codes(findings), do: Enum.map(findings, & &1.code)

  describe "a piece at the piece limit" do
    test "exactly max_piece_minutes raises nothing and one second more raises a warning" do
      # 240 minutes is the limit, so 06:00–10:00 is exactly on it.
      on_limit = [piece(hms(6, 0), hms(10, 0))]
      assert findings(on_limit, max_piece_minutes: 240) == []

      over = [piece(hms(6, 0), hms(10, 0, 1))]
      assert [finding] = findings(over, max_piece_minutes: 240)
      assert finding.code == :piece_too_long
      assert finding.severity == :warning

      assert finding.detail == %{
               piece: 1,
               secs: minutes(hms(10, 0, 1) - hms(6, 0)) * 60 + 1,
               limit_secs: 14_400
             }

      assert finding.run_ids == ["1010"]
    end

    test "an unset limit raises nothing however long the piece is" do
      # Sixteen hours, with the spread limit lifted so the piece limit is alone on
      # trial.
      long = [piece(hms(4, 0), hms(20, 0))]

      assert findings(long,
               max_piece_minutes: nil,
               crew: crew(max_spread_minutes: 1_200)
             ) == []
    end
  end

  describe "a spread at the spread limit" do
    # A one-piece run signs on 15 minutes early and off 5 minutes late, so its
    # spread is the piece plus 20 minutes. 06:00–17:40 is 700 minutes, +20 = 720.
    # The piece limit is unset here so the spread is the only thing on trial.
    defp spread_run(piece_start, piece_finish), do: [piece(piece_start, piece_finish)]

    test "720 minutes raises nothing and 721 raises a warning" do
      assert findings(spread_run(hms(6, 0), hms(17, 40)), max_piece_minutes: nil) == []

      over = work_of(spread_run(hms(6, 0), hms(17, 41)))
      assert over.spread_secs == hms(12, 1)
      assert minutes(over.spread_secs) == 721

      assert [finding] = findings(spread_run(hms(6, 0), hms(17, 41)), max_piece_minutes: nil)
      assert finding.code == :spread_too_long
      assert finding.severity == :warning
      assert finding.detail == %{secs: hms(12, 1), limit_secs: 43_200}
    end

    test "a longer allowed spread is not breached by the same run" do
      assert findings(spread_run(hms(6, 0), hms(17, 41)),
               crew: crew(max_spread_minutes: 800),
               max_piece_minutes: nil
             ) == []
    end
  end

  describe "a run with too many pieces" do
    test "three pieces is an error naming the count" do
      pieces = [
        piece(hms(6, 0), hms(7, 0)),
        piece(hms(8, 0), hms(9, 0)),
        piece(hms(10, 0), hms(11, 0))
      ]

      assert [finding] = findings(pieces)
      assert finding.code == :too_many_pieces
      assert finding.severity == :error
      assert finding.detail == %{pieces: 3}
    end

    test "two pieces is within the limit" do
      two = [piece(hms(6, 0), hms(7, 0)), piece(hms(8, 0), hms(9, 0))]
      assert :too_many_pieces not in codes(findings(two))
    end
  end

  describe "a break that cannot be real" do
    # The second piece starts one second too early to have its report, so the
    # break is −1 s. What is available is the 899 s between 07:00 and 07:14:59;
    # what is needed is 900 s, the whole of the 15-minute pull-out report, with
    # nowhere to put it.
    test "raises an error naming what was needed and what was available" do
      pieces = [piece(hms(6, 0), hms(7, 0)), piece(hms(7, 14, 59), hms(9, 0))]
      work = work_of(pieces)
      assert [%{secs: -1, paid?: false}] = work.breaks

      assert [finding] = findings(pieces)
      assert finding.code == :cannot_reach_piece
      assert finding.severity == :error
      assert finding.detail.available_secs == 899
      assert finding.detail.needed_secs == 900
      assert finding.detail.secs == -1
      assert finding.run_ids == ["1010"]
    end

    test "a break of exactly zero is reachable and raises nothing" do
      # 07:00 plus a 15-minute report puts the next start at 07:15.
      pieces = [piece(hms(6, 0), hms(7, 0)), piece(hms(7, 15), hms(9, 0))]
      assert [%{secs: 0, paid?: true}] = work_of(pieces).breaks
      assert :cannot_reach_piece not in codes(findings(pieces))
    end
  end

  describe "a handover away from relief" do
    defp boundary(opts) do
      %{
        gap_index: 2,
        at_secs: hms(10, 0),
        stop: Keyword.get(opts, :stop, @riv),
        at_relief?: Keyword.get(opts, :at_relief?, false),
        side: :origin,
        from_trip_id: "00000000-0000-0000-0000-0000000000a1",
        to_trip_id: "00000000-0000-0000-0000-0000000000b1",
        from_run: Keyword.get(opts, :from_run, "1010"),
        to_run: Keyword.get(opts, :to_run, "2020"),
        block_id: "101"
      }
    end

    test "a change to uncovered work is an error naming only the run that is there" do
      assert [finding] = Checks.boundary_findings([boundary(to_run: nil)])
      assert finding.code == :not_at_relief
      assert finding.severity == :error
      # The uncovered side is not a run, so it is not named.
      assert finding.run_ids == ["1010"]
      assert finding.block_id == "101"

      assert finding.trip_ids == [
               "00000000-0000-0000-0000-0000000000a1",
               "00000000-0000-0000-0000-0000000000b1"
             ]

      assert finding.detail.stop_id == "RIV"
      assert finding.detail.stop_name == "Riverside Station"
    end

    test "a change into a run names that run instead" do
      assert [finding] = Checks.boundary_findings([boundary(from_run: nil)])
      assert finding.run_ids == ["2020"]
    end

    test "a change out of uncovered work into uncovered work raises nothing" do
      assert Checks.boundary_findings([boundary(from_run: nil, to_run: nil)]) == []
    end

    test "a boundary that is at relief raises nothing" do
      assert Checks.boundary_findings([boundary(at_relief?: true)]) == []
    end

    test "a stop with no point still names the stop" do
      unmarked = %{@riv | lat: nil, lon: nil, name: nil}
      assert [finding] = Checks.boundary_findings([boundary(stop: unmarked)])
      assert finding.detail.stop_id == "RIV"
      assert finding.detail.stop_name == nil
    end
  end

  describe "travel that could not be resolved" do
    test "an unknown leg is a notice" do
      # A stop with no point at all, so nothing can be estimated to the garage.
      stranded =
        piece(hms(6, 0), hms(8, 0))
        |> Map.merge(%{
          end_ref: {:stop, "NOWHERE"},
          end_stop: %{@riv | stop_id: "NOWHERE", name: nil, lat: nil, lon: nil}
        })

      work = work_of([stranded])
      assert [%{from: {:stop, "NOWHERE"}, to: {:garage, @garage}}] = work.unknown_travel

      assert [finding] = Checks.run_findings("1010", [stranded], work, context(), @crew)
      assert finding.code == :travel_unknown
      assert finding.severity == :notice
      assert finding.detail == %{from: {:stop, "NOWHERE"}, to: {:garage, @garage}}
    end
  end

  describe "uncovered work" do
    test "no segments raises nothing" do
      assert Checks.uncovered_finding([]) == []
    end

    test "segments raise one warning counting the trips and the duty" do
      segments = [
        piece(hms(6, 0), hms(7, 0), run_id: nil, block_id: "102"),
        piece(hms(12, 40), hms(13, 10), run_id: nil, block_id: "102")
      ]

      assert [finding] = Checks.uncovered_finding(segments)
      assert finding.code == :uncovered_work
      assert finding.severity == :warning
      assert finding.run_ids == []
      assert finding.detail == %{trips: 2, secs: 3600 + 1800}
      assert length(finding.trip_ids) == 2
    end
  end

  describe "the findings of a whole run" do
    test "come out errors first, then warnings, then notices" do
      long = piece(hms(6, 0), hms(11, 0))
      pieces = [long, piece(hms(7, 0), hms(9, 0)), piece(hms(10, 0), hms(11, 0))]
      severities = findings(pieces, max_piece_minutes: 240) |> Enum.map(& &1.severity)

      assert severities == Enum.sort_by(severities, &severity_rank/1)
    end
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:notice), do: 2
end
