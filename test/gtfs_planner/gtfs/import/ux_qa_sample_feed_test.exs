defmodule GtfsPlanner.Gtfs.Import.UxQaSampleFeedTest do
  @moduledoc """
  The UX QA sample feed commits as one artifact, so the importer must accept all
  of it and store every row. The expected row counts are read from the zip's own
  files, independently of `GtfsPlanner.Gtfs.Import`, and are additionally pinned
  to hand-written literals; the calendars must still be current and the weekend
  AAMV trips must be present, because a feed whose calendars have ended or whose
  `stop_times.txt` is rejected makes every downstream journey QA check drift.

  `test/fixtures/gtfs/ux_qa/NOTICE.md` records the three modifications made to
  Google's `sample-feed-1.zip`; the second test here restores the upstream
  five-field `stop_times.txt` row shape to prove the importer rejects it.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import

  @fixture Path.expand("../../../fixtures/gtfs/ux_qa/sample-feed.zip", __DIR__)

  # Hand-written from the fixture's own files; the importer computes none of them.
  @expected_counts %{routes: 5, stops: 9, trips: 11, stop_times: 28, calendars: 2}
  @counted_files %{
    routes: "routes.txt",
    stops: "stops.txt",
    trips: "trips.txt",
    stop_times: "stop_times.txt",
    calendars: "calendar.txt"
  }

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{organization: organization, gtfs_version: gtfs_version}
  end

  describe "importing test/fixtures/gtfs/ux_qa/sample-feed.zip" do
    test "stores every row the zip contains", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      zip_counts = zip_row_counts()

      assert zip_counts == @expected_counts

      assert {:ok, %Import.Result{} = result} =
               Import.import_files(organization.id, gtfs_version.id, [
                 %{filename: "sample-feed.zip", content: fixture_binary()}
               ])

      assert result.unrecognized_files == []
      assert Import.Result.publishable?(result)

      # Read back through the public contexts rather than the importer's counts,
      # so a count the importer reports but does not persist cannot pass.
      assert stored_count(Gtfs.Route, gtfs_version) == zip_counts.routes
      assert stored_count(Gtfs.Stop, gtfs_version) == zip_counts.stops
      assert stored_count(Gtfs.Trip, gtfs_version) == zip_counts.trips
      assert stored_count(Gtfs.StopTime, gtfs_version) == zip_counts.stop_times
      assert stored_count(Gtfs.Calendar, gtfs_version) == zip_counts.calendars

      assert stored_count(Gtfs.Route, gtfs_version) == 5
      assert stored_count(Gtfs.Stop, gtfs_version) == 9
      assert stored_count(Gtfs.Trip, gtfs_version) == 11
      assert stored_count(Gtfs.StopTime, gtfs_version) == 28
      assert stored_count(Gtfs.Calendar, gtfs_version) == 2
    end

    test "keeps the calendars current and the AAMV weekend trips complete", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:ok, %Import.Result{}} =
               Import.import_files(organization.id, gtfs_version.id, [
                 %{filename: "sample-feed.zip", content: fixture_binary()}
               ])

      calendars = Repo.all(from c in Gtfs.Calendar, where: c.gtfs_version_id == ^gtfs_version.id)

      assert length(calendars) == 2
      assert Enum.all?(calendars, &(Date.compare(&1.end_date, ~D[2030-03-01]) != :lt))

      weekend_trips =
        Repo.all(
          from t in Gtfs.Trip,
            where:
              t.gtfs_version_id == ^gtfs_version.id and t.route_id == "AAMV" and
                t.service_id == "WE",
            select: t.trip_id,
            order_by: t.trip_id
        )

      assert weekend_trips == ["AAMV1", "AAMV2", "AAMV3", "AAMV4"]

      aamv3_seconds =
        Repo.all(
          from st in Gtfs.StopTime,
            where: st.gtfs_version_id == ^gtfs_version.id and st.trip_id == "AAMV3",
            select: st.arrival_time,
            order_by: st.stop_sequence
        )
        |> Enum.map(&seconds_after_midnight/1)

      assert aamv3_seconds == [46_800, 50_400]
    end

    test "rejects a stop_times.txt row with five fields, as upstream ships it", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      upstream_stop_times =
        fixture_zip()
        |> Map.new(fn {name, content} -> {to_string(name), content} end)
        |> Map.fetch!("stop_times.txt")
        |> String.split("\n", trim: true)
        # Upstream declares `drop_off_time` and gives every row five fields,
        # which is the shape `GtfsPlanner.Gtfs.Import.CsvParser` rejects. The
        # header is taken from the zip's own row — matched by its first field,
        # since every field is spelled out — and only the data rows are cut to
        # five fields.
        |> then(fn [header | rows] ->
          assert String.starts_with?(header, "trip_id,")

          String.replace(header, "drop_off_type", "drop_off_time") <>
            "\n" <>
            Enum.map_join(rows, "\n", fn row ->
              row |> String.split(",") |> Enum.take(5) |> Enum.join(",")
            end)
        end)

      zip =
        fixture_zip()
        |> Enum.map(fn
          {~c"stop_times.txt", _content} -> {~c"stop_times.txt", upstream_stop_times}
          entry -> entry
        end)
        |> then(&:zip.create(~c"upstream-stop-times.zip", &1, [:memory]))

      assert {:ok, {_name, binary}} = zip

      result =
        Import.import_files(organization.id, gtfs_version.id, [
          %{filename: "upstream-stop-times.zip", content: binary}
        ])

      assert {:error, %Import.Failure{} = failure} = result
      assert failure.failed_file == "stop_times.txt"
      assert failure.reason_code == "wrong_field_count"

      # The rejected rows must not be published even partially.
      assert stored_count(Gtfs.StopTime, gtfs_version) == 0
    end
  end

  defp fixture_binary, do: File.read!(@fixture)

  defp fixture_zip do
    {:ok, entries} = :zip.unzip(String.to_charlist(@fixture), [:memory])
    Enum.map(entries, fn {name, content} -> {name, to_string(content)} end)
  end

  # Counts straight from the zip's bytes: non-empty lines minus the header. This
  # oracle never runs the importer, so it cannot agree with a broken importer.
  defp zip_row_counts do
    contents = Map.new(fixture_zip(), fn {name, content} -> {to_string(name), content} end)

    Map.new(@counted_files, fn {key, filename} ->
      {key, data_row_count(Map.fetch!(contents, filename))}
    end)
  end

  defp data_row_count(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> length()
    |> Kernel.-(1)
  end

  defp stored_count(schema, gtfs_version) do
    Repo.aggregate(from(r in schema, where: r.gtfs_version_id == ^gtfs_version.id), :count)
  end

  # GTFS times are H:MM:SS or HH:MM:SS and may exceed 24 hours for extended
  # service, so they are read as a duration rather than a clock time.
  defp seconds_after_midnight(value) do
    [hours, minutes, seconds] =
      value
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    hours * 3600 + minutes * 60 + seconds
  end
end
