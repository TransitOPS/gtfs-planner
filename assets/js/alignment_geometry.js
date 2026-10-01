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
// toleranceM / cos(meanLat); Leaflet's simplify takes the linear tolerance
// (verified against the vendored 1.9.4 build in step 21). Returns the kept
// chain (endpoints always kept).
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
  const runs = [];
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
      runs.push([runStart, i - 1]);
      runStart = null;
    }
  }

  // Splicing a run shifts every later index, so apply runs right to
  // left: earlier runs then still address their original positions.
  for (let r = runs.length - 1; r >= 0; r--) {
    flushRun(runs[r][0], runs[r][1]);
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

function isFiniteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function strictlyIncreasing(values) {
  for (let i = 1; i < values.length; i++) {
    if (!(values[i] > values[i - 1])) return false;
  }
  return true;
}

// A split is a position on the shape polyline: {seg, frac, point}, ordered
// lexicographically by (seg, frac). frac === 1 normalizes to the next
// segment start so an exact vertex hit never duplicates its shape point in
// the "strictly between" interior below. point is a fresh [lon, lat].
function normalizeSplit(seg, frac, point) {
  if (frac >= 1) return { seg: seg + 1, frac: 0, point };
  if (frac <= 0) return { seg, frac: 0, point };
  return { seg, frac, point };
}

function splitBefore(a, b) {
  return a.seg < b.seg || (a.seg === b.seg && a.frac < b.frac);
}

// Section interior between two splits: the first split point, the shape
// points strictly between the split positions, then the second split
// point. Consecutive sections share their boundary split values.
function sectionInterior(lonLat, splitA, splitB) {
  const interior = [splitA.point];
  for (let j = 0; j < lonLat.length; j++) {
    const here = { seg: j, frac: 0 };
    if (splitBefore(splitA, here) && splitBefore(here, splitB)) {
      interior.push([lonLat[j][0], lonLat[j][1]]);
    }
  }
  interior.push(splitB.point);
  return interior;
}

function lerpLonLat(lonLat, seg, frac) {
  const [lon0, lat0] = lonLat[seg];
  const [lon1, lat1] = lonLat[seg + 1];
  return [lon0 + frac * (lon1 - lon0), lat0 + frac * (lat1 - lat0)];
}

function distancePreconditions(lonLat, shapeDists, visits, visitDistances) {
  return (
    Array.isArray(visitDistances) &&
    visitDistances.length === visits.length &&
    visitDistances.every(isFiniteNumber) &&
    strictlyIncreasing(visitDistances) &&
    lonLat.length >= 1 &&
    shapeDists.length === lonLat.length &&
    shapeDists.every(isFiniteNumber) &&
    visitDistances[0] >= shapeDists[0] &&
    visitDistances[visitDistances.length - 1] <= shapeDists[shapeDists.length - 1]
  );
}

// Split positions by interpolating each visit distance along the shape.
// Returns null when a visit distance cannot be bracketed (non-monotonic
// imported distances), so the caller falls back to projection.
function distanceSplits(lonLat, shapeDists, visitDistances) {
  const splits = [];
  for (const d of visitDistances) {
    let found = null;
    for (let i = 0; i < shapeDists.length - 1; i++) {
      const d0 = shapeDists[i];
      const d1 = shapeDists[i + 1];
      // A flat or reversed imported segment carries no distance: skip it.
      if (!(d1 > d0)) continue;
      if (d >= d0 && d <= d1) {
        const t = (d - d0) / (d1 - d0);
        found = normalizeSplit(i, t, lerpLonLat(lonLat, i, t));
        break;
      }
    }
    if (!found) return null;
    splits.push(found);
  }
  return splits;
}

function projectToSegment(p, a, b) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const len2 = dx * dx + dy * dy;
  if (len2 === 0) {
    return { frac: 0, planarDist: Math.hypot(p.x - a.x, p.y - a.y) };
  }
  const t = Math.min(1, Math.max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
  const qx = a.x + t * dx;
  const qy = a.y + t * dy;
  return { frac: t, planarDist: Math.hypot(p.x - qx, p.y - qy) };
}

// Project every visit onto the shape with a monotonic cursor: each visit
// scans forward from the previous split and takes the local minimum of the
// first contiguous under-threshold run (first occurrence wins ties). A
// visit with nothing under the threshold takes the nearest admissible point
// and fails, flagging both adjacent sections. Returns {splits, failed}.
function projectionSplits(L, lonLat, projected, visits, thresholdM) {
  const splits = [];
  const failed = new Array(visits.length).fill(false);
  let cursor = { seg: 0, frac: 0 };

  visits.forEach(([lon, lat], vi) => {
    const v = L.CRS.EPSG3857.project(L.latLng(lat, lon));
    // EPSG3857 stretches ground metres by 1/cos φ; the visit latitude
    // restores ground metres for the threshold comparison.
    const cosPhi = Math.cos((lat * Math.PI) / 180);
    let runBest = null;
    let runActive = false;
    let nearest = null;

    for (let j = cursor.seg; j < projected.length - 1; j++) {
      const lo = j === cursor.seg ? cursor.frac : 0;
      const r = projectToSegment(v, projected[j], projected[j + 1]);
      // The cursor segment is only admissible ahead of the cursor.
      const frac = j === cursor.seg ? Math.min(1, Math.max(lo, r.frac)) : r.frac;
      const qx = projected[j].x + frac * (projected[j + 1].x - projected[j].x);
      const qy = projected[j].y + frac * (projected[j + 1].y - projected[j].y);
      const ground = Math.hypot(v.x - qx, v.y - qy) * cosPhi;
      const candidate = { seg: j, frac, ground };
      if (!nearest || ground < nearest.ground) nearest = candidate;
      if (ground <= thresholdM) {
        if (!runActive) {
          runActive = true;
          runBest = null;
        }
        if (!runBest || ground < runBest.ground) runBest = candidate;
      } else if (runActive) {
        break;
      }
    }

    if (runBest) {
      const split = normalizeSplit(runBest.seg, runBest.frac, lerpLonLat(lonLat, runBest.seg, runBest.frac));
      splits.push(split);
      cursor = { seg: split.seg, frac: split.frac };
    } else {
      failed[vi] = true;
      // Beyond the shape end there is no admissible segment: hold the cursor.
      // The cursor is never clamped back into the shape, so later visits
      // cannot project behind it.
      const hold = nearest || cursor;
      const atEnd = hold.seg >= lonLat.length - 1;
      const seg = atEnd ? lonLat.length - 1 : hold.seg;
      const frac = atEnd ? 0 : hold.frac;
      const point = atEnd ? [...lonLat[lonLat.length - 1]] : lerpLonLat(lonLat, seg, frac);
      const split = { seg, frac, point };
      splits.push(split);
      cursor = { seg, frac };
    }
  });

  return { splits, failed };
}

// convertImportedShape({visits, shapePoints, visitDistances, thresholdM = 100})
// -> {method: "distance" | "projection", sections: [{interior, flagged}]}.
//
// Splits one imported whole shape (the dialog's chosen shape when trips
// diverge) into one draft per consecutive visit pair. visits and
// shapePoints are [lon, lat]; a shape point may carry its imported distance
// as [lon, lat, dist] (null when the import had none). Distances are opaque
// numbers in the shape's original units — imported shapes keep those units
// while pattern-owned shapes are metres — so interpolation orders points
// along the shape but never converts units. Pure: drafts only, never
// writes (CR-9). Only toLatLng/fromLatLng change axis order (INV-1).
//
// Distance method: every visit/shape distance present, visit distances
// strictly increasing within the first/last shape distances; each
// section's interior is split i, the shape points strictly between, then
// split i+1. Projection method (otherwise): monotonic cursor, first
// under-threshold run refined to its local minimum, flags on failure; a
// flagged section's interior is [] (a straight draft).
export function convertImportedShape({ visits, shapePoints, visitDistances, thresholdM = 100 }) {
  const lonLat = shapePoints.map(([lon, lat]) => [lon, lat]);
  const shapeDists = shapePoints.map((point) => point[2]);

  if (distancePreconditions(lonLat, shapeDists, visits, visitDistances)) {
    const splits = distanceSplits(lonLat, shapeDists, visitDistances);
    if (splits) {
      return {
        method: "distance",
        sections: splits.slice(1).map((split, i) => ({
          interior: sectionInterior(lonLat, splits[i], split),
          flagged: false,
        })),
      };
    }
  }

  const L = leaflet();
  if (lonLat.length < 2) {
    return {
      method: "projection",
      sections: visits.slice(1).map(() => ({ interior: [], flagged: true })),
    };
  }
  const projected = lonLat.map(([lon, lat]) => L.CRS.EPSG3857.project(L.latLng(lat, lon)));
  const { splits, failed } = projectionSplits(L, lonLat, projected, visits, thresholdM);
  return {
    method: "projection",
    sections: splits.slice(1).map((split, i) => ({
      interior: failed[i] || failed[i + 1] ? [] : sectionInterior(lonLat, splits[i], split),
      flagged: failed[i] || failed[i + 1],
    })),
  };
}

// Cumulative projected length up to each vertex of a projected chain, plus
// the chain total, so a projection's distance along the line can be
// compared.
function alongDistances(projected) {
  const cum = [0];
  for (let i = 0; i < projected.length - 1; i++) {
    const dx = projected[i + 1].x - projected[i].x;
    const dy = projected[i + 1].y - projected[i].y;
    cum.push(cum[i] + Math.hypot(dx, dy));
  }
  return cum;
}

// projectVisitOntoLine(L, lonLat, projected, cum, lon, lat)
// -> {alongM, distanceM}: where one visit lands on the line and how far it
// is from it, or null for a chain of one projected point.
//
// Unlike `projectionSplits`, this searches the whole line with no monotonic
// cursor: the fit review must measure a line that runs the other way before
// it is reversed, and a cursor would pin every visit to the start of the
// line. The projection, the ground-metre correction and `projectToSegment`
// are the conversion's own, so the fit and the conversion agree on which
// visits are inside the threshold (INV-5).
function projectVisitOntoLine(L, projected, cum, lon, lat) {
  const v = L.CRS.EPSG3857.project(L.latLng(lat, lon));
  // EPSG3857 stretches ground metres by 1/cos φ; the visit latitude
  // restores ground metres for the threshold comparison.
  const cosPhi = Math.cos((lat * Math.PI) / 180);
  let best = null;
  for (let j = 0; j < projected.length - 1; j++) {
    const r = projectToSegment(v, projected[j], projected[j + 1]);
    if (best && r.planarDist >= best.planarDist) continue;
    best = { seg: j, frac: r.frac, planarDist: r.planarDist };
  }
  if (!best) return null;
  return {
    alongM: cum[best.seg] + best.frac * (cum[best.seg + 1] - cum[best.seg]),
    distanceM: best.planarDist * cosPhi,
  };
}

// fitSummary({visits, points, thresholdM = 100})
// -> {direction, reachesStart, reachesEnd, far, within, visitCount, lengthM}.
//
// The fit review's measurements, from the same projection and the same
// threshold `convertImportedShape` uses (INV-5): each visit is projected
// onto the line by `projectVisitOntoLine`, which reuses `projectToSegment`
// and the conversion's ground-metre correction, so a review reporting no
// far stop is the input whose conversion flags no section. visits are the
// hook's visit maps (`{position, stop_id, lon, lat}`); points are [lon, lat]
// or [lon, lat, dist].
//
// direction is "reversed" when the last visit projects before the first
// along the line, and "unknown" when the line or the visit run cannot say:
// fewer than two points, fewer than two visits, or both ends projecting to
// the same place along the line. reachesStart/reachesEnd hold when the
// first/last visit is within the threshold of that end of the line, so a
// line stopping short of a visit reports the miss. far lists the visits
// beyond the threshold, in visit order, with their ground-metre distance;
// within counts the rest. Pure: it reports, it never drafts (CR-9).
export function fitSummary({ visits, points, thresholdM = 100 }) {
  const lonLat = points.map(([lon, lat]) => [lon, lat]);
  const visitCount = visits.length;
  if (visitCount === 0 || lonLat.length < 2) {
    return {
      direction: "unknown",
      reachesStart: false,
      reachesEnd: false,
      far: [],
      within: 0,
      visitCount,
      lengthM: lengthMeters(lonLat.map(toLatLng)),
    };
  }

  const L = leaflet();
  const projected = lonLat.map(([lon, lat]) => L.CRS.EPSG3857.project(L.latLng(lat, lon)));
  const cum = alongDistances(projected);
  // A stop without coordinates cannot be placed, so it reads as unplaced (far
  // with no distance) rather than throwing in the projection.
  const placeable = (visit) => typeof visit.lon === "number" && typeof visit.lat === "number";
  const placed = visits.map((visit) =>
    placeable(visit) ? projectVisitOntoLine(L, projected, cum, visit.lon, visit.lat) : null,
  );
  const alongs = placed.map((placement) => (placement ? placement.alongM : null));

  let direction = "unknown";
  if (visitCount > 1 && alongs[0] !== null && alongs[visitCount - 1] !== null && alongs[0] !== alongs[visitCount - 1]) {
    direction = alongs[visitCount - 1] < alongs[0] ? "reversed" : "same";
  }

  // Reaching an end is about the visit and that end of the line, not about
  // the line's own length, so an end point beyond the visit's position is
  // still reached.
  const ground = (a, b) => L.CRS.Earth.distance(L.latLng(a[1], a[0]), L.latLng(b[1], b[0]));
  const reaches = (visit, end) => placeable(visit) && ground([visit.lon, visit.lat], end) <= thresholdM;
  const far = [];
  let within = 0;
  visits.forEach((visit, i) => {
    const distanceM = placed[i] ? placed[i].distanceM : null;
    if (distanceM !== null && distanceM <= thresholdM) {
      within += 1;
      return;
    }
    far.push({ position: visit.position, stopId: visit.stop_id, distanceM });
  });

  return {
    direction,
    reachesStart: reaches(visits[0], lonLat[0]),
    reachesEnd: reaches(visits[visitCount - 1], lonLat[lonLat.length - 1]),
    far,
    within,
    visitCount,
    lengthM: lengthMeters(lonLat.map(toLatLng)),
  };
}

// reverseLine(points) -> a new array in the opposite order. The points
// themselves are shared, never mutated: the review previews the reversal,
// and the conversion later drafts the reversed chain.
export function reverseLine(points) {
  return points.slice().reverse();
}

// joinPieces(pieces, toleranceM = 50) -> one [lon, lat] chain, or null when
// the ends do not meet. Google My Maps splits a path into one line per ten
// stops, so consecutive pieces repeat the shared vertex; each joint is
// measured with the same ground-metre distance `lengthMeters` uses and the
// repeated vertex of the following piece is dropped. A joint beyond the
// tolerance returns null rather than a chain with a jump in it. Points pass
// through as they arrive, an imported distance included.
export function joinPieces(pieces, toleranceM = 50) {
  if (!Array.isArray(pieces)) return null;
  if (pieces.length === 0) return [];
  if (pieces.some((piece) => !Array.isArray(piece) || piece.length === 0)) return null;

  const L = leaflet();
  const ground = (a, b) => L.CRS.Earth.distance(L.latLng(a[1], a[0]), L.latLng(b[1], b[0]));
  const reaches = (visit, end) => placeable(visit) && ground([visit.lon, visit.lat], end) <= thresholdM;
  const joined = pieces[0].slice();
  for (let i = 1; i < pieces.length; i++) {
    if (ground(joined[joined.length - 1], pieces[i][0]) > toleranceM) return null;
    joined.push(...pieces[i].slice(1));
  }
  return joined;
}
