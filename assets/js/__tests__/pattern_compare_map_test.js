/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import PatternCompareMap, { layersFor, shouldFit } from "../pattern_compare_map";

// Merge evidence for the Compare patterns map (spec 19, step 20). jsdom has
// no Leaflet, so the cases establish the hook's own contract: what the server
// payload may become on the canvas (series and connector styles, marker
// shapes, pins, end chips), that the map fits once and only a `compare:frame`
// moves it again (FH-29), that row hover and selection ring their stops, that
// a marker click links back to the row, and how the pane degrades when the
// runtime or its tiles are missing. The rendered pixels are the journey
// lane's contract (EV-21); nothing here loads a tile or talks to the server.

const PAYLOAD = {
  stops: [
    { stop_id: "S1", name: "Depot", coordinates: [-124.0, 44.5], served: "both" },
    { stop_id: "S2", name: "Otter Rock", coordinates: [-124.1, 44.6], served: "a" },
    { stop_id: "S3", name: "Depoe Bay", coordinates: [-124.2, 44.7], served: "b" },
  ],
  sections: [
    {
      from_stop_id: "S1",
      to_stop_id: "S2",
      series: "both",
      style: "path",
      points: [
        [-124.0, 44.5],
        [-124.05, 44.55],
        [-124.1, 44.6],
      ],
    },
    {
      from_stop_id: "S2",
      to_stop_id: "S3",
      series: "a",
      style: "connector",
      points: [
        [-124.1, 44.6],
        [-124.2, 44.7],
      ],
    },
    {
      from_stop_id: "S2",
      to_stop_id: "S1",
      series: "b",
      style: "path",
      points: [
        [-124.1, 44.6],
        [-124.0, 44.5],
      ],
    },
  ],
  ends: {
    a: { first_stop_id: "S1", last_stop_id: "S2" },
    b: { first_stop_id: "S1", last_stop_id: "S3" },
  },
  pins: [
    { n: 1, stop_id: "S2" },
    { n: 2, stop_id: "S3" },
  ],
};

// The full geometry the first render fits to: every line's points and every
// stop marker.
const FIT_LATLNGS = [
  [44.5, -124.0],
  [44.55, -124.05],
  [44.6, -124.1],
  [44.6, -124.1],
  [44.7, -124.2],
  [44.6, -124.1],
  [44.5, -124.0],
  [44.5, -124.0],
  [44.6, -124.1],
  [44.7, -124.2],
];

describe("layersFor", () => {
  it("maps a shared section to neutral, A to navy, B to cyan and a connector to dashed", () => {
    const { lines } = layersFor(PAYLOAD);
    const [shared, connector, b] = lines;

    expect(lines).toHaveLength(3);
    expect(shared.series).toBe("both");
    expect(shared.style).toBe("path");
    expect(shared.options.color).toBe("#7a85ac");
    expect(shared.options.dashArray).toBeNull();
    expect(shared.casing).toEqual({
      color: "#ffffff",
      weight: 7,
      dashArray: null,
      lineCap: "round",
      lineJoin: "round",
    });

    expect(connector.series).toBe("a");
    expect(connector.style).toBe("connector");
    expect(connector.options.color).toBe("#0a1330");
    expect(connector.options.dashArray).toBe("9 7");
    expect(connector.casing.dashArray).toBe("9 7");

    expect(b.series).toBe("b");
    expect(b.options.color).toBe("#2c8888");
    expect(b.options.dashArray).toBeNull();
  });

  it("keeps a line's points in Leaflet order and refuses a line with under two", () => {
    const { lines } = layersFor({
      sections: [
        {
          from_stop_id: "S1",
          to_stop_id: "S2",
          series: "a",
          style: "path",
          points: [[-124.0, 44.5]],
        },
        {
          from_stop_id: "S1",
          to_stop_id: "S2",
          series: "a",
          style: "connector",
          points: null,
        },
      ],
    });

    expect(lines).toEqual([]);

    const [line] = layersFor(PAYLOAD).lines;
    expect(line.latlngs[0]).toEqual([44.5, -124.0]);
    expect(line.key).toBe("line-0-S1-S2");
  });

  it("returns circle markers for only-A stops and square markers for only-B stops", () => {
    const stops = new Map(layersFor(PAYLOAD).stops.map((stop) => [stop.stop_id, stop]));

    expect(stops.get("S2").shape).toBe("circle");
    expect(stops.get("S2").served).toBe("a");
    expect(stops.get("S2").options.fillColor).toBe("#0a1330");

    expect(stops.get("S3").shape).toBe("square");
    expect(stops.get("S3").served).toBe("b");

    expect(stops.get("S1").shape).toBe("circle");
    expect(stops.get("S1").options.fillColor).toBe("#ffffff");
    expect(stops.get("S1").options.color).toBe("#0a1330");
  });

  it("drops stops, pins, chips and sections the canvas cannot draw", () => {
    const layers = layersFor({
      stops: [
        { stop_id: "S1", coordinates: null, served: "a" },
        { stop_id: "", coordinates: [1, 2], served: "b" },
        { stop_id: "S3", coordinates: ["west", 44], served: "both" },
      ],
      sections: [
        {
          from_stop_id: "S1",
          to_stop_id: "S2",
          series: "a",
          style: "path",
          points: [[-124.0, 44.5]],
        },
      ],
      ends: { a: { first_stop_id: "S1", last_stop_id: "S2" }, b: null },
      pins: [{ n: 1, stop_id: "S1" }, { n: 2, stop_id: "S3" }, { n: 3 }],
    });

    expect(layers).toEqual({ lines: [], stops: [], pins: [], chips: [] });
  });

  it("numbers pins and places an A/B chip at each pattern's first and last stop", () => {
    const { pins, chips } = layersFor(PAYLOAD);

    expect(pins.map((pin) => pin.n)).toEqual([1, 2]);
    expect(pins[0].latlng).toEqual([44.6, -124.1]);
    expect(chips.map((chip) => chip.key)).toEqual([
      "a-first-S1",
      "a-last-S2",
      "b-first-S1",
      "b-last-S3",
    ]);
    expect(chips[0].label).toBe("A");
    expect(chips[0].anchor).toEqual([-16, -14]);
    expect(chips[3].anchor).toEqual([16, 14]);
  });

  it("accepts an absent or unreadable payload as nothing to draw", () => {
    const empty = { lines: [], stops: [], pins: [], chips: [] };
    expect(layersFor(null)).toEqual(empty);
    expect(layersFor({})).toEqual(empty);
  });
});

