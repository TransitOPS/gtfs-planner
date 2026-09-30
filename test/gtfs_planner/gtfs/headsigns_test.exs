defmodule GtfsPlanner.Gtfs.HeadsignsTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Headsigns

  @lint_ctx %{route_short_name: nil, route_long_name: nil, sibling_headsigns: []}

  describe "normalize/1" do
    test "trims values and maps blank forms to nil" do
      assert Headsigns.normalize(" Lincoln City ") == "Lincoln City"
      assert Headsigns.normalize(nil) == nil
      assert Headsigns.normalize("") == nil
      assert Headsigns.normalize("   ") == nil
    end
  end

  describe "effective_default/2" do
    test "prefers the timing value and normalizes both inputs" do
      assert Headsigns.effective_default("", " Lincoln City ") == "Lincoln City"

      assert Headsigns.effective_default("Lincoln City via Taft High", "Lincoln City") ==
               "Lincoln City via Taft High"

      assert Headsigns.effective_default(nil, nil) == nil
    end
  end

  describe "follows?/2" do
    test "a trip follows when trimmed values match, including blank equals blank" do
      assert Headsigns.follows?(" Lincoln City", "Lincoln City")
      assert Headsigns.follows?(nil, "")
      assert Headsigns.follows?(" ", nil)
    end

    test "case differences and different values do not follow" do
      refute Headsigns.follows?("Lincoln city", "Lincoln City")
      refute Headsigns.follows?("Roads End via Lincoln City", "Lincoln City")
      refute Headsigns.follows?(nil, "Lincoln City")
    end
  end

  describe "difference/3" do
    test "labels a case-or-spacing difference as the only likely typo" do
      assert Headsigns.difference("Lincoln city", "Lincoln City", nil) ==
               %{kind: :case_or_spacing, likely_typo: true}
    end

    test "labels blank values, interline trips and anything else" do
      assert Headsigns.difference(nil, "Lincoln City", nil) == %{kind: :blank, likely_typo: false}

      assert Headsigns.difference("Roads End via Lincoln City", "Lincoln City", %{
               route_short_name: "20"
             }) == %{kind: :interline, likely_typo: false}

      assert Headsigns.difference("Depoe Bay", "Lincoln City", nil) ==
               %{kind: :other, likely_typo: false}
    end
  end

  describe "lint/2" do
    test "flags a leading To or Towards and all capitals in the fixed order" do
      assert Headsigns.lint("TO LINCOLN CITY", @lint_ctx) == [:leading_to, :all_caps]
      assert Headsigns.lint("Towards Depoe Bay", @lint_ctx) == [:leading_to]
    end

    test "flags the route short name as a whole word and the long name as a substring" do
      assert Headsigns.lint("Route 20 Lincoln City", %{route_short_name: "20"}) == [:route_name]
      refute :route_name in Headsigns.lint("Lincoln City", %{route_short_name: "20"})
      refute :route_name in Headsigns.lint("Coast route C", %{route_short_name: "C"})

      assert :route_name in Headsigns.lint("Coast Highway to Lincoln City", %{
               route_long_name: "Coast Highway"
             })
    end

    test "flags values over 30 graphemes" do
      assert Headsigns.lint(String.duplicate("a", 31), @lint_ctx) == [:long]
      assert Headsigns.lint(String.duplicate("a", 30), @lint_ctx) == []
    end

    test "flags a sibling headsign equal except for case" do
      assert Headsigns.lint("Lincoln City express", %{sibling_headsigns: ["Lincoln City Express"]}) ==
               [:sibling_case]
    end

    test "returns no warnings for acceptable wording" do
      assert Headsigns.lint("Northbound", @lint_ctx) == []
      assert Headsigns.lint("Lincoln City via Depoe Bay", @lint_ctx) == []
      assert Headsigns.lint("Roads End, continues to Taft", @lint_ctx) == []
      assert Headsigns.lint(nil, @lint_ctx) == []
    end
  end
end
