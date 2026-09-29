/**
 * flex_area_edit.js
 *
 * The pure ring-editing state behind the area editor's map (AC-12): the ring
 * maths the `FlexAreaMap` hook drives while points are being edited, and the
 * history and push buffer beside it. Nothing here reads the DOM, Leaflet or
 * `window`, so every rule below is testable on its own
 * (`js/__tests__/flex_area_edit_test.js`, EV-20); the hook owns the map, the
 * handles and the keyboard.
 *
 * A ring is a closed list of `[lon, lat]` positions: the first position is
 * repeated as the last, as GeoJSON's linear ring and the stored polygon's own
 * ring are. Every function returns a new ring and never mutates its input.
 * Wire order is `[lon, lat]`; the one axis swap for Leaflet is
 * `alignment_geometry.toLatLng`.
 *
 * Movement is the reference's keyboard path: 20 m a press, 100 m with Shift.
 * The conversion is the local sphere — north and south metres are a fixed
 * fraction of a degree, east and west metres shrink with the cosine of the
 * latitude — which is what makes a 20 m step measure 20 m by haversine.
 */

// Leaflet's own earth radius (`L.CRS.Earth.R`), so a step here and a length
// measured by `alignment_geometry.lengthMeters` agree.
const EARTH_RADIUS_M = 6371000;
const METRES_PER_DEGREE = (Math.PI / 180) * EARTH_RADIUS_M;
const SHORT_STEP_M = 20;
const LONG_STEP_M = 100;

// A ground-metre step east or west has no finite degree length at a pole.
const MIN_COS = 1e-6;

function position(value) {
  return Array.isArray(value) && value.length >= 2;
}

function copyPosition([lon, lat]) {
  return [lon, lat];
}

function samePosition(a, b) {
  return a[0] === b[0] && a[1] === b[1];
}

// The ring's own vertices: the submitted positions without the repeated closing
// one. A ring that is not closed keeps every position.
export function openRing(ring) {
  const positions = Array.isArray(ring) ? ring.filter(position).map(copyPosition) : [];
  if (positions.length > 1 && samePosition(positions[0], positions[positions.length - 1])) {
    return positions.slice(0, -1);
  }
  return positions;
}

/** Closes a ring: the first vertex repeated as the last, or `[]` when there is none. */
export function closeRing(ring) {
  const vertices = openRing(ring);
  if (vertices.length === 0) return [];
  return [...vertices, copyPosition(vertices[0])];
}

/** True when both rings are the same closed shape, position for position. */
export function sameRing(a, b) {
  const left = Array.isArray(a) ? a.filter(position) : [];
  const right = Array.isArray(b) ? b.filter(position) : [];
  if (left.length !== right.length) return false;
  return left.every((value, index) => samePosition(value, right[index]));
}

/** The number of vertices a ring holds, the closing repeat not counted. */
export function ringSize(ring) {
  return openRing(ring).length;
}

// One compass step of `metres` from a [lon, lat] position, on the local sphere.
function offset([lon, lat], direction, metres) {
  const latRad = (lat * Math.PI) / 180;
  const dLat = metres / METRES_PER_DEGREE;
  const cos = Math.cos(latRad);
  const dLon = Math.abs(cos) < MIN_COS ? 0 : metres / (METRES_PER_DEGREE * cos);

  switch (direction) {
    case "north":
      return [lon, lat + dLat];
    case "south":
      return [lon, lat - dLat];
    case "east":
      return [lon + dLon, lat];
    case "west":
      return [lon - dLon, lat];
    default:
      return [lon, lat];
  }
}

/**
 * `movePoint(ring, index, direction, {shift})` moves one vertex 20 m, or 100 m
 * with Shift, towards "north" | "south" | "east" | "west". The result stays
 * closed, and an index the ring does not have returns the ring unchanged.
 */
export function movePoint(ring, index, direction, { shift = false } = {}) {
  const vertices = openRing(ring);
  if (!Number.isInteger(index) || index < 0 || index >= vertices.length) {
    return closeRing(ring);
  }

  const metres = shift ? LONG_STEP_M : SHORT_STEP_M;
  const moved = vertices.map((value, at) =>
    at === index ? offset(value, direction, metres) : value,
  );

  return closeRing(moved);
}

/**
 * `insertAt(ring, edgeIndex, point)` inserts a position between the vertices at
 * `edgeIndex` and `edgeIndex + 1`, the closing edge included. The insertion
 * index is clamped into the ring, so a stale edge index still inserts.
 */
export function insertAt(ring, edgeIndex, point) {
  const vertices = openRing(ring);
  if (!position(point) || vertices.length === 0) return closeRing(ring);

  const at = Math.min(Math.max(Math.trunc(edgeIndex) + 1, 1), vertices.length);
  const next = [
    ...vertices.slice(0, at),
    copyPosition(point),
    ...vertices.slice(at),
  ];

  return closeRing(next);
}

/**
 * `removePoint(ring, index)` removes one vertex. A ring keeps at least a
 * triangle plus its closing repeat, so three vertices are refused and the ring
 * comes back unchanged.
 */
export function removePoint(ring, index) {
  const vertices = openRing(ring);
  if (vertices.length <= 3 || !Number.isInteger(index) || index < 0 || index >= vertices.length) {
    return closeRing(ring);
  }

  return closeRing(vertices.filter((_value, at) => at !== index));
}

/**
 * `createHistory(initial)` is the undo/redo stack of an editing session: every
 * change pushes the ring before it, `undo` walks back, `redo` walks forward,
 * and a change made after an undo drops the redo stack. It holds rings, not
 * operations, so a restored ring is exactly a ring the editor had.
 */
export function createHistory(initial = null) {
  let current = initial ? closeRing(initial) : null;
  let past = [];
  let future = [];

  const snapshot = (ring) => (ring ? ring.map(copyPosition) : null);

  return {
    /** The current ring, or null before the first one. */
    ring: () => snapshot(current),
    /** A fresh session: `push` records nothing from the previous one. */
    reset(ring) {
      current = ring ? closeRing(ring) : null;
      past = [];
      future = [];
    },
    /** Records `ring` as the new state; false when it does not change anything. */
    push(ring) {
      const closed = closeRing(ring);
      if (closed.length === 0) return false;
      if (current && sameRing(closed, current)) return false;
      past.push(current);
      current = closed;
      future = [];
      return true;
    },
    undo() {
      if (past.length === 0) return null;
      future.push(current);
      current = past.pop();
      return snapshot(current);
    },
    redo() {
      if (future.length === 0) return null;
      past.push(current);
      current = future.pop();
      return snapshot(current);
    },
    canUndo: () => past.length > 0,
    canRedo: () => future.length > 0,
  };
}

/**
 * `createPushBuffer(delayMs, push)` coalesces a burst of edits into one push:
 * `schedule` keeps only the newest ring and pushes it `delayMs` after the last
 * edit, `flush` pushes a pending ring at once, and `pending` says whether one
 * is waiting. This is the hook's 300 ms `flex_area_edited` rule.
 */
export function createPushBuffer(delayMs, push) {
  let timer = null;
  let waiting = false;
  let value = null;

  function clear() {
    if (timer !== null) clearTimeout(timer);
    timer = null;
  }

  function flush() {
    clear();
    if (!waiting) return false;

    waiting = false;
    const latest = value;
    value = null;
    push(latest);
    return true;
  }

  return {
    schedule(next) {
      value = next;
      waiting = true;
      clear();
      timer = setTimeout(flush, delayMs);
    },
    flush,
    cancel() {
      clear();
      waiting = false;
      value = null;
    },
    pending: () => waiting,
  };
}
