defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.ShiftTest do
  @moduledoc """
  Merge evidence (EV-8) for the R4 Shift planner:

  - A linked trip shifted as a whole keeps its timing linkage: its update carries the
    timing's clocks at the new first departure and no linkage fields, so it never becomes
    custom (FH-17).
  - A shift whose result starts below 00:00 is refused with an `{:error, :negative_time}`
    consequence and writes no update (FH-18).
  - No update ever carries `block_id`, including a blocked trip whose moved endpoints add
    a block finding: a shift keeps blocks (FH-19).
  - A shift from a timepoint moves that occurrence and every later one; the result relinks
    to the first matching timing or becomes custom with reason `edited_in_schedules`.
  - Frequency trips move their windows and template; a timepoint shift excludes them whole.
  - Consequences list the trips that now start after 24:00, a listed trip already leaving
    at the shifted first departure, the block findings the move adds and the windows moved.

  Every expected value below is literal and hand-derived from R1, R4 and the §4.4 contract
  in spec.md; nothing computes an expectation with the module under test. The planner is
  pure, so the states are hand-built maps and no sandbox or fixture is involved.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/schedules/trip_changes/shift_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules.TripChanges
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip

  @trip_a "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @trip_b "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @trip_c "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @trip_d "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  @pattern_id "99999999-9999-4999-8999-999999999999"
  @base_timing "11111111-1111-4111-8111-111111111111"
  @peak_timing "22222222-2222-4222-8222-222222222222"
  @wkdy [~D[2026-03-02], ~D[2026-03-03], ~D[2026-03-04]]
  @sat [~D[2026-03-07]]
  @base_offsets [0, 600, 1200]
  @hour_offsets [0, 1_800, 3_600]

  describe "a whole-trip shift of a linked trip" do
    test "moves the timing's clocks and writes no linkage fields (FH-17)" do
      state = state([linked(@trip_a, at(7, 0))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert [update] = change_set.updates
      assert update.trip_id == @trip_a
      assert update.fields == %{}
      assert update.frequencies == :unchanged

      assert update.stop_times == [
               %{
                 position: 1,
                 arrival_time: "07:05:00",
                 departure_time: "07:05:00",
                 timepoint: 1,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               },
               %{
                 position: 2,
                 arrival_time: "07:15:00",
                 departure_time: "07:15:00",
                 timepoint: 0,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               },
               %{
                 position: 3,
                 arrival_time: "07:25:00",
                 departure_time: "07:25:00",
                 timepoint: 0,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               }
             ]

      assert change_set.inserts == []
      assert change_set.deletes == []
      assert change_set.consequences == []
    end

    test "keeps a blocked trip's block (FH-19)" do
      state =
        state([linked(@trip_a, at(8, 0), block_id: "103", offsets: @hour_offsets)],
          block_inputs:
            block_inputs([
              trip_row(@trip_a, at(8, 0), at(9, 0), block_id: "103"),
              trip_row(@trip_b, at(9, 10), at(10, 0), block_id: "103")
            ])
        )

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert [update] = change_set.updates
      refute Map.has_key?(update.fields, :block_id)
      assert update.fields == %{}
      assert change_set.consequences == []
    end

    test "refuses a result below 00:00 and writes no update (FH-18)" do
      state = state([linked(@trip_a, at(0, 5))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], -600, nil}, state)

      assert change_set.updates == []
      assert change_set.consequences == [{:error, :negative_time}]
    end

    test "allows a shift that lands exactly on 00:00" do
      state = state([linked(@trip_a, at(0, 5))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], -300, nil}, state)

      assert [update] = change_set.updates

      assert update.stop_times ==
               values([
                 {"00:00:00", "00:00:00"},
                 {"00:10:00", "00:10:00"},
                 {"00:20:00", "00:20:00"}
               ])

      assert change_set.consequences == []
    end

    test "relinks a custom trip when the moved times equal a timing" do
      state = state([custom(@trip_a, at(6, 55))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert [update] = change_set.updates

      assert update.stop_times ==
               values([
                 {"07:00:00", "07:00:00"},
                 {"07:10:00", "07:10:00"},
                 {"07:20:00", "07:20:00"}
               ])

      assert update.fields == %{
               timed_pattern_id: @base_timing,
               pattern_derivation_state: "linked",
               pattern_derivation_reason: nil
             }

      assert change_set.consequences == []
    end

    test "keeps a custom trip custom when no pattern timing matches" do
      state = state([custom(@trip_a, at(7, 0))], patterns: patterns([peak_timing()]))

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert [update] = change_set.updates

      assert update.fields == %{
               timed_pattern_id: nil,
               pattern_derivation_state: "custom",
               pattern_derivation_reason: "edited_in_schedules"
             }

      assert change_set.consequences == []
    end

    test "leaves a cleared intermediate stop empty" do
      state =
        state([custom(@trip_a, at(7, 0), offsets: [0, :clear, 1_200])], patterns: patterns([]))

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert [update] = change_set.updates

      assert update.stop_times == [
               %{
                 position: 1,
                 arrival_time: "07:05:00",
                 departure_time: "07:05:00",
                 timepoint: 1,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               },
               %{
                 position: 2,
                 arrival_time: nil,
                 departure_time: nil,
                 timepoint: 0,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               },
               %{
                 position: 3,
                 arrival_time: "07:25:00",
                 departure_time: "07:25:00",
                 timepoint: 0,
                 pickup_type: 0,
                 drop_off_type: 0,
                 stop_headsign: nil
               }
             ]
    end
  end

  describe "a shift from a timepoint" do
    test "moves the chosen stop and every later one and makes a linked trip custom" do
      state = state([linked(@trip_a, at(7, 0))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, 2}, state)

      assert [update] = change_set.updates

      assert update.stop_times ==
               values([
                 {"07:00:00", "07:00:00"},
                 {"07:15:00", "07:15:00"},
                 {"07:25:00", "07:25:00"}
               ])

      assert update.fields == %{
               timed_pattern_id: nil,
               pattern_derivation_state: "custom",
               pattern_derivation_reason: "edited_in_schedules"
             }

      assert change_set.consequences == [{:note, {:becomes_custom, [@trip_a]}}]
    end

    test "relinks when the result equals a pattern timing" do
      state =
        state([linked(@trip_a, at(7, 0))], patterns: patterns([base_timing(), peak_timing()]))

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, 2}, state)

      assert [update] = change_set.updates

      assert update.stop_times ==
               values([
                 {"07:00:00", "07:00:00"},
                 {"07:15:00", "07:15:00"},
                 {"07:25:00", "07:25:00"}
               ])

      assert update.fields == %{
               timed_pattern_id: @peak_timing,
               pattern_derivation_state: "linked",
               pattern_derivation_reason: nil
             }

      assert change_set.consequences == []
    end

    test "leaves earlier clocks alone and keeps an already-custom trip custom" do
      state = state([custom(@trip_a, at(7, 0))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, 2}, state)

      assert [update] = change_set.updates

      assert update.stop_times ==
               values([
                 {"07:00:00", "07:00:00"},
                 {"07:15:00", "07:15:00"},
                 {"07:25:00", "07:25:00"}
               ])

      assert update.fields == %{
               timed_pattern_id: nil,
               pattern_derivation_state: "custom",
               pattern_derivation_reason: "edited_in_schedules"
             }

      assert change_set.consequences == []
    end

    test "moves only the last stop when the shift starts there" do
      state = state([custom(@trip_a, at(7, 0))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, 3}, state)

      assert [update] = change_set.updates

      assert update.stop_times ==
               values([
                 {"07:00:00", "07:00:00"},
                 {"07:10:00", "07:10:00"},
                 {"07:25:00", "07:25:00"}
               ])

      assert change_set.consequences == []
    end

    test "refuses a position past the trip's last stop" do
      state = state([linked(@trip_a, at(7, 0))])

      assert {:error, :invalid_command} = plan({:shift, [@trip_a], 300, 4}, state)
    end

    test "excludes a frequency trip from the timepoint shift" do
      state = state([frequency(@trip_a, at(6, 0)), linked(@trip_b, at(6, 30))])

      assert {:ok, change_set} = plan({:shift, [@trip_a, @trip_b], 300, 2}, state)

      assert [update] = change_set.updates
      assert update.trip_id == @trip_b

      assert change_set.consequences == [
               {:note, {:becomes_custom, [@trip_b]}},
               {:note, {:excluded, @trip_a, :frequency_whole}}
             ]
    end
  end

  describe "frequency trips" do
    test "move their windows and template" do
      state = state([frequency(@trip_a, at(6, 0))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert [update] = change_set.updates
      assert update.fields == %{}

      assert update.stop_times ==
               values([
                 {"06:05:00", "06:05:00"},
                 {"06:15:00", "06:15:00"},
                 {"06:25:00", "06:25:00"}
               ])

      assert update.frequencies == [
               %{
                 start_time: "06:05:00",
                 end_time: "07:05:00",
                 headway_secs: 600,
                 exact_times: 1
               }
             ]

      assert change_set.consequences == [{:note, {:windows_moved, [@trip_a]}}]
    end

    test "refuse a window that would start before 00:00" do
      state = state([frequency(@trip_a, at(0, 5))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], -600, nil}, state)

      assert change_set.updates == []
      assert change_set.consequences == [{:error, :negative_time}]
    end
  end

  describe "consequences" do
    test "note trips that now start at or after 24:00 and leave trips already there" do
      state = state([linked(@trip_a, at(23, 58)), linked(@trip_b, at(25, 10))])

      assert {:ok, change_set} = plan({:shift, [@trip_a, @trip_b], 300, nil}, state)

      assert length(change_set.updates) == 2
      assert change_set.consequences == [{:note, {:crosses_midnight, [@trip_a]}}]
    end

    test "warn about a listed trip already leaving at the shifted first departure" do
      state =
        state([linked(@trip_a, at(7, 0))],
          block_inputs:
            block_inputs([
              trip_row(@trip_a, at(7, 0), at(7, 20)),
              trip_row(@trip_b, at(7, 5), at(7, 25)),
              trip_row(@trip_c, at(7, 5), at(7, 25), service_id: "SAT"),
              trip_row(@trip_d, at(7, 5), at(7, 25), frequency?: true)
            ])
        )

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert change_set.consequences == [{:warning, {:duplicate_departure, @trip_a, "07:05:00"}}]
    end

    test "warn about a listed trip the state holds without using block inputs" do
      state = state([linked(@trip_a, at(7, 0)), linked(@trip_b, at(7, 5))])

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert change_set.consequences == [{:warning, {:duplicate_departure, @trip_a, "07:05:00"}}]
    end

    test "report the block findings the shifted endpoints add" do
      state = block_103_state([trip_row(@trip_b, at(9, 10), at(10, 0), block_id: "103")])

      assert {:ok, change_set} = plan({:shift, [@trip_a], 480, nil}, state)

      assert [update] = change_set.updates
      assert update.fields == %{}

      assert [{:warning, {:block_findings, [finding]}}] = change_set.consequences
      assert finding.code == :short_layover
      assert finding.severity == :warning
      assert finding.block_id == "103"
      assert finding.trip_ids == [@trip_a, @trip_b]
      assert finding.detail == %{gap_secs: 120}
      assert finding.transfer_id == nil
    end

    test "add nothing when the shift removes a finding instead" do
      state =
        state([linked(@trip_a, at(8, 0), block_id: "103", offsets: @hour_offsets)],
          block_inputs:
            block_inputs([
              trip_row(@trip_a, at(8, 0), at(9, 0), block_id: "103"),
              trip_row(@trip_b, at(9, 2), at(10, 0), block_id: "103")
            ])
        )

      assert {:ok, change_set} = plan({:shift, [@trip_a], -480, nil}, state)

      assert change_set.consequences == []
    end

    test "feed the added block findings into the reviewed fingerprint" do
      tight = block_103_state([trip_row(@trip_b, at(9, 10), at(10, 0), block_id: "103")])
      loose = put_in(tight.block_inputs.settings.min_layover_minutes, 1)

      {:ok, command} = TripChanges.validate({:shift, [@trip_a], 480, nil})
      assert {:ok, tight_change_set} = TripChanges.plan(command, tight)
      assert {:ok, loose_change_set} = TripChanges.plan(command, loose)

      assert [{:warning, {:block_findings, [_finding]}}] = tight_change_set.consequences
      assert loose_change_set.consequences == []

      refute TripChanges.fingerprint(command, tight, tight_change_set) ==
               TripChanges.fingerprint(command, loose, loose_change_set)
    end

    test "plan every selected trip and never name block_id (FH-19)" do
      state =
        state(
          [
            linked(@trip_a, at(8, 0), block_id: "103", offsets: @hour_offsets),
            custom(@trip_b, at(8, 30)),
            frequency(@trip_c, at(9, 0))
          ],
          patterns: patterns([peak_timing()]),
          block_inputs:
            block_inputs([
              trip_row(@trip_a, at(8, 0), at(9, 0), block_id: "103"),
              trip_row(@trip_b, at(8, 30), at(8, 50)),
              trip_row(@trip_c, at(9, 0), at(9, 20), frequency?: true)
            ])
        )

      assert {:ok, change_set} = plan({:shift, [@trip_a, @trip_b, @trip_c], 300, nil}, state)

      assert Enum.map(change_set.updates, & &1.trip_id) == [@trip_a, @trip_b, @trip_c]

      for update <- change_set.updates do
        refute Map.has_key?(update.fields, :block_id)
      end

      assert Enum.at(change_set.updates, 0).fields == %{}

      assert Enum.at(change_set.updates, 1).fields == %{
               timed_pattern_id: nil,
               pattern_derivation_state: "custom",
               pattern_derivation_reason: "edited_in_schedules"
             }

      assert Enum.at(change_set.updates, 2).frequencies == [
               %{start_time: "09:05:00", end_time: "10:05:00", headway_secs: 600, exact_times: 1}
             ]

      assert change_set.consequences == [{:note, {:windows_moved, [@trip_c]}}]
    end

    test "a trip the state does not hold is not_found" do
      state = state([linked(@trip_a, at(7, 0))])

      assert {:error, :not_found} = plan({:shift, [@trip_a, @trip_b], 300, nil}, state)
    end

    test "reads the loader's StopTime and Frequency structs" do
      state = %{
        route: %{route_id: "R1"},
        trips: %{
          @trip_a => %{
            trip: %Trip{
              id: @trip_a,
              service_id: "WKDY",
              route_pattern_id: @pattern_id,
              block_id: "103",
              pattern_derivation_state: "linked",
              timed_pattern_id: @base_timing,
              updated_at: ~U[2026-01-01 00:00:00Z]
            },
            stop_times: [
              %StopTime{
                id: "st-1",
                stop_sequence: 1,
                arrival_time: "08:00:00",
                departure_time: "08:00:00",
                timepoint: 1,
                pickup_type: 0,
                drop_off_type: 0
              },
              %StopTime{
                id: "st-2",
                stop_sequence: 2,
                arrival_time: "08:30:00",
                departure_time: "08:30:00",
                timepoint: 0,
                pickup_type: 0,
                drop_off_type: 0
              },
              %StopTime{
                id: "st-3",
                stop_sequence: 3,
                arrival_time: "09:00:00",
                departure_time: "09:00:00",
                timepoint: 0,
                pickup_type: 0,
                drop_off_type: 0
              }
            ],
            frequencies: [
              %Frequency{
                start_time: "08:00:00",
                end_time: "09:00:00",
                headway_secs: 600,
                exact_times: 1
              }
            ]
          }
        },
        patterns: patterns([timing(@base_timing, "Base", [0, 1_800, 3_600])]),
        pattern_trips: %{},
        block_inputs: nil
      }

      assert {:ok, change_set} = plan({:shift, [@trip_a], 300, nil}, state)

      assert [update] = change_set.updates
      assert update.fields == %{}

      assert update.stop_times ==
               values([
                 {"08:05:00", "08:05:00"},
                 {"08:35:00", "08:35:00"},
                 {"09:05:00", "09:05:00"}
               ])

      assert update.frequencies == [
               %{start_time: "08:05:00", end_time: "09:05:00", headway_secs: 600, exact_times: 1}
             ]

      assert change_set.consequences == [{:note, {:windows_moved, [@trip_a]}}]
    end
  end

  # --- fixtures ------------------------------------------------------------

  defp plan(command, state) do
    {:ok, validated} = TripChanges.validate(command)

    TripChanges.plan(validated, state)
  end

  defp state(trips, opts \\ []) do
    %{
      route: %{route_id: "R1"},
      trips: Map.new(trips),
      patterns: Keyword.get(opts, :patterns, patterns([base_timing()])),
      pattern_trips: Keyword.get(opts, :pattern_trips, %{}),
      block_inputs: Keyword.get(opts, :block_inputs)
    }
  end

  defp block_103_state(other_trips) do
    state([linked(@trip_a, at(8, 0), block_id: "103", offsets: @hour_offsets)],
      block_inputs:
        block_inputs([
          trip_row(@trip_a, at(8, 0), at(9, 0), block_id: "103") | other_trips
        ])
    )
  end

  defp linked(id, start, opts \\ []), do: loaded(id, start, "linked", opts)

  defp custom(id, start, opts \\ []), do: loaded(id, start, "custom", opts)

  defp frequency(id, start, opts \\ []) do
    window = %{
      start_time: GtfsTime.format(start),
      end_time: GtfsTime.format(start + 3_600),
      headway_secs: 600,
      exact_times: 1
    }

    loaded(id, start, "custom", Keyword.put(opts, :frequencies, [window]))
  end

  defp loaded(id, start, derivation, opts) do
    trip = %{
      id: id,
      trip_id: Keyword.get(opts, :trip_id, id),
      route_id: "R1",
      service_id: Keyword.get(opts, :service_id, "WKDY"),
      block_id: Keyword.get(opts, :block_id),
      route_pattern_id: Keyword.get(opts, :pattern_id, @pattern_id),
      pattern_derivation_state: derivation,
      timed_pattern_id:
        Keyword.get(opts, :timed_pattern_id, if(derivation == "linked", do: @base_timing)),
      pattern_derivation_reason: if(derivation == "custom", do: "imported"),
      updated_at: ~U[2026-01-01 00:00:00Z]
    }

    {id,
     %{
       trip: trip,
       stop_times: stop_times(start, Keyword.get(opts, :offsets, @base_offsets), opts),
       frequencies: Keyword.get(opts, :frequencies, [])
     }}
  end

  defp stop_times(start, offsets, opts) do
    flags = Keyword.get(opts, :flags, [])

    offsets
    |> Enum.with_index(1)
    |> Enum.map(fn {offset, position} ->
      flag = Enum.at(flags, position - 1, %{})
      clock = if offset == :clear, do: nil, else: GtfsTime.format(start + offset)

      %{
        id: "st-#{position}",
        stop_id: "stop-#{position}",
        stop_sequence: position,
        arrival_time: clock,
        departure_time: clock,
        timepoint: Map.get(flag, :timepoint, if(position == 1, do: 1, else: 0)),
        pickup_type: Map.get(flag, :pickup_type, 0),
        drop_off_type: Map.get(flag, :drop_off_type, 0),
        stop_headsign: Map.get(flag, :stop_headsign)
      }
    end)
  end

  defp patterns(timings) do
    %{
      @pattern_id => %{
        pattern: %{id: @pattern_id},
        occurrences: [
          %{stop_id: "stop-1", position: 1},
          %{stop_id: "stop-2", position: 2},
          %{stop_id: "stop-3", position: 3}
        ],
        timings: timings
      }
    }
  end

  defp base_timing, do: timing(@base_timing, "Base", @base_offsets)

  defp peak_timing, do: timing(@peak_timing, "Peak", [0, 900, 1_500])

  defp timing(id, name, offsets) do
    rows =
      offsets
      |> Enum.with_index(1)
      |> Enum.map(fn {offset, position} ->
        %{
          arrival_offset: offset,
          departure_offset: offset,
          timepoint: if(position == 1, do: 1, else: 0),
          pickup_type: 0,
          drop_off_type: 0,
          stop_headsign: nil
        }
      end)

    %{timing: %{id: id, name: name}, rows: rows}
  end

  defp block_inputs(trip_rows, opts \\ []) do
    %{
      calendars: [
        %{service_id: "WKDY", name: "Weekday", active_dates: @wkdy, trip_count: 1},
        %{service_id: "SAT", name: "Saturday", active_dates: @sat, trip_count: 1}
      ],
      trips: trip_rows,
      transfers: [],
      settings: %{min_layover_minutes: Keyword.get(opts, :min_layover, 5)}
    }
  end

  defp trip_row(id, from_secs, to_secs, opts \\ []) do
    stop = %{stop_id: "S1", name: nil, parent_station: nil, lat: nil, lon: nil}

    %{
      id: id,
      trip_id: Keyword.get(opts, :trip_id, id),
      route_id: "R1",
      service_id: Keyword.get(opts, :service_id, "WKDY"),
      block_id: Keyword.get(opts, :block_id),
      trip_headsign: nil,
      route_pattern_id: Keyword.get(opts, :pattern_id, @pattern_id),
      updated_at: ~U[2026-01-01 00:00:00Z],
      frequency?: Keyword.get(opts, :frequency?, false),
      headway_secs: nil,
      first_arrival: from_secs,
      first_departure: from_secs,
      last_arrival: to_secs,
      last_departure: to_secs,
      first_stop: stop,
      last_stop: stop,
      plottable?: true
    }
  end

  defp values(clocks) do
    clocks
    |> Enum.with_index(1)
    |> Enum.map(fn {{arrival, departure}, position} ->
      %{
        position: position,
        arrival_time: arrival,
        departure_time: departure,
        timepoint: if(position == 1, do: 1, else: 0),
        pickup_type: 0,
        drop_off_type: 0,
        stop_headsign: nil
      }
    end)
  end

  defp at(hours, minutes), do: hours * 3_600 + minutes * 60
end
