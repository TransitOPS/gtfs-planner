/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import FareZoneMapHook, {
  idsInBounds,
  markerLabel,
} from "../fare_zone_map_hook";

const ZONES = {
  A: { name: "Central", color: "#1f5fbf" },
  B: { name: "Eastbank", color: "#0d737d" },
  Zone1: { name: "Zone one", color: "#4b1f78" },
};

// The wire shape of `FareZones.list_stop_points/2`:
// [id, stop_id, stop_name, lat, lon, zone_id, parent_station]
const POINTS = [
  ["stop-a", "S1", "Union Square", 0.05, 0.05, "A", null],
  ["stop-b", "S2", "Eastbank", 0.06, 0.08, "Zone1", null],
  ["stop-c", "S3", "Airport", 0.3, 0.4, null, null],
];

const READY = {
  points: POINTS,
  zones: ZONES,
  selected: [],
  filter: { kind: "all", zone_id: null },
};

const UNASSIGNED_COLOR = "#586479";
const SELECTION_COLOR = "#c81870";

function recordingContext() {
  const texts = [];
  return {
    texts,
    font: "",
    textAlign: "",
    textBaseline: "",
    fillStyle: "",
    setTransform: vi.fn(),
    clearRect: vi.fn(),
    fillText: vi.fn((text, x, y) => texts.push({ text, x, y })),
  };
}

/**
 * Stubbed Leaflet. Only the external library boundary is faked; the hook's own
 * logic runs unmodified. The projection is a linear stand-in whose scale can be
 * changed to imitate zoom or pan, so a box's geographic extent depends on the
 * current view rather than on container pixels.
 */
function createLeafletStub({ zoom = 13, scale = 1000, size = { x: 800, y: 500 } } = {}) {
  const stub = {
    zoom,
    scale,
    size,
    maps: [],
    tiles: [],
    markers: [],
    canvasCalls: 0,
  };

  stub.map = vi.fn((container, options) => {
    const handlers = new Map();
    const map = {
      container,
      options,
      layers: [],
      dragging: {
        enabled: true,
        enable() {
          this.enabled = true;
        },
        disable() {
          this.enabled = false;
        },
      },
      createPane: vi.fn((name, parent) => {
        const pane = document.createElement("div");
        pane.className = `leaflet-pane leaflet-${name.toLowerCase()}-pane`;
        (parent || container).appendChild(pane);
        return pane;
      }),
      getSize: () => ({ x: stub.size.x, y: stub.size.y }),
      getZoom: () => stub.zoom,
      latLngToContainerPoint: vi.fn(([lat, lon]) => ({
        x: lon * stub.scale,
        y: lat * stub.scale,
      })),
      containerPointToLatLng: vi.fn(([x, y]) => ({
        lat: y / stub.scale,
        lng: x / stub.scale,
      })),
      mouseEventToContainerPoint: vi.fn((event) => ({
        x: event.clientX,
        y: event.clientY,
      })),
      fitBounds: vi.fn(() => map),
      invalidateSize: vi.fn(() => map),
      zoomIn: vi.fn(() => map),
      zoomOut: vi.fn(() => map),
      on: vi.fn((event, handler) => {
        handlers.set(event, [...(handlers.get(event) || []), handler]);
        return map;
      }),
      off: vi.fn((event, handler) => {
        handlers.set(
          event,
          (handlers.get(event) || []).filter((fn) => fn !== handler),
        );
        return map;
      }),
      fire: (event) => (handlers.get(event) || []).forEach((fn) => fn()),
      addLayer: vi.fn((layer) => {
        map.layers.push(layer);
        return map;
      }),
      removeLayer: vi.fn((layer) => {
        map.layers = map.layers.filter((item) => item !== layer);
      }),
      remove: vi.fn(() => {
        map.removed = true;
      }),
    };
    stub.maps.push(map);
    return map;
  });

  stub.canvas = vi.fn(() => {
    stub.canvasCalls += 1;
    return { renderer: "canvas" };
  });

  stub.tileLayer = vi.fn((url, options) => {
    const handlers = new Map();
    const layer = {
      url,
      options,
      on: vi.fn((event, handler) => {
        handlers.set(event, [...(handlers.get(event) || []), handler]);
        return layer;
      }),
      fire: (event) => (handlers.get(event) || []).forEach((fn) => fn()),
      addTo: vi.fn((map) => {
        map.addLayer(layer);
        return layer;
      }),
      redraw: vi.fn(),
    };
    stub.tiles.push(layer);
    return layer;
  });

  stub.circleMarker = vi.fn((latlng, options) => {
    const handlers = new Map();
    const marker = {
      latlng,
      options: { ...options },
      styles: [],
      tooltip: null,
      on: vi.fn((event, handler) => {
        handlers.set(event, [...(handlers.get(event) || []), handler]);
        return marker;
      }),
      off: vi.fn((event, handler) => {
        handlers.set(
          event,
          (handlers.get(event) || []).filter((fn) => fn !== handler),
        );
        return marker;
      }),
      fire: (event) => (handlers.get(event) || []).forEach((fn) => fn()),
      addTo: vi.fn((map) => {
        map.addLayer(marker);
        marker.map = map;
        return marker;
      }),
      setStyle: vi.fn((style) => {
        marker.styles.push(style);
        marker.options = { ...marker.options, ...style };
        return marker;
      }),
      bindTooltip: vi.fn((text, tooltipOptions) => {
        marker.tooltip = { text, options: tooltipOptions };
        return marker;
      }),
      setTooltipContent: vi.fn((text) => {
        marker.tooltip = { ...(marker.tooltip || {}), text };
        return marker;
      }),
      bringToFront: vi.fn(() => marker),
    };
    stub.markers.push(marker);
    return marker;
  });

  return stub;
}

