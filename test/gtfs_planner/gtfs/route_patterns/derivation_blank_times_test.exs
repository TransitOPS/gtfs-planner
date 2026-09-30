defmodule GtfsPlanner.Gtfs.RoutePatterns.DerivationBlankTimesTest do
  @moduledoc """
  Derivation with blank non-timepoint times: a trip whose only blanks are between
  timed stops links and stores nil offset pairs, while a half pair, a blank end,
  a blank timepoint and a backwards trip stay custom. A fully timed trip links
  with integer offsets, as before.

  Expected offsets, reasons and counts are literals from the GTFS reference
  (`timepoint=1` carries a time, interpolated times "should" be provided
  otherwise) and MBTA `route_patterns.txt`; no production function computes an
  expected value here.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # Thirteen ordered stops.
  @stop_ids ~w(S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13)

  # The two ends and three interior timepoints, three minutes apart each.
  @timed_positions [1, 4, 7, 10, 13]

  setup _context do
    organization =
      organization_fixture(%{alias: "derivation-blank-times-#{System.system_time(:nanosecond)}"})

    version = gtfs_version_fixture(organization.id)
    _route = route_fixture(organization.id, version.id, %{route_id: "R1"})

    stops =
      Map.new(@stop_ids, fn stop_id ->
        {stop_id,
         stop_fixture(organization.id, version.id, %{
           stop_id: stop_id,
           stop_name: "Stop #{stop_id}"
         })}
      end)

    %{organization: organization, version: version, stops: stops}
  end

  describe "a trip blank between timepoints" do
    test "links, stores nil offsets and leaves its stop_times rows alone", context do
      _trip = imported_trip(context, "T-1", blank_timed_rows())

      before = stop_time_snapshot(context)

      assert {:ok, summary} =
               Derivation.derive_version(
                 context.organization.id,
                 context.version.id,
                 {:import, nil}
               )

      assert summary.patterns_created == 1
      assert summary.timings_created == 1
      assert summary.trips_linked == 1
      assert summary.trips_custom == 0

      linked = Repo.get_by!(Trip, trip_id: "T-1")
      assert linked.pattern_derivation_state == "linked"
      assert linked.pattern_derivation_reason == nil
      refute is_nil(linked.route_pattern_id)
      refute is_nil(linked.timed_pattern_id)

      rows = timing_rows(linked.timed_pattern_id)
      assert length(rows) == 13

      assert offsets(rows) == [
               {0, 0},
               {nil, nil},
               {nil, nil},
               {540, 540},
               {nil, nil},
               {nil, nil},
               {1080, 1080},
               {nil, nil},
               {nil, nil},
               {1620, 1620},
               {nil, nil},
               {nil, nil},
               {2160, 2160}
             ]

      # Grouping is linkage only; the imported stop times are unchanged.
      assert stop_time_snapshot(context) == before
    end

    test "two trips with the same timed values share one timing", context do
      _first = imported_trip(context, "T-1", blank_timed_rows())
      _second = imported_trip(context, "T-2", blank_timed_rows())

      assert {:ok, summary} =
               Derivation.derive_version(
                 context.organization.id,
                 context.version.id,
                 {:import, nil}
               )

      assert summary.patterns_created == 1
      assert summary.timings_created == 1
      assert summary.trips_linked == 2

      assert [timing] = timings(context)
      rows = timing_rows(timing.id)
      assert length(rows) == 13
      assert Enum.count(offsets(rows), fn {arrival, _departure} -> is_nil(arrival) end) == 8
    end
  end

  describe "trips that stay outside patterns" do
    test "a stop with an arrival but no departure is custom missing_times", context do
      rows = blank_timed_rows()

      trip =
        imported_trip(
          context,
          "T-half",
          List.replace_at(rows, 1, %{Enum.at(rows, 1) | departure_time: nil})
        )

      assert {:ok, _summary} = derive(context)
      assert custom_reason(trip) == "missing_times"
    end

    test "a stop with a departure but no arrival is custom missing_times", context do
      rows = blank_timed_rows()

      trip =
        imported_trip(
          context,
          "T-half-departure",
          List.replace_at(rows, 1, %{Enum.at(rows, 1) | arrival_time: nil})
        )

      assert {:ok, _summary} = derive(context)
      assert custom_reason(trip) == "missing_times"
    end

    test "a blank last stop is custom missing_times", context do
      rows = List.replace_at(blank_timed_rows(), 12, blank_row("S13"))
      trip = imported_trip(context, "T-blank-last", rows)

      assert {:ok, _summary} = derive(context)
      assert custom_reason(trip) == "missing_times"
    end

    test "a blank first stop is custom missing_times", context do
      rows = List.replace_at(blank_timed_rows(), 0, blank_row("S1"))
      trip = imported_trip(context, "T-blank-first", rows)

      assert {:ok, _summary} = derive(context)
      assert custom_reason(trip) == "missing_times"
    end

    test "a blank timepoint stop is custom missing_times", context do
      # The stop keeps `timepoint = 1`; only its times go blank.
      rows = List.replace_at(blank_timed_rows(), 6, blank_row("S7", %{timepoint: 1}))
      trip = imported_trip(context, "T-blank-timepoint", rows)

      assert {:ok, _summary} = derive(context)
      assert custom_reason(trip) == "missing_times"
    end

    test "timed rows that go backwards are custom invalid_chronology", context do
      rows =
        blank_timed_rows()
        |> List.replace_at(6, time_row("S7", "08:06:00", "08:06:00", %{timepoint: 1}))
        |> List.replace_at(9, time_row("S10", "08:27:00", "08:27:00", %{timepoint: 1}))

      trip = imported_trip(context, "T-backwards", rows)

      assert {:ok, _summary} = derive(context)
      assert custom_reason(trip) == "invalid_chronology"
    end

    test "a departure before its own arrival is custom invalid_chronology", context do
      rows =
        blank_timed_rows()
        |> List.replace_at(3, time_row("S4", "08:09:00", "08:08:00", %{timepoint: 1}))

      trip = imported_trip(context, "T-departure-first", rows)

      assert {:ok, _summary} = derive(context)
      assert custom_reason(trip) == "invalid_chronology"
    end

    test "an unparseable time is custom invalid_time", context do
      rows =
        blank_timed_rows()
        |> List.replace_at(2, time_row("S3", "not-a-time"))

      trip = imported_trip(context, "T-garbage", rows)

      assert {:ok, _summary} = derive(context)
      assert custom_reason(trip) == "invalid_time"
    end
  end

  describe "a fully timed trip" do
    test "links with integer offsets and no nil", context do
      _trip = imported_trip(context, "T-full", fully_timed_rows())

      assert {:ok, summary} = derive(context)

      assert summary.patterns_created == 1
      assert summary.timings_created == 1
      assert summary.trips_linked == 1

      linked = Repo.get_by!(Trip, trip_id: "T-full")
      assert linked.pattern_derivation_state == "linked"

      assert offsets(timing_rows(linked.timed_pattern_id)) ==
               Enum.map(0..12, fn stops_passed -> {stops_passed * 240, stops_passed * 240} end)
    end
  end

  defp derive(context) do
    Derivation.derive_version(context.organization.id, context.version.id, {:import, nil})
  end

  # Thirteen ordered rows: the two ends and three interior timepoints carry both
  # times and a timepoint marker, every other position is blank.
  defp blank_timed_rows do
    @stop_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {stop_id, position} ->
      if position in @timed_positions do
        minutes = (position - 1) * 3
        time = "08:#{minutes |> Integer.to_string() |> String.pad_leading(2, "0")}:00"
        time_row(stop_id, time, time, %{timepoint: 1})
      else
        blank_row(stop_id)
      end
    end)
  end

  # Every stop timed, four minutes apart, with timepoints every fourth stop.
  defp fully_timed_rows do
    @stop_ids
    |> Enum.with_index(0)
    |> Enum.map(fn {stop_id, stops_passed} ->
      minutes = stops_passed * 4
      time = "08:#{minutes |> Integer.to_string() |> String.pad_leading(2, "0")}:00"
      extra = if(rem(stops_passed, 4) == 0, do: %{timepoint: 1}, else: %{})
      time_row(stop_id, time, time, extra)
    end)
  end

  defp blank_row(stop_id, extra \\ %{}) do
    stop_time_row(stop_id, nil, nil, extra)
  end

  defp time_row(stop_id, arrival, departure \\ nil, extra \\ %{}) do
    stop_time_row(stop_id, arrival, departure || arrival, extra)
  end

  defp stop_time_row(stop_id, arrival, departure, extra) do
    Map.merge(
      %{
        stop_id: stop_id,
        arrival_time: arrival,
        departure_time: departure,
        timepoint: nil,
        pickup_type: nil,
        drop_off_type: nil,
        stop_headsign: nil
      },
      extra
    )
  end

  defp offsets(rows), do: Enum.map(rows, &{&1.arrival_offset, &1.departure_offset})

  defp custom_reason(trip) do
    stored = Repo.get!(Trip, trip.id)
    assert stored.pattern_derivation_state == "custom"
    stored.pattern_derivation_reason
  end

  defp timings(context) do
    from(t in TimedPattern,
      where:
        t.organization_id == ^context.organization.id and
          t.gtfs_version_id == ^context.version.id,
      order_by: [asc: t.name, asc: t.id]
    )
    |> Repo.all()
  end

  defp timing_rows(timing_id) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where: row.timed_pattern_id == ^timing_id,
      order_by: [asc: occurrence.position]
    )
    |> Repo.all()
  end

  defp stop_time_snapshot(context) do
    from(st in StopTime,
      where:
        st.organization_id == ^context.organization.id and
          st.gtfs_version_id == ^context.version.id,
      order_by: [asc: st.trip_id, asc: st.stop_sequence],
      select:
        {st.id, st.trip_id, st.stop_id, st.stop_sequence, st.arrival_time, st.departure_time,
         st.timepoint, st.pickup_type, st.drop_off_type, st.stop_headsign}
    )
    |> Repo.all()
  end

  defp imported_trip(context, trip_id, rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    trip =
      %{
        id: Ecto.UUID.generate(),
        trip_id: trip_id,
        route_id: "R1",
        service_id: "WK",
        direction_id: 0,
        trip_headsign: nil,
        route_pattern_id: nil,
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        inserted_at: now,
        updated_at: now
      }

    {1, nil} = Repo.insert_all(Trip, [trip])

    rows
    |> Enum.with_index(1)
    |> Enum.each(fn {row, index} ->
      {1, nil} =
        Repo.insert_all(StopTime, [
          row
          |> Map.put(:stop_sequence, index)
          |> Map.merge(%{
            id: Ecto.UUID.generate(),
            trip_id: trip_id,
            organization_id: context.organization.id,
            gtfs_version_id: context.version.id,
            inserted_at: now,
            updated_at: now
          })
        ])
    end)

    Repo.get_by!(Trip,
      trip_id: trip_id,
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id
    )
  end
end
