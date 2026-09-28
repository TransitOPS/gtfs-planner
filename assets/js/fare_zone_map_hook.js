/**
 * FareZoneMap
 *
 * Owns the fare-zone map in the Zones tab. The server renders the root's static
 * markup (`#fare-zone-map`, `phx-update="ignore"`); this hook binds its controls
 * and draws the version's boardable stops.
 *
 * Protocol (spec.md › Map hook protocol):
 *   hook → server  fare_zone_map_ready {} → reply {points, zones, selected, filter}
 *   hook → server  select_stops {ids}, toggle_stop {id}, map_unavailable {reason}
 *   server → hook  fare_zone_snapshot, fare_zone_selection,
 *                  fare_zone_points_changed, fare_zone_zones, fare_zone_filter
 *
 * Every mount hydrates from the `fare_zone_map_ready` reply (or a later
 * `fare_zone_snapshot`) alone and keeps no state outside its own instance, so a
 * remounted or retried map never depends on deltas an earlier mount received
 * (CR-8).
 *
 * Selectors the server renders inside the root:
 *   [data-map-mode="select"] / [data-map-mode="pan"]  mode buttons (aria-pressed)
 *   [data-map-zoom="in"] / [data-map-zoom="out"]      zoom buttons
 *   [data-map-fit]                                    fit to the drawn points
 *   [data-map-hint]                                   hint text for the mode
 *   [data-map-canvas]                                 Leaflet container; the hook
 *                                                     writes data-map-state,
 *                                                     data-point-count and
 *                                                     data-selected-count on it
 */

// One constant so the basemap can be switched in one place (PM-13). Tiles come
// from the existing authenticated Geoapify proxy; no key reaches the browser.
const TILE_URL = "/map/tiles/osm-bright/{z}/{x}/{y}";
const TILE_ATTRIBUTION =
  "© OpenStreetMap contributors © OpenMapTiles © Geoapify";

// Leaflet needs some view before the handshake reply lands; the reply's fit
// replaces it immediately. Step 23 renders no initial-view data attributes.
const DEFAULT_CENTER = [0, 0];
const DEFAULT_ZOOM = 2;
const MIN_ZOOM = 2;
const MAX_ZOOM = 19;
const FIT_PADDING = [24, 24];

const LABEL_PANE = "fareZoneMapLabels";
// Above the overlay pane (400) and below the shadow pane (500): the ID is
// printed inside the marker circle the overlay pane draws.
const LABEL_PANE_Z_INDEX = "450";
const LABEL_MIN_ZOOM = 14;
const LABEL_FONT = "600 11px system-ui, sans-serif";
const LABEL_OFFSET_Y = 1;

// Prototype marker treatment: zone-coloured stroke on a white fill, and a
// magenta ring that reads selection independently of colour.
const MARKER_RADIUS = 12;
const MARKER_WEIGHT = 2.5;
const SELECTION_RADIUS = 18;
const SELECTION_WEIGHT = 3;
const SELECTION_COLOR = "#c81870";
const UNASSIGNED_COLOR = "#586479";
const MARKER_FILL = "#ffffff";
const DIM_OPACITY = 0.35;

const SELECT_BOX_BORDER = "#c81870";
const SELECT_BOX_FILL = "rgba(200, 24, 112, 0.11)";
const SELECT_BOX_Z_INDEX = "800";
// A shorter drag is a click on the map, not a selection box.
const DRAG_THRESHOLD_PX = 4;

const HINT_SELECT =
  "Click stops or drag a box to select. The box does not create a zone boundary.";
const HINT_PAN = "Drag the map to move. Use + and − to zoom.";

const STATE_INITIALIZING = "initializing";
const STATE_READY = "ready";
const STATE_UNAVAILABLE = "unavailable";

/**
 * The marker's two-character zone label. `nil` (unassigned) reads "–"; an ID
 * longer than two characters keeps its first two characters and an ellipsis.
 * Display only: the exact bytes stay in the tooltip copy.
 */