// Point markers and their selection rings are both circle markers; the hook
// draws rings non-interactive so a ring never swallows a stop's click.
const pointMarkersOn = (map) =>
  map.layers.filter((layer) => layer.options && layer.options.radius === 12);
const ringsOn = (map) =>
  map.layers.filter((layer) => layer.options && layer.options.radius === 18);

function renderRoot() {
  document.body.innerHTML = `
    <div id="fare-zone-map">
      <button type="button" data-map-mode="select" aria-pressed="true">Select stops</button>
      <button type="button" data-map-mode="pan" aria-pressed="false">Pan map</button>
      <button type="button" data-map-zoom="in" aria-label="Zoom in">＋</button>
      <button type="button" data-map-zoom="out" aria-label="Zoom out">−</button>
      <button type="button" data-map-fit>Fit</button>
      <div data-map-canvas></div>
      <div data-map-hint></div>
    </div>`;
  return document.getElementById("fare-zone-map");
}

function mount({ reply = READY } = {}) {
  const el = renderRoot();
  const pushes = [];
  const subscriptions = {};
  const hook = {
    ...FareZoneMapHook,
    el,
    pushEvent: vi.fn((name, payload, callback) => {
      pushes.push({ name, payload });
      if (typeof callback === "function" && reply !== null) callback(reply);
    }),
    handleEvent: vi.fn((name, callback) => {
      subscriptions[name] = callback;
    }),
  };

  FareZoneMapHook.mounted.call(hook);

  return {
    hook,
    el,
    canvas: el.querySelector("[data-map-canvas]"),
    map: hook._map,
    pushes,
    subscriptions,
    pushed: (name) => pushes.filter((push) => push.name === name),
  };
}

function drag(el, from, to) {
  el.dispatchEvent(
    new MouseEvent("pointerdown", {
      clientX: from.x,
      clientY: from.y,
      button: 0,
      bubbles: true,
    }),
  );
  window.dispatchEvent(
    new MouseEvent("pointermove", {
      clientX: to.x,
      clientY: to.y,
      bubbles: true,
    }),
  );
  window.dispatchEvent(
    new MouseEvent("pointerup", { clientX: to.x, clientY: to.y, bubbles: true }),
  );
}

let originalLeaflet;
let originalGetContext;

beforeEach(() => {
  originalLeaflet = window.L;
  originalGetContext = Object.getOwnPropertyDescriptor(
    HTMLCanvasElement.prototype,
    "getContext",
  );
  Object.defineProperty(HTMLCanvasElement.prototype, "getContext", {
    configurable: true,
    writable: true,
    value: function (type) {
      if (type !== "2d") return null;
      if (!this.__context) this.__context = recordingContext();
      return this.__context;
    },
  });
});

afterEach(() => {
  window.L = originalLeaflet;
  if (originalGetContext) {
    Object.defineProperty(
      HTMLCanvasElement.prototype,
      "getContext",
      originalGetContext,
    );
  }
  document.body.innerHTML = "";
});

