defmodule GtfsPlanner.Gtfs.Blocking.GeneratorTest do
  @moduledoc """
  Tests for the suggested-blocks generator.

  The oracle is never the generator's own bookkeeping. Every instance is checked
  by applying `run/4`'s assignments to the rows it was given and handing the
  result to `Checks.block_findings/3` with the same context, so a rule the
  generator believes about itself and a rule the checks enforce are compared
  rather than assumed. Coverage is recomputed from the input row set and the
  whole result is compared across three input orders.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Generator

  @main "00000000-0000-4000-8000-000000000001"
  @north "00000000-0000-4000-8000-000000000002"
  @cutaway "00000000-0000-4000-8000-000000000003"
  @diesel "00000000-0000-4000-8000-000000000004"

  # The endpoint stops the fixtures chain between. The garage sits a few hundred
  # metres from `@riv_a`, so a pull-out is a couple of minutes; `@nowhere` is the
  # one stop the version cannot place.
  @riv_a %{stop_id: "RIV_A", name: "Riverside A", parent_station: "RIV", lat: 45.5, lon: -75.5}
  @riv_b %{
    stop_id: "RIV_B",
    name: "Riverside B",
    parent_station: "RIV",
    lat: 45.501,
    lon: -75.501
  }
  @market %{stop_id: "MKT", name: "Market Square", parent_station: nil, lat: 45.51, lon: -75.51}
  @valley %{stop_id: "VAL", name: "Valley College", parent_station: nil, lat: 45.52, lon: -75.52}
  @nowhere %{stop_id: "GAP", name: "Unplaced", parent_station: nil, lat: nil, lon: nil}

  @singleton_reasons [:exceeds_vehicle_limit, :exceeds_relief_limit]
  @allowed_singleton_codes [:too_long, :no_relief_opportunity]

  describe "generated plans add no error or forbidden warning" do
    test "on every instance, added findings are only the allowed singleton exceptions" do
      for instance <- instances() do
        result = run(instance)
        {before, after_findings} = findings_around(instance, result)
        allowed = singleton_block_ids(result)

        for {block_id, findings} <- after_findings do
          before_keys = Map.get(before, block_id, [])

          if fixed_block?(result, block_id) do
            lost = before_keys -- Enum.map(findings, &Checks.finding_key/1)
            assert lost == [], "#{instance.name}: block #{block_id} lost #{inspect(lost)}"
          end

          for finding <- findings, Checks.finding_key(finding) not in before_keys do
            assert finding.block_id in allowed,
                   "#{instance.name}: added #{finding.code} on block #{inspect(finding.block_id)}"

            assert finding.code in @allowed_singleton_codes,
                   "#{instance.name}: added forbidden #{finding.code}"
          end
        end
      end
    end

    test "a run that respects the relief limit raises no exception at all" do
      instance = Enum.find(instances(), &(&1.name == :relief_allows_a_long_chain))
      result = run(instance)

      assert Enum.filter(result.leftovers, &(&1.reason in @singleton_reasons)) == []

      {before, after_findings} = findings_around(instance, result)

      # The run creates one block, so `after_findings` is keyed by it. What the
      # case claims is that it raises nothing: every block's finding list is
      # empty, before and after.
      assert before == %{}
      assert Enum.all?(after_findings, fn {_block_id, findings} -> findings == [] end)
      assert map_size(after_findings) > 0
    end

    test "a relief limit the chain cannot meet splits the block and reports it" do
      instance = Enum.find(instances(), &(&1.name == :relief_splits_a_chain))
      result = run(instance)

      # T1 alone is inside the limit; T2 is not, and chaining it onto T1 would
      # leave an unrelieved stretch the limit also forbids, so it opens a block
      # of its own and that block is reported rather than dropped.
      assert [%{id: "1", trips: [%{trip_id: "T1"}]}, %{id: "2", trips: [%{trip_id: "T2"}]}] =
               result.blocks

      assert [%{reason: :exceeds_relief_limit, block_id: "2", trip: %{trip_id: "T2"}}] =
               result.leftovers
    end
  end

  describe "coverage, mode boundaries and block identifiers" do
    test "every scheduled trip is in exactly one block or in the leftovers with a reason" do
      for instance <- instances() do
        result = run(instance)
        rows = Map.fetch!(instance, :rows)

        assert Map.keys(result.assignments) |> Enum.sort() ==
                 rows |> Enum.map(& &1.id) |> Enum.sort(),
               "#{instance.name}: coverage"

        placed =
          Enum.flat_map(result.blocks, & &1.trips)

        assert placed |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(placed),
               "#{instance.name}: a trip appears twice"

        for %{trip: trip, reason: reason, block_id: block_id} <- result.leftovers do
          assert is_atom(reason) and reason != nil, "#{instance.name}: leftover without a reason"
          assert Map.fetch!(result.assignments, trip.id) == block_id
        end

        # Every scheduled trip is accounted for: named in a block the run
        # produced or in the leftovers, never both and never neither. A trip
        # that is both is a reported singleton, which keeps its block on purpose.
        placed_ids = MapSet.new(placed, & &1.id)
        leftover_ids = MapSet.new(result.leftovers, & &1.trip.id)

        assert MapSet.size(MapSet.union(placed_ids, leftover_ids)) == length(rows),
               "#{instance.name}: a trip is in no block and in no leftovers"

        assert placed_ids |> MapSet.intersection(leftover_ids) |> MapSet.size() ==
                 Enum.count(result.leftovers, &(&1.reason in @singleton_reasons)),
               "#{instance.name}: a trip is both placed and dropped"
      end
    end

    test ":unassigned_only keeps every existing assignment" do
      instance = Enum.find(instances(), &(&1.name == :invalid_fixed_block))
      result = run(instance)
      assigned = Map.fetch!(instance, :rows) |> Enum.filter(& &1.block_id)

      for trip <- assigned do
        assert Map.fetch!(result.assignments, trip.id) == trip.block_id
      end

      assert Enum.map(result.blocks, &{&1.id, &1.new?}) == [{"101", false}, {"102", true}]
    end

    test "frequency trips keep their assignment in every mode" do
      instance = Enum.find(instances(), &(&1.name == :frequency_trips))

      for mode <- [:unassigned_only, :replace_all, {:selected, ["101"]}] do
        result = run(%{instance | mode: mode})
        frequency = Enum.find(Map.fetch!(instance, :rows), & &1.frequency?)

        assert Map.fetch!(result.assignments, frequency.id) == "101"
        assert [%{reason: :repeating_service, block_id: "101"}] = result.leftovers
        refute Enum.any?(result.blocks, &holds?(frequency.id, &1))
      end
    end

    test "a rebuild over selected blocks reuses 101 and 102 before 105" do
      instance = Enum.find(instances(), &(&1.name == :selected_reuses_ids))
      result = run(instance)

      assert Enum.map(result.blocks, & &1.id) == ["101", "102", "105"]
      assert Enum.all?(result.blocks, & &1.new?)
    end

    test "a new block continues after the highest numeric ID in use" do
      result = run(Enum.find(instances(), &(&1.name == :required_type_partitions)))

      assert Enum.map(result.blocks, & &1.id) == ["105", "106"]
    end

    test "route 30 requiring a 35-ft diesel never shares a block with route 12" do
      instance = Enum.find(instances(), &(&1.name == :required_type_partitions))
      result = run(instance)

      for block <- result.blocks,
          routes = block.trips |> Enum.map(& &1.route_id) |> Enum.uniq() do
        assert length(routes) == 1, "block #{block.id} mixes #{inspect(routes)}"
        assert block.vehicle_type_id == if("30" in routes, do: @diesel, else: nil)
      end

      assert result.blocks |> Enum.map(& &1.trips) |> Enum.map(&length/1) == [3, 3]
    end

    test "a stop without coordinates that needs a drive from every block and the garage is a leftover" do
      result = run(Enum.find(instances(), &(&1.name == :stop_without_coordinates)))

      assert [%{reason: :unknown_location, block_id: nil, trip: %{trip_id: "T2"}}] =
               result.leftovers

      assert Enum.map(result.blocks, & &1.id) == ["1"]
    end

    test "an unplottable trip is a leftover and is never placed" do
      result = run(Enum.find(instances(), &(&1.name == :unplottable_trip)))

      assert [%{reason: :unplottable, block_id: nil, trip: %{trip_id: "T2"}}] = result.leftovers
    end

    test "a single-trip block over the vehicle limit is kept and reported" do
      instance = Enum.find(instances(), &(&1.name == :oversized_singleton))
      result = run(instance)

      assert Enum.map(result.blocks, & &1.id) == ["1", "2"]

      # The trip stays in its block: the run reports the block, it does not drop
      # the trip, so block 1 still holds T1 and block 2 still holds T2.
      assert [%{reason: :exceeds_vehicle_limit, block_id: "1", trip: %{trip_id: "T1"}}] =
               result.leftovers

      assert [%{id: "1", trips: [%{trip_id: "T1"}]}, %{id: "2", trips: [%{trip_id: "T2"}]}] =
               result.blocks
    end
  end

  describe "determinism" do
    test "three input orders give identical results" do
      for instance <- instances() do
        rows = Map.fetch!(instance, :rows)
        results = Enum.map([1, 7, 42], fn _ -> run(%{instance | rows: Enum.shuffle(rows)}) end)

        assert results |> Enum.uniq() |> length() == 1,
               "#{instance.name}: order changed the result"
      end
    end
  end

  defp holds?(trip_id, block), do: Enum.any?(block.trips, &(&1.id == trip_id))

  # --- harness ----------------------------------------------------------------

  defp run(instance) do
    Generator.run(
      Map.fetch!(instance, :mode),
      Map.fetch!(instance, :rows),
      Map.fetch!(instance, :context),
      Map.get(instance, :used_ids, [])
    )
  end

  # The independent pass: apply the assignments and let `Checks` read the result
  # over every block, rather than believing anything the generator reported. Both
  # sides are keyed by block ID so a finding that moved between blocks cannot
  # cancel one out.
  defp findings_around(instance, result) do
    rows = Map.fetch!(instance, :rows)
    context = Map.fetch!(instance, :context)

    before =
      rows
      |> Enum.filter(& &1.block_id)
      |> Enum.group_by(& &1.block_id)
      |> Map.new(fn {block_id, trips} ->
        {block_id,
         trips
         |> then(&Checks.block_findings(block_id, &1, context))
         |> Enum.map(&Checks.finding_key/1)}
      end)

    after_findings =
      (result.blocks ++ untouched_blocks(rows, result))
      |> Enum.uniq_by(& &1.id)
      |> Map.new(fn block ->
        applied = Enum.filter(rows, &(Map.get(result.assignments, &1.id) == block.id))

        {block.id, Checks.block_findings(block.id, applied, context)}
      end)

    {before, after_findings}
  end

  # A block the run did not rebuild — a seeded block, or one whose every trip was
  # a leftover left where it was — still has to be read after the run, or a
  # finding the page would still show would look as though the generator had
  # removed it.
  defp untouched_blocks(rows, result) do
    rows
    |> Enum.filter(& &1.block_id)
    |> Enum.map(& &1.block_id)
    |> Enum.reject(&Enum.any?(result.blocks, fn block -> block.id == &1 end))
    |> Enum.uniq()
    |> Enum.map(&%{id: &1})
  end

  # A fixed block is one the run did not create: its findings are inherited, so
  # every one of them has to survive. A block the run created is a new block, and
  # the guarantee for it is that the run added nothing, which the added-side
  # assertions already cover.
  defp fixed_block?(result, block_id) do
    not Enum.any?(result.blocks, &(&1.id == block_id and &1.new?))
  end

  defp singleton_block_ids(result) do
    result.leftovers
    |> Enum.filter(&(&1.reason in @singleton_reasons))
    |> Enum.map(& &1.block_id)
    |> MapSet.new()
  end

  # --- fixtures ---------------------------------------------------------------

  defp instances do
    [
      unassigned_only(),
      relief_allows_a_long_chain(),
      relief_splits_a_chain(),
      invalid_fixed_block(),
      explicit_attributes(),
      stop_without_coordinates(),
      oversized_singleton(),
      frequency_trips(),
      required_type_partitions(),
      unassigned_continues_after_highest(),
      selected_reuses_ids(),
      unplottable_trip(),
      no_relief_limit_chains_everything()
    ]
  end

  # Three trips with no existing blocks. The first opens a block, the second
  # chains onto it and the third cannot (it starts before the second arrives), so
  # the run makes two blocks out of three trips.
  defp unassigned_only do
    %{
      name: :unassigned_only,
      mode: :unassigned_only,
      context: context([]),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(6, 30),
          arrival: minutes(7, 30),
          first: @market,
          last: @valley
        ),
        trip(3, "T3",
          route: "12",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @market
        )
      ]
    }
  end

  # The same long pair, with a relief limit the schedule can meet because the
  # marked window splits the block's only long tail.
  defp relief_allows_a_long_chain do
    %{
      name: :relief_allows_a_long_chain,
      mode: :unassigned_only,
      context: context(max_piece_minutes: 360, relief_stop_ids: MapSet.new(["MKT"])),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(6, 30),
          arrival: minutes(9),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  # The same two trips with a limit the chain cannot meet: the trip splits out
  # and each single-trip block is then reported rather than dropped.
  defp relief_splits_a_chain do
    %{
      name: :relief_splits_a_chain,
      mode: :unassigned_only,
      context: context(max_piece_minutes: 120, relief_stop_ids: MapSet.new(["MKT"])),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(6, 30),
          arrival: minutes(9),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  # An existing block that is already wrong: two overlapping trips raise an
  # `:overlap` and a `:cannot_reach` before the run and must still raise them
  # after, as existing findings rather than as anything the run added.
  defp invalid_fixed_block do
    %{
      name: :invalid_fixed_block,
      mode: :unassigned_only,
      used_ids: ["101"],
      context: context([]),
      rows: [
        trip(1, "T1",
          route: "12",
          block: "101",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          block: "101",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @riv_b
        ),
        trip(3, "T3",
          route: "12",
          departure: minutes(8, 3),
          arrival: minutes(9, 3),
          first: @riv_a,
          last: @market
        )
      ]
    }
  end

  # Block 101 carries an explicit attribute row naming a diesel, so it resolves
  # to that type while a route 12 trip resolves to none. The unassigned trip is
  # therefore in another partition and opens its own block.
  defp explicit_attributes do
    %{
      name: :explicit_attributes,
      mode: :unassigned_only,
      used_ids: ["101"],
      context:
        context(attributes: %{{"WKDY", "101"} => %{garage_id: @main, vehicle_type_id: @diesel}}),
      rows: [
        trip(1, "T1",
          route: "30",
          block: "101",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @market
        )
      ]
    }
  end

  # The second trip starts where the version has no coordinates, so every drive
  # into it is unknown — from the open block and from the garage a new block
  # would pull out of. It is a leftover rather than a block with an empty move.
  defp stop_without_coordinates do
    %{
      name: :stop_without_coordinates,
      mode: :unassigned_only,
      context: context([]),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(7),
          arrival: minutes(8),
          first: @nowhere,
          last: @market
        )
      ]
    }
  end

  # A 45-minute platform limit: the first trip alone is too long for a block, so
  # it is kept and reported, and the second trip is too long chained onto it, so
  # it opens a block of its own that is within the limit.
  defp oversized_singleton do
    %{
      name: :oversized_singleton,
      mode: :unassigned_only,
      context: context(max_block_minutes: 45),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(6, 30),
          arrival: minutes(7),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  # A frequency trip is a template repeated across the day, so it is held where
  # it is in every mode and never offered to a block.
  defp frequency_trips do
    %{
      name: :frequency_trips,
      mode: :unassigned_only,
      used_ids: ["101"],
      context: context([]),
      rows: [
        trip(1, "T1",
          route: "12",
          block: "101",
          frequency?: true,
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @market
        )
      ]
    }
  end

  # A replace-all over two routes where route 30 requires the diesel. The two
  # routes are in different partitions, and the run numbers its new blocks after
  # the highest ID in use.
  defp required_type_partitions do
    %{
      name: :required_type_partitions,
      mode: :replace_all,
      used_ids: ["101", "102", "103", "104"],
      context:
        context(route_settings: %{"12" => %{}, "30" => %{required_vehicle_type_id: @diesel}}),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(6, 30),
          arrival: minutes(7, 30),
          first: @market,
          last: @valley
        ),
        trip(3, "T3",
          route: "12",
          departure: minutes(8),
          arrival: minutes(9),
          first: @riv_a,
          last: @market
        ),
        trip(4, "T4",
          route: "30",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(5, "T5",
          route: "30",
          departure: minutes(6, 30),
          arrival: minutes(7, 30),
          first: @market,
          last: @valley
        ),
        trip(6, "T6",
          route: "30",
          departure: minutes(8),
          arrival: minutes(9),
          first: @riv_a,
          last: @market
        )
      ]
    }
  end

  # Unassigned trips with no block to chain onto, over a version whose blocks
  # are numbered 101–104.
  defp unassigned_continues_after_highest do
    %{
      name: :unassigned_continues_after_highest,
      mode: :unassigned_only,
      used_ids: ["101", "102", "103", "104"],
      context: context([]),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(5, 30),
          arrival: minutes(6, 30),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  # A rebuild of blocks 101 and 102 whose trips do not fit two blocks, so the
  # run reuses 101 and 102 and then continues at 105.
  defp selected_reuses_ids do
    %{
      name: :selected_reuses_ids,
      mode: {:selected, ["101", "102"]},
      used_ids: ["101", "102", "103", "104"],
      context: context([]),
      rows: [
        trip(1, "T1",
          route: "12",
          block: "101",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          block: "101",
          departure: minutes(6, 5),
          arrival: minutes(7, 5),
          first: @market,
          last: @valley
        ),
        trip(3, "T3",
          route: "12",
          block: "102",
          departure: minutes(5, 30),
          arrival: minutes(6, 30),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  # A trip with no usable endpoints has nothing to chain, so it stays where the
  # page left it.
  defp unplottable_trip do
    %{
      name: :unplottable_trip,
      mode: :unassigned_only,
      context: context([]),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          plottable?: false,
          departure: minutes(7),
          arrival: minutes(8),
          first: @riv_a,
          last: @market
        )
      ]
    }
  end

  # A long day with no relief limit set, which is the cheap path: the trial
  # builds are tails and no block is rejected for a stretch nobody has set a
  # limit for.
  defp no_relief_limit_chains_everything do
    %{
      name: :no_relief_limit_chains_everything,
      mode: :unassigned_only,
      context: context([]),
      rows: [
        trip(1, "T1",
          route: "12",
          departure: minutes(5),
          arrival: minutes(6),
          first: @riv_a,
          last: @riv_b
        ),
        trip(2, "T2",
          route: "12",
          departure: minutes(6, 30),
          arrival: minutes(7, 30),
          first: @market,
          last: @valley
        ),
        trip(3, "T3",
          route: "12",
          departure: minutes(8),
          arrival: minutes(9, 30),
          first: @riv_a,
          last: @market
        ),
        trip(4, "T4",
          route: "12",
          departure: minutes(10),
          arrival: minutes(11),
          first: @market,
          last: @valley
        )
      ]
    }
  end

  defp context(overrides) do
    struct!(
      %Context{
        min_layover_minutes: 5,
        default_garage_id: @main,
        garages: %{
          @main => %{
            id: @main,
            garage_id: "Main",
            name: "Main",
            lat: 45.505,
            lon: -75.505
          },
          @north => %{
            id: @north,
            garage_id: "North",
            name: "North",
            lat: 45.6,
            lon: -75.6
          }
        },
        vehicle_types: %{
          @cutaway => %{id: @cutaway, name: "Cutaway", max_out_minutes: 600},
          @diesel => %{id: @diesel, name: "35-ft diesel", max_out_minutes: 480}
        }
      },
      overrides
    )
  end

  defp trip(number, trip_id, opts) do
    departure = Keyword.fetch!(opts, :departure)
    arrival = Keyword.fetch!(opts, :arrival)

    %{
      id: uuid(number),
      trip_id: trip_id,
      route_id: Keyword.get(opts, :route, "12"),
      service_id: Keyword.get(opts, :service, "WKDY"),
      block_id: Keyword.get(opts, :block),
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: nil,
      updated_at: ~U[2026-01-01 00:00:00Z],
      frequency?: Keyword.get(opts, :frequency?, false),
      headway_secs: nil,
      first_arrival: departure,
      first_departure: departure,
      last_arrival: arrival,
      last_departure: arrival,
      first_stop: Keyword.get(opts, :first, @riv_a),
      last_stop: Keyword.get(opts, :last, @market),
      plottable?: Keyword.get(opts, :plottable?, true)
    }
  end

  defp minutes(hour, minute \\ 0), do: hour * 3600 + minute * 60

  defp uuid(number) do
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
  end
end
