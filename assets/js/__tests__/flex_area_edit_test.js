import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  closeRing,
  createHistory,
  createPushBuffer,
  insertAt,
  movePoint,
  openRing,
  removePoint,
  ringSize,
  sameRing,
} from "../flex_area_edit";

// Merge evidence (EV-20) for the area editor's point editing (AC-12). The
// module under test is pure — no DOM, no Leaflet, no `window` — so these cases
// establish the ring maths, the history and the 300 ms push rule directly,
// with hand-computed distances. The composed browser behaviour (handles, the
// toolbar, the crossing marker, the server's validity answer) is EV-27's
// `area-edit-points` case.

// The same circle the app's own `L.CRS.Earth` measures with, so a step here and
// a length measured by `alignment_geometry.lengthMeters` agree (±0.5 m).
const EARTH_RADIUS_M = 6371000;

function haversine([lonA, latA], [lonB, latB]) {
  const rad = Math.PI / 180;
  const sinDLat = Math.sin(((latB - latA) * rad) / 2);
  const sinDLon = Math.sin(((lonB - lonA) * rad) / 2);
  const a =
    sinDLat * sinDLat +
    Math.cos(latA * rad) * Math.cos(latB * rad) * sinDLon * sinDLon;

  return 2 * EARTH_RADIUS_M * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// A closed square near Newport, the shape an edited drawn area starts as.
const SQUARE = [
  [-124.05, 44.6],
  [-124.04, 44.6],
  [-124.04, 44.61],
  [-124.05, 44.61],
  [-124.05, 44.6],
];

// A closed triangle: three vertices plus the closing repeat, the smallest ring
// an editor keeps.
const TRIANGLE = [
  [-124.05, 44.6],
  [-124.04, 44.6],
  [-124.045, 44.61],
  [-124.05, 44.6],
];

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("ring shape", () => {
  it("closes an open ring once and drops the repeat again", () => {
    const open = [
      [-124.05, 44.6],
      [-124.04, 44.6],
      [-124.04, 44.61],
    ];

    const closed = closeRing(open);

    expect(closed).toHaveLength(4);
    expect(closed[3]).toEqual(closed[0]);
    expect(closeRing(closed)).toEqual(closed);
    expect(openRing(closed)).toEqual(open);
    expect(ringSize(closed)).toBe(3);
    expect(closeRing([])).toEqual([]);
  });

  it("leaves the submitted ring untouched", () => {
    const ring = [...SQUARE.map((position) => [...position])];
    const before = JSON.stringify(ring);

    movePoint(ring, 0, "east");
    insertAt(ring, 1, [-124.045, 44.605]);
    removePoint(ring, 2);

    expect(JSON.stringify(ring)).toBe(before);
  });
});

describe("movePoint", () => {
  it("moves one vertex 20 m east, measured by haversine, and keeps the ring closed", () => {
    const moved = movePoint(SQUARE, 1, "east");

    expect(haversine(SQUARE[1], moved[1])).toBeGreaterThanOrEqual(19.5);
    expect(haversine(SQUARE[1], moved[1])).toBeLessThanOrEqual(20.5);
    expect(moved[1][1]).toBe(SQUARE[1][1]);
    expect(moved[1][0]).toBeGreaterThan(SQUARE[1][0]);
    expect(moved).toHaveLength(SQUARE.length);
    expect(moved[4]).toEqual(moved[0]);
    expect(moved[0]).toEqual(SQUARE[0]);
    expect(moved[2]).toEqual(SQUARE[2]);
  });

  it("moves 100 m while Shift is held", () => {
    const short = movePoint(SQUARE, 1, "east", { shift: false });
    const long = movePoint(SQUARE, 1, "east", { shift: true });

    expect(haversine(SQUARE[1], short[1])).toBeLessThanOrEqual(20.5);
    expect(haversine(SQUARE[1], long[1])).toBeGreaterThanOrEqual(99.5);
    expect(haversine(SQUARE[1], long[1])).toBeLessThanOrEqual(100.5);
  });

  it("moves north, south and west by the same 20 m", () => {
    for (const direction of ["north", "south", "west"]) {
      const moved = movePoint(SQUARE, 3, direction);
      const distance = haversine(SQUARE[3], moved[3]);

      expect(distance).toBeGreaterThanOrEqual(19.5);
      expect(distance).toBeLessThanOrEqual(20.5);
    }
  });

  it("returns the ring unchanged for an index it does not have", () => {
    expect(sameRing(movePoint(SQUARE, 9, "east"), SQUARE)).toBe(true);
    expect(sameRing(movePoint(SQUARE, -1, "east"), SQUARE)).toBe(true);
  });
});

describe("insertAt and removePoint", () => {
  it("inserts between the edge's two vertices and closes the ring again", () => {
    const inserted = insertAt(SQUARE, 0, [-124.045, 44.6]);

    expect(inserted).toHaveLength(SQUARE.length + 1);
    expect(inserted[0]).toEqual(SQUARE[0]);
    expect(inserted[1]).toEqual([-124.045, 44.6]);
    expect(inserted[2]).toEqual(SQUARE[1]);
    expect(inserted[inserted.length - 1]).toEqual(inserted[0]);
  });

  it("inserts on the closing edge before the repeated first vertex", () => {
    const inserted = insertAt(SQUARE, 3, [-124.05, 44.605]);

    expect(inserted).toHaveLength(SQUARE.length + 1);
    expect(inserted[4]).toEqual([-124.05, 44.605]);
    expect(inserted[3]).toEqual(SQUARE[3]);
    expect(inserted[inserted.length - 1]).toEqual(inserted[0]);
  });

  it("removes one vertex down to a triangle", () => {
    const removed = removePoint(SQUARE, 1);

    expect(removed).toHaveLength(SQUARE.length - 1);
    expect(removed).toHaveLength(4);
    expect(removed).not.toContainEqual(SQUARE[1]);
    expect(removed[removed.length - 1]).toEqual(removed[0]);
  });

  it("refuses to remove below a triangle plus its closing vertex", () => {
    expect(sameRing(removePoint(TRIANGLE, 0), TRIANGLE)).toBe(true);
    expect(removePoint(TRIANGLE, 0)).toHaveLength(4);
    expect(sameRing(removePoint(SQUARE, 7), SQUARE)).toBe(true);
  });
});

describe("createHistory", () => {
  it("undoes three edits back to the ring after two, and redoes the third", () => {
    const history = createHistory(SQUARE);
    const first = movePoint(SQUARE, 0, "east");
    const second = movePoint(first, 1, "east");
    const third = movePoint(second, 2, "east");

    expect(history.canUndo()).toBe(false);
    expect(history.canRedo()).toBe(false);

    expect(history.push(first)).toBe(true);
    expect(history.push(second)).toBe(true);
    expect(history.push(third)).toBe(true);
    expect(history.canUndo()).toBe(true);

    expect(sameRing(history.undo(), second)).toBe(true);
    expect(history.canRedo()).toBe(true);
    expect(sameRing(history.redo(), third)).toBe(true);
    expect(history.canRedo()).toBe(false);
    expect(sameRing(history.ring(), third)).toBe(true);
  });

  it("drops the redo stack when a new edit follows an undo", () => {
    const history = createHistory(SQUARE);
    const first = movePoint(SQUARE, 0, "east");
    const second = movePoint(first, 1, "east");

    history.push(first);
    history.push(second);
    expect(sameRing(history.undo(), first)).toBe(true);
    expect(history.canRedo()).toBe(true);

    const other = movePoint(first, 2, "north");

    expect(history.push(other)).toBe(true);
    expect(history.canRedo()).toBe(false);
    expect(history.redo()).toBe(null);
    expect(sameRing(history.ring(), other)).toBe(true);
  });

  it("records nothing for a ring that did not change, and resets a fresh session", () => {
    const history = createHistory(SQUARE);

    expect(history.push(SQUARE)).toBe(false);
    expect(history.canUndo()).toBe(false);

    history.push(movePoint(SQUARE, 0, "east"));
    expect(history.canUndo()).toBe(true);

    history.reset(TRIANGLE);
    expect(history.canUndo()).toBe(false);
    expect(history.canRedo()).toBe(false);
    expect(sameRing(history.ring(), TRIANGLE)).toBe(true);
  });
});

describe("createPushBuffer", () => {
  it("pushes one burst once, with the last ring, 300 ms after the last edit", () => {
    const pushed = [];
    const buffer = createPushBuffer(300, (ring) => pushed.push(ring));

    buffer.schedule(SQUARE);
    vi.advanceTimersByTime(200);
    buffer.schedule(movePoint(SQUARE, 0, "east"));
    vi.advanceTimersByTime(200);
    const last = movePoint(SQUARE, 1, "east");
    buffer.schedule(last);

    expect(buffer.pending()).toBe(true);
    expect(pushed).toEqual([]);

    vi.advanceTimersByTime(299);
    expect(pushed).toEqual([]);

    vi.advanceTimersByTime(1);
    expect(pushed).toHaveLength(1);
    expect(pushed[0]).toEqual(last);
    expect(buffer.pending()).toBe(false);
  });

  it("flushes a pending ring at once and cancels the timer", () => {
    const pushed = [];
    const buffer = createPushBuffer(300, (ring) => pushed.push(ring));

    buffer.schedule(SQUARE);
    expect(buffer.flush()).toBe(true);
    expect(pushed).toEqual([SQUARE]);

    vi.advanceTimersByTime(600);
    expect(pushed).toHaveLength(1);
    expect(buffer.flush()).toBe(false);
    expect(buffer.pending()).toBe(false);
  });

  it("drops a cancelled ring", () => {
    const pushed = [];
    const buffer = createPushBuffer(300, (ring) => pushed.push(ring));

    buffer.schedule(SQUARE);
    buffer.cancel();

    vi.advanceTimersByTime(600);
    expect(pushed).toEqual([]);
  });
});
