/**
 * StopMap
 *
 * Owns the Leaflet canvas in the Map view of Stops & stations. The server
 * renders the root's static markup (`#stop-map`, `phx-update="ignore"`) plus the
 * legend controls around it; this hook binds those controls and draws the
 * version's stops and route lines.
 *
 * Protocol (spec.md › Map hook protocol):
 *   hook → server  stop_map_ready {}, stop_map_bounds {south, west, north, east},
 *                  select_stop {stop_id}, map_unavailable {reason}
 *   server → hook  stop_map:scene {payload}
 *
 * Every mount draws from the scene alone and keeps no state outside its own
 * instance, so a remounted or retried map never depends on deltas an earlier
 * mount received (CR-8). The scene is pushed again when the page retries or
 * when a version change is loaded, and re-applying it is the whole of the
 * update.
 *
 * Markers are `divIcon`s rather than `circleMarker`s for two reasons. They keep
 * their pixel size at every zoom, which is what lets a stop stay the same size
 * as the streets around it when an editor zooms from the whole feed to one
 * corner. And the direction tick is a piece of the marker's own markup, rotated
 * by a bearing the scene already carries, instead of a second layer that would
 * have to be kept in step with the first.
 *
 * ## Add mode and the pin
 *
 * The server owns which mode the map is in: it pushes `stop_map:mode` with the
 * mode, an optional pin and an optional ghost. That is the same rule the scene
 * follows — the browser never decides what is being edited, it reports what a
 * person did with the controls it drew.
 *
 * In add mode the canvas is a placement target: a click reports `place` with
 * the clicked point, and Enter on the focused canvas reports the map's centre
 * for the keyboard placement the caption promises. A drag or an arrow key on
 * the pin reports `pin_moved` once per change — on pointerup and on each key,
 * never on the pointermove stream in between, because a report per pixel is a
 * round trip per pixel.
 *
 * The pin is a real `<button>` in the stage's overlay rather than a `divIcon`,
 * because it has to take focus and answer the arrow keys. The ghost is drawn by
 * Leaflet like every other layer, so it follows a pan for free.
 */

import {
  addSatelliteBasemap,
  addStreetBasemap,
  STREET_MAX_ZOOM,
} from "./basemap_layers";
import { bearingDeg, bearingVector, offsetPolyline } from "./stop_map_geometry";

// Leaflet needs a view before the scene arrives; `stop_map_ready` is pushed once
// the canvas exists, and the scene's bounds replace this view immediately.
const DEFAULT_CENTER = [0, 0];
const DEFAULT_ZOOM = 2;
const MIN_ZOOM = 2;
const FIT_PADDING = [28, 28];
const FIT_MAX_ZOOM = 17;
// Leaflet's `fitBounds` padding insets the view rather than growing it, so
// fitting a version's own bounds crops whatever sits on the edge out of the
// view. The panel lists the stops in the view, so the northernmost stop of a
// feed would be missing from the list meant to hold all of them. The bounds are
// inflated by this much first, and the padding then eats the margin rather than
// the data.
const FIT_MARGIN = 0.1;
// Past this zoom a road is wide enough on screen for its own line, so the
// per-route offsets that keep two buses sharing a street apart would push the
// line off the road it belongs to.
const OFFSET_MAX_ZOOM = 16;
const LINE_SLOT_PX = 4.5;
const LINE_BASE_OFFSET_PX = 3;
const LINE_WEIGHT = 3;
const LINE_CASING_WEIGHT = 5.5;
const ROUTE_FALLBACK_COLOR = "#586479";
const NAVY = "#0f1a3d";

const STOP_RADIUS_PX = 9;
const STATION_RADIUS_PX = 13;
const BAY_RADIUS_PX = 9;
const MARKER_BOX_PX = STOP_RADIUS_PX * 2 + 8;

// A name is worth painting only where it can be read without landing on its
// neighbours. The prototype's default map state paints none — the basemap's own
// street names are the text at that scale, and the panel's list is where a stop's
// name belongs until the map is closed in past the point where the marks
// themselves separate.
const LABEL_MIN_ZOOM = 18;

// A station's bays sit metres apart — the seed's two are thirteen — so at any
// zoom that shows a whole feed their discs land on top of each other and on
// their own station. The prototype hides them for the same reason, and past
// this zoom the letters separate and a bay becomes the subject it is.
const BAY_MIN_ZOOM = 18;

// Two panes so the route lines sit under the stops at every zoom, which is the
// order a reader expects: the road is context, the stop is the subject.
const LINE_PANE = "stopMapLines";
const MARKER_PANE = "stopMapMarkers";
const MARKER_PANE_Z_INDEX = "450";

// The placement pin's own numbers. The prototype states the nudge in feet
// because feet are what a rider measures a curb in; the pin answers in metres
// because that is what a coordinate pair is denominated in, and the caption and
// the pin's aria-label both say feet so the two never meet.
const NUDGE_METRES = 1;
const NUDGE_METRES_SHIFTED = 10;
const METRES_PER_DEGREE = 111_320;
const METRES_PER_MILE = 1609.344;
const FEET_PER_METRE = 0.3048;
// Below this the ghost is the pin drawn twice, and a distance label reading "0
// ft" beside a zero-length move is noise.
const GHOST_MIN_METRES = 0.5;

