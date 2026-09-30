defmodule GtfsPlanner.Gtfs.PatternComparisonTest do
  @moduledoc """
  Merge evidence (EV-7) for CL-7, CL-8, CL-10, CL-11 and CL-12: `compare/2`
  composes the scoped comparison read with defaults, timing scoping, usage,
  alignment and suggestions, and establishes INV-1's timing scoping for the
  compare page while preserving INV-2 (nothing is written) and INV-5 (end to end
  comes from the read).

  Every expected row, segment, count and end-to-end figure is hand-derived from
  the literal fixture offsets below, not from the implementation or the
  prototype engine. The focused gate command is deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner/gtfs/pattern_comparison_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.PatternComparison
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    other_route = route_fixture(organization.id, version.id)

    stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "s1",
        stop_name: "One",
        stop_lat: Decimal.new("44.0"),
        stop_lon: Decimal.new("-124.0")
      })

    # `stop_code` is an importer-only field that no changeset casts, so the
    # fixture cannot set it; the comparison read still has to project it.
    stop
    |> change(stop_code: "S1C")
    |> Repo.update!()

    Enum.each(~w(s2 s3 s4 s5 s6 x y z), fn stop_id ->
      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: String.upcase(stop_id)
      })
    end)

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAY"})

    # A: S1-S2-S3-S4-S5-S6. B: S1-S2-X-Y-S4-S5-S6 replaces S3 with X and Y and
    # runs the replaced stretch 30 seconds faster.
    a =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "pattern_a",
        route_pattern_name: "Full A",
        direction_id: 0,
        timing_name: "Base A",
        stops: [
          {"s1", 0, 0, 1},
          {"s2", 120, 120, 1},
          {"s3", 240, 240, 1},
          {"s4", 360, 360, 1},
          {"s5", 480, 480, 1},
          {"s6", 600, 600, 1}
        ]
      })

    b =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "pattern_b",
        route_pattern_name: "Replacement B",
        direction_id: 0,
        route_pattern_sort_order: 1,
        timing_name: "Base B",
        stops: [
          {"s1", 0, 0, 1},
          {"s2", 120, 120, 1},
          {"x", 180, 180, 1},
          {"y", 240, 240, 1},
          {"s4", 330, 330, 1},
          {"s5", 450, 450, 1},
          {"s6", 570, 570, 1}
        ]
      })

    other_route_b =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: other_route.route_id,
        route_pattern_id: "pattern_route_b",
        route_pattern_name: "Other route B",
        direction_id: 0,
        timing_name: "Other route base",
        stops: [
          {"s1", 0, 0, 1},
          {"s2", 100, 100, 1},
          {"s3", 200, 200, 1},
          {"s4", 300, 300, 1},
          {"s5", 400, 400, 1},
          {"s6", 500, 500, 1}
        ]
      })

    %{
      scope: %{organization_id: organization.id, gtfs_version_id: version.id},
      organization: organization,
      version: version,
      route: route,
      other_route: other_route,
      a: a,
      b: b,
      other_route_b: other_route_b
    }
  end

  test "composes the replacement comparison with literal rows, segments and end to end",
       context do
    assert {:ok, result} = compare(context, %{a: "pattern_a", b: "pattern_b"})

    assert result.route.route_id == context.route.route_id
    assert result.b_error == nil
    assert result.service_id == "WEEKDAY"

    assert result.calendars == [
             %{
               service_id: "WEEKDAY",
               name: "WEEKDAY",
               trips: %{"pattern_a" => 0, "pattern_b" => 0}
             }
           ]

    assert result.a.pattern.route_pattern_id == "pattern_a"
    assert result.a.route.route_id == context.route.route_id
    assert result.a.stops == ~w(s1 s2 s3 s4 s5 s6)
    assert result.a.timing_id == context.a.timing.id
    assert result.a.usage.total == 0

    assert Enum.map(result.a.rows, &{&1.position, &1.arrival_offset, &1.departure_offset}) == [
             {1, 0, 0},
             {2, 120, 120},
             {3, 240, 240},
             {4, 360, 360},
             {5, 480, 480},
             {6, 600, 600}
           ]

    assert result.b.pattern.route_pattern_id == "pattern_b"
    assert result.b.route.route_id == context.route.route_id
    assert result.b.stops == ~w(s1 s2 x y s4 s5 s6)
    assert result.b.timing_id == context.b.timing.id

    alignment = result.alignment

    assert shape(alignment.rows) == [
             {:same, 1, 1, "s1"},
             {:same, 2, 2, "s2"},
             {:a, 3, nil, "s3"},
             {:b, nil, 3, "x"},
             {:b, nil, 4, "y"},
             {:same, 4, 5, "s4"},
             {:same, 5, 6, "s5"},
             {:same, 6, 7, "s6"}
           ]

    assert alignment.counts == %{shared: 5, a_only: 1, b_only: 2, moved: 0}

    assert alignment.segments == [
             %{from: 0, to: 1, a_secs: 120, b_secs: 120, diff: 0, same_stops?: true},
             %{from: 1, to: 5, a_secs: 240, b_secs: 210, diff: -30, same_stops?: false},
             %{from: 5, to: 6, a_secs: 120, b_secs: 120, diff: 0, same_stops?: true},
             %{from: 6, to: 7, a_secs: 120, b_secs: 120, diff: 0, same_stops?: true}
           ]

    assert alignment.untimed == MapSet.new()
    assert alignment.waits == %{}

    assert [item] = alignment.differences.items
    assert item.kind == :stops
    assert item.rows == [2, 3, 4]
    assert item.frame == [1, 2, 3, 4, 5]
    assert item.detail.before == "s2"
    assert item.detail.after == "s4"
    assert item.detail.a_only == ["s3"]
    assert item.detail.b_only == ["x", "y"]

    assert item.detail.segment ==
             %{from: 1, to: 5, a_secs: 240, b_secs: 210, diff: -30, same_stops?: false}

    assert alignment.differences.smaller_timing == 0
    refute alignment.identical?
    refute alignment.opposite?
    refute alignment.reversed?

    assert alignment.end_a == 600
    assert alignment.end_b == 570
    assert alignment.end_change == -30
    assert alignment.end_percent == -5

    assert result.stops_by_id["s1"] == %{
             stop_id: "s1",
             stop_name: "One",
             stop_code: "S1C",
             stop_lat: Decimal.new("44.0"),
             stop_lon: Decimal.new("-124.0"),
             timepoint?: true
           }

    assert result.stops_by_id["x"].timepoint?
    refute Map.has_key?(result.stops_by_id, "z")
    assert result.suggestions == []
  end

  test "loads a B on another published route of the version with that route", context do
    assert {:ok, result} = compare(context, %{a: "pattern_a", b: "pattern_route_b"})

    assert result.route.route_id == context.route.route_id
    assert result.b.pattern.route_pattern_id == "pattern_route_b"
    assert result.b.route.route_id == context.other_route.route_id
    assert result.b.route.route_id != result.route.route_id
    assert result.b.stops == ~w(s1 s2 s3 s4 s5 s6)
    assert result.b_error == nil

    assert result.alignment.identical?
    assert result.alignment.counts == %{shared: 6, a_only: 0, b_only: 0, moved: 0}
    assert result.alignment.end_a == 600
    assert result.alignment.end_b == 500
    assert result.alignment.end_change == -100
    assert result.alignment.end_percent == -17
  end

  test "reports a b of another organization as not found with no B reads", context do
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_route = route_fixture(foreign_organization.id, foreign_version.id)

    schedule_pattern_fixture(foreign_organization.id, foreign_version.id, %{
      route_id: foreign_route.route_id,
      route_pattern_id: "pattern_foreign",
      stops: [{"foreign_stop", 0, 0, 1}]
    })

    assert {:ok, result} = compare(context, %{a: "pattern_a", b: "pattern_foreign"})

    assert result.b == nil
    assert result.b_error == {:not_found, "pattern_foreign"}
    assert result.alignment == nil
    assert result.a.pattern.route_pattern_id == "pattern_a"
    assert result.a.stops == ~w(s1 s2 s3 s4 s5 s6)
    refute Map.has_key?(result.stops_by_id, "foreign_stop")
  end

  test "reports a b of another version as not found with no B reads", context do
    other_version = gtfs_version_fixture(context.organization.id)
    other_version_route = route_fixture(context.organization.id, other_version.id)

    schedule_pattern_fixture(context.organization.id, other_version.id, %{
      route_id: other_version_route.route_id,
      route_pattern_id: "pattern_other_version",
      stops: [{"other_version_stop", 0, 0, 1}]
    })

    assert {:ok, result} = compare(context, %{a: "pattern_a", b: "pattern_other_version"})

    assert result.b == nil
    assert result.b_error == {:not_found, "pattern_other_version"}
    assert result.alignment == nil
    refute Map.has_key?(result.stops_by_id, "other_version_stop")
  end

  test "reports a b on an unpublished version as not found with no B reads", context do
    {:ok, staging} =
      Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

    staging_route = route_fixture(context.organization.id, staging.id)

    schedule_pattern_fixture(context.organization.id, staging.id, %{
      route_id: staging_route.route_id,
      route_pattern_id: "pattern_staging",
      stops: [{"staging_stop", 0, 0, 1}]
    })

    assert {:ok, result} = compare(context, %{a: "pattern_a", b: "pattern_staging"})

    assert result.b == nil
    assert result.b_error == {:not_found, "pattern_staging"}
    assert result.alignment == nil
    refute Map.has_key?(result.stops_by_id, "staging_stop")
  end

  test "returns not found for an a outside the URL route", context do
    assert {:error, :not_found} = compare(context, %{a: "pattern_route_b"})
    assert {:error, :not_found} = compare(context, %{a: "pattern_missing"})

    assert {:error, :not_found} =
             PatternComparison.compare(context.scope, %{route_id: "route_missing", a: "pattern_a"})
  end

  test "falls back to B's default timing when tb names another pattern's timing", context do
    peak = timed_pattern_fixture(context.b.pattern, %{name: "Peak B"})

    other_pattern =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_c",
        timing_name: "Foreign timing",
        stops: [{"s2", 0, 0, 1}]
      })

    assert {:ok, result} =
             compare(context, %{a: "pattern_a", b: "pattern_b", tb: other_pattern.timing.id})

    assert result.b.timing_id == context.b.timing.id
    assert Enum.map(result.b.rows, & &1.stop_id) == ~w(s1 s2 x y s4 s5 s6)

    assert {:ok, foreign_result} =
             compare(context, %{
               a: "pattern_a",
               b: "pattern_b",
               ta: other_pattern.timing.id,
               tb: other_pattern.timing.id
             })

    assert foreign_result.a.timing_id == context.a.timing.id
    assert foreign_result.b.timing_id == context.b.timing.id

    assert {:ok, own_result} = compare(context, %{a: "pattern_a", b: "pattern_b", tb: peak.id})
    assert own_result.b.timing_id == peak.id
  end

  test "falls back to the default timing when tb names a timing of another organization",
       context do
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_route = route_fixture(foreign_organization.id, foreign_version.id)

    foreign_pattern =
      schedule_pattern_fixture(foreign_organization.id, foreign_version.id, %{
        route_id: foreign_route.route_id,
        route_pattern_id: "pattern_foreign_timing",
        timing_name: "Foreign org timing",
        stops: [{"foreign_timing_stop", 0, 0, 1}]
      })

    assert {:ok, result} =
             compare(context, %{a: "pattern_a", b: "pattern_b", tb: foreign_pattern.timing.id})

    assert result.b.timing_id == context.b.timing.id
    assert Enum.map(result.b.rows, & &1.stop_id) == ~w(s1 s2 x y s4 s5 s6)
  end

  test "an unknown service falls back to the calendar with the most A and B trips", context do
    calendar_fixture(context.organization.id, context.version.id, %{service_id: "SATURDAY"})

    # A alone is busiest on WEEKDAY (2 against 1); A and B together are busiest
    # on SATURDAY (4 against 2), so the fallback must choose SATURDAY.
    linked_trip(context, "pattern_a", context.a.timing, "WEEKDAY")
    linked_trip(context, "pattern_a", context.a.timing, "WEEKDAY")
    linked_trip(context, "pattern_a", context.a.timing, "SATURDAY")
    linked_trip(context, "pattern_b", context.b.timing, "SATURDAY")
    linked_trip(context, "pattern_b", context.b.timing, "SATURDAY")
    linked_trip(context, "pattern_b", context.b.timing, "SATURDAY")

    assert {:ok, result} = compare(context, %{a: "pattern_a", b: "pattern_b", service: "UNKNOWN"})

    assert result.service_id == "SATURDAY"

    assert result.calendars == [
             %{
               service_id: "SATURDAY",
               name: "SATURDAY",
               trips: %{"pattern_a" => 1, "pattern_b" => 3}
             },
             %{
               service_id: "WEEKDAY",
               name: "WEEKDAY",
               trips: %{"pattern_a" => 2, "pattern_b" => 0}
             }
           ]

    assert result.a.usage.total == 1
    assert result.b.usage.total == 3

    assert {:ok, explicit} =
             compare(context, %{a: "pattern_a", b: "pattern_b", service: "WEEKDAY"})

    assert explicit.service_id == "WEEKDAY"
    assert explicit.a.usage.total == 2
    assert explicit.b.usage.total == 0
  end

  test "a B without timings has nil rows, no segments and no end to end", context do
    plain =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_plain",
        route_pattern_name: "No times",
        direction_id: 0,
        route_pattern_sort_order: 2
      })

    route_pattern_stop_fixture(plain, "s1", 1)
    route_pattern_stop_fixture(plain, "s2", 2)

    assert {:ok, result} = compare(context, %{a: "pattern_a", b: "pattern_plain"})

    assert result.b.timing_id == nil
    assert result.b.rows == nil
    assert result.b.timings == []

    assert shape(result.alignment.rows) == [
             {:same, 1, 1, "s1"},
             {:same, 2, 2, "s2"},
             {:a, 3, nil, "s3"},
             {:a, 4, nil, "s4"},
             {:a, 5, nil, "s5"},
             {:a, 6, nil, "s6"}
           ]

    assert result.alignment.segments == []
    assert result.alignment.untimed == MapSet.new()
    assert result.alignment.waits == %{}
    assert result.alignment.end_a == 600
    assert result.alignment.end_b == nil
    assert result.alignment.end_change == nil
    assert result.alignment.end_percent == nil
  end

  test "an A without timings has nil rows, no segments and no end to end", context do
    plain =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_plain_a",
        route_pattern_name: "No times A",
        direction_id: 0
      })

    route_pattern_stop_fixture(plain, "s1", 1)
    route_pattern_stop_fixture(plain, "s2", 2)

    assert {:ok, result} = compare(context, %{a: "pattern_plain_a", b: "pattern_a"})

    assert result.a.timing_id == nil
    assert result.a.rows == nil
    assert result.alignment.segments == []
    assert result.alignment.untimed == MapSet.new()
    assert result.alignment.waits == %{}
    assert result.alignment.end_a == nil
    assert result.alignment.end_b == 600
    assert result.alignment.end_change == nil
    assert result.alignment.end_percent == nil
  end

  test "reverse aligns against B's reversed stops and hides running times", context do
    schedule_pattern_fixture(context.organization.id, context.version.id, %{
      route_id: context.route.route_id,
      route_pattern_id: "pattern_reverse",
      route_pattern_name: "Inbound",
      direction_id: 1,
      timing_name: "Inbound base",
      stops: [
        {"s6", 0, 0, 1},
        {"s5", 120, 120, 1},
        {"s4", 240, 240, 1},
        {"s3", 360, 360, 1},
        {"s2", 480, 480, 1},
        {"s1", 600, 600, 1}
      ]
    })

    assert {:ok, forward} = compare(context, %{a: "pattern_a", b: "pattern_reverse"})

    assert forward.alignment.opposite?
    refute forward.alignment.reversed?

    assert {:ok, result} =
             compare(context, %{a: "pattern_a", b: "pattern_reverse", reverse: true})

    assert result.alignment.reversed?
    refute result.alignment.opposite?
    refute result.alignment.identical?

    # B's positions count down from its length: reversing [s6..s1] lines every
    # stop up with A, so the rows are A's order and `b_pos` counts up the
    # reversed list (B's own stop 1, s6, is the reversed list's last entry).
    assert result.b.stops == ~w(s6 s5 s4 s3 s2 s1)

    assert shape(result.alignment.rows) == [
             {:same, 1, 1, "s1"},
             {:same, 2, 2, "s2"},
             {:same, 3, 3, "s3"},
             {:same, 4, 4, "s4"},
             {:same, 5, 5, "s5"},
             {:same, 6, 6, "s6"}
           ]

    assert Enum.map(result.alignment.rows, &(7 - &1.b_pos)) == [6, 5, 4, 3, 2, 1]

    assert result.alignment.counts == %{shared: 6, a_only: 0, b_only: 0, moved: 0}
    assert result.alignment.segments == []
    assert result.alignment.untimed == MapSet.new()
    assert result.alignment.waits == %{}
    assert result.alignment.end_a == nil
    assert result.alignment.end_b == nil
    assert result.alignment.end_change == nil
    assert result.alignment.end_percent == nil
  end

  test "b absent suggests up to three same-direction patterns by trips then stops in common",
       context do
    calendar_fixture(context.organization.id, context.version.id, %{service_id: "SATURDAY"})

    high =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_high",
        route_pattern_name: "High trips",
        direction_id: 0,
        timing_name: "High base",
        stops: [{"s1", 0, 0, 1}, {"s2", 60, 60, 1}, {"s3", 120, 120, 1}]
      })

    shared =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_shared",
        route_pattern_name: "More shared",
        direction_id: 0,
        timing_name: "Shared base",
        stops: [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 1},
          {"s4", 180, 180, 1},
          {"s5", 240, 240, 1},
          {"s6", 300, 300, 1},
          {"z", 360, 360, 1}
        ]
      })

    tie_more =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_tie_more",
        route_pattern_name: "Tie more shared",
        direction_id: 0,
        timing_name: "Tie more base",
        stops: [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 1},
          {"s4", 180, 180, 1},
          {"s5", 240, 240, 1}
        ]
      })

    tie_less =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_tie_less",
        route_pattern_name: "Tie less shared",
        direction_id: 0,
        timing_name: "Tie less base",
        stops: [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 1},
          {"s4", 180, 180, 1}
        ]
      })

    identical =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_identical",
        route_pattern_name: "Identical list",
        direction_id: 0,
        timing_name: "Identical base",
        stops: [
          {"s1", 0, 0, 1},
          {"s2", 60, 60, 1},
          {"s3", 120, 120, 1},
          {"s4", 180, 180, 1},
          {"s5", 240, 240, 1},
          {"s6", 300, 300, 1}
        ]
      })

    other_direction =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_other_direction",
        route_pattern_name: "Other direction",
        direction_id: 1,
        timing_name: "Other direction base",
        stops: [{"s1", 0, 0, 1}, {"s2", 60, 60, 1}, {"s3", 120, 120, 1}]
      })

    linked_trips(context, "pattern_a", context.a.timing, "WEEKDAY", 2)
    linked_trips(context, "pattern_high", high.timing, "WEEKDAY", 6)
    linked_trips(context, "pattern_shared", shared.timing, "WEEKDAY", 5)
    # Nine SATURDAY trips must not outrank the five WEEKDAY trips: suggestions
    # count the chosen calendar, not every calendar.
    linked_trips(context, "pattern_shared", shared.timing, "SATURDAY", 9)
    linked_trips(context, "pattern_tie_more", tie_more.timing, "WEEKDAY", 4)
    linked_trips(context, "pattern_tie_less", tie_less.timing, "WEEKDAY", 4)
    # The busiest pattern of the route must stay out of the list: its stop list
    # is identical to A's.
    linked_trips(context, "pattern_identical", identical.timing, "WEEKDAY", 10)
    linked_trips(context, "pattern_other_direction", other_direction.timing, "WEEKDAY", 20)

    assert {:ok, result} = compare(context, %{a: "pattern_a"})

    assert result.b == nil
    assert result.alignment == nil
    assert result.b_error == nil
    assert result.service_id == "WEEKDAY"
    assert result.a.usage.total == 2

    # A's own stops only: suggestions add no stop to the result.
    assert result.stops_by_id |> Map.keys() |> Enum.sort() == ~w(s1 s2 s3 s4 s5 s6)

    assert Enum.map(result.suggestions, & &1.route_pattern_id) == [
             "pattern_high",
             "pattern_shared",
             "pattern_tie_more"
           ]

    assert Enum.map(result.suggestions, & &1.name) == [
             "High trips",
             "More shared",
             "Tie more shared"
           ]

    assert Enum.map(result.suggestions, & &1.shared) == [3, 6, 5]
    assert Enum.map(result.suggestions, & &1.trips) == [6, 5, 4]

    suggested = Enum.map(result.suggestions, & &1.route_pattern_id)

    refute "pattern_identical" in suggested
    refute "pattern_other_direction" in suggested
    refute "pattern_tie_less" in suggested
    refute "pattern_route_b" in suggested
  end

  defp compare(context, params) do
    PatternComparison.compare(
      context.scope,
      Map.merge(
        %{
          route_id: context.route.route_id,
          a: nil,
          b: nil,
          service: nil,
          ta: nil,
          tb: nil,
          reverse: false
        },
        params
      )
    )
  end

  defp linked_trips(context, route_pattern_id, timing, service_id, count) do
    Enum.each(1..count, fn _ -> linked_trip(context, route_pattern_id, timing, service_id) end)
  end

  defp linked_trip(context, route_pattern_id, %TimedPattern{} = timing, service_id) do
    trip =
      trip_fixture(context.organization.id, context.version.id, context.route.route_id, %{
        service_id: service_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })
  end

  defp shape(rows) do
    Enum.map(rows, &{&1.type, &1.a_pos, &1.b_pos, &1.stop_id})
  end
end
