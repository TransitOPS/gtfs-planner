/**
 * The geometry the StopMap hook draws with.
 *
 * Everything here is pure: it takes numbers in and returns numbers out, with no
 * Leaflet, no DOM and no hook state. That is deliberate, because these are the
 * two rules a reader would otherwise have to take on trust — a route line drawn
 * a few pixels to the right of the direction of travel, and a stop's arrow
 * pointing the way its buses go — and a rule worth arguing about should be
 * testable without a browser in the room.
 *
 * Coordinates are screen coordinates: `[x, y]` with y increasing downward, the
 * way Leaflet's `latLngToContainerPoint/1` and `containerPointToLatLng/1` report
 * them. Mixing in with geographic points is the one thing that silently mirrors
 * the whole map, so nothing in this module takes a latitude.
 */

/**
 * Moves a polyline `offset` pixels to the right of the direction of travel.
 *
 * "Right of travel" is what makes two buses that share a street legible: the
 * northbound and southbound halves of a route separate into two parallel lines
 * a few pixels apart, and each line carries its own route colour and its own
 * head. Offsetting to a fixed side of the map instead would flip which side a
 * line lands on as the route turned a corner.
 *
 * Each vertex's direction comes from its neighbours — the previous and the next
 * point, clamped at the ends — so a vertex inside a curve is offset along the
 * average of the two segments it joins rather than along either of them.
 *
 * `project` turns a point into screen coordinates and is called once per point;
 * pass `identity` when the points already are screen coordinates. A polyline
 * with fewer than two points, or a zero-length offset, returns the projected
 * points unchanged: there is no direction to offset from, and inventing one
 * would move points for no reason a reader could see.
 */
export function offsetPolyline(points, offset, project = identity) {
  if (!Array.isArray(points) || points.length === 0) return [];
  const projected = points.map(project);
  if (projected.length < 2 || !offset) return projected;

  return projected.map((point, index) => {
    const previous = projected[Math.max(0, index - 1)];
    const next = projected[Math.min(projected.length - 1, index + 1)];

    let dx = next[0] - previous[0];
    let dy = next[1] - previous[1];
    const length = Math.hypot(dx, dy) || 1;
    dx /= length;
    dy /= length;

    // Right of travel in screen coordinates: rotating the direction vector a
    // quarter turn clockwise. On a y-down axis that is (-dy, dx) — for a bus
    // heading north (dx 0, dy -1) it is (1, 0), four pixels east, which is the
    // right-hand side of the road it is driving on.
    return [point[0] - dy * offset, point[1] + dx * offset];
  });
}

/**
 * The compass heading a screen segment points along, in degrees clockwise from
 * north (the unit a GTFS `stop_bearing` is written in, and the unit an arrow
 * points in).
 *
 * A segment from `[0, 0]` to `[1, 0]` runs east and reports 90; from `[0, 0]`
 * to `[0, -1]` runs north (screen up is north) and reports 0. A zero-length
 * segment has no heading, so it reports `null` and the caller draws no tick
 * rather than an arrow pointing at an arbitrary north.
 */
export function bearingDeg(from, to) {
  const dx = to[0] - from[0];
  const dy = to[1] - from[1];
  if (dx === 0 && dy === 0) return null;

  return (Math.atan2(dx, -dy) * 180) / Math.PI;
}

/**
 * The screen-space vector a stop's direction arrow points along: a unit vector
 * for a bearing in degrees, `[0, 0]` when there is no bearing to draw.
 *
 * Kept separate from `bearingDeg/2` because the two are asked different
 * questions. `bearingDeg` is "which way does this road go", which is a number
 * worth asserting. This is "which way should the arrow tip sit", which is a
 * position, and is what the marker layer needs at draw time.
 */
export function bearingVector(bearing) {
  if (bearing === null || bearing === undefined || !Number.isFinite(bearing)) {
    return [0, 0];
  }

  const radians = (bearing * Math.PI) / 180;
  return [Math.sin(radians), -Math.cos(radians)];
}

function identity(point) {
  return point;
}
