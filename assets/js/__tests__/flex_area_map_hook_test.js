/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import FlexAreaMapHook, { areaClassName } from "../flex_area_map_hook";

// Merge evidence (EV-19) for the FlexAreaMap hook. The Leaflet runtime is
// stubbed, so nothing here loads a tile or reaches a tile host: these cases
// establish the hook's own contract — what it draws for a `flex_map:load`
// payload, which axis order it converts, how a second payload replaces the
// first and what it tears down — for CL-16 (the read-only flex maps).
//
// The basemap is streets, via this app's own Geoapify proxy, so no key reaches
// the browser. Asserted as a literal: this is the assertion that fails if the
// map silently falls back to aerial imagery.

const STREET_URL = "/map/tiles/osm-bright/{z}/{x}/{y}";
const MAX_ZOOM = 19;
const ROUTE_FALLBACK_COLOR = "#0d737d";

function polygon(ring) {
  return { type: "Polygon", coordinates: [ring] };
}

// The flex fixture's own shapes: the Newport and Toledo areas of
// `flex_fixtures.ex`, an access area between them, and the valley road's
// endpoints.
const NEWPORT = polygon([
  [-124.075, 44.595],
  [-124.045, 44.595],
  [-124.045, 44.625],
  [-124.075, 44.625],
  [-124.075, 44.595],
]);
const TOLEDO = polygon([
  [-123.97, 44.6],
  [-123.9, 44.6],
  [-123.9, 44.65],
  [-123.97, 44.65],
  [-123.97, 44.6],
]);
const ACCESS = polygon([
  [-124.04, 44.585],
  [-124.005, 44.585],
  [-124.005, 44.6],
  [-124.04, 44.6],
  [-124.04, 44.585],
]);

const LOAD = {
  areas: [
    { id: "area-access", geojson: ACCESS, role: "selected" },
    { id: "area-newport", geojson: NEWPORT, role: "other" },
    { id: "area-toledo", geojson: TOLEDO, role: "overlap" },
  ],
  routes: [
    { id: "1", color: "#1f5fbf", coordinates: [[-124.05, 44.605], [-124.03, 44.61]] },
    { id: "20", color: null, coordinates: [[-124.05, 44.605], [-123.93, 44.62]] },
  ],
  stops: [
    { id: "NP1", name: "Newport City Center", lon: -124.05343, lat: 44.63437, hub: true },
    { id: "NP2", name: "Newport Heights", lon: -124.03225, lat: 44.63536, hub: false },
  ],
};

// The union of the three areas above: the frame every area must be inside.
const AREA_EXTENT = [
  [44.585, -124.075],
  [44.65, -123.9],
];

// Three area layers, two route lines, and the connecting stop's marker plus its
// core and the plain stop's marker.
const DRAWN_LAYERS = 8;

// --- the Leaflet stub -------------------------------------------------------

// A bounds object with a readable extent, so a test can assert what the hook
// asked Leaflet to frame without a projection: Leaflet's own
// `latLngBounds().extend()` accumulation, in [south, west] / [north, east].
function boundsStub(extent = null) {
  const bounds = {
    _extent: extent ? [[...extent[0]], [...extent[1]]] : null,
    isValid: () => bounds._extent !== null,
    extend(other) {
      const corners = other && other._extent ? other._extent : [other];

      corners.forEach(([lat, lon]) => {
        if (bounds._extent === null) {
          bounds._extent = [
            [lat, lon],
            [lat, lon],
          ];
          return;
        }

        bounds._extent[0][0] = Math.min(bounds._extent[0][0], lat);
        bounds._extent[0][1] = Math.min(bounds._extent[0][1], lon);
        bounds._extent[1][0] = Math.max(bounds._extent[1][0], lat);
        bounds._extent[1][1] = Math.max(bounds._extent[1][1], lon);
      });

      return bounds;
    },
  };

  return bounds;
}

function pointsExtent(points) {
  const lats = points.map(([lat]) => lat);
  const lons = points.map(([, lon]) => lon);

  return [
    [Math.min(...lats), Math.min(...lons)],
    [Math.max(...lats), Math.max(...lons)],
  ];
}

// The extent of a test polygon, walked from its positions.
function polygonExtent(geojson) {
  const positions = [];

  const walk = (node) => {
    if (typeof node[0] === "number") positions.push(node);
    else node.forEach(walk);
  };

  walk(geojson.coordinates);

  return pointsExtent(positions);
}

