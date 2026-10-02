defmodule GtfsPlanner.Alerts.Completion do
  @moduledoc """
  What an alert means and what is still missing from it.

  `effect_for/1` derives the GTFS-Realtime effect from the situation the operator
  chose, never from the message text and never from a form param (R4, R9). The
  effect follows the situation: a detour that skips stops is `:detour`, a delay
  is `:significant_delays`, a stop closure is `:no_service`, and an
  accessibility issue stays an accessibility issue rather than becoming a
  closure. A detour with no skipped stops derives no effect at all, because
  every stop is still served and the draft says so in `errors/1`.

  `errors/1` reports the questions the draft has not answered yet as
  `{step, field, message}` tuples, where `step` is one of the URL step keys the
  editor's step sequence uses. The messages are the copy the editor shows the
  operator, so they are plain words in sentence case.

  `complete?/1` is exactly `errors/1 == []`, so the flag `Alerts.save_draft/4`
  stores and the list of outstanding questions can never disagree.

  These are pure derivations over a `GtfsPlanner.Alerts.Alert` struct: nothing
  here reads the database, writes a row or converts a civil time between zones
  (R12, CR-7).
  """

  alias GtfsPlanner.Alerts.Alert

  # The first step of each situation's sequence that answers "who is this about".
  @scope_step %{
    delay: :routes,
    detour: :routes,
    cancelled_trips: :routes,
    suspension: :routes,
    service_change: :routes,
    stop_moved: :place,
    stop_closed: :place,
    accessibility: :place
  }

  @scope_field %{routes: :route_ids, place: :stop_ids}
  @scope_message %{routes: "Choose at least one route.", place: "Choose the place."}

  @urgency_message "Choose whether riders are affected now or on planned dates."
  @situation_message "Choose what is happening."
  @all_stops_served_message "All stops still served — this is a delay"
  @alternative_message "Give the alternative stop, or describe where to board."
  @departures_message "Choose the cancelled departures."
  @timing_message "Answer when this applies."
  @end_kind_message "Say when this is expected to end."
  @confirmed_end_message "Choose the date it ends."
  @check_in_message "Choose when to check back."
  @start_date_message "Choose the date this started."
  @start_time_message "Choose the time of day this applies."
  @pattern_message "Choose when this repeats."
  @first_date_message "Choose the first date."
  @continuous_end_message "Choose the last date."
  @reversed_period_message "Choose an end date after the start date."
  @weeks_message "Choose how many weeks this repeats."
  @weekdays_message "Choose the days of the week."
  @header_message "Write the headline riders will see."
  @description_message "Describe what to expect and what to do instead."

  @type error :: {step :: atom(), field :: atom(), message :: String.t()}

  @doc """
  The sentence for a period whose last date is before its first, shared with the
  editor's inline message so the question and the review say the same thing.
  """
  @spec reversed_period_message() :: String.t()
  def reversed_period_message, do: @reversed_period_message

  @doc """
  Derives the GTFS-Realtime effect an alert's situation implies, or `nil` when
  the situation is not chosen yet or implies no effect on its own.

  Only a `service_change` reads a second answer. A detour derives `:detour` only
  when it names skipped stops or a stretch, so a draft whose stops are all
  served cannot present itself as a detour (R9).
  """
  @spec effect_for(Alert.t()) :: atom() | nil
  def effect_for(%Alert{situation: nil}), do: nil

  def effect_for(%Alert{situation: :detour} = alert) do
    if detour_skips_stops?(alert), do: :detour
  end

  def effect_for(%Alert{situation: :service_change, service_change_kind: :fewer_trips}),
    do: :reduced_service

  def effect_for(%Alert{situation: :service_change, service_change_kind: :extra_service}),
    do: :additional_service

  def effect_for(%Alert{situation: :service_change, service_change_kind: :information}),
    do: :other_effect

  def effect_for(%Alert{situation: situation}) do
    case situation do
      :delay -> :significant_delays
      :stop_moved -> :stop_moved
      :stop_closed -> :no_service
      :cancelled_trips -> :no_service
      :suspension -> :no_service
      :accessibility -> :accessibility_issue
      _other -> nil
    end
  end

  @doc """
  Lists the questions an alert still has to answer, in step order.

  Every element is `{step, field, message}`, where `step` is a URL step key and
  `field` names the answer that is missing. The list is empty exactly when
  `complete?/1` is true.

  A `cancelled_trips` alert is the one situation with no timing step, so its
  period comes from the service dates of the departures it names (R9).
  """
  @spec errors(Alert.t()) :: [error()]
  def errors(%Alert{} = alert) do
    urgency_errors(alert) ++
      situation_errors(alert) ++
      scope_errors(alert) ++
      situation_rule_errors(alert) ++
      timing_errors(alert) ++
      message_errors(alert)
  end

  @doc """
  Returns true when the alert has answered every question its situation asks for.
  """
  @spec complete?(Alert.t()) :: boolean()
  def complete?(%Alert{} = alert), do: errors(alert) == []

  defp urgency_errors(%Alert{urgency: nil}), do: [{:urgency, :urgency, @urgency_message}]
  defp urgency_errors(%Alert{}), do: []

  defp situation_errors(%Alert{situation: nil}),
    do: [{:situation, :situation, @situation_message}]

  defp situation_errors(%Alert{}), do: []

  # Every situation except a whole-system suspension names who it is about, and
  # each names it on a different step. The step decides which field answers it:
  # a place question is answered by a stop, a routes question by a route, so a
  # stop closure holding only routes still has to name its place.
  defp scope_errors(%Alert{situation: situation} = alert) do
    case Map.fetch(@scope_step, situation) do
      {:ok, step} ->
        if scope_answered?(scope(alert), step) do
          []
        else
          [{step, Map.fetch!(@scope_field, step), Map.fetch!(@scope_message, step)}]
        end

      :error ->
        []
    end
  end

  # Rules the situation itself imposes beyond naming the steps it shows.
  defp situation_rule_errors(%Alert{situation: :detour} = alert) do
    if detour_skips_stops?(alert) do
      []
    else
      [{:stops, :stop_ids, @all_stops_served_message}]
    end
  end

  defp situation_rule_errors(%Alert{situation: :stop_moved} = alert) do
    if alternative_answered?(scope(alert)) do
      []
    else
      [{:alternative, :alternative_stop_id, @alternative_message}]
    end
  end

  defp situation_rule_errors(%Alert{situation: :cancelled_trips} = alert) do
    if cancelled_departures(alert) == [] do
      [{:departures, :trips, @departures_message}]
    else
      []
    end
  end

  defp situation_rule_errors(%Alert{}), do: []

  defp timing_errors(%Alert{situation: :cancelled_trips}), do: []

  defp timing_errors(%Alert{timing: nil}), do: [{:timing, :timing, @timing_message}]

  defp timing_errors(%Alert{urgency: :now, timing: timing}) do
    timing_error(timing, is_nil(timing.start_date), :start_date, @start_date_message) ++
      time_of_day_errors(timing) ++
      end_errors(timing)
  end

  # A planned alert is asked Once or Repeats each week, not how it ends: its end
  # is the last date of a continuous period or the weeks and weekdays of a
  # weekly one, which `pattern_errors/1` checks. Only a current alert answers an
  # end kind, so `end_errors/1` belongs to the clause above.
  defp timing_errors(%Alert{timing: timing}) do
    timing_error(timing, is_nil(timing.pattern), :pattern, @pattern_message) ++
      timing_error(timing, is_nil(timing.first_date), :first_date, @first_date_message) ++
      time_of_day_errors(timing) ++
      pattern_errors(timing)
  end

  defp timing_error(_timing, false, _field, _message), do: []

  defp timing_error(_timing, true, field, message), do: [{:timing, field, message}]

  defp time_of_day_errors(%{all_day: true}), do: []
  defp time_of_day_errors(%{start_time: nil}), do: [{:timing, :start_time, @start_time_message}]
  defp time_of_day_errors(%{start_time: _start_time}), do: []

  # A confirmed end expires the alert, so it needs a date. An estimated or
  # unknown end leaves the feed end open, so it needs a check-in instead.
  defp end_errors(%{end_kind: nil}), do: [{:timing, :end_kind, @end_kind_message}]

  defp end_errors(%{end_kind: :confirmed, end_date: nil}),
    do: [{:timing, :end_date, @confirmed_end_message}]

  defp end_errors(%{end_kind: :confirmed} = timing) do
    if reversed_period?(timing.start_date, timing.end_date),
      do: [{:timing, :end_date, @reversed_period_message}],
      else: []
  end

  defp end_errors(%{end_kind: kind, check_in_at: nil}) when kind in [:estimated, :unknown],
    do: [{:timing, :check_in_at, @check_in_message}]

  defp end_errors(%{end_kind: _kind}), do: []

  defp pattern_errors(%{pattern: :continuous, last_date: nil}),
    do: [{:timing, :last_date, @continuous_end_message}]

  defp pattern_errors(%{pattern: :continuous} = timing) do
    if reversed_period?(timing.first_date, timing.last_date),
      do: [{:timing, :last_date, @reversed_period_message}],
      else: []
  end

  defp pattern_errors(%{pattern: :weekly, weeks: nil}), do: [{:timing, :weeks, @weeks_message}]

  defp pattern_errors(%{pattern: :weekly, weekdays: weekdays}) when weekdays in [nil, []],
    do: [{:timing, :weekdays, @weekdays_message}]

  defp pattern_errors(%{pattern: _pattern}), do: []

  defp reversed_period?(%Date{} = first, %Date{} = last), do: Date.compare(last, first) == :lt
  defp reversed_period?(_first, _last), do: false

  defp message_errors(%Alert{message: nil}) do
    [{:message, :header, @header_message}, {:message, :description, @description_message}]
  end

  defp message_errors(%Alert{message: message}) do
    header = if blank?(message.header), do: [{:message, :header, @header_message}], else: []

    description =
      if blank?(message.description),
        do: [{:message, :description, @description_message}],
        else: []

    header ++ description
  end

  defp detour_skips_stops?(%Alert{} = alert) do
    answer = scope(alert)

    present?(answer && answer.stop_ids) or
      (not is_nil(answer && answer.stretch_from_stop_id) and
         not is_nil(answer && answer.stretch_to_stop_id))
  end

  defp alternative_answered?(nil), do: false

  defp alternative_answered?(answer) do
    not is_nil(answer.alternative_stop_id) or present?(answer.alternative_directions)
  end

  defp cancelled_departures(%Alert{} = alert) do
    case scope(alert) do
      nil -> []
      answer -> answer.trips || []
    end
  end

  defp scope_answered?(nil, _step), do: false

  defp scope_answered?(answer, :routes) do
    answer.shape == :system or not is_nil(answer.mode_route_type) or
      present?(answer.route_ids)
  end

  defp scope_answered?(answer, :place), do: present?(answer.stop_ids)

  defp scope(%Alert{scope: answer}), do: answer

  defp present?(nil), do: false
  defp present?(list) when is_list(list), do: list != []
  defp present?(_other), do: true

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
