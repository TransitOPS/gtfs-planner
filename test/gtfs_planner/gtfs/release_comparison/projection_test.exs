defmodule GtfsPlanner.Gtfs.ReleaseComparison.ProjectionTest do
  @moduledoc """
  Focused evidence for CL-3/FH-3: the projection preserves native calendar
  semantics, references, loop sequences and unknowns, and duplicate, missing or
  malformed input never becomes complete zero service.

  Expected values are hand-calculated from the fixture text in each test. The
  first case runs the real native exporter, the step 2 reader and this
  projection together, so the shape later steps receive is the shape they will
  actually be handed.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Calendar, as: CalendarSchema
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.Projection
  alias GtfsPlanner.Gtfs.ReleaseComparison.Reader
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Trip

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

  setup do
    root =
      Path.join(System.tmp_dir!(), "comparison-projection-#{System.unique_integer([:positive])}")

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

  describe "build/1 on a native full-main artifact" do
    test "projects the real exported rows and discloses what the artifact cannot resolve",
         context do
      %{organization: organization, version: version} = context
      seed_native_version!(organization, version)
      {claim, identity} = claim_native!(organization, version, context.scope)

      assert {:ok, reader_output} = Reader.read(claim, identity)
      assert {:ok, projection} = Projection.build(reader_output)

      assert projection.identity == identity
      # The selected evidence stays exactly as the reader produced it.
      assert projection.tables == reader_output.tables

      # The native export's own run identity is carried through unchanged, so the
      # estimation disclosure is the artifact's, not a guess made here.
      assert projection.estimation == %{
               possible: identity.estimate_missing_times,
               method: identity.estimate_method
             }

      assert [agency] = Map.values(projection.agencies)
      assert agency.agency_id == "AGENCY"
      assert agency.timezone == "America/Los_Angeles"

      assert [stop] = Map.values(projection.stops)
      assert stop.stop_id == "S1"
      assert Decimal.equal?(stop.lat, Decimal.new("40.7128"))
      assert Decimal.equal?(stop.lon, Decimal.new("-74.0060"))

      # The native exporter writes the route's stored agency reference rather
      # than the agency table's `agency_id`, so this artifact's route names an
      # agency the file does not define. That is disclosed as an unknown
      # timezone rather than resolved to a guess.
      assert [route] = Map.values(projection.routes)
      assert route.route_id == "R1"
      assert route.route_type == 3
      assert route.long_name == "Test Route"
      assert route.timezone == nil
      refute route.timezone_known?

      assert Enum.any?(projection.unknowns, fn entry ->
               entry == %{
                 file: "routes.txt",
                 row: 2,
                 entity_id: "R1",
                 field: "agency_id",
                 reason: :unknown_agency
               }
             end)

      assert [trip] = Map.values(projection.trips)
      assert trip.trip_id == "T1"
      assert trip.service_id == "WEEK"
      assert trip.direction_id == nil

      # The native exporter writes each table's stored primary reference into the
      # foreign columns, so this artifact's `trips.txt` and `stop_times.txt`
      # carry database UUIDs rather than the GTFS identifiers of `routes.txt` and
      # `stops.txt`. The projection reports exactly that instead of resolving a
      # reference it cannot prove, so the artifact is not silently complete.
      assert trip.route_id != route.route_id
      assert trip.route_id != ""

      # `stop_times.txt` groups under the trip reference it names, which is that
      # same stored UUID rather than the `trips.txt` identifier.
      assert [referenced_trip_id] = Map.keys(projection.stop_occurrences)
      assert referenced_trip_id != trip.trip_id

      assert [%{sequence: 1, arrival_secs: 28_800, source: %{file: "stop_times.txt", row: 2}}] =
               projection.stop_occurrences[referenced_trip_id]

      assert Enum.any?(projection.unknowns, &(&1.reason == :unknown_route))
      assert Enum.any?(projection.unknowns, &(&1.reason == :unknown_stop))

      assert [calendar] = Map.values(projection.calendars)
      assert calendar.service_id == "WEEK"
      assert calendar.start_date == ~D[2026-01-01]
      assert calendar.end_date == ~D[2026-12-31]
      assert calendar.friday == 1
      assert calendar.saturday == 0
      assert calendar.source == %{file: "calendar.txt", row: 2}
      assert projection.frequencies == []
    end

    test "reads only the selected bytes, never the live version, and inserts nothing", context do
      %{organization: organization, version: version} = context
      seed_native_version!(organization, version)

      # A whole second version exists in the live database with its own service
      # and route. The projection describes the selected artifact, so neither may
      # appear in it and nothing may be written.
      other_version = gtfs_version_fixture(organization.id)
      other_agency = agency_fixture(organization.id, other_version.id, %{agency_id: "OTHER"})
      calendar_fixture(organization.id, other_version.id, %{service_id: "LIVE_ONLY"})

      route_fixture(organization.id, other_version.id, %{
        route_id: "R_LIVE",
        agency_id: other_agency.id
      })

      before = snapshot_counts()

      {claim, identity} = claim_native!(organization, version, context.scope)
      assert {:ok, reader_output} = Reader.read(claim, identity)
      assert {:ok, projection} = Projection.build(reader_output)

      refute Map.has_key?(projection.calendars, "LIVE_ONLY")
      refute Map.has_key?(projection.routes, "R_LIVE")
      assert Map.keys(projection.calendars) == ["WEEK"]

      assert snapshot_counts() == before
    end
  end

  describe "calendar semantics" do
    test "dates-only service becomes a nil calendar plus its CalendarDate additions" do
      tables =
        tables(
          agency: agency([{"AGENCY", "Metro", "http://a.example", "America/Denver"}]),
          routes: routes([{"R1", "AGENCY", "1", "Main", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}]),
          trips: trips([{"R1", "DATES", "T1", "0"}]),
          stop_times: stop_times([{"T1", "08:00:00", "08:00:00", "S1", "1"}]),
          calendar_dates: calendar_dates([{"DATES", "20260704", "1"}, {"DATES", "20261126", "2"}])
        )

      assert {:ok, projection} = Projection.build(reader_output(tables))

      assert projection.calendars == %{"DATES" => nil}

      assert [added, removed] = projection.exceptions["DATES"]

      # The native structs are what `ServiceDates` consumes, and each carries the
      # physical row it came from beside it.
      assert %CalendarDate{service_id: "DATES", date: ~D[2026-07-04], exception_type: 1} = added
      assert added.source == %{file: "calendar_dates.txt", row: 2}
      assert %CalendarDate{date: ~D[2026-11-26], exception_type: 2} = removed
      assert removed.source == %{file: "calendar_dates.txt", row: 3}

      # The two dates are the service's entire effective coverage here.
      assert ServiceDates.active_dates(
               projection.calendars["DATES"],
               projection.exceptions["DATES"]
             ) ==
               [~D[2026-07-04]]

      assert projection.unknowns == []
    end

    test "a malformed weekly row leaves the service unknown instead of dates-only" do
      tables =
        tables(
          agency: agency([{"AGENCY", "Metro", "http://a.example", "UTC"}]),
          routes: routes([{"R1", "AGENCY", "1", "Main", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}]),
          trips: trips([{"R1", "WEEK", "T1", "0"}]),
          stop_times: stop_times([{"T1", "08:00:00", "08:00:00", "S1", "1"}]),
          calendar:
            calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}]),
          calendar_dates: calendar_dates([{"WEEK", "20260704", "1"}])
        )

      assert {:ok, projection} = Projection.build(reader_output(tables))

      assert [
               %CalendarSchema{
                 service_id: "WEEK",
                 start_date: ~D[2026-01-01],
                 end_date: ~D[2026-12-31]
               }
             ] =
               Map.values(projection.calendars)

      assert [%CalendarDate{service_id: "WEEK", date: ~D[2026-07-04], exception_type: 1}] =
               projection.exceptions["WEEK"]

      # Tuesday 9 is not a weekday value, and the weekly range ends before it
      # starts: both name the service with their own file and row.
      bad =
        Map.put(
          tables,
          "calendar.txt",
          calendar([{"WEEK", "1", "9", "1", "1", "1", "0", "0", "20261231", "20260101"}])
        )

      assert {:ok, refused} = Projection.build(reader_output(bad))

      # A malformed weekly row is not a dates-only service, so the service keeps
      # no calendar entry at all.
      assert refused.calendars == %{"WEEK" => nil}

      assert Enum.any?(refused.unknowns, fn entry ->
               entry == %{
                 file: "calendar.txt",
                 row: 2,
                 entity_id: "WEEK",
                 field: "tuesday",
                 reason: :invalid_weekday
               }
             end)

      assert Enum.any?(refused.unknowns, fn entry ->
               entry == %{
                 file: "calendar.txt",
                 row: 2,
                 entity_id: "WEEK",
                 field: "end_date",
                 reason: :reversed_date_range
               }
             end)
    end

    test "bad dates, bad exception types and duplicate service-dates each disclose file and row" do
      tables =
        tables(
          agency: agency([{"AGENCY", "Metro", "http://a.example", "UTC"}]),
          routes: routes([{"R1", "AGENCY", "1", "Main", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}]),
          trips: trips([{"R1", "WEEK", "T1", "0"}]),
          stop_times: stop_times([{"T1", "08:00:00", "08:00:00", "S1", "1"}]),
          calendar_dates:
            calendar_dates([
              {"WEEK", "20260704", "1"},
              {"WEEK", "20260705", "1"},
              {"WEEK", "2026-13-01", "2"},
              {"WEEK", "20261225", "3"},
              {"WEEK", "20260705", "2"}
            ])
        )

      assert {:ok, projection} = Projection.build(reader_output(tables))

      # The two readable dates survive in date order; the unreadable rows never
      # become dates, and the repeated pair keeps only its first row.
      assert [
               %CalendarDate{date: ~D[2026-07-04], exception_type: 1},
               %CalendarDate{date: ~D[2026-07-05], exception_type: 1}
             ] = projection.exceptions["WEEK"]

      assert Enum.map(projection.exceptions["WEEK"], & &1.source) == [
               %{file: "calendar_dates.txt", row: 2},
               %{file: "calendar_dates.txt", row: 3}
             ]

      reasons =
        projection.unknowns
        |> Enum.filter(&(&1.file == "calendar_dates.txt"))
        |> Enum.map(&{&1.row, &1.field, &1.reason})
        |> Enum.sort()

      # The physical rows are 4, 5 and 6: row 2 and row 3 are the readable dates.
      assert reasons == [
               {4, "date", :invalid_date},
               {5, "exception_type", :invalid_exception_type},
               {6, "date", :duplicate_service_date}
             ]

      assert Enum.all?(projection.unknowns, &(&1.entity_id == "WEEK"))
    end
  end

  describe "duplicates and missing references" do
    test "a duplicate route, stop or trip keeps the first row and discloses the later one" do
      tables =
        tables(
          agency: agency([{"AGENCY", "Metro", "http://a.example", "UTC"}]),
          routes:
            routes([
              {"R1", "AGENCY", "1", "Main", "3"},
              {"R1", "AGENCY", "9", "Other", "3"}
            ]),
          stops:
            stops([
              {"S1", "First", "40.1", "-74.1"},
              {"S1", "Second", "41.2", "-75.2"}
            ]),
          trips:
            trips([
              {"R1", "WEEK", "T1", "0"},
              {"R1", "WEEK", "T1", "1"}
            ]),
          stop_times: stop_times([{"T1", "08:00:00", "08:00:00", "S1", "1"}]),
          calendar:
            calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}])
        )

      assert {:ok, projection} = Projection.build(reader_output(tables))

      # The first row survives untouched: a duplicate never overwrites evidence.
      assert projection.routes["R1"].short_name == "1"
      assert projection.stops["S1"].name == "First"
      assert projection.trips["T1"].direction_id == 0

      duplicates =
        projection.unknowns
        |> Enum.filter(&(&1.reason == :duplicate_id))
        |> Enum.map(&{&1.file, &1.row})
        |> Enum.sort()

      assert duplicates == [
               {"routes.txt", 3},
               {"stops.txt", 3},
               {"trips.txt", 3}
             ]
    end

    test "a missing route, stop or service reference stays visible and never implies coverage" do
      tables =
        tables(
          agency: agency([{"AGENCY", "Metro", "http://a.example", "UTC"}]),
          routes: routes([{"R1", "AGENCY", "1", "Main", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}]),
          trips: trips([{"R_MISSING", "WEEK", "T1", "0"}, {"R1", "", "T2", "0"}]),
          stop_times: stop_times([{"T1", "08:00:00", "08:00:00", "S1", "1"}]),
          calendar:
            calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}])
        )

      assert {:ok, projection} = Projection.build(reader_output(tables))

      # Both trips stay indexed so the dangling references remain countable.
      assert Map.keys(projection.trips) |> Enum.sort() == ["T1", "T2"]
      assert projection.trips["T1"].route_id == "R_MISSING"

      references =
        projection.unknowns
        |> Enum.filter(&(&1.reason in [:unknown_route, :missing_id]))
        |> Enum.map(&{&1.row, &1.entity_id, &1.field, &1.reason})
        |> Enum.sort()

      assert references == [
               {2, "T1", "route_id", :unknown_route},
               {3, "T2", "service_id", :missing_id}
             ]
    end
  end

  describe "unevaluable input" do
    test "a Flex stop reference stays ordered with its raw identifier and an unknown" do
      tables =
        tables(
          agency: agency([{"AGENCY", "Metro", "http://a.example", "UTC"}]),
          routes: routes([{"R1", "AGENCY", "1", "Main", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}]),
          trips: trips([{"R1", "WEEK", "T1", "0"}]),
          stop_times:
            stop_times([
              {"T1", "08:00:00", "08:00:00", "FLEX_LOC", "1"},
              {"T1", "08:10:00", "08:10:00", "S1", "2"}
            ]),
          calendar:
            calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}])
        )

      assert {:ok, projection} = Projection.build(reader_output(tables))

      assert [first, second] = projection.stop_occurrences["T1"]
      assert first.stop_id == "FLEX_LOC"
      assert second.stop_id == "S1"

      assert Enum.any?(projection.unknowns, fn entry ->
               entry == %{
                 file: "stop_times.txt",
                 row: 2,
                 entity_id: "T1",
                 field: "stop_id",
                 reason: :unknown_stop
               }
             end)
    end

    test "a loop keeps repeated stops ordered by sequence and discloses a repeated sequence" do
      tables =
        tables(
          agency: agency([{"AGENCY", "Metro", "http://a.example", "UTC"}]),
          routes: routes([{"R1", "AGENCY", "1", "Main", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}, {"S2", "Second", "41.1", "-75.1"}]),
          trips: trips([{"R1", "WEEK", "T1", "0"}]),
          stop_times:
            stop_times([
              # Unsorted on purpose, and the loop revisits S1.
              {"T1", "08:30:00", "08:30:00", "S1", "9"},
              {"T1", "08:00:00", "08:00:00", "S1", "1"},
              {"T1", "08:15:00", "08:15:00", "S2", "5"},
              {"T1", "08:40:00", "08:40:00", "S2", "5"}
            ]),
          calendar:
            calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}])
        )

      assert {:ok, projection} = Projection.build(reader_output(tables))

      assert Enum.map(projection.stop_occurrences["T1"], & &1.sequence) == [1, 5, 5, 9]
      assert Enum.map(projection.stop_occurrences["T1"], & &1.stop_id) == ["S1", "S2", "S2", "S1"]

      assert Enum.any?(projection.unknowns, fn entry ->
               entry == %{
                 file: "stop_times.txt",
                 row: 5,
                 entity_id: "S2",
                 field: "stop_sequence",
                 reason: :duplicate_sequence
               }
             end)
    end

    test "non-integer sequence or headway, invalid times and an unsupported exact_times are unknown" do
      tables =
        tables(
          agency: agency([{"AGENCY", "Metro", "http://a.example", "UTC"}]),
          routes: routes([{"R1", "AGENCY", "1", "Main", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}]),
          trips: trips([{"R1", "WEEK", "T1", "2"}]),
          stop_times: stop_times([{"T1", "8:0:0", "08:00:00", "S1", "1a"}]),
          frequencies:
            frequencies([
              {"T1", "08:00:00", "09:00:00", "1200", "1"},
              {"T1", "10:00:00", "11:00:00", "20m", "maybe"}
            ]),
          calendar:
            calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}])
        )

      assert {:ok, projection} = Projection.build(reader_output(tables))

      assert [occurrence] = projection.stop_occurrences["T1"]
      assert occurrence.sequence == nil
      assert occurrence.arrival_secs == nil
      assert occurrence.arrival_time == "8:0:0"
      assert occurrence.departure_secs == 28_800

      assert [%{headway_secs: 1200, exact_times: 1}, %{headway_secs: nil, exact_times: nil}] =
               projection.frequencies

      reasons =
        projection.unknowns
        |> Enum.map(&{&1.file, &1.row, &1.field, &1.reason})
        |> Enum.sort()

      assert reasons == [
               {"frequencies.txt", 3, "exact_times", :unsupported_exact_times},
               {"frequencies.txt", 3, "headway_secs", :invalid_integer},
               {"stop_times.txt", 2, "arrival_time", :invalid_time},
               {"stop_times.txt", 2, "stop_sequence", :invalid_integer},
               {"trips.txt", 2, "direction_id", :invalid_integer}
             ]
    end

    test "an ambiguous or dangling agency is an unknown timezone, not a guess" do
      two_agencies =
        tables(
          agency:
            agency([
              {"A1", "First", "http://a.example", "UTC"},
              {"A2", "Second", "http://b.example", "America/Denver"}
            ]),
          routes:
            routes([{"R_BLANK", "", "1", "Main", "3"}, {"R_DANGLING", "A9", "2", "X", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}]),
          trips: trips([{"R_BLANK", "WEEK", "T1", "0"}]),
          stop_times: stop_times([{"T1", "08:00:00", "08:00:00", "S1", "1"}]),
          calendar:
            calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}])
        )

      assert {:ok, projection} = Projection.build(reader_output(two_agencies))

      assert projection.routes["R_BLANK"].timezone == nil
      refute projection.routes["R_BLANK"].timezone_known?
      assert projection.routes["R_DANGLING"].timezone == nil

      assert Enum.any?(projection.unknowns, &(&1.reason == :ambiguous_agency))
      assert Enum.any?(projection.unknowns, &(&1.reason == :unknown_agency))

      # With exactly one agency, a blank agency_id resolves to that agency's
      # timezone, which is what makes aligned timing claims possible.
      one_agency =
        tables(
          agency: agency([{"", "Only", "http://a.example", "America/Denver"}]),
          routes: routes([{"R_BLANK", "", "1", "Main", "3"}]),
          stops: stops([{"S1", "First", "40.1", "-74.1"}]),
          trips: trips([{"R_BLANK", "WEEK", "T1", "0"}]),
          stop_times: stop_times([{"T1", "08:00:00", "08:00:00", "S1", "1"}]),
          calendar:
            calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}])
        )

      assert {:ok, single} = Projection.build(reader_output(one_agency))
      assert single.routes["R_BLANK"].timezone == "America/Denver"
      assert single.routes["R_BLANK"].timezone_known?
    end

    test "refuses more frequency templates than the bound allows, and accepts exactly the bound" do
      assert {:ok, at_bound} =
               Projection.build(reader_output(frequencies_templates(20_000)))

      assert length(at_bound.frequencies) == 20_000

      assert {:error, :unsupported_size} =
               Projection.build(reader_output(frequencies_templates(20_001)))
    end
  end

  describe "estimation disclosure" do
    test "an estimating artifact is disclosed at artifact level only" do
      identity = identity(%{estimate_missing_times: true, estimate_method: :even})
      tables = base_tables()

      assert {:ok, projection} = Projection.build(%{tables: tables, identity: identity})

      assert projection.estimation == %{possible: true, method: :even}

      # The disclosure is artifact-level: no occurrence claims to know whether
      # its own exported time was filled.
      assert [occurrence] = projection.stop_occurrences["T1"]
      refute Map.has_key?(occurrence, :estimated)
      refute Map.has_key?(occurrence, :estimated?)
    end

    test "an artifact exported without estimation reports no possible estimation" do
      identity = identity(%{estimate_missing_times: false, estimate_method: nil})

      assert {:ok, projection} =
               Projection.build(%{tables: base_tables(), identity: identity})

      assert projection.estimation == %{possible: false, method: nil}
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp base_tables do
    Map.merge(
      tables(
        agency: agency([{"AGENCY", "Metro", "http://a.example", "UTC"}]),
        routes: routes([{"R1", "AGENCY", "1", "Main", "3"}]),
        stops: stops([{"S1", "First", "40.1", "-74.1"}]),
        trips: trips([{"R1", "WEEK", "T1", "0"}]),
        stop_times: stop_times([{"T1", "08:00:00", "08:00:00", "S1", "1"}])
      ),
      %{
        "calendar.txt" =>
          calendar([{"WEEK", "1", "1", "1", "1", "1", "0", "0", "20260101", "20261231"}])
      }
    )
  end

  defp tables(opts) do
    Enum.reduce(opts, %{}, fn {name, content}, acc -> Map.put(acc, "#{name}.txt", content) end)
  end

  # The reader result is used exactly as given: the tables under test are the
  # artifact, so no other table is quietly merged in behind them.
  defp reader_output(tables) do
    %{tables: tables, identity: identity()}
  end

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: Ecto.UUID.generate(),
        version_id: Ecto.UUID.generate(),
        sha256: String.duplicate("a", 64),
        size: 4_096,
        export_type: :full,
        expires_at: DateTime.utc_now(),
        estimate_missing_times: false,
        estimate_method: nil
      },
      overrides
    )
  end

  # Rows are shaped exactly as `Reader.read/2` returns them, with the physical
  # CSV row number beginning at 2, so the projection sees its real input.
  defp csv(header, rows) do
    for {data, index} <- Enum.with_index(rows, 2) do
      fields = header |> Enum.zip(Tuple.to_list(data)) |> Map.new()
      %{row: index, fields: fields}
    end
  end

  defp agency(rows), do: csv(@agency_header, rows)
  defp routes(rows), do: csv(@routes_header, rows)
  defp stops(rows), do: csv(@stops_header, rows)
  defp trips(rows), do: csv(@trips_header, rows)
  defp stop_times(rows), do: csv(@stop_times_header, rows)
  defp frequencies(rows), do: csv(@frequencies_header, rows)
  defp calendar(rows), do: csv(@calendar_header, rows)
  defp calendar_dates(rows), do: csv(@calendar_dates_header, rows)

  defp frequencies_templates(count) do
    rows =
      for _index <- 1..count//1, do: {"T1", "08:00:00", "09:00:00", "1200", "1"}

    Map.put(base_tables(), "frequencies.txt", frequencies(rows))
  end

  # -- native composition -----------------------------------------------------

  defp claim_native!(organization, version, scope) do
    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :full)
    claim!(organization, version, scope, bytes)
  end

  # Publishes the bytes as a ready native main artifact, claims them the way
  # step 7 will, and takes the identity from step 1's own selection contract.
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
               "from" => "2026-04-01",
               "to" => "2026-04-02"
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

  defp snapshot_counts do
    %{
      calendars: Repo.aggregate(CalendarSchema, :count),
      calendar_dates: Repo.aggregate(CalendarDate, :count),
      routes: Repo.aggregate(Route, :count),
      trips: Repo.aggregate(Trip, :count)
    }
  end
end
