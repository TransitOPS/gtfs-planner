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

  defp timing_h(id, name, rows, headsign) do
    %{id: id, name: name, rows: rows, trip_count: 3, headsign: headsign}
  end

  defp scope_h(pattern_headsign, timings, trips) do
    %{
      pattern_id: @pattern_id,
      patterns: [
        %{
          id: @pattern_id,
          route_pattern_id: @natural_id,
          headsign: pattern_headsign,
          timings: timings
        }
      ],
      trips: trips
    }
  end

  defp short_rows do
    [timing_row(0, 0), timing_row(200, 200, timepoint: 0), timing_row(500, 500)]
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

  describe "metadata, headsigns, warnings and discarded decisions" do
    defp main_and_short_scope(pattern_headsign, main_headsign) do
      scope_h(
        pattern_headsign,
        [
          timing_h("timing-main", "Main", base_rows(), main_headsign),
          timing_h("timing-short", "Short turn", short_rows(), "Hospital")
        ],
        []
      )
    end

    defp moved_row(n, fields \\ %{}) do
      ready_row(n, @half_past_7, short_rows(), fields)
    end

    test "blank Trip number and Block keep the matched values; an exact pair is :unchanged" do
      s =
        scope([timing("timing-1", "Typical", base_rows())], [
          rich_trip("trip-1", 6 * 3600,
            timed_pattern_id: "timing-1",
            trip_short_name: "1207",
            block_id: "101",
            trip_headsign: nil
          )
        ])

      plan = Plan.build([ready_row(1, 6 * 3600, base_rows())], s, :replace, %{}, @stamp, [])
      [change] = plan.changes

      assert change.op == :unchanged
      assert change.trip_short_name == "1207"
      assert change.block_id == "101"
      assert change.trip_headsign == nil
      assert change.diffs == []
      assert change.warnings == []
      assert change.timing == {:existing, "timing-1"}
      assert plan.counts == %{empty_counts() | unchanged: 1}
      assert plan.trips == %{before: 1, after: 1}
      assert plan.discarded_decisions == []
    end

    test "a pasted Trip number overrides and lists exactly what changed" do
      s =
        scope([timing("timing-1", "Typical", base_rows())], [
          rich_trip("trip-1", 6 * 3600,
            timed_pattern_id: "timing-1",
            trip_short_name: "1207",
            block_id: "101"
          )
        ])

      row = ready_row(1, 6 * 3600, base_rows(), %{trip_short_name: "1227"})
      [change] = Plan.build([row], s, :replace, %{}, @stamp, []).changes

      assert change.op == :change
      assert change.trip_short_name == "1227"
      assert change.block_id == "101"
      assert change.diffs == [:trip_short_name]
    end

    test "a default-following trip moved to the short turn takes the new effective default" do
      s = main_and_short_scope("Riverside Terminal", nil)

      s = %{
        s
        | trips: [
            rich_trip("trip-1", @half_past_7,
              timed_pattern_id: "timing-main",
              trip_headsign: "Riverside Terminal"
            )
          ]
      }

      [change] = Plan.build([moved_row(1)], s, :replace, %{}, @stamp, []).changes

      assert change.op == :change
      assert change.timing == {:existing, "timing-short"}
      assert change.trip_headsign == "Hospital"
      assert change.diffs == [:times, :trip_headsign]
      assert change.warnings == []
    end

    test "the old default comes from the old timing headsign before the pattern headsign" do
      s = main_and_short_scope("Riverside Terminal", "Depot")

      s = %{
        s
        | trips: [
            rich_trip("trip-1", @half_past_7,
              timed_pattern_id: "timing-main",
              trip_headsign: "Depot"
            )
          ]
      }

      [change] = Plan.build([moved_row(1)], s, :replace, %{}, @stamp, []).changes

      assert change.op == :change
      assert change.trip_headsign == "Hospital"
      assert change.diffs == [:times, :trip_headsign]
    end

    test "a custom 'Express' headsign is kept with :custom_headsign_moved" do
      s = main_and_short_scope("Riverside Terminal", nil)

      s = %{
        s
        | trips: [
            rich_trip("trip-1", @half_past_7,
              timed_pattern_id: "timing-main",
              trip_headsign: "Express"
            )
          ]
      }

      [change] = Plan.build([moved_row(1)], s, :replace, %{}, @stamp, []).changes

      assert change.op == :change
      assert change.trip_headsign == "Express"
      assert change.diffs == [:times]
      assert change.warnings == [:custom_headsign_moved]
    end

    test "an explicit headsign override applies without the moved warning" do
      s = main_and_short_scope("Riverside Terminal", nil)

      s = %{
        s
        | trips: [
            rich_trip("trip-1", @half_past_7,
              timed_pattern_id: "timing-main",
              trip_headsign: "Express"
            )
          ]
      }

      row = moved_row(1, %{trip_headsign: "Downtown"})
      [change] = Plan.build([row], s, :replace, %{}, @stamp, []).changes

      assert change.op == :change
      assert change.trip_headsign == "Downtown"
      assert change.diffs == [:times, :trip_headsign]
      assert change.warnings == []
    end

    test "new trips take the effective default and blanks never write empty values" do
      s = scope_h("Hospital", [], [])

      rows = [
        ready_row(1, 6 * 3600, base_rows()),
        ready_row(2, 7 * 3600, base_rows(), %{trip_headsign: "  "}),
        ready_row(3, 8 * 3600, base_rows(), %{trip_headsign: "Downtown"})
      ]

      plan = Plan.build(rows, s, :add, %{}, @stamp, [])
      assert Enum.map(plan.changes, & &1.trip_headsign) == ["Hospital", "Hospital", "Downtown"]
      assert Enum.map(plan.changes, & &1.trip_short_name) == [nil, nil, nil]
      assert Enum.map(plan.changes, & &1.block_id) == [nil, nil, nil]

      anchorless =
        Plan.build([ready_row(1, 6 * 3600, base_rows())], scope(), :add, %{}, @stamp, [])

      [change] = anchorless.changes
      assert change.trip_headsign == nil
      assert change.trip_headsign != ""
    end

    test "a retimed trip with an in-seat transfer warns; an unchanged one does not" do
      retimed_vector = [
        timing_row(0, 0),
        timing_row(400, 400, timepoint: 0),
        timing_row(800, 800)
      ]

      s =
        scope([timing("timing-1", "Typical", base_rows())], [
          rich_trip("trip-1", 6 * 3600, timed_pattern_id: "timing-1", in_seat_transfer: true),
          rich_trip("trip-2", 7 * 3600, timed_pattern_id: "timing-1", in_seat_transfer: true)
        ])

      rows = [
        ready_row(1, 6 * 3600, retimed_vector),
        ready_row(2, 7 * 3600, base_rows())
      ]

      plan = Plan.build(rows, s, :replace, %{}, @stamp, [])
      assert Enum.map(plan.changes, & &1.op) == [:change, :unchanged]
      assert Enum.map(plan.changes, & &1.warnings) == [[:in_seat_retimed], []]
    end

    test "a trip number duplicated on the calendar warns whether kept or pasted" do
      s =
        scope([timing("timing-1", "Typical", base_rows())], [
          rich_trip("trip-1", 6 * 3600, timed_pattern_id: "timing-1", trip_short_name: "1207"),
          rich_trip("trip-2", 7 * 3600, trip_short_name: "1207")
        ])

      plan =
        Plan.build([ready_row(1, 6 * 3600, base_rows())], s, :replace, %{}, @stamp, [])

      assert Enum.map(plan.changes, & &1.op) == [:unchanged, :remove]
      [kept, _removed] = plan.changes
      assert kept.trip_short_name == "1207"
      assert kept.warnings == [:duplicate_trip_number]

      existing = scope([], [rich_trip("trip-1", 6 * 3600, trip_short_name: "1207")])
      pasted = ready_row(1, 7 * 3600, base_rows(), %{trip_short_name: "1207"})
      [added] = Plan.build([pasted], existing, :add, %{}, @stamp, []).changes

      assert added.op == :add
      assert added.warnings == [:duplicate_trip_number]
    end

    test "a pairing naming a deleted trip is discarded and the row needs a decision again" do
      t1207 = rich_trip("trip-1207", @half_past_7, trip_short_name: "1207")
      t1209 = rich_trip("trip-1209", @half_past_7, trip_short_name: "1209")
      s = scope([], [t1207, t1209])
      row = ready_row(1, @half_past_7, base_rows(), %{trip_short_name: "1227"})

      plan = Plan.build([row], s, :replace, %{1 => %{pair: "trip-9999"}}, @stamp, [])
      [change] = plan.changes

      assert change.op == :needs_decision
      assert change.candidates == [t1207, t1209]

      assert plan.discarded_decisions == [
               %{row: 1, kind: :pair, value: "trip-9999", reason: :unknown_trip}
             ]
    end

    test "a pair naming a trip taken by an earlier row is superseded" do
      t1207 = rich_trip("trip-1207", @half_past_7, trip_short_name: "1207")
      t1209 = rich_trip("trip-1209", @half_past_7, trip_short_name: "1209")
      t1211 = rich_trip("trip-1211", @half_past_7, trip_short_name: "1211")
      s = scope([], [t1207, t1209, t1211])

      rows = [
        ready_row(1, @half_past_7, base_rows()),
        ready_row(2, @half_past_7, base_rows())
      ]

      decisions = %{1 => %{pair: "trip-1207"}, 2 => %{pair: "trip-1207"}}
      plan = Plan.build(rows, s, :replace, decisions, @stamp, [])
      [first, second] = plan.changes

      assert Enum.map(plan.changes, & &1.op) == [:change, :needs_decision]
      assert first.trip == t1207
      assert second.candidates == [t1209, t1211]

      assert plan.discarded_decisions == [
               %{row: 2, kind: :pair, value: "trip-1207", reason: :superseded}
             ]
    end

    test "a keep on a non-duplicate is discarded; a keep on a duplicate applies silently" do
      existing = scope([], [rich_trip("trip-7", 7 * 3600)])

      rows = [
        ready_row(1, 6 * 3600, base_rows()),
        ready_row(2, 7 * 3600, base_rows())
      ]

      plan =
        Plan.build(rows, existing, :add, %{1 => %{keep: true}, 2 => %{keep: true}}, @stamp, [])

      assert Enum.map(plan.changes, & &1.op) == [:add, :add]

      assert plan.discarded_decisions == [
               %{row: 1, kind: :keep, value: true, reason: :not_a_duplicate}
             ]
    end

    test "a pair decision in Add mode is not applicable; neither stays silent" do
      row = ready_row(1, 6 * 3600, base_rows())

      named = Plan.build([row], scope(), :add, %{1 => %{pair: "trip-1"}}, @stamp, [])
      assert Enum.map(named.changes, & &1.op) == [:add]

      assert named.discarded_decisions == [
               %{row: 1, kind: :pair, value: "trip-1", reason: :not_applicable}
             ]

      neither = Plan.build([row], scope(), :add, %{1 => %{pair: "neither"}}, @stamp, [])
      assert neither.discarded_decisions == []
    end

    test "an unknown pattern choice is discarded; a fitting chosen pattern applies" do
      s = scope([timing("timing-1", "Typical", base_rows())], [rich_trip("trip-1", 6 * 3600)])
      row = ready_row(1, 6 * 3600, base_rows())

      unknown =
        Plan.build([row], s, :replace, %{1 => %{pattern_id: "pattern-gone"}}, @stamp, [])

      assert Enum.map(unknown.changes, & &1.op) == [:change]

      assert unknown.discarded_decisions == [
               %{row: 1, kind: :pattern, value: "pattern-gone", reason: :unknown_pattern}
             ]

      chosen = %{row | how: :chosen}

      fitting =
        Plan.build([chosen], s, :replace, %{1 => %{pattern_id: @pattern_id}}, @stamp, [])

      assert Enum.map(fitting.changes, & &1.op) == [:change]
      assert fitting.discarded_decisions == []
    end

    test "a chosen pattern the row no longer fits withholds the row" do
      estimated_first = [
        %{
          arrival_offset: 0,
          departure_offset: 0,
          timepoint: 0,
          pickup_type: 0,
          drop_off_type: 0,
          stop_headsign: nil
        }
        | tl(base_rows())
      ]

      row = %{
        ready_row(1, 6 * 3600, estimated_first)
        | how: :chosen,
          key: key(estimated_first)
      }

      plan = Plan.build([row], scope(), :replace, %{1 => %{pattern_id: @pattern_id}}, @stamp, [])
      [change] = plan.changes

      assert change.op == :needs_decision
      assert change.timing == nil

      assert plan.discarded_decisions == [
               %{row: 1, kind: :pattern, value: @pattern_id, reason: :pattern_misfit}
             ]

      add_plan = Plan.build([row], scope(), :add, %{1 => %{pattern_id: @pattern_id}}, @stamp, [])
      assert Enum.map(add_plan.changes, & &1.op) == [:needs_decision]
      assert add_plan.new_timings == []
    end

    test "discarded decisions are empty for plain builds" do
      s = scope([timing("timing-1", "Typical", base_rows())], [rich_trip("trip-1", 6 * 3600)])

      assert Plan.build([ready_row(1, 6 * 3600, base_rows())], scope(), :add, %{}, @stamp, []).discarded_decisions ==
               []

      assert Plan.build([ready_row(1, 6 * 3600, base_rows())], s, :replace, %{}, @stamp, []).discarded_decisions ==
               []
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
