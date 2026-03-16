defmodule GtfsPlanner.Gtfs.StationReport.HelpersTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationReport.Helpers

  describe "haversine/4" do
    test "returns ~111,195m for one equatorial degree of longitude" do
      distance = Helpers.haversine(0.0, 0.0, 0.0, 1.0)
      assert_in_delta distance, 111_195, 200
    end

    test "returns 0.0 for identical points" do
      assert Helpers.haversine(40.7128, -74.0060, 40.7128, -74.0060) == 0.0
    end

    test "accepts Decimal inputs" do
      distance =
        Helpers.haversine(
          Decimal.new("40.7128"),
          Decimal.new("-74.0060"),
          Decimal.new("40.7128"),
          Decimal.new("-74.0060")
        )

      assert distance == 0.0
    end

    test "accepts mixed Decimal and float inputs" do
      distance = Helpers.haversine(Decimal.new("0.0"), 0.0, 0.0, Decimal.new("1.0"))
      assert_in_delta distance, 111_195, 200
    end

    test "clamps near-antipodal calculations to a finite maximum distance" do
      distance = Helpers.haversine(89.999999, 0.0, -89.999999, 180.0)

      assert distance == distance
      assert_in_delta distance, :math.pi() * 6_371_000.0, 1.0
    end
  end

  describe "title_case/1" do
    test "capitalizes each word" do
      assert Helpers.title_case("hello world") == "Hello World"
    end

    test "lowercases minor words except first" do
      assert Helpers.title_case("gate of the north") == "Gate of the North"
    end

    test "preserves acronym-style tokens" do
      assert Helpers.title_case("JFK") == "JFK"
      assert Helpers.title_case("ADA entrance to NYC") == "ADA Entrance to NYC"
    end

    test "handles single word" do
      assert Helpers.title_case("entrance") == "Entrance"
    end

    test "handles empty string" do
      assert Helpers.title_case("") == ""
    end
  end

  describe "find_outliers/2" do
    test "detects outlier values exceeding threshold" do
      result =
        Helpers.find_outliers(
          [{:a, 30}, {:b, 30}, {:c, 30}, {:d, 30}, {:e, 30}, {:f, 300}],
          2.0
        )

      assert result == [{:f, 300}]
    end

    test "returns empty list when fewer than 3 samples" do
      assert Helpers.find_outliers([{:a, 10}, {:b, 20}], 2.0) == []
    end

    test "returns empty list when all values are identical" do
      assert Helpers.find_outliers([{:a, 10}, {:b, 10}, {:c, 10}], 2.0) == []
    end

    test "uses default threshold of 2.0" do
      result =
        Helpers.find_outliers([{:a, 30}, {:b, 30}, {:c, 30}, {:d, 30}, {:e, 30}, {:f, 300}])

      assert result == [{:f, 300}]
    end
  end

  describe "present?/1" do
    test "returns false for nil" do
      refute Helpers.present?(nil)
    end

    test "returns false for empty string" do
      refute Helpers.present?("")
    end

    test "returns false for whitespace-only string" do
      refute Helpers.present?("   ")
    end

    test "returns true for non-empty string" do
      assert Helpers.present?("x")
    end

    test "returns true for integer" do
      assert Helpers.present?(0)
    end
  end

  describe "item/6" do
    test "returns a map with all 6 keys including category" do
      result = Helpers.item("test_id", "Test Label", :pass, :error, 42, ["detail"])

      assert result == %{
               id: "test_id",
               label: "Test Label",
               status: :pass,
               category: :error,
               value: 42,
               details: ["detail"]
             }
    end

    test "defaults details to nil" do
      result = Helpers.item("test_id", "Test Label", :info, :analysis, 0)
      assert result.details == nil
    end
  end

  describe "decimal_to_float/1" do
    test "converts Decimal to float" do
      assert Helpers.decimal_to_float(Decimal.new("1.5")) == 1.5
    end

    test "returns float as-is" do
      assert Helpers.decimal_to_float(1.5) == 1.5
    end

    test "converts integer to float" do
      assert Helpers.decimal_to_float(3) == 3.0
    end

    test "returns nil for nil" do
      assert Helpers.decimal_to_float(nil) == nil
    end
  end
end
