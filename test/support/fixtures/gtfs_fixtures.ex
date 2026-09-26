defmodule GtfsPlanner.GtfsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Gtfs` context.
  """

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  @doc """
  Generate valid level attributes for testing.
  """
  def valid_level_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      level_id: "L#{System.unique_integer()}",
      level_index: 0.0,
      level_name: "Test Level"
    })
  end

  @doc """
  Generate a level fixture.
  """
  def level_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    {:ok, level} =
      Gtfs.create_level(
        valid_level_attrs(attrs)
        |> Map.put(:organization_id, organization_id)
        |> Map.put(:gtfs_version_id, gtfs_version_id)
      )

    level
  end

  @doc """
  Generate valid stop attributes for testing.
  """
  def valid_stop_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      stop_id: "stop_#{System.unique_integer()}",
      stop_name: "Test Stop",
      stop_lat: Decimal.new("40.7128"),
      stop_lon: Decimal.new("-74.0060"),
      location_type: 0,
      wheelchair_boarding: 0
    })
  end

  @doc """
  Generate a stop fixture.
  """
  def stop_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    {:ok, stop} =
      Gtfs.create_stop(
        valid_stop_attrs(attrs)
        |> Map.put(:organization_id, organization_id)
        |> Map.put(:gtfs_version_id, gtfs_version_id)
      )

    stop
  end

  @doc """
  Generate valid pathway attributes for testing.
  """
  def valid_pathway_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      pathway_id: "pathway_#{System.unique_integer([:positive])}",
      pathway_mode: 1,
      is_bidirectional: true,
      traversal_time: 60
    })
  end

  @doc """
  Generate a pathway fixture.
  """
  def pathway_fixture(organization_id, gtfs_version_id, from_stop_id, to_stop_id, attrs \\ %{}) do
    {:ok, pathway} =
      attrs
      |> valid_pathway_attrs()
      |> Map.merge(%{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        from_stop_id: from_stop_id,
        to_stop_id: to_stop_id
      })
      |> Gtfs.create_pathway()

    pathway
  end

  @doc """
  Generate valid route attributes for testing.
  """
  def valid_route_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      route_id: "route_#{System.unique_integer([:positive])}",
      route_short_name: "#{System.unique_integer([:positive])}",
      route_long_name: "Test Route",
      route_type: 3,
      route_color: "0000FF",
      route_text_color: "FFFFFF",
      active: true
    })
  end

  @doc """
  Generate a route fixture.
  """
  def route_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    {:ok, route} =
      Gtfs.create_route(
        valid_route_attrs(attrs)
        |> Map.put(:organization_id, organization_id)
        |> Map.put(:gtfs_version_id, gtfs_version_id)
      )

    route
  end

  @doc """
  Generate valid agency attributes for testing.
  """
  def valid_agency_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      agency_id: "agency_#{System.unique_integer([:positive])}",
      agency_name: "Test Agency",
      agency_url: "http://example.com",
      agency_timezone: "America/Los_Angeles"
    })
  end

  @doc """
  Generate an agency fixture.
  """
  def agency_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    {:ok, agency} =
      Gtfs.create_agency(
        valid_agency_attrs(attrs)
        |> Map.put(:organization_id, organization_id)
        |> Map.put(:gtfs_version_id, gtfs_version_id)
      )

    agency
  end

  @doc """
  Generate valid trip attributes for testing.
  """
  def valid_trip_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      trip_id: "trip_#{System.unique_integer([:positive])}",
      service_id: "service_#{System.unique_integer([:positive])}",
      trip_headsign: "Downtown"
    })
  end

  @doc """
  Generate a trip fixture.
  """
  def trip_fixture(organization_id, gtfs_version_id, route_id, attrs \\ %{}) do
    {:ok, trip} =
      Gtfs.create_trip(
        valid_trip_attrs(attrs)
        |> Map.put(:organization_id, organization_id)
        |> Map.put(:gtfs_version_id, gtfs_version_id)
        |> Map.put(:route_id, route_id)
      )

    trip
  end

  @doc """
  Generate valid stop time attributes for testing.
  """
  def valid_stop_time_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      arrival_time: "08:00:00",
      departure_time: "08:00:00",
      stop_sequence: System.unique_integer([:positive])
    })
  end

  @doc """
  Generate a stop time fixture.
  """
  def stop_time_fixture(organization_id, gtfs_version_id, trip_id, stop_id, attrs \\ %{}) do
    {:ok, stop_time} =
      Gtfs.create_stop_time(
        valid_stop_time_attrs(attrs)
        |> Map.put(:organization_id, organization_id)
        |> Map.put(:gtfs_version_id, gtfs_version_id)
        |> Map.put(:trip_id, trip_id)
        |> Map.put(:stop_id, stop_id)
      )

    stop_time
  end

  @doc "Generate a route pattern fixture for occurrence and timing tests."
  def route_pattern_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          route_pattern_id: "pattern_#{System.unique_integer([:positive])}",
          route_id: "route_fixture",
          direction_id: 0,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        },
        attrs
      )

    %RoutePattern{}
    |> RoutePattern.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Generate one ordered stop occurrence for a route pattern."
  def route_pattern_stop_fixture(route_pattern, stop_id, position, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          route_pattern_id: route_pattern.id,
          route_pattern: route_pattern,
          organization_id: route_pattern.organization_id,
          gtfs_version_id: route_pattern.gtfs_version_id,
          stop_id: stop_id,
          position: position
        },
        attrs
      )

    %RoutePatternStop{}
    |> RoutePatternStop.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Generate a named timing for a route pattern."
  def timed_pattern_fixture(route_pattern, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          route_pattern_id: route_pattern.id,
          route_pattern: route_pattern,
          organization_id: route_pattern.organization_id,
          gtfs_version_id: route_pattern.gtfs_version_id,
          name: "Timing #{System.unique_integer([:positive])}"
        },
        attrs
      )

    %TimedPattern{}
    |> TimedPattern.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Generate a timing row attached to an occurrence."
  def timed_pattern_stop_fixture(timed_pattern, route_pattern_stop, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          timed_pattern_id: timed_pattern.id,
          route_pattern_stop_id: route_pattern_stop.id,
          arrival_offset: 0,
          departure_offset: 0,
          timed_pattern: timed_pattern,
          route_pattern_stop: route_pattern_stop
        },
        attrs
      )

    %TimedPatternStop{}
    |> TimedPatternStop.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Set application-owned pattern classification on a trip fixture."
  def trip_pattern_metadata_fixture(trip, attrs) do
    trip
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  @doc "Generate a calendar fixture."
  def calendar_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          service_id: "calendar_#{System.unique_integer([:positive])}",
          monday: 1,
          tuesday: 1,
          wednesday: 1,
          thursday: 1,
          friday: 1,
          saturday: 0,
          sunday: 0,
          start_date: ~D[2026-01-01],
          end_date: ~D[2026-12-31],
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        },
        Map.new(attrs)
      )

    %Calendar{}
    |> Calendar.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Generate a calendar date fixture."
  def calendar_date_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          service_id: "calendar_#{System.unique_integer([:positive])}",
          date: ~D[2026-07-04],
          exception_type: 1,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        },
        Map.new(attrs)
      )

    %CalendarDate{}
    |> CalendarDate.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Generate a calendar attribute fixture."
  def calendar_attribute_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          service_id: "calendar_#{System.unique_integer([:positive])}",
          service_description: "Standard Service",
          service_schedule_name: "Weekday",
          service_schedule_type: "Weekday",
          service_schedule_typicality: 1,
          rating_start_date: ~D[2026-01-01],
          rating_end_date: ~D[2026-12-31],
          rating_description: "Winter 2026",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        },
        Map.new(attrs)
      )

    %CalendarAttribute{}
    |> CalendarAttribute.changeset(attrs)
    |> Repo.insert!()
  end
end
