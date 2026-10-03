defmodule GtfsPlanner.Gtfs.Runs.PlanTest do
  @moduledoc """
  The fingerprint covers every input a suggestion depended on.

  The failure is an input edited after the preview that falls outside the
  fingerprint, so a stale plan is written. Ruling it out means showing that each
  input, varied alone, changes the fingerprint, which is the shape of these tests:
  one input varied at a time. A fingerprint that covered some of them would pass a
  test that varied several at once.

  The inputs are a trip's block or times, the day type's assignments, a crew rule,
  a Block rules setting, a relief point, a driving time, and a block attribute.
  Each gets its own test rather than a loop, so a failure names the input that
  fell out.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/plan_test.exs`.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Runs.Plan

  @garage_uuid "11111111-2222-4333-8444-555555555555"
  @bay_a %{stop_id: "BAY_A", name: "Bay A", parent_station: "RIV", lat: 42.0, lon: -71.0}

  @crew %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 720
  }

  # Deterministic IDs, not generated ones. A fingerprint test that called
  # Ecto.UUID.generate/0 in its helper would be comparing two different days
  # every time and would fail for the wrong reason - it did, twice, before this
  # was made a function of the index.
  defp trip(index, overrides \\ []) do
    Map.merge(
      %{
        id: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0"),
        trip_id: "t#{index}",
        route_id: "R1",
        service_id: "WKDY",
        block_id: "101",
        first_departure: 6 * 3600,
        last_arrival: 7 * 3600,
        first_stop: @bay_a,
        last_stop: @bay_a,
        updated_at: ~U[2026-01-01 00:00:00Z],
        frequency?: false,
        plottable?: true
      },
      Map.new(overrides)
    )
  end

  defp context(overrides \\ []) do
    garage = %{id: @garage_uuid, garage_id: "MAIN", name: "Main Garage", lat: 42.0, lon: -71.0}

    Map.merge(
      struct!(Context,
        min_layover_minutes: 5,
        pull_out_buffer_minutes: 10,
        deadhead_speed_kmh: 30,
        deadhead_circuity: 1.3,
        entered_minutes: %{{{:stop, "VC"}, {:stop, "MS"}} => 14},
        trip_km: %{},
        default_garage_id: @garage_uuid,
        garages: %{@garage_uuid => garage},
        relief_stop_ids: MapSet.new(["RIV"]),
        attributes: %{{"101", "block-101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil}}
      ),
      Map.new(overrides)
    )
  end

  defp inputs(overrides) do
    base = %{
      context: context(),
      trips: [trip(1), trip(2), trip(3)],
      assignments: %{},
      crew: @crew
    }

    Map.merge(base, Map.new(overrides))
  end

  defp fingerprint(overrides), do: Plan.fingerprint(inputs(overrides))

  describe "build/1" do
    test "lists only the trips whose run differs, sorted by trip ID" do
      [first, second, third] = [trip(1), trip(2), trip(3)]

      current = %{first.trip_id => "1001", second.trip_id => "1001", third.trip_id => "1002"}
      proposed = %{first.trip_id => "1001", second.trip_id => "2001", third.trip_id => "1002"}

      plan = plan(current, proposed)

      # The first trip was already on the right run and is not a change.
      assert [%{trip_id: second_id, from: "1001", to: "2001"}] = plan.moves
      assert second_id == second.trip_id
    end

    test "names every affected run, on both sides of a move" do
      [first, second] = [trip(1), trip(2)]

      current = %{first.trip_id => "1001", second.trip_id => "1001"}
      proposed = %{first.trip_id => "2001", second.trip_id => "2001"}

      plan = plan(current, proposed)

      # 1001 lost both trips and 2001 gained them; neither is visible from the
      # new IDs alone.
      assert plan.changed_run_ids == ["1001", "2001"]
      assert plan.new_run_ids == ["2001"]
    end

    test "a trip joining a run is a move whether or not it had a run, and a new run is new" do
      [first, second] = [trip(1), trip(2)]

      # The first is explicitly unassigned, the second was never in the map at
      # all. Both end up with no previous run, so both are moves from nothing.
      plan = plan(%{first.trip_id => nil}, %{first.trip_id => "1001", second.trip_id => "1001"})

      assert [%{from: nil, to: "1001"}, %{from: nil, to: "1001"}] = plan.moves
      assert plan.changed_run_ids == ["1001"]
      assert plan.new_run_ids == ["1001"]
    end

    test "a proposal that changes nothing has no moves" do
      [first, second] = [trip(1), trip(2)]
      same = %{first.trip_id => "1001", second.trip_id => "1002"}

      plan = plan(same, same)

      assert plan.moves == []
      assert plan.changed_run_ids == []
      assert plan.new_run_ids == []
    end

    test "the plan carries the day, the scope, the figures and the fingerprint through" do
      [first] = [trip(1)]
      plan = plan(%{first.trip_id => "1001"}, %{first.trip_id => "2001"})

      assert plan.day_type_key == "weekday"
      assert plan.scope == :uncovered_only
      assert plan.before == %{runs: 1}
      assert plan.after == %{runs: 2}
      assert plan.preview == %{runs: [:preview]}
      assert plan.fingerprint == fingerprint([])
    end
  end

  defp plan(current, proposed) do
    Plan.build(%{
      day_type_key: "weekday",
      scope: :uncovered_only,
      current: current,
      proposed: proposed,
      before: %{runs: 1},
      after: %{runs: 2},
      preview: %{runs: [:preview]},
      fingerprint: fingerprint([])
    })
  end

  describe "the fingerprint covers every input" do
    test "a trip moving to another block" do
      assert fingerprint(trips: [trip(1), trip(2, block_id: "102")]) != fingerprint([])
    end

    test "a trip's first departure" do
      assert fingerprint(trips: [trip(1), trip(2, first_departure: 6 * 3600 + 60)]) !=
               fingerprint([])
    end

    test "a trip's last arrival" do
      assert fingerprint(trips: [trip(1), trip(2, last_arrival: 7 * 3600 + 60)]) !=
               fingerprint([])
    end

    test "a trip's first stop" do
      moved = %{@bay_a | stop_id: "BAY_C", parent_station: "RIV"}
      assert fingerprint(trips: [trip(1), trip(2, first_stop: moved)]) != fingerprint([])
    end

    test "a trip's last stop" do
      moved = %{@bay_a | stop_id: "BAY_D", parent_station: "RIV"}
      assert fingerprint(trips: [trip(1), trip(2, last_stop: moved)]) != fingerprint([])
    end

    test "a trip's update time" do
      touched = trip(2, updated_at: ~U[2026-01-02 00:00:00Z])
      assert fingerprint(trips: [trip(1), touched]) != fingerprint([])
    end

    test "a trip recreated under the same trip ID with every other value equal" do
      recreated = trip(2, id: "11111111-1111-4111-8111-111111111111")

      refute recreated.id == trip(2).id
      assert recreated.trip_id == trip(2).trip_id
      assert fingerprint(trips: [trip(1), recreated, trip(3)]) != fingerprint([])
    end

    test "one assignment" do
      [first | _] = [trip(1)]
      assert fingerprint(assignments: %{first.trip_id => "1001"}) != fingerprint([])
    end

    test "one crew value" do
      assert fingerprint(crew: %{@crew | report_pull_out_minutes: 16}) != fingerprint([])
    end

    test "a relief point" do
      assert fingerprint(context: context(relief_stop_ids: MapSet.new(["RIV", "MS"]))) !=
               fingerprint([])
    end

    test "a driving time" do
      other = context(entered_minutes: %{{{:stop, "VC"}, {:stop, "MS"}} => 15})
      assert fingerprint(context: other) != fingerprint([])
    end

    test "a block attribute" do
      other =
        context(attributes: %{{"101", "block-101"} => %{garage_id: nil, vehicle_type_id: nil}})

      assert fingerprint(context: other) != fingerprint([])
    end

    test "a Block rules value" do
      assert fingerprint(context: context(min_layover_minutes: 6)) != fingerprint([])
    end

    test "a deadhead speed, which a Block rules setting carries" do
      assert fingerprint(context: context(deadhead_speed_kmh: 25)) != fingerprint([])
    end

    test "a garage moving" do
      moved =
        context(
          garages: %{
            @garage_uuid => %{
              id: @garage_uuid,
              garage_id: "MAIN",
              name: "Main Garage",
              lat: 42.1,
              lon: -71.0
            }
          }
        )

      assert fingerprint(context: moved) != fingerprint([])
    end
  end

  describe "the fingerprint ignores order" do
    test "the same inputs given in a different order hash the same" do
      [a, b, c] = [trip(1), trip(2), trip(3)]
      assignments = %{a.trip_id => "1001", b.trip_id => "1002", c.trip_id => "1003"}

      forwards = Plan.fingerprint(inputs(trips: [a, b, c], assignments: assignments))

      backwards =
        Plan.fingerprint(
          inputs(trips: [c, b, a], assignments: Map.new(Enum.reverse(Map.to_list(assignments))))
        )

      shuffled =
        Plan.fingerprint(
          inputs(trips: [b, a, c], assignments: Map.new(Enum.shuffle(Map.to_list(assignments))))
        )

      assert forwards == backwards
      assert forwards == shuffled
    end

    test "it is stable across repeated calls" do
      assert fingerprint([]) == fingerprint([])
    end

    test "it is a lowercase hex SHA-256" do
      digest = fingerprint([])
      assert String.length(digest) == 64
      assert digest == String.downcase(digest)
      assert Regex.match?(~r/^[0-9a-f]{64}$/, digest)
    end
  end
end
