defmodule GtfsPlanner.Gtfs.Blocking.TodsExportRunsTest do
  @moduledoc """
  The identifiers a run needs to refer back to what the supplement export wrote.

  A day type carrying runs needs two things the movement-only export could not
  give it: a `service_id` even when it has no deadhead, and a mapping from each of
  its movements to the trip that movement was written as.

  The module under test is pure, so these cases run in the local ExUnit process
  with no sandbox, fixtures or cleanup. Movements are handed over as the literal
  `Movements.t()` maps a day load produces — derived and never stored.

  The service IDs are recomputed here from the export's naming rule with
  `:crypto`, as in `tods_export_test.exs`, rather than read back from the result:
  a case that read `ids.service_ids` to build its expectation would pass whatever
  the module returned.

  Run with:
  `mix test test/gtfs_planner/gtfs/blocking/tods_export_runs_test.exs
  test/gtfs_planner/gtfs/blocking/tods_export_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.TodsExport

  @garage_uuid "0f2b3a4c-5d6e-4f70-8a91-b2c3d4e5f607"
  @t1_id "2c3d4e5f-6071-4a82-93a4-b5c6d7e8f901"
  @t2_id "3d4e5f60-7182-4a93-84b5-c6d7e8f90112"

  @d1 ~D[2026-09-14]
  @d2 ~D[2026-09-15]

  @weekday_key "weekday-key"

  defp garage(garage_id),
    do: %{garage_id: garage_id, name: garage_id, lat: 42.0, lon: -71.0}

  defp garages, do: %{@garage_uuid => garage("MAIN")}

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

  # The gap's own `index` is a parameter here, where `tods_export_test.exs`'s
  # helper fixes it at 0: two drives in one block are only distinguishable by
  # their index, and that is exactly what `{:gap, index}` is built from.
  defp gap(from_id, to_id, arrival_secs, departure_secs, kind, drive_secs, index) do
    %{
      index: index,
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

  # One block: out of the garage, two drives, back. Two drives rather than one so
  # the `{:gap, index}` keys are distinguishable from each other.
  defp two_gap_block(block_id) do
    %{
      block_id: block_id,
      trips: [
        trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600),
        trip(@t2_id, "S3", "S4", 9 * 3600, 10 * 3600)
      ],
      movements:
        movements(
          pull_out:
            pull({:garage, @garage_uuid}, {:stop, "S1"}, 5 * 3600 + 30 * 60, 6 * 3600, 30 * 60),
          pull_back:
            pull(
              {:stop, "S4"},
              {:garage, @garage_uuid},
              10 * 3600 + 10 * 60,
              10 * 3600 + 40 * 60,
              30 * 60
            ),
          gaps: [
            gap(@t1_id, @t2_id, 7 * 3600, 8 * 3600, :drive, 20 * 60, 0),
            gap(@t2_id, @t1_id, 10 * 3600 + 10 * 60, 11 * 3600, :drive, 20 * 60, 1)
          ]
        )
    }
  end

  defp day_type(key, dates) do
    %{key: key, dates: dates, service_ids: ["A"], label: key, date_count: length(dates)}
  end

  defp input(overrides) do
    Map.merge(
      %{
        day_types: [],
        blocks_by_day_type: %{},
        run_day_types: %{},
        garages_by_id: garages(),
        public_ids: %{service_ids: ["A", "B"], trip_ids: ["T-1"], route_ids: ["R-1"]}
      },
      Map.new(overrides)
    )
  end

  # The day type's service ID, recomputed from the rule rather than read from the
  # result.
  defp service_id(key, width \\ 6), do: "ops_dt_" <> hex(key, width)

  defp hex(key, width),
    do:
      key
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, width)

  defp dates_of(rows, id) do
    rows
    |> Enum.filter(&(&1.service_id == id))
    |> Enum.map(& &1.date)
    |> Enum.sort()
  end

  describe "a day type with runs but no movement" do
    setup do
      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1, @d2])],
            blocks_by_day_type: %{@weekday_key => []},
            run_day_types: %{@weekday_key => %{}}
          )
        )

      %{rows: rows, expected_service: service_id(@weekday_key)}
    end

    test "still gets a service and its calendar dates", %{rows: rows, expected_service: s} do
      # The run hangs on a service. A day type with runs and no deadhead has
      # nothing to write in the movement files, but the run events still need
      # somewhere to hang, and the service is that somewhere.
      assert rows.ids.service_ids[@weekday_key].service_id == s
      assert dates_of(rows.calendar_dates, s) == [@d1, @d2]
    end

    test "writes no routes row, because no movement trip exists", %{rows: rows} do
      # The deadhead route exists only to carry movements. With no trip on it, a
      # route row is a row no consumer can act on — the same rule that drops a
      # service with no movement.
      assert rows.routes == []
      assert rows.trips == []
      assert rows.ids.movement_trip_ids == %{}
    end

    test "omits nothing, because nothing was left out", %{rows: rows} do
      assert rows.omitted == 0
    end
  end

  describe "run_day_types with no entry" do
    test "a day type with no movement and no runs is still dropped entirely" do
      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1, @d2])],
            blocks_by_day_type: %{@weekday_key => []},
            run_day_types: %{}
          )
        )

      # Unchanged from the movement-only export: with no runs there is nothing to
      # refer back to, so no empty service is minted for it.
      assert rows == %{calendar_dates: [], routes: [], trips: [], stop_times: [], omitted: 0}
    end
  end

  describe "prev? reserves the previous-day service" do
    setup do
      # No leg starts before midnight here, so the only reason to reserve `_prev`
      # is that a run reaches before it.
      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1, @d2])],
            blocks_by_day_type: %{@weekday_key => [two_gap_block("101")]},
            run_day_types: %{@weekday_key => %{prev?: true}}
          )
        )

      %{rows: rows, service: service_id(@weekday_key), prev: service_id(@weekday_key) <> "_prev"}
    end

    test "the _prev service and its shifted dates exist without a pre-midnight movement",
         %{rows: rows, service: service, prev: prev} do
      assert dates_of(rows.calendar_dates, prev) == [Date.add(@d1, -1), Date.add(@d2, -1)]
      assert dates_of(rows.calendar_dates, service) == [@d1, @d2]

      # Without a pre-midnight movement, no trip is written on the previous
      # service: the reservation is for the run, not for a movement.
      assert Enum.all?(rows.trips, &(&1.service_id == service))
    end

    test "the reservation is not made when prev? is false or absent" do
      for run_day_type <- [%{}, %{prev?: false}] do
        rows =
          TodsExport.rows(
            input(
              day_types: [day_type(@weekday_key, [@d1])],
              blocks_by_day_type: %{@weekday_key => [two_gap_block("101")]},
              run_day_types: %{@weekday_key => run_day_type}
            )
          )

        prev = service_id(@weekday_key) <> "_prev"
        refute Enum.any?(rows.calendar_dates, &(&1.service_id == prev))
      end
    end
  end

  describe "ids.movement_trip_ids" do
    setup do
      block = two_gap_block("101")

      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1, @d2])],
            blocks_by_day_type: %{@weekday_key => [block]},
            run_day_types: %{@weekday_key => %{}}
          )
        )

      %{rows: rows}
    end

    test "maps each leg key to the trip_id actually written for it", %{rows: rows} do
      movement_trip_ids = rows.ids.movement_trip_ids

      for leg_key <- [
            {@weekday_key, "101", :pull_out},
            {@weekday_key, "101", :pull_back},
            {@weekday_key, "101", {:gap, 0}},
            {@weekday_key, "101", {:gap, 1}}
          ] do
        assert Map.has_key?(movement_trip_ids, leg_key),
               "expected an entry for #{inspect(leg_key)}, got #{inspect(Map.keys(movement_trip_ids))}"
      end

      # Every mapped ID is a trip that was really written, and each trip is
      # mapped exactly once — an entry naming a trip nobody can find would be
      # worse than no entry.
      written = MapSet.new(rows.trips, & &1.trip_id)
      assert MapSet.new(Map.values(movement_trip_ids)) == written
      assert map_size(movement_trip_ids) == length(rows.trips)
    end

    test "the two drives are distinct entries, not one", %{rows: rows} do
      first = rows.ids.movement_trip_ids[{@weekday_key, "101", {:gap, 0}}]
      second = rows.ids.movement_trip_ids[{@weekday_key, "101", {:gap, 1}}]

      # The point of carrying `gap.index`: two drives between the same pair of
      # stop sequences are still two movements.
      refute first == second
    end

    test "service_ids matches the service_id on that day type's calendar rows", %{rows: rows} do
      service = rows.ids.service_ids[@weekday_key].service_id

      assert service == service_id(@weekday_key)
      assert dates_of(rows.calendar_dates, service) == [@d1, @d2]
    end
  end

  describe "a movement that cannot be written" do
    test "an unknown drive has no entry in movement_trip_ids" do
      block = %{
        block_id: "101",
        trips: [trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600)],
        movements: movements(gaps: [gap(@t1_id, @t2_id, 7 * 3600, 8 * 3600, :unknown, nil, 0)])
      }

      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1])],
            blocks_by_day_type: %{@weekday_key => [block]},
            run_day_types: %{@weekday_key => %{}}
          )
        )

      # The unknown drive names no endpoint and no time, so no trip is written
      # for it. It has no trip, so it has no ID either: an entry pointing at a
      # trip that is not in the file would send a consumer looking for a row
      # that does not exist.
      assert rows.omitted == 1
      assert rows.trips == []
      refute Map.has_key?(rows.ids.movement_trip_ids, {@weekday_key, "101", {:gap, 0}})
      assert rows.ids.movement_trip_ids == %{}
    end

    test "a known drive alongside an unknown one is still mapped" do
      block = %{
        block_id: "101",
        trips: [
          trip(@t1_id, "S1", "S2", 6 * 3600, 7 * 3600),
          trip(@t2_id, "S3", "S4", 9 * 3600, 10 * 3600)
        ],
        movements:
          movements(
            gaps: [
              gap(@t1_id, @t2_id, 7 * 3600, 8 * 3600, :unknown, nil, 0),
              gap(@t2_id, @t1_id, 10 * 3600, 8 * 3600 + 2 * 3600, :drive, 20 * 60, 1)
            ]
          )
      }

      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1])],
            blocks_by_day_type: %{@weekday_key => [block]},
            run_day_types: %{@weekday_key => %{}}
          )
        )

      assert rows.omitted == 1

      # The unknown gap's index is not reused by the known one, and the known
      # one is addressable at its own index.
      assert Map.has_key?(rows.ids.movement_trip_ids, {@weekday_key, "101", {:gap, 1}})
      refute Map.has_key?(rows.ids.movement_trip_ids, {@weekday_key, "101", {:gap, 0}})
    end
  end

  describe "two day types carrying runs" do
    test "each gets its own service and the ids do not collide" do
      other_key = "wednesday-key"
      other_block = Map.put(two_gap_block("102"), :block_id, "102")

      rows =
        TodsExport.rows(
          input(
            day_types: [day_type(@weekday_key, [@d1]), day_type(other_key, [@d2])],
            blocks_by_day_type: %{@weekday_key => [], other_key => [other_block]},
            run_day_types: %{@weekday_key => %{}, other_key => %{}}
          )
        )

      assert rows.ids.service_ids[@weekday_key].service_id == service_id(@weekday_key)
      assert rows.ids.service_ids[other_key].service_id == service_id(other_key)

      refute rows.ids.service_ids[@weekday_key].service_id ==
               rows.ids.service_ids[other_key].service_id

      # The movement is keyed by its own day type, so the same block id on two
      # day types does not collide.
      assert Map.has_key?(rows.ids.movement_trip_ids, {other_key, "102", :pull_out})
      refute Map.has_key?(rows.ids.movement_trip_ids, {@weekday_key, "102", :pull_out})
    end
  end

  describe "without run_day_types" do
    test "the output is the movement-only export's, plus the ids" do
      block = two_gap_block("101")

      rows =
        TodsExport.rows(%{
          day_types: [day_type(@weekday_key, [@d1])],
          blocks_by_day_type: %{@weekday_key => [block]},
          garages_by_id: garages(),
          public_ids: %{service_ids: ["A"], trip_ids: [], route_ids: []}
        })

      # No `run_day_types` key at all: the default is `%{}` and the day type is
      # kept because it has movements, not because it carries runs. Every
      # movement file is exactly what the movement-only export wrote.
      assert Enum.map(rows.trips, & &1.tods_trip_type) ==
               [:pull_out, :deadhead, :deadhead, :pull_back]

      assert length(rows.stop_times) == 8
      assert length(rows.routes) == 1
      assert dates_of(rows.calendar_dates, service_id(@weekday_key)) == [@d1]
    end
  end
end
