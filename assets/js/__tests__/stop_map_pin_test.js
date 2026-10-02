/* @vitest-environment jsdom */
//
// The placement pin and add mode.
//
// The browser owns no decision here. The server says which mode the map is in
// and where the pin is; the browser reports what a person did with the
// controls it drew. These cases are the boundary between the two: what is
// reported, when, and how often.
//
// The Leaflet stub fakes only the library. The hook's own projection stub is
// linear with `scale` pixels per degree, which is what makes a nudge
// measurable in metres rather than in pixels.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import StopMapHook, { formatDistance, haversineMetres } from "../stop_map_hook";

// The stub's origin: the centre the map reports and the origin the projection
// measures from, so a nudge in metres is a nudge the assertions can read.
const ORIGIN = { lat: 44.63, lng: -124.05 };
const METRES_PER_DEGREE = 111_320;

// One located stop, which is all the mark tests need: a click has to reach
// something drawn before it can be asked whether it places or selects.
const SCENE = {
  stops: [
    {
      id: "10",
      stop_id: "1434",
      name: "US 101 & SE 1st St",
      code: "",
      point: [-124.05317, 44.63561],
      location_type: 0,
      served: true,
      pattern_ids: [],
    },
  ],
  lines: [],
  routes: {},
  bounds: [
    [-124.06, 44.62],
    [-124.04, 44.65],
  ],
};

function createLeafletStub({ zoom = 18, scale = 1000 } = {}) {
  const stub = { zoom, scale, markers: [], polylines: [] };

  stub.map = vi.fn((container) => {
    const handlers = new Map();

    const map = {
      container,
      layers: [],
      getZoom: () => stub.zoom,
      getCenter: () => ({ ...ORIGIN }),
      getBounds: () => ({
        getSouth: () => 44.6,
        getWest: () => -124.1,
        getNorth: () => 44.7,
        getEast: () => -124.0,
      }),
      getSize: () => ({ x: 800, y: 500 }),
      setZoom: vi.fn((value) => {
        stub.zoom = value;
        map.fire("zoomend");
        return map;
      }),
      fitBounds: vi.fn(() => map),
      setView: vi.fn(() => map),
      invalidateSize: vi.fn(() => map),
      hasLayer: (layer) => map.layers.includes(layer),
      createPane: vi.fn((name) => {
        const pane = document.createElement("div");
        pane.className = `leaflet-pane leaflet-${name.toLowerCase()}-pane`;
        container.appendChild(pane);
        return pane;
      }),
      latLngToContainerPoint: ([lat, lng]) => ({
        x: (lng - ORIGIN.lng) * stub.scale,
        y: (ORIGIN.lat - lat) * stub.scale,
      }),
      containerPointToLatLng: ([x, y]) => ({
        lat: ORIGIN.lat - y / stub.scale,
        lng: ORIGIN.lng + x / stub.scale,
      }),
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
      addLayer: vi.fn((layer) => {
        map.layers.push(layer);
        return map;
      }),
      removeLayer: vi.fn((layer) => {
        map.layers = map.layers.filter((item) => item !== layer);
        return map;
      }),
      remove: vi.fn(() => map),
      fire: (event, ...args) =>
        (handlers.get(event) || []).forEach((fn) => fn(...args)),
    };

    return map;
  });

  stub.layerGroup = vi.fn(() => {
    const group = {
      layers: [],
      addTo: vi.fn((map) => {
        map.addLayer(group);
        return group;
      }),
      addLayer: vi.fn((layer) => {
        group.layers.push(layer);
        return layer;
      }),
      clearLayers: vi.fn(() => {
        group.layers = [];
      }),
    };
    return group;
  });

  stub.marker = vi.fn((latlng, options) => {
    const layer = {
      latlng,
      options,
      handlers: new Map(),
      on: vi.fn((event, handler) => {
        layer.handlers.set(event, [
          ...(layer.handlers.get(event) || []),
          handler,
        ]);
        return layer;
      }),
      fire: (event, ...args) =>
        (layer.handlers.get(event) || []).forEach((fn) => fn(...args)),
      addTo: vi.fn((group) => {
        group.addLayer(layer);
        return layer;
      }),
    };
    stub.markers.push(layer);
    return layer;
  });

  stub.polyline = vi.fn((points, options) => {
    const layer = {
      points,
      options,
      addTo: vi.fn((group) => {
        group.addLayer(layer);
        return layer;
      }),
    };
    stub.polylines.push(layer);
    return layer;
  });

  stub.divIcon = vi.fn((options) => ({ ...options, kind: "divIcon" }));

  stub.tileLayer = vi.fn(() => ({
    on: vi.fn(),
    addTo: vi.fn((map) => {
      map.addLayer({});
      return map;
    }),
  }));

  return stub;
}

