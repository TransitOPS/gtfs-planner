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
 * In `network` mode the same hook is the Connections workspace's map: one count
 * marker per place of the filtered groups, a review badge on a place holding
 * anything needing review, and the arrival/departure pins of the selected group
 * or the open connection drawn the way the drawer draws them. It is still only a
 * locator — the list carries every action (CR-6) — but unlike the mini-map it
 * is interactive: a reader can pan, zoom with the wheel and Ctrl or the zoom
 * control, and choose a place from the map.
 *
 * The container is `phx-update="ignore"`, so the server never patches inside it
 * and this hook owns its contents for the life of the mount. The `data-*`
 * attributes are the only input, and a re-render that changes them arrives as
 * `updated()` rather than as a remount, so a gap drawer reopened on another trip
 * — or a filter that changed the Connections list — redraws in place.
 *
 * Required data-* attrs on the hook root element:
 *   data-mode      "pair" for the drawer mini-map or "network" for the
 *                  Connections map. The hook refuses any other value rather
 *                  than drawing the wrong map.
 *   data-pair      `pair` only: JSON `{arrival: {name, lat, lon, color},
 *                  departure: {...}, meters}` — the gap's own two stop
 *                  references.
 *   data-places    `network` only: JSON `[{id, name, lat, lon, count, "review?",
 *                  tokens, anchor}]` — one row per place of the filtered groups.
 *                  `tokens` are the group's URL tokens at that place and `anchor`
 *                  is the list section's DOM id, so a click can open the one
 *                  group a place holds or bring a place with several to the list.
 *   data-selection `network` only: JSON `{arrival: {name, lat, lon, color},
 *                  departure: {...}}` for the selected group or the open
 *                  connection, or `null` for neither.
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

// The Connections map fits places rather than one handoff, and a day of
// connections spreads over a whole region, so its fit is looser than the
// drawer's: the pins are two stops apart and the reader is being shown where
// they sit among the day's other places, not how far apart two marks are.
const NETWORK_FIT_PADDING = [32, 32];
const NETWORK_FIT_MAX_ZOOM = 17;
const NETWORK_SINGLE_POINT_ZOOM = 15;

// A place's marker is a real 44 px button with the count in a disc and the place
// name beside it, matching the list row it stands for.
const PLACE_BUTTON_SIZE = 44;
const PLACE_DISC_SIZE = 36;

// A place holding anything that needs review carries the prototype's warning
// mark on its count. Drawn rather than imported: the marker HTML is built inside
// the map pane, which has no access to the `<.icon>` component, and the mark is
// decorative — the button's own label says "some need review".
const REVIEW_BADGE_SVG =
  '<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8 2.6 14.4 13.4H1.6z"/><path d="M8 6.6v3.1"/><path d="M8 11.6h.01"/></svg>';

// The Blocks page scrolls, so a bare wheel over the map would scroll the page
// past a list the reader is using. The map takes the wheel only when the reader
// asks for it with the modifier the browser itself uses for zoom, and says so
// for long enough to read.
const WHEEL_HINT_MS = 1100;

// The drawer's map is a picture: no drag, no zoom, no keyboard panning, because
// the drawer's own text already says what the two dots are.
const PAIR_MAP_OPTIONS = {
  dragging: false,
  scrollWheelZoom: false,
  doubleClickZoom: false,
  boxZoom: false,
  touchZoom: false,
  keyboard: false,
  zoomControl: false,
  attributionControl: true,
  maxZoom: STREET_MAX_ZOOM,
};

// The Connections map is a locator the reader drives: it pans, it zooms by
// keyboard and by the control, and it takes the wheel only with the modifier.
// Leaflet's own wheel handler is off because it would take every wheel.
const NETWORK_MAP_OPTIONS = {
  dragging: true,
  scrollWheelZoom: false,
  doubleClickZoom: true,
  boxZoom: false,
  touchZoom: true,
  keyboard: true,
  // Leaflet adds its zoom control itself at the top left, where the prototype
  // does not put it. The map adds both controls at the top right instead, so the
  // corner a reader reaches for matches the rest of the application.
  zoomControl: false,
  attributionControl: true,
  maxZoom: STREET_MAX_ZOOM,
};

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

