defmodule GtfsPlanner.Gtfs.Flex.RiderText do
  @moduledoc """
  The rider-facing text of a flex service (R5, R7, AC-9).

  Every function is pure. It reads one `GtfsPlanner.Gtfs.FlexService` with its
  embedded hours and booking rules, and a calendars map
  `%{service_id => %{name: "Weekday", plural: "Weekdays"}}` that the caller
  builds from `calendar_attributes`, falling back to the service id. Export and
  the service page therefore render the same words from the same fields, so the
  generated text cannot disagree with the rule fields.

  `deadline_lines/2` builds the deadline sentences a trip planner derives from a
  booking rule, `message/2` is the text riders read (the eligibility sentence,
  those deadline sentences, how to book, then the note), and `app_renderings/1`
  shows how three trip planners word the one rule. `hours_lines/3` words the
  hours of an area service — an area's name prefixes the rows that name it — or
  the calendars and optional band of a detour service. `rider_name/1` qualifies
  a registered-riders service with " (registered riders)" unless its name
  already says who it is for, and `drop_off_message/1` is the drop-off
  instruction of a detour service that takes them.

  The wording is the prototype's (`evidence/prototype-src/flex-model.js`,
  `flex-services.js:511-525`), with two spec-mandated changes: the OneBusAway
  rendering states "the Friday before" instead of a fixed date (CR-9), and the
  earlier-day deadline names the rule's own fields ("Book by 4:00 pm 1 business
  day before", R7). A calendar the map does not know falls back to its service
  id, and an area row falls back to its area key.
  """

  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexService

  @registered_suffix " (registered riders)"
  @qualified ~r/registered|paratransit|\bADA\b|senior|eligib/i
  @drop_off "To get off away from the route, tell the driver when you board."
  @transit_note "Its own line from the rule; your text is not shown on the trip screen."
  @otp_note "Then your text, which is where riders see the clock time."
  @oba_note "Then your text as a footnote, so the deadline appears twice."

  # The prototype's words for the calendars a detour service runs on, keyed by
  # the calendar's name, so an imported id like "WEEKDAY" still reads "weekdays".
  @detour_calendar_words %{
    "weekday" => "weekdays",
    "weekdays" => "weekdays",
    "saturday" => "Saturdays",
    "sunday" => "Sundays",
    "school" => "school days",
    "school day" => "school days",
    "school days" => "school days"
  }

  @doc """
  Words the hours of a service as rider-facing lines.

  A detour service names the calendars it runs on and the band that keeps trips
  ("On Route 20 trips: weekdays and Saturdays, 9:00 am–3:00 pm only"). An area
  service groups its hours rows by area and calendar in the order they are
  stored, prefixes an area's name when the row names one ("Toledo only: …"), and
  joins several windows for the same area and calendar with " and ". An end at
  or before the start is the next day and reads " (next day)".
  """
  @spec hours_lines(FlexService.t(), [FlexArea.t()], map()) :: [String.t()]
  def hours_lines(%FlexService{kind: :detour} = service, _areas, calendars),
    do: detour_hours_lines(service, calendars)

  def hours_lines(%FlexService{} = service, areas, calendars),
    do: area_hours_lines(service, areas, calendars)

  @doc """
  Builds the deadline lines a trip planner derives from a service's booking
  rules (R7).

  The service-wide rule (`service_id` nil) comes first, followed by the Monday
  sentence when it books one business day ahead on an office-days calendar, then
  one line per calendar-scoped rule of an area service ("Saturday trips: book by
  12:00 pm 2 days before"). A detour service has exactly one rule, so it never
  renders a calendar-scoped line.
  """
  @spec deadline_lines(FlexService.t(), map()) :: [String.t()]
  def deadline_lines(%FlexService{} = service, calendars) do
    service_wide =
      case main_rule(service) do
        nil -> []
        rule -> main_lines(rule)
      end

    service_wide ++ calendar_rule_lines(service, calendars)
  end

  defp main_lines(rule) do
    case deadline_text(rule) do
      "" -> []
      line -> [line | monday_line(rule)]
    end
  end

  @doc """
  The text riders read: the eligibility sentence, the deadline sentences, how to
  book, then the staff note (R5, R7).

  A registered-riders service starts with "For registered riders only: …" and
  keeps an eligibility that already starts with capitals ("ADA paratransit card
  holders"), because that is how the agency wrote it.
  """
  @spec message(FlexService.t(), map()) :: String.t()
  def message(%FlexService{} = service, calendars) do
    [
      eligibility_sentence(service),
      Enum.map_join(deadline_lines(service, calendars), " ", &(&1 <> ".")),
      how_to_book(service),
      note(service)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  @doc """
  The name trip planners show this service under (R5).

  A registered-riders service that is included in the flex feed gains
  " (registered riders)" unless its name already says who it is for
  (`registered`, `paratransit`, `ADA`, `senior` or `eligib`, any case).
  """
  @spec rider_name(FlexService.t()) :: String.t()
  def rider_name(%FlexService{riders: :registered, include_registered: true, name: name})
      when is_binary(name) and name != "" do
    if Regex.match?(@qualified, name), do: name, else: name <> @registered_suffix
  end

  def rider_name(%FlexService{name: name}), do: name || ""

  @doc """
  The instruction shown for a detour service that lets riders get off away from
  the route, and nil when it does not (`dropoffs: :book`) or for an area service.
  """
  @spec drop_off_message(FlexService.t()) :: String.t() | nil
  def drop_off_message(%FlexService{kind: :detour, dropoffs: dropoffs}) when dropoffs != :book,
    do: @drop_off

  def drop_off_message(%FlexService{}), do: nil

  @doc """
  How three trip planners render one booking rule, as `{app, line, note}`.

  Transit and OneBusAway word the deadline from the fields; OpenTripPlanner's
  web app shows a day count and relies on the rider text for the clock time. The
  OneBusAway rendering of a business-days rule says "the Friday before" rather
  than a fixed date (CR-9).
  """
  @spec app_renderings(FlexBookingRule.t()) :: [{String.t(), String.t(), String.t()}]
  def app_renderings(%FlexBookingRule{} = rule) do
    [
      {"Transit app", transit_line(rule), @transit_note},
      {"OpenTripPlanner planners", otp_line(rule), @otp_note},
      {"OneBusAway (in development)", onebusaway_line(rule), @oba_note}
    ]
  end

  defp detour_hours_lines(service, calendars) do
    words =
      Enum.map(service.calendar_service_ids, &detour_calendar_word(&1, calendars))

    case words do
      [] ->
        ["No trips chosen"]

      words ->
        [
          "On Route #{service.route_id} trips: #{Enum.join(words, " and ")}#{band_suffix(service)}"
        ]
    end
  end

  defp detour_calendar_word(service_id, calendars) do
    name = calendar_name(calendars, service_id)

    Map.get(@detour_calendar_words, String.downcase(name), calendar_plural(calendars, service_id))
  end

  defp band_suffix(%FlexService{band_start: start, band_end: finish})
       when is_binary(start) and is_binary(finish),
       do: ", #{range_text(%{start: start, end: finish})} only"

  defp band_suffix(%FlexService{}), do: ""

  defp area_hours_lines(service, areas, calendars) do
    lines =
      service.hours
      |> group_hours()
      |> Enum.map(fn {{area_key, service_id}, rows} ->
        prefix = if area_key in [nil, ""], do: "", else: "#{area_name(areas, area_key)} only: "
        windows = Enum.map_join(rows, " and ", &range_text/1)
        "#{prefix}#{calendar_plural(calendars, service_id)} #{windows}"
      end)

    if lines == [], do: ["No hours yet"], else: lines
  end

  # Hours rows are grouped by area and calendar in the order they first appear,
  # so a service's lines keep the order staff wrote them in.
  defp group_hours(hours) do
    Enum.reduce(hours, [], fn row, groups ->
      key = {row.area_key, row.service_id}

      case List.keyfind(groups, key, 0) do
        nil -> groups ++ [{key, [row]}]
        {^key, rows} -> List.keyreplace(groups, key, 0, {key, rows ++ [row]})
      end
    end)
  end

  defp area_name(areas, area_key) do
    case Enum.find(areas, &(&1.key == area_key)) do
      %FlexArea{name: name} when is_binary(name) and name != "" -> name
      _other -> area_key
    end
  end

  defp main_rule(service), do: Enum.find(service.booking_rules, &is_nil(&1.service_id))

  defp monday_line(%FlexBookingRule{when: :earlier_day, business_days: true, days: 1} = rule),
    do: ["Book Monday trips by #{t12(rule.by)} the Friday before"]

  defp monday_line(%FlexBookingRule{}), do: []

  # R7: a detour service has exactly one rule, so only an area service renders
  # its calendar-scoped rules.
  defp calendar_rule_lines(%FlexService{kind: :detour}, _calendars), do: []

  defp calendar_rule_lines(service, calendars) do
    service.booking_rules
    |> Enum.reject(&is_nil(&1.service_id))
    |> Enum.map(fn rule ->
      "#{calendar_name(calendars, rule.service_id)} trips: #{lowercase_first(deadline_text(rule))}"
    end)
  end

  defp eligibility_sentence(%FlexService{riders: :registered} = service) do
    who =
      service.eligibility
      |> to_string()
      |> String.trim()
      |> String.replace_suffix(".", "")
      |> downcase_unless_initialism()

    case who do
      "" -> "For registered riders only."
      who -> "For registered riders only: #{who}."
    end
  end

  defp eligibility_sentence(%FlexService{}), do: nil

  defp downcase_unless_initialism(""), do: ""

  defp downcase_unless_initialism(who) do
    if Regex.match?(~r/\A[A-Z]{2}/, who), do: who, else: lowercase_first(who)
  end

  defp how_to_book(service) do
    how =
      [call_line(service), if(present?(service.booking_url), do: "book online")]
      |> Enum.reject(&is_nil/1)

    case how do
      [] -> nil
      parts -> "#{capitalize_first(Enum.join(parts, " or "))}."
    end
  end

  defp call_line(%FlexService{phone: phone} = service) when is_binary(phone) and phone != "",
    do: "call #{phone}#{phone_hours_suffix(service.phone_hours)}"

  defp call_line(%FlexService{}), do: nil

  defp phone_hours_suffix(%{"days" => days, "from" => from, "to" => to}),
    do: " (#{days} #{t12(from, true)}–#{t12(to, true)})"

  defp phone_hours_suffix(_phone_hours), do: ""

  defp note(service) do
    case service.note |> to_string() |> String.trim() do
      "" -> nil
      note -> note
    end
  end

  defp deadline_text(%FlexBookingRule{when: :now} = rule) do
    if rule.max_days do
      "Book now, or up to #{rule.max_days} days ahead"
    else
      "Book when you’re ready to travel"
    end
  end

  defp deadline_text(%FlexBookingRule{when: :same_day} = rule),
    do: "Book at least #{dur(rule.minutes)} before pickup#{horizon(rule)}"

  defp deadline_text(%FlexBookingRule{when: :earlier_day} = rule) do
    unit = if rule.business_days, do: "business day", else: "day"
    days = days(rule)

    "Book by #{t12(rule.by)} #{days} #{unit}#{plural(days)} before#{horizon(rule)}"
  end

  defp deadline_text(%FlexBookingRule{}), do: ""

  defp horizon(%FlexBookingRule{max_days: nil}), do: ""
  defp horizon(%FlexBookingRule{max_days: max_days}), do: ", up to #{max_days} days ahead"

  defp transit_line(%FlexBookingRule{when: :earlier_day} = rule) do
    case days(rule) do
      1 -> "Book by #{clock_caps(rule.by)} the day before"
      days -> "Book by #{clock_caps(rule.by)} #{days} days before"
    end
  end

  defp transit_line(%FlexBookingRule{when: :same_day} = rule),
    do: "Book #{dur(rule.minutes)} ahead"

  defp transit_line(%FlexBookingRule{}), do: "Book now"

  defp otp_line(%FlexBookingRule{when: :earlier_day} = rule) do
    days = days(rule)
    "Reservation required at least #{days} day#{plural(days)} in advance"
  end

  defp otp_line(%FlexBookingRule{}), do: "Reservation required"

  defp onebusaway_line(%FlexBookingRule{when: :earlier_day, business_days: true} = rule),
    do: "Book by #{t12(rule.by)} the Friday before"

  defp onebusaway_line(%FlexBookingRule{when: :earlier_day} = rule),
    do: "Book by #{t12(rule.by)} the day before your ride"

  defp onebusaway_line(%FlexBookingRule{when: :same_day}), do: "Same-day booking"

  defp onebusaway_line(%FlexBookingRule{}), do: "No notice needed"

  defp days(%FlexBookingRule{days: days}) when is_integer(days), do: days
  defp days(%FlexBookingRule{}), do: 0

  defp dur(minutes) do
    minutes = if is_integer(minutes), do: minutes, else: 0

    [hours_phrase(div(minutes, 60)), minutes_phrase(rem(minutes, 60))]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "0 minutes"
      phrases -> Enum.join(phrases, " ")
    end
  end

  defp hours_phrase(0), do: nil
  defp hours_phrase(1), do: "1 hour"
  defp hours_phrase(hours), do: "#{hours} hours"

  defp minutes_phrase(0), do: nil
  defp minutes_phrase(1), do: "1 minute"
  defp minutes_phrase(minutes), do: "#{minutes} minutes"

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  defp clock_caps(time) do
    time
    |> t12(true)
    |> String.replace("am", "AM")
    |> String.replace("pm", "PM")
  end

  # "7:00 am–6:00 pm", and "6:00 pm–1:00 am (next day)" when the end is the next
  # day (R6).
  defp range_text(%{start: start, end: finish}) do
    "#{t12(start)}–#{t12(finish)}#{if overnight?(start, finish), do: " (next day)"}"
  end

  defp overnight?(start, finish) do
    case {minutes_of(start), minutes_of(finish)} do
      {start_minutes, finish_minutes}
      when is_integer(start_minutes) and is_integer(finish_minutes) ->
        finish_minutes <= start_minutes

      _other ->
        false
    end
  end

  defp t12(time, compact \\ false) do
    case minutes_of(time) do
      nil ->
        ""

      minutes ->
        suffix = if rem(div(minutes, 60), 24) >= 12, do: "pm", else: "am"
        hour = rem(rem(div(minutes, 60), 24) + 11, 12) + 1

        if compact and rem(minutes, 60) == 0 do
          "#{hour} #{suffix}"
        else
          "#{hour}:#{pad(rem(minutes, 60))} #{suffix}"
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

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp calendar_entry(calendars, service_id), do: Map.get(calendars, service_id, %{})

  defp calendar_name(calendars, service_id) do
    calendars |> calendar_entry(service_id) |> Map.get(:name) |> blank_to(service_id)
  end

  defp calendar_plural(calendars, service_id) do
    calendars
    |> calendar_entry(service_id)
    |> Map.get(:plural)
    |> blank_to(calendar_name(calendars, service_id))
  end

  defp blank_to(value, _fallback) when is_binary(value) and value != "", do: value
  defp blank_to(_value, fallback), do: fallback

  defp present?(value), do: is_binary(value) and value != ""

  defp capitalize_first(""), do: ""
  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp lowercase_first(""), do: ""

  defp lowercase_first(<<first::utf8, rest::binary>>),
    do: String.downcase(<<first::utf8>>) <> rest
end
