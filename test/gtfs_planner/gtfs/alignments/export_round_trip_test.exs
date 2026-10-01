defmodule GtfsPlanner.Gtfs.Alignments.ExportRoundTripTest do
  @moduledoc false
  # Step 18 / EV-17: a drawn loop (A,B,C,A,B) plus a divergent pattern replaced
  # by a drawn shape survive export, and the export re-imports with equal
  # shapes, trip references and stop-time distances (CL-17 / FH-27 / AC-22).
  #
  # Committing-session coverage through the real composition
  # `Gtfs.review_alignment_save/3` -> `Gtfs.apply_alignment_save/5` ->
  # `Export.export_to_zip/3` -> `Import.import_files/3`. Every DB call runs
  # in `unboxed/1` so rows commit on real connections; each test owns one
  # organization and deletes exactly those rows on exit. CSVs are parsed by
  # header name. The exporter needs no changes: it streams `shapes` rows,
  # `trips.shape_id` and `stop_times.shape_dist_traveled` under one snapshot.
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.ConcurrencyHelpers
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Versions.GtfsVersion

  @loop_points %{
    1 => [[-74.0055, 40.7131]],
    2 => [[-74.0045, 40.7142]],
    3 => [[-74.0052, 40.7139]],
    4 => [[-74.0055, 40.7131]]
  }

  test "drawn loop exports stored geometry, references and distances; deleted shapes are absent" do
    org = new_org("align-export")
    on_exit(fn -> cleanup([org.id]) end)

    fixture =
      unboxed(fn ->
        version = gtfs_version_fixture(org.id)
        build_feed(org, version)
      end)

    {:ok, zip} = unboxed(fn -> Export.export_to_zip(org.id, fixture.version_id, :full) end)
    files = unzip(zip)

    stored =
      unboxed(fn ->
        %{
          loop_shapes: shape_rows(org.id, fixture.version_id, "LOOP_P"),
          div_shapes: shape_rows(org.id, fixture.version_id, "DIV_P"),
          old1: shape_rows(org.id, fixture.version_id, "OLD1"),
          old2: shape_rows(org.id, fixture.version_id, "OLD2"),
          loop_visits: visit_distances(fixture.loop_pattern_id),
          loop_trip: trip_row(org.id, fixture.version_id, "LOOP_T"),
          div_t1: trip_row(org.id, fixture.version_id, "DIV_T1"),
          div_t2: trip_row(org.id, fixture.version_id, "DIV_T2"),
          loop_stops: trip_distances(org.id, fixture.version_id, "LOOP_T")
        }
      end)

    assert stored.old1 == []
    assert stored.old2 == []
    # Five loop anchors plus four interiors (one per section); two divergent
    # anchors plus one interior.
    assert length(stored.loop_shapes) == 9
    assert length(stored.div_shapes) == 3

    assert_shapes_equal_exported(stored.loop_shapes, files, "LOOP_P")
    assert_shapes_equal_exported(stored.div_shapes, files, "DIV_P")
    assert_no_exported_shape(files, "OLD1")
    assert_no_exported_shape(files, "OLD2")

    assert_trip_shape(files, "LOOP_T", "LOOP_P")
    assert_trip_shape(files, "DIV_T1", "DIV_P")
    assert_trip_shape(files, "DIV_T2", "DIV_P")
    assert stored.loop_trip.shape_id == "LOOP_P"
    assert stored.div_t1.shape_id == "DIV_P"
    assert stored.div_t2.shape_id == "DIV_P"

    assert_stop_distances_equal_exported(stored.loop_visits, files, "LOOP_T")
    assert_stop_distances_equal_exported(stored.loop_visits, stored.loop_stops)
  end

  test "export re-import reproduces shapes, references and distances; imported pattern is :imported" do
    org = new_org("align-reimport")
    on_exit(fn -> cleanup([org.id]) end)

    fixture =
      unboxed(fn ->
        version = gtfs_version_fixture(org.id)
        build_feed(org, version)
      end)

    {:ok, zip} = unboxed(fn -> Export.export_to_zip(org.id, fixture.version_id, :full) end)
    files = unzip(zip)

    import_files =
      Enum.map(files, fn {name, content} -> %{filename: to_string(name), content: content} end)

    version_b = new_version(org)

    assert {:ok, _result} =
             unboxed(fn -> StagedImport.import_files(org.id, version_b.id, import_files) end)

    comparison =
      unboxed(fn ->
        %{
          loop_a: shape_rows(org.id, fixture.version_id, "LOOP_P"),
          loop_b: shape_rows(org.id, version_b.id, "LOOP_P"),
          div_a: shape_rows(org.id, fixture.version_id, "DIV_P"),
          div_b: shape_rows(org.id, version_b.id, "DIV_P"),
          loop_trip_b: trip_row(org.id, version_b.id, "LOOP_T"),
          div_t1_b: trip_row(org.id, version_b.id, "DIV_T1"),
          div_t2_b: trip_row(org.id, version_b.id, "DIV_T2"),
          loop_stops_a: trip_distances(org.id, fixture.version_id, "LOOP_T"),
          loop_stops_b: trip_distances(org.id, version_b.id, "LOOP_T"),
          div_stops_a: trip_distances(org.id, fixture.version_id, "DIV_T1"),
          div_stops_b: trip_distances(org.id, version_b.id, "DIV_T1"),
          imported_loop:
            Repo.one!(
              from(p in RoutePattern,
                where:
                  p.organization_id == ^org.id and p.gtfs_version_id == ^version_b.id and
                    p.route_pattern_id == "LOOP_P"
              )
            )
        }
      end)

    assert_shape_tuples_equal(comparison.loop_a, comparison.loop_b)
    assert_shape_tuples_equal(comparison.div_a, comparison.div_b)
    assert comparison.loop_trip_b.shape_id == "LOOP_P"
    assert comparison.div_t1_b.shape_id == "DIV_P"
    assert comparison.div_t2_b.shape_id == "DIV_P"
    assert_decimals_equal(comparison.loop_stops_a, comparison.loop_stops_b)
    assert_decimals_equal(comparison.div_stops_a, comparison.div_stops_b)

    imported_status =
      unboxed(fn ->
        comparison.imported_loop
        |> Repo.reload!()
        |> Alignments.resolve()
        |> get_in([:status, :export])
      end)

    assert imported_status == :imported
  end

  # Draws the loop plus the divergent replacement and returns the version and
  # pattern ids. Must run inside `unboxed/1`.
  defp build_feed(org, version) do
    agency_fixture(org.id, version.id, %{agency_id: "ALIGN_AGENCY"})

    coord_stop(org.id, version.id, "A", "40.712800", "-74.006000")
    coord_stop(org.id, version.id, "B", "40.713800", "-74.005000")
    coord_stop(org.id, version.id, "C", "40.714800", "-74.004000")
    coord_stop(org.id, version.id, "D", "40.730800", "-73.997000")
    coord_stop(org.id, version.id, "E", "40.731800", "-73.996000")

    route_fixture(org.id, version.id, %{route_id: "LOOP_R"})
    route_fixture(org.id, version.id, %{route_id: "DIV_R"})

    loop_pattern =
      route_pattern_fixture(org.id, version.id, %{route_id: "LOOP_R", route_pattern_id: "LOOP_P"})

    ["A", "B", "C", "A", "B"]
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(loop_pattern, stop_id, position)
    end)

    loop_pattern = Repo.reload!(loop_pattern)
    loop_timing = timed_pattern_fixture(loop_pattern)

    loop_trip =
      trip_fixture(org.id, version.id, "LOOP_R", %{
        trip_id: "LOOP_T",
        service_id: "WEEKDAY",
        direction_id: 0,
        trip_headsign: "Loop"
      })

    trip_pattern_metadata_fixture(loop_trip, %{
      route_pattern_id: "LOOP_P",
      timed_pattern_id: loop_timing.id,
      pattern_derivation_state: "linked"
    })

    ["A", "B", "C", "A", "B"]
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, sequence} ->
      stop_time_fixture(org.id, version.id, "LOOP_T", stop_id, %{stop_sequence: sequence})
    end)

    div_pattern =
      route_pattern_fixture(org.id, version.id, %{route_id: "DIV_R", route_pattern_id: "DIV_P"})

    ["D", "E"]
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(div_pattern, stop_id, position)
    end)

    div_pattern = Repo.reload!(div_pattern)
    div_timing = timed_pattern_fixture(div_pattern)

    insert_shape(org, version, "OLD1", 0, "40.100000", "-74.100000", "5.5")
    insert_shape(org, version, "OLD1", 1, "40.101000", "-74.099000", "812.4")
    insert_shape(org, version, "OLD2", 0, "40.200000", "-74.200000", "6.5")
    insert_shape(org, version, "OLD2", 1, "40.201000", "-74.199000", "900.0")

    for {trip_id, shape_id} <- [{"DIV_T1", "OLD1"}, {"DIV_T2", "OLD2"}] do
      trip =
        trip_fixture(org.id, version.id, "DIV_R", %{
          trip_id: trip_id,
          service_id: "WEEKDAY",
          direction_id: 0,
          trip_headsign: "Divergent",
          shape_id: shape_id
        })

      trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: "DIV_P",
        timed_pattern_id: div_timing.id,
        pattern_derivation_state: "linked"
      })

      stop_time_fixture(org.id, version.id, trip_id, "D", %{stop_sequence: 1})
      stop_time_fixture(org.id, version.id, trip_id, "E", %{stop_sequence: 2})
    end

    actor = editor_fixture(org)

    audit = %AuditContext{
      organization_id: org.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    loop_pattern = Repo.reload!(loop_pattern)

    loop_draft =
      for position <- 1..4 do
        set_entry(section_at(loop_pattern, position), Map.fetch!(@loop_points, position))
      end

    {:ok, loop_review} = Gtfs.review_alignment_save(loop_pattern.id, loop_draft, audit)
    assert loop_review.origin.complete? == true

    loop_scopes =
      for section <- loop_review.sections,
          section.action == :choose_scope,
          into: %{},
          do: {to_string(section.position), "shared"}

    {:ok, loop_result} =
      Gtfs.apply_alignment_save(
        loop_pattern.id,
        loop_draft,
        %{"scopes" => loop_scopes},
        loop_review.fingerprint,
        audit
      )

    assert loop_result.materialized == ["LOOP_P"]
    assert Repo.reload!(loop_pattern).shape_id == "LOOP_P"

    div_pattern = Repo.reload!(div_pattern)
    div_draft = [set_entry(section_at(div_pattern, 1), [[-73.9965, 40.7312]])]

    {:ok, div_review} = Gtfs.review_alignment_save(div_pattern.id, div_draft, audit)
    assert div_review.requires_confirmation? == true

    div_scopes =
      for section <- div_review.sections,
          section.action == :choose_scope,
          into: %{},
          do: {to_string(section.position), "shared"}

    {:ok, div_result} =
      Gtfs.apply_alignment_save(
        div_pattern.id,
        div_draft,
        %{"scopes" => div_scopes, "confirm_replacements" => true},
        div_review.fingerprint,
        audit
      )

    assert div_result.materialized == ["DIV_P"]
    assert Enum.sort(div_result.shapes_deleted) == ["OLD1", "OLD2"]
    assert Repo.reload!(div_pattern).shape_id == "DIV_P"

    %{
      version_id: version.id,
      loop_pattern_id: loop_pattern.id,
      div_pattern_id: div_pattern.id
    }
  end

  defp coord_stop(org_id, version_id, stop_id, lat, lon) do
    stop_fixture(org_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Stop #{stop_id}",
      stop_lat: Decimal.new(lat),
      stop_lon: Decimal.new(lon)
    })
  end

  defp insert_shape(org, version, shape_id, sequence, lat_s, lon_s, dist_s) do
    %Shape{}
    |> Shape.changeset(%{
      organization_id: org.id,
      gtfs_version_id: version.id,
      shape_id: shape_id,
      shape_pt_sequence: sequence,
      shape_pt_lat: lat_s,
      shape_pt_lon: lon_s,
      shape_dist_traveled: dist_s
    })
    |> Repo.insert!()
  end

  defp section_at(pattern, position) do
    pattern
    |> Alignments.resolve()
    |> Map.fetch!(:sections)
    |> Enum.find(&(&1.position == position))
  end

  defp set_entry(section, points) do
    %{
      "position" => section.position,
      "from_occurrence_id" => section.from_occurrence_id,
      "to_stop_id" => section.to_stop_id,
      "op" => "set",
      "points" => points,
      "base" => %{
        "segment_id" => section.revision.segment_id,
        "lock_version" => section.revision.lock_version
      }
    }
  end

  defp shape_rows(org_id, version_id, shape_id) do
    Repo.all(
      from(s in Shape,
        where:
          s.organization_id == ^org_id and s.gtfs_version_id == ^version_id and
            s.shape_id == ^shape_id,
        order_by: [asc: s.shape_pt_sequence]
      )
    )
  end

  defp visit_distances(pattern_id) do
    Repo.all(
      from(o in RoutePatternStop,
        where: o.route_pattern_id == ^pattern_id,
        order_by: [asc: o.position],
        select: o.shape_dist_traveled
      )
    )
  end

  defp trip_row(org_id, version_id, trip_id) do
    Repo.one!(
      from(t in Trip,
        where:
          t.organization_id == ^org_id and t.gtfs_version_id == ^version_id and
            t.trip_id == ^trip_id
      )
    )
  end

  defp trip_distances(org_id, version_id, trip_id) do
    Repo.all(
      from(st in StopTime,
        where:
          st.organization_id == ^org_id and st.gtfs_version_id == ^version_id and
            st.trip_id == ^trip_id,
        order_by: [asc: st.stop_sequence],
        select: st.shape_dist_traveled
      )
    )
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

  defp table_rows(files, name) do
    case Enum.find(files, fn {entry_name, _} -> to_string(entry_name) == name end) do
      nil ->
        flunk(
          "expected #{name} in export; got #{inspect(Enum.map(files, fn {n, _} -> to_string(n) end))}"
        )

      {_, content} ->
        [header | rows] =
          content |> to_string() |> String.split("\n", trim: true)

        columns = String.split(header, ",")

        parsed =
          Enum.map(rows, fn row -> Enum.zip(columns, String.split(row, ",")) |> Map.new() end)

        {columns, parsed}
    end
  end

  defp assert_shapes_equal_exported(stored_rows, files, shape_id) do
    {_columns, parsed} = table_rows(files, "shapes.txt")

    exported =
      parsed
      |> Enum.filter(&(&1["shape_id"] == shape_id))
      |> Enum.sort_by(&String.to_integer(&1["shape_pt_sequence"]))

    assert length(exported) == length(stored_rows)

    Enum.zip(stored_rows, exported)
    |> Enum.each(fn {stored, row} ->
      assert String.to_integer(row["shape_pt_sequence"]) == stored.shape_pt_sequence
      assert Decimal.compare(Decimal.new(row["shape_pt_lat"]), stored.shape_pt_lat) == :eq
      assert Decimal.compare(Decimal.new(row["shape_pt_lon"]), stored.shape_pt_lon) == :eq

      assert Decimal.compare(Decimal.new(row["shape_dist_traveled"]), stored.shape_dist_traveled) ==
               :eq
    end)
  end

  defp assert_no_exported_shape(files, shape_id) do
    {_columns, parsed} = table_rows(files, "shapes.txt")
    assert Enum.filter(parsed, &(&1["shape_id"] == shape_id)) == []
  end

  defp assert_trip_shape(files, trip_id, shape_id) do
    {_columns, parsed} = table_rows(files, "trips.txt")
    row = Enum.find(parsed, &(&1["trip_id"] == trip_id))
    assert row != nil
    assert row["shape_id"] == shape_id
  end

  defp assert_stop_distances_equal_exported(visit_distances, files, trip_id) do
    {_columns, parsed} = table_rows(files, "stop_times.txt")

    exported =
      parsed
      |> Enum.filter(&(&1["trip_id"] == trip_id))
      |> Enum.sort_by(&String.to_integer(&1["stop_sequence"]))
      |> Enum.map(&Decimal.new(&1["shape_dist_traveled"]))

    assert_decimals_equal(visit_distances, exported)
  end

  defp assert_stop_distances_equal_exported(visit_distances, stored_distances)
       when is_list(stored_distances) and is_list(visit_distances) do
    assert_decimals_equal(visit_distances, stored_distances)
  end

  defp assert_shape_tuples_equal(rows_a, rows_b) do
    assert length(rows_a) == length(rows_b)

    Enum.zip(rows_a, rows_b)
    |> Enum.each(fn {a, b} ->
      assert a.shape_pt_sequence == b.shape_pt_sequence
      assert Decimal.compare(a.shape_pt_lat, b.shape_pt_lat) == :eq
      assert Decimal.compare(a.shape_pt_lon, b.shape_pt_lon) == :eq
      assert Decimal.compare(a.shape_dist_traveled, b.shape_dist_traveled) == :eq
    end)
  end

  defp assert_decimals_equal(actual, expected) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn
      {nil, nil} -> :ok
      {nil, _} -> flunk("expected nil distance, got #{inspect(expected)}")
      {_, nil} -> flunk("expected distance, got nil")
      {got, want} -> assert Decimal.compare(got, want) == :eq
    end)
  end

  defp cleanup(organization_ids) do
    unboxed(fn ->
      # The alignment save needs an editor, which `editor_fixture/1` commits with the
      # organization's membership; deleting the organization alone leaves the user.
      ConcurrencyHelpers.delete_committed_members!(organization_ids)

      timing_ids =
        Repo.all(
          from(t in TimedPattern, where: t.organization_id in ^organization_ids, select: t.id)
        )

      Repo.delete_all(from(r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(s in AlignmentSegment, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Shape, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id in ^organization_ids))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id in ^organization_ids))
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
      refute Repo.exists?(from(s in Shape, where: s.organization_id in ^organization_ids))

      refute Repo.exists?(
               from(s in AlignmentSegment, where: s.organization_id in ^organization_ids)
             )

      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
    end)
  end
end
