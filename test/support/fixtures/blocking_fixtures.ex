defmodule GtfsPlanner.BlockingFixtures do
  @moduledoc """
  Calendar-service, blocked-trip and frequency fixtures for the Blocks day load.

  They live in their own module, separate from `GtfsPlanner.GtfsFixtures` which
  package 10 also edits (CR-12), and every function takes the organization and the
  GTFS version it writes into, so a test can build a foreign organization, another
  version or a second day type beside its own.
  """

  import GtfsPlanner.GtfsFixtures

  @weekly_keys [
    :monday,
    :tuesday,
    :wednesday,
    :thursday,
    :friday,
    :saturday,
    :sunday,
    :start_date,
    :end_date
  ]

  @doc """
  Creates an active service with a name and returns `%{service_id:, name:}`.

  Attributes:

    * `:service_id` — defaults to a unique ID
    * `:name` — the calendar's service description, which day-type labels print
    * `:dates` — makes a dates-only service (calendar_dates additions only) from
      the given `Date`s
    * otherwise the weekly attributes (`:monday` to `:sunday`, `:start_date`,
      `:end_date`) create a weekly calendar over `GtfsFixtures`' 2026 defaults
  """
  def calendar_service_fixture(organization_id, gtfs_version_id, attrs) do
    attrs = Map.new(attrs)
    service_id = Map.get(attrs, :service_id, "service_#{System.unique_integer([:positive])}")
    name = Map.get(attrs, :name, "Service #{service_id}")

    case Map.get(attrs, :dates) do
      nil ->
        attrs
        |> Map.take(@weekly_keys)
        |> Map.put(:service_id, service_id)
        |> then(&calendar_fixture(organization_id, gtfs_version_id, &1))

      dates ->
        Enum.each(dates, fn date ->
          calendar_date_fixture(organization_id, gtfs_version_id, %{
            service_id: service_id,
            date: date,
            exception_type: 1
          })
        end)
    end

    calendar_attribute_fixture(organization_id, gtfs_version_id, %{
      service_id: service_id,
      service_description: name
    })

    %{service_id: service_id, name: name}
  end

  @doc """
  Creates a trip with a first and a last stop time and returns the trip.

  `:first_stop` and `:last_stop` name the stored stops; when either is omitted the
  trip gets its own stop, so a caller that only cares about times passes clocks and
  nothing else. `:first_arrival` and `:first_departure` fill stop sequence 1,
  `:last_arrival` and `:last_departure` stop sequence 2, and a departure defaults
  to its arrival. Any of the four may be `nil`, which stores an empty time and
  leaves the trip unplottable.
  """
  def blocked_trip_fixture(organization_id, gtfs_version_id, route_id, attrs) do
    attrs = Map.new(attrs)

    first_arrival = Map.get(attrs, :first_arrival, "08:00:00")
    first_departure = Map.get(attrs, :first_departure, first_arrival)
    last_arrival = Map.get(attrs, :last_arrival, "09:00:00")
    last_departure = Map.get(attrs, :last_departure, last_arrival)

    trip =
      trip_fixture(
        organization_id,
        gtfs_version_id,
        route_id,
        Map.take(attrs, [:trip_id, :service_id, :block_id, :trip_headsign, :route_pattern_id])
      )

    stop_time_fixture(
      organization_id,
      gtfs_version_id,
      trip.trip_id,
      endpoint_stop_id(organization_id, gtfs_version_id, attrs, :first_stop),
      %{stop_sequence: 1, arrival_time: first_arrival, departure_time: first_departure}
    )

    stop_time_fixture(
      organization_id,
      gtfs_version_id,
      trip.trip_id,
      endpoint_stop_id(organization_id, gtfs_version_id, attrs, :last_stop),
      %{stop_sequence: 2, arrival_time: last_arrival, departure_time: last_departure}
    )

    trip
  end

  @doc """
  Creates a frequencies row for one trip and returns it.

  `:trip_id` is required; `:start_time`, `:end_time`, `:headway_secs` and
  `:exact_times` default as in `GtfsFixtures.frequency_fixture/4`, and a different
  `:start_time` adds a second window to the same trip.
  """
  def frequency_row_fixture(organization_id, gtfs_version_id, attrs) do
    attrs = Map.new(attrs)

    frequency_fixture(
      organization_id,
      gtfs_version_id,
      Map.fetch!(attrs, :trip_id),
      Map.drop(attrs, [:trip_id])
    )
  end

  defp endpoint_stop_id(organization_id, gtfs_version_id, attrs, key) do
    case Map.get(attrs, key) do
      nil -> stop_fixture(organization_id, gtfs_version_id).stop_id
      stop_id -> stop_id
    end
  end
end
