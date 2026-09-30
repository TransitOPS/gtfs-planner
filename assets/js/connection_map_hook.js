/**
 * ConnectionMapHook
 *
 * Draws where a connection hands over. In `pair` mode it is the connection
 * drawer's "Where the vehicle waits" mini-map: the stop the vehicle arrives at,
 * the stop it departs from, and the dashed connector between them with the
 * distance. It is a picture of one fact the drawer already states in words, so it
 * is not an action surface: no dragging, no zooming, no picking, and no event
 * ever leaves the browser (CR-6 — the list and the drawer keep working with the
 * map gone).
 *
 * The stops are dots in their own route's colour, cased in white so they read
 * against the street tiles, each with a permanent tooltip that names the side
 * and the stop. One stop that both trips use gets a single "Arrives and
 * departs" marker and no connector, because there is nothing to connect.
 *
 * The container is `phx-update="ignore"`, so the server never patches inside it
 * and this hook owns its contents for the life of the mount. The `data-pair`
 * attribute is the only input, and a re-render that changes the pair arrives as
 * `updated()` rather than as a remount, so a gap drawer reopened on another trip
 * redraws in place.
 *
 * Required data-* attrs on the hook root element:
 *   data-mode      "pair" for the drawer mini-map. The hook refuses any other
 *                  value rather than drawing the wrong map: the Connections
 *                  view's `network` map is step 22's contract and nothing else
 *                  should land here before it exists.
 *   data-pair      JSON `{arrival: {name, lat, lon, color}, departure: {...},
 *                  meters}` — the gap's own two stop references.
 *
 * This is an external-runtime boundary: `window.L` and the tile source. Missing
 * Leaflet and a failed tile both degrade to `data-state="unavailable"` plus the
 * drawer's own text, never an exception and never a map that swallows the
 * drawer. That is FH-16.
 */

import { addStreetBasemap, STREET_MAX_ZOOM } from "./basemap_layers";
import { DIAGRAM_BASE_COLOR, paletteColor } from "./stop_icon_symbols";

// The drawer's map is 176 px tall (the prototype's frame) and its width is the
// drawer's content column, so a fit that leaves less than this on the short axis
// would push one marker under the drawer's padding.
const FIT_PADDING = [32, 32];
const FIT_MAX_ZOOM = 18;

// A lone stop has no box to fit, so it gets a fixed close zoom instead of the
// world view an empty bounds would produce.
const SINGLE_POINT_ZOOM = 17;

// Cased drawing, the same constants the Transfers page's connector uses, so a
// rule read on one surface is drawn the same on the other. The street basemap
// draws dashed lines of its own, so an uncased dash reads as basemap detail
// rather than as the handoff.
const LINE_WEIGHT = 3;
const CASING_WEIGHT = 7;
const CASING_COLOR = "#ffffff";
const CASING_OPACITY = 0.85;
const DASH_ARRAY = "6 6";

// The dot is a route's own colour inside a white case, so the stop reads on
// pavement, on grass and over a route line alike.
const DOT_RADIUS = 8;
const DOT_CASE_WEIGHT = 3;

// Leaflet stacks markers by latitude, so two stops metres apart would cover each
// other at any useful zoom. The two endpoints are lifted clear of each other.
const ENDPOINT_Z_OFFSET = 500;

// A permanent tooltip's own class, so the words match the drawer's type rather
// than Leaflet's defaults. The container is `phx-update="ignore"`, so this
// cannot come from a server-rendered attribute.
const TOOLTIP_CLASS = "connection-map-tooltip";

// The fallback when a route carries no usable colour, so an uncoloured feed
// still draws a legible dot.
const COLOR_FALLBACK = DIAGRAM_BASE_COLOR;

