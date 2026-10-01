defmodule GtfsPlanner.RunsFixtures do
  @moduledoc """
  Runs fixtures for the database, LiveView and export tests of the Runs page.

  They live in their own module, separate from the blocking fixture modules they
  reuse rather than edit, and every function takes the organization and the GTFS
  version it writes into, so a test can build a foreign organization, a second day
  type or a staging version beside its own.

  `runs_version_fixture/1` is the shared planning day the tests cut into runs: a
  published version with one weekday calendar, a garage, four stops on one
  meridian, block 101 of four trips and block 102 of two. Its relief point is
  marked through `Blocking.update_relief_settings/3` and its default garage and
  piece limit through `Blocking`'s own writers, so the fixture takes the same path
  the page takes and a test never has to set a planning input behind the lock that
  owns it.

  ## The day

  Stops sit on one meridian so every distance is a real drive rather than a
  rounding artefact: `RIV` is Riverside Station with two bays that inherit its
  point, and `VC` and `MS` are a tenth and a third of a degree north.

      RIV (40.00)  BAY_A, BAY_B          — the marked station
      VC  (40.01)                          Valley College
      MS  (40.03)                          Market Square

  Block 101 runs `a` and `b` inside the station, so the gap between them is a
  layover at a marked relief point — the case a handover can be planned into —
  and then leaves for `VC` and `MS`, so its last two gaps are real drives.
  Block 102 is two trips back inside the station, which gives a second layover to
  mark and a block of its own to cut.

      101  a  BAY_A → BAY_A  05:50–06:50     layover to b
           b  BAY_B → BAY_B  07:00–08:00
           c  VC    → VC     09:00–09:30     drive from b
           d  MS    → MS     10:00–10:30     drive from c
      102  e  BAY_A → BAY_A  12:00–12:30     layover to f
           f  BAY_B → BAY_B  12:40–13:10
  """

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.AccountsFixtures, only: [editor_audit_fixture: 2]
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.AdvancedBlockingFixtures
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.TripRun

  @riverside {40.0, -74.0}
  @valley_college {40.01, -74.0}
  @market_square {40.03, -74.0}

  # The station the relief mark belongs to. A bay inherits its parent's point, so
  # `Checks.handoff/2` reads the layover between two bays as being at one place.
  @relief_stop_id "RIV"

  @bay_a "BAY_A"
  @bay_b "BAY_B"
  @valley_college_stop "VC"
  @market_square_stop "MS"

  # The long drives of the two blocks and the piece limit Block rules own. Every
  # fixture block here is an hour or less, so 330 leaves the limit doing its real
  # job of refusing a piece that runs long without cutting a normal day short.
  @max_piece_minutes 330

  @doc """
  Assigns one trip to one run on one day type and returns the stored row.

  `:trip`, `:day_type_key` and `:run_id` are required. The organization, version
  and day type are set on the struct and never cast, exactly as
  `GtfsPlanner.Gtfs.TripRun.changeset/2` expects, so a fixture cannot build a row
  whose scope came from its own attributes.
  """
  def trip_run_fixture(organization_id, gtfs_version_id, attrs) do
    attrs = Map.new(attrs)

    %TripRun{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      trip_id: trip_id(Map.fetch!(attrs, :trip)),
      day_type_key: Map.fetch!(attrs, :day_type_key)
    }
    |> TripRun.changeset(%{run_id: Map.fetch!(attrs, :run_id)})
    |> GtfsPlanner.Repo.insert!()
  end

  @doc """
  Builds the published two-block runs version and returns its parts.

  Returns `%{organization:, version:, route:, day_type_key:, garage:,
  blocks:, relief_stop_id:}`:

    * `day_type_key` — the version's own weekday key, read back through
      `Blocking.load_day/3` rather than assumed, so a fixture cannot name a day
      type the day load would refuse.
    * `blocks` — `"101"` and `"102"` mapped to their trips in service order, the
      shape the piece, cut and plan tests cut from.
    * `relief_stop_id` — the marked station's own stop ID, which is also the
      candidate ID `list_relief_candidates/3` returns for it.
    * `garage` — the version's default garage, already stored as such.

  Every stop sits on one meridian, so the drives between blocks and out of the
  garage have real distances to estimate. `:max_piece_minutes` may be overridden
  by a test that is about the limit itself; everything else is fixed, because a
  shared fixture whose shape drifts silently invalidates the step that reads it.
  """
  def runs_version_fixture(opts \\ []) do
    opts = Map.new(opts)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    audit = editor_audit_fixture(organization, version)
    route = route_fixture(organization.id, version.id, %{route_id: "R1"})

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    # The garage carries its own point, so a run's travel in and out is a real
    # estimate rather than an unknown leg.
    garage = garage_fixture(organization.id)

    stops = stops(organization, version)

    blocks = %{
      "101" => block_101(organization, version, route, stops),
      "102" => block_102(organization, version, route, stops)
    }

    # The default garage and the piece limit are planning inputs, so they are
    # written through the writers that take the version and blocking locks rather
    # than by inserting a settings row behind their back.
    {:ok, _settings} =
      Blocking.update_settings(audit, %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: "any",
        default_garage_id: garage.id,
        deadhead_speed_kmh: 30,
        deadhead_circuity: 1.3,
        max_piece_minutes: nil
      })

    # The relief mark goes through the drawer the page saves, and a station
    # candidate is named by its own `parent_station` — the key `list_relief_candidates/3`
    # returns for a station rather than one of its bays.
    {:ok, :ok} =
      Blocking.update_relief_settings(audit, nil, %{
        max_piece_minutes: Map.get(opts, :max_piece_minutes, @max_piece_minutes),
        marked: [@relief_stop_id]
      })

    %{
      organization: organization,
      version: version,
      audit: audit,
      route: route,
      day_type_key: day_type_key!(organization, version),
      garage: garage,
      blocks: blocks,
      relief_stop_id: @relief_stop_id
    }
  end

  # The station is a row of its own so a candidate can name it, and the two bays
  # carry no coordinates of their own: they inherit the station's, exactly as a
  # real feed's child stops do.
  defp stops(organization, version) do
    stop_with_coordinates(organization, version, %{
      stop_id: @relief_stop_id,
      stop_name: "Riverside Station",
      stop_lat: Decimal.new("#{@riverside |> elem(0)}"),
      stop_lon: Decimal.new("#{@riverside |> elem(1)}")
    })

    for {stop_id, name, parent, {lat, lon}} <- [
          {@bay_a, "Bay A", @relief_stop_id, @riverside},
          {@bay_b, "Bay B", @relief_stop_id, @riverside},
          {@valley_college_stop, "Valley College", nil, @valley_college},
          {@market_square_stop, "Market Square", nil, @market_square}
        ] do
      stop_with_coordinates(organization, version, %{
        stop_id: stop_id,
        stop_name: name,
        parent_station: parent,
        stop_lat: Decimal.new("#{lat}"),
        stop_lon: Decimal.new("#{lon}")
      })
    end

    %{
      bay_a: @bay_a,
      bay_b: @bay_b,
      valley_college: @valley_college_stop,
      market_square: @market_square_stop
    }
  end

  # Two trips inside the marked station and then two away from it, so the block
  # carries a layover a handover can be planned into and two drives that have to
  # be estimated. Every gap is long enough for the drive it carries.
  defp block_101(organization, version, route, stops) do
    [
      trip(
        organization,
        version,
        route,
        {"a", "101", stops.bay_a, stops.bay_a, "05:50:00", "06:50:00"}
      ),
      trip(
        organization,
        version,
        route,
        {"b", "101", stops.bay_b, stops.bay_b, "07:00:00", "08:00:00"}
      ),
      trip(
        organization,
        version,
        route,
        {"c", "101", stops.valley_college, stops.valley_college, "09:00:00", "09:30:00"}
      ),
      trip(
        organization,
        version,
        route,
        {"d", "101", stops.market_square, stops.market_square, "10:00:00", "10:30:00"}
      )
    ]
  end

  defp block_102(organization, version, route, stops) do
    [
      trip(
        organization,
        version,
        route,
        {"e", "102", stops.bay_a, stops.bay_a, "12:00:00", "12:30:00"}
      ),
      trip(
        organization,
        version,
        route,
        {"f", "102", stops.bay_b, stops.bay_b, "12:40:00", "13:10:00"}
      )
    ]
  end

  # One plottable, non-frequency trip with a first and a last stop time, built by
  # `BlockingFixtures` so it is the same trip shape the blocking tests derive their
  # days from, and so `Checks.sequence/1` accepts it as a run's sequence trip.
  defp trip(organization, version, route, {trip_id, block_id, first_stop, last_stop, first, last}) do
    blocked_trip_fixture(organization.id, version.id, route.route_id, %{
      trip_id: trip_id,
      service_id: "WK",
      block_id: block_id,
      first_stop: first_stop,
      last_stop: last_stop,
      first_departure: first,
      last_arrival: last
    })
  end

  # The version's own weekday key, read from the day load rather than assumed, so
  # a fixture can never name a day type the load would refuse.
  defp day_type_key!(organization, version) do
    {:ok, day} = Blocking.load_day(organization.id, version.id, nil)
    day.day_type.key
  end

  defp stop_with_coordinates(organization, version, attrs) do
    AdvancedBlockingFixtures.stop_with_coordinates_fixture(organization.id, version.id, attrs)
  end

  # A caller may name the trip by its UUID or by the trip struct it already holds.
  defp trip_id(%{id: id}), do: id
  defp trip_id(id) when is_binary(id), do: id
end