const NUDGE_STEPS = {
  ArrowUp: [0, 1],
  ArrowDown: [0, -1],
  ArrowLeft: [-1, 0],
  ArrowRight: [1, 0],
};

const MODE_BROWSE = "browse";
const MODE_ADD = "add";

const STATE_INITIALIZING = "initializing";
const STATE_READY = "ready";
const STATE_UNAVAILABLE = "unavailable";

const BASEMAP_STREET = "streets";
const BASEMAP_SATELLITE = "satellite";

const StopMap = {
  mounted() {
    this._leaflet = null;
    this._map = null;
    this._scene = null;
    this._stopLayers = new Map();
    this._lineLayers = [];
    this._stopGroup = null;
    this._lineGroup = null;
    this._tileLayers = [];
    this._basemap = BASEMAP_STREET;
    this._showRoutes = true;
    this._tileErrorPushed = false;
    this._state = STATE_INITIALIZING;
    this._announcedBounds = null;
    this._resizeObserver = null;
    this._mode = MODE_BROWSE;
    this._pin = null;
    this._ghost = null;
    this._pinGroup = null;
    this._overlay = null;
    this._crosshair = null;
    this._pinElement = null;
    this._onPinDown = null;
    this._onPinKey = null;
    this._onMapClick = null;
    this._onMapKey = null;

    const leaflet = window.L;
    if (!leaflet) {
      this._state = STATE_UNAVAILABLE;
      this._leaflet = null;
      this.pushEvent("map_unavailable", { reason: "Leaflet is unavailable" });
      return;
    }
    this._leaflet = leaflet;

    // A remount can reuse a container before the previous hook's destroyed()
    // ran; Leaflet refuses to initialize a container it still owns.
    if (this.el._leaflet_id) {
      this.el._leaflet_id = undefined;
      this.el.innerHTML = "";
    }

    const map = leaflet.map(this.el, {
      center: DEFAULT_CENTER,
      zoom: DEFAULT_ZOOM,
      minZoom: MIN_ZOOM,
      maxZoom: STREET_MAX_ZOOM,
      zoomControl: false,
      attributionControl: true,
      // The stage is focusable so the arrow keys pan the map, which Leaflet only
      // wires up for a container it believes can take focus.
      keyboard: true,
      scrollWheelZoom: false,
      // Markers are positioned by Leaflet on every zoom; a fade between two
      // positions is a marker that is briefly in the wrong place.
      zoomAnimation: false,
    });
    this._map = map;

    this._bindTileState();
    this._setBasemap(BASEMAP_STREET);

    this._createPanes();

    this._lineGroup = leaflet.layerGroup().addTo(map);
    this._stopGroup = leaflet.layerGroup().addTo(map);
    // Its own group, because the stops and the lines are cleared and rebuilt on
    // every view change and the pin's layers are cleared with neither of them.
    this._pinGroup = leaflet.layerGroup().addTo(map);

    // Every view change redraws all three: the lines because their per-route
    // offset is a screen-space rule, the stops because what a mark shows depends
    // on the zoom (a bay separates from its station past BAY_MIN_ZOOM, a name
    // appears below LABEL_MAX_ZOOM), and the bounds because that is what the
    // panel's list follows.
    this._onViewChange = () => {
      this._redrawLines();
      this._redrawStops();
      this._reportBounds();
      // The pin is DOM positioned from the view, so a pan leaves it behind
      // until it is told where it is now.
      this._positionPin();
    };
    map.on("moveend", this._onViewChange);
    map.on("zoomend", this._onViewChange);

    this._wasHidden = this.el.clientWidth === 0;
    if (typeof ResizeObserver !== "undefined") {
      this._resizeObserver = new ResizeObserver(() =>
        this._onContainerResize(),
      );
      this._resizeObserver.observe(this.el);
    }

    this._bindControls();
    this._bindPlacement();

    this.handleEvent("stop_map:scene", (event) =>
      this._applyScene((event && event.payload) || event),
    );
    this.handleEvent("stop_map:mode", (event) =>
      this._applyMode((event && event.payload) || event),
    );
    this.handleEvent("stop_map:focus", (event) =>
      this._applyFocus((event && event.payload) || event),
    );

    // Readiness is reported by the push, not written onto the container: LiveView
    // patches the hook element's attributes on every render, and an attribute the
    // hook added but the server did not is one it takes away again.
    this._state = STATE_READY;
    this.pushEvent("stop_map_ready", {});
    this._reportBounds();
  },

  destroyed() {
    this._unbindControls();
    this._unbindPlacement();

    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }

    if (this._map) {
      try {
        this._map.remove();
      } catch (_) {
        // LiveView already remounted a hook on this container.
      }
      this._map = null;
    }

    this._removeOverlay();
    this._scene = null;
    this._stopLayers = new Map();
    this._lineLayers = [];
    this._tileLayers = [];
    this._stopGroup = null;
    this._lineGroup = null;
    this._pinGroup = null;
    this._pin = null;
    this._ghost = null;
  },

  // ── add mode and the placement pin ──────────────────────────────────────

  // Placement is reported, never decided here: the server says which mode the
  // map is in, and the browser says what a person did with the controls it drew.
  _bindPlacement() {
    this._onMapClick = (event) => {
      if (this._mode !== MODE_ADD) return;
      const latlng = event && event.latlng;
      if (!latlng) return;

      // One report per click, whether it placed the first stop or moved the
      // one the last click placed. The server owns which of the two it was.
      this.pushEvent("place", { lat: latlng.lat, lon: latlng.lng });
    };
    this._onMapKey = (event) => {
      // The canvas answers only while it is the element under the key. A key
      // pressed on the pin is the pin's own, handled there.
      if (event.target !== this.el || this._mode !== MODE_ADD) return;

      if (event.key === "Enter") {
        event.preventDefault();
        // Placement without a pointer: the crosshair is at the centre, so the
        // centre is what gets reported.
        const centre = this._map.getCenter();
        this.pushEvent("place", { lat: centre.lat, lon: centre.lng });
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.pushEvent("cancel_add", {});
      }
    };

    this._map.on("click", this._onMapClick);
    this.el.addEventListener("keydown", this._onMapKey);
  },

  _unbindPlacement() {
    if (this._onMapClick && this._map) {
      this._map.off("click", this._onMapClick);
      this._onMapClick = null;
    }
    if (this._onMapKey) {
      this.el.removeEventListener("keydown", this._onMapKey);
      this._onMapKey = null;
    }
  },

  _applyMode(payload) {
    const data = payload || {};

    this._mode = data.mode === MODE_ADD ? MODE_ADD : MODE_BROWSE;
    this._pin = readPin(data.pin);
    // A ghost without a pin is a saved position with nothing to compare it to.
    this._ghost = this._pin ? readPoint(data.ghost) : null;

    this._ensureOverlay();
    this._syncModeChrome();
    this._renderPin();
  },

  // A check names a stop an editor has to look at, so the view goes to it. The
  // point is dropped rather than clamped, exactly as a placement is: a check
  // that pointed at latitude 0 would centre the map on the equator.
  _applyFocus(payload) {
    const point = readPoint(payload);
    if (!this._map || !point) return;

    // Street zoom at least: a stop seen at the fitted view is a dot among every
    // other dot, and "review this pair" is worth nothing at that scale.
    this._map.setView([point.lat, point.lon], Math.max(this._map.getZoom(), 18));
  },

  _syncModeChrome() {
    // A cursor is the whole of what add mode looks like before anything is
    // placed, and it is the one thing a person can see without a screenshot.
    this.el.classList.toggle("stop-map-adding", this._mode === MODE_ADD);

    if (!this._crosshair) return;
    this._crosshair.hidden = !(this._mode === MODE_ADD && !this._pin);
  },

  // The overlay is the stage's, not the canvas's, for the legend's reason:
  // Leaflet owns every child of `#stop-map`, and a pin Leaflet threw away on
  // the next `fitBounds` would be a placement the editor could not adjust.
  // The stage renders it empty and the hook fills it, so a diff has something
  // to own and never removes a pin mid-drag.
  _ensureOverlay() {
    if (this._overlay) return this._overlay;

    const root = this._controlsRoot();
    let overlay = root.querySelector("#stop-map-overlay");

    if (!overlay) {
      overlay = document.createElement("div");
      overlay.id = "stop-map-overlay";
      overlay.className = "stop-map-overlay";
      root.appendChild(overlay);
    }

    const crosshair =
      overlay.querySelector("#stop-map-crosshair") || buildCrosshair(overlay);

    this._overlay = overlay;
    this._crosshair = crosshair;
    return overlay;
  },

  _removeOverlay() {
    this._removePinElement();
    // The overlay itself is the stage's: it is emptied, not removed, so the
    // next mount finds the element the server rendered rather than a new one.
    this._overlay = null;
    this._crosshair = null;
    this.el.classList.remove("stop-map-adding");
  },

  _renderPin() {
    if (!this._pin) {
      this._removePinElement();
      this._drawPinLayers();
      this._syncModeChrome();
      return;
    }

    const button = this._pinElement || this._createPinElement();
    const label = this._pin.label || "Stop";

    // The nudge is stated where a keyboard user will find it: on the control
    // itself, not only in the caption the pointer user reads.
    button.setAttribute(
      "aria-label",
      `${label} position. Drag it, or focus it and use the arrow keys to move it about 3 feet, 30 feet with Shift.`,
    );

    const badge = button.querySelector("[data-stop-map-pin-label]");
    badge.textContent = this._pin.label || "";
    badge.hidden = !this._pin.label;

    this._positionPin();
    this._drawPinLayers();
    this._syncModeChrome();
  },

  _createPinElement() {
    this._ensureOverlay();

    const button = document.createElement("button");
    button.type = "button";
    button.dataset.stopMapPin = "";
    button.className = "stop-map-pin";
    button.innerHTML =
      '<span class="stop-map-pin-ring"></span>' +
      '<span class="stop-map-pin-body">' +
      '<svg class="stop-map-pin-glyph" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.4"><circle cx="12" cy="12" r="8"></circle><path d="M7.5 12h9"></path></svg>' +
      "</span>" +
      '<span data-stop-map-pin-label class="stop-map-pin-label"></span>';

    this._onPinDown = (event) => this._startPinDrag(event);
    this._onPinKey = (event) => this._onPinKeyDown(event);
    button.addEventListener("pointerdown", this._onPinDown);
    button.addEventListener("keydown", this._onPinKey);

    this._overlay.appendChild(button);
    this._pinElement = button;
    return button;
  },

  _removePinElement() {
    const button = this._pinElement;
    if (!button) return;

    if (this._onPinDown) {
      button.removeEventListener("pointerdown", this._onPinDown);
      this._onPinDown = null;
    }
    if (this._onPinKey) {
      button.removeEventListener("keydown", this._onPinKey);
      this._onPinKey = null;
    }

    if (button.parentElement) button.parentElement.removeChild(button);
    this._pinElement = null;
  },

  _positionPin() {
    if (!this._pinElement || !this._pin || !this._map) return;

    const point = this._map.latLngToContainerPoint([
      this._pin.lat,
      this._pin.lon,
    ]);
    this._pinElement.style.left = `${point.x}px`;
    this._pinElement.style.top = `${point.y}px`;
  },

  // The saved position a pending move started from, the dashed line between it
  // and the pin, and how far apart they are. Drawn by Leaflet rather than by
  // the overlay, so a pan moves all three without anything recomputing them.
  _drawPinLayers() {
    if (!this._map || !this._pinGroup) return;

    this._pinGroup.clearLayers();
    if (!this._pin || !this._ghost) return;

    const saved = [this._ghost.lon, this._ghost.lat];
    const placed = [this._pin.lon, this._pin.lat];
    const metres = haversineMetres(saved, placed);
    if (metres < GHOST_MIN_METRES) return;

    this._leaflet
      .marker([this._ghost.lat, this._ghost.lon], {
        icon: this._leaflet.divIcon({
          className: "stop-map-marker stop-map-ghost-marker",
          html: '<span class="stop-map-ghost"></span>',
          iconSize: [MARKER_BOX_PX, MARKER_BOX_PX],
          iconAnchor: [MARKER_BOX_PX / 2, MARKER_BOX_PX / 2],
        }),
        pane: MARKER_PANE,
        interactive: false,
        keyboard: false,
      })
      .addTo(this._pinGroup);

    this._leaflet
      .polyline(
        [
          [this._ghost.lat, this._ghost.lon],
          [this._pin.lat, this._pin.lon],
        ],
        { color: NAVY, weight: 2, dashArray: "5 4", interactive: false },
      )
      .addTo(this._pinGroup);

    this._leaflet
      .marker(
        [
          (this._ghost.lat + this._pin.lat) / 2,
          (this._ghost.lon + this._pin.lon) / 2,
        ],
        {
          icon: this._leaflet.divIcon({
            className: "stop-map-marker stop-map-distance-marker",
            html: `<span class="stop-map-distance">${escapeHtml(
              formatDistance(metres),
            )}</span>`,
            iconSize: [0, 0],
            iconAnchor: [0, 0],
          }),
          pane: MARKER_PANE,
          interactive: false,
          keyboard: false,
        },
      )
      .addTo(this._pinGroup);
  },

  _startPinDrag(event) {
    if (event.button !== 0 || !this._pin) return;
    // The drag is the pin's, not the map's: without this a pointerdown on the
    // pin starts a pan under it.
    event.preventDefault();
    event.stopPropagation();

    const button = event.currentTarget;
    if (typeof button.setPointerCapture === "function") {
      button.setPointerCapture(event.pointerId);
    }

    const move = (moveEvent) => {
      this._setPinLatLng(this._pointerLatLng(moveEvent));
    };

    // The report is the pointerup, never the pointermove stream: an editor
    // dragging a pin crosses a hundred points in a second, and a report per
    // point is a round trip per point for a draft the server already owns.
    const up = (upEvent) => {
      button.removeEventListener("pointermove", move);
      button.removeEventListener("pointerup", up);
      button.removeEventListener("pointercancel", up);

      const [lon, lat] = this._pointerLatLng(upEvent);
      this._setPinLatLng([lon, lat]);
      this.pushEvent("pin_moved", { lat, lon });
      // Focus returns to the pin so the arrow keys work straight after a drag.
      button.focus();
    };

    button.addEventListener("pointermove", move);
    button.addEventListener("pointerup", up);
    button.addEventListener("pointercancel", up);
  },

  _onPinKeyDown(event) {
    const step = NUDGE_STEPS[event.key];
    if (!step || !this._pin) return;

    // The pin's own keys: the canvas pans on the arrow keys in browse mode,
    // and here they would pan the pin off the place it is being set.
    event.preventDefault();
    event.stopPropagation();

    const metres = event.shiftKey ? NUDGE_METRES_SHIFTED : NUDGE_METRES;
    const [lon, lat] = offsetMetres(
      [this._pin.lon, this._pin.lat],
      [step[0] * metres, step[1] * metres],
    );

    this._setPinLatLng([lon, lat]);
    this.pushEvent("pin_moved", { lat, lon });
  },

  // The local half of a pin change: the browser shows the move immediately, and
  // the server's echo of it is what makes it the draft.
  _setPinLatLng([lon, lat]) {
    if (!this._pin) return;

    this._pin = { ...this._pin, lat, lon };
    this._positionPin();
    this._drawPinLayers();
  },

  // A mark answers differently in each mode. Browsing, a mark is a stop to
  // open. Placing, it is a curb with a stop already standing on it, which is
  // exactly the thing an editor is pointing at — and the marker takes the
  // click away from the canvas, so a mark that did not place would be one
  // place on the map where placing is impossible.
  _clickStop(stop) {
    if (this._mode === MODE_ADD && stop.point) {
      this.pushEvent("place", { lat: stop.point[1], lon: stop.point[0] });
      return;
    }

    this.pushEvent("select_stop", { stop_id: stop.id });
  },

  _pointerLatLng(event) {
    const rect = this.el.getBoundingClientRect();
    const { lat, lng } = this._map.containerPointToLatLng([
      event.clientX - rect.left,
      event.clientY - rect.top,
    ]);

    return [lng, lat];
  },

  _createPanes() {
    this._markerPane = this._map.createPane(MARKER_PANE);
    if (this._markerPane) {
      this._markerPane.style.zIndex = MARKER_PANE_Z_INDEX;
      // The tick is drawn inside the marker's own markup, so the marker takes
      // its click; the pane does not need to.
      this._markerPane.style.pointerEvents = "none";
    }
    // Lines use the default overlay pane; a dedicated pane here would only need
    // the z-index the stop pane already sets above it.
  },

  _setBasemap(style) {
    const leaflet = this._leaflet;
    if (!leaflet || !this._map) return;

    for (const layer of this._tileLayers) {
      if (layer && this._map.hasLayer(layer)) this._map.removeLayer(layer);
    }
    this._tileLayers = [];

    this._basemap = style;
    const added =
      style === BASEMAP_SATELLITE
        ? addSatelliteBasemap(leaflet, this._map)
        : addStreetBasemap(leaflet, this._map);
    this._tileLayers = added.filter(Boolean);

    for (const layer of this._tileLayers) {
      if (layer.on) layer.on("tileerror", this._onTileError);
    }

    this._syncBasemapControls();
  },

  _bindTileState() {
    // One unavailable map per mount: the page falls back to the list and does
    // not need a signal per failed tile.
    this._onTileError = () => {
      if (this._tileErrorPushed) return;
      this._tileErrorPushed = true;
      this._state = STATE_UNAVAILABLE;
      this.pushEvent("map_unavailable", {
        reason: "Map tiles are unavailable",
      });
    };
  },

  _applyScene(payload) {
    if (!payload || !this._map) return;

    this._scene = payload;
    this._fitScene();
    this._redrawLines();
    this._redrawStops();
    this._syncBasemapControls();
    this._reportBounds();
  },

  _fitScene() {
    const bounds = this._scene && this._scene.bounds;
    if (!Array.isArray(bounds) || bounds.length !== 2) return;

    // The payload carries `[lon, lat]` pairs because that is the JSON
    // convention `display_point/1` established, and Leaflet's `fitBounds`
    // array form is `[[south, west], [north, east]]` — latitude first. Handing
    // it the payload's pairs unchanged asks it to fit a box in the southern
    // hemisphere at the stops' longitude, which is a valid box and nowhere near
    // this feed: the map lands on Antarctica and the panel reports a view with
    // no stops in it.
    const [west, south] = bounds[0];
    const [east, north] = bounds[1];
    const [[paddedWest, paddedSouth], [paddedEast, paddedNorth]] =
      inflateBounds(
        [
          [west, south],
          [east, north],
        ],
        FIT_MARGIN,
      );

    this._map.fitBounds(
      [
        [paddedSouth, paddedWest],
        [paddedNorth, paddedEast],
      ],
      {
        padding: FIT_PADDING,
        maxZoom: FIT_MAX_ZOOM,
      },
    );
  },

  _lineOffset(line, index, zoom) {
    if (zoom > OFFSET_MAX_ZOOM) return 0;

    // One slot per pattern of the same route, so a route's directions stack
    // side by side instead of drawing over each other.
    const siblings = (this._scene.lines || []).filter(
      (candidate) => candidate.route_id === line.route_id,
    );
    const slot = siblings.findIndex((candidate) => candidate === line);
    const base = LINE_BASE_OFFSET_PX + Math.max(0, slot) * LINE_SLOT_PX;
    // Index breaks a tie between two patterns the payload sent in the same slot.
    return base + (slot < 0 ? index * LINE_SLOT_PX : 0);
  },

  _redrawLines() {
    if (!this._map || !this._lineGroup) return;

    this._lineGroup.clearLayers();
    this._lineLayers = [];
    if (!this._showRoutes || !this._scene) return;

    const zoom = this._map.getZoom();
    const lines = this._scene.lines || [];

    lines.forEach((line, index) => {
      const points = this._linePoints(line, zoom, index);
      if (points.length < 2) return;

      const color = this._routeColor(line.route_id);

      // A white casing under the coloured line: where two routes share a street
      // the casing is what keeps the second line legible over the first, and it
      // is why the prototype draws every line twice.
      const casing = this._leaflet
        .polyline(points, {
          color: "#ffffff",
          weight: LINE_CASING_WEIGHT,
          opacity: 0.9,
          lineCap: "round",
          lineJoin: "round",
          interactive: false,
        })
        .addTo(this._lineGroup);

      const route = this._leaflet
        .polyline(points, {
          color,
          weight: LINE_WEIGHT,
          opacity: 0.85,
          lineCap: "round",
          lineJoin: "round",
          interactive: false,
        })
        .addTo(this._lineGroup);

      route.bringToFront?.();
      this._lineLayers.push(casing, route);
    });
  },

  // The offset is a screen-space rule, so the line is projected into container
  // pixels, offset there, and projected back. Doing it in degrees would put a
  // constant offset at every zoom, which grows into the next block at street
  // level and vanishes at feed level.
  _linePoints(line, zoom, index) {
    const points = Array.isArray(line.points) ? line.points : [];
    if (points.length < 2) return [];

    const latLngs = points.map(([lon, lat]) => [lat, lon]);
    const offset = this._lineOffset(line, index, zoom);
    if (!offset) return latLngs;

    const map = this._map;
    const projected = points.map(([lon, lat]) => {
      const point = map.latLngToContainerPoint([lat, lon]);
      return [point.x, point.y];
    });
    const shifted = offsetPolyline(projected, offset);

    return shifted.map(([x, y]) => {
      const { lat, lng } = map.containerPointToLatLng([x, y]);
      return [lat, lng];
    });
  },

  _routeColor(routeId) {
    const route = (this._scene.routes || {})[routeId];
    const color = route && route.color;
    if (typeof color !== "string") return ROUTE_FALLBACK_COLOR;

    // `route_color` is six hex digits without a leading `#`, because that is
    // what the GTFS spec says and what a feed sends.
    const hex = color.replace(/^#/, "");
    return /^[0-9a-f]{6}$/i.test(hex) ? `#${hex}` : ROUTE_FALLBACK_COLOR;
  },

  _redrawStops() {
    if (!this._map || !this._stopGroup) return;

    this._stopGroup.clearLayers();
    this._stopLayers = new Map();

    const stops = (this._scene && this._scene.stops) || [];
    const zoom = this._map.getZoom();
    const showLabels = zoom >= LABEL_MIN_ZOOM;
    const showBays = zoom >= BAY_MIN_ZOOM;

    for (const stop of stops) {
      // An unlocated stop has nowhere to be drawn. It is still in the panel's
      // list, where the editor can reach it by ID.
      if (!stop.point) continue;

      const kind = this._stopKind(stop);
      if (kind === "bay" && !showBays) continue;

      const marker = this._leaflet
        .marker([stop.point[1], stop.point[0]], {
          icon: this._stopIcon(stop, kind, showLabels),
          pane: MARKER_PANE,
          keyboard: true,
          riseOnHover: true,
          title: stop.name || stop.stop_id,
        })
        .addTo(this._stopGroup);

      marker.on("click", () => this._clickStop(stop));
      this._stopLayers.set(stop.id, marker);
    }
  },

  _stopIcon(stop, kind, showLabels) {
    const label = escapeHtml(this._stopLabel(stop));

    const shapes = {
      station: `<span class="stop-map-station"></span>`,
      bay: `<span class="stop-map-bay">${label}</span>`,
      served: `<span class="stop-map-stop"></span>`,
      unserved: `<span class="stop-map-stop stop-map-stop-unserved"></span>`,
    };

    const tick = this._tickMarkup(stop);
    // A bay's letter is the mark itself, so it is never repeated as a name.
    const name =
      showLabels && kind !== "bay"
        ? `<span class="stop-map-label">${escapeHtml(
            stop.name || stop.stop_id || "",
          )}</span>`
        : "";

    return this._leaflet.divIcon({
      className: `stop-map-marker stop-map-marker-${kind}`,
      html: `${shapes[kind]}${tick}${name}`,
      iconSize: [MARKER_BOX_PX, MARKER_BOX_PX],
      iconAnchor: [MARKER_BOX_PX / 2, MARKER_BOX_PX / 2],
    });
  },

  // The tick is the stop's travel direction: a rider cannot tell which way a
  // stop faces from a dot, and an editor placing a new one needs to know which
  // side of the street the buses stop on.
  _tickMarkup(stop) {
    const bearing = this._stopBearing(stop);
    if (bearing === null || bearing === undefined) return "";
    if (this._stopKind(stop) !== "served") return "";

    const [tx, ty] = bearingVector(bearing);
    if (tx === 0 && ty === 0) return "";

    const distance = STOP_RADIUS_PX + 5;
    const tipX = MARKER_BOX_PX / 2 + tx * distance;
    const tipY = MARKER_BOX_PX / 2 + ty * distance;

    // `bearingDeg` already answers in degrees, which is what a CSS rotation is
    // in. Converting again lands on the same angle by accident, 5156° of the
    // way round a circle.

    return `<span class="stop-map-tick" style="left:${tipX.toFixed(1)}px;top:${tipY.toFixed(
      1,
    )}px;transform:translate(-50%,-50%) rotate(${bearing.toFixed(1)}deg)"></span>`;
  },

  // Which way the buses go at this stop. The payload does not carry a bearing
  // per stop — a GTFS feed has no such column — so it is read off the pattern
  // lines that serve the stop: the segment nearest the stop gives the direction
  // the bus is travelling there, which is the direction a rider recognises.
  // A stop no line reaches has no tick, rather than one pointing north.
  _stopBearing(stop) {
    if (stop.bearing !== null && stop.bearing !== undefined)
      return stop.bearing;

    const patternIds = new Set((stop.pattern_ids || []).map(String));
    if (patternIds.size === 0) return null;

    const map = this._map;
    const point = container(map, stop.point);

    let nearest = null;
    for (const line of this._scene.lines || []) {
      if (!patternIds.has(String(line.pattern_id))) continue;

      const projected = (line.points || []).map(([lon, lat]) =>
        container(map, [lon, lat]),
      );

      for (let index = 1; index < projected.length; index++) {
        const segment = nearestSegmentTo(
          point,
          projected[index - 1],
          projected[index],
        );
        if (!segment) continue;
        if (!nearest || segment.distance < nearest.distance) nearest = segment;
      }
    }

    return nearest ? nearest.bearing : null;
  },

  // A bay is a stop that lives inside a station. This codebase's feeds model
  // that as an ordinary stop with a parent — which is what a boarding area's
  // letter rides on — so `parent_station` decides it, and a GTFS boarding area
  // (`location_type` 4) is honoured for a feed that spells it the other way.
  _stopKind(stop) {
    if (stop.location_type === 1) return "station";
    if (stop.location_type === 4 || stop.parent_station) return "bay";
    return stop.served === false ? "unserved" : "served";
  },

  // A station is named for its building; a bay for its letter; a stop for its
  // name, falling back to the feed's own ID because an unnamed stop still needs
  // something a reader can point at.
  _stopLabel(stop) {
    if (this._stopKind(stop) === "bay" && stop.code) return String(stop.code);
    return stop.name || stop.stop_id || "";
  },

  _reportBounds() {
    if (!this._map) return;

    const bounds = this._map.getBounds();
    if (!bounds) return;

    const south = bounds.getSouth();
    const west = bounds.getWest();
    const north = bounds.getNorth();
    const east = bounds.getEast();
    const rounded = [south, west, north, east].map((value) =>
      Number(value.toFixed(5)),
    );

    // A pan that changes nothing in the fifth decimal is not a new view, and
    // the panel would be recomputed for it.
    if (this._announcedBounds && sameBounds(this._announcedBounds, rounded)) {
      return;
    }
    this._announcedBounds = rounded;

    this.pushEvent("stop_map_bounds", {
      south: rounded[0],
      west: rounded[1],
      north: rounded[2],
      east: rounded[3],
    });
  },

  _onContainerResize() {
    if (!this._map) return;

    const hidden = this.el.clientWidth === 0;
    if (hidden) {
      this._wasHidden = true;
      return;
    }

    this._map.invalidateSize();
    // Leaflet repositions its own layers on a resize; the pin is DOM positioned
    // from the view, so without this a pin placed on a desktop window is left
    // at those pixels when the workspace stacks for a phone — which is outside
    // the canvas entirely.
    this._positionPin();

    if (this._wasHidden) {
      // Leaflet sized itself against a zero-width container and kept that view.
      // Fitting again is what makes a rule opened on a phone land on its own
      // stops rather than on the middle of the Atlantic.
      this._wasHidden = false;
      this._fitScene();
      this._reportBounds();
    }
  },

  // The basemap and the routes toggle are client-only: they change what is drawn
  // and nothing the server stores, so a round-trip would cost a diff for no
  // change in state. The legend is a sibling of the canvas rather than a child,
  // because Leaflet owns every child of `#stop-map` and a legend in there would
  // be the first thing a `fitBounds` threw away — so the listeners are on the
  // document and scoped back to this map's own controls by their attributes.
  _bindControls() {
    this._onBasemapClick = (event) => {
      const choice = event.target.closest?.("[data-map-basemap]");
      if (!choice) return;
      this._setBasemap(choice.dataset.mapBasemap);
    };
    this._onRoutesChange = (event) => {
      const input = event.target.closest?.("[data-map-routes]");
      if (!input) return;
      this._showRoutes = input.checked;
      this._redrawLines();
    };
    this._onZoomClick = (event) => {
      const button = event.target.closest?.("[data-map-zoom]");
      if (!button || !this._map) return;
      this._map.setZoom(
        this._map.getZoom() + (button.dataset.mapZoom === "in" ? 1 : -1),
      );
    };
    this._onFitClick = (event) => {
      if (!event.target.closest?.("[data-map-fit]") || !this._map) return;
      // The same fit the scene arrived with, so "show every stop" and the
      // initial view are one rule rather than two that can disagree.
      this._fitScene();
      this._redrawStops();
      this._reportBounds();
    };

    document.addEventListener("click", this._onBasemapClick);
    document.addEventListener("change", this._onRoutesChange);
    document.addEventListener("click", this._onZoomClick);
    document.addEventListener("click", this._onFitClick);
  },

  _unbindControls() {
    if (this._onBasemapClick) {
      document.removeEventListener("click", this._onBasemapClick);
      this._onBasemapClick = null;
    }
    if (this._onRoutesChange) {
      document.removeEventListener("change", this._onRoutesChange);
      this._onRoutesChange = null;
    }
    if (this._onZoomClick) {
      document.removeEventListener("click", this._onZoomClick);
      this._onZoomClick = null;
    }
    if (this._onFitClick) {
      document.removeEventListener("click", this._onFitClick);
      this._onFitClick = null;
    }
  },

  _syncBasemapControls() {
    const root = this._controlsRoot();
    if (!root) return;

    for (const button of root.querySelectorAll("[data-map-basemap]")) {
      const active = button.dataset.mapBasemap === this._basemap;
      button.setAttribute("aria-pressed", active ? "true" : "false");
    }

    const routes = root.querySelector("[data-map-routes]");
    if (routes) routes.checked = this._showRoutes;
  },

  // The legend is a sibling of the canvas inside the stage, because Leaflet owns
  // every child of `#stop-map`. Controls are therefore read from the stage rather
  // than from `this.el`, and never from the document at large: two maps on one
  // page would otherwise each answer for the other's legend.
  _controlsRoot() {
    return this.el.parentElement || document;
  },
};

