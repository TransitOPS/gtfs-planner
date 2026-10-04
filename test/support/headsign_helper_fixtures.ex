defmodule GtfsPlanner.HeadsignHelperFixtures do
  @moduledoc """
  The A01 headsign scenario the Headsign helper's tests share: one pattern whose
  default is `Downtown Terminal`, with every kind of trip a rename must tell apart.

  Pattern `A01-P1` on route `R1` has two timings. `Off-peak` has no headsign of its
  own, so its fifteen trips are the pattern scope. `Peak` carries `Peak Terminal`
  and shields its two trips from a pattern-scope rename. The Off-peak trips, by
  departure order:

    * twelve followers `A01-F01` to `A01-F12`, the last stored as
      ` Downtown Terminal ` with surrounding spaces,
    * two interlined trips `A01-I1` and `A01-I2` (`Downtown Terminal, continues to
      Airport`), each on a block that continues on route `R2`,
    * one case variant `A01-C1` (`downtown terminal`).

  The second Off-peak stop carries the stop-level headsign `Airport`, which no
  trip-headsign rename may touch. Expected values in tests are written by hand
  from this description, never read back from the code under test.
  """

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @doc """
  Inserts the A01 rows into `organization_id` and `gtfs_version_id`.

  Returns `%{route:, route2:, pattern:, off_peak:, peak:, trips:}`; `trips` maps each
  trip ID above to its stored `Trip`.
  """
  def a01_fixture(organization_id, gtfs_version_id) do
    route =
      route_fixture(organization_id, gtfs_version_id, %{route_id: "R1", route_short_name: "1"})

    route2 =
      route_fixture(organization_id, gtfs_version_id, %{route_id: "R2", route_short_name: "2"})

    stop_fixture(organization_id, gtfs_version_id, %{
      stop_id: "A01-S1",
      stop_name: "Union Station"
    })

    stop_fixture(organization_id, gtfs_version_id, %{
      stop_id: "A01-S2",
      stop_name: "Airport Plaza"
    })

    bundle =
      schedule_pattern_fixture(organization_id, gtfs_version_id, %{
        route_id: route.route_id,
        route_pattern_id: "A01-P1",
        route_pattern_name: "Downtown",
        headsign: "Downtown Terminal",
        timing_name: "Off-peak",
        stops: [{"A01-S1", 0, 0, 1}, {"A01-S2", 600, 600, 1}]
      })

    # The stop-level headsign lives on the Off-peak timing's second row.
    [_first, second] = bundle.rows
    Repo.update!(Ecto.Changeset.change(%TimedPatternStop{} = second, stop_headsign: "Airport"))

    peak =
      timed_pattern_fixture(bundle.pattern, %{name: "Peak", headsign: "Peak Terminal"})

    for {occurrence, row} <- Enum.zip(bundle.occurrences, bundle.rows) do
      timed_pattern_stop_fixture(peak, occurrence, %{
        arrival_offset: row.arrival_offset,
        departure_offset: row.departure_offset,
        timepoint: row.timepoint
      })
    end

    followers =
      for index <- 1..12 do
        id = "A01-F" <> String.pad_leading(Integer.to_string(index), 2, "0")
        {id, "Downtown Terminal", clock(6, (index - 1) * 5), nil}
      end

    differing = [
      {"A01-I1", "Downtown Terminal, continues to Airport", "18:00:00", "A01-B1"},
      {"A01-I2", "Downtown Terminal, continues to Airport", "18:30:00", "A01-B2"},
      {"A01-C1", "downtown terminal", "19:00:00", nil}
    ]

    off_peak_trips =
      for {trip_id, headsign, start_time, block_id} <- followers ++ differing, into: %{} do
        %{trip: trip} =
          schedule_trip_fixture(organization_id, gtfs_version_id, route.route_id, bundle, %{
            service_id: "A01-WK",
            trip_id: trip_id,
            trip_headsign: headsign,
            block_id: block_id,
            start_time: start_time
          })

        {trip_id, trip}
      end

    # An import stores headsigns untrimmed through `insert_all`; the Trip changeset
    # would trim this one, so the padded value is written the way an import writes it.
    padded = Map.fetch!(off_peak_trips, "A01-F12")

    Repo.update_all(from(trip in Trip, where: trip.id == ^padded.id),
      set: [trip_headsign: " Downtown Terminal "]
    )

    peak_trips =
      for {trip_id, start_time} <- [{"A01-P1", "07:00:00"}, {"A01-P2", "07:30:00"}], into: %{} do
        %{trip: trip} =
          schedule_trip_fixture(organization_id, gtfs_version_id, route.route_id, bundle, %{
            service_id: "A01-WK",
            trip_id: trip_id,
            trip_headsign: "Peak Terminal",
            start_time: start_time,
            timed_pattern_id: peak.id
          })

        {trip_id, trip}
      end

    # Each interlined trip ends ten minutes after it starts; its block continues on
    # route R2 ten minutes after that.
    for {trip_id, block_id, departure} <- [
          {"A01-R2-1", "A01-B1", "18:20:00"},
          {"A01-R2-2", "A01-B2", "18:50:00"}
        ] do
      trip_fixture(organization_id, gtfs_version_id, route2.route_id, %{
        trip_id: trip_id,
        service_id: "A01-WK",
        block_id: block_id,
        trip_headsign: "Airport"
      })

      stop_time_fixture(organization_id, gtfs_version_id, trip_id, "A01-S1", %{
        stop_sequence: 1,
        arrival_time: departure,
        departure_time: departure
      })
    end

    %{
      route: route,
      route2: route2,
      pattern: bundle.pattern,
      off_peak: bundle.timing,
      peak: peak,
      trips: Map.merge(off_peak_trips, peak_trips)
    }
  end

  @doc """
  A `headsigns` helper scope for `user`, admitted through the real
  `Scope.with_source_snapshot/2` exactly as the Pattern page admits it: the route
  identity, the pattern and, for a Running-times task, the timing.
  """
  def helper_scope(organization, version, user, route, pattern, timing \\ nil) do
    {:ok, context} =
      Scope.with_source_snapshot(Scope.context({:route, route.id}), %{
        kind: "headsign_scope",
        payload: %{
          "schema_version" => 1,
          "pattern_id" => pattern.id,
          "timing_id" => timing && timing.id
        }
      })

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "headsigns",
      version_name: version.name,
      resource_context: context
    }
  end

  defp clock(hour, minute) do
    :io_lib.format("~2..0B:~2..0B:00", [hour, minute]) |> IO.iodata_to_binary()
  end
end
