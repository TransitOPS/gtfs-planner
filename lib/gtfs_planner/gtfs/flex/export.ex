defmodule GtfsPlanner.Gtfs.Flex.Export do
  @moduledoc """
  Flex export entry points.

  `sequence_mapper/2` is R3's only implementation (INV-3): the `stop_sequence`
  of every trip whose route belongs to an active detour service of the version
  is doubled in every profile that writes `stop_times.txt`, whether or not flex
  is included, whether or not the service is ready and whether or not the trip
  gets any zone rows. The zone rows `Flex.Export.Detours` writes take the odd
  value between. Nothing here reads readiness or geometry, so a service with
  errors still keeps the main feed's sequences stable.

  `build_entries/2` is the flex zip's one assembly point and runs inside the
  caller's export snapshot. It loads the version's services, readiness facts,
  calendars and agency, then for every active service:

  1. runs `Flex.Checks.run/3` and leaves the service out on any error (R4);
  2. leaves a registered-riders service out when `include_registered` is false
     and requires its eligibility and info URL when it is true (R5);
  3. derives the area geometry (`Flex.Geometry.get_geojson/1` for stored
     polygons, `route_buffer/4` for route-distance areas, `detour_zones/3` for
     a detour service) and leaves the service out when derivation fails (R4,
     R8);
  4. builds the rows `Flex.Export.Areas.rows/4` or
     `Flex.Export.Detours.rows/4` return, with the detour service's own booking
     rule.

  It answers the rows the flex zip appends to `routes.txt`, `trips.txt` and
  `stop_times.txt`, the extra file entries (`locations.geojson`, the three
  CSVs), the number of services exported and the warnings: one
  `flex_service_excluded` per service left out, the detour rows' own warnings,
  the Transit hold risk (`transit_hold_risk`, AC-25) and
  `main_feed_not_produced` when the version has no routes (R15).

  Both the organization and the version are filters, never defaults (INV-4):
  another organization's or version's detour services never enter the set, so a
  given feed exports the same bytes however its neighbors change.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.CsvWriter
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.Export.Areas
  alias GtfsPlanner.Gtfs.Flex.Export.Detours
  alias GtfsPlanner.Gtfs.Flex.Export.FileSpecs
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # AC-25's Transit hold rule: a feed is held when 75% of its routes, or 25% of
  # its routes with more than 40 trips on their busiest service day, lose every
  # trip. A "frequent" route is one over the 40-trip threshold.
  @hold_route_ratio 0.75
  @hold_frequent_ratio 0.25
  @frequent_trips 40

  @empty_rows %{
    routes: [],
    trips: [],
    stop_times: [],
    locations: [],
    location_groups: [],
    location_group_stops: [],
    booking_rules: []
  }

  @typedoc """
  What `build_entries/2` returns: the rows the flex zip appends per file, the
  extra file entries, the number of services exported and whether the flex zip
  replaces a main feed that was not produced (R15).
  """
  @type entries :: %{
          services: non_neg_integer(),
          main_feed_not_produced: boolean(),
          rows: %{routes: [map()], trips: [map()], stop_times: [map()]},
          entries: [{charlist(), binary()}]
        }

  @doc """
  Returns the function that doubles a stop time's `stop_sequence` when its trip
  runs on a route an active detour service covers.

  The detour routes and the trips on them are read once, when the mapper is
  built, so every row of one export is answered from the same set and the
  caller binds one mapper to one export snapshot. The function accepts a
  `GtfsPlanner.Gtfs.StopTime` or a map with the same keys and returns the same
  shape; a stop time on any other route is returned unchanged.
  """
  @spec sequence_mapper(Ecto.UUID.t(), Ecto.UUID.t()) ::
          (StopTime.t() | map() -> StopTime.t() | map())
  def sequence_mapper(organization_id, version_id) do
    trip_ids = detour_trip_ids(organization_id, version_id)

    fn
      %{trip_id: trip_id} = stop_time ->
        if MapSet.member?(trip_ids, trip_id) do
          %{stop_time | stop_sequence: stop_time.stop_sequence * 2}
        else
          stop_time
        end

      stop_time ->
        stop_time
    end
  end

  @doc """
  Builds the flex rows, extra files and warnings of one version.

  Must run inside the export snapshot: it reads the version's services,
  readiness facts, calendars and geometry through the shared repository
  connection. Returns `{:ok, entries, warnings}`; the caller appends
  `entries.rows` to the flex zip's `routes.txt`, `trips.txt` and
  `stop_times.txt` and writes `entries.entries` as whole files.
  """
  @spec build_entries(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, entries(), [Export.warning()]}
  def build_entries(organization_id, version_id) do
    services = Flex.list_services(organization_id, version_id)
    active = Enum.filter(services, & &1.active)
    facts = Checks.version_facts(organization_id, version_id)

    calendar_rows = calendar_rows(organization_id, version_id)
    exception_rows = calendar_date_rows(organization_id, version_id)
    names = Flex.calendars_map(organization_id, version_id)
    agency_id = agency_id(organization_id, version_id)

    prepared =
      Enum.map(active, fn service ->
        prepare_service(
          service,
          services,
          facts,
          names,
          agency_id,
          organization_id,
          version_id
        )
      end)

    included = Enum.filter(prepared, & &1.included?)
    excluded = Enum.reject(prepared, & &1.included?)

    rows = merge_rows(included)

    main_feed_not_produced =
      included != [] and not version_has_routes?(organization_id, version_id)

    warnings =
      excluded_warnings(excluded) ++
        Enum.flat_map(included, & &1.warnings) ++
        hold_warnings(prepared, calendar_rows, exception_rows, organization_id, version_id) ++
        main_feed_warnings(main_feed_not_produced)

    {:ok,
     %{
       services: length(included),
       main_feed_not_produced: main_feed_not_produced,
       rows: %{routes: rows.routes, trips: rows.trips, stop_times: rows.stop_times},
       entries: extra_entries(rows)
     }, warnings}
  end

  # --- the service page's plan ------------------------------------------------

  @typedoc """
  One planned export row as the service page's export-details drawer lists it:
  the flex file it goes to, its R11 ID and a sentence about what it holds.
  """
  @type plan_row :: %{file: String.t(), id: String.t(), summary: String.t()}

  @typedoc """
  The next export's rows for one service, as the service page shows them: the
  headline the In exports section states, one count per file, the planned rows
  with their R11 IDs, the detour rows' own warnings, and the derived detour
  zones with the area each covers.
  """
  @type plan :: %{
          headline: String.t(),
          counts: [{String.t(), non_neg_integer(), String.t()}],
          rows: [plan_row()],
          warnings: [Export.warning()],
          zones: [%{zone_id: String.t(), stop_a: String.t(), stop_b: String.t(), km2: float()}]
        }

  @doc """
  Previews the rows the next export writes for one service (AC-29).

  The plan is the export's own builders over the service on screen: for an area
  service `Areas.rows/4`, and for a detour service `Geometry.detour_zones/3`,
  the route's trip times and `Detours.rows/4`. `areas` are the service's areas
  as `Areas.rows/4` reads them (`%{area: FlexArea.t(), geojson: map()}`), each
  optionally carrying the `:km2` the caller measured for its summary.

  Nothing here runs readiness or writes: a service whose geometry cannot be
  derived yet plans no zones, and the page decides what its own readiness
  findings mean. The reads are scoped to the organization and version (R10).
  """
  @spec plan(Ecto.UUID.t(), Ecto.UUID.t(), FlexService.t(), [map()]) :: plan()
  def plan(organization_id, version_id, %FlexService{} = service, areas) when is_list(areas) do
    calendars = Flex.calendars_map(organization_id, version_id)

    case service.kind do
      :area -> area_plan(service, areas, calendars, agency_id(organization_id, version_id))
      :detour -> detour_plan(service, organization_id, version_id, calendars)
    end
  end

  defp area_plan(service, areas, calendars, agency_id) do
    rows = Areas.rows(service, areas, calendars, agency_id)

    km2 =
      Map.new(areas, fn input ->
        {Areas.location_id(service, input.area), Map.get(input, :km2)}
      end)

    planned =
      Enum.map(rows.locations, &area_location_row(&1, km2)) ++
        Enum.map(rows.location_groups, &area_group_row(&1, rows.location_group_stops)) ++
        Enum.map(rows.booking_rules, &booking_rule_plan_row/1) ++
        Enum.map(rows.routes, &area_route_row/1) ++
        Enum.map(rows.trips, &area_trip_row(&1, rows.stop_times, calendars))

    %{
      headline: area_headline(rows),
      counts: [
        {"Areas", length(rows.locations), "locations.geojson"},
        {"Stop groups", length(rows.location_groups), "location_groups.txt"},
        {"Booking rules", length(rows.booking_rules), "booking_rules.txt"},
        {"Routes", length(rows.routes), "routes.txt"},
        {"Trips", length(rows.trips), "trips.txt"},
        {"Stop times", length(rows.stop_times), "stop_times.txt"}
      ],
      rows: planned,
      warnings: [],
      zones: []
    }
  end

  defp detour_plan(service, organization_id, version_id, calendars) do
    rules = detour_booking_rules(service, calendars)
    zones = detour_zones_with_area(organization_id, version_id, service)
    {rows, warnings} = detour_rows(service, zones, organization_id, version_id, rules)
    trips = rows.stop_times |> Enum.map(& &1.trip_id) |> Enum.uniq()

    planned =
      Enum.map(zones, &detour_location_row(&1, service)) ++
        Enum.map(rows.booking_rules, &booking_rule_plan_row/1) ++
        Enum.map(rows.stop_times, &detour_stop_time_row/1) ++
        [detour_route_row(service)]

    %{
      headline: detour_headline(service, zones, trips),
      counts: [
        {"Detour areas", length(zones), "locations.geojson"},
        {"Booking rules", length(rows.booking_rules), "booking_rules.txt"},
        {"Route trips changed", length(trips), "trips.txt"},
        {"Stop times added", length(rows.stop_times), "stop_times.txt"}
      ],
      rows: planned,
      warnings: warnings,
      zones: Enum.map(zones, &Map.take(&1, [:zone_id, :stop_a, :stop_b, :km2]))
    }
  end

  # The derived zones with the area each covers, measured through the same
  # `Geometry.stats/3` the editor's own summary uses; a service whose geometry
  # cannot be derived yet has none.
  defp detour_zones_with_area(organization_id, version_id, service) do
    case Geometry.detour_zones(organization_id, version_id, service) do
      {:ok, zones} ->
        Enum.map(zones, fn zone ->
          Map.put(zone, :km2, Geometry.stats(organization_id, version_id, zone.geojson).km2)
        end)

      {:error, _reason} ->
        []
    end
  end

  defp detour_rows(_service, [], _organization_id, _version_id, rules),
    do: {%{@empty_rows | booking_rules: rules}, []}

  defp detour_rows(service, zones, organization_id, version_id, rules) do
    {rows, warnings} =
      Detours.rows(
        service,
        zones,
        detour_trip_times(organization_id, version_id, service.route_id),
        rule_id(rules, service)
      )

    {%{
       @empty_rows
       | stop_times: rows.stop_times,
         locations: rows.locations,
         booking_rules: rules
     }, warnings}
  end

  # --- the plan's sentences ---------------------------------------------------

  defp area_headline(rows) do
    "Adds #{length(rows.locations)} #{plural(length(rows.locations), "area")}, " <>
      "#{length(rows.trips)} flex #{plural(length(rows.trips), "trip")} and " <>
      "#{length(rows.booking_rules)} #{plural(length(rows.booking_rules), "booking rule")}"
  end

  defp detour_headline(service, zones, trips) do
    "Changes #{length(trips)} Route #{service.route_id} #{plural(length(trips), "trip")}: " <>
      "adds #{length(zones)} detour #{plural(length(zones), "area")}#{measure_phrase(service)}"
  end

  defp measure_phrase(%FlexService{measure: :stops}), do: ", one around each stop"
  defp measure_phrase(%FlexService{}), do: ", one for each stretch between stops"

  defp area_location_row(location, km2) do
    %{
      file: "locations.geojson",
      id: location.id,
      summary:
        join_parts([
          "“#{location.stop_name}”",
          area_text(Map.get(km2, location.id)),
          "the name goes in stop_name, which riders see"
        ])
    }
  end

  defp area_group_row(group, group_stops) do
    %{
      file: "location_groups.txt",
      id: group.location_group_id,
      summary:
        "#{group.location_group_name} · #{length(group_stops)} connecting #{plural(length(group_stops), "stop")}"
    }
  end

  defp area_route_row(route) do
    %{
      file: "routes.txt",
      id: route.route_id,
      summary: "“#{route.route_long_name}” · route type Bus (3)"
    }
  end

  defp area_trip_row(trip, stop_times, calendars) do
    %{
      file: "trips.txt",
      id: trip.trip_id,
      summary:
        join_parts([
          "#{calendar_label(calendars, trip.service_id)} calendar",
          window_text(Enum.filter(stop_times, &(&1.trip_id == trip.trip_id))),
          "two rows per area: pickups, then drop-offs"
        ])
    }
  end

  defp detour_location_row(zone, service) do
    %{
      file: "locations.geojson",
      id: zone.zone_id,
      summary:
        join_parts([
          "Stretch between stops #{zone.stop_a} and #{zone.stop_b}",
          area_text(zone.km2),
          "stop_name “Route #{service.route_id} detour area”"
        ])
    }
  end

  defp detour_stop_time_row(%{trip_id: trip_id} = stop_time) do
    %{
      file: "stop_times.txt",
      id: trip_id,
      summary:
        join_parts([
          "Detour row between the stretch's stops",
          window_text([stop_time]),
          "pickup_type #{stop_time.pickup_type} · drop_off_type #{stop_time.drop_off_type}"
        ])
    }
  end

  defp detour_route_row(service) do
    %{
      file: "routes.txt",
      id: "route #{service.route_id}",
      summary:
        "Written once. The fixed stops keep their times; the timed stop_sequence doubles so the zone rows sit between them (R3)."
    }
  end

  defp booking_rule_plan_row(row) do
    %{
      file: "booking_rules.txt",
      id: row.booking_rule_id,
      summary:
        join_parts([
          "booking_type #{row.booking_type} #{booking_type_word(row.booking_type)}",
          prior_notice_text(row),
          contact_text(row),
          message_text(row.message)
        ])
    }
  end

  defp booking_type_word(0), do: "real time"
  defp booking_type_word(1), do: "same day"
  defp booking_type_word(2), do: "earlier day"
  defp booking_type_word(_type), do: "unspecified"

  defp prior_notice_text(row) do
    join_parts(
      [
        field_text("prior_notice_duration_min", row.prior_notice_duration_min),
        field_text("prior_notice_duration_max", row.prior_notice_duration_max),
        field_text("prior_notice_last_day", row.prior_notice_last_day),
        field_text("prior_notice_last_time", row.prior_notice_last_time),
        field_text("prior_notice_start_day", row.prior_notice_start_day),
        field_text("prior_notice_service_id", row.prior_notice_service_id)
      ],
      " · "
    )
  end

  defp contact_text(row) do
    [
      {"phone_number", row.phone_number},
      {"booking_url", row.booking_url},
      {"info_url", row.info_url}
    ]
    |> Enum.filter(fn {_column, value} -> present?(value) end)
    |> Enum.map_join(" · ", &elem(&1, 0))
  end

  defp message_text(message) when is_binary(message) and message != "",
    do: "message “#{message}”"

  defp message_text(_message), do: nil

  defp field_text(_name, nil), do: nil
  defp field_text(name, value), do: "#{name} #{value}"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp area_text(km2) when is_number(km2), do: "#{Float.round(km2 * 1.0, 1)} km²"
  defp area_text(_km2), do: nil

  # The window one trip's flex rows carry: the first row's start and the last
  # row's end, which R12 and R2 derive from the stored times.
  defp window_text([]), do: nil

  defp window_text(rows) do
    first = hd(rows)
    last = List.last(rows)
    "window #{first.start_pickup_drop_off_window}–#{last.end_pickup_drop_off_window}"
  end

  defp calendar_label(calendars, service_id) do
    get_in(calendars, [service_id, :name]) || service_id
  end

  defp join_parts(parts, separator \\ " · ") do
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(separator)
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  # --- one service ------------------------------------------------------------

  defp prepare_service(
         service,
         services,
         facts,
         calendars,
         agency_id,
         organization_id,
         version_id
       ) do
    case service.kind do
      :area ->
        prepare_area_service(
          service,
          services,
          facts,
          calendars,
          agency_id,
          organization_id,
          version_id
        )

      :detour ->
        prepare_detour_service(
          service,
          services,
          facts,
          calendars,
          organization_id,
          version_id
        )
    end
  end

  # An area service always builds its rows, even when it is left out, because
  # its generated route's daily trip count feeds the Transit hold computation
  # (AC-25). Only a service that passes readiness and derives every area's
  # geometry is exported (R4, R8).
  defp prepare_area_service(
         service,
         services,
         facts,
         calendars,
         agency_id,
         organization_id,
         version_id
       ) do
    checks = Checks.run(service, facts, services)
    error = Enum.find(checks, &(&1.level == :error))
    {area_inputs, geometry_error} = derive_areas(service, organization_id, version_id)
    rows = Areas.rows(service, area_inputs, calendars, agency_id)

    payload = %{
      service: service,
      included?: false,
      # A registered-riders service that staff keep out of the flex file is a
      # policy exclusion, not a removed route: it is not part of the feed the
      # Transit hold rule compares.
      hold?: not registered_out?(service),
      detail: nil,
      warnings: [],
      rows: rows,
      flex_route: %{route_id: "flex-#{service.key}", counts: trip_counts(rows.trips)}
    }

    cond do
      registered_out?(service) -> payload
      error -> %{payload | detail: error.text}
      geometry_error -> %{payload | detail: area_geometry_detail(geometry_error)}
      true -> %{payload | included?: true}
    end
  end

  # A detour service adds no route, so an excluded one only loses its zone rows;
  # the fixed route and its trips stay in the flex zip.
  defp prepare_detour_service(
         service,
         services,
         facts,
         calendars,
         organization_id,
         version_id
       ) do
    checks = Checks.run(service, facts, services)
    error = Enum.find(checks, &(&1.level == :error))

    payload = %{
      service: service,
      included?: false,
      hold?: false,
      detail: nil,
      warnings: [],
      rows: @empty_rows,
      flex_route: nil
    }

    cond do
      registered_out?(service) ->
        payload

      error ->
        %{payload | detail: error.text}

      true ->
        case Geometry.detour_zones(organization_id, version_id, service) do
          {:error, reason} ->
            %{payload | detail: detour_geometry_detail(reason)}

          {:ok, zones} ->
            rules = detour_booking_rules(service, calendars)

            {rows, warnings} =
              Detours.rows(
                service,
                zones,
                detour_trip_times(organization_id, version_id, service.route_id),
                rule_id(rules, service)
              )

            %{
              payload
              | included?: true,
                warnings: warnings,
                rows: %{
                  @empty_rows
                  | stop_times: rows.stop_times,
                    locations: rows.locations,
                    booking_rules: rules
                }
            }
        end
    end
  end

  defp registered_out?(%FlexService{riders: :registered, include_registered: false}), do: true
  defp registered_out?(%FlexService{}), do: false

  # R7: a detour service's one rule covers every trip, so the zone rows
  # reference the rule the same mapping wrote; a service without one is a
  # readiness error and never reaches this point.
  defp rule_id([%{booking_rule_id: id} | _rest], _service), do: id
  defp rule_id([], service), do: "flex-#{service.key}-book"

  defp detour_booking_rules(service, calendars) do
    drop_off_message = RiderText.drop_off_message(service)

    service
    |> Areas.booking_rule_rows(calendars)
    |> Enum.map(&Map.put(&1, :drop_off_message, drop_off_message))
  end

  # --- geometry ---------------------------------------------------------------

  # Stored polygons come back from `Flex.Geometry` in position order; a
  # route-distance area is recomputed from the version's current shapes (R8,
  # AC-11), so a route edit changes the exported area without a save.
  defp derive_areas(service, organization_id, version_id) do
    stored = Geometry.get_geojson(Enum.map(service.areas, & &1.id))

    {inputs, errors} =
      Enum.map_reduce(service.areas, [], fn area, errors ->
        case area_geometry(area, stored, organization_id, version_id) do
          {:ok, geojson} -> {%{area: area, geojson: geojson}, errors}
          {:error, reason} -> {%{area: area, geojson: %{}}, [reason | errors]}
        end
      end)

    {inputs, errors |> Enum.reverse() |> List.first()}
  end

  defp area_geometry(
         %FlexArea{source: :route_distance} = area,
         _stored,
         organization_id,
         version_id
       ) do
    case Geometry.route_buffer(organization_id, version_id, area.route_ids, area.distance_m) do
      {:ok, geojson} -> {:ok, geojson}
      {:error, reason} -> {:error, {:route_distance, area.key, reason}}
    end
  end

  defp area_geometry(%FlexArea{id: id, key: key}, stored, _organization_id, _version_id) do
    case Map.fetch(stored, id) do
      {:ok, geojson} -> {:ok, geojson}
      :error -> {:error, {:no_geometry, key}}
    end
  end

  defp area_geometry_detail({:route_distance, key, reason}) do
    "the route-distance area #{key} could not be built: #{geometry_reason(reason)}"
  end

  defp area_geometry_detail({:no_geometry, key}) do
    "the area #{key} has no shape to export"
  end

  defp detour_geometry_detail(reason) do
    "the detour area could not be built: #{geometry_reason(reason)}"
  end

  defp geometry_reason({:missing_routes, route_ids}) do
    "the route #{Enum.join(route_ids, ", ")} is not in this version"
  end

  defp geometry_reason(:empty), do: "the version has no shape for it"
  defp geometry_reason(:stretch_not_on_route), do: "no active route pattern visits the stretch"
  defp geometry_reason({:invalid, reason, _location}), do: "PostGIS rejected it: #{reason}"
  defp geometry_reason(reason), do: inspect(reason)

  # --- detour trips -----------------------------------------------------------

  # The trips the detour rows consider: the route's trips with their stored stop
  # times in visit order, each flagged when `frequencies.txt` lists it (R2, R6).
  defp detour_trip_times(organization_id, version_id, route_id) do
    trips =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
            t.route_id == ^route_id,
        order_by: [asc: t.trip_id],
        select: %{trip_id: t.trip_id, service_id: t.service_id}
      )
      |> Repo.all()

    trip_ids = Enum.map(trips, & &1.trip_id)

    stop_times =
      from(st in StopTime,
        where:
          st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id and
            st.trip_id in ^trip_ids,
        order_by: [asc: st.trip_id, asc: st.stop_sequence],
        select: %{
          trip_id: st.trip_id,
          stop_id: st.stop_id,
          stop_sequence: st.stop_sequence,
          arrival_time: st.arrival_time,
          departure_time: st.departure_time
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.trip_id)

    frequencies =
      from(f in Frequency,
        where:
          f.organization_id == ^organization_id and f.gtfs_version_id == ^version_id and
            f.trip_id in ^trip_ids,
        select: f.trip_id
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.map(trips, fn trip ->
      %{
        trip_id: trip.trip_id,
        service_id: trip.service_id,
        frequency?: MapSet.member?(frequencies, trip.trip_id),
        stops: stop_times_in_visit_order(stop_times, trip.trip_id)
      }
    end)
  end

  defp stop_times_in_visit_order(stop_times, trip_id) do
    stop_times
    |> Map.get(trip_id, [])
    |> Enum.map(&Map.take(&1, [:stop_id, :stop_sequence, :arrival_time, :departure_time]))
  end

  # --- rows and files ---------------------------------------------------------

  defp merge_rows(payloads) do
    Enum.reduce(payloads, @empty_rows, fn payload, acc ->
      %{
        routes: acc.routes ++ payload.rows.routes,
        trips: acc.trips ++ payload.rows.trips,
        stop_times: acc.stop_times ++ payload.rows.stop_times,
        locations: acc.locations ++ payload.rows.locations,
        location_groups: acc.location_groups ++ payload.rows.location_groups,
        location_group_stops: acc.location_group_stops ++ payload.rows.location_group_stops,
        booking_rules: acc.booking_rules ++ payload.rows.booking_rules
      }
    end)
  end

  # The extra files of the flex zip: the FeatureCollection `Jason.encode!` and
  # the three CSVs through `CsvWriter`, each only when it has content.
  defp extra_entries(rows) do
    [
      {~c"locations.geojson", locations_geojson(rows.locations)},
      {~c"booking_rules.txt", csv(rows.booking_rules, FileSpecs.booking_rules_spec())},
      {~c"location_groups.txt", csv(rows.location_groups, FileSpecs.location_groups_spec())},
      {~c"location_group_stops.txt",
       csv(rows.location_group_stops, FileSpecs.location_group_stops_spec())}
    ]
    |> Enum.reject(fn {_filename, content} -> is_nil(content) end)
  end

  defp locations_geojson([]), do: nil

  defp locations_geojson(locations) do
    Jason.encode!(%{
      "type" => "FeatureCollection",
      "features" => Enum.map(locations, &location_feature/1)
    })
  end

  defp location_feature(%{id: id, stop_name: stop_name, geometry: geometry}) do
    %{
      "type" => "Feature",
      "id" => id,
      "properties" => %{"stop_name" => stop_name},
      "geometry" => geometry
    }
  end

  defp csv([], _spec), do: nil

  defp csv(rows, spec) do
    {:ok, io} = StringIO.open("")
    CsvWriter.write_header(io, spec)
    Enum.each(rows, &CsvWriter.write_row(io, &1, spec, %{}))
    {_input, content} = StringIO.contents(io)
    content
  end

  # --- warnings ---------------------------------------------------------------

  defp excluded_warnings(excluded) do
    excluded
    |> Enum.reject(&is_nil(&1.detail))
    |> Enum.map(fn payload ->
      %{
        code: "flex_service_excluded",
        detail:
          "#{payload.service.name} was left out of the flex file: #{sentence(payload.detail)}",
        file: "routes.txt",
        entity_type: "flex_service"
      }
    end)
  end

  defp sentence(text) do
    if String.ends_with?(text, "."), do: text, else: text <> "."
  end

  defp main_feed_warnings(false), do: []

  defp main_feed_warnings(true) do
    [
      %{
        code: "main_feed_not_produced",
        detail:
          "This version has no fixed routes, so no main feed was produced; the flex file is " <>
            "the run's only feed.",
        file: "routes.txt",
        entity_type: "feed"
      }
    ]
  end

  # --- Transit hold -----------------------------------------------------------

  # A removed flex route shows Transit a 100% trip drop. The feed is at risk when
  # enough routes (or enough of the routes over 40 trips on their busiest day)
  # are removed. Only a generated area-service route can be removed: a detour
  # service's fixed route keeps its trips in the flex zip.
  defp hold_warnings(prepared, calendar_rows, exception_rows, organization_id, version_id) do
    lost =
      prepared
      |> Enum.filter(&(&1.hold? and not &1.included?))
      |> Enum.map(& &1.flex_route)
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.route_id, &1.counts})

    if lost == %{} do
      []
    else
      generated =
        prepared
        |> Enum.filter(& &1.hold?)
        |> Enum.map(& &1.flex_route)
        |> Enum.reject(&is_nil/1)
        |> Map.new(&{&1.route_id, &1.counts})

      counts = Map.merge(generated, main_route_trip_counts(organization_id, version_id))

      routes =
        MapSet.union(MapSet.new(Map.keys(counts)), main_route_ids(organization_id, version_id))

      dates = service_dates(calendar_rows, exception_rows)

      frequent =
        routes
        |> Enum.filter(&(busiest_day(Map.get(counts, &1, %{}), dates) > @frequent_trips))
        |> MapSet.new()

      lost_routes = MapSet.new(Map.keys(lost))
      lost_frequent = MapSet.intersection(lost_routes, frequent)

      route_ratio = ratio(MapSet.size(lost_routes), MapSet.size(routes))
      frequent_ratio = ratio(MapSet.size(lost_frequent), MapSet.size(frequent))

      if route_ratio >= @hold_route_ratio or frequent_ratio >= @hold_frequent_ratio do
        [hold_warning(lost_routes, routes, lost_frequent, frequent)]
      else
        []
      end
    end
  end

  defp ratio(_part, 0), do: 0.0
  defp ratio(part, whole), do: part / whole

  defp hold_warning(lost_routes, routes, lost_frequent, frequent) do
    lost = MapSet.size(lost_routes)
    total = MapSet.size(routes)
    lost_frequent_count = MapSet.size(lost_frequent)
    frequent_count = MapSet.size(frequent)

    %{
      code: "transit_hold_risk",
      detail:
        "Transit may hold this feed: leaving out services removes #{lost} of #{total} routes " <>
          "(#{percent(lost, total)}%), including #{lost_frequent_count} of #{frequent_count} " <>
          "routes with more than #{@frequent_trips} trips on their busiest day " <>
          "(#{percent(lost_frequent_count, frequent_count)}%).",
      file: "routes.txt",
      entity_type: "route"
    }
  end

  defp percent(_part, 0), do: 0
  defp percent(part, whole), do: round(part / whole * 100)

  # A route's trips on its busiest service day: the stored trips of a fixed
  # route, or the windowed trips an area service generates, summed over the
  # calendars active that day.
  defp busiest_day(counts_by_service, dates_by_service) do
    counts_by_service
    |> Enum.flat_map(fn {service_id, count} ->
      dates_by_service
      |> Map.get(service_id, [])
      |> Enum.map(&{&1, count})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {_date, counts} -> Enum.sum(counts) end)
    |> Enum.max(fn -> 0 end)
  end

  defp main_route_ids(organization_id, version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id,
      select: r.route_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp main_route_trip_counts(organization_id, version_id) do
    from(t in Trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id,
      group_by: [t.route_id, t.service_id],
      select: {t.route_id, t.service_id, count(t.id)}
    )
    |> Repo.all()
    |> Enum.group_by(fn {route_id, _service_id, _count} -> route_id end)
    |> Map.new(fn {route_id, rows} ->
      {route_id, Map.new(rows, fn {_route_id, service_id, count} -> {service_id, count} end)}
    end)
  end

  defp service_dates(calendar_rows, exception_rows) do
    exceptions = Enum.group_by(exception_rows, & &1.service_id)
    calendars = Map.new(calendar_rows, &{&1.service_id, &1})

    service_ids = MapSet.union(MapSet.new(Map.keys(calendars)), MapSet.new(Map.keys(exceptions)))

    Map.new(service_ids, fn service_id ->
      {service_id,
       ServiceDates.active_dates(
         Map.get(calendars, service_id),
         Map.get(exceptions, service_id, [])
       )}
    end)
  end

  defp trip_counts(trips) do
    trips
    |> Enum.group_by(& &1.service_id)
    |> Map.new(fn {service_id, rows} -> {service_id, length(rows)} end)
  end

  # --- version reads ----------------------------------------------------------

  defp calendar_rows(organization_id, version_id) do
    from(c in Calendar,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id,
      order_by: [asc: c.service_id]
    )
    |> Repo.all()
  end

  defp calendar_date_rows(organization_id, version_id) do
    from(d in CalendarDate,
      where: d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id,
      order_by: [asc: d.service_id, asc: d.date]
    )
    |> Repo.all()
  end

  defp agency_id(organization_id, version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id,
      order_by: [asc: a.agency_id],
      select: a.agency_id,
      limit: 1
    )
    |> Repo.one()
  end

  defp version_has_routes?(organization_id, version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id,
      select: true,
      limit: 1
    )
    |> Repo.exists?()
  end

  # --- sequence mapper --------------------------------------------------------

  defp detour_trip_ids(organization_id, version_id) do
    route_ids =
      Repo.all(
        from s in FlexService,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id and
              s.kind == :detour and s.active,
          select: s.route_id
      )

    case route_ids do
      [] -> MapSet.new()
      route_ids -> trip_ids_on(organization_id, version_id, route_ids)
    end
  end

  defp trip_ids_on(organization_id, version_id, route_ids) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id in ^route_ids,
      select: t.trip_id
    )
    |> Repo.all()
    |> MapSet.new()
  end
end
