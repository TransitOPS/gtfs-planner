# Step 007 — Summarize missing times for a version
#
# Data-test proof (EV-7): `MissingTimes.summary/2` counts a version's missing
# stop times and classifies trips exactly as the export does, scoped to one
# organization and version with the export's inactive-route closure.

defmodule GtfsPlanner.Gtfs.Export.MissingTimesSummaryTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export.MissingTimes
  alias GtfsPlanner.Gtfs.Export.StreamBuilder
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  # Org A version 1: one fillable trip plus one trip per can't-estimate
  # reason, a no-distance route, an inactive route, all with literal counts:
  # 6 trips, 16 missing cells, 2 estimable trips, 8 estimable times.
  defp seed_version_one do
    org = organization_fixture()
    v1 = gtfs_version_fixture(org.id)

    for index <- 1..5 do
      stop_fixture(org.id, v1.id, stop_id: "S#{index}")
    end

    stop_fixture(org.id, v1.id,
      stop_id: "L1",
      stop_lat: Decimal.new("45.0"),
      stop_lon: Decimal.new("-124.0")
    )

    stop_fixture(org.id, v1.id,
      stop_id: "L2",
      stop_lat: Decimal.new("45.004"),
      stop_lon: Decimal.new("-124.004")
    )

    stop_fixture(org.id, v1.id,
      stop_id: "L3",
      stop_lat: Decimal.new("45.009"),
      stop_lon: Decimal.new("-124.012")
    )

    route_fixture(org.id, v1.id,
      route_id: "R1",
      route_short_name: "10",
      route_long_name: "Downtown Loop",
      route_color: "FF0000"
    )

    route_fixture(org.id, v1.id,
      route_id: "R2",
      route_short_name: "20",
      route_long_name: "Crosstown",
      route_color: "00FF00"
    )

    route_fixture(org.id, v1.id, route_id: "R_OFF", active: false)

    # Fillable by stored distance: anchors 08:00/08:10 over
    # 0/200/400/2400/3000, three fully blank rows (6 missing cells).
    trip_fixture(org.id, v1.id, "R1", %{trip_id: "T_FILL", service_id: "SV1"})

    blank_rows(org.id, v1.id, "T_FILL", [
      {"S1", 1, "08:00:00", "08:00:00", nil, "0"},
      {"S2", 2, nil, nil, nil, "200"},
      {"S3", 3, nil, nil, nil, "400"},
      {"S4", 4, nil, nil, nil, "2400"},
      {"S5", 5, "08:10:00", "08:10:00", 1, "3000"}
    ])

    # No first time: 2 missing cells, first departure unknown.
    trip_fixture(org.id, v1.id, "R1", %{trip_id: "T_NOFIRST", service_id: "SV1"})

    blank_rows(org.id, v1.id, "T_NOFIRST", [
      {"S1", 1, nil, nil, nil, "0"},
      {"S2", 2, "08:02:00", "08:02:00", nil, "750"},
      {"S3", 3, "08:04:00", "08:04:00", nil, "1500"},
      {"S4", 4, "08:06:00", "08:06:00", nil, "2250"},
      {"S5", 5, "08:10:00", "08:10:00", 1, "3000"}
    ])

    # No last time: 2 missing cells.
    trip_fixture(org.id, v1.id, "R1", %{trip_id: "T_NOLAST", service_id: "SV1"})

    blank_rows(org.id, v1.id, "T_NOLAST", [
      {"S1", 1, "08:00:00", "08:00:00", 1, "0"},
      {"S2", 2, "08:02:00", "08:02:00", nil, "750"},
      {"S3", 3, "08:04:00", "08:04:00", nil, "1500"},
      {"S4", 4, "08:06:00", "08:06:00", nil, "2250"},
      {"S5", 5, nil, nil, nil, "3000"}
    ])

    # Untimed timepoint in the middle: 2 missing cells.
    trip_fixture(org.id, v1.id, "R1", %{trip_id: "T_TP", service_id: "SV1"})

    blank_rows(org.id, v1.id, "T_TP", [
      {"S1", 1, "08:00:00", "08:00:00", 1, "0"},
      {"S2", 2, nil, nil, 1, "1500"},
      {"S3", 3, "08:10:00", "08:10:00", 1, "3000"}
    ])

    # Out-of-order anchors: 2 missing cells.
    trip_fixture(org.id, v1.id, "R1", %{trip_id: "T_OOO", service_id: "SV1"})

    blank_rows(org.id, v1.id, "T_OOO", [
      {"S1", 1, "08:00:00", "08:00:00", 1, "0"},
      {"S2", 2, nil, nil, nil, "1000"},
      {"S3", 3, "08:05:00", "08:05:00", 1, "2000"},
      {"S4", 4, "08:03:00", "08:03:00", 1, "3000"}
    ])

    # No stored distances at all: fills by straight line (2 missing cells).
    trip_fixture(org.id, v1.id, "R2", %{trip_id: "T_LINE", service_id: "SV2"})

    blank_rows(org.id, v1.id, "T_LINE", [
      {"L1", 1, "09:00:00", "09:00:00", 1, nil},
      {"L2", 2, nil, nil, nil, nil},
      {"L3", 3, "09:10:00", "09:10:00", 1, nil}
    ])

    # Inactive route: the export leaves the whole trip out.
    trip_fixture(org.id, v1.id, "R_OFF", %{trip_id: "T_OFF", service_id: "SV9"})

    blank_rows(org.id, v1.id, "T_OFF", [
      {"S1", 1, "08:00:00", "08:00:00", 1, "0"},
      {"S2", 2, nil, nil, nil, "1500"},
      {"S3", 3, "08:10:00", "08:10:00", 1, "3000"}
    ])

    {org, v1}
  end

  defp blank_rows(organization_id, version_id, trip_id, rows) do
    Enum.each(rows, fn {stop_id, sequence, arrival, departure, timepoint, distance} ->
      attrs = %{
        stop_sequence: sequence,
        arrival_time: arrival,
        departure_time: departure,
        timepoint: timepoint
      }

      attrs =
        if is_nil(distance),
          do: attrs,
          else: Map.put(attrs, :shape_dist_traveled, Decimal.new(distance))

      stop_time_fixture(organization_id, version_id, trip_id, stop_id, attrs)
    end)
  end

  defp ordered_stop_times(organization_id, version_id, trip_id) do
    from(s in StopTime,
      where: s.organization_id == ^organization_id,
      where: s.gtfs_version_id == ^version_id,
      where: s.trip_id == ^trip_id,
      order_by: s.stop_sequence
    )
    |> Repo.all()
  end

  defp ordered_all_stop_times(organization_id, version_id) do
    from(s in StopTime,
      where: s.organization_id == ^organization_id,
      where: s.gtfs_version_id == ^version_id,
      order_by: [asc: s.trip_id, asc: s.stop_sequence]
    )
    |> Repo.all()
  end

  test "counts trips and missing cells with literal expected numbers" do
    {org, v1} = seed_version_one()

    before = ordered_all_stop_times(org.id, v1.id)

    assert %{
             trips: 6,
             missing_times: 16,
             estimable_trips: 2,
             estimable_times: 8
           } = MissingTimes.summary(org.id, v1.id)

    # INV-1: the summary never writes stop_times rows.
    assert ordered_all_stop_times(org.id, v1.id) == before
  end

  test "lists each can't-estimate trip with the same reason fill_trip/3 returns" do
    {org, v1} = seed_version_one()
    coords = MissingTimes.stop_coordinates(org.id, v1.id)

    expected = [
      {"T_NOFIRST", :no_first_time, "first stop has no time", nil},
      {"T_NOLAST", :no_last_time, "last stop has no time", "08:00:00"},
      {"T_OOO", :order, "backwards", "08:00:00"},
      {"T_TP", :timepoint_without_time, "timepoint without times", "08:00:00"}
    ]

    summary = MissingTimes.summary(org.id, v1.id)

    assert Enum.map(summary.not_estimable, & &1.trip_id) == [
             "T_NOFIRST",
             "T_NOLAST",
             "T_OOO",
             "T_TP"
           ]

    for {trip_id, reason, snippet, first_departure} <- expected do
      records = ordered_stop_times(org.id, v1.id, trip_id)

      assert {_records, {:not_estimated, warning}} =
               MissingTimes.fill_trip(records, :distance, coords)

      assert warning.detail =~ snippet

      assert %{route_id: "R1", service_id: "SV1", reason: ^reason} =
               Enum.find(summary.not_estimable, &(&1.trip_id == trip_id))

      assert %{first_departure: ^first_departure} =
               Enum.find(summary.not_estimable, &(&1.trip_id == trip_id))
    end
  end

  test "groups routes with names, color and the straight-line flag" do
    {org, v1} = seed_version_one()

    assert [
             %{
               route_id: "R1",
               route_short_name: "10",
               route_long_name: "Downtown Loop",
               route_color: "FF0000",
               trips: 5,
               missing_times: 14,
               straight_line?: false
             },
             %{
               route_id: "R2",
               route_short_name: "20",
               route_long_name: "Crosstown",
               route_color: "00FF00",
               trips: 1,
               missing_times: 2,
               straight_line?: true
             }
           ] = MissingTimes.summary(org.id, v1.id).routes
  end

  test "never counts another organization's or version's trips" do
    {org, v1} = seed_version_one()

    other_org = organization_fixture()
    other_version = gtfs_version_fixture(other_org.id)
    stop_fixture(other_org.id, other_version.id, stop_id: "S1")
    route_fixture(other_org.id, other_version.id, route_id: "RB")
    trip_fixture(other_org.id, other_version.id, "RB", %{trip_id: "T_OTHER"})

    stop_time_fixture(other_org.id, other_version.id, "T_OTHER", "S1", %{
      stop_sequence: 1,
      arrival_time: nil,
      departure_time: nil
    })

    v2 = gtfs_version_fixture(org.id)
    stop_fixture(org.id, v2.id, stop_id: "S1")
    route_fixture(org.id, v2.id, route_id: "R1")
    trip_fixture(org.id, v2.id, "R1", %{trip_id: "T_V2"})

    stop_time_fixture(org.id, v2.id, "T_V2", "S1", %{
      stop_sequence: 1,
      arrival_time: nil,
      departure_time: nil
    })

    assert %{trips: 6, missing_times: 16} = MissingTimes.summary(org.id, v1.id)
    assert %{trips: 1, missing_times: 2} = MissingTimes.summary(org.id, v2.id)
    assert %{trips: 1, missing_times: 2} = MissingTimes.summary(other_org.id, other_version.id)
  end

  test "excludes trips on inactive routes, matching stream_records/4" do
    {org, v1} = seed_version_one()

    {:ok, streamed_trip_ids} =
      Repo.transaction(fn ->
        StreamBuilder.stream_records(Repo, StopTime, org.id, v1.id)
        |> Enum.map(& &1.trip_id)
        |> Enum.uniq()
        |> Enum.sort()
      end)

    assert "T_FILL" in streamed_trip_ids
    refute "T_OFF" in streamed_trip_ids

    summary = MissingTimes.summary(org.id, v1.id)
    refute Enum.any?(summary.not_estimable, &(&1.trip_id == "T_OFF"))
    refute Enum.any?(summary.routes, &(&1.route_id == "R_OFF"))
    assert summary.trips == 6
  end

  test "a version with no blanks returns zero counts without loading estimation inputs" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    stop_fixture(org.id, version.id, stop_id: "S1")
    route_fixture(org.id, version.id, route_id: "R1")
    trip_fixture(org.id, version.id, "R1", %{trip_id: "T_FULL"})

    stop_time_fixture(org.id, version.id, "T_FULL", "S1", %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00",
      timepoint: 1
    })

    handler_id = "missing-times-summary-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          if self() == pid, do: send(pid, {:summary_query, metadata.source})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert MissingTimes.summary(org.id, version.id) == %{
             trips: 0,
             missing_times: 0,
             estimable_trips: 0,
             estimable_times: 0,
             not_estimable: [],
             routes: []
           }

    assert_receive {:summary_query, "stop_times"}
    refute_receive {:summary_query, _source}, 0
  end

  test "counts NULL and empty arrival and departure cells once per trip" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    stop_fixture(org.id, version.id, stop_id: "S1")
    route_fixture(org.id, version.id, route_id: "R1")
    trip_fixture(org.id, version.id, "R1", %{trip_id: "T_MIXED"})

    blank_rows(org.id, version.id, "T_MIXED", [
      {"S1", 1, "08:00:00", "08:00:00", 1, "0"},
      {"S1", 2, nil, nil, 0, "1500"},
      {"S1", 3, "08:10:00", "08:10:00", 1, "3000"}
    ])

    # Bypass changeset normalization to exercise literal empty strings as well as NULL.
    from(s in StopTime,
      where: s.organization_id == ^org.id and s.gtfs_version_id == ^version.id,
      where: s.trip_id == "T_MIXED" and s.stop_sequence in [1, 2]
    )
    |> Repo.update_all(set: [arrival_time: ""])

    from(s in StopTime,
      where: s.organization_id == ^org.id and s.gtfs_version_id == ^version.id,
      where: s.trip_id == "T_MIXED" and s.stop_sequence == 3
    )
    |> Repo.update_all(set: [departure_time: ""])

    assert %{
             trips: 1,
             missing_times: 4,
             estimable_trips: 1,
             estimable_times: 4,
             not_estimable: [],
             routes: [%{route_id: "R1", trips: 1, missing_times: 4}]
           } = MissingTimes.summary(org.id, version.id)
  end

  test "classifies with the organization's saved estimate method" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    stop_fixture(org.id, version.id, stop_id: "S1")
    stop_fixture(org.id, version.id, stop_id: "S2")
    route_fixture(org.id, version.id, route_id: "R1")
    trip_fixture(org.id, version.id, "R1", %{trip_id: "T_EVEN"})

    blank_rows(org.id, version.id, "T_EVEN", [
      {"S1", 1, "08:00:00", "08:00:00", 1, "0"},
      {"S2", 2, nil, nil, nil, "1500"},
      {"S1", 3, "08:10:00", "08:10:00", 1, "3000"}
    ])

    assert %{estimable_trips: 1, estimable_times: 2} =
             MissingTimes.summary(org.id, version.id)

    {:ok, _} = ExportDefaults.update(org.id, editor_fixture(org), %{estimate_method: :even})

    assert %{estimable_trips: 1, estimable_times: 2} =
             MissingTimes.summary(org.id, version.id)
  end
end