// `data-places` is server-rendered JSON. A place the version cannot place is
// skipped rather than drawn at (0, 0) — the server names it in the pane's own
// note and still lists it, so dropping the marker loses nothing (FH-16).
function placesFromJson(raw) {
  if (!raw) return [];

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_) {
    return [];
  }

  if (!Array.isArray(parsed)) return [];

  return parsed.map(placeFrom).filter(Boolean);
}

function placeFrom(raw) {
  if (!raw || typeof raw !== "object") return null;

  const lat = coordinate(raw.lat);
  const lon = coordinate(raw.lon);
  if (lat === null || lon === null) return null;

  const count = Number(raw.count);
  return {
    id: raw.id === undefined || raw.id === null ? "" : String(raw.id),
    name: raw.name || "",
    lat,
    lon,
    count: Number.isFinite(count) && count > 0 ? count : 0,
    review: raw["review?"] === true,
    // The server sends the tokens it drew the list rows from, so the marker and
    // the row beside it cannot disagree about which group a place holds.
    tokens: Array.isArray(raw.tokens) ? raw.tokens.map(String) : [],
    anchor: typeof raw.anchor === "string" ? raw.anchor : "",
  };
}

// `data-selection` is the selected group or the open connection's two stops, or
// `null` when the reader has chosen neither. Anything unparseable, or a payload
// missing either endpoint, draws no pins rather than half a handoff.
function selectionFromJson(raw) {
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

  return { arrival, departure };
}

function placeMarkerHtml(place) {
  const connections = place.count === 1 ? "1 connection" : `${place.count} connections`;
  const review = place.review
    ? `<span class="connection-map-place-review" aria-hidden="true">${REVIEW_BADGE_SVG}</span>`
    : "";
  const label = `${place.name}: ${connections}${place.review ? ", some need review" : ""}`;

  return (
    `<button type="button" class="connection-map-place-button" aria-label="${escapeHtml(label)}">` +
    `<span class="connection-map-place-disc">${place.count}${review}</span>` +
    `<span class="connection-map-place-label">${escapeHtml(place.name)}</span>` +
    "</button>"
  );
}

