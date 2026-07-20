defmodule GtfsPlannerWeb.Components.DiagramPalette do
  @moduledoc """
  Named visual roles for station diagrams.

  Diagram imagery is operator supplied, so these colors are always paired with the
  durable shape, label, halo, line, direction, and weight cues recorded here. The
  module is the single source for CSS custom properties consumed by diagram HEEx and
  JavaScript in later work.
  """

  @roles %{
    active_stop: %{
      css_variable: "--diagram-active-stop",
      color: "#0B5FFF",
      cue: "filled circle and active label"
    },
    fallback_stop: %{
      css_variable: "--diagram-fallback-stop",
      color: "#7C3AED",
      cue: "diamond marker and fallback label"
    },
    other_level_stop: %{
      css_variable: "--diagram-other-level-stop",
      color: "#4B5563",
      cue: "outlined circle and level label"
    },
    pathway_forward: %{
      css_variable: "--diagram-pathway-forward",
      color: "#FF00FF",
      cue: "solid line with forward arrow"
    },
    pathway_reverse: %{
      css_variable: "--diagram-pathway-reverse",
      color: "#B45309",
      cue: "dashed line with reverse arrow"
    },
    pathway_inactive: %{
      css_variable: "--diagram-pathway-inactive",
      color: "#6B7280",
      cue: "dotted line and unavailable label"
    },
    label: %{css_variable: "--diagram-label", color: "#1F2937", cue: "text label"},
    label_halo: %{
      css_variable: "--diagram-label-halo",
      color: "#FFFFFF",
      cue: "label outline halo"
    },
    ruler: %{
      css_variable: "--diagram-ruler",
      color: "#155E75",
      cue: "tick marks and distance text"
    },
    focus: %{css_variable: "--diagram-focus", color: "#1D4ED8", cue: "two-pixel focus ring"},
    selection: %{
      css_variable: "--diagram-selection",
      color: "#BE123C",
      cue: "selection outline and handle"
    },
    building_outline: %{
      css_variable: "--diagram-building-outline",
      color: "#374151",
      cue: "heavy building boundary"
    },
    error: %{
      css_variable: "--diagram-error",
      color: "#B91C1C",
      cue: "error icon and recovery text"
    },
    degraded: %{
      css_variable: "--diagram-degraded",
      color: "#6B7280",
      cue: "dashed boundary and degraded text"
    }
  }

  @doc "Returns the semantic role metadata consumed by diagram renderers."
  @spec roles() :: %{atom() => %{css_variable: String.t(), color: String.t(), cue: String.t()}}
  def roles, do: @roles

  @doc "Returns named CSS variables in deterministic lexical order."
  @spec css_variables() :: [{String.t(), String.t()}]
  def css_variables do
    @roles
    |> Map.values()
    |> Enum.map(&{&1.css_variable, &1.color})
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Serializes the palette for a `style` attribute or generated stylesheet."
  @spec css_custom_properties() :: String.t()
  def css_custom_properties do
    css_variables()
    |> Enum.map_join(" ", fn {name, color} -> "#{name}: #{color};" end)
  end

  @doc "Returns the WCAG contrast ratio for two six-digit CSS hex colors."
  @spec contrast_ratio(String.t(), String.t()) :: float()
  def contrast_ratio(background, foreground) do
    lighter = max(relative_luminance(background), relative_luminance(foreground))
    darker = min(relative_luminance(background), relative_luminance(foreground))
    (lighter + 0.05) / (darker + 0.05)
  end

  defp relative_luminance("#" <> hex), do: relative_luminance(hex)

  defp relative_luminance(<<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    0.2126 * linearize(String.to_integer(r, 16)) +
      0.7152 * linearize(String.to_integer(g, 16)) +
      0.0722 * linearize(String.to_integer(b, 16))
  end

  defp linearize(channel) do
    srgb = channel / 255
    if srgb <= 0.04045, do: srgb / 12.92, else: :math.pow((srgb + 0.055) / 1.055, 2.4)
  end
end
