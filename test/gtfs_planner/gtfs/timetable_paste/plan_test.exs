defmodule GtfsPlanner.Gtfs.TimetablePaste.PlanTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.TimetablePaste.Plan

  # Literal fixtures. One pattern ("pattern-main", natural id "PAT-1") with
  # three occurrences and one timing; scope trips carry the natural
  # route_pattern_id the way load_paste_scope/5 will load them, so the
  # duplicate tests also prove the uuid → natural bridge.
  @pattern_id "pattern-main"
  @natural_id "PAT-1"
  @stamp "Sep 28"

  defp timing_row(arrival, departure, opts \\ []) do
    %{
      arrival_offset: arrival,
      departure_offset: departure,
      timepoint: Keyword.get(opts, :timepoint, 1),
      pickup_type: Keyword.get(opts, :pickup, 0),
      drop_off_type: Keyword.get(opts, :drop, 0),
      stop_headsign: Keyword.get(opts, :headsign, nil)
    }
  end

  # Same tuple layout Plan (and RowResolver) keys on: the full final vector
  # plus per-stop attributes as a deterministic binary.
  defp key(rows) do
    vector =
      Enum.map(rows, fn row ->
        {row.arrival_offset, row.departure_offset, row.timepoint, row.pickup_type,
         row.drop_off_type, row.stop_headsign}
      end)

    :erlang.term_to_binary(vector, [:deterministic])
  end

  defp base_rows do
    [
      timing_row(0, 0),
      timing_row(300, 300, timepoint: 0),
      timing_row(600, 600)
    ]
  end

  defp ready_row(n, start_secs, timing_rows, fields \\ %{}) do
    %{
      row: n,
      status: :ready,
      issue: nil,
      pattern_id: @pattern_id,
      how: :default,
      start_secs: start_secs,
      timing_rows: timing_rows,
      key: key(timing_rows),
      pasted: [1, 3],
      trip_short_name: Map.get(fields, :trip_short_name),
      block_id: Map.get(fields, :block_id),
      trip_headsign: Map.get(fields, :trip_headsign),
      rolled?: false,
      shift: 0
    }
  end

  defp scope(timings \\ [], trips \\ []) do
    %{
      pattern_id: @pattern_id,
      patterns: [
        %{id: @pattern_id, route_pattern_id: @natural_id, timings: timings}
      ],
      trips: trips
    }
  end

  defp timing(id, name, rows) do
    %{id: id, name: name, rows: rows, trip_count: 3}
  end

  defp trip(id, start_secs) do
    %{id: id, trip_id: "T-#{id}", route_pattern_id: @natural_id, start_secs: start_secs}
  end

  @half_past_7 7 * 3600 + 30 * 60

  defp rich_trip(id, start_secs, opts \\ []) do
    trip(id, start_secs) |> Map.merge(Map.new(opts))
  end

  defp ready_row_on(pattern_id, n, start_secs, timing_rows, fields \\ %{}) do
    %{ready_row(n, start_secs, timing_rows, fields) | pattern_id: pattern_id}
  end

  defp empty_counts do
    %{add: 0, change: 0, unchanged: 0, remove: 0, duplicate: 0, skipped: 0, needs_decision: 0}
  end

  describe "add mode" do
    test "every accepted row becomes an :add with exact counts" do
      rows = [
        ready_row(1, 6 * 3600, base_rows()),
        ready_row(2, 7 * 3600, base_rows())
      ]

      plan = Plan.build(rows, scope(), :add, %{}, @stamp, [])

      assert Enum.map(plan.changes, & &1.op) == [:add, :add]
      assert plan.counts == %{empty_counts() | add: 2}
      assert plan.refusal == nil
      assert plan.warnings == []
      assert plan.transfers_removed == 0
      assert plan.replace_patterns == []
      assert plan.vehicles == %{before: nil, after: nil}
      assert plan.trips == %{before: 0, after: 2}
      assert plan.writes_blocks? == false
      # Same vector twice: one shared pending timing, both rows point at it.
      assert [%{pattern_id: @pattern_id, name: "Pasted Sep 28 · A", key: shared_key}] =
               plan.new_timings

      assert shared_key == key(base_rows())

      assert Enum.map(plan.changes, & &1.timing) == [
               new: "Pasted Sep 28 · A",
               new: "Pasted Sep 28 · A"
             ]
    end

    test "change shape carries the spec keys" do
      [change] =
        Plan.build([ready_row(1, 6 * 3600, base_rows())], scope(), :add, %{}, @stamp, []).changes

      assert Map.keys(change) |> Enum.sort() ==
               [
                 :block_id,
                 :diffs,
                 :op,
                 :row,
                 :timing,
                 :trip,
                 :trip_headsign,
                 :trip_short_name,
                 :warnings
               ]

      assert change == %{
               op: :add,
               row: ready_row(1, 6 * 3600, base_rows()),
               trip: nil,
               diffs: [],
               timing: {:new, "Pasted Sep 28 · A"},
               trip_short_name: nil,
               block_id: nil,
               trip_headsign: nil,
               warnings: []
             }
    end

    test "a row repeating an existing trip is :duplicate until Add anyway" do
      rows = [ready_row(1, 6 * 3600, base_rows())]
      existing = scope([], [trip("trip-1", 6 * 3600)])

      plan = Plan.build(rows, existing, :add, %{}, @stamp, [])
      [change] = plan.changes

      assert change.op == :duplicate
      assert change.trip == trip("trip-1", 6 * 3600)
      assert change.timing == nil
      assert plan.counts == %{empty_counts() | duplicate: 1}
      assert plan.new_timings == []
      assert plan.trips == %{before: 1, after: 1}

      kept = Plan.build(rows, existing, :add, %{1 => %{keep: true}}, @stamp, [])
      [kept_change] = kept.changes

      assert kept_change.op == :add
      assert kept_change.timing == {:new, "Pasted Sep 28 · A"}
      assert kept.counts == %{empty_counts() | add: 1}

      # The LiveView JSON round-trip (string keys) keeps working.
      string_kept = Plan.build(rows, existing, :add, %{"1" => %{"keep" => true}}, @stamp, [])
      assert Enum.map(string_kept.changes, & &1.op) == [:add]

      # Decisions also arrive inside the review input.
      input_kept =
        Plan.build(rows, existing, :add, %{decisions: %{1 => %{keep: true}}}, @stamp, [])

      assert Enum.map(input_kept.changes, & &1.op) == [:add]
    end

    test "a row repeating an earlier pasted row is :duplicate" do
      rows = [
        ready_row(1, 6 * 3600, base_rows()),
        ready_row(2, 6 * 3600, base_rows())
      ]

      plan = Plan.build(rows, scope(), :add, %{}, @stamp, [])

      assert Enum.map(plan.changes, & &1.op) == [:add, :duplicate]
      assert plan.counts == %{empty_counts() | add: 1, duplicate: 1}
      # The skipped duplicate consumes no second timing.
      assert length(plan.new_timings) == 1
      assert plan.trips == %{before: 0, after: 1}

      kept = Plan.build(rows, scope(), :add, %{2 => %{keep: true}}, @stamp, [])
      assert Enum.map(kept.changes, & &1.op) == [:add, :add]
      assert length(kept.new_timings) == 1
    end

    test "an exact full-vector match reuses the existing timing" do
      existing = scope([timing("timing-1", "Typical", base_rows())], [])
      plan = Plan.build([ready_row(1, 6 * 3600, base_rows())], existing, :add, %{}, @stamp, [])
      [change] = plan.changes

      assert change.timing == {:existing, "timing-1"}
      assert plan.new_timings == []
      assert plan.counts == %{empty_counts() | add: 1}
    end

    test "a one-second miss or an attribute miss mints a pending timing" do
      off = [timing_row(0, 0), timing_row(301, 301, timepoint: 0), timing_row(600, 600)]

      attr = [
        timing_row(0, 0),
        timing_row(300, 300, timepoint: 0, pickup: 1),
        timing_row(600, 600)
      ]

      existing = scope([timing("timing-1", "Typical", base_rows())], [])

      for rows <- [off, attr] do
        [change] =
          Plan.build([ready_row(1, 6 * 3600, rows)], existing, :add, %{}, @stamp, []).changes

        assert change.timing == {:new, "Pasted Sep 28 · A"}
      end
    end

    test "an existing lowercase pasted name makes the next name · B" do
      existing =
        scope([timing("timing-1", "pasted sep 28 · a", base_rows())], []) |> Map.put(:trips, [])

      other = [timing_row(0, 0), timing_row(400, 400, timepoint: 0), timing_row(800, 800)]

      plan = Plan.build([ready_row(1, 6 * 3600, other)], existing, :add, %{}, @stamp, [])
      [change] = plan.changes

      assert change.timing == {:new, "Pasted Sep 28 · B"}
      assert [%{name: "Pasted Sep 28 · B"}] = plan.new_timings
    end

    test "twenty-seven distinct vectors name the last · AA" do
      rows =
        Enum.map(0..26, fn i ->
          varied = [
            timing_row(0, 0),
            timing_row(300 + i, 300 + i, timepoint: 0),
            timing_row(600, 600)
          ]

          ready_row(i + 1, 6 * 3600 + i * 600, varied)
        end)

      plan = Plan.build(rows, scope(), :add, %{}, @stamp, [])
      names = Enum.map(plan.new_timings, & &1.name)

      assert length(names) == 27
      assert Enum.at(names, 0) == "Pasted Sep 28 · A"
      assert Enum.at(names, 25) == "Pasted Sep 28 · Z"
      assert Enum.at(names, 26) == "Pasted Sep 28 · AA"
      assert plan.counts == %{empty_counts() | add: 27}
    end

    test "skipped and decision rows are never counted as adds" do
      skipped = %{
        ready_row(1, 6 * 3600, base_rows())
        | status: :skipped,
          start_secs: nil,
          timing_rows: nil,
          key: nil
      }

      decision = %{
        row: 2,
        status: :decision,
        issue: :no_pattern,
        pattern_id: nil,
        how: nil,
        start_secs: nil,
        timing_rows: nil,
        key: nil,
        pasted: [],
        trip_short_name: "1227",
        block_id: nil,
        trip_headsign: nil,
        rolled?: false,
        shift: 0
      }

      plan = Plan.build([skipped, decision], scope(), :add, %{}, @stamp, [])

      assert Enum.map(plan.changes, & &1.op) == [:skipped, :needs_decision]
      assert plan.counts == %{empty_counts() | skipped: 1, needs_decision: 1}
      assert plan.new_timings == []
      assert plan.trips == %{before: 0, after: 0}
      assert plan.writes_blocks? == false
    end

    test "writes_blocks? follows applied rows' block values" do
      blocked = ready_row(1, 6 * 3600, base_rows(), %{block_id: "101"})
      plain = ready_row(2, 7 * 3600, base_rows())

      assert Plan.build([blocked, plain], scope(), :add, %{}, @stamp, []).writes_blocks? == true
      assert Plan.build([plain], scope(), :add, %{}, @stamp, []).writes_blocks? == false

      # A blocked row that stays :duplicate writes nothing.
      existing = scope([], [trip("trip-1", 6 * 3600)])
      assert Plan.build([blocked], existing, :add, %{}, @stamp, []).writes_blocks? == false
    end
  end

  describe "replace mode" do
    test "an exact pattern and start pair keeps the existing trip as a :change" do
      existing = rich_trip("trip-1", 6 * 3600)
      s = scope([timing("timing-1", "Typical", base_rows())], [existing])
      row = ready_row(1, 6 * 3600, base_rows())

      plan = Plan.build([row], s, :replace, %{}, @stamp, [])
      [change] = plan.changes

      assert change.op == :change
      assert change.trip == existing
      assert change.row == row
      assert change.timing == {:existing, "timing-1"}
      assert change.warnings == []
      assert plan.refusal == nil
      assert plan.counts == %{empty_counts() | change: 1}
      assert plan.replace_patterns == [@pattern_id]
      assert plan.transfers_removed == 0
      assert plan.new_timings == []
      assert plan.trips == %{before: 1, after: 1}
      assert plan.vehicles == %{before: nil, after: nil}
      assert plan.writes_blocks? == false
    end

    test "a unique equal trip number pairs without a decision and removes the other" do
      t1207 =
        rich_trip("trip-1207", @half_past_7,
          trip_short_name: "1207",
          transfer_ids: ["x1", "x2"]
        )

      t1209 = rich_trip("trip-1209", @half_past_7, trip_short_name: "1209")
      s = scope([], [t1207, t1209])
      row = ready_row(1, @half_past_7, base_rows(), %{trip_short_name: "1209"})

      plan = Plan.build([row], s, :replace, %{}, @stamp, [])
      assert Enum.map(plan.changes, & &1.op) == [:change, :remove]
      [change, removal] = plan.changes

      assert change.trip == t1209
      assert change.row == row
      assert removal.trip == t1207
      assert removal.row == nil
      assert plan.transfers_removed == 2
      assert plan.counts == %{empty_counts() | change: 1, remove: 1}
      assert plan.trips == %{before: 2, after: 1}
      assert plan.refusal == nil
    end

    test "two 07:30 trips with a new trip number need a decision and remove nothing" do
      t1207 = rich_trip("trip-1207", @half_past_7, trip_short_name: "1207")
      t1209 = rich_trip("trip-1209", @half_past_7, trip_short_name: "1209")
      s = scope([], [t1207, t1209])
      row = ready_row(1, @half_past_7, base_rows(), %{trip_short_name: "1227"})

      plan = Plan.build([row], s, :replace, %{}, @stamp, [])
      [change] = plan.changes

      assert change.op == :needs_decision
      assert change.row == row
      assert change.trip == nil
      assert change.candidates == [t1207, t1209]
      assert change.timing == nil
      assert plan.counts == %{empty_counts() | needs_decision: 1}
      assert plan.refusal == nil
      assert plan.replace_patterns == [@pattern_id]
      assert plan.transfers_removed == 0
      assert plan.trips == %{before: 2, after: 2}
    end

    test "choosing 1207 pairs it and removes the other" do
      t1207 = rich_trip("trip-1207", @half_past_7, trip_short_name: "1207")
      t1209 = rich_trip("trip-1209", @half_past_7, trip_short_name: "1209")
      s = scope([], [t1207, t1209])
      row = ready_row(1, @half_past_7, base_rows(), %{trip_short_name: "1227"})

      plan = Plan.build([row], s, :replace, %{1 => %{pair: "trip-1207"}}, @stamp, [])
      assert Enum.map(plan.changes, & &1.op) == [:change, :remove]
      [change, removal] = plan.changes

      assert change.trip == t1207
      assert removal.trip == t1209
      assert plan.counts == %{empty_counts() | change: 1, remove: 1}
      assert plan.trips == %{before: 2, after: 1}

      # The natural trip_id and the LiveView JSON string form name it too.
      by_natural =
        Plan.build([row], s, :replace, %{1 => %{pair: "T-trip-1207"}}, @stamp, [])

      assert Enum.map(by_natural.changes, & &1.op) == [:change, :remove]

      as_json =
        Plan.build([row], s, :replace, %{"1" => %{"pair" => "trip-1207"}}, @stamp, [])

      assert Enum.map(as_json.changes, & &1.op) == [:change, :remove]
    end

    test "'neither' adds the row and removes both candidates" do
      t1207 = rich_trip("trip-1207", @half_past_7, trip_short_name: "1207")
      t1209 = rich_trip("trip-1209", @half_past_7, trip_short_name: "1209")
      s = scope([], [t1207, t1209])
      row = ready_row(1, @half_past_7, base_rows(), %{trip_short_name: "1227"})

      plan = Plan.build([row], s, :replace, %{1 => %{pair: "neither"}}, @stamp, [])
      assert Enum.map(plan.changes, & &1.op) == [:add, :remove, :remove]

      [added, first_removed, second_removed] = plan.changes
      assert added.row == row
      assert added.timing == {:new, "Pasted Sep 28 · A"}
      assert first_removed.trip == t1207
      assert second_removed.trip == t1209
      assert plan.counts == %{empty_counts() | add: 1, remove: 2}
      assert plan.trips == %{before: 2, after: 1}
    end

    test "a blank trip number cannot pair two candidates" do
      t1207 = rich_trip("trip-1207", @half_past_7, trip_short_name: "1207")
      t1209 = rich_trip("trip-1209", @half_past_7, trip_short_name: "1209")
      s = scope([], [t1207, t1209])

      plan = Plan.build([ready_row(1, @half_past_7, base_rows())], s, :replace, %{}, @stamp, [])
      [change] = plan.changes

      assert change.op == :needs_decision
      assert change.candidates == [t1207, t1209]
      assert plan.counts == %{empty_counts() | needs_decision: 1}
    end

    test "a pairing choice naming no candidate stays undecided" do
      t1207 = rich_trip("trip-1207", @half_past_7, trip_short_name: "1207")
      t1209 = rich_trip("trip-1209", @half_past_7, trip_short_name: "1209")
      s = scope([], [t1207, t1209])
      row = ready_row(1, @half_past_7, base_rows(), %{trip_short_name: "1227"})

      plan = Plan.build([row], s, :replace, %{1 => %{pair: "trip-9999"}}, @stamp, [])
      [change] = plan.changes

      assert change.op == :needs_decision
      assert change.candidates == [t1207, t1209]
      assert plan.counts == %{empty_counts() | needs_decision: 1}
    end

    test "every row skipped refuses with :nothing_accepted and deletes nothing" do
      kept = rich_trip("trip-1", 6 * 3600, transfer_ids: ["x1"])
      s = scope([], [kept])

      skipped = %{
        ready_row(1, 6 * 3600, base_rows())
        | status: :skipped,
          start_secs: nil,
          timing_rows: nil,
          key: nil
      }

      plan = Plan.build([skipped], s, :replace, %{}, @stamp, [])

      assert plan.refusal == :nothing_accepted
      assert Enum.map(plan.changes, & &1.op) == [:skipped]
      assert plan.counts == %{empty_counts() | skipped: 1}
      assert plan.transfers_removed == 0
      assert plan.replace_patterns == []
      assert plan.trips == %{before: 1, after: 1}
    end

    test "a frequency trip in scope refuses replace without deleting" do
      freq = rich_trip("trip-freq", 9 * 3600, frequencies: [%{headway_secs: 600}])
      paired = rich_trip("trip-1", 6 * 3600)
      s = scope([], [paired, freq])

      plan =
        Plan.build([ready_row(1, 6 * 3600, base_rows())], s, :replace, %{}, @stamp, [])

      assert plan.refusal == {:frequency, freq}
      assert Enum.map(plan.changes, & &1.op) == [:change]
      assert plan.counts == %{empty_counts() | change: 1}
      assert plan.transfers_removed == 0
    end

    test "a custom trip whose stops differ refuses replace" do
      custom =
        rich_trip("trip-custom", 9 * 3600,
          pattern_derivation_state: "custom",
          stops_differ?: true
        )

      paired = rich_trip("trip-1", 6 * 3600)
      s = scope([], [paired, custom])

      plan =
        Plan.build([ready_row(1, 6 * 3600, base_rows())], s, :replace, %{}, @stamp, [])

      assert plan.refusal == {:stops_differ, custom}
      assert Enum.map(plan.changes, & &1.op) == [:change]
      assert plan.transfers_removed == 0
    end

    test "a custom trip with matching stops pairs with a :custom_replaced warning" do
      custom =
        rich_trip("trip-custom", 6 * 3600,
          pattern_derivation_state: "custom",
          stops_differ?: false
        )

      s = scope([], [custom])

      plan =
        Plan.build([ready_row(1, 6 * 3600, base_rows())], s, :replace, %{}, @stamp, [])

      [change] = plan.changes
      assert change.op == :change
      assert change.trip == custom
      assert change.warnings == [:custom_replaced]
      assert plan.refusal == nil
    end

    test "unpaired trips on pasted patterns are removed; other patterns untouched" do
      short_id = "pattern-short"

      s = %{
        pattern_id: @pattern_id,
        patterns: [
          %{id: @pattern_id, route_pattern_id: @natural_id, timings: []},
          %{id: short_id, route_pattern_id: "PAT-2", timings: []}
        ],
        trips: [
          rich_trip("trip-0600", 6 * 3600),
          rich_trip("trip-0700", 7 * 3600, transfer_ids: ["a", "b"]),
          rich_trip("trip-0800", 8 * 3600, transfer_ids: ["c"]),
          rich_trip("trip-short", 6 * 3600, route_pattern_id: "PAT-2")
        ]
      }

      plan =
        Plan.build(
          [ready_row_on(@pattern_id, 1, 6 * 3600, base_rows())],
          s,
          :replace,
          %{},
          @stamp,
          []
        )

      assert Enum.map(plan.changes, & &1.op) == [:change, :remove, :remove]
      [_paired, first, second] = plan.changes
      assert first.trip == rich_trip("trip-0700", 7 * 3600, transfer_ids: ["a", "b"])
      assert second.trip == rich_trip("trip-0800", 8 * 3600, transfer_ids: ["c"])
      assert plan.transfers_removed == 3
      assert plan.counts == %{empty_counts() | change: 1, remove: 2}
      assert plan.replace_patterns == [@pattern_id]
      assert plan.trips == %{before: 4, after: 2}
    end

    test "paired rows mint one shared pending timing on a new vector" do
      other = [timing_row(0, 0), timing_row(400, 400, timepoint: 0), timing_row(800, 800)]
      s = scope([timing("timing-1", "Typical", base_rows())], [])

      no_trips = Plan.build([], s, :replace, %{}, @stamp, [])
      assert no_trips.refusal == :nothing_accepted

      s2 =
        scope([timing("timing-1", "Typical", base_rows())], [
          rich_trip("trip-1", 6 * 3600),
          rich_trip("trip-2", 7 * 3600)
        ])

      plan =
        Plan.build(
          [ready_row(1, 6 * 3600, other), ready_row(2, 7 * 3600, other)],
          s2,
          :replace,
          %{},
          @stamp,
          []
        )

      assert Enum.map(plan.changes, & &1.op) == [:change, :change]
      assert [%{pattern_id: @pattern_id, name: "Pasted Sep 28 · A"}] = plan.new_timings

      assert Enum.map(plan.changes, & &1.timing) == [
               new: "Pasted Sep 28 · A",
               new: "Pasted Sep 28 · A"
             ]
    end

    test "a paired blocked row writes blocks" do
      s = scope([], [rich_trip("trip-1", 6 * 3600)])
      row = ready_row(1, 6 * 3600, base_rows(), %{block_id: "101"})

      plan = Plan.build([row], s, :replace, %{}, @stamp, [])
      assert plan.writes_blocks? == true

      plain = Plan.build([ready_row(1, 6 * 3600, base_rows())], s, :replace, %{}, @stamp, [])
      assert plain.writes_blocks? == false
    end
  end

  describe "next_free_name/3" do
    test "first name is · A and taken names advance case-insensitively" do
      assert Plan.next_free_name([], "Sep 28", []) == "Pasted Sep 28 · A"

      assert Plan.next_free_name(["Pasted Sep 28 · A", "pasted sep 28 · b"], "Sep 28", [
               "Pasted Sep 28 · C"
             ]) == "Pasted Sep 28 · D"
    end

    test "pending names in the same build block reuse" do
      first = Plan.next_free_name([], "Sep 28", [])
      second = Plan.next_free_name([], "Sep 28", [first])

      assert first == "Pasted Sep 28 · A"
      assert second == "Pasted Sep 28 · B"
    end
  end
end
