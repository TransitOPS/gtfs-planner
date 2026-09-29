/**
 * FlexAreaMap
 *
 * Owns every flex map: the list's "Where flex runs" card, the service page's
 * map (step 22) and the area editor's map (step 24, edited by points since
 * step 25). The server renders the hook root (`#flex-area-map` in the editor)
 * with a `.flex-map-stage` container inside it and, outside the root, the
 * toolbar and the panel; the root is `phx-update="ignore"`, so this hook owns
 * the stage for the life of the mount and tears every Leaflet object down in
 * destroyed().
 *
 * Protocol:
 *   hook → server  flex_map_ready {} → server → hook  flex_map:load {payload}
 *
 * Payload (built by `GtfsPlanner.Gtfs.Flex.map_payload/2` and the editor's own
 * `area_payload/1`):
 *   areas  [{id, geojson, role?}]  one stored area per entry. `role` is
 *                                  "selected" | "other" | "overlap" and adds
 *                                  that treatment; an entry without a role
 *                                  (the list, where every area it draws is
 *                                  equally in play) gets the plain one. The
 *                                  editor leaves its own candidate out while
 *                                  points are being edited: the hook draws the
 *                                  ring it is editing instead.
 *   routes [{id, color, coordinates}]  one line per route; `coordinates` are
 *                                  [lon, lat], converted with `toLatLng/1`.
 *   stops  [{id, name, lon, lat, hub}]  `hub` picks the connecting-stop glyph
 *                                  and its always-on label.
 *
 * Point editing (AC-12, step 25):
 *   server → hook  flex_map:mode {mode: "pan" | "edit" | "draw", ring?, vertices?}
 *                  Enter a mode. "edit" hands over the closed ring to edit;
 *                  "draw" starts an empty drawing; "pan" hands the map back to
 *                  the payload.
 *   server → hook  flex_map:ring {ring, vertices}
 *                  The server's own ring replaces the edited one (Simplify's
 *                  answer). It is one undo entry: Undo restores the detail.
 *   server → hook  flex_map:crossing {lon, lat, reason} — or nulls to clear.
 *                  The server's verdict on an edited ring; the marker names the
 *                  point and the panel carries the reason. A valid ring clears it.
 *   hook → server  flex_area_edited {ring}   the full closed ring, [lon, lat],
 *                  at most once per 300 ms burst.
 *   hook → server  flex_area_simplify {}
 *
 * The ring maths, the history and the 300 ms coalescing are the pure module
 * `flex_area_edit.js`; this hook owns the map, the handles and the keyboard
 * (EV-20 vs. the browser case).
 *
 * The basemap is streets, through the app's own Geoapify proxy, so a flex area
 * is read against the roads it covers and no key reaches the browser. A failed
 * tile changes nothing here: the areas, lines and stops stay drawn over a blank
 * background, which is what the card shows in the browser tests.
 *
 * Leaflet keeps its default zoom control (keyboard reachable) and its
 * attribution control (the tile credit stays visible). `scrollWheelZoom` is off
 * so a page scroll over the map scrolls the page.
 */

import { addStreetBasemap, STREET_MAX_ZOOM } from "./basemap_layers";
import { fromLatLng, nearestEdgeIndex, toLatLng } from "./alignment_geometry";
import {
  closeRing,
  createHistory,
  createPushBuffer,
  insertAt,
  movePoint,
  openRing,
  removePoint,
  sameRing,
} from "./flex_area_edit";

// A world view before any payload lands. The payload's own fit replaces it
// immediately; a version with nothing drawable keeps it.
const WORLD_CENTER = [20, 0];
const WORLD_ZOOM = 2;
const MIN_ZOOM = 2;
const FIT_PADDING = [24, 24];
// The street tiles stop here, so a fit must not ask for more.
const FIT_MAX_ZOOM = STREET_MAX_ZOOM;

const STAGE_SELECTOR = ".flex-map-stage";

