import { describe, expect, it } from "vitest";
import {
  bearingDeg,
  bearingVector,
  offsetPolyline,
} from "../stop_map_geometry";

describe("offsetPolyline", () => {
  it("puts a north-bound line's points 4px to the east, the right of travel", () => {
    // Screen up is north, so a bus heading north runs from (0, 100) to (0, 0).
    const points = [
      [0, 100],
      [0, 50],
      [0, 0],
    ];

    expect(offsetPolyline(points, 4)).toEqual([
      [4, 100],
      [4, 50],
      [4, 0],
    ]);
  });

  it("puts a south-bound line's points 4px to the west", () => {
    const points = [
      [0, 0],
      [0, 50],
      [0, 100],
    ];

    expect(offsetPolyline(points, 4)).toEqual([
      [-4, 0],
      [-4, 50],
      [-4, 100],
    ]);
  });

  it("offsets a curve's middle vertex along the average of its two segments", () => {
    // A right turn: straight north, then due east. The corner's direction is the
    // diagonal, so its offset lands off-axis rather than jumping between the
    // two segment offsets.
    const points = [
      [0, 100],
      [0, 50],
      [50, 50],
    ];

    const [start, corner, end] = offsetPolyline(points, 6);
    const rootHalfDiagonal = 6 / Math.SQRT2;

    expect(start).toEqual([6, 100]);
    // The corner leaves along a diagonal, so it lands off both segments'
    // offsets rather than on either of them.
    expect(corner[0]).toBeCloseTo(rootHalfDiagonal);
    expect(corner[1]).toBeCloseTo(50 + rootHalfDiagonal);
    // The last vertex heads due east, whose right-hand side is below it.
    expect(end).toEqual([50, 56]);
  });

  it("scales the offset with the caller, so a nearer view separates more", () => {
    const points = [
      [100, 100],
      [100, 0],
    ];

    // Still on the east side of a north-bound line; only the distance changes,
    // because the side is a property of the direction of travel, not of the map.
    expect(offsetPolyline(points, 20)).toEqual([
      [120, 100],
      [120, 0],
    ]);
  });

  it("returns the projected points unchanged for fewer than two points", () => {
    expect(offsetPolyline([[3, 4]], 6)).toEqual([[3, 4]]);
    expect(offsetPolyline([], 6)).toEqual([]);
    expect(offsetPolyline(null, 6)).toEqual([]);
  });

  it("returns the projected points unchanged at offset zero", () => {
    const points = [
      [0, 100],
      [0, 0],
    ];

    expect(offsetPolyline(points, 0)).toEqual(points);
  });

  it("does not divide by zero at a vertex whose neighbours coincide", () => {
    const points = [
      [5, 5],
      [5, 5],
      [5, 40],
    ];

    const result = offsetPolyline(points, 4);

    expect(
      result.every(([x, y]) => Number.isFinite(x) && Number.isFinite(y)),
    ).toBe(true);
  });

  it("projects geographic points before offsetting", () => {
    // A scale stand-in for the map's projection, as the Leaflet stub uses.
    const project = ([lon, lat]) => [lon * 100, lat * 100];

    expect(
      offsetPolyline(
        [
          [0, 0.5],
          [0, 0.1],
        ],
        4,
        project,
      ),
    ).toEqual([
      [4, 50],
      [4, 10],
    ]);
  });
});

describe("bearingDeg", () => {
  it("reports due east as 90", () => {
    expect(bearingDeg([0, 0], [10, 0])).toBeCloseTo(90);
  });

  it("reports due north as 0 and due south as 180", () => {
    expect(bearingDeg([0, 0], [0, -10])).toBeCloseTo(0);
    expect(bearingDeg([0, 0], [0, 10])).toBeCloseTo(180);
    expect(bearingDeg([0, 0], [10, 10])).toBeCloseTo(135);
  });

  it("reports no heading for a zero-length segment", () => {
    expect(bearingDeg([4, 4], [4, 4])).toBeNull();
  });
});

describe("bearingVector", () => {
  it("points east for 90 and north for 0", () => {
    expect(bearingVector(90)[0]).toBeCloseTo(1);
    expect(bearingVector(90)[1]).toBeCloseTo(0);
    expect(bearingVector(0)[0]).toBeCloseTo(0);
    expect(bearingVector(0)[1]).toBeCloseTo(-1);
  });

  it("points nowhere when there is no bearing", () => {
    expect(bearingVector(null)).toEqual([0, 0]);
    expect(bearingVector(undefined)).toEqual([0, 0]);
    expect(bearingVector(Number.NaN)).toEqual([0, 0]);
  });
});
