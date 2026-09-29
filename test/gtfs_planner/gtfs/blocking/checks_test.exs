defmodule GtfsPlanner.Gtfs.Blocking.ChecksTest do
  @moduledoc """
  Merge evidence (EV-3) for the pure block checks:

  - A nested block returns every overlapping pair, A-B, A-C and B-C.
  - The validator's exact-equality exemption holds at different stops, and a pair
    is reported when the earlier trip's last arrival is before the later trip's
    first departure and its last departure is after it.
  - Touching trips (`last_departure` equal to the next `first_arrival`) are not
    reported.
  - Times above 86,400 seconds compare as stored, and a 25:10 trip sequences after
    a 05:00 trip.
  - With a 5-minute minimum, 4- and 0-minute gaps warn, a 5-minute gap does not,
    and a negative gap yields no layover or move finding.
  - Handoffs are the same stop, the same non-empty parent station, nearby within
    200 m without a notice, an empty move beyond 200 m, or unknown coordinates,
    and use the parent station's coordinates a stop reference carries for a stop
    that has none of its own.
  - A frequency-based trip yields one `:frequency_trip` notice and no overlap; an
    unplottable trip yields one `:unplottable` notice and leaves the sequence.
  - `finding_key/1` is equal for a pair listed in either order.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/checks_test.exs`. Every expected value
  is derived from R4/R5's examples, from fixed coordinates measured outside this
  module, or from hand-written integer clock seconds; trip rows are built by the
  local helper and no string is parsed. The module reads no database, clock, files
  or network.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.{Checks, Context}

  # One origin point and two points north of it. The great-circle formula with a
  # 6,371,000 m earth radius gives 120.0905 m and 340.034 m, so `handoff/2` reports
  # exactly 120 and 340 meters.
  @origin_lat 42.0
  @origin_lon -71.0
  @near_lat 42.00108
  @far_lat 42.003058

  describe "sequence/1" do
    test "leaves out frequency-based and unplottable trips" do
      scheduled = trip("s", at(8, 0), at(9, 0))
      frequency = trip("f", at(8, 30), at(9, 30), frequency?: true, headway_secs: 1200)
      unplottable = trip("u", nil, nil)

      assert Checks.sequence([unplottable, frequency, scheduled]) == [scheduled]
    end

    test "orders a 25:10 trip after a 05:00 trip" do
      early = trip("early", at(5, 0), at(6, 0))
      night = trip("night", at(24, 30), at(25, 10))

      assert Enum.map(Checks.sequence([night, early]), & &1.id) == ["early", "night"]
    end
  end

  describe "overlap_pairs/1" do
    test "returns every pair of a nested block" do
      a = trip("a", at(8, 0), at(10, 0))
      b = trip("b", at(8, 10), at(9, 50))
      c = trip("c", at(9, 0), at(9, 10))

      pairs = Checks.overlap_pairs(Checks.sequence([c, a, b]))

      assert pair_ids(pairs) == [{"a", "b"}, {"a", "c"}, {"b", "c"}]
    end

    test "exempts an exact-equality handoff at different stops" do
      earlier =
        trip("earlier", at(8, 0), at(9, 5),
          last_arrival: at(9, 0),
          last_stop: stop("A", lat: @origin_lat, lon: @origin_lon)
        )

      later =
        trip("later", at(9, 5), at(10, 0),
          first_arrival: at(9, 0),
          first_stop: stop("B", lat: @far_lat, lon: @origin_lon)
        )

      assert Checks.handoff(earlier.last_stop, later.first_stop) == {:moves, 340}
      assert Checks.overlap_pairs(Checks.sequence([earlier, later])) == []
    end

    test "reports a pair when the earlier trip's last arrival is before the later trip's first departure" do
      earlier = trip("earlier", at(8, 0), at(9, 0))
      later = trip("later", at(9, 0), at(10, 0), first_arrival: at(8, 55))

      assert pair_ids(Checks.overlap_pairs(Checks.sequence([earlier, later]))) == [
               {"earlier", "later"}
             ]
    end

    test "does not report touching trips" do
      earlier = trip("earlier", at(8, 0), at(9, 0), last_arrival: at(8, 55))
      later = trip("later", at(9, 5), at(10, 0), first_arrival: at(9, 0))

      assert Checks.overlap_pairs(Checks.sequence([earlier, later])) == []
    end

    test "compares times after midnight" do
      earlier = trip("earlier", at(24, 30), at(25, 10))
      later = trip("later", at(25, 0), at(25, 30))

      assert pair_ids(Checks.overlap_pairs(Checks.sequence([earlier, later]))) == [
               {"earlier", "later"}
             ]
    end
  end

  describe "gaps/1" do
    test "returns each consecutive pair's gap and handoff" do
      main = stop("A", lat: @origin_lat, lon: @origin_lon)
      junction = stop("B", lat: @origin_lat, lon: @origin_lon)
      far = stop("C", lat: @far_lat, lon: @origin_lon)

      first = trip("first", at(8, 0), at(9, 0), last_stop: main)
      second = trip("second", at(9, 12), at(10, 12), first_stop: main, last_stop: junction)
      third = trip("third", at(10, 30), at(11, 30), first_stop: far)

      assert Checks.gaps(Checks.sequence([first, second, third])) == [
               %{from_id: "first", to_id: "second", gap_secs: 720, handoff: :same_stop},
               %{from_id: "second", to_id: "third", gap_secs: 1080, handoff: {:moves, 340}}
             ]
    end
  end

  describe "handoff/2" do
    test "returns :same_stop for one stop" do
      assert Checks.handoff(stop("A"), stop("A")) == :same_stop
    end

    test "returns :same_station for two stops sharing a non-empty parent" do
      from = stop("A1", parent_station: "P", lat: @origin_lat, lon: @origin_lon)
      to = stop("A2", parent_station: "P", lat: @far_lat, lon: @origin_lon)

      assert Checks.handoff(from, to) == :same_station
    end

    test "treats two stops without a parent station as different places" do
      from = stop("A", lat: @origin_lat, lon: @origin_lon)
      to = stop("B", lat: @near_lat, lon: @origin_lon)

      assert Checks.handoff(from, to) == {:nearby, 120}
    end

    test "returns {:moves, 340} for stops beyond 200 meters" do
      from = stop("A", lat: @origin_lat, lon: @origin_lon)
      to = stop("B", lat: @far_lat, lon: @origin_lon)

      assert Checks.handoff(from, to) == {:moves, 340}
    end

    test "returns {:moves, nil} when a stop has no coordinates" do
      from = stop("A", lat: @origin_lat, lon: @origin_lon)

      assert Checks.handoff(from, stop("B")) == {:moves, nil}
    end

    test "uses the coordinates a stop reference carries from its parent station" do
      # `Queries.trip_rows/3` substitutes the parent station's coordinates for a
      # stop that has none of its own, so these two stops arrive positioned by
      # their parents 120 m apart.
      from = parent_coordinates_ref("A1", stop("P", lat: @origin_lat, lon: @origin_lon))
      to = parent_coordinates_ref("B1", stop("Q", lat: @near_lat, lon: @origin_lon))

      assert Checks.handoff(from, to) == {:nearby, 120}
    end
  end

  describe "block_findings/3" do
    test "reports an overlap error with the overlap seconds" do
      a = trip("a", at(8, 0), at(10, 0))
      b = trip("b", at(8, 10), at(9, 50))

      assert Checks.block_findings("101", [a, b], Context.layover_only(5)) == [
               %{
                 code: :overlap,
                 severity: :error,
                 block_id: "101",
                 trip_ids: ["a", "b"],
                 transfer_id: nil,
                 detail: %{overlap_secs: 6000}
               }
             ]
    end

    test "warns for a gap below the minimum layover" do
      main = stop("A", lat: @origin_lat, lon: @origin_lon)
      a = trip("a", at(7, 0), at(8, 0), last_stop: main)
      b = trip("b", at(8, 4), at(9, 0), first_arrival: at(8, 0), first_stop: main)

      assert Checks.block_findings("101", [a, b], Context.layover_only(5)) == [
               %{
                 code: :short_layover,
                 severity: :warning,
                 block_id: "101",
                 trip_ids: ["a", "b"],
                 transfer_id: nil,
                 detail: %{gap_secs: 240}
               }
             ]
    end

    test "warns for a zero-minute gap" do
      main = stop("A", lat: @origin_lat, lon: @origin_lon)
      a = trip("a", at(7, 0), at(8, 0), last_stop: main)
      b = trip("b", at(8, 0), at(9, 0), first_stop: main)

      assert [%{code: :short_layover, severity: :warning, detail: %{gap_secs: 0}}] =
               Checks.block_findings("101", [a, b], Context.layover_only(5))
    end

    test "does not warn at exactly the minimum layover" do
      main = stop("A", lat: @origin_lat, lon: @origin_lon)
      a = trip("a", at(7, 0), at(8, 0), last_stop: main)
      b = trip("b", at(8, 5), at(9, 5), first_arrival: at(8, 0), first_stop: main)

      assert Checks.block_findings("101", [a, b], Context.layover_only(5)) == []
    end

    test "reports no layover or move for a negative gap" do
      a =
        trip("a", at(7, 0), at(8, 0), last_stop: stop("A", lat: @origin_lat, lon: @origin_lon))

      b =
        trip("b", at(8, 0), at(9, 0),
          first_arrival: at(7, 56),
          first_departure: at(7, 56),
          first_stop: stop("B", lat: @far_lat, lon: @origin_lon)
        )

      assert Enum.map(Checks.block_findings("101", [a, b], Context.layover_only(5)), & &1.code) ==
               [:overlap]
    end

    test "reports an empty move as a notice with the gap and the distance" do
      a =
        trip("a", at(7, 0), at(8, 0), last_stop: stop("A", lat: @origin_lat, lon: @origin_lon))

      b =
        trip("b", at(8, 12), at(9, 12),
          first_arrival: at(8, 0),
          first_stop: stop("B", lat: @far_lat, lon: @origin_lon)
        )

      assert Checks.block_findings("101", [a, b], Context.layover_only(5)) == [
               %{
                 code: :repositions,
                 severity: :notice,
                 block_id: "101",
                 trip_ids: ["a", "b"],
                 transfer_id: nil,
                 detail: %{gap_secs: 720, meters: 340}
               }
             ]
    end

    test "does not report a nearby handoff as an empty move" do
      a =
        trip("a", at(7, 0), at(8, 0), last_stop: stop("A", lat: @origin_lat, lon: @origin_lon))

      b =
        trip("b", at(8, 12), at(9, 12),
          first_arrival: at(8, 0),
          first_stop: stop("B", lat: @near_lat, lon: @origin_lon)
        )

      assert Checks.block_findings("101", [a, b], Context.layover_only(5)) == []
    end

    test "reports missing coordinates as an empty move with no distance" do
      a =
        trip("a", at(7, 0), at(8, 0), last_stop: stop("A", lat: @origin_lat, lon: @origin_lon))

      b = trip("b", at(8, 12), at(9, 12), first_arrival: at(8, 0), first_stop: stop("B"))

      assert [%{code: :repositions, severity: :notice, detail: %{gap_secs: 720, meters: nil}}] =
               Checks.block_findings("101", [a, b], Context.layover_only(5))
    end

    test "reports a frequency-based trip once and no overlap" do
      scheduled = trip("s", at(8, 0), at(10, 0))
      frequency = trip("f", at(8, 30), at(9, 30), frequency?: true, headway_secs: 1200)

      assert Checks.block_findings("101", [scheduled, frequency], Context.layover_only(5)) == [
               %{
                 code: :frequency_trip,
                 severity: :notice,
                 block_id: "101",
                 trip_ids: ["f"],
                 transfer_id: nil,
                 detail: %{headway_secs: 1200}
               }
             ]
    end

    test "reports an unplottable trip once" do
      scheduled = trip("s", at(8, 0), at(10, 0))
      unplottable = trip("u", nil, nil)

      assert Checks.block_findings("101", [scheduled, unplottable], Context.layover_only(5)) == [
               %{
                 code: :unplottable,
                 severity: :notice,
                 block_id: "101",
                 trip_ids: ["u"],
                 transfer_id: nil,
                 detail: %{}
               }
             ]
    end
  end

  describe "finding_key/1" do
    test "is equal for a pair listed in either order" do
      a = trip("a", at(8, 0), at(10, 0))
      b = trip("b", at(8, 10), at(9, 50))

      [overlap] = Checks.block_findings("101", [a, b], Context.layover_only(5))

      assert Checks.finding_key(overlap) == {:overlap, ["a", "b"], nil}

      assert Checks.finding_key(%{overlap | trip_ids: ["b", "a"]}) ==
               Checks.finding_key(overlap)
    end
  end

  # Integer seconds, never parsed from a string (CR-3).
  defp at(hours, minutes), do: hours * 3600 + minutes * 60

  defp trip(id, from_secs, to_secs, opts \\ []) do
    %{
      id: id,
      trip_id: Keyword.get(opts, :trip_id, id),
      route_id: "R1",
      service_id: "W",
      block_id: Keyword.get(opts, :block_id, "101"),
      trip_headsign: nil,
      route_pattern_id: nil,
      updated_at: ~U[2026-01-01 00:00:00Z],
      frequency?: Keyword.get(opts, :frequency?, false),
      headway_secs: Keyword.get(opts, :headway_secs),
      first_arrival: Keyword.get(opts, :first_arrival, from_secs),
      first_departure: Keyword.get(opts, :first_departure, from_secs),
      last_arrival: Keyword.get(opts, :last_arrival, to_secs),
      last_departure: Keyword.get(opts, :last_departure, to_secs),
      first_stop: Keyword.get(opts, :first_stop),
      last_stop: Keyword.get(opts, :last_stop),
      plottable?: Keyword.get(opts, :plottable?, is_integer(from_secs) and is_integer(to_secs))
    }
  end

  defp stop(stop_id, opts \\ []) do
    %{
      stop_id: stop_id,
      name: Keyword.get(opts, :name, stop_id),
      parent_station: Keyword.get(opts, :parent_station),
      lat: Keyword.get(opts, :lat),
      lon: Keyword.get(opts, :lon)
    }
  end

  # The reference `Queries.trip_rows/3` builds for a stop without coordinates of
  # its own and with a parent station that has some.
  defp parent_coordinates_ref(stop_id, parent) do
    stop(stop_id, parent_station: parent.stop_id, lat: parent.lat, lon: parent.lon)
  end

  defp pair_ids(pairs), do: Enum.map(pairs, fn {earlier, later} -> {earlier.id, later.id} end)
end
