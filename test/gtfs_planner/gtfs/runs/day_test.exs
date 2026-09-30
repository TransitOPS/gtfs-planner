defmodule GtfsPlanner.Gtfs.Runs.DayTest do
  @moduledoc """
  One day's runs, findings and figures.

  The day here is six blocks over one garage, all hand-built through the real
  `Blocking.Movements.build/3` and `Blocking.Relief.windows/3` as
  `pieces_test.exs` builds its own, so the pieces and boundaries under test are
  derived rather than asserted.

  ## The day, and its figures, by hand

  Every block is one trip at the station, and the garage stands at the station's
  own point, so there is no travel anywhere: each piece starts and ends at the
  garage and the pull-out and pull-back costs nothing. A run's paid time is
  therefore 15 + 15 of report + its pieces + 5 to sign off, and a run with two
  pieces is `straight` or `split` purely on the break between them.

      101  06:00–07:00  run A        one piece          :one_piece
      102  07:45–08:45  run S   ┐
      103  09:30–10:30  run S   ┘ two pieces, break  30 min  :straight
      104  12:00–13:00  run P   ┐
      105  14:00–15:00  run P   ┘ two pieces, break  45 min  :split
      106  16:00–17:00  unassigned                     one uncovered segment

  A break is the next start less its 15-minute report less the previous end, so
  S's is 09:30 − 15 − 08:45 = 30 minutes, exactly at the paid maximum, and P's
  is 14:00 − 15 − 13:00 = 45 minutes, over it.

      A  sign-on 05:45  sign-off 07:05  spread  80 min  paid  15+60+5      =  80
      S  sign-on 07:30  sign-off 10:35  spread 185 min  paid  15+15+60+60+5+30 = 185
      P  sign-on 11:45  sign-off 15:05  spread 200 min  paid  15+15+60+60+5   = 155

  S's 30-minute break is at the paid maximum, so it is paid time as well as a
  break; P's 45 minutes is not. That difference is most of why the two runs with
  identical pieces have different paid totals.

  `straight_share` is 1 ÷ (1 + 1) = 50: A is in neither the numerator nor the
  denominator, because a run with no break had no choice to be straight.
  `vehicle_share` is (60 + 120 + 120) ÷ (80 + 185 + 155) = 300 ÷ 420 = 71.4…,
  which rounds to 71. The longest spread is P's 200 minutes. `axis` starts at A's
  sign-on, 05:45, and ends at the uncovered segment's finish, 17:00.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/day_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Relief
  alias GtfsPlanner.Gtfs.Runs.Day

  @garage_uuid "11111111-2222-4333-8444-555555555555"
  @bay_a %{stop_id: "BAY_A", name: "Bay A", parent_station: "RIV", lat: 42.0, lon: -71.0}
  @bay_b %{stop_id: "BAY_B", name: "Bay B", parent_station: "RIV", lat: 42.0, lon: -71.0}

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
    {lat, lon} = Keyword.get(opts, :garage_at, {42.0, -71.0})

    garage = %{
      id: @garage_uuid,
      garage_id: "MAIN",
      name: "Main Garage",
      lat: lat,
      lon: lon
    }

    struct!(Context,
      min_layover_minutes: 0,
      pull_out_buffer_minutes: 0,
      deadhead_speed_kmh: 30,
      deadhead_circuity: 1.3,
      entered_minutes: Keyword.get(opts, :entered, %{}),
      trip_km: %{},
      garages: if(Keyword.get(opts, :garage, true), do: %{@garage_uuid => garage}, else: %{}),
      relief_stop_ids: MapSet.new(Keyword.get(opts, :marked, []))
    )
  end

  # One trip in its own block, assigned to `run` (or to nothing when `run` is nil).
  defp solo_block(block_id, departure, arrival, run) do
    [trip] = trips(block_id, [{departure, arrival, @bay_a, @bay_a}])
    {block, [^trip]} = block(block_id, [trip], context())
    {block, if(run, do: %{trip.id => run}, else: %{})}
  end

  defp trips(block_id, specs) do
    specs
    |> Enum.with_index(1)
    |> Enum.map(fn {{departure, arrival, first, last}, index} ->
      %{
        id: Ecto.UUID.generate(),
        trip_id: "#{block_id}-#{index}",
        route_id: "R1",
        service_id: "WKDY",
        block_id: block_id,
        trip_headsign: nil,
        route_pattern_id: nil,
        shape_id: "SH1",
        updated_at: DateTime.utc_now(),
        frequency?: false,
        headway_secs: nil,
        first_arrival: departure,
        first_departure: departure,
        last_arrival: arrival,
        last_departure: arrival,
        first_stop: first,
        last_stop: last,
        plottable?: true
      }
    end)
  end

  defp block(block_id, trips, context) do
    sequence = Checks.sequence(trips)
    movements = Movements.build(trips, resolution(), context)
    windows = Relief.windows(trips, movements, context)

    {%{block_id: block_id, trips: sequence, movements: movements, windows: windows}, trips}
  end

  defp resolution do
    %{
      garage_id: @garage_uuid,
      vehicle_type_id: nil,
      garage_source: :default,
      conflict: nil
    }
  end

  # The six-block day, returned as blocks and the assignments they carry.
  defp full_day do
    {a, map_a} = solo_block("101", hms(6, 0), hms(7, 0), "A")
    {s1, map_s1} = solo_block("102", hms(7, 45), hms(8, 45), "S")
    {s2, map_s2} = solo_block("103", hms(9, 30), hms(10, 30), "S")
    {p1, map_p1} = solo_block("104", hms(12, 0), hms(13, 0), "P")
    {p2, map_p2} = solo_block("105", hms(14, 0), hms(15, 0), "P")
    {u, map_u} = solo_block("106", hms(16, 0), hms(17, 0), nil)

    {[a, s1, s2, p1, p2, u],
     Map.merge(
       Map.merge(map_a, map_s1),
       Map.merge(map_s2, Map.merge(map_p1, Map.merge(map_p2, map_u)))
     )}
  end

  describe "a day of one of each kind of run" do
    setup do
      {blocks, assignments} = full_day()
      {:ok, day: Day.derive(blocks, assignments, context(), @crew)}
    end

    test "groups the pieces into three runs of three types", %{day: day} do
      assert [a, s, p] = day.runs
      assert {a.run_id, s.run_id, p.run_id} == {"A", "S", "P"}

      # S and P each serve two blocks, which is what makes them two-piece runs.
      assert length(a.pieces) == 1
      assert length(s.pieces) == 2
      assert length(p.pieces) == 2

      assert a.work.type == :one_piece
      assert s.work.type == :straight
      assert p.work.type == :split
      assert day.stats.runs == 3
      assert day.stats.by_type == %{one_piece: 1, straight: 1, split: 1}
    end

    test "counts the straight share over the runs that had a choice", %{day: day} do
      # A is in neither side: a run with one piece had no break to be straight or
      # split about.
      assert day.stats.straight_share == 50
    end

    test "sums paid and vehicle seconds and rounds the vehicle share", %{day: day} do
      # 80 + 185 + 155 paid, and 60 + 120 + 120 on vehicles: 300 ÷ 420 = 71.4.
      assert minutes(day.stats.paid_secs) == 80 + 185 + 155
      assert minutes(day.stats.vehicle_secs) == 60 + 120 + 120
      assert day.stats.vehicle_share == 71
    end

    test "names the run with the longest spread", %{day: day} do
      # A 80 min, S 185 min, P 200 min.
      assert day.stats.longest_spread == %{run_id: "P", secs: hms(3, 20)}
    end

    test "counts the uncovered trips and their duty", %{day: day} do
      assert [segment] = day.uncovered
      assert is_nil(segment.run_id)
      assert day.stats.uncovered == %{trips: 1, secs: hms(1, 0)}
    end

    test "spans the axis from the earliest sign-on to the latest uncovered end", %{day: day} do
      # 05:45 is A's sign-on; 17:00 is the uncovered segment's finish, which is
      # later than every run's sign-off.
      assert day.axis == %{start_secs: hms(5, 45), end_secs: hms(17, 0)}
    end

    test "counts problems by severity, and one uncovered segment is one warning", %{day: day} do
      # Nothing here breaches a limit, so the day's only finding is the page-level
      # statement that 16:00–17:00 is unassigned.
      assert [%{code: :uncovered_work, severity: :warning}] = day.findings
      assert day.stats.problems == %{errors: 0, warnings: 1, notices: 0}
    end
  end

  describe "a day of only uncovered work" do
    test "has no straight share and an axis from the segment alone" do
      {block, assignments} = solo_block("106", hms(16, 0), hms(17, 0), nil)
      day = Day.derive([block], assignments, context(), @crew)

      assert day.runs == []
      assert day.stats.runs == 0
      assert day.stats.by_type == %{one_piece: 0, straight: 0, split: 0}
      # Zero straight of zero eligible runs is not a percentage.
      assert day.stats.straight_share == nil
      assert day.stats.paid_secs == 0
      assert day.stats.vehicle_share == nil
      assert day.stats.longest_spread == nil
      assert day.axis == %{start_secs: hms(16, 0), end_secs: hms(17, 0)}
    end
  end

  describe "an empty day" do
    test "is zero figures and no axis" do
      day = Day.derive([], %{}, context(), @crew)

      assert day.runs == []
      assert day.uncovered == []
      assert day.findings == []
      assert day.axis == nil

      assert day.stats == %{
               runs: 0,
               by_type: %{one_piece: 0, straight: 0, split: 0},
               straight_share: nil,
               paid_secs: 0,
               vehicle_secs: 0,
               vehicle_share: nil,
               longest_spread: nil,
               uncovered: %{trips: 0, secs: 0},
               problems: %{errors: 0, warnings: 0, notices: 0}
             }
    end
  end

  describe "the order runs come out in" do
    test "is by sign-on, then by run ID when they sign on together" do
      # Two blocks starting at the same minute, assigned to "Z" and "A", and a
      # third starting later. The two that tie are ordered by ID, not by the
      # order the blocks were handed in or by assignment.
      {z, map_z} = solo_block("101", hms(6, 0), hms(7, 0), "Z")
      {a, map_a} = solo_block("102", hms(6, 0), hms(7, 0), "A")
      {m, map_m} = solo_block("103", hms(8, 0), hms(9, 0), "M")

      blocks = [z, a, m]
      assignments = Map.merge(map_z, Map.merge(map_a, map_m))
      day = Day.derive(blocks, assignments, context(), @crew)

      assert Enum.map(day.runs, & &1.run_id) == ["A", "Z", "M"]
    end
  end

  describe "a handover away from relief" do
    test "reaches the day's findings and every run it names" do
      # One block, two trips, unmarked stops, so the change has no relief window
      # and the handover lands at the first trip's last arrival.
      trips =
        trips("101", [
          {hms(18, 0), hms(19, 0), @bay_a, @bay_a},
          {hms(19, 30), hms(20, 30), @bay_b, @bay_b}
        ])

      {block, [first, second]} = block("101", trips, context())
      assignments = %{first.id => "R1", second.id => "R2"}

      day = Day.derive([block], assignments, context(), @crew)

      assert [r1, r2] = day.runs
      assert Enum.map([r1, r2], & &1.run_id) == ["R1", "R2"]

      # One error on the day, naming both runs…
      assert [finding] = day.findings
      assert finding.code == :not_at_relief
      assert finding.severity == :error
      assert finding.run_ids == ["R1", "R2"]

      # …attached to each of them, so opening one run still shows it.
      assert [attached] = r1.findings
      assert attached == finding
      assert [^attached] = r2.findings

      # Counted once, not twice, however many runs it is attached to.
      assert day.stats.problems == %{errors: 1, warnings: 0, notices: 0}
    end
  end
end
