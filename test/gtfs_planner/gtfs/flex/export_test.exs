defmodule GtfsPlanner.Gtfs.Flex.ExportTest do
  @moduledoc """
  Judges the flex zip assembly and R3 in `GtfsPlanner.Gtfs.Export` (EV-6).

  The prepared cases run against `GtfsPlanner.FlexFixtures`' representative
  feed on the local test database: the zip content comparison, the main zip's
  equality with a flex-free export apart from the detour doubling, the R3
  stability across a same-time fix and an `include_flex` toggle, the `:operations`
  profile's doubling, the exclusion warnings, registered riders, the no-routes
  answer, the Transit hold thresholds and the stored-table counts. EV-4 (the
  validator CLI) judges the same fixture's structural validity in
  `GtfsPlanner.Gtfs.Export.FlexValidatorTest`.

  ZIP entries are compared file by file: Erlang's `:zip.create/3` stamps each
  member with its creation time, so two exports of the same data are equal in
  content but not in bytes across a second boundary.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BookingRule
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  import Ecto.Query, only: [from: 2]

  @route_20_trips ["20-out-am", "20-in-am", "20-out-sat"]
  @flex_extra_files [
    "booking_rules.txt",
    "location_group_stops.txt",
    "location_groups.txt",
    "locations.geojson"
  ]
  @flex_stop_times_header [
    "trip_id",
    "arrival_time",
    "departure_time",
    "stop_id",
    "location_group_id",
    "location_id",
    "stop_sequence",
    "stop_headsign",
    "start_pickup_drop_off_window",
    "end_pickup_drop_off_window",
    "pickup_type",
    "drop_off_type",
    "continuous_pickup",
    "continuous_drop_off",
    "shape_dist_traveled",
    "timepoint",
    "pickup_booking_rule_id",
    "drop_off_booking_rule_id"
  ]

  @drawn_area %{
    "type" => "Polygon",
    "coordinates" => [
      [
        [-124.09, 44.57],
        [-124.08, 44.57],
        [-124.08, 44.58],
        [-124.09, 44.58],
        [-124.09, 44.57]
      ]
    ]
  }

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      version: version,
      organization_id: organization.id,
      gtfs_version_id: version.id
    }
  end

  describe "build_zips/4 flex zip" do
    test "carries every main file plus the flex files and the flex stop_times header", context do
      flex_representative_fixture(context.organization, context.version)

      assert {:ok, %{main: main, flex: flex}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      main_files = zip_files(main)
      flex_files = zip_files(flex)

      assert Map.keys(main_files) != []

      assert Map.keys(main_files) -- Map.keys(flex_files) == []
      assert Enum.sort(Map.keys(flex_files) -- Map.keys(main_files)) == @flex_extra_files

      assert flex_files["stop_times.txt"] |> lines() |> hd() |> String.split(",") ==
               @flex_stop_times_header

      for file <- @flex_extra_files, do: assert(byte_size(flex_files[file]) > 0)
    end

    test "locations.geojson is a FeatureCollection of named six-decimal polygons", context do
      flex_representative_fixture(context.organization, context.version)

      assert {:ok, %{flex: flex}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      document = flex |> zip_files() |> Map.fetch!("locations.geojson") |> Jason.decode!()

      assert document["type"] == "FeatureCollection"

      assert Enum.sort(Enum.map(document["features"], & &1["id"])) == [
               "flex-newport-access-a1",
               "flex-newport-dial-a-ride-a1",
               "flex-newport-dial-a-ride-a2",
               "flex-valley-line-detours-NP1-NP2",
               "flex-valley-line-detours-NP2-TLD1",
               "flex-valley-line-detours-TLD1-TLD2"
             ]

      for feature <- document["features"] do
        assert feature["type"] == "Feature"
        assert is_binary(feature["properties"]["stop_name"])
        assert feature["geometry"]["type"] in ["Polygon", "MultiPolygon"]
        assert Enum.all?(coordinates(feature["geometry"]), &(decimals(&1) <= 6))
      end

      names = Enum.map(document["features"], & &1["properties"]["stop_name"])
      assert "Newport" in names
      assert "Toledo" in names
      assert "Route 20 detour area" in names
    end

    test "the flex zip names the booking rules and grouping stops files' rows", context do
      flex_representative_fixture(context.organization, context.version)

      assert {:ok, %{flex: flex}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      files = zip_files(flex)

      assert files["location_groups.txt"] |> lines() |> hd() ==
               "location_group_id,location_group_name"

      assert files["location_group_stops.txt"] |> lines() |> hd() == "location_group_id,stop_id"
      assert files["location_group_stops.txt"] =~ "flex-newport-dial-a-ride-stops,OTR"
      assert files["location_group_stops.txt"] =~ "flex-newport-dial-a-ride-stops,DPB"

      assert files["booking_rules.txt"] |> lines() |> hd() ==
               "booking_rule_id,booking_type,prior_notice_duration_min,prior_notice_duration_max," <>
                 "prior_notice_last_day,prior_notice_last_time,prior_notice_start_day," <>
                 "prior_notice_start_time,prior_notice_service_id,message,pickup_message," <>
                 "drop_off_message,phone_number,info_url,booking_url"

      assert files["booking_rules.txt"] =~ "flex-valley-line-detours-book"
      assert files["booking_rules.txt"] =~ "To get off away from the route"
    end
  end

  describe "R3 stop_sequence" do
    test "the main zip equals a flex-free export apart from the detour doubling", context do
      flex_representative_fixture(context.organization, context.version)

      assert {:ok, %{main: main}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      delete_services(context)

      assert {:ok, plain, _warnings} =
               Export.build_zip(context.organization_id, context.gtfs_version_id, :full)

      main_files = zip_files(main)
      plain_files = zip_files(plain)

      assert Enum.sort(Map.keys(main_files)) == Enum.sort(Map.keys(plain_files))

      for {name, content} <- plain_files, name != "stop_times.txt" do
        assert main_files[name] == content, "#{name} changed when flex services were deleted"
      end

      [main_header | main_rows] = lines(main_files["stop_times.txt"])
      [plain_header | plain_rows] = lines(plain_files["stop_times.txt"])

      assert main_header == plain_header
      assert Enum.map(main_rows, &halve_detour_sequence/1) == plain_rows

      # The doubling really happened: every Route 20 row is even and every
      # Route 1 row keeps its stored value.
      route_20_sequences =
        main_rows
        |> Enum.filter(&(trip_of(&1) in @route_20_trips))
        |> Enum.map(&sequence_of/1)

      assert route_20_sequences != []
      assert Enum.all?(route_20_sequences, &(rem(&1, 2) == 0))

      route_1_sequences =
        main_rows
        |> Enum.filter(&(trip_of(&1) == "1-weekday"))
        |> Enum.map(&sequence_of/1)

      assert route_1_sequences == [1, 2]
    end

    test "Route 20 timed sequences match between the zips and stay stable", context do
      feed = flex_representative_fixture(context.organization, context.version)

      assert {:ok, %{main: main, flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      assert warning_code?(warnings, "flex_detour_same_time")

      assert timed_sequences(main) == timed_sequences(flex)

      fix_same_time_pair(feed)

      assert {:ok, %{main: main_fixed, flex: flex_fixed}, warnings_fixed} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      refute warning_code?(warnings_fixed, "flex_detour_same_time")
      assert timed_sequences(main_fixed) == timed_sequences(main)
      assert timed_sequences(flex_fixed) == timed_sequences(flex)

      assert {:ok, %{main: main_plain}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: false
               )

      assert timed_sequences(main_plain) == timed_sequences(main)
    end

    test "the operations profile doubles the same sequences", context do
      flex_representative_fixture(context.organization, context.version)

      assert {:ok, operations, _warnings} =
               Export.build_zip(context.organization_id, context.gtfs_version_id, :operations)

      stored = stored_sequences(context.organization_id, context.gtfs_version_id)

      for row <- csv_rows(zip_files(operations)["stop_times.txt"]) do
        expected =
          if row["trip_id"] in @route_20_trips do
            Map.fetch!(stored, {row["trip_id"], row["stop_id"]}) * 2
          else
            Map.fetch!(stored, {row["trip_id"], row["stop_id"]})
          end

        assert String.to_integer(row["stop_sequence"]) == expected,
               "unexpected sequence for #{row["trip_id"]} #{row["stop_id"]}"
      end
    end
  end

  describe "exclusions and warnings" do
    test "a readiness error is left out with its first error and no main byte changes", context do
      flex_representative_fixture(context.organization, context.version)

      assert {:ok, %{main: main_before}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      broken_service(context)

      assert {:ok, %{main: main_after, flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      assert zip_files(main_after) == zip_files(main_before)

      warning = Enum.find(warnings, &(&1.code == "flex_service_excluded"))
      refute is_nil(warning)
      assert warning.detail =~ "Broken Shuttle"
      assert warning.detail =~ "absent"

      # One service of five routes is left out: below both Transit thresholds.
      refute warning_code?(warnings, "transit_hold_risk")

      files = zip_files(flex)
      refute files["routes.txt"] =~ "flex-broken-shuttle"

      document = Jason.decode!(files["locations.geojson"])
      refute Enum.any?(document["features"], &(&1["id"] == "flex-broken-shuttle-a1"))
    end

    test "a route-distance area whose route is gone is left out and names the route", context do
      flex_representative_fixture(context.organization, context.version)

      distance_service(context, "Distance Shuttle", ["ghost"])

      assert {:ok, %{flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      warning = Enum.find(warnings, &(&1.code == "flex_service_excluded"))
      refute is_nil(warning)
      assert warning.detail =~ "Distance Shuttle"
      assert warning.detail =~ "ghost"

      files = zip_files(flex)
      refute files["routes.txt"] =~ "flex-distance-shuttle"
      refute files["locations.geojson"] =~ "flex-distance-shuttle-a1"
    end

    test "a route-distance area on a shapeless route fails geometry at export", context do
      flex_representative_fixture(context.organization, context.version)

      route_fixture(context.organization_id, context.gtfs_version_id, %{route_id: "SHAPELESS"})
      distance_service(context, "Distance Shuttle", ["SHAPELESS"])

      assert {:ok, %{flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      warning = Enum.find(warnings, &(&1.code == "flex_service_excluded"))
      refute is_nil(warning)
      assert warning.detail =~ "Distance Shuttle"
      assert warning.detail =~ "no shape"

      refute zip_files(flex)["locations.geojson"] =~ "flex-distance-shuttle-a1"
    end

    test "a registered-riders service is exported only when include_registered is true",
         context do
      feed = flex_representative_fixture(context.organization, context.version)

      assert {:ok, %{flex: flex}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      files = zip_files(flex)
      assert files["routes.txt"] =~ "Newport Access (registered riders)"
      assert files["booking_rules.txt"] =~ "For registered riders only: adults 60 and older"

      loaded = load_service(context, feed.services.registered.id)

      assert {:ok, _service} =
               Flex.save_service(
                 flex_audit_fixture(context.organization_id, context.gtfs_version_id),
                 loaded,
                 %{include_registered: false},
                 area_inputs(loaded)
               )

      assert {:ok, %{flex: flex_off}, warnings_off} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      files_off = zip_files(flex_off)
      refute files_off["routes.txt"] =~ "flex-newport-access"
      refute files_off["booking_rules.txt"] =~ "For registered riders only"
      refute warning_code?(warnings_off, "flex_service_excluded")
      refute warning_code?(warnings_off, "transit_hold_risk")
    end

    test "a deactivated service stays out of the flex zip without a warning", context do
      feed = flex_representative_fixture(context.organization, context.version)

      assert {:ok, _service} =
               Flex.set_active(
                 flex_audit_fixture(context.organization_id, context.gtfs_version_id),
                 feed.services.registered.id,
                 false
               )

      assert {:ok, %{flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      refute zip_files(flex)["routes.txt"] =~ "flex-newport-access"
      refute warning_code?(warnings, "flex_service_excluded")
    end
  end

  describe "stored flex files" do
    test "a stored booking rule and the flex rules share one booking_rules.txt", context do
      flex_representative_fixture(context.organization, context.version)

      %BookingRule{
        organization_id: context.organization_id,
        gtfs_version_id: context.gtfs_version_id
      }
      |> BookingRule.changeset(%{booking_rule_id: "imported-book", booking_type: 0})
      |> Repo.insert!()

      assert {:ok, %{flex: flex}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      {:ok, entries} = :zip.unzip(flex, [:memory])
      booking_files = for {~c"booking_rules.txt", content} <- entries, do: content

      assert [content] = booking_files

      ids = content |> csv_rows() |> Enum.map(& &1["booking_rule_id"])
      assert "imported-book" in ids
      assert "flex-valley-line-detours-book" in ids
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "inactive routes" do
    test "a detour on an inactive route is left out with a warning and adds no zone rows",
         context do
      flex_representative_fixture(context.organization, context.version)
      deactivate_routes(context, ["20"])

      assert {:ok, %{main: main, flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      warning = Enum.find(warnings, &(&1.detail =~ "Valley Line detours"))
      assert warning.code == "flex_service_excluded"
      assert warning.detail =~ "inactive"

      refute zip_files(main)["routes.txt"] =~ "Valley Line"

      files = zip_files(flex)
      refute files["stop_times.txt"] =~ "flex-valley-line-detours"
      refute files["locations.geojson"] =~ "flex-valley-line-detours"
      refute files["booking_rules.txt"] =~ "flex-valley-line-detours"
    end

    test "a version whose routes are all inactive makes the flex zip its only feed", context do
      flex_representative_fixture(context.organization, context.version)
      deactivate_routes(context, ["1", "20"])

      assert {:ok, %{main: nil, flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      assert warning_code?(warnings, "main_feed_not_produced")

      routes = flex |> zip_files() |> Map.fetch!("routes.txt") |> csv_rows()
      assert Enum.all?(routes, &String.starts_with?(&1["route_id"], "flex-"))
    end
  end

  describe "when the flex zip is built" do
    test "a version without flex services builds the main zip only", context do
      flex_feed_fixture(context.organization, context.version)

      assert {:ok, %{main: main, flex: nil}, []} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      assert is_binary(main)
    end

    test "a flex build that fails in PostgreSQL leaves the main zip and warns", context do
      feed = flex_representative_fixture(context.organization, context.version)

      assert {:ok, plain, _warnings} =
               Export.build_zip(context.organization_id, context.gtfs_version_id, :full)

      # A bow-tie ring written past `Flex.Geometry`'s validation: the export's
      # `ST_ReducePrecision` raises on it inside the snapshot transaction.
      [area | _rest] = load_service(context, feed.services.area.id).areas

      Repo.query!(
        "UPDATE flex_areas SET geom = ST_Multi(ST_GeomFromText(" <>
          "'POLYGON((-124.09 44.57, -124.08 44.58, -124.08 44.57, -124.09 44.58, -124.09 44.57))'" <>
          ", 4326)) WHERE id = $1",
        [Ecto.UUID.dump!(area.id)]
      )

      assert {:ok, %{main: main, flex: nil}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      assert Enum.map(warnings, & &1.code) == ["flex_build_failed"]

      assert Map.delete(zip_files(main), "stop_times.txt") ==
               Map.delete(zip_files(plain), "stop_times.txt")

      # The snapshot transaction rolled back to its savepoint, so the
      # connection still answers.
      assert Repo.aggregate(Trip, :count) > 0
    end
  end

  describe "no fixed routes (R15)" do
    test "the flex zip is the run's only feed with a main_feed_not_produced warning", context do
      agency_fixture(context.organization_id, context.gtfs_version_id, %{
        agency_id: "SOLO",
        agency_name: "Solo Transit",
        agency_url: "https://example.org",
        agency_timezone: "America/Los_Angeles"
      })

      calendar_fixture(context.organization_id, context.gtfs_version_id, %{
        service_id: "weekday",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0
      })

      {:ok, service} =
        Flex.create_service(flex_audit_fixture(context.organization_id, context.gtfs_version_id), %{
          name: "Only Feed Shuttle",
          kind: :area
        })

      assert {:ok, _service} =
               Flex.save_service(
                 flex_audit_fixture(context.organization_id, context.gtfs_version_id),
                 service,
                 %{
                   phone: "(541) 555-0142",
                   hours: [%{area_key: "a1", service_id: "weekday", start: "08:00", end: "17:00"}],
                   booking_rules: [%{when: :same_day, minutes: 60}]
                 },
                 [%{key: "a1", name: "Solo", source: :drawn, geojson: @drawn_area}]
               )

      assert {:ok, %{main: nil, flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      assert warning_code?(warnings, "main_feed_not_produced")

      files = zip_files(flex)
      assert files["routes.txt"] =~ "flex-only-feed-shuttle"
      assert files["stop_times.txt"] =~ "start_pickup_drop_off_window"
      assert files["locations.geojson"] =~ "flex-only-feed-shuttle-a1"
    end
  end

  describe "Transit hold (AC-25)" do
    test "75% of the routes left out adds the warning", context do
      route_fixture(context.organization_id, context.gtfs_version_id, %{route_id: "1"})

      for index <- 1..3 do
        {:ok, service} =
          Flex.create_service(flex_audit_fixture(context.organization_id, context.gtfs_version_id), %{
            name: "Hold #{index} Shuttle",
            kind: :area
          })

        # No area, so the service is a readiness error and its generated route
        # is absent from the flex zip.
        assert {:ok, _service} =
                 Flex.save_service(
                   flex_audit_fixture(context.organization_id, context.gtfs_version_id),
                   service,
                   %{
                     phone: "(541) 555-0142",
                     hours: [
                       %{area_key: "a1", service_id: "weekday", start: "08:00", end: "17:00"}
                     ],
                     booking_rules: [%{when: :same_day, minutes: 60}]
                   },
                   []
                 )
      end

      assert {:ok, %{flex: flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      warning = Enum.find(warnings, &(&1.code == "transit_hold_risk"))
      refute is_nil(warning)
      assert warning.detail =~ "3 of 4"
      assert zip_files(flex)["routes.txt"] =~ "route_id"
    end

    test "a frequent excluded route adds the warning below the route threshold", context do
      route_fixture(context.organization_id, context.gtfs_version_id, %{route_id: "1"})

      calendar_fixture(context.organization_id, context.gtfs_version_id, %{
        service_id: "weekday",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0
      })

      {:ok, service} =
        Flex.create_service(flex_audit_fixture(context.organization_id, context.gtfs_version_id), %{
          name: "Frequent Flex",
          kind: :area
        })

      # 42 half-hour windows make 42 generated trips on the busiest day; no
      # contact is a readiness error, so the route is left out and frequent.
      hours =
        for minutes <- Enum.take_every(0..1230, 30) do
          %{
            area_key: "a1",
            service_id: "weekday",
            start: hhmm(minutes),
            end: hhmm(minutes + 30)
          }
        end

      assert {:ok, _service} =
               Flex.save_service(
                 flex_audit_fixture(context.organization_id, context.gtfs_version_id),
                 service,
                 %{
                   hours: hours,
                   booking_rules: [%{when: :same_day, minutes: 60}]
                 },
                 [%{key: "a1", name: "Frequent", source: :drawn, geojson: @drawn_area}]
               )

      assert {:ok, %{flex: _flex}, warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      warning = Enum.find(warnings, &(&1.code == "transit_hold_risk"))
      refute is_nil(warning)
      assert warning.detail =~ "1 of 2 routes"
      assert warning.detail =~ "1 of 1"
    end
  end

  describe "stored data (AC-26)" do
    test "authoring and exporting flex leaves trips, stop times, blocks and calendars unchanged",
         context do
      flex_feed_fixture(context.organization, context.version)

      before = stored_counts(context)

      flex_services_fixture(context.organization, context.version)

      assert {:ok, %{main: main, flex: flex}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      assert is_binary(main)
      assert is_binary(flex)
      assert stored_counts(context) == before
    end
  end

  describe "delegation" do
    test "build_zip/3 is build_zips without flex, and export_to_zip/4 :flex is the flex zip",
         context do
      flex_representative_fixture(context.organization, context.version)

      assert {:ok, %{main: main}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: false
               )

      assert {:ok, plain, _warnings} =
               Export.build_zip(context.organization_id, context.gtfs_version_id, :full)

      assert zip_files(main) == zip_files(plain)

      assert {:ok, flex} =
               Export.export_to_zip(context.organization_id, context.gtfs_version_id, :flex, [])

      assert {:ok, %{flex: flex_from_build}, _warnings} =
               Export.build_zips(context.organization_id, context.gtfs_version_id, :full,
                 include_flex: true
               )

      assert zip_files(flex) == zip_files(flex_from_build)
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp zip_files(zip) do
    {:ok, files} = :zip.unzip(zip, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  defp lines(content), do: content |> to_string() |> String.split("\n", trim: true)

  defp csv_rows(content) do
    case lines(content) do
      [] ->
        []

      [header | rows] ->
        columns = String.split(header, ",")

        Enum.map(rows, fn row ->
          columns |> Enum.zip(String.split(row, ",")) |> Map.new()
        end)
    end
  end

  defp coordinates(geometry) do
    geometry["coordinates"] |> List.flatten() |> Enum.filter(&is_number/1)
  end

  defp decimals(number) when is_float(number) do
    number
    |> :erlang.float_to_binary([:short])
    |> String.split(".")
    |> List.last()
    |> String.length()
  end

  defp decimals(_number), do: 0

  defp trip_of(row) do
    row |> String.split(",") |> hd()
  end

  defp sequence_of(row) do
    row |> String.split(",") |> Enum.at(4) |> String.to_integer()
  end

  # The flex-included main zip doubles the detour route's sequences; halving
  # them again compares it with the export of the same data without the detour
  # service.
  defp halve_detour_sequence(row) do
    [trip_id, arrival, departure, stop_id, sequence | rest] = String.split(row, ",")

    if trip_id in @route_20_trips do
      sequence = div(String.to_integer(sequence), 2)

      [trip_id, arrival, departure, stop_id, Integer.to_string(sequence) | rest]
      |> Enum.join(",")
    else
      row
    end
  end

  defp timed_sequences(zip) do
    zip
    |> zip_files()
    |> Map.fetch!("stop_times.txt")
    |> csv_rows()
    |> Enum.filter(fn row ->
      row["trip_id"] in @route_20_trips and row["stop_id"] not in [nil, ""]
    end)
    |> Enum.map(&{&1["trip_id"], &1["stop_id"], &1["stop_sequence"]})
  end

  defp stored_sequences(organization_id, version_id) do
    from(st in StopTime,
      where: st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id,
      select: {st.trip_id, st.stop_id, st.stop_sequence}
    )
    |> Repo.all()
    |> Map.new(fn {trip_id, stop_id, sequence} -> {{trip_id, stop_id}, sequence} end)
  end

  defp warning_code?(warnings, code), do: Enum.any?(warnings, &(&1.code == code))

  defp stored_counts(context) do
    {:ok, day} = Blocking.load_day(context.organization_id, context.gtfs_version_id, nil)

    {:ok, usage} =
      Calendars.calendar_usage(context.organization_id, context.gtfs_version_id, "weekday")

    %{
      trips:
        Repo.aggregate(
          from(t in Trip,
            where:
              t.organization_id == ^context.organization_id and
                t.gtfs_version_id == ^context.gtfs_version_id
          ),
          :count
        ),
      stop_times:
        Repo.aggregate(
          from(st in StopTime,
            where:
              st.organization_id == ^context.organization_id and
                st.gtfs_version_id == ^context.gtfs_version_id
          ),
          :count
        ),
      day_trips: day.counts.trips,
      calendar_usage: usage
    }
  end

  defp deactivate_routes(context, route_ids) do
    from(r in Route,
      where:
        r.organization_id == ^context.organization_id and
          r.gtfs_version_id == ^context.gtfs_version_id and r.route_id in ^route_ids
    )
    |> Repo.update_all(set: [active: false])
  end

  defp delete_services(context) do
    services = Flex.list_services(context.organization_id, context.gtfs_version_id)

    Enum.each(services, fn service ->
      assert :ok =
               Flex.delete_service(
                 flex_audit_fixture(context.organization_id, context.gtfs_version_id),
                 service.id
               )
    end)
  end

  defp load_service(context, id) do
    assert {:ok, service} = Flex.get_service(context.organization_id, context.gtfs_version_id, id)
    service
  end

  defp area_inputs(service) do
    stored = Geometry.get_geojson(Enum.map(service.areas, & &1.id))

    Enum.map(service.areas, fn area ->
      %{key: area.key, name: area.name, source: area.source, geojson: stored[area.id]}
    end)
  end

  # An area service whose only hours row names a calendar the version does not
  # have: its first readiness error names the missing calendar.
  defp broken_service(context) do
    {:ok, service} =
      Flex.create_service(flex_audit_fixture(context.organization_id, context.gtfs_version_id), %{
        name: "Broken Shuttle",
        kind: :area
      })

    assert {:ok, _service} =
             Flex.save_service(
               flex_audit_fixture(context.organization_id, context.gtfs_version_id),
               service,
               %{
                 phone: "(541) 555-0142",
                 hours: [%{area_key: "a1", service_id: "absent", start: "08:00", end: "17:00"}],
                 booking_rules: [%{when: :same_day, minutes: 60}]
               },
               [%{key: "a1", name: "Broken", source: :drawn, geojson: @drawn_area}]
             )
  end

  defp distance_service(context, name, route_ids) do
    {:ok, service} =
      Flex.create_service(flex_audit_fixture(context.organization_id, context.gtfs_version_id), %{
        name: name,
        kind: :area
      })

    assert {:ok, _service} =
             Flex.save_service(
               flex_audit_fixture(context.organization_id, context.gtfs_version_id),
               service,
               %{
                 phone: "(541) 555-0142",
                 hours: [%{area_key: "a1", service_id: "weekday", start: "08:00", end: "17:00"}],
                 booking_rules: [%{when: :same_day, minutes: 60}]
               },
               [
                 %{
                   key: "a1",
                   name: "Distance",
                   source: :route_distance,
                   route_ids: route_ids,
                   distance_m: 400
                 }
               ]
             )
  end

  defp hhmm(minutes) do
    [div(minutes, 60), rem(minutes, 60)]
    |> Enum.map_join(":", &(&1 |> Integer.to_string() |> String.pad_leading(2, "0")))
  end
end
