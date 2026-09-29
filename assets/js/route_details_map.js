/**
 * RouteDetailsMapHook
 *
 * Owns Route › Details' saved route map: the Leaflet rendering of the step-17
 * projection `GtfsPlanner.Gtfs.Routes.Map.route_map/3`, drawn inside the
 * ignored `#route-map` container. The server renders the payload, the pattern
 * list, the legend and every control; this hook only draws what the payload
 * already says and never invents geometry (INV-5, seam S-3).
 *
 * Required data-* attrs on the hook root element:
 *   data-map-payload  route_map/3 as JSON: `{route_uuid, route_id, status,
 *                     saved_alignment, patterns: [{route_pattern_id,
 *                     direction_id, route_pattern_name, visits, sections}],
 *                     imported_shape_variants}`. Visits and sections carry
 *                     `[lon, lat]` coordinates (JSON numbers) or explicit
 *                     `unlocated: [{ref, reason}]` metadata. Every section
 *                     carries its `source` (`stop_pair` | `imported_shape`)
 *                     and its `saved | missing | unavailable` status.
 *   data-map-colors   `{route_color, route_text_color}` — the colors the
 *                     badge preview is showing, so the lines and the badge
 *                     start coherent.
 *   data-map-context  optional `{routes: [...]}` — the route_context_map/4
 *                     page(s): other routes in the viewport, each with its
 *                     own deduplicated `sections` and
 *                     `imported_shape_variants` (same source/status labels),
 *                     identity fields and `active`. Absent means the layer
 *                     is off or cleared; the hook never invents geometry.
 *
 * The context layer ("Show other routes", AC-27) draws each other route as a
 * thinner line in its own color below the current route's geometry, dashed
 * only when the route is explicitly inactive, with a badge naming it. It is
 * never interactive and never part of the fit; highlighting a current-route
 * pattern dims the context layer so the selection still reads. The hook also
 * owns the checkbox: toggling it — and every map move while it is on — pushes
 * `route_context_viewport` with the map's bounds, and the server's newest
 * event wins (the patch carries whatever state that newest event produced).
 *
 * The container is `phx-update="ignore"`, so the server never patches inside
 * it; the `data-*` attributes themselves are patched, and a hook on an ignored
 * container receives `updated()` whenever its dataset changed. Color-only
 * changes therefore recolor without ever touching the view; a payload whose
 * `route_uuid` changed is a different opened route and refits once (AC-26).
 * Anything else redraws in place and preserves pan/zoom.
 *
 * Sections are drawn by their own labels (AC-25): a `saved` stop-pair section
 * is a solid line; a `missing` section is dashed only when both of its
 * endpoint visits have coordinates; `unavailable` geometry (and a missing
 * section with an unlocated endpoint) is never drawn and never fabricated —
 * the pattern list explains it instead. Distinct imported shapes render once
 * each as labelled variants. Occurrence markers key on
 * `route_pattern_id:position`, so a loop's repeated stop keeps one marker per
 * visit.
 *
 * This is an external-runtime boundary: window.L (Leaflet) and the
 * authenticated tile proxy `/map/tiles/osm-bright/:z/:x/:y` (same-origin
 * cookies ride along). A missing Leaflet degrades to the plain frame without
 * an exception; a failed tile keeps every vector and the text list on screen
 * and only explains the street-map loss (AC-26). Wheel zoom is cooperative:
 * plain wheel scrolls the page behind a hint, Ctrl/Cmd + wheel zooms, and the
 * 44px zoom/fit controls plus the pattern list are the keyboard/text
 * equivalents (AC-28).
 */

import {
  automaticTextColor,
  contrastRatio,
  normalizeHex,
} from "./route_identity_preview.js";

// The authenticated osm-bright proxy (MapTilesController keeps the key server
// side). Same-origin, so the operator's session authorizes every tile.
const TILE_URL = "/map/tiles/osm-bright/{z}/{x}/{y}";

// Colors, with the literals only protecting an isolated fixture or a missing
// stylesheet. A route with no color draws like the prototype's: a white line
// that reads through its casing.
const DEFAULT_LINE_COLOR = "FFFFFF";
const WHITE = "FFFFFF";
const CASING_COLOR = "#ffffff";
const LOW_CONTRAST_CASING = "#7a8698";
const SWATCH_FALLBACK = "#7A8698";

const LINE_WEIGHT = 5;
const CASING_WEIGHT = 9;
const CONTEXT_LINE_WEIGHT = 3.5;
const CONTEXT_CASING_WEIGHT = 6.5;
const CONTEXT_DASH_ARRAY = "2 6";
const CONTEXT_OPACITY = 0.9;
const CONTEXT_INACTIVE_OPACITY = 0.45;
const CONTEXT_DIM_OPACITY = 0.12;
const DASH_ARRAY = "9 7";
const HIGHLIGHT_OPACITY = 1;
const DIM_OPACITY = 0.28;

