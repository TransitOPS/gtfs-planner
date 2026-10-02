defmodule GtfsPlanner.Alerts.FeedPeriods do
  @moduledoc """
  Compiles an alert's civil timing answer into the explicit UTC periods a public
  realtime feed carries.

  Authoring stores civil `Date`, `Time` and `NaiveDateTime` values plus the IANA
  zone name the agency wrote them in, because that is what the operator entered
  and what the editor shows back. A public feed needs the opposite: absolute
  instants. This module is the single conversion between the two, and it resolves
  them with the standard `DateTime` and the pinned `tzdata` dependency rather
  than a second time utility library.

  Three civil-time rules drive the result:

    * An all-day period and an overnight period end at *civil* midnight, so a
      spring-forward day is a 23-hour period and a fall-back day is 25 hours. The
      end is never the start plus 86,400 seconds.
    * A wall clock reading that does not exist (a DST gap) is a correction the
      operator must make, and a reading that exists twice (a DST fold) is a
      choice the operator must save. Neither is ever resolved by taking the
      first offset: a fold returns both alternatives keyed to that specific local
      occurrence in that specific zone, and a gap names the civil window that
      does exist.
    * An unknown or estimated end stays open. `check_in_at` is an internal
      operator aid and never becomes a period end, so a check-in can never
      expire a rider alert.

  `Recurrence.occurrences/1` still owns which civil dates a pattern covers, with
  its existing 366-day and 400-occurrence bounds; `GtfsTime` still owns parsing
  GTFS service times, which may run past 24:00. This module only resolves civil
  readings into instants, and returns `{:error, field_errors}` for a reading it
  cannot resolve without guessing.

  These are pure derivations: nothing here reads the database, writes a row or
  contacts an external service. Zone rules are read from the `:tzdata`
  application, which the application starts as one of its dependencies.
  """

  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Gtfs.GtfsTime

  @seconds_per_day 86_400
  @midnight ~T[00:00:00]
  # `Recurrence` expands a pattern to whole weeks from its first date, so a week
  # is the smallest span a future first date can sit behind `today`.
  @default_lead_days 7

  @type period :: %{start: integer(), end: integer() | nil}
  @type offset_choice :: %{key: String.t(), offset_seconds: integer(), start: integer()}

  @type field_error :: %{
          field: atom(),
          message: String.t(),
          key: String.t() | nil,
          choices: [offset_choice()]
        }

  @type offset_choices :: %{optional(String.t()) => integer()}

  @doc """
  Compiles a timing answer into the notice boundary and active periods a public
  feed serves, in the zone the alert is actually read in.

  `explicit_zone` is the trusted zone to read the civil timing in — the
  organization's explicit alert timezone, or the zone the alert was saved with.
  It wins over `timing.time_zone`; a missing or unusable zone is a field error
  rather than a silent UTC reading, because a UTC fallback is a display
  disclosure, never consent to a publication zone.

  `offset_choices` holds the offsets the operator explicitly saved for
  ambiguous local occurrences, keyed by `choice_key/2`. A fold without a saved
  choice for that exact occurrence and zone is refused; a saved offset that no
  longer matches either alternative is refused too, so a changed zone database
  can never silently reinterpret a choice.

  The zone rules come from the pinned `tzdata` dependency with autoupdate
  disabled, so accepted periods stay stable for the life of a snapshot.
  """
  @spec compile(TimingAnswer.t(), String.t() | nil, offset_choices()) ::
          {:ok, %{notice_at: integer(), periods: [period()]}} | {:error, [field_error()]}
  def compile(%TimingAnswer{} = timing, explicit_zone, offset_choices \\ %{}) do
    with {:ok, zone} <- zone(timing, explicit_zone),
         {:ok, occurrences} <- occurrences(timing),
         {:ok, notice_at} <- notice_at(occurrences, timing, zone),
         {:ok, periods} <- periods(occurrences, timing, zone, offset_choices) do
      {:ok, %{notice_at: notice_at, periods: periods}}
    end
  end

  @doc """
  Resolves one GTFS service time on a service date into an explicit UTC instant.

  GTFS service times continue past midnight, so `25:30:00` on `2026-03-07` is
  01:30 on the *next* civil date. The service date keeps its identity rather
  than being folded back onto the same date, and the offset a fold leaves
  ambiguous is resolved exactly as in `compile/3`: from a saved choice, or not
  at all.
  """
  @spec service_instant(Date.t(), String.t() | GtfsTime.seconds(), String.t(), offset_choices()) ::
          {:ok, integer()} | {:error, [field_error()]}
  def service_instant(%Date{} = service_date, service_time, zone, offset_choices \\ %{}) do
    with {:ok, zone} <- known_zone(zone),
         {:ok, seconds} <- parse_service_time(service_time) do
      resolve(civil(service_date, seconds), :start_time, zone, offset_choices)
    end
  end

  @doc """
  Returns the key an explicit offset choice is saved under.

  One key names one local reading in one zone, so two zones that both fall back
  at the same wall clock, or the same reading in the start and the end of one
  period, stay separate choices.
  """
  @spec choice_key(NaiveDateTime.t(), String.t()) :: String.t()
  def choice_key(%NaiveDateTime{} = naive, zone) when is_binary(zone) do
    zone <> "|" <> NaiveDateTime.to_iso8601(naive)
  end

  # The zone an alert's civil timing is read in: the explicit one first, then the
  # zone the alert was saved with. Neither may be blank, and the name must exist
  # in the pinned zone database.
  defp zone(%TimingAnswer{} = timing, explicit_zone) do
    case usable_zone(explicit_zone) || usable_zone(timing.time_zone) do
      nil -> {:error, [error(:time_zone, "Choose the timezone this alert's times are in.")]}
      zone -> known_zone(zone)
    end
  end

  defp known_zone(zone) do
    case usable_zone(zone) do
      nil ->
        {:error, [error(:time_zone, "Choose the timezone this alert's times are in.")]}

      trimmed ->
        case Tzdata.periods(trimmed) do
          {:error, :not_found} ->
            {:error, [error(:time_zone, "#{trimmed} is not a known timezone.")]}

          _periods ->
            {:ok, trimmed}
        end
    end
  end

  defp usable_zone(zone) when is_binary(zone) do
    case String.trim(zone) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp usable_zone(_zone), do: nil

  defp occurrences(%TimingAnswer{} = timing) do
    case Recurrence.occurrences(timing) do
      {:ok, occurrences} ->
        {:ok, occurrences}

      {:error, :too_many} ->
        {:error,
         [
           error(
             :timing,
             "This timing repeats further ahead than an alert can be published for. " <>
               "Shorten it to #{Recurrence.max_span_days()} days or #{Recurrence.max_occurrences()} dates."
           )
         ]}

      {:error, :incomplete} ->
        {:error, [error(:timing, "This alert's timing is not complete enough to publish.")]}
    end
  end

  # Every occurrence is compiled, so an operator sees every correction the answer
  # needs at once instead of one per attempt. Ambiguity anywhere refuses the
  # whole compile rather than publishing the occurrences that happened to resolve.
  defp periods(occurrences, timing, zone, offset_choices) do
    occurrences
    |> Enum.map(&period(&1, timing, zone, offset_choices))
    |> Enum.reduce({:ok, []}, &collect/2)
    |> case do
      {:ok, periods} -> {:ok, Enum.reverse(periods)}
      {:error, errors} -> {:error, errors}
    end
  end

  defp collect({:ok, period}, {:ok, periods}), do: {:ok, [period | periods]}
  # A period that already resolved is dropped as soon as any occurrence is
  # refused: the whole compile is one answer, not a partially publishable set.
  defp collect({:error, errors}, {:ok, _periods}), do: {:error, errors}
  defp collect({:error, errors}, {:error, collected}), do: {:error, collected ++ errors}

  # An all-day period is the whole civil date, so its end is the next civil
  # midnight: 23 hours across a spring-forward date, 25 across a fall-back one.
  defp period(%{all_day?: true, date: date}, _timing, zone, offset_choices) do
    with {:ok, start} <-
           resolve(NaiveDateTime.new!(date, @midnight), :start_time, zone, offset_choices),
         {:ok, end_instant} <-
           resolve(
             NaiveDateTime.new!(Date.add(date, 1), @midnight),
             :end_time,
             zone,
             offset_choices
           ) do
      {:ok, %{start: start, end: end_instant}}
    end
  end

  defp period(%{starts: nil}, _timing, _zone, _offset_choices) do
    {:error, [error(:start_time, "Choose the time this alert starts.")]}
  end

  defp period(%{starts: starts} = occurrence, timing, zone, offset_choices) do
    with {:ok, start} <- resolve(starts, :start_time, zone, offset_choices),
         {:ok, end_instant} <- end_instant(occurrence, timing, zone, offset_choices) do
      {:ok, %{start: start, end: end_instant}}
    end
  end

  # An unknown or estimated end stays open, and an internal check-in is never
  # read as one: a rider alert must not expire because an operator never
  # checked in, or because recovery was only estimated.
  defp end_instant(%{ends: nil}, _timing, _zone, _offset_choices), do: {:ok, nil}

  defp end_instant(%{ends: ends} = _occurrence, %TimingAnswer{} = timing, zone, offset_choices) do
    if TimingAnswer.closed_end?(timing),
      do: resolve(ends, :end_time, zone, offset_choices),
      else: {:ok, nil}
  end

  defp resolve(%NaiveDateTime{} = naive, field, zone, offset_choices) do
    case DateTime.from_naive(naive, zone, Tzdata.TimeZoneDatabase) do
      {:ok, instant} ->
        {:ok, DateTime.to_unix(instant)}

      {:ambiguous, first, second} ->
        choose_offset(naive, zone, offset_choices, field, [first, second])

      {:gap, just_before, just_after} ->
        {:error, [gap_error(naive, zone, field, just_before, just_after)]}

      {:error, _reason} ->
        {:error, [error(:time_zone, "#{zone} is not a known timezone.")]}
    end
  end

  # A fold is only resolved by a saved choice for this exact reading in this
  # exact zone, and only when the saved offset is still one of the two
  # alternatives. The earlier occurrence is never chosen on the operator's
  # behalf; both are returned so the editor can offer them.
  defp choose_offset(naive, zone, offset_choices, field, alternatives) do
    key = choice_key(naive, zone)

    case Enum.find(alternatives, &(offset_seconds(&1) == Map.get(offset_choices, key))) do
      nil -> {:error, [fold_error(key, zone, naive, field, alternatives)]}
      chosen -> {:ok, DateTime.to_unix(chosen)}
    end
  end

  defp fold_error(key, zone, naive, field, alternatives) do
    choices =
      Enum.map(alternatives, fn instant ->
        %{
          key: key,
          offset_seconds: offset_seconds(instant),
          start: DateTime.to_unix(instant)
        }
      end)

    %{
      field: field,
      message:
        "#{clock(naive)} occurs twice on #{civil_date(naive)} in #{zone} because the clocks go back. " <>
          "Choose which of these two instants applies.",
      key: key,
      choices: choices
    }
  end

  defp gap_error(naive, zone, field, just_before, just_after) do
    first_valid = DateTime.to_time(just_before) |> add_second()
    last_valid = DateTime.to_time(just_after)

    error(
      field,
      "#{clock(naive)} does not exist on #{civil_date(naive)} in #{zone} because the clocks go " <>
        "forward. Choose a time between #{clock_time(first_valid)} and #{clock_time(last_valid)}."
    )
  end

  # The notice boundary is when an accepted snapshot may first be told about this
  # alert. It is derived only from the answer's own civil dates: the date the
  # operator chose, or the `Recurrence` default of at most a week before the
  # first date the alert covers. Nothing here reads a clock, so a snapshot's
  # notice boundary does not move when the snapshot is recompiled, and inclusion
  # is a separate decision the feed makes against the current time.
  defp notice_at(occurrences, timing, zone) do
    case anchor_date(occurrences, timing) do
      %Date{} = anchor_date ->
        {:ok, boundary_instant(notice_date(anchor_date, timing), zone)}

      nil ->
        {:error, [error(:timing, "This alert's timing has no date to publish.")]}
    end
  end

  # The date the alert's civil span is measured from. Every answer that expands
  # to occurrences names one, and a pattern whose dates were all removed still
  # names its first date.
  defp anchor_date(occurrences, %TimingAnswer{} = timing) do
    Enum.find_value(occurrences, & &1.date) || timing.first_date || timing.start_date
  end

  defp notice_date(%Date{} = anchor_date, %TimingAnswer{} = timing) do
    Recurrence.notice_on(timing, Date.add(anchor_date, -@default_lead_days))
  end

  # A notice boundary is a lower bound rather than a period the operator chose,
  # so the earliest real instant of that local midnight is used when the
  # midnight is ambiguous or skipped. Demanding a saved choice for a boundary
  # nobody entered would refuse a correct answer because one zone changed rules.
  defp boundary_instant(%Date{} = date, zone) do
    naive = NaiveDateTime.new!(date, @midnight)

    case DateTime.from_naive(naive, zone, Tzdata.TimeZoneDatabase) do
      {:ok, instant} ->
        DateTime.to_unix(instant)

      {:ambiguous, first, _second} ->
        DateTime.to_unix(first)

      {:gap, _just_before, just_after} ->
        DateTime.to_unix(just_after)

      {:error, _reason} ->
        DateTime.to_unix(DateTime.new!(date, @midnight, "Etc/UTC"))
    end
  end

  defp parse_service_time(seconds) when is_integer(seconds) and seconds >= 0, do: {:ok, seconds}

  defp parse_service_time(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> {:ok, seconds}
      {:error, :invalid_time} -> {:error, [error(:start_time, "Choose a valid start time.")]}
    end
  end

  defp parse_service_time(_value), do: {:error, [error(:start_time, "Choose a start time.")]}

  # A GTFS service time keeps its service date and continues onto the next civil
  # date when it runs past midnight.
  defp civil(%Date{} = service_date, seconds) do
    NaiveDateTime.new!(
      Date.add(service_date, div(seconds, @seconds_per_day)),
      Time.add(@midnight, rem(seconds, @seconds_per_day))
    )
  end

  defp error(field, message), do: %{field: field, message: message, key: nil, choices: []}

  defp add_second(time), do: Time.add(time, 1, :second)

  defp clock(naive), do: clock_time(NaiveDateTime.to_time(naive))

  defp civil_date(naive), do: Date.to_iso8601(NaiveDateTime.to_date(naive))

  # A `DateTime` carries the zone's standard offset and the daylight part
  # separately, so the offset actually in force at that instant is their sum.
  defp offset_seconds(%DateTime{} = instant), do: instant.utc_offset + instant.std_offset

  defp clock_time(%Time{hour: 0, minute: 0}), do: "12:00 AM"

  defp clock_time(%Time{hour: hour, minute: minute}) do
    meridiem = if hour < 12, do: "AM", else: "PM"
    calendar_hour = rem(hour + 11, 12) + 1
    minutes = if minute == 0, do: "", else: ":" <> pad_two(minute)
    "#{calendar_hour}#{minutes} #{meridiem}"
  end

  defp pad_two(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
