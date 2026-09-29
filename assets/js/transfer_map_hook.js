/**
 * TransferMapHook
 *
 * Owns the Transfers page's connection map: the selected rule's or the open
 * draft's Arrive and Board endpoints, a station endpoint's child platforms, the
 * dashed direction from one to the other (or a loop when both sides are the same
 * station), and the pick-on-map candidates that resolve one side without its
 * named field. Each endpoint is a dot with a text pill, so the words, not a
 * colour or a letter key, say which is which.
 *
 * The container is `phx-update="ignore"`, so the server never patches inside it
 * and this hook owns its contents for the life of the mount — including tearing
 * every Leaflet object down in destroyed().
 *
 * Required data-* attrs on the hook root element:
 *   data-map-generation  UUID of the LiveView mount this map belongs to; every
 *                        event pushed from here echoes it (R10)
 *   data-extent          version_extent/2 as JSON ({south, west, north, east}),
 *                        `{}` or absent when the version has no coordinates
 *
 * The basemap is streets, not aerial imagery: a transfer rule is read against
 * the blocks and crossings the connection crosses, and a satellite photo
 * underneath it hides all of them.
 *
 * This is an external-runtime boundary: window.L (Leaflet) and the tile source.
 * Missing Leaflet degrades to a "fatal" map state rather than an exception, and
 * a failed tile reports "imagery_unavailable" (the state name predates the
 * basemap change and is the server's contract). Neither state may block the
 * list, the inspector or the form — the page renders the unavailable panel from
 * the state event (AC-22).
 */

import { addStreetBasemap, STREET_MAX_ZOOM } from "./basemap_layers";
import {
  DIAGRAM_BASE_COLOR,
  paletteColor,
  treatmentForLocationType,
} from "./stop_icon_symbols";

// One drag or zoom emits several moveend events, and the server answers every
// bounds push with a candidate query, so only the settled viewport is asked
// about. The pick id rides on each push so a finished session's answer can be
// dropped (R10).
const BOUNDS_DEBOUNCE_MS = 250;

const FIT_PADDING = [32, 32];
const FIT_MAX_ZOOM = 18;
const SINGLE_POINT_ZOOM = 17;

// The Arrive = Board loop has to clear the dot it surrounds, or the loop hides
// behind it.
const LOOP_RADIUS = 22;

// The connection is drawn as a cased line: an accent dash over a white underlay.
// The street basemap draws dashed lines of its own, so an uncased dash reads as
// basemap detail rather than as the rule's direction.
const LINE_WEIGHT = 3;
const CASING_WEIGHT = 7;
const CASING_COLOR = "#ffffff";
const CASING_OPACITY = 0.85;

// Pick candidates are the only click targets on this map, so they are lifted
// above the endpoint pills they can overlap. The endpoint pills in turn sit
// above the child platforms: Leaflet stacks markers by latitude, so a station's
// children — metres from the endpoint — would otherwise cover the pill at any
// zoom that fits a long connection.
const LETTER_Z_OFFSET = 500;
const CANDIDATE_Z_OFFSET = 1000;

// View used before any endpoint or version extent is known. Deliberately a wide
// world view rather than a zero-sized box at (0, 0).
const WORLD_CENTER = [20, 0];
const WORLD_ZOOM = 1;

// The Arrive and Board markers: a dot on the stop and a text pill beside it. They
// name the endpoints, they are not actions, so they stay out of the tab order
// (keyboard: false) and out of the marker pane's keyboard handlers. Arrive sits
// above its dot and Board below, so two stops close together keep both words
// readable; a rule that arrives and boards at one stop shows one pill above it.
const DOT_ICON_SIZE = 16;
const DOT_CLASS = "block size-4 rounded-full ring-2 ring-white";
const PILL_CLASS =
  "absolute left-1/2 -translate-x-1/2 whitespace-nowrap rounded-badge px-2 py-1 text-[13px] font-bold leading-none text-white";
