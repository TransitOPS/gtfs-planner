/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import ConnectionMapHook from "../connection_map_hook";

// Merge evidence (EV-20) for the ConnectionMap hook's pair mode, the drawer's
// "Where the vehicle waits" mini-map. The Leaflet runtime is stubbed exactly as
// `transfer_map_hook_test.js` stubs it, so nothing here loads a tile or reaches a
// tile host. These cases reject FH-16 for CL-15: the two ends of a handoff, the
// one-stop case, a redraw, a teardown, and the unavailable state that must not
// throw.
const STREET_URL = "/map/tiles/osm-bright/{z}/{x}/{y}";

const ARRIVAL = {
  stop_id: "42W",
  name: "42nd & Washington",
  lat: 40.7527,
  lon: -73.9772,
  color: "#0B5FFF",
};
const DEPARTURE = {
  stop_id: "12E",
  name: "12th & Elm",
  lat: 40.7483,
  lon: -73.9819,
  color: "#BE123C",
};

function layerStub() {
  const layer = { addTo: vi.fn(), on: vi.fn(), bindTooltip: vi.fn(), removeLayer: vi.fn() };
  layer.addTo.mockReturnValue(layer);
  return layer;
}

function markerStub() {
  const marker = { addTo: vi.fn(), on: vi.fn() };
  marker.addTo.mockReturnValue(marker);
  return marker;
}

function controlStub(options) {
  const control = { options, addTo: vi.fn() };
  control.addTo.mockReturnValue(control);
  return control;
}

function tileLayerStub() {
  const layer = layerStub();
  layer.redraw = vi.fn();
  return layer;
}

function groupStub() {
  const group = { addTo: vi.fn(), clearLayers: vi.fn(), removeLayer: vi.fn() };
  group.addTo.mockReturnValue(group);
  return group;
}

function createLeaflet() {
  // Every control the hook constructs lands here, so a case can assert on the
  // one it added without knowing how `L.Control.extend` was stubbed.
  const controls = [];
  const map = {
    fitBounds: vi.fn(),
    getZoom: vi.fn(() => 14),
    invalidateSize: vi.fn(),
    remove: vi.fn(),
    setView: vi.fn(),
    setZoom: vi.fn(),
  };

  const L = {
    map: vi.fn(() => map),
    tileLayer: vi.fn(() => tileLayerStub()),
    layerGroup: vi.fn(() => groupStub()),
    circleMarker: vi.fn(() => layerStub()),
    polyline: vi.fn(() => layerStub()),
    marker: vi.fn(() => markerStub()),
    divIcon: vi.fn((options) => ({ ...options })),
    latLngBounds: vi.fn((southWest, northEast) => ({ southWest, northEast })),
  };

  // The stub constructor records each instance, gives it the prototype the hook
  // supplied, and answers `addTo` the way a real control does.
  L.Control = {
    extend: vi.fn((proto) => {
      const Control = function () {
        controls.push(this);
        Object.assign(this, proto);
      };

      Control.prototype.addTo = function () {
        this.addedTo = true;
        return this;
      };

      return Control;
    }),
  };

  // `L.control.zoom({position})` is how the map moves Leaflet's own zoom control
  // to the corner the application uses.
  L.control = {
    zoom: vi.fn((options) => {
      const control = controlStub(options);
      controls.push(control);
      return control;
    }),
  };

  return { L, map, controls };
}

function pairJson(pair) {
  return JSON.stringify(pair);
}

function buildRegion() {
  const region = document.createElement("div");
  const root = document.createElement("div");
  root.id = "connection-pair-map";

  const notice = document.createElement("p");
  notice.id = "connection-pair-map-unavailable";
  notice.dataset.role = "connection-map-unavailable";
  notice.className = "hidden";

  region.appendChild(root);
  region.appendChild(notice);
  document.body.appendChild(region);
  return { region, root, notice };
}

function mountHook(root) {
  const hook = { ...ConnectionMapHook, el: root };
  hook.mounted();
  return hook;
}

function circleMarkers(L) {
  return L.circleMarker.mock.calls.map(([latlng, options]) => ({ latlng, options }));
}

function polylines(L) {
  return L.polyline.mock.calls.map(([points, options]) => ({ points, options }));
}

function tooltips(L, method) {
  return L[method].mock.results
    .map((result) => result.value.bindTooltip.mock.calls[0])
    .filter(Boolean)
    .map(([content, options]) => ({ content, options }));
}