const MIN_ZOOM = 2;
const TILE_MAX_ZOOM = 19;
const FIT_PADDING = [24, 24];
const FIT_MAX_ZOOM = 17;
const WORLD_CENTER = [20, 0];
const WORLD_ZOOM = 2;

// How long the cooperative-zoom hint stays up after a plain wheel gesture.
const HINT_MS = 1200;

// DOM ids outside the ignored container that this hook drives.
const CARD_ID = "route-map-card";
const HINT_ID = "route-map-hint";
const TILES_UNAVAILABLE_ID = "route-map-tiles-unavailable";
const TILES_RETRY_ID = "route-map-tiles-retry";
const ZOOM_IN_ID = "route-map-zoom-in";
const ZOOM_OUT_ID = "route-map-zoom-out";
const FIT_ID = "route-map-fit";
const PATTERN_LIST_ID = "route-map-pattern-list";
const VARIANT_LIST_ID = "route-map-variant-list";
const CONTEXT_TOGGLE_ID = "route-map-context-toggle";
const FORM_ID = "route-details-form";
const COLOR_FIELD_SELECTOR = 'input[name="route[route_color]"]';

// The LiveView event that carries the viewport to the server, and the leaflet
// pane that keeps context geometry under the current route's own lines.
const CONTEXT_VIEWPORT_EVENT = "route_context_viewport";
const CONTEXT_PANE = "routeContextPane";

// `[lon, lat]` at the model boundary, `[lat, lon]` for Leaflet — the explicit
// conversion R7 asks for. Only finite JSON numbers pass: anything else
// (null, a string, NaN) is corrupt input that must never become a drawn
// point at (0, 0).
export function leafletLatLng(coordinates) {
  if (!Array.isArray(coordinates) || coordinates.length !== 2) return null;
  const lon = coordinates[0];
  const lat = coordinates[1];
  if (
    typeof lon !== "number" ||
    !Number.isFinite(lon) ||
    typeof lat !== "number" ||
    !Number.isFinite(lat)
  ) {
    return null;
  }
  return [lat, lon];
}

export function parsePayload(raw) {
  if (typeof raw !== "string" || raw === "") return null;

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_error) {
    return null;
  }

  if (
    !parsed ||
    typeof parsed !== "object" ||
    !Array.isArray(parsed.patterns) ||
    !Array.isArray(parsed.imported_shape_variants)
  ) {
    return null;
  }

  return parsed;
}

export function parseColors(raw) {
  let parsed = {};
  if (typeof raw === "string" && raw !== "") {
    try {
      parsed = JSON.parse(raw);
    } catch (_error) {
      parsed = {};
    }
  }

  return {
    route_color:
      parsed && typeof parsed.route_color === "string"
        ? parsed.route_color
        : "",
    route_text_color:
      parsed && typeof parsed.route_text_color === "string"
        ? parsed.route_text_color
        : "",
  };
}

// The line color is the route color the badge preview shows: a blank or
// unusable draft previews as the prototype's white default, never as a
// half-parsed value. Local preview only — the server validates what saves.
export function lineColorFor(colors) {
  return normalizeHex(colors?.route_color) || DEFAULT_LINE_COLOR;
}

// The white casing under the line, or the prototype's grey edge when the line
// itself would disappear against white.
export function casingFor(lineHex) {
  const ratio = contrastRatio(lineHex, WHITE);
  return ratio !== null && ratio < 1.5 ? LOW_CONTRAST_CASING : CASING_COLOR;
}

// List swatches sit on white, so a white line draws in the grey fallback.
export function swatchColorFor(lineHex) {
  return lineHex === WHITE ? SWATCH_FALLBACK : `#${lineHex}`;
}

function visitCoordinatesByPosition(pattern) {
  const byPosition = new Map();
  for (const visit of pattern?.visits || []) {
    const latlng = leafletLatLng(visit?.coordinates);
    if (latlng) byPosition.set(visit.position, latlng);
  }
  return byPosition;
}

function sectionKey(pattern, section) {
  return `${pattern.route_pattern_id}:${section.from_position}-${section.to_position}`;
}