describe("markerLabel", () => {
  it("keeps up to two characters and shortens longer zone IDs", () => {
    expect(markerLabel("A")).toBe("A");
    expect(markerLabel("AB")).toBe("AB");
    expect(markerLabel("Zone1")).toBe("Zo…");
  });

  it("keeps an imported ID's bytes, including a leading space", () => {
    expect(markerLabel(" A")).toBe(" A");
  });

  it("reads an absent zone as a dash", () => {
    expect(markerLabel(null)).toBe("–");
    expect(markerLabel(undefined)).toBe("–");
    expect(markerLabel("")).toBe("–");
  });
});

describe("idsInBounds", () => {
  const points = [
    { id: "inside", lat: 0.15, lon: 0.15 },
    { id: "edge", lat: 0.2, lon: 0.2 },
    { id: "outside", lat: 0.3, lon: 0.3 },
  ];
  const topLeft = { lat: 0.1, lon: 0.1 };
  const bottomRight = { lat: 0.2, lon: 0.2 };

  it("returns the same ids for a box dragged in either direction, edges included", () => {
    expect(idsInBounds(points, [topLeft, bottomRight])).toEqual([
      "inside",
      "edge",
    ]);
    expect(idsInBounds(points, [bottomRight, topLeft])).toEqual([
      "inside",
      "edge",
    ]);
  });

  it("excludes a point outside the box on either axis", () => {
    const wideShortBox = [
      { lat: 0, lon: 0 },
      { lat: 0.05, lon: 0.5 },
    ];
    expect(idsInBounds(points, wideShortBox)).toEqual([]);
  });

  it("returns no ids without a complete box", () => {
    expect(idsInBounds(points, [])).toEqual([]);
    expect(idsInBounds(points, [topLeft])).toEqual([]);
    expect(idsInBounds(null, [topLeft, bottomRight])).toEqual([]);
  });
});

describe("FareZoneMap mounted lifecycle", () => {
  it("asks for its snapshot on mount and draws the reply's points", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { canvas, map, pushed } = mount();

    const ready = pushed("fare_zone_map_ready");
    expect(ready).toHaveLength(1);
    expect(ready[0].payload).toEqual({});

    const markers = pointMarkersOn(map);
    expect(markers).toHaveLength(3);
    expect(markers[0].options.color).toBe("#1f5fbf");
    expect(markers[1].options.color).toBe("#4b1f78");
    expect(markers[2].options.color).toBe(UNASSIGNED_COLOR);
    expect(markers[0].options.fillColor).toBe("#ffffff");
    expect(markers[0].options.radius).toBe(12);
    expect(markers[0].latlng).toEqual([0.05, 0.05]);

    expect(markers[0].tooltip.text).toBe("Union Square · Central");
    expect(markers[1].tooltip.text).toBe("Eastbank · Zone one");
    expect(markers[2].tooltip.text).toBe("Airport · Unassigned");

    expect(canvas.dataset.mapState).toBe("ready");
    expect(canvas.dataset.pointCount).toBe("3");
    expect(canvas.dataset.selectedCount).toBe("0");

    expect(map.fitBounds).toHaveBeenCalledWith(
      [
        [0.05, 0.05],
        [0.3, 0.4],
      ],
      { padding: [24, 24] },
    );
  });

  it("uses the canvas renderer and the proxied osm-bright tile layer", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { map } = mount();

    expect(stub.canvasCalls).toBe(1);
    expect(map.options.renderer).toEqual({ renderer: "canvas" });
    expect(stub.tiles).toHaveLength(1);
    expect(stub.tiles[0].url).toBe("/map/tiles/osm-bright/{z}/{x}/{y}");
    expect(stub.tiles[0].options.attribution).toContain("OpenStreetMap");
    expect(stub.tiles[0].options.attribution).toContain("Geoapify");
    expect(map.options.zoomControl).toBe(false);
  });

  it("hydrates every mount from its own reply", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const first = mount();
    expect(first.canvas.dataset.pointCount).toBe("3");

    const second = mount({
      reply: {
        points: [POINTS[0]],
        zones: ZONES,
        selected: ["stop-a"],
        filter: { kind: "all", zone_id: null },
      },
    });

    expect(second.pushed("fare_zone_map_ready")).toHaveLength(1);
    expect(second.canvas.dataset.pointCount).toBe("1");
    expect(second.canvas.dataset.selectedCount).toBe("1");
    // The second map drew its own single point; nothing came from the first.
    expect(pointMarkersOn(second.map)).toHaveLength(1);
    expect(pointMarkersOn(first.map)).toHaveLength(3);
  });

  it("applies a later snapshot to the drawn state", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { canvas, map, subscriptions } = mount();
    subscriptions["fare_zone_snapshot"]({
      points: [POINTS[2]],
      zones: ZONES,
      selected: ["stop-c"],
      filter: { kind: "zone", zone_id: "A" },
    });

    expect(pointMarkersOn(map)).toHaveLength(1);
    expect(pointMarkersOn(map)[0].options.opacity).toBe(0.35);
    expect(ringsOn(map)).toHaveLength(1);
    expect(canvas.dataset.pointCount).toBe("1");
    expect(canvas.dataset.selectedCount).toBe("1");
    expect(canvas.dataset.mapState).toBe("ready");
  });

  it("reports an unavailable map when Leaflet is missing", () => {
    window.L = undefined;

    const { canvas, map, pushed } = mount();

    expect(canvas.dataset.mapState).toBe("unavailable");
    expect(map).toBeNull();
    expect(pushed("map_unavailable")).toHaveLength(1);
    expect(pushed("fare_zone_map_ready")).toHaveLength(0);
  });

  it("pushes map_unavailable once for tile errors", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { pushed } = mount();
    const tiles = stub.tiles[0];

    tiles.fire("tileerror");
    tiles.fire("tileerror");

    const unavailable = pushed("map_unavailable");
    expect(unavailable).toHaveLength(1);
    expect(unavailable[0].payload).toEqual({ reason: expect.any(String) });
  });
});

