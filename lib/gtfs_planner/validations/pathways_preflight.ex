defmodule GtfsPlanner.Validations.PathwaysPreflight do
  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.{Calendar, CalendarDate, Pathway, Route, Stop, StopTime, Trip}
  alias GtfsPlanner.Repo

  @moduledoc """
  Deterministic preflight boundary for pathways export validation.

  This module currently establishes the stable public contract used by
  preflight callers. Rule evaluators are composed in later implementation
  steps.
  """

  @typedoc "Stable machine-readable issue identifier."
  @type issue_code :: atom() | String.t()

  @typedoc "Issue severity used by preflight gates and UIs."
  @type issue_severity :: :blocking | :warning

  @typedoc "Context payload with file/field/row/id diagnostics."
  @type issue_context :: %{optional(atom() | String.t()) => term()}

  @type issue :: %{
          required(:code) => issue_code(),
          required(:severity) => issue_severity(),
          required(:message) => String.t(),
          required(:context) => issue_context()
        }

  @typedoc "Optional test-window data consumed by service-window checks."
  @type test_window_context :: %{optional(atom() | String.t()) => term()}

  @type metadata :: %{
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          required(:test_window_context) => test_window_context(),
          optional(:record_counts) => map()
        }

  @type records :: %{
          required(:stops) => [map()],
          required(:pathways) => [map()],
          required(:stop_times) => [map()],
          required(:trips) => [map()],
          required(:routes) => [map()],
          required(:calendars) => [map()],
          required(:calendar_dates) => [map()]
        }

  @type result :: %{
          required(:blocking_errors) => [issue()],
          required(:warnings) => [issue()],
          required(:metadata) => metadata()
        }

  @type outcome :: {:ok, result()} | {:error, result()}

  @type longitude_sign :: :negative | :positive

  @doc """
  Runs pathways preflight checks and returns a structured, tagged outcome.

  `opts` may include `:test_window_context` for future service-window checks.
  """
  @spec run(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: outcome()
  def run(organization_id, gtfs_version_id, opts \\ []) do
    test_window_context = normalize_test_window_context(opts)
    records = load_required_records(organization_id, gtfs_version_id)
    expected_lon_sign = expected_longitude_sign(opts, test_window_context)

    blocking_errors =
      run_evaluators(records, [
        fn eval_records -> evaluate_station_coordinates(eval_records.stops) end,
        fn eval_records ->
          evaluate_station_longitude_sign(eval_records.stops, expected_lon_sign)
        end,
        fn eval_records -> evaluate_boarding_area_parent_integrity(eval_records.stops) end,
        &evaluate_referential_integrity/1,
        fn eval_records -> evaluate_stop_time_time_formats(eval_records.stop_times) end,
        fn eval_records -> evaluate_active_service_window(eval_records, test_window_context) end
      ])

    warnings = run_evaluators(records, [&evaluate_warnings/1])

    result = %{
      blocking_errors: blocking_errors,
      warnings: warnings,
      metadata: %{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        test_window_context: test_window_context,
        record_counts: summarize_record_counts(records)
      }
    }

    case result.blocking_errors do
      [] -> {:ok, result}
      _ -> {:error, result}
    end
  end

  @doc """
  Loads the minimum GTFS datasets needed by preflight evaluators.

  The query layer is scoped by organization/version and selects only fields
  required by planned preflight rules.
  """
  @spec load_required_records(Ecto.UUID.t(), Ecto.UUID.t()) :: records()
  def load_required_records(organization_id, gtfs_version_id) do
    %{
      stops: load_stops(organization_id, gtfs_version_id),
      pathways: load_pathways(organization_id, gtfs_version_id),
      stop_times: load_stop_times(organization_id, gtfs_version_id),
      trips: load_trips(organization_id, gtfs_version_id),
      routes: load_routes(organization_id, gtfs_version_id),
      calendars: load_calendars(organization_id, gtfs_version_id),
      calendar_dates: load_calendar_dates(organization_id, gtfs_version_id)
    }
  end

  @spec normalize_test_window_context(keyword()) :: test_window_context()
  defp normalize_test_window_context(opts) do
    case Keyword.get(opts, :test_window_context, %{}) do
      context when is_map(context) -> context
      _other -> %{}
    end
  end

  @spec load_stops(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  defp load_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: %{
        stop_id: s.stop_id,
        location_type: s.location_type,
        parent_station: s.parent_station,
        stop_lat: s.stop_lat,
        stop_lon: s.stop_lon
      }
    )
    |> Repo.all()
  end

  @spec load_pathways(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  defp load_pathways(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id,
      select: %{
        pathway_id: p.pathway_id,
        from_stop_id: p.from_stop_id,
        to_stop_id: p.to_stop_id
      }
    )
    |> Repo.all()
  end

  @spec load_stop_times(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  defp load_stop_times(organization_id, gtfs_version_id) do
    from(st in StopTime,
      where: st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id,
      select: %{
        trip_id: st.trip_id,
        stop_id: st.stop_id,
        stop_sequence: st.stop_sequence,
        arrival_time: st.arrival_time,
        departure_time: st.departure_time
      }
    )
    |> Repo.all()
  end

  @spec load_trips(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  defp load_trips(organization_id, gtfs_version_id) do
    from(t in Trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      select: %{trip_id: t.trip_id, route_id: t.route_id, service_id: t.service_id}
    )
    |> Repo.all()
  end

  @spec load_routes(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  defp load_routes(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      select: %{route_id: r.route_id}
    )
    |> Repo.all()
  end

  @spec load_calendars(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  defp load_calendars(organization_id, gtfs_version_id) do
    from(c in Calendar,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id,
      select: %{
        service_id: c.service_id,
        monday: c.monday,
        tuesday: c.tuesday,
        wednesday: c.wednesday,
        thursday: c.thursday,
        friday: c.friday,
        saturday: c.saturday,
        sunday: c.sunday,
        start_date: c.start_date,
        end_date: c.end_date
      }
    )
    |> Repo.all()
  end

  @spec load_calendar_dates(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  defp load_calendar_dates(organization_id, gtfs_version_id) do
    from(cd in CalendarDate,
      where: cd.organization_id == ^organization_id and cd.gtfs_version_id == ^gtfs_version_id,
      select: %{service_id: cd.service_id, date: cd.date, exception_type: cd.exception_type}
    )
    |> Repo.all()
  end

  @spec summarize_record_counts(records()) :: map()
  defp summarize_record_counts(records) do
    Map.new(records, fn {key, rows} -> {key, length(rows)} end)
  end

  @spec run_evaluators(records(), [(records() -> [issue()])]) :: [issue()]
  defp run_evaluators(records, evaluators) do
    Enum.flat_map(evaluators, fn evaluator -> evaluator.(records) end)
  end

  @spec evaluate_station_coordinates([map()]) :: [issue()]
  defp evaluate_station_coordinates(stops) do
    stops
    |> Enum.filter(&(&1.location_type == 1))
    |> Enum.flat_map(fn stop ->
      [
        coordinate_issue(stop, :stop_lat, -90.0, 90.0),
        coordinate_issue(stop, :stop_lon, -180.0, 180.0)
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  @spec evaluate_station_longitude_sign([map()], longitude_sign() | nil) :: [issue()]
  defp evaluate_station_longitude_sign(_stops, nil), do: []

  defp evaluate_station_longitude_sign(stops, expected_sign) do
    stops
    |> Enum.filter(&(&1.location_type == 1))
    |> Enum.flat_map(fn stop ->
      case parse_coordinate(stop.stop_lon) do
        {:ok, lon} when lon == 0.0 ->
          []

        {:ok, lon} ->
          if longitude_matches_expected_sign?(lon, expected_sign) do
            []
          else
            [
              %{
                code: :station_stop_lon_sign_mismatch,
                severity: :blocking,
                message:
                  "Station #{stop.stop_id} has stop_lon with wrong sign for configured region in stops.txt.",
                context:
                  issue_context(stop, :stop_lon, lon)
                  |> Map.put(:expected_sign, Atom.to_string(expected_sign))
              }
            ]
          end

        _other ->
          []
      end
    end)
  end

  @spec evaluate_boarding_area_parent_integrity([map()]) :: [issue()]
  defp evaluate_boarding_area_parent_integrity(stops) do
    known_stop_ids =
      stops
      |> Enum.map(& &1.stop_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    stops
    |> Enum.filter(&(&1.location_type == 4))
    |> Enum.sort_by(fn stop -> stop.stop_id || "" end)
    |> Enum.flat_map(fn stop ->
      case normalize_parent_station(stop.parent_station) do
        nil ->
          [
            %{
              code: :boarding_area_parent_station_missing,
              severity: :blocking,
              message: "Boarding area #{stop.stop_id} is missing parent_station in stops.txt.",
              context: issue_context(stop, :parent_station)
            }
          ]

        parent_station ->
          if MapSet.member?(known_stop_ids, parent_station) do
            []
          else
            [
              %{
                code: :boarding_area_parent_station_not_found,
                severity: :blocking,
                message:
                  "Boarding area #{stop.stop_id} references unknown parent_station #{parent_station} in stops.txt.",
                context: issue_context(stop, :parent_station, parent_station)
              }
            ]
          end
      end
    end)
  end

  @spec evaluate_referential_integrity(records()) :: [issue()]
  defp evaluate_referential_integrity(records) do
    trip_ids = records.trips |> Enum.map(& &1.trip_id) |> MapSet.new()
    stop_ids = records.stops |> Enum.map(& &1.stop_id) |> MapSet.new()
    route_ids = records.routes |> Enum.map(& &1.route_id) |> MapSet.new()

    sorted_stop_times =
      Enum.sort_by(records.stop_times, fn stop_time ->
        {
          normalize_sort_value(stop_time.trip_id),
          stop_time.stop_sequence || -1,
          normalize_sort_value(stop_time.stop_id)
        }
      end)

    sorted_trips =
      Enum.sort_by(records.trips, fn trip ->
        {
          normalize_sort_value(trip.trip_id),
          normalize_sort_value(trip.route_id),
          normalize_sort_value(trip.service_id)
        }
      end)

    service_ids =
      (records.calendars |> Enum.map(& &1.service_id)) ++
        (records.calendar_dates |> Enum.map(& &1.service_id))

    service_ids = MapSet.new(service_ids)

    stop_time_trip_issues =
      sorted_stop_times
      |> Enum.reject(&MapSet.member?(trip_ids, &1.trip_id))
      |> Enum.map(fn stop_time ->
        %{
          code: :stop_time_trip_not_found,
          severity: :blocking,
          message:
            "stop_times.txt row for trip_id #{stop_time.trip_id} references unknown trip_id.",
          context: %{
            file: "stop_times.txt",
            field: "trip_id",
            trip_id: stop_time.trip_id,
            stop_id: stop_time.stop_id
          }
        }
      end)

    stop_time_stop_issues =
      sorted_stop_times
      |> Enum.reject(&MapSet.member?(stop_ids, &1.stop_id))
      |> Enum.map(fn stop_time ->
        %{
          code: :stop_time_stop_not_found,
          severity: :blocking,
          message:
            "stop_times.txt row for stop_id #{stop_time.stop_id} references unknown stop_id.",
          context: %{
            file: "stop_times.txt",
            field: "stop_id",
            trip_id: stop_time.trip_id,
            stop_id: stop_time.stop_id
          }
        }
      end)

    trip_route_issues =
      sorted_trips
      |> Enum.reject(&MapSet.member?(route_ids, &1.route_id))
      |> Enum.map(fn trip ->
        %{
          code: :trip_route_not_found,
          severity: :blocking,
          message: "trips.txt row for trip_id #{trip.trip_id} references unknown route_id.",
          context: %{
            file: "trips.txt",
            field: "route_id",
            trip_id: trip.trip_id,
            route_id: trip.route_id
          }
        }
      end)

    trip_service_issues =
      sorted_trips
      |> Enum.reject(&MapSet.member?(service_ids, &1.service_id))
      |> Enum.map(fn trip ->
        %{
          code: :trip_service_not_found,
          severity: :blocking,
          message: "trips.txt row for trip_id #{trip.trip_id} references unknown service_id.",
          context: %{
            file: "trips.txt",
            field: "service_id",
            trip_id: trip.trip_id,
            service_id: trip.service_id
          }
        }
      end)

    stop_time_trip_issues ++ stop_time_stop_issues ++ trip_route_issues ++ trip_service_issues
  end

  @spec evaluate_stop_time_time_formats([map()]) :: [issue()]
  defp evaluate_stop_time_time_formats(stop_times) do
    stop_times
    |> Enum.sort_by(fn stop_time ->
      {
        normalize_sort_value(stop_time.trip_id),
        stop_time.stop_sequence || -1,
        normalize_sort_value(stop_time.stop_id)
      }
    end)
    |> Enum.flat_map(fn stop_time ->
      [
        invalid_stop_time_time_issue(stop_time, :arrival_time),
        invalid_stop_time_time_issue(stop_time, :departure_time)
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  @spec invalid_stop_time_time_issue(map(), :arrival_time | :departure_time) :: issue() | nil
  defp invalid_stop_time_time_issue(stop_time, field) do
    value = Map.get(stop_time, field)

    if valid_gtfs_time_format?(value) do
      nil
    else
      %{
        code: invalid_stop_time_time_issue_code(field),
        severity: :blocking,
        message:
          "stop_times.txt row for trip_id #{stop_time.trip_id} has invalid #{field} format.",
        context: %{
          file: "stop_times.txt",
          field: Atom.to_string(field),
          trip_id: stop_time.trip_id,
          stop_id: stop_time.stop_id,
          stop_sequence: stop_time.stop_sequence,
          value: value
        }
      }
    end
  end

  @spec valid_gtfs_time_format?(term()) :: boolean()
  defp valid_gtfs_time_format?(nil), do: true
  defp valid_gtfs_time_format?(""), do: true

  defp valid_gtfs_time_format?(value) when is_binary(value) do
    with [hours, minutes, seconds] <- String.split(String.trim(value), ":"),
         true <- hours != "",
         {hours_int, ""} <- Integer.parse(hours),
         true <- hours_int >= 0,
         {minutes_int, ""} <- Integer.parse(minutes),
         {seconds_int, ""} <- Integer.parse(seconds),
         true <- minutes_int in 0..59,
         true <- seconds_int in 0..59 do
      true
    else
      _ -> false
    end
  end

  defp valid_gtfs_time_format?(_value), do: false

  @spec invalid_stop_time_time_issue_code(:arrival_time | :departure_time) :: atom()
  defp invalid_stop_time_time_issue_code(:arrival_time),
    do: :stop_time_arrival_time_invalid_format

  defp invalid_stop_time_time_issue_code(:departure_time),
    do: :stop_time_departure_time_invalid_format

  @spec normalize_sort_value(term()) :: String.t()
  defp normalize_sort_value(nil), do: ""
  defp normalize_sort_value(value) when is_binary(value), do: value
  defp normalize_sort_value(value), do: to_string(value)

  @spec evaluate_active_service_window(records(), test_window_context()) :: [issue()]
  defp evaluate_active_service_window(records, test_window_context) do
    case extract_service_date(test_window_context) do
      nil ->
        []

      service_date ->
        trip_service_ids =
          records.trips
          |> Enum.map(& &1.service_id)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        active_service_ids = active_service_ids_for_date(records, service_date)

        if MapSet.disjoint?(trip_service_ids, active_service_ids) do
          [
            %{
              code: :service_window_no_active_service,
              severity: :blocking,
              message:
                "No active service_id in trips.txt matches the selected service date #{Date.to_iso8601(service_date)}.",
              context: %{
                file: "calendar.txt",
                service_date: Date.to_iso8601(service_date),
                trip_count: map_set_size(trip_service_ids),
                active_service_count: map_set_size(active_service_ids)
              }
            }
          ]
        else
          []
        end
    end
  end

  @spec evaluate_warnings(records()) :: [issue()]
  defp evaluate_warnings(records) do
    known_stop_ids =
      records.stops
      |> Enum.map(& &1.stop_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    records.pathways
    |> Enum.flat_map(fn pathway ->
      [
        pathway_endpoint_warning(pathway, :from_stop_id, known_stop_ids),
        pathway_endpoint_warning(pathway, :to_stop_id, known_stop_ids)
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  @spec pathway_endpoint_warning(map(), :from_stop_id | :to_stop_id, MapSet.t(String.t())) ::
          issue() | nil
  defp pathway_endpoint_warning(pathway, field, known_stop_ids) do
    stop_id = Map.get(pathway, field)

    cond do
      is_nil(stop_id) or stop_id == "" ->
        %{
          code: :pathway_endpoint_stop_missing,
          severity: :warning,
          message: "Pathway #{pathway.pathway_id} is missing #{field} in pathways.txt.",
          context: %{
            file: "pathways.txt",
            pathway_id: pathway.pathway_id,
            field: Atom.to_string(field),
            value: stop_id
          }
        }

      MapSet.member?(known_stop_ids, stop_id) ->
        nil

      true ->
        %{
          code: :pathway_endpoint_stop_not_found,
          severity: :warning,
          message:
            "Pathway #{pathway.pathway_id} references unknown #{field} #{stop_id} in pathways.txt.",
          context: %{
            file: "pathways.txt",
            pathway_id: pathway.pathway_id,
            field: Atom.to_string(field),
            value: stop_id
          }
        }
    end
  end

  @spec active_service_ids_for_date(records(), Date.t()) :: MapSet.t(String.t())
  defp active_service_ids_for_date(records, service_date) do
    base_active_service_ids =
      records.calendars
      |> Enum.filter(&calendar_active_on_date?(&1, service_date))
      |> Enum.map(& &1.service_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    additions =
      records.calendar_dates
      |> Enum.filter(&(&1.date == service_date and &1.exception_type == 1))
      |> Enum.map(& &1.service_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    removals =
      records.calendar_dates
      |> Enum.filter(&(&1.date == service_date and &1.exception_type == 2))
      |> Enum.map(& &1.service_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    base_active_service_ids
    |> MapSet.union(additions)
    |> MapSet.difference(removals)
  end

  @spec calendar_active_on_date?(map(), Date.t()) :: boolean()
  defp calendar_active_on_date?(calendar, service_date) do
    in_range? = Date.compare(service_date, calendar.start_date) in [:eq, :gt]
    in_range? = in_range? and Date.compare(service_date, calendar.end_date) in [:eq, :lt]

    in_range? and weekday_service_active?(calendar, Date.day_of_week(service_date))
  end

  @spec weekday_service_active?(map(), 1..7) :: boolean()
  defp weekday_service_active?(calendar, weekday) do
    value =
      case weekday do
        1 -> calendar.monday
        2 -> calendar.tuesday
        3 -> calendar.wednesday
        4 -> calendar.thursday
        5 -> calendar.friday
        6 -> calendar.saturday
        7 -> calendar.sunday
      end

    value == 1
  end

  @spec extract_service_date(test_window_context()) :: Date.t() | nil
  defp extract_service_date(test_window_context) do
    test_window_context
    |> service_date_candidates()
    |> Enum.find_value(&normalize_service_date/1)
  end

  @spec service_date_candidates(test_window_context()) :: [term()]
  defp service_date_candidates(test_window_context) do
    [
      map_value(test_window_context, :service_date),
      map_value(test_window_context, :query_date),
      map_value(test_window_context, :date),
      map_value(test_window_context, :test_date),
      map_value(test_window_context, :query_datetime),
      map_value(test_window_context, :datetime)
    ]
  end

  @spec normalize_service_date(term()) :: Date.t() | nil
  defp normalize_service_date(%Date{} = date), do: date
  defp normalize_service_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp normalize_service_date(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)

  defp normalize_service_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        date

      {:error, _reason} ->
        with {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
          DateTime.to_date(datetime)
        else
          _other -> nil
        end
    end
  end

  defp normalize_service_date(_value), do: nil

  @spec map_set_size(MapSet.t()) :: non_neg_integer()
  defp map_set_size(set), do: MapSet.size(set)

  @spec expected_longitude_sign(keyword(), test_window_context()) :: longitude_sign() | nil
  defp expected_longitude_sign(opts, test_window_context) do
    opts
    |> Keyword.get(:expected_longitude_sign)
    |> normalize_longitude_sign()
    |> case do
      nil ->
        test_window_context
        |> map_value(:expected_longitude_sign)
        |> normalize_longitude_sign()

      sign ->
        sign
    end
  end

  @spec normalize_longitude_sign(term()) :: longitude_sign() | nil
  defp normalize_longitude_sign(value) when value in [:negative, "negative", :west, "west", -1],
    do: :negative

  defp normalize_longitude_sign(value) when value in [:positive, "positive", :east, "east", 1],
    do: :positive

  defp normalize_longitude_sign(_value), do: nil

  @spec longitude_matches_expected_sign?(float(), longitude_sign()) :: boolean()
  defp longitude_matches_expected_sign?(lon, :negative), do: lon < 0
  defp longitude_matches_expected_sign?(lon, :positive), do: lon > 0

  @spec map_value(map() | nil, atom()) :: term()
  defp map_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp map_value(_payload, _key), do: nil

  @spec coordinate_issue(map(), :stop_lat | :stop_lon, float(), float()) :: issue() | nil
  defp coordinate_issue(stop, field, min, max) do
    field_value = Map.get(stop, field)

    case parse_coordinate(field_value) do
      {:ok, coordinate} when coordinate >= min and coordinate <= max ->
        nil

      {:ok, coordinate} ->
        %{
          code: out_of_range_issue_code(field),
          severity: :blocking,
          message: "Station #{stop.stop_id} has #{field} outside #{min}..#{max} in stops.txt.",
          context: issue_context(stop, field, coordinate)
        }

      :missing ->
        %{
          code: missing_issue_code(field),
          severity: :blocking,
          message: "Station #{stop.stop_id} is missing #{field} in stops.txt.",
          context: issue_context(stop, field)
        }

      :not_numeric ->
        %{
          code: not_numeric_issue_code(field),
          severity: :blocking,
          message: "Station #{stop.stop_id} has non-numeric #{field} in stops.txt.",
          context: issue_context(stop, field, field_value)
        }
    end
  end

  @spec parse_coordinate(term()) :: {:ok, float()} | :missing | :not_numeric
  defp parse_coordinate(nil), do: :missing
  defp parse_coordinate(""), do: :missing
  defp parse_coordinate(%Decimal{} = value), do: {:ok, Decimal.to_float(value)}
  defp parse_coordinate(value) when is_float(value), do: {:ok, value}
  defp parse_coordinate(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_coordinate(_value), do: :not_numeric

  @spec normalize_parent_station(term()) :: String.t() | nil
  defp normalize_parent_station(nil), do: nil
  defp normalize_parent_station(""), do: nil
  defp normalize_parent_station(value) when is_binary(value), do: value
  defp normalize_parent_station(value), do: to_string(value)

  @spec missing_issue_code(:stop_lat | :stop_lon) :: atom()
  defp missing_issue_code(:stop_lat), do: :station_stop_lat_missing
  defp missing_issue_code(:stop_lon), do: :station_stop_lon_missing

  @spec not_numeric_issue_code(:stop_lat | :stop_lon) :: atom()
  defp not_numeric_issue_code(:stop_lat), do: :station_stop_lat_not_numeric
  defp not_numeric_issue_code(:stop_lon), do: :station_stop_lon_not_numeric

  @spec out_of_range_issue_code(:stop_lat | :stop_lon) :: atom()
  defp out_of_range_issue_code(:stop_lat), do: :station_stop_lat_out_of_range
  defp out_of_range_issue_code(:stop_lon), do: :station_stop_lon_out_of_range

  @spec issue_context(map(), :stop_lat | :stop_lon | :parent_station, term() | nil) ::
          issue_context()
  defp issue_context(stop, field, value \\ nil) do
    %{
      file: "stops.txt",
      stop_id: stop.stop_id,
      location_type: stop.location_type,
      field: Atom.to_string(field),
      value: value
    }
  end
end
