/**
 * Local route-color calculations shared by the create drawer's and Route >
 * Details' preview inputs.
 *
 * These mirror GtfsPlannerWeb.Components.RouteIdentity: the same strict
 * six-digit hex normalization, the same WCAG sRGB relative luminance, and the
 * same black/white fallback the server's changeset applies for an automatic
 * text color, so a preview and a trusted save agree on the same pair.
 *
 * Everything here is local presentation math (spec R7: "Color input preview is
 * local"): no result establishes persisted truth, and the server revalidates
 * every submitted color. Invalid input returns null rather than a partial
 * value, so a caller cannot build an inline style from it.
 */

// Spec R7: two valid non-white route colors read as the same line on a map
// below this CIE76 delta. The comparison is a warning only; it never blocks a
// save.
export const SIMILAR_COLOR_DELTA = 12;

const HEX_PATTERN = /^[0-9A-Fa-f]{6}$/;

/** Trims, drops one leading "#", uppercases; null for anything else. */
export function normalizeHex(value) {
  if (typeof value !== "string") return null;

  const stripped = value.trim().replace(/^#/, "");
  return HEX_PATTERN.test(stripped) ? stripped.toUpperCase() : null;
}

const channels = (hex) => [0, 2, 4].map((i) => Number.parseInt(hex.slice(i, i + 2), 16));

const linearize = (channel) => {
  const srgb = channel / 255;
  return srgb <= 0.04045 ? srgb / 12.92 : Math.pow((srgb + 0.055) / 1.055, 2.4);
};

const relativeLuminance = (hex) => {
  const [r, g, b] = channels(hex).map(linearize);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};

/** WCAG 2.x contrast ratio of two colors; null when either is unusable. */
export function contrastRatio(background, foreground) {
  const bg = normalizeHex(background);
  const fg = normalizeHex(foreground);

  if (!bg || !fg) return null;

  const [lighter, darker] = [relativeLuminance(bg), relativeLuminance(fg)];
  return (Math.max(lighter, darker) + 0.05) / (Math.min(lighter, darker) + 0.05);
}

/**
 * The black/white text the badge would show on this background: black unless
 * white contrasts more. Same pick as
 * `GtfsPlannerWeb.Components.RouteIdentity.automatic_text_color/1` and as the
 * `text_mode: "automatic"` recompute in `Route`'s changeset; null for an
 * unusable background.
 */
export function automaticTextColor(background) {
  const bg = normalizeHex(background);
  if (!bg) return null;

  return contrastRatio(bg, "000000") >= contrastRatio(bg, "FFFFFF")
    ? "000000"
    : "FFFFFF";
}

// CIE76 distance in CIE Lab. White is excluded from the comparison (below), so
// the constant here is the prototype's D65 matrix, not a calibrated Lab
// whitepoint.
const lab = (hex) => {
  const [r, g, b] = channels(hex).map(linearize);
  const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  const x = f((r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047);
  const y = f(r * 0.2126 + g * 0.7152 + b * 0.0722);
  const z = f((r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883);

  return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
};

const colorDelta = (a, b) => {
  const [p, q] = [lab(a), lab(b)];
  return Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]);
};

/**
 * The saved route whose color is closest to `color` within
 * `SIMILAR_COLOR_DELTA`, as an advisory hit the caller may render. Only valid
 * non-white colors are compared, so a near-white route color never warns and a
 * white saved route is never named. Returns null when the subject is unusable
 * or white, or when no candidate is within the threshold.
 */
export function similarColor(color, candidates) {
  const subject = normalizeHex(color);
  if (!subject || subject === "FFFFFF") return null;
  if (!Array.isArray(candidates)) return null;

  let nearest = null;

  for (const candidate of candidates) {
    const hex = normalizeHex(candidate?.route_color);
    if (!hex || hex === "FFFFFF") continue;

    const delta = colorDelta(subject, hex);
    if (delta >= SIMILAR_COLOR_DELTA) continue;

    if (!nearest || delta < nearest.delta) {
      nearest = {route: candidate, delta};
    }
  }

  if (!nearest) return null;

  return {route: nearest.route, delta: nearest.delta, severity: "advisory"};
}
