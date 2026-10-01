defmodule GtfsPlanner.Gtfs.ReleaseComparison.ReaderTest do
  @moduledoc """
  Focused evidence for CL-2/FH-2: the comparison parses only the bytes it
  rehashed from the claimed path, admits only allowlisted members, and refuses
  unsafe, oversized, duplicated or malformed archives instead of returning
  partial evidence.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.Reader

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  @agency "agency_id,agency_name,agency_url,agency_timezone\nAGENCY,Metro,http://a.example,America/Los_Angeles\n"
  @routes "route_id,agency_id,route_short_name,route_long_name,route_type\nR1,AGENCY,1,Main,3\n"
  # The same shape with a different route id, so a replacement archive is exactly
  # as large as the bytes it replaces and only its digest differs.
  @other_routes "route_id,agency_id,route_short_name,route_long_name,route_type\nR9,AGENCY,1,Main,3\n"
  @stops "stop_id,stop_name,stop_lat,stop_lon\nS1,First,40.7128,-74.0060\n"
  @trips "route_id,service_id,trip_id\nR1,WEEK,T1\n"
  @stop_times_header "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
  @stop_times @stop_times_header <> "T1,08:00:00,08:00:00,S1,1\n"
  @calendar "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nWEEK,1,1,1,1,1,0,0,20260101,20261231\n"
  @calendar_dates "service_id,date,exception_type\nWEEK,20260704,2\n"

  @mib 1_048_576
  @max_selected_bytes 20 * @mib
  @max_rows 100_000
  # Five required members plus the calendar each carry one data row.
  @rows_in_small_tables 5

  setup do
    root = Path.join(System.tmp_dir!(), "comparison-reader-#{System.unique_integer([:positive])}")
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

  describe "read/2 on a native full-main artifact" do
    test "parses the allowlisted members of the real exported ZIP with physical row refs",
         context do
      %{organization: organization, version: version} = context
      seed_native_version!(organization, version)
      {claim, identity} = claim_native!(organization, version)

      assert {:ok, %{tables: tables, identity: returned}} = Reader.read(claim, identity)
      assert returned == identity

      assert Map.keys(tables) |> Enum.sort() == [
               "agency.txt",
               "calendar.txt",
               "routes.txt",
               "stop_times.txt",
               "stops.txt",
               "trips.txt"
             ]

      assert [%{row: 2, fields: agency}] = tables["agency.txt"]
      assert agency["agency_id"] == "AGENCY"
      assert agency["agency_timezone"] == "America/Los_Angeles"
      assert [%{row: 2, fields: %{"route_id" => "R1"}}] = tables["routes.txt"]
      assert [%{row: 2, fields: %{"trip_id" => "T1"}}] = tables["trips.txt"]
      assert [%{row: 2, fields: %{"stop_sequence" => "1"}}] = tables["stop_times.txt"]
      assert [%{row: 2, fields: %{"stop_id" => "S1"}}] = tables["stops.txt"]
      assert [%{row: 2, fields: %{"service_id" => "WEEK"}}] = tables["calendar.txt"]

      # Nothing is extracted beside the artifact: the read is memory-only.
      assert {:ok, listing} = File.ls(Path.dirname(claim.path))
      assert length(listing) == 1
      assert Path.extname(hd(listing)) == ".zip"
    end

    test "accepts calendar_dates as the only service coverage", context do
      %{organization: organization, scope: scope} = context
      version = seed_dates_only_version!(organization)
      {claim, identity} = claim!(organization, version, scope, dates_only_zip())

      assert {:ok, %{tables: tables}} = Reader.read(claim, identity)

      assert Map.keys(tables) |> Enum.sort() == [
               "agency.txt",
               "calendar_dates.txt",
               "routes.txt",
               "stop_times.txt",
               "stops.txt",
               "trips.txt"
             ]

      assert [%{row: 2, fields: %{"date" => "20260704", "exception_type" => "2"}}] =
               tables["calendar_dates.txt"]
    end
  end

  describe "consumed bytes" do
    test "refuses bytes replaced after the claim and never reports the replacement", context do
      %{organization: organization, version: version, scope: scope} = context

      {claim, identity} =
        claim!(organization, version, scope, service_zip(overrides: %{routes: @routes}))

      replacement = service_zip(overrides: %{routes: @other_routes})
      assert byte_size(replacement) == identity.size

      File.write!(claim.path, replacement)
      assert {:error, :unavailable} = Reader.read(claim, identity)

      # A claim that describes other bytes parses those bytes: the reported rows
      # always come from the binary whose digest was checked.
      {other_claim, other_identity} =
        claim!(organization, gtfs_version_fixture(organization.id), scope, replacement)

      assert {:ok, %{tables: tables}} = Reader.read(other_claim, other_identity)
      assert [%{fields: %{"route_id" => "R9"}}] = tables["routes.txt"]
    end

    test "refuses an oversized replacement before retaining the extra chunks", context do
      %{organization: organization, version: version, scope: scope} = context
      {claim, identity} = claim!(organization, version, scope, service_zip())
      original = File.read!(claim.path)

      # The read cap is the recorded size, so a larger file is refused after the
      # first bounded chunk instead of being read whole.
      File.write!(claim.path, String.duplicate("A", 512 * 1024))
      assert {:error, :unsupported_size} = Reader.read(claim, identity)

      # Truncation below the recorded size is a digest refusal, not a short read.
      File.write!(claim.path, binary_part(original, 0, 8))
      assert {:error, :unavailable} = Reader.read(claim, identity)

      # A removed artifact is unavailable, not a partial read.
      File.rm!(claim.path)
      assert {:error, :unavailable} = Reader.read(claim, identity)
    end

    test "refuses a claim whose identity disagrees with the claim", context do
      %{organization: organization, version: version, scope: scope} = context
      {claim, identity} = claim!(organization, version, scope, service_zip())

      assert {:error, :unavailable} =
               Reader.read(claim, %{identity | sha256: String.duplicate("0", 64)})

      assert {:error, :unavailable} = Reader.read(claim, %{identity | size: identity.size + 1})
    end
  end

  describe "member admission" do
    test "keeps only allowlisted members and ignores shapes, images and personnel payloads",
         context do
      %{organization: organization, version: version, scope: scope} = context

      {claim, identity} =
        claim!(
          organization,
          version,
          scope,
          service_zip(
            extra: [
              {"frequencies.txt",
               "trip_id,start_time,end_time,headway_secs\nT1,08:00:00,09:00:00,1200\n"},
              {"feed_info.txt", "feed_publisher_name,feed_lang\nMetro,en\n"},
              {"shapes.txt", "shape_id,shape_pt_lat,shape_pt_lon\nSH1,40.7,-74.0\n"},
              {"levels.txt", "level_id,level_index\nL1,0\n"},
              {"personnel.txt", "personnel_id,salary\nP1,90000\n"},
              {"extensions/photo.jpg", <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF">>}
            ]
          )
        )

      assert {:ok, %{tables: tables}} = Reader.read(claim, identity)

      assert Map.keys(tables) |> Enum.sort() == [
               "agency.txt",
               "calendar.txt",
               "feed_info.txt",
               "frequencies.txt",
               "routes.txt",
               "stop_times.txt",
               "stops.txt",
               "trips.txt"
             ]

      assert [%{fields: %{"headway_secs" => "1200"}}] = tables["frequencies.txt"]
      assert [%{fields: %{"feed_lang" => "en"}}] = tables["feed_info.txt"]
    end

    test "ignores a nested member that merely ends with an allowlist name", context do
      %{organization: organization, version: version, scope: scope} = context

      {claim, identity} =
        claim!(
          organization,
          version,
          scope,
          service_zip(extra: [{"nested/routes.txt", "route_id\nR9\n"}])
        )

      assert {:ok, %{tables: tables}} = Reader.read(claim, identity)
      assert [%{fields: %{"route_id" => "R1"}}] = tables["routes.txt"]
      refute Map.has_key?(tables, "nested/routes.txt")
    end

    test "refuses a duplicated allowlisted member name", context do
      %{organization: organization, version: version, scope: scope} = context

      {claim, identity} =
        claim!(
          organization,
          version,
          scope,
          service_zip(extra: [{"routes.txt", "route_id\nR9\n"}])
        )

      assert {:error, :invalid_archive} = Reader.read(claim, identity)
    end

    test "refuses an unsafe member path", context do
      %{organization: organization, version: version, scope: scope} = context

      {claim, identity} =
        claim!(
          organization,
          version,
          scope,
          service_zip(extra: [{"../routes.txt", "route_id\nR9\n"}])
        )

      assert {:error, :invalid_archive} = Reader.read(claim, identity)
    end

    test "refuses a missing required table and an archive with no calendar coverage", context do
      %{organization: organization, version: version, scope: scope} = context

      {missing_trips, missing_identity} =
        claim!(organization, version, scope, service_zip(drop: ["trips.txt"]))

      assert {:error, :invalid_archive} = Reader.read(missing_trips, missing_identity)

      {no_calendar, no_calendar_identity} =
        claim!(
          organization,
          version,
          scope,
          service_zip(drop: ["calendar.txt", "calendar_dates.txt"])
        )

      assert {:error, :invalid_archive} = Reader.read(no_calendar, no_calendar_identity)
    end

    test "refuses a member whose declared size understates the extracted bytes", context do
      %{organization: organization, version: version, scope: scope} = context

      understated =
        stored_zip([
          {"agency.txt", @agency, byte_size(@agency)},
          {"routes.txt", @routes, 4},
          {"stops.txt", @stops, byte_size(@stops)},
          {"trips.txt", @trips, byte_size(@trips)},
          {"stop_times.txt", @stop_times, byte_size(@stop_times)},
          {"calendar.txt", @calendar, byte_size(@calendar)}
        ])

      {claim, identity} = claim!(organization, version, scope, understated)
      assert {:error, :invalid_archive} = Reader.read(claim, identity)
    end

    test "refuses more entries than the import entry cap", context do
      %{organization: organization, version: version, scope: scope} = context

      crowded =
        service_zip(extra: for(index <- 1..10_001, do: {"extra#{index}.txt", "x\n"}))

      {claim, identity} = claim!(organization, version, scope, crowded)
      assert {:error, :unsupported_size} = Reader.read(claim, identity)
    end
  end

  describe "malformed CSV" do
    test "refuses invalid UTF-8, malformed quoting, a duplicate header, a wrong count and emptiness",
         context do
      %{organization: organization, version: version, scope: scope} = context

      refused = [
        {"invalid utf8", "stop_id,stop_name\nS1,Main Stree\xFFt\n"},
        {"malformed quoting",
         "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nT1,\"08:0,08:00:00,S1,1\n"},
        {"duplicate header", "stop_id,stop_id\nS1,S1\n"},
        {"blank header", "stop_id,\nS1,First\n"},
        {"wrong field count", "stop_id,stop_name\nS1,First,extra\n"},
        {"empty content", ""}
      ]

      for {label, content} <- refused do
        {claim, identity} =
          claim!(organization, version, scope, service_zip(overrides: %{stops: content}))

        assert {:error, :malformed_csv} = Reader.read(claim, identity),
               "expected #{label} to refuse"
      end
    end
  end

  describe "selected caps" do
    test "accepts exactly the selected byte cap and refuses one byte more", context do
      %{organization: organization, version: version, scope: scope} = context

      others = selected_bytes() - byte_size(@agency)
      prefix = byte_size(agency_of(0))

      at_cap = service_zip(overrides: %{agency: agency_of(@max_selected_bytes - others - prefix)})
      {claim, identity} = claim!(organization, version, scope, at_cap)

      assert {:ok, %{tables: tables}} = Reader.read(claim, identity)

      assert byte_size(hd(tables["agency.txt"]).fields["agency_name"]) ==
               @max_selected_bytes - others - prefix

      over_cap =
        service_zip(overrides: %{agency: agency_of(@max_selected_bytes - others - prefix + 1)})

      {over_claim, over_identity} = claim!(organization, version, scope, over_cap)

      assert {:error, :unsupported_size} = Reader.read(over_claim, over_identity)
    end

    test "accepts exactly the row cap and refuses one row more without truncation", context do
      %{organization: organization, version: version, scope: scope} = context

      at_cap_rows = @max_rows - @rows_in_small_tables

      {claim, identity} =
        claim!(
          organization,
          version,
          scope,
          service_zip(overrides: %{stop_times: stop_times(at_cap_rows)})
        )

      assert {:ok, %{tables: tables}} = Reader.read(claim, identity)
      assert length(tables["stop_times.txt"]) == at_cap_rows
      assert Enum.sum(Enum.map(tables, fn {_name, rows} -> length(rows) end)) == @max_rows

      {over_claim, over_identity} =
        claim!(
          organization,
          version,
          scope,
          service_zip(overrides: %{stop_times: stop_times(at_cap_rows + 1)})
        )

      assert {:error, :unsupported_size} = Reader.read(over_claim, over_identity)
    end
  end

  defp service_zip(opts \\ []) do
    defaults = [
      {"agency.txt", @agency},
      {"routes.txt", @routes},
      {"stops.txt", @stops},
      {"trips.txt", @trips},
      {"stop_times.txt", @stop_times},
      {"calendar.txt", @calendar}
    ]

    members =
      Enum.map(defaults, fn {name, content} ->
        {name, Map.get(opts[:overrides] || %{}, name_key(name), content)}
      end)

    members = Enum.reject(members, fn {name, _content} -> name in (opts[:drop] || []) end)

    stored_zip(members ++ (opts[:extra] || []))
  end

  defp dates_only_zip,
    do: service_zip(extra: [{"calendar_dates.txt", @calendar_dates}], drop: ["calendar.txt"])

  defp name_key("agency.txt"), do: :agency
  defp name_key("routes.txt"), do: :routes
  defp name_key("stops.txt"), do: :stops
  defp name_key("trips.txt"), do: :trips
  defp name_key("stop_times.txt"), do: :stop_times
  defp name_key("calendar.txt"), do: :calendar

  # An uncompressed ZIP written byte by byte, so a test can state a declared
  # uncompressed size that differs from the bytes the member carries.
  defp stored_zip(entries) do
    stated =
      Enum.map(entries, fn
        {name, content} -> {name, content, byte_size(content)}
        {name, content, declared} -> {name, content, declared}
      end)

    {locals, central, _offset} =
      Enum.reduce(stated, {[], [], 0}, fn {name, content, declared}, {locals, central, offset} ->
        name_length = byte_size(name)
        crc = :erlang.crc32(content)

        local =
          <<0x04034B50::little-32, 10::little-16, 0::little-16, 0::little-16, 0::little-16,
            0::little-16, crc::little-32, byte_size(content)::little-32, declared::little-32,
            name_length::little-16, 0::little-16>> <> name <> content

        directory =
          <<0x02014B50::little-32, 10::little-16, 10::little-16, 0::little-16, 0::little-16,
            0::little-16, 0::little-16, crc::little-32, byte_size(content)::little-32,
            declared::little-32, name_length::little-16, 0::little-16, 0::little-16, 0::little-16,
            0::little-16, 0::little-32, offset::little-32>> <> name

        {locals ++ [local], central ++ [directory], offset + byte_size(local)}
      end)

    body = IO.iodata_to_binary(locals)
    directory = IO.iodata_to_binary(central)

    eocd =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, length(stated)::little-16,
        length(stated)::little-16, byte_size(directory)::little-32, byte_size(body)::little-32,
        0::little-16>>

    IO.iodata_to_binary([body, directory, eocd])
  end

  defp selected_bytes do
    Enum.reduce([@agency, @routes, @stops, @trips, @stop_times, @calendar], 0, fn content,
                                                                                  total ->
      total + byte_size(content)
    end)
  end

  defp agency_of(name_length) do
    "agency_id,agency_name,agency_url,agency_timezone\nAGENCY,#{String.duplicate("A", name_length)},http://a.example,UTC\n"
  end

  # `count` data rows under the real `stop_times.txt` header.
  defp stop_times(count) do
    IO.iodata_to_binary([
      @stop_times_header,
      for(index <- 1..count//1, do: "T#{index},08:00:00,08:00:00,S#{index},1\n")
    ])
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

  # The producer's real ZIP, through the same claim and identity path.
  defp claim_native!(organization, version) do
    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :full)
    {claim, identity} = claim!(organization, version, scope_for(organization, version), bytes)
    {claim, identity}
  end

  defp scope_for(organization, version) do
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "release_comparison",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }
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

  defp seed_dates_only_version!(organization) do
    version = gtfs_version_fixture(organization.id)
    agency = agency_fixture(organization.id, version.id, %{agency_id: "AGENCY"})
    route = route_fixture(organization.id, version.id, %{route_id: "R1", agency_id: agency.id})
    stop = stop_fixture(organization.id, version.id, %{stop_id: "S1"})

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "WEEK",
      date: ~D[2026-07-04],
      exception_type: 1
    })

    trip =
      trip_fixture(organization.id, version.id, route.id, %{trip_id: "T1", service_id: "WEEK"})

    stop_time_fixture(organization.id, version.id, trip.id, stop.id, %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    })

    version
  end
end