function createLeaflet() {
  const map = {
    layers: [],
    fitBounds: vi.fn(),
    removeLayer: vi.fn((layer) => {
      map.layers = map.layers.filter((item) => item !== layer);
    }),
    remove: vi.fn(() => {
      map.removed = true;
    }),
  };

  const drawable = (layer) => {
    layer.addTo = vi.fn((target) => {
      target.layers.push(layer);
      return layer;
    });
    return layer;
  };

  const L = {
    map: vi.fn(() => map),
    tileLayer: vi.fn((url, options) => {
      const tile = drawable({
        url,
        options,
        on: vi.fn(() => tile),
      });
      return tile;
    }),
    geoJSON: vi.fn((geojson, options) =>
      drawable({
        geojson,
        options,
        getBounds: () => boundsStub(polygonExtent(geojson)),
      }),
    ),
    polyline: vi.fn((latlngs, options) =>
      drawable({
        latlngs,
        options,
        getBounds: () => boundsStub(pointsExtent(latlngs)),
      }),
    ),
    circleMarker: vi.fn((latlng, options) =>
      drawable({
        latlng,
        options,
        getLatLng: () => ({ lat: latlng[0], lng: latlng[1] }),
        bindTooltip: vi.fn(() => undefined),
      }),
    ),
    latLngBounds: vi.fn(() => boundsStub()),
  };

  return { L, map };
}

function renderRoot({ withStage = true } = {}) {
  document.body.innerHTML = `
    <div id="flex-list-map">
      ${withStage ? '<div class="flex-map-stage"></div>' : ""}
    </div>`;

  return document.getElementById("flex-list-map");
}

function mount({ root = null, reducedMotion = false } = {}) {
  const el = root || renderRoot();
  const { L, map } = createLeaflet();
  const pushes = [];
  const events = new Map();

  window.L = L;
  window.matchMedia = vi.fn(() => ({ matches: reducedMotion }));

  const hook = {
    ...FlexAreaMapHook,
    el,
    pushEvent: vi.fn((name, payload) => pushes.push({ name, payload })),
    handleEvent: vi.fn((name, handler) => events.set(name, handler)),
  };

  FlexAreaMapHook.mounted.call(hook);

  return {
    hook,
    el,
    L,
    map,
    stage: el.querySelector(".flex-map-stage"),
    pushes,
    events,
    load: (payload) => events.get("flex_map:load")(payload),
  };
}

function geoJSONLayers(L) {
  return L.geoJSON.mock.results.map((result) => result.value);
}

function circlesOn(map) {
  return map.layers.filter((layer) => layer.latlng !== undefined);
}

let originalLeaflet;
let originalMatchMedia;

beforeEach(() => {
  originalLeaflet = window.L;
  originalMatchMedia = window.matchMedia;
});

afterEach(() => {
  window.L = originalLeaflet;
  window.matchMedia = originalMatchMedia;
  document.body.innerHTML = "";
});

// --- mounting ---------------------------------------------------------------

describe("mounting the hook", () => {
  it("creates the map on the stage, adds the street basemap and asks for the payload", () => {
    const { L, map, stage, pushes, events, hook } = mount();

    expect(L.map).toHaveBeenCalledTimes(1);
    expect(L.map.mock.calls[0][0]).toBe(stage);
    expect(L.map.mock.calls[0][1]).toMatchObject({
      center: [20, 0],
      zoom: 2,
      minZoom: 2,
      maxZoom: MAX_ZOOM,
      // A page scroll over the card scrolls the page, not the map.
      scrollWheelZoom: false,
    });
    // Leaflet's zoom control, its attribution control and its keyboard panning
    // stay at their defaults, which is what makes the controls reachable.
    expect(L.map.mock.calls[0][1].zoomControl).toBeUndefined();
    expect(L.map.mock.calls[0][1].attributionControl).toBeUndefined();

    expect(hook._map).toBe(map);

    const tile = L.tileLayer.mock.results[0].value;
    expect(L.tileLayer).toHaveBeenCalledTimes(1);
    expect(tile.url).toBe(STREET_URL);
    expect(tile.addTo).toHaveBeenCalledWith(map);

    expect(events.has("flex_map:load")).toBe(true);
    expect(pushes).toEqual([{ name: "flex_map_ready", payload: {} }]);
  });

  it("resets a container Leaflet still owns from an earlier mount", () => {
    const root = renderRoot();
    const stage = root.querySelector(".flex-map-stage");
    stage._leaflet_id = 42;
    stage.innerHTML = "<div>stale</div>";

    mount({ root });

    expect(stage._leaflet_id).toBe(undefined);
    expect(stage.innerHTML).toBe("");
  });

  it("draws nothing when the root has no stage", () => {
    const { L, hook, pushes } = mount({ root: renderRoot({ withStage: false }) });

    expect(L.map).not.toHaveBeenCalled();
    expect(hook._map).toBeNull();
    expect(pushes).toEqual([]);
  });

  it("draws nothing, and does not throw, when Leaflet is unavailable", () => {
    const root = renderRoot();
    window.L = undefined;

    const hook = { ...FlexAreaMapHook, el: root, pushEvent: vi.fn(), handleEvent: vi.fn() };

    expect(() => FlexAreaMapHook.mounted.call(hook)).not.toThrow();
    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(hook._map).toBeNull();
  });

  it("tears the map down on destroy", () => {
    const { hook, map } = mount();
    hook.load(LOAD);

    hook.destroyed();

    expect(map.remove).toHaveBeenCalledTimes(1);
    expect(hook._map).toBeNull();
    expect(hook._layers).toEqual([]);
  });
});

