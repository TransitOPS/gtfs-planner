defmodule GtfsPlanner.Gtfs.ReleaseComparison.Projection do
  @max_templates 20_000

  @moduledoc """
  Projects the verified rows of one retained native full-main export artifact
  into the immutable native inputs the comparison consumes.

  `build/1` takes exactly what `GtfsPlanner.Gtfs.ReleaseComparison.Reader.read/2`
  returns: the admitted artifact identity and the parsed tables, each row still
  carrying its physical CSV row number. It reads no file, calls no repository
  and never sees the live version, so the projection can only describe the
  selected bytes. The reader's tables are preserved unchanged in `:tables`, so
  every finding stays referenced back to the evidence it came from.

  The projection is deliberately explicit about what it cannot evaluate:

    * A service that appears only in `calendar_dates.txt` has a `nil` calendar
      and its `CalendarDate` additions, which is the native dates-only service.
    * A service whose weekly row or date exception is malformed carries no
      calendar entry at all and an entry in `:unknowns`. Absence is not the
      dates-only `nil`: a caller must treat a service named by a `calendar.txt` or
      `calendar_dates.txt` unknown as not evaluable rather than as a service with
      no weekly service.
    * Route, stop and trip identifiers are indexed once. A repeated identifier
      keeps the first row and discloses the later one, so a duplicate can never
      overwrite evidence or make a feed look complete.
    * A route's timezone is its agency's timezone. A blank `agency_id` resolves
      only when the artifact holds exactly one agency; any other ambiguity or a
      dangling reference is unknown rather than a guess, because an unknown
      timezone suppresses aligned timing claims instead of producing a false one.
    * A `stop_times.txt` row naming a stop the artifact does not define - a Flex
      location group member, for example - stays in the ordered occurrences with
      its raw identifier and an unknown, so a Flex reference is disclosed as
      unevaluable instead of silently becoming a resolvable stop.
    * Frequencies stay in their own list, unscheduled against the trips, and each
      entry keeps its own source reference.

  More than #{@max_templates} frequency templates refuses the whole artifact as
  `{:error, :unsupported_size}`; a bound is never met by trimming rows.

  ## Estimation

  The native export fills missing stop times silently, so the projection records
  only what the artifact identity already proved: `:estimation` is
  `%{possible: boolean, method: atom() | nil}`, an artifact-level statement that
  exported times may include estimates. No row claims to know which values were
  filled, and nothing here reads the live version to reconstruct the originals.
  """

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.GtfsTime

  @weekday_fields [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]
  @date_pattern ~r/\A[0-9]{8}\z/
  @integer_pattern ~r/\A-?[0-9]+\z/
  @agency_file "agency.txt"
  @routes_file "routes.txt"
  @stops_file "stops.txt"
  @trips_file "trips.txt"
  @stop_times_file "stop_times.txt"
  @calendar_file "calendar.txt"
  @calendar_dates_file "calendar_dates.txt"
  @frequencies_file "frequencies.txt"

  @typedoc """
  One disclosed defect, located in the selected bytes it came from.

  `entity_id` is the identifier the defect is about and `nil` when the row names
  none, so a row-level fault is never attributed to an unrelated entity.
  """
  @type unknown :: %{
          required(:file) => String.t(),
          required(:row) => pos_integer(),
          required(:entity_id) => String.t() | nil,
          required(:field) => String.t(),
          required(:reason) => atom()
        }

  @type source_ref :: %{required(:file) => String.t(), required(:row) => pos_integer()}

  @type projection :: %{
          required(:identity) => map(),
          required(:tables) => %{String.t() => [map()]},
          required(:estimation) => %{
            required(:possible) => boolean(),
            required(:method) => atom() | nil
          },
          required(:agencies) => %{String.t() => map()},
          required(:routes) => %{String.t() => map()},
          required(:stops) => %{String.t() => map()},
          required(:trips) => %{String.t() => map()},
          required(:stop_occurrences) => %{String.t() => [map()]},
          required(:calendars) => %{String.t() => Calendar.t() | nil},
          required(:exceptions) => %{String.t() => [CalendarDate.t()]},
          required(:frequencies) => [map()],
          required(:unknowns) => [unknown()]
        }

  @doc """
  Projects one reader result into the native comparison inputs, or refuses it.

  The only refusal is `{:error, :unsupported_size}`, returned when the artifact
  holds more frequency templates than the fixed bound allows. A refusal is never
  a trimmed projection.
  """
  @spec build(map()) :: {:ok, projection()} | {:error, :unsupported_size}
  def build(%{tables: tables, identity: identity}) when is_map(tables) and is_map(identity) do
    with {agencies, agency_unknowns} <- project_agencies(rows(tables, @agency_file)),
         {routes, route_unknowns} <- project_routes(rows(tables, @routes_file), agencies),
         {stops, stop_unknowns} <- project_stops(rows(tables, @stops_file)),
         {defined_services, exceptions, calendar_unknowns} <- project_calendars(tables),
         {trips, trip_unknowns} <-
           project_trips(rows(tables, @trips_file), routes, defined_services, exceptions),
         {occurrences, occurrence_unknowns} <-
           project_occurrences(rows(tables, @stop_times_file), stops),
         {:ok, frequencies, frequency_unknowns} <-
           project_frequencies(rows(tables, @frequencies_file), trips) do
      {:ok,
       %{
         identity: identity,
         tables: tables,
         estimation: estimation(identity),
         agencies: agencies,
         routes: routes,
         stops: stops,
         trips: trips,
         stop_occurrences: occurrences,
         calendars: calendars(defined_services, trips),
         exceptions: exceptions,
         frequencies: frequencies,
         unknowns:
           sort_unknowns(
             agency_unknowns ++
               route_unknowns ++
               stop_unknowns ++
               trip_unknowns ++
               occurrence_unknowns ++
               calendar_unknowns ++
               frequency_unknowns
           )
       }}
    end
  end

  def build(_reader_output), do: {:error, :unsupported_size}

  # -- agencies ---------------------------------------------------------------

  # A single agency may carry a blank `agency_id`, which GTFS uses for a
  # one-agency feed; two blank agencies are indistinguishable, so neither is
  # indexed and both are disclosed.
  defp project_agencies(rows) do
    single = length(rows) == 1

    Enum.reduce(rows, {%{}, []}, fn %{row: row, fields: fields}, {index, unknowns} ->
      id = value(fields, "agency_id")
      timezone = value(fields, "agency_timezone")

      row_unknowns =
        []
        |> prepend_if(id == "" and not single, fn ->
          unknown(@agency_file, row, nil, "agency_id", :blank_agency_id)
        end)
        |> prepend_if(timezone == "", fn ->
          unknown(@agency_file, row, blank_to_nil(id), "agency_timezone", :blank_timezone)
        end)

      if id == "" and not single do
        {index, row_unknowns ++ unknowns}
      else
        agency = %{
          agency_id: id,
          name: value(fields, "agency_name"),
          url: value(fields, "agency_url"),
          timezone: blank_to_nil(timezone),
          source: source(@agency_file, row)
        }

        duplicate = unknown(@agency_file, row, blank_to_nil(id), "agency_id", :duplicate_id)

        insert_unique(index, id, agency, duplicate, row_unknowns ++ unknowns)
      end
    end)
  end

  # -- routes -----------------------------------------------------------------

  defp project_routes(rows, agencies) do
    Enum.reduce(rows, {%{}, []}, fn %{row: row, fields: fields}, {index, unknowns} ->
      id = value(fields, "route_id")
      agency_id = value(fields, "agency_id")
      {route_type, type_unknowns} = parse_integer(fields, "route_type", @routes_file, row, id)
      {timezone, timezone_unknowns} = resolve_timezone(agency_id, agencies, row, id)

      if id == "" do
        {index, [unknown(@routes_file, row, nil, "route_id", :missing_id) | unknowns]}
      else
        route = %{
          route_id: id,
          agency_id: agency_id,
          short_name: value(fields, "route_short_name"),
          long_name: value(fields, "route_long_name"),
          route_type: route_type,
          timezone: timezone,
          timezone_known?: not is_nil(timezone),
          source: source(@routes_file, row)
        }

        duplicate = unknown(@routes_file, row, id, "route_id", :duplicate_id)

        insert_unique(index, id, route, duplicate, type_unknowns ++ timezone_unknowns ++ unknowns)
      end
    end)
  end

  # A route's timezone is its agency's. Exactly one agency may stand in for a
  # blank `agency_id`; any other ambiguity or a dangling reference is unknown.
  defp resolve_timezone("", agencies, row, id) do
    case Map.values(agencies) do
      [agency] -> {agency.timezone, []}
      _ambiguous -> {nil, [unknown(@routes_file, row, id, "agency_id", :ambiguous_agency)]}
    end
  end

  defp resolve_timezone(agency_id, agencies, row, id) do
    case Map.fetch(agencies, agency_id) do
      {:ok, %{timezone: timezone}} -> {timezone, []}
      :error -> {nil, [unknown(@routes_file, row, id, "agency_id", :unknown_agency)]}
    end
  end

  # -- stops ------------------------------------------------------------------

  defp project_stops(rows) do
    Enum.reduce(rows, {%{}, []}, fn %{row: row, fields: fields}, {index, unknowns} ->
      id = value(fields, "stop_id")
      {lat, lat_unknowns} = parse_decimal(fields, "stop_lat", @stops_file, row, id)
      {lon, lon_unknowns} = parse_decimal(fields, "stop_lon", @stops_file, row, id)

      {location_type, type_unknowns} =
        parse_integer(fields, "location_type", @stops_file, row, id)

      field_unknowns = lat_unknowns ++ lon_unknowns ++ type_unknowns

      if id == "" do
        missing = unknown(@stops_file, row, nil, "stop_id", :missing_id)
        {index, field_unknowns ++ [missing | unknowns]}
      else
        stop = %{
          stop_id: id,
          name: value(fields, "stop_name"),
          lat: lat,
          lon: lon,
          location_type: location_type,
          parent_station: value(fields, "parent_station"),
          source: source(@stops_file, row)
        }

        duplicate = unknown(@stops_file, row, id, "stop_id", :duplicate_id)

        insert_unique(index, id, stop, duplicate, field_unknowns ++ unknowns)
      end
    end)
  end

  # -- trips ------------------------------------------------------------------

  # A trip stays indexed even when its route or service is unknown, so the
  # dangling reference remains visible to every later step instead of
  # disappearing into a service that looks like it has no dates.
  defp project_trips(rows, routes, calendars, exceptions) do
    Enum.reduce(rows, {%{}, []}, fn row, acc ->
      keep_trip(row, routes, calendars, exceptions, acc)
    end)
  end

  defp keep_trip(%{row: row, fields: fields}, routes, calendars, exceptions, {index, unknowns}) do
    id = value(fields, "trip_id")
    route_id = value(fields, "route_id")
    service_id = value(fields, "service_id")
    {direction_id, direction_unknowns} = parse_direction(fields, row, id)

    reference_unknowns =
      trip_reference_unknowns(row, id, route_id, service_id, routes, calendars, exceptions)

    if id == "" do
      {index, direction_unknowns ++ reference_unknowns ++ unknowns}
    else
      trip = %{
        trip_id: id,
        route_id: route_id,
        service_id: service_id,
        direction_id: direction_id,
        headsign: value(fields, "trip_headsign"),
        source: source(@trips_file, row)
      }

      duplicate = unknown(@trips_file, row, id, "trip_id", :duplicate_id)

      insert_unique(
        index,
        id,
        trip,
        duplicate,
        direction_unknowns ++ reference_unknowns ++ unknowns
      )
    end
  end

  # Every reference a trip names must exist somewhere in the artifact, or the
  # row stays indexed and the gap is disclosed instead of being resolved.
  defp trip_reference_unknowns(row, id, route_id, service_id, routes, calendars, exceptions) do
    named = id != ""

    []
    |> prepend_if(not named, fn -> unknown(@trips_file, row, nil, "trip_id", :missing_id) end)
    |> prepend_if(named and route_id == "", fn ->
      unknown(@trips_file, row, id, "route_id", :missing_id)
    end)
    |> prepend_if(named and route_id != "" and not Map.has_key?(routes, route_id), fn ->
      unknown(@trips_file, row, id, "route_id", :unknown_route)
    end)
    |> prepend_if(named and route_id != "" and service_id == "", fn ->
      unknown(@trips_file, row, id, "service_id", :missing_id)
    end)
    |> prepend_if(
      named and service_id != "" and not service_described?(service_id, calendars, exceptions),
      fn ->
        unknown(@trips_file, row, id, "service_id", :unknown_service)
      end
    )
  end

  defp service_described?(service_id, calendars, exceptions) do
    Map.has_key?(calendars, service_id) or Map.has_key?(exceptions, service_id)
  end

  defp parse_direction(fields, row, id) do
    case value(fields, "direction_id") do
      "" -> {nil, []}
      "0" -> {0, []}
      "1" -> {1, []}
      _other -> {nil, [unknown(@trips_file, row, id, "direction_id", :invalid_integer)]}
    end
  end

  # -- stop occurrences -------------------------------------------------------

  # A `stop_times.txt` row for an undefined trip is not indexed, because no
  # projection entity could ever carry it; every other row keeps its raw
  # identifiers so an unresolvable stop stays ordered and visible.
  defp project_occurrences(rows, stops) do
    {groups, unknowns} =
      Enum.reduce(rows, {%{}, []}, fn %{row: row, fields: fields}, {groups, unknowns} ->
        trip_id = value(fields, "trip_id")
        stop_id = value(fields, "stop_id")
        {sequence, sequence_unknowns} = parse_sequence(fields, row, trip_id)
        {arrival, arrival_unknowns} = parse_stop_time(fields, "arrival_time", row, trip_id)
        {departure, departure_unknowns} = parse_stop_time(fields, "departure_time", row, trip_id)

        row_unknowns =
          []
          |> prepend_if(trip_id == "", fn ->
            unknown(@stop_times_file, row, nil, "trip_id", :missing_id)
          end)
          |> prepend_if(trip_id != "" and stop_id == "", fn ->
            unknown(@stop_times_file, row, trip_id, "stop_id", :missing_id)
          end)
          |> prepend_if(
            trip_id != "" and stop_id != "" and not Map.has_key?(stops, stop_id),
            fn -> unknown(@stop_times_file, row, trip_id, "stop_id", :unknown_stop) end
          )

        occurrence = %{
          sequence: sequence,
          stop_id: stop_id,
          arrival_secs: arrival,
          departure_secs: departure,
          arrival_time: value(fields, "arrival_time"),
          departure_time: value(fields, "departure_time"),
          source: source(@stop_times_file, row)
        }

        row_unknowns = sequence_unknowns ++ arrival_unknowns ++ departure_unknowns ++ row_unknowns

        if trip_id == "" do
          {groups, row_unknowns ++ unknowns}
        else
          {Map.update(groups, trip_id, [occurrence], &(&1 ++ [occurrence])),
           row_unknowns ++ unknowns}
        end
      end)

    {ordered, order_unknowns} = order_occurrences(groups)

    {ordered, order_unknowns ++ unknowns}
  end

  # Loops keep every repeated stop identifier; only the numeric sequence orders
  # them, and a repeated sequence is disclosed rather than collapsed, because
  # dropping either occurrence would invent a pattern.
  defp order_occurrences(groups) do
    Enum.reduce(groups, {%{}, []}, fn {trip_id, occurrences}, {ordered, unknowns} ->
      {rows, group_unknowns} = disclose_repeated_sequences(occurrences, [])

      {Map.put(ordered, trip_id, Enum.sort_by(rows, &occurrence_order/1)),
       group_unknowns ++ unknowns}
    end)
  end

  # An occurrence with no readable sequence sorts after every sequenced one, and
  # the physical row keeps the order deterministic inside a repeated sequence.
  defp occurrence_order(occurrence) do
    {if(is_nil(occurrence.sequence), do: 1, else: 0), occurrence.sequence || 0,
     occurrence.source.row}
  end

  defp disclose_repeated_sequences(occurrences, unknowns) do
    {rows, _seen, unknowns} =
      Enum.reduce(occurrences, {[], MapSet.new(), unknowns}, &keep_occurrence/2)

    {Enum.reverse(rows), unknowns}
  end

  defp keep_occurrence(occurrence, {rows, seen, unknowns}) do
    case occurrence.sequence do
      nil ->
        {[occurrence | rows], seen, unknowns}

      sequence ->
        if MapSet.member?(seen, sequence) do
          {[occurrence | rows], seen, [repeated_sequence(occurrence) | unknowns]}
        else
          {[occurrence | rows], MapSet.put(seen, sequence), unknowns}
        end
    end
  end

  defp repeated_sequence(occurrence) do
    unknown(
      @stop_times_file,
      occurrence.source.row,
      occurrence.stop_id,
      "stop_sequence",
      :duplicate_sequence
    )
  end

  # -- calendars and exceptions ------------------------------------------------

  defp project_calendars(tables) do
    {weekly, weekly_unknowns} = project_weekly(rows(tables, @calendar_file))
    {exceptions, exception_unknowns} = project_exceptions(rows(tables, @calendar_dates_file))

    # Only the services a calendar table actually defines are complete here. A
    # service named solely by a trip is disclosed by `project_trips/4` and added
    # by `calendars/2` as an explicitly undefined service.
    defined = weekly

    {defined, exceptions, weekly_unknowns ++ exception_unknowns}
  end

  # A service no calendar table defines still gets a `nil` calendar, so it reads
  # as a service with no weekly row rather than as one that is not in the
  # artifact at all; its `:unknown_service` unknown is what says the artifact
  # never described it.
  defp calendars(defined_services, trips) do
    trip_services =
      trips
      |> Map.values()
      |> Enum.map(& &1.service_id)
      |> Enum.reject(&(&1 == ""))

    defined_services
    |> Map.merge(Map.new(trip_services, &{&1, nil}), fn _id, defined, _absent -> defined end)
  end

  defp project_weekly(rows) do
    Enum.reduce(rows, {%{}, []}, fn %{row: row, fields: fields}, {index, unknowns} ->
      service_id = value(fields, "service_id")
      {weekdays, weekday_unknowns} = weekday_flags(fields, row, service_id)
      {start_date, start_unknowns} = parse_calendar_date(fields, "start_date", row, service_id)
      {end_date, end_unknowns} = parse_calendar_date(fields, "end_date", row, service_id)
      range_unknowns = ordered_range(start_date, end_date, row, service_id)
      row_unknowns = weekday_unknowns ++ start_unknowns ++ end_unknowns ++ range_unknowns

      cond do
        service_id == "" ->
          {index,
           row_unknowns ++
             [unknown(@calendar_file, row, nil, "service_id", :missing_id) | unknowns]}

        row_unknowns != [] ->
          # A malformed weekly row is not a dates-only service: the service
          # keeps no calendar entry and stays disclosed as unknown instead.
          {index, row_unknowns ++ unknowns}

        true ->
          calendar = weekly_calendar(service_id, weekdays, start_date, end_date, row)
          duplicate = unknown(@calendar_file, row, service_id, "service_id", :duplicate_id)

          insert_unique(index, service_id, calendar, duplicate, unknowns)
      end
    end)
  end

  # The native struct keeps its own shape for `ServiceDates`, and the physical
  # row it came from is carried beside it as a plain key.
  defp weekly_calendar(service_id, weekdays, start_date, end_date, row) do
    Map.put(
      struct!(
        Calendar,
        [service_id: service_id] ++
          Enum.map(weekdays, fn {field, flag} -> {field, flag} end) ++
          [start_date: start_date, end_date: end_date]
      ),
      :source,
      source(@calendar_file, row)
    )
  end

  defp weekday_flags(fields, row, service_id) do
    Enum.reduce(@weekday_fields, {%{}, []}, fn field, {flags, unknowns} ->
      case value(fields, Atom.to_string(field)) do
        "0" ->
          {Map.put(flags, field, 0), unknowns}

        "1" ->
          {Map.put(flags, field, 1), unknowns}

        _other ->
          {flags,
           unknowns ++
             [unknown(@calendar_file, row, service_id, Atom.to_string(field), :invalid_weekday)]}
      end
    end)
  end

  defp ordered_range(%Date{} = first, %Date{} = last, row, service_id) do
    if Date.compare(first, last) == :gt do
      [unknown(@calendar_file, row, service_id, "end_date", :reversed_date_range)]
    else
      []
    end
  end

  defp ordered_range(_first, _last, _row, _service_id), do: []

  # One date may carry one exception: a repeated service-date pair is disclosed
  # and the first row kept, so a contradiction never reaches native evaluation
  # as if the two types agreed.
  defp project_exceptions(rows) do
    Enum.reduce(rows, {%{}, [], MapSet.new()}, fn %{row: row, fields: fields},
                                                  {index, unknowns, seen} ->
      service_id = value(fields, "service_id")
      {date, date_unknowns} = parse_calendar_date(fields, "date", row, service_id)
      {exception_type, type_unknowns} = parse_exception_type(fields, row, service_id)
      row_unknowns = date_unknowns ++ type_unknowns

      cond do
        service_id == "" ->
          {index,
           row_unknowns ++
             [unknown(@calendar_dates_file, row, nil, "service_id", :missing_id) | unknowns],
           seen}

        row_unknowns != [] ->
          {index, row_unknowns ++ unknowns, seen}

        MapSet.member?(seen, {service_id, date}) ->
          {index,
           [
             unknown(@calendar_dates_file, row, service_id, "date", :duplicate_service_date)
             | unknowns
           ], seen}

        true ->
          # The native struct keeps its own shape for `ServiceDates`, and the
          # physical row it came from is carried beside it as a plain key.
          exception =
            Map.put(
              struct!(CalendarDate,
                service_id: service_id,
                date: date,
                exception_type: exception_type
              ),
              :source,
              source(@calendar_dates_file, row)
            )

          {Map.update(index, service_id, [exception], &(&1 ++ [exception])), unknowns,
           MapSet.put(seen, {service_id, date})}
      end
    end)
    |> then(fn {index, unknowns, _seen} -> {sort_exceptions(index), unknowns} end)
  end

  defp sort_exceptions(index) do
    Map.new(index, fn {service_id, exceptions} ->
      {service_id, Enum.sort_by(exceptions, & &1.date, Date)}
    end)
  end

  # -- frequencies ------------------------------------------------------------

  # Frequencies stay separate from the trips: whether a template expands to exact
  # departures is the native evaluation's rule, and the template count is bounded
  # here so an oversized artifact refuses instead of being trimmed.
  defp project_frequencies(rows, trips) do
    if length(rows) > @max_templates do
      {:error, :unsupported_size}
    else
      {frequencies, unknowns} =
        Enum.reduce(rows, {[], []}, fn row, acc -> keep_frequency(row, trips, acc) end)

      {:ok, frequencies, unknowns}
    end
  end

  defp keep_frequency(%{row: row, fields: fields}, trips, {entries, unknowns}) do
    trip_id = value(fields, "trip_id")
    {start_secs, start_unknowns} = parse_frequency_time(fields, "start_time", row, trip_id)
    {end_secs, end_unknowns} = parse_frequency_time(fields, "end_time", row, trip_id)

    {headway, headway_unknowns} =
      parse_integer(fields, "headway_secs", @frequencies_file, row, trip_id)

    {exact_times, exact_unknowns} = parse_exact_times(fields, row, trip_id)

    row_unknowns =
      []
      |> prepend_if(trip_id == "", fn ->
        unknown(@frequencies_file, row, nil, "trip_id", :missing_id)
      end)
      |> prepend_if(trip_id != "" and not Map.has_key?(trips, trip_id), fn ->
        unknown(@frequencies_file, row, trip_id, "trip_id", :unknown_trip)
      end)
      |> Kernel.++(start_unknowns)
      |> Kernel.++(end_unknowns)
      |> Kernel.++(headway_unknowns)
      |> Kernel.++(exact_unknowns)

    entry = %{
      trip_id: trip_id,
      start_secs: start_secs,
      end_secs: end_secs,
      headway_secs: headway,
      exact_times: exact_times,
      source: source(@frequencies_file, row)
    }

    {entries ++ [entry], row_unknowns ++ unknowns}
  end

  # A blank `exact_times` is the GTFS default of 0: a window, not a departure
  # list. Any other value is unsupported rather than treated as 0 or 1.
  defp parse_exact_times(fields, row, trip_id) do
    case value(fields, "exact_times") do
      "" ->
        {0, []}

      "0" ->
        {0, []}

      "1" ->
        {1, []}

      _other ->
        {nil, [unknown(@frequencies_file, row, trip_id, "exact_times", :unsupported_exact_times)]}
    end
  end

  # -- shared parsing ---------------------------------------------------------

  defp parse_calendar_date(fields, name, row, entity_id) do
    file = if name == "date", do: @calendar_dates_file, else: @calendar_file
    raw = value(fields, name)

    if Regex.match?(@date_pattern, raw) do
      case Date.from_iso8601(iso8601(raw)) do
        {:ok, date} -> {date, []}
        {:error, _reason} -> {nil, [unknown(file, row, entity_id, name, :invalid_date)]}
      end
    else
      {nil, [unknown(file, row, entity_id, name, :invalid_date)]}
    end
  end

  defp iso8601(<<year::binary-size(4), month::binary-size(2), day::binary-size(2)>>) do
    year <> "-" <> month <> "-" <> day
  end

  defp parse_integer(fields, name, file, row, entity_id) do
    case value(fields, name) do
      "" ->
        {nil, []}

      raw ->
        case parse_strict_integer(raw) do
          {:ok, number} -> {number, []}
          :error -> {nil, [unknown(file, row, entity_id, name, :invalid_integer)]}
        end
    end
  end

  defp parse_sequence(fields, row, trip_id) do
    case parse_strict_integer(value(fields, "stop_sequence")) do
      {:ok, number} ->
        {number, []}

      :error ->
        {nil, [unknown(@stop_times_file, row, trip_id, "stop_sequence", :invalid_integer)]}
    end
  end

  defp parse_strict_integer(raw) do
    if Regex.match?(@integer_pattern, raw) do
      case Integer.parse(raw) do
        {number, ""} -> {:ok, number}
        _partial -> :error
      end
    else
      :error
    end
  end

  defp parse_decimal(fields, name, file, row, entity_id) do
    case value(fields, name) do
      "" ->
        {nil, []}

      raw ->
        case Decimal.parse(raw) do
          {decimal, ""} -> {decimal, []}
          _other -> {nil, [unknown(file, row, entity_id, name, :invalid_decimal)]}
        end
    end
  end

  defp parse_stop_time(fields, name, row, trip_id) do
    case value(fields, name) do
      "" ->
        {nil, []}

      raw ->
        case GtfsTime.parse(raw) do
          {:ok, seconds} ->
            {seconds, []}

          {:error, :invalid_time} ->
            {nil, [unknown(@stop_times_file, row, trip_id, name, :invalid_time)]}
        end
    end
  end

  defp parse_frequency_time(fields, name, row, trip_id) do
    case value(fields, name) do
      "" ->
        {nil, []}

      raw ->
        case GtfsTime.parse(raw) do
          {:ok, seconds} ->
            {seconds, []}

          {:error, :invalid_time} ->
            {nil, [unknown(@frequencies_file, row, trip_id, name, :invalid_time)]}
        end
    end
  end

  defp parse_exception_type(fields, row, service_id) do
    case value(fields, "exception_type") do
      "1" ->
        {1, []}

      "2" ->
        {2, []}

      _other ->
        {nil,
         [
           unknown(
             @calendar_dates_file,
             row,
             service_id,
             "exception_type",
             :invalid_exception_type
           )
         ]}
    end
  end

  defp insert_unique(index, key, value, duplicate_unknown, unknowns) do
    if Map.has_key?(index, key) do
      {index, [duplicate_unknown | unknowns]}
    else
      {Map.put(index, key, value), unknowns}
    end
  end

  defp prepend_if(unknowns, true, fun), do: [fun.() | unknowns]
  defp prepend_if(unknowns, false, _fun), do: unknowns

  defp rows(tables, name), do: Map.get(tables, name, [])

  defp value(fields, name) do
    case Map.get(fields, name) do
      nil -> ""
      "" -> ""
      raw when is_binary(raw) -> raw
      other -> to_string(other)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp source(file, row), do: %{file: file, row: row}

  defp unknown(file, row, entity_id, field, reason) do
    %{file: file, row: row, entity_id: entity_id, field: field, reason: reason}
  end

  # A stable order keeps the digest of a later result reproducible regardless of
  # the order the reduce happened to accumulate in.
  defp sort_unknowns(unknowns) do
    Enum.sort_by(unknowns, fn entry ->
      {entry.file, entry.row, entry.field, to_string(entry.reason), entry.entity_id || ""}
    end)
  end

  defp estimation(identity) do
    %{
      possible: Map.get(identity, :estimate_missing_times) == true,
      method: Map.get(identity, :estimate_method)
    }
  end
end