export function markerLabel(zoneId) {
  if (zoneId === null || zoneId === undefined || zoneId === "") return "–";
  const id = String(zoneId);
  return id.length > 2 ? `${id.slice(0, 2)}…` : id;
}

/**
 * IDs of the points inside a box built from two projected container corners.
 * The corners may arrive in either drag direction and both edges are inclusive.
 * `points` carry the same `lat`/`lon` the map currently projects the corners
 * to, so a box drawn after a pan or zoom compares the coordinates the map is
 * showing rather than stale container pixels.
 */
export function idsInBounds(points, bounds) {
  if (!Array.isArray(points) || !Array.isArray(bounds)) return [];
  const [first, second] = bounds;
  if (!first || !second) return [];

  const latMin = Math.min(first.lat, second.lat);
  const latMax = Math.max(first.lat, second.lat);
  const lonMin = Math.min(first.lon, second.lon);
  const lonMax = Math.max(first.lon, second.lon);

  return points
    .filter(
      (point) =>
        point &&
        point.lat >= latMin &&
        point.lat <= latMax &&
        point.lon >= lonMin &&
        point.lon <= lonMax,
    )
    .map((point) => point.id);
}

// Wire shape from `FareZones.list_stop_points/2`:
//   [id, stop_id, stop_name, lat, lon, zone_id, parent_station]
function normalizePoint(row) {
  if (!Array.isArray(row)) return null;

  const [id, stopId, name, lat, lon, zoneId, parentStation] = row;
  if (id === undefined || !Number.isFinite(lat) || !Number.isFinite(lon)) {
    return null;
  }

  return {
    id,
    stopId,
    name,
    lat,
    lon,
    zoneId: zoneId === undefined ? null : zoneId,
    parentStation: parentStation === undefined ? null : parentStation,
  };
}

function normalizeFilter(filter) {
  if (!filter || typeof filter !== "object") return { kind: "all", zone_id: null };
  if (filter.kind === "zone" || filter.kind === "unassigned") {
    return { kind: filter.kind, zone_id: filter.zone_id ?? null };
  }
  return { kind: "all", zone_id: null };
}

// Corner pair `[[minLat, minLon], [maxLat, maxLon]]` for `map.fitBounds/2`, so
// Leaflet never has to guess which entries of a point list are corners.
function pointsBounds(points) {
  if (!Array.isArray(points) || points.length === 0) return null;

  let latMin = points[0].lat;
  let latMax = latMin;
  let lonMin = points[0].lon;
  let lonMax = lonMin;

  for (const point of points) {
    if (point.lat < latMin) latMin = point.lat;
    if (point.lat > latMax) latMax = point.lat;
    if (point.lon < lonMin) lonMin = point.lon;
    if (point.lon > lonMax) lonMax = point.lon;
  }

  return [
    [latMin, lonMin],
    [latMax, lonMax],
  ];
}

function distance(first, second) {
  return Math.hypot(second.x - first.x, second.y - first.y);
}