const ARRIVE_TONE = {
  dot: "bg-strong",
  pill: "bg-strong bottom-full mb-1.5",
};
const BOARD_TONE = {
  dot: "bg-cyan-700",
  pill: "bg-cyan-700 top-full mt-1.5",
};

// Theme colors, with the literals only protecting an isolated fixture or a
// missing stylesheet from rendering nothing.
const LINE_FALLBACK = "#0d737d";

function coordinate(value) {
  if (value === null || value === undefined || value === "") return null;

  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

// One drawable point, or null. A payload entry without usable coordinates is
// omitted instead of drawn at (0, 0) or thrown on: an endpoint without
// coordinates is a normal state of an imported feed (AC-22, FH-20).
function mapPoint(raw) {
  const lat = coordinate(raw?.lat);
  const lon = coordinate(raw?.lon);
  if (lat === null || lon === null) return null;

  return {
    stop_id: raw.stop_id,
    name: raw.name || raw.stop_id || "",
    lat,
    lon,
    location_type: raw.location_type,
  };
}

// `data-extent` is server-rendered JSON. A version with no coordinates renders
// `{}`, and a partial box is no box, so both answer null and the hook keeps its
// world view.
function extentFromJson(raw) {
  if (!raw) return null;

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_) {
    return null;
  }

  if (!parsed || typeof parsed !== "object") return null;

  const south = coordinate(parsed.south);
  const west = coordinate(parsed.west);
  const north = coordinate(parsed.north);
  const east = coordinate(parsed.east);
  if ([south, west, north, east].includes(null)) return null;

  return { south, west, north, east };
}

function pointTuple(point) {
  return [point.lat, point.lon];
}

function endpointIcon(L, label, tone) {
  return L.divIcon({
    className: "",
    html:
      `<span class="${DOT_CLASS} ${tone.dot}"></span>` +
      `<span class="${PILL_CLASS} ${tone.pill}">${label}</span>`,
    iconSize: [DOT_ICON_SIZE, DOT_ICON_SIZE],
    iconAnchor: [DOT_ICON_SIZE / 2, DOT_ICON_SIZE / 2],
  });
}

// Child stops and pick candidates share the station diagram's location-type
// shape grammar, so a platform reads the same here as on the diagram. A
// candidate is a target: the white ring lifts it off the basemap, Leaflet puts
// tabindex="0" on this element for `keyboard: true`, and the theme outline marks
// where Tab and Enter will act.
function stopIcon(L, stop, color, { interactive = false } = {}) {
  const treatment = treatmentForLocationType(stop.location_type, color);
  const width = parseFloat(treatment.width);
  const height = parseFloat(treatment.height);
  const border = interactive ? "3px solid #fff" : `2px solid ${treatment.stroke}`;
  const rounding =
    treatment.symbol === "circle" ? "rounded-full" : "rounded-[3px]";
  const className = interactive
    ? "transfer-map-candidate " +
      rounding +
      " focus-visible:outline-2 focus-visible:outline-offset-2" +
      " focus-visible:outline-primary"
    : "";

  return L.divIcon({
    className,
    html:
      `<span style="display:block;width:${treatment.width};height:${treatment.height};` +
      `background-color:${treatment.fill};border:${border};` +
      `border-radius:${treatment.borderRadius}"></span>`,
    iconSize: [width, height],
    iconAnchor: [width / 2, height / 2],
  });
}

