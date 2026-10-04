defmodule GtfsPlanner.Gtfs.Runs.TodsExportTest do
  @moduledoc """
  The `run_events.txt` rows a set of derived runs become.

  Every expected row below is hand-written from the TODS `run_events.txt` layout:
  the event types, their order, their `10, 20, …` numbering, and their times
  computed as seconds and formatted by hand. Nothing here reads the result to
  build an expectation, so a row that came out in the wrong order, with the wrong
  service, or with a wrong time fails rather than confirming itself.

  The runs are handed over as literal `Day.derived()` maps — derived and never
  stored — and the module is pure, so these cases run in the local ExUnit process
  with no sandbox, fixtures or cleanup.

  These cases cover the row construction: the event sequence, the service, the
  previous-day shift, the piece expansion, the left-out count and the uncovered
  count. Whether the ZIP's references resolve is `operations_runs_test.exs`'s
  subject.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/tods_export_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Runs.TodsExport

  @key "day-key"
  @service "ops_dt_abc123"

  @garage_uuid "0f2b3a4c-5d6e-4f70-8a91-b2c3d4e5f607"
  @other_garage_uuid "1a2b3c4d-5e6f-4a70-8b91-c2d3e4f50617"

  @t1 "2c3d4e5f-6071-4a82-93a4-b5c6d7e8f901"
  @t2 "3d4e5f60-7182-4a93-84b5-c6d7e8f90112"
  @t3 "4d5e6f70-8192-4a03-95b6-c7d8e9f01223"
  @t4 "5e6f7081-92a3-4b14-a6c7-d8e9f0122334"

  @h 3600
  @m 60

  # The movement export's IDs for the movements this file names. They are written
  # here as plain strings because the point is that this module reads them and
  # never mints one.
  @pull_out_trip "dh-101-aaaaaa-1"
  @pull_back_trip "dh-101-aaaaaa-3"
  @gap0_trip "dh-101-aaaaaa-2"
  @gap1_trip "dh-101-aaaaaa-4"

  defp garage(garage_id),
    do: %{garage_id: garage_id, name: garage_id, lat: 42.0, lon: -71.0}

  defp garages,
    do: %{@garage_uuid => garage("MAIN"), @other_garage_uuid => garage("NORTH")}

  defp trip(id, trip_id, first_stop_id, last_stop_id, first_departure, last_arrival) do
    %{
      id: id,
      trip_id: trip_id,
      route_id: "R1",
      first_stop: %{stop_id: first_stop_id},
      last_stop: %{stop_id: last_stop_id},
      first_departure: first_departure,
      last_arrival: last_arrival
    }
  end

  defp gap(index, from_id, to_id, arrival_secs, kind, drive_secs) do
    %{
      index: index,
      from_id: from_id,
      to_id: to_id,
      arrival_secs: arrival_secs,
      departure_secs: arrival_secs + 30 * @m,
      gap_secs: 30 * @m,
      kind: kind,
      drive_secs: drive_secs,
      source: :estimated,
      wait_secs: nil,
      feasible?: true,
      km: nil
    }
  end

  # A piece. `start_ref` and `end_ref` are the whole story of whether the piece
  # owns a pull-out or a pull-back: a garage ref means the block opened or closed
  # with one, a stop ref means the piece started or ended at a relief.
  defp piece(overrides) do
    Map.merge(
      %{
        run_id: "10000",
        block_id: "101",
        garage_id: @garage_uuid,
        trips: [],
        route_id: "R1",
        start_secs: 0,
        end_secs: 0,
        start_kind: :block_start,
        end_kind: :block_end,
        start_ref: {:garage, @garage_uuid},
        end_ref: {:garage, @garage_uuid},
        start_stop: nil,
        end_stop: nil,
        start_boundary: nil,
        end_boundary: nil,
        gaps: []
      },
      Map.new(overrides)
    )
  end

  defp segment(overrides) do
    Map.merge(
      %{
        kind: :piece,
        start_secs: 0,
        end_secs: 0,
        from: nil,
        to: nil,
        source: :estimated,
        piece_index: nil,
        paid?: false
      },
      Map.new(overrides)
    )
  end

  defp run(overrides) do
    Map.merge(
      %{run_id: "10000", pieces: [], work: %{sign_on_secs: 0, segments: []}, findings: []},
      Map.new(overrides)
    )
  end

  defp day(runs, uncovered \\ []) do
    %{runs: runs, uncovered: uncovered, findings: [], stats: nil, axis: nil}
  end

  defp day_type(key \\ @key) do
    %{
      key: key,
      label: "Weekday",
      dates: [~D[2026-09-14]],
      service_ids: ["A"],
      date_count: 1,
      first_date: ~D[2026-09-14],
      last_date: ~D[2026-09-14],
      trip_count: 4,
      special?: false
    }
  end

  defp ids(overrides \\ []) do
    %{
      service_ids: %{@key => %{service_id: @service, prev_service_id: nil}},
      movement_trip_ids: %{}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp rows(runs, opts \\ []) do
    TodsExport.rows(%{
      day_types: Keyword.get(opts, :day_types, [day_type()]),
      run_days: Keyword.get(opts, :run_days, %{@key => day(runs)}),
      ids: Keyword.get(opts, :ids, ids()),
      garages_by_id: garages()
    })
  end

  defp events(runs, opts), do: rows(runs, opts).run_events

  defp movement_ids do
    %{
      {@key, "101", :pull_out} => @pull_out_trip,
      {@key, "101", {:gap, 0}} => @gap0_trip,
      {@key, "101", :pull_back} => @pull_back_trip
    }
  end

  # A hand-written row. The `nil`s are the file's blank cells.
  defp row(overrides) do
    Map.merge(
      %{
        service_id: @service,
        run_id: "10000",
        event_sequence: nil,
        piece_id: "10000-1",
        block_id: "101",
        job_type: "Operator",
        event_type: nil,
        trip_id: "",
        start_location: nil,
        start_time: nil,
        start_mid_trip: nil,
        end_location: nil,
        end_time: nil,
        end_mid_trip: nil
      },
      Map.new(overrides)
    )
  end

  # A clock formatter for the TEST's own arithmetic. Deliberately not the
  # module's: an expectation built by the code under test proves nothing.
  defp hhmmss(total) do
    Enum.map_join([div(total, 3600), rem(div(total, 60), 60), rem(total, 60)], ":", fn v ->
      v |> Integer.to_string() |> String.pad_leading(2, "0")
    end)
  end

  describe "a one-piece garage run" do
    setup do
      trips = [
        trip(@t1, "TP-1", "S1", "S2", 6 * @h, 7 * @h),
        trip(@t2, "TP-2", "S3", "S4", 8 * @h, 9 * @h)
      ]

      piece =
        piece(
          trips: trips,
          start_secs: 5 * @h + 30 * @m,
          end_secs: 9 * @h + 40 * @m,
          gaps: [gap(0, @t1, @t2, 7 * @h, :drive, 20 * @m)]
        )

      segments = [
        segment(
          kind: :report,
          start_secs: 5 * @h + 15 * @m,
          end_secs: 5 * @h + 30 * @m,
          from: {:garage, @garage_uuid},
          to: {:garage, @garage_uuid}
        ),
        segment(
          kind: :piece,
          start_secs: 5 * @h + 30 * @m,
          end_secs: 9 * @h + 40 * @m,
          piece_index: 1
        ),
        segment(
          kind: :sign_off,
          start_secs: 9 * @h + 40 * @m,
          end_secs: 9 * @h + 45 * @m,
          from: {:garage, @garage_uuid},
          to: {:garage, @garage_uuid}
        )
      ]

      %{
        run:
          run(
            run_id: "10000",
            pieces: [piece],
            work: %{sign_on_secs: 5 * @h + 15 * @m, segments: segments}
          )
      }
    end

    test "writes Report Time, Pull-Out, two Operator, Deadhead, Pull-Back, Sign-Off", %{run: run} do
      expected = [
        # 05:15 -> 05:30, 15 minutes at the garage.
        row(
          event_sequence: 10,
          event_type: "Report Time",
          start_location: "MAIN",
          start_time: "05:15:00",
          end_location: "MAIN",
          end_time: "05:30:00"
        ),
        # 05:30 -> 06:00, garage to the first stop.
        row(
          event_sequence: 20,
          event_type: "Pull-Out",
          trip_id: @pull_out_trip,
          start_location: "MAIN",
          start_time: "05:30:00",
          start_mid_trip: 2,
          end_location: "S1",
          end_time: "06:00:00",
          end_mid_trip: 2
        ),
        row(
          event_sequence: 30,
          event_type: "Operator",
          trip_id: "TP-1",
          start_location: "S1",
          start_time: "06:00:00",
          start_mid_trip: 2,
          end_location: "S2",
          end_time: "07:00:00",
          end_mid_trip: 2
        ),
        # 07:00 -> 07:20, S2 to S3, the piece's own drive gap.
        row(
          event_sequence: 40,
          event_type: "Deadhead",
          trip_id: @gap0_trip,
          start_location: "S2",
          start_time: "07:00:00",
          start_mid_trip: 2,
          end_location: "S3",
          end_time: "07:20:00",
          end_mid_trip: 2
        ),
        row(
          event_sequence: 50,
          event_type: "Operator",
          trip_id: "TP-2",
          start_location: "S3",
          start_time: "08:00:00",
          start_mid_trip: 2,
          end_location: "S4",
          end_time: "09:00:00",
          end_mid_trip: 2
        ),
        # 09:00 -> 09:40, the last stop back to the garage.
        row(
          event_sequence: 60,
          event_type: "Pull-Back",
          trip_id: @pull_back_trip,
          start_location: "S4",
          start_time: "09:00:00",
          start_mid_trip: 2,
          end_location: "MAIN",
          end_time: "09:40:00",
          end_mid_trip: 2
        ),
        # 09:40 -> 09:45, at the garage, on no piece and no block.
        row(
          event_sequence: 70,
          piece_id: nil,
          block_id: nil,
          event_type: "Sign-Off",
          start_location: "MAIN",
          start_time: "09:40:00",
          end_location: "MAIN",
          end_time: "09:45:00"
        )
      ]

      assert events([run], ids: ids(movement_trip_ids: movement_ids())) == expected
    end

    test "every event is on the day type's own service", %{run: run} do
      for event <- events([run], ids: ids(movement_trip_ids: movement_ids())) do
        assert event.service_id == @service
        assert event.job_type == "Operator"
      end
    end

    test "the sequence starts at 10 and ascends by 10", %{run: run} do
      sequences =
        events([run], ids: ids(movement_trip_ids: movement_ids()))
        |> Enum.map(& &1.event_sequence)

      assert sequences == [10, 20, 30, 40, 50, 60, 70]
    end
  end

  describe "a piece that starts at a relief" do
    setup do
      # The piece begins at a relief stop, not the garage, so it owns no
      # pull-out: the relief drive belongs to the outgoing operator.
      trips = [
        trip(@t3, "TP-3", "R1", "R2", 10 * @h + 5 * @m, 11 * @h),
        trip(@t4, "TP-4", "R3", "R4", 12 * @h, 13 * @h)
      ]

      piece =
        piece(
          trips: trips,
          start_secs: 10 * @h,
          end_secs: 13 * @h + 30 * @m,
          start_kind: :relief,
          start_ref: {:stop, "R1"},
          start_stop: %{stop_id: "R1"},
          end_ref: {:garage, @garage_uuid}
        )

      segments = [
        segment(
          kind: :travel,
          start_secs: 9 * @h + 40 * @m,
          end_secs: 10 * @h,
          from: {:garage, @garage_uuid},
          to: {:stop, "R1"}
        ),
        segment(
          kind: :report,
          start_secs: 10 * @h,
          end_secs: 10 * @h + 5 * @m,
          from: {:stop, "R1"},
          to: {:stop, "R1"}
        ),
        segment(
          kind: :piece,
          start_secs: 10 * @h + 5 * @m,
          end_secs: 13 * @h + 30 * @m,
          piece_index: 1
        ),
        segment(
          kind: :sign_off,
          start_secs: 13 * @h + 30 * @m,
          end_secs: 13 * @h + 35 * @m,
          from: {:garage, @garage_uuid},
          to: {:garage, @garage_uuid}
        )
      ]

      %{
        run:
          run(
            run_id: "10000",
            pieces: [piece],
            work: %{sign_on_secs: 9 * @h + 40 * @m, segments: segments}
          )
      }
    end

    test "travels out, reports at the relief stop, works, pulls back, signs off", %{run: run} do
      expected = [
        row(
          event_sequence: 10,
          event_type: "Travel",
          start_location: "MAIN",
          start_time: "09:40:00",
          end_location: "R1",
          end_time: "10:00:00"
        ),
        # The report is AT the relief stop, not the garage: 5 minutes, the relief
        # allowance rather than the 15 a pull-out gets.
        row(
          event_sequence: 20,
          event_type: "Report Time",
          start_location: "R1",
          start_time: "10:00:00",
          end_location: "R1",
          end_time: "10:05:00"
        ),
        row(
          event_sequence: 30,
          event_type: "Operator",
          trip_id: "TP-3",
          start_location: "R1",
          start_time: "10:05:00",
          start_mid_trip: 2,
          end_location: "R2",
          end_time: "11:00:00",
          end_mid_trip: 2
        ),
        row(
          event_sequence: 40,
          event_type: "Operator",
          trip_id: "TP-4",
          start_location: "R3",
          start_time: "12:00:00",
          start_mid_trip: 2,
          end_location: "R4",
          end_time: "13:00:00",
          end_mid_trip: 2
        ),
        row(
          event_sequence: 50,
          event_type: "Pull-Back",
          trip_id: @pull_back_trip,
          start_location: "R4",
          start_time: "13:00:00",
          start_mid_trip: 2,
          end_location: "MAIN",
          end_time: "13:30:00",
          end_mid_trip: 2
        ),
        row(
          event_sequence: 60,
          piece_id: nil,
          block_id: nil,
          event_type: "Sign-Off",
          start_location: "MAIN",
          start_time: "13:30:00",
          end_location: "MAIN",
          end_time: "13:35:00"
        )
      ]

      written = events([run], ids: ids(movement_trip_ids: movement_ids()))

      # No Pull-Out: the piece did not start a block, and the pull-out ID belongs
      # to the block's own first piece.
      assert Enum.map(written, & &1.event_type) ==
               ["Travel", "Report Time", "Operator", "Operator", "Pull-Back", "Sign-Off"]

      assert written == expected
    end
  end

  describe "a split run" do
    setup do
      # Two pieces in one run, with a break between them. Each piece reports for
      # itself, and the break and the sign-off belong to neither piece.
      first =
        piece(
          trips: [trip(@t1, "TP-1", "S1", "S2", 6 * @h, 7 * @h)],
          start_secs: 5 * @h + 45 * @m,
          end_secs: 7 * @h
        )

      second =
        piece(
          trips: [trip(@t2, "TP-2", "S3", "S4", 12 * @h, 13 * @h)],
          start_secs: 12 * @h,
          end_secs: 13 * @h + 30 * @m,
          start_kind: :relief,
          start_ref: {:stop, "S3"}
        )

      segments = [
        segment(
          kind: :report,
          start_secs: 5 * @h + 30 * @m,
          end_secs: 5 * @h + 45 * @m,
          from: {:garage, @garage_uuid},
          to: {:garage, @garage_uuid}
        ),
        segment(kind: :piece, start_secs: 5 * @h + 45 * @m, end_secs: 7 * @h, piece_index: 1),
        segment(
          kind: :report,
          start_secs: 12 * @h - 15 * @m,
          end_secs: 12 * @h,
          from: {:garage, @garage_uuid},
          to: {:garage, @garage_uuid}
        ),
        segment(
          kind: :break,
          start_secs: 7 * @h,
          end_secs: 12 * @h - 15 * @m,
          from: {:stop, "S2"},
          to: {:stop, "S2"}
        ),
        segment(kind: :piece, start_secs: 12 * @h, end_secs: 13 * @h + 30 * @m, piece_index: 2),
        segment(
          kind: :sign_off,
          start_secs: 13 * @h + 30 * @m,
          end_secs: 13 * @h + 35 * @m,
          from: {:garage, @garage_uuid},
          to: {:garage, @garage_uuid}
        )
      ]

      %{
        run:
          run(
            run_id: "1010",
            pieces: [first, second],
            work: %{sign_on_secs: 5 * @h + 30 * @m, segments: segments}
          )
      }
    end

    test "two Report Time events, a Break on no piece, and one Sign-Off", %{run: run} do
      written = events([run], ids: ids())

      # Two reports, because a split's second piece reports for itself.
      reports = Enum.filter(written, &(&1.event_type == "Report Time"))
      assert length(reports) == 2

      # Each 00:15:00 long, which is what `end_time - start_time` says.
      for report <- reports do
        assert report.end_time == hhmmss(to_secs(report.start_time) + 15 * @m)
      end

      assert Enum.map(reports, & &1.start_time) == ["05:30:00", "11:45:00"]

      # Exactly one break, and one sign-off: a break is not a report, and a sign-off
      # happens once per run however many pieces it has.
      assert length(Enum.filter(written, &(&1.event_type == "Break"))) == 1
      assert length(Enum.filter(written, &(&1.event_type == "Sign-Off"))) == 1
    end

    test "the Break and the Sign-Off carry no piece and no block", %{run: run} do
      for event <- events([run], ids: ids()),
          event_type <- ["Break", "Sign-Off"] do
        if event.event_type == event_type do
          assert event.piece_id == nil
          assert event.block_id == nil
        end
      end
    end

    test "each piece is numbered 1 and 2 within the run", %{run: run} do
      piece_ids =
        [run]
        |> events(ids: ids())
        |> Enum.reject(&is_nil(&1.piece_id))
        |> Enum.map(& &1.piece_id)
        |> Enum.uniq()

      assert piece_ids == ["1010-1", "1010-2"]
    end
  end

  describe "a run signing on before midnight" do
    setup do
      # Signing on at 23:50 the day before is -600 seconds into this service day.
      # The revenue trip at 06:00 is therefore 30:00 on the previous service day.
      trips = [trip(@t1, "TP-1", "S1", "S2", 6 * @h, 7 * @h)]

      piece = piece(trips: trips, start_secs: -5 * @m, end_secs: 7 * @h + 30 * @m)

      segments = [
        segment(
          kind: :report,
          start_secs: -10 * @m,
          end_secs: -5 * @m,
          from: {:garage, @garage_uuid},
          to: {:garage, @garage_uuid}
        ),
        segment(kind: :piece, start_secs: -5 * @m, end_secs: 7 * @h + 30 * @m, piece_index: 1)
      ]

      %{
        run:
          run(
            run_id: "10000",
            pieces: [piece],
            work: %{sign_on_secs: -10 * @m, segments: segments}
          ),
        day_ids: ids(service_ids: %{@key => %{service_id: @service, prev_service_id: nil}})
      }
    end

    test "is written on the day type's own service", %{run: run, day_ids: day_ids} do
      for event <- events([run], ids: day_ids) do
        assert event.service_id == @service
      end
    end

    test "reads 23:50 for a 23:50 sign-on and 30:00 for a 06:00 trip", %{
      run: run,
      day_ids: day_ids
    } do
      written = events([run], ids: day_ids)

      report = Enum.find(written, &(&1.event_type == "Report Time"))
      assert report.start_time == "23:50:00"
      assert report.end_time == "23:55:00"

      # 06:00 on this service day reads 30:00 because the whole run is read one
      # day later, so the 23:50 sign-on stays in order before it. Above 24:00, not
      # wrapped into the morning: the run really did work past midnight.
      operator = Enum.find(written, &(&1.event_type == "Operator"))
      assert operator.start_time == "30:00:00"
      assert operator.end_time == "31:00:00"
    end

    test "writes no negative time", %{run: run, day_ids: day_ids} do
      for event <- events([run], ids: day_ids) do
        assert to_secs(event.start_time) >= 0
        assert to_secs(event.end_time) >= 0
      end
    end

    test "run_day_types/1 marks this day type shifted?", %{run: run} do
      assert TodsExport.run_day_types(%{@key => day([run])}) == %{@key => %{shifted?: true}}
    end
  end

  describe "run_day_types/1" do
    test "is false for a day type whose runs all sign on at or after midnight" do
      normal = run(work: %{sign_on_secs: 5 * @h, segments: []})

      assert TodsExport.run_day_types(%{@key => day([normal])}) == %{@key => %{shifted?: false}}
    end

    test "ignores a run with an error, because it is never written" do
      # A run that signs on before midnight but is dropped for an error would
      # leave a movement read as extended against a service the run never uses.
      broken = %{
        run_id: "10000",
        pieces: [],
        work: %{sign_on_secs: -600, segments: []},
        findings: [%{code: :cannot_reach_piece, severity: :error, run_ids: ["10000"]}]
      }

      # Still listed: the run is not left out of the day, it is left out of the
      # FILE. What it must not do is shift a movement for a run no file carries.
      assert TodsExport.run_day_types(%{@key => day([broken])}) == %{@key => %{shifted?: false}}
    end

    test "a day type with no runs is not asked for a service at all" do
      # Absent, not present with shifted?: false. Asking for a service makes the
      # movement export mint one and list the day type's dates on it, which is the
      # header-only `calendar_dates_supplement.txt` it otherwise refuses to write.
      assert TodsExport.run_day_types(%{@key => day([])}) == %{}
    end
  end

  describe "a run with an error" do
    setup do
      broken = %{
        run_id: "10000",
        pieces: [],
        work: %{sign_on_secs: 5 * @h, segments: []},
        findings: [
          %{code: :cannot_reach_piece, severity: :error, run_ids: ["10000"]},
          %{code: :piece_too_long, severity: :warning, run_ids: ["10000"]}
        ]
      }

      fine = run(run_id: "10001", work: %{sign_on_secs: 5 * @h, segments: []})
      %{broken: broken, fine: fine}
    end

    test "is left out of the rows entirely", %{broken: broken, fine: fine} do
      result = rows([broken, fine])

      # A run written with a caveat is worse than one absent: a consumer would
      # roster an operator onto a run this planner already knows is broken.
      for event <- result.run_events do
        assert event.run_id == "10001"
      end
    end

    test "is counted in left_out", %{broken: broken, fine: fine} do
      assert rows([broken, fine]).left_out == 1
    end

    test "a warning alone does not leave a run out", %{fine: fine} do
      warned = %{
        fine
        | findings: [%{code: :piece_too_long, severity: :warning, run_ids: ["10001"]}]
      }

      assert rows([warned]).left_out == 0
    end
  end

  describe "uncovered trips" do
    test "are counted per day type and reported only when there are some" do
      uncovered_piece =
        piece(run_id: nil, trips: [trip(@t3, "TP-3", "S1", "S2", 6 * @h, 7 * @h)])

      result =
        rows([], run_days: %{@key => day([run([])], [uncovered_piece])})

      assert result.uncovered == [%{day_type: day_type(), trips: 1}]
    end

    test "a day type with no runs is not reported, because nothing in it has been cut" do
      uncovered_piece =
        piece(run_id: nil, trips: [trip(@t3, "TP-3", "S1", "S2", 6 * @h, 7 * @h)])

      assert rows([], run_days: %{@key => day([], [uncovered_piece])}).uncovered == []
    end

    test "a day type with nothing uncovered is not reported" do
      assert rows([], run_days: %{@key => day([])}).uncovered == []
    end

    test "are counted once even when two pieces share a trip" do
      a = piece(run_id: nil, trips: [trip(@t3, "TP-3", "S1", "S2", 6 * @h, 7 * @h)])
      b = piece(run_id: nil, trips: [trip(@t3, "TP-3", "S1", "S2", 6 * @h, 7 * @h)])

      assert rows([], run_days: %{@key => day([run([])], [a, b])}).uncovered == [
               %{day_type: day_type(), trips: 1}
             ]
    end
  end

  describe "a day type with no service" do
    test "writes nothing, because a run event with no service is not a row" do
      result =
        rows([run(work: %{sign_on_secs: 5 * @h, segments: []})], ids: ids(service_ids: %{}))

      assert result.run_events == []
      assert result.left_out == 0
    end

    test "a day type absent from run_days contributes nothing" do
      result = rows([], run_days: %{})

      assert result.run_events == []
      assert result.uncovered == []
    end
  end

  describe "trip events never overlap" do
    test "within every run, in every case above" do
      cases = all_cases()

      for {label, run_list, opts} <- cases do
        written = events(run_list, opts)

        for run_id <- written |> Enum.map(& &1.run_id) |> Enum.uniq() do
          trip_events =
            written
            |> Enum.filter(&(&1.run_id == run_id and not is_nil(&1.start_mid_trip)))

          ordered = Enum.sort_by(trip_events, &to_secs(&1.start_time))

          ordered
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.each(fn [earlier, later] ->
            assert to_secs(later.start_time) >= to_secs(earlier.end_time),
                   "#{label}: #{later.event_type} at #{later.start_time} starts before " <>
                     "#{earlier.event_type} ends at #{earlier.end_time}"
          end)
        end
      end
    end
  end

  defp all_cases do
    [
      {"one-piece", [one_piece_run()], [ids: ids(movement_trip_ids: movement_ids())]},
      {"relief-start", [relief_run()], [ids: ids(movement_trip_ids: movement_ids())]},
      {"split", [split_run()], [ids: ids()]},
      {"two-drive", [two_drive_run()], [ids: ids(movement_trip_ids: two_drive_ids())]}
    ]
  end

  defp one_piece_run do
    trips = [
      trip(@t1, "TP-1", "S1", "S2", 6 * @h, 7 * @h),
      trip(@t2, "TP-2", "S3", "S4", 8 * @h, 9 * @h)
    ]

    p =
      piece(
        trips: trips,
        start_secs: 5 * @h + 30 * @m,
        end_secs: 9 * @h + 40 * @m,
        gaps: [gap(0, @t1, @t2, 7 * @h, :drive, 20 * @m)]
      )

    run(
      run_id: "10000",
      pieces: [p],
      work: %{
        sign_on_secs: 5 * @h + 15 * @m,
        segments: [
          segment(
            kind: :report,
            start_secs: 5 * @h + 15 * @m,
            end_secs: 5 * @h + 30 * @m,
            from: {:garage, @garage_uuid},
            to: {:garage, @garage_uuid}
          ),
          segment(
            kind: :piece,
            start_secs: 5 * @h + 30 * @m,
            end_secs: 9 * @h + 40 * @m,
            piece_index: 1
          ),
          segment(
            kind: :sign_off,
            start_secs: 9 * @h + 40 * @m,
            end_secs: 9 * @h + 45 * @m,
            from: {:garage, @garage_uuid},
            to: {:garage, @garage_uuid}
          )
        ]
      }
    )
  end

  defp two_drive_run do
    trips = [
      trip(@t1, "TP-1", "S1", "S2", 6 * @h, 7 * @h),
      trip(@t2, "TP-2", "S3", "S4", 8 * @h, 9 * @h),
      trip(@t3, "TP-3", "S5", "S6", 10 * @h, 11 * @h)
    ]

    p =
      piece(
        trips: trips,
        start_secs: 5 * @h + 30 * @m,
        end_secs: 12 * @h + 40 * @m,
        gaps: [
          gap(0, @t1, @t2, 7 * @h, :drive, 20 * @m),
          gap(1, @t2, @t3, 9 * @h, :layover, nil)
        ]
      )

    run(
      run_id: "10000",
      pieces: [p],
      work: %{
        sign_on_secs: 5 * @h + 15 * @m,
        segments: [
          segment(
            kind: :report,
            start_secs: 5 * @h + 15 * @m,
            end_secs: 5 * @h + 30 * @m,
            from: {:garage, @garage_uuid},
            to: {:garage, @garage_uuid}
          ),
          segment(
            kind: :piece,
            start_secs: 5 * @h + 30 * @m,
            end_secs: 12 * @h + 40 * @m,
            piece_index: 1
          )
        ]
      }
    )
  end

  defp relief_run do
    trips = [
      trip(@t3, "TP-3", "R1", "R2", 10 * @h + 5 * @m, 11 * @h),
      trip(@t4, "TP-4", "R3", "R4", 12 * @h, 13 * @h)
    ]

    p =
      piece(
        trips: trips,
        start_secs: 10 * @h,
        end_secs: 13 * @h + 30 * @m,
        start_kind: :relief,
        start_ref: {:stop, "R1"},
        end_ref: {:garage, @garage_uuid}
      )

    run(
      run_id: "10000",
      pieces: [p],
      work: %{
        sign_on_secs: 9 * @h + 40 * @m,
        segments: [
          segment(
            kind: :travel,
            start_secs: 9 * @h + 40 * @m,
            end_secs: 10 * @h,
            from: {:garage, @garage_uuid},
            to: {:stop, "R1"}
          ),
          segment(
            kind: :report,
            start_secs: 10 * @h,
            end_secs: 10 * @h + 5 * @m,
            from: {:stop, "R1"},
            to: {:stop, "R1"}
          ),
          segment(
            kind: :piece,
            start_secs: 10 * @h + 5 * @m,
            end_secs: 13 * @h + 30 * @m,
            piece_index: 1
          ),
          segment(
            kind: :sign_off,
            start_secs: 13 * @h + 30 * @m,
            end_secs: 13 * @h + 35 * @m,
            from: {:garage, @garage_uuid},
            to: {:garage, @garage_uuid}
          )
        ]
      }
    )
  end

  defp split_run do
    first =
      piece(
        trips: [trip(@t1, "TP-1", "S1", "S2", 6 * @h, 7 * @h)],
        start_secs: 5 * @h + 45 * @m,
        end_secs: 7 * @h
      )

    second =
      piece(
        trips: [trip(@t2, "TP-2", "S3", "S4", 12 * @h, 13 * @h)],
        start_secs: 12 * @h,
        end_secs: 13 * @h + 30 * @m,
        start_kind: :relief,
        start_ref: {:stop, "S3"}
      )

    run(
      run_id: "1010",
      pieces: [first, second],
      work: %{
        sign_on_secs: 5 * @h + 30 * @m,
        segments: [
          segment(
            kind: :report,
            start_secs: 5 * @h + 30 * @m,
            end_secs: 5 * @h + 45 * @m,
            from: {:garage, @garage_uuid},
            to: {:garage, @garage_uuid}
          ),
          segment(kind: :piece, start_secs: 5 * @h + 45 * @m, end_secs: 7 * @h, piece_index: 1),
          segment(
            kind: :report,
            start_secs: 12 * @h - 15 * @m,
            end_secs: 12 * @h,
            from: {:garage, @garage_uuid},
            to: {:garage, @garage_uuid}
          ),
          segment(
            kind: :break,
            start_secs: 7 * @h,
            end_secs: 12 * @h - 15 * @m,
            from: {:stop, "S2"},
            to: {:stop, "S2"}
          ),
          segment(kind: :piece, start_secs: 12 * @h, end_secs: 13 * @h + 30 * @m, piece_index: 2),
          segment(
            kind: :sign_off,
            start_secs: 13 * @h + 30 * @m,
            end_secs: 13 * @h + 35 * @m,
            from: {:garage, @garage_uuid},
            to: {:garage, @garage_uuid}
          )
        ]
      }
    )
  end

  defp two_drive_ids do
    %{
      {@key, "101", :pull_out} => @pull_out_trip,
      {@key, "101", {:gap, 0}} => @gap0_trip,
      {@key, "101", {:gap, 1}} => @gap1_trip,
      {@key, "101", :pull_back} => @pull_back_trip
    }
  end

  # `HH:MM:SS` back to seconds, so a length or an order can be asserted on times
  # without re-deriving them.
  defp to_secs(clock) do
    [h, m, s] = clock |> String.split(":") |> Enum.map(&String.to_integer/1)
    h * @h + m * @m + s
  end
end
