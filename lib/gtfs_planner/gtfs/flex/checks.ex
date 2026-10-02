defmodule GtfsPlanner.Gtfs.Flex.Checks do
  @moduledoc """
  Readiness checks for one flex service (AC-8; R4–R7, R10, R11).

  `run/3` reads one service with its areas loaded, the version's facts
  (`version_facts/2`) and the version's other services, and returns the checks
  the Flex pages show: an `:error` keeps the service out of the flex file (R4),
  a `:warning` never does, and `:info` is context. The wording is the
  prototype's (`evidence/prototype-src/flex-model.js`, `checks()`), with the
  rules the prototype had no server data for: a calendar, stop or route the
  version does not have (R6, R10, R14), a generated ID that equals one already
  in the same file (R11), two areas of one service overlapping while both are
  in service, and the registered-riders fields (R5).

  One check is `%{level, section, field, text}`: `section` names the service
  page's `:when`, `:where`, `:booking` or `:riders` block and `field` the input
  it belongs to, so the page can put each check beside its field. `status/2`
  turns a check list into the badge the Flex list and the service page show.

  `version_facts/2` reads a version once — its calendar service IDs, stop IDs,
  routes and their continuous-boarding flags, and the natural IDs already in
  `routes.txt`, `trips.txt`, `stops.txt` and `booking_rules.txt` — so a list of
  services is checked without a query per service. Geometry is compared through
  `Flex.Geometry` only (CR-1): `self_overlaps/1` for two areas of one service
  and `overlaps/4` for another active area service.

  `run/3` measures the rider text with no calendar names, so a calendar-scoped
  booking rule's line uses its service id there; the count can differ by a few
  characters from the exported message once the page's calendars map exists
  (step 22).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.BookingRule
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values
  alias GtfsPlanner.Wording

  @typedoc """
  One readiness finding: `:error` excludes the service from the flex file (R4),
  `:warning` never does, and `:info` is context for the page.
  """
  @type check :: %{
          level: :error | :warning | :info,
          section: :when | :booking | :where | :riders,
          field: atom(),
          text: String.t()
        }

  @typedoc """
  What `version_facts/2` reads: the version's calendar service IDs, its stop
  IDs, its routes with their continuous-boarding flags, and the natural IDs
  already used in the files the flex export appends to.
  """
  @type facts :: %{
          service_ids: MapSet.t(),
          stop_ids: MapSet.t(),
          routes: %{String.t() => %{continuous?: boolean(), active?: boolean()}},
          gtfs_ids: %{atom() => MapSet.t()}
        }

  @phone_format ~r/\A\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\z/
  @booking_url_format ~r/\Ahttps:\/\/[^\s.]+\.[^\s]+\z/
  # The prototype's "the area name looks like data" test: an all-capitals name
  # or one with an underscore.
  @code_like_area_name ~r/\A[A-Z0-9_\-\s]{3,}\z|_/
  @book_words ~r/\b(book|booking|reserve|reservation|call|schedule|notice|ahead|advance|in advance)\b/i
  @note_duration ~r/(\d+)\s*(minutes?|mins?|hours?|hrs?)\b/i
  @note_days ~r/(\d+)\s*(days?)\b/i
  @note_app_mention ~r/\b(app|online|website|web site)\b/i
  @note_times ~r/\b\d{1,2}(:\d{2})?\s?(am|pm)\b/i
  @note_fares ~r/\$\s?\d/
  @note_code ~r/[{}\[\]<>]|\\n|_[a-z]/i
  @sentence_split ~r/(?<=[.!?])\s+/
  @message_limit 250
  @ada_distance_m 1_200
  @long_hours_minutes 16 * 60
  @minutes_per_day 1_440

  # --- version facts ----------------------------------------------------------

  @doc """
  Reads the facts readiness checks need for one version.

  `service_ids` is every calendar service ID the version defines — a weekly
  `calendars` row or a `calendar_dates` exception — `stop_ids` its stops,
  `routes` its routes keyed by natural ID with `continuous?` true when
  `continuous_pickup` or `continuous_drop_off` allows boarding anywhere (GTFS 0,
  2 or 3) and `active?` false when the route is explicitly inactive (the export
  leaves it out with its trips), and `gtfs_ids` the natural IDs already used in
  the files the flex export appends to (`routes`, `trips`, `stops` and
  `booking_rules`; R11).

  Every read is scoped to the organization and version (R10, INV-4).
  """
  @spec version_facts(Ecto.UUID.t(), Ecto.UUID.t()) :: facts()
  def version_facts(organization_id, version_id) do
    stops = natural_ids(Stop, :stop_id, organization_id, version_id)

    %{
      service_ids: service_ids(organization_id, version_id),
      stop_ids: stops,
      routes: routes(organization_id, version_id),
      gtfs_ids: %{
        routes: natural_ids(Route, :route_id, organization_id, version_id),
        trips: natural_ids(Trip, :trip_id, organization_id, version_id),
        stops: stops,
        booking_rules: natural_ids(BookingRule, :booking_rule_id, organization_id, version_id)
      }
    }
  end

  defp service_ids(organization_id, version_id) do
    MapSet.union(
      natural_ids(Calendar, :service_id, organization_id, version_id),
      natural_ids(CalendarDate, :service_id, organization_id, version_id)
    )
  end

  defp routes(organization_id, version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id,
      select: {r.route_id, r.continuous_pickup, r.continuous_drop_off, r.active}
    )
    |> Repo.all()
    |> Map.new(fn {route_id, pickup, drop_off, active} ->
      {route_id,
       %{continuous?: continuous?(pickup) or continuous?(drop_off), active?: active != false}}
    end)
  end

  defp natural_ids(schema, field, organization_id, version_id) do
    from(row in schema,
      where: row.organization_id == ^organization_id and row.gtfs_version_id == ^version_id,
      select: map(row, ^[field])
    )
    |> Repo.all()
    |> MapSet.new(&Map.fetch!(&1, field))
  end

  # GTFS continuous stopping: 0 board anywhere, 2 call the agency, 3 coordinate
  # with the driver. 1 is "only at stops".
  defp continuous?(value) when value in [0, 2, 3], do: true
  defp continuous?(_value), do: false

  # --- checks -----------------------------------------------------------------

  @doc """
  Returns every readiness check for one service.

  `service` must carry its areas (the context's reads preload them),
  `version_facts` is `version_facts/2`'s map, and `others` is the version's
  other services. `run/3` also compares the service's stored areas with the
  version through `Flex.Geometry`, so it runs on the caller's database
  connection.
  """
  @spec run(FlexService.t(), facts(), [FlexService.t()]) :: [check()]
  def run(%FlexService{} = service, version_facts, others) when is_list(others) do
    where_checks(service, version_facts) ++
      when_checks(service, version_facts) ++
      booking_checks(service, version_facts) ++
      rider_checks(service) ++
      overlap_checks(service, others) ++
      collision_checks(service, version_facts)
  end

  @doc """
  The badge for one service: its tone, its label and its error and warning
  counts.

  An inactive service is `"Inactive"` and a registered-riders service that is
  left out of the flex file is `"Not in trip planners"`, whatever the checks
  say. Otherwise an error makes the tone `:error` with `"1 problem"` or
  `"2 problems"`, a warning alone makes it `:warning` with
  `"Ready · 2 suggestions"`, and no error or warning is `:success` with
  `"Ready"`.
  """
  @spec status(FlexService.t(), [check()]) :: %{
          tone: atom(),
          label: String.t(),
          errors: non_neg_integer(),
          warnings: non_neg_integer()
        }
  def status(%FlexService{} = service, checks) when is_list(checks) do
    errors = Enum.count(checks, &(&1.level == :error))
    warnings = Enum.count(checks, &(&1.level == :warning))
    counts = %{errors: errors, warnings: warnings}

    cond do
      not service.active ->
        Map.merge(counts, %{tone: :neutral, label: "Inactive"})

      service.riders == :registered and not service.include_registered ->
        Map.merge(counts, %{tone: :neutral, label: "Not in trip planners"})

      errors > 0 ->
        Map.merge(counts, %{tone: :error, label: "#{errors} problem#{Wording.noun(errors, "")}"})

      warnings > 0 ->
        Map.merge(counts, %{
          tone: :warning,
          label: "Ready · #{warnings} suggestion#{Wording.noun(warnings, "")}"
        })

      true ->
        Map.merge(counts, %{tone: :success, label: "Ready"})
    end
  end

  # --- where ------------------------------------------------------------------

  defp where_checks(%FlexService{kind: :area} = service, version_facts) do
    areas = service.areas

    area_presence(areas) ++
      area_name_checks(areas) ++
      self_overlap_checks(service) ++
      missing_route_checks(areas, version_facts) ++
      missing_stop_checks(service.hub_stop_ids, version_facts)
  end

  defp where_checks(%FlexService{kind: :detour} = service, version_facts) do
    route_checks(service, version_facts) ++
      missing_stop_checks([service.first_stop_id, service.last_stop_id], version_facts) ++
      detour_distance_checks(service)
  end

  defp area_presence([]), do: [check(:error, :where, :area, "Add the area riders can travel in.")]
  defp area_presence(_areas), do: []

  defp area_name_checks(areas) do
    areas
    |> Enum.filter(&(Values.present?(&1.name) and Regex.match?(@code_like_area_name, &1.name)))
    |> Enum.map(
      &check(
        :warning,
        :where,
        :area,
        "Riders see the area name “#{&1.name}”. Use a place name riders know, such as the town."
      )
    )
  end

  # Two areas of one service that overlap while both are in service make every
  # place in the overlap reachable in either, so the rider cannot tell them
  # apart (AC-8).
  defp self_overlap_checks(service) do
    service
    |> Geometry.self_overlaps()
    |> Enum.filter(fn {key_a, key_b} -> share_hours_window?(service, key_a, key_b) end)
    |> Enum.map(fn {key_a, key_b} ->
      check(
        :error,
        :where,
        :area,
        "The areas “#{area_name(service.areas, key_a)}” and “#{area_name(service.areas, key_b)}” " <>
          "overlap while both are in service. Redraw one so they do not."
      )
    end)
  end

  defp missing_route_checks(areas, version_facts) do
    route_ids = Enum.flat_map(areas, & &1.route_ids)

    missing =
      route_ids
      |> missing_ids(version_facts.gtfs_ids.routes)
      |> Enum.map(fn id ->
        check(
          :error,
          :where,
          :routes,
          "Route “#{id}” is not in this version. Choose a route this version has."
        )
      end)

    missing ++
      (route_ids
       |> Enum.uniq()
       |> Enum.filter(&inactive_route?(&1, version_facts))
       |> Enum.map(&check(:error, :where, :routes, inactive_route_text(&1))))
  end

  defp missing_stop_checks(stop_ids, version_facts) do
    stop_ids
    |> missing_ids(version_facts.stop_ids)
    |> Enum.map(fn id ->
      check(:error, :where, :stops, "The stop “#{id}” is not in this version.")
    end)
  end

  defp route_checks(%FlexService{route_id: route_id} = service, version_facts) do
    choice =
      if Values.present?(route_id) do
        []
      else
        [check(:error, :where, :route, "Choose the route that detours.")]
      end

    choice ++
      missing_route_check(route_id, version_facts) ++
      inactive_route_check(route_id, version_facts) ++
      continuous_boarding_checks(service, version_facts)
  end

  # An inactive route leaves the export with its trips, so a detour on it, or
  # an area that follows it, would describe service the feed does not carry.
  defp inactive_route_check(route_id, version_facts) do
    if Values.present?(route_id) and inactive_route?(route_id, version_facts) do
      [check(:error, :where, :route, inactive_route_text(route_id))]
    else
      []
    end
  end

  defp inactive_route?(route_id, version_facts) do
    get_in(version_facts.routes, [route_id, :active?]) == false
  end

  defp inactive_route_text(route_id) do
    "Route “#{route_id}” is inactive, so exports leave it out. Make the route active or " <>
      "choose another route."
  end

  defp missing_route_check(route_id, version_facts) do
    if Values.present?(route_id) and not Map.has_key?(version_facts.routes, route_id) do
      [
        check(
          :error,
          :where,
          :route,
          "Route “#{route_id}” is not in this version. Choose a route this version has."
        )
      ]
    else
      []
    end
  end

  # A route that lets riders board anywhere cannot also carry detours (AC-8).
  defp continuous_boarding_checks(%FlexService{route_id: route_id}, version_facts)
       when is_binary(route_id) do
    case get_in(version_facts.routes, [route_id, :continuous?]) do
      true ->
        [
          check(
            :error,
            :where,
            :route,
            "Route #{route_id} lets riders board anywhere along the street. Exports can’t combine " <>
              "that with detours. In Route #{route_id}, set Continuous Pickup and Continuous " <>
              "Drop Off to 1 (only at stops)."
          )
        ]

      _other ->
        []
    end
  end

  defp continuous_boarding_checks(%FlexService{}, _version_facts), do: []

  defp detour_distance_checks(%FlexService{distance_m: distance_m} = service) do
    missing =
      if is_integer(distance_m) do
        []
      else
        [
          check(
            :error,
            :where,
            :distance,
            "Choose the detour distance your agency publishes."
          )
        ]
      end

    wording =
      if Values.present?(service.wording) do
        []
      else
        [
          check(
            :error,
            :where,
            :wording,
            "Enter how your timetable and website describe detours, so the text riders read " <>
              "matches them."
          )
        ]
      end

    ada =
      if service.ada_only and is_integer(distance_m) and distance_m < @ada_distance_m do
        [
          check(
            :warning,
            :where,
            :distance,
            "Detours for ADA-eligible riders only replace paratransit, which must reach ¾ mile from " <>
              "the route. A shorter distance leaves some eligible riders without service."
          )
        ]
      else
        []
      end

    missing ++ wording ++ ada
  end

  # --- when -------------------------------------------------------------------

  defp when_checks(%FlexService{kind: :area} = service, version_facts) do
    hours = service.hours

    hours_presence(hours) ++
      long_hours_checks(hours) ++
      zone_hours_check(hours) ++
      missing_calendar_checks(Enum.map(hours, & &1.service_id), version_facts, :when, :hours)
  end

  defp when_checks(%FlexService{kind: :detour} = service, version_facts) do
    presence =
      if service.calendar_service_ids == [] do
        [check(:error, :when, :hours, "Choose which trips offer detours.")]
      else
        []
      end

    presence ++
      missing_calendar_checks(service.calendar_service_ids, version_facts, :when, :hours)
  end

  defp hours_presence([]),
    do: [check(:error, :when, :hours, "Add the hours riders can travel.")]

  defp hours_presence(_hours), do: []

  # A row that runs more than 16 hours reaches into the next day (R6).
  defp long_hours_checks(hours) do
    hours
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} -> long_hours_check(row, index) end)
  end

  defp long_hours_check(row, index) do
    case window(row) do
      {start, finish} when finish - start > @long_hours_minutes ->
        [
          check(
            :error,
            :when,
            :"hours-#{index}",
            "These hours run #{round((finish - start) / 60)} hours, into the next day. Check the " <>
              "end time."
          )
        ]

      _other ->
        []
    end
  end

  defp zone_hours_check(hours) do
    if Enum.any?(hours, &Values.present?(&1.area_key)) do
      [
        check(
          :warning,
          :when,
          :zone_hours,
          "Areas in this service run at different hours. Riders read each area’s hours separately " <>
            "(“Toledo only: …”); check the rider text says it plainly."
        )
      ]
    else
      []
    end
  end

  defp missing_calendar_checks(service_ids, version_facts, section, field) do
    service_ids
    |> missing_ids(version_facts.service_ids)
    |> Enum.map(fn id ->
      check(
        :error,
        section,
        field,
        "The calendar “#{id}” is not in this version. Choose a calendar this version has."
      )
    end)
  end

  # --- booking ----------------------------------------------------------------

  defp booking_checks(service, version_facts) do
    contact_checks(service) ++
      rule_shape_checks(service) ++
      Enum.flat_map(service.booking_rules, &rule_field_checks/1) ++
      missing_calendar_checks(
        Enum.map(service.booking_rules, & &1.service_id),
        version_facts,
        :booking,
        :service_id
      ) ++
      note_checks(service) ++
      message_length_checks(service)
  end

  defp contact_checks(%FlexService{phone: phone, booking_url: booking_url}) do
    contact_missing_check(phone, booking_url) ++ phone_check(phone) ++ url_check(booking_url)
  end

  defp contact_missing_check(phone, booking_url) do
    if Values.blank?(phone) and Values.blank?(booking_url) do
      [
        check(
          :error,
          :booking,
          :contact,
          "Add a phone number or booking link so riders know how to book."
        )
      ]
    else
      []
    end
  end

  defp phone_check(phone) do
    if Values.present?(phone) and not Regex.match?(@phone_format, String.trim(phone)) do
      [
        check(
          :error,
          :booking,
          :phone,
          "Enter the phone number as 10 digits, for example (541) 555-0142."
        )
      ]
    else
      []
    end
  end

  defp url_check(booking_url) do
    if Values.present?(booking_url) and
         not Regex.match?(@booking_url_format, String.trim(booking_url)) do
      [check(:error, :booking, :url, "Enter the full booking link, starting with https://")]
    else
      []
    end
  end

  # R7: a detour service has exactly one rule, and it covers every trip.
  defp rule_shape_checks(%FlexService{kind: :detour} = service) do
    rules = service.booking_rules

    if length(rules) == 1 and not Enum.any?(rules, &Values.present?(&1.service_id)) do
      []
    else
      [
        check(
          :error,
          :booking,
          :booking_rules,
          "A detour service has exactly one booking rule, and it covers every trip. Remove the " <>
            "extra or calendar-scoped rules."
        )
      ]
    end
  end

  defp rule_shape_checks(%FlexService{}), do: []

  defp rule_field_checks(%FlexBookingRule{when: nil}),
    do: [check(:error, :booking, :when, "Choose when riders must book.")]

  defp rule_field_checks(%FlexBookingRule{when: :same_day} = rule) do
    if is_integer(rule.minutes) and rule.minutes > 0 do
      []
    else
      [check(:error, :booking, :minutes, "Enter how many minutes ahead riders must book.")]
    end
  end

  defp rule_field_checks(%FlexBookingRule{when: :earlier_day} = rule) do
    days =
      if is_integer(rule.days) and rule.days > 0 do
        []
      else
        [check(:error, :booking, :days, "Enter how many days ahead riders must book.")]
      end

    by =
      if Values.present?(rule.by) do
        []
      else
        [check(:error, :booking, :by, "Enter the time riders must book by.")]
      end

    days ++ by
  end

  defp rule_field_checks(%FlexBookingRule{}), do: []

  # --- the note ---------------------------------------------------------------

  defp note_checks(service) do
    note = trimmed(service.note)

    if note == "" do
      []
    else
      rule = main_rule(service)

      note_sentence_checks(note, rule) ++
        app_mention_check(note, service) ++
        note_format_checks(note)
    end
  end

  defp note_sentence_checks(note, rule) do
    @sentence_split
    |> Regex.split(note)
    |> Enum.filter(&Regex.match?(@book_words, &1))
    |> Enum.flat_map(fn sentence ->
      duration_contradiction(sentence, rule) ++ days_contradiction(sentence, rule)
    end)
  end

  defp duration_contradiction(sentence, %FlexBookingRule{when: :same_day, minutes: minutes})
       when is_integer(minutes) do
    case Regex.run(@note_duration, sentence) do
      [quoted, number, unit] ->
        if duration_minutes(number, unit) == minutes do
          []
        else
          [
            check(
              :warning,
              :booking,
              :note,
              "The note says “#{quoted}”, but the rule says at least #{duration(minutes)}. Trip " <>
                "planners show both."
            )
          ]
        end

      nil ->
        []
    end
  end

  defp duration_contradiction(_sentence, _rule), do: []

  defp days_contradiction(sentence, %FlexBookingRule{when: :earlier_day, days: days})
       when is_integer(days) do
    case Regex.run(@note_days, sentence) do
      [quoted, number | _unit] ->
        if String.to_integer(number) == days do
          []
        else
          [
            check(
              :warning,
              :booking,
              :note,
              "The note says “#{quoted}”, but the rule says #{day_count(days, false)}."
            )
          ]
        end

      nil ->
        []
    end
  end

  defp days_contradiction(_sentence, _rule), do: []

  defp app_mention_check(note, %FlexService{booking_url: booking_url}) do
    if Regex.match?(@note_app_mention, note) and Values.blank?(booking_url) do
      [
        check(
          :warning,
          :booking,
          :note,
          "The note mentions booking online, but there is no booking link. Add the link so trip " <>
            "planners can offer it."
        )
      ]
    else
      []
    end
  end

  defp note_format_checks(note) do
    [
      {Regex.match?(@note_times, note),
       "The note repeats times. Trip planners already show service hours, and phone-line hours " <>
         "have their own field."},
      {Regex.match?(@note_fares, note),
       "The note lists fares. Put fares on the page with fares and details, so the note stays " <>
         "about booking."},
      {Regex.match?(@note_code, note),
       "The note looks like code or data. Riders see it exactly as written."}
    ]
    |> Enum.filter(fn {found, _text} -> found end)
    |> Enum.map(fn {_found, text} -> check(:warning, :booking, :note, text) end)
  end

  defp message_length_checks(service) do
    length = service |> RiderText.message(%{}) |> String.length()

    if length > @message_limit do
      [
        check(
          :warning,
          :booking,
          :note,
          "The text riders read is #{length} characters. Keep it near 250: the spec asks for a " <>
            "short note about what riders must do."
        )
      ]
    else
      []
    end
  end

  # --- riders -----------------------------------------------------------------

  defp rider_checks(%FlexService{riders: :registered} = service) do
    info_url_checks(service) ++ eligibility_checks(service) ++ registered_context(service)
  end

  defp rider_checks(%FlexService{}), do: []

  # R5: an exported registered-riders service needs a page about who can ride.
  defp info_url_checks(%FlexService{include_registered: true} = service) do
    if Values.present?(service.info_url) do
      []
    else
      [
        check(
          :error,
          :riders,
          :info,
          "Add a page with fares and details under How riders book. Riders who aren’t registered " <>
            "need to learn how to sign up."
        )
      ]
    end
  end

  defp info_url_checks(%FlexService{}), do: []

  defp eligibility_checks(service) do
    if Values.present?(service.eligibility) do
      []
    else
      [
        check(
          :error,
          :riders,
          :eligibility,
          "Say who can register, for example “Adults 60 and older and riders with disabilities.”"
        )
      ]
    end
  end

  defp registered_context(%FlexService{include_registered: true}) do
    [
      check(
        :info,
        :riders,
        :riders,
        "Trip planners can’t check who is registered. They show this service to everyone, with " <>
          "your statement of who can ride."
      )
    ]
  end

  defp registered_context(%FlexService{}) do
    [
      check(
        :info,
        :riders,
        :riders,
        "Left out of the flex feed. Riders won’t find it in trip planners; your website and phone " <>
          "line stay the way to reach it."
      )
    ]
  end

  # --- overlaps with other services -------------------------------------------

  # AC-8's information line: another active area service of this version serves
  # part of one of this service's stored areas. `Geometry.overlaps/4` measures
  # it, so an inactive, detour or geometry-less service never appears; `others`
  # is the version's other services and only saves the query when none can
  # overlap.
  defp overlap_checks(service, others) do
    areas = service.areas

    if areas != [] and Enum.any?(others, &overlap_candidate?(&1, service)) do
      stored = Geometry.get_geojson(for area <- areas, area.id, do: area.id)

      Enum.flat_map(areas, fn area -> area_overlap_checks(service, area, stored[area.id]) end)
    else
      []
    end
  end

  defp overlap_candidate?(other, service) do
    other.id != service.id and other.active and other.kind == :area and
      other.gtfs_version_id == service.gtfs_version_id
  end

  defp area_overlap_checks(_service, _area, nil), do: []

  defp area_overlap_checks(service, area, geojson) do
    service.organization_id
    |> Geometry.overlaps(service.gtfs_version_id, geojson, service.id)
    |> Enum.map(fn overlap ->
      check(
        :info,
        :where,
        :area,
        "Part of #{area.name} (#{round1(overlap.km2)} km²) is also served by #{overlap.name}. " <>
          "Riders there may see both services."
      )
    end)
  end

  # --- generated ID collisions ------------------------------------------------

  # R11: a generated ID that equals an existing ID in the same file is an
  # error. `gtfs_ids.stops` also holds locations and location groups, which GTFS
  # requires to be unique across `stops.stop_id`, the locations and the group
  # IDs.
  defp collision_checks(%FlexService{key: key} = service, version_facts)
       when is_binary(key) and key != "" do
    generated =
      for {file, id} <- generated_ids(service),
          MapSet.member?(Map.get(version_facts.gtfs_ids, file, MapSet.new()), id) do
        collision_check(file, id)
      end

    generated ++ trip_prefix_checks(service, version_facts)
  end

  defp collision_checks(%FlexService{}, _version_facts), do: []

  defp generated_ids(%FlexService{kind: :detour} = service), do: booking_rule_ids(service)

  defp generated_ids(%FlexService{kind: :area} = service) do
    key = service.key

    locations =
      for area <- service.areas, is_binary(area.key), is_integer(area.position) do
        {:stops, "flex-#{key}-a#{area.position}"}
      end

    group =
      if service.hub_stop_ids == [], do: [], else: [{:stops, "flex-#{key}-stops"}]

    [{:routes, "flex-#{key}"}] ++ locations ++ group ++ booking_rule_ids(service)
  end

  defp booking_rule_ids(service) do
    service.booking_rules
    |> Enum.map(fn rule ->
      case rule.service_id do
        id when is_binary(id) and id != "" ->
          {:booking_rules, "flex-#{service.key}-book-#{Flex.slugify(id)}"}

        _other ->
          {:booking_rules, "flex-#{service.key}-book"}
      end
    end)
    |> Enum.uniq()
  end

  # R11's trip IDs are `flex-<key>-<service_id slug>-<hhmm>`, which export
  # derives per interval (step 13). Readiness only knows the prefix, so any trip
  # whose ID starts with it is reported rather than re-deriving the intervals.
  defp trip_prefix_checks(%FlexService{kind: :detour}, _version_facts), do: []

  defp trip_prefix_checks(%FlexService{key: key}, version_facts) do
    prefix = "flex-#{key}-"

    version_facts.gtfs_ids
    |> Map.get(:trips, MapSet.new())
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
    |> Enum.map(&collision_check(:trips, &1))
  end

  defp collision_check(:routes, id) do
    check(
      :error,
      :where,
      :id,
      "The generated route ID “#{id}” is already used in routes.txt. A feed can’t have two routes " <>
        "with the same ID."
    )
  end

  defp collision_check(:trips, id) do
    check(
      :error,
      :where,
      :id,
      "This version already has the trip “#{id}”, and the flex file generates trip IDs starting " <>
        "with the same prefix. Two trips with the same ID can’t be published."
    )
  end

  defp collision_check(:stops, id) do
    check(
      :error,
      :where,
      :id,
      "The generated location ID “#{id}” is already used as a stop ID. GTFS IDs must be unique " <>
        "across stops, locations and location groups."
    )
  end

  defp collision_check(:booking_rules, id) do
    check(
      :error,
      :where,
      :id,
      "The generated booking rule ID “#{id}” is already used in booking_rules.txt. A feed can’t " <>
        "have two booking rules with the same ID."
    )
  end

  # --- hours windows ----------------------------------------------------------

  # An hours row as [start, end) in minutes from midnight, with an end at or
  # before the start taken as the next day (R6). A row without both times is not
  # a window.
  defp window(%{start: start, end: finish}) do
    with start_minutes when is_integer(start_minutes) <- GtfsTime.parse_hhmm(start),
         finish_minutes when is_integer(finish_minutes) <- GtfsTime.parse_hhmm(finish) do
      if finish_minutes <= start_minutes do
        {start_minutes, finish_minutes + @minutes_per_day}
      else
        {start_minutes, finish_minutes}
      end
    else
      _other -> nil
    end
  end

  defp window(_row), do: nil

  defp share_hours_window?(service, key_a, key_b) do
    service.hours
    |> Enum.group_by(& &1.service_id)
    |> Enum.any?(fn {_service_id, rows} ->
      windows_overlap?(area_windows(rows, key_a), area_windows(rows, key_b))
    end)
  end

  # A row with no area covers every area of the service.
  defp area_windows(rows, key) do
    for row <- rows, row.area_key in [nil, "", key], span = window(row), span != nil, do: span
  end

  # Windows are compared on the day boundary too: an hours row that runs past
  # midnight is in service when the next day's early window is (R6).
  defp windows_overlap?(windows_a, windows_b) do
    Enum.any?(windows_a, fn window_a -> Enum.any?(windows_b, &overlaps?(window_a, &1)) end)
  end

  defp overlaps?({a_start, a_end}, {b_start, b_end}) do
    Enum.any?([0, @minutes_per_day, -@minutes_per_day], fn day ->
      max(a_start, b_start + day) < min(a_end, b_end + day)
    end)
  end

  # --- small helpers ----------------------------------------------------------

  defp check(level, section, field, text) do
    %{level: level, section: section, field: field, text: text}
  end

  defp missing_ids(ids, known) do
    ids
    |> Enum.filter(&Values.present?/1)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known, &1))
  end

  defp main_rule(service) do
    Enum.find(service.booking_rules, &(not Values.present?(&1.service_id)))
  end

  defp area_name(areas, key) do
    case Enum.find(areas, &(&1.key == key)) do
      %FlexArea{name: name} when is_binary(name) and name != "" -> name
      _other -> key
    end
  end

  defp duration_minutes(number, unit) do
    minutes = String.to_integer(number)
    if String.match?(unit, ~r/h/i), do: minutes * 60, else: minutes
  end

  # The same wording as `RiderText`'s deadline sentence ("at least 1 hour"),
  # whose duration helper is private there.
  defp duration(0), do: "0 minutes"
  defp duration(1), do: "1 minute"
  defp duration(minutes) when minutes < 60, do: "#{minutes} minutes"

  defp duration(minutes) do
    hours = div(minutes, 60)
    rest = rem(minutes, 60)

    case {hours, rest} do
      {hours, 0} ->
        "#{hours} hour#{Wording.noun(hours, "")}"

      {hours, rest} ->
        "#{hours} hour#{Wording.noun(hours, "")} #{rest} minute#{Wording.noun(rest, "")}"
    end
  end

  defp day_count(days, business_days) do
    unit = if business_days, do: "business day", else: "day"
    "#{days} #{unit}#{Wording.noun(days, "")}"
  end

  defp round1(number) when is_float(number), do: :erlang.float_to_binary(number, decimals: 1)
  defp round1(number), do: to_string(number)

  defp trimmed(value), do: value |> to_string() |> String.trim()
end
