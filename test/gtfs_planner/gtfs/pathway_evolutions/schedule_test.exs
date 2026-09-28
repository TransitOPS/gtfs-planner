defmodule GtfsPlanner.Gtfs.PathwayEvolutions.ScheduleTest do
  @moduledoc """
  Merge evidence (EV-3) for pure service-day closure evaluation:

  - A Monday `25:00:00-26:00:00` window is a Tuesday 01:00 instant, closed at its
    start and open at its end, and a `49:00:00-50:00:00` window is still found two
    service days later because the candidate envelope reaches back far enough.
  - Adjacent windows leave no open gap, an instance spanning the whole span stays
    active throughout it, and ending one of two overlapping closures does not
    reopen the pathway.
  - A spring-forward `00:00:00-00:30:00` closure and a `25:00:00-26:00:00` closure
    on the last service date both fall inside `horizon/4`, and a cause change makes
    distinct segments even when the closed pathway set does not change.
  - `preview_target/3` returns exact elapsed service seconds, keeps `25:00:00`
    instead of reparsing a clock label, and walks back to a preceding origin.

  Every expected instant is a hand-derived literal. A service-day origin is local
  noon in the agency zone minus twelve elapsed hours, so with `America/New_York` -
  EST (UTC-5) until 2027-03-14 02:00 local and EDT (UTC-4) from then on - noon on
  2027-03-13 is `17:00Z` and noon on 2027-03-14 and later is `16:00Z`:

      origin(2027-03-13) = 2027-03-13T17:00Z - 12h = 2027-03-13T05:00:00Z
      origin(2027-03-14) = 2027-03-14T16:00Z - 12h = 2027-03-14T04:00:00Z
      origin(2027-04-12) = 2027-04-12T16:00Z - 12h = 2027-04-12T04:00:00Z

  The origins are supplied to the module, so the tests state them as literals
  rather than deriving them with a library. Nothing here reads a calendar or a
  database: the active service dates are the `%{service_id => [Date.t()]}` map the
  analysis loader builds from `Calendars.ServiceDates.active_dates_between/4`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.PathwayEvolutions.Schedule

  # Hand-derived America/New_York service-day origins (see the moduledoc).
  @origin_2027_03_13 ~U[2027-03-13 05:00:00Z]
  @origin_2027_03_14 ~U[2027-03-14 04:00:00Z]
  @origin_2027_03_15 ~U[2027-03-15 04:00:00Z]
  @origin_2027_04_11 ~U[2027-04-11 04:00:00Z]
  @origin_2027_04_12 ~U[2027-04-12 04:00:00Z]
  @origin_2027_04_13 ~U[2027-04-13 04:00:00Z]
  @origin_2027_04_14 ~U[2027-04-14 04:00:00Z]
  @origin_2027_04_15 ~U[2027-04-15 04:00:00Z]

  # Service-time seconds, in GTFS form: 08:00:00, 09:00:00, 10:00:00, 11:00:00,
  # 11:30:00, 12:00:00, 00:30:00, 25:00:00, 26:00:00, 49:00:00 and 50:00:00.
  @eight_am 28_800
  @nine_am 32_400
  @ten_am 36_000
  @eleven_am 39_600
  @half_past_eleven 41_400
  @noon 43_200
  @half_hour 1_800
  @twenty_five_hours 90_000
  @twenty_six_hours 93_600
  @forty_nine_hours 176_400
  @fifty_hours 180_000

  # Closure ids are literal UUIDs so a hand-authored expectation names the exact
  # cause identity instead of a generated value.
  @ids [
    {"early", "00000000-0000-4000-8000-000000000001"},
    {"elevator", "00000000-0000-4000-8000-000000000002"},
    {"far", "00000000-0000-4000-8000-000000000003"},
    {"first", "00000000-0000-4000-8000-000000000004"},
    {"late", "00000000-0000-4000-8000-000000000005"},
    {"long", "00000000-0000-4000-8000-000000000006"},
    {"second", "00000000-0000-4000-8000-000000000007"},
    {"short", "00000000-0000-4000-8000-000000000008"},
    {"stairs", "00000000-0000-4000-8000-000000000009"}
  ]

  describe "preview_dates/3" do
    test "reaches back for a window above 24 hours and forward one service date" do
      closures = [
        closure("elevator", "PW_ELEV", "WEEKDAY", @twenty_five_hours, @fifty_hours)
      ]

      # ceil(180000/82800) = 3 dates of lookback; ceil(3600/82800) = 1 forward date.
      assert Schedule.preview_dates(closures, ~D[2027-04-14], 3_600) ==
               Date.range(~D[2027-04-11], ~D[2027-04-15])
    end

    test "keeps one lookback date and one forward date for a same-day window" do
      closures = [closure("elevator", "PW_ELEV", "WEEKDAY", @nine_am, @ten_am)]

      assert Schedule.preview_dates(closures, ~D[2027-04-12], 3_600) ==
               Date.range(~D[2027-04-11], ~D[2027-04-13])

      assert Schedule.preview_dates(closures, ~D[2027-04-12], 0) ==
               Date.range(~D[2027-04-11], ~D[2027-04-12])
    end

    test "returns the selected service date alone when there are no closures" do
      assert Schedule.preview_dates([], ~D[2027-04-12], 0) ==
               Date.range(~D[2027-04-12], ~D[2027-04-12])
    end
  end

  describe "range_dates/3" do
    test "adds the window lookback and one extra service date past the last" do
      closures = [closure("elevator", "PW_ELEV", "WEEKDAY", @nine_am, @ten_am)]

      # ceil(36000/82800) = 1: 2027-04-11 through 2027-04-16, so a 25:00:00
      # window on the last service date and the origin after it stay inside.
      assert Schedule.range_dates(closures, ~D[2027-04-12], ~D[2027-04-14]) ==
               Date.range(~D[2027-04-11], ~D[2027-04-16])
    end

    test "returns the requested range plus the next service date when there are no closures" do
      assert Schedule.range_dates([], ~D[2027-04-12], ~D[2027-04-14]) ==
               Date.range(~D[2027-04-12], ~D[2027-04-15])
    end
  end

  describe "instance_count/2" do
    test "counts one instance per active service date of the closure's own service" do
      closures = [
        closure("elevator", "PW_ELEV", "WEEKDAY", @twenty_five_hours, @twenty_six_hours),
        closure("stairs", "PW_STAIR", "WEEKEND", @nine_am, @ten_am)
      ]

      active_dates = %{
        "WEEKDAY" => [~D[2027-04-12], ~D[2027-04-13], ~D[2027-04-14]],
        "WEEKEND" => [~D[2027-04-10], ~D[2027-04-11], ~D[2027-04-17]]
      }

      assert Schedule.instance_count(closures, active_dates) == 6
    end

    test "counts nothing for a service with no active dates" do
      closures = [closure("elevator", "PW_ELEV", "WEEKDAY", @nine_am, @ten_am)]

      assert Schedule.instance_count(closures, %{"WEEKDAY" => []}) == 0
      assert Schedule.instance_count(closures, %{"OTHER" => [~D[2027-04-12]]}) == 0
    end
  end

  describe "instances/3" do
    test "expands a Monday 25:00:00 window onto Tuesday 01:00 for each active date" do
      closures = [
        closure("elevator", "PW_ELEV", "WEEKDAY", @twenty_five_hours, @twenty_six_hours)
      ]

      instances =
        Schedule.instances(closures, %{"WEEKDAY" => [~D[2027-04-12], ~D[2027-04-13]]}, %{
          ~D[2027-04-12] => @origin_2027_04_12,
          ~D[2027-04-13] => @origin_2027_04_13
        })

      assert instances == [
               expected_instance(
                 "elevator",
                 "PW_ELEV",
                 "WEEKDAY",
                 ~D[2027-04-12],
                 @twenty_five_hours,
                 @twenty_six_hours,
                 ~U[2027-04-13 05:00:00Z],
                 ~U[2027-04-13 06:00:00Z]
               ),
               expected_instance(
                 "elevator",
                 "PW_ELEV",
                 "WEEKDAY",
                 ~D[2027-04-13],
                 @twenty_five_hours,
                 @twenty_six_hours,
                 ~U[2027-04-14 05:00:00Z],
                 ~U[2027-04-14 06:00:00Z]
               )
             ]
    end

    test "skips an active service date with no loaded origin instead of inventing an instant" do
      closures = [closure("elevator", "PW_ELEV", "WEEKDAY", @nine_am, @ten_am)]
      active_dates = %{"WEEKDAY" => [~D[2027-04-12], ~D[2027-04-13]]}

      instances =
        Schedule.instances(closures, active_dates, %{~D[2027-04-12] => @origin_2027_04_12})

      assert [%{service_date: ~D[2027-04-12]}] = instances

      # The count stays the upper bound a caller checks its cap against.
      assert Schedule.instance_count(closures, active_dates) == 2
    end
  end

  describe "closed_at/2" do
    setup do
      closures = [
        closure("first", "PW_ELEV", "WEEKDAY", @nine_am, @ten_am),
        closure("second", "PW_ELEV", "WEEKDAY", @ten_am, @eleven_am)
      ]

      instances =
        Schedule.instances(closures, %{"WEEKDAY" => [~D[2027-04-12]]}, %{
          ~D[2027-04-12] => @origin_2027_04_12
        })

      %{instances: instances}
    end

    test "is closed at an instance start and open at an instance end", %{instances: instances} do
      assert [first, second] = instances

      assert Schedule.closed_at(instances, first.starts_at) |> ids() == [id("first")]
      assert Schedule.closed_at(instances, first.ends_at) |> ids() == [id("second")]
      assert Schedule.closed_at(instances, second.ends_at) == []
    end

    test "leaves no open gap where two windows meet", %{instances: instances} do
      # 10:00:00 on 2027-04-12 is both the first window's end and the second's start.
      for instant <- [
            ~U[2027-04-12 13:00:00Z],
            ~U[2027-04-12 13:59:59Z],
            ~U[2027-04-12 14:00:00Z],
            ~U[2027-04-12 14:00:01Z],
            ~U[2027-04-12 14:59:59Z]
          ] do
        assert Schedule.closed_at(instances, instant) != [],
               "the pathway is open at #{DateTime.to_iso8601(instant)}"
      end
    end

    test "keeps the pathway closed when one of two overlapping closures ends" do
      closures = [
        closure("long", "PW_ELEV", "WEEKDAY", @nine_am, @noon),
        closure("short", "PW_ELEV", "WEEKDAY", @ten_am, @eleven_am)
      ]

      instances =
        Schedule.instances(closures, %{"WEEKDAY" => [~D[2027-04-12]]}, %{
          ~D[2027-04-12] => @origin_2027_04_12
        })

      # 11:00:00 is the short window's end, where it is already open, and the
      # long window still covers the pathway.
      assert Schedule.closed_at(instances, ~U[2027-04-12 15:00:00Z]) |> ids() == [id("long")]

      assert Schedule.closed_at(instances, ~U[2027-04-12 15:00:00Z]) |> pathways() ==
               MapSet.new(["PW_ELEV"])

      # The short window is closed at its own start, alongside the long window.
      assert Schedule.closed_at(instances, ~U[2027-04-12 14:00:00Z]) |> ids() ==
               [id("long"), id("short")]
    end
  end

  describe "horizon/4" do
    test "covers a daylight-saving service date from its 04:00:00Z origin" do
      closures = [closure("early", "PW_ELEV", "WEEKEND", 0, @half_hour)]
      origins = %{~D[2027-03-14] => @origin_2027_03_14, ~D[2027-03-15] => @origin_2027_03_15}

      instances = Schedule.instances(closures, %{"WEEKEND" => [~D[2027-03-14]]}, origins)
      assert [opening] = instances

      # 00:00:00 on 2027-03-14 is 23:00 EST on 2027-03-13, so the 30-minute
      # window starts an hour before civil midnight on 2027-03-14.
      assert opening.starts_at == ~U[2027-03-14 04:00:00Z]
      assert opening.ends_at == ~U[2027-03-14 04:30:00Z]

      # The origin after the last service date is a day later than this window
      # ends, so it ends the horizon and the closure is its first closed period.
      assert Schedule.horizon(origins, instances, ~D[2027-03-14], ~D[2027-03-14]) ==
               {~U[2027-03-14 04:00:00Z], ~U[2027-03-15 04:00:00Z]}

      segments =
        Schedule.segments(instances, ~U[2027-03-14 04:00:00Z], ~U[2027-03-15 04:00:00Z])

      assert shape(segments) == [
               {"2027-03-14T04:00:00Z", "2027-03-14T04:30:00Z", ["PW_ELEV"], ["early"]},
               {"2027-03-14T04:30:00Z", "2027-03-15T04:00:00Z", [], []}
             ]

      # A midnight-based origin would have looked for this window at 05:00:00Z,
      # where it is not closed at all.
      assert Schedule.closed_at(instances, ~U[2027-03-14 05:00:00Z]) == []
    end

    test "extends past the next origin for a 25:00:00 window on the last service date" do
      closures = [
        closure("late", "PW_ELEV", "WEEKEND", @twenty_five_hours, @twenty_six_hours)
      ]

      origins = %{~D[2027-03-14] => @origin_2027_03_14, ~D[2027-03-15] => @origin_2027_03_15}

      instances = Schedule.instances(closures, %{"WEEKEND" => [~D[2027-03-14]]}, origins)
      assert [late] = instances

      # 25:00:00 on 2027-03-14 is 01:00 EDT on 2027-03-15, an hour past that
      # service date's own origin, so the horizon has to reach beyond it.
      assert late.starts_at == ~U[2027-03-15 05:00:00Z]
      assert late.ends_at == ~U[2027-03-15 06:00:00Z]

      assert Schedule.horizon(origins, instances, ~D[2027-03-14], ~D[2027-03-14]) ==
               {~U[2027-03-14 04:00:00Z], ~U[2027-03-15 06:00:00Z]}

      segments =
        Schedule.segments(instances, ~U[2027-03-14 04:00:00Z], ~U[2027-03-15 06:00:00Z])

      assert shape(segments) == [
               {"2027-03-14T04:00:00Z", "2027-03-15T05:00:00Z", [], []},
               {"2027-03-15T05:00:00Z", "2027-03-15T06:00:00Z", ["PW_ELEV"], ["late"]}
             ]
    end

    test "covers the origin after the last service date when it has no instance" do
      origins = %{~D[2027-04-12] => @origin_2027_04_12, ~D[2027-04-15] => @origin_2027_04_15}

      assert Schedule.horizon(origins, [], ~D[2027-04-12], ~D[2027-04-14]) ==
               {~U[2027-04-12 04:00:00Z], ~U[2027-04-15 04:00:00Z]}
    end

    test "refuses a range whose boundary origin was not loaded" do
      origins = %{~D[2027-04-12] => @origin_2027_04_12}

      assert_raise ArgumentError, ~r/no service-day origin loaded for 2027-04-15/, fn ->
        Schedule.horizon(origins, [], ~D[2027-04-12], ~D[2027-04-14])
      end
    end
  end

  describe "segments/3" do
    test "splits at every boundary, keeps each cause, and marks the open gap" do
      closures = [
        closure("first", "PW_ELEV", "WEEKDAY", @nine_am, @ten_am),
        closure("second", "PW_ELEV", "WEEKDAY", @ten_am, @eleven_am),
        closure("stairs", "PW_STAIR", "WEEKDAY", @half_past_eleven, @noon)
      ]

      instances =
        Schedule.instances(closures, %{"WEEKDAY" => [~D[2027-04-12]]}, %{
          ~D[2027-04-12] => @origin_2027_04_12
        })

      # 09:00-10:00, 10:00-11:00 and 11:30-12:00 local on 2027-04-12 are
      # 13:00-14:00, 14:00-15:00 and 15:30-16:00Z, with a 30-minute open gap.
      segments =
        Schedule.segments(instances, ~U[2027-04-12 13:00:00Z], ~U[2027-04-12 16:00:00Z])

      assert shape(segments) == [
               {"2027-04-12T13:00:00Z", "2027-04-12T14:00:00Z", ["PW_ELEV"], ["first"]},
               {"2027-04-12T14:00:00Z", "2027-04-12T15:00:00Z", ["PW_ELEV"], ["second"]},
               {"2027-04-12T15:00:00Z", "2027-04-12T15:30:00Z", [], []},
               {"2027-04-12T15:30:00Z", "2027-04-12T16:00:00Z", ["PW_STAIR"], ["stairs"]}
             ]
    end

    test "keeps the full instance identity on each segment" do
      closures = [
        closure("first", "PW_ELEV", "WEEKDAY", @nine_am, @ten_am),
        closure("second", "PW_ELEV", "WEEKDAY", @ten_am, @eleven_am)
      ]

      instances =
        Schedule.instances(closures, %{"WEEKDAY" => [~D[2027-04-12]]}, %{
          ~D[2027-04-12] => @origin_2027_04_12
        })

      segments =
        Schedule.segments(instances, ~U[2027-04-12 13:00:00Z], ~U[2027-04-12 15:00:00Z])

      assert [first_segment, second_segment] = segments

      assert first_segment.instances == [hd(instances)]
      assert second_segment.instances == [List.last(instances)]

      # Both segments close the same pathway and share the 14:00:00Z boundary.
      # They stay separate because the active closure identities differ.
      assert first_segment.closed_pathway_ids == second_segment.closed_pathway_ids
      assert first_segment.ends_at == second_segment.starts_at
    end

    test "keeps a cause change distinct when the closed set does not change" do
      closures = [
        closure("long", "PW_ELEV", "WEEKDAY", @nine_am, @noon),
        closure("short", "PW_ELEV", "WEEKDAY", @ten_am, @eleven_am)
      ]

      instances =
        Schedule.instances(closures, %{"WEEKDAY" => [~D[2027-04-12]]}, %{
          ~D[2027-04-12] => @origin_2027_04_12
        })

      segments =
        Schedule.segments(instances, ~U[2027-04-12 13:00:00Z], ~U[2027-04-12 16:00:00Z])

      # The first and last segments have the same closed set and the same cause,
      # but the middle segment separates them, so they are not adjacent and are
      # not merged.
      assert shape(segments) == [
               {"2027-04-12T13:00:00Z", "2027-04-12T14:00:00Z", ["PW_ELEV"], ["long"]},
               {"2027-04-12T14:00:00Z", "2027-04-12T15:00:00Z", ["PW_ELEV"], ["long", "short"]},
               {"2027-04-12T15:00:00Z", "2027-04-12T16:00:00Z", ["PW_ELEV"], ["long"]}
             ]
    end

    test "clips an instance that starts before the span and keeps it active throughout" do
      closures = [closure("long", "PW_ELEV", "WEEKDAY", @eight_am, @ten_am)]

      instances =
        Schedule.instances(closures, %{"WEEKDAY" => [~D[2027-04-12]]}, %{
          ~D[2027-04-12] => @origin_2027_04_12
        })

      assert [long] = instances

      # 08:00-10:00 local is 12:00-14:00Z, so the span starts inside the instance.
      assert long.starts_at == ~U[2027-04-12 12:00:00Z]
      assert long.ends_at == ~U[2027-04-12 14:00:00Z]

      segments =
        Schedule.segments(instances, ~U[2027-04-12 13:00:00Z], ~U[2027-04-12 13:30:00Z])

      assert shape(segments) == [
               {"2027-04-12T13:00:00Z", "2027-04-12T13:30:00Z", ["PW_ELEV"], ["long"]}
             ]
    end

    test "has no segments for an empty or reversed span" do
      closures = [closure("first", "PW_ELEV", "WEEKDAY", @nine_am, @ten_am)]

      instances =
        Schedule.instances(closures, %{"WEEKDAY" => [~D[2027-04-12]]}, %{
          ~D[2027-04-12] => @origin_2027_04_12
        })

      assert Schedule.segments(
               instances,
               ~U[2027-04-12 13:00:00Z],
               ~U[2027-04-12 13:00:00Z]
             ) == []

      assert Schedule.segments(
               instances,
               ~U[2027-04-12 15:00:00Z],
               ~U[2027-04-12 13:00:00Z]
             ) == []
    end

    test "returns one open segment for a span with no closures" do
      segments = Schedule.segments([], ~U[2027-04-12 04:00:00Z], ~U[2027-04-13 04:00:00Z])

      assert shape(segments) == [{"2027-04-12T04:00:00Z", "2027-04-13T04:00:00Z", [], []}]
    end
  end

  describe "preview_target/3" do
    test "keeps exact service seconds on the preferred service date" do
      origins = %{~D[2027-04-12] => @origin_2027_04_12, ~D[2027-04-13] => @origin_2027_04_13}

      # A 25:00:00-26:00:00 window on 2027-04-12 offers before, closes, during
      # and reopens instants that fall on the next civil day; all four keep
      # service time rather than a reparsed clock label.
      assert Schedule.preview_target(~U[2027-04-13 04:59:00Z], ~D[2027-04-12], origins) ==
               %{date: ~D[2027-04-12], time: 89_940}

      assert Schedule.preview_target(~U[2027-04-13 05:00:00Z], ~D[2027-04-12], origins) ==
               %{date: ~D[2027-04-12], time: 90_000}

      assert Schedule.preview_target(~U[2027-04-13 05:30:00Z], ~D[2027-04-12], origins) ==
               %{date: ~D[2027-04-12], time: 91_800}

      assert Schedule.preview_target(~U[2027-04-13 06:00:00Z], ~D[2027-04-12], origins) ==
               %{date: ~D[2027-04-12], time: 93_600}
    end

    test "resolves a spring-forward service day against its 04:00:00Z origin" do
      origins = %{~D[2027-03-14] => @origin_2027_03_14, ~D[2027-03-15] => @origin_2027_03_15}

      # 00:30:00 on 2027-03-14 is 04:30:00Z, an hour after civil midnight.
      assert Schedule.preview_target(~U[2027-03-14 04:30:00Z], ~D[2027-03-14], origins) ==
               %{date: ~D[2027-03-14], time: 1_800}
    end

    test "walks back to a preceding origin for a target before its own origin" do
      origins = %{
        ~D[2027-03-13] => @origin_2027_03_13,
        ~D[2027-03-14] => @origin_2027_03_14
      }

      # 22:00 EST on 2027-03-13 is 03:00:00Z, before the 2027-03-14 origin, so it
      # belongs to 2027-03-13 as 22:00:00 of service time.
      assert Schedule.preview_target(~U[2027-03-14 03:00:00Z], ~D[2027-03-14], origins) ==
               %{date: ~D[2027-03-13], time: 79_200}
    end

    test "uses the latest loaded origin when the preferred service date is absent" do
      origins = %{
        ~D[2027-04-13] => @origin_2027_04_13,
        ~D[2027-04-14] => @origin_2027_04_14,
        ~D[2027-04-15] => @origin_2027_04_15
      }

      assert Schedule.preview_target(~U[2027-04-14 04:30:00Z], ~D[2027-04-20], origins) ==
               %{date: ~D[2027-04-14], time: 1_800}
    end

    test "refuses a target that precedes every loaded origin" do
      origins = %{~D[2027-04-14] => @origin_2027_04_14}

      assert_raise ArgumentError,
                   ~r/no service-day origin at or before 2027-01-01T00:00:00Z/,
                   fn ->
                     Schedule.preview_target(~U[2027-01-01 00:00:00Z], ~D[2027-01-01], origins)
                   end
    end
  end

  describe "a 49:00:00-50:00:00 window" do
    test "is still discoverable from a preview two service days later" do
      closures = [closure("far", "PW_ELEV", "WEEKDAY", @forty_nine_hours, @fifty_hours)]

      service_dates = [
        ~D[2027-04-11],
        ~D[2027-04-12],
        ~D[2027-04-13],
        ~D[2027-04-14],
        ~D[2027-04-15]
      ]

      active_dates = %{"WEEKDAY" => service_dates}

      assert Enum.to_list(Schedule.preview_dates(closures, ~D[2027-04-14], 3_600)) ==
               service_dates

      origins = %{
        ~D[2027-04-11] => @origin_2027_04_11,
        ~D[2027-04-12] => @origin_2027_04_12,
        ~D[2027-04-13] => @origin_2027_04_13,
        ~D[2027-04-14] => @origin_2027_04_14,
        ~D[2027-04-15] => @origin_2027_04_15
      }

      instances = Schedule.instances(closures, active_dates, origins)

      assert Schedule.instance_count(closures, active_dates) == length(instances)

      # 01:00:00 on 2027-04-14 is 2027-04-14T05:00:00Z, which is 49:00:00 of
      # service time on Monday 2027-04-12 - two service days earlier.
      assert Schedule.closed_at(instances, ~U[2027-04-14 05:00:00Z]) |> dates() ==
               [~D[2027-04-12]]

      assert instances
             |> Enum.find(&(&1.service_date == ~D[2027-04-12]))
             |> Map.take([
               :starts_at,
               :ends_at
             ]) == %{starts_at: ~U[2027-04-14 05:00:00Z], ends_at: ~U[2027-04-14 06:00:00Z]}
    end
  end

  defp closure(label, pathway_id, service_id, start_time, end_time) do
    %PathwayEvolution{
      id: id(label),
      pathway_id: pathway_id,
      service_id: service_id,
      start_time: start_time,
      end_time: end_time
    }
  end

  defp expected_instance(
         label,
         pathway_id,
         service_id,
         service_date,
         start_time,
         end_time,
         starts_at,
         ends_at
       ) do
    %{
      evolution_id: id(label),
      pathway_id: pathway_id,
      service_id: service_id,
      service_date: service_date,
      start_time: start_time,
      end_time: end_time,
      starts_at: starts_at,
      ends_at: ends_at
    }
  end

  defp id(label) do
    {_label, value} = Enum.find(@ids, &match?({^label, _value}, &1))

    value
  end

  defp label(value) do
    Enum.find_value(@ids, fn
      {name, ^value} -> name
      _other -> nil
    end)
  end

  defp ids(instances), do: Enum.map(instances, & &1.evolution_id)
  defp dates(instances), do: Enum.map(instances, & &1.service_date)
  defp pathways(instances), do: MapSet.new(instances, & &1.pathway_id)

  defp shape(segments) do
    Enum.map(segments, fn segment ->
      closed = segment.closed_pathway_ids |> MapSet.to_list() |> Enum.sort()
      causes = segment.instances |> ids() |> Enum.map(&label/1)

      {DateTime.to_iso8601(segment.starts_at), DateTime.to_iso8601(segment.ends_at), closed,
       causes}
    end)
  end
end