// Every drawable path of one pattern, keyed to its own section. A saved
// section draws solid from its own coordinates; a missing section draws
// dashed only when both endpoint visits have coordinates (AC-25); unknown
// geometry is never drawn.
export function sectionPaths(pattern) {
  const endpoints = visitCoordinatesByPosition(pattern);
  const paths = [];

  for (const section of pattern?.sections || []) {
    if (section?.source !== "stop_pair") continue;

    if (section.status === "saved") {
      const rawCoordinates = Array.isArray(section.coordinates)
        ? section.coordinates
        : [];
      const latlngs = rawCoordinates.map(leafletLatLng).filter(Boolean);
      if (latlngs.length && latlngs.length === rawCoordinates.length) {
        paths.push({
          key: sectionKey(pattern, section),
          kind: "solid",
          latlngs,
        });
      }
      continue;
    }

    if (section.status === "missing") {
      const from = endpoints.get(section.from_position);
      const to = endpoints.get(section.to_position);
      if (from && to) {
        paths.push({
          key: sectionKey(pattern, section),
          kind: "dashed",
          latlngs: [from, to],
        });
      }
    }

    // `unavailable` — and a `missing` section with an unlocated endpoint —
    // stays undrawn: unknown geometry is never fabricated (INV-5).
  }

  return paths;
}

export function variantPaths(variant) {
  if (variant?.source !== "imported_shape") return [];
  if (variant.status !== "saved" || !Array.isArray(variant.coordinates)) {
    return [];
  }

  const latlngs = variant.coordinates.map(leafletLatLng).filter(Boolean);
  if (!latlngs.length) return [];

  return [{ key: variant.shape_id, kind: "solid", latlngs }];
}

// One marker per visit, not per stop: a repeated stop keeps one marker per
// occurrence position, so loop patterns never lose an occurrence (AC-25).
export function occurrenceMarkers(pattern) {
  const markers = [];

  for (const visit of pattern?.visits || []) {
    const latlng = leafletLatLng(visit?.coordinates);
    if (!latlng) continue;
    markers.push({
      key: `${pattern.route_pattern_id}:${visit.position}`,
      stopId: visit.stop_id,
      position: visit.position,
      latlng,
    });
  }

  return markers;
}

// The stops to draw as white dots ringed in the line color. With nothing
// highlighted the map shows every stop the saved patterns visit, small, and a
// stop that patterns share is drawn once. Highlighting a pattern narrows the map
// to that pattern's own visits, larger, with the first visit biggest.
export function stopMarkers(patterns, highlightId) {
  const highlighted = highlightId
    ? patterns.filter((pattern) => pattern.route_pattern_id === highlightId)
    : [];
  if (highlightId && highlighted.length === 0) return [];

  if (highlighted.length) {
    return highlighted.flatMap((pattern) =>
      occurrenceMarkers(pattern).map((marker) => ({
        ...marker,
        radius: marker.position === 1 ? 7 : 5,
      })),
    );
  }

  const seen = new Set();
  const markers = [];
  for (const pattern of patterns) {
    for (const marker of occurrenceMarkers(pattern)) {
      const at = JSON.stringify(marker.latlng);
      if (seen.has(at)) continue;
      seen.add(at);
      markers.push({ ...marker, radius: 4 });
    }
  }
  return markers;
}

export function unlocatedPhrase(reason) {
  switch (reason) {
    case "coordinates_absent":
      return "a stop has no coordinates";
    case "stop_not_found":
      return "a referenced stop is missing";
    case "shape_points_absent":
      return "the shape has no points";
    default:
      return "the path is unknown";
  }
}

export function isZoomWheel(event) {
  return !!(event && (event.ctrlKey || event.metaKey));
}

// What a LiveView patch means for the map. Same route: redraw in place and
// keep pan/zoom. Different route: full redraw plus the one fit. The decision
// is pure so a color-only patch can never reset the view (AC-26).
export function nextMapAction(renderedRouteUuid, payload) {
  if (!payload) return "none";
  if (renderedRouteUuid && payload.route_uuid === renderedRouteUuid) {
    return "redraw";
  }
  return "refit";
}

// The "Show other routes" payload. Same contract as the main payload: parse
// defensively and draw only what the server actually returned.
export function parseContext(raw) {
  if (typeof raw !== "string" || raw === "") return null;

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_error) {
    return null;
  }

  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.routes)) {
    return null;
  }

  return parsed;
}

// Every drawable path of one context route, in payload order. Only `saved`
// geometry with fully valid coordinates draws: context sections without an
// endpoint in the payload — and `missing`/`unavailable` entries — are never
// fabricated (INV-5).
export function contextRoutePaths(route) {
  if (!route || typeof route.route_id !== "string") return [];

  const paths = [];

  for (const section of route.sections || []) {
    if (section?.source !== "stop_pair" || section.status !== "saved") continue;
    const rawCoordinates = Array.isArray(section.coordinates)
      ? section.coordinates
      : [];
    const latlngs = rawCoordinates.map(leafletLatLng).filter(Boolean);
    if (latlngs.length >= 2 && latlngs.length === rawCoordinates.length) {
      paths.push({ latlngs });
    }
  }

  for (const variant of route.imported_shape_variants || []) {
    if (variant?.source !== "imported_shape" || variant.status !== "saved") {
      continue;
    }
    const rawCoordinates = Array.isArray(variant.coordinates)
      ? variant.coordinates
      : [];
    const latlngs = rawCoordinates.map(leafletLatLng).filter(Boolean);
    if (latlngs.length >= 2 && latlngs.length === rawCoordinates.length) {
      paths.push({ latlngs });
    }
  }

  return paths;
}

