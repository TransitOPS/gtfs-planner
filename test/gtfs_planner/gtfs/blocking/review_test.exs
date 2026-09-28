defmodule GtfsPlanner.Gtfs.Blocking.ReviewTest do
  @moduledoc """
  Merge evidence (EV-10) for the pure block-change review:

  - An `{A,B}` trip assigned to 101 with no problem on `{A,B}` but an overlap with a
    `{A,C}` trip is listed as added on the `{A,C}` effect and needs confirmation,
    although one trip changes.
  - A safe single-trip assign and a safe single-trip unassign need no confirmation.
  - A two-trip assign needs confirmation although it adds no problem.
  - An overlap present before and after is existing, not added.
  - Moving two of three trips of 101 on another day type splits it with one
    remaining.
  - Assigning into a block that already has trips joins it.
  - An added `:repositions` notice alone does not need confirmation for one trip.
  - A change that makes a type 4/5 record not next adds an `:in_seat_stale` warning
    through the shared `Blocking.InSeat` rule, and a record whose day type the
    command does not touch is never added.
  - The fingerprint is equal for equal input and differs when a locked row's
    `updated_at`, any of its four times, or the resolved target changes.
  - The selected day type is the first effect and `affected_date_count` is the sum
    of the affected day types' dates.

  Every value is derived from R3/AC-12 and hand-written integer clock seconds; the
  module reads no database, clock, files or network. The focused gate command is
  deferred to branch review: `mix test test/gtfs_planner/gtfs/blocking/review_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.{DayTypes, Review}

  @min_layover 5
  @monday ~D[2026-01-05]
  @tuesday ~D[2026-01-06]
  @wednesday ~D[2026-01-07]

  describe "build/1 with a shared trip across day types" do
    test "lists the added overlap on the other day type and needs confirmation" do
      calendars = [
        calendar("A", [@monday, @tuesday], 1),
        calendar("B", [@monday], 1),
        calendar("C", [@tuesday], 1)
      ]

      {monday, tuesday} = two_day_types(calendars, ["A", "B"], ["A", "C"])

      x = trip("x", "A", nil, at(8, 0), at(9, 0))
      b = trip("b", "B", "101", at(10, 0), at(11, 0))
      c = trip("c", "C", "101", at(8, 30), at(9, 30))

      review =
        build(%{
          command: {:assign, [x.id], "101"},
          target: "101",
          selected_key: monday.key,
          affected: DayTypes.containing(DayTypes.derive(calendars), "A"),
          rows: [x, b, c],
          changes: [%{trip: x, from: nil, to: "101"}],
          service_dates: DayTypes.service_dates(calendars)
        })

      assert review.needs_confirmation?
      assert review.added_problem_count == 1
      assert review.affected_date_count == 2
      assert Enum.map(review.effects, & &1.day_type.key) == [monday.key, tuesday.key]

      first = effect(review, monday)
      assert first.selected?
      assert first.added == []
      assert first.changed_trip_ids == [x.id]
      assert first.joins == ["101"]
      assert first.splits == []

      other = effect(review, tuesday)
      refute other.selected?
      assert other.changed_trip_ids == [x.id]

      assert Enum.any?(
               other.added,
               &(&1.code == :overlap and Enum.sort(&1.trip_ids) == ["c", "x"])
             )

      assert other.existing == []
    end
  end

  describe "build/1 confirmation rule" do
    test "a safe single-trip assign needs no confirmation" do
      {day_type, service_dates} = solo_day()
      x = trip("x", "A", nil, at(8, 0), at(9, 0))

      review =
        build(%{
          command: {:assign, [x.id], "7"},
          target: "7",
          selected_key: day_type.key,
          affected: [day_type],
          rows: [x],
          changes: [%{trip: x, from: nil, to: "7"}],
          service_dates: service_dates
        })

      refute review.needs_confirmation?
      assert review.added_problem_count == 0

      assert review.effects == [
               %{
                 day_type: day_type,
                 selected?: true,
                 changed_trip_ids: [x.id],
                 joins: [],
                 splits: [],
                 added: [],
                 existing: []
               }
             ]
    end

    test "a safe single-trip unassign needs no confirmation" do
      {day_type, service_dates} = solo_day()
      p = trip("p", "A", "101", at(8, 0), at(9, 5))
      q = trip("q", "A", "101", at(9, 10), at(10, 0))

      review =
        build(%{
          command: {:unassign, [q.id]},
          target: nil,
          selected_key: day_type.key,
          affected: [day_type],
          rows: [p, q],
          changes: [%{trip: q, from: "101", to: nil}],
          service_dates: service_dates
        })

      refute review.needs_confirmation?
      assert review.added_problem_count == 0
      assert effect(review, day_type).splits == [%{block_id: "101", remaining: 1}]
    end

    test "a two-trip assign needs confirmation although it adds no problem" do
      {day_type, service_dates} = solo_day()
      x1 = trip("x1", "A", nil, at(8, 0), at(9, 0))
      x2 = trip("x2", "A", nil, at(10, 0), at(11, 0))

      review =
        build(%{
          command: {:assign, [x1.id, x2.id], "7"},
          target: "7",
          selected_key: day_type.key,
          affected: [day_type],
          rows: [x1, x2],
          changes: [%{trip: x1, from: nil, to: "7"}, %{trip: x2, from: nil, to: "7"}],
          service_dates: service_dates
        })

      assert review.added_problem_count == 0
      assert review.needs_confirmation?
      assert effect(review, day_type).changed_trip_ids == [x1.id, x2.id]
    end

    test "an overlap present before and after is existing, not added" do
      {day_type, service_dates} = solo_day()
      p = trip("p", "A", "101", at(8, 0), at(9, 0))
      q = trip("q", "A", "101", at(8, 30), at(9, 30))
      x = trip("x", "A", nil, at(10, 0), at(11, 0))

      review =
        build(%{
          command: {:assign, [x.id], "101"},
          target: "101",
          selected_key: day_type.key,
          affected: [day_type],
          rows: [p, q, x],
          changes: [%{trip: x, from: nil, to: "101"}],
          service_dates: service_dates
        })

      result = effect(review, day_type)

      assert Enum.any?(
               result.existing,
               &(&1.code == :overlap and Enum.sort(&1.trip_ids) == ["p", "q"])
             )

      refute Enum.any?(result.added, &(&1.code == :overlap))
      refute review.needs_confirmation?
    end

    test "an added reposition notice alone does not need confirmation for one trip" do
      {day_type, service_dates} = solo_day()
      origin = stop("O", lat: 42.0, lon: -71.0)
      far = stop("F", lat: 42.003058, lon: -71.0)
      b = trip("b", "A", "101", at(6, 0), at(7, 0), last_stop: origin)
      x = trip("x", "A", nil, at(8, 0), at(9, 0), first_stop: far)

      review =
        build(%{
          command: {:assign, [x.id], "101"},
          target: "101",
          selected_key: day_type.key,
          affected: [day_type],
          rows: [b, x],
          changes: [%{trip: x, from: nil, to: "101"}],
          service_dates: service_dates
        })

      result = effect(review, day_type)
      [reposition] = Enum.filter(result.added, &(&1.code == :repositions))
      assert reposition.severity == :notice
      assert reposition.detail.meters == 340
      assert review.added_problem_count == 0
      refute review.needs_confirmation?
    end
  end

  describe "build/1 splits and joins" do
    test "moving two of three trips of 101 splits it on that day type with one remaining" do
      calendars = [
        calendar("A", [@monday, @tuesday], 1),
        calendar("B", [@monday], 0),
        calendar("C", [@tuesday], 0)
      ]

      {monday, tuesday} = two_day_types(calendars, ["A", "B"], ["A", "C"])
      c1 = trip("c1", "A", "101", at(6, 0), at(7, 0))
      c2 = trip("c2", "A", "101", at(8, 0), at(9, 0))
      c3 = trip("c3", "C", "101", at(10, 0), at(11, 0))

      review =
        build(%{
          command: {:assign, [c1.id, c2.id], "202"},
          target: "202",
          selected_key: monday.key,
          affected: DayTypes.containing(DayTypes.derive(calendars), "A"),
          rows: [c1, c2, c3],
          changes: [%{trip: c1, from: "101", to: "202"}, %{trip: c2, from: "101", to: "202"}],
          service_dates: DayTypes.service_dates(calendars)
        })

      assert Enum.map(review.effects, & &1.day_type.key) == [monday.key, tuesday.key]
      assert effect(review, monday).splits == []
      assert effect(review, tuesday).splits == [%{block_id: "101", remaining: 1}]
      assert effect(review, tuesday).joins == []
    end

    test "a new target joins nothing while an existing target joins" do
      {day_type, service_dates} = solo_day()
      b = trip("b", "A", "101", at(10, 0), at(11, 0))
      fresh = trip("fresh", "A", nil, at(8, 0), at(9, 0))
      existing = trip("existing", "A", nil, at(8, 0), at(9, 0))

      new_review =
        build(%{
          command: {:assign, [fresh.id], "7"},
          target: "7",
          selected_key: day_type.key,
          affected: [day_type],
          rows: [b, fresh],
          changes: [%{trip: fresh, from: nil, to: "7"}],
          service_dates: service_dates
        })

      assert effect(new_review, day_type).joins == []

      existing_review =
        build(%{
          command: {:assign, [existing.id], "101"},
          target: "101",
          selected_key: day_type.key,
          affected: [day_type],
          rows: [b, existing],
          changes: [%{trip: existing, from: nil, to: "101"}],
          service_dates: service_dates
        })

      assert effect(existing_review, day_type).joins == ["101"]
    end
  end

  describe "build/1 in-seat context" do
    test "an unassign that makes a record not next adds an in-seat warning" do
      {day_type, service_dates} = solo_day()
      p = trip("p", "A", "101", at(8, 0), at(9, 5))
      q = trip("q", "A", "101", at(9, 10), at(10, 0))
      record = record("t4", p, q)
      context = context([p, q], day_type, service_dates, %{{day_type.key, "101"} => [p.id, q.id]})

      review =
        build(%{
          command: {:unassign, [q.id]},
          target: nil,
          selected_key: day_type.key,
          affected: [day_type],
          rows: [p, q],
          changes: [%{trip: q, from: "101", to: nil}],
          in_seat: %{rows: [record], context: context},
          service_dates: service_dates
        })

      result = effect(review, day_type)

      assert Enum.any?(
               result.added,
               &(&1.code == :in_seat_stale and &1.severity == :warning and &1.block_id == "101")
             )

      assert review.added_problem_count == 1
      assert review.needs_confirmation?
    end

    test "a record whose day type the command does not touch is never added" do
      calendars = [calendar("A", [@monday], 1), calendar("B", [@tuesday], 1)]
      day_types = DayTypes.derive(calendars)
      [monday] = Enum.filter(day_types, &(&1.service_ids == ["A"]))
      [tuesday] = Enum.filter(day_types, &(&1.service_ids == ["B"]))
      service_dates = DayTypes.service_dates(calendars)

      p = trip("p", "A", "101", at(8, 0), at(9, 5))
      q = trip("q", "A", nil, at(9, 10), at(10, 0))
      c = trip("c", "B", "9", at(12, 0), at(13, 0))
      record = record("t4", p, q)
      context = context([p, q, c], monday, service_dates, %{{monday.key, "101"} => [p.id]})

      review =
        build(%{
          command: {:unassign, [c.id]},
          target: nil,
          selected_key: tuesday.key,
          affected: DayTypes.containing(day_types, "B"),
          rows: [c],
          changes: [%{trip: c, from: "9", to: nil}],
          in_seat: %{rows: [record], context: context},
          service_dates: service_dates
        })

      assert Enum.map(review.effects, & &1.day_type.key) == [tuesday.key]
      refute Enum.any?(hd(review.effects).added, &(&1.code == :in_seat_stale))
    end
  end

  describe "build/1 fingerprint and effect scope" do
    test "the fingerprint is stable and changes with a locked row or the resolved target" do
      {day_type, service_dates} = solo_day()
      x = trip("x", "A", "101", at(8, 0), at(9, 0))
      base = [x]

      fingerprint = fn rows, target ->
        change = %{trip: Enum.find(rows, &(&1.id == "x")), from: "101", to: target}

        build(%{
          command: {:assign, ["x"], target},
          target: target,
          selected_key: day_type.key,
          affected: [day_type],
          rows: rows,
          changes: [change],
          service_dates: service_dates
        }).fingerprint
      end

      assert fingerprint.(base, "202") == fingerprint.(base, "202")

      assert fingerprint.([%{x | updated_at: ~U[2026-01-02 00:00:00Z]}], "202") !=
               fingerprint.(base, "202")

      for field <- [:first_arrival, :first_departure, :last_arrival, :last_departure] do
        assert fingerprint.([Map.update!(x, field, &(&1 + 60))], "202") !=
                 fingerprint.(base, "202")
      end

      assert fingerprint.(base, "303") != fingerprint.(base, "202")
    end

    test "effects list the selected day type first and sum the affected dates" do
      calendars = [
        calendar("A", [@monday, @tuesday, @wednesday], 1),
        calendar("B", [@monday], 0)
      ]

      day_types = DayTypes.derive(calendars)
      [shared] = Enum.filter(day_types, &(&1.service_ids == ["A", "B"]))
      [alone] = Enum.filter(day_types, &(&1.service_ids == ["A"]))

      assert shared.date_count == 1
      assert alone.date_count == 2

      review =
        build(%{
          command: {:unassign, []},
          target: nil,
          selected_key: alone.key,
          affected: DayTypes.containing(day_types, "A"),
          rows: [],
          changes: [],
          service_dates: DayTypes.service_dates(calendars)
        })

      assert Enum.map(review.effects, & &1.day_type.key) == [alone.key, shared.key]
      assert hd(review.effects).selected?
      assert review.affected_date_count == 3
    end
  end

  defp build(attrs) do
    Review.build(
      Map.merge(
        %{
          command: {:unassign, []},
          target: nil,
          selected_key: nil,
          affected: [],
          rows: [],
          changes: [],
          in_seat: %{rows: [], context: empty_context()},
          service_dates: %{},
          min_layover_minutes: @min_layover
        },
        attrs
      )
    )
  end

  defp calendar(service_id, dates, trip_count) do
    %{service_id: service_id, name: service_id, active_dates: dates, trip_count: trip_count}
  end

  defp solo_day do
    calendars = [calendar("A", [@monday], 1)]
    [day_type] = DayTypes.derive(calendars)
    {day_type, DayTypes.service_dates(calendars)}
  end

  defp two_day_types(calendars, first_services, second_services) do
    day_types = DayTypes.derive(calendars)
    first = Enum.find(day_types, &(&1.service_ids == first_services))
    second = Enum.find(day_types, &(&1.service_ids == second_services))
    {first, second}
  end

  defp effect(review, day_type), do: Enum.find(review.effects, &(&1.day_type.key == day_type.key))

  defp empty_context do
    %{trips: %{}, service_dates: %{}, day_types: [], sequences: %{}}
  end

  defp context(trips, day_type, service_dates, sequences) do
    %{
      trips: Map.new(trips, &{&1.trip_id, &1}),
      service_dates: service_dates,
      day_types: [day_type],
      sequences: sequences
    }
  end

  defp record(id, from, to) do
    %{
      id: id,
      from_trip_id: from.trip_id,
      to_trip_id: to.trip_id,
      transfer_type: 4,
      from_stop_id: from.last_stop.stop_id,
      to_stop_id: to.first_stop.stop_id
    }
  end

  # Integer seconds, never parsed from a string (CR-3).
  defp at(hours, minutes), do: hours * 3600 + minutes * 60

  defp trip(id, service_id, block_id, from_secs, to_secs, opts \\ []) do
    %{
      id: id,
      trip_id: Keyword.get(opts, :trip_id, id),
      route_id: "R1",
      service_id: service_id,
      block_id: block_id,
      trip_headsign: nil,
      route_pattern_id: nil,
      updated_at: Keyword.get(opts, :updated_at, ~U[2026-01-01 00:00:00Z]),
      frequency?: false,
      headway_secs: nil,
      first_arrival: Keyword.get(opts, :first_arrival, from_secs),
      first_departure: Keyword.get(opts, :first_departure, from_secs),
      last_arrival: Keyword.get(opts, :last_arrival, to_secs),
      last_departure: Keyword.get(opts, :last_departure, to_secs),
      first_stop: Keyword.get(opts, :first_stop, stop("S")),
      last_stop: Keyword.get(opts, :last_stop, stop("S")),
      plottable?: Keyword.get(opts, :plottable?, true)
    }
  end

  defp stop(stop_id, opts \\ []) do
    %{
      stop_id: stop_id,
      name: stop_id,
      parent_station: Keyword.get(opts, :parent_station),
      lat: Keyword.get(opts, :lat),
      lon: Keyword.get(opts, :lon)
    }
  end
end