function boundsOf(points) {
  const lats = points.map((point) => point.lat);
  const lons = points.map((point) => point.lon);

  return [
    [Math.min(...lats), Math.min(...lons)],
    [Math.max(...lats), Math.max(...lons)],
  ];
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
    this._placePoints = [];
    this._selection = [];
    this._placeMarkers = [];

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

    this._map = L.map(this.el, this.el.dataset.mode === "network" ? NETWORK_MAP_OPTIONS : PAIR_MAP_OPTIONS);

    this._tileLayers = addStreetBasemap(L, this._map).filter(Boolean);
    this._bindTileState();

    this.layers = L.layerGroup().addTo(this._map);

    if (this.el.dataset.mode === "network") {
      this._bindNetworkControls();
    }

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

  // The Connections map redraws only when its own payload changed. A filter
  // keystroke re-renders the whole panel, and rebuilding a day's markers on every
  // character would drop the reader's pan and zoom for nothing.
  updated() {
    if (this.el.dataset.mode !== "network") {
      this._draw();
      return;
    }

    const key = this._networkKey();
    if (key === this._drawnKey) return;

    this._draw();
  },

  destroyed() {
    this._destroyed = true;

    this._unbindNetworkControls();

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
  // says it is unavailable and the drawer's own sentence — or the pane's, beside
  // the list — carries the facts. The hook must never throw here: the map is not
  // allowed to take the drawer or the list with it (FH-16, CL-15).
  //
  // Both hiding idioms are cleared, because the two surfaces render the notice
  // the way their own markup does: the drawer region uses a Tailwind `hidden`
  // class, the Connections pane a server-rendered `hidden` attribute.
  _setUnavailable() {
    this.el.dataset.state = "unavailable";

    const notice = this.el.parentElement?.querySelector(
      "[data-role='connection-map-unavailable']",
    );
    if (!notice) return;

    notice.classList.remove("hidden");
    notice.hidden = false;
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

    // Any mode this hook does not own is left unavailable rather than half-drawn:
    // a map that shows the wrong thing is worse than one that says it cannot.
    const mode = this.el.dataset.mode;
    if (mode === "network") {
      this._drawNetwork();
      return;
    }

    if (mode !== "pair") {
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

  // What the map is currently drawing, as one string. `updated()` compares it
  // so an unrelated re-render does not redraw the map.
  _networkKey() {
    return `${this.el.dataset.places || ""}|${this.el.dataset.selection || ""}`;
  },

  // The Connections map. A day with no place the version can place still draws
  // nothing wrong: there are simply no markers, and the pane's own note names
  // the places it could not draw. That is a drawn map with nothing on it, not an
  // unavailable one, so the note and the list are the answer and `data-state`
  // stays `ready`.
  _drawNetwork() {
    const places = placesFromJson(this.el.dataset.places);
    const selection = selectionFromJson(this.el.dataset.selection);

    this._drawnKey = this._networkKey();
    this._color = this._fallbackColor();

    // The place markers and the selection pins are kept apart: the fit targets
    // one set or the other, never their union, and `_points` belongs to the
    // drawer pair's own fit.
    this._placePoints = places;

    this._placeMarkers = places.map((place) => this._placeMarker(place));

    if (selection) {
      // The place the selected group belongs to drops its own count marker while
      // that group is on the map. The pins already say which stop is which, and a
      // count disc standing on the same pixel only hides one of the words.
      const stops = [selection.arrival, selection.departure];

      this._placeMarkers
        .filter((marker) => stops.some((stop) => marker.place.lat === stop.lat && marker.place.lon === stop.lon))
        .forEach((marker) => this.layers.removeLayer(marker));

      // The same drawing as the drawer's pair, on the same terms: one stop both
      // trips use is one pin and no connector.
      const sameStop = selection.arrival.stop_id === selection.departure.stop_id;

      if (sameStop) {
        this._marker(selection.arrival, "Arrives and departs", "top");
      } else {
        // The labels go above and below the two pins, pointing away from each
        // other, so neither word lands on the connector or on the other pin. A
        // handoff is often short enough that both stops land in the same stretch
        // of frame, so a label laid out sideways is a label laid on a place
        // marker instead.
        const arrivalNorth = selection.arrival.lat >= selection.departure.lat;

        this._marker(selection.arrival, "Arrives", arrivalNorth ? "top" : "bottom");
        this._marker(selection.departure, "Departs", arrivalNorth ? "bottom" : "top");
        this._casedLine([pointTuple(selection.arrival), pointTuple(selection.departure)]);
      }

      this._selection = [selection.arrival, selection.departure];
    } else {
      this._selection = [];
    }

    this._setReady();
    this._fitNetwork();
  },

  // One place, one marker. The marker is a `divIcon` holding a real button, so
  // it is in the tab order and answers Enter and Space the way the list row
  // beside it does; Leaflet's own `keyboard` marker option is off so a reader
  // does not meet the same place twice.
  _placeMarker(place) {
    const marker = this._L.marker(pointTuple(place), {
      icon: this._L.divIcon({
        className: "connection-map-place",
        html: placeMarkerHtml(place),
        iconSize: [PLACE_BUTTON_SIZE, PLACE_BUTTON_SIZE],
        iconAnchor: [PLACE_BUTTON_SIZE / 2, PLACE_BUTTON_SIZE / 2],
      }),
      keyboard: false,
      riseOnHover: true,
      title: place.name,
      alt: place.name,
    });

    marker.on("click", () => this._choosePlace(place));
    marker.addTo(this.layers);
    // The place rides along on the marker so the selection can recognise it and
    // drop its count while this group's pins are drawn.
    marker.place = place;

    return marker;
  },

  // The one action a place marker has, and it is the same action the list row
  // has. A place holding one group opens it, the way its row does. A place
  // holding several has no single group to open, so the marker brings that
  // place's section into view and puts the keyboard on its first row instead of
  // guessing which of them the reader meant.
  _choosePlace(place) {
    if (place.tokens.length === 1) {
      this.pushEvent("open_group", { group: place.tokens[0] });
      return;
    }

    const section = place.anchor ? document.getElementById(place.anchor) : null;
    if (!section) return;

    section.scrollIntoView({ block: "start" });
    section.querySelector("button")?.focus();
  },

  _fitNetwork() {
    if (this._destroyed || !this._map) return;

    // A selection is what the reader is looking at, so it wins the fit; with no
    // selection the fit is every place, which is what the "Show every place"
    // control asks for.
    const points = this._selection.length ? this._selection : this._placePoints;
    if (!points.length) return;

    if (points.length === 1) {
      this._map.setView(pointTuple(points[0]), NETWORK_SINGLE_POINT_ZOOM);
      return;
    }

    // The connection drawer is non-modal and 480 px wide, so it covers the right
    // of the pane. Fitting into the covered width would centre the selection
    // under the drawer; the right padding is the width the drawer takes, so the
    // fit lands in the part of the pane the reader can actually see.
    const right = NETWORK_FIT_PADDING[0] + this._drawerOverlap();

    this._map.fitBounds(this._L.latLngBounds(...boundsOf(points)), {
      paddingTopLeft: [NETWORK_FIT_PADDING[0], NETWORK_FIT_PADDING[1]],
      paddingBottomRight: [NETWORK_FIT_PADDING[0], right],
      maxZoom: NETWORK_FIT_MAX_ZOOM,
    });
  },

  // How much of the map pane the open connection drawer covers, in pixels, or 0
  // when no drawer is open. The drawer element is only in the DOM while its
  // LiveView render includes it, so its absence is the closed case.
  _drawerOverlap() {
    const drawer = document.getElementById("gap-drawer");
    if (!drawer) return 0;

    const width = drawer.getBoundingClientRect().width;
    if (!width) return 0;

    const pane = this.el.getBoundingClientRect();
    const covered = pane.right - (window.innerWidth - width);
    return covered > 0 ? Math.round(covered) : 0;
  },

  _bindNetworkControls() {
    this._addZoomControl();
    this._addFitControl();
    this._bindWheelHint();
  },

  _addZoomControl() {
    if (!this._map || typeof this._L.control?.zoom !== "function") return;

    const zoom = this._L.control.zoom({ position: "topright" }).addTo(this._map);
    this._zoomControl = zoom;
  },

  // Leaflet's zoom control is the map's own; "Show every place" is the one
  // control this map adds, and it is added the same way into the same corner, so
  // a reader finds both in one place and neither is orphaned server markup when
  // the map never loads.
  _addFitControl() {
    if (!this._map || !this._L.Control || typeof this._L.Control.extend !== "function") {
      return;
    }

    const L = this._L;
    const FitControl = L.Control.extend({
      options: { position: "topright" },
      onAdd: () => {
        const button = document.createElement("button");
        button.type = "button";
        button.id = "connections-map-fit";
        button.setAttribute("aria-label", "Show every place");
        button.setAttribute("title", "Show every place");
        button.className = "connection-map-fit";
        button.addEventListener("click", () => this._fitNetwork());
        return button;
      },
    });

    const control = new FitControl();
    control.addTo(this._map);
    this._fitControl = control;
  },

  _bindWheelHint() {
    const pane = this.el.parentElement;
    if (!pane) return;

    this._hint = pane.querySelector("[data-map-wheel-hint]");
    this._wheelHandler = (event) => this._onWheel(event);
    this.el.addEventListener("wheel", this._wheelHandler, { passive: false });
  },

  _unbindNetworkControls() {
    if (this._wheelHandler) {
      this.el.removeEventListener("wheel", this._wheelHandler);
      this._wheelHandler = null;
    }

    if (this._hintTimer) {
      clearTimeout(this._hintTimer);
      this._hintTimer = null;
    }

    this._fitControl = null;
    this._zoomControl = null;
  },

  // The Blocks page scrolls, so a bare wheel over the map would scroll the page
  // out from under a reader using the list beside it. The wheel zooms when the
  // reader holds the modifier the browser itself uses for zoom, and otherwise
  // says once how to do it.
  _onWheel(event) {
    if (event.ctrlKey || event.metaKey) {
      event.preventDefault();
      if (!this._map) return;

      const zoom = this._map.getZoom() + (event.deltaY < 0 ? 1 : -1);
      this._map.setZoom(zoom);
      return;
    }

    this._showWheelHint();
  },

  _showWheelHint() {
    if (!this._hint) return;

    this._hint.hidden = false;
    if (this._hintTimer) clearTimeout(this._hintTimer);
    this._hintTimer = setTimeout(() => {
      if (this._hint) this._hint.hidden = true;
      this._hintTimer = null;
    }, WHEEL_HINT_MS);
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

    this._map.fitBounds(this._L.latLngBounds(...boundsOf(this._points)), {
      padding: FIT_PADDING,
      maxZoom: FIT_MAX_ZOOM,
    });
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
    if (this.el.dataset.mode === "network") {
      this._fitNetwork();
    } else {
      this._fit();
    }
  },
};

export default ConnectionMapHook;