// The distance from `point` to the segment [from, to], with the segment's
// heading. A point beyond either end measures to the endpoint, so a stop sitting
// on the extension of a line past its last vertex still reads as nearest to that
// line rather than to no line at all.
// Leaflet's `Point` is an object with `x` and `y`; the geometry helpers speak in
// `[x, y]` pairs. This is the one place the two meet.
function container(map, [lon, lat]) {
  const point = map.latLngToContainerPoint([lat, lon]);
  return [point.x, point.y];
}

function nearestSegmentTo(point, from, to) {
  const dx = to[0] - from[0];
  const dy = to[1] - from[1];
  const lengthSquared = dx * dx + dy * dy;

  const t =
    lengthSquared === 0
      ? 0
      : Math.max(
          0,
          Math.min(
            1,
            ((point[0] - from[0]) * dx + (point[1] - from[1]) * dy) /
              lengthSquared,
          ),
        );

  const closest = [from[0] + t * dx, from[1] + t * dy];

  return {
    distance: Math.hypot(point[0] - closest[0], point[1] - closest[1]),
    bearing: bearingDeg(from, to),
  };
}

// `[lon, lat]` moved by a number of metres east and north. Longitude degrees
// are shorter than latitude degrees away from the equator, so the same metres
// east of a stop and north of it are not the same number of degrees — and at
// the poles, where that ratio runs away, a stop with no draggable longitude is
// better than one that jumps to the other side of the world.
function offsetMetres([lon, lat], [east, north]) {
  const scale = Math.max(0.05, Math.cos((lat * Math.PI) / 180));

  return [
    lon + east / (METRES_PER_DEGREE * scale),
    lat + north / METRES_PER_DEGREE,
  ];
}

