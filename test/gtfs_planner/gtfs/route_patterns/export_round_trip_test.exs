defmodule GtfsPlanner.Gtfs.RoutePatterns.ExportRoundTripTest do
  @moduledoc """
  Merge evidence (EV-8) for the export boundary: the full export publishes route
  pattern identities and trip pattern links, re-import preserves supplied
  identities, custom service and materialized times, and every export reads
  route patterns, trips and stop times from one repeatable-read snapshot.

  Fixtures are committed on dedicated connections so the export-race case can
  commit an independent edit while a real export is reading. Each test captures
  its organization IDs and deletes exactly those rows in foreign-key order,
  asserting absence afterwards; no unscoped table scan is used.
  """
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.FileSpec
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @pattern_header "route_pattern_id,route_id,direction_id,route_pattern_name," <>
                    "route_pattern_time_desc,route_pattern_typicality," <>
                    "route_pattern_sort_order,representative_trip_id,canonical_route_pattern"

  @trips_header "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id," <>
                  "block_id,shape_id,wheelchair_accessible,bikes_allowed,route_pattern_id"

  @internal_columns ~w(id organization_id gtfs_version_id derivation_key timed_pattern_id
                       pattern_derivation_state pattern_derivation_reason headsign active
                       inserted_at updated_at)

  test "full export publishes the nine route pattern columns and trip links without internal metadata" do
    org = new_org("export-columns")
    on_exit(fn -> cleanup([org.id]) end)

    fixture =
      unboxed(fn ->
        version = gtfs_version_fixture(org.id)
        route = route_fixture(org.id, version.id, route_id: "RP_ROUTE", route_short_name: "RP")
        s1 = stop_fixture(org.id, version.id, stop_id: "RP_S1")
        s2 = stop_fixture(org.id, version.id, stop_id: "RP_S2")

        pattern_a =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "RP_A",
            route_id: route.route_id,
            direction_id: 0,
            route_pattern_name: "Alpha",
            route_pattern_time_desc: "Saturday",
            route_pattern_typicality: 1,
            route_pattern_sort_order: 1,
            representative_trip_id: nil,
            canonical_route_pattern: 0
          })

        pattern_b =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "RP_B",
            route_id: route.route_id,
            direction_id: 1,
            route_pattern_name: "Beta",
            route_pattern_time_desc: "Weekday",
            route_pattern_typicality: 2,
            route_pattern_sort_order: 3,
            representative_trip_id: "RP_TRIP_LINKED",
            canonical_route_pattern: 1,
            headsign: "PATTERN_INTERNAL_HEADSIGN",
            derivation_key: "PATTERN_DERIVATION_HASH"
          })

        occ_b1 = route_pattern_stop_fixture(pattern_b, s1.stop_id, 1)
        occ_b2 = route_pattern_stop_fixture(pattern_b, s2.stop_id, 2)

        timing =
          timed_pattern_fixture(pattern_b, %{
            name: "INTERNAL_TIMING_NAME",
            derivation_key: "TIMING_DERIVATION_HASH"
          })

        timed_pattern_stop_fixture(timing, occ_b1, %{arrival_offset: 0, departure_offset: 0})
        timed_pattern_stop_fixture(timing, occ_b2, %{arrival_offset: 300, departure_offset: 300})

        linked =
          trip_fixture(org.id, version.id, "RP_ROUTE",
            trip_id: "RP_TRIP_LINKED",
            service_id: "WEEKDAY",
            direction_id: 1,
            trip_headsign: "Linked Destination"
          )

        trip_pattern_metadata_fixture(linked, %{
          route_pattern_id: "RP_B",
          timed_pattern_id: timing.id,
          pattern_derivation_state: "linked",
          pattern_derivation_reason: nil
        })

        custom =
          trip_fixture(org.id, version.id, "RP_ROUTE",
            trip_id: "RP_TRIP_CUSTOM",
            service_id: "WEEKDAY",
            direction_id: 0,
            trip_headsign: "Custom Destination"
          )

        trip_pattern_metadata_fixture(custom, %{
          route_pattern_id: "RP_ABSENT_PATTERN",
          timed_pattern_id: nil,
          pattern_derivation_state: "custom",
          pattern_derivation_reason: "missing_pattern"
        })

        stop_time_fixture(org.id, version.id, "RP_TRIP_LINKED", "RP_S1",
          stop_sequence: 1,
          arrival_time: "06:00:00",
          departure_time: "06:00:00"
        )

        stop_time_fixture(org.id, version.id, "RP_TRIP_LINKED", "RP_S2",
          stop_sequence: 5,
          arrival_time: "06:05:00",
          departure_time: "06:05:00"
        )

        stop_time_fixture(org.id, version.id, "RP_TRIP_CUSTOM", "RP_S1",
          stop_sequence: 1,
          arrival_time: "07:00:00",
          departure_time: "07:00:00"
        )

        audit =
          Repo.insert!(
            ChangeLog.changeset(%ChangeLog{}, %{
              entity_type: "route_pattern",
              entity_id: pattern_b.id,
              entity_external_id: "RP_B",
              station_stop_id: nil,
              actor_id: Ecto.UUID.generate(),
              actor_email: "AUDIT_METADATA_ACTOR@example.com",
              action: "updated",
              snapshot: %{"route_pattern_name" => "AUDIT_METADATA_SNAPSHOT"},
              changed_fields: %{"route_pattern_name" => "AUDIT_METADATA_CHANGED_FIELD"},
              organization_id: org.id,
              gtfs_version_id: version.id
            })
          )

        %{
          version: version,
          pattern_a: pattern_a,
          pattern_b: pattern_b,
          linked: linked,
          custom: custom,
          audit: audit
        }
      end)

    {:ok, zip} =
      unboxed(fn -> Export.export_to_zip(org.id, fixture.version.id, :full) end)

    files = unzip(zip)
    names = filenames(files)

    assert "route_patterns.txt" in names
    refute "timed_patterns.txt" in names
    refute "route_pattern_stops.txt" in names
    refute "timed_pattern_stops.txt" in names
    refute "change_logs.txt" in names

    pattern_lines = csv_lines(files, "route_patterns.txt")
    assert hd(pattern_lines) == @pattern_header

    [first_row, second_row] = tl(pattern_lines)

    assert first_row == "RP_A,RP_ROUTE,0,Alpha,Saturday,1,1,,0"
    assert second_row == "RP_B,RP_ROUTE,1,Beta,Weekday,2,3,RP_TRIP_LINKED,1"

    trip_lines = csv_lines(files, "trips.txt")
    assert hd(trip_lines) == @trips_header

    linked_row = Enum.find(trip_lines, &(&1 =~ "RP_TRIP_LINKED"))
    custom_row = Enum.find(trip_lines, &(&1 =~ "RP_TRIP_CUSTOM"))
    assert linked_row |> split_row() |> List.last() == "RP_B"
    assert custom_row |> split_row() |> List.last() == "RP_ABSENT_PATTERN"

    assert linked_row |> split_row() |> Enum.at(5) == "1"
    assert custom_row |> split_row() |> Enum.at(3) == "Custom Destination"

    Enum.each(files, fn {name, content} ->
      text = to_string(content)

      if String.ends_with?(to_string(name), ".txt") do
        header_columns = text |> String.split("\n", trim: true) |> hd() |> split_row()

        refute Enum.any?(@internal_columns, &(&1 in header_columns)),
               "#{name} leaked an internal column: #{inspect(header_columns)}"
      end

      refute text =~ "PATTERN_DERIVATION_HASH"
      refute text =~ "TIMING_DERIVATION_HASH"
      refute text =~ "INTERNAL_TIMING_NAME"
      refute text =~ "PATTERN_INTERNAL_HEADSIGN"
      refute text =~ "missing_pattern"
      refute text =~ "AUDIT_METADATA_ACTOR"
      refute text =~ "AUDIT_METADATA_SNAPSHOT"
      refute text =~ "AUDIT_METADATA_CHANGED_FIELD"
    end)

    {:ok, pathways_zip} =
      unboxed(fn -> Export.export_to_zip(org.id, fixture.version.id, :pathways) end)

    refute "route_patterns.txt" in filenames(unzip(pathways_zip))

    output_dir =
      Path.join(System.tmp_dir!(), "rt-dir-export-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(output_dir) end)

    assert {:ok, written_paths} =
             unboxed(fn ->
               Export.export_specs_to_directory(
                 org.id,
                 fixture.version.id,
                 FileSpec.get_specs(:full),
                 output_dir
               )
             end)

    assert Enum.any?(written_paths, &(Path.basename(&1) == "route_patterns.txt"))

    assert File.read!(Path.join(output_dir, "route_patterns.txt")) =~
             "RP_B,RP_ROUTE,1,Beta,Weekday,2,3,RP_TRIP_LINKED,1"
  end

  test "export then import into a second version preserves pattern IDs, custom trips and materialized times" do
    org = new_org("round-trip")
    on_exit(fn -> cleanup([org.id]) end)

    version_a =
      unboxed(fn ->
        version = gtfs_version_fixture(org.id)
        _agency = agency_fixture(org.id, version.id, agency_id: "RT_AGENCY")
        _route = route_fixture(org.id, version.id, route_id: "RT_ROUTE", route_short_name: "RT")

        for stop_id <- ["RT_S1", "RT_S2", "RT_S3"] do
          stop_fixture(org.id, version.id, stop_id: stop_id)
        end

        pattern =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "RT_PATTERN",
            route_id: "RT_ROUTE",
            direction_id: 0,
            route_pattern_name: "Round Trip",
            route_pattern_time_desc: "Weekday",
            route_pattern_typicality: 2,
            route_pattern_sort_order: 5,
            representative_trip_id: "RT_LINKED",
            canonical_route_pattern: 1,
            derivation_key: "RT_PATTERN_SIG"
          })

        occurrences =
          ["RT_S1", "RT_S2", "RT_S3"]
          |> Enum.with_index(1)
          |> Enum.map(fn {stop_id, position} ->
            route_pattern_stop_fixture(pattern, stop_id, position)
          end)

        timing =
          timed_pattern_fixture(pattern, %{name: "Round Timing", derivation_key: "RT_TIMING_SIG"})

        occurrences
        |> Enum.with_index()
        |> Enum.each(fn {occurrence, index} ->
          offset = index * 60

          timed_pattern_stop_fixture(timing, occurrence, %{
            arrival_offset: offset,
            departure_offset: offset
          })
        end)

        linked =
          trip_fixture(org.id, version.id, "RT_ROUTE",
            trip_id: "RT_LINKED",
            service_id: "WEEKDAY",
            direction_id: 0,
            trip_headsign: "Linked Destination"
          )

        trip_pattern_metadata_fixture(linked, %{
          route_pattern_id: "RT_PATTERN",
          timed_pattern_id: timing.id,
          pattern_derivation_state: "linked",
          pattern_derivation_reason: nil
        })

        custom =
          trip_fixture(org.id, version.id, "RT_ROUTE",
            trip_id: "RT_CUSTOM",
            service_id: "WEEKDAY",
            direction_id: 0,
            trip_headsign: "Custom Destination"
          )

        trip_pattern_metadata_fixture(custom, %{
          route_pattern_id: "RT_ABSENT",
          timed_pattern_id: nil,
          pattern_derivation_state: "custom",
          pattern_derivation_reason: "missing_pattern"
        })

        for {trip_id, stop_id, sequence, arrival} <- [
              {"RT_LINKED", "RT_S1", 1, "06:00:00"},
              {"RT_LINKED", "RT_S2", 5, "06:02:00"},
              {"RT_LINKED", "RT_S3", 10, "06:04:00"}
            ] do
          stop_time_fixture(org.id, version.id, trip_id, stop_id,
            stop_sequence: sequence,
            arrival_time: arrival,
            departure_time: arrival
          )
        end

        stop_time_fixture(org.id, version.id, "RT_CUSTOM", "RT_S1",
          stop_sequence: 1,
          arrival_time: "07:00:00",
          departure_time: "07:00:00",
          stop_headsign: "Custom Stop Destination"
        )

        stop_time_fixture(org.id, version.id, "RT_CUSTOM", "RT_S2",
          stop_sequence: 2,
          arrival_time: "07:05:00",
          departure_time: "07:05:00"
        )

        version
      end)

    {:ok, zip} = unboxed(fn -> Export.export_to_zip(org.id, version_a.id, :full) end)
    files = unzip(zip)

    import_files =
      Enum.map(files, fn {name, content} -> %{filename: to_string(name), content: content} end)

    version_b = new_version(org)

    assert {:ok, _result} =
             unboxed(fn -> Import.import_files(org.id, version_b.id, import_files) end)

    imported =
      unboxed(fn ->
        patterns =
          Repo.all(
            from(p in RoutePattern,
              where: p.organization_id == ^org.id and p.gtfs_version_id == ^version_b.id,
              order_by: p.route_pattern_id
            )
          )

        linked =
          Repo.one!(
            from(t in Trip,
              where:
                t.organization_id == ^org.id and t.gtfs_version_id == ^version_b.id and
                  t.trip_id == "RT_LINKED"
            )
          )

        custom =
          Repo.one!(
            from(t in Trip,
              where:
                t.organization_id == ^org.id and t.gtfs_version_id == ^version_b.id and
                  t.trip_id == "RT_CUSTOM"
            )
          )

        custom_first_stop =
          Repo.one!(
            from(st in StopTime,
              where:
                st.organization_id == ^org.id and st.gtfs_version_id == ^version_b.id and
                  st.trip_id == "RT_CUSTOM" and st.stop_sequence == 1
            )
          )

        %{
          patterns: patterns,
          linked: linked,
          custom: custom,
          custom_first_stop: custom_first_stop,
          times: %{
            linked_a: numeric_times(org.id, version_a.id, "RT_LINKED"),
            linked_b: numeric_times(org.id, version_b.id, "RT_LINKED"),
            custom_a: numeric_times(org.id, version_a.id, "RT_CUSTOM"),
            custom_b: numeric_times(org.id, version_b.id, "RT_CUSTOM")
          }
        }
      end)

    assert [pattern] = imported.patterns
    assert pattern.route_pattern_id == "RT_PATTERN"
    assert pattern.route_id == "RT_ROUTE"
    assert pattern.direction_id == 0
    assert pattern.route_pattern_name == "Round Trip"
    assert pattern.route_pattern_time_desc == "Weekday"
    assert pattern.route_pattern_typicality == 2
    assert pattern.route_pattern_sort_order == 5
    assert pattern.representative_trip_id == "RT_LINKED"
    assert pattern.canonical_route_pattern == 1

    assert imported.linked.route_pattern_id == "RT_PATTERN"
    assert imported.linked.pattern_derivation_state == "linked"
    assert imported.linked.trip_headsign == "Linked Destination"

    assert imported.custom.route_pattern_id == "RT_ABSENT"
    assert imported.custom.pattern_derivation_state == "custom"
    assert imported.custom.pattern_derivation_reason != nil
    assert imported.custom.trip_headsign == "Custom Destination"

    assert imported.custom_first_stop.stop_headsign == "Custom Stop Destination"

    assert imported.times.linked_a == imported.times.linked_b
    assert imported.times.custom_a == imported.times.custom_b
  end

  test "sparse timing-only labels and structural 1..N labels survive the export unchanged" do
    org = new_org("labels")
    on_exit(fn -> cleanup([org.id]) end)

    version =
      unboxed(fn ->
        version = gtfs_version_fixture(org.id)
        route = route_fixture(org.id, version.id, route_id: "LBL_ROUTE", route_short_name: "LBL")

        for stop_id <- ["LBL_S1", "LBL_S2", "LBL_S3"] do
          stop_fixture(org.id, version.id, stop_id: stop_id)
        end

        pattern =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "LBL_PATTERN",
            route_id: route.route_id,
            direction_id: 0
          })

        occurrences =
          ["LBL_S1", "LBL_S2", "LBL_S3"]
          |> Enum.with_index(1)
          |> Enum.map(fn {stop_id, position} ->
            route_pattern_stop_fixture(pattern, stop_id, position)
          end)

        timing = timed_pattern_fixture(pattern, %{name: "Label Timing"})

        occurrences
        |> Enum.with_index()
        |> Enum.each(fn {occurrence, index} ->
          offset = index * 120

          timed_pattern_stop_fixture(timing, occurrence, %{
            arrival_offset: offset,
            departure_offset: offset
          })
        end)

        for {trip_id, labels} <- [{"LBL_SPARSE", [1, 5, 10]}, {"LBL_STRUCT", [1, 2, 3]}] do
          trip = trip_fixture(org.id, version.id, "LBL_ROUTE", trip_id: trip_id, direction_id: 0)

          trip_pattern_metadata_fixture(trip, %{
            route_pattern_id: "LBL_PATTERN",
            timed_pattern_id: timing.id,
            pattern_derivation_state: "linked",
            pattern_derivation_reason: nil
          })

          ["LBL_S1", "LBL_S2", "LBL_S3"]
          |> Enum.zip(labels)
          |> Enum.with_index()
          |> Enum.each(fn {{stop_id, label}, index} ->
            clock = "0#{8 + index}:00:00"

            stop_time_fixture(org.id, version.id, trip_id, stop_id,
              stop_sequence: label,
              arrival_time: clock,
              departure_time: clock
            )
          end)
        end

        version
      end)

    {:ok, zip} = unboxed(fn -> Export.export_to_zip(org.id, version.id, :full) end)
    files = unzip(zip)

    rows = csv_lines(files, "stop_times.txt") |> tl()

    labels_for = fn trip_id ->
      rows
      |> Enum.filter(&(&1 =~ trip_id))
      |> Enum.map(&(&1 |> split_row() |> Enum.at(4) |> String.to_integer()))
    end

    assert labels_for.("LBL_SPARSE") == [1, 5, 10]
    assert labels_for.("LBL_STRUCT") == [1, 2, 3]
  end

  test "a committed edit from a separate connection cannot mix pre-edit trips with post-edit stop times" do
    previous_snapshot = Application.get_env(:gtfs_planner, :gtfs_export_snapshot)

    Application.put_env(
      :gtfs_planner,
      :gtfs_export_snapshot,
      GtfsPlanner.Gtfs.Export.Snapshot.Repo
    )

    on_exit(fn ->
      if is_nil(previous_snapshot) do
        Application.delete_env(:gtfs_planner, :gtfs_export_snapshot)
      else
        Application.put_env(:gtfs_planner, :gtfs_export_snapshot, previous_snapshot)
      end
    end)

    org = new_org("export-race")
    on_exit(fn -> cleanup([org.id]) end)

    fixture =
      unboxed(fn ->
        version = gtfs_version_fixture(org.id)
        _agency = agency_fixture(org.id, version.id, agency_id: "CONC_AGENCY")
        route = route_fixture(org.id, version.id, route_id: "CONC_ROUTE", route_short_name: "C")

        for stop_id <- ["CONC_S1", "CONC_S2"] do
          stop_fixture(org.id, version.id, stop_id: stop_id)
        end

        pattern =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "CONC_PATTERN",
            route_id: route.route_id,
            direction_id: 0,
            route_pattern_name: "Concurrent",
            route_pattern_time_desc: "Before",
            route_pattern_typicality: 0,
            route_pattern_sort_order: 0
          })

        trip =
          trip_fixture(org.id, version.id, route.route_id,
            trip_id: "CONC_TRIP",
            service_id: "WEEKDAY",
            direction_id: 0,
            trip_headsign: "Before"
          )

        trip_pattern_metadata_fixture(trip, %{
          route_pattern_id: "CONC_PATTERN",
          timed_pattern_id: nil,
          pattern_derivation_state: "custom",
          pattern_derivation_reason: "missing_times"
        })

        for {stop_id, sequence, clock} <- [
              {"CONC_S1", 1, "08:00:00"},
              {"CONC_S2", 2, "08:10:00"}
            ] do
          stop_time_fixture(org.id, version.id, "CONC_TRIP", stop_id,
            stop_sequence: sequence,
            arrival_time: clock,
            departure_time: clock
          )
        end

        %{version: version, pattern: pattern, trip: trip}
      end)

    parent = self()

    task =
      Task.async(fn ->
        receive do
          :start_export -> :ok
        end

        unboxed(fn ->
          %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:exporter_backend, self(), backend_pid})
          Export.export_to_zip(org.id, fixture.version.id, :full)
        end)
      end)

    exporter_pid = task.pid
    handler_id = {__MODULE__, :export_race}

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, exporter} ->
        query = to_string(metadata[:query])

        if self() == exporter and metadata[:source] == "trips" and
             String.contains?(query, ~s(t0."trip_headsign")) do
          :telemetry.detach(handler_id)
          send(owner, {:export_paused, self()})

          receive do
            :resume_export -> :ok
          after
            30_000 -> :ok
          end
        end
      end,
      {self(), exporter_pid}
    )

    send(exporter_pid, :start_export)
    assert_receive {:exporter_backend, ^exporter_pid, exporter_backend}, 10_000
    assert_receive {:export_paused, ^exporter_pid}, 10_000

    writer_backend =
      unboxed(fn ->
        %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        backend_pid
      end)

    assert writer_backend != exporter_backend

    assert {:ok, _} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 Repo.update_all(
                   from(t in Trip,
                     where: t.organization_id == ^org.id and t.trip_id == "CONC_TRIP"
                   ),
                   set: [direction_id: 1, trip_headsign: "After"]
                 )

                 Repo.update_all(
                   from(st in StopTime,
                     where: st.organization_id == ^org.id and st.trip_id == "CONC_TRIP"
                   ),
                   set: [arrival_time: "09:00:00", departure_time: "09:00:00"]
                 )

                 Repo.update_all(
                   from(p in RoutePattern,
                     where: p.organization_id == ^org.id and p.route_pattern_id == "CONC_PATTERN"
                   ),
                   set: [route_pattern_time_desc: "After"]
                 )
               end)
             end)

    send(exporter_pid, :resume_export)
    assert {:ok, interleaved_zip} = Task.await(task, 30_000)

    before = %{direction: "0", headsign: "Before", arrival: "08:00:00", time_desc: "Before"}
    after_edit = %{direction: "1", headsign: "After", arrival: "09:00:00", time_desc: "After"}

    interleaved = snapshot_of(interleaved_zip)

    assert interleaved in [before, after_edit],
           "export mixed pre-edit and post-edit revisions: #{inspect(interleaved)}"

    assert interleaved == before

    {:ok, after_zip} = unboxed(fn -> Export.export_to_zip(org.id, fixture.version.id, :full) end)
    assert snapshot_of(after_zip) == after_edit
  end

  test "derived pattern identities are exported for their linked trips" do
    org = new_org("derived-export")
    on_exit(fn -> cleanup([org.id]) end)

    generated_pattern_id = "app-#{Ecto.UUID.generate()}"

    version =
      unboxed(fn ->
        version = gtfs_version_fixture(org.id)
        route = route_fixture(org.id, version.id, route_id: "DER_ROUTE", route_short_name: "DER")
        s1 = stop_fixture(org.id, version.id, stop_id: "DER_S1")
        s2 = stop_fixture(org.id, version.id, stop_id: "DER_S2")

        pattern =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: generated_pattern_id,
            route_id: route.route_id,
            direction_id: 0,
            route_pattern_name: "Derived",
            route_pattern_typicality: 1,
            derivation_key: "DER_DERIVATION_KEY"
          })

        occ1 = route_pattern_stop_fixture(pattern, s1.stop_id, 1)
        occ2 = route_pattern_stop_fixture(pattern, s2.stop_id, 2)

        timing =
          timed_pattern_fixture(pattern, %{
            name: "Derived Timing",
            derivation_key: "DER_TIMING_KEY"
          })

        timed_pattern_stop_fixture(timing, occ1, %{arrival_offset: 0, departure_offset: 0})
        timed_pattern_stop_fixture(timing, occ2, %{arrival_offset: 120, departure_offset: 120})

        trip =
          trip_fixture(org.id, version.id, route.route_id,
            trip_id: "DER_TRIP",
            service_id: "WEEKDAY",
            direction_id: 0
          )

        trip_pattern_metadata_fixture(trip, %{
          route_pattern_id: generated_pattern_id,
          timed_pattern_id: timing.id,
          pattern_derivation_state: "linked",
          pattern_derivation_reason: nil
        })

        stop_time_fixture(org.id, version.id, "DER_TRIP", "DER_S1",
          stop_sequence: 1,
          arrival_time: "10:00:00",
          departure_time: "10:00:00"
        )

        stop_time_fixture(org.id, version.id, "DER_TRIP", "DER_S2",
          stop_sequence: 2,
          arrival_time: "10:02:00",
          departure_time: "10:02:00"
        )

        version
      end)

    {:ok, zip} = unboxed(fn -> Export.export_to_zip(org.id, version.id, :full) end)
    files = unzip(zip)

    pattern_row =
      files |> csv_lines("route_patterns.txt") |> tl() |> Enum.find(&(&1 =~ generated_pattern_id))

    refute is_nil(pattern_row)
    assert pattern_row |> split_row() |> hd() == generated_pattern_id
    assert pattern_row |> split_row() |> Enum.at(1) == "DER_ROUTE"

    trip_row = files |> csv_lines("trips.txt") |> Enum.find(&(&1 =~ "DER_TRIP"))
    assert trip_row |> split_row() |> List.last() == generated_pattern_id

    refute Enum.any?(files, fn {_, content} -> to_string(content) =~ "DER_DERIVATION_KEY" end)
    refute Enum.any?(files, fn {_, content} -> to_string(content) =~ "DER_TIMING_KEY" end)
  end

  defp snapshot_of(zip) do
    files = unzip(zip)

    trip_row =
      files |> csv_lines("trips.txt") |> Enum.find(&(&1 =~ "CONC_TRIP")) |> split_row()

    stop_time_row =
      files |> csv_lines("stop_times.txt") |> Enum.find(&(&1 =~ "CONC_TRIP")) |> split_row()

    pattern_row =
      files
      |> csv_lines("route_patterns.txt")
      |> Enum.find(&(&1 =~ "CONC_PATTERN"))
      |> split_row()

    %{
      direction: Enum.at(trip_row, 5),
      headsign: Enum.at(trip_row, 3),
      arrival: Enum.at(stop_time_row, 1),
      time_desc: Enum.at(pattern_row, 4)
    }
  end

  defp numeric_times(organization_id, version_id, trip_id) do
    Repo.all(
      from(st in StopTime,
        where:
          st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id and
            st.trip_id == ^trip_id,
        order_by: st.stop_sequence,
        select: {st.stop_sequence, st.arrival_time, st.departure_time}
      )
    )
    |> Enum.map(fn {sequence, arrival, departure} ->
      {sequence, seconds!(arrival), seconds!(departure)}
    end)
  end

  defp seconds!(nil), do: nil

  defp seconds!(value) do
    {:ok, seconds} = GtfsTime.parse(value)
    seconds
  end

  defp new_org(prefix) do
    unboxed(fn ->
      organization_fixture(%{alias: "#{prefix}-#{System.system_time(:nanosecond)}"})
    end)
  end

  defp new_version(org) do
    unboxed(fn -> gtfs_version_fixture(org.id) end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    entries
  end

  defp filenames(files), do: Enum.map(files, fn {name, _} -> to_string(name) end)

  defp csv_lines(files, name) do
    case Enum.find(files, fn {entry_name, _} -> to_string(entry_name) == name end) do
      nil ->
        flunk("expected #{name} in export; got #{inspect(filenames(files))}")

      {_, content} ->
        content |> to_string() |> String.split("\n", trim: true)
    end
  end

  defp split_row(row), do: String.split(row, ",")

  defp cleanup(organization_ids) do
    unboxed(fn ->
      timing_ids =
        Repo.all(
          from(t in TimedPattern, where: t.organization_id in ^organization_ids, select: t.id)
        )

      Repo.delete_all(from(r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids))
      Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(r in RoutePatternStop, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id in ^organization_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(a in Agency, where: a.organization_id in ^organization_ids))
      refute Repo.exists?(from(r in Route, where: r.organization_id in ^organization_ids))
      refute Repo.exists?(from(s in Stop, where: s.organization_id in ^organization_ids))
      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(st in StopTime, where: st.organization_id in ^organization_ids))
      refute Repo.exists?(from(p in RoutePattern, where: p.organization_id in ^organization_ids))

      refute Repo.exists?(
               from(r in RoutePatternStop, where: r.organization_id in ^organization_ids)
             )

      refute Repo.exists?(from(t in TimedPattern, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
    end)
  end
end
