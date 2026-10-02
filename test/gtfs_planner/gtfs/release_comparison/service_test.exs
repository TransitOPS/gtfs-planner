defmodule GtfsPlanner.Gtfs.ReleaseComparison.ServiceTest do
  @moduledoc """
  Focused evidence for CL-5/FH-5: effective service uses calendar additions and
  removals, overnight service-day seconds and separate exact and non-exact
  frequency representation within explicit bounds.

  Expected values are hand-calculated from the fixture text in each test. The
  first case runs the real native exporter, the step 2 reader and the step 3
  projection before this evaluation, so the shape later steps receive is the
  shape they will actually be handed.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.Projection
  alias GtfsPlanner.Gtfs.ReleaseComparison.Reader
  alias GtfsPlanner.Gtfs.ReleaseComparison.Service

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

  # Every weekday of a 2026 window, so a test chooses coverage through its
  # exceptions rather than through a sparse weekly row.
  @every_weekday {"WEEK", "1", "1", "1", "1", "1", "1", "1", "20260101", "20261231"}

  # Monday 2026-11-23 through Friday 2026-11-27.
  @monday ~D[2026-11-23]
  @thursday ~D[2026-11-26]
  @friday ~D[2026-11-27]

  setup do
    root =
      Path.join(System.tmp_dir!(), "comparison-service-#{System.unique_integer([:positive])}")

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

  describe "evaluate/3 on a native full-main artifact" do
    test "evaluates the real exported rows and reports what the artifact cannot resolve",
         context do
      %{organization: organization, version: version, scope: scope} = context
      seed_native_version!(organization, version)
      {claim, identity} = claim_native!(organization, version, scope)

      assert {:ok, reader_output} = Reader.read(claim, identity)
      assert {:ok, projection} = Projection.build(reader_output)
      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @friday)

      # The evaluation reads the selected bytes only: the window is bounded to
      # the five requested days and the artifact describes one weekly service.
      assert evaluation.from == @monday
      assert evaluation.to == @friday

      assert [trip] = evaluation.evaluated_trips
      assert trip.service_dates == [@monday, ~D[2026-11-24], ~D[2026-11-25], @thursday, @friday]

      # The native exporter wrote a stored route reference into `trips.txt`, so
      # this artifact's groups carry no resolvable timezone and the unresolved
      # route is disclosed instead of being repaired.
      assert Enum.map(evaluation.groups, & &1.date) == [
               @monday,
               ~D[2026-11-24],
               ~D[2026-11-25],
               @thursday,
               @friday
             ]

      assert [group | _] = evaluation.groups
      assert group.timezone == nil
      assert group.route_id == trip.route_id
      assert group.scheduled_count == 1
      assert group.exact_count == 1

      # `stop_times.txt` groups under the stored trip reference it names, which
      # is that same UUID rather than the `trips.txt` identifier, so this trip
      # has no ordered occurrences. Its dates and its one departure are still
      # counted; only the span is suppressed.
      assert group.pattern == []
      assert group.first_secs == nil
      refute group.span_complete?
      assert group.count_complete?

      assert Enum.any?(evaluation.unknowns, &(&1.reason == :unknown_route))

      # Nothing here is a claim of aligned timing or of a complete comparison.
      refute evaluation.complete?
    end

    test "evaluates only the requested dates and never reads the live version", context do
      %{organization: organization, version: version, scope: scope} = context
      seed_native_version!(organization, version)

      other_version = gtfs_version_fixture(organization.id)
      other_agency = agency_fixture(organization.id, other_version.id, %{agency_id: "OTHER"})
      calendar_fixture(organization.id, other_version.id, %{service_id: "LIVE_ONLY"})

      route_fixture(organization.id, other_version.id, %{
        route_id: "R_LIVE",
        agency_id: other_agency.id
      })

      {claim, identity} = claim_native!(organization, version, scope)
      assert {:ok, reader_output} = Reader.read(claim, identity)
      assert {:ok, projection} = Projection.build(reader_output)

      # A single-day window inside the weekly service bounds the answer.
      assert {:ok, evaluation} = Service.evaluate(projection, @thursday, @thursday)
      assert [trip] = evaluation.evaluated_trips
      assert trip.service_dates == [@thursday]
      assert Enum.map(evaluation.groups, & &1.date) == [@thursday]

      # A window before the service begins yields no group at all rather than a
      # group claiming zero service.
      assert {:ok, empty} = Service.evaluate(projection, ~D[2025-12-29], ~D[2025-12-31])
      assert empty.groups == []
      refute empty.complete?
    end
  end

  describe "effective service dates" do
    test "a Thursday removal empties the weekly service while a dates-only addition fills it" do
      projection =
        project(
          trips: [
            {"R1", "WEEK", "T_WEEK", "0"},
            {"R1", "DATES", "T_DATES", "1"}
          ],
          stop_times: [
            {"T_WEEK", "08:00:00", "08:00:00", "S1", "1"},
            {"T_DATES", "09:00:00", "09:00:00", "S1", "1"}
          ],
          calendar: [@every_weekday],
          calendar_dates: [{"WEEK", "20261126", "2"}, {"DATES", "20261126", "1"}]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @friday)

      # The two trips differ in direction, so they are two groups even on one
      # route, one pattern and one date.
      weekly = Enum.filter(evaluation.groups, &(&1.direction_id == 0))
      dates_only = Enum.filter(evaluation.groups, &(&1.direction_id == 1))

      assert Enum.map(weekly, & &1.date) == [@monday, ~D[2026-11-24], ~D[2026-11-25], @friday]
      assert Enum.map(dates_only, & &1.date) == [@thursday]

      assert [weekly_trip, dates_trip] = Enum.sort_by(evaluation.evaluated_trips, & &1.trip_id)
      assert weekly_trip.trip_id == "T_DATES"
      assert weekly_trip.service_dates == [@thursday]
      assert dates_trip.trip_id == "T_WEEK"
      assert dates_trip.service_dates == [@monday, ~D[2026-11-24], ~D[2026-11-25], @friday]

      # The window is fully described, so this evaluation is complete.
      assert evaluation.unknowns == []
      assert evaluation.complete?
    end

    test "a malformed exception outside the query window still makes the service unknown" do
      projection =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          calendar: [@every_weekday]
        )

      # The projection refuses to project an unsupported exception type, so this
      # is what a caller that skipped the projection would hand the evaluation.
      # The exception sits outside the window and must still be validated.
      contradictory =
        Map.update!(projection, :exceptions, fn exceptions ->
          Map.put(exceptions, "WEEK", [
            exception(~D[2026-11-26], 2, 2),
            exception(~D[2026-11-26], 1, 3)
          ])
        end)

      assert {:ok, evaluation} = Service.evaluate(contradictory, @monday, ~D[2026-11-25])

      # The service yields no dates at all rather than an empty schedule that
      # would read as lost service.
      assert evaluation.groups == []
      assert [trip] = evaluation.evaluated_trips
      assert trip.service_dates == []

      assert Enum.any?(evaluation.unknowns, fn entry ->
               entry.entity == :service and
                 entry.entity_id == "WEEK" and
                 entry.reason == :unevaluable_service
             end)

      refute evaluation.complete?
    end

    test "a service no calendar table describes is unknown, not a service with no dates" do
      projection =
        project(
          trips: [{"R1", "UNDEFINED", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          calendar: [@every_weekday]
        )

      # The projection is what discloses the gap: the trip is indexed and its
      # service is named, so no artifact row can be mistaken for a described one.
      assert Map.has_key?(projection.calendars, "UNDEFINED")
      assert Enum.any?(projection.unknowns, &(&1.reason == :unknown_service))

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @friday)

      # A nil calendar with no exceptions is the native dates-only service, which
      # has no date here and therefore no group - never an empty group claiming
      # that the service lost every trip.
      assert evaluation.groups == []
      assert [trip] = evaluation.evaluated_trips
      assert trip.service_dates == []
    end

    test "raises for a window that ends before it starts" do
      projection = project(stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}])

      assert_raise ArgumentError, ~r/ends before it starts/, fn ->
        Service.evaluate(projection, @friday, @monday)
      end
    end
  end

  describe "service-day seconds" do
    test "25:10:00 stays 90,600 on its service date and a loop keeps sequences 1 and 9" do
      projection =
        project(
          stops: [{"S1", "Loop stop", "40.1", "-74.1"}],
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T1", "25:10:00", "25:10:00", "S1", "9"}
          ]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      assert group.first_secs == 28_800
      # The overnight value is service-day seconds on the same service date, not
      # a civil time on the next day: it is never reduced modulo 24 hours.
      assert group.last_secs == 90_600
      assert GtfsTime.format(group.last_secs) == "25:10:00"

      # The loop keeps both occurrences distinct by sequence.
      assert group.pattern == [
               %{stop_id: "S1", sequence: 1},
               %{stop_id: "S1", sequence: 9}
             ]

      assert [trip] = evaluation.evaluated_trips
      assert trip.time_vector == [{28_800, 28_800}, {90_600, 90_600}]
      assert trip.pattern == group.pattern
    end

    test "a frequency window past midnight keeps its service-day seconds" do
      projection =
        project(
          stop_times: [{"T1", "25:10:00", "25:10:00", "S1", "1"}],
          frequencies: [{"T1", "25:10:00", "25:50:00", "1200", "1"}]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      # 25:10:00 and 25:30:00 are the departures; 25:50:00 is excluded because
      # the window end is exclusive.
      assert group.exact_count == 2
      assert group.first_secs == 90_600
      assert group.last_secs == 90_600 + 1_200
      assert GtfsTime.format(group.first_secs) == "25:10:00"
      assert GtfsTime.format(group.last_secs) == "25:30:00"
    end
  end

  describe "exact and non-exact frequency representation" do
    test "an exact 08:00-09:00 window every 20 minutes gives 08:00, 08:20 and 08:40" do
      projection =
        project(
          stop_times: [
            {"T1", "08:00:00", "08:00:00", "S1", "1"},
            {"T1", "08:30:00", "08:30:00", "S2", "2"}
          ],
          stops: [{"S1", "First", "40.1", "-74.1"}, {"S2", "Second", "41.1", "-75.1"}],
          frequencies: [{"T1", "08:00:00", "09:00:00", "1200", "1"}]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      assert group.scheduled_count == 3
      assert group.exact_count == 3

      # The first stop's departures are 08:00:00, 08:20:00 and 08:40:00. The
      # exclusive end 09:00:00 is not a departure.
      assert Enum.map([group.first_secs, 30_000, 31_200], &GtfsTime.format/1) ==
               ["08:00:00", "08:20:00", "08:40:00"]

      # The second stop is 30 minutes after the first, so the group's span runs
      # from the earliest first-stop departure to the last departure's arrival at
      # the second stop: 08:40:00 + 00:30:00 = 09:10:00.
      assert group.first_secs == 28_800
      assert group.last_secs == 33_000
      assert GtfsTime.format(group.last_secs) == "09:10:00"

      # The second stop's times are each departure plus its own offset from the
      # first stop, so the group's span covers the whole trip.
      assert group.span_complete?
      assert group.count_complete?
      assert group.frequency_windows == []

      assert [trip] = evaluation.evaluated_trips
      assert [%{exact_times: 1, start_secs: 28_800, end_secs: 32_400}] = trip.frequencies
      assert evaluation.complete?
    end

    test "a non-exact window is retained and contributes no exact count" do
      projection =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [{"T1", "08:00:00", "09:00:00", "1200", "0"}]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      # The template is never counted as one trip, and its departure total is
      # not invented either: the group claims no count and says so.
      assert group.scheduled_count == 0
      assert group.exact_count == 0
      refute group.count_complete?
      refute group.span_complete?
      assert group.first_secs == nil
      assert group.last_secs == nil

      assert [
               %{
                 trip_id: "T1",
                 start_secs: 28_800,
                 end_secs: 32_400,
                 headway_secs: 1_200,
                 exact_times: 0,
                 source: %{file: "frequencies.txt", row: 2}
               }
             ] = group.frequency_windows

      refute evaluation.complete?
    end

    test "a blank exact_times is the GTFS default of 0 and stays a window" do
      projection =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [{"T1", "08:00:00", "09:00:00", "1200", ""}]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      assert [%{exact_times: 0}] = group.frequency_windows
      assert group.exact_count == 0
      refute group.count_complete?
    end
  end

  describe "unusable input" do
    test "overlapping windows are unknown and the earlier window still counts" do
      projection =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [
            {"T1", "08:00:00", "09:00:00", "1200", "1"},
            {"T1", "08:30:00", "10:00:00", "1200", "1"}
          ]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      assert group.exact_count == 3

      # The overlapping window contributes no departures and the group's total
      # is therefore not the whole service.
      refute group.count_complete?

      assert Enum.any?(evaluation.unknowns, fn entry ->
               entry.reason == :overlapping_frequency_windows and
                 entry.source == %{file: "frequencies.txt", row: 3}
             end)
    end

    test "touching windows do not overlap" do
      projection =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [
            {"T1", "08:00:00", "09:00:00", "1200", "1"},
            {"T1", "09:00:00", "10:00:00", "1200", "1"}
          ]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      assert group.exact_count == 6
      assert group.count_complete?
      assert evaluation.unknowns == []
    end

    test "an unreadable first-stop time makes every window unusable" do
      projection =
        project(
          stop_times: [
            {"T1", "not-a-time", "not-a-time", "S1", "1"},
            {"T1", "08:30:00", "08:30:00", "S2", "2"}
          ],
          stops: [{"S1", "First", "40.1", "-74.1"}, {"S2", "Second", "41.1", "-75.1"}],
          frequencies: [{"T1", "08:00:00", "09:00:00", "1200", "1"}]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      assert group.exact_count == 0
      refute group.count_complete?
      refute group.span_complete?

      assert Enum.any?(evaluation.unknowns, &(&1.reason == :unusable_frequency_anchor))
    end

    test "an unusable headway, reversed window or unsupported exact_times is unknown" do
      projection =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [
            {"T1", "08:00:00", "09:00:00", "0", "1"},
            {"T1", "09:00:00", "09:00:00", "1200", "1"},
            {"T1", "10:00:00", "11:00:00", "1200", "maybe"},
            {"T1", "nope", "11:00:00", "1200", "1"}
          ]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      assert group.exact_count == 0

      reasons =
        evaluation.unknowns
        |> Enum.map(&{&1.source.row, &1.reason})
        |> Enum.sort()

      assert reasons == [
               {2, :invalid_headway},
               {3, :until_not_after_from},
               {4, :unsupported_exact_times},
               {5, :unreadable_frequency_window}
             ]
    end

    test "missing times suppress only spans, never a valid scheduled trip" do
      projection =
        project(stop_times: [{"T1", "", "", "S1", "1"}])

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      # The trip exists on this date, so its scheduled occurrence and its one
      # departure are both counted.
      assert group.scheduled_count == 1
      assert group.exact_count == 1
      assert group.count_complete?
      # Only the span is suppressed: no time was stated to bound it.
      assert group.first_secs == nil
      assert group.last_secs == nil
      refute group.span_complete?
    end

    test "a trip whose route is unresolvable is evaluated with no timezone" do
      projection =
        project(
          trips: [{"R_MISSING", "WEEK", "T1", "0"}],
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          calendar: [@every_weekday]
        )

      assert {:ok, evaluation} = Service.evaluate(projection, @monday, @monday)

      assert [group] = evaluation.groups
      assert group.route_id == "R_MISSING"
      assert group.timezone == nil
      assert group.scheduled_count == 1
      assert group.first_secs == 28_800
      assert Enum.any?(evaluation.unknowns, &(&1.reason == :unknown_route))
    end
  end

  describe "occurrence bounds" do
    test "accepts exactly 200,000 expanded occurrences and refuses one more" do
      # A one-second headway over a window ending exactly 200,000 seconds after
      # the start expands to exactly 200,000 departures on one active date.
      at_bound =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [{"T1", "08:00:00", long_clock(28_800 + 200_000), "1", "1"}]
        )

      assert {:ok, evaluation} = Service.evaluate(at_bound, @monday, @monday)
      assert [group] = evaluation.groups
      assert group.exact_count == 200_000
      assert group.first_secs == 28_800
      assert group.last_secs == 28_800 + 199_999

      # 200,001 departures on one date is over the bound.
      one_over =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [{"T1", "08:00:00", long_clock(28_800 + 200_001), "1", "1"}]
        )

      assert {:error, :unsupported_size} = Service.evaluate(one_over, @monday, @monday)

      # Two active dates of 100,000 each are also over the bound, so the total is
      # per artifact and not per trip or per date.
      over_bound =
        project(
          stop_times: [{"T1", "08:00:00", "08:00:00", "S1", "1"}],
          frequencies: [{"T1", "08:00:00", long_clock(28_800 + 100_000), "1", "1"}],
          calendar: [@every_weekday]
        )

      assert {:error, :unsupported_size} = Service.evaluate(over_bound, @monday, @friday)
    end
  end

  # -- fixtures ----------------------------------------------------------------

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
      trips: [{"R1", "WEEK", "T1", "0"}]
    ]

    # A test chooses coverage through `calendar_dates`, so the weekly row is a
    # default unless the test states one itself.
    files =
      if Keyword.has_key?(opts, :calendar) or Keyword.has_key?(opts, :calendar_dates),
        do: default_rows,
        else: Keyword.put(default_rows, :calendar, [@every_weekday])

    files = Keyword.merge(files, opts)

    tables =
      Enum.reduce(files, %{}, fn {name, rows}, acc ->
        Map.put(acc, "#{name}.txt", csv(Map.fetch!(headers, name), rows))
      end)

    {:ok, projection} = Projection.build(%{tables: tables, identity: identity()})
    projection
  end

  # The native struct keeps its own shape and carries the physical row beside it,
  # exactly as the projection attaches it.
  defp exception(date, type, row) do
    CalendarDate
    |> struct!(service_id: "WEEK", date: date, exception_type: type)
    |> Map.put(:source, %{file: "calendar_dates.txt", row: row})
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

  defp long_clock(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    remainder = rem(seconds, 60)

    :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, minutes, remainder]) |> to_string()
  end

  # -- native composition -----------------------------------------------------

  defp claim_native!(organization, version, scope) do
    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :full)
    claim!(organization, version, scope, bytes)
  end

  defp claim!(organization, version, scope, bytes) do
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

    {claim, selection.left}
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
  end
end