// --- drawing a payload ------------------------------------------------------

describe("drawing a flex_map:load payload", () => {
  it("draws one role-classed area layer per area, a line per route and a marker per stop", () => {
    const { L, map, load } = mount();

    load(LOAD);

    const areas = geoJSONLayers(L);
    expect(areas).toHaveLength(3);
    expect(areas.map((layer) => layer.geojson)).toEqual([ACCESS, NEWPORT, TOLEDO]);
    expect(areas.map((layer) => layer.options.className)).toEqual([
      "flex-map-area flex-map-area--selected",
      "flex-map-area flex-map-area--other",
      "flex-map-area flex-map-area--overlap",
    ]);
    // Read-only: no drawn layer takes a click the map should get.
    expect(areas.every((layer) => layer.options.interactive === false)).toBe(true);

    expect(L.polyline).toHaveBeenCalledTimes(2);
    expect(L.polyline.mock.calls[0][1]).toMatchObject({
      color: "#1f5fbf",
      weight: 3,
      interactive: false,
    });
    // A route without a colour takes the legend's own line colour.
    expect(L.polyline.mock.calls[1][1].color).toBe(ROUTE_FALLBACK_COLOR);

    // One marker per stop, plus the connecting stop's core.
    const circles = circlesOn(map);
    expect(circles.map((circle) => circle.options.radius)).toEqual([6.5, 2.5, 4.5]);
    expect(map.layers).toHaveLength(DRAWN_LAYERS);
  });

  it("converts storage coordinates with toLatLng, for lines and markers both", () => {
    const { L, map, load } = mount();

    load(LOAD);

    // [lon, lat] in, [lat, lon] drawn — the one axis swap the map does.
    expect(L.polyline.mock.calls[0][0]).toEqual([
      [44.605, -124.05],
      [44.61, -124.03],
    ]);

    const [hub, , plain] = circlesOn(map);
    expect(hub.latlng).toEqual([44.63437, -124.05343]);
    expect(plain.latlng).toEqual([44.63536, -124.03225]);
  });

  it("names a connecting stop on the map and leaves a plain stop unnamed", () => {
    const { map, load } = mount();

    load(LOAD);

    const [hub, core, plain] = circlesOn(map);

    expect(hub.bindTooltip).toHaveBeenCalledWith("Newport City Center", {
      permanent: true,
      direction: "right",
      offset: [10, 0],
      className: "flex-map-stop-label",
    });
    expect(core.bindTooltip).not.toHaveBeenCalled();
    expect(plain.bindTooltip).not.toHaveBeenCalled();
  });

  it("fits every area's bounds, with the map's own padding and zoom ceiling", () => {
    const { map, load } = mount();

    load(LOAD);

    expect(map.fitBounds).toHaveBeenCalledTimes(1);
    expect(map.fitBounds.mock.calls[0][0]._extent).toEqual(AREA_EXTENT);
    expect(map.fitBounds.mock.calls[0][1]).toEqual({
      padding: [24, 24],
      maxZoom: MAX_ZOOM,
      animate: true,
    });
  });

  it("fits without animation when the reader asked for reduced motion", () => {
    const { map, load } = mount({ reducedMotion: true });

    load(LOAD);

    expect(map.fitBounds.mock.calls[0][1].animate).toBe(false);
  });

  it("draws the list's roleless areas in the plain treatment", () => {
    const { L, load } = mount();

    // The list has no selection to signal: every area it sends is equally in
    // play, which is the reference's plain zone style.
    load({
      areas: [{ id: "area-newport", geojson: NEWPORT }],
      routes: [],
      stops: [],
    });

    expect(geoJSONLayers(L)[0].options.className).toBe("flex-map-area");
  });

  it("frames the routes and stops when no area has stored geometry", () => {
    const { map, load } = mount();

    load({ areas: [], routes: LOAD.routes, stops: LOAD.stops });

    // The route endpoints and both stop points.
    expect(map.fitBounds).toHaveBeenCalledTimes(1);
    expect(map.fitBounds.mock.calls[0][0]._extent).toEqual([
      [44.605, -124.05343],
      [44.63536, -123.93],
    ]);
  });

  it("leaves the view alone when nothing is drawable", () => {
    const { map, load } = mount();

    load({ areas: [], routes: [], stops: [] });

    expect(map.fitBounds).not.toHaveBeenCalled();
    expect(map.layers).toEqual([]);
  });

  it("skips an underived area, a stop without coordinates and a one-point line", () => {
    const { L, map, load } = mount();

    load({
      areas: [
        { id: "area-underived", geojson: null },
        { id: "area-newport", geojson: NEWPORT },
      ],
      routes: [
        { id: "1", color: "#1f5fbf", coordinates: [[-124.05, 44.605]] },
        { id: "20", color: "#1f5fbf", coordinates: null },
      ],
      stops: [
        { id: "NOPOINT", name: "No coordinates", hub: false },
        { id: "NP1", name: "Newport City Center", lon: -124.05343, lat: 44.63437, hub: true },
      ],
    });

    expect(L.geoJSON).toHaveBeenCalledTimes(1);
    expect(L.polyline).not.toHaveBeenCalled();
    // The connecting stop's own marker and core; the unusable stop is absent.
    expect(circlesOn(map)).toHaveLength(2);
  });

  it("binds no tile state, so a failed tile cannot clear the overlays", () => {
    const { L, map, pushes, load } = mount();

    load(LOAD);

    // The flex map has no failure channel: it binds nothing to the tile layer
    // and pushes nothing after the handshake, so a failed tile leaves the areas
    // drawn over the blank background.
    const tile = L.tileLayer.mock.results[0].value;
    expect(tile.on).not.toHaveBeenCalled();
    expect(pushes.map((push) => push.name)).toEqual(["flex_map_ready"]);
    expect(map.layers).toHaveLength(DRAWN_LAYERS);
  });
});

