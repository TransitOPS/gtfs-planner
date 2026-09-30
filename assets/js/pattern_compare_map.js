/**
 * PatternCompareMap
 *
 * The Compare patterns map (spec 19, `AC-22`, `R10`, `R11`): the Leaflet pane
 * that draws the `PatternComparison.map_payload/3` read of both patterns. The
 * server renders the payload; this hook only draws what it already says and
 * never invents geometry (`INV-5`). The map is a linked locator, not the work
 * surface: it holds no server state and sends no LiveView events (`INV-4`).
 *
 * Mounted on `#compare-map` with `phx-update="ignore"`, so the hook owns
 * everything inside the pane (tiles, vectors, markers and the degraded-state
 * notice) and the server only patches `data-map-payload`. A payload change
 * redraws the layers in place.
 *
 * Required data-* attrs on the hook root element:
 *   data-map-payload  `map_payload/3` as JSON, `[lon, lat]` coordinates:
 *                     `stops: [{stop_id, name, coordinates, served}]` with
 *                     `served: a | b | both`, `sections: [{from_stop_id,
 *                     to_stop_id, series, style, points}]` with `series: a |
 *                     b | both` and `style: path | connector`, `ends: {a:
 *                     {first_stop_id, last_stop_id}, b: <same> | nil}` and
 *                     `pins: [{n, stop_id}]` — the numbered difference pins,
 *                     filled by the LiveView from the differences (step 21).
 *                     A stop without coordinates is left out by the read; a
 *                     pin or end whose stop is missing is not drawn.
 *
 * What is drawn (AC-22): shared sections in the neutral navy, A in navy, B in
 * cyan; a connector section dashed and a saved path solid, each over a white
 * casing so it reads on the basemap; only-A stops as navy circles, only-B
 * stops as cyan squares and stops both patterns serve as white circles ringed
 * in navy; numbered difference pins; and an A/B end chip at each pattern's
 * first and last stop, so the series never depends on colour alone. The
 * palette is the design system's (navy-800/cyan-700/navy-300 as hex, because
 * Leaflet writes SVG attributes rather than classes).
 *
 * The map fits once after load (FH-29): the first render with drawable
 * geometry fits, later payload patches redraw without moving the view, and
 * only a `compare:frame` frames again. `leafletLatLng` is reused from
 * `route_details_map`.
 *
 * Window events this hook dispatches (the PatternCompareWorkspace contract):
 *   compare:row-for-stop {stopId}  a stop marker or difference pin was
 *                                  clicked; the workspace selects the first
 *                                  row serving that stop
 *
 * Window events this hook listens for (dispatched by the workspace):
 *   compare:frame        {stopIds}      fit the map to the difference's stops
 *                                       and drop the row ring
 *   compare:hot          {stopId|null}  ring a row's stop, null clears it
 *   compare:select-stop  {stopId}       ring the selected row's stop
 *
 * This is an external-runtime boundary: `window.L` (Leaflet) and the
 * authenticated `/map/tiles/osm-bright/:z/:x/:y` proxy (same-origin cookies
 * ride along). A missing Leaflet, or a tile that errors, degrades to the DS
 * "The map is unavailable" notice with "Retry map" (`#compare-map-off` and
 * `#compare-map-retry`); the notice never throws and the stop table keeps
 * working. `Retry map` redraws the tiles, or mounts the runtime again when
 * Leaflet was absent.
 *
 * Deliberate limits (step 20): no zoom/fit chrome and no stop-name labels are
 * built here — the prepared card names neither, the difference frames are the
 * way back to a known view, and the stop table is the text equivalent. Wheel
 * zoom is off so a sticky pane cannot swallow the page's own scroll.
 */

import { leafletLatLng } from "./route_details_map";

// The authenticated osm-bright proxy (MapTilesController keeps the key server
// side). Same-origin, so the operator's session authorizes every tile.
const TILE_URL = "/map/tiles/osm-bright/{z}/{x}/{y}";
const TILE_ATTRIBUTION = "© OpenStreetMap contributors · Geoapify";
const TILE_MAX_ZOOM = 19;
const MIN_ZOOM = 2;
const WORLD_CENTER = [20, 0];
const WORLD_ZOOM = 2;
const FIT_PADDING = [24, 24];
const FIT_MAX_ZOOM = 17;

