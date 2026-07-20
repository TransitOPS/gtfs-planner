defmodule GtfsPlanner.Gtfs.DiagramUploadValidatorTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.DiagramUploadValidator

  @png <<
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    0,
    0,
    0,
    13,
    "IHDR",
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    8,
    6,
    0,
    0,
    0,
    31,
    21,
    196,
    137,
    0,
    0,
    0,
    0,
    "IEND",
    174,
    66,
    96,
    130
  >>
  @jpeg <<255, 216, 255, 224, 0, 16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 255, 217>>

  describe "validate/2" do
    test "accepts PNG bytes only for a PNG extension" do
      assert {:ok, %{extension: ".png", content_type: "image/png"}} =
               DiagramUploadValidator.validate("floorplan.png", @png)
    end

    test "accepts JPEG bytes for both supported JPEG extensions" do
      assert {:ok, %{extension: ".jpg", content_type: "image/jpeg"}} =
               DiagramUploadValidator.validate("floorplan.jpg", @jpeg)

      assert {:ok, %{extension: ".jpeg", content_type: "image/jpeg"}} =
               DiagramUploadValidator.validate("floorplan.JPEG", @jpeg)
    end

    test "rejects empty files" do
      assert {:error, :empty_file} = DiagramUploadValidator.validate("floorplan.png", <<>>)
    end

    test "rejects truncated and mismatched raster bytes" do
      assert {:error, :content_mismatch} =
               DiagramUploadValidator.validate("floorplan.png", binary_part(@png, 0, 8))

      assert {:error, :content_mismatch} =
               DiagramUploadValidator.validate("floorplan.jpeg", binary_part(@jpeg, 0, 4))

      assert {:error, :content_mismatch} =
               DiagramUploadValidator.validate("floorplan.jpg", @png)

      assert {:error, :content_mismatch} =
               DiagramUploadValidator.validate("floorplan.png", @jpeg)
    end

    test "rejects unsupported extensions and SVG input" do
      assert {:error, :unsupported_type} =
               DiagramUploadValidator.validate("floorplan.svg", "<svg></svg>")

      assert {:error, :unsupported_type} =
               DiagramUploadValidator.validate("floorplan.gif", "GIF89a")
    end
  end
end
