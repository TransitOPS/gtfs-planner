defmodule GtfsPlanner.ColorTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Color

  describe "linear_channel/1" do
    test "takes the linear branch at or below the sRGB threshold" do
      assert Color.linear_channel(10) == 10 / 255 / 12.92
      assert Color.linear_channel(0) == 0.0
    end

    test "takes the power branch above the sRGB threshold" do
      assert Color.linear_channel(11) == :math.pow((11 / 255 + 0.055) / 1.055, 2.4)
      assert Color.linear_channel(255) == 1.0
      refute Color.linear_channel(11) == 11 / 255 / 12.92
    end
  end

  describe "relative_luminance/1" do
    test "is 0.0 for black and 1.0 for white" do
      assert Color.relative_luminance("000000") == 0.0
      assert Color.relative_luminance("FFFFFF") == 1.0
    end

    test "matches the replaced copies bit for bit in their sum order" do
      # Values the four replaced copies returned at revision f0920526.
      # D32F2F is order-sensitive: summing g and b first yields
      # 0.16087150202123557, one double away.
      assert Color.relative_luminance("D32F2F") == 0.16087150202123554
      assert Color.relative_luminance("1A2B3C") == 0.02273610305991506
      assert Color.relative_luminance("0F4C81") == 0.06855419953844218
    end

    test "accepts a leading hash and either case" do
      assert Color.relative_luminance("#ffffff") == Color.relative_luminance("FFFFFF")
      assert Color.relative_luminance("d32f2f") == Color.relative_luminance("D32F2F")
    end

    test "raises FunctionClauseError instead of guessing for any other value" do
      assert_raise FunctionClauseError, fn -> Color.relative_luminance("GGGGGG") end
      assert_raise FunctionClauseError, fn -> Color.relative_luminance("#GGGGGG") end
      assert_raise FunctionClauseError, fn -> Color.relative_luminance("#FFF") end
      assert_raise FunctionClauseError, fn -> Color.relative_luminance(nil) end
      assert_raise FunctionClauseError, fn -> Color.relative_luminance(123_456) end
    end
  end

  describe "contrast_ratio/2" do
    test "black on white is 21.0, with or without the hash prefix" do
      assert Color.contrast_ratio("FFFFFF", "000000") == 21.0
      assert Color.contrast_ratio("#ffffff", "000000") == 21.0
    end

    test "is symmetric and 1.0 against the same color" do
      assert Color.contrast_ratio("767676", "FFFFFF") == Color.contrast_ratio("FFFFFF", "767676")
      assert Color.contrast_ratio("808080", "808080") == 1.0
    end

    test "keeps the existing 4.5:1 boundary decisions" do
      assert Color.contrast_ratio("757575", "FFFFFF") >= 4.5
      assert Color.contrast_ratio("808080", "999999") < 4.5
    end
  end

  describe "text_color/1" do
    test "picks black on light backgrounds and white on dark ones" do
      assert Color.text_color("FFD200") == "000000"
      assert Color.text_color("FFFFFF") == "000000"
      assert Color.text_color("000000") == "FFFFFF"
    end

    test "accepts a leading hash and either case" do
      assert Color.text_color("#ffd200") == "000000"
      assert Color.text_color("#1A1A1A") == "FFFFFF"
    end
  end
end
