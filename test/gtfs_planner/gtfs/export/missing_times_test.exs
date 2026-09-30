defmodule GtfsPlanner.Gtfs.Export.MissingTimesTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export.MissingTimes
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime

  defp row(trip_id, stop_id, seq, arrival, departure, opts \\ []) do
    %{
      trip_id: trip_id,
      stop_id: stop_id,
      stop_sequence: seq,
      arrival_time: arrival,
      departure_time: departure,
      stop_headsign: Keyword.get(opts, :headsign),
      shape_dist_traveled: Keyword.get(opts, :distance),
      timepoint: Keyword.get(opts, :timepoint)
    }
  end

  defp dist(value), do: Decimal.new(value)

  describe "fill_trip/3 with complete trips" do
    test "a trip with no blank rows returns the identical record list and :unchanged" do
      records = [
        row("T1", "S1", 1, "08:00:00", "08:00:00", timepoint: 1),
        row("T1", "S2", 2, "08:02:00", "08:02:00", timepoint: 0),
        row("T1", "S3", 3, "08:05:00", "08:06:00", timepoint: nil)
      ]

      assert {^records, :unchanged} = MissingTimes.fill_trip(records, :distance, %{})
    end

    test "an empty trip returns :unchanged" do
      assert {[], :unchanged} = MissingTimes.fill_trip([], :distance, %{})
    end
  end

  describe "fill_trip/3 with stored distances" do
    test "fills blanks by distance with R8 flags and leaves the rest as stored" do
      records = [
        row("T1", "S1", 1, "08:00:00", "08:00:00", timepoint: nil, distance: dist("0")),
        row("T1", "S2", 2, nil, nil, timepoint: nil, distance: dist("200")),
        row("T1", "S3", 3, nil, nil,
          timepoint: nil,
          distance: dist("400"),
          headsign: "Downtown"
        ),
        row("T1", "S4", 4, nil, nil, timepoint: nil, distance: dist("2400")),
        row("T1", "S5", 5, "08:10:00", "08:10:00", timepoint: 1, distance: dist("3000"))
      ]

      assert {filled, :filled} = MissingTimes.fill_trip(records, :distance, %{})

      assert [
               %{arrival_time: "08:00:00", departure_time: "08:00:00", timepoint: 1},
               %{arrival_time: "08:00:40", departure_time: "08:00:40", timepoint: 0},
               %{
                 arrival_time: "08:01:20",
                 departure_time: "08:01:20",
                 timepoint: 0,
                 stop_headsign: "Downtown"
               },
               %{arrival_time: "08:08:00", departure_time: "08:08:00", timepoint: 0},
               %{arrival_time: "08:10:00", departure_time: "08:10:00", timepoint: 1}
             ] = filled
    end
  end

  describe "fill_trip/3 with stop coordinates" do
    test "uses the straight line when stored distances are missing" do
      records = [
        row("T1", "S1", 1, "08:00:00", "08:00:00", timepoint: 1),
        row("T1", "S2", 2, nil, nil),
        row("T1", "S3", 3, nil, nil),
        row("T1", "S4", 4, nil, nil),
        row("T1", "S5", 5, "08:10:00", "08:10:00", timepoint: 1)
      ]

      coords = %{
        "S1" => {45.0, -122.0},
        "S2" => {45.001, -122.003},
        "S3" => {45.004, -122.004},
        "S4" => {45.006, -122.010},
        "S5" => {45.009, -122.012}
      }

      assert {filled, :filled} = MissingTimes.fill_trip(records, :distance, coords)

      assert [
               %{arrival_time: "08:00:00", departure_time: "08:00:00", timepoint: 1},
               %{arrival_time: "08:01:44", departure_time: "08:01:44", timepoint: 0},
               %{arrival_time: "08:04:02", departure_time: "08:04:02", timepoint: 0},
               %{arrival_time: "08:07:31", departure_time: "08:07:31", timepoint: 0},
               %{arrival_time: "08:10:00", departure_time: "08:10:00", timepoint: 1}
             ] = filled
    end
  end

  describe "fill_trip/3 with one-sided rows" do
    test "copies the single time to the other side" do
      records = [
        row("T1", "S1", 1, "08:00:00", "08:00:00", timepoint: 1),
        row("T1", "S2", 2, "08:05:00", nil, timepoint: nil),
        row("T1", "S3", 3, "08:10:00", "08:10:00", timepoint: 1)
      ]

      assert {filled, :filled} = MissingTimes.fill_trip(records, :distance, %{})

      assert [
               %{arrival_time: "08:00:00", departure_time: "08:00:00", timepoint: 1},
               %{arrival_time: "08:05:00", departure_time: "08:05:00", timepoint: 1},
               %{arrival_time: "08:10:00", departure_time: "08:10:00", timepoint: 1}
             ] = filled
    end
  end

  describe "fill_trip/3 with overnight times" do
    test "25:10:00 anchors fill unwrapped through GtfsTime.format/1" do
      records = [
        %StopTime{
          trip_id: "TN",
          stop_id: "S1",
          stop_sequence: 1,
          arrival_time: "25:10:00",
          departure_time: "25:10:00",
          timepoint: nil
        },
        %StopTime{
          trip_id: "TN",
          stop_id: "S2",
          stop_sequence: 2,
          arrival_time: nil,
          departure_time: nil,
          timepoint: nil
        },
        %StopTime{
          trip_id: "TN",
          stop_id: "S3",
          stop_sequence: 3,
          arrival_time: "25:20:00",
          departure_time: "25:20:00",
          timepoint: 1
        }
      ]

      assert {filled, :filled} = MissingTimes.fill_trip(records, :distance, %{})

      assert [
               %StopTime{
                 arrival_time: "25:10:00",
                 departure_time: "25:10:00",
                 timepoint: 1
               },
               %StopTime{
                 arrival_time: "25:15:00",
                 departure_time: "25:15:00",
                 timepoint: 0
               },
               %StopTime{
                 arrival_time: "25:20:00",
                 departure_time: "25:20:00",
                 timepoint: 1
               }
             ] = filled
    end
  end

  describe "fill_trip/3 with trips that cannot be estimated" do
    test "a trip with no last time returns unchanged with one warning" do
      records = [
        row("T2", "S1", 1, "08:00:00", "08:00:00", timepoint: 1),
        row("T2", "S2", 2, nil, nil),
        row("T2", "S3", 3, nil, nil)
      ]

      assert {^records, {:not_estimated, warning}} =
               MissingTimes.fill_trip(records, :distance, %{})

      assert warning.code == "missing_times_not_estimated"
      assert warning.file == "stop_times.txt"
      assert warning.entity_type == "trip"
      assert warning.detail =~ "T2"
      assert warning.detail =~ "last stop has no time"
    end

    test "a trip with an untimed timepoint returns unchanged with one warning" do
      records = [
        row("T3", "S1", 1, "08:00:00", "08:00:00", timepoint: 1),
        row("T3", "S2", 2, nil, nil, timepoint: 1),
        row("T3", "S3", 3, "08:10:00", "08:10:00", timepoint: 1)
      ]

      assert {^records, {:not_estimated, warning}} =
               MissingTimes.fill_trip(records, :distance, %{})

      assert warning.code == "missing_times_not_estimated"
      assert warning.detail =~ "T3"
      assert warning.detail =~ "timepoint without times"
    end

    test "a trip with out-of-order anchors returns unchanged with one warning" do
      records = [
        row("T4", "S1", 1, "08:00:00", "08:00:00", timepoint: 1),
        row("T4", "S2", 2, nil, nil),
        row("T4", "S3", 3, "08:05:00", "08:05:00", timepoint: 1),
        row("T4", "S4", 4, "08:03:00", "08:03:00", timepoint: 1)
      ]

      assert {^records, {:not_estimated, warning}} =
               MissingTimes.fill_trip(records, :distance, %{})

      assert warning.code == "missing_times_not_estimated"
      assert warning.detail =~ "T4"
      assert warning.detail =~ "backwards"
    end
  end

  describe "cap_warnings/2" do
    test "returns short lists untouched" do
      warnings = [
        %{code: "missing_times_not_estimated", detail: "d", file: "f", entity_type: "trip"}
      ]

      assert ^warnings = MissingTimes.cap_warnings(warnings)
    end

    test "caps 150 warnings at 99 plus one summary naming 51 more" do
      warnings =
        for i <- 1..150 do
          %{
            code: "missing_times_not_estimated",
            detail: "Trip T#{i} was left blank.",
            file: "stop_times.txt",
            entity_type: "trip"
          }
        end

      capped = MissingTimes.cap_warnings(warnings)

      assert length(capped) == 100
      assert Enum.take(capped, 99) == Enum.take(warnings, 99)

      summary = List.last(capped)
      assert summary.code == "missing_times_not_estimated_more"
      assert summary.file == "stop_times.txt"
      assert summary.entity_type == "trip"
      assert summary.detail =~ "51"
    end

    test "leaves no room at a limit of zero" do
      warnings = [
        %{code: "missing_times_not_estimated", detail: "d", file: "f", entity_type: "trip"}
      ]

      assert MissingTimes.cap_warnings(warnings, 0) == []
    end
  end

  describe "stop_coordinates/2" do
    test "returns only the given organization's and version's stops with coordinates" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      other_org = organization_fixture()
      other_org_version = gtfs_version_fixture(other_org.id)
      other_version = gtfs_version_fixture(org.id)

      s1 = stop_fixture(org.id, version.id, %{stop_id: "COORD-1"})
      s2 = stop_fixture(org.id, version.id, %{stop_id: "COORD-2"})

      Repo.insert!(%Stop{
        organization_id: org.id,
        gtfs_version_id: version.id,
        stop_id: "COORDLESS",
        stop_name: "No coordinates"
      })

      stop_fixture(other_org.id, other_org_version.id, %{stop_id: "COORD-1"})
      stop_fixture(org.id, other_version.id, %{stop_id: "COORD-1"})

      coords = MissingTimes.stop_coordinates(org.id, version.id)

      assert Map.keys(coords) |> Enum.sort() == ["COORD-1", "COORD-2"]

      assert {lat1, lon1} = coords["COORD-1"]
      assert_in_delta lat1, Decimal.to_float(s1.stop_lat), 0.000000001
      assert_in_delta lon1, Decimal.to_float(s1.stop_lon), 0.000000001

      assert {lat2, lon2} = coords["COORD-2"]
      assert_in_delta lat2, Decimal.to_float(s2.stop_lat), 0.000000001
      assert_in_delta lon2, Decimal.to_float(s2.stop_lon), 0.000000001
    end
  end
end
