# Step 005 — Estimate the stop times flex derives from
#
# Production-composition integration test (EV-5): `Export.build_zips/4` with an
# estimate method fills each covered trip through `MissingTimes.fill_trip/3`
# before the detour rows are derived, so every flex zone window equals the
# estimated departure/arrival the main zip writes for the stops it sits
# between. Without estimation the derived rows match today's stored behavior,
# an unestimable trip warns only once from the main build, and the service
# page plan preview (`Flex.Export.plan/5`) still reads stored times.

defmodule GtfsPlanner.Gtfs.Export.MissingTimesFlexTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Flex.Export, as: FlexExport
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  # The inbound Valley Line trip runs weekday at 11:00, inside the detour
  # service's 09:00–15:00 band, over TLD2 → TLD1 → NP2 → NP1. Blanking its two
  # middle stops leaves timed anchors at both ends, so distance estimation
  # fills them from the stops' coordinates.
  @trip "20-in-am"
  @blank_stops ["TLD1", "NP2"]

  test "derived zone windows equal the main zip's estimated times" do
    {organization, version} = seed_detour_version()
    blank_stops(organization.id, version.id, @trip, @blank_stops)

    assert {:ok, %{main: main, flex: flex}, _warnings} =
             Export.build_zips(organization.id, version.id, :full,
               include_flex: true,
               estimate: :distance
             )

    main_trip = trip_rows(zip_csvs(main)["stop_times.txt"], @trip)
    derived = derived_rows(zip_csvs(flex)["stop_times.txt"], @trip)

    assert length(main_trip) == 4
    assert length(derived) == 3

    # The middle stops are estimated in the main zip with timepoint 0.
    assert Enum.at(main_trip, 1)["arrival_time"] != ""
    assert Enum.at(main_trip, 1)["timepoint"] == "0"
    assert Enum.at(main_trip, 2)["arrival_time"] != ""
    assert Enum.at(main_trip, 2)["timepoint"] == "0"

    # Each zone row sits between two fixed rows and carries their times.
    for {prev, next, zone} <- Enum.zip([main_trip, tl(main_trip), derived]) do
      assert zone["start_pickup_drop_off_window"] == prev["departure_time"]
      assert zone["end_pickup_drop_off_window"] == next["arrival_time"]
    end

    # INV-1: the estimating build never rewrites stored stop times.
    assert stored_times(organization.id, version.id, @trip, @blank_stops) == [nil, nil, nil, nil]
  end

  test "with estimation off the derived rows match today's stored behavior" do
    {organization, version} = seed_detour_version()
    blank_stops(organization.id, version.id, @trip, @blank_stops)

    assert {:ok, %{flex: flex_off}, _} =
             Export.build_zips(organization.id, version.id, :full, include_flex: true)

    assert {:ok, %{flex: flex_on}, _} =
             Export.build_zips(organization.id, version.id, :full,
               include_flex: true,
               estimate: :distance
             )

    # Every pair of the blanked trip touches a blank stop, so today's stored
    # behavior writes no zone rows for it.
    assert derived_rows(zip_csvs(flex_off)["stop_times.txt"], @trip) == []

    # A fully timed trip's derived rows are identical with and without
    # estimation: estimating changes nothing already timed.
    assert derived_rows(zip_csvs(flex_off)["stop_times.txt"], "20-out-sat") ==
             derived_rows(zip_csvs(flex_on)["stop_times.txt"], "20-out-sat")

    assert {:ok, _entries, flex_warnings} =
             FlexExport.build_entries(organization.id, version.id)

    assert Enum.any?(flex_warnings, &(&1.code == "flex_detour_missing_time"))
  end

  test "an unestimable trip keeps today's derived rows with no duplicate warning" do
    {organization, version} = seed_detour_version()
    blank_stops(organization.id, version.id, @trip, @blank_stops ++ ["NP1"])

    assert {:ok, %{flex: flex_on}, warnings_on} =
             Export.build_zips(organization.id, version.id, :full,
               include_flex: true,
               estimate: :distance
             )

    assert {:ok, %{flex: flex_off}, _} =
             Export.build_zips(organization.id, version.id, :full, include_flex: true)

    # The trip cannot be estimated (no last time): the flex rows are the same
    # as today's stored behavior.
    assert derived_rows(zip_csvs(flex_on)["stop_times.txt"], @trip) ==
             derived_rows(zip_csvs(flex_off)["stop_times.txt"], @trip)

    # The main build warns once; the flex path adds no second warning.
    missing = Enum.filter(warnings_on, &(&1.code == "missing_times_not_estimated"))
    assert length(missing) == 1
    assert hd(missing).detail =~ @trip
  end

  test "the service page plan preview still reads stored times" do
    {organization, version, service} = seed_detour_version_with_service()
    blank_stops(organization.id, version.id, @trip, @blank_stops)

    zones = FlexExport.plan_zones(organization.id, version.id, service)
    assert length(zones) == 3

    plan = FlexExport.plan(organization.id, version.id, service, [], zones: zones)

    # The plan derives from stored times: the blanked trip's pairs are missing
    # times, so it plans no rows for them, exactly as before estimation.
    planned =
      plan.rows
      |> Enum.filter(&(&1.file == "stop_times.txt" and &1.id == @trip))

    assert planned == []
    assert Enum.any?(plan.warnings, &(&1.code == "flex_detour_missing_time"))
  end

  # --- fixtures ---------------------------------------------------------------

  defp seed_detour_version do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    flex_representative_fixture(organization, version)
    {organization, version}
  end

  defp seed_detour_version_with_service do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    feed = flex_representative_fixture(organization, version)
    {organization, version, feed.services.detour}
  end

  defp blank_stops(organization_id, version_id, trip_id, stop_ids) do
    {count, _} =
      from(st in StopTime,
        where:
          st.organization_id == ^organization_id and
            st.gtfs_version_id == ^version_id and st.trip_id == ^trip_id and
            st.stop_id in ^stop_ids
      )
      |> Repo.update_all(set: [arrival_time: nil, departure_time: nil])

    assert count == length(stop_ids)
  end

  # --- zip helpers ------------------------------------------------------------

  defp zip_csvs(zip_binary) do
    {:ok, entries} = :zip.unzip(zip_binary, [:memory])

    Map.new(entries, fn {name, content} ->
      {to_string(name), parse_csv(to_string(content))}
    end)
  end

  defp parse_csv(content) do
    [header | lines] = String.split(content, "\n", trim: true)
    columns = String.split(header, ",")

    Enum.map(lines, fn line ->
      columns |> Enum.zip(String.split(line, ",")) |> Map.new()
    end)
  end

  defp trip_rows(rows, trip_id) do
    rows
    |> Enum.filter(&(&1["trip_id"] == trip_id))
    |> Enum.sort_by(&String.to_integer(&1["stop_sequence"]))
  end

  defp derived_rows(rows, trip_id) do
    rows
    |> Enum.filter(&(&1["trip_id"] == trip_id and &1["location_id"] != ""))
    |> Enum.sort_by(&String.to_integer(&1["stop_sequence"]))
  end

  defp stored_times(organization_id, version_id, trip_id, stop_ids) do
    from(st in StopTime,
      where:
        st.organization_id == ^organization_id and
          st.gtfs_version_id == ^version_id and st.trip_id == ^trip_id and
          st.stop_id in ^stop_ids,
      order_by: [asc: st.stop_sequence],
      select: {st.arrival_time, st.departure_time}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {arrival, departure} -> [arrival, departure] end)
  end
end
