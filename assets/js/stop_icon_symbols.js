/**
 * Canonical child-stop icon vocabulary mirrored from
 * lib/gtfs_planner_web/live/gtfs/station_diagram_components.ex.
 *
 * Keep this module in sync with the diagram render case around line 1639 and
 * the legend around line 2271. The diagram remains the visual source of truth;
 * this module gives JavaScript map render paths one shared copy of that
 * vocabulary.
 */

// These mirror DiagramPalette's safe fallbacks. Production renderers resolve
// the custom property from #diagram-page; the literal only protects isolated
// hook fixtures and a missing stylesheet from becoming invisible.
export const DIAGRAM_BASE_COLOR = "#0B5FFF";
export const DIAGRAM_ACTIVE_COLOR = "#BE123C";
export const HALO_COLOR = "#FFFFFF";

export function paletteColor(root, variable, fallback) {
  if (root) {
    const computed =
      typeof getComputedStyle === "function" ? getComputedStyle(root).getPropertyValue(variable) : "";
    const value = (computed || root.style?.getPropertyValue(variable) || "").trim();
    if (value) return value;
  }

  return fallback;
}

export const BADGE_SIZE_PX = 11;
const BADGE_GAP_PX = 2;

export function symbolForLocationType(locationType) {
  const parsed =
    typeof locationType === "number"
      ? locationType
      : Number.parseInt(String(locationType), 10);

  if (parsed === 0 || parsed === 2) return "rect_upright";
  if (parsed === 4) return "rect_square";
  return "circle";
}

// Map marker pixel sizes. These are the georeferencing map's own render sizes
// (the diagram is SVG in its own coordinate space, so only the *shape* grammar
// is shared, not these pixel values). Sized 50% larger than the original
// 8x12 / 10x10 for legibility against aerial imagery.
export function dimensionsForSymbol(symbol) {
  if (symbol === "rect_upright") return { width: "12px", height: "18px" };
  return { width: "15px", height: "15px" };
}

export function borderRadiusForSymbol(symbol) {
  if (symbol === "rect_upright" || symbol === "rect_square") return "2px";
  return "9999px";
}

// On the georeferencing map every marker on a level renders as one unified
// color: the level color is both fill and stroke, with no white-outline
// treatment for any location type. Shape still encodes location type; color
// encodes only the level (and, for the active level, the diagram base color).
export function treatmentForLocationType(locationType, color) {
  const symbol = symbolForLocationType(locationType);
  const { width, height } = dimensionsForSymbol(symbol);

  return {
    symbol,
    fill: color,
    stroke: color,
    width,
    height,
    borderRadius: borderRadiusForSymbol(symbol),
  };
}

const SVG_NS = "http://www.w3.org/2000/svg";

// Glyph paths in a normalized 0..1 viewBox, mirrored from the diagram's
// cross_level_stairs_icon (3-step staircase) and cross_level_elevator_icon
// (up/down triangle pair).
const STAIRS_PATH =
  "M 0 1 L 0 0.6667 L 0.3333 0.6667 L 0.3333 0.3333 " +
  "L 0.6667 0.3333 L 0.6667 0 L 1 0 L 1 1 Z";
const ELEVATOR_PATH =
  "M 0.5 0.05 L 0.85 0.45 L 0.15 0.45 Z " +
  "M 0.5 0.95 L 0.85 0.55 L 0.15 0.55 Z";

// Diagram rule: stairs(2) and escalator(4) share the staircase glyph; every
// other cross-level mode (elevator, walkway, etc.) uses the elevator glyph.
export function badgeSymbolForMode(pathwayMode) {
  const parsed =
    typeof pathwayMode === "number"
      ? pathwayMode
      : Number.parseInt(String(pathwayMode), 10);

  return parsed === 2 || parsed === 4 ? "stairs" : "elevator";
}

// Build one cross-level pathway badge as a small SVG glyph, positioned just to
// the right of a stop marker. The badge shares the level color so the stop and
// its pathway markers read as a single unified-color unit. `index` stacks
// multiple badges horizontally.
export function createBadgeElement(pathwayMode, color, index = 0) {
  const symbol = badgeSymbolForMode(pathwayMode);

  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 1 1");
  svg.setAttribute("width", String(BADGE_SIZE_PX));
  svg.setAttribute("height", String(BADGE_SIZE_PX));
  svg.classList.add("map-stop-badge", "pointer-events-none");
  svg.dataset.badgeSymbol = symbol;
  svg.style.position = "absolute";
  svg.style.top = "50%";
  svg.style.left = `calc(100% + ${BADGE_GAP_PX}px + ${
    index * (BADGE_SIZE_PX + BADGE_GAP_PX)
  }px)`;
  svg.style.transform = "translateY(-50%)";

  const path = document.createElementNS(SVG_NS, "path");
  path.setAttribute("d", symbol === "stairs" ? STAIRS_PATH : ELEVATOR_PATH);
  path.setAttribute("fill", color);
  svg.appendChild(path);

  return svg;
}

// Append a badge per cross-level pathway to a positioned marker element, in the
// level color.
export function appendStopBadges(markerEl, badges, color) {
  if (!markerEl || !Array.isArray(badges)) return;
  badges.forEach((badge, index) => {
    markerEl.appendChild(createBadgeElement(badge.pathway_mode, color, index));
  });
}
