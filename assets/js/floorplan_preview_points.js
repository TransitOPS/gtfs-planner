/**
 * DOM-free preview-coordinate helpers for active child-stop pins.
 *
 * This module follows the coordinate convention in
 * lib/gtfs_planner/gtfs/floorplan_transform.ex but returns ONLY map-container
 * pixels. The server transform remains the durable source of truth; this helper
 * exists purely to position preview pins while the operator manipulates the
 * active floorplan, so browser geometry never becomes a data source.
 *
 * Coordinate convention (matching floorplan_transform.ex `project/4`):
 *   1. Diagram coordinates are width-normalized and top-left anchored.
 *   2. One diagram unit equals `imageNaturalWidth / 100` natural image pixels on
 *      both axes.
 *   3. The untransformed image is rendered via `object-contain` inside the
 *      Leaflet canvas (letterboxed when aspect ratios differ).
 *   4. The active floorplan transform matches `#map-alignment-overlay`:
 *      CSS `translate(tx, ty) rotate(rotation) scale(scale)` around the canvas
 *      center, so offsets are scaled, then rotated, then translated.
 *   5. Positive rotation follows CSS screen coordinates (clockwise): a point
 *      right of center moves downward under `rotation: 90`.
 *
 * No dependencies: standard JavaScript math only. The module imports nothing.
 */

function isFiniteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function coerceNumber(value) {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

// Normalize a raw diagram coordinate into `{x, y}` with finite numbers, or
// `null`. Accepts numeric or numeric-string `x`/`y` keys (JSON payloads encode
// atom-keyed maps as string keys).
export function normalizeDiagramPoint(raw) {
  if (!raw || typeof raw !== "object") return null;

  const x = coerceNumber(raw.x);
  const y = coerceNumber(raw.y);

  if (x === null || y === null) return null;

  return { x, y };
}

// Compute the object-contain bounds of the natural image inside the canvas.
// Returns `{x, y, width, height}` in canvas pixels, or `null` for non-positive
// or non-finite dimensions.
export function containedImageRect({
  canvasWidth,
  canvasHeight,
  imageNaturalWidth,
  imageNaturalHeight,
} = {}) {
  if (
    !isFiniteNumber(canvasWidth) ||
    !isFiniteNumber(canvasHeight) ||
    canvasWidth <= 0 ||
    canvasHeight <= 0
  ) {
    return null;
  }

  if (
    !isFiniteNumber(imageNaturalWidth) ||
    !isFiniteNumber(imageNaturalHeight) ||
    imageNaturalWidth <= 0 ||
    imageNaturalHeight <= 0
  ) {
    return null;
  }

  const containScale = Math.min(
    canvasWidth / imageNaturalWidth,
    canvasHeight / imageNaturalHeight,
  );

  const width = imageNaturalWidth * containScale;
  const height = imageNaturalHeight * containScale;
  const x = (canvasWidth - width) / 2;
  const y = (canvasHeight - height) / 2;

  return { x, y, width, height };
}

function normalizeTransform(transform) {
  if (!transform || typeof transform !== "object") return null;

  const { tx, ty, rotation, scale } = transform;

  if (
    !isFiniteNumber(tx) ||
    !isFiniteNumber(ty) ||
    !isFiniteNumber(rotation) ||
    !isFiniteNumber(scale) ||
    scale <= 0
  ) {
    return null;
  }

  return { tx, ty, rotation, scale };
}

// Map a width-normalized diagram coordinate to a map-container pixel under the
// current active floorplan transform. Returns `{x, y}` or `null` when any input
// is invalid (fail-fast).
export function previewPointForDiagramCoordinate({
  coordinate,
  transform,
  canvasWidth,
  canvasHeight,
  imageNaturalWidth,
  imageNaturalHeight,
} = {}) {
  const point = normalizeDiagramPoint(coordinate);
  if (point === null) return null;

  const activeTransform = normalizeTransform(transform);
  if (activeTransform === null) return null;

  const rect = containedImageRect({
    canvasWidth,
    canvasHeight,
    imageNaturalWidth,
    imageNaturalHeight,
  });
  if (rect === null) return null;

  // Diagram units -> natural image pixels -> contained-image pixels.
  // One diagram unit is `imageNaturalWidth / 100` natural px on both axes; the
  // object-contain scale is `rect.width / imageNaturalWidth`, so one diagram
  // unit maps to `rect.width / 100` contained px.
  const unitPx = rect.width / 100;
  const containedX = rect.x + point.x * unitPx;
  const containedY = rect.y + point.y * unitPx;

  // Apply the overlay transform around the canvas center: scale, then rotate,
  // then translate.
  const centerX = canvasWidth / 2;
  const centerY = canvasHeight / 2;

  let dx = containedX - centerX;
  let dy = containedY - centerY;

  dx *= activeTransform.scale;
  dy *= activeTransform.scale;

  const rotationRad = (activeTransform.rotation * Math.PI) / 180;
  const cos = Math.cos(rotationRad);
  const sin = Math.sin(rotationRad);

  const rotatedX = dx * cos - dy * sin;
  const rotatedY = dx * sin + dy * cos;

  return {
    x: centerX + rotatedX + activeTransform.tx,
    y: centerY + rotatedY + activeTransform.ty,
  };
}