// Design tokens as hex: Leaflet writes SVG attributes, not CSS classes. A is
// the darkest navy token (the DS ramp has no 700), as on the slot cards.
const NEUTRAL = "#7a85ac"; // --color-navy-300, shared sections
const SERIES_A = "#0a1330"; // --color-navy-800
const SERIES_B = "#2c8888"; // --color-cyan-700
const HOVER_RING = "#7dd3cb"; // --color-cyan-300
const SELECTED_RING = "#c81870"; // --color-action
const WHITE = "#ffffff";

const SERIES = ["both", "a", "b"];
const SERIES_COLORS = { both: NEUTRAL, a: SERIES_A, b: SERIES_B };

const LINE_WEIGHT = 4;
const CASING_WEIGHT = 7;
const CONNECTOR_DASH = "9 7";
const ONLY_STOP_RADIUS = 6.5;
const SHARED_STOP_RADIUS = 4.5;
const SQUARE_SIZE = 13;
const PIN_SIZE = 22;
const END_CHIP_SIZE = 18;
const HOVER_RING_RADIUS = 14;
const SELECTED_RING_RADIUS = 12;

// The DS notice the hook owns inside the ignored container. The read-failure
// notice is the LiveView's own block (step 21) and is not this one.
const NOTICE_ID = "compare-map-off";
const RETRY_ID = "compare-map-retry";

// The map fits once after load: the first render fits, later patches do not
// (FH-29). `state` is the hook's own fit bookkeeping.
export function shouldFit(state) {
  return !state || state.fitted !== true;
}

// The payload as drawable descriptors, pure and Leaflet-free so the cases can
// pin the mapping without a runtime: lines (with their casing), stop markers,
// difference pins and end chips. Coordinates Leaflet cannot use are dropped,
// and a line needs two points to exist at all.
export function layersFor(payload) {
  const markers = [];
  const locations = new Map();

  for (const stop of Array.isArray(payload?.stops) ? payload.stops : []) {
    const latlng = leafletLatLng(stop?.coordinates);
    if (!latlng || typeof stop?.stop_id !== "string" || stop.stop_id === "") continue;
    if (!locations.has(stop.stop_id)) locations.set(stop.stop_id, latlng);
    markers.push(stopLayer(stop, latlng));
  }

  return {
    lines: Array.isArray(payload?.sections) ? payload.sections.flatMap(lineLayer) : [],
    stops: markers,
    pins: pinLayers(payload?.pins, locations),
    chips: chipLayers(payload?.ends, locations),
  };
}

function readPayload(raw) {
  if (typeof raw !== "string" || raw === "") return null;

  try {
    const payload = JSON.parse(raw);
    return payload && typeof payload === "object" ? payload : null;
  } catch (_error) {
    return null;
  }
}

function lineLayer(section, index) {
  const latlngs = leafletLatLngs(section?.points);
  if (latlngs.length < 2) return [];

  const series = SERIES.includes(section?.series) ? section.series : "both";
  const connector = section?.style === "connector";
  const dashArray = connector ? CONNECTOR_DASH : null;

  return [
    {
      key: `line-${index}-${section?.from_stop_id}-${section?.to_stop_id}`,
      series,
      style: connector ? "connector" : "path",
      latlngs,
      options: {
        color: SERIES_COLORS[series],
        weight: LINE_WEIGHT,
        opacity: 1,
        dashArray,
        lineCap: "round",
        lineJoin: "round",
      },
      casing: {
        color: WHITE,
        weight: CASING_WEIGHT,
        dashArray,
        lineCap: "round",
        lineJoin: "round",
      },
    },
  ];
}

function stopLayer(stop, latlng) {
  const served = stop?.served === "a" || stop?.served === "b" ? stop.served : "both";

  const options =
    served === "both"
      ? {
          color: SERIES_A,
          weight: 2,
          fillColor: WHITE,
          fillOpacity: 1,
          radius: SHARED_STOP_RADIUS,
        }
      : {
          color: WHITE,
          weight: 2,
          fillColor: served === "a" ? SERIES_A : SERIES_B,
          fillOpacity: 1,
          radius: ONLY_STOP_RADIUS,
        };

  return {
    key: `stop-${stop.stop_id}`,
    stop_id: stop.stop_id,
    served,
    shape: served === "b" ? "square" : "circle",
    latlng,
    options,
  };
}

