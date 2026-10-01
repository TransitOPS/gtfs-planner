defmodule GtfsPlanner.Alerts.CompletionTest do
  @moduledoc """
  Step 3: `Completion` derives the effect from the situation and reports the
  questions each situation still has to answer (R9, AC-3).

  The expected effects and messages here are literals from the spec's rules, not
  values recomputed by the module under test.
  """

  use GtfsPlanner.DataCase

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Completion
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer.TripTarget
  alias GtfsPlanner.Alerts.TimingAnswer

  @route_id "11111111-1111-1111-1111-111111111111"
  @stop_id "22222222-2222-2222-2222-222222222222"
  @other_stop_id "33333333-3333-3333-3333-333333333333"
  @trip_id "44444444-4444-4444-4444-444444444444"
  @alternative_stop_id "55555555-5555-5555-5555-555555555555"

  describe "effect_for/1" do
    test "no situation derives no effect" do
      assert Completion.effect_for(alert()) == nil
    end

    test "a detour with skipped stops is a detour" do
      assert Completion.effect_for(alert(situation: :detour, scope: scope(stop_ids: [@stop_id]))) ==
               :detour
    end

    test "a detour with a from-to stretch is a detour" do
      alert =
        alert(
          situation: :detour,
          scope: scope(stretch_from_stop_id: @stop_id, stretch_to_stop_id: @other_stop_id)
        )

      assert Completion.effect_for(alert) == :detour
    end

    test "a detour with no skipped stops derives no effect" do
      alert = alert(situation: :detour, scope: scope())

      assert Completion.effect_for(alert) == nil
    end

    test "a delay is significant delays" do
      assert Completion.effect_for(alert(situation: :delay)) == :significant_delays
    end

    test "a moved stop stays a moved stop" do
      assert Completion.effect_for(alert(situation: :stop_moved)) == :stop_moved
    end

    test "a closed stop is no service" do
      assert Completion.effect_for(alert(situation: :stop_closed)) == :no_service
    end

    test "a suspension is no service" do
      assert Completion.effect_for(alert(situation: :suspension, scope: scope(shape: :system))) ==
               :no_service
    end

    test "cancelled trips are no service" do
      alert = alert(situation: :cancelled_trips, scope: scope(trips: [trip(@trip_id)]))

      assert Completion.effect_for(alert) == :no_service
    end

    test "an accessibility issue stays an accessibility issue" do
      assert Completion.effect_for(alert(situation: :accessibility)) == :accessibility_issue
    end

    test "service change follows the chosen change" do
      for {kind, effect} <- [
            {:fewer_trips, :reduced_service},
            {:extra_service, :additional_service},
            {:information, :other_effect}
          ] do
        alert = alert(situation: :service_change, service_change_kind: kind)

        assert Completion.effect_for(alert) == effect
      end
    end

    test "service change without a chosen change derives no effect" do
      assert Completion.effect_for(alert(situation: :service_change)) == nil
    end
  end

  describe "errors/1" do
    test "a detour with no skipped stops is reported on its stops step" do
      alert = alert(situation: :detour, scope: scope())

      assert {:stops, :stop_ids, message} = error_on(alert, :stops)
      assert message == "All stops still served — this is a delay"
    end

    test "a detour with skipped stops has no stops error" do
      errors = Completion.errors(alert(situation: :detour, scope: scope(stop_ids: [@stop_id])))

      refute :stops in steps(errors)
    end

    test "a moved stop without an alternative is reported on its alternative step" do
      alert = alert(situation: :stop_moved, scope: scope(stop_ids: [@stop_id]))

      assert {:alternative, :alternative_stop_id, _message} = error_on(alert, :alternative)
    end

    test "a moved stop with an alternative stop has no alternative error" do
      alert =
        alert(
          situation: :stop_moved,
          scope: scope(stop_ids: [@stop_id], alternative_stop_id: @alternative_stop_id)
        )

      assert :alternative not in steps(Completion.errors(alert))
    end

    test "a moved stop with written directions has no alternative error" do
      alert =
        alert(
          situation: :stop_moved,
          scope: scope(stop_ids: [@stop_id], alternative_directions: "Board at Elm and 3rd.")
        )

      assert :alternative not in steps(Completion.errors(alert))
    end

    test "an estimated end without a check-in is reported on the timing step" do
      alert = alert(timing: struct(now_timing(), end_kind: :estimated))

      assert {:timing, :check_in_at, _message} = error_on(alert, :timing)
    end

    test "an estimated end with a check-in has no timing error" do
      alert =
        alert(
          timing: struct(now_timing(), end_kind: :estimated, check_in_at: ~N[2026-10-05 15:00:00])
        )

      assert :timing not in steps(Completion.errors(alert))
    end

    test "a confirmed end without an end date is reported on the timing step" do
      alert = alert(timing: struct(now_timing(), end_date: nil))

      assert {:timing, :end_date, _message} = error_on(alert, :timing)
    end

    test "an unanswered timing answer is reported on the timing step" do
      assert {:timing, :timing, _message} = error_on(alert(timing: nil), :timing)
    end

    test "cancelled trips with departures and no timing answer have no timing error" do
      alert =
        alert(situation: :cancelled_trips, timing: nil, scope: scope(trips: [trip(@trip_id)]))

      assert :timing not in steps(Completion.errors(alert))
    end

    test "cancelled trips with no departures are reported on the departures step" do
      alert = alert(situation: :cancelled_trips, timing: nil, scope: scope())

      assert {:departures, :trips, _message} = error_on(alert, :departures)
    end

    test "a missing header is reported on the message step" do
      alert = alert(message: %MessageAnswer{description: "Take Route 1 instead."})

      assert {:message, :header, _message} = error_on(alert, :message)
    end

    test "a missing description is reported on the message step" do
      alert = alert(message: %MessageAnswer{header: "Route 12 detour"})

      assert {:message, :description, _message} = error_on(alert, :message)
    end

    test "a missing urgency is reported on the urgency step" do
      assert {:urgency, :urgency, _message} = error_on(alert(urgency: nil), :urgency)
    end

    test "a missing situation is reported on the situation step" do
      assert {:situation, :situation, _message} = error_on(alert(situation: nil), :situation)
    end

    test "a delay with no scope answer is reported on its routes step" do
      assert {:routes, :route_ids, _message} = error_on(alert(scope: nil), :routes)
    end

    test "a closed stop with no scope answer is reported on its place step" do
      alert = alert(situation: :stop_closed, scope: nil)

      assert {:place, :stop_ids, _message} = error_on(alert, :place)
    end

    test "a whole-system suspension needs no route answer" do
      alert = alert(situation: :suspension, scope: scope(shape: :system))

      assert :routes not in steps(Completion.errors(alert))
    end

    test "a planned alert with no recurrence pattern is reported on the timing step" do
      alert =
        alert(urgency: :planned, timing: struct(planned_timing(), first_date: ~D[2026-10-05]))

      assert [{:timing, :pattern, _message}] = Completion.errors(alert)
    end

    test "a planned weekly alert with its recurrence answered has no timing error" do
      alert =
        alert(
          urgency: :planned,
          timing:
            struct(planned_timing(),
              pattern: :weekly,
              first_date: ~D[2026-10-05],
              weeks: 2,
              weekdays: [1, 2, 3, 4, 5]
            )
        )

      assert :timing not in steps(Completion.errors(alert))
    end

    test "a continuous planned period without a last date is reported on the timing step" do
      alert =
        alert(
          urgency: :planned,
          timing: struct(planned_timing(), pattern: :continuous, first_date: ~D[2026-10-05])
        )

      assert {:timing, :last_date, _message} = error_on(alert, :timing)
    end
  end

  describe "complete?/1" do
    test "a fully answered delay is complete" do
      alert = alert(situation: :delay)

      assert Completion.errors(alert) == []
      assert Completion.complete?(alert)
    end

    test "an other-cause alert with a blank explanation is complete" do
      alert =
        alert(
          situation: :delay,
          cause: :other_cause,
          cause_detail: "   "
        )

      assert Completion.errors(alert) == []
      assert Completion.complete?(alert)
    end

    test "an unanswered alert is not complete" do
      refute Completion.complete?(struct!(Alert, %{}))
    end

    test "an alert missing one message field is not complete" do
      refute Completion.complete?(
               alert(situation: :delay, message: %MessageAnswer{header: "Delay"})
             )
    end
  end

  defp error_on(alert, step) do
    matches =
      Enum.filter(Completion.errors(alert), fn {candidate, _field, _message} ->
        candidate == step
      end)

    assert [error] = matches
    error
  end

  defp steps(errors), do: Enum.map(errors, fn {step, _field, _message} -> step end)

  defp alert(overrides \\ %{}) do
    defaults = %{
      urgency: :now,
      situation: :delay,
      scope: scope(),
      timing: now_timing(),
      message: message()
    }

    struct!(Alert, Map.merge(defaults, overrides))
  end

  defp scope(overrides \\ %{}) do
    struct!(ScopeAnswer, Map.merge(%{shape: :route_direction, route_ids: [@route_id]}, overrides))
  end

  defp now_timing do
    %TimingAnswer{
      start_date: ~D[2026-10-05],
      start_time: ~T[08:00:00],
      end_kind: :confirmed,
      end_date: ~D[2026-10-06]
    }
  end

  defp planned_timing do
    %TimingAnswer{start_time: ~T[20:00:00], end_kind: :confirmed, end_date: ~D[2026-10-16]}
  end

  defp message do
    %MessageAnswer{header: "Route 12 detour", description: "Board Route 4 at Elm and 3rd."}
  end

  defp trip(trip_id) do
    %TripTarget{trip_id: trip_id, service_date: ~D[2026-10-05]}
  end
end
