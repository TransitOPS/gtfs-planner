defmodule GtfsPlanner.Gtfs.RoutePatterns.MaterializerBlanksTest do
  @moduledoc """
  A nil offset pair materializes to a nil arrival and departure, so a blank
  non-timepoint stop is the absence of a scheduled time rather than `0` or an
  estimate, while the timed rows around it still decide chronology.

  Expected clock strings and offsets are literals from the GTFS reference (a
  blank interpolated time is absent, `timepoint = 1` carries a time) and from the
  prepared `materialize(25_200, ...)` case; no production function computes an
  expected value here.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  # 25_200 seconds is 07:00:00, the prepared start for the unit case.
  @start_seconds 25_200

  # Five ordered stops; the ends and the middle carry times and the two between
  # them are blank non-timepoints.
  @blank_offsets [
    {0, 0},
    {nil, nil},
    {nil, nil},
    {nil, nil},
    {600, 600}
  ]

  describe "materialize/3 with blank offsets" do
    test "returns nil clock strings at the blank positions and the start time at position 1" do
      occurrences = occurrences(["A", "B", "C", "D", "E"])

      assert {:ok, values} =
               Materializer.materialize(@start_seconds, occurrences, timing_rows(@blank_offsets))

      assert Enum.map(values, &{&1.stop_sequence, &1.stop_id, &1.arrival_time, &1.departure_time}) ==
               [
                 {1, "A", "07:00:00", "07:00:00"},
                 {2, "B", nil, nil},
                 {3, "C", nil, nil},
                 {4, "D", nil, nil},
                 {5, "E", "07:10:00", "07:10:00"}
               ]

      # A blank carries no estimate and no midnight: the row's own offsets stay nil.
      assert Enum.map(values, &{&1.arrival_offset, &1.departure_offset}) == @blank_offsets
    end

    test "a blank between two timed rows does not break chronology" do
      rows = [{0, 0}, {nil, nil}, {300, 300}]

      assert {:ok, values} =
               Materializer.materialize(
                 @start_seconds,
                 occurrences(["A", "B", "C"]),
                 timing_rows(rows)
               )

      assert Enum.map(values, & &1.arrival_time) == ["07:00:00", nil, "07:05:00"]
    end

    test "a timed row out of order is still an error" do
      rows = [{0, 0}, {600, 600}, {300, 300}]

      assert {:error, :invalid_chronology} =
               Materializer.materialize(
                 @start_seconds,
                 occurrences(["A", "B", "C"]),
                 timing_rows(rows)
               )
    end

    test "a blank end stop is an error" do
      rows = [{0, 0}, {nil, nil}, {600, 600}, {nil, nil}]

      assert {:error, :invalid_chronology} =
               Materializer.materialize(
                 @start_seconds,
                 occurrences(["A", "B", "C", "D"]),
                 timing_rows(rows)
               )
    end

    test "a half-timed row is an error" do
      rows = [{0, 0}, {300, nil}, {600, 600}]

      assert {:error, :invalid_chronology} =
               Materializer.materialize(
                 @start_seconds,
                 occurrences(["A", "B", "C"]),
                 timing_rows(rows)
               )
    end

    test "a fully timed vector is unchanged" do
      rows = [{0, 0}, {300, 330}, {720, 720}]

      assert {:ok, values} =
               Materializer.materialize(
                 @start_seconds,
                 occurrences(["A", "B", "C"]),
                 timing_rows(rows)
               )

      assert Enum.map(values, &{&1.arrival_time, &1.departure_time}) ==
               [{"07:00:00", "07:00:00"}, {"07:05:00", "07:05:30"}, {"07:12:00", "07:12:00"}]
    end
  end

  describe "Schedules.create_trips/3 on a timing with blank rows" do
    test "inserts nil times at the blank positions and real times elsewhere", context do
      route_id = "R-blanks"
      service = weekly_calendar(context, route_id)

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: route_id,
          stops: [
            {"A", 0, 0, 1},
            {"B", nil, nil, 0},
            {"C", nil, nil, 0},
            {"D", 600, 600, 1}
          ]
        })

      assert {:ok, %{trips: [trip]}} =
               Schedules.create_trips(
                 route_id,
                 %{
                   pattern_id: bundle.pattern.id,
                   timed_pattern_id: bundle.timing.id,
                   service_id: service,
                   start_time: "07:00:00",
                   repeat: nil
                 },
                 context.audit
               )

      assert trip.pattern_derivation_state == "linked"

      assert Enum.map(
               persisted_stop_times(trip.trip_id),
               &{&1.stop_sequence, &1.stop_id, &1.arrival_time, &1.departure_time}
             ) ==
               [
                 {1, "A", "07:00:00", "07:00:00"},
                 {2, "B", nil, nil},
                 {3, "C", nil, nil},
                 {4, "D", "07:10:00", "07:10:00"}
               ]
    end
  end

  setup do
    organization =
      organization_fixture(%{alias: "materializer-blanks-#{System.system_time(:nanosecond)}"})

    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp occurrences(stop_ids) do
    stop_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {stop_id, position} ->
      %{id: "s#{position}", stop_id: stop_id, position: position}
    end)
  end

  defp timing_rows(offsets) do
    offsets
    |> Enum.with_index(1)
    |> Enum.map(fn {{arrival, departure}, position} ->
      %{
        arrival_offset: arrival,
        departure_offset: departure,
        # The first and last stops are timepoints; the blanks between them are not.
        timepoint: if(position == 1 or position == length(offsets), do: 1, else: 0),
        pickup_type: 0,
        drop_off_type: 0,
        stop_headsign: nil
      }
    end)
  end

  defp weekly_calendar(context, route_id) do
    service_id = "wk_#{System.unique_integer([:positive])}"

    assert {:ok, _payload} =
             GtfsPlanner.Gtfs.create_calendar(
               %{
                 service_id: service_id,
                 name: "Weekday #{route_id}",
                 kind: :weekly,
                 monday: 1,
                 tuesday: 1,
                 wednesday: 1,
                 thursday: 1,
                 friday: 1,
                 saturday: 0,
                 sunday: 0,
                 start_date: ~D[2026-01-05],
                 end_date: ~D[2026-02-27]
               },
               context.audit
             )

    service_id
  end

  defp persisted_stop_times(trip_id) do
    from(st in StopTime,
      where: st.trip_id == ^trip_id,
      order_by: [asc: st.stop_sequence]
    )
    |> Repo.all()
  end
end