function pinLayers(pins, locations) {
  if (!Array.isArray(pins)) return [];

  return pins.flatMap((pin) => {
    const latlng = locations.get(pin?.stop_id);
    if (!latlng || !Number.isFinite(pin?.n)) return [];
    return [{ key: `pin-${pin.n}`, n: pin.n, stop_id: pin.stop_id, latlng }];
  });
}

function chipLayers(ends, locations) {
  const chips = [];

  for (const side of ["a", "b"]) {
    const end = ends?.[side];
    if (!end) continue;

    for (const [position, stopId] of [
      ["first", end.first_stop_id],
      ["last", end.last_stop_id],
    ]) {
      const latlng = locations.get(stopId);
      if (!latlng) continue;

      // The prototype puts each pattern's chip down-left (A) or down-right
      // (B) of the stop, above the first stop and below the last.
      const dx = side === "a" ? -16 : 16;
      const dy = position === "first" ? -14 : 14;
      chips.push({
        key: `${side}-${position}-${stopId}`,
        label: side.toUpperCase(),
        side,
        latlng,
        anchor: [dx, dy],
      });
    }
  }

  return chips;
}

function leafletLatLngs(points) {
  if (!Array.isArray(points)) return [];
  return points.map(leafletLatLng).filter((latlng) => latlng !== null);
}