describe("FareZoneMap selection", () => {
  it("applies a selection delta to the ring and data-selected-count", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { canvas, map, subscriptions } = mount();

    subscriptions["fare_zone_selection"]({ added: ["stop-a"], removed: [] });

    const rings = ringsOn(map);
    expect(rings).toHaveLength(1);
    expect(rings[0].options.radius).toBe(18);
    expect(rings[0].options.color).toBe(SELECTION_COLOR);
    expect(rings[0].options.weight).toBe(3);
    expect(rings[0].latlng).toEqual([0.05, 0.05]);
    expect(rings[0].options.interactive).toBe(false);
    expect(pointMarkersOn(map)[0].bringToFront).toHaveBeenCalled();
    expect(canvas.dataset.selectedCount).toBe("1");

    subscriptions["fare_zone_selection"]({
      added: [],
      removed: ["stop-a"],
    });

    expect(ringsOn(map)).toHaveLength(0);
    expect(map.removeLayer).toHaveBeenCalledWith(rings[0]);
    expect(canvas.dataset.selectedCount).toBe("0");
  });

  it("counts a selected stop that the map cannot draw", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { canvas, map, subscriptions } = mount();
    subscriptions["fare_zone_selection"]({ added: ["stop-no-location"] });

    expect(canvas.dataset.selectedCount).toBe("1");
    expect(ringsOn(map)).toHaveLength(0);
  });

  it("recolors exactly the stops a points delta names", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { map, subscriptions } = mount();
    const markers = pointMarkersOn(map);

    subscriptions["fare_zone_points_changed"]({ changes: [["stop-a", "B"]] });

    expect(markers[0].options.color).toBe("#0d737d");
    expect(markers[0].tooltip.text).toBe("Union Square · Eastbank");
    expect(markers[0].styles).toHaveLength(1);
    expect(markers[1].styles).toHaveLength(0);
    expect(markers[2].styles).toHaveLength(0);

    subscriptions["fare_zone_points_changed"]({ changes: [["stop-b", null]] });

    expect(markers[1].options.color).toBe(UNASSIGNED_COLOR);
    expect(markers[1].tooltip.text).toBe("Eastbank · Unassigned");
  });

  it("recolors every marker of a zone from a zones delta", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { map, subscriptions } = mount();
    const markers = pointMarkersOn(map);

    subscriptions["fare_zone_zones"]({
      zones: {
        ...ZONES,
        A: { name: "Central", color: "#8a5a0e" },
        B: { name: "Eastbank", color: "#267548" },
      },
    });

    expect(markers[0].options.color).toBe("#8a5a0e");
    expect(markers[1].options.color).toBe("#4b1f78");
    expect(markers[2].options.color).toBe(UNASSIGNED_COLOR);
    expect(markers[1].styles).toHaveLength(1);

    // A delta that names one zone leaves the other zones' colours alone.
    subscriptions["fare_zone_zones"]({
      zones: { Zone1: { name: "Zone one", color: "#267548" } },
    });

    expect(markers[1].options.color).toBe("#267548");
    expect(markers[0].options.color).toBe("#8a5a0e");
    expect(markers[2].options.color).toBe(UNASSIGNED_COLOR);
  });

  it("dims the markers outside the current filter", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { map, subscriptions } = mount();
    const markers = pointMarkersOn(map);
    expect(markers[0].options.opacity).toBe(1);

    subscriptions["fare_zone_filter"]({
      filter: { kind: "unassigned", zone_id: null },
    });
    expect(markers[0].options.opacity).toBe(0.35);
    expect(markers[1].options.opacity).toBe(0.35);
    expect(markers[2].options.opacity).toBe(1);

    subscriptions["fare_zone_filter"]({
      filter: { kind: "zone", zone_id: "Zone1" },
    });
    expect(markers[0].options.opacity).toBe(0.35);
    expect(markers[1].options.opacity).toBe(1);
    expect(markers[2].options.opacity).toBe(0.35);

    subscriptions["fare_zone_filter"]({
      filter: { kind: "all", zone_id: null },
    });
    expect(markers[0].options.opacity).toBe(1);
  });

  it("toggles a stop on a marker click in Select mode only", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { el, map, pushed } = mount();
    const marker = pointMarkersOn(map)[0];

    marker.fire("click");
    expect(pushed("toggle_stop")).toHaveLength(1);
    expect(pushed("toggle_stop")[0].payload).toEqual({ id: "stop-a" });

    el.querySelector('[data-map-mode="pan"]').click();
    marker.fire("click");
    expect(pushed("toggle_stop")).toHaveLength(1);
  });
});

