defmodule GtfsPlanner.Gtfs.Routes.IdentifierTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Routes

  # Pure contract tests: infer_route_id/3 is called directly with fixed
  # candidate lists, submitted attrs and a taken-ID snapshot; each expected
  # ID and reason is listed independently. Final database allocation under
  # the version write lock belongs to step 7 and is verified there.

  defp example(route_id, route_short_name) do
    %{route_id: route_id, route_short_name: route_short_name}
  end

  describe "prefix inference (B10/B12 infer B15 for number 15)" do
    test "two matching examples with full agreement infer the shared prefix" do
      candidates = [example("B10", "10"), example("B12", "12")]

      assert {:ok, %{route_id: "B15", reason: :inferred_prefix, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_short_name: "15"}, [])
    end

    test "one matching example is not enough; the number is used instead" do
      assert {:ok, %{route_id: "15", reason: :number, mode: :generated}} =
               Routes.infer_route_id([example("B10", "10")], %{route_short_name: "15"}, [])
    end

    test "two matching examples still need at least 60% agreement" do
      candidates = [
        example("B10", "10"),
        example("B12", "12"),
        example("X13", "13"),
        example("X14", "14")
      ]

      assert {:ok, %{route_id: "15", reason: :number, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_short_name: "15"}, [])
    end

    test "two of three eligible examples reach 60% agreement" do
      candidates = [example("B10", "10"), example("B12", "12"), example("X13", "13")]

      assert {:ok, %{route_id: "B15", reason: :inferred_prefix, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_short_name: "15"}, [])
    end

    test "exactly 60% agreement qualifies" do
      candidates = [
        example("B10", "10"),
        example("B12", "12"),
        example("B3", "3"),
        example("X14", "14"),
        example("X15", "15")
      ]

      assert {:ok, %{route_id: "B20", reason: :inferred_prefix, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_short_name: "20"}, [])
    end

    test "only IDs ending in their own number are eligible examples" do
      candidates = [example("B10", "10"), example("B10x", "9")]

      assert {:ok, %{route_id: "15", reason: :number, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_short_name: "15"}, [])
    end

    test "candidate order does not change the result" do
      candidates = [example("X13", "13"), example("B12", "12"), example("B10", "10")]

      assert {:ok, %{route_id: "B15", reason: :inferred_prefix, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_short_name: "15"}, [])
    end

    test "inference runs only when a number was entered" do
      candidates = [example("B10", "10"), example("B12", "12")]

      assert {:ok, %{route_id: "blue-line", reason: :name_slug, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_long_name: "Blue Line"}, [])
    end
  end

  describe "slug fallback" do
    test "the lowercase name slug is used without a number" do
      assert {:ok, %{route_id: "blue-line-express", reason: :name_slug, mode: :generated}} =
               Routes.infer_route_id([], %{route_long_name: "Blue Line Express"}, [])
    end

    test "an empty slug falls back to route" do
      assert {:ok, %{route_id: "route", reason: :slug_fallback, mode: :generated}} =
               Routes.infer_route_id([], %{route_long_name: "   "}, [])

      assert {:ok, %{route_id: "route", reason: :slug_fallback, mode: :generated}} =
               Routes.infer_route_id([], %{}, [])
    end

    test "a non-Latin slug falls back to route" do
      assert {:ok, %{route_id: "route", reason: :slug_fallback, mode: :generated}} =
               Routes.infer_route_id([], %{route_long_name: "地铁环线"}, [])
    end
  end

  describe "generated duplicates" do
    test "a taken generated ID appends -2, then -3" do
      candidates = [example("B10", "10"), example("B12", "12")]

      assert {:ok, %{route_id: "B15-2", reason: :inferred_prefix, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_short_name: "15"}, ["B15"])

      assert {:ok, %{route_id: "B15-3", reason: :inferred_prefix, mode: :generated}} =
               Routes.infer_route_id(candidates, %{route_short_name: "15"}, ["B15", "B15-2"])
    end

    test "the route fallback suffixes the same way" do
      assert {:ok, %{route_id: "route-2", reason: :slug_fallback, mode: :generated}} =
               Routes.infer_route_id([], %{}, ["route"])
    end
  end

  describe "manual override" do
    test "a manual ID is returned verbatim without suffixing" do
      assert {:ok, %{route_id: "X1", reason: :manual, mode: :manual}} =
               Routes.infer_route_id([], %{route_id: "X1"}, ["X1-2"])
    end

    test "a manual duplicate remains an error instead of suffixing" do
      assert {:error, :duplicate_route_id} =
               Routes.infer_route_id([], %{route_id: "B15"}, ["B15", "B15-2"])
    end

    test "string-keyed attrs are recognized" do
      assert {:error, :duplicate_route_id} =
               Routes.infer_route_id([], %{"route_id" => "B15"}, ["B15"])

      assert {:ok, %{route_id: "B15", reason: :inferred_prefix, mode: :generated}} =
               Routes.infer_route_id(
                 [example("B10", "10"), example("B12", "12")],
                 %{"route_short_name" => "15"},
                 []
               )
    end
  end
end
