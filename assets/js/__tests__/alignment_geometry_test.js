/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { describe, expect, it } from "vitest";
import {
  fromLatLng,
  lengthMeters,
  nearestEdgeIndex,
  pointsInBounds,
  simplifyInterior,
  toLatLng,
} from "../alignment_geometry";

const L = window.L;
// Leaflet's spherical radius (metres), so degree offsets below are exact
// under L.CRS.Earth.distance. Used only to construct fixtures; every
// keep/remove expectation is a hardcoded literal.
const R = 6371008;
const DEG = 180 / Math.PI;
const dLat = (m) => (m / R) * DEG;
const dLon = (m, lat) => (m / (R * Math.cos((lat * Math.PI) / 180))) * DEG;

describe("axis conversions", () => {
  it("converts [lon, lat] to [lat, lon] and back with the axis preserved", () => {
    expect(toLatLng([-74.006, 40.7128])).toEqual([40.7128, -74.006]);
    expect(fromLatLng({ lat: 40.7128, lng: -74.006 })).toEqual([
      -74.006, 40.7128,
    ]);
  });

  it("round-trips through a real Leaflet LatLng", () => {
    const stored = [-74.006, 40.7128];
    const roundTripped = fromLatLng(L.latLng(...toLatLng(stored)));
    expect(roundTripped).toEqual(stored);
  });
});

describe("simplifyInterior", () => {
  it("keeps both anchors untouched and returns only interior points", () => {
    const anchorA = [-74.0, 40.0];
    const anchorB = [-74.0 + dLon(200, 40), 40.0];
    const interior = [
      [-74.0 + dLon(80, 40), 40.0],
      [-74.0 + dLon(160, 40), 40.0],
    ];

    const result = simplifyInterior(anchorA, interior, anchorB, 5);

    expect(result).toEqual([]);
    expect(result).not.toContain(anchorA);
    expect(result).not.toContain(anchorB);
  });

  it("at lat 40 keeps a 20 m bump at tolerance 10 and removes it at 25", () => {
    const lon0 = -74.0;
    const anchorA = [lon0, 40.0];
    const anchorB = [lon0 + dLon(200, 40), 40.0];
    const bump = [lon0 + dLon(100, 40), 40.0 + dLat(20)];

    expect(L.CRS.Earth.distance(L.latLng(40, lon0), L.latLng(40, anchorB[0]))).toBeCloseTo(200, 0);

    expect(simplifyInterior(anchorA, [bump], anchorB, 10)).toEqual([bump]);
    expect(simplifyInterior(anchorA, [bump], anchorB, 25)).toEqual([]);
  });

  it("at lat 60 removes an 8 m bump at tolerance 10 (needs the cos phi correction)", () => {
    const lon0 = 10.0;
    const anchorA = [lon0, 60.0];
    const anchorB = [lon0 + dLon(200, 60), 60.0];
    const bump = [lon0 + dLon(100, 60), 60.0 + dLat(8)];

    // Without the 1/cos(phi) scaling the projected bump (16 units) would
    // survive a tolerance of 10; with it the tolerance doubles and the
    // bump is removed.
    expect(simplifyInterior(anchorA, [bump], anchorB, 10)).toEqual([]);
  });

  it("with selected {2,3} simplifies only that run and leaves the rest", () => {
    const lon0 = -74.0;
    const lat = 40.0;
    const at = (east, north = 0) => [lon0 + dLon(east, lat), lat + dLat(north)];
    const anchorA = at(0);
    const anchorB = at(480);
    const interior = [at(80), at(160, 20), at(240, 20), at(320), at(400)];

    const result = simplifyInterior(
      anchorA,
      interior,
      anchorB,
      25,
      new Set([2, 3]),
    );

    // The unselected 20 m bump at index 1 survives; the selected run 2..3
    // collapses to nothing between its fixed neighbours.
    expect(result).toEqual([interior[0], interior[1], interior[4]]);
  });
});

describe("nearestEdgeIndex", () => {
  it("returns the insertion index of the closest edge", () => {
    const stubMap = {
      latLngToLayerPoint: (latlng) => L.CRS.EPSG3857.project(latlng),
    };
    const latlngs = [
      [40.0, -74.0],
      [40.0, -74.0 + dLon(100, 40)],
      [40.0, -74.0 + dLon(200, 40)],
      [40.0, -74.0 + dLon(300, 40)],
      [40.0, -74.0 + dLon(400, 40)],
    ];
    const click = L.latLng(40.0 + dLat(15), -74.0 + dLon(250, 40));

    expect(nearestEdgeIndex(stubMap, click, latlngs)).toBe(3);
  });
});

describe("pointsInBounds", () => {
  it("returns the Set of interior indexes inside the bounds", () => {
    const interior = [
      [-74.0, 40.0],
      [-73.99, 40.0],
      [-73.98, 40.0],
      [-73.97, 40.0],
    ];
    const bounds = L.latLngBounds(
      L.latLng(39.99, -73.995),
      L.latLng(40.01, -73.975),
    );

    expect(pointsInBounds(interior, bounds)).toEqual(new Set([1, 2]));
  });
});

describe("lengthMeters", () => {
  it("sums haversine legs and is zero without a segment", () => {
    const a = [40.0, -74.0];
    const b = [40.0, -74.0 + dLon(100, 40)];
    const c = [40.0, -74.0 + dLon(200, 40)];

    expect(lengthMeters([a, b, c])).toBeCloseTo(200, 0);
    expect(lengthMeters([a])).toBe(0);
    expect(lengthMeters([])).toBe(0);
  });
});
