defmodule GtfsPlanner.TodsGeneratorFixtures do
  @moduledoc """
  Fixtures for the TODS generator's block-candidate tests.

  They compose `RunsFixtures.runs_version_fixture/1` — a published version with
  one weekday calendar, a garage, four stops on one meridian, block 101 of four
  trips and block 102 of two, and its relief and default-garage rules written
  through the writers that own them — rather than re-deriving any of that. What
  is added here is only what a *generation* candidate needs on top of it:

    * a second calendar, `MO`, active on Mondays alone, so the version derives two
      day types — Monday as `{MO, WK}` and Tuesday through Friday as `{WK}` — and a
      weekday trip is in both. That overlap is what makes "one trip UUID, one block
      ID" observable rather than vacuous.
    * `:extra_trips`, for a case that needs a chain of its own rather than the
      one this module builds. Each is `{trip_id, service_id, first_stop,
      last_stop, first, last}` and goes through the same
      `blocked_trip_fixture/4` the existing blocks use, so it is the same trip
      shape the generator reads.

      Extra trips run on their own route, which requires its own vehicle type. The
      generator partitions trips by garage and required type before it chains any
      of them, so an extra trip can never join one of the fixture's existing blocks
      and always opens a new one — which is what makes "the generator created this
      block" an observable fact rather than an accident of times. `extra_route:
      :schedule` puts them on the version's own route instead, where the generator
      chains them onto the existing blocks.
    * a foreign organization with its own version, garage and trip, a
      garage-less organization, and a staging version beside the published one,
      so a case can ask for a scope it must not be served.

  The blocks are written through `blocked_trip_fixture/4` and their garages
  resolve through `Blocking.Context.resolve_block/3` like a real block's, so a
  candidate that overlays the selected garage is observable rather than assumed.
  """

  import GtfsPlanner.AccountsFixtures, only: [editor_audit_fixture: 2]
  import GtfsPlanner.AdvancedBlockingFixtures, only: [route_operating_setting_fixture: 3]
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures, only: [route_fixture: 3, stop_fixture: 3]
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @weekday_service "WK"
  @monday_service "MO"
  @saturday_service "SA"

  @doc """
  Builds the published version the block-candidate cases share.

  `:extra_trips` adds unblocked trips as
  `{trip_id, service_id, first_stop, last_stop, first, last}` tuples, on a route
  of their own unless `extra_route: :schedule` asks for the version's.

  The returned `:weekday_day_type` and `:monday_day_type` are read from
  `Blocking.DayTypes.derive/1` rather than assumed, so a fixture can never name
  a day type the load would refuse. `:trip_ids` maps the fixture's own `trip_id`
  strings to their UUIDs, which is the identity a candidate's assignments are
  keyed by.
  """
  def tods_world_fixture(opts \\ []) do
    opts = Map.new(opts)

    world = runs_version_fixture()
    %{organization: organization, version: version} = world

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @monday_service,
      name: "Monday",
      monday: 1,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0
    })

    extra_route = extra_route(world, Map.get(opts, :extra_route, :generator))

    extra =
      Enum.map(
        Map.get(opts, :extra_trips, []),
        &extra_trip(organization, version, extra_route, &1)
      )

    world
    |> Map.merge(%{
      extra_route: extra_route,
      weekday_day_type: day_type_key_for(organization, version, [@weekday_service]),
      monday_day_type:
        day_type_key_for(organization, version, [@monday_service, @weekday_service]),
      extra_trips: extra
    })
    |> Map.put(:trip_ids, trip_ids(world, extra))
  end

  # A route of its own requiring a vehicle type of its own, so an extra trip is in
  # a partition no existing block is in and the generator must open a new block for
  # it. The garage still resolves through the version default, which is what makes
  # the selected garage's overlay observable on the new block.
  defp extra_route(%{organization: organization, version: version}, :generator) do
    route = route_fixture(organization.id, version.id, %{route_id: "GEN"})
    vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Generator Type"})

    route_operating_setting_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      required_vehicle_type_id: vehicle_type.id
    })

    Map.put(route, :vehicle_type_id, vehicle_type.id)
  end

  # The version's own route, so an extra trip resolves to the same garage and type
  # an existing block does and the generator chains it onto one of them.
  defp extra_route(%{route: route}, :schedule), do: route

  defp extra_trip(
         organization,
         version,
         route,
         {trip_id, service_id, first_stop, last_stop, first, last}
       ) do
    {first_arrival, first_departure} =
      case first do
        {arrival, departure} -> {arrival, departure}
        departure -> {departure, departure}
      end

    trip =
      blocked_trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: trip_id,
        service_id: service_id,
        block_id: nil,
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: first_arrival,
        first_departure: first_departure,
        last_arrival: last,
        last_departure: last
      })

    %{trip_id: trip_id, uuid: trip.id}
  end

  # Every trip the world owns, by its GTFS `trip_id`, so a case can assert on an
  # assignment without reading a stop time back to find the UUID.
  defp trip_ids(world, extra) do
    existing =
      for {_block_id, trips} <- world.blocks, trip <- trips, into: %{} do
        {trip.trip_id, trip.id}
      end

    Map.merge(existing, Map.new(extra, &{&1.trip_id, &1.uuid}))
  end

  @doc """
  Adds block "201" to `world`: two well-formed weekday trips on the world's own
  extra route, so a case has an existing block the generator extends and the
  checks read as valid on every day it runs.

  The fixture's 101 and 102 pass a first departure that precedes their default
  first arrival of 08:00, so `Checks.sequence/1` reads them as overlapping. They
  are the blocks a preservation case needs and not the block a case about validity
  can build on, so the block written here carries both clocks and can be.

  Returns the trips it wrote.
  """
  def generator_block_fixture(world) do
    write_block_trips(world, @weekday_service, [
      {"201-1", "14:00:00", "14:30:00"},
      {"201-2", "14:40:00", "15:10:00"}
    ])
  end

  @doc """
  Adds a Saturday conflict to block "201": a calendar service active on Saturdays
  alone and two of the block's trips on it whose spans overlap, so block "201" is
  invalid on the Saturday day type and valid on every weekday.

  The conflict is deliberately outside a Monday-to-Friday range, so the day type it
  invalidates the block on is one the range does not select. A candidate that only
  re-read the days it composed on would call a new move onto block "201" legal, and
  storing it would put a trip in a block that overlaps another trip of its own on
  one of its dates.

  Returns the Saturday trips it wrote.
  """
  def out_of_range_block_conflict_fixture(world) do
    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: @saturday_service,
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0
    })

    write_block_trips(world, @saturday_service, [
      {"201-sa-1", "14:00:00", "15:00:00"},
      {"201-sa-2", "14:30:00", "15:30:00"}
    ])
  end

  defp write_block_trips(world, service_id, trips) do
    Enum.map(trips, fn {trip_id, first_departure, last_arrival} ->
      blocked_trip_fixture(world.organization.id, world.version.id, world.extra_route.route_id, %{
        trip_id: trip_id,
        service_id: service_id,
        block_id: "201",
        first_stop: world.relief_stop_id,
        last_stop: world.relief_stop_id,
        first_arrival: first_departure,
        first_departure: first_departure,
        last_arrival: last_arrival
      })
    end)
  end

  @doc """
  The five normalized inputs for `world`'s first two calendar weeks.

  Two weeks rather than one, because the fixture's Monday-only service makes a
  one-week range select the weekday day type alone: the case about a trip being
  in two day types needs a range holding a date of each.

  `:garage_id` defaults to the world's garage and can be overridden, which is how
  a case asks for a garage of another organization or of none.
  """
  def tods_inputs(world, overrides \\ %{}) do
    monday = first_active_week(world)

    %{
      "start_date" => Date.to_iso8601(monday),
      "end_date" => Date.to_iso8601(Date.add(monday, 13)),
      "representative_week" => Date.to_iso8601(monday),
      "garage_id" => world.garage.id,
      "terminal_relief?" => false
    }
    |> Map.merge(Map.new(overrides))
  end

  @doc """
  The Monday of the week holding the version's first active date.
  """
  def first_active_week(world) do
    world.organization.id
    |> active_dates(world.version.id)
    |> Enum.min(Date)
    |> Date.beginning_of_week(:monday)
  end

  @doc """
  Every date the version has scheduled service, sorted.
  """
  def active_dates(organization_id, version_id) do
    {:ok, calendars} = Gtfs.list_calendars(organization_id, version_id)

    calendars
    |> Enum.flat_map(& &1.active_dates)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Runs `Gtfs.preview_tods_generation/2` on `world` with `tods_inputs/2`, the call
  a page's read path makes: the facade delegate and the generator behind it, with
  no argument a test builds by hand. Returns the raw `{:ok, _} | {:error, _}` so a
  case can assert on a refusal shape rather than on a raise.
  """
  def preview(world, overrides \\ %{}) do
    Gtfs.preview_tods_generation(world.audit, tods_inputs(world, overrides))
  end

  @doc """
  The version's derived day types, in `Blocking.DayTypes.derive/1` order.
  """
  def day_types(world) do
    {:ok, calendars} = Gtfs.list_calendars(world.organization.id, world.version.id)
    Blocking.DayTypes.derive(calendars)
  end

  @doc """
  Builds a second organization with one published version, a garage, two stops
  and a weekday trip, so a case can name a garage or a version that is not its
  own.
  """
  def foreign_scope_fixture do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    audit = editor_audit_fixture(organization, version)
    route = route_fixture(organization.id, version.id, %{route_id: "R1"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @weekday_service,
      name: "Weekday"
    })

    garage = garage_fixture(organization.id)
    {first_stop, last_stop} = two_stops(organization, version)

    trip =
      blocked_trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: "foreign-a",
        service_id: @weekday_service,
        block_id: nil,
        first_stop: first_stop,
        last_stop: last_stop,
        first_departure: "08:00:00",
        last_arrival: "08:30:00"
      })

    %{
      organization: organization,
      version: version,
      audit: audit,
      garage: garage,
      trip: trip
    }
  end

  @doc """
  Builds an organization of its own with a published version, a calendar and a
  trip but no garage, so a case can ask for a generation where there is nowhere
  to run from.
  """
  def garage_less_scope_fixture do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    audit = editor_audit_fixture(organization, version)
    route = route_fixture(organization.id, version.id, %{route_id: "R1"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: @weekday_service,
      name: "Weekday"
    })

    {first_stop, last_stop} = two_stops(organization, version)

    blocked_trip_fixture(organization.id, version.id, route.route_id, %{
      trip_id: "garageless-a",
      service_id: @weekday_service,
      block_id: nil,
      first_stop: first_stop,
      last_stop: last_stop,
      first_departure: "08:00:00",
      last_arrival: "08:30:00"
    })

    %{organization: organization, version: version, audit: audit}
  end

  @doc """
  Builds a staging version beside `world`'s published one: the same organization
  and a calendar, and no usable status, so a case can ask for the version a page
  must refuse before it composes anything.
  """
  def staging_version_fixture(world) do
    version = staging_version(world.organization.id, %{name: "Staging"})

    calendar_service_fixture(world.organization.id, version.id, %{
      service_id: @weekday_service,
      name: "Weekday"
    })

    %{version: version, audit: editor_audit_fixture(world.organization, version)}
  end

  @doc """
  Counts the rows a preview must not change, in the tables a generation preview
  could reach. Taken inside the caller's transaction, so a case can compare the
  counts before and after and assert the preview wrote nothing.
  """
  def planning_row_counts(world) do
    organization_id = world.organization.id
    version_id = world.version.id

    scoped = fn schema ->
      Repo.aggregate(
        from(row in schema,
          where: row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id
        ),
        :count
      )
    end

    %{
      trips: scoped.(Trip),
      block_attributes: scoped.(BlockAttribute),
      roster_lines: scoped.(RosterLine),
      roster_line_days: scoped.(RosterLineDay),
      trip_runs: scoped.(TripRun),
      operators:
        Repo.aggregate(
          from(o in Operator, where: o.organization_id == ^organization_id),
          :count
        )
    }
  end

  defp two_stops(organization, version) do
    first = stop_fixture(organization.id, version.id, %{stop_id: "GONE_A"}).stop_id
    second = stop_fixture(organization.id, version.id, %{stop_id: "GONE_B"}).stop_id

    {first, second}
  end

  defp staging_version(organization_id, attrs) do
    {:ok, version} = Versions.create_staging_gtfs_version(organization_id, attrs)
    version
  end

  defp day_type_key_for(organization, version, service_ids) do
    service_ids = Enum.sort(service_ids)

    organization.id
    |> day_types_for(version.id)
    |> Enum.find(&(&1.service_ids == service_ids))
    |> Map.fetch!(:key)
  end

  defp day_types_for(organization_id, version_id) do
    {:ok, calendars} = Gtfs.list_calendars(organization_id, version_id)
    Blocking.DayTypes.derive(calendars)
  end
end