const PatternCompareMap = {
  mounted() {
    this._destroyed = false;
    this._fitted = false;
    this._layers = null;
    this._stopLocations = new Map();
    this._hotStopId = null;
    this._selectedStopId = null;
    this._map = null;
    this._L = null;
    this._tiles = null;
    this._notice = null;

    this._onFrame = (event) => this._frame(event.detail);
    this._onHot = (event) => this._setHot(event.detail?.stopId ?? null);
    this._onSelectStop = (event) => this._setSelected(event.detail?.stopId ?? null);
    window.addEventListener("compare:frame", this._onFrame);
    window.addEventListener("compare:hot", this._onHot);
    window.addEventListener("compare:select-stop", this._onSelectStop);

    this._prepareContainer();
    this._buildNotice();
    this._mountMap();
    this._applyDataset();
  },

  // The server patches `data-map-payload`; the layers are redrawn in place
  // and the view is left where it is (FH-29).
  updated() {
    if (this._destroyed) return;
    this._applyDataset();
  },

  destroyed() {
    this._destroyed = true;

    window.removeEventListener("compare:frame", this._onFrame);
    window.removeEventListener("compare:hot", this._onHot);
    window.removeEventListener("compare:select-stop", this._onSelectStop);

    if (this._map) {
      try {
        this._map.remove();
      } catch (_error) {
        /* container reused by a newer instance */
      }
      this._map = null;
    }

    this._tiles = null;
    this._notice = null;
  },

  // --- setup -----------------------------------------------------------------

  // A reused container can still carry Leaflet's own flag and DOM
  // (RouteDetailsMap precedent), which would break the fresh map.
  _prepareContainer() {
    if (this.el._leaflet_id) {
      this.el._leaflet_id = undefined;
      this.el.innerHTML = "";
    }
  },

  _buildNotice() {
    const notice = document.createElement("div");
    notice.id = NOTICE_ID;
    notice.hidden = true;
    notice.setAttribute("role", "status");
    notice.className =
      "absolute inset-0 z-[800] flex flex-col items-center justify-center gap-2 " +
      "bg-canvas px-6 text-center";
    notice.innerHTML = `
      <span class="hero-map size-7 text-muted" aria-hidden="true"></span>
      <p class="text-sm font-bold text-strong">The map is unavailable</p>
      <p class="max-w-[34ch] text-sm text-default">The stop list, differences and times still work.</p>
      <button
        type="button"
        id="${RETRY_ID}"
        class="mt-2 inline-flex min-h-11 items-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
      >
        <span class="hero-arrow-path size-4" aria-hidden="true"></span>Retry map
      </button>`;

    notice.querySelector(`#${RETRY_ID}`).addEventListener("click", () => this._retry());
    this.el.appendChild(notice);
    this._notice = notice;
  },

  _mountMap() {
    if (this._map) return;

    const L = window.L;
    if (!L) {
      console.error(
        "PatternCompareMap: window.L (Leaflet) is not available; " +
          "the stop list, differences and times still work",
      );
      this._showNotice();
      return;
    }
    this._L = L;

    this._map = L.map(this.el, {
      zoomControl: false,
      attributionControl: true,
      minZoom: MIN_ZOOM,
      // A sticky pane must not swallow the page's own scroll; pinch,
      // double-click and the difference frames move the map instead.
      scrollWheelZoom: false,
    });
    this._map.setView(WORLD_CENTER, WORLD_ZOOM);

    this._tiles = L.tileLayer(TILE_URL, {
      attribution: TILE_ATTRIBUTION,
      maxZoom: TILE_MAX_ZOOM,
      maxNativeZoom: TILE_MAX_ZOOM,
      updateWhenIdle: false,
    }).addTo(this._map);

    this._lines = L.layerGroup().addTo(this._map);
    this._stops = L.layerGroup().addTo(this._map);
    this._pins = L.layerGroup().addTo(this._map);
    this._chips = L.layerGroup().addTo(this._map);
    this._rings = L.layerGroup().addTo(this._map);

    // A tile that errored is the degraded state; a later tile that loaded
    // recovers. `load` alone is not that signal: an errored tile counts as
    // ready, so a wholly aborted basemap would end with `load` (TransferMap's
    // finding).
    this._tiles.on("tileerror", () => this._showNotice());
    this._tiles.on("tileload", () => this._hideNotice());

    this._hideNotice();
  },

  _retry() {
    this._hideNotice();

    if (this._tiles) {
      this._tiles.redraw();
      return;
    }

    // Leaflet was absent when the hook mounted: try the runtime again.
    this._mountMap();
    this._applyDataset();
  },

  _showNotice() {
    if (!this._notice) return;

    // The container is the hook's own ignored element; give the notice a
    // positioned ancestor even before Leaflet adds its container class.
    if (getComputedStyle(this.el).position === "static") {
      this.el.style.position = "relative";
    }

    this._notice.hidden = false;
  },

  _hideNotice() {
    if (this._notice) this._notice.hidden = true;
  },

  // --- drawing ---------------------------------------------------------------

  _applyDataset() {
    const payload = readPayload(this.el.dataset.mapPayload);
    this._layers = layersFor(payload);
    this._stopLocations = new Map(
      this._layers.stops.map((stop) => [stop.stop_id, stop.latlng]),
    );

    this._draw();
    this._fitOnce();
  },

  _draw() {
    if (!this._map || !this._layers) return;

    for (const group of [this._lines, this._stops, this._pins, this._chips, this._rings]) {
      group.clearLayers();
    }

    // The white casing under each line keeps it readable on the basemap, as
    // `route_details_map` draws its saved sections.
    for (const line of this._layers.lines) {
      this._lines.addLayer(
        this._L.polyline(line.latlngs, { ...line.casing, interactive: false }),
      );
      this._lines.addLayer(
        this._L.polyline(line.latlngs, { ...line.options, interactive: false }),
      );
    }

    for (const stop of this._layers.stops) {
      this._stops.addLayer(this._stopLayer(stop));
    }

    for (const pin of this._layers.pins) {
      this._pins.addLayer(this._pinLayer(pin));
    }

    for (const chip of this._layers.chips) {
      this._chips.addLayer(this._chipLayer(chip));
    }

    this._drawRings();
  },

  _stopLayer(stop) {
    if (stop.shape === "square") {
      return this._L
        .marker(stop.latlng, {
          keyboard: false,
          icon: this._L.divIcon({
            className: "compare-map-stop-square",
            html: `<span class="block size-[13px] rounded-[2px] border-2 border-white bg-cyan-700"></span>`,
            iconSize: [SQUARE_SIZE, SQUARE_SIZE],
            iconAnchor: [SQUARE_SIZE / 2, SQUARE_SIZE / 2],
          }),
        })
        .on("click", () => this._requestRow(stop.stop_id));
    }

    return this._L
      .circleMarker(stop.latlng, stop.options)
      .on("click", () => this._requestRow(stop.stop_id));
  },

  _pinLayer(pin) {
    return this._L
      .marker(pin.latlng, {
        keyboard: false,
        title: `Difference ${pin.n}`,
        icon: this._L.divIcon({
          className: "compare-map-pin",
          html: `<span class="flex size-[22px] items-center justify-center rounded-full border-2 border-white bg-navy-800 text-[12px] font-bold leading-none text-white">${pin.n}</span>`,
          iconSize: [PIN_SIZE, PIN_SIZE],
          iconAnchor: [PIN_SIZE / 2, PIN_SIZE / 2],
        }),
      })
      .on("click", () => this._requestRow(pin.stop_id));
  },

  _chipLayer(chip) {
    const [dx, dy] = chip.anchor;

    return this._L.marker(chip.latlng, {
      interactive: false,
      keyboard: false,
      icon: this._L.divIcon({
        className: "compare-map-chip",
        html: `<span class="inline-flex size-[18px] items-center justify-center rounded-badge ${
          chip.side === "a" ? "bg-navy-800" : "bg-cyan-700"
        } text-[11px] font-bold leading-none text-white" title="Pattern ${chip.label}">${chip.label}</span>`,
        iconSize: [END_CHIP_SIZE, END_CHIP_SIZE],
        iconAnchor: [END_CHIP_SIZE / 2 - dx, END_CHIP_SIZE / 2 - dy],
      }),
    });
  },

  // `compare:hot` rings a hovered row's stop; `compare:select-stop` rings the
  // selected row's stop (the workspace answers `compare:row-for-stop` with it).
  _drawRings() {
    if (!this._map) return;

    this._rings.clearLayers();

    const hot = this._stopLocations.get(this._hotStopId);
    if (hot) {
      this._rings.addLayer(
        this._L.circleMarker(hot, {
          radius: HOVER_RING_RADIUS,
          stroke: false,
          fillColor: HOVER_RING,
          fillOpacity: 0.55,
          interactive: false,
        }),
      );
    }

    const selected = this._stopLocations.get(this._selectedStopId);
    if (selected) {
      this._rings.addLayer(
        this._L.circleMarker(selected, {
          radius: SELECTED_RING_RADIUS,
          color: SELECTED_RING,
          weight: 3,
          fill: false,
          interactive: false,
        }),
      );
    }
  },

  // --- events ----------------------------------------------------------------

  _frame(detail) {
    if (this._destroyed || !this._map) return;

    this._setSelected(null);

    const latlngs = (Array.isArray(detail?.stopIds) ? detail.stopIds : [])
      .map((stopId) => this._stopLocations.get(stopId))
      .filter(Boolean);

    if (latlngs.length === 0) return;
    this._fit(latlngs);
  },

  _setHot(stopId) {
    const next = typeof stopId === "string" && stopId !== "" ? stopId : null;
    if (next === this._hotStopId) return;
    this._hotStopId = next;
    this._drawRings();
  },

  _setSelected(stopId) {
    const next = typeof stopId === "string" && stopId !== "" ? stopId : null;
    if (next === this._selectedStopId) return;
    this._selectedStopId = next;
    this._drawRings();
  },

  // The map never selects a row itself: the workspace owns row selection and
  // answers with `compare:select-stop`, which rings the stop (R11, INV-4).
  _requestRow(stopId) {
    if (!stopId) return;
    window.dispatchEvent(
      new CustomEvent("compare:row-for-stop", { detail: { stopId } }),
    );
  },

  // --- fitting ---------------------------------------------------------------

  _fitOnce() {
    if (!this._map || !this._layers || !shouldFit({ fitted: this._fitted })) return;

    const latlngs = [
      ...this._layers.lines.flatMap((line) => line.latlngs),
      ...this._layers.stops.map((stop) => stop.latlng),
    ];

    if (latlngs.length === 0) return;
    this._fit(latlngs);
  },

  _fit(latlngs) {
    this._fitted = true;

    if (latlngs.length === 1) {
      this._map.setView(latlngs[0], FIT_MAX_ZOOM);
      return;
    }

    this._map.fitBounds(this._L.latLngBounds(latlngs), {
      padding: FIT_PADDING,
      maxZoom: FIT_MAX_ZOOM,
    });
  },
};

export default PatternCompareMap;
