defmodule GtfsPlanner.Reachability.ScoringTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Reachability.Scoring
  alias GtfsPlanner.Routing.Route

  describe "pair_outcome/1" do
    test "ok route is reachable" do
      assert Scoring.pair_outcome({:ok, %Route{}}) == :reachable
    end

    test "no_path is unreachable" do
      assert Scoring.pair_outcome({:error, :no_path}) == :unreachable
    end

    test "unknown_element is invalid" do
      assert Scoring.pair_outcome({:error, {:unknown_element, "X"}}) == :invalid
    end

    test "same_origin_and_destination is invalid" do
      assert Scoring.pair_outcome({:error, :same_origin_and_destination}) == :invalid
    end
  end

  describe "run_outcome/1" do
    test "empty results is not_applicable" do
      assert Scoring.run_outcome([]) == :not_applicable
    end

    test "any invalid result is failed" do
      results = [
        %{mode: :walking, outcome: :reachable},
        %{mode: :walking, outcome: :invalid}
      ]

      assert Scoring.run_outcome(results) == :failed
    end

    test "walking unreachable is failed" do
      results = [
        %{mode: :walking, outcome: :unreachable},
        %{mode: :wheelchair, outcome: :reachable}
      ]

      assert Scoring.run_outcome(results) == :failed
    end

    test "wheelchair unreachable with all walking reachable is warning" do
      results = [
        %{mode: :walking, outcome: :reachable},
        %{mode: :wheelchair, outcome: :unreachable}
      ]

      assert Scoring.run_outcome(results) == :warning
    end

    test "all reachable is passed" do
      results = [
        %{mode: :walking, outcome: :reachable},
        %{mode: :wheelchair, outcome: :reachable}
      ]

      assert Scoring.run_outcome(results) == :passed
    end
  end

  describe "counts/1" do
    test "assigns walking-unreachable and invalid to errors, wheelchair-unreachable to warnings, reachable to infos" do
      results = [
        %{mode: :walking, outcome: :reachable},
        %{mode: :walking, outcome: :unreachable},
        %{mode: :wheelchair, outcome: :reachable},
        %{mode: :wheelchair, outcome: :unreachable},
        %{mode: :walking, outcome: :invalid}
      ]

      counts = Scoring.counts(results)

      assert counts.errors == 2
      assert counts.warnings == 1
      assert counts.infos == 2
    end
  end
end
