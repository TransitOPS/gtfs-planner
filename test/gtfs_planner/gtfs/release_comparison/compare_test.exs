defmodule GtfsPlanner.Gtfs.ReleaseComparison.CompareTest do
  @moduledoc """
  Focused evidence for CL-6/FH-6: the difference result is deterministic and
  scoped, and a total is never calculated across an unknown route or an
  incomplete representation.

  Every expected value is hand-calculated from the fixture in each test. The
  first case runs the real native exporter, the step 2 reader and the step 3
  projection before comparing, so the shape `run/3` receives is the shape a
  genuine artifact produces - including the stored primary references the native
  exporter writes into the foreign columns.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare
  alias GtfsPlanner.Gtfs.ReleaseComparison.Projection
  alias GtfsPlanner.Gtfs.ReleaseComparison.Reader

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  @agency_header ~w(agency_id agency_name agency_url agency_timezone)
  @routes_header ~w(route_id agency_id route_short_name route_long_name route_type)
  @stops_header ~w(stop_id stop_name stop_lat stop_lon)
  @trips_header ~w(route_id service_id trip_id direction_id)
  @stop_times_header ~w(trip_id arrival_time departure_time stop_id stop_sequence)
  @frequencies_header ~w(trip_id start_time end_time headway_secs exact_times)
  @calendar_header ~w(service_id monday tuesday wednesday thursday friday saturday sunday
                      start_date end_date)
  @calendar_dates_header ~w(service_id date exception_type)

  # Monday 2026-11-23 through Friday 2026-11-27, so a test chooses coverage
  # through its calendar exceptions rather than through a sparse weekly row.
  @monday ~D[2026-11-23]
  @thursday ~D[2026-11-26]
  @friday ~D[2026-11-27]
  @window %{from: @monday, to: @friday}

  setup do
    root =
      Path.join(System.tmp_dir!(), "comparison-compare-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "release_comparison",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }

    %{organization: organization, version: version, scope: scope}
  end

  describe "run/3 on a genuine native full-main artifact" do
    test "reports no difference and refuses to conclude across what the artifact cannot resolve",
         %{organization: organization, version: version, scope: scope} do
      seed_native_version!(organization, version)
      {:ok, projection} = native_projection(organization, version, scope)

      assert {:ok, result} = Compare.run(projection, projection, @window)

      # The same bytes on both sides state the same service, so there is no
      # difference to report - not one effective change and not one structural
      # change.
      assert result.effective_changes == []
      assert result.structural_changes == []

      # Nothing is concluded about the whole system. The native exporter wrote
      # stored primary references into `trips.txt`, so the trip's route does not
      # resolve and no route mapping is proven.
      assert result.totals.exact_count_delta == nil
      assert result.totals.scheduled_count_delta == nil
      assert :unmapped_route in result.totals.reasons
      assert result.completeness.status == :incomplete

      # The rows are still inspectable: five dated groups, each carrying its own
      # independent count and the reason it could not be joined.
      assert length(result.groups) == 5
      assert Enum.all?(result.groups, &(&1.reason == :unmapped_route))
      assert Enum.all?(result.groups, &(&1.comparable? == false))

      assert Enum.map(result.groups, & &1.date) == [
               @monday,
               ~D[2026-11-24],
               ~D[2026-11-25],
               @thursday,
               @friday
             ]

      assert [group | _] = result.groups
      assert group.left.scheduled_count == 1
      assert group.left.exact_count == 1

      # The artifact's own disclosures survive into the result, tagged with the
      # side they came from, and the unevaluated entities stay declared.
      assert Enum.any?(result.unknowns, &(&1.reason == :unknown_route))
      assert [:left, :right] == Enum.uniq(Enum.map(result.unknowns, & &1.side))
      assert Enum.map(result.exclusions, & &1.entity) == [:fare, :pathway, :flex]

      # The digest describes exactly this result, and describing it twice
      # describes it identically.
      assert {:ok, again} = Compare.run(projection, projection, @window)
      assert again.digest == result.digest
      assert again == result
    end
  end

  describe "effective service differences" do
    test "a holiday that removes two trips is a proven count delta of -2" do
      trips = [
        {"R1", "WEEK", "T1", "0"},
        {"R1", "HOL", "T2", "0"},
        {"R1", "HOL", "T3", "0"}
      ]

      stop_times = [
        {"T1", "08:00:00", "08:00:00", "S1", "1"},
        {"T2", "09:00:00", "09:00:00", "S1", "1"},
        {"T3", "10:00:00", "10:00:00", "S1", "1"}
      ]

      left =
        project(
          trips: trips,
          stop_times: stop_times,
          calendar: [every_weekday("WEEK"), every_weekday("HOL")]
        )

      # The candidate keeps the same trips but removes the holiday service on the
      # Thursday, so only that date changes.
      right =
        project(
          trips: trips,
          stop_times: stop_times,
          calendar: [every_weekday("WEEK"), every_weekday("HOL")],
          calendar_dates: [{"HOL", "20261126", "2"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # Every unit in the window is measured, so the totals are the hand-summed
      # window totals: three trips on Thursday become one, and no other date
      # moves.
      assert result.totals.scheduled_count_delta == -2
      assert result.totals.exact_count_delta == -2
      assert result.totals.reasons == []
      assert result.totals.total_units == 5
      assert result.totals.measured_units == 5

      # One difference, on the Thursday alone.
      assert [change] = result.effective_changes
      assert change.kind == :count_changed
      assert change.date == @thursday
      assert change.dates == [@thursday]
      assert change.route == "R1"
      assert change.route_ids == %{left: "R1", right: "R1"}

      assert change.counts == %{
               left: %{scheduled_count: 3, exact_count: 3},
               right: %{scheduled_count: 1, exact_count: 1}
             }

      # -2 occurrences, and the span's last departure falls from 10:00:00 to
      # 08:00:00 because the two later trips are the ones the holiday removes.
      assert change.delta.scheduled_count == -2
      assert change.delta.exact_count == -2
      assert change.delta.first_secs == 0
      assert change.delta.last_secs == -7_200

      # The references point at the physical rows the counts came from.
      assert change.source_refs == %{
               left: [
                 %{file: "trips.txt", row: 2},
                 %{file: "trips.txt", row: 3},
                 %{file: "trips.txt", row: 4}
               ],
               right: [%{file: "trips.txt", row: 2}]
             }

      # The calendar change itself is disclosed structurally rather than counted
      # twice, and no other date produced a difference.
      assert [dates_change, other_change] =
               Enum.filter(result.structural_changes, &(&1.change == :service_dates))

      assert Enum.map([dates_change, other_change], & &1.id) == ["T2", "T3"]
      assert dates_change.entity == :trip

      assert dates_change.left == [
               "2026-11-23",
               "2026-11-24",
               "2026-11-25",
               "2026-11-26",
               "2026-11-27"
             ]

      assert dates_change.right == ["2026-11-23", "2026-11-24", "2026-11-25", "2026-11-27"]
      refute dates_change.meaning_changed
      assert dates_change.left_ref == %{id: "T2", file: "trips.txt", row: 3}

      assert result.completeness == %{status: :complete, reasons: []}
    end

    test "renamed identifiers alone are structural churn, not service loss" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      right =
        project(
          trips: [{"R1", "WEEK", "T_RENAMED", "0"}],
          stop_times: [{"T_RENAMED", "08:00:00", "08:00:00", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # The service is identical: one departure on each of the five dates, so no
      # unit is a difference and both totals are exactly zero.
      assert result.effective_changes == []
      assert result.totals.exact_count_delta == 0
      assert result.totals.scheduled_count_delta == 0
      assert result.totals.reasons == []

      # What changed is the identifier, and it is disclosed as exactly that.
      assert [change] = result.structural_changes
      assert change.entity == :trip
      assert change.change == :identifier
      assert change.left == "T1"
      assert change.right == "T_RENAMED"
      refute change.meaning_changed
      assert change.left_ref == %{id: "T1", file: "trips.txt", row: 2}
      assert change.right_ref == %{id: "T_RENAMED", file: "trips.txt", row: 2}

      assert result.completeness == %{status: :complete, reasons: []}
    end

    test "an unmatched route identifier is structural, and its groups are never counted as loss" do
      left =
        project(
          routes: [{"R1", "AGENCY", "1", "Main", "3"}, {"R9", "AGENCY", "9", "Extra", "3"}],
          trips: [{"R1", "WEEK", "T1", "0"}, {"R9", "WEEK", "T9", "0"}],
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T9", "09:00:00", "09:00:00", "S1", "1"}
          ]
        )

      right =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # R9 exists on the left only. Its five groups stay inspectable with their
      # own counts, but an unmatched identifier is not a mapping, so nothing is
      # claimed about how much service it stood for.
      unmatched = Enum.filter(result.groups, &(&1.route_ids.left == "R9"))
      assert length(unmatched) == 5
      assert Enum.all?(unmatched, &(&1.reason == :unmapped_route))
      assert Enum.all?(unmatched, &(&1.comparable? == false))
      assert Enum.all?(unmatched, &(&1.left.exact_count == 1))
      assert Enum.all?(unmatched, &is_nil(&1.right))
      assert Enum.all?(unmatched, &(&1.delta.exact_count == nil))

      # No effective difference is claimed for them.
      assert result.effective_changes == []

      # The route is disclosed structurally, without a total.
      assert [%{entity: :route, change: :removed, id: "R9", meaning_changed: false}] =
               Enum.filter(result.structural_changes, &(&1.entity == :route))

      assert result.totals.exact_count_delta == nil
      assert result.totals.scheduled_count_delta == nil
      assert result.totals.reasons == [:unmapped_route]
      assert result.totals.total_units == 10
      assert result.totals.measured_units == 5
    end

    test "a proven route that states service on only one side is reported separately, without a delta" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}, {"R1", "EXTRA", "T2", "1"}],
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T2", "09:00:00", "09:00:00", "S1", "1"}
          ],
          calendar_dates: [{"EXTRA", "20261124", "1"}]
        )

      # The same route, without the dates-only addition. The route identity is
      # proven, and one date has a group on the left and none on the right.
      right =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      assert [change] = result.effective_changes
      assert change.kind == :removed
      assert change.route == "R1"
      assert change.direction_id == 1
      assert change.date == ~D[2026-11-24]
      assert change.counts.left.exact_count == 1
      assert change.counts.right == nil

      # Absence of a group is not evidence of no service, so no delta is claimed
      # and the window total is suppressed rather than reduced.
      assert change.delta.exact_count == nil
      assert change.reason == :one_sided_unit
      assert result.totals.exact_count_delta == nil
      assert result.totals.reasons == [:one_sided_unit]
      assert result.totals.total_units == 6
      assert result.totals.measured_units == 5
    end
  end

  describe "trip timing and frequency differences" do
    test "a ten minute shift with a safe pattern is +600 seconds over the ordered occurrence" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T1", "08:30:00", "08:30:00", "S1", "2"}
          ]
        )

      right =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [
            {"T1", "08:10:00", "08:10:00", "S1", "1"},
            {"T1", "08:40:00", "08:40:00", "S1", "2"}
          ]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      assert [change] = Enum.filter(result.effective_changes, &(&1.kind == :timing_changed))
      assert change.route == "R1"
      assert change.trips == %{left: "T1", right: "T1"}
      assert change.reason == nil

      # 08:00:00 -> 08:10:00 and 08:30:00 -> 08:40:00: 600 seconds at each
      # ordered occurrence, and nowhere else.
      assert change.delta.first_secs == 600
      assert change.delta.last_secs == 600

      assert [first, second] = change.timing
      assert first.index == 0
      assert first.left_secs == 28_800
      assert first.right_secs == 29_400
      assert first.delta_secs == 600
      assert second.index == 1
      assert second.left_secs == 30_600
      assert second.right_secs == 31_200
      assert second.delta_secs == 600

      assert change.dates == [@monday, ~D[2026-11-24], ~D[2026-11-25], @thursday, @friday]

      # The change is referenced back to the physical trip rows on both sides.
      assert change.source_refs == %{
               left: [%{file: "trips.txt", row: 2}],
               right: [%{file: "trips.txt", row: 2}]
             }

      # Counts are unaffected by a shift, so no count change is reported.
      assert Enum.all?(result.effective_changes, &(&1.kind == :timing_changed))
      assert result.totals.exact_count_delta == 0
    end

    test "different timezones prevent an aligned span conclusion" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      right =
        project(
          agency: [{"AGENCY", "Metro", "http://a.example", "America/New_York"}],
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:10:00", "08:10:00", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # The two time vectors are reported as a difference that could not be
      # aligned, with no delta claimed from them.
      assert [change] = Enum.filter(result.effective_changes, &(&1.kind == :timing_changed))
      assert change.reason == :timezone_mismatch
      assert change.timing == nil
      assert change.delta.first_secs == nil

      # The same guard applies to the route/date spans, which are still counted.
      assert Enum.all?(result.groups, &(&1.span_reason == :timezone_mismatch))
      assert Enum.all?(result.groups, &(&1.delta.first_secs == nil))
      assert Enum.all?(result.groups, &(&1.delta.exact_count == 0))
      assert result.totals.exact_count_delta == 0
    end

    test "a same-identifier stop that moved suppresses the pattern and its aligned span" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      right =
        project(
          stops: [{"S1", "First", "41.2", "-74.1"}],
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:10:00", "08:10:00", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # The stop keeps its correspondence by identical identifier, but the move
      # means the two artifacts are not describing the same ride any more.
      assert [change] = Enum.filter(result.effective_changes, &(&1.kind == :timing_changed))
      assert change.reason == :stop_meaning_changed
      assert change.timing == nil

      assert Enum.all?(result.groups, &(&1.pattern_reason == :stop_meaning_changed))
      assert Enum.all?(result.groups, &(&1.pattern_pairs == []))
      assert Enum.all?(result.groups, &(&1.delta.first_secs == nil))

      # The counts of the route and date are still compared: the route did not
      # stop running.
      assert Enum.all?(result.groups, &(&1.delta.exact_count == 0))
      assert result.totals.exact_count_delta == 0
      assert result.completeness == %{status: :incomplete, reasons: [:stop_meaning_changed]}
    end

    test "a same-identifier trip that now serves a different stop is not given an aligned delta" do
      # Every stop exists in both files and pairs by identifier, so no stop is
      # unresolved. Only the trip changed: it served S2 second and now serves S3.
      stops = [
        {"S1", "First", "40.1", "-74.1"},
        {"S2", "Second", "40.2", "-74.2"},
        {"S3", "Third", "40.3", "-74.3"}
      ]

      left =
        project(
          stops: stops,
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T1", "08:10:00", "08:10:00", "S2", "2"}
          ]
        )

      right =
        project(
          stops: stops,
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T1", "08:25:00", "08:25:00", "S3", "2"}
          ]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # The second occurrence is 08:10 at one stop and 08:25 at another, so a
      # +900 second delta would compare two different rides.
      assert [change] = Enum.filter(result.effective_changes, &(&1.kind == :timing_changed))
      assert change.reason == :trip_meaning_changed
      assert change.timing == nil

      assert change.delta == %{
               scheduled_count: nil,
               exact_count: nil,
               first_secs: nil,
               last_secs: nil
             }

      # The stop pattern change itself is disclosed as the structural change.
      assert Enum.any?(
               result.structural_changes,
               &(&1.entity == :trip and &1.change == :stop_pattern and &1.meaning_changed)
             )
    end

    test "a timing difference that cannot be read says so instead of blaming a timezone" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      # The same trip and stop, but the candidate leaves the times blank.
      right =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "", "", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      assert [change] = Enum.filter(result.effective_changes, &(&1.kind == :timing_changed))
      assert change.reason == :unreadable_times
      assert change.timing == nil
    end

    test "a span with an unreadable first time is not diffed against a known one" do
      stops = [
        {"S1", "First", "40.1", "-74.1"},
        {"S2", "Second", "40.2", "-74.2"},
        {"S3", "Third", "40.3", "-74.3"}
      ]

      left =
        project(
          stops: stops,
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [
            {"T1", "", "", "S1", "1"},
            {"T1", "08:10:00", "08:10:00", "S2", "2"},
            {"T1", "08:20:00", "08:20:00", "S3", "3"}
          ]
        )

      right =
        project(
          stops: stops,
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T1", "08:10:00", "08:10:00", "S2", "2"},
            {"T1", "08:20:00", "08:20:00", "S3", "3"}
          ]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # The earlier file's first time is unknown. Its readable extremes start at
      # 08:10, so a -600 second first-time delta would compare 08:10 with 08:00.
      assert length(result.groups) == 5
      assert Enum.all?(result.groups, &(&1.delta.first_secs == nil))
      assert Enum.all?(result.groups, &(&1.delta.last_secs == nil))

      # The counts are still compared, and still equal.
      assert Enum.all?(result.groups, &(&1.delta.exact_count == 0))
      assert result.completeness.status == :incomplete
    end

    test "twin stops in the candidate file are unresolved and keep their patterns unpaired" do
      # One stop in the earlier file; two identical stops in the candidate. Either
      # twin could be the earlier stop, so no pair is proven and no pattern through
      # them is compared, but the route's own counts still are.
      left =
        project(
          stops: [{"S1", "Twin", "40.1", "-74.1"}],
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      right =
        project(
          stops: [{"S1A", "Twin", "40.1", "-74.1"}, {"S1B", "Twin", "40.1", "-74.1"}],
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1A", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      assert Enum.all?(result.groups, &(&1.pattern_reason == :stop_ambiguous))
      assert Enum.all?(result.groups, &(&1.pattern_pairs == []))
      assert Enum.all?(result.groups, &(&1.delta.exact_count == 0))
      assert result.totals.exact_count_delta == 0

      assert result.completeness.status == :incomplete
      assert :unresolved_entity_matches in result.completeness.reasons

      # Every side of the ambiguity is disclosed: the earlier stop with its two
      # candidates, and each candidate with the stop it could be.
      stops = Enum.filter(result.unresolved, &(&1.entity == :stop))
      assert length(stops) == 3
      assert Enum.all?(stops, &(&1.reason == :ambiguous_signature))
    end

    test "a changed frequency template is a representation change, not a timing one" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      right =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [{"T1", "08:00:00", "10:00:00", "1200", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      assert [change] = Enum.filter(result.effective_changes, &(&1.kind == :frequency_changed))
      assert change.frequency_windows.left == []
      assert change.frequency_windows.right == [{28_800, 36_000, 1_200, 1}]
      assert change.timing == nil
      assert change.reason == nil
    end
  end

  describe "unknown and incomplete coverage" do
    test "a retained frequency window suppresses the whole-system totals but not the rows" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      # A non-exact template states a departure total this slice cannot prove, so
      # the candidate reports zero provable departures rather than one.
      right =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [{"T1", "08:00:00", "09:00:00", "1200", "0"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # No total is calculated across an incomplete representation, in either
      # direction: -5 departures would be the loss FH-6 describes.
      assert result.totals.exact_count_delta == nil
      assert result.totals.scheduled_count_delta == nil
      assert result.totals.reasons == [:incomplete_counts, :right_evaluation_incomplete]
      assert result.totals.measured_units == 0
      assert result.totals.total_units == 5

      # Every row is still inspectable, with both independent counts and the
      # reason they could not be joined.
      assert length(result.groups) == 5

      for group <- result.groups do
        assert group.comparable? == false
        assert group.reason == :incomplete_counts
        assert group.left.exact_count == 1
        assert group.right.exact_count == 0
        assert group.delta.exact_count == nil
      end

      # No count difference is claimed either, because the counts were never
      # comparable in the first place.
      # The retained window is itself disclosed as a representation change, and
      # no count difference is claimed from the two totals.
      assert [change] = result.effective_changes
      assert change.kind == :frequency_changed
      assert change.frequency_windows.right == [{28_800, 32_400, 1_200, 0}]
      assert Enum.all?(result.effective_changes, &(&1.kind != :count_changed))

      assert result.completeness.status == :incomplete
      assert :unmeasured_units in result.completeness.reasons
      assert :right_evaluation_incomplete in result.completeness.reasons
    end

    test "a dropped calendar exception never reads as a complete zero change" do
      trips = [{"R1", "WEEK", "T1", "0"}, {"R1", "HOL", "T2", "0"}]

      stop_times = [
        {"T1", "08:00:00", "08:00:00", "S1", "1"},
        {"T2", "09:00:00", "09:00:00", "S1", "1"}
      ]

      calendar = [every_weekday("WEEK"), every_weekday("HOL")]
      left = project(trips: trips, stop_times: stop_times, calendar: calendar)

      # The candidate means to remove the holiday service on Thursday, but its
      # exception type is unreadable, so the row is dropped and Thursday stays
      # active. Both files then state two departures on every date.
      right =
        project(
          trips: trips,
          stop_times: stop_times,
          calendar: calendar,
          calendar_dates: [{"HOL", "20261126", "x"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      assert Enum.any?(
               result.unknowns,
               &(&1.side == :right and &1.reason == :invalid_exception_type)
             )

      assert result.effective_changes == []

      # Nothing may be concluded about a file whose rows were dropped.
      assert result.totals.exact_count_delta == nil
      assert result.totals.scheduled_count_delta == nil
      assert result.totals.reasons == [:right_evaluation_incomplete]

      assert result.completeness == %{
               status: :incomplete,
               reasons: [:right_evaluation_incomplete]
             }
    end

    test "a dropped weekly calendar row keeps the lost service from reading as a complete change" do
      trips = [{"R1", "WEEK", "T1", "0"}, {"R1", "HOL", "T2", "0"}]

      stop_times = [
        {"T1", "08:00:00", "08:00:00", "S1", "1"},
        {"T2", "09:00:00", "09:00:00", "S1", "1"}
      ]

      left =
        project(
          trips: trips,
          stop_times: stop_times,
          calendar: [every_weekday("WEEK"), every_weekday("HOL")]
        )

      # The candidate's HOL weekly row has an unreadable Monday flag, so the row
      # is dropped and HOL states no date at all. WEEK still states service on
      # every date, which is why the artifact has groups to compare.
      right =
        project(
          trips: trips,
          stop_times: stop_times,
          calendar: [
            every_weekday("WEEK"),
            {"HOL", "x", "1", "1", "1", "1", "1", "1", "20260101", "20261231"}
          ]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # The five dates each lose one of two departures, and that is shown row by
      # row, but the file that lost them is not fully read.
      assert length(result.effective_changes) == 5
      assert Enum.all?(result.effective_changes, &(&1.counts.left.exact_count == 2))
      assert Enum.all?(result.effective_changes, &(&1.counts.right.exact_count == 1))
      assert result.totals.exact_count_delta == nil
      assert result.totals.reasons == [:right_evaluation_incomplete]
      assert result.completeness.status == :incomplete
      assert :right_evaluation_incomplete in result.completeness.reasons
    end

    test "unpaired trips on both sides with equal counts are not a complete no-difference" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      # Another identifier at another time on the same route, pattern and dates:
      # the trip may be the same service retimed, so nothing proves it unchanged.
      right =
        project(
          trips: [{"R1", "WEEK", "T9", "0"}],
          stop_times: [{"T9", "08:30:00", "08:30:00", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      assert result.effective_changes == []
      assert result.totals.exact_count_delta == 0
      assert Enum.map(result.unresolved, & &1.reason) == [:no_candidate, :no_candidate]
      assert result.completeness == %{status: :incomplete, reasons: [:unpaired_trips]}
    end

    test "a trip added with nothing unpaired on the other side stays a complete count change" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      right =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}, {"R1", "WEEK", "T2", "0"}],
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T2", "09:00:00", "09:00:00", "S1", "1"}
          ]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # One departure becomes two on each of five dates, and every one of them is
      # accounted for by the new trip.
      assert result.totals.exact_count_delta == 5
      assert length(result.effective_changes) == 5
      assert result.completeness == %{status: :complete, reasons: []}
    end

    test "an unmapped route keeps every count and suppresses the totals" do
      # Both artifacts name an agency that `agency.txt` does not define, so
      # neither route can be renamed onto the other and no mapping is proven -
      # exactly the shape the native exporter produces.
      left =
        project(
          routes: [{"R1", "MISSING", "1", "Main", "3"}],
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      right =
        project(
          routes: [{"R7", "MISSING", "1", "Main", "3"}],
          trips: [{"R7", "WEEK", "T7", "0"}],
          stop_times: [{"T7", "08:00:00", "08:00:00", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(left, right, @window)

      # A dangling agency reference is disclosed by the projection, and no route
      # mapping is proven, so no unit is measured and no total is produced.
      assert result.totals.exact_count_delta == nil
      assert :unmapped_route in result.totals.reasons
      assert Enum.all?(result.groups, &(&1.reason == :unmapped_route))
      assert Enum.all?(result.groups, &(&1.left.exact_count == 1))
      assert Enum.all?(result.groups, &(&1.delta.exact_count == nil))
      assert Enum.any?(result.unknowns, &(&1.reason == :unknown_agency))
    end

    test "identical fully validated bytes are a complete no-difference verdict that still declares its exclusions" do
      projection =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      assert {:ok, result} = Compare.run(projection, projection, @window)

      assert result.effective_changes == []
      assert result.structural_changes == []
      assert result.unresolved == []
      assert result.unknowns == []

      assert result.totals == %{
               exact_count_delta: 0,
               scheduled_count_delta: 0,
               reasons: [],
               measured_units: 5,
               total_units: 5
             }

      assert result.completeness == %{status: :complete, reasons: []}

      # A complete verdict is still a verdict about the service entities only.
      assert Enum.map(result.exclusions, & &1.entity) == [:fare, :pathway, :flex]
      assert Enum.all?(result.exclusions, &(&1.reason == :unsupported_table))

      assert result.artifacts == [projection.identity, projection.identity]
      assert result.window == @window
      assert byte_size(result.digest) == 64
    end

    test "missing data never yields a complete no-difference verdict" do
      # The trip names a service no calendar table describes, so the artifact
      # states no evaluable service at all.
      left =
        project(
          trips: [{"R1", "MISSING", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          calendar: [every_weekday("WEEK")]
        )

      assert {:ok, result} = Compare.run(left, left, @window)

      assert result.effective_changes == []
      assert result.totals.exact_count_delta == nil
      assert result.completeness.status == :incomplete
      assert :no_service_groups in result.completeness.reasons
      assert :left_evaluation_incomplete in result.completeness.reasons
      assert Enum.any?(result.unknowns, &(&1.reason == :unknown_service))
    end

    test "the digest changes with the result and is stable across repeated runs" do
      left =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}]
        )

      shifted =
        project(
          trips: [{"R1", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:10:00", "08:10:00", "S1", "1"}]
        )

      assert {:ok, first} = Compare.run(left, left, @window)
      assert {:ok, repeated} = Compare.run(left, left, @window)
      assert {:ok, shifted_result} = Compare.run(left, shifted, @window)
      assert {:ok, other_window} = Compare.run(left, left, %{from: @thursday, to: @friday})

      assert first.digest == repeated.digest
      refute first.digest == shifted_result.digest
      refute first.digest == other_window.digest

      # Both artifact identities are carried, so two different artifacts can
      # never share a digest by accident.
      assert [left_identity, left_identity] = first.artifacts
      assert left_identity == left.identity
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp every_weekday(service_id) do
    {service_id, "1", "1", "1", "1", "1", "1", "1", "20260101", "20261231"}
  end

  defp project(opts) do
    headers = %{
      agency: @agency_header,
      routes: @routes_header,
      stops: @stops_header,
      trips: @trips_header,
      stop_times: @stop_times_header,
      frequencies: @frequencies_header,
      calendar: @calendar_header,
      calendar_dates: @calendar_dates_header
    }

    default_rows = [
      agency: [{"AGENCY", "Metro", "http://a.example", "UTC"}],
      routes: [{"R1", "AGENCY", "1", "Main", "3"}],
      stops: [{"S1", "First", "40.1", "-74.1"}],
      trips: [{"R1", "WEEK", "T1", "0"}],
      stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
      calendar: [every_weekday("WEEK")]
    ]

    tables =
      default_rows
      |> Keyword.merge(opts)
      |> Enum.reduce(%{}, fn {name, rows}, acc ->
        Map.put(acc, "#{name}.txt", csv(Map.fetch!(headers, name), rows))
      end)

    {:ok, projection} = Projection.build(%{tables: tables, identity: identity()})
    projection
  end

  defp identity do
    %{
      run_id: Ecto.UUID.generate(),
      version_id: Ecto.UUID.generate(),
      sha256: String.duplicate("a", 64),
      size: 4_096,
      export_type: :full,
      expires_at: DateTime.utc_now(),
      estimate_missing_times: false,
      estimate_method: nil
    }
  end

  # Rows are shaped exactly as `Reader.read/2` returns them, with the physical
  # CSV row number beginning at 2, so the projection sees its real input.
  defp csv(header, rows) do
    for {data, index} <- Enum.with_index(rows, 2) do
      fields = header |> Enum.zip(Tuple.to_list(data)) |> Map.new()
      %{row: index, fields: fields}
    end
  end

  # -- native composition -----------------------------------------------------

  defp native_projection(organization, version, scope) do
    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :full)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", bytes)

    {:ok, _run} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    assert {:ok, claim} = ExportRuns.claim_download(organization.id, version.id, run.id, :main)

    assert {:ok, selection} =
             ReleaseComparison.resolve_selection(scope, %{
               "left_run_id" => run.id,
               "right_run_id" => run.id,
               "from" => "2026-11-23",
               "to" => "2026-11-27"
             })

    {:ok, reader_output} = Reader.read(claim, selection.left)
    Projection.build(reader_output)
  end

  defp seed_native_version!(organization, version) do
    agency = agency_fixture(organization.id, version.id, %{agency_id: "AGENCY"})
    route = route_fixture(organization.id, version.id, %{route_id: "R1", agency_id: agency.id})
    stop = stop_fixture(organization.id, version.id, %{stop_id: "S1"})
    calendar_fixture(organization.id, version.id, %{service_id: "WEEK"})

    trip =
      trip_fixture(organization.id, version.id, route.id, %{trip_id: "T1", service_id: "WEEK"})

    stop_time_fixture(organization.id, version.id, trip.id, stop.id, %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    })

    route
  end
end
