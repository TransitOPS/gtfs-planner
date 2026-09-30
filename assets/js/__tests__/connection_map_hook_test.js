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
  const layer = { addTo: vi.fn(), on: vi.fn(), bindTooltip: vi.fn() };
  layer.addTo.mockReturnValue(layer);
  return layer;
}

function tileLayerStub() {
  const layer = layerStub();
  layer.redraw = vi.fn();
  return layer;
}

function groupStub() {
  const group = { addTo: vi.fn(), clearLayers: vi.fn() };
  group.addTo.mockReturnValue(group);
  return group;
}

function createLeaflet() {
  const map = {
    fitBounds: vi.fn(),
    invalidateSize: vi.fn(),
    remove: vi.fn(),
    setView: vi.fn(),
  };

  const L = {
    map: vi.fn(() => map),
    tileLayer: vi.fn(() => tileLayerStub()),
    layerGroup: vi.fn(() => groupStub()),
    circleMarker: vi.fn(() => layerStub()),
    polyline: vi.fn(() => layerStub()),
    latLngBounds: vi.fn((southWest, northEast) => ({ southWest, northEast })),
  };

  return { L, map };
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
    expect(redrawn[2].content).toContain("12th &amp; Elm");
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
    const network = buildRegion();
    network.root.dataset.mode = "network";
    network.root.dataset.pair = pairJson({
      arrival: ARRIVAL,
      departure: DEPARTURE,
      meters: 370,
    });
    mountHook(network.root);
    expect(L.circleMarker).not.toHaveBeenCalled();
    expect(network.root.dataset.state).toBe("unavailable");
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

let originalLeaflet;

beforeEach(() => {
  originalLeaflet = window.L;
  document.body.innerHTML = "";
});

afterEach(() => {
  window.L = originalLeaflet;
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