// The prototype's badge: the route's color as the plate, white traded for the
// grey fallback, and the automatic text color when no text color is usable.
export function contextBadge(route) {
  if (!route) return null;

  const bg = normalizeHex(route.route_color) || DEFAULT_LINE_COLOR;
  const plate = bg === WHITE ? SWATCH_FALLBACK : `#${bg}`;
  const fg =
    normalizeHex(route.route_text_color) ||
    automaticTextColor(plate) ||
    "000000";
  const label =
    String(
      route.route_short_name || route.route_long_name || route.route_id,
    ).trim() || route.route_id;

  return { label, background: plate, color: `#${fg}` };
}

// Viewport bounds the server can compare across moves: rounded to the same
// precision so a map nudge that lands on the same view never re-queries.
export function roundBounds({ north, south, east, west }) {
  const round = (value) => Math.round(value * 1e6) / 1e6;
  return {
    north: round(north),
    south: round(south),
    east: round(east),
    west: round(west),
  };
}

export function sameViewportBounds(a, b) {
  if (!a || !b) return false;
  return (
    a.north === b.north &&
    a.south === b.south &&
    a.east === b.east &&
    a.west === b.west
  );
}

// Badge labels come from stored route names and reach a divIcon as HTML, so
// they are escaped before they can become markup.
function escapeBadgeLabel(label) {
  const div = document.createElement("div");
  div.textContent = String(label);
  return div.innerHTML;
}

