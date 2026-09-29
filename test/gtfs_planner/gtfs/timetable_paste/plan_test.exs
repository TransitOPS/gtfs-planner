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

    test "replace mode raises instead of half-building" do
      assert_raise ArgumentError, ~r/does not implement mode :replace/, fn ->
        Plan.build([], scope(), :replace, %{}, @stamp, [])
      end
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
