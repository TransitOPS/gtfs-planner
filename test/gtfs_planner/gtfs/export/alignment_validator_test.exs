defmodule GtfsPlanner.Gtfs.Export.AlignmentValidatorTest do
  @moduledoc """
  Judges a full export carrying drawn alignment geometry against the tracked
  MobilityData validator CLI (EV-18, AC-23).

  The feed holds a drawn loop pattern (A,B,C,A,B) with a linked trip and a
  second drawn pattern (D,E,F) reordered through the 01 stop-edit facade
  (`Gtfs.review/4` + `Gtfs.apply_review/4`), which clears its visit distances
  while keeping its shape rows. The export must carry no
  `decreasing_or_equal_stop_time_distance` or
  `equal_shape_distance_diff_coordinates` notice and no ERROR notice naming
  `shapes.txt` or `stop_times.txt`.

  The module writes the ZIP and the validator report to a temporary directory
  removed after the test, and makes no network calls
  (`--skip_validator_update`). It shells out to the configured JDK and the
  tracked 39 MB jar, so `@moduletag :validator_cli` excludes it from the
  default suite (see `test/test_helper.exs`); branch review runs it
  explicitly:

      MIX_TEST_PARTITION=_align12 mix test --only validator_cli test/gtfs_planner/gtfs/export/alignment_validator_test.exs

  The single test runs the CLI once inside one 300-second ExUnit timeout, the
  prepared EV-18 deadline.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.GtfsValidatorCli
  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  @validator_version "8.0.1"

  @loop_points %{
    1 => [[-74.0055, 40.7131]],
    2 => [[-74.0045, 40.7142]],
    3 => [[-74.0052, 40.7139]],
    4 => [[-74.0055, 40.7131]]
  }

  test "drawn loop and reordered drawn pattern export without shape distance errors" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_feed(organization.id, version.id)

    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    draw_loop!(organization, version, audit)
    reorder_drawn_pattern!(organization, version, audit)

    tmp_dir =
      Path.join(System.tmp_dir!(), "alignment_validator_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    zip = export_zip!(tmp_dir, organization.id, version.id)
    entries = zip_entries(zip)

    # The distance assertions below are vacuous unless both files export.
    assert "shapes.txt" in entries
    assert "stop_times.txt" in entries

    report = GtfsValidatorCli.run!(Path.join(tmp_dir, "report"), zip)

    assert report["summary"]["validatorVersion"] == @validator_version

    codes = notice_codes(report)

    refute "decreasing_or_equal_stop_time_distance" in codes,
           "validator reports decreasing stop-time distances: #{inspect(codes)}"

    refute "equal_shape_distance_diff_coordinates" in codes,
           "validator reports equal shape distances: #{inspect(codes)}"

    assert shape_stop_errors(report) == [],
           "validator ERRORs name shapes.txt or stop_times.txt: " <>
             inspect(Enum.map(shape_stop_errors(report), & &1["code"]))

    print_observation(report)
  end

  # A feed the validator accepts: agency, the calendar service the loop trip
  # names, two routes, six stops with coordinates, and nothing else. Patterns,
  # trips and geometry are added per case below.
  defp seed_feed(organization_id, version_id) do
    agency_fixture(organization_id, version_id, %{agency_id: "ALIGN_AGENCY"})

    calendar_fixture(organization_id, version_id, %{service_id: "SVC1"})

    route_fixture(organization_id, version_id, %{route_id: "LOOP_R"})
    route_fixture(organization_id, version_id, %{route_id: "REORD_R"})

    coord_stop(organization_id, version_id, "A", "40.712800", "-74.006000")
    coord_stop(organization_id, version_id, "B", "40.713800", "-74.005000")
    coord_stop(organization_id, version_id, "C", "40.714800", "-74.004000")
    coord_stop(organization_id, version_id, "D", "40.730800", "-73.997000")
    coord_stop(organization_id, version_id, "E", "40.731800", "-73.996000")
    coord_stop(organization_id, version_id, "F", "40.732800", "-73.995000")
  end

  # Draws the A,B,C,A,B loop with one interior point per section and a linked
  # trip whose stop times carry strictly increasing clock times.
  defp draw_loop!(organization, version, audit) do
    loop_pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "LOOP_R",
        route_pattern_id: "LOOP_P"
      })

    ["A", "B", "C", "A", "B"]
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(loop_pattern, stop_id, position)
    end)

    loop_pattern = Repo.reload!(loop_pattern)
    loop_timing = timed_pattern_fixture(loop_pattern)

    loop_trip =
      trip_fixture(organization.id, version.id, "LOOP_R", %{
        trip_id: "LOOP_T",
        service_id: "SVC1",
        direction_id: 0,
        trip_headsign: "Loop"
      })

    trip_pattern_metadata_fixture(loop_trip, %{
      route_pattern_id: "LOOP_P",
      timed_pattern_id: loop_timing.id,
      pattern_derivation_state: "linked"
    })

    [
      {"A", "08:00:00"},
      {"B", "08:05:00"},
      {"C", "08:10:00"},
      {"A", "08:15:00"},
      {"B", "08:20:00"}
    ]
    |> Enum.with_index(1)
    |> Enum.each(fn {{stop_id, time}, sequence} ->
      stop_time_fixture(organization.id, version.id, "LOOP_T", stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end)

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
  end

  # Draws D,E,F straight, then reorders to D,F,E through the 01 facade. The
  # reorder clears the visit distances while the drawn shape rows survive, so
  # the export carries geometry whose stop times have no distances to dispute.
  defp reorder_drawn_pattern!(organization, version, audit) do
    {:ok, pattern} =
      Gtfs.create_pattern(
        "REORD_R",
        %{route_pattern_name: "Reorder", direction_id: 0, stops: ["D", "E", "F"]},
        audit
      )

    insert_shared(organization, version, "D", "E")
    insert_shared(organization, version, "E", "F")

    assert {:ok, draw_review} = Gtfs.review_alignment_save(pattern.id, [], audit)
    assert draw_review.origin.complete? == true

    assert {:ok, draw_result} =
             Gtfs.apply_alignment_save(pattern.id, [], %{}, draw_review.fingerprint, audit)

    assert draw_result.materialized == [Repo.reload!(pattern).route_pattern_id]

    shape_id = Repo.reload!(pattern).shape_id
    assert shape_id != nil

    [d, e, f] = occurrences(pattern.id)
    timing = timing_for(pattern.id)

    operation =
      {:stops,
       [
         %{id: d.id, stop_id: d.stop_id},
         %{id: f.id, stop_id: f.stop_id},
         %{id: e.id, stop_id: e.stop_id}
       ], %{timing.id => %{}}}

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(
               pattern.id,
               operation,
               source_for(organization, version, "REORD_R", pattern),
               audit
             )

    assert {:ok, _} = Gtfs.apply_review(pattern.id, operation, fingerprint, audit)

    assert Repo.reload!(pattern).shape_id == shape_id
    assert %{status: %{export: :stale}} = Alignments.resolve(Repo.reload!(pattern))
  end

  defp coord_stop(organization_id, version_id, stop_id, lat, lon) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Stop #{stop_id}",
      stop_lat: Decimal.new(lat),
      stop_lon: Decimal.new(lon)
    })
  end

  defp insert_shared(organization, version, from_id, to_id) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id
    }
    |> AlignmentSegment.changeset(%{points: []})
    |> Repo.insert!()
  end

  defp occurrences(pattern_id), do: stored_occurrences(pattern_id)

  defp timing_for(pattern_id) do
    [timing] = stored_timings(pattern_id)
    timing
  end

  defp source_for(organization, version, route_id, pattern) do
    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(organization.id, version.id, route_id, pattern.id)

    source
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

  defp export_zip!(tmp_dir, organization_id, version_id) do
    {:ok, zip_binary} = Export.export_to_zip(organization_id, version_id, :full)

    path = Path.join(tmp_dir, "alignment.zip")
    File.write!(path, zip_binary)
    path
  end

  defp zip_entries(zip_path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])
    Enum.map(entries, fn {name, _content} -> List.to_string(name) end)
  end

  # The 8.0.1 report holds one entry per notice code:
  # %{"code" => ..., "severity" => "ERROR" | "WARNING" | "INFO",
  #   "totalNotices" => n, "sampleNotices" => [%{"filename" => ...}, ...]}
  defp notice_codes(report) do
    report |> GtfsValidatorCli.notices() |> Enum.map(& &1["code"])
  end

  defp shape_stop_errors(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.filter(fn notice ->
      GtfsValidatorCli.severity(notice) == "ERROR" and
        Enum.any?(sample_files(notice), &(&1 in ["shapes.txt", "stop_times.txt"]))
    end)
  end

  defp sample_files(notice) do
    notice
    |> Map.get("sampleNotices", [])
    |> Enum.flat_map(&[&1["filename"], &1["childFilename"]])
    |> Enum.reject(&is_nil/1)
  end

  defp file_severity_counts(report, file, severity) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.count(fn notice ->
      GtfsValidatorCli.severity(notice) == severity and file in sample_files(notice)
    end)
  end

  defp print_observation(report) do
    IO.puts(
      "EV-18 shapes.txt ERROR notices=#{file_severity_counts(report, "shapes.txt", "ERROR")} " <>
        "WARNING notices=#{file_severity_counts(report, "shapes.txt", "WARNING")} " <>
        "stop_times.txt ERROR notices=#{file_severity_counts(report, "stop_times.txt", "ERROR")} " <>
        "WARNING notices=#{file_severity_counts(report, "stop_times.txt", "WARNING")}"
    )
  end
end