const RouteDetailsMapHook = {
  mounted() {
    this._destroyed = false;
    this._renderedRouteUuid = null;
    this._payloadRaw = "";
    this._payload = null;
    this._highlight = null;
    this._lineColor = DEFAULT_LINE_COLOR;
    this._lineLayers = [];
    this._contextRaw = "";
    this._contextLineLayers = [];
    this._contextBadges = [];
    this._lastContextBounds = null;
    this._hintTimer = null;
    this._cleanup = [];

    const L = window.L;
    if (!L) {
      console.error(
        "RouteDetailsMapHook: window.L (Leaflet) is not available; " +
          "the pattern list remains the text equivalent",
      );
      return;
    }
    this._L = L;

    // If LiveView reused a container that already had Leaflet initialized,
    // reset the flag and clear the child DOM first (MapAlignment precedent).
    if (this.el._leaflet_id) {
      this.el._leaflet_id = undefined;
      this.el.innerHTML = "";
    }

    this._buildMap();
    this._bindControls();
    this._applyDataset();
  },

  updated() {
    if (this._destroyed || !this._map) return;
    // Color-only patches must not redraw geometry; a changed payload redraws
    // (and refits only when the route itself changed).
    this._applyDataset();
  },

  destroyed() {
    this._destroyed = true;

    if (this._hintTimer) {
      clearTimeout(this._hintTimer);
      this._hintTimer = null;
    }

    for (const teardown of this._cleanup.splice(0)) {
      try {
        teardown();
      } catch (_error) {
        /* the node is already gone */
      }
    }

    if (this._map) {
      try {
        this._map.remove();
      } catch (_error) {
        /* container reused by a newer instance */
      }
      this._map = null;
    }
  },

  // --- setup -----------------------------------------------------------------

  _buildMap() {
    const L = this._L;

    this._map = L.map(this.el, {
      zoomControl: false,
      attributionControl: false,
      // Wheel zoom is cooperative: the hook's own wheel listener decides.
      scrollWheelZoom: false,
      // The prototype's map is a picture with button/list equivalents, not a
      // tab stop; keyboard operation goes through the 44px controls and the
      // pattern list (AC-26/AC-28).
      keyboard: false,
      minZoom: MIN_ZOOM,
    });
    this._map.setView(WORLD_CENTER, WORLD_ZOOM);

    this._tiles = L.tileLayer(TILE_URL, {
      keepBuffer: 4,
      maxNativeZoom: TILE_MAX_ZOOM,
      maxZoom: TILE_MAX_ZOOM,
      updateWhenIdle: false,
    }).addTo(this._map);

    this._sections = L.layerGroup().addTo(this._map);
    this._variants = L.layerGroup().addTo(this._map);
    this._markers = L.layerGroup().addTo(this._map);

    // Context geometry lives in its own pane under the overlay pane, so the
    // current route always reads on top and the context never intercepts a
    // drag or click meant for it.
    const contextPane = this._map.createPane(CONTEXT_PANE);
    contextPane.style.zIndex = "350";
    contextPane.style.pointerEvents = "none";
    this._contexts = L.layerGroup().addTo(this._map);

    // Every map move with context enabled reports the new viewport; identical
    // bounds are skipped so settling from a fit does not re-query.
    this._onMoveEnd = () => {
      const toggle = document.getElementById(CONTEXT_TOGGLE_ID);
      if (!toggle?.checked) return;
      this._pushContextViewport(this._viewportBounds());
    };
    this._map.on("moveend", this._onMoveEnd);

    // A tile that errored is the degraded state; a later tile that loaded
    // recovers. `load` is not that signal: an errored tile counts as ready,
    // so a wholly aborted basemap would end with `load` (TransferMap's
    // finding). Vectors live in their own layers and are never touched by
    // tile state (AC-26).
    this._tiles.on("tileerror", () => this._setTilesUnavailable(true));
    this._tiles.on("tileload", () => this._setTilesUnavailable(false));

    this._L.control
      .scale({ imperial: false, position: "bottomleft", maxWidth: 120 })
      .addTo(this._map);
  },

  _bindControls() {
    this._bindClick(ZOOM_IN_ID, () => this._map?.zoomIn());
    this._bindClick(ZOOM_OUT_ID, () => this._map?.zoomOut());
    this._bindClick(FIT_ID, () => this._fit());
    this._bindClick(TILES_RETRY_ID, () => {
      this._setTilesUnavailable(false);
      this._tiles?.redraw();
    });

    // "Show other routes" (AC-27): the checkbox stays a native checkbox (its
    // keyboard operation included); this only reports the toggle and the
    // viewport it applies to. Turning it off tells the server to clear, so no
    // state older than the newest event can survive.
    const toggle = document.getElementById(CONTEXT_TOGGLE_ID);
    if (toggle) {
      this._onContextToggle = (event) => {
        if (event.target.checked) {
          this._pushContextViewport(this._viewportBounds());
        } else {
          this._lastContextBounds = null;
          this._pushEventTo("route_context_viewport", { enabled: false });
        }
      };
      toggle.addEventListener("change", this._onContextToggle);
      this._cleanup.push(() =>
        toggle.removeEventListener("change", this._onContextToggle),
      );
    }

    // Cooperative gestures: plain wheel scrolls the page behind a hint;
    // Ctrl/Cmd + wheel zooms around the pointer (the prototype's contract).
    this._onWheel = (event) => {
      if (this._destroyed || !this._map) return;
      if (!isZoomWheel(event)) {
        this._showHint();
        return;
      }
      event.preventDefault();
      const step = event.deltaY < 0 ? 1 : -1;
      const zoom = Math.min(
        TILE_MAX_ZOOM,
        Math.max(MIN_ZOOM, this._map.getZoom() + step),
      );
      this._map.setZoomAround(
        this._map.mouseEventToContainerPoint(event),
        zoom,
      );
    };
    this.el.addEventListener("wheel", this._onWheel, { passive: false });
    this._cleanup.push(() =>
      this.el.removeEventListener("wheel", this._onWheel),
    );

    // The lists are the map's text equivalent: hovering or focusing a row
    // highlights its geometry; leaving clears it unless the row keeps focus.
    this._bindHighlightList(PATTERN_LIST_ID);
    this._bindHighlightList(VARIANT_LIST_ID);

    // Draft color preview (C-2, AC-19): the hex field and the picker repaint
    // the lines locally on every keystroke, without a server round trip and
    // without a fit. Nothing here is submitted or saved.
    const form = document.getElementById(FORM_ID);
    if (form) {
      this._onFormInput = (event) => {
        const isColor =
          event.target?.matches?.(
            `${COLOR_FIELD_SELECTOR}, input[type="color"]`,
          ) ?? false;
        if (!isColor) return;

        const field = form.querySelector(COLOR_FIELD_SELECTOR);
        const picker = form.querySelector('input[type="color"]');
        const raw = (field?.value ?? "").trim() || picker?.value || "";
        this._applyColors({ route_color: raw, route_text_color: "" });
      };
      form.addEventListener("input", this._onFormInput);
      this._cleanup.push(() =>
        form.removeEventListener("input", this._onFormInput),
      );
    }
  },

  _bindClick(id, handler) {
    const el = document.getElementById(id);
    if (!el) return;

    el.addEventListener("click", handler);
    this._cleanup.push(() => el.removeEventListener("click", handler));
  },

  _bindHighlightList(listId) {
    const list = document.getElementById(listId);
    if (!list) return;

    const rowFor = (node) => node?.closest?.("[data-map-highlight]") || null;

    const onOver = (event) => {
      const row = rowFor(event.target);
      if (row) this.setHighlight(row.dataset.mapHighlight);
    };
    const onOut = (event) => {
      const row = rowFor(event.target);
      const to = rowFor(event.relatedTarget);
      if (row && to !== row && !row.contains(to)) this.setHighlight(null);
    };
    const onFocusIn = (event) => {
      const row = rowFor(event.target);
      if (row) this.setHighlight(row.dataset.mapHighlight);
    };
    const onFocusOut = (event) => {
      const row = rowFor(event.target);
      if (row && !row.contains(event.relatedTarget)) this.setHighlight(null);
    };
    const onClick = (event) => {
      const row = rowFor(event.target);
      // Variant rows are buttons: their click pins the highlight (the
      // prototype's map-click toggle). Pattern rows are links and navigate.
      if (row?.dataset.mapKind === "variant") {
        event.preventDefault();
        this.setHighlight(
          this._highlight === row.dataset.mapHighlight
            ? null
            : row.dataset.mapHighlight,
        );
      }
    };

    list.addEventListener("mouseover", onOver);
    list.addEventListener("mouseout", onOut);
    list.addEventListener("focusin", onFocusIn);
    list.addEventListener("focusout", onFocusOut);
    list.addEventListener("click", onClick);
    this._cleanup.push(() => {
      list.removeEventListener("mouseover", onOver);
      list.removeEventListener("mouseout", onOut);
      list.removeEventListener("focusin", onFocusIn);
      list.removeEventListener("focusout", onFocusOut);
      list.removeEventListener("click", onClick);
    });
  },

  // --- dataset driven rendering ---------------------------------------------

  _applyDataset() {
    const raw =
      typeof this.el.dataset.mapPayload === "string"
        ? this.el.dataset.mapPayload
        : "";

    if (raw !== "" && raw !== this._payloadRaw) {
      const payload = parsePayload(raw);
      if (payload) {
        const action = nextMapAction(this._renderedRouteUuid, payload);
        this._renderedRouteUuid = payload.route_uuid;
        this._payloadRaw = raw;
        this._payload = payload;
        if (action === "refit") this._highlight = null;
        this._draw();
        if (action === "refit") this._fit();
      }
    }

    const rawContext =
      typeof this.el.dataset.mapContext === "string"
        ? this.el.dataset.mapContext
        : "";
    if (rawContext !== this._contextRaw) {
      this._contextRaw = rawContext;
      this._drawContext(rawContext === "" ? null : parseContext(rawContext));
    }

    this._applyColors(parseColors(this.el.dataset.mapColors));
  },

  _applyColors(colors) {
    const lineHex = lineColorFor(colors);
    this._lineColor = lineHex;

    this._paintLines();
    this._paintMarkers();
    this._paintSwatches();
  },

  _paintSwatches() {
    const stroke = swatchColorFor(this._lineColor);
    document
      .querySelectorAll(".route-map-swatch")
      .forEach((line) => line.setAttribute("stroke", stroke));
  },

  // Build every drawable path once per payload. Recolors restyle these same
  // layers, so a color keystroke never rebuilds geometry (or the view).
  _draw() {
    if (!this._L || !this._payload) return;

    this._sections.clearLayers();
    this._variants.clearLayers();
    this._lineLayers = [];

    const build = (layerGroup, pathLists, labelFor) => {
      for (const path of pathLists) {
        const under = this._L.polyline(path.latlngs, {
          color: CASING_COLOR,
          weight: CASING_WEIGHT,
          opacity: HIGHLIGHT_OPACITY,
        });
        const line = this._L.polyline(path.latlngs, {
          color: "#ffffff",
          weight: LINE_WEIGHT,
          opacity: HIGHLIGHT_OPACITY,
        });
        const label = labelFor(path);
        if (label) {
          line.bindTooltip(label, {
            permanent: true,
            direction: "top",
            className: "route-map-variant-label",
          });
        }
        under.addTo(layerGroup);
        line.addTo(layerGroup);
        this._lineLayers.push({ key: path.key, kind: path.kind, line, under });
      }
    };

    build(
      this._sections,
      (this._payload.patterns || []).flatMap((pattern) =>
        sectionPaths(pattern),
      ),
      () => null,
    );
    build(
      this._variants,
      (this._payload.imported_shape_variants || []).flatMap((variant) =>
        variantPaths(variant).map((path) => ({
          ...path,
          label: variant.label,
        })),
      ),
      (path) => path.label,
    );

    this._paintLines();
    this._paintMarkers();
    this._paintRows();
  },

  _paintLines() {
    const color = `#${this._lineColor}`;
    const casing = casingFor(this._lineColor);

    for (const entry of this._lineLayers) {
      const on = this._highlight === null || this._highlight === entry.key;
      const opacity = on ? HIGHLIGHT_OPACITY : DIM_OPACITY;

      entry.line.setStyle({
        color,
        weight: LINE_WEIGHT,
        opacity,
        dashArray: entry.kind === "dashed" ? DASH_ARRAY : null,
        lineCap: entry.kind === "dashed" ? "butt" : "round",
      });
      entry.under.setStyle({ color: casing, weight: CASING_WEIGHT, opacity });
    }

    this._paintContextLines();
  },

  // --- other-route context ---------------------------------------------------

  _viewportBounds() {
    if (!this._map) return null;
    const bounds = this._map.getBounds();
    return roundBounds({
      north: bounds.getNorth(),
      south: bounds.getSouth(),
      east: bounds.getEast(),
      west: bounds.getWest(),
    });
  },

  _pushContextViewport(bounds) {
    if (this._destroyed || typeof this.pushEvent !== "function") return;
    if (!bounds) return;
    if (sameViewportBounds(bounds, this._lastContextBounds)) return;

    this._lastContextBounds = bounds;
    this._pushEventTo(CONTEXT_VIEWPORT_EVENT, { enabled: true, bounds });
  },

  _pushEventTo(event, payload) {
    if (this._destroyed || typeof this.pushEvent !== "function") return;
    this.pushEvent(event, payload);
  },

  // Redraws the whole context layer from one parsed payload. The fit is never
  // touched: context is added to the operator's view, not a new one.
  _drawContext(context) {
    if (!this._L || !this._contexts) return;

    this._contexts.clearLayers();
    this._contextLineLayers = [];
    this._contextBadges = [];
    if (!context) {
      this._paintContextLines();
      return;
    }

    for (const route of context.routes || []) {
      const badge = contextBadge(route);
      const paths = contextRoutePaths(route);
      const inactive = route?.active === false;
      const opacity = inactive ? CONTEXT_INACTIVE_OPACITY : CONTEXT_OPACITY;

      for (const path of paths) {
        const hex = badge ? badge.background.slice(1) : DEFAULT_LINE_COLOR;
        const under = this._L.polyline(path.latlngs, {
          pane: CONTEXT_PANE,
          color: casingFor(hex),
          weight: CONTEXT_CASING_WEIGHT,
          opacity,
          interactive: false,
        });
        const line = this._L.polyline(path.latlngs, {
          pane: CONTEXT_PANE,
          color: `#${hex}`,
          weight: CONTEXT_LINE_WEIGHT,
          opacity,
          dashArray: inactive ? CONTEXT_DASH_ARRAY : null,
          interactive: false,
        });
        under.addTo(this._contexts);
        line.addTo(this._contexts);
        this._contextLineLayers.push({ line, under, opacity });
      }

      if (badge && paths.length) {
        const marker = this._L.marker(paths[0].latlngs[0], {
          pane: CONTEXT_PANE,
          interactive: false,
          keyboard: false,
          icon: this._L.divIcon({
            className: "route-map-context-badge",
            html: `<span style="background:${badge.background};color:${badge.color}">${escapeBadgeLabel(badge.label)}</span>`,
            iconSize: null,
          }),
        });
        marker.addTo(this._contexts);
        this._contextBadges.push(marker);
      }
    }

    this._paintContextLines();
  },

  // Highlighting a current-route pattern dims the context layer so the
  // selection still reads; clearing restores each entry's own opacity.
  _paintContextLines() {
    const dim = this._highlight !== null;

    for (const entry of this._contextLineLayers) {
      const opacity = dim ? CONTEXT_DIM_OPACITY : entry.opacity;
      entry.line.setStyle({ opacity });
      entry.under.setStyle({ opacity });
    }

    for (const marker of this._contextBadges) {
      marker.setOpacity(dim ? CONTEXT_DIM_OPACITY : 1);
    }
  },

  // --- highlight -------------------------------------------------------------

  setHighlight(id) {
    if (this._highlight === id) return;
    this._highlight = id;
    this._paintLines();
    this._paintMarkers();
    this._paintRows();
    this._showCard(id);
  },

  _paintMarkers() {
    if (!this._L || !this._markers) return;
    this._markers.clearLayers();

    const stroke =
      this._lineColor === WHITE ? SWATCH_FALLBACK : `#${this._lineColor}`;

    for (const marker of stopMarkers(
      this._payload?.patterns || [],
      this._highlight,
    )) {
      this._L
        .circleMarker(marker.latlng, {
          radius: marker.radius,
          color: stroke,
          weight: 2.5,
          fillOpacity: 1,
          fillColor: "#ffffff",
        })
        .bindTooltip(`Stop ${marker.stopId} (visit ${marker.position})`, {
          direction: "top",
        })
        .addTo(this._markers);
    }
  },

  _paintRows() {
    document
      .querySelectorAll(
        "#route-map-pattern-list [data-map-highlight], " +
          "#route-map-variant-list [data-map-highlight]",
      )
      .forEach((row) => {
        row.dataset.on = String(row.dataset.mapHighlight === this._highlight);
      });
  },

  _showCard(id) {
    const card = document.getElementById(CARD_ID);
    if (!card) return;

    const pattern = (this._payload?.patterns || []).find(
      (candidate) => candidate.route_pattern_id === id,
    );
    const variant = (this._payload?.imported_shape_variants || []).find(
      (candidate) => candidate.shape_id === id,
    );

    const body = pattern
      ? this._patternCard(pattern)
      : variant
        ? this._variantCard(variant)
        : null;
    if (!body) {
      card.hidden = true;
      card.textContent = "";
      return;
    }

    card.replaceChildren(...body);
    card.hidden = false;
  },

  _sectionNotes(pattern) {
    const endpoints = visitCoordinatesByPosition(pattern);
    let dashed = 0;
    let hidden = 0;
    const reasons = new Set();

    for (const section of pattern.sections || []) {
      if (section.status === "missing") {
        if (
          endpoints.get(section.from_position) &&
          endpoints.get(section.to_position)
        ) {
          dashed += 1;
        } else {
          hidden += 1;
        }
      } else if (section.status === "unavailable") {
        hidden += 1;
      }
      for (const unlocated of section.unlocated || []) {
        reasons.add(unlocatedPhrase(unlocated.reason));
      }
    }

    return { dashed, hidden, reasons: [...reasons] };
  },

  _patternCard(pattern) {
    const name = document.createElement("p");
    name.className = "font-[650] text-strong";
    name.textContent = pattern.route_pattern_name || pattern.route_pattern_id;

    const stops = (pattern.visits || []).length;
    const summary = document.createElement("p");
    summary.className = "text-muted";
    summary.textContent = `${stops} ${stops === 1 ? "stop" : "stops"}`;

    const { dashed, hidden, reasons } = this._sectionNotes(pattern);
    const notes = [];
    if (dashed) {
      notes.push(
        `${dashed} ${dashed === 1 ? "section" : "sections"} drawn straight: no path yet`,
      );
    }
    if (hidden) {
      notes.push(
        `${hidden} ${hidden === 1 ? "section" : "sections"} not shown: ${reasons.join(", ")}`,
      );
    }

    const children = [name, summary];
    for (const note of notes) {
      const p = document.createElement("p");
      p.className = "mt-1 text-warning-fg";
      p.textContent = note;
      children.push(p);
    }
    return children;
  },

  _variantCard(variant) {
    const name = document.createElement("p");
    name.className = "font-[650] text-strong";
    name.textContent = variant.label || `Variant ${variant.variant}`;

    const patterns = (variant.route_pattern_ids || []).length;
    const summary = document.createElement("p");
    summary.className = "text-muted";
    summary.textContent = `${patterns} ${patterns === 1 ? "pattern" : "patterns"}`;

    const children = [name, summary];
    if (variant.status !== "saved") {
      const p = document.createElement("p");
      p.className = "mt-1 text-warning-fg";
      const reasons = (variant.unlocated || []).map((entry) =>
        unlocatedPhrase(entry.reason),
      );
      p.textContent = `Not shown: ${reasons.join(", ")}`;
      children.push(p);
    }
    return children;
  },

  // --- view ------------------------------------------------------------------

  _fit() {
    if (!this._map || !this._payload) return;

    const latlngs = this._lineLayers.flatMap((entry) =>
      entry.line.getLatLngs(),
    );
    if (latlngs.length) {
      this._map.fitBounds(this._L.latLngBounds(latlngs), {
        padding: FIT_PADDING,
        maxZoom: FIT_MAX_ZOOM,
        animate: false,
      });
    }
  },

  _showHint() {
    const hint = document.getElementById(HINT_ID);
    if (!hint) return;

    hint.hidden = false;
    if (this._hintTimer) clearTimeout(this._hintTimer);
    this._hintTimer = setTimeout(() => {
      this._hintTimer = null;
      hint.hidden = true;
    }, HINT_MS);
  },

  _setTilesUnavailable(unavailable) {
    const banner = document.getElementById(TILES_UNAVAILABLE_ID);
    if (banner) banner.hidden = !unavailable;
  },
};

export default RouteDetailsMapHook;