describe("FareZoneMap box selection", () => {
  const dragReply = {
    points: [
      ["stop-in", "S4", "Inside", 0.2, 0.2, "A", null],
      ["stop-out", "S5", "Outside", 0.05, 0.05, "A", null],
    ],
    zones: ZONES,
    selected: [],
    filter: { kind: "all", zone_id: null },
  };

  it("starts in Select mode with the map's own dragging disabled", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { el, map } = mount({ reply: dragReply });

    expect(
      el.querySelector('[data-map-mode="select"]').getAttribute("aria-pressed"),
    ).toBe("true");
    expect(map.dragging.enabled).toBe(false);
    expect(el.querySelector("[data-map-hint]").textContent).toBe(
      "Click stops or drag a box to select. The box does not create a zone boundary.",
    );
  });

  it("pushes the ids of the projected box corners in Select mode", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { canvas, map, pushed } = mount({ reply: dragReply });

    drag(canvas, { x: 100, y: 100 }, { x: 300, y: 300 });

    // The stub projects container pixels to lat/lon on a 1/1000 scale, so this
    // box covers 0.1–0.3 on both axes: comparing raw pixels would select
    // nothing, because every point's coordinates are far below 100.
    expect(map.containerPointToLatLng).toHaveBeenCalledWith([100, 100]);
    expect(map.containerPointToLatLng).toHaveBeenCalledWith([300, 300]);
    expect(pushed("select_stops")).toHaveLength(1);
    expect(pushed("select_stops")[0].payload).toEqual({ ids: ["stop-in"] });
  });

  it("selects the same stops for a box dragged in the reverse direction", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { canvas, pushed } = mount({ reply: dragReply });

    drag(canvas, { x: 300, y: 300 }, { x: 100, y: 100 });

    expect(pushed("select_stops")).toHaveLength(1);
    expect(pushed("select_stops")[0].payload).toEqual({ ids: ["stop-in"] });
  });

  it("ignores a pointer drag shorter than the threshold", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { canvas, pushed } = mount({ reply: dragReply });

    drag(canvas, { x: 100, y: 100 }, { x: 103, y: 100 });

    expect(pushed("select_stops")).toHaveLength(0);
  });

  it("uses the current projection for each box, not cached pixels", () => {
    const stub = createLeafletStub({ scale: 1000 });
    window.L = stub;

    const farReply = {
      points: [["stop-far", "S6", "Far", 0.5, 0.5, "A", null]],
      zones: ZONES,
      selected: [],
      filter: { kind: "all", zone_id: null },
    };
    const { canvas, pushed } = mount({ reply: farReply });

    drag(canvas, { x: 100, y: 100 }, { x: 300, y: 300 });
    expect(pushed("select_stops")[0].payload).toEqual({ ids: [] });

    // A zoom or pan changes what those container pixels project to; the same
    // gesture must now select the point.
    stub.scale = 500;
    drag(canvas, { x: 100, y: 100 }, { x: 300, y: 300 });
    expect(pushed("select_stops")[1].payload).toEqual({ ids: ["stop-far"] });
  });

  it("selects nothing while Pan mode owns the drag", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { el, canvas, map, pushed } = mount({ reply: dragReply });

    el.querySelector('[data-map-mode="pan"]').click();

    expect(
      el.querySelector('[data-map-mode="pan"]').getAttribute("aria-pressed"),
    ).toBe("true");
    expect(
      el.querySelector('[data-map-mode="select"]').getAttribute("aria-pressed"),
    ).toBe("false");
    expect(map.dragging.enabled).toBe(true);
    expect(el.querySelector("[data-map-hint]").textContent).toBe(
      "Drag the map to move. Use + and − to zoom.",
    );

    drag(canvas, { x: 100, y: 100 }, { x: 300, y: 300 });

    expect(pushed("select_stops")).toHaveLength(0);
  });
});

