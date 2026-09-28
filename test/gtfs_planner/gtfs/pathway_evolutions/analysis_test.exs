defmodule GtfsPlanner.Gtfs.PathwayEvolutions.AnalysisTest do
  @moduledoc """
  Merge evidence (EV-4) for `PathwayEvolutions.analyze_closures/5`: every
  boundary in a bounded service-date horizon, and the limits that must never be
  presented as a complete answer.

  Every expectation is hand-derived from the acceptance cases and from
  PostgreSQL's timezone catalog, not from the pure `Schedule` evaluator, so the
  assertions reject a horizon computed as civil midnight, a sweep that samples
  instead of cutting at instance boundaries, and a report that softens an
  incomplete station. The instants that matter here are:

      America/New_York  2027-01-15 (EST, origin 05:00Z)  09:00 -> 14:00Z
      America/New_York  2027-03-14 (EDT date, 23 hours, origin 04:00Z)
      America/New_York  2027-04-12 (Monday, origin 04:00Z)  25:00 -> next day 05:00Z

  The `2027-03-14` origin is `04:00Z` because the service day is local noon minus
  twelve *elapsed* hours, so on a 23-hour date service time `00:00:00` is still
  `23:00` EST on the evening of `2027-03-13` and the local labels carry the
  `-18000` offset while the next day carries `-14400`. Asserting both offsets is
  what makes a repeated civil hour and a daylight-saving boundary distinguishable.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Versions

  # 2027-01-15 is a winter date: origin 05:00Z, local midnight 00:00 EST.
  @winter ~D[2027-01-15]
  # 2027-03-14 is the second Sunday of March: a 23-hour service date, origin 04:00Z.
  @spring_forward ~D[2027-03-14]
  # 2027-04-12 is a Monday, so `25:00:00-26:00:00` is Tuesday 01:00-02:00 local.
  @monday ~D[2027-04-12]

  @est_offset -18_000
  @edt_offset -14_400

  describe "analyze_closures/5 horizon" do
    test "reports a five-minute outage with its exact endpoints, labels and offsets" do
      scope = station_scope()
      assert {:ok, closure} = save_closure(scope, %{start_time: "09:00", end_time: "09:05"})

      assert {:ok, report} = analyze(scope, @winter, @winter)

      assert report.first_date == @winter
      assert report.last_date == @winter
      assert report.status == :complete
      assert report.incomplete_reasons == []
      assert report.timezone == "America/New_York"
      assert %DateTime{} = report.computed_at

      # The covered span starts at the service date's origin and runs to the next
      # one: a 09:05 window does not reach past midnight, so the horizon is a full
      # 24 elapsed hours even though the service date is a normal-length day.
      assert report.horizon_start == ~U[2027-01-15 05:00:00.000000Z]
      assert report.horizon_end == ~U[2027-01-16 05:00:00.000000Z]
      assert report.local_start == ~N[2027-01-15 00:00:00.000000]
      assert report.local_end == ~N[2027-01-16 00:00:00.000000]

      assert report.base.status == :complete
      assert report.base.incomplete_reasons == []
      assert [base_pair] = report.base.pairs
      assert base_pair.entrance_id == "ENT_1"
      assert base_pair.platform_id == "PLAT_1"
      assert base_pair.walking_to_platform
      assert base_pair.step_free_to_platform
      assert base_pair.walking_to_exit
      assert base_pair.step_free_to_exit

      # A five-minute closure is reported with exactly its own five minutes, not
      # rounded out to a sampling grid and not widened to the service date.
      assert [finding] = report.findings
      assert finding.starts_at == ~U[2027-01-15 14:00:00.000000Z]
      assert finding.ends_at == ~U[2027-01-15 14:05:00.000000Z]
      assert finding.local_start == ~N[2027-01-15 09:00:00.000000]
      assert finding.local_end == ~N[2027-01-15 09:05:00.000000]
      assert finding.start_utc_offset == @est_offset
      assert finding.end_utc_offset == @est_offset

      # The start instant is named as service-day seconds from a loaded origin, so
      # a link built from it resolves the same instant.
      assert finding.preview_target == %{date: @winter, time: 32_400}

      assert [instance] = finding.instances
      assert instance.evolution_id == closure.evolution.id
      assert instance.pathway_id == "PW_ENTRY"
      assert instance.service_id == "SVC"
      assert instance.service_date == @winter
      assert instance.start_time == 32_400
      assert instance.end_time == 32_700
      assert instance.starts_at == ~U[2027-01-15 14:00:00.000000Z]
      assert instance.ends_at == ~U[2027-01-15 14:05:00.000000Z]

      # The one bidirectional walkway is the station's only connection, so closing
      # it empties all four directions and the platform loses every step-free route.
      assert finding.comparison.lost == [
               finding("ENT_1", "PLAT_1", :step_free, :to_exit),
               finding("ENT_1", "PLAT_1", :step_free, :to_platform),
               finding("ENT_1", "PLAT_1", :walking, :to_exit),
               finding("ENT_1", "PLAT_1", :walking, :to_platform)
             ]

      assert finding.comparison.baseline_gaps == []

      assert finding.comparison.platforms_without_step_free == %{
               to_platform: ["PLAT_1"],
               to_exit: ["PLAT_1"]
             }
    end

    test "includes a 25:00:00 window on the last service date and its spill-over" do
      scope = station_scope()
      assert {:ok, closure} = save_closure(scope, %{start_time: "25:00", end_time: "26:00"})

      assert {:ok, report} = analyze(scope, @monday, @monday)

      # origin(2027-04-12) is 04:00Z. The last date's own window ends at 06:00Z the
      # next day, an hour past origin(2027-04-13) at 04:00Z, so the covered span
      # is extended past the next origin rather than ending there.
      assert report.horizon_start == ~U[2027-04-12 04:00:00.000000Z]
      assert report.horizon_end == ~U[2027-04-13 06:00:00.000000Z]
      assert report.local_start == ~N[2027-04-12 00:00:00.000000]
      assert report.local_end == ~N[2027-04-13 02:00:00.000000]

      # Two loss periods: the previous service date's window intersecting the first
      # hour of the requested date, and the requested date's own `25:00` window,
      # which is Tuesday 01:00-02:00 local and would be missed by a span that
      # stopped at the next origin.
      assert [spill_over, last_date] = report.findings

      assert spill_over.starts_at == ~U[2027-04-12 05:00:00.000000Z]
      assert spill_over.ends_at == ~U[2027-04-12 06:00:00.000000Z]
      assert [spill_over_instance] = spill_over.instances
      assert spill_over_instance.evolution_id == closure.evolution.id
      assert spill_over_instance.service_date == ~D[2027-04-11]
      assert spill_over.preview_target == %{date: ~D[2027-04-11], time: 90_000}

      assert last_date.starts_at == ~U[2027-04-13 05:00:00.000000Z]
      assert last_date.ends_at == ~U[2027-04-13 06:00:00.000000Z]
      assert [last_date_instance] = last_date.instances
      assert last_date_instance.evolution_id == closure.evolution.id
      assert last_date_instance.service_date == @monday
      assert last_date.local_start == ~N[2027-04-13 01:00:00.000000]
      assert last_date.local_end == ~N[2027-04-13 02:00:00.000000]
      assert last_date.start_utc_offset == @edt_offset
      assert last_date.end_utc_offset == @edt_offset

      # `25:00:00` is kept as elapsed service seconds from its own service date
      # rather than being reparsed as the `01:00` clock label it prints as.
      assert last_date.preview_target == %{date: @monday, time: 90_000}
    end

    test "sweeps previous-service-date spill-over and an above-24:00 window over two days" do
      scope = station_scope()
      assert {:ok, _} = save_closure(scope, %{start_time: "23:00", end_time: "26:00"})

      assert {:ok, report} = analyze(scope, @winter, ~D[2027-01-16])

      # The last requested date owns the span's end: origin(2027-01-17) is 05:00Z
      # and that date's own window ends at 07:00Z the following day.
      assert report.horizon_start == ~U[2027-01-15 05:00:00.000000Z]
      assert report.horizon_end == ~U[2027-01-17 07:00:00.000000Z]
      assert report.local_start == ~N[2027-01-15 00:00:00.000000]
      assert report.local_end == ~N[2027-01-17 02:00:00.000000]

      # One period per service date whose `23:00:00-26:00:00` window intersects
      # the span, each named by the service date that owns it. The first is
      # `2027-01-14`'s window spilling into the requested range, and `24:00:00` is
      # kept as elapsed seconds rather than becoming midnight.
      assert Enum.map(report.findings, &{&1.starts_at, &1.ends_at, &1.preview_target}) == [
               {~U[2027-01-15 05:00:00.000000Z], ~U[2027-01-15 07:00:00.000000Z],
                %{date: ~D[2027-01-14], time: 86_400}},
               {~U[2027-01-16 04:00:00.000000Z], ~U[2027-01-16 07:00:00.000000Z],
                %{date: ~D[2027-01-15], time: 82_800}},
               {~U[2027-01-17 04:00:00.000000Z], ~U[2027-01-17 07:00:00.000000Z],
                %{date: ~D[2027-01-16], time: 82_800}}
             ]

      assert Enum.map(report.findings, &length(&1.instances)) == [1, 1, 1]
    end

    test "agrees with the moment preview across the spring-forward service date" do
      scope = station_scope(calendar: daily_calendar("SVC", ~D[2027-03-01], ~D[2027-03-31]))
      assert {:ok, closure} = save_closure(scope, %{start_time: "00:00", end_time: "00:30"})

      # The origin is 04:00Z, so the preview instant is 04:15Z and the closure is
      # active there.
      assert {:ok, preview} = preview(scope, @spring_forward, 900)
      assert preview.instant == ~U[2027-03-14 04:15:00.000000Z]
      assert [closed] = preview.closed
      assert closed.evolution_id == closure.evolution.id
      assert closed.starts_at == ~U[2027-03-14 04:00:00.000000Z]
      assert closed.ends_at == ~U[2027-03-14 04:30:00.000000Z]

      # The one-day range over the same service date finds the very same period:
      # a range whose day boundary was civil midnight would miss a window that
      # starts at the origin.
      assert {:ok, report} = analyze(scope, @spring_forward, @spring_forward)
      assert report.horizon_start == ~U[2027-03-14 04:00:00.000000Z]
      assert report.horizon_end == ~U[2027-03-15 04:00:00.000000Z]

      # Both endpoints of this service date are still EST: the origin is 23:00 on
      # the evening of 2027-03-13, and the transition happens later that day.
      assert report.local_start == ~N[2027-03-13 23:00:00.000000]
      assert report.local_end == ~N[2027-03-15 00:00:00.000000]

      assert [finding] = report.findings
      assert finding.starts_at == closed.starts_at
      assert finding.ends_at == closed.ends_at
      assert finding.instances == [closed]
      assert finding.comparison == preview.comparison
      assert finding.local_start == ~N[2027-03-13 23:00:00.000000]
      assert finding.local_end == ~N[2027-03-13 23:30:00.000000]
      assert finding.start_utc_offset == @est_offset
      assert finding.end_utc_offset == @est_offset
      assert finding.preview_target == %{date: @spring_forward, time: 0}
    end

    test "keeps walking and loses step-free when the station's only elevator closes" do
      scope = elevator_scope()

      assert {:ok, _} =
               save_closure(scope, %{
                 pathway_id: "PW_ELEVATOR",
                 start_time: "09:00",
                 end_time: "09:30"
               })

      assert {:ok, report} = analyze(scope, @winter, @winter)

      assert [base_pair] = report.base.pairs
      assert base_pair.walking_to_platform
      assert base_pair.step_free_to_platform
      assert base_pair.walking_to_exit
      assert base_pair.step_free_to_exit

      # The stairs and the concourse stay open, so walking survives in both
      # directions while the step-free graph loses the only step-free edge.
      assert [finding] = report.findings
      assert finding.starts_at == ~U[2027-01-15 14:00:00.000000Z]
      assert finding.ends_at == ~U[2027-01-15 14:30:00.000000Z]

      assert finding.comparison.lost == [
               finding("ENT_1", "PLAT_1", :step_free, :to_exit),
               finding("ENT_1", "PLAT_1", :step_free, :to_platform)
             ]

      assert finding.comparison.baseline_gaps == []

      assert finding.comparison.platforms_without_step_free == %{
               to_platform: ["PLAT_1"],
               to_exit: ["PLAT_1"]
             }
    end
  end

  describe "analyze_closures/5 causes" do
    test "keeps overlapping closures closed until the last window ends" do
      scope = station_scope()
      assert {:ok, first} = save_closure(scope, %{start_time: "09:00", end_time: "11:00"})
      assert {:ok, second} = save_closure(scope, %{start_time: "10:00", end_time: "12:00"})

      assert {:ok, report} = analyze(scope, @winter, @winter)

      # The union of the two windows is one continuous outage. The period where
      # both instances are active is kept, because the active closure identities
      # changed, and no open period is reported between the three.
      assert Enum.map(report.findings, &{&1.starts_at, &1.ends_at, length(&1.instances)}) == [
               {~U[2027-01-15 14:00:00.000000Z], ~U[2027-01-15 15:00:00.000000Z], 1},
               {~U[2027-01-15 15:00:00.000000Z], ~U[2027-01-15 16:00:00.000000Z], 2},
               {~U[2027-01-15 16:00:00.000000Z], ~U[2027-01-15 17:00:00.000000Z], 1}
             ]

      assert [
               [%{evolution_id: first_period}],
               [both_first, both_second],
               [%{evolution_id: last_period}]
             ] =
               Enum.map(report.findings, & &1.instances)

      assert first_period == first.evolution.id
      assert both_first.evolution_id == first.evolution.id
      assert both_second.evolution_id == second.evolution.id
      assert last_period == second.evolution.id

      # The pathway is still closed at the end of the first window because the
      # second one covers that instant, and open again only after both end.
      assert Enum.map(report.findings, & &1.preview_target) == [
               %{date: @winter, time: 32_400},
               %{date: @winter, time: 36_000},
               %{date: @winter, time: 39_600}
             ]

      assert [_first_period, two_hours, last_period] = report.findings
      assert last_period.ends_at == ~U[2027-01-15 17:00:00.000000Z]
      assert two_hours.local_start == ~N[2027-01-15 10:00:00.000000]
      assert two_hours.local_end == ~N[2027-01-15 11:00:00.000000]
    end

    test "leaves no open gap between adjacent windows" do
      scope = station_scope()
      assert {:ok, _} = save_closure(scope, %{start_time: "09:00", end_time: "10:00"})
      assert {:ok, _} = save_closure(scope, %{start_time: "10:00", end_time: "11:00"})

      assert {:ok, report} = analyze(scope, @winter, @winter)

      # Half-open windows: the first ends at 15:00Z and the second starts there, so
      # the two reported periods meet exactly and no open minute is invented
      # between them. They stay apart because the active closure changed.
      assert Enum.map(report.findings, &{&1.starts_at, &1.ends_at}) == [
               {~U[2027-01-15 14:00:00.000000Z], ~U[2027-01-15 15:00:00.000000Z]},
               {~U[2027-01-15 15:00:00.000000Z], ~U[2027-01-15 16:00:00.000000Z]}
             ]

      assert Enum.all?(report.findings, &(&1.comparison.lost != []))
      assert contiguous?(report.findings)
    end
  end

  describe "analyze_closures/5 limits" do
    test "refuses a reversed or over-long range before loading inputs" do
      scope = station_scope()
      _closure = save_closure(scope, %{start_time: "09:00", end_time: "09:05"})

      version_id = scope.version.id

      # A reversed range and 32 requested service days are both out of bounds.
      assert analyze(scope, @winter, ~D[2027-01-14]) == {:error, :range_invalid}
      assert analyze(scope, ~D[2027-01-01], ~D[2027-02-01]) == {:error, :range_invalid}

      # The check runs before any row is read, so an unknown organization with an
      # invalid range is refused for the range rather than for the scope.
      assert Gtfs.analyze_closures(
               Ecto.UUID.generate(),
               version_id,
               "STN_1",
               @winter,
               ~D[2027-01-14]
             ) == {:error, :range_invalid}

      # 31 requested service days is inside the bound, and the same scope still
      # answers an ordinary request, so the refusals are the range and not a
      # broken scope.
      assert {:ok, longest} = analyze(scope, ~D[2027-01-01], ~D[2027-01-31])
      assert longest.first_date == ~D[2027-01-01]
      assert longest.last_date == ~D[2027-01-31]
      assert {:ok, ordinary} = analyze(scope, @winter, @winter)
      assert ordinary.status == :complete
    end

    test "refuses more than 200000 instances before building them" do
      # The candidate span stays inside the 100,000-date ceiling here, so the
      # refusal is the instance bound: a service whose window spans 71 years
      # widens the envelope to 51,909 civil dates, and five closures over it
      # describe 259,545 instances.
      scope =
        station_scope(calendar: daily_calendar("SVC", ~D[1900-01-01], ~D[2199-12-31]))

      for {start_time, end_time} <- [
            {0, 300},
            {21_600, 21_900},
            {43_200, 43_500},
            {64_800, 65_100},
            {2_147_483_617, 2_147_483_647}
          ] do
        pathway_evolution_fixture(scope.organization.id, scope.version.id, %{
          pathway_id: "PW_ENTRY",
          service_id: "SVC",
          start_time: start_time,
          end_time: end_time
        })
      end

      assert analyze(scope, @winter, @winter) == {:error, :analysis_too_large}

      # A station without those windows answers the same request, so the refusal
      # is the bound.
      ordinary = station_scope()
      assert {:ok, _} = save_closure(ordinary, %{start_time: "09:00", end_time: "09:05"})
      assert {:ok, report} = analyze(ordinary, @winter, @winter)
      assert length(report.findings) == 1
    end
  end

  describe "analyze_closures/5 status" do
    test "keeps an incomplete base incomplete with zero findings" do
      # A platform, a passage and the walkway between them, with no entrance: the
      # base evaluation has no pairs to lose, and the closure still runs.
      scope = no_entrance_scope()

      assert {:ok, _} =
               save_closure(scope, %{
                 pathway_id: "PW_LINK",
                 start_time: "09:00",
                 end_time: "10:00"
               })

      assert {:ok, report} = analyze(scope, @winter, @winter)

      assert report.base.status == :incomplete
      assert report.base.pairs == []
      assert report.status == :incomplete
      assert report.incomplete_reasons == [:no_entrances]

      # The covered span is still stated, and an empty findings list beside an
      # incomplete base is not "no connection lost".
      assert report.horizon_start == ~U[2027-01-15 05:00:00.000000Z]
      assert report.horizon_end == ~U[2027-01-16 05:00:00.000000Z]
      assert report.findings == []
    end
  end

  describe "analyze_closures/5 refusals" do
    test "refuses a missing, invalid or conflicting zone while authoring still works" do
      cases = [
        {:missing, []},
        {:invalid, [%{agency_timezone: "Not/AZone"}]},
        {:conflicting,
         [%{agency_timezone: "America/New_York"}, %{agency_timezone: "Europe/Paris"}]}
      ]

      for {reason, agencies} <- cases do
        scope =
          station_scope(
            agencies: agencies,
            calendar: daily_calendar("SVC", ~D[2027-01-01], ~D[2027-12-31])
          )

        assert analyze(scope, @winter, @winter) == {:error, {:timezone_unavailable, reason}}

        # The UTC fallback is never used for analysis, and the refusal does not
        # block authoring: the closure is still saved and audited.
        assert {:ok, mutation} = save_closure(scope, %{start_time: "09:00", end_time: "09:05"})
        assert mutation.evolution.pathway_id == "PW_ENTRY"
        assert mutation.evolution.start_time == 32_400
        assert mutation.evolution.end_time == 32_700
      end
    end

    test "returns not_found for foreign, unpublished, non-station and malformed scopes" do
      scope = station_scope()
      _closure = save_closure(scope, %{start_time: "09:00", end_time: "09:05"})

      organization_id = scope.organization.id
      version_id = scope.version.id

      # A platform is not a station, and an unknown stop does not exist.
      assert analyze_in(organization_id, version_id, "PLAT_1") == {:error, :not_found}
      assert analyze_in(organization_id, version_id, "NOPE") == {:error, :not_found}
      assert analyze_in("not-a-uuid", version_id, "STN_1") == {:error, :not_found}
      assert analyze_in(organization_id, "12345", "STN_1") == {:error, :not_found}

      # An unpublished staging version holds its own rows and stays invisible.
      {:ok, staging} = Versions.create_staging_gtfs_version(organization_id, %{name: "Staging"})
      level_fixture(organization_id, staging.id, %{level_id: "L_STREET", level_index: 0.0})

      staging_station =
        stop_fixture(organization_id, staging.id, %{stop_id: "STN_S", location_type: 1})

      pathway_fixture(organization_id, staging.id, staging_station.stop_id, "OUT_S", %{
        pathway_id: "PW_S"
      })

      assert analyze_in(organization_id, staging.id, "STN_S") == {:error, :not_found}

      # A foreign organization's version never resolves this organization's station.
      foreign_version = gtfs_version_fixture(organization_fixture().id)
      assert analyze_in(organization_id, foreign_version.id, "STN_1") == {:error, :not_found}
    end
  end

  # -- station scopes ---------------------------------------------------------

  # One station with a single bidirectional walkway between its entrance and its
  # platform, so closing that walkway empties every direction. `SVC` is a daily
  # calendar over 2027 unless another one is supplied.
  defp station_scope(opts \\ []) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    for attrs <- Keyword.get(opts, :agencies, [%{agency_timezone: "America/New_York"}]) do
      agency_fixture(organization.id, version.id, attrs)
    end

    level_fixture(organization.id, version.id, %{level_id: "L_STREET", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})
    stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

    stop_fixture(organization.id, version.id, %{
      stop_id: "ENT_1",
      location_type: 2,
      parent_station: "STN_1",
      level_id: "L_STREET"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "PLAT_1",
      location_type: 0,
      parent_station: "STN_1",
      level_id: "L_PLAT"
    })

    pathway_fixture(organization.id, version.id, "ENT_1", "PLAT_1", %{
      pathway_id: "PW_ENTRY",
      pathway_mode: 1
    })

    calendar_fixture(
      organization.id,
      version.id,
      Keyword.get(opts, :calendar, daily_calendar("SVC", ~D[2027-01-01], ~D[2027-12-31]))
    )

    scope(organization, version, actor, "STN_1", "SVC")
  end

  # The same station reached by an elevator and by stairs from the entrance to a
  # concourse node, and by a walkway from that node to the platform. Closing the
  # elevator keeps walking and loses step-free.
  defp elevator_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})
    level_fixture(organization.id, version.id, %{level_id: "L_STREET", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})
    stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

    stop_fixture(organization.id, version.id, %{
      stop_id: "ENT_1",
      location_type: 2,
      parent_station: "STN_1",
      level_id: "L_STREET"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "NODE_1",
      location_type: 3,
      parent_station: "STN_1",
      level_id: "L_STREET"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "PLAT_1",
      location_type: 0,
      parent_station: "STN_1",
      level_id: "L_PLAT"
    })

    # GTFS pathway modes: 1 walkway, 2 stairs, 5 elevator.
    pathway_fixture(organization.id, version.id, "ENT_1", "NODE_1", %{
      pathway_id: "PW_ELEVATOR",
      pathway_mode: 5
    })

    pathway_fixture(organization.id, version.id, "ENT_1", "NODE_1", %{
      pathway_id: "PW_STAIRS",
      pathway_mode: 2
    })

    pathway_fixture(organization.id, version.id, "NODE_1", "PLAT_1", %{
      pathway_id: "PW_CONCOURSE",
      pathway_mode: 1
    })

    calendar_fixture(
      organization.id,
      version.id,
      daily_calendar("SVC", ~D[2027-01-01], ~D[2027-12-31])
    )

    scope(organization, version, actor, "STN_1", "SVC")
  end

  # A station with a platform, a passage and the walkway between them, and no
  # entrance at all: the base evaluation is incomplete for want of entrances.
  defp no_entrance_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})
    level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})
    stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

    stop_fixture(organization.id, version.id, %{
      stop_id: "PLAT_1",
      location_type: 0,
      parent_station: "STN_1",
      level_id: "L_PLAT"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "NODE_1",
      location_type: 3,
      parent_station: "STN_1",
      level_id: "L_PLAT"
    })

    pathway_fixture(organization.id, version.id, "PLAT_1", "NODE_1", %{
      pathway_id: "PW_LINK",
      pathway_mode: 1
    })

    calendar_fixture(
      organization.id,
      version.id,
      daily_calendar("SVC", ~D[2027-01-01], ~D[2027-12-31])
    )

    scope(organization, version, actor, "STN_1", "SVC")
  end

  defp scope(organization, version, actor, stop_id, service_id) do
    %{
      organization: organization,
      version: version,
      service_id: service_id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: stop_id,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp daily_calendar(service_id, first, last) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1,
      start_date: first,
      end_date: last
    }
  end

  defp save_closure(scope, attrs) do
    Gtfs.create_pathway_evolution(
      Map.merge(%{pathway_id: "PW_ENTRY", service_id: scope.service_id}, attrs),
      scope.audit
    )
  end

  defp analyze(scope, first_date, last_date) do
    analyze_in(scope.organization.id, scope.version.id, "STN_1", first_date, last_date)
  end

  defp analyze_in(organization_id, gtfs_version_id, stop_id) do
    analyze_in(organization_id, gtfs_version_id, stop_id, @winter, @winter)
  end

  defp analyze_in(organization_id, gtfs_version_id, stop_id, first_date, last_date) do
    Gtfs.analyze_closures(organization_id, gtfs_version_id, stop_id, first_date, last_date)
  end

  defp preview(scope, service_date, service_time) do
    Gtfs.preview_closures(
      scope.organization.id,
      scope.version.id,
      "STN_1",
      service_date,
      service_time
    )
  end

  defp finding(entrance_id, platform_id, mode, direction) do
    %{entrance_id: entrance_id, platform_id: platform_id, mode: mode, direction: direction}
  end

  # Reported periods must meet exactly: a phantom gap would leave an instant inside
  # a continuous outage that the report never accounts for.
  defp contiguous?(findings) do
    findings
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> DateTime.compare(left.ends_at, right.starts_at) == :eq end)
  end
end
