/**
 * alignment_geometry.js
 *
 * The only client axis conversions (INV-1) plus the Leaflet-backed geometry
 * helpers for pattern alignment editing. Wire/storage order is [lon, lat]
 * (GeoJSON); Leaflet order is [lat, lon]. Axis order changes only in
 * `toLatLng`/`fromLatLng` here and in `Alignments.Materializer.build/2`.
 *
 * Leaflet is read from `window.L` at call time (vendored Leaflet 1.9.4, no
 * npm geometry dependency — CR-6). Lengths come from `L.CRS.Earth.distance`;
 * simplification projects with `L.CRS.EPSG3857` and reduces with
 * `L.LineUtil.simplify`.
 */

// Leaflet is installed on `window` by the vendored UMD build. Read at call
// time so tests can install it under jsdom before importing this module.
function leaflet() {
  return window.L;
}

// toLatLng([lon, lat]) -> [lat, lon]: storage order to Leaflet order.
export function toLatLng([lon, lat]) {
  return [lat, lon];
}

// fromLatLng({lat, lng}) -> [lon, lat]: Leaflet order to storage order.
export function fromLatLng({ lat, lng }) {
  return [lng, lat];
}

// Simplify one [lon, lat] chain with a ground-metre tolerance expressed in
// Web Mercator projected units. EPSG3857 stretches ground metres by
// 1/cos(mean latitude), so the linear projected tolerance is
// toleranceM / cos(meanLat); Leaflet's simplify takes the *squared*
// tolerance. Returns the kept chain (endpoints always kept).
function simplifyChain(chain, toleranceM) {
  const L = leaflet();
  const projected = chain.map(([lon, lat]) =>
    L.CRS.EPSG3857.project(L.latLng(lat, lon)),
  );
  const meanLatRad =
    (chain.reduce((sum, [, lat]) => sum + lat, 0) / chain.length) *
    (Math.PI / 180);
  const linear = toleranceM / Math.cos(meanLatRad);
  const kept = L.LineUtil.simplify(projected, linear);
  const keptIndexes = new Set(kept.map((point) => projected.indexOf(point)));
  return chain.filter((_, index) => keptIndexes.has(index));
}

// simplifyInterior(anchorA, interior, anchorB, toleranceM, selected?)
//
// All points are [lon, lat]; anchors stay fixed and the result holds only
// interior points. Without `selected`, the whole anchor+interior+anchor
// chain is simplified. With `selected` (a Set of interior indexes), each
// contiguous selected run is simplified with its neighbours held fixed and
// every unselected interior point is returned unchanged.
export function simplifyInterior(
  anchorA,
  interior,
  anchorB,
  toleranceM,
  selected,
) {
  if (interior.length === 0) return [];
  if (!selected) {
    return simplifyChain([anchorA, ...interior, anchorB], toleranceM).slice(
      1,
      -1,
    );
  }

  const valid = new Set(
    [...selected].filter((i) => i >= 0 && i < interior.length),
  );
  const result = [...interior];
  let runStart = null;

  const flushRun = (start, end) => {
    const before = start === 0 ? anchorA : interior[start - 1];
    const after = end === interior.length - 1 ? anchorB : interior[end + 1];
    const simplified = simplifyChain(
      [before, ...interior.slice(start, end + 1), after],
      toleranceM,
    ).slice(1, -1);
    result.splice(start, end - start + 1, ...simplified);
  };

  for (let i = 0; i <= interior.length; i++) {
    if (i < interior.length && valid.has(i)) {
      if (runStart === null) runStart = i;
    } else if (runStart !== null) {
      flushRun(runStart, i - 1);
      runStart = null;
    }
  }

  return result;
}

// nearestEdgeIndex(map, latlng, latlngs) -> insertion index.
//
// `latlngs` are Leaflet-order [lat, lon] pairs as drawn; `latlng` is the
// click (Leaflet LatLng or [lat, lon] pair). Returns the index at which a
// point on the closest edge would be inserted (edge i spans latlngs[i] to
// latlngs[i + 1], so the insertion index is i + 1).
export function nearestEdgeIndex(map, latlng, latlngs) {
  const L = leaflet();
  if (latlngs.length < 2) return latlngs.length;
  const click = map.latLngToLayerPoint(L.latLng(latlng));
  const drawn = latlngs.map(([lat, lon]) =>
    map.latLngToLayerPoint(L.latLng(lat, lon)),
  );

  let bestIndex = 1;
  let bestDistance = Infinity;
  for (let i = 0; i < drawn.length - 1; i++) {
    const distance = L.LineUtil.pointToSegmentDistance(
      click,
      drawn[i],
      drawn[i + 1],
    );
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i + 1;
    }
  }
  return bestIndex;
}

// pointsInBounds(interior, bounds) -> Set of interior indexes inside the
// given L.latLngBounds. `interior` points are [lon, lat].
export function pointsInBounds(interior, bounds) {
  const L = leaflet();
  const inside = new Set();
  interior.forEach(([lon, lat], index) => {
    if (bounds.contains(L.latLng(lat, lon))) inside.add(index);
  });
  return inside;
}

// lengthMeters(latlngs) -> haversine metres along Leaflet-order [lat, lon]
// pairs as drawn. Empty and single-point lines are 0.
export function lengthMeters(latlngs) {
  const L = leaflet();
  let total = 0;
  for (let i = 0; i < latlngs.length - 1; i++) {
    total += L.CRS.Earth.distance(
      L.latLng(latlngs[i][0], latlngs[i][1]),
      L.latLng(latlngs[i + 1][0], latlngs[i + 1][1]),
    );
  }
  return total;
}
