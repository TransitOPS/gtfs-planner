/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { describe, expect, it } from "vitest";
import {
  convertImportedShape,
  fitSummary,
  joinPieces,
  reverseLine,
} from "../alignment_geometry";

// Leaflet's spherical radius (metres), so degree offsets below are exact
// under L.CRS.Earth.distance. Used only to construct fixtures; every
// expectation is a hardcoded literal.
//
// One caveat: distanceM comes from the EPSG3857 projection, whose radius is
// Leaflet's 6378137 m, not Earth's 6371008 m used here. A projected distance
// between two fixture points is therefore about 0.11% larger than its
// nominal value, which is why distanceM expectations below are windows
// rather than exact literals — the same tolerance the prepared case for the
// 271 m offset uses.
const R = 6371008;
const DEG = 180 / Math.PI;
const mDeg = (m) => (m / R) * DEG;

// A straight line east along the equator, one vertex every 100 m. The
// equator keeps Web Mercator's 1/cos φ stretch at 1, so projected and
// ground metres agree and the literals below hold exactly.
const alongLine = (metres) =>
  Array.from({ length: metres / 100 + 1 }, (_, i) => [mDeg(i * 100), 0]);

const visit = (position, metres, offsetM = 0) => ({
  position,
  stop_id: `S${position}`,
  lon: mDeg(metres),
  lat: mDeg(offsetM),
});

describe("fitSummary on a line following the visits", () => {
  const points = alongLine(400);
  const visits = [0, 1, 2, 3, 4].map((i) => visit(i, i * 100));

  it("reports the same direction, both ends reached and no far stop", () => {
    const fit = fitSummary({ visits, points });

    expect(fit.direction).toBe("same");
    expect(fit.reachesStart).toBe(true);
    expect(fit.reachesEnd).toBe(true);
    expect(fit.far).toEqual([]);
    expect(fit.within).toBe(5);
    expect(fit.visitCount).toBe(5);
    // 400 m of straight line at the equator.
    expect(fit.lengthM).toBeCloseTo(400, 2);
  });

  it("reports reversed for the same line drawn backwards, and same again after reverseLine", () => {
    const reversedFit = fitSummary({ visits, points: reverseLine(points) });

    expect(reversedFit.direction).toBe("reversed");
    // Reversing the reported line puts it back in the pattern's order.
    const restored = fitSummary({
      visits,
      points: reverseLine(reverseLine(points)),
    });
    expect(restored.direction).toBe("same");
    expect(restored.far).toEqual([]);
    expect(restored.reachesStart).toBe(true);
    expect(restored.reachesEnd).toBe(true);
  });

  it("returns a new array and leaves the original in order", () => {
    const reversed = reverseLine(points);

    expect(reversed).not.toBe(points);
    expect(points[0]).toEqual([0, 0]);
    expect(reversed[0]).toEqual(points[points.length - 1]);
    expect(reversed).toHaveLength(points.length);
  });

  it("returns unknown with no visits and with a one-point line", () => {
    expect(fitSummary({ visits: [], points }).direction).toBe("unknown");
    const point = fitSummary({ visits, points: [[0, 0]] });
    expect(point.direction).toBe("unknown");
    expect(point.far).toEqual([]);
    expect(point.lengthM).toBe(0);
  });

  it("converts every section when it reports no far stop", () => {
    const fit = fitSummary({ visits, points });
    const result = convertImportedShape({
      visits: visits.map((v) => [v.lon, v.lat]),
      shapePoints: points,
      visitDistances: null,
    });

    expect(fit.far).toEqual([]);
    expect(result.method).toBe("projection");
    expect(result.sections).toHaveLength(4);
    result.sections.forEach((section) => {
      expect(section.flagged).toBe(false);
      expect(section.interior.length).toBeGreaterThan(0);
    });
    // Consecutive sections share their boundary split point.
    expect(result.sections[0].interior.at(-1)).toEqual(
      result.sections[1].interior[0],
    );
  });
});