// --- a second payload -------------------------------------------------------

describe("a second payload", () => {
  it("replaces the layers the first payload drew", () => {
    const { map, load } = mount();

    load(LOAD);
    const first = [...map.layers];

    load({
      areas: [{ id: "area-newport", geojson: NEWPORT, role: "selected" }],
      routes: [],
      stops: [],
    });

    expect(map.removeLayer).toHaveBeenCalledTimes(first.length);
    expect(map.removeLayer.mock.calls.map(([layer]) => layer)).toEqual(first);
    expect(map.layers).toHaveLength(1);
    expect(map.fitBounds).toHaveBeenCalledTimes(1);
  });

  it("clears everything for a payload with nothing to draw", () => {
    const { map, load } = mount();

    load(LOAD);
    const drawn = map.layers.length;

    load({});

    expect(map.removeLayer).toHaveBeenCalledTimes(drawn);
    expect(map.layers).toEqual([]);
  });
});

describe("areaClassName", () => {
  it("maps each role to its treatment and anything else to the plain one", () => {
    expect(areaClassName("selected")).toBe("flex-map-area flex-map-area--selected");
    expect(areaClassName("other")).toBe("flex-map-area flex-map-area--other");
    expect(areaClassName("overlap")).toBe("flex-map-area flex-map-area--overlap");
    expect(areaClassName(undefined)).toBe("flex-map-area");
    expect(areaClassName(null)).toBe("flex-map-area");
    expect(areaClassName("draft")).toBe("flex-map-area");
  });
});
