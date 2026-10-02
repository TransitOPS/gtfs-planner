defmodule GtfsPlanner.Gtfs.Flex.Export.Areas do
  @moduledoc """
  The flex rows of one area service (R12, AC-18).

  `rows/4` is pure: it turns one `GtfsPlanner.Gtfs.FlexService`, its areas with
  the GeoJSON the export derived, a calendars map
  (`%{service_id => %{name, plural}}`, the shape `GtfsPlanner.Gtfs.Flex.RiderText`
  reads) and the version's agency ID into the maps the flex files append, keyed
  by GTFS column atoms so `GtfsPlanner.Gtfs.Export.CsvWriter.write_row/4`
  resolves them.

  R12 splits each calendar's day at every hours-row boundary: the elementary
  intervals between those boundaries each carry the set of in-service areas, and
  every interval with at least one area becomes a trip. Trip A boards in each
  area in position order and lets riders off in each area, plus the connecting
  stops group when the service has one; trip B, only with connecting stops,
  boards at the group and lets riders off in each area. Riders can therefore
  travel within and between areas and between an area and the connecting stops,
  and never between two connecting stops.

  Every row is windowed (`HH:MM:SS`, with an end at or before the start exported
  as 24:00:00 or later, R6) and carries 2 on the side that is available and 1 on
  the side that is not, with the calendar's booking rule on that side. IDs are
  R11's, derived with `GtfsPlanner.Gtfs.Flex.slugify/1`; the service's areas
  become `locations.geojson` entries whose `stop_name` is the area name, and its
  connecting stops one location group. Nothing here reads or writes the database
  (CR-4), so the caller decides which services are exportable (R4).
  """

  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Values

  @minutes_per_day 1_440

  @typedoc """
  One area of the service with the GeoJSON the export derived for it.
  """
  @type area_input :: %{area: FlexArea.t(), geojson: map()}

  @typedoc """
  The rows of one area service, keyed by the flex file each belongs to.
  """
  @type rows_map :: %{
          routes: [map()],
          trips: [map()],
          stop_times: [map()],
          locations: [map()],
          location_groups: [map()],
          location_group_stops: [map()],
          booking_rules: [map()]
        }

  @doc """
  Returns the routes, trips, stop_times, locations, location groups and booking
  rules of one area service.

  `areas` are the service's areas in any order (the result orders them by
  `position`), each with the GeoJSON its location feature carries. `calendars`
  names the version's calendars for the booking-rule messages, and `agency_id`
  is the version's agency for the generated route.
  """
  @spec rows(FlexService.t(), [area_input()], map(), String.t() | nil) :: rows_map()
  def rows(%FlexService{} = service, areas, calendars, agency_id) do
    areas = areas_in_position_order(areas)
    trips = trips(service, areas)

    %{
      routes: [route_row(service, agency_id)],
      trips: Enum.map(trips, & &1.row),
      stop_times: Enum.flat_map(trips, & &1.stop_times),
      locations: Enum.map(areas, &location_row(service, &1)),
      location_groups: group_rows(service),
      location_group_stops: group_stop_rows(service),
      booking_rules: booking_rule_rows(service, calendars)
    }
  end

  # --- trips ------------------------------------------------------------------

  # Hours rows keep their stored order, so a service's calendars export in the
  # order staff wrote them, then each calendar's intervals by start time.
  defp trips(service, areas) do
    service.hours
    |> hours_by_calendar()
    |> Enum.flat_map(fn {calendar_id, hours} ->
      calendar_trips(service, calendar_id, hours, areas)
    end)
  end

  defp hours_by_calendar(hours) do
    hours
    |> Enum.map(& &1.service_id)
    |> Enum.uniq()
    |> Enum.map(fn service_id ->
      {service_id, Enum.filter(hours, &(&1.service_id == service_id))}
    end)
  end

  defp calendar_trips(service, calendar_id, hours, areas) do
    rule_id = calendar_rule_id(service, calendar_id)

    hours
    |> intervals()
    |> Enum.flat_map(fn interval ->
      interval_trips(service, calendar_id, areas, hours, rule_id, interval)
    end)
  end

  defp interval_trips(service, calendar_id, areas, hours, rule_id, interval) do
    case in_service_areas(areas, hours, interval) do
      [] ->
        []

      in_service ->
        trip_a(service, calendar_id, in_service, rule_id, interval) ++
          trip_b(service, calendar_id, in_service, rule_id, interval)
    end
  end

  # R12: board in each area, then let riders off in each area and at the
  # connecting stops.
  defp trip_a(service, calendar_id, areas, rule_id, interval) do
    trip_id = trip_id(service, calendar_id, interval)

    rows =
      Enum.map(areas, &pickup_row(trip_id, location(service, &1), rule_id, interval)) ++
        Enum.map(areas, &drop_off_row(trip_id, location(service, &1), rule_id, interval)) ++
        group_drop_off(service, trip_id, rule_id, interval)

    [%{row: trip_row(service, calendar_id, trip_id), stop_times: sequence(rows)}]
  end

  # R12: board at the connecting stops, then let riders off in each area. No
  # group drop-off, so riders cannot travel from one connecting stop to another.
  defp trip_b(%FlexService{hub_stop_ids: []}, _calendar_id, _areas, _rule_id, _interval), do: []

  defp trip_b(service, calendar_id, areas, rule_id, interval) do
    trip_id = trip_id(service, calendar_id, interval) <> "-from-stops"

    rows =
      [pickup_row(trip_id, group(service), rule_id, interval)] ++
        Enum.map(areas, &drop_off_row(trip_id, location(service, &1), rule_id, interval))

    [%{row: trip_row(service, calendar_id, trip_id), stop_times: sequence(rows)}]
  end

  defp group_drop_off(%FlexService{hub_stop_ids: []}, _trip_id, _rule_id, _interval), do: []

  defp group_drop_off(service, trip_id, rule_id, interval),
    do: [drop_off_row(trip_id, group(service), rule_id, interval)]

  # A trip's rows are numbered in the order riders meet them.
  defp sequence(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, stop_sequence} -> %{row | stop_sequence: stop_sequence} end)
  end

  # --- intervals --------------------------------------------------------------

  # Every hours row contributes its start and its end (the next day for an end
  # at or before the start); the sorted, unique boundaries delimit the
  # elementary intervals each with one set of in-service areas (R12).
  defp intervals(hours) do
    hours
    |> Enum.flat_map(&boundaries/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [start_minutes, finish_minutes] -> {start_minutes, finish_minutes} end)
  end

  defp boundaries(row) do
    case window(row) do
      nil -> []
      {start_minutes, finish_minutes} -> [start_minutes, finish_minutes]
    end
  end

  # A row with no area covers every area of the service (R6), and a row covers
  # an elementary interval when its window spans it.
  defp in_service_areas(areas, hours, interval) do
    Enum.filter(areas, fn %{area: area} -> Enum.any?(hours, &covers?(&1, area.key, interval)) end)
  end

  defp covers?(row, area_key, {start_minutes, finish_minutes}) do
    row.area_key in [nil, "", area_key] and
      covered_window?(window(row), start_minutes, finish_minutes)
  end

  defp covered_window?(nil, _start_minutes, _finish_minutes), do: false

  defp covered_window?({row_start, row_finish}, start_minutes, finish_minutes),
    do: row_start <= start_minutes and finish_minutes <= row_finish

  # An hours row as [start, finish) in minutes from midnight, with an end at or
  # before the start taken as the next day (R6). A row without both times is not
  # a window.
  defp window(row) do
    with start_minutes when is_integer(start_minutes) <- minutes_of(row.start),
         finish_minutes when is_integer(finish_minutes) <- minutes_of(row.end) do
      if finish_minutes <= start_minutes do
        {start_minutes, finish_minutes + @minutes_per_day}
      else
        {start_minutes, finish_minutes}
      end
    end
  end

  defp minutes_of(time) when is_binary(time) do
    with [hours, minutes] <- String.split(time, ":"),
         {hours, ""} <- Integer.parse(hours),
         {minutes, ""} <- Integer.parse(minutes) do
      hours * 60 + minutes
    else
      _other -> nil
    end
  end

  defp minutes_of(_time), do: nil

  # --- rows -------------------------------------------------------------------

  defp trip_row(service, calendar_id, trip_id) do
    %{route_id: route_id(service), service_id: calendar_id, trip_id: trip_id}
  end

  defp pickup_row(trip_id, place, rule_id, interval) do
    stop_time_row(trip_id, place, interval, 2, 1, %{
      pickup_booking_rule_id: rule_id,
      drop_off_booking_rule_id: nil
    })
  end

  defp drop_off_row(trip_id, place, rule_id, interval) do
    stop_time_row(trip_id, place, interval, 1, 2, %{
      pickup_booking_rule_id: nil,
      drop_off_booking_rule_id: rule_id
    })
  end

  defp stop_time_row(trip_id, place, interval, pickup_type, drop_off_type, rules) do
    {start_minutes, finish_minutes} = interval

    %{
      trip_id: trip_id,
      arrival_time: nil,
      departure_time: nil,
      stop_id: nil,
      location_group_id: place.location_group_id,
      location_id: place.location_id,
      stop_sequence: nil,
      start_pickup_drop_off_window: window_time(start_minutes),
      end_pickup_drop_off_window: window_time(finish_minutes),
      pickup_type: pickup_type,
      drop_off_type: drop_off_type,
      pickup_booking_rule_id: rules.pickup_booking_rule_id,
      drop_off_booking_rule_id: rules.drop_off_booking_rule_id
    }
  end

  defp location(service, %{area: area}) do
    %{location_id: location_id(service, area), location_group_id: nil}
  end

  defp group(service), do: %{location_id: nil, location_group_id: group_id(service)}

  defp route_row(service, agency_id) do
    %{
      route_id: route_id(service),
      agency_id: agency_id,
      route_long_name: RiderText.rider_name(service),
      route_type: 3
    }
  end

  defp location_row(service, %{area: area, geojson: geojson}) do
    %{id: location_id(service, area), stop_name: area.name, geometry: geojson}
  end

  defp group_rows(%FlexService{hub_stop_ids: []}), do: []

  defp group_rows(service) do
    [
      %{
        location_group_id: group_id(service),
        location_group_name: "#{service.name} connecting stops"
      }
    ]
  end

  defp group_stop_rows(%FlexService{hub_stop_ids: []}), do: []

  defp group_stop_rows(service) do
    Enum.map(service.hub_stop_ids, fn stop_id ->
      %{location_group_id: group_id(service), stop_id: stop_id}
    end)
  end

  # --- booking rules ----------------------------------------------------------

  @doc """
  The service's booking rules as the GTFS `booking_rules.txt` columns.

  `rows/4` appends these after its trips; the export also uses them for a
  detour service, whose own module writes no booking-rule row but whose zone
  rows reference the service's one rule (R7, AC-19). `calendars` is the map
  `GtfsPlanner.Gtfs.Flex.RiderText` reads for the message.
  """
  @spec booking_rule_rows(FlexService.t(), map()) :: [map()]
  def booking_rule_rows(service, calendars) do
    Enum.map(service.booking_rules, &booking_rule_row(service, &1, calendars))
  end

  # R7's fields as the GTFS booking_rules.txt columns. A real-time rule carries
  # no prior-notice field (the optional horizon lives in the message), a
  # same-day rule a minimum and optional maximum duration, and an earlier-day
  # rule the last day and time, an optional start day (midnight) and the
  # office-days calendar.
  defp booking_rule_row(service, %FlexBookingRule{} = rule, calendars) do
    %{
      booking_rule_id: rule_id(service, rule),
      booking_type: booking_type(rule.when),
      prior_notice_duration_min: prior_notice_duration_min(rule),
      prior_notice_duration_max: prior_notice_duration_max(rule),
      prior_notice_last_day: prior_notice_last_day(rule),
      prior_notice_last_time: prior_notice_last_time(rule),
      prior_notice_start_day: prior_notice_start_day(rule),
      prior_notice_start_time: prior_notice_start_time(rule),
      prior_notice_service_id: prior_notice_service_id(rule),
      message: RiderText.message(service, calendars),
      phone_number: service.phone,
      info_url: service.info_url,
      booking_url: service.booking_url
    }
  end

  defp booking_type(:now), do: 0
  defp booking_type(:same_day), do: 1
  defp booking_type(:earlier_day), do: 2
  defp booking_type(_when), do: nil

  defp prior_notice_duration_min(%FlexBookingRule{when: :same_day, minutes: minutes}),
    do: minutes

  defp prior_notice_duration_min(%FlexBookingRule{}), do: nil

  defp prior_notice_duration_max(%FlexBookingRule{when: :same_day, max_days: max_days})
       when is_integer(max_days),
       do: max_days * @minutes_per_day

  defp prior_notice_duration_max(%FlexBookingRule{}), do: nil

  defp prior_notice_last_day(%FlexBookingRule{when: :earlier_day, days: days}), do: days
  defp prior_notice_last_day(%FlexBookingRule{}), do: nil

  defp prior_notice_last_time(%FlexBookingRule{when: :earlier_day, by: by}),
    do: window_time_from_time(by)

  defp prior_notice_last_time(%FlexBookingRule{}), do: nil

  defp prior_notice_start_day(%FlexBookingRule{when: :earlier_day, max_days: max_days}),
    do: max_days

  defp prior_notice_start_day(%FlexBookingRule{}), do: nil

  defp prior_notice_start_time(%FlexBookingRule{when: :earlier_day, max_days: max_days})
       when is_integer(max_days),
       do: "00:00:00"

  defp prior_notice_start_time(%FlexBookingRule{}), do: nil

  defp prior_notice_service_id(%FlexBookingRule{
         when: :earlier_day,
         business_days: true,
         office_service_id: office_service_id
       }),
       do: office_service_id

  defp prior_notice_service_id(%FlexBookingRule{}), do: nil

  # The calendar's own rule wins over the service-wide one; a calendar without
  # either references no rule.
  defp calendar_rule_id(service, calendar_id) do
    case scoped_rule(service, calendar_id) || main_rule(service) do
      nil -> nil
      rule -> rule_id(service, rule)
    end
  end

  defp scoped_rule(service, calendar_id) when is_binary(calendar_id) and calendar_id != "" do
    Enum.find(service.booking_rules, &(&1.service_id == calendar_id))
  end

  defp scoped_rule(_service, _calendar_id), do: nil

  defp main_rule(service),
    do: Enum.find(service.booking_rules, &(not Values.present?(&1.service_id)))

  defp rule_id(service, %FlexBookingRule{service_id: calendar_id})
       when is_binary(calendar_id) and calendar_id != "" do
    "flex-#{service.key}-book-#{Flex.slugify(calendar_id)}"
  end

  defp rule_id(service, %FlexBookingRule{}), do: "flex-#{service.key}-book"

  # --- identifiers ------------------------------------------------------------

  @doc """
  R11's location ID for one area: `flex-<key>-a<position>`.

  `rows/4` uses it for the GeoJSON feature's own ID and the service page's
  export-details plan uses it to name the planned row before the row exists.
  """
  @spec location_id(FlexService.t(), FlexArea.t()) :: String.t()
  def location_id(service, area), do: "flex-#{service.key}-a#{area.position}"

  defp route_id(service), do: "flex-#{service.key}"

  defp group_id(service), do: "flex-#{service.key}-stops"

  defp trip_id(service, calendar_id, {start_minutes, _finish_minutes}) do
    "flex-#{service.key}-#{Flex.slugify(calendar_id)}-#{hhmm(start_minutes)}"
  end

  # --- values -----------------------------------------------------------------

  defp window_time_from_time(time) do
    case minutes_of(time) do
      nil -> nil
      minutes -> window_time(minutes)
    end
  end

  # A GTFS time, with an end past midnight as 24:00:00 or later (R6).
  defp window_time(minutes), do: "#{pad(div(minutes, 60))}:#{pad(rem(minutes, 60))}:00"

  defp hhmm(minutes), do: "#{pad(div(minutes, 60))}#{pad(rem(minutes, 60))}"

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp areas_in_position_order(areas) do
    Enum.sort_by(areas, fn %{area: area} -> {area.position || 0, area.key || ""} end)
  end
end
