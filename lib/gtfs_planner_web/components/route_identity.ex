defmodule GtfsPlannerWeb.Components.RouteIdentity do
  @moduledoc """
  Safe route-color presentation: strict hex normalization, WCAG sRGB contrast
  selection, and a badge component that never interpolates unvalidated feed
  values into inline styles.

  Called through an explicit alias in each consumer; not part of the global
  `GtfsPlannerWeb.html_helpers/0` import set.
  """
  use Phoenix.Component

  @hex_regex ~r/\A[0-9A-Fa-f]{6}\z/

  @spec normalize_hex(term()) :: {:ok, String.t()} | :error
  def normalize_hex(value) when is_binary(value) do
    stripped = String.trim(value)

    stripped =
      case stripped do
        "#" <> rest -> rest
        other -> other
      end

    if Regex.match?(@hex_regex, stripped) do
      {:ok, String.upcase(stripped)}
    else
      :error
    end
  end

  def normalize_hex(_), do: :error

  @spec contrast_ratio(String.t(), String.t()) :: float()
  def contrast_ratio(background, foreground) do
    l1 = relative_luminance(background)
    l2 = relative_luminance(foreground)
    lighter = max(l1, l2)
    darker = min(l1, l2)
    (lighter + 0.05) / (darker + 0.05)
  end

  attr :route, :map, required: true
  attr :class, :any, default: nil

  def route_badge(assigns) do
    bg = Map.get(assigns.route, :route_color)
    fg = Map.get(assigns.route, :route_text_color)

    {style, badge_class} =
      case normalize_hex(bg) do
        {:ok, norm_bg} ->
          resolved_fg = resolve_foreground(norm_bg, fg)
          {"background-color: ##{norm_bg}; color: ##{resolved_fg}", nil}

        :error ->
          {nil, "bg-base-300 text-base-content"}
      end

    label = badge_text(assigns.route)

    assigns =
      assigns
      |> assign(:style, style)
      |> assign(:badge_class, badge_class)
      |> assign(:label, label)

    ~H"""
    <span
      :if={@style}
      class={[
        "inline-flex items-center justify-center rounded px-2 py-0.5 text-xs font-medium",
        @class
      ]}
      style={@style}
    >
      {@label}
    </span>
    <span
      :if={!@style}
      class={[
        "inline-flex items-center justify-center rounded px-2 py-0.5 text-xs font-medium",
        @badge_class,
        @class
      ]}
    >
      {@label}
    </span>
    """
  end

  defp resolve_foreground(norm_bg, fg) do
    case normalize_hex(fg) do
      {:ok, norm_fg} ->
        if contrast_ratio(norm_bg, norm_fg) >= 4.5 do
          norm_fg
        else
          higher_contrast_choice(norm_bg)
        end

      :error ->
        higher_contrast_choice(norm_bg)
    end
  end

  defp higher_contrast_choice(norm_bg) do
    black_ratio = contrast_ratio(norm_bg, "000000")
    white_ratio = contrast_ratio(norm_bg, "FFFFFF")
    if black_ratio >= white_ratio, do: "000000", else: "FFFFFF"
  end

  defp badge_text(route) do
    short_name = Map.get(route, :route_short_name)
    route_id = Map.get(route, :route_id)

    cond do
      present?(short_name) -> short_name
      present?(route_id) -> route_id
      true -> "Unknown route"
    end
  end

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp relative_luminance(hex) do
    {r, g, b} = hex_to_rgb(hex)
    0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
  end

  defp hex_to_rgb(<<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp linearize(channel) do
    srgb = channel / 255

    if srgb <= 0.04045 do
      srgb / 12.92
    else
      :math.pow((srgb + 0.055) / 1.055, 2.4)
    end
  end
end