const TransferMapHook = {
  mounted() {
    this.generation = this.el.dataset.mapGeneration;
    this._destroyed = false;
    this._pickId = null;
    this._points = [];
    this._boundsTimer = null;
    this._extent = extentFromJson(this.el.dataset.extent);

    const L = window.L;
    if (!L) {
      this._emitState("fatal");
      return;
    }
    this._L = L;

    // If LiveView reused a container that already had Leaflet initialized (for
    // example a previous hook's destroyed() did not run before this mount),
    // L.map throws "Map container is already initialized." Reset the internal
    // flag and clear the child DOM first — the MapAlignment precedent.
    if (this.el._leaflet_id) {
      this.el._leaflet_id = undefined;
      this.el.innerHTML = "";
    }

    this._childColor = paletteColor(this.el, "--color-primary", DIAGRAM_BASE_COLOR);
    this._lineColor = paletteColor(this.el, "--color-accent", LINE_FALLBACK);

    this.map = L.map(this.el, {
      zoomControl: true,
      keyboard: true,
      dragging: true,
      scrollWheelZoom: false,
      attributionControl: true,
      // The street tiles stop here, so the map stops here too rather than
      // zooming into an empty grid.
      maxZoom: STREET_MAX_ZOOM,
    });

    this._tileLayers = addStreetBasemap(L, this.map).filter(Boolean);
    this._bindTileState();

    this.layers = L.layerGroup().addTo(this.map);
    this.candidates = L.layerGroup().addTo(this.map);

    this._bindPickBounds();
    this._setInitialView();

    // Client-only control: the page's "Fit connection" button dispatches this on
    // the ignored container instead of round-tripping to the server. With no
    // endpoint to fit yet it refits the version, so the button is never dead.
    this._onFitRequest = () => {
      if (this._points.length) {
        this._fit(this._points);
      } else {
        this._fitExtent();
      }
    };
    this.el.addEventListener("transfer-map:fit", this._onFitRequest);

    // Below 1024px the page hides this pane (display: none) while the list has the
    // screen, and Leaflet cannot size a hidden container: it would keep the view it
    // computed for nothing. When the pane is shown again, remeasure and fit the
    // connection once, so a rule chosen on a phone opens on its own streets. A
    // resize while the pane stays visible is Leaflet's own to handle.
    this._wasHidden = this.el.clientWidth === 0;
    if (typeof ResizeObserver !== "undefined") {
      this._resizeObserver = new ResizeObserver(() => this._onContainerResize());
      this._resizeObserver.observe(this.el);
    }

    this.handleEvent("transfer_map:show", (payload) => this._show(payload));
    this.handleEvent("transfer_map:pick_start", (payload) =>
      this._startPick(payload),
    );
    this.handleEvent("transfer_map:pick_candidates", (payload) =>
      this._setCandidates(payload),
    );
    this.handleEvent("transfer_map:pick_end", (payload) => this._endPick(payload));
    this.handleEvent("transfer_map:retry", () => this._retry());
  },

  destroyed() {
    this._destroyed = true;
    this._pickId = null;

    if (this._boundsTimer) {
      clearTimeout(this._boundsTimer);
      this._boundsTimer = null;
    }

    if (this.el && this._onFitRequest) {
      this.el.removeEventListener("transfer-map:fit", this._onFitRequest);
    }
    this._onFitRequest = null;

    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }

    if (this.map) {
      try {
        this.map.remove();
      } catch (_) {
        /* container reused by a newer instance */
      }
      this.map = null;
    }
  },

  // Every server-bound event goes through here: once destroyed, this hook must
  // not write to a LiveView that has already replaced it.
  _push(name, payload) {
    if (this._destroyed) return;

    this.pushEvent(name, payload);
  },

  _emitState(state) {
    this._push("transfer_map_state", { generation: this.generation, state });
  },

  // A tile that loaded is enough to call the basemap present, and a failed tile
  // reports the degraded state. The layer's `load` event is not that signal:
  // Leaflet fires it once every tile in view is ready, and a tile that errored
  // counts as ready, so a wholly aborted basemap ends with `load` and clears the
  // degraded state (AC-22, FH-20). `tileload` is the per-tile success event.
  _bindTileState() {
    this._tileLayers.forEach((layer) => {
      layer.on?.("tileload", () => this._emitState("ready"));
      layer.on?.("tileerror", () => this._emitState("imagery_unavailable"));
    });
  },

  _bindPickBounds() {
    this.map.on("moveend", () => {
      if (this._pickId === null) return;

      if (this._boundsTimer) clearTimeout(this._boundsTimer);
      this._boundsTimer = setTimeout(() => {
        this._boundsTimer = null;
        this._pushBounds();
      }, BOUNDS_DEBOUNCE_MS);
    });
  },

  _pushBounds() {
    if (this._destroyed || this._pickId === null || !this.map) return;

    const bounds = this.map.getBounds();
    this._push("transfer_map_bounds", {
      pick_id: this._pickId,
      south: bounds.getSouth(),
      west: bounds.getWest(),
      north: bounds.getNorth(),
      east: bounds.getEast(),
    });
  },

  _setInitialView() {
    if (this._extent) {
      this._fitExtent();
    } else {
      this.map.setView(WORLD_CENTER, WORLD_ZOOM);
    }
  },

  // One marker on the map. `keyboard` is the whole difference between an inert
  // shape (an endpoint, a child platform) and an action (a pick candidate): Leaflet adds
  // tabindex and role="button" only when it is true, and it never turns Enter
  // into a click, so the candidate binds its own Enter below.
  _marker(point, options, group) {
    return this._L
      .marker(pointTuple(point), { keyboard: false, ...options })
      .addTo(group || this.layers);
  },

  _show(payload = {}) {
    if (this._destroyed || !this.map) return;

    const a = mapPoint(payload.a);
    const b = mapPoint(payload.b);
    const children = (payload.children || []).map(mapPoint).filter(Boolean);
    // Both sides at one station is the station-vs-station rule: the endpoints
    // coincide, so one "Arrive and board" pill is drawn inside the loop instead of
    // two pills stacked on the same pixel.
    const loop = Boolean(a && b && a.stop_id === b.stop_id);

    this.layers.clearLayers();
    this._points = [];

    children.forEach((child) => {
      this._marker(child, {
        icon: stopIcon(this._L, child, this._childColor),
        title: child.name,
      });
      // The fit frames everything this payload draws, so a platform outside the
      // endpoints' own box is not clipped at the edge of the view.
      this._points.push(child);
    });

    if (a && b && loop) {
      this._marker(a, {
        icon: endpointIcon(this._L, "Arrive and board", ARRIVE_TONE),
        title: a.name,
        zIndexOffset: LETTER_Z_OFFSET,
      });
      this._points = [a, ...this._points];

      const loopOptions = {
        radius: LOOP_RADIUS,
        fill: false,
        interactive: false,
      };
      this._L
        .circleMarker(pointTuple(a), {
          ...loopOptions,
          weight: CASING_WEIGHT,
          color: CASING_COLOR,
          opacity: CASING_OPACITY,
        })
        .addTo(this.layers);
      this._L
        .circleMarker(pointTuple(a), {
          ...loopOptions,
          dashArray: "6 6",
          weight: LINE_WEIGHT,
          color: this._lineColor,
        })
        .addTo(this.layers);
    } else {
      if (a) {
        this._marker(a, {
          icon: endpointIcon(this._L, "Arrive", ARRIVE_TONE),
          title: a.name,
          zIndexOffset: LETTER_Z_OFFSET,
        });
        this._points.push(a);
      }
      if (b) {
        this._marker(b, {
          icon: endpointIcon(this._L, "Board", BOARD_TONE),
          title: b.name,
          zIndexOffset: LETTER_Z_OFFSET,
        });
        this._points.push(b);
      }
      if (a && b) {
        const line = [pointTuple(a), pointTuple(b)];
        this._L
          .polyline(line, {
            weight: CASING_WEIGHT,
            color: CASING_COLOR,
            opacity: CASING_OPACITY,
            interactive: false,
          })
          .addTo(this.layers);
        this._L
          .polyline(line, {
            dashArray: "6 6",
            weight: LINE_WEIGHT,
            color: this._lineColor,
            interactive: false,
          })
          .addTo(this.layers);
      }
    }

    // A payload with no drawable endpoint falls back to the whole version, so
    // the map still answers "where is this version" while an operator picks the
    // first side of a new rule.
    if (this._points.length) {
      if (payload.fit !== false) this._fit(this._points);
    } else {
      this._fitExtent();
    }
  },

  _fit(points) {
    if (this._destroyed || !this.map || !points.length) return;

    if (points.length === 1) {
      this.map.setView(pointTuple(points[0]), SINGLE_POINT_ZOOM);
      return;
    }

    this.map.fitBounds(this._bounds(points), {
      padding: FIT_PADDING,
      maxZoom: FIT_MAX_ZOOM,
    });
  },

  _fitExtent() {
    if (this._destroyed || !this.map || !this._extent) return;

    const { south, west, north, east } = this._extent;
    this.map.fitBounds(this._L.latLngBounds([south, west], [north, east]), {
      padding: FIT_PADDING,
      maxZoom: FIT_MAX_ZOOM,
    });
  },

  _bounds(points) {
    const lats = points.map((point) => point.lat);
    const lons = points.map((point) => point.lon);

    return this._L.latLngBounds(
      [Math.min(...lats), Math.min(...lons)],
      [Math.max(...lats), Math.max(...lons)],
    );
  },

  _startPick(payload = {}) {
    if (this._destroyed || !this.map) return;

    this._pickId = payload.pick_id;
    // A new session starts empty: leaving the previous session's candidates on
    // the map would let a click echo the new pick id for an old stop.
    this.candidates.clearLayers();

    this._pushBounds();
  },

  _setCandidates(payload = {}) {
    if (this._destroyed || !this.map) return;
    // Echo discipline (R10, CR-6): only the session this hook is currently
    // running may draw candidates or accept a pick from them.
    if (payload.pick_id !== this._pickId) return;

    this.candidates.clearLayers();

    (payload.stops || []).forEach((raw) => {
      const point = mapPoint(raw);
      if (!point) return;

      const pick = () => {
        if (this._destroyed || payload.pick_id !== this._pickId) return;

        this._push("transfer_map_pick", {
          pick_id: this._pickId,
          stop_id: point.stop_id,
        });
      };

      const marker = this._marker(
        point,
        {
          icon: stopIcon(this._L, point, this._childColor, { interactive: true }),
          keyboard: true,
          riseOnHover: true,
          title: point.name,
          zIndexOffset: CANDIDATE_Z_OFFSET,
        },
        this.candidates,
      );

      marker.on("click", pick);

      // Leaflet's `keyboard` option makes a marker tabbable and announces it as
      // a button, but it never turns Enter into a click for a div, and a
      // candidate is only reachable by keyboard if it can be picked that way.
      marker.getElement?.()?.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") return;

        event.preventDefault();
        pick();
      });
    });
  },

  _endPick(payload = {}) {
    // A pick id that is not the current session belongs to a session the server
    // has already moved on from, so it must not end this one.
    if (payload.pick_id !== undefined && payload.pick_id !== this._pickId) return;

    this._pickId = null;

    if (this._boundsTimer) {
      clearTimeout(this._boundsTimer);
      this._boundsTimer = null;
    }

    this.candidates?.clearLayers();
  },

  _onContainerResize() {
    if (this._destroyed || !this.map) return;

    if (this.el.clientWidth === 0) {
      this._wasHidden = true;
      return;
    }
    if (!this._wasHidden) return;

    this._wasHidden = false;
    this.map.invalidateSize();

    if (this._points.length) {
      this._fit(this._points);
    } else {
      this._fitExtent();
    }
  },

  _retry() {
    if (this._destroyed || !this.map) return;

    this._tileLayers.forEach((layer) => layer.redraw?.());
    this.map.invalidateSize();
  },
};

export default TransferMapHook;
