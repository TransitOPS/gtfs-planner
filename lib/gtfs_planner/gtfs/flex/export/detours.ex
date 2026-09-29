defmodule GtfsPlanner.Gtfs.Flex.Export.Detours do
  @moduledoc """
  The flex rows of one detour service (R2, R6, AC-19).

  `rows/4` is pure: it turns one `GtfsPlanner.Gtfs.FlexService`, the zones
  `GtfsPlanner.Gtfs.Flex.Geometry.detour_zones/3` derived for it, the trips the
  service covers (each with its stored stop times in visit order) and the ID of
  the service's booking rule into the zone `stop_times` rows the flex file
  appends and the `locations.geojson` features for the zones, keyed by GTFS
  column atoms so `GtfsPlanner.Gtfs.Export.CsvWriter.write_row/4` resolves them.

  A covered trip keeps its own `trip_id` and its fixed stops; between each pair
  of consecutive stops in the stretch one windowed row names the pair's zone
  (R2). Its window is the departure at the first stop of the pair and the
  arrival at the second, verbatim so seconds survive, and its `stop_sequence`
  is the odd value between the doubled stored sequences (R3). The zone is the
  same in either direction, because R11's ID is built from the unordered pair
  and the stretch applies in whichever order the trip visits its stops.

  The trips considered are those of the service's chosen calendars (R6). A
  band keeps only trips whose departure at the first stretch stop reached falls
  in it, start inclusive and end exclusive. A trip listed in `frequencies.txt`,
  a pair with equal or missing times and a pair with no derived zone get no
  rows; the last three are reported once per pair with the number of trips they
  affect. Every row also carries `:drop_off_message`, the `booking_rules.txt`
  field AC-19 sets for the modes that let riders get off away from the route.

  Nothing here reads or writes the database (CR-4), so the caller decides which
  services are exportable (R4).
  """

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.GtfsTime

  @typedoc """
  One stored stop of a trip, in visit order.
  """
  @type stop :: %{
          stop_id: String.t(),
          stop_sequence: integer(),
          arrival_time: String.t() | nil,
          departure_time: String.t() | nil
        }

  @typedoc """
  One trip a detour service may cover, with its stored stop times.
  """
  @type trip :: %{
          trip_id: String.t(),
          service_id: String.t(),
          frequency?: boolean(),
          stops: [stop()]
        }

  @typedoc """
  One detour zone derived by `Flex.Geometry.detour_zones/3` (R13).
  """
  @type zone :: %{zone_id: String.t(), stop_a: String.t(), stop_b: String.t(), geojson: map()}

  @typedoc """
  The rows of one detour service, keyed by the flex file each belongs to.
  """
  @type rows_map :: %{stop_times: [map()], locations: [map()]}

  @doc """
  Returns the zone `stop_times` rows and `locations.geojson` features of one
  detour service, with the warnings for what could not be written.

  `zones` are the service's derived zones in any order (each is looked up by
  its unordered pair), `trip_times` are the trips on the service's route with
  their stored stop times in visit order, and `rule_id` is the booking rule the
  rows reference.
  """
  @spec rows(FlexService.t(), [zone()], [trip()], String.t()) :: {rows_map(), [Export.warning()]}
  def rows(%FlexService{kind: :detour} = service, zones, trip_times, rule_id) do
    zone_index = zone_index(zones)
    trips = selected_trips(service, trip_times)

    stop_times =
      trips
      |> Enum.reject(& &1.frequency?)
      |> Enum.flat_map(&rows_for(service, &1, zone_index, rule_id))

    issues = Enum.flat_map(trips, &issues_for(service, &1, zone_index, rule_id))

    {
      %{stop_times: stop_times, locations: Enum.map(zones, &location_row(service, &1))},
      warnings(service, issues)
    }
  end

  # --- rows -------------------------------------------------------------------

  # R6: a detour service selects the trips of its chosen calendars; a service
  # with none is a readiness error (R4) and covers nothing here.
  defp selected_trips(%FlexService{calendar_service_ids: []}, _trip_times), do: []

  defp selected_trips(service, trip_times) do
    selected = MapSet.new(service.calendar_service_ids)
    Enum.filter(trip_times, &MapSet.member?(selected, &1.service_id))
  end

  defp rows_for(service, trip, zone_index, rule_id) do
    stops = stretch(service, trip.stops)

    if in_band?(service, stops) do
      stops
      |> chunk_pairs()
      |> Enum.flat_map(&rows_for_pair(service, trip, &1, zone_index, rule_id))
    else
      []
    end
  end

  defp rows_for_pair(service, trip, [first, second], zone_index, rule_id) do
    case pair(service, trip, first, second, zone_index, rule_id) do
      {:ok, row} -> [row]
      {:issue, _issue} -> []
    end
  end

  defp issues_for(_service, %{frequency?: true} = trip, _zone_index, _rule_id),
    do: [{:flex_detour_frequency_trip, trip.trip_id}]

  defp issues_for(service, trip, zone_index, rule_id) do
    service
    |> stretch(trip.stops)
    |> chunk_pairs()
    |> Enum.flat_map(&issues_for_pair(service, trip, &1, zone_index, rule_id))
  end

  defp issues_for_pair(service, trip, [first, second], zone_index, rule_id) do
    case pair(service, trip, first, second, zone_index, rule_id) do
      {:ok, _row} -> []
      {:issue, issue} -> [issue]
    end
  end

  defp chunk_pairs(stops), do: Enum.chunk_every(stops, 2, 1, :discard)

  # R13: the stretch applies between the two named stops in whichever order the
  # trip visits them, so an inbound trip starts at the named last stop. A trip
  # that visits only one of them covers the part of the stretch it runs, the
  # same clamp `Flex.Geometry.detour_zones/3` applies to a short-turn pattern.
  defp stretch(%FlexService{} = service, stops) do
    first = stop_index(stops, service.first_stop_id)
    last = stop_index(stops, service.last_stop_id)

    case {first, last} do
      {nil, nil} -> []
      {index, nil} -> Enum.drop(stops, index)
      {nil, index} -> Enum.take(stops, index + 1)
      {from, to} -> Enum.slice(stops, min(from, to)..max(from, to))
    end
  end

  defp stop_index(_stops, nil), do: nil
  defp stop_index(stops, stop_id), do: Enum.find_index(stops, &(&1.stop_id == stop_id))

  defp pair(service, trip, first, second, zone_index, rule_id) do
    with {:ok, departure_seconds} <- time_seconds(first.departure_time),
         {:ok, arrival_seconds} <- time_seconds(second.arrival_time) do
      if departure_seconds == arrival_seconds do
        {:issue, {:flex_detour_same_time, stop_pair(first, second)}}
      else
        zone_row(service, trip, first, second, zone_index, rule_id)
      end
    else
      _missing -> {:issue, {:flex_detour_missing_time, stop_pair(first, second)}}
    end
  end

  defp zone_row(service, trip, first, second, zone_index, rule_id) do
    case Map.fetch(zone_index, stop_pair(first, second)) do
      {:ok, zone} -> {:ok, row(trip, first, second, zone, rule_id, service)}
      :error -> {:issue, {:flex_detour_no_zone, stop_pair(first, second)}}
    end
  end

  defp stop_pair(first, second), do: {first.stop_id, second.stop_id}

  defp row(trip, first, second, zone, rule_id, service) do
    {pickup_type, drop_off_type, pickup_rule, drop_off_rule} = references(service, rule_id)

    %{
      trip_id: trip.trip_id,
      arrival_time: nil,
      departure_time: nil,
      stop_id: nil,
      location_group_id: nil,
      location_id: zone.zone_id,
      stop_sequence: first.stop_sequence * 2 + 1,
      start_pickup_drop_off_window: first.departure_time,
      end_pickup_drop_off_window: second.arrival_time,
      pickup_type: pickup_type,
      drop_off_type: drop_off_type,
      pickup_booking_rule_id: pickup_rule,
      drop_off_booking_rule_id: drop_off_rule,
      drop_off_message: RiderText.drop_off_message(service)
    }
  end

  # AC-19: how riders board and leave the detour, with the booking references
  # each mode uses. A detour service has exactly one rule (R7), so `book`
  # references the same rule on both sides.
  defp references(%FlexService{dropoffs: :tell_driver}, rule_id), do: {2, 3, rule_id, nil}
  defp references(%FlexService{dropoffs: :book}, rule_id), do: {2, 2, rule_id, rule_id}
  defp references(%FlexService{dropoffs: :dropoff_only}, _rule_id), do: {1, 3, nil, nil}

  # --- band -------------------------------------------------------------------

  defp in_band?(_service, []), do: true

  defp in_band?(service, [first | _rest]) do
    case band_bounds(service) do
      nil -> true
      {start, finish} -> in_band_departure(first.departure_time, start, finish)
    end
  end

  # A trip whose reference departure is missing or unreadable cannot be shown
  # to be in the band, so it is left out; the pair it would have started with
  # still reports its missing time.
  defp in_band_departure(departure, start, finish) do
    case time_seconds(departure) do
      {:ok, seconds} -> seconds >= start and seconds < finish
      {:error, :invalid_time} -> false
    end
  end

  # The stored band is "HH:MM"; a partial or unreadable one is no band.
  defp band_bounds(%FlexService{band_start: start, band_end: finish})
       when is_binary(start) and is_binary(finish) do
    with {:ok, start} <- hhmm_seconds(start),
         {:ok, finish} <- hhmm_seconds(finish) do
      {start, finish}
    else
      _invalid -> nil
    end
  end

  defp band_bounds(_service), do: nil

  defp hhmm_seconds(time) when is_binary(time), do: GtfsTime.parse(time <> ":00")

  # --- locations and warnings -------------------------------------------------

  defp zone_index(zones) do
    zones
    |> Enum.flat_map(fn zone ->
      [{{zone.stop_a, zone.stop_b}, zone}, {{zone.stop_b, zone.stop_a}, zone}]
    end)
    |> Map.new()
  end

  # The zone name riders read, the prototype's export plan: one name per route,
  # with R11's zone ID.
  defp location_row(%FlexService{route_id: route_id}, zone) do
    %{id: zone.zone_id, stop_name: "Route #{route_id} detour area", geometry: zone.geojson}
  end

  # One warning per distinct finding, in the order the findings appear, carrying
  # how many trips it affects.
  defp warnings(service, issues) do
    issues
    |> Enum.uniq()
    |> Enum.map(fn issue -> warning(service, issue, Enum.count(issues, &(&1 == issue))) end)
  end

  defp warning(service, {:flex_detour_frequency_trip, trip_id}, _count) do
    %{
      code: "flex_detour_frequency_trip",
      detail: "#{service.name}: trip #{trip_id} runs on a frequency and gets no detour rows.",
      file: "stop_times.txt",
      entity_type: "stop_time"
    }
  end

  defp warning(service, {code, {stop_a, stop_b}}, count) do
    %{
      code: Atom.to_string(code),
      detail: detail(service, code, stop_a, stop_b, count),
      file: "stop_times.txt",
      entity_type: "stop_time"
    }
  end

  defp detail(service, :flex_detour_same_time, stop_a, stop_b, count) do
    "#{service.name}: no detour row for #{count} #{trip_word(count)} between stops " <>
      "#{stop_a} and #{stop_b}: the departure and arrival times are equal."
  end

  defp detail(service, :flex_detour_missing_time, stop_a, stop_b, count) do
    "#{service.name}: no detour row for #{count} #{trip_word(count)} between stops " <>
      "#{stop_a} and #{stop_b}: a departure or arrival time is missing."
  end

  defp detail(service, :flex_detour_no_zone, stop_a, stop_b, count) do
    "#{service.name}: no detour area covers stops #{stop_a} and #{stop_b} for " <>
      "#{count} #{trip_word(count)}."
  end

  defp trip_word(1), do: "trip"
  defp trip_word(_count), do: "trips"

  defp time_seconds(value) when is_binary(value), do: GtfsTime.parse(value)
  defp time_seconds(_value), do: {:error, :invalid_time}
end