describe("connection_map_hook pair mode", () => {
  it("mounts one non-interactive street map bounded to the drawer's zoom ceiling", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { root } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: DEPARTURE, meters: 370 });

    mountHook(root);

    expect(L.map).toHaveBeenCalledTimes(1);
    const [, options] = L.map.mock.calls[0];
    expect(options.dragging).toBe(false);
    expect(options.scrollWheelZoom).toBe(false);
    expect(options.doubleClickZoom).toBe(false);
    expect(options.boxZoom).toBe(false);
    expect(options.zoomControl).toBe(false);
    expect(options.maxZoom).toBe(19);
    expect(L.tileLayer.mock.calls[0][0]).toBe(STREET_URL);
    expect(root.dataset.state).toBe("ready");
    expect(map.setView).not.toHaveBeenCalled();
  });

  it("draws two route-coloured dots and one dashed cased connector with the distance", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: DEPARTURE, meters: 370 });

    mountHook(root);

    // Each dot is a white case plus the route's own fill, so two markers per stop.
    expect(L.circleMarker).toHaveBeenCalledTimes(4);
    const dots = circleMarkers(L).filter(({ options }) => options.fillColor !== "#ffffff");
    expect(dots.map(({ options }) => options.fillColor)).toEqual([
      "#0B5FFF",
      "#BE123C",
    ]);

    const labels = tooltips(L, "circleMarker");
    expect(labels).toHaveLength(2);
    expect(labels[0].content).toContain("Arrives");
    expect(labels[0].content).toContain("42nd &amp; Washington");
    expect(labels[0].options.permanent).toBe(true);
    expect(labels[1].content).toContain("Departs");
    expect(labels[1].content).toContain("12th &amp; Elm");
    expect(labels[1].options.permanent).toBe(true);

    // One connector, drawn twice: a white casing and the dashed accent over it.
    expect(L.polyline).toHaveBeenCalledTimes(2);
    const [casing, dashed] = polylines(L);
    expect(casing.options.dashArray).toBeUndefined();
    expect(casing.options.color).toBe("#ffffff");
    expect(casing.points).toEqual([
      [ARRIVAL.lat, ARRIVAL.lon],
      [DEPARTURE.lat, DEPARTURE.lon],
    ]);
    expect(dashed.options.dashArray).toBe("6 6");
    expect(dashed.options.interactive).toBe(false);

    // The distance rides the dashed line, because the casing carries no meaning.
    const lineTip = L.polyline.mock.results[1].value.bindTooltip.mock.calls[0];
    expect(lineTip[0]).toBe("370 m");
    expect(lineTip[1].permanent).toBe(true);
  });

  it("fits both stops with padding and a max zoom", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { root } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: DEPARTURE, meters: 370 });

    mountHook(root);

    expect(L.latLngBounds.mock.calls[0]).toEqual([
      [DEPARTURE.lat, DEPARTURE.lon],
      [ARRIVAL.lat, ARRIVAL.lon],
    ]);
    expect(map.fitBounds.mock.calls[0][1]).toEqual({
      padding: [32, 32],
      maxZoom: 18,
    });
  });

  it("draws one 'Arrives and departs' dot and no connector when both trips use one stop", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { root } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: ARRIVAL, meters: null });

    mountHook(root);

    expect(L.circleMarker).toHaveBeenCalledTimes(2);
    expect(L.polyline).not.toHaveBeenCalled();

    const [label] = tooltips(L, "circleMarker");
    expect(label.content).toContain("Arrives and departs");
    expect(label.content).not.toContain("Departs<");

    // One point has no box to fit, so it gets a fixed close view.
    expect(map.fitBounds).not.toHaveBeenCalled();
    expect(map.setView.mock.calls[0]).toEqual([[ARRIVAL.lat, ARRIVAL.lon], 17]);
  });

  it("redraws from a new data-pair on updated(), clearing the previous layers", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: DEPARTURE, meters: 370 });

    const hook = mountHook(root);
    expect(L.circleMarker).toHaveBeenCalledTimes(4);

    const group = L.layerGroup.mock.results[0].value;
    const moved = {
      stop_id: "31S",
      name: "31st & State",
      lat: 40.7451,
      lon: -73.9892,
      color: "#046A38",
    };
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: moved, meters: 180 });
    hook.updated();

    expect(group.clearLayers).toHaveBeenCalledTimes(2);
    expect(L.circleMarker).toHaveBeenCalledTimes(8);
    const redrawn = tooltips(L, "circleMarker");
    expect(redrawn).toHaveLength(4);
    expect(redrawn[2].content).toContain("42nd &amp; Washington");
    expect(redrawn[3].content).toContain("31st &amp; State");
  });

  it("removes the map and disconnects the resize observer in destroyed()", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const observe = vi.fn();
    const disconnect = vi.fn();
    vi.stubGlobal(
      "ResizeObserver",
      class {
        constructor(callback) {
          this.callback = callback;
        }
        observe = observe;
        disconnect = disconnect;
      },
    );
    const { root } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: DEPARTURE, meters: 370 });

    const hook = mountHook(root);
    expect(observe).toHaveBeenCalledWith(root);

    hook.destroyed();

    expect(disconnect).toHaveBeenCalledTimes(1);
    expect(map.remove).toHaveBeenCalledTimes(1);
    expect(hook._map).toBeNull();
  });

  it("marks the map unavailable and throws nothing when Leaflet is missing", () => {
    window.L = undefined;
    const { root, notice } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: DEPARTURE, meters: 370 });

    const hook = { ...ConnectionMapHook, el: root };

    expect(() => hook.mounted()).not.toThrow();
    expect(root.dataset.state).toBe("unavailable");
    expect(notice.classList.contains("hidden")).toBe(false);
    expect(hook._map).toBeUndefined();
  });

  it("marks the map unavailable when a tile errors and keeps it there on a late load", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root, notice } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({ arrival: ARRIVAL, departure: DEPARTURE, meters: 370 });

    mountHook(root);
    const layer = L.tileLayer.mock.results[0].value;
    const handler = (name) =>
      layer.on.mock.calls.find(([event]) => event === name)[1];

    handler("tileerror")();
    expect(root.dataset.state).toBe("unavailable");
    expect(notice.classList.contains("hidden")).toBe(false);

    // A tile that did load after the failure must not clear the degraded state.
    handler("tileload")();
    expect(root.dataset.state).toBe("unavailable");
  });

  it("draws nothing and says unavailable for a pair the version cannot place", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root, notice } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({
      arrival: { ...ARRIVAL, lat: null, lon: null },
      departure: DEPARTURE,
      meters: 370,
    });

    mountHook(root);

    expect(L.circleMarker).not.toHaveBeenCalled();
    expect(L.polyline).not.toHaveBeenCalled();
    expect(root.dataset.state).toBe("unavailable");
    expect(notice.classList.contains("hidden")).toBe(false);
  });

  it("draws nothing for unparseable JSON or a mode it does not own", () => {
    const { L } = createLeaflet();
    window.L = L;

    const broken = buildRegion();
    broken.root.dataset.mode = "pair";
    broken.root.dataset.pair = "{not json";
    mountHook(broken.root);
    expect(L.circleMarker).not.toHaveBeenCalled();
    expect(broken.root.dataset.state).toBe("unavailable");

    L.circleMarker.mockClear();
    L.marker.mockClear();
    const unknown = buildRegion();
    unknown.root.dataset.mode = "diagram";
    unknown.root.dataset.pair = pairJson({
      arrival: ARRIVAL,
      departure: DEPARTURE,
      meters: 370,
    });
    mountHook(unknown.root);
    expect(L.circleMarker).not.toHaveBeenCalled();
    expect(L.marker).not.toHaveBeenCalled();
    expect(unknown.root.dataset.state).toBe("unavailable");
  });

  it("drops a route colour the version never validated, keeping the dot legible", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildRegion();
    root.dataset.mode = "pair";
    root.dataset.pair = pairJson({
      arrival: { ...ARRIVAL, color: "javascript:alert(1)" },
      departure: DEPARTURE,
      meters: 370,
    });

    mountHook(root);

    const dots = circleMarkers(L).filter(({ options }) => options.fillColor !== "#ffffff");
    expect(dots[0].options.fillColor).not.toBe("javascript:alert(1)");
    expect(dots[0].options.fillColor).toMatch(/^#[0-9A-Fa-f]{3,6}$/);
  });
});

