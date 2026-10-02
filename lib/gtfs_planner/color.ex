defmodule GtfsPlanner.Color do
  @moduledoc """
  Canonical WCAG sRGB color math: channel linearization, relative luminance,
  contrast ratio and the automatic black/white text pick.

  Callers alias this module and call it qualified. Every function accepts
  `"RRGGBB"` or `"#RRGGBB"` in either case and treats anything else as a
  programming error, so a caller validates untrusted input first and no
  function guesses a fallback. The sum order
  `0.2126 * r + 0.7152 * g + 0.0722 * b` is part of the contract: it keeps
  `relative_luminance/1` bit-identical to the four copies this module replaces,
  and `Route.editor_changeset/3` persists `text_color/1`'s pick.
  """

  # One hexadecimal digit. Guarding all six digits in the head is what makes
  # invalid input raise `FunctionClauseError` instead of `ArgumentError`.
  defguardp is_hex_digit(char) when char in ?0..?9 or char in ?A..?F or char in ?a..?f

  @doc """
  Returns the WCAG relative luminance of a six-digit sRGB hex color.

  Accepts a leading `#` and either case. Any other value raises
  `FunctionClauseError`.
  """
  @spec relative_luminance(String.t()) :: float()
  def relative_luminance(hex) do
    {r, g, b} = hex_to_rgb(hex)
    0.2126 * linear_channel(r) + 0.7152 * linear_channel(g) + 0.0722 * linear_channel(b)
  end

  @doc """
  Returns the linearized sRGB channel value for an 8-bit channel.

  A channel at or below 0.04045 divides by 12.92; above it the channel takes
  the 2.4 gamma. Both branches match the copies this module replaces for all
  256 channel values, so the 0.03928 copy's threshold is not observable.
  """
  @spec linear_channel(0..255) :: float()
  def linear_channel(channel) do
    srgb = channel / 255

    if srgb <= 0.04045 do
      srgb / 12.92
    else
      :math.pow((srgb + 0.055) / 1.055, 2.4)
    end
  end

  @doc """
  Returns the WCAG contrast ratio between two six-digit hex colors.

  The ratio is `(lighter + 0.05) / (darker + 0.05)`, so black on white is 21.0.
  """
  @spec contrast_ratio(String.t(), String.t()) :: float()
  def contrast_ratio(background, foreground) do
    lighter = max(relative_luminance(background), relative_luminance(foreground))
    darker = min(relative_luminance(background), relative_luminance(foreground))
    (lighter + 0.05) / (darker + 0.05)
  end

  @doc """
  Returns `"000000"` or `"FFFFFF"`, whichever contrasts more with the background.

  A tie picks black. The pick agrees with both automatic text picks this module
  replaces for every 8-bit background.
  """
  @spec text_color(String.t()) :: String.t()
  def text_color(background) do
    if contrast_ratio(background, "000000") >= contrast_ratio(background, "FFFFFF") do
      "000000"
    else
      "FFFFFF"
    end
  end

  defp hex_to_rgb("#" <> hex), do: hex_to_rgb(hex)

  defp hex_to_rgb(<<r1, r2, g1, g2, b1, b2>>)
       when is_hex_digit(r1) and is_hex_digit(r2) and is_hex_digit(g1) and is_hex_digit(g2) and
              is_hex_digit(b1) and is_hex_digit(b2) do
    {channel(r1, r2), channel(g1, g2), channel(b1, b2)}
  end

  defp channel(high, low), do: String.to_integer(<<high, low>>, 16)
end
