/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { describe, expect, it } from "vitest";
import { convertImportedShape } from "../alignment_geometry";

const L = window.L;
// Leaflet's spherical radius (metres), so degree offsets below are exact
// under L.CRS.Earth.distance. Used only to construct fixtures; every
// split/flag expectation is a hardcoded literal.
const R = 6371008;
const DEG = 180 / Math.PI;
const mDeg = (m) => (m / R) * DEG;

describe("convertImportedShape by distance", () => {
  it("splits a straight shape at the interpolated visit distance", () => {
    const shapePoints = [
      [0, 0, 0],
      [mDeg(100), 0, 100],
      [mDeg(200), 0, 200],
      [mDeg(300), 0, 300],
    ];
    const visits = [
      [0, 0],
      [mDeg(150), 0],
      [mDeg(300), 0],
    ];

    const result = convertImportedShape({
      visits,
      shapePoints,
      visitDistances: [0, 150, 300],
    });

    expect(result.method).toBe("distance");
    expect(result.sections).toHaveLength(2);
    expect(result.sections[0].flagged).toBe(false);
    expect(result.sections[1].flagged).toBe(false);
    // The interpolated 150 m split point closes the first section and
    // opens the second one.
    const firstEnd = result.sections[0].interior.at(-1);
    expect(firstEnd[0]).toBeCloseTo(mDeg(150), 12);
    expect(firstEnd[1]).toBeCloseTo(0, 12);
    expect(result.sections[1].interior[0]).toEqual(firstEnd);
    // Each interior holds its split endpoints plus the shape points
    // strictly between them.
    expect(result.sections[0].interior).toHaveLength(3);
    expect(result.sections[1].interior).toHaveLength(3);
    expect(result.sections[0].interior[1][0]).toBeCloseTo(mDeg(100), 12);
    expect(result.sections[1].interior[1][0]).toBeCloseTo(mDeg(200), 12);
  });
});

describe("convertImportedShape by projection", () => {
  // Out-and-back loop with the return pass offset 33 m north, so each pass
  // has a distinct minimum: A,B,C outbound, then A',B' home.
  const A = [0, 0];
  const B = [mDeg(111), 0];
  const C = [mDeg(222), 0];
  const Aprime = [0, mDeg(33)];
  const Bprime = [mDeg(111), mDeg(33)];
  const shapePoints = [A, B, C, Aprime, Bprime];
  const visits = [A, B, C, A, B];

  it("projects loop return visits onto the return pass without flags", () => {
    const result = convertImportedShape({ visits, shapePoints });

    expect(result.method).toBe("projection");
    expect(result.sections).toHaveLength(4);
    expect(result.sections.map((s) => s.flagged)).toEqual([
      false,
      false,
      false,
      false,
    ]);
    // Visit 3 (C) splits at the outbound C vertex.
    const cSplit = result.sections[1].interior.at(-1);
    expect(cSplit[0]).toBeCloseTo(mDeg(222), 9);
    expect(cSplit[1]).toBeCloseTo(0, 9);
    // Visits 4 and 5 land on the return pass: their latitudes carry the
    // 33 m offset, ruling out the outbound copies at latitude 0. Section
    // 2 spans visits C -> A, so the A-return split closes it.
    const aReturn = result.sections[2].interior.at(-1);
    expect(aReturn[1]).toBeGreaterThan(mDeg(20));
    expect(aReturn[0]).toBeLessThan(mDeg(50));
    expect(
      L.CRS.Earth.distance(L.latLng(A[1], A[0]), L.latLng(aReturn[1], aReturn[0])),
    ).toBeLessThan(100);
    const bReturn = result.sections[3].interior.at(-1);
    expect(bReturn[0]).toBeCloseTo(mDeg(111), 9);
    expect(bReturn[1]).toBeCloseTo(mDeg(33), 9);
    // Consecutive sections share their boundary split values.
    for (let i = 0; i < 3; i++) {
      expect(result.sections[i + 1].interior[0]).toEqual(
        result.sections[i].interior.at(-1),
      );
    }
  });

  it("flags both adjacent sections of a stop beyond the threshold", () => {
    const line = [
      [0, 0],
      [mDeg(150), 0],
      [mDeg(300), 0],
    ];
    const offPath = [
      [0, 0],
      [mDeg(150), mDeg(150)],
      [mDeg(300), 0],
    ];

    const result = convertImportedShape({ visits: offPath, shapePoints: line });

    expect(result.method).toBe("projection");
    expect(result.sections).toHaveLength(2);
    expect(result.sections[0].flagged).toBe(true);
    expect(result.sections[1].flagged).toBe(true);
    expect(result.sections[0].interior).toEqual([]);
    expect(result.sections[1].interior).toEqual([]);

    // The same geometry converts cleanly once the threshold covers it.
    const wide = convertImportedShape({
      visits: offPath,
      shapePoints: line,
      thresholdM: 200,
    });
    expect(wide.sections.map((s) => s.flagged)).toEqual([false, false]);
    expect(wide.sections[0].interior.length).toBeGreaterThan(0);
    expect(wide.sections[1].interior.length).toBeGreaterThan(0);
  });

  it("falls back to projection when visit distances do not increase", () => {
    const shapePoints = [
      [0, 0, 0],
      [mDeg(150), 0, 150],
      [mDeg(300), 0, 300],
    ];
    const visits = [
      [0, 0],
      [mDeg(150), 0],
      [mDeg(300), 0],
    ];

    const result = convertImportedShape({
      visits,
      shapePoints,
      visitDistances: [0, 300, 150],
    });

    expect(result.method).toBe("projection");
    expect(result.sections).toHaveLength(2);
    expect(result.sections.map((s) => s.flagged)).toEqual([false, false]);
  });
});

describe("convertImportedShape axis order", () => {
  it("emits every output point as [lon, lat]", () => {
    const shapePoints = [
      [0.005, 0.001, 0],
      [0.006, 0.0012, 50],
    ];

    const result = convertImportedShape({
      visits: [
        [0.005, 0.001],
        [0.006, 0.0012],
      ],
      shapePoints,
      visitDistances: [0, 50],
    });

    expect(result.method).toBe("distance");
    expect(result.sections).toHaveLength(1);
    const interior = result.sections[0].interior;
    // The first element is the longitude of the input shape points.
    expect(interior[0]).toEqual([0.005, 0.001]);
    for (const point of interior) {
      expect(point).toHaveLength(2);
      expect(point[0]).toBeGreaterThan(point[1]);
    }
  });
});