// Merge evidence (EV-24) for the ConnectionMap hook's network mode: the
// Connections workspace's map pane. The Leaflet runtime is stubbed exactly as in
// the pair-mode describes above, so nothing here loads a tile or reaches a tile
// host; the real browser path is EV-29. These cases reject FH-16 for CL-15: one
// marker per place the version can place, the two ways a marker can be used, the
// selection pins, the fit beside an open drawer, the cooperative wheel, and the
// unavailable state that must not take the list with it.
const UNION = {
  id: "UNION-SQ",
  name: "Union Square",
  lat: 40.7359,
  lon: -73.9911,
  count: 26,
  "review?": true,
  tokens: ["dG9rZW4"],
  anchor: "connections-place-x1",
};

const RIVERSIDE = {
  id: "RIVERSIDE",
  name: "Riverside Drive",
  lat: 40.7518,
  lon: -73.9742,
  count: 4,
  "review?": false,
  tokens: ["dG9rZW4Mg", "dG9rZW4Mw"],
  anchor: "connections-place-x2",
};

const UNPLACED = {
  id: "LOGAN-CIRCLE",
  name: "Logan Circle",
  lat: null,
  lon: null,
  count: 6,
  "review?": false,
  tokens: ["dG9rZW4NA"],
  anchor: "connections-place-x3",
};

