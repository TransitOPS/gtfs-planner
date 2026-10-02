defmodule GtfsPlanner.ValuesTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Values

  describe "blank?/1" do
    test "treats nil and whitespace-only binaries as blank" do
      assert Values.blank?(nil)
      assert Values.blank?("")
      assert Values.blank?("  ")
      assert Values.blank?(" \t\n ")
    end

    test "treats falsey and empty non-binaries as present" do
      refute Values.blank?(0)
      refute Values.blank?(false)
      refute Values.blank?([])
      refute Values.blank?(%{})
      refute Values.blank?(:blank)
    end
  end

  describe "present?/1" do
    test "negates blank?/1" do
      refute Values.present?(nil)
      refute Values.present?("   ")
      assert Values.present?("Main St")
      assert Values.present?(0)
      assert Values.present?([])
    end
  end

  describe "presence/1" do
    test "returns the trimmed binary" do
      assert Values.presence(" Main St ") == "Main St"
      assert Values.presence("Riverdale") == "Riverdale"
    end

    test "returns nil for blank binaries" do
      assert Values.presence("") == nil
      assert Values.presence("  ") == nil
    end

    test "returns nil for every non-binary" do
      assert Values.presence(nil) == nil
      assert Values.presence(5) == nil
      assert Values.presence(["x"]) == nil
      assert Values.presence(%{name: "x"}) == nil
    end
  end

  describe "uuid?/1" do
    test "accepts lowercase and uppercase UUID strings" do
      assert Values.uuid?("a987fbc9-4bed-3078-cf07-9141ba07c9f3")
      assert Values.uuid?("A987FBC9-4BED-3078-CF07-9141BA07C9F3")
    end

    test "rejects malformed binaries and non-binaries" do
      refute Values.uuid?("not-a-uuid")
      refute Values.uuid?("")
      refute Values.uuid?(123)
      refute Values.uuid?(nil)
      refute Values.uuid?(["a987fbc9-4bed-3078-cf07-9141ba07c9f3"])
    end
  end

  describe "to_float/1" do
    test "converts decimals, integers and floats to floats" do
      assert Values.to_float(Decimal.new("1.5")) == 1.5
      assert Values.to_float(3) == 3.0
      assert Values.to_float(-0.25) == -0.25
    end

    test "returns nil for nil and for values no copy accepted" do
      assert Values.to_float(nil) == nil
      assert Values.to_float("1") == nil
      assert Values.to_float([1]) == nil
    end
  end

  describe "positive_integer/2" do
    test "parses a positive integer binary" do
      assert Values.positive_integer("3", 1) == 3
      assert Values.positive_integer("42", 1) == 42
    end

    test "returns the default for zero, trailing characters and an empty binary" do
      assert Values.positive_integer("0", 1) == 1
      assert Values.positive_integer("2x", 1) == 1
      assert Values.positive_integer("", 25) == 25
    end

    test "keeps positive integers and defaults every other term" do
      assert Values.positive_integer(4, 1) == 4
      assert Values.positive_integer(0, 1) == 1
      assert Values.positive_integer(-3, 1) == 1
      assert Values.positive_integer(nil, 25) == 25
      assert Values.positive_integer(["3"], 25) == 25
    end

    test "returns the caller's default instead of a hard-coded one" do
      assert Values.positive_integer("nope", 25) == 25
    end
  end

  describe "put_present/3" do
    test "puts present values, including empty lists and zero" do
      assert Values.put_present(%{}, :q, "Main St") == %{q: "Main St"}
      assert Values.put_present(%{}, :q, []) == %{q: []}
      assert Values.put_present(%{}, :q, 0) == %{q: 0}
    end

    test "puts a non-blank binary unchanged rather than trimmed" do
      assert Values.put_present(%{}, :q, " Main St ") == %{q: " Main St "}
    end

    test "skips nil and whitespace-only binaries" do
      assert Values.put_present(%{}, :q, nil) == %{}
      assert Values.put_present(%{}, :q, "  ") == %{}
    end

    test "replaces an existing key" do
      assert Values.put_present(%{q: "old"}, :q, "new") == %{q: "new"}
    end
  end
end