describe("fitSummary ends and far stops", () => {
  it("reports reachesEnd false for a line ending 400 m before the last visit", () => {
    const points = alongLine(600);
    // The first four visits sit on the 600 m line; the last is 400 m past
    // its end.
    const visits = [0, 150, 300, 450, 1000].map((m, i) => visit(i, m));

    const fit = fitSummary({ visits, points });

    expect(fit.reachesStart).toBe(true);
    expect(fit.reachesEnd).toBe(false);
    // The visit past the end of the line is also the one stop beyond the
    // threshold, at its true distance from the line's end.
    expect(fit.far).toHaveLength(1);
    expect(fit.far[0].position).toBe(4);
    expect(fit.far[0].stopId).toBe("S4");
    expect(fit.far[0].distanceM).toBeGreaterThan(395);
    expect(fit.far[0].distanceM).toBeLessThan(405);
    expect(fit.within).toBe(4);
  });

  it("reports a visit 271 m off the line in far with its distance", () => {
    const points = alongLine(400);
    const visits = [
      visit(0, 0),
      visit(1, 100),
      visit(2, 200, 271),
      visit(3, 300),
      visit(4, 400),
    ];

    const fit = fitSummary({ visits, points });

    expect(fit.direction).toBe("same");
    expect(fit.reachesStart).toBe(true);
    expect(fit.reachesEnd).toBe(true);
    expect(fit.far).toHaveLength(1);
    expect(fit.far[0].position).toBe(2);
    expect(fit.far[0].stopId).toBe("S2");
    expect(fit.far[0].distanceM).toBeGreaterThan(266);
    expect(fit.far[0].distanceM).toBeLessThan(276);
    expect(fit.within).toBe(4);
  });

  it("lists every far stop in visit order", () => {
    const points = alongLine(400);
    const visits = [
      visit(0, 0, 150),
      visit(1, 100),
      visit(2, 200, 400),
      visit(3, 300),
      visit(4, 400),
    ];

    const fit = fitSummary({ visits, points });

    expect(fit.far.map((entry) => entry.position)).toEqual([0, 2]);
    expect(fit.within).toBe(3);
  });
});

describe("joinPieces", () => {
  // A piece of the same 100 m-spaced line, moved along the equator and
  // starting one vertex in: My Maps repeats the shared vertex between the
  // pieces it splits a path into.
  const pieceAfter = (endM, gapM) =>
    alongLine(200)
      .slice(1)
      .map(([lon]) => [lon + mDeg(100 + gapM), 0]);

  it("joins two pieces whose ends are 20 m apart into one line", () => {
    const first = alongLine(200);
    const second = pieceAfter(200, 20);

    const joined = joinPieces([first, second]);

    expect(joined).not.toBeNull();
    // The repeated vertex of the second piece is dropped.
    expect(joined).toHaveLength(first.length + second.length - 1);
    expect(joined[0]).toEqual([0, 0]);
    expect(joined.at(-1)).toEqual([mDeg(320), 0]);
  });

  it("returns null for pieces 2 km apart", () => {
    expect(joinPieces([alongLine(200), pieceAfter(200, 2000)])).toBeNull();
  });

  it("honours an explicit tolerance and rejects an empty piece", () => {
    const first = alongLine(200);
    const second = pieceAfter(200, 60);

    expect(joinPieces([first, second])).toBeNull();
    expect(joinPieces([first, second], 100)).not.toBeNull();
    expect(joinPieces([first, []])).toBeNull();
    expect(joinPieces([])).toEqual([]);
  });

  it("returns a single piece unchanged in order", () => {
    const only = alongLine(200);

    expect(joinPieces([only])).toEqual(only);
  });
});

describe("fitSummary with a stop that has no coordinates", () => {
  it("reports the stop as far with no distance instead of throwing", () => {
    const points = alongLine(400);
    const visits = [
      visit(0, 0),
      { position: 1, stop_id: "S1", lon: null, lat: null },
      visit(2, 400),
    ];

    const fit = fitSummary({ visits, points });

    expect(fit.far).toEqual([{ position: 1, stopId: "S1", distanceM: null }]);
    expect(fit.within).toBe(2);
    expect(fit.direction).toBe("same");
    expect(fit.reachesStart).toBe(true);
    expect(fit.reachesEnd).toBe(true);
  });
});
