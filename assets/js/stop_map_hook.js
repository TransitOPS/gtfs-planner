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

    // Every view change redraws all three: the lines because their per-route
    // offset is a screen-space rule, the stops because what a mark shows depends
    // on the zoom (a bay separates from its station past BAY_MIN_ZOOM, a name
    // appears below LABEL_MAX_ZOOM), and the bounds because that is what the
    // panel's list follows.
    this._onViewChange = () => {
      this._redrawLines();
      this._redrawStops();
      this._reportBounds();
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

    this.handleEvent("stop_map:scene", (event) =>
      this._applyScene((event && event.payload) || event),
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

    this._scene = null;
    this._stopLayers = new Map();
    this._lineLayers = [];
    this._tileLayers = [];
    this._stopGroup = null;
    this._lineGroup = null;
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

      marker.on("click", () =>
        this.pushEvent("select_stop", { stop_id: stop.id }),
      );
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
  STATE_INITIALIZING,
  STATE_READY,
  STATE_UNAVAILABLE,
};
