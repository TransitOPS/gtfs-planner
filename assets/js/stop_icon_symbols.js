/**
 * Canonical child-stop icon vocabulary mirrored from
 * lib/gtfs_planner_web/live/gtfs/station_diagram_components.ex.
 *
 * Keep this module in sync with the diagram render case around line 1639 and
 * the legend around line 2271. The diagram remains the visual source of truth;
 * this module gives JavaScript map render paths one shared copy of that
 * vocabulary.
 */

export const DIAGRAM_BASE_COLOR = "#0080FF";
export const DIAGRAM_ACTIVE_COLOR = "#FF4500";
export const HALO_COLOR = "#FFFFFF";

export const OUTLINE_DOT_MIN_OPACITY = 0.6;

export function symbolForLocationType(locationType) {
  const parsed =
    typeof locationType === "number"
      ? locationType
      : Number.parseInt(String(locationType), 10);

  if (parsed === 0 || parsed === 2) return "rect_upright";
  if (parsed === 4) return "rect_square";
  return "circle";
}

export function dimensionsForSymbol(symbol) {
  if (symbol === "rect_upright") return { width: "8px", height: "12px" };
  return { width: "10px", height: "10px" };
}

export function borderRadiusForSymbol(symbol) {
  if (symbol === "rect_upright" || symbol === "rect_square") return "2px";
  return "9999px";
}

export function isOutlineType(locationType) {
  const parsed =
    typeof locationType === "number"
      ? locationType
      : Number.parseInt(String(locationType), 10);

  return parsed === 2;
}

export function treatmentForLocationType(locationType, color) {
  const symbol = symbolForLocationType(locationType);
  const { width, height } = dimensionsForSymbol(symbol);
  const outline = isOutlineType(locationType);

  return {
    symbol,
    outline,
    fill: outline ? HALO_COLOR : color,
    stroke: outline ? color : HALO_COLOR,
    width,
    height,
    borderRadius: borderRadiusForSymbol(symbol),
  };
}
