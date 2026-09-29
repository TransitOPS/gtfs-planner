defmodule GtfsPlanner.Gtfs.Blocking.TodsExportTest do
  @moduledoc """
  Merge evidence (EV-24) for CL-24 / R13 and AC-29: the supplement rows one
  version's derived movements become.

  The expected values here are recomputed from R13's own rule rather than read
  back from the module: a day type's service ID is the SHA-256 of its key at the
  width the identifier takes, which this file computes with `:crypto` directly,
  and the previous day's dates are `Date.add/2` away from the day type's own. The
  per-date uniqueness case builds its expected `(movement, date)` pairs from the
  day types' dates rather than from the returned `calendar_dates`, so a row that
  appeared twice on a date, or a date that was missing, would fail.

  The module under test is pure: it reads its arguments and touches no database,
  clock, file or network (CR-1), so these cases run in the local ExUnit process
  with no sandbox, no fixtures and no cleanup. Movements are handed over as the
  literal `Movements.t()` maps the day load produces — they are derived and never
  stored (INV-8) — and garage endpoints carry the garage's UUID, with this export
  the only place they become the public `garage_id` (CR-7).

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/tods_export_test.exs`. What it
  establishes is the row construction: the services, the one-per-date rule, the
  `_prev` day, the clock, the identifiers and their collision handling, and the
  omitted count. Whether the ZIP those rows are written into passes the Mobility
  Data validator, and whether a version's blocks and driving times are right, are
  EV-8's and EV-14's.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.TodsExport

  @garage_uuid "0f2b3a4c-5d6e-4f70-8a91-b2c3d4e5f607"
  @other_garage_uuid "1a2b3c4d-5e6f-4a70-8b91-c2d3e4f50617"
  @t1_id "2c3d4e5f-6071-4a82-93a4-b5c6d7e8f901"
  @t2_id "3d4e5f60-7182-4a93-84b5-c6d7e8f90112"

  @d1 ~D[2026-09-14]
  @d2 ~D[2026-09-15]
  @d3 ~D[2026-09-16]

  # The two day types of the first cases: {A} on Monday and Tuesday, {A,B} on
  # Wednesday. Their keys stand in for `DayTypes.key/1`'s canonical form; the
  # module hashes whatever key it is given, and these cases are about what it
  # writes, not about how a key was derived.
  @weekday_key "weekday-key"
  @wednesday_key "wednesday-key"

  defp garage(garage_id), do: %{garage_id: garage_id, name: garage_id, lat: 42.0, lon: -71.0}

  defp garages do
    %{@garage_uuid => garage("MAIN"), @other_garage_uuid => garage("NORTH")}
  end

  defp trip(id, first_stop_id, last_stop_id, first_departure, last_arrival) do
    %{
      id: id,
      first_stop: %{stop_id: first_stop_id},
      last_stop: %{stop_id: last_stop_id},
      first_departure: first_departure,
      last_arrival: last_arrival
    }
  end

  defp pull(from, to, start_secs, end_secs, drive_secs) do
    %{
      from: from,
      to: to,
      start_secs: start_secs,
      end_secs: end_secs,
      drive_secs: drive_secs,
      source: if(is_nil(drive_secs), do: :unknown, else: :estimated),
      km: nil
    }
  end

  defp gap(from_id, to_id, arrival_secs, departure_secs, kind, drive_secs) do
    %{
      index: 0,
      from_id: from_id,
      to_id: to_id,
      arrival_secs: arrival_secs,
      departure_secs: departure_secs,
      gap_secs: departure_secs - arrival_secs,
      kind: kind,
      drive_secs: drive_secs,
      source: if(kind == :layover, do: nil, else: :estimated),
      wait_secs: if(kind == :layover, do: departure_secs - arrival_secs, else: nil),
      feasible?: true,
      km: nil
    }
  end

  defp movements(overrides) do
    Map.merge(
      %{
        garage_id: @garage_uuid,
        vehicle_type_id: nil,
        pull_out: nil,
        pull_back: nil,
        gaps: [],
        platform_start_secs: nil,
        platform_end_secs: nil,
        service_secs: 0,
        layover_secs: 0,
        drive_secs: 0,
        service_km: 0.0,
        service_km_estimated?: false,
        deadhead_km: 0.0
      },
      Map.new(overrides)
    )
  end

  # One block with a single pull-out, for the identifier cases: what is under
  # test there is the ID, not the movement.
  defp simple_block(block_id) do
    %{
      block_id: block_id,
      trips: [trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600)],
      movements:
        movements(
          pull_out: pull({:garage, @garage_uuid}, {:stop, "S1"}, 5 * 3600, 6 * 3600, 3600)
        )
    }
  end

  # One day type, one block, one movement. `public_ids` may name any subset of the
  # three public ID kinds, defaulting to three that collide with nothing.
  defp one_movement(options) do
    TodsExport.rows(
      input(
        day_types: [day_type(@weekday_key, [@d1])],
        blocks_by_day_type: %{
          @weekday_key => List.wrap(Keyword.get(options, :blocks, simple_block("101")))
        },
        public_ids: %{
          service_ids: Keyword.get(options, :service_ids, []),
          trip_ids: Keyword.get(options, :trip_ids, []),
          route_ids: Keyword.get(options, :route_ids, [])
        }
      )
    )
  end

  defp day_type(key, dates) do
    %{key: key, dates: dates, service_ids: ["A"], label: key, date_count: length(dates)}
  end

  defp input(overrides) do
    Map.merge(
      %{
        day_types: [],
        blocks_by_day_type: %{},
        garages_by_id: garages(),
        public_ids: %{service_ids: ["A", "B"], trip_ids: ["T-1"], route_ids: ["R-1"]}
      },
      Map.new(overrides)
    )
  end

  # R13's service ID, recomputed here from the rule: `ops_dt_` plus `width` hex
  # characters of the SHA-256 of the day-type key.
  defp service_id(key, width \\ 6), do: "ops_dt_" <> hex(key, width)

  defp hex(key, width),
    do:
      key
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, width)

  defp service_dates(rows, service_id) do
    rows
    |> Enum.filter(&(&1.service_id == service_id))
    |> Enum.map(& &1.date)
    |> Enum.sort()
  end

  defp trips_of(rows, kind) do
    Enum.filter(rows, &(&1.tods_trip_type == kind))
  end

  describe "one supplement service per day type (R13)" do
    setup do
      # Block 101 on the weekday day type: out of the garage, one drive, back.
      weekday_block = %{
        block_id: "101",
        trips: [
          trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600),
          trip(@t2_id, "S3", "S4", 8 * 3600, 9 * 3600)
        ],
        movements:
          movements(
            pull_out:
              pull({:garage, @garage_uuid}, {:stop, "S1"}, 5 * 3600 + 30 * 60, 6 * 3600, 30 * 60),
            pull_back:
              pull(
                {:stop, "S4"},
                {:garage, @garage_uuid},
                9 * 3600 + 10 * 60,
                9 * 3600 + 40 * 60,
                30 * 60
              ),
            gaps: [gap(@t1_id, @t2_id, 7 * 3600, 8 * 3600, :drive, 8 * 60)]
          )
      }

      wednesday_block = %{
        block_id: "102",
        trips: [trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600)],
        movements:
          movements(
            pull_out:
              pull(
                {:garage, @other_garage_uuid},
                {:stop, "S1"},
                5 * 3600 + 30 * 60,
                6 * 3600,
                30 * 60
              )
          )
      }

      %{weekday: [weekday_block], wednesday: [wednesday_block]}
    end

    test "two day types get one service each, listing exactly their own dates", %{
      weekday: weekday,
      wednesday: wednesday
    } do
      rows =
        TodsExport.rows(
          input(
            day_types: [
              day_type(@weekday_key, [@d1, @d2]),
              day_type(@wednesday_key, [@d3])
            ],
            blocks_by_day_type: %{@weekday_key => weekday, @wednesday_key => wednesday}
          )
        )

      assert service_dates(rows.calendar_dates, service_id(@weekday_key)) == [@d1, @d2]
      assert service_dates(rows.calendar_dates, service_id(@wednesday_key)) == [@d3]

      # One calendar_dates row per (service, date), exception_type 1 throughout:
      # a day type's own service is an addition, never a removal.
      assert Enum.all?(rows.calendar_dates, &(&1.exception_type == 1))
      assert length(rows.calendar_dates) == 3

      # No service lists a date outside its own day type.
      expected_dates = %{
        service_id(@weekday_key) => [@d1, @d2],
        service_id(@wednesday_key) => [@d3]
      }

      assert Enum.all?(rows.calendar_dates, fn row ->
               Map.fetch!(expected_dates, row.service_id) |> Enum.member?(row.date)
             end)
    end

    test "a block with a pull-out, one drive and a pull-back writes three movements in order", %{
      weekday: [block]
    } do
      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1, @d2])],
            blocks_by_day_type: %{@weekday_key => [block]}
          )
        )

      assert Enum.map(rows.trips, & &1.tods_trip_type) == [:pull_out, :deadhead, :pull_back]
      assert length(rows.stop_times) == 6
      assert length(Enum.uniq(Enum.map(rows.trips, & &1.trip_id))) == 3

      # Every movement has exactly its own two stop times, in sequence.
      for trip <- rows.trips do
        times = Enum.filter(rows.stop_times, &(&1.trip_id == trip.trip_id))
        assert Enum.map(times, & &1.stop_sequence) == [1, 2]
      end

      # The route is the one deadhead route every movement hangs off.
      assert [%{route_id: route_id}] = rows.routes
      assert route_id == "deadheads"
      assert Enum.all?(rows.trips, &(&1.route_id == route_id))

      # No `_prev` service: nothing here starts before midnight.
      refute Enum.any?(rows.calendar_dates, &String.ends_with?(&1.service_id, "_prev"))
    end

    test "garages are written by garage_id and stops by stop_id", %{weekday: [block]} do
      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1])],
            blocks_by_day_type: %{@weekday_key => [block]}
          )
        )

      assert [pull_out, deadhead, pull_back] = rows.trips
      assert [from, to] = Enum.filter(rows.stop_times, &(&1.trip_id == pull_out.trip_id))
      assert from.stop_id == "MAIN"
      assert to.stop_id == "S1"

      assert [from, to] = Enum.filter(rows.stop_times, &(&1.trip_id == deadhead.trip_id))
      assert from.stop_id == "S2"
      assert to.stop_id == "S3"

      assert [from, to] = Enum.filter(rows.stop_times, &(&1.trip_id == pull_back.trip_id))
      assert from.stop_id == "S4"
      assert to.stop_id == "MAIN"
    end

    test "a day type with no blocks writes no service, route or trip at all" do
      rows =
        TodsExport.rows(
          input(day_types: [day_type(@weekday_key, [@d1, @d2])], blocks_by_day_type: %{})
        )

      assert rows == %{calendar_dates: [], routes: [], trips: [], stop_times: [], omitted: 0}
    end
  end

  describe "a movement before midnight moves to the previous service day (R13)" do
    setup do
      # A 00:05 first departure behind a 20-minute pull-out starts at −900 s.
      block = %{
        block_id: "201",
        trips: [trip(@t1_id, "S1", "S2", 300, 3600)],
        movements:
          movements(pull_out: pull({:garage, @garage_uuid}, {:stop, "S1"}, -900, 300, 20 * 60))
      }

      %{block: [block]}
    end

    test "the _prev service lists each date minus one day and the clock is read there", %{
      block: [block]
    } do
      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1, @d2])],
            blocks_by_day_type: %{@weekday_key => [block]}
          )
        )

      prev = service_id(@weekday_key) <> "_prev"

      assert service_dates(rows.calendar_dates, prev) == [
               Date.add(@d1, -1),
               Date.add(@d2, -1)
             ]

      # The own-date service still lists the day type's own dates; the movement
      # is on the previous one, so the date it runs is unambiguous.
      assert service_dates(rows.calendar_dates, service_id(@weekday_key)) == [@d1, @d2]

      assert [trip] = rows.trips
      assert trip.service_id == prev

      assert [from, to] = Enum.filter(rows.stop_times, &(&1.trip_id == trip.trip_id))
      assert from.arrival_time == "23:45:00"
      assert to.arrival_time == "00:05:00"
      assert to.departure_time == "00:05:00"

      # No negative clock string is written anywhere.
      assert Enum.all?(rows.stop_times, &(not String.starts_with?(&1.arrival_time, "-")))
    end

    test "a 25:10 pull-back keeps 25:10:00 on the day's own service" do
      block = %{
        block_id: "202",
        trips: [trip(@t1_id, "S1", "S2", 6 * 3600, 25 * 3600 + 10 * 60)],
        movements:
          movements(
            pull_out: pull({:garage, @garage_uuid}, {:stop, "S1"}, 5 * 3600, 6 * 3600, 3600),
            pull_back:
              pull(
                {:stop, "S2"},
                {:garage, @garage_uuid},
                25 * 3600 + 10 * 60,
                25 * 3600 + 40 * 60,
                30 * 60
              )
          )
      }

      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1])],
            blocks_by_day_type: %{@weekday_key => [block]}
          )
        )

      assert [pull_back] = trips_of(rows.trips, :pull_back)
      assert pull_back.service_id == service_id(@weekday_key)

      assert [from, to] = Enum.filter(rows.stop_times, &(&1.trip_id == pull_back.trip_id))
      assert from.arrival_time == "25:10:00"
      assert to.arrival_time == "25:40:00"

      # The day type has no negative-start movement, so no previous-day service.
      refute Enum.any?(rows.calendar_dates, &String.ends_with?(&1.service_id, "_prev"))
    end
  end

  describe "per-date uniqueness (FH-24)" do
    test "every (movement, date) pair appears once, recomputed from the day types' dates" do
      blocks = [
        %{
          block_id: "101",
          trips: [trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600)],
          movements:
            movements(
              pull_out: pull({:garage, @garage_uuid}, {:stop, "S1"}, 5 * 3600, 6 * 3600, 3600)
            )
        }
      ]

      dates = [@d1, @d2, @d3]

      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, dates)],
            blocks_by_day_type: %{@weekday_key => blocks}
          )
        )

      # The expectation is built from the day type's own dates, not from the rows.
      expected = for _movement <- rows.trips, date <- dates, do: date

      actual =
        for trip <- rows.trips,
            row <- Enum.filter(rows.calendar_dates, &(&1.service_id == trip.service_id)),
            do: row.date

      assert Enum.sort(actual) == Enum.sort(expected)
      assert length(actual) == length(Enum.uniq(actual))
    end
  end

  describe "identifier allocation (R13, PM-8)" do
    test "a public service ID equal to ops_dt_<6 hex> forces the 8-hex form" do
      rows = one_movement(service_ids: [service_id(@weekday_key)])

      assert Enum.map(rows.trips, & &1.service_id) == [service_id(@weekday_key, 8)]
      assert service_dates(rows.calendar_dates, service_id(@weekday_key, 8)) == [@d1]

      # The 6-hex form is the public service's, and the export added nothing on it.
      assert service_dates(rows.calendar_dates, service_id(@weekday_key)) == []
    end

    test "wider digests collide in turn, and _2 is taken only once all four are" do
      for {width, taken} <- [{8, [6]}, {10, [6, 8]}, {12, [6, 8, 10]}] do
        rows = one_movement(service_ids: Enum.map(taken, &service_id(@weekday_key, &1)))

        assert Enum.map(rows.trips, & &1.service_id) == [service_id(@weekday_key, width)]
      end

      rows = one_movement(service_ids: Enum.map([6, 8, 10, 12], &service_id(@weekday_key, &1)))

      assert Enum.map(rows.trips, & &1.service_id) == [service_id(@weekday_key) <> "_2"]
    end

    test "the deadheads route collides with a public route and becomes deadheads_2" do
      rows = one_movement(route_ids: ["deadheads"])

      assert [%{route_id: "deadheads_2"}] = rows.routes
      assert Enum.all?(rows.trips, &(&1.route_id == "deadheads_2"))
    end

    test "a public route ID blocks the service ID it collides with" do
      # All three identifier kinds draw on one used set, so an ID that happens to
      # be a public route is as blocking as one that happens to be a public
      # service: a supplement ID must be new in the feed, not only in its file.
      rows = one_movement(route_ids: [service_id(@weekday_key)])

      assert Enum.map(rows.trips, & &1.service_id) == [service_id(@weekday_key, 8)]
      assert service_dates(rows.calendar_dates, service_id(@weekday_key, 8)) == [@d1]
    end

    test "trip IDs are dh-<block>-<short>-<seq>, per block and free of public IDs" do
      blocks = [
        %{
          block_id: "101",
          trips: [trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600)],
          movements:
            movements(
              pull_out: pull({:garage, @garage_uuid}, {:stop, "S1"}, 5 * 3600, 6 * 3600, 3600),
              pull_back:
                pull({:stop, "S2"}, {:garage, @garage_uuid}, 7 * 3600, 7 * 3600 + 3600, 3600)
            )
        },
        %{
          block_id: "102",
          trips: [trip(@t2_id, "S3", "S4", 6 * 3600, 7 * 3600)],
          movements:
            movements(
              pull_out: pull({:garage, @garage_uuid}, {:stop, "S3"}, 5 * 3600, 6 * 3600, 3600)
            )
        }
      ]

      rows =
        one_movement(
          blocks: blocks,
          trip_ids: ["dh-101-#{hex(@weekday_key, 6)}-1", "dh-101-#{hex(@weekday_key, 6)}-2"]
        )

      assert Enum.map(rows.trips, & &1.trip_id) == [
               "dh-101-#{hex(@weekday_key, 8)}-1",
               "dh-101-#{hex(@weekday_key, 8)}-2",
               "dh-102-#{hex(@weekday_key, 6)}-1"
             ]

      assert length(Enum.uniq(Enum.map(rows.trips, & &1.trip_id))) == 3
    end

    test "an omitted movement leaves no hole in a block's sequence" do
      block = %{
        block_id: "101",
        trips: [trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600)],
        movements:
          movements(
            pull_out: pull({:garage, @garage_uuid}, {:stop, "S1"}, 6 * 3600, 6 * 3600, nil),
            pull_back:
              pull({:stop, "S2"}, {:garage, @garage_uuid}, 7 * 3600, 7 * 3600 + 3600, 3600)
          )
      }

      rows = one_movement(blocks: [block])

      assert rows.omitted == 1
      assert Enum.map(rows.trips, & &1.trip_id) == ["dh-101-#{hex(@weekday_key, 6)}-1"]
    end
  end

  describe "movements a consumer cannot run are omitted and counted" do
    test "an unknown drive is left out and counted in omitted" do
      block = %{
        block_id: "301",
        trips: [
          trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600),
          trip(@t2_id, "S3", "S4", 8 * 3600, 9 * 3600)
        ],
        movements:
          movements(
            pull_out: pull({:garage, @garage_uuid}, {:stop, "S1"}, 5 * 3600, 6 * 3600, 3600),
            pull_back:
              pull({:stop, "S4"}, {:garage, @garage_uuid}, 9 * 3600, 9 * 3600 + 3600, 3600),
            gaps: [
              gap(@t1_id, @t2_id, 7 * 3600, 8 * 3600, :unknown, nil),
              # A layover is not a movement, so it is neither written nor counted.
              gap(@t1_id, @t2_id, 7 * 3600, 8 * 3600, :layover, nil)
            ]
          )
      }

      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1])],
            blocks_by_day_type: %{@weekday_key => [block]}
          )
        )

      assert rows.omitted == 1
      assert Enum.map(rows.trips, & &1.tods_trip_type) == [:pull_out, :pull_back]
      assert length(rows.stop_times) == 4
    end

    test "a day type whose only movement is omitted writes nothing but the count" do
      block = %{
        block_id: "302",
        trips: [trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600)],
        movements:
          movements(
            pull_out: pull({:garage, @garage_uuid}, {:stop, "S1"}, 6 * 3600, 6 * 3600, nil)
          )
      }

      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1])],
            blocks_by_day_type: %{@weekday_key => [block]}
          )
        )

      assert rows.omitted == 1
      assert rows.trips == []
      assert rows.routes == []
      assert rows.calendar_dates == []
    end
  end
end