// Area treatments, by the prototype's zone classes (`.zone`, `.is-selected`,
// `.is-other`, `.zone.is-overlap`). The plain class is what the reference's own
// list draws; the role modifiers arrive with the service page and the editor.
const AREA_CLASS = "flex-map-area";
const AREA_ROLE_CLASSES = {
  selected: "flex-map-area--selected",
  other: "flex-map-area--other",
  overlap: "flex-map-area--overlap",
};
// The ring being edited and the same ring once the server refused it: the
// prototype's `.zone.is-draft` and `.zone.is-error`.
const DRAFT_CLASS = "flex-map-area--draft";
const ERROR_CLASS = "flex-map-area--error";
// The id the editor's payload gives its own candidate; the hook draws that
// area itself while points are being edited.
const CANDIDATE_ID = "area-candidate";

const ROUTE_WEIGHT = 3;
// The legend's "Fixed route" swatch and the app's own line colour; a route
// without a `route_color` in the feed is drawn with it.
const ROUTE_FALLBACK_COLOR = "#0d737d";

// The prototype's stop glyph: a white disc with a dark ring, and, for a
// connecting stop, a dark core and its always-on name.
const STOP_RADIUS = 4.5;
const STOP_WEIGHT = 1.6;
const HUB_RADIUS = 6.5;
const HUB_WEIGHT = 2.4;
const HUB_CORE_RADIUS = 2.5;
const STOP_FILL = "#ffffff";
const STOP_COLOR = "#0a1330";
const LABEL_OFFSET = [10, 0];

// The prototype's point tools: a 9 px square handle (drawn in a larger,
// focusable box), a 3.5 px midpoint circle and a 9 px crossing mark.
const HANDLE_ICON_SIZE = 22;
const MIDPOINT_RADIUS = 3.5;
const PLACED_RADIUS = 4.5;
const CROSSING_ICON_SIZE = 22;

// The reference's 300 ms rule: one push per burst of edits.
const EDIT_DEBOUNCE_MS = 300;

const ARROW_DIRECTIONS = {
  ArrowUp: "north",
  ArrowDown: "south",
  ArrowLeft: "west",
  ArrowRight: "east",
};

const EDIT_HINT =
  "Drag a point to move it · Click the boundary to add one · Arrows move 20 m (100 m with Shift) · Delete removes it";
const DRAW_HINT = "Click the map to place points around the area";
const DRAWN_HINT = "Boundary drawn · Click Edit points to adjust it";

/** The area's class list for its role; an unknown or absent role is the plain one. */
export function areaClassName(role) {
  const modifier = AREA_ROLE_CLASSES[role];
  return modifier ? `${AREA_CLASS} ${modifier}` : AREA_CLASS;
}

/** `[lon, lat]` storage order to Leaflet's `[lat, lng]`; the one axis swap here (INV-1). */
function latLngs(coordinates) {
  if (!Array.isArray(coordinates)) return [];
  return coordinates.filter(Array.isArray).map(toLatLng);
}

// A payload may carry a geometry the server drew from a stored area; anything
// else (a null, a string) is skipped rather than handed to Leaflet.
function areaGeometry(area) {
  return area && typeof area === "object" && area.geojson ? area.geojson : null;
}

// One Leaflet icon per point handle: the prototype's white square with the
// action-coloured border, magenta while the point is the selected one.
function handleIcon(leaflet, picked) {
  return leaflet.divIcon({
    className: "flex-area-handle",
    iconSize: [HANDLE_ICON_SIZE, HANDLE_ICON_SIZE],
    iconAnchor: [HANDLE_ICON_SIZE / 2, HANDLE_ICON_SIZE / 2],
    html: `<span class="flex-area-handle-dot${picked ? " is-picked" : ""}"></span>`,
  });
}

// The prototype's crossing mark: a pale red disc with a dark X.
function crossingIcon(leaflet) {
  return leaflet.divIcon({
    className: "flex-area-crossing",
    iconSize: [CROSSING_ICON_SIZE, CROSSING_ICON_SIZE],
    iconAnchor: [CROSSING_ICON_SIZE / 2, CROSSING_ICON_SIZE / 2],
    html: '<svg width="22" height="22" viewBox="0 0 22 22" aria-hidden="true"><circle class="flex-area-crossing-disc" cx="11" cy="11" r="9"/><path class="flex-area-crossing-x" d="M7.5 7.5L14.5 14.5M14.5 7.5L7.5 14.5"/></svg>',
  });
}