describe("FareZoneMap labels and controls", () => {
  it("draws one canvas label per in-view point at zoom 14 or closer", () => {
    const stub = createLeafletStub({ zoom: 14 });
    window.L = stub;

    const { canvas } = mount();
    const labelCanvas = canvas.querySelector("canvas");

    expect(labelCanvas).toBeTruthy();
    // Its own pane, not a child of the container: a pane inside the map pane
    // would be offset by every pan.
    expect(labelCanvas.parentElement).not.toBe(canvas);
    expect(labelCanvas.__context.texts.map((entry) => entry.text)).toEqual([
      "A",
      "Zo…",
      "–",
    ]);
    expect(labelCanvas.__context.texts[0].x).toBe(50);
    expect(labelCanvas.__context.texts[0].y).toBe(51);
  });

  it("clears the labels below zoom 14 and redraws on a view change", () => {
    const stub = createLeafletStub({ zoom: 12 });
    window.L = stub;

    const { canvas, map } = mount();
    const ctx = canvas.querySelector("canvas").__context;

    expect(ctx.texts).toHaveLength(0);
    expect(ctx.clearRect).toHaveBeenCalled();

    stub.zoom = 14;
    map.fire("moveend");
    expect(ctx.texts).toHaveLength(3);

    stub.zoom = 13;
    map.fire("zoomend");
    expect(ctx.texts).toHaveLength(3);

    stub.zoom = 15;
    map.fire("resize");
    expect(ctx.texts).toHaveLength(6);
  });

  it("wires the zoom and fit controls", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { el, map } = mount();

    el.querySelector('[data-map-zoom="in"]').click();
    el.querySelector('[data-map-zoom="out"]').click();
    expect(map.zoomIn).toHaveBeenCalledTimes(1);
    expect(map.zoomOut).toHaveBeenCalledTimes(1);

    map.fitBounds.mockClear();
    el.querySelector("[data-map-fit]").click();
    expect(map.fitBounds).toHaveBeenCalledWith(
      [
        [0.05, 0.05],
        [0.3, 0.4],
      ],
      { padding: [24, 24] },
    );
  });
});

describe("FareZoneMap teardown", () => {
  it("removes the map and every listener it added", () => {
    const stub = createLeafletStub();
    window.L = stub;

    const { el, canvas, map, hook, pushed } = mount();

    // Passthrough spies: the listeners are really added and removed, and every
    // call is recorded so a listener that outlives the hook is visible.
    const addSpy = vi.spyOn(window, "addEventListener");
    const removeSpy = vi.spyOn(window, "removeEventListener");

    drag(canvas, { x: 100, y: 100 }, { x: 300, y: 300 });
    const added = addSpy.mock.calls.map(([type, handler]) => [type, handler]);
    expect(added.length).toBeGreaterThan(0);

    hook.destroyed();

    expect(map.remove).toHaveBeenCalled();
    added.forEach(([type, handler]) => {
      expect(removeSpy.mock.calls).toContainEqual([type, handler]);
    });

    const addedBeforeTeardown = addSpy.mock.calls.length;
    canvas.dispatchEvent(
      new MouseEvent("pointerdown", { clientX: 10, clientY: 10, button: 0 }),
    );
    expect(addSpy.mock.calls).toHaveLength(addedBeforeTeardown);

    el.querySelector('[data-map-mode="pan"]').click();
    expect(el.querySelector("[data-map-hint]").textContent).toBe(
      "Click stops or drag a box to select. The box does not create a zone boundary.",
    );
    expect(pushed("select_stops")).toHaveLength(1);
    expect(canvas.querySelector("canvas")).toBeNull();

    addSpy.mockRestore();
    removeSpy.mockRestore();
  });
});