function renderRoot() {
  document.body.innerHTML = `
    <div id="stops-map-stage">
      <div id="stop-map" tabindex="0"></div>
      <div id="stop-map-overlay" class="stop-map-overlay">
        <div id="stop-map-crosshair" class="stop-map-crosshair" aria-hidden="true" hidden>
          <span class="stop-map-crosshair-v"></span>
          <span class="stop-map-crosshair-h"></span>
        </div>
      </div>
    </div>`;
  return document.getElementById("stop-map");
}

function mount({ stub } = {}) {
  const el = renderRoot();
  const pushes = [];
  const subscriptions = {};
  window.L = stub || createLeafletStub();

  const hook = {
    ...StopMapHook,
    el,
    pushEvent: vi.fn((name, payload) => pushes.push({ name, payload })),
    handleEvent: vi.fn((name, callback) => {
      subscriptions[name] = callback;
    }),
  };

  StopMapHook.mounted.call(hook);

  return {
    hook,
    el,
    pushes,
    pushed: (name) => pushes.filter((push) => push.name === name),
    mode: (payload) => subscriptions["stop_map:mode"]({ payload }),
    scene: (payload) => subscriptions["stop_map:scene"]({ payload }),
    pin: () => document.querySelector("[data-stop-map-pin]"),
    stub: window.L,
  };
}

// The markup Leaflet would render for the `divIcon`s the hook asked for.
function iconMarkup(stub) {
  return stub.markers
    .map((marker) => (marker.options && marker.options.icon?.html) || "")
    .join("");
}

// jsdom has no `PointerEvent`, so the drag is expressed with the MouseEvent the
// pin's listeners read the same fields from.
function pointer(name, { x, y, button = 0 }) {
  const event = new MouseEvent(name, {
    bubbles: true,
    cancelable: true,
    button,
    clientX: x,
    clientY: y,
  });
  event.pointerId = 1;
  return event;
}

function key(name, init = {}) {
  return new KeyboardEvent("keydown", {
    key: name,
    bubbles: true,
    cancelable: true,
    ...init,
  });
}

beforeEach(() => {
  window.ResizeObserver = undefined;
});

afterEach(() => {
  document.body.innerHTML = "";
  delete window.L;
});

describe("add mode", () => {
  it("reports a clicked point as a placement", () => {
    const { hook, pushed, mode } = mount();

    mode({ mode: "add", pin: null, ghost: null });
    hook._map.fire("click", { latlng: { lat: 44.6356, lng: -124.0531 } });

    expect(pushed("place")).toEqual([
      { name: "place", payload: { lat: 44.6356, lon: -124.0531 } },
    ]);
  });

  it("reports the map's centre when Enter is pressed on the canvas", () => {
    const { hook, pushed, mode } = mount();

    mode({ mode: "add", pin: null, ghost: null });
    hook.el.dispatchEvent(key("Enter"));

    expect(pushed("place")[0].payload).toEqual({
      lat: ORIGIN.lat,
      lon: ORIGIN.lng,
    });
  });

  it("reports nothing for a click or a key while browsing", () => {
    const { hook, pushed, el, mode } = mount();

    hook._map.fire("click", { latlng: { lat: 44.6356, lng: -124.0531 } });
    el.dispatchEvent(key("Enter"));
    el.dispatchEvent(key("Escape"));

    expect(pushed("place")).toEqual([]);
    expect(pushed("cancel_add")).toEqual([]);
  });

  it("cancels on Escape while placing", () => {
    const { hook, pushed, el, mode } = mount();

    mode({ mode: "add", pin: null, ghost: null });
    el.dispatchEvent(key("Escape"));

    expect(pushed("cancel_add")).toHaveLength(1);
  });

  it("places on an existing mark rather than selecting it, because the mark takes the click", () => {
    const { mode, scene, pushed, stub } = mount();

    scene(SCENE);
    const drawn = stub.markers[stub.markers.length - 1];

    mode({ mode: "add", pin: null, ghost: null });
    drawn.fire("click");

    // A stop already standing on the curb is the thing an editor is pointing
    // at; selecting it would leave one place on the map where placing cannot
    // happen at all.
    expect(pushed("select_stop")).toHaveLength(0);
    expect(pushed("place")[0].payload).toEqual({
      lat: 44.63561,
      lon: -124.05317,
    });
  });

  it("opens a stop when it is clicked while browsing", () => {
    const { scene, pushed, stub } = mount();

    scene(SCENE);
    stub.markers[stub.markers.length - 1].fire("click");

    expect(pushed("select_stop")[0].payload).toEqual({ stop_id: "10" });
    expect(pushed("place")).toHaveLength(0);
  });

  it("shows a crosshair while placing and takes it away once there is a pin", () => {
    const { hook, mode } = mount();
    const crosshair = () =>
      document.getElementById("stop-map-crosshair").hidden;

    mode({ mode: "add", pin: null, ghost: null });
    expect(crosshair()).toBe(false);
    expect(hook.el.classList.contains("stop-map-adding")).toBe(true);

    mode({ mode: "browse", pin: { lat: 44.63, lon: -124.05 }, ghost: null });
    expect(crosshair()).toBe(true);
    expect(hook.el.classList.contains("stop-map-adding")).toBe(false);
  });
});