const FareZoneMap = {
  mounted() {
    this._leaflet = null;
    this._map = null;
    this._points = [];
    this._zones = {};
    this._selected = new Set();
    this._filter = normalizeFilter(null);
    this._markers = new Map();
    this._markerLayers = [];
    this._mode = "select";
    this._state = STATE_INITIALIZING;
    this._dragStart = null;
    // A completed box gesture can end over a marker, and the browser reports
    // that release as a click on it too. The flag is set by the box path and
    // consumed by the first marker click, so a box selection is never also a
    // one-stop toggle (AC-28); the next pointerdown clears it either way.
    this._suppressMarkerClick = false;
    this._tileErrorPushed = false;
    this._controls = [];
    this._labelPane = null;
    this._labelCanvas = null;
    this._labelCtx = null;
    this._boxEl = null;

    const canvasEl = this.el.querySelector("[data-map-canvas]");
    this._canvasEl = canvasEl;
    this._hintEl = this.el.querySelector("[data-map-hint]");
    if (!canvasEl) return;

    const leaflet = window.L;
    if (!leaflet) {
      canvasEl.dataset.mapState = STATE_UNAVAILABLE;
      this.pushEvent("map_unavailable", { reason: "Leaflet is unavailable" });
      return;
    }
    this._leaflet = leaflet;

    // A remount can reuse the container before the previous hook's destroyed()
    // ran; Leaflet refuses to initialize a container it still owns.
    if (canvasEl._leaflet_id) {
      canvasEl._leaflet_id = undefined;
      canvasEl.innerHTML = "";
    }

    const map = leaflet.map(canvasEl, {
      center: DEFAULT_CENTER,
      zoom: DEFAULT_ZOOM,
      minZoom: MIN_ZOOM,
      maxZoom: MAX_ZOOM,
      zoomControl: false,
      // The label canvas is drawn in container coordinates and is not scaled
      // with the map pane, so an animated zoom would drag the IDs away from
      // their markers for the length of the animation.
      zoomAnimation: false,
      renderer: leaflet.canvas(),
    });
    this._map = map;

    const tiles = leaflet
      .tileLayer(TILE_URL, {
        attribution: TILE_ATTRIBUTION,
        maxZoom: MAX_ZOOM,
      })
      .addTo(map);
    this._onTileError = () => {
      // One unavailable map per mount: the server falls back to the stop list
      // and does not need a signal per failed tile.
      if (this._tileErrorPushed) return;
      this._tileErrorPushed = true;
      this.pushEvent("map_unavailable", { reason: "Map tiles are unavailable" });
    };
    tiles.on("tileerror", this._onTileError);

    // The label canvas lives in its own pane parented to the map container
    // rather than the map pane: canvas coordinates are container coordinates,
    // and a pane inside the map pane is offset by every pan.
    this._labelPane = map.createPane(LABEL_PANE, canvasEl);
    if (this._labelPane) {
      this._labelPane.style.zIndex = LABEL_PANE_Z_INDEX;
      this._labelPane.style.pointerEvents = "none";
    }
    this._labelCanvas = document.createElement("canvas");
    this._labelCanvas.style.position = "absolute";
    this._labelCanvas.style.left = "0";
    this._labelCanvas.style.top = "0";
    this._labelCtx =
      typeof this._labelCanvas.getContext === "function"
        ? this._labelCanvas.getContext("2d")
        : null;
    if (this._labelPane) this._labelPane.appendChild(this._labelCanvas);

    this._onViewChange = () => this._redrawLabels();
    map.on("moveend", this._onViewChange);
    map.on("zoomend", this._onViewChange);
    map.on("resize", this._onViewChange);

    this._bindControls();
    this._bindPointer();
    this._setMode(this._mode);
    this._syncObservable();

    this.handleEvent("fare_zone_snapshot", (payload) =>
      this._applySnapshot(payload),
    );
    this.handleEvent("fare_zone_selection", (payload) =>
      this._applySelection(payload),
    );
    this.handleEvent("fare_zone_points_changed", (payload) =>
      this._applyPointChanges(payload),
    );
    this.handleEvent("fare_zone_zones", (payload) => this._applyZones(payload));
    this.handleEvent("fare_zone_filter", (payload) =>
      this._applyFilter(payload),
    );

    this.pushEvent("fare_zone_map_ready", {}, (reply) =>
      this._applySnapshot(reply),
    );
  },

  destroyed() {
    this._unbindPointer();
    this._unbindControls();

    if (this._boxEl) {
      this._boxEl.remove();
      this._boxEl = null;
    }

    // map.remove() does not take the label pane with it: the pane was parented
    // to the map container, not to the map pane.
    if (this._labelPane) {
      this._labelPane.remove();
      this._labelPane = null;
    }

    if (this._map) {
      try {
        this._map.remove();
      } catch (_) {
        // LiveView already remounted a hook on this container.
      }
      this._map = null;
    }

    this._markers = new Map();
    this._markerLayers = [];
    this._points = [];
    this._selected = new Set();
    this._dragStart = null;
    this._labelCanvas = null;
    this._labelCtx = null;
    this._leaflet = null;
  },

  // --- State from the server -------------------------------------------------

  _applySnapshot(snapshot) {
    if (!snapshot || typeof snapshot !== "object") return;

    const rows = Array.isArray(snapshot.points) ? snapshot.points : [];
    this._points = rows.map(normalizePoint).filter(Boolean);
    this._zones =
      snapshot.zones && typeof snapshot.zones === "object" ? snapshot.zones : {};
    this._selected = new Set(
      Array.isArray(snapshot.selected) ? snapshot.selected : [],
    );
    this._filter = normalizeFilter(snapshot.filter);

    this._drawMarkers();
    this._fitPoints();
    this._redrawLabels();
    this._state = STATE_READY;
    this._syncObservable();
  },

  _applySelection(payload) {
    if (!payload || typeof payload !== "object") return;

    const added = Array.isArray(payload.added) ? payload.added : [];
    const removed = Array.isArray(payload.removed) ? payload.removed : [];
    added.forEach((id) => this._selected.add(id));
    removed.forEach((id) => this._selected.delete(id));

    this._syncSelectionRings();
    this._syncObservable();
  },

  _applyPointChanges(payload) {
    const changes = payload && Array.isArray(payload.changes) ? payload.changes : [];

    changes.forEach((change) => {
      if (!Array.isArray(change)) return;
      const [id, zoneId] = change;
      const entry = this._markers.get(id);
      // A changed stop the map does not draw (no coordinates) has no marker.
      if (!entry) return;
      entry.record.zoneId = zoneId === undefined ? null : zoneId;
      this._restyleMarker(entry);
    });

    this._redrawLabels();
  },

  _applyZones(payload) {
    if (!payload || typeof payload.zones !== "object" || payload.zones === null) {
      return;
    }
    // Merged, not replaced: the delta names the zones it changes, and a marker
    // whose zone is absent keeps the colour it was drawn with.
    this._zones = { ...this._zones, ...payload.zones };
    this._markers.forEach((entry) => this._restyleMarker(entry));
    this._redrawLabels();
  },

  _applyFilter(payload) {
    if (!payload) return;
    this._filter = normalizeFilter(payload.filter);
    this._markers.forEach((entry) => this._restyleMarker(entry));
  },

  _syncObservable() {
    const el = this._canvasEl;
    if (!el) return;
    el.dataset.mapState = this._state;
    el.dataset.pointCount = String(this._points.length);
    el.dataset.selectedCount = String(this._selected.size);
  },

  // --- Drawing ---------------------------------------------------------------

  _drawMarkers() {
    if (!this._map) return;

    this._markerLayers.forEach((layer) => this._map.removeLayer(layer));
    this._markerLayers = [];
    this._markers = new Map();

    this._points.forEach((record) => {
      const marker = this._leaflet
        .circleMarker([record.lat, record.lon], this._markerStyle(record))
        .addTo(this._map);
      marker.bindTooltip(this._tooltipCopy(record), {
        direction: "top",
        offset: [0, -MARKER_RADIUS],
      });
      marker.on("click", () => {
        if (this._mode !== "select") return;
        if (this._suppressMarkerClick) {
          this._suppressMarkerClick = false;
          return;
        }
        this.pushEvent("toggle_stop", { id: record.id });
      });

      this._markers.set(record.id, { record, marker, ring: null });
      this._markerLayers.push(marker);
    });

    this._syncSelectionRings();
  },

  _markerStyle(record) {
    const dimmed = !this._inFilter(record);
    return {
      radius: MARKER_RADIUS,
      color: this._zoneColor(record.zoneId),
      weight: MARKER_WEIGHT,
      fillColor: MARKER_FILL,
      fillOpacity: dimmed ? DIM_OPACITY : 1,
      opacity: dimmed ? DIM_OPACITY : 1,
    };
  },

  _restyleMarker(entry) {
    entry.marker.setStyle(this._markerStyle(entry.record));
    entry.marker.setTooltipContent(this._tooltipCopy(entry.record));
  },

  _syncSelectionRings() {
    if (!this._map) return;

    this._markers.forEach((entry) => {
      const selected = this._selected.has(entry.record.id);

      if (selected && !entry.ring) {
        entry.ring = this._leaflet
          .circleMarker([entry.record.lat, entry.record.lon], {
            radius: SELECTION_RADIUS,
            color: SELECTION_COLOR,
            weight: SELECTION_WEIGHT,
            fillColor: MARKER_FILL,
            fillOpacity: 1,
            opacity: 1,
            interactive: false,
          })
          .addTo(this._map);
        this._markerLayers.push(entry.ring);
        // The ring is a wider white disc, so it belongs behind its marker.
        if (typeof entry.marker.bringToFront === "function") {
          entry.marker.bringToFront();
        }
      } else if (!selected && entry.ring) {
        this._map.removeLayer(entry.ring);
        this._markerLayers = this._markerLayers.filter(
          (layer) => layer !== entry.ring,
        );
        entry.ring = null;
      }
    });
  },

  _redrawLabels() {
    const canvas = this._labelCanvas;
    const ctx = this._labelCtx;
    if (!canvas || !ctx || !this._map) return;

    const size = this._map.getSize();
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.round(size.x * ratio);
    canvas.height = Math.round(size.y * ratio);
    canvas.style.width = `${size.x}px`;
    canvas.style.height = `${size.y}px`;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, size.x, size.y);

    // Membership is never colour alone (AC-28): below this zoom the labels
    // would overlap, so the list stays the complete alternative.
    if (this._map.getZoom() < LABEL_MIN_ZOOM) return;

    ctx.font = LABEL_FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";

    this._points.forEach((record) => {
      const point = this._map.latLngToContainerPoint([record.lat, record.lon]);
      if (point.x < 0 || point.y < 0 || point.x > size.x || point.y > size.y) {
        return;
      }
      ctx.fillStyle = this._zoneColor(record.zoneId);
      ctx.fillText(markerLabel(record.zoneId), point.x, point.y + LABEL_OFFSET_Y);
    });
  },

  _zoneColor(zoneId) {
    if (zoneId === null || zoneId === undefined) return UNASSIGNED_COLOR;
    const zone = this._zones[zoneId];
    return (zone && zone.color) || UNASSIGNED_COLOR;
  },

  _tooltipCopy(record) {
    const assigned = record.zoneId !== null && record.zoneId !== undefined;
    const zone = assigned ? this._zones[record.zoneId] : null;
    const zoneName = assigned ? (zone && zone.name) || record.zoneId : "Unassigned";
    const name = record.name || record.stopId || "";
    return `${name} · ${zoneName}`;
  },

  _inFilter(record) {
    if (this._filter.kind === "zone") return record.zoneId === this._filter.zone_id;
    if (this._filter.kind === "unassigned") {
      return record.zoneId === null || record.zoneId === undefined;
    }
    return true;
  },

  // --- Controls and pointer selection ---------------------------------------

  _bindControls() {
    const bind = (selector, handler) => {
      const el = this.el.querySelector(selector);
      if (!el) return;
      el.addEventListener("click", handler);
      this._controls.push([el, handler]);
    };

    bind('[data-map-mode="select"]', () => this._setMode("select"));
    bind('[data-map-mode="pan"]', () => this._setMode("pan"));
    bind('[data-map-zoom="in"]', () => {
      if (this._map) this._map.zoomIn();
    });
    bind('[data-map-zoom="out"]', () => {
      if (this._map) this._map.zoomOut();
    });
    bind("[data-map-fit]", () => this._fitPoints());
  },

  _unbindControls() {
    this._controls.forEach(([el, handler]) =>
      el.removeEventListener("click", handler),
    );
    this._controls = [];
  },

  _setMode(mode) {
    this._mode = mode;

    const select = this.el.querySelector('[data-map-mode="select"]');
    const pan = this.el.querySelector('[data-map-mode="pan"]');
    if (select) select.setAttribute("aria-pressed", String(mode === "select"));
    if (pan) pan.setAttribute("aria-pressed", String(mode === "pan"));

    // Select mode owns the drag gesture, so the map must not pan under it.
    const dragging = this._map && this._map.dragging;
    if (dragging && typeof dragging.disable === "function") {
      if (mode === "select") dragging.disable();
      else dragging.enable();
    }

    if (this._hintEl) {
      this._hintEl.textContent = mode === "select" ? HINT_SELECT : HINT_PAN;
    }

    if (mode !== "select") this._clearBox();
  },

  _bindPointer() {
    this._onPointerDown = (event) => {
      if (this._mode !== "select" || event.button !== 0 || !this._map) return;
      // A new gesture is its own click: nothing from the previous box is left
      // to suppress.
      this._suppressMarkerClick = false;
      this._dragStart = this._map.mouseEventToContainerPoint(event);
      window.addEventListener("pointermove", this._onPointerMove);
      window.addEventListener("pointerup", this._onPointerUp);
      window.addEventListener("pointercancel", this._onPointerUp);
    };

    this._onPointerMove = (event) => {
      if (!this._dragStart || !this._map) return;
      const point = this._map.mouseEventToContainerPoint(event);
      if (distance(this._dragStart, point) < DRAG_THRESHOLD_PX) return;
      this._showBox(this._dragStart, point);
    };

    this._onPointerUp = (event) => {
      window.removeEventListener("pointermove", this._onPointerMove);
      window.removeEventListener("pointerup", this._onPointerUp);
      window.removeEventListener("pointercancel", this._onPointerUp);

      const start = this._dragStart;
      this._dragStart = null;
      this._clearBox();
      if (!start || !this._map) return;

      const end = this._map.mouseEventToContainerPoint(event);
      if (distance(start, end) < DRAG_THRESHOLD_PX) return;

      // Project the container corners before comparing: the box is a
      // geographic rectangle, not a rectangle of screen pixels.
      const bounds = [this._toLatLon(start), this._toLatLon(end)];
      // The box owns this gesture: the stop under the cursor is one of the ids
      // the box just reported, so the click that follows the release must not
      // toggle it out of the selection the box made (AC-28).
      this._suppressMarkerClick = true;
      this.pushEvent("select_stops", {
        ids: idsInBounds(this._points, bounds),
      });
    };

    this._canvasEl.addEventListener("pointerdown", this._onPointerDown);
  },

  _unbindPointer() {
    if (this._canvasEl && this._onPointerDown) {
      this._canvasEl.removeEventListener("pointerdown", this._onPointerDown);
    }
    if (this._onPointerMove) {
      window.removeEventListener("pointermove", this._onPointerMove);
      window.removeEventListener("pointerup", this._onPointerUp);
      window.removeEventListener("pointercancel", this._onPointerUp);
    }
    this._onPointerDown = null;
    this._onPointerMove = null;
    this._onPointerUp = null;
  },

  _toLatLon(point) {
    const latLng = this._map.containerPointToLatLng([point.x, point.y]);
    return { lat: latLng.lat, lon: latLng.lng };
  },

  _showBox(start, end) {
    if (!this._boxEl) {
      const box = document.createElement("div");
      box.className = "fare-zone-map-select-box";
      box.style.position = "absolute";
      box.style.left = "0";
      box.style.top = "0";
      box.style.border = `2px dashed ${SELECT_BOX_BORDER}`;
      box.style.background = SELECT_BOX_FILL;
      box.style.pointerEvents = "none";
      box.style.zIndex = SELECT_BOX_Z_INDEX;
      this._canvasEl.appendChild(box);
      this._boxEl = box;
    }

    this._boxEl.style.display = "block";
    this._boxEl.style.left = `${Math.min(start.x, end.x)}px`;
    this._boxEl.style.top = `${Math.min(start.y, end.y)}px`;
    this._boxEl.style.width = `${Math.abs(end.x - start.x)}px`;
    this._boxEl.style.height = `${Math.abs(end.y - start.y)}px`;
  },

  _clearBox() {
    if (this._boxEl) this._boxEl.style.display = "none";
  },

  _fitPoints() {
    const bounds = pointsBounds(this._points);
    if (!this._map || !bounds) return;
    this._map.fitBounds(bounds, { padding: FIT_PADDING });
  },
};

export default FareZoneMap;
