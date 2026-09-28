defmodule GtfsPlanner.Gtfs.LanguageCodesTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.LanguageCodes

  describe "options/1" do
    test "lists every two-letter ISO 639-1 code once, sorted by English name" do
      assert [{"Common", _common}, {"All languages", options}] = LanguageCodes.options([])

      codes = Enum.map(options, &elem(&1, 1))

      # ISO 639-1 defines 184 codes; a truncated or padded list fails here.
      assert length(codes) == 184
      assert codes == Enum.uniq(codes)
      assert Enum.all?(codes, &Regex.match?(~r/^[a-z]{2}$/, &1))
      assert Enum.all?(~w(en es fr zh ar), &(&1 in codes))

      labels = Enum.map(options, &elem(&1, 0))
      assert labels == Enum.sort(labels)
      assert hd(labels) == "Abkhazian (ab)"
      assert "English (en)" in labels
    end

    test "lists the common languages first in a fixed order" do
      assert [{"Common", common}, _] = LanguageCodes.options([])

      assert Enum.map(common, &elem(&1, 1)) == ~w(en es fr de pt zh ar ru ja ko it vi)
      assert {"English (en)", "en"} = hd(common)
      assert {"Vietnamese (vi)", "vi"} = List.last(common)
    end

    test "offers Multilingual last in the common group only for include_mul: true" do
      assert [{"Common", without_mul}, _] = LanguageCodes.options([])
      refute Enum.any?(without_mul, &(elem(&1, 1) == "mul"))

      assert [{"Common", with_mul}, _] = LanguageCodes.options(include_mul: true)
      assert List.last(with_mul) == {"Multilingual (mul)", "mul"}
      assert with_mul == without_mul ++ [{"Multilingual (mul)", "mul"}]
    end

    test "keeps an unlisted current value first, labelled with its raw code" do
      assert [{"Current value", [{"en-US", "en-US"}]} | rest] =
               LanguageCodes.options(current: "en-US")

      assert Enum.map(rest, &elem(&1, 0)) == ["Common", "All languages"]
    end

    test "adds no current value group for a listed, multilingual or blank current value" do
      for current <- ["en", "zh", "", "   ", nil] do
        assert Enum.map(LanguageCodes.options(current: current), &elem(&1, 0)) ==
                 ["Common", "All languages"]
      end

      assert Enum.map(LanguageCodes.options(current: "mul", include_mul: true), &elem(&1, 0)) ==
               ["Common", "All languages"]
    end

    test "keeps a stored mul value selectable when the caller excludes mul" do
      assert [{"Current value", [{"mul", "mul"}]} | _] = LanguageCodes.options(current: "mul")
    end

    test "treats a present nil include_mul as excluded for a stored mul value" do
      assert [{"Current value", [{"mul", "mul"}]} | _] =
               LanguageCodes.options(include_mul: nil, current: "mul")
    end
  end

  describe "valid?/2" do
    test "accepts the listed codes" do
      assert LanguageCodes.valid?("en", [])
      assert LanguageCodes.valid?("zh", [])
      assert LanguageCodes.valid?("mi", [])
    end

    test "rejects unlisted, malformed and nil values" do
      refute LanguageCodes.valid?("en-US", [])
      refute LanguageCodes.valid?("en ", [])
      refute LanguageCodes.valid?("eng", [])
      refute LanguageCodes.valid?("", [])
      refute LanguageCodes.valid?(nil, [])
    end

    test "accepts mul only with include_mul: true" do
      refute LanguageCodes.valid?("mul", [])
      refute LanguageCodes.valid?("mul", include_mul: false)
      assert LanguageCodes.valid?("mul", include_mul: true)
    end

    test "returns false, not nil, for a present nil include_mul" do
      assert LanguageCodes.valid?("mul", include_mul: nil) == false
      assert LanguageCodes.valid?("en", include_mul: nil) == true
    end
  end
end
