defmodule GtfsPlanner.Gtfs.TimetablePasteTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.TimetablePaste

  # Literal fixtures: a three-stop main pattern with one timing; scope trips
  # carry the natural route_pattern_id the way load_paste_scope/5 will load
  # them, so replace pairing also proves the uuid → natural bridge.
  @stops %{
    "S1" => %{stop_code: "1001", stop_name: "Central Station"},
    "S2" => %{stop_code: "1002", stop_name: "Market Street"},
    "S3" => %{stop_code: "1003", stop_name: "Hospital"}
  }

  defp timing_row(arrival, departure) do
    %{
      arrival_offset: arrival,
      departure_offset: departure,
      timepoint: 1,
      pickup_type: 0,
      drop_off_type: 0,
      stop_headsign: nil
    }
  end

  defp base_timing(id \\ "t1", name \\ "Typical", rows \\ nil) do
    %{
      id: id,
      name: name,
      headsign: nil,
      rows: rows || [timing_row(0, 0), timing_row(300, 300), timing_row(600, 600)],
      trip_count: 2
    }
  end

  defp base_pattern(timings \\ [base_timing()]) do
    %{
      id: "p1",
      route_pattern_id: "PAT-1",
      name: "Main",
      headsign: "Hospital",
      occurrences: [
        %{id: "o1", stop_id: "S1", position: 1},
        %{id: "o2", stop_id: "S2", position: 2},
        %{id: "o3", stop_id: "S3", position: 3}
      ],
      timings: timings
    }
  end

  defp base_scope(trips \\ []) do
    %{
      route: %{id: "R1"},
      calendar: %{service_id: "WKDY"},
      direction_id: 0,
      pattern_id: "p1",
      patterns: [base_pattern()],
      stops: @stops,
      trips: trips
    }
  end

  defp base_input(text, overrides \\ []) do
    %{
      text: text,
      layout: :auto,
      header?: true,
      overrides: Map.new(overrides),
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :add,
      template_timing_id: nil,
      stamp: "Sep 28",
      block_rows: []
    }
  end

  defp two_trip_text do
    "Central Station\tMarket Street\tHospital\n07:00\t07:05\t07:10\n08:00\t08:05\t08:10\n"
  end

  test "reviews a trips-in-rows paste end to end" do
    scope = base_scope()
    input = base_input(two_trip_text())

    assert {:ok, review} = TimetablePaste.review(scope, input)
    assert review.orientation == :trips_in_rows
    assert length(review.grid) == 3
    assert Enum.map(review.columns, & &1.status) == [:exact, :exact, :exact]

    assert Enum.map(review.columns, & &1.target) == [
             {:occurrence, "o1", :departure},
             {:occurrence, "o2", :departure},
             {:occurrence, "o3", :departure}
           ]

    assert review.column_issues == []

    assert Enum.map(review.rows, &{&1.row, &1.status, &1.pattern_id, &1.how}) == [
             {1, :ready, "p1", :default},
             {2, :ready, "p1", :default}
           ]

    assert Enum.map(review.rows, & &1.start_secs) == [7 * 3600, 8 * 3600]
    assert review.plan.counts.add == 2
    assert review.plan.refusal == nil
    assert review.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert review.fingerprint == TimetablePaste.fingerprint(scope, input)
  end

  test "auto layout detects stops-in-rows and transposes" do
    scope = base_scope()

    text =
      "\tTrip A\tTrip B\n" <>
        "Central Station\t07:00\t08:00\n" <>
        "Market Street\t07:05\t08:05\n" <>
        "Hospital\t07:10\t08:10\n"

    assert {:ok, review} = TimetablePaste.review(scope, base_input(text))
    assert review.orientation == :stops_in_rows
    assert hd(review.grid) == ["", "Central Station", "Market Street", "Hospital"]
    assert review.column_issues == []
    assert Enum.map(review.rows, &{&1.row, &1.status}) == [{1, :ready}, {2, :ready}]
    assert Enum.map(review.rows, & &1.start_secs) == [7 * 3600, 8 * 3600]
    assert review.plan.counts.add == 2
  end

  test "a 150-stop by 500-trip stops-in-rows sheet is accepted after orientation" do
    {scope, text} = large_sheet(150, 500)

    input = %{
      text: text,
      layout: :stops_in_rows,
      header?: false,
      overrides: %{},
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :add,
      template_timing_id: nil,
      stamp: "Sep 28"
    }

    assert byte_size(text) < 200 * 1024
    assert {:ok, review} = TimetablePaste.review(scope, input)
    assert review.orientation == :stops_in_rows
    assert length(review.grid) == 500
    assert review.grid |> hd() |> length() == 150
    assert length(review.columns) == 150
    assert Enum.all?(review.columns, &(&1.status == :chosen))
    assert review.column_issues == []
    assert length(review.rows) == 500
    assert Enum.all?(review.rows, &(&1.status == :ready))
    assert review.plan.counts.add == 500
    # Trip 1 pastes every stop while the rest paste endpoints with estimates,
    # so the build mints two pending timings, one per distinct vector.
    assert length(review.plan.new_timings) == 2
    assert review.fingerprint == TimetablePaste.fingerprint(scope, input)
  end

  test "501 trips after orientation are refused with {:too_many_rows, 501}" do
    {scope, text} = large_sheet(150, 501)

    input = %{
      text: text,
      layout: :stops_in_rows,
      header?: false,
      overrides: %{},
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :add,
      template_timing_id: nil,
      stamp: "Sep 28"
    }

    assert {:error, {:too_many_rows, 501}} = TimetablePaste.review(scope, input)
  end

  test "151 columns after orientation are refused with {:too_many_columns, 151}" do
    line = List.duplicate("07:00", 151) |> Enum.join("\t")
    scope = base_scope()
    input = %{base_input(line <> "\n" <> line <> "\n") | header?: false}

    assert {:error, {:too_many_columns, 151}} = TimetablePaste.review(scope, input)
  end

  test "stop names without times return :no_times" do
    scope = base_scope()
    input = base_input("Central Station\tMarket Street\nCentral\tMarket\n")

    assert {:error, :no_times} = TimetablePaste.review(scope, input)
  end

  test "parse errors are specific and the input text stays with the caller" do
    scope = base_scope()
    text = "a\t\"b\nc\td\n"
    input = base_input(text)

    assert {:error, {:unclosed_quote, 1}} = TimetablePaste.review(scope, input)
    assert input.text == text
  end

  test "column issues leave plan nil with an empty row list" do
    scope = base_scope()
    input = base_input("Central Station\tMystery Stop\n07:00\t07:05\n")

    assert {:ok, review} = TimetablePaste.review(scope, input)
    assert review.column_issues == [%{col: 1, kind: :unmatched}, %{col: nil, kind: :too_few}]
    assert review.plan == nil
    assert review.rows == []
    assert review.fingerprint == TimetablePaste.fingerprint(scope, input)
  end

  test "changing an unused timing's offsets changes the fingerprint" do
    used = base_timing("t1", "Typical")
    unused = base_timing("t2", "Unused")
    scope = %{base_scope() | patterns: [%{base_pattern() | timings: [used, unused]}]}
    input = base_input(two_trip_text())

    before_fp = TimetablePaste.fingerprint(scope, input)

    moved_rows = [timing_row(0, 0), timing_row(301, 301), timing_row(600, 600)]
    moved = %{unused | rows: moved_rows}
    moved_scope = %{scope | patterns: [%{base_pattern() | timings: [used, moved]}]}

    assert TimetablePaste.fingerprint(moved_scope, input) != before_fp
  end

  test "changing a used timing changes the fingerprint" do
    scope = base_scope()
    input = base_input(two_trip_text())
    before_fp = TimetablePaste.fingerprint(scope, input)

    moved =
      base_timing("t1", "Typical", [timing_row(0, 0), timing_row(301, 301), timing_row(600, 600)])

    moved_scope = %{scope | patterns: [%{base_pattern() | timings: [moved]}]}

    assert TimetablePaste.fingerprint(moved_scope, input) != before_fp
  end

  test "decisions change the fingerprint but key order does not" do
    scope = base_scope()
    input = base_input(two_trip_text())
    before_fp = TimetablePaste.fingerprint(scope, input)

    skipped = %{input | decisions: %{1 => %{skip: true}}}
    assert TimetablePaste.fingerprint(scope, skipped) != before_fp

    atom_keys = %{input | decisions: %{1 => %{cells: %{0 => "07:30"}, skip: false}}}
    string_keys = %{input | decisions: %{"1" => %{"skip" => false, "cells" => %{"0" => "07:30"}}}}

    assert TimetablePaste.fingerprint(scope, atom_keys) ==
             TimetablePaste.fingerprint(scope, string_keys)
  end

  test "block rows are not fingerprinted" do
    scope = base_scope()
    input = base_input(two_trip_text())

    row = %{
      trip_id: "T-1",
      service_id: "WKDY",
      block_id: "101",
      first_arrival_secs: 7 * 3600,
      last_departure_secs: 7 * 3600 + 600,
      plottable?: true,
      frequency?: false
    }

    assert TimetablePaste.fingerprint(scope, input) ==
             TimetablePaste.fingerprint(scope, %{input | block_rows: [row]})
  end

  test "only transfers naming removed or retimed trips affect the fingerprint" do
    trip_a = %{
      id: "A",
      trip_id: "TA",
      route_pattern_id: "PAT-1",
      direction_id: 0,
      start_secs: 7 * 3600,
      timed_pattern_id: "t1",
      pattern_derivation_state: "linked",
      block_id: nil,
      trip_short_name: "101",
      trip_headsign: nil,
      frequencies: [],
      updated_at: ~U[2026-09-28 12:00:00Z],
      transfer_ids: ["XF-1"]
    }

    trip_c = %{
      id: "C",
      trip_id: "TC",
      route_pattern_id: "PAT-2",
      direction_id: 0,
      start_secs: 9 * 3600,
      timed_pattern_id: "t9",
      pattern_derivation_state: "linked",
      block_id: nil,
      trip_short_name: "109",
      trip_headsign: nil,
      frequencies: [],
      updated_at: ~U[2026-09-28 12:00:00Z],
      transfer_ids: ["XC-1"]
    }

    short_pattern = %{
      id: "p2",
      route_pattern_id: "PAT-2",
      name: "Short",
      headsign: "Hospital",
      occurrences: [
        %{id: "s1", stop_id: "S1", position: 1},
        %{id: "s2", stop_id: "S2", position: 2},
        %{id: "s3", stop_id: "S3", position: 3}
      ],
      timings: []
    }

    scope = %{base_scope([trip_a]) | patterns: [base_pattern(), short_pattern]}

    input = %{
      base_input("Central Station\tMarket Street\tHospital\n07:00\t07:06\t07:11\n")
      | mode: :replace
    }

    assert {:ok, review} = TimetablePaste.review(scope, input)
    assert Enum.map(review.plan.changes, & &1.op) == [:change]
    base_fp = review.fingerprint

    retimed = %{scope | trips: [%{trip_a | transfer_ids: ["XF-2"]}]}
    assert TimetablePaste.fingerprint(retimed, input) != base_fp

    with_other = %{scope | trips: [trip_a, trip_c]}
    other_fp = TimetablePaste.fingerprint(with_other, input)

    with_other_changed = %{scope | trips: [trip_a, %{trip_c | transfer_ids: ["XC-2"]}]}
    assert TimetablePaste.fingerprint(with_other_changed, input) == other_fp
  end

  # A 150-stop pattern with one timing; each raw line holds one stop's times
  # across +trips+ trips, sparse (endpoints only) so the sheet fits the
  # 200 KB clipboard bound. Transposed, each row is one trip.
  defp large_sheet(stop_count, trip_count) do
    stops =
      for i <- 1..stop_count, into: %{} do
        id = "S" <> String.pad_leading(to_string(i), 3, "0")
        {id, %{stop_code: "C#{i}", stop_name: "Stop #{i}"}}
      end

    occurrences =
      for i <- 1..stop_count do
        id = "S" <> String.pad_leading(to_string(i), 3, "0")
        %{id: "o-#{id}", stop_id: id, position: i}
      end

    timing_rows = for i <- 1..stop_count, do: timing_row((i - 1) * 60, (i - 1) * 60)

    scope = %{
      route: %{id: "R1"},
      calendar: %{service_id: "WKDY"},
      direction_id: 0,
      pattern_id: "p1",
      patterns: [
        %{
          id: "p1",
          route_pattern_id: "PAT-1",
          name: "Main",
          headsign: "Stop #{stop_count}",
          occurrences: occurrences,
          timings: [
            %{id: "t1", name: "Typical", headsign: nil, rows: timing_rows, trip_count: 500}
          ]
        }
      ],
      stops: stops,
      trips: []
    }

    text =
      for stop <- 1..stop_count do
        stop_line(stop, stop_count, trip_count)
      end
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    {scope, text}
  end

  # Each raw line holds one stop's times across +trip_count+ trips. The two
  # endpoint stops carry every trip; middle stops carry one anchor cell (a
  # wholly blank line would be dropped as an empty row) and the parser pads
  # the ragged rows. Transposed, each row is one trip with estimates between
  # its endpoint times, and the sheet fits the 200 KB clipboard bound.
  defp stop_line(1, _stop_count, trip_count), do: full_line(trip_count, 0)

  defp stop_line(stop_index, stop_count, trip_count) when stop_index == stop_count do
    full_line(trip_count, 300)
  end

  defp stop_line(_stop_index, _stop_count, _trip_count), do: "7:01"

  defp full_line(trip_count, shift) do
    1..trip_count
    |> Enum.map(fn trip -> format_cell(7 * 3600 + trip * 60 + shift) end)
    |> Enum.join("\t")
  end

  defp format_cell(secs) do
    "#{div(secs, 3600)}:#{String.pad_leading(to_string(div(rem(secs, 3600), 60)), 2, "0")}"
  end
end