function buildNetworkPane({ places, selection = null, width = 1200 } = {}) {
  const pane = document.createElement("div");
  pane.id = "connections-map-pane";

  const root = document.createElement("div");
  root.id = "connections-map";
  root.dataset.mode = "network";
  root.dataset.places = JSON.stringify(places || []);
  root.dataset.selection = JSON.stringify(selection);
  root.getBoundingClientRect = () => ({ right: width, left: 0, top: 0, bottom: 0 });

  const hint = document.createElement("p");
  hint.id = "connections-map-wheel-hint";
  hint.dataset.mapWheelHint = "";
  hint.hidden = true;

  const notice = document.createElement("div");
  notice.id = "connections-map-unavailable";
  notice.dataset.role = "connection-map-unavailable";
  notice.hidden = true;

  pane.appendChild(root);
  pane.appendChild(hint);
  pane.appendChild(notice);
  document.body.appendChild(pane);
  return { pane, root, hint, notice };
}

function markerIcons(L) {
  return L.marker.mock.calls.map(([latlng, options]) => ({ latlng, icon: options.icon }));
}

function markerClick(L, index) {
  return L.marker.mock.results[index].value.on.mock.calls.find(
    ([event]) => event === "click",
  )[1];
}

describe("connection_map_hook network mode", () => {
  it("mounts an interactive street map and draws one marker per placeable place", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildNetworkPane({ places: [UNION, RIVERSIDE, UNPLACED] });

    mountHook(root);

    const [, options] = L.map.mock.calls[0];
    expect(options.dragging).toBe(true);
    // A bare wheel would scroll the Blocks page out from under the reader.
    expect(options.scrollWheelZoom).toBe(false);
    expect(options.keyboard).toBe(true);
    // Leaflet's own control is added by the hook into the application's corner.
    expect(options.zoomControl).toBe(false);
    expect(options.maxZoom).toBe(19);
    expect(L.control.zoom).toHaveBeenCalledWith({ position: "topright" });

    // Logan Circle has no coordinates, so it is the pane's note to name rather
    // than a marker at (0, 0) somewhere off the coast of Africa.
    expect(L.marker).toHaveBeenCalledTimes(2);
    expect(markerIcons(L).map(({ latlng }) => latlng)).toEqual([
      [UNION.lat, UNION.lon],
      [RIVERSIDE.lat, RIVERSIDE.lon],
    ]);

    const [union, riverside] = markerIcons(L);
    expect(union.icon.html).toContain("26");
    expect(union.icon.html).toContain("Union Square");
    expect(union.icon.html).toContain("Union Square: 26 connections, some need review");
    expect(union.icon.iconSize).toEqual([44, 44]);
    expect(riverside.icon.html).toContain("Riverside Drive");
    expect(riverside.icon.html).not.toContain("needs review");
    // A real button inside the icon, so the marker is a keyboard target the way
    // the list row beside it is.
    expect(union.icon.html).toContain("<button");

    expect(root.dataset.state).toBe("ready");
  });

  it("opens the one group a place holds, and scrolls the list for a place holding several", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildNetworkPane({ places: [UNION, RIVERSIDE] });

    const section = document.createElement("section");
    section.id = RIVERSIDE.anchor;
    const firstRow = document.createElement("button");
    section.appendChild(firstRow);
    section.scrollIntoView = vi.fn();
    document.body.appendChild(section);

    const hook = mountHook(root);
    const push = vi.fn();
    hook.pushEvent = push;

    markerClick(L, 0)();
    expect(push).toHaveBeenCalledWith("open_group", { group: UNION.tokens[0] });
    expect(section.scrollIntoView).not.toHaveBeenCalled();

    markerClick(L, 1)();
    // Several groups is not a choice, so nothing is pushed and the list is
    // brought to the place with the keyboard on its first row.
    expect(push).toHaveBeenCalledTimes(1);
    expect(section.scrollIntoView).toHaveBeenCalledWith({ block: "start" });
    expect(document.activeElement).toBe(firstRow);
  });

  it("drops the selected place's own count marker so it cannot cover a pin label", () => {
    const { L } = createLeaflet();
    window.L = L;
    // The group's arrival stop is the place itself, so the count disc would be
    // drawn on the same pixel as the "Arrives" pin.
    const { root } = buildNetworkPane({
      places: [UNION, RIVERSIDE],
      selection: {
        arrival: { ...ARRIVAL, lat: RIVERSIDE.lat, lon: RIVERSIDE.lon },
        departure: { ...DEPARTURE },
      },
    });

    mountHook(root);

    // Both markers are built, and the one standing on a pin is taken back off
    // the map rather than left to hide the word under it.
    expect(L.marker).toHaveBeenCalledTimes(2);
    expect(L.layerGroup.mock.results[0].value.removeLayer).toHaveBeenCalledTimes(1);
  });

  it("draws the selection's arrival and departure pins with a dashed connector between them", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildNetworkPane({
      places: [UNION],
      selection: {
        arrival: { ...ARRIVAL },
        departure: { ...DEPARTURE },
      },
    });

    mountHook(root);

    // The two route-coloured pins, each a white case plus its own fill.
    const dots = circleMarkers(L).filter(({ options }) => options.fillColor !== "#ffffff");
    expect(dots.map(({ options }) => options.fillColor)).toEqual([
      "#0B5FFF",
      "#BE123C",
    ]);

    const labels = tooltips(L, "circleMarker");
    expect(labels).toHaveLength(2);
    expect(labels[0].content).toContain("Arrives");
    expect(labels[1].content).toContain("Departs");
    expect(labels.every(({ options }) => options.permanent)).toBe(true);
    // The labels sit above and below their own pin, away from the connector:
    // a handoff is often short enough that both stops land in the same stretch
    // of frame, and a label laid sideways lands on the other one.
    expect(labels[0].options.direction).toBe("top");
    expect(labels[1].options.direction).toBe("bottom");

    // One connector, a white casing and the dashed accent over it.
    expect(L.polyline).toHaveBeenCalledTimes(2);
    const [casing, dashed] = polylines(L);
    expect(casing.options.color).toBe("#ffffff");
    expect(dashed.options.dashArray).toBe("6 6");
    expect(dashed.points).toEqual([
      [ARRIVAL.lat, ARRIVAL.lon],
      [DEPARTURE.lat, DEPARTURE.lon],
    ]);
  });

  it("draws one pin and no connector when the selection's stops are one stop", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildNetworkPane({
      places: [UNION],
      selection: { arrival: { ...ARRIVAL }, departure: { ...ARRIVAL } },
    });

    mountHook(root);

    expect(L.polyline).not.toHaveBeenCalled();
    const [label] = tooltips(L, "circleMarker");
    expect(label.content).toContain("Arrives and departs");
  });

  it("fits the selection into the width an open connection drawer leaves uncovered", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    window.innerWidth = 1440;
    const { root } = buildNetworkPane({
      places: [UNION],
      selection: {
        arrival: { ...ARRIVAL },
        departure: { ...DEPARTURE },
      },
      width: 1440,
    });

    const drawer = document.createElement("aside");
    drawer.id = "gap-drawer";
    drawer.getBoundingClientRect = () => ({ width: 480, left: 960, right: 1440 });
    document.body.appendChild(drawer);

    mountHook(root);

    // The drawer covers the right 480 px of a 1440 px window, so the fit's right
    // padding carries that 480 px: without it the selection would be centred
    // under the drawer.
    expect(map.fitBounds.mock.calls[0][1]).toEqual({
      paddingTopLeft: [32, 32],
      paddingBottomRight: [32, 32 + 480],
      maxZoom: 17,
    });
  });

  it("fits every place, with no drawer padding, when nothing is selected", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    window.innerWidth = 1440;
    const { root } = buildNetworkPane({
      places: [UNION, RIVERSIDE],
      width: 1440,
    });

    mountHook(root);

    expect(L.latLngBounds.mock.calls[0]).toEqual([
      [UNION.lat, UNION.lon],
      [RIVERSIDE.lat, RIVERSIDE.lon],
    ]);
    expect(map.fitBounds.mock.calls[0][1]).toEqual({
      paddingTopLeft: [32, 32],
      paddingBottomRight: [32, 32],
      maxZoom: 17,
    });
  });

  it("zooms on a modified wheel and explains an unmodified one without zooming", () => {
    vi.useFakeTimers();
    const { L, map } = createLeaflet();
    window.L = L;
    const { root, hint } = buildNetworkPane({ places: [UNION] });

    mountHook(root);
    expect(L.Control.extend).toHaveBeenCalledTimes(1);

    root.dispatchEvent(new WheelEvent("wheel", { deltaY: -120, cancelable: true }));
    expect(hint.hidden).toBe(false);
    expect(map.setZoom).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1100);
    expect(hint.hidden).toBe(true);

    root.dispatchEvent(
      new WheelEvent("wheel", { deltaY: -120, ctrlKey: true, cancelable: true }),
    );
    expect(map.getZoom).toHaveBeenCalled();
    expect(map.setZoom).toHaveBeenCalledWith(15);
    expect(hint.hidden).toBe(true);
  });

  it("keeps the map ready through a filter re-render that changed nothing, and redraws when it did", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildNetworkPane({ places: [UNION] });

    const hook = mountHook(root);
    expect(L.marker).toHaveBeenCalledTimes(1);

    hook.updated();
    expect(L.marker).toHaveBeenCalledTimes(1);

    root.dataset.places = JSON.stringify([UNION, RIVERSIDE]);
    hook.updated();
    expect(L.marker).toHaveBeenCalledTimes(3);
  });

  it("shows the pane's unavailable notice and throws nothing when Leaflet is missing", () => {
    window.L = undefined;
    const { root, notice } = buildNetworkPane({ places: [UNION] });

    const hook = { ...ConnectionMapHook, el: root };

    expect(() => hook.mounted()).not.toThrow();
    expect(root.dataset.state).toBe("unavailable");
    expect(notice.hidden).toBe(false);
    expect(hook._map).toBeUndefined();
  });

  it("shows the unavailable notice on a tile error and keeps the list's own text", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root, notice } = buildNetworkPane({ places: [UNION] });

    mountHook(root);
    const layer = L.tileLayer.mock.results[0].value;
    const handler = (name) =>
      layer.on.mock.calls.find(([event]) => event === name)[1];

    handler("tileerror")();
    expect(root.dataset.state).toBe("unavailable");
    expect(notice.hidden).toBe(false);
    // The list beside it is untouched: the failure is the map's own.
    expect(root.parentElement.id).toBe("connections-map-pane");

    handler("tileload")();
    expect(root.dataset.state).toBe("unavailable");
  });

  it("draws no marker and stays ready when no place has coordinates", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { root } = buildNetworkPane({ places: [UNPLACED] });

    mountHook(root);

    expect(L.marker).not.toHaveBeenCalled();
    expect(map.fitBounds).not.toHaveBeenCalled();
    // Every place is named in the pane's own note instead, so this is an empty
    // map rather than a failed one.
    expect(root.dataset.state).toBe("ready");
  });

  it("escapes a place name the version stored with markup in it", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { root } = buildNetworkPane({
      places: [{ ...UNION, name: '<img src=x onerror="alert(1)">' }],
    });

    mountHook(root);

    const [{ icon }] = markerIcons(L);
    expect(icon.html).not.toContain("<img");
    expect(icon.html).toContain("&lt;img");
  });

  it("destroys the map, its fit control and its wheel listener in destroyed()", () => {
    const { L, map, controls } = createLeaflet();
    window.L = L;
    const disconnect = vi.fn();
    vi.stubGlobal(
      "ResizeObserver",
      class {
        observe = vi.fn();
        disconnect = disconnect;
      },
    );
    const { root } = buildNetworkPane({ places: [UNION] });

    const hook = mountHook(root);
    const fit = controls.find((control) => control.onAdd);

    expect(fit).toBeDefined();
    expect(fit.addedTo).toBe(true);

    hook.destroyed();

    expect(disconnect).toHaveBeenCalledTimes(1);
    expect(map.remove).toHaveBeenCalledTimes(1);
    expect(hook._map).toBeNull();
    expect(hook._wheelHandler).toBeNull();
  });
});

let originalLeaflet;

beforeEach(() => {
  originalLeaflet = window.L;
  document.body.innerHTML = "";
});

afterEach(() => {
  window.L = originalLeaflet;
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