function coordinate(value) {
  if (value === null || value === undefined || value === "") return null;

  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizeColor(value) {
  if (typeof value !== "string") return null;

  const trimmed = value.trim().replace(/^#/, "");
  return /^[0-9A-Fa-f]{6}$/.test(trimmed) ? `#${trimmed}` : null;
}

// One drawable endpoint, or null. A stop reference without usable coordinates is
// omitted rather than drawn at (0, 0): an imported feed with no position for one
// of the two stops is a normal state, and the drawer says "Location unknown"
// instead of rendering this hook at all.
function mapPoint(raw) {
  const lat = coordinate(raw?.lat);
  const lon = coordinate(raw?.lon);
  if (lat === null || lon === null) return null;

  return {
    stop_id: raw.stop_id,
    name: raw.name || raw.stop_id || "",
    lat,
    lon,
    color: normalizeColor(raw.color),
  };
}

// `data-pair` is server-rendered JSON. Anything unparseable answers null, and a
// payload without both endpoints draws nothing rather than half a handoff.
function pairFromJson(raw) {
  if (!raw) return null;

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_) {
    return null;
  }

  if (!parsed || typeof parsed !== "object") return null;

  const arrival = mapPoint(parsed.arrival);
  const departure = mapPoint(parsed.departure);
  if (!arrival || !departure) return null;

  const meters = coordinate(parsed.meters);
  return { arrival, departure, meters };
}

function pointTuple(point) {
  return [point.lat, point.lon];
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function tooltipHtml(label, name) {
  const title = escapeHtml(label);
  return name ? `<strong>${title}</strong><br>${escapeHtml(name)}` : title;
}

const ConnectionMapHook = {
  mounted() {
    this.mode = this.el.dataset.mode;
    this._destroyed = false;
    this._points = [];

    const L = window.L;
    if (!L) {
      this._setUnavailable();
      return;
    }
    this._L = L;

    // Leaflet refuses a container it has already initialized. A previous mount
    // whose destroyed() did not run leaves that flag behind, and the map is the
    // one thing in the drawer that may outlive its own patch.
    if (this.el._leaflet_id) {
      this.el._leaflet_id = undefined;
      this.el.innerHTML = "";
    }

    this._map = L.map(this.el, {
      // A picture, not a control: no drag, no zoom, no keyboard panning. The
      // drawer's own text says what the two dots are.
      dragging: false,
      scrollWheelZoom: false,
      doubleClickZoom: false,
      boxZoom: false,
      touchZoom: false,
      keyboard: false,
      zoomControl: false,
      attributionControl: true,
      maxZoom: STREET_MAX_ZOOM,
    });

    this._tileLayers = addStreetBasemap(L, this._map).filter(Boolean);
    this._bindTileState();

    this.layers = L.layerGroup().addTo(this._map);

    // A drawer that opens on a phone or inside a collapsed panel is measured at
    // 0 × 0, and Leaflet keeps the view it computed for nothing. Re-measuring
    // when it becomes visible is what makes the fit land on the stops.
    this._wasHidden = this.el.clientWidth === 0;
    if (typeof ResizeObserver !== "undefined") {
      this._resizeObserver = new ResizeObserver(() => this._onContainerResize());
      this._resizeObserver.observe(this.el);
    }

    this._draw();
  },

  // The drawer's pair can change under a live mount: the drawer is re-rendered
  // on its own state and this element keeps its identity. Redrawing here is what
  // keeps the mini-map from describing the previous trip.
  updated() {
    this._draw();
  },

  destroyed() {
    this._destroyed = true;

    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }

    if (this._map) {
      try {
        this._map.remove();
      } catch (_) {
        /* container reused by a newer instance */
      }
      this._map = null;
    }
  },

  // Missing Leaflet and a failed tile both answer the same way: the map region
  // says it is unavailable and the drawer's own sentence carries the stops. The
  // hook must never throw here — the map is not allowed to take the drawer with
  // it (FH-16, CL-15).
  _setUnavailable() {
    this.el.dataset.state = "unavailable";

    const notice = this.el.parentElement?.querySelector(
      "[data-role='connection-map-unavailable']",
    );
    if (notice) notice.classList.remove("hidden");
  },

  _setReady() {
    if (this.el.dataset.state === "unavailable") return;

    this.el.dataset.state = "ready";
  },

  // `tileload` is the per-tile success event, not the layer's `load`: Leaflet
  // fires `load` once every tile in view is settled, and a tile that errored
  // counts as settled, so a wholly aborted basemap would end on `load` and clear
  // the degraded state.
  _bindTileState() {
    this._tileLayers.forEach((layer) => {
      layer.on?.("tileload", () => this._setReady());
      layer.on?.("tileerror", () => this._setUnavailable());
    });
  },

  _draw() {
    if (this._destroyed || !this._map) return;

    this.layers.clearLayers();
    this._points = [];

    // `network` is a different map with a different payload; drawing this one
    // from a network payload would be a lie. Before step 22 owns it, the mode is
    // left unavailable rather than half-drawn.
    if (this.el.dataset.mode !== "pair") {
      this._setUnavailable();
      return;
    }

    const pair = pairFromJson(this.el.dataset.pair);
    if (!pair) {
      this._setUnavailable();
      return;
    }

    const { arrival, departure, meters } = pair;
    // The same stop on both sides is not a connection across a street: it is one
    // place the vehicle arrives at and leaves from, so it is one marker and no
    // connector.
    const sameStop = arrival.stop_id === departure.stop_id;

    this._color = this._fallbackColor();

    if (sameStop) {
      this._marker(arrival, "Arrives and departs", "top");
    } else {
      // The labels go outward from the connector, not along it. A handoff is
      // often short enough that both stops land in the same 176 px of frame, and
      // labels stacked on the line cover the line and each other; one to the
      // left and one to the right keep all three words readable at any distance.
      this._marker(arrival, "Arrives", "left");
      this._marker(departure, "Departs", "right");

      const line = [pointTuple(arrival), pointTuple(departure)];
      this._casedLine(line);
      // The distance belongs on the connector rather than in the drawer body, so
      // the picture and the sentence about it cannot drift apart. A payload with
      // no distance still draws the connector.
      if (meters !== null) {
        this._casedLine(line, `${Math.round(meters)} m`, "top");
      }
    }

    this._setReady();
    this._fit();
  },

  _fallbackColor() {
    return paletteColor(this.el, "--color-primary", COLOR_FALLBACK);
  },

  // A white case under a route-coloured dot, then the dot. Two circle markers
  // rather than one stroked-and-filled marker, because Leaflet's stroke sits
  // outside the radius and the two rings would not share a centre cleanly.
  _marker(point, label, direction) {
    const color = point.color || this._color;

    this._L.circleMarker(pointTuple(point), {
      radius: DOT_RADIUS,
      weight: DOT_CASE_WEIGHT,
      color: CASING_COLOR,
      fillColor: CASING_COLOR,
      fillOpacity: 1,
      interactive: false,
    }).addTo(this.layers);

    const dot = this._L.circleMarker(pointTuple(point), {
      radius: DOT_RADIUS,
      weight: 1,
      color: color,
      fillColor: color,
      fillOpacity: 1,
      interactive: false,
      zIndexOffset: ENDPOINT_Z_OFFSET,
    }).addTo(this.layers);

    dot.bindTooltip(tooltipHtml(label, point.name), {
      permanent: true,
      direction,
      directionOffset: 10,
      className: TOOLTIP_CLASS,
      interactive: false,
    });

    this._points.push(point);
  },

  // A cased connector: a white underlay, then the dashed accent over it. The
  // tooltip rides the dashed line, because the casing is the drawing's shadow and
  // carries no meaning of its own.
  _casedLine(points, label, direction) {
    this._L.polyline(points, {
      weight: CASING_WEIGHT,
      color: CASING_COLOR,
      opacity: CASING_OPACITY,
      interactive: false,
    }).addTo(this.layers);

    const line = this._L.polyline(points, {
      dashArray: DASH_ARRAY,
      weight: LINE_WEIGHT,
      color: this._color,
      interactive: false,
    }).addTo(this.layers);

    if (label) {
      line.bindTooltip(escapeHtml(label), {
        permanent: true,
        direction: direction || "center",
        className: TOOLTIP_CLASS,
        interactive: false,
      });
    }

    return line;
  },

  _fit() {
    if (this._destroyed || !this._map || !this._points.length) return;

    if (this._points.length === 1) {
      this._map.setView(pointTuple(this._points[0]), SINGLE_POINT_ZOOM);
      return;
    }

    const lats = this._points.map((point) => point.lat);
    const lons = this._points.map((point) => point.lon);

    this._map.fitBounds(
      this._L.latLngBounds(
        [Math.min(...lats), Math.min(...lons)],
        [Math.max(...lats), Math.max(...lons)],
      ),
      { padding: FIT_PADDING, maxZoom: FIT_MAX_ZOOM },
    );
  },

  _onContainerResize() {
    if (this._destroyed || !this._map) return;

    if (this.el.clientWidth === 0) {
      this._wasHidden = true;
      return;
    }
    if (!this._wasHidden) return;

    this._wasHidden = false;
    this._map.invalidateSize();
    this._fit();
  },
};

export default ConnectionMapHook;
