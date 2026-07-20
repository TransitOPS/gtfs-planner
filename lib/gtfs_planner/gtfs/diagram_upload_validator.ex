defmodule GtfsPlanner.Gtfs.DiagramUploadValidator do
  @moduledoc """
  Validates new station-diagram raster uploads before they enter storage.

  Validation intentionally accepts only PNG and JPEG extensions whose bytes have
  the matching raster signature. Existing SVG diagrams are delivery-compatible,
  but SVG is never a valid new upload.
  """

  @type validation_result ::
          {:ok, %{extension: String.t(), content_type: String.t()}}
          | {:error, :unsupported_type | :content_mismatch | :empty_file}

  @spec validate(String.t(), binary()) :: validation_result()
  def validate(filename, binary) when is_binary(filename) and is_binary(binary) do
    case binary do
      <<>> -> {:error, :empty_file}
      _ -> validate_raster(extension(filename), binary)
    end
  end

  def validate(_, _), do: {:error, :unsupported_type}

  defp validate_raster(".png", binary) do
    if png?(binary) do
      {:ok, %{extension: ".png", content_type: "image/png"}}
    else
      {:error, :content_mismatch}
    end
  end

  defp validate_raster(extension, binary) when extension in [".jpg", ".jpeg"] do
    if jpeg?(binary) do
      {:ok, %{extension: extension, content_type: "image/jpeg"}}
    else
      {:error, :content_mismatch}
    end
  end

  defp validate_raster(_extension, _binary), do: {:error, :unsupported_type}

  defp extension(filename), do: filename |> Path.extname() |> String.downcase()

  # A PNG must contain its signature, its mandatory first IHDR chunk, and its
  # terminal IEND chunk. This is deliberately byte-level validation, not MIME
  # sniffing or a browser/image-library decode.
  defp png?(<<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", _::binary>> = binary) do
    byte_size(binary) >= 45 and
      binary_part(binary, byte_size(binary) - 12, 12) ==
        <<0, 0, 0, 0, "IEND", 174, 66, 96, 130>>
  end

  defp png?(_binary), do: false

  # JPEG has no fixed application header. Require a Start Of Image marker, a
  # following marker byte, and the End Of Image marker so a bare/truncated SOI
  # cannot be staged as a diagram.
  defp jpeg?(binary) when byte_size(binary) >= 6 do
    case binary do
      <<255, 216, 255, _marker, _::binary>> ->
        binary_part(binary, byte_size(binary) - 2, 2) == <<255, 217>>

      _ ->
        false
    end
  end

  defp jpeg?(_binary), do: false
end