function haversineMetres([lon1, lat1], [lon2, lat2]) {
  const radius = 6_371_000;
  const toRadians = Math.PI / 180;
  const dLat = (lat2 - lat1) * toRadians;
  const dLon = (lon2 - lon1) * toRadians;

  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * toRadians) *
      Math.cos(lat2 * toRadians) *
      Math.sin(dLon / 2) ** 2;

  return 2 * radius * Math.asin(Math.min(1, Math.sqrt(a)));
}

// Feet under a thousand of them and miles over, on the prototype's own rule:
// a curb is measured in feet and a move across a neighbourhood is not. Both
// figures land on a 5-foot step so the label stops flickering as the pin moves.
function formatDistance(metres) {
  const feet = metres / FEET_PER_METRE;

  return feet < 1000
    ? `${Math.round(feet / 5) * 5} ft`
    : `${(metres / METRES_PER_MILE).toFixed(2)} mi`;
}

// The crosshair, for a stage that renders an overlay without one.
function buildCrosshair(overlay) {
  const crosshair = document.createElement("div");
  crosshair.id = "stop-map-crosshair";
  crosshair.className = "stop-map-crosshair";
  crosshair.setAttribute("aria-hidden", "true");
  crosshair.hidden = true;
  crosshair.innerHTML =
    '<span class="stop-map-crosshair-v"></span><span class="stop-map-crosshair-h"></span>';

  overlay.appendChild(crosshair);
  return crosshair;
}