describe("shouldFit", () => {
  it("is true for the first render and false afterwards", () => {
    expect(shouldFit({ fitted: false })).toBe(true);
    expect(shouldFit({})).toBe(true);
    expect(shouldFit({ fitted: true })).toBe(false);
  });
});

// A recording stand-in for the Leaflet runtime: jsdom has none, and the hook's
// own contract is what these cases assert, not Leaflet's behaviour.
function leafletStub() {
  const stub = { maps: [], tiles: [], lines: [], circles: [], markers: [] };

  const overlay = (latlng, options) => {
    const handlers = new Map();
    return {
      latlng,
      options,
      on(event, handler) {
        handlers.set(event, handler);
        return this;
      },
      fire(event) {
        handlers.get(event)?.();
      },
      addTo(map) {
        map.layers.push(this);
        return this;
      },
    };
  };

  stub.map = vi.fn((container, options) => {
    const map = {
      container,
      options,
      groups: [],
      layers: [],
      setView: vi.fn(() => map),
      fitBounds: vi.fn(() => map),
      remove: vi.fn(() => {
        map.removed = true;
      }),
    };
    stub.maps.push(map);
    return map;
  });

  stub.tileLayer = vi.fn((url, options) => {
    const layer = overlay(null, options);
    layer.url = url;
    layer.redraw = vi.fn();
    stub.tiles.push(layer);
    return layer;
  });

  stub.layerGroup = vi.fn(() => ({
    layers: [],
    addTo(map) {
      map.groups.push(this);
      return this;
    },
    addLayer(layer) {
      this.layers.push(layer);
      return this;
    },
    clearLayers() {
      this.layers = [];
    },
  }));

  stub.polyline = vi.fn((latlngs, options) => {
    const layer = overlay(latlngs, options);
    stub.lines.push(layer);
    return layer;
  });

  stub.circleMarker = vi.fn((latlng, options) => {
    const layer = overlay(latlng, options);
    stub.circles.push(layer);
    return layer;
  });

  stub.marker = vi.fn((latlng, options) => {
    const layer = overlay(latlng, options);
    stub.markers.push(layer);
    return layer;
  });

  stub.divIcon = vi.fn((options) => options);
  stub.latLngBounds = vi.fn((latlngs) => ({ latlngs }));

  return stub;
}

function mapFixture(payload) {
  document.body.innerHTML = `
    <div id="compare-map-pane">
      <div
        id="compare-map"
        class="relative h-[360px] overflow-hidden rounded-card border border-subtle"
      ></div>
    </div>`;

  const element = document.getElementById("compare-map");
  if (payload !== undefined) element.dataset.mapPayload = JSON.stringify(payload);
  return element;
}

let hooks = [];
let listeners = [];
let originalLeaflet;

