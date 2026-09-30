defmodule GtfsPlanner.Gtfs.Blocking.RiderOutcomesTest do
  @moduledoc """
  Merge evidence (EV-13) for the pure rider-outcome copy (AC-13, AC-14, CR-3,
  R14): the copy is the corrected one, and the strings asserted here are literals
  copied from spec step 11 rather than captured from the module, so a change to
  the wording fails here rather than silently changing what an editor is told.

  - A same-route close handoff: Google's row says the ride continues only if the
    route is a loop, the turnback hint is present, and OpenTripPlanner with no
    record set infers the link.
  - A route change at the same stop: Google's row says one continuous ride, the
    OTP stay row quotes the to-trip's first stop, and the route-change hint names
    the route, the headsign, the same stop and the wait.
  - A 370 m move: Google's row is unknown, the OTP not-stated row is no stay-on
    link, and the distance hint states the distance.
  - A move with no coordinates: OTP's title is unknown.
  - A stay with a forbidden pickup or drop-off: OTP's row is no stay-on link and
    names the problem, and `pickup_problem/1` returns the same sentence.
  - The four hints are returned in the order route change, turnback, wait,
    distance, and a wait over ten minutes adds the wait hint.
  - Every refusal state's text, with a not-next failure naming the next trip
    where the day type has one and not naming it where it does not.
  - `footnote/0` is the corrected one line under the table.

  The connections are hand-built in the shape `Blocking.Connections.build/1`
  returns, carrying the two trip rows, the gap and the caller's `turnback?`. The
  module reads no database, clock, file or network.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 mix test
  test/gtfs_planner/gtfs/blocking/rider_outcomes_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.RiderOutcomes

  describe "hints/1" do
    test "a same-route turnback at one stop explains the loop rule" do
      connection =
        connection(
          from: trip(1, "R24", 0, headsign: "Fairmont"),
          to: trip(2, "R24", 1, headsign: "Union Station"),
          handoff: :same_stop,
          turnback?: true
        )

      assert [%{kind: :turnback, text: text}] = RiderOutcomes.hints(connection)

      assert text ==
               "Route R24 turns back here toward Union Station. Google offers staying on within one " <>
                 "route only for loop routes. Transit's converter treats a next trip that " <>
                 "retraces this one as must re-board, unless both ends are within 500 m."
    end

    test "a route change at the same stop names the route, headsign, stop and wait" do
      connection =
        connection(
          from: trip(1, "R12", 0, headsign: "Fairmont"),
          to:
            trip(2, "R24", 0,
              headsign: "Union Station",
              first_stop: stop("UNION", "Union Station")
            ),
          handoff: :same_stop,
          gap_secs: 240
        )

      assert [%{kind: :route_change, text: text}] = RiderOutcomes.hints(connection)

      assert text ==
               "Continues as Route R24 to Union Station from the same stop after 4 min."
    end

    test "each close handoff reads the way the editor sees it" do
      assert [%{text: station}] =
               connection(
                 from: trip(1, "R12"),
                 to: trip(2, "R24"),
                 handoff: :same_station,
                 gap_secs: 60
               )
               |> RiderOutcomes.hints()

      assert station =~ "from another stop in the same station after 1 min."

      assert [%{text: nearby}] =
               connection(
                 from: trip(1, "R12"),
                 to: trip(2, "R24"),
                 handoff: {:nearby, 60},
                 gap_secs: 60
               )
               |> RiderOutcomes.hints()

      assert nearby =~ "from a stop 60 m away after 1 min."

      assert [%{text: moves}] =
               connection(
                 from: trip(1, "R12"),
                 to: trip(2, "R24"),
                 handoff: {:moves, 370},
                 gap_secs: 60
               )
               |> RiderOutcomes.hints()

      assert moves =~ "from another stop after 1 min."
    end

    test "a wait over ten minutes adds the wait hint" do
      connection =
        connection(
          from: trip(1, "R12"),
          to: trip(2, "R24"),
          handoff: :same_stop,
          gap_secs: 14 * 60
        )

      assert [%{kind: :wait, text: text}] = RiderOutcomes.hints(connection)

      assert text ==
               "The vehicle waits 14 min. Transit's converter treats waits over 10 min as must " <>
                 "re-board and over 20 min as unlinked. OpenTripPlanner has no wait limit."
    end

    test "the hints come back in the order route change, turnback, wait, distance" do
      connection =
        connection(
          from: trip(1, "R12", 0),
          to: trip(2, "R24", 1, headsign: "Union Station"),
          handoff: {:moves, 370},
          gap_secs: 14 * 60,
          turnback?: true
        )

      assert Enum.map(RiderOutcomes.hints(connection), & &1.kind) ==
               [:route_change, :turnback, :wait, :distance]
    end

    test "a move states its distance and an unmeasured move states no distance" do
      assert [%{text: distance}] =
               connection(
                 from: trip(1, "R12"),
                 to: trip(2, "R24"),
                 handoff: {:moves, 370},
                 gap_secs: 60
               )
               |> RiderOutcomes.hints()

      assert distance ==
               "Stops are 370 m apart; the vehicle moves empty between them. OpenTripPlanner " <>
                 "infers staying on only within 200 m but honours \"Riders stay on board\" at " <>
                 "any distance. Transit's converter says re-board beyond 500 m."

      # An unmeasured move states no distance; the route change it does carry is
      # the only hint that survives.
      assert Enum.map(
               connection(
                 from: trip(1, "R12"),
                 to: trip(2, "R24"),
                 handoff: {:moves, nil},
                 gap_secs: 60
               )
               |> RiderOutcomes.hints(),
               & &1.kind
             ) == [:route_change]
    end

    test "a trip with no headsign leaves the sentence naming the route alone" do
      connection =
        connection(
          from: trip(1, "R12"),
          to: trip(2, "R24", 0, headsign: nil),
          handoff: :same_stop,
          gap_secs: 240
        )

      assert [%{text: text}] = RiderOutcomes.hints(connection)

      assert text == "Continues as Route R24 from the same stop after 4 min."
    end
  end

  describe "rows/2" do
    test "the three rows come back Google Maps, OpenTripPlanner and the Transit app" do
      connection = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: :same_stop)

      assert Enum.map(RiderOutcomes.rows(connection, :none), & &1.app) ==
               ["Google Maps", "OpenTripPlanner", "Transit app"]
    end

    test "a close route change tells riders one continuous ride, whatever the choice" do
      connection = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: :same_stop)

      for setting <- [:none, :stay, :reboard, :conflict] do
        assert [google, _otp, _transit] = RiderOutcomes.rows(connection, setting)

        assert google == %{
                 app: "Google Maps",
                 title: "Shows one continuous ride",
                 detail:
                   "Tells riders to stay on the vehicle, from the shared block. Google Maps " <>
                     "ignores this setting."
               }
      end
    end

    test "a close same-route handoff offers Google's ride only for a loop route" do
      connection = connection(from: trip(1, "R24"), to: trip(2, "R24"), handoff: :same_station)

      assert [google, _otp, _transit] = RiderOutcomes.rows(connection, :stay)

      assert google == %{
               app: "Google Maps",
               title: "Only if Route R24 is a loop",
               detail:
                 "Google offers staying on within one route only for loop routes. It ignores " <>
                   "this setting."
             }
    end

    test "a move is unknown to Google whatever the choice" do
      connection = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: {:moves, 370})

      for setting <- [:none, :stay, :reboard, :conflict] do
        assert [google, _otp, _transit] = RiderOutcomes.rows(connection, setting)

        assert google == %{
                 app: "Google Maps",
                 title: "Unknown",
                 detail:
                   "Google needs the same or a physically close stop and publishes no " <>
                     "distance. It ignores this setting."
               }
      end
    end

    test "a stay quotes the to-trip's first stop" do
      connection =
        connection(
          from: trip(1, "R12"),
          to: trip(2, "R24", first_stop: stop("UNION", "Union Station")),
          handoff: {:moves, 370}
        )

      assert [_google, otp, transit] = RiderOutcomes.rows(connection, :stay)

      assert otp == %{
               app: "OpenTripPlanner",
               title: "Stay on board",
               detail:
                 "Shows \"Stay on board at Union Station\" and counts no transfer, with no " <>
                   "distance or time check."
             }

      assert transit == %{
               app: "Transit app",
               title: "Stay on board",
               detail: "Follows this setting."
             }
    end

    test "a forbidden pickup or drop-off makes the stay row a dropped record" do
      pickup =
        connection(
          from: trip(1, "R12"),
          to:
            trip(2, "R24",
              first_stop: stop("UNION", "Union Station"),
              first_pickup_type: 1
            ),
          handoff: :same_stop
        )

      problem = "Trip TRIP-2 doesn't allow pickup at its first stop, Union Station."

      assert RiderOutcomes.pickup_problem(pickup) == problem
      assert [_google, otp, _transit] = RiderOutcomes.rows(pickup, :stay)

      assert otp == %{
               app: "OpenTripPlanner",
               title: "No stay-on link",
               detail: "OpenTripPlanner drops this record. " <> problem
             }

      drop_off =
        connection(
          from:
            trip(1, "R12",
              last_stop: stop("FAIR", "Fairmont"),
              last_drop_off_type: 1
            ),
          to: trip(2, "R24"),
          handoff: :same_stop
        )

      assert RiderOutcomes.pickup_problem(drop_off) ==
               "Trip TRIP-1 doesn't allow drop-off at its last stop, Fairmont."

      assert [_google, otp, _transit] = RiderOutcomes.rows(drop_off, :stay)
      assert otp.title == "No stay-on link"
    end

    test "a stay the handoff allows raises no problem" do
      connection = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: :same_stop)

      assert RiderOutcomes.pickup_problem(connection) == nil
    end

    test "a re-board removes the link OTP would infer, whatever the handoff" do
      for handoff <- [:same_stop, :same_station, {:nearby, 60}, {:moves, 370}, {:moves, nil}] do
        connection = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: handoff)

        assert [_google, otp, transit] = RiderOutcomes.rows(connection, :reboard)

        assert otp == %{
                 app: "OpenTripPlanner",
                 title: "No stay-on link",
                 detail:
                   "Removes the link it would infer. Shows an ordinary transfer if it offers one."
               }

        assert transit == %{
                 app: "Transit app",
                 title: "Get off and board again",
                 detail: "Follows this setting."
               }
      end
    end

    test "not stated reports what OTP infers from the block" do
      close = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: :same_stop)

      assert [_google, otp, transit] = RiderOutcomes.rows(close, :none)

      assert otp == %{
               app: "OpenTripPlanner",
               title: "Stay on board",
               detail:
                 "Inferred from the block: stops within 200 m (OpenTripPlanner's default), " <>
                   "whatever the wait."
             }

      assert transit == %{
               app: "Transit app",
               title: "Decides from the block",
               detail: "Uses its own wait, distance and turnback rules."
             }

      moved = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: {:moves, 370})

      assert [_google, otp, _transit] = RiderOutcomes.rows(moved, :none)

      assert otp == %{
               app: "OpenTripPlanner",
               title: "No stay-on link",
               detail: "Stops are more than 200 m apart (OpenTripPlanner's default)."
             }

      unknown = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: {:moves, nil})

      assert [_google, otp, _transit] = RiderOutcomes.rows(unknown, :none)

      assert otp == %{
               app: "OpenTripPlanner",
               title: "Unknown",
               detail: "Stop coordinates are missing, so the distance is unknown."
             }
    end

    test "a conflict reads as not stated" do
      connection = connection(from: trip(1, "R12"), to: trip(2, "R24"), handoff: :same_stop)

      assert RiderOutcomes.rows(connection, :conflict) == RiderOutcomes.rows(connection, :none)
    end
  end

  describe "footnote/0" do
    test "names Transit delay propagation and OneBusAway" do
      assert RiderOutcomes.footnote() ==
               "Transit can carry delays into the next trip from the block or from either record. " <>
                 "OneBusAway shows \"Continues as\" from the block and ignores this setting."
    end
  end

  describe "refusal_text/1" do
    test "a not-next failure naming the next trip says which trip runs instead" do
      text =
        RiderOutcomes.refusal_text(
          {:stale,
           {:not_next,
            [
              %{
                key: "weekday",
                label: "Weekday",
                date_count: 143,
                next_trip_id: "X"
              }
            ]}}
        )

      assert text ==
               "On Weekday, 143 dates, trip X runs next on this vehicle, so these trips aren't " <>
                 "one vehicle on every date they share."
    end

    test "a not-next failure with no next trip says only that they are not consecutive" do
      text =
        RiderOutcomes.refusal_text(
          {:stale,
           {:not_next, [%{key: "weekday", label: "Weekday", date_count: 38, next_trip_id: nil}]}}
        )

      assert text == "On Weekday, 38 dates, these trips aren't consecutive on one vehicle."
    end

    test "every day type's failure is one sentence" do
      text =
        RiderOutcomes.refusal_text(
          {:stale,
           {:not_next,
            [
              %{key: "weekday", label: "Weekday", date_count: 143, next_trip_id: "X"},
              %{key: "saturday", label: "Saturday", date_count: 38, next_trip_id: nil}
            ]}}
        )

      assert text ==
               "On Weekday, 143 dates, trip X runs next on this vehicle, so these trips aren't " <>
                 "one vehicle on every date they share. " <>
                 "On Saturday, 38 dates, these trips aren't consecutive on one vehicle."
    end

    test "the remaining states each have their own sentence" do
      assert RiderOutcomes.refusal_text({:unconfirmed, :coupling}) ==
               "The second trip starts before the first one ends, so they can't be one vehicle " <>
                 "in sequence."

      assert RiderOutcomes.refusal_text({:unconfirmed, :untimed}) ==
               "A trip has missing or repeating times, so this connection can't be checked."

      assert RiderOutcomes.refusal_text({:unconfirmed, :next_service_day}) ==
               "The second trip runs on the next service day, which this view can't set."

      assert RiderOutcomes.refusal_text({:stale, :no_block}) == "A trip has no block."
      assert RiderOutcomes.refusal_text({:stale, :no_shared_date}) == "The trips share no date."

      assert RiderOutcomes.refusal_text({:stale, :trip_missing}) ==
               "A trip isn't in this version."

      assert RiderOutcomes.refusal_text({:stale, :stops_changed}) ==
               "The record's stops changed."
    end

    test "a matching record is not a refusal" do
      assert RiderOutcomes.refusal_text(:matches) == nil
    end
  end

  # One connection in the shape `Blocking.Connections.build/1` returns: the two
  # trips, the gap between them and the caller's turnback fact.
  defp connection(opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    handoff = Keyword.get(opts, :handoff, :same_stop)
    gap_secs = Keyword.get(opts, :gap_secs, 300)

    %{
      from: from,
      to: to,
      turnback?: Keyword.get(opts, :turnback?, false),
      gap: %{
        from_id: from.id,
        to_id: to.id,
        gap_secs: gap_secs,
        handoff: handoff
      }
    }
  end

  defp trip(number, route_id, direction_id \\ 0, opts \\ []) do
    %{
      id: uuid(number),
      trip_id: "TRIP-#{number}",
      route_id: route_id,
      service_id: "WEEK",
      block_id: "101",
      direction_id: direction_id,
      trip_headsign: Keyword.get(opts, :headsign, "Terminus"),
      route_pattern_id: nil,
      shape_id: nil,
      updated_at: ~U[2026-09-01 12:00:00Z],
      frequency?: false,
      headway_secs: nil,
      first_arrival: 1_800,
      first_departure: 1_800,
      last_arrival: 2_000,
      last_departure: 2_000,
      first_pickup_type: Keyword.get(opts, :first_pickup_type, 0),
      last_drop_off_type: Keyword.get(opts, :last_drop_off_type, 0),
      first_stop: Keyword.get(opts, :first_stop),
      last_stop: Keyword.get(opts, :last_stop),
      plottable?: true
    }
  end

  defp stop(stop_id, name) do
    %{
      stop_id: stop_id,
      name: name,
      parent_station: nil,
      parent_name: nil,
      lat: 38.9,
      lon: -77.0
    }
  end

  defp uuid(number) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
  end
end
