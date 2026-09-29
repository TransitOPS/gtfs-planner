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

  # The prototype's advisory similarity threshold, in CIE76 units.
  @similar_color_delta 12

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

  # The normalized background and the foreground that reaches 4.5:1 against it,
  # or `:error` when the feed's background is missing or unvalidated.
  # `route_colors/1` and `route_badge/1` share this so a caller that paints its
  # own surface and the badge itself can never disagree about a route's colours.
  defp resolved_colors(route) do
    case normalize_hex(Map.get(route, :route_color)) do
      {:ok, norm_bg} ->
        {:ok, norm_bg, resolve_foreground(norm_bg, Map.get(route, :route_text_color))}

      :error ->
        :error
    end
  end

  @doc """
  The black/white text color the badge shows on a route color: black unless
  white gives more contrast, the same WCAG pick `Route`'s changeset applies for
  `text_mode: "automatic"` and `assets/js/route_identity_preview.js` mirrors in
  the browser.

  Accepts raw or normalized six-digit hex. Returns `:error` for anything else,
  so no caller can build a style from an unvalidated value.
  """
  @spec automatic_text_color(term()) :: String.t() | :error
  def automatic_text_color(background) do
    case normalize_hex(background) do
      {:ok, norm_bg} ->
        if contrast_ratio(norm_bg, "000000") >= contrast_ratio(norm_bg, "FFFFFF"),
          do: "000000",
          else: "FFFFFF"

      :error ->
        :error
    end
  end

  @doc """
  Returns a route's colours as a safe inline style and a fallback class.

  The style carries the normalized background and the foreground that reaches
  4.5:1 contrast against it, so a caller that paints its own surface (a timeline
  trip bar) never interpolates an unvalidated feed value. An invalid or missing
  background yields no style and the neutral `bg-base-300 text-base-content`
  class instead, so colour stays decorative and never the only signal.
  """
  @spec route_colors(map()) :: {String.t() | nil, String.t() | nil}
  def route_colors(route) do
    case resolved_colors(route) do
      {:ok, norm_bg, resolved_fg} ->
        {"background-color: ##{norm_bg}; color: ##{resolved_fg}", nil}

      :error ->
        {nil, "bg-base-300 text-base-content"}
    end
  end


  @doc """
  The saved candidate whose color is nearest to `color` within the prototype's
  advisory CIE76 delta of 12, as `%{route: candidate, delta: delta}`.

  Only valid non-white colors are compared, so a near-white route color never
  warns and a white saved route is never named. Returns `nil` when the subject
  is unusable or white, or when no candidate is within the threshold. This is
  the same arithmetic `assets/js/route_identity_preview.js` exports as
  `similarColor`, so the server-rendered advisory and the browser helper can
  never disagree about what looks alike on a map.
  """
  @spec similar_color(term(), [map()]) :: %{route: map(), delta: float()} | nil
  def similar_color(color, candidates) when is_list(candidates) do
    with {:ok, subject} <- normalize_hex(color),
         false <- subject == "FFFFFF" do
      candidates
      |> Enum.reduce(nil, fn candidate, nearest ->
        with {:ok, hex} <- normalize_hex(candidate[:route_color]),
             false <- hex == "FFFFFF",
             delta = color_delta(subject, hex),
             false <- delta >= @similar_color_delta,
             true <- is_nil(nearest) or delta < nearest.delta do
          %{route: candidate, delta: delta}
        else
          _other -> nearest
        end
      end)
    else
      _other -> nil
    end
  end

  def similar_color(_color, _candidates), do: nil

  # CIE76 distance in CIE Lab. White is excluded from the comparison (above),
  # so the constant here is the prototype's D65 matrix, not a calibrated Lab
  # whitepoint — the same conversion `route_identity_preview.js` carries.
  defp lab(hex) do
    {r, g, b} = hex_to_rgb(hex)
    [lr, lg, lb] = Enum.map([r, g, b], &linearize/1)
    f = fn t -> if t > 0.008856, do: :math.pow(t, 1 / 3), else: 7.787 * t + 16 / 116 end

    x = f.((lr * 0.4124 + lg * 0.3576 + lb * 0.1805) / 0.95047)
    y = f.(lr * 0.2126 + lg * 0.7152 + lb * 0.0722)
    z = f.((lr * 0.0193 + lg * 0.1192 + lb * 0.9505) / 1.08883)

    [116 * y - 16, 500 * (x - y), 200 * (y - z)]
  end

  defp color_delta(a, b) do
    [p1, p2, p3] = lab(a)
    [q1, q2, q3] = lab(b)
    :math.sqrt((p1 - q1) ** 2 + (p2 - q2) ** 2 + (p3 - q3) ** 2)
  end

  attr :route, :map, required: true
  attr :class, :any, default: nil

  attr :size, :string,
    values: ~w(default large),
    default: "default",
    doc: "`large` is the badge a route's own page leads its heading with"

  def route_badge(assigns) do
    {style, badge_class} =
      case resolved_colors(assigns.route) do
        {:ok, norm_bg, resolved_fg} ->
          # A near-white route color (FFD200 reads ~1.2:1 on white) needs an edge,
          # or the badge disappears into the page. Anything below the 3:1 WCAG
          # 1.4.11 floor for component graphics gets a subtle ring.
          edge =
            if contrast_ratio(norm_bg, "FFFFFF") < 3.0,
              do: " ring-1 ring-inset ring-subtle",
              else: ""

          {"background-color: ##{norm_bg}; color: ##{resolved_fg}", "shrink-0" <> edge}

        :error ->
          # Unvalidated feed values never reach the style attribute; a bad or
          # missing route_color falls back to a neutral surface, not to white.
          {nil, "bg-canvas text-strong ring-1 ring-inset ring-subtle shrink-0"}
      end

    label = badge_text(assigns.route)

    # A feed's short name can be a sentence: the large badge is capped at its
    # container and wraps the name inside it instead of pushing the page sideways.
    size_class =
      case assigns.size do
        "large" ->
          "min-h-10 min-w-12 max-w-full px-3 py-1 text-center text-xl leading-tight break-words"

        _default ->
          "px-2 py-0.5 text-xs leading-none"
      end

    assigns =
      assigns
      |> assign(:size_class, size_class)
      |> assign(:style_attrs, if(style, do: [style: style], else: []))
      |> assign(:badge_class, badge_class)
      |> assign(:label, label)

    ~H"""
    <span
      class={[
        "inline-flex items-center justify-center rounded-badge font-bold tabular-nums",
        @size_class,
        @badge_class,
        @class
      ]}
      {@style_attrs}
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
          automatic_text_color(norm_bg)
        end

      :error ->
        automatic_text_color(norm_bg)
    end
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