function mount(payload = PAYLOAD) {
  const hook = Object.create(PatternCompareMap);
  hook.el = mapFixture(payload);
  hook.pushEvent = vi.fn();
  hook.mounted();
  hooks.push(hook);
  return hook;
}

function collectEvents(name) {
  const details = [];
  const listener = (event) => details.push(event.detail);
  window.addEventListener(name, listener);
  listeners.push(() => window.removeEventListener(name, listener));
  return details;
}

function dispatch(name, detail) {
  window.dispatchEvent(new CustomEvent(name, { detail }));
}

beforeEach(() => {
  originalLeaflet = window.L;
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  window.L = originalLeaflet;
  for (const remove of listeners.splice(0)) remove();
  hooks = [];
  document.body.innerHTML = "";
  vi.restoreAllMocks();
});

describe("PatternCompareMap", () => {
  it("draws the payload over the authenticated tiles and fits once", () => {
    const stub = leafletStub();
    window.L = stub;

    const hook = mount();
    const map = stub.maps[0];

    expect(map.options.scrollWheelZoom).toBe(false);
    expect(stub.tiles[0].url).toBe("/map/tiles/osm-bright/{z}/{x}/{y}");
    expect(stub.tiles[0].options.attribution).toContain("OpenStreetMap");
    expect(map.setView).toHaveBeenCalledWith([20, 0], 2);

    expect(map.fitBounds).toHaveBeenCalledTimes(1);
    expect(map.fitBounds.mock.calls[0][0].latlngs).toEqual(FIT_LATLNGS);
    expect(map.fitBounds.mock.calls[0][1]).toEqual({ padding: [24, 24], maxZoom: 17 });

    // Two polylines (casing and line) per section, three markers.
    expect(hook._lines.layers).toHaveLength(6);
    expect(hook._stops.layers).toHaveLength(3);
  });

  it("redraws a patched payload without refitting the view", () => {
    const stub = leafletStub();
    window.L = stub;

    const hook = mount();
    const map = stub.maps[0];

    hook.el.dataset.mapPayload = JSON.stringify({
      ...PAYLOAD,
      sections: [PAYLOAD.sections[0]],
      pins: [],
      ends: {},
    });
    hook.updated();

    expect(hook._lines.layers).toHaveLength(2);
    expect(hook._pins.layers).toEqual([]);
    expect(hook._chips.layers).toEqual([]);
    expect(map.fitBounds).toHaveBeenCalledTimes(1);

    hook.el.dataset.mapPayload = "not json {";
    hook.updated();

    expect(hook._lines.layers).toEqual([]);
    expect(hook._stops.layers).toEqual([]);
    expect(map.fitBounds).toHaveBeenCalledTimes(1);
  });

  it("frames on compare:frame only, and clears the row ring", () => {
    const stub = leafletStub();
    window.L = stub;

    const hook = mount();
    const map = stub.maps[0];

    dispatch("compare:select-stop", { stopId: "S2" });
    expect(hook._rings.layers).toHaveLength(1);

    dispatch("compare:frame", { stopIds: ["S2", "S3"] });
    expect(map.fitBounds).toHaveBeenCalledTimes(2);
    expect(map.fitBounds.mock.calls[1][0].latlngs).toEqual([
      [44.6, -124.1],
      [44.7, -124.2],
    ]);
    expect(hook._rings.layers).toEqual([]);

    // A single stop cannot form bounds; an unknown one fits nothing.
    dispatch("compare:frame", { stopIds: ["S1"] });
    expect(map.setView).toHaveBeenLastCalledWith([44.5, -124.0], 17);

    dispatch("compare:frame", { stopIds: ["gone", null] });
    expect(map.fitBounds).toHaveBeenCalledTimes(2);
    expect(map.setView).toHaveBeenCalledTimes(2);
  });

  it("rings the hot and selected stops, and drops both on leave", () => {
    const stub = leafletStub();
    window.L = stub;

    const hook = mount();

    dispatch("compare:hot", { stopId: "S2" });
    expect(hook._rings.layers.map((layer) => layer.options.radius)).toEqual([14]);
    expect(hook._rings.layers[0].options.fillColor).toBe("#7dd3cb");

    dispatch("compare:select-stop", { stopId: "S3" });
    expect(hook._rings.layers.map((layer) => layer.options.radius)).toEqual([14, 12]);
    expect(hook._rings.layers[1].options.color).toBe("#c81870");

    dispatch("compare:hot", { stopId: null });
    expect(hook._rings.layers.map((layer) => layer.options.radius)).toEqual([12]);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("dispatches compare:row-for-stop on a marker click and pushes no server event", () => {
    const stub = leafletStub();
    window.L = stub;

    const hook = mount();
    const requests = collectEvents("compare:row-for-stop");

    const aStop = hook._stops.layers.find((layer) => layer.latlng[1] === -124.1);
    aStop.fire("click");

    const bStop = hook._stops.layers.find(
      (layer) => layer.options.icon?.className === "compare-map-stop-square",
    );
    bStop.fire("click");

    hook._pins.layers[0].fire("click");

    expect(requests).toEqual([
      { stopId: "S2" },
      { stopId: "S3" },
      { stopId: "S2" },
    ]);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("draws the numbered difference pins and the A/B end chips", () => {
    const stub = leafletStub();
    window.L = stub;

    const hook = mount();

    expect(hook._pins.layers).toHaveLength(2);
    expect(hook._pins.layers[0].options.title).toBe("Difference 1");
    expect(hook._pins.layers[0].options.icon.html).toContain(">1</span>");
    expect(hook._pins.layers[1].options.icon.html).toContain(">2</span>");

    expect(hook._chips.layers).toHaveLength(4);
    expect(hook._chips.layers[0].options.interactive).toBe(false);
    expect(hook._chips.layers[0].options.icon.iconAnchor).toEqual([25, 23]);
    expect(hook._chips.layers[1].options.icon.iconAnchor).toEqual([25, -5]);
    expect(hook._chips.layers[2].options.icon.iconAnchor).toEqual([-7, 23]);
    expect(hook._chips.layers[3].options.icon.iconAnchor).toEqual([-7, -5]);
    expect(hook._chips.layers[0].options.icon.html).toContain(">A</span>");
    expect(hook._chips.layers[2].options.icon.html).toContain(">B</span>");
  });

  it("renders the unavailable notice when Leaflet is missing and does not throw", () => {
    delete window.L;

    const hook = mount();
    const notice = document.getElementById("compare-map-off");

    expect(hook._map).toBeNull();
    expect(notice).not.toBeNull();
    expect(notice.hidden).toBe(false);
    expect(notice.textContent).toContain("The map is unavailable");
    expect(notice.textContent).toContain("The stop list, differences and times still work.");
    expect(notice.querySelector("#compare-map-retry").textContent).toContain("Retry map");
    expect(getComputedStyle(document.getElementById("compare-map")).position).toBe("relative");

    expect(() => dispatch("compare:frame", { stopIds: ["S1"] })).not.toThrow();
    expect(() => dispatch("compare:hot", { stopId: "S2" })).not.toThrow();
  });

  it("mounts the runtime on Retry map when Leaflet arrives late", () => {
    delete window.L;

    const hook = mount();
    const stub = leafletStub();
    window.L = stub;

    document.getElementById("compare-map-retry").click();

    expect(hook._map).toBe(stub.maps[0]);
    expect(hook._lines.layers).toHaveLength(6);
    expect(stub.maps[0].fitBounds).toHaveBeenCalledTimes(1);
    expect(document.getElementById("compare-map-off").hidden).toBe(true);
  });

  it("shows the unavailable notice on a tile error and retries the tiles", () => {
    const stub = leafletStub();
    window.L = stub;

    mount();
    const notice = document.getElementById("compare-map-off");

    expect(notice.hidden).toBe(true);

    stub.tiles[0].fire("tileerror");
    expect(notice.hidden).toBe(false);

    stub.tiles[0].fire("tileload");
    expect(notice.hidden).toBe(true);

    stub.tiles[0].fire("tileerror");
    notice.querySelector("#compare-map-retry").click();

    expect(stub.tiles[0].redraw).toHaveBeenCalledTimes(1);
    expect(notice.hidden).toBe(true);
  });

  it("clears a reused container before mounting its own notice", () => {
    const stub = leafletStub();
    window.L = stub;

    const element = mapFixture(PAYLOAD);
    element._leaflet_id = 42;
    element.insertAdjacentHTML("beforeend", "<div>stale map</div>");

    const hook = Object.create(PatternCompareMap);
    hook.el = element;
    hook.pushEvent = vi.fn();
    hook.mounted();
    hooks.push(hook);

    expect(element._leaflet_id).toBeUndefined();
    expect(element.querySelectorAll("#compare-map-off")).toHaveLength(1);
    expect(element.textContent).not.toContain("stale map");
  });

  it("stops listening and removes the map when destroyed", () => {
    const stub = leafletStub();
    window.L = stub;

    const hook = mount();
    const map = stub.maps[0];

    hook.destroyed();

    expect(map.removed).toBe(true);

    dispatch("compare:frame", { stopIds: ["S2", "S3"] });
    dispatch("compare:hot", { stopId: "S2" });

    expect(map.fitBounds).toHaveBeenCalledTimes(1);
    expect(hook._rings.layers).toEqual([]);
  });
});
