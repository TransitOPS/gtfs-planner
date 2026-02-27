defmodule GtfsPlanner.Gtfs.TraversalCalculatorTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.{Pathway, TraversalCalculator}

  describe "calculate/2" do
    test "uses traversal_time before length and stairs in default pathway modes" do
      pathway = %Pathway{
        pathway_mode: 1,
        traversal_time: 90,
        length: Decimal.new("40"),
        stair_count: 30
      }

      assert %{
               time_seconds: 90.0,
               distance_meters: 40.0,
               calculation_method: :traversal_time
             } = TraversalCalculator.calculate(pathway, nil)
    end

    test "uses length fallback when traversal_time is absent" do
      pathway = %Pathway{pathway_mode: 3, traversal_time: nil, length: Decimal.new("14.0")}

      assert %{calculation_method: :length_walk_speed, distance_meters: 14.0} =
               TraversalCalculator.calculate(pathway, nil)
    end

    test "uses stair_count fallback when traversal_time and length are absent" do
      pathway = %Pathway{pathway_mode: 2, traversal_time: nil, length: nil, stair_count: 20}

      assert %{calculation_method: :stair_count_estimate, distance_meters: distance_meters} =
               TraversalCalculator.calculate(pathway, nil)

      assert distance_meters > 0
    end

    test "normalizes decimal and integer inputs" do
      pathway = %Pathway{pathway_mode: 1, traversal_time: nil, length: Decimal.new("7.25")}

      result = TraversalCalculator.calculate(pathway, nil)
      assert is_float(result.time_seconds)
      assert result.distance_meters == 7.25
    end

    test "escalator uses explicit traversal_time then length fallback" do
      explicit = %Pathway{pathway_mode: 4, traversal_time: 25, length: Decimal.new("10")}
      fallback = %Pathway{pathway_mode: 4, traversal_time: nil, length: Decimal.new("10")}

      assert %{calculation_method: :escalator_traversal_time, time_seconds: 25.0} =
               TraversalCalculator.calculate(explicit, nil)

      assert %{calculation_method: :escalator_length_speed, distance_meters: 10.0} =
               TraversalCalculator.calculate(fallback, nil)
    end

    test "elevator uses board slack and level diff estimate when traversal_time is absent" do
      pathway = %Pathway{pathway_mode: 5, traversal_time: nil}

      assert %{calculation_method: :elevator_level_diff_estimate, time_seconds: 150.0} =
               TraversalCalculator.calculate(pathway, 3)
    end

    test "elevator uses board slack with single hop fallback when level diff is absent" do
      pathway = %Pathway{pathway_mode: 5, traversal_time: nil}

      assert %{calculation_method: :elevator_single_level_estimate, time_seconds: 110.0} =
               TraversalCalculator.calculate(pathway, nil)
    end

    test "elevator uses board slack plus explicit traversal_time when present" do
      pathway = %Pathway{pathway_mode: 5, traversal_time: 18}

      assert %{calculation_method: :elevator_traversal_time, time_seconds: 108.0} =
               TraversalCalculator.calculate(pathway, 99)
    end
  end
end