function readPin(value) {
  const point = readPoint(value);
  if (!point) return null;

  return { ...point, label: value.label ? String(value.label) : "" };
}

// A point that cannot be read is dropped rather than clamped. A pin at
// latitude 0 because the payload said "north" would be drawn on the equator
// and saved there.
function readPoint(value) {
  if (!value || typeof value !== "object") return null;

  const lat = Number(value.lat);
  const lon = Number(value.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;

  return { lat, lon };
}

function sameBounds(first, second) {
  return first.every((value, index) => value === second[index]);
}

// `[[west, south], [east, north]]` grown by `ratio` of its own span on every
// side. A degenerate extent — one stop, or a whole feed on one point — has no
// span to grow, so it is returned unchanged and Leaflet's own padding decides
// how much room to leave.
function inflateBounds([[west, south], [east, north]], ratio) {
  const dx = (east - west) * ratio;
  const dy = (north - south) * ratio;

  return [
    [west - dx, south - dy],
    [east + dx, north + dy],
  ];
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export default StopMap;
export {
  BASEMAP_SATELLITE,
  BASEMAP_STREET,
  MODE_ADD,
  MODE_BROWSE,
  STATE_INITIALIZING,
  STATE_READY,
  STATE_UNAVAILABLE,
  formatDistance,
  haversineMetres,
};