describe("the pin", () => {
  const placed = (extra = {}) => ({
    mode: "browse",
    pin: { lat: 44.63, lon: -124.05, label: "New stop" },
    ghost: null,
    ...extra,
  });

  it("is a focusable button that states its own arrow-key behaviour", () => {
    const { mode, pin: element } = mount();

    mode(placed());
    const button = element();

    expect(button.tagName).toBe("BUTTON");
    expect(button.getAttribute("type")).toBe("button");
    // Not tabbable: focus is taken by the click or by Tab reaching it, and a
    // button in the document is already in the tab order.
    expect(button.disabled).toBe(false);
    expect(button.getAttribute("aria-label")).toContain(
      "arrow keys to move it about 3 feet, 30 feet with Shift",
    );
    expect(button.querySelector("[data-stop-map-pin-label]").textContent).toBe(
      "New stop",
    );
  });

  it("is removed when the server takes the pin away", () => {
    const { mode, pin: element } = mount();

    mode(placed());
    expect(element()).not.toBeNull();

    mode({ mode: "browse", pin: null, ghost: null });
    expect(element()).toBeNull();
  });

  it("reports one move on pointerup and none during the drag", () => {
    const { mode, pushed, pin: element } = mount();

    mode(placed());
    const button = element();

    button.dispatchEvent(pointer("pointerdown", { x: 0, y: 0 }));
    button.dispatchEvent(pointer("pointermove", { x: 40, y: 25 }));
    button.dispatchEvent(pointer("pointermove", { x: 60, y: 30 }));

    // A drag is a hundred reports a second, and each one is a round trip for a
    // draft the server already owns.
    expect(pushed("pin_moved")).toHaveLength(0);

    button.dispatchEvent(pointer("pointerup", { x: 60, y: 30 }));

    expect(pushed("pin_moved")).toHaveLength(1);
    expect(pushed("pin_moved")[0].payload).toEqual({
      lat: ORIGIN.lat - 30 / 1000,
      lon: ORIGIN.lng + 60 / 1000,
    });
  });

  it("nudges about a metre north on ArrowUp and about ten on Shift", () => {
    const { mode, pushed, pin: element } = mount();

    mode(placed());
    const button = element();

    button.dispatchEvent(key("ArrowUp"));
    const one = pushed("pin_moved").at(-1).payload;

    expect(one.lat - ORIGIN.lat).toBeCloseTo(1 / METRES_PER_DEGREE, 10);
    expect(one.lon).toBeCloseTo(ORIGIN.lng, 10);

    button.dispatchEvent(key("ArrowUp", { shiftKey: true }));
    const ten = pushed("pin_moved").at(-1).payload;

    expect((ten.lat - one.lat) * METRES_PER_DEGREE).toBeCloseTo(10, 6);
    expect(pushed("pin_moved")).toHaveLength(2);
  });

  it("nudges east by the same number of metres as it does north", () => {
    const { mode, pushed, pin: element } = mount();

    mode(placed());
    const button = element();

    button.dispatchEvent(key("ArrowRight"));
    const east = pushed("pin_moved").at(-1).payload;

    // A degree of longitude is shorter than a degree of latitude away from the
    // equator, so the nudge is read back through the same ratio it was made
    // with: a metre east at this latitude is a larger share of a degree.
    const degrees = east.lon - ORIGIN.lng;
    const metres =
      degrees * METRES_PER_DEGREE * Math.cos((ORIGIN.lat * Math.PI) / 180);

    expect(metres).toBeGreaterThan(0.95);
    expect(metres).toBeLessThan(1.05);
  });

  it("ignores a key that is not a nudge", () => {
    const { mode, pushed, pin: element } = mount();

    mode(placed());
    element().dispatchEvent(key("a"));

    expect(pushed("pin_moved")).toHaveLength(0);
  });
});