function stopPoint(stop) {
  if (!stop) return null;

  const lon = Number(stop.lon);
  const lat = Number(stop.lat);
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;

  // The map draws a stop's own name, its point and whether it is a connecting
  // stop; the payload's id stays the server's identity for the row.
  return { name: stop.name || "", lat, lon, hub: Boolean(stop.hub) };
}

const FlexAreaMap = {
  mounted() {
    this._leaflet = null;
    this._map = null;
    this._areas = [];
    this._layers = [];

    // Point editing (step 25): the ring the hook owns, its history, the draw
    // in progress and every layer they use. Nothing below is touched until the
    // server asks for a mode, so a read-only map pays nothing for it.
    this._mode = "pan";
    this._ring = null;
    this._ringLayer = null;
    this._editLayers = [];
    this._handles = [];
    this._midpoints = [];
    this._drawing = [];
    this._drawPoints = [];
    this._drawLine = null;
    this._drawFinished = false;
    this._focusIndex = 0;
    this._dragStart = null;
    this._crossing = null;
    this._crossingLayer = null;
    this._hint = null;
    this._history = createHistory();
    this._pushes = createPushBuffer(EDIT_DEBOUNCE_MS, (ring) =>
      this.pushEvent("flex_area_edited", { ring }),
    );

    const stage = this.el.querySelector(STAGE_SELECTOR);
    if (!stage) return;

    const leaflet = window.L;
    if (!leaflet) return;
    this._leaflet = leaflet;

    // A remount can reuse a container the previous hook's destroyed() did not
    // release; Leaflet refuses to initialize a container it still owns.
    if (stage._leaflet_id) {
      stage._leaflet_id = undefined;
      stage.innerHTML = "";
    }

    const map = leaflet.map(stage, {
      center: WORLD_CENTER,
      zoom: WORLD_ZOOM,
      minZoom: MIN_ZOOM,
      maxZoom: STREET_MAX_ZOOM,
      // A page scroll over the card must scroll the page, not zoom the map.
      // Leaflet keeps its zoom control, its attribution control and its
      // keyboard panning (arrow keys, +/−) at their defaults.
      scrollWheelZoom: false,
    });
    this._map = map;

    addStreetBasemap(leaflet, map);

    this.handleEvent("flex_map:load", (payload) => this._load(payload));
    this.handleEvent("flex_map:mode", (payload) => this._setMode(payload));
    this.handleEvent("flex_map:ring", (payload) => this._applyServerRing(payload));
    this.handleEvent("flex_map:crossing", (payload) => this._setCrossing(payload));

    // The toolbar's client-side buttons (Undo, Redo, Previous and Next point)
    // dispatch a DOM action, the way the alignment editor's own detail buttons
    // do: the history and the focus live in this hook, not in the socket.
    this._onAction = (event) => this._handleAction(event?.detail?.action);
    this.el.addEventListener("flex-area:action", this._onAction);
    this._onKeyDown = (event) => this._handleKey(event);
    document.addEventListener("keydown", this._onKeyDown);

    this.pushEvent("flex_map_ready", {});
  },

  destroyed() {
    document.removeEventListener("keydown", this._onKeyDown);
    this.el?.removeEventListener?.("flex-area:action", this._onAction);
    this._pushes.cancel();

    if (this._hint) {
      this._hint.remove();
      this._hint = null;
    }

    if (this._map) {
      try {
        this._map.remove();
      } catch (_) {
        // LiveView already remounted a hook on this container.
      }
      this._map = null;
    }

    this._layers = [];
    this._areas = [];
    this._editLayers = [];
    this._handles = [];
    this._midpoints = [];
    this._drawPoints = [];
    this._ringLayer = null;
    this._drawLine = null;
    this._crossingLayer = null;
    this._crossing = null;
    this._ring = null;
    this._leaflet = null;
  },

  // A reconnect keeps the hook-owned ring: a push still waiting in the debounce
  // window is delivered rather than lost with the socket.
  reconnected() {
    if (this._destroyed) return;
    this._pushes.flush();
  },

  // --- Drawing the server's payload ------------------------------------------

  // Every load replaces what the previous one drew: the map is a view of the
  // server's payload, not a growing stack of layers. The ring being edited is
  // the hook's own and survives the load (`_editLayers`).
  _load(payload) {
    if (!this._map || !payload || typeof payload !== "object") return;

    this._clear();
    this._drawAreas(Array.isArray(payload.areas) ? payload.areas : []);
    this._drawRoutes(Array.isArray(payload.routes) ? payload.routes : []);
    this._drawStops(Array.isArray(payload.stops) ? payload.stops : []);
    this._fit();
  },

  _clear() {
    this._layers.forEach((layer) => this._map.removeLayer(layer));
    this._layers = [];
    this._areas = [];
  },

  _add(layer) {
    layer.addTo(this._map);
    this._layers.push(layer);
    return layer;
  },

  // One geoJSON layer per stored area, in payload order: the polygon's ring
  // order (holes included) is the server's GeoJSON, and `fill-rule: evenodd`
  // is Leaflet's own default for a path.
  _drawAreas(areas) {
    areas.forEach((area) => {
      const geojson = areaGeometry(area);
      if (!geojson) return;

      const layer = this._add(
        this._leaflet.geoJSON(geojson, {
          className: areaClassName(area.role),
          interactive: false,
        }),
      );

      const bounds = typeof layer.getBounds === "function" ? layer.getBounds() : null;
      if (bounds && (!bounds.isValid || bounds.isValid())) this._areas.push(bounds);
    });
  },

  _drawRoutes(routes) {
    routes.forEach((route) => {
      if (!route || typeof route !== "object") return;

      const points = latLngs(route.coordinates);
      if (points.length < 2) return;

      this._add(
        this._leaflet.polyline(points, {
          color: route.color || ROUTE_FALLBACK_COLOR,
          weight: ROUTE_WEIGHT,
          interactive: false,
        }),
      );
    });
  },

  _drawStops(stops) {
    stops.forEach((raw) => {
      const stop = stopPoint(raw);
      if (!stop) return;

      const centre = [stop.lat, stop.lon];
      const options = stop.hub
        ? { radius: HUB_RADIUS, weight: HUB_WEIGHT }
        : { radius: STOP_RADIUS, weight: STOP_WEIGHT };

      const marker = this._add(
        this._leaflet.circleMarker(centre, {
          ...options,
          color: STOP_COLOR,
          fillColor: STOP_FILL,
          fillOpacity: 1,
          interactive: false,
        }),
      );

      if (!stop.hub) return;

      // The connecting stop's core, then its name: the map is read without a
      // hover on a touch screen, so a hub's label is permanent.
      this._add(
        this._leaflet.circleMarker(centre, {
          radius: HUB_CORE_RADIUS,
          stroke: false,
          fillColor: STOP_COLOR,
          fillOpacity: 1,
          interactive: false,
        }),
      );

      // Stop names come from imported feeds; Leaflet writes a string tooltip
      // as HTML, so the name goes in as a text node.
      const label = document.createElement("span");
      label.textContent = stop.name;

      marker.bindTooltip(label, {
        permanent: true,
        direction: "right",
        offset: LABEL_OFFSET,
        className: "flex-map-stop-label",
      });
    });
  },

  // The frame is the flex areas when any is stored (the reference fits its
  // service shapes); a version whose areas are all underived falls back to its
  // route lines and connecting stops, and a version with nothing drawable keeps
  // the world view. While a ring is being edited the ring is the frame, or a
  // payload arriving mid-edit would move the map under the user's hands.
  _fit() {
    if (!this._map) return;

    if (this._mode !== "pan" && this._ring) {
      this._fitRing();
      return;
    }

    const bounds = this._leaflet.latLngBounds([]);
    this._areas.forEach((areaBounds) => bounds.extend(areaBounds));

    if (!bounds.isValid()) {
      this._layers.forEach((layer) => {
        if (typeof layer.getLatLng === "function") bounds.extend(layer.getLatLng());
        else if (typeof layer.getBounds === "function") bounds.extend(layer.getBounds());
      });
    }

    if (!bounds.isValid()) return;

    this._map.fitBounds(bounds, {
      padding: FIT_PADDING,
      maxZoom: FIT_MAX_ZOOM,
      animate: !prefersReducedMotion(),
    });
  },

  _fitRing() {
    if (!this._map || !this._ring || this._ring.length < 2) return;

    this._map.fitBounds(this._leaflet.latLngBounds(latLngs(this._ring)), {
      padding: FIT_PADDING,
      maxZoom: FIT_MAX_ZOOM,
      animate: !prefersReducedMotion(),
    });
  },

  // --- The editing modes -----------------------------------------------------

  // Enter the mode the server asks for. "edit" arrives with the ring to edit,
  // "draw" starts empty and "pan" hands the map back to the payload.
  _setMode(payload) {
    if (!this._map || !this._leaflet || this._destroyed) return;

    const requested = payload && payload.mode;
    const ring = payload && payload.ring ? closeRing(payload.ring) : null;
    const mode = requested === "edit" && ring && ring.length >= 4 ? "edit" : requested;

    if (mode === "edit") {
      this._mode = "edit";
      this._ring = ring;
      this._history.reset(ring);
      this._focusIndex = 0;
    } else if (mode === "draw") {
      this._mode = "draw";
      this._ring = null;
      this._drawing = [];
      this._drawFinished = false;
      this._history.reset(null);
    } else {
      this._mode = "pan";
      this._ring = null;
      this._drawing = [];
      this._drawFinished = false;
      this._history.reset(null);
    }

    this._clearCrossing();
    this._renderEditLayers();
    this._fit();
  },

  // The server's own ring (Simplify's answer) replaces the edited one as one
  // undo entry, so Undo restores the detail the server removed.
  _applyServerRing(payload) {
    if (this._destroyed || !this._map) return;

    const ring = payload && payload.ring ? closeRing(payload.ring) : null;
    if (this._mode === "pan" || !ring || ring.length < 4) return;
    if (sameRing(this._ring, ring)) return;

    this._history.push(ring);
    this._ring = this._history.ring();
    this._focusIndex = Math.min(this._focusIndex, openRing(ring).length - 1);
    this._clearCrossing();
    this._renderEditLayers();
  },

  // The server's verdict on the ring just pushed: a marker where the boundary
  // crosses itself, or no marker at all (null coordinates) for a valid ring.
  _setCrossing(payload) {
    if (this._destroyed || !this._map || !this._leaflet) return;

    const lon = payload ? Number(payload.lon) : NaN;
    const lat = payload ? Number(payload.lat) : NaN;

    if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
      this._clearCrossing();
      return;
    }

    this._clearCrossing();

    this._crossing = { lon, lat, reason: payload.reason || "" };
    this._crossingLayer = this._leaflet
      .marker([lat, lon], {
        icon: crossingIcon(this._leaflet),
        interactive: false,
        zIndexOffset: 800,
      })
      .addTo(this._map);
    this._paintRing();
    this._updateHint();
  },

  _clearCrossing() {
    if (this._crossingLayer) {
      this._map.removeLayer(this._crossingLayer);
      this._crossingLayer = null;
    }

    this._crossing = null;
    this._paintRing();
  },

  // --- The edited ring's layers ----------------------------------------------

  _addEdit(layer) {
    layer.addTo(this._map);
    this._editLayers.push(layer);
    return layer;
  },

  _clearEditLayers() {
    this._editLayers.forEach((layer) => this._map.removeLayer(layer));
    this._editLayers = [];
    this._ringLayer = null;
    this._drawLine = null;
    this._handles = [];
    this._midpoints = [];
    this._drawPoints = [];
  },

  _renderEditLayers() {
    this._clearEditLayers();
    this.el.dataset.mode =
      this._mode === "draw" ? "draw" : this._mode === "edit" ? "edit" : "";

    if (this._mode === "edit" && this._ring) {
      this._drawRing();
      this._drawMidpoints();
      this._drawHandles();
    } else if (this._mode === "draw" && this._ring) {
      this._drawRing();
    } else if (this._mode === "draw") {
      this._drawDrawing();
    }

    this._syncToolbar();
    this._updateHint();
  },

  // The ring being edited, drawn as the prototype's draft zone; clicking it
  // inserts a point on the nearest edge.
  _drawRing() {
    const layer = this._addEdit(
      this._leaflet.polygon(latLngs(this._ring), {
        className: `${AREA_CLASS} ${DRAFT_CLASS}`,
        interactive: true,
      }),
    );

    layer.on("click", (event) => this._insertOnNearestEdge(event.latlng));
    this._ringLayer = layer;
    this._paintRing();
  },

  // The prototype's small circles: one insert affordance per edge.
  _drawMidpoints() {
    if (!this._ring) return;

    const vertices = openRing(this._ring);

    this._midpoints = vertices.map((position, index) => {
      const next = vertices[(index + 1) % vertices.length];
      const middle = [(position[0] + next[0]) / 2, (position[1] + next[1]) / 2];
      const marker = this._leaflet.circleMarker(toLatLng(middle), {
        radius: MIDPOINT_RADIUS,
        className: "flex-area-midpoint",
        interactive: true,
      });

      marker.on("click", () => this._insertVertex(index, middle));
      marker.addTo(this._map);
      return marker;
    });
  },

  // The prototype's square handles; the selected one carries `is-picked`, and
  // each is a tab stop whose own keydown moves or removes it.
  _drawHandles() {
    if (!this._ring) return;

    const vertices = openRing(this._ring);

    this._handles = vertices.map((position, index) => {
      const marker = this._leaflet.marker(toLatLng(position), {
        draggable: true,
        keyboard: true,
        icon: handleIcon(this._leaflet, index === this._focusIndex),
        zIndexOffset: 600,
      });

      marker.on("dragstart", () => this._beginDrag());
      marker.on("drag", () => this._dragTo(index, marker));
      marker.on("dragend", () => this._endDrag());
      marker.addTo(this._map);

      // Leaflet's keyboard markers are plain tabbable divs, so a DOM keydown
      // owns arrows and Delete per handle.
      marker
        .getElement?.()
        ?.addEventListener?.("keydown", (event) => this._onHandleKey(index, event));
      return marker;
    });
  },

  _paintRing() {
    const element = this._ringLayer?.getElement?.();
    if (!element) return;

    element.classList.toggle(DRAFT_CLASS, !this._crossing);
    element.classList.toggle(ERROR_CLASS, Boolean(this._crossing));
  },

  // --- Editing one vertex ----------------------------------------------------

  _beginDrag() {
    this._dragStart = this._ring;
  },

  // Live drag feedback: the ring follows the handle without recording history;
  // `dragend` records one entry for the whole gesture.
  _dragTo(index, marker) {
    if (this._mode !== "edit" || !this._ring) return;

    const vertices = openRing(this._ring);
    if (index < 0 || index >= vertices.length) return;

    vertices[index] = fromLatLng(marker.getLatLng());
    this._ring = closeRing(vertices);
    if (this._ringLayer) this._ringLayer.setLatLngs(latLngs(this._ring));
  },

  _endDrag() {
    if (this._mode !== "edit" || !this._dragStart) {
      this._dragStart = null;
      return;
    }

    const before = this._dragStart;
    this._dragStart = null;

    if (sameRing(before, this._ring)) return;

    this._history.push(this._ring);
    this._ring = this._history.ring();
    this._renderEditLayers();
    this._schedulePush();
  },

  _insertOnNearestEdge(latlng) {
    if (this._mode !== "edit" || !this._ring || !latlng) return;

    // `nearestEdgeIndex` counts the insertion position (edge i inserts at
    // i + 1); `insertAt` takes the edge's first vertex.
    const insertion = nearestEdgeIndex(this._map, latlng, latLngs(this._ring));
    this._insertVertex(Math.max(insertion - 1, 0), fromLatLng(latlng));
  },

  _insertVertex(edgeIndex, position) {
    if (this._mode !== "edit" || !this._ring) return;

    const next = insertAt(this._ring, edgeIndex, position);
    if (sameRing(next, this._ring)) return;

    this._ring = next;
    this._history.push(next);
    this._focusIndex = Math.min(edgeIndex + 1, openRing(next).length - 1);
    this._renderEditLayers();
    this._schedulePush();
  },

  _moveVertex(index, direction, shift) {
    if (this._mode !== "edit" || !this._ring) return;

    const next = movePoint(this._ring, index, direction, { shift });
    if (sameRing(next, this._ring)) return;

    this._ring = next;
    this._history.push(next);
    this._renderEditLayers();
    this._focusHandle(index);
    this._schedulePush();
  },

  _removeVertex(index) {
    if (this._mode !== "edit" || !this._ring) return;

    const next = removePoint(this._ring, index);
    if (sameRing(next, this._ring)) return;

    this._ring = next;
    this._history.push(next);
    this._focusIndex = Math.min(index, openRing(next).length - 1);
    this._renderEditLayers();
    this._focusHandle(this._focusIndex);
    this._schedulePush();
  },

  _undoRing() {
    if (this._mode === "pan") return;

    const ring = this._history.undo();
    if (!ring || ring.length < 4) return;

    this._ring = ring;
    this._renderEditLayers();
    this._schedulePush();
  },

  _redoRing() {
    if (this._mode === "pan") return;

    const ring = this._history.redo();
    if (!ring || ring.length < 4) return;

    this._ring = ring;
    this._renderEditLayers();
    this._schedulePush();
  },

  // --- Draw mode --------------------------------------------------------------

  _drawDrawing() {
    const points = this._drawing.map(toLatLng);

    if (points.length >= 2) {
      this._drawLine = this._addEdit(
        this._leaflet.polyline(points, {
          className: "flex-map-draw-line",
          interactive: false,
        }),
      );
    }

    if (this._drawing.length >= 3) {
      this._addEdit(
        this._leaflet.polygon(latLngs([...this._drawing, this._drawing[0]]), {
          className: `${AREA_CLASS} ${DRAFT_CLASS}`,
          interactive: false,
        }),
      );
    }

    this._drawPoints = this._drawing.map((position, index) => {
      const first = index === 0;
      const marker = this._leaflet.circleMarker(toLatLng(position), {
        radius: PLACED_RADIUS,
        className: first ? "flex-area-draw-point is-picked" : "flex-area-draw-point",
        interactive: first,
      });

      if (first) marker.on("click", () => this._finishDraw());
      marker.addTo(this._map);
      return marker;
    });

    this._bindDrawClick();
  },

  _bindDrawClick() {
    if (this._drawClickBound || !this._map) return;

    this._drawClickBound = true;
    this._map.on("click", (event) => this._onDrawClick(event));
  },

  _onDrawClick(event) {
    if (this._mode !== "draw" || !event?.latlng) return;
    // The first point closes the ring; its own handler owns that click.
    if (event.originalEvent?.target?.closest?.(".flex-area-draw-point")) return;

    if (this._drawFinished) this._startOver();

    this._drawing.push(fromLatLng(event.latlng));
    this._renderEditLayers();
  },

  _removeLastDrawPoint() {
    if (this._mode !== "draw" || this._drawing.length === 0) return;

    this._drawing.pop();
    this._renderEditLayers();
  },

  // A click on the first point, or Enter: three points make a ring, and the
  // server measures it (one push for the whole drawing).
  _finishDraw() {
    if (this._mode !== "draw" || this._drawing.length < 3 || this._drawFinished) return;

    this._ring = closeRing(this._drawing);
    this._drawing = [];
    this._drawFinished = true;
    this._history.reset(this._ring);
    this._renderEditLayers();
    this._schedulePush();
    this._pushes.flush();
  },

  _startOver() {
    this._ring = null;
    this._drawing = [];
    this._drawFinished = false;
    this._history.reset(null);
  },

  // --- The toolbar ------------------------------------------------------------

  // Draw, Pan and Edit points are server events (`phx-click`); Undo, Redo and
  // the point walk are the hook's own, because the history and the handle focus
  // never leave the browser.
  _handleAction(action) {
    switch (action) {
      case "undo":
        this._undoRing();
        break;
      case "redo":
        this._redoRing();
        break;
      case "previous_point":
        this._focusStep(-1);
        break;
      case "next_point":
        this._focusStep(1);
        break;
      default:
        break;
    }
  },

  _focusStep(delta) {
    const count = this._handles.length;
    if (this._mode !== "edit" || count === 0) return;

    this._focusIndex = (this._focusIndex + delta + count) % count;
    this._paintFocus();
    this._focusHandle(this._focusIndex);
  },

  _focusHandle(index) {
    const marker = this._handles[index];
    const element = marker?.getElement?.();
    if (!element) return;

    const latlng = marker.getLatLng?.();
    if (latlng && this._map?.panInside) this._map.panInside(latlng, { padding: FIT_PADDING });
    element.focus?.();
  },

  _paintFocus() {
    this._handles.forEach((marker, index) => {
      const dot = marker?.getElement?.()?.querySelector?.(".flex-area-handle-dot");
      if (dot) dot.classList.toggle("is-picked", index === this._focusIndex);
    });
  },

  // Undo/Redo and the point walk are hook state, so their buttons' enabled
  // state follows it. The buttons themselves are the server's DOM.
  _syncToolbar() {
    const editing = this._mode === "edit";
    const undo = document.getElementById("area-undo");
    const redo = document.getElementById("area-redo");
    const previous = document.getElementById("area-prev-point");
    const next = document.getElementById("area-next-point");
    const simplify = document.getElementById("area-simplify");

    if (undo) undo.disabled = !(editing && this._history.canUndo());
    if (redo) redo.disabled = !(editing && this._history.canRedo());
    if (previous) previous.disabled = !(editing && this._handles.length > 0);
    if (next) next.disabled = !(editing && this._handles.length > 0);

    // Simplify is the server's own call, but a ring still inside the 300 ms
    // window must reach the server before it simplifies.
    if (simplify && !this._simplifyWired) {
      this._simplifyWired = true;
      simplify.addEventListener("click", () => this._pushes.flush(), { capture: true });
    }
  },

  _updateHint() {
    const hint = this._hintElement();
    if (!hint) return;

    const text = this._hintText();
    hint.textContent = text;
    hint.hidden = text === "";
  },

  _hintElement() {
    if (this._hint) return this._hint;

    const hint = document.createElement("div");
    hint.className = "flex-map-hint";
    hint.setAttribute("role", "status");
    hint.hidden = true;
    this.el.appendChild(hint);
    this._hint = hint;
    return hint;
  },

  _hintText() {
    if (this._mode === "pan") return "";
    if (this._mode === "draw") {
      if (this._drawFinished || this._ring) return DRAWN_HINT;
      if (this._drawing.length === 0) return DRAW_HINT;
      return `${this._drawing.length} ${this._drawing.length === 1 ? "point" : "points"} · Click the first point or press Enter to finish`;
    }

    const size = this._ring ? openRing(this._ring).length : 0;
    const selected = size === 0 ? "" : ` · Point ${this._focusIndex + 1} of ${size} selected`;
    return `${EDIT_HINT}${selected}`;
  },

  // --- The keyboard -----------------------------------------------------------

  // Ctrl/⌘Z and the draw keys work wherever focus sits inside the map or its
  // toolbar; the focused handle's own listener owns arrows and Delete.
  _handleKey(event) {
    if (this._mode === "pan" || !this._inScope()) return;

    const key = event.key;

    if ((event.ctrlKey || event.metaKey) && (key === "z" || key === "Z")) {
      event.preventDefault();
      if (event.shiftKey) this._redoRing();
      else this._undoRing();
      return;
    }

    if (this._mode !== "draw") return;

    if (key === "Enter") {
      event.preventDefault();
      this._finishDraw();
    } else if (key === "Backspace") {
      event.preventDefault();
      this._removeLastDrawPoint();
    } else if (key === "Escape") {
      event.preventDefault();
      this._startOver();
      this._renderEditLayers();
    }
  },

  _inScope() {
    const active = document.activeElement;
    if (!active) return false;
    if (this.el.contains(active)) return true;

    const toolbar = document.getElementById("flex-area-tools");
    return Boolean(toolbar && toolbar.contains(active));
  },

  _onHandleKey(index, event) {
    if (this._mode !== "edit") return;

    const key = event.key;

    if (ARROW_DIRECTIONS[key]) {
      event.preventDefault();
      event.stopPropagation();
      this._focusIndex = index;
      this._moveVertex(index, ARROW_DIRECTIONS[key], event.shiftKey);
      return;
    }

    if (key === "Delete" || key === "Backspace") {
      event.preventDefault();
      event.stopPropagation();
      this._removeVertex(index);
    }
  },
};

function prefersReducedMotion() {
  return Boolean(
    typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  );
}

export default FlexAreaMap;
