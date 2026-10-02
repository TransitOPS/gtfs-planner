defmodule GtfsPlanner.Gtfs.Fares.MoneyTest do
  @moduledoc """
  `Fares.Money` is the one parser and formatter every fare price goes through,
  so its cases are literals: each expected value is worked by hand from what an
  operator types on a fare machine (R9), not produced by the code under test.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Fares.Money

  describe "parse/1 reads what an operator types" do
    test "accepts dollars and cents with or without a dollar sign" do
      assert {:ok, amount} = Money.parse("1.5")
      assert Decimal.equal?(amount, Decimal.new("1.50"))

      assert {:ok, amount} = Money.parse("1.50")
      assert Decimal.equal?(amount, Decimal.new("1.50"))

      assert {:ok, amount} = Money.parse("$1.50")
      assert Decimal.equal?(amount, Decimal.new("1.50"))

      assert {:ok, amount} = Money.parse(".5")
      assert Decimal.equal?(amount, Decimal.new("0.50"))
    end

    test "keeps the exact exponent of what was typed" do
      # A stored amount is compared and diffed, so `1.5` and `1.50` must be the
      # same number written the way the operator wrote it.
      assert {:ok, one} = Money.parse("1.5")
      assert {:ok, two} = Money.parse("1.50")

      assert Decimal.equal?(one, two)
      assert Decimal.to_string(one, :normal) == "1.5"
      assert Decimal.to_string(two, :normal) == "1.50"
    end

    test "reads Free in any case as a price of zero" do
      for input <- ["Free", "FREE", "free", "fReE", " free "] do
        assert {:ok, amount} = Money.parse(input)
        assert Decimal.equal?(amount, 0), "expected #{inspect(input)} to be free"
      end
    end

    test "reads a blank cell as not sold" do
      for input <- ["", "   ", "\t"] do
        assert Money.parse(input) == {:ok, nil}
      end
    end

    test "refuses anything that is not a price" do
      for input <- [
            "1.5.0",
            "-1.00",
            "abc",
            "1.555",
            "1.",
            "$",
            "1 50",
            "1,50",
            "1.50 USD",
            "free ride",
            "Free1",
            "0x10"
          ] do
        assert Money.parse(input) == {:error, :invalid},
               "expected #{inspect(input)} to be refused"
      end
    end

    test "refuses a value that is not a string, so a missing field is never a price" do
      assert Money.parse(nil) == {:error, :invalid}
      assert Money.parse(1.5) == {:error, :invalid}
    end
  end

  describe "minor_units/1 reads the currency's smallest unit" do
    test "counts two for the common currencies" do
      assert Money.minor_units("USD") == 2
      assert Money.minor_units("CAD") == 2
      assert Money.minor_units("EUR") == 2
    end

    test "counts none for JPY and KRW, and three for the three-decimal currencies" do
      assert Money.minor_units("JPY") == 0
      assert Money.minor_units("KRW") == 0

      for currency <- ["BHD", "KWD", "JOD", "OMR", "TND"] do
        assert Money.minor_units(currency) == 3
      end
    end

    test "falls back to two for an unknown code" do
      assert Money.minor_units("XYZ") == 2
      assert Money.minor_units(nil) == 2
    end
  end

  describe "format/2 renders a stored amount" do
    test "writes the symbol and rounds to the currency's minor units" do
      assert Money.format(Decimal.new("1.5"), "USD") == "$1.50"
      assert Money.format(Decimal.new("1.555"), "USD") == "$1.56"
      assert Money.format(Decimal.new("1.5"), "EUR") == "€1.50"
      assert Money.format(Decimal.new("2"), "GBP") == "£2.00"
    end

    test "reads zero as Free, because a zero price is a free ride" do
      assert Money.format(Decimal.new("0"), "USD") == "Free"
      assert Money.format(Decimal.new("0.00"), "JPY") == "Free"
    end

    test "keeps the currency code when no symbol is known" do
      assert Money.format(Decimal.new(150), "JPY") == "JPY 150"
      assert Money.format(Decimal.new("9.99"), "CAD") == "CAD 9.99"
    end

    test "rounds to no decimals for a currency without minor units" do
      assert Money.format(Decimal.new("150.4"), "JPY") == "JPY 150"
      assert Money.format(Decimal.new("150.6"), "JPY") == "JPY 151"
    end

    test "leaves a missing amount as nil" do
      assert Money.format(nil, "USD") == nil
    end
  end
end
