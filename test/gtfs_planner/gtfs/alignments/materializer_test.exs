defmodule GtfsPlanner.Gtfs.Alignments.MaterializerTest do
  # Expected distances are hand-derived haversine constants from the independent
  # oracle `.specs/12-pattern-alignments/evidence/oracle-constants.py`
  # (recorded output in `evidence/oracle-constants.txt`); they are never
  # computed with the module under test.
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Alignments.Materializer

  describe "build/2 meridian fixture" do
    test "returns oracle visit and point distances" do
      visits = [%{lat: 0.0, lon: 0.0}, %{lat: 0.001, lon: 0.0}, %{lat: 0.003, lon: 0.0}]
      sections = [[], [[0.0, 0.002]]]

      assert {:ok, result} = Materializer.build(visits, sections)

      assert result.visit_distances == [
               Decimal.new("0.00"),
               Decimal.new("111.20"),
               Decimal.new("333.59")
             ]

      assert Enum.map(result.points, & &1.dist) == [
               Decimal.new("0.00"),
               Decimal.new("111.20"),
               Decimal.new("222.39"),
               Decimal.new("333.59")
             ]

      assert Enum.map(result.points, & &1.sequence) == [0, 1, 2, 3]
    end
  end

  describe "build/2 loop" do
    test "visit distances strictly increase across the repeated pair" do
      visits = [
        %{lat: 0.0, lon: 0.0},
        %{lat: 0.001, lon: 0.0},
        %{lat: 0.002, lon: 0.0},
        %{lat: 0.0, lon: 0.0},
        %{lat: 0.001, lon: 0.0}
      ]

      assert {:ok, result} = Materializer.build(visits, [[], [], [], []])

      assert result.visit_distances == [
               Decimal.new("0.00"),
               Decimal.new("111.20"),
               Decimal.new("222.39"),
               Decimal.new("444.78"),
               Decimal.new("555.98")
             ]
    end
  end

  describe "build/2 parallels and asymmetric pairs" do
    test "45N parallel leg matches the oracle" do
      visits = [%{lat: 45.0, lon: 0.0}, %{lat: 45.0, lon: 0.001}]

      assert {:ok, result} = Materializer.build(visits, [[]])
      assert result.visit_distances == [Decimal.new("0.00"), Decimal.new("78.63")]
    end

    test "NYC pair keeps axis order and matches the oracle distance" do
      visits = [%{lat: 40.7128, lon: -74.0060}, %{lat: 40.7138, lon: -74.0050}]

      assert {:ok, result} = Materializer.build(visits, [[]])
      assert [first, _second] = result.points
      assert first.lat == Decimal.new("40.712800")
      assert first.lon == Decimal.new("-74.006000")
      assert result.visit_distances == [Decimal.new("0.00"), Decimal.new("139.53")]
    end
  end

  describe "build/2 interior dedupe" do
    test "drops interiors equal to an anchor but never drops anchors" do
      visits = [%{lat: 0.0, lon: 0.0}, %{lat: 0.001, lon: 0.0}, %{lat: 0.0, lon: 0.0}]

      # First interior duplicates the following anchor, second duplicates its
      # predecessor; both are dropped while all three anchors survive.
      sections = [[[0.0, 0.001], [0.0, 0.001]], []]

      assert {:ok, result} = Materializer.build(visits, sections)
      assert Enum.map(result.points, & &1.sequence) == [0, 1, 2]

      assert Enum.map(result.points, &{&1.lat, &1.lon}) == [
               {Decimal.new("0.000000"), Decimal.new("0.000000")},
               {Decimal.new("0.001000"), Decimal.new("0.000000")},
               {Decimal.new("0.000000"), Decimal.new("0.000000")}
             ]

      assert result.visit_distances == [
               Decimal.new("0.00"),
               Decimal.new("111.20"),
               Decimal.new("222.39")
             ]
    end
  end

  describe "build/2 destination crossing" do
    test "keeps a nonconsecutive repeat of the next anchor with full distances" do
      visits = [%{lat: 0.0, lon: 0.0}, %{lat: 0.0, lon: 0.001}]

      # The first interior crosses the destination and the path loops back:
      # dropping it would silently shorten the exported shape.
      sections = [[[0.001, 0.0], [0.001, 0.001]]]

      assert {:ok, result} = Materializer.build(visits, sections)

      assert Enum.map(result.points, &[Decimal.to_float(&1.lon), Decimal.to_float(&1.lat)]) == [
               [0.0, 0.0],
               [0.001, 0.0],
               [0.001, 0.001],
               [0.001, 0.0]
             ]

      assert Enum.map(result.points, & &1.dist) == [
               Decimal.new("0.00"),
               Decimal.new("111.20"),
               Decimal.new("222.39"),
               Decimal.new("333.59")
             ]

      assert result.visit_distances == [Decimal.new("0.00"), Decimal.new("333.59")]
    end
  end

  describe "build/2 digest" do
    test "is stable and separates identical point lists by anchor indices" do
      a = %{lat: 0.0, lon: 0.0}
      b = %{lat: 0.001, lon: 0.0}
      c = %{lat: 0.002, lon: 0.0}

      assert {:ok, first} = Materializer.build([a, c], [[[0.0, 0.001]]])
      assert {:ok, second} = Materializer.build([a, c], [[[0.0, 0.001]]])
      assert {:ok, anchored} = Materializer.build([a, b, c], [[], []])

      assert first.digest == second.digest

      assert Enum.map(first.points, &{&1.lat, &1.lon}) ==
               Enum.map(anchored.points, &{&1.lat, &1.lon})

      refute first.digest == anchored.digest
    end
  end

  describe "build/2 blocked sections" do
    test "a visit without coordinates blocks both adjacent sections" do
      visits = [%{lat: 0.0, lon: 0.0}, %{lat: nil, lon: 0.0}, %{lat: 0.002, lon: 0.0}]

      assert {:error, {:blocked, blockers}} = Materializer.build(visits, [[], []])

      assert blockers == [
               %{position: 1, reason: :no_coordinates},
               %{position: 2, reason: :no_coordinates}
             ]
    end

    test "distinct visits at one coordinate block the section as zero length" do
      visits = [%{lat: 0.0, lon: 0.0}, %{lat: 0.0, lon: 0.0}]

      assert {:error, {:blocked, blockers}} = Materializer.build(visits, [[]])
      assert blockers == [%{position: 1, reason: :zero_length}]
    end
  end

  describe "length_m/1" do
    test "sums haversine metres over [lon, lat] legs" do
      assert Materializer.length_m([]) == 0.0
      assert Materializer.length_m([[0.0, 0.0]]) == 0.0

      leg = Materializer.length_m([[0.0, 0.0], [0.0, 0.001]])
      assert Float.round(leg, 2) == 111.2
    end
  end
end