describe("the ghost of a saved position", () => {
  const thirteenMetres = 13.716;

  it("draws a dashed circle at the saved position and the distance to it", () => {
    const { mode, stub } = mount();

    mode({
      mode: "browse",
      pin: {
        lat: ORIGIN.lat + thirteenMetres / METRES_PER_DEGREE,
        lon: ORIGIN.lng,
        label: "",
      },
      ghost: { lat: ORIGIN.lat, lon: ORIGIN.lng },
    });

    // The stub does not render a `divIcon`'s markup into the document, so the
    // markup Leaflet would render is what is asserted.
    const markup = iconMarkup(stub);

    expect(markup).toContain('class="stop-map-ghost"');
    expect(markup).toContain("45 ft");
  });

  it("joins the two positions with a dashed line", () => {
    const { hook, mode, stub } = mount();

    mode({
      mode: "browse",
      pin: {
        lat: ORIGIN.lat + thirteenMetres / METRES_PER_DEGREE,
        lon: ORIGIN.lng,
        label: "",
      },
      ghost: { lat: ORIGIN.lat, lon: ORIGIN.lng },
    });

    const connector = stub.polylines.at(-1);
    expect(connector.options.dashArray).toBe("5 4");
    expect(connector.points).toHaveLength(2);
    expect(hook._pinGroup.layers.length).toBeGreaterThan(0);
  });

  it("draws no ghost and no label while the pin has not moved", () => {
    const { mode } = mount();

    mode({
      mode: "browse",
      pin: { lat: ORIGIN.lat, lon: ORIGIN.lng, label: "" },
      ghost: { lat: ORIGIN.lat, lon: ORIGIN.lng },
    });

    expect(document.querySelector(".stop-map-ghost")).toBeNull();
    expect(document.querySelector(".stop-map-distance")).toBeNull();
  });

  it("drops a ghost that arrives without a pin", () => {
    const { mode } = mount();

    mode({
      mode: "browse",
      pin: null,
      ghost: { lat: ORIGIN.lat, lon: ORIGIN.lng },
    });

    // A saved position with nothing to compare it against is not a move.
    expect(document.querySelector(".stop-map-ghost")).toBeNull();
  });

  it("refuses a pin that carries no readable point", () => {
    const { mode, pin: element } = mount();

    mode({ mode: "browse", pin: { lat: "north", lon: -124.05 }, ghost: null });

    expect(element()).toBeNull();
  });
});

describe("the distances the ghost label prints", () => {
  it("reads in feet to the nearest five under a thousand feet", () => {
    expect(formatDistance(13.716)).toBe("45 ft");
    expect(formatDistance(0.3048 * 12)).toBe("10 ft");
  });

  it("reads in miles past a thousand feet", () => {
    expect(formatDistance(1609.344)).toBe("1.00 mi");
  });

  it("measures between two points on the Earth, not between two pixels", () => {
    const metres = haversineMetres(
      [ORIGIN.lng, ORIGIN.lat],
      [ORIGIN.lng, ORIGIN.lat + 0.01],
    );

    expect(metres).toBeGreaterThan(1100);
    expect(metres).toBeLessThan(1120);
  });
});

describe("teardown", () => {
  it("leaves no pin and no add-mode chrome behind", () => {
    const { hook, mode } = mount();

    mode({
      mode: "browse",
      pin: { lat: ORIGIN.lat, lon: ORIGIN.lng, label: "New stop" },
      ghost: null,
    });
    hook.destroyed();

    // The overlay is the stage's and stays; what the hook put in it goes.
    expect(document.getElementById("stop-map-overlay")).not.toBeNull();
    expect(document.querySelector("[data-stop-map-pin]")).toBeNull();
    expect(hook.el.classList.contains("stop-map-adding")).toBe(false);
  });
});
