defmodule GtfsPlanner.Validations.PathwaysPreflightTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.{Calendar, CalendarDate}
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.PathwaysPreflight

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "run/3" do
    test "returns ok with stable structured payload" do
      organization_id = Ecto.UUID.generate()
      gtfs_version_id = Ecto.UUID.generate()
      test_window_context = %{start_time: "08:00:00", end_time: "09:00:00"}

      assert {:ok, result} =
               PathwaysPreflight.run(
                 organization_id,
                 gtfs_version_id,
                 test_window_context: test_window_context
               )

      assert result.blocking_errors == []
      assert result.warnings == []

      assert result.metadata.organization_id == organization_id
      assert result.metadata.gtfs_version_id == gtfs_version_id
      assert result.metadata.test_window_context == test_window_context

      assert result.metadata.record_counts == %{
               stops: 0,
               pathways: 0,
               stop_times: 0,
               trips: 0,
               routes: 0,
               calendars: 0,
               calendar_dates: 0
             }
    end

    test "normalizes non-map test window context to empty map" do
      organization_id = Ecto.UUID.generate()
      gtfs_version_id = Ecto.UUID.generate()

      assert {:ok, result} =
               PathwaysPreflight.run(
                 organization_id,
                 gtfs_version_id,
                 test_window_context: "invalid"
               )

      assert result.metadata.test_window_context == %{}
    end

    test "returns blocking error when station latitude is out of range" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      insert_stop_row!(organization.id, gtfs_version.id, %{
        stop_id: "station_bad_lat",
        location_type: 1,
        stop_lat: Decimal.new("91.0"),
        stop_lon: Decimal.new("-74.0")
      })

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :station_stop_lat_out_of_range, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.message =~ "station_bad_lat"
      assert issue.context.file == "stops.txt"
      assert issue.context.field == "stop_lat"
      assert issue.context.stop_id == "station_bad_lat"
    end

    test "ignores non-station coordinate range failures for step-4 station scope" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      insert_stop_row!(organization.id, gtfs_version.id, %{
        stop_id: "platform_out_of_range",
        location_type: 0,
        stop_lat: Decimal.new("95.0"),
        stop_lon: Decimal.new("-190.0")
      })

      assert {:ok, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)
      assert result.blocking_errors == []
    end

    test "returns blocking error when station longitude sign mismatches configured region" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      insert_stop_row!(organization.id, gtfs_version.id, %{
        stop_id: "station_bad_sign",
        location_type: 1,
        stop_lat: Decimal.new("41.8810"),
        stop_lon: Decimal.new("87.6270")
      })

      assert {:error, result} =
               PathwaysPreflight.run(
                 organization.id,
                 gtfs_version.id,
                 expected_longitude_sign: :negative
               )

      assert [%{code: :station_stop_lon_sign_mismatch, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.field == "stop_lon"
      assert issue.context.expected_sign == "negative"
      assert issue.context.stop_id == "station_bad_sign"
    end

    test "skips longitude sign check when expected sign is not configured" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      insert_stop_row!(organization.id, gtfs_version.id, %{
        stop_id: "station_no_sign_config",
        location_type: 1,
        stop_lat: Decimal.new("41.8810"),
        stop_lon: Decimal.new("87.6270")
      })

      assert {:ok, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)
      assert result.blocking_errors == []
    end

    test "returns blocking error when boarding area is missing parent_station" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      insert_stop_row!(organization.id, gtfs_version.id, %{
        stop_id: "boarding_missing_parent",
        location_type: 4,
        parent_station: nil,
        stop_lat: Decimal.new("41.8810"),
        stop_lon: Decimal.new("-87.6270")
      })

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :boarding_area_parent_station_missing, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.field == "parent_station"
      assert issue.context.stop_id == "boarding_missing_parent"
    end

    test "returns blocking error when boarding area parent_station is unknown" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      insert_stop_row!(organization.id, gtfs_version.id, %{
        stop_id: "boarding_unknown_parent",
        location_type: 4,
        parent_station: "missing_station",
        stop_lat: Decimal.new("41.8810"),
        stop_lon: Decimal.new("-87.6270")
      })

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :boarding_area_parent_station_not_found, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.field == "parent_station"
      assert issue.context.stop_id == "boarding_unknown_parent"
      assert issue.context.value == "missing_station"
    end

    test "passes boarding area parent_station integrity when parent exists in scoped stops" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      insert_stop_row!(organization.id, gtfs_version.id, %{
        stop_id: "platform_parent",
        location_type: 0,
        parent_station: nil,
        stop_lat: Decimal.new("41.8810"),
        stop_lon: Decimal.new("-87.6270")
      })

      insert_stop_row!(organization.id, gtfs_version.id, %{
        stop_id: "boarding_with_parent",
        location_type: 4,
        parent_station: "platform_parent",
        stop_lat: Decimal.new("41.8810"),
        stop_lon: Decimal.new("-87.6270")
      })

      assert {:ok, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)
      assert result.blocking_errors == []
    end

    test "returns blocking error when stop_times row references unknown trip" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      stop = stop_fixture(organization.id, gtfs_version.id)

      _stop_time =
        stop_time_fixture(organization.id, gtfs_version.id, "missing_trip", stop.stop_id)

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :stop_time_trip_not_found, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.file == "stop_times.txt"
      assert issue.context.field == "trip_id"
      assert issue.context.trip_id == "missing_trip"
      assert issue.context.stop_id == stop.stop_id
    end

    test "returns blocking error when stop_times row references unknown stop" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      route = route_fixture(organization.id, gtfs_version.id)
      trip = trip_fixture(organization.id, gtfs_version.id, route.route_id)
      create_calendar!(organization.id, gtfs_version.id, trip.service_id)

      _stop_time =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, "missing_stop")

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :stop_time_stop_not_found, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.file == "stop_times.txt"
      assert issue.context.field == "stop_id"
      assert issue.context.trip_id == trip.trip_id
      assert issue.context.stop_id == "missing_stop"
    end

    test "returns blocking error when trip references unknown route" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      _trip =
        trip_fixture(organization.id, gtfs_version.id, "missing_route", %{
          trip_id: "trip_missing_route",
          service_id: "service_known"
        })

      create_calendar!(organization.id, gtfs_version.id, "service_known")

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :trip_route_not_found, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.file == "trips.txt"
      assert issue.context.field == "route_id"
      assert issue.context.trip_id == "trip_missing_route"
      assert issue.context.route_id == "missing_route"
    end

    test "returns blocking error when trip references unknown service" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      route = route_fixture(organization.id, gtfs_version.id)

      _trip =
        trip_fixture(organization.id, gtfs_version.id, route.route_id, %{
          trip_id: "trip_missing_service",
          service_id: "missing_service"
        })

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :trip_service_not_found, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.file == "trips.txt"
      assert issue.context.field == "service_id"
      assert issue.context.trip_id == "trip_missing_service"
      assert issue.context.service_id == "missing_service"
    end

    test "returns deterministic referential issue codes across required entities" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      _stop_time_unknown_trip =
        stop_time_fixture(organization.id, gtfs_version.id, "missing_trip", "missing_stop")

      _trip_unknown_route =
        trip_fixture(organization.id, gtfs_version.id, "missing_route", %{
          trip_id: "trip_missing_route",
          service_id: "missing_service"
        })

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert Enum.map(result.blocking_errors, & &1.code) == [
               :stop_time_trip_not_found,
               :stop_time_stop_not_found,
               :trip_route_not_found,
               :trip_service_not_found
             ]
    end

    test "returns blocking error when stop_times arrival_time has invalid format" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      stop = stop_fixture(organization.id, gtfs_version.id)
      route = route_fixture(organization.id, gtfs_version.id)

      trip =
        trip_fixture(organization.id, gtfs_version.id, route.route_id, %{
          trip_id: "trip_invalid_arrival_time",
          service_id: "service_valid_time_format"
        })

      create_calendar!(organization.id, gtfs_version.id, trip.service_id)

      _stop_time =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop.stop_id, %{
          stop_sequence: 1,
          arrival_time: "08:61:00",
          departure_time: "09:00:00"
        })

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :stop_time_arrival_time_invalid_format, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.file == "stop_times.txt"
      assert issue.context.field == "arrival_time"
      assert issue.context.trip_id == trip.trip_id
      assert issue.context.stop_id == stop.stop_id
      assert issue.context.stop_sequence == 1
      assert issue.context.value == "08:61:00"
    end

    test "returns blocking error when stop_times departure_time has invalid format" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      stop = stop_fixture(organization.id, gtfs_version.id)
      route = route_fixture(organization.id, gtfs_version.id)

      trip =
        trip_fixture(organization.id, gtfs_version.id, route.route_id, %{
          trip_id: "trip_invalid_departure_time",
          service_id: "service_valid_time_format_2"
        })

      create_calendar!(organization.id, gtfs_version.id, trip.service_id)

      _stop_time =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop.stop_id, %{
          stop_sequence: 1,
          arrival_time: "09:00:00",
          departure_time: "09:00"
        })

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert [%{code: :stop_time_departure_time_invalid_format, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.file == "stop_times.txt"
      assert issue.context.field == "departure_time"
      assert issue.context.trip_id == trip.trip_id
      assert issue.context.stop_id == stop.stop_id
      assert issue.context.stop_sequence == 1
      assert issue.context.value == "09:00"
    end

    test "returns deterministic invalid time format issue codes across stop_times" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      stop = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop_time_codes"})
      route = route_fixture(organization.id, gtfs_version.id)

      trip =
        trip_fixture(organization.id, gtfs_version.id, route.route_id, %{
          trip_id: "trip_time_codes",
          service_id: "service_time_codes"
        })

      create_calendar!(organization.id, gtfs_version.id, trip.service_id)

      _stop_time_invalid_arrival =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop.stop_id, %{
          stop_sequence: 1,
          arrival_time: "bad",
          departure_time: "10:00:00"
        })

      _stop_time_invalid_departure =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop.stop_id, %{
          stop_sequence: 2,
          arrival_time: "11:00:00",
          departure_time: "11:70:00"
        })

      assert {:error, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert Enum.map(result.blocking_errors, & &1.code) == [
               :stop_time_arrival_time_invalid_format,
               :stop_time_departure_time_invalid_format
             ]
    end

    test "returns blocking error when no trip service is active for selected service date" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      stop = stop_fixture(organization.id, gtfs_version.id)
      route = route_fixture(organization.id, gtfs_version.id)

      trip =
        trip_fixture(organization.id, gtfs_version.id, route.route_id, %{
          trip_id: "trip_no_active_service",
          service_id: "service_no_active"
        })

      _stop_time =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop.stop_id)

      create_calendar!(organization.id, gtfs_version.id, trip.service_id, %{
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-01-01],
        end_date: ~D[2026-12-31]
      })

      assert {:error, result} =
               PathwaysPreflight.run(
                 organization.id,
                 gtfs_version.id,
                 test_window_context: %{service_date: ~D[2026-02-02]}
               )

      assert [%{code: :service_window_no_active_service, severity: :blocking} = issue] =
               result.blocking_errors

      assert issue.context.file == "calendar.txt"
      assert issue.context.service_date == "2026-02-02"
      assert issue.context.trip_count == 1
      assert issue.context.active_service_count == 0
    end

    test "passes service-window check when calendar_dates adds service on selected date" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      stop = stop_fixture(organization.id, gtfs_version.id)
      route = route_fixture(organization.id, gtfs_version.id)

      trip =
        trip_fixture(organization.id, gtfs_version.id, route.route_id, %{
          trip_id: "trip_calendar_date_added",
          service_id: "service_added"
        })

      _stop_time =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop.stop_id)

      create_calendar!(organization.id, gtfs_version.id, trip.service_id, %{
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-01-01],
        end_date: ~D[2026-12-31]
      })

      create_calendar_date!(organization.id, gtfs_version.id, trip.service_id, %{
        date: ~D[2026-02-02],
        exception_type: 1
      })

      assert {:ok, result} =
               PathwaysPreflight.run(
                 organization.id,
                 gtfs_version.id,
                 test_window_context: %{service_date: ~D[2026-02-02]}
               )

      assert result.blocking_errors == []
    end

    test "returns warning when pathways endpoint references unknown stop" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      known_stop = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "known_stop"})

      _pathway =
        pathway_fixture(organization.id, gtfs_version.id, known_stop.stop_id, "missing_stop", %{
          pathway_id: "pathway_unknown_endpoint"
        })

      assert {:ok, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert result.blocking_errors == []

      assert [%{code: :pathway_endpoint_stop_not_found, severity: :warning} = warning] =
               result.warnings

      assert warning.context.file == "pathways.txt"
      assert warning.context.pathway_id == "pathway_unknown_endpoint"
      assert warning.context.field == "to_stop_id"
      assert warning.context.value == "missing_stop"
    end

    test "returns deterministic warning codes for unknown pathway endpoints" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      _pathway =
        pathway_fixture(organization.id, gtfs_version.id, "missing_from_stop", "missing_stop", %{
          pathway_id: "pathway_invalid_endpoints"
        })

      assert {:ok, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)
      assert result.blocking_errors == []

      assert Enum.map(result.warnings, & &1.code) == [
               :pathway_endpoint_stop_not_found,
               :pathway_endpoint_stop_not_found
             ]
    end
  end

  describe "load_required_records/2" do
    test "loads scoped datasets with only required fields" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      stop_a = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop_a"})
      stop_b = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop_b"})
      route = route_fixture(organization.id, gtfs_version.id, %{route_id: "route_1"})

      trip =
        trip_fixture(organization.id, gtfs_version.id, route.route_id, %{
          trip_id: "trip_1",
          service_id: "service_1"
        })

      _stop_time =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop_a.stop_id)

      _pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_id: "pathway_1"
        })

      create_calendar!(organization.id, gtfs_version.id, trip.service_id)
      create_calendar_date!(organization.id, gtfs_version.id, trip.service_id)

      records = PathwaysPreflight.load_required_records(organization.id, gtfs_version.id)

      assert Enum.all?(records.stops, fn stop ->
               Enum.sort(Map.keys(stop)) ==
                 [:location_type, :parent_station, :stop_id, :stop_lat, :stop_lon]
             end)

      assert Enum.all?(records.pathways, fn pathway ->
               Enum.sort(Map.keys(pathway)) == [:from_stop_id, :pathway_id, :to_stop_id]
             end)

      assert Enum.all?(records.stop_times, fn stop_time ->
               Enum.sort(Map.keys(stop_time)) ==
                 [:arrival_time, :departure_time, :stop_id, :stop_sequence, :trip_id]
             end)

      assert Enum.all?(records.trips, fn trip ->
               Enum.sort(Map.keys(trip)) == [:route_id, :service_id, :trip_id]
             end)

      assert Enum.all?(records.routes, fn route ->
               Enum.sort(Map.keys(route)) == [:route_id]
             end)

      assert Enum.all?(records.calendars, fn calendar ->
               Enum.sort(Map.keys(calendar)) == [
                 :end_date,
                 :friday,
                 :monday,
                 :saturday,
                 :service_id,
                 :start_date,
                 :sunday,
                 :thursday,
                 :tuesday,
                 :wednesday
               ]
             end)

      assert Enum.all?(records.calendar_dates, fn calendar_date ->
               Enum.sort(Map.keys(calendar_date)) == [:date, :exception_type, :service_id]
             end)
    end

    test "run/3 includes record_counts metadata from query layer" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      stop_a = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop_c"})
      stop_b = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop_d"})
      route = route_fixture(organization.id, gtfs_version.id, %{route_id: "route_2"})

      trip =
        trip_fixture(organization.id, gtfs_version.id, route.route_id, %{
          trip_id: "trip_2",
          service_id: "service_2"
        })

      _stop_time =
        stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop_a.stop_id)

      _pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_id: "pathway_2"
        })

      create_calendar!(organization.id, gtfs_version.id, trip.service_id)
      create_calendar_date!(organization.id, gtfs_version.id, trip.service_id)

      assert {:ok, result} = PathwaysPreflight.run(organization.id, gtfs_version.id)

      assert result.metadata.record_counts == %{
               stops: 2,
               pathways: 1,
               stop_times: 1,
               trips: 1,
               routes: 1,
               calendars: 1,
               calendar_dates: 1
             }
    end
  end

  defp create_calendar!(organization_id, gtfs_version_id, service_id, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        service_id: service_id,
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
      })

    %Calendar{}
    |> Calendar.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_calendar_date!(organization_id, gtfs_version_id, service_id, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        service_id: service_id,
        date: ~D[2026-02-01],
        exception_type: 1,
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })

    %CalendarDate{}
    |> CalendarDate.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_stop_row!(organization_id, gtfs_version_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row =
      attrs
      |> Map.merge(%{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        inserted_at: now,
        updated_at: now
      })

    {1, _} = Repo.insert_all(Stop, [row])
    :ok
  end
end
