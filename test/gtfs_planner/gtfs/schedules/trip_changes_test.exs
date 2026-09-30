defmodule GtfsPlanner.Gtfs.Schedules.TripChangesTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  # Every expected value below is literal and hand-derived from R1, R3 and the
  # §4.4 contract in spec.md. Nothing here computes an expectation with the
  # module under test.

  @trip_a "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @trip_b "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @trip_c "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @peak_id "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  @trip_a_upper "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"

  @window %{start_secs: 21_600, end_secs: 25_200, headway_secs: 600}

  @empty_change_set %{updates: [], inserts: [], deletes: [], consequences: []}

  # Cedar Library 07:00, 07:10, 07:20 as a timing's relative rows and as the
  # materialized stop rows a linked trip would store.
  @occurrences [
    %{stop_id: "stop-1", position: 1},
    %{stop_id: "stop-2", position: 2},
    %{stop_id: "stop-3", position: 3}
  ]

  @cedar_rows [
    %{
      arrival_offset: 0,
      departure_offset: 0,
      timepoint: 1,
      pickup_type: 0,
      drop_off_type: 0,
      stop_headsign: nil
    },
    %{
      arrival_offset: 600,
      departure_offset: 600,
      timepoint: 0,
      pickup_type: 0,
      drop_off_type: 0,
      stop_headsign: nil
    },
    %{
      arrival_offset: 1_200,
      departure_offset: 1_200,
      timepoint: 0,
      pickup_type: 0,
      drop_off_type: 0,
      stop_headsign: nil
    }
  ]

  @cedar_match [
    %{
      arrival_time: "07:00:00",
      departure_time: "07:00:00",
      timepoint: 1,
      pickup_type: 0,
      drop_off_type: 0,
      stop_headsign: nil
    },
    %{
      arrival_time: "07:10:00",
      departure_time: "07:10:00",
      timepoint: 0,
      pickup_type: 0,
      drop_off_type: 0,
      stop_headsign: nil
    },
    %{
      arrival_time: "07:20:00",
      departure_time: "07:20:00",
      timepoint: 0,
      pickup_type: 0,
      drop_off_type: 0,
      stop_headsign: nil
    }
  ]

  describe "validate/1" do
    test "refuses an empty selection" do
      assert TripChanges.validate({:shift, [], 300, nil}) == {:error, :invalid_command}
      assert TripChanges.validate({:set_timing, [], @trip_c}) == {:error, :invalid_command}
    end

    test "refuses more than 500 distinct trips" do
      ids = Enum.map(1..501, &uuid/1)

      assert TripChanges.validate({:shift, ids, 300, nil}) == {:error, :too_many_trips}
    end

    test "accepts 500 distinct trips and deduplicates before counting" do
      ids = Enum.map(1..500, &uuid/1)

      assert {:ok, {:shift, validated, 300, nil}} =
               TripChanges.validate({:shift, ids, 300, nil})

      assert length(validated) == 500

      duplicated = [uuid(1) | ids]

      assert {:ok, {:shift, deduplicated, 300, nil}} =
               TripChanges.validate({:shift, duplicated, 300, nil})

      assert length(deduplicated) == 500
    end

    test "casts UUIDs and returns a deduplicated sorted id list" do
      assert TripChanges.validate({:shift, [@trip_b, @trip_a_upper, @trip_a], 300, nil}) ==
               {:ok, {:shift, [@trip_a, @trip_b], 300, nil}}
    end

    test "refuses a shift delta that is not a nonzero whole minute within 24 hours" do
      for delta <- [30, 0, 90, 86_460, 1.5] do
        assert TripChanges.validate({:shift, [@trip_a], delta, nil}) ==
                 {:error, :invalid_command},
               "expected #{inspect(delta)} to be refused"
      end

      assert TripChanges.validate({:shift, [@trip_a], 300, nil}) ==
               {:ok, {:shift, [@trip_a], 300, nil}}

      assert TripChanges.validate({:shift, [@trip_a], -300, nil}) ==
               {:ok, {:shift, [@trip_a], -300, nil}}

      assert TripChanges.validate({:shift, [@trip_a], 86_400, nil}) ==
               {:ok, {:shift, [@trip_a], 86_400, nil}}
    end

    test "refuses an unknown stop-edit mode and other malformed stop edits" do
      base = %{position: 2, value: 26_880, mode: :later, shown_positions: :all}

      assert TripChanges.validate({:edit_stop, @trip_a, %{base | mode: :sideways}}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:edit_stop, @trip_a, %{base | position: 0}}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:edit_stop, @trip_a, %{base | value: -1}}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:edit_stop, @trip_a, %{base | shown_positions: [1, 0]}}) ==
               {:error, :invalid_command}
    end

    test "accepts a clear and a timepoints view" do
      assert TripChanges.validate(
               {:edit_stop, @trip_a,
                %{position: 3, value: :clear, mode: :only, shown_positions: [1, 3]}}
             ) ==
               {:ok,
                {:edit_stop, @trip_a,
                 %{position: 3, value: :clear, mode: :only, shown_positions: [1, 3]}}}
    end

    test "accepts set-timing, calendar, copy and frequency commands" do
      assert TripChanges.validate({:set_timing, [@trip_b, @trip_a], @trip_c}) ==
               {:ok, {:set_timing, [@trip_a, @trip_b], @trip_c}}

      assert TripChanges.validate({:move_calendar, [@trip_a], "SAT"}) ==
               {:ok, {:move_calendar, [@trip_a], "SAT"}}

      assert TripChanges.validate({:copy, [@trip_a], "SAT", 0, true}) ==
               {:ok, {:copy, [@trip_a], "SAT", 0, true}}

      assert TripChanges.validate(
               {:add_frequency,
                %{
                  pattern_id: @trip_a_upper,
                  timed_pattern_id: @trip_b,
                  service_id: "SAT",
                  windows: [@window],
                  exact_times: 1
                }}
             ) ==
               {:ok,
                {:add_frequency,
                 %{
                   pattern_id: @trip_a,
                   timed_pattern_id: @trip_b,
                   service_id: "SAT",
                   windows: [@window],
                   exact_times: 1
                 }}}

      assert TripChanges.validate(
               {:update_frequency, @trip_a, %{windows: [@window], exact_times: :keep}}
             ) ==
               {:ok, {:update_frequency, @trip_a, %{windows: [@window], exact_times: :keep}}}

      assert TripChanges.validate({:convert_frequency, @trip_a}) ==
               {:ok, {:convert_frequency, @trip_a}}
    end

    test "refuses malformed windows and exact_times choices" do
      assert TripChanges.validate(
               {:add_frequency,
                %{
                  pattern_id: @trip_a,
                  timed_pattern_id: @trip_b,
                  service_id: "SAT",
                  windows: [%{start_secs: 21_600, end_secs: 25_200, headway_secs: 0}],
                  exact_times: 1
                }}
             ) == {:error, :invalid_command}

      assert TripChanges.validate(
               {:add_frequency,
                %{
                  pattern_id: @trip_a,
                  timed_pattern_id: @trip_b,
                  service_id: "SAT",
                  windows: [@window],
                  exact_times: 2
                }}
             ) == {:error, :invalid_command}

      assert TripChanges.validate(
               {:update_frequency, @trip_a, %{windows: :all, exact_times: :keep}}
             ) == {:error, :invalid_command}

      assert TripChanges.validate(
               {:update_frequency, @trip_a, %{windows: [@window], exact_times: nil}}
             ) == {:error, :invalid_command}
    end

    test "refuses a copy offset that is not a whole minute within 24 hours" do
      assert TripChanges.validate({:copy, [@trip_a], "SAT", 30, true}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:copy, [@trip_a], "SAT", 0, :yes}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:copy, [@trip_a], "", 0, true}) ==
               {:error, :invalid_command}
    end

    test "refuses invalid UUIDs, unknown tags and malformed input" do
      assert TripChanges.validate({:shift, ["not-a-uuid"], 300, nil}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:shift, :all, 300, nil}) == {:error, :invalid_command}

      assert TripChanges.validate({:convert_frequency, "not-a-uuid"}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:unknown, [@trip_a]}) == {:error, :invalid_command}
      assert TripChanges.validate(:shift) == {:error, :invalid_command}
      assert TripChanges.validate({:shift, [@trip_a], 300, 0}) == {:error, :invalid_command}
    end

    test "accepts a shaped restore payload and refuses a malformed one" do
      payload = %{
        operation_id: @trip_a,
        organization_id: @trip_b,
        gtfs_version_id: @trip_c,
        route_id: "12",
        trips: [
          %{id: @trip_a, written_updated_at: ~U[2026-06-01 10:00:00.000000Z], fields: %{}}
        ],
        created: []
      }

      assert {:ok, {:restore, ^payload}} = TripChanges.validate({:restore, payload})

      assert TripChanges.validate({:restore, %{payload | route_id: 12}}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:restore, %{payload | trips: :all}}) ==
               {:error, :invalid_command}

      assert TripChanges.validate({:restore, %{}}) == {:error, :invalid_command}
    end
  end

  describe "plan/2" do
    test "returns :invalid_command until a planner owns the tag" do
      # :shift is planned since step 9; these tags still fall through to the dispatch
      # fallback until their planner steps (12–18) add a clause above it.
      assert TripChanges.plan({:set_timing, [@trip_a], @trip_c}, %{}) ==
               {:error, :invalid_command}

      assert TripChanges.plan({:convert_frequency, @trip_a}, %{}) ==
               {:error, :invalid_command}
    end
  end

  describe "fingerprint/3" do
    test "is equal when the same command has its ids reordered" do
      state = fingerprint_state()

      first =
        TripChanges.fingerprint({:shift, [@trip_a, @trip_b], 300, nil}, state, @empty_change_set)

      second =
        TripChanges.fingerprint({:shift, [@trip_b, @trip_a], 300, nil}, state, @empty_change_set)

      assert first == second
    end

    test "changes when one trip's updated_at changes" do
      command = {:shift, [@trip_a, @trip_b], 300, nil}
      state = fingerprint_state()

      moved =
        put_in(state, [:trips, @trip_b, :trip, :updated_at], ~U[2026-06-01 10:00:01.000000Z])

      refute TripChanges.fingerprint(command, state, @empty_change_set) ==
               TripChanges.fingerprint(command, moved, @empty_change_set)
    end

    test "changes when one stop clock changes" do
      command = {:shift, [@trip_a, @trip_b], 300, nil}
      state = fingerprint_state()

      moved =
        put_in(
          state,
          [:trips, @trip_b, :stop_times, Access.at(1), :departure_time],
          "07:32:00"
        )

      refute TripChanges.fingerprint(command, state, @empty_change_set) ==
               TripChanges.fingerprint(command, moved, @empty_change_set)
    end

    test "changes when the change adds a block finding" do
      command = {:shift, [@trip_a, @trip_b], 300, nil}
      state = fingerprint_state()

      finding = %{code: :short_layover, trip_ids: [@trip_b, @trip_a], transfer_id: nil}

      with_finding = %{
        @empty_change_set
        | consequences: [{:warning, {:block_findings, [finding]}}]
      }

      refute TripChanges.fingerprint(command, state, @empty_change_set) ==
               TripChanges.fingerprint(command, state, with_finding)
    end

    test "is unchanged when the same finding is listed twice in a different order" do
      command = {:shift, [@trip_a, @trip_b], 300, nil}
      state = fingerprint_state()
      finding = %{code: :short_layover, trip_ids: [@trip_a, @trip_b], transfer_id: nil}

      once = %{
        @empty_change_set
        | consequences: [{:warning, {:block_findings, [finding]}}]
      }

      twice = %{
        @empty_change_set
        | consequences: [
            {:note, {:crosses_midnight, [@trip_a]}},
            {:warning, {:block_findings, [finding, finding]}}
          ]
      }

      assert TripChanges.fingerprint(command, state, once) ==
               TripChanges.fingerprint(command, state, twice)
    end

    test "changes when a different delta targets the same trips" do
      state = fingerprint_state()

      refute TripChanges.fingerprint({:shift, [@trip_a], 300, nil}, state, @empty_change_set) ==
               TripChanges.fingerprint({:shift, [@trip_a], 360, nil}, state, @empty_change_set)
    end
  end

  describe "relink/3" do
    test "links an exact timing match" do
      assert TripChanges.relink(@cedar_match, @occurrences, [
               timing(@trip_a, "Cedar", @cedar_rows)
             ]) == {:linked, @trip_a}
    end

    test "stays custom when equal clocks carry a different pickup type" do
      [first, second, third] = @cedar_match
      rows = [first, %{second | pickup_type: 1}, third]

      assert TripChanges.relink(rows, @occurrences, [
               timing(@trip_a, "Cedar", @cedar_rows)
             ]) == :custom
    end

    test "stays custom on a differing drop-off type, headsign or timepoint" do
      [first, second, third] = @cedar_match

      assert TripChanges.relink([first, %{second | drop_off_type: 1}, third], @occurrences, [
               timing(@trip_a, "Cedar", @cedar_rows)
             ]) == :custom

      assert TripChanges.relink(
               [first, %{second | stop_headsign: "Downtown"}, third],
               @occurrences,
               [timing(@trip_a, "Cedar", @cedar_rows)]
             ) == :custom

      assert TripChanges.relink([first, %{second | timepoint: nil}, third], @occurrences, [
               timing(@trip_a, "Cedar", @cedar_rows)
             ]) == :custom
    end

    test "considers timings in name order and links the first equal one" do
      assert TripChanges.relink(@cedar_match, @occurrences, [
               timing(@peak_id, "Peak", @cedar_rows),
               timing(@trip_a, "Cedar", @cedar_rows)
             ]) == {:linked, @trip_a}
    end

    test "stays custom when no timing matches or the rows are malformed" do
      different = [
        %{
          arrival_time: "07:00:00",
          departure_time: "07:00:00",
          timepoint: 1,
          pickup_type: 0,
          drop_off_type: 0,
          stop_headsign: nil
        },
        %{
          arrival_time: "07:10:00",
          departure_time: "07:10:00",
          timepoint: 0,
          pickup_type: 0,
          drop_off_type: 0,
          stop_headsign: nil
        },
        %{
          arrival_time: "07:25:00",
          departure_time: "07:25:00",
          timepoint: 0,
          pickup_type: 0,
          drop_off_type: 0,
          stop_headsign: nil
        }
      ]

      assert TripChanges.relink(different, @occurrences, [
               timing(@trip_a, "Cedar", @cedar_rows)
             ]) == :custom

      assert TripChanges.relink([], @occurrences, [timing(@trip_a, "Cedar", @cedar_rows)]) ==
               :custom

      assert TripChanges.relink(Enum.take(@cedar_match, 2), @occurrences, [
               timing(@trip_a, "Cedar", @cedar_rows)
             ]) == :custom

      assert TripChanges.relink(@cedar_match, @occurrences, []) == :custom
    end
  end

  describe "allocate_trip_ids/5" do
    test "uses the service and start stamp for a free ID" do
      assert TripChanges.allocate_trip_ids("12", 0, "SAT", [61_200], []) ==
               ["12-0-SAT-1700"]
    end

    test "takes the smallest free suffix at or above 2 when the base is taken" do
      assert TripChanges.allocate_trip_ids("12", 0, "SAT", [61_200], ["12-0-SAT-1700"]) ==
               ["12-0-SAT-1700-2"]

      assert TripChanges.allocate_trip_ids(
               "12",
               0,
               "SAT",
               [61_200],
               ["12-0-SAT-1700", "12-0-SAT-1700-2"]
             ) == ["12-0-SAT-1700-3"]
    end

    test "reserves IDs across the batch so two departures never share one" do
      assert TripChanges.allocate_trip_ids("12", 0, "SAT", [61_200, 61_200], []) ==
               ["12-0-SAT-1700", "12-0-SAT-1700-2"]

      assert TripChanges.allocate_trip_ids("12", 0, "SAT", [61_200, 63_000], []) ==
               ["12-0-SAT-1700", "12-0-SAT-1730"]
    end

    test "stamps unwrapped hours past midnight" do
      assert TripChanges.allocate_trip_ids("12", 0, "SAT", [90_600], []) ==
               ["12-0-SAT-2510"]
    end
  end

  defp uuid(index) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")
  end

  defp timing(id, name, rows), do: %{timing: %{id: id, name: name}, rows: rows}

  defp fingerprint_state do
    %{
      trips: %{
        @trip_a => trip_state(@trip_a, "07:00:00"),
        @trip_b => trip_state(@trip_b, "07:30:00")
      }
    }
  end

  defp trip_state(trip_id, departure_time) do
    %{
      trip: %{
        id: trip_id,
        updated_at: ~U[2026-06-01 10:00:00.000000Z],
        service_id: "WKD",
        timed_pattern_id: nil,
        pattern_derivation_state: "custom",
        block_id: nil
      },
      stop_times: [
        %{
          id: "#{trip_id}-1",
          stop_sequence: 1,
          arrival_time: departure_time,
          departure_time: departure_time
        },
        %{
          id: "#{trip_id}-2",
          stop_sequence: 2,
          arrival_time: "07:31:00",
          departure_time: "07:31:00"
        }
      ],
      frequencies: []
    }
  end
end
