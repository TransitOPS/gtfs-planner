/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import StopMapHook, {
  BASEMAP_SATELLITE,
  BASEMAP_STREET,
} from "../stop_map_hook";

const ROUTES = {
  "route-a": { route_id: "route-a", short_name: "1", color: "1f5fbf" },
  "route-b": { route_id: "route-b", short_name: "3", color: "4b1f78" },
};

// The wire shape of `StopsMap.display_payload/2`: `point` is `[lon, lat]`, which
// is the order the hook reverses before handing anything to Leaflet.
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
      pattern_ids: ["p1"],
    },
    {
      id: "11",
      stop_id: "NTC-A",
      name: "Newport Transit Center, Bay A",
      code: "A",
      point: [-124.05, 44.63],
      // A bay is an ordinary stop inside a station, which is how this
      // codebase's feeds spell it; a GTFS boarding area is the same thing said
      // with `location_type` 4, and both are covered below.
      location_type: 0,
      parent_station: "ST-NTC",
      served: true,
      pattern_ids: ["p1"],
    },
    {
      id: "12",
      stop_id: "NTC",
      name: "Newport Transit Center",
      code: "",
      point: [-124.049, 44.629],
      location_type: 1,
      parent_station: null,
      served: true,
      pattern_ids: [],
    },
    // Unlocated: it belongs in the panel's list and has nowhere to be drawn.
    {
      id: "13",
      stop_id: "9999",
      name: "Nowhere",
      code: "",
      point: null,
      location_type: 0,
      served: true,
      pattern_ids: [],
    },
  ],
  lines: [
    {
      pattern_id: "p1",
      route_id: "route-a",
      direction_id: "0",
      points: [
        [-124.06, 44.63],
        [-124.05, 44.63],
      ],
    },
    {
      pattern_id: "p2",
      route_id: "route-a",
      direction_id: "1",
      points: [
        [-124.05, 44.64],
        [-124.06, 44.64],
      ],
    },
  ],
  routes: ROUTES,
  bounds: [
    [-124.06, 44.62],
    [-124.04, 44.65],
  ],
};

/**
 * Stubbed Leaflet. Only the external library boundary is faked; the hook's own
 * logic runs unmodified. The projection is a linear stand-in whose scale can be
 * changed to imitate zoom, so a line's pixel offset depends on the current view.
 */
function createLeafletStub({ zoom = 18, scale = 1000 } = {}) {
  const stub = { zoom, scale, tiles: [], markers: [], polylines: [], maps: [] };

  stub.map = vi.fn((container) => {
    const handlers = new Map();
    let bounds = {
      getSouth: () => 44.6,
      getWest: () => -124.1,
      getNorth: () => 44.7,
      getEast: () => -124.0,
    };

    const map = {
      container,
      layers: [],
      getZoom: () => stub.zoom,
      setZoom: vi.fn((value) => {
        stub.zoom = value;
        map.fire("zoomend");
        return map;
      }),
      getBounds: () => bounds,
      getSize: () => ({ x: 800, y: 500 }),
      setBounds: (value) => {
        bounds = value;
      },
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
      latLngToContainerPoint: ([lat, lon]) => ({
        x: (lon + 124.05) * stub.scale,
        y: (44.63 - lat) * stub.scale,
      }),
      containerPointToLatLng: ([x, y]) => ({
        lat: 44.63 - y / stub.scale,
        lng: -124.05 + x / stub.scale,
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
      remove: vi.fn(() => {
        map.removed = true;
      }),
      fire: (event) => (handlers.get(event) || []).forEach((fn) => fn()),
    };
    stub.maps.push(map);
    return map;
  });

  stub.layerGroup = vi.fn(() => {
    const group = {
      layers: [],
      addTo: vi.fn(() => group),
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

  stub.tileLayer = vi.fn((url, options) => {
    const layer = {
      url,
      options,
      handlers: new Map(),
      on: vi.fn((event, handler) => {
        layer.handlers.set(event, [
          ...(layer.handlers.get(event) || []),
          handler,
        ]);
        return layer;
      }),
      addTo: vi.fn((map) => {
        map.addLayer(layer);
        return layer;
      }),
      fire: (event) => (layer.handlers.get(event) || []).forEach((fn) => fn()),
    };
    stub.tiles.push(layer);
    return layer;
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
      addTo: vi.fn((group) => {
        group.addLayer(layer);
        return layer;
      }),
      fire: (event) => (layer.handlers.get(event) || []).forEach((fn) => fn()),
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
      bringToFront: vi.fn(() => layer),
    };
    stub.polylines.push(layer);
    return layer;
  });

  stub.divIcon = vi.fn((options) => ({ ...options, kind: "divIcon" }));

  return stub;
}

function renderRoot() {
  document.body.innerHTML = `
    <div id="stops-map-stage">
      <div id="stop-map"></div>
      <div id="stops-map-legend">
        <button type="button" data-map-basemap="streets" aria-pressed="true">Streets</button>
        <button type="button" data-map-basemap="satellite" aria-pressed="false">Satellite</button>
        <input type="checkbox" data-map-routes checked />
      </div>
    <div id="stops-map-zoom">
        <button type="button" data-map-zoom="in" aria-label="Zoom in">+</button>
        <button type="button" data-map-zoom="out" aria-label="Zoom out">−</button>
        <button type="button" data-map-fit aria-label="Show every stop">⛶</button>
      </div>
    </div>`;
  return document.getElementById("stop-map");
}

function mount({ reply = SCENE, stub } = {}) {
  const el = renderRoot();
  const pushes = [];
  const subscriptions = {};
  window.L = stub || createLeafletStub();

  const hook = {
    ...StopMapHook,
    el,
    pushEvent: vi.fn((name, payload, callback) => {
      pushes.push({ name, payload });
      if (typeof callback === "function" && reply !== null) callback(reply);
    }),
    handleEvent: vi.fn((name, callback) => {
      subscriptions[name] = callback;
    }),
  };

  StopMapHook.mounted.call(hook);
  if (subscriptions["stop_map:scene"]) {
    subscriptions["stop_map:scene"]({ payload: SCENE });
  }

  return {
    hook,
    el,
    map: hook._map,
    pushes,
    pushed: (name) => pushes.filter((push) => push.name === name),
    focus: (payload) => subscriptions["stop_map:focus"]({ payload }),
    markers: hook._stopLayers,
    lines: hook._lineLayers,
    tileLayers: () => hook._tileLayers,
  };
}

beforeEach(() => {
  window.ResizeObserver = undefined;
});

afterEach(() => {
  document.body.innerHTML = "";
  delete window.L;
});

describe("mounting", () => {
  it("draws 3 stop markers and 2 polylines from a 3-stop, 2-line scene and pushes stop_map_ready", () => {
    const stub = createLeafletStub();
    const scene = {
      ...SCENE,
      stops: SCENE.stops.slice(0, 3),
      lines: SCENE.lines.slice(0, 2),
    };
    const el = renderRoot();
    const pushes = [];
    const subscriptions = {};
    window.L = stub;

    const hook = {
      ...StopMapHook,
      el,
      pushEvent: vi.fn((name, payload) => pushes.push({ name, payload })),
      handleEvent: vi.fn((name, callback) => {
        subscriptions[name] = callback;
      }),
    };

    StopMapHook.mounted.call(hook);
    subscriptions["stop_map:scene"]({ payload: scene });

    expect(hook._stopLayers.size).toBe(3);
    expect(hook._lineLayers.length).toBe(4);
    expect(pushes.map((push) => push.name)).toContain("stop_map_ready");
  });

  it("leaves an unlocated stop out of the canvas but keeps the located ones", () => {
    const { markers } = mount();

    // Four stops in the payload, one of them with no coordinates at all.
    expect(markers.size).toBe(3);
    expect(markers.has("13")).toBe(false);
    expect(markers.has("10")).toBe(true);
  });

  it("reports the current view so the panel knows which stops are in it", () => {
    const { pushed } = mount();

    const bounds = pushed("stop_map_bounds").pop().payload;

    expect(bounds).toEqual({
      south: 44.6,
      west: -124.1,
      north: 44.7,
      east: -124.0,
    });
  });

  it("does not report the same view twice", () => {
    const { hook, pushed } = mount();
    const afterScene = pushed("stop_map_bounds").length;

    hook._map.fire("moveend");

    expect(pushed("stop_map_bounds").length).toBe(afterScene);
  });

  it("reports a new view after a pan that changed it", () => {
    const { hook, pushed } = mount();

    hook._map.setBounds({
      getSouth: () => 44.0,
      getWest: () => -125.0,
      getNorth: () => 45.0,
      getEast: () => -123.0,
    });
    hook._map.fire("moveend");

    expect(pushed("stop_map_bounds").pop().payload.south).toBe(44.0);
  });

  it("pushes map_unavailable when Leaflet is missing, and never touches the DOM", () => {
    const el = renderRoot();
    delete window.L;
    const pushes = [];

    const hook = {
      ...StopMapHook,
      el,
      pushEvent: vi.fn((name, payload) => pushes.push({ name, payload })),
      handleEvent: vi.fn(),
    };

    StopMapHook.mounted.call(hook);

    expect(pushes).toEqual([
      {
        name: "map_unavailable",
        payload: { reason: "Leaflet is unavailable" },
      },
    ]);
    expect(hook._map).toBeNull();
  });
});

describe("drawing stops", () => {
  it("pushes select_stop with a stop's id when its marker is clicked", () => {
    const { markers, pushed } = mount();

    markers.get("10").fire("click");

    expect(pushed("select_stop").pop().payload).toEqual({ stop_id: "10" });
  });

  it("gives a stop a plain disc and a station a filled square", () => {
    const { markers } = mount();

    expect(markers.get("10").options.icon.html).toContain("stop-map-stop");
    expect(markers.get("10").options.icon.html).not.toContain(
      "stop-map-station",
    );
    expect(markers.get("12").options.icon.html).toContain("stop-map-station");
  });

  it("draws an unserved stop with the dashed class the legend describes", () => {
    const el = renderRoot();
    const subscriptions = {};
    window.L = createLeafletStub();

    const hook = {
      ...StopMapHook,
      el,
      pushEvent: vi.fn(),
      handleEvent: (name, callback) => {
        subscriptions[name] = callback;
      },
    };
    StopMapHook.mounted.call(hook);
    subscriptions["stop_map:scene"]({
      payload: {
        ...SCENE,
        stops: [{ ...SCENE.stops[0], served: false }],
        lines: [],
      },
    });

    expect(hook._stopLayers.get("10").options.icon.html).toContain(
      "stop-map-stop-unserved",
    );
  });

  it("gives a bay its letter", () => {
    const { markers } = mount();

    expect(markers.get("11").options.icon.html).toContain(">A<");
  });

  it("reads a GTFS boarding area as a bay too", () => {
    const el = renderRoot();
    const subscriptions = {};
    window.L = createLeafletStub();

    const hook = {
      ...StopMapHook,
      el,
      pushEvent: vi.fn(),
      handleEvent: (name, callback) => {
        subscriptions[name] = callback;
      },
    };
    StopMapHook.mounted.call(hook);
    subscriptions["stop_map:scene"]({
      payload: {
        ...SCENE,
        stops: [{ ...SCENE.stops[1], location_type: 4, parent_station: null }],
        lines: [],
      },
    });

    expect(hook._stopLayers.get("11").options.icon.html).toContain(
      "stop-map-bay",
    );
  });

  it("folds a station's bays into it until the map is close enough to separate them", () => {
    // The seed's two bays are thirteen metres apart. At a zoom that shows a
    // whole feed their discs land on the station and on each other, so below
    // that zoom the station stands for all of them.
    const { markers } = mount({ stub: createLeafletStub({ zoom: 14 }) });

    expect(markers.has("11")).toBe(false);
    expect(markers.has("12")).toBe(true);

    const { markers: close } = mount({
      stub: createLeafletStub({ zoom: 18 }),
    });

    expect(close.has("11")).toBe(true);
  });

  it("fits the whole feed again from the stack", () => {
    const { hook } = mount({ stub: createLeafletStub({ zoom: 14 }) });
    const callsBefore = hook._map.fitBounds.mock.calls.length;

    document.querySelector("[data-map-fit]").click();

    expect(hook._map.fitBounds.mock.calls.length).toBe(callsBefore + 1);
  });

  it("zooms from the stack the workspace renders beside the canvas", () => {
    const { hook } = mount({ stub: createLeafletStub({ zoom: 14 }) });
    const stack = document.getElementById("stops-map-zoom");

    stack.querySelector('[data-map-zoom="in"]').click();
    expect(hook._map.getZoom()).toBe(15);

    stack.querySelector('[data-map-zoom="out"]').click();
    stack.querySelector('[data-map-zoom="out"]').click();
    expect(hook._map.getZoom()).toBe(13);
  });

  it("redraws the stops when the view changes, not only when a scene arrives", () => {
    // What a mark shows depends on the zoom: a bay separates from its station
    // past BAY_MIN_ZOOM and a name is painted with them. A view change
    // that only moved the lines and the panel's view would leave every mark as
    // it was drawn for the zoom the feed was fitted at.
    const { hook } = mount({ stub: createLeafletStub({ zoom: 14 }) });

    expect(hook._stopLayers.has("11")).toBe(false);

    hook._map.setZoom(18);

    expect(hook._stopLayers.get("11").options.icon.html).toContain(
      "stop-map-bay",
    );
    expect(hook._stopLayers.get("10").options.icon.html).toContain(
      "stop-map-label",
    );
  });

  it("fits to a margin so the outermost stop is still in the view", () => {
    // The panel lists the stops inside the view the hook reports. Fitting the
    // version's own bounds with Leaflet's padding crops the stops on the edge
    // out of that view, and they vanish from the list that is meant to have all
    // of them.
    const { hook } = mount();

    const [[south, west], [north, east]] = hook._map.fitBounds.mock.calls[0][0];
    const [[dataWest, dataSouth], [dataEast, dataNorth]] = SCENE.bounds;

    expect(west).toBeLessThan(dataWest);
    expect(south).toBeLessThan(dataSouth);
    expect(east).toBeGreaterThan(dataEast);
    expect(north).toBeGreaterThan(dataNorth);
  });

  it("hands Leaflet the bounds the way Leaflet reads them", () => {
    // `display_point/1` sends `[lon, lat]`; `fitBounds` wants
    // `[[south, west], [north, east]]`. Given the payload's own pairs it fits a
    // valid box in the southern hemisphere at this feed's longitude — the map
    // lands on Antarctica and the panel reports a view with nothing in it.
    const { hook } = mount();
    const [[south, west], [north, east]] = hook._map.fitBounds.mock.calls[0][0];

    expect(south).toBeCloseTo(44.617, 3);
    expect(west).toBeCloseTo(-124.062, 3);
    expect(north).toBeCloseTo(44.653, 3);
    expect(east).toBeCloseTo(-124.038, 3);
  });

  it("writes a stop's name beside its mark only where a name is readable", () => {
    // The default map state paints none: at that scale the basemap's own street
    // names are the text, and the panel's list is where a stop's name belongs
    // until the map is closed in past the point where the marks separate.
    const { markers: atFeed } = mount({
      stub: createLeafletStub({ zoom: 16 }),
    });

    expect(atFeed.get("10").options.icon.html).not.toContain("stop-map-label");

    const { markers: atStreet } = mount({
      stub: createLeafletStub({ zoom: 18 }),
    });

    expect(atStreet.get("10").options.icon.html).toContain("stop-map-label");
    expect(atStreet.get("10").options.icon.html).toContain(
      "US 101 &amp; SE 1st St",
    );
    // A bay's letter is the mark; repeating the name beside it says it twice.
    expect(atStreet.get("11").options.icon.html).not.toContain(
      "stop-map-label",
    );
  });

  it("escapes a stop name that came from a feed", () => {
    const el = renderRoot();
    const subscriptions = {};
    window.L = createLeafletStub();

    const hook = {
      ...StopMapHook,
      el,
      pushEvent: vi.fn(),
      handleEvent: (name, callback) => {
        subscriptions[name] = callback;
      },
    };
    StopMapHook.mounted.call(hook);
    subscriptions["stop_map:scene"]({
      payload: {
        ...SCENE,
        stops: [
          {
            ...SCENE.stops[1],
            code: '<img src=x onerror="alert(1)">',
            location_type: 4,
          },
        ],
        lines: [],
      },
    });

    const html = hook._stopLayers.get("11").options.icon.html;

    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;img");
  });

  it("draws a travel tick on a served stop that a line reaches", () => {
    const { markers } = mount();

    // Stop 10 sits on pattern p1, which runs east, so the tick is drawn.
    expect(markers.get("10").options.icon.html).toContain("stop-map-tick");
    // The station is reached by no pattern, so there is no direction to show.
    expect(markers.get("12").options.icon.html).not.toContain("stop-map-tick");
  });

  it("draws no tick where no line reaches the stop", () => {
    const el = renderRoot();
    const subscriptions = {};
    window.L = createLeafletStub();

    const hook = {
      ...StopMapHook,
      el,
      pushEvent: vi.fn(),
      handleEvent: (name, callback) => {
        subscriptions[name] = callback;
      },
    };
    StopMapHook.mounted.call(hook);
    subscriptions["stop_map:scene"]({
      payload: {
        ...SCENE,
        stops: [{ ...SCENE.stops[0], pattern_ids: [] }],
        lines: [],
      },
    });

    expect(hook._stopLayers.get("10").options.icon.html).not.toContain(
      "stop-map-tick",
    );
  });

  it("keeps a marker's pixel size the same at any zoom", () => {
    // A marker that grew with the map would stop reading as a point on a street
    // once the editor zoomed in to place a stop beside it.
    const atStreet = mount({
      stub: createLeafletStub({ zoom: 14 }),
    }).markers.get("10").options.icon.iconSize;
    const atFeed = mount({ stub: createLeafletStub({ zoom: 18 }) }).markers.get(
      "10",
    ).options.icon.iconSize;

    expect(atStreet).toEqual(atFeed);
  });
});

describe("drawing lines", () => {
  it("gives each line a white casing under its route colour", () => {
    const { hook } = mount();
    const [casing, route] = hook._lineLayers;

    expect(casing.options.color).toBe("#ffffff");
    expect(route.options.color).toBe("#1f5fbf");
  });

  it("adds a leading # to a feed's bare hex colour", () => {
    const { hook } = mount();

    expect(hook._lineLayers[1].options.color).toBe("#1f5fbf");
  });

  it("falls back to a readable grey for a colour that is not six hex digits", () => {
    const el = renderRoot();
    const subscriptions = {};
    window.L = createLeafletStub();

    const hook = {
      ...StopMapHook,
      el,
      pushEvent: vi.fn(),
      handleEvent: (name, callback) => {
        subscriptions[name] = callback;
      },
    };
    StopMapHook.mounted.call(hook);
    subscriptions["stop_map:scene"]({
      payload: {
        ...SCENE,
        lines: [{ ...SCENE.lines[0], route_id: "route-b" }],
        routes: { "route-b": { route_id: "route-b", color: "red" } },
      },
    });

    expect(hook._lineLayers[1].options.color).toBe("#586479");
  });

  it("offsets the two directions of one route to opposite sides of the street", () => {
    // Below OFFSET_MAX_ZOOM, where a road is narrower than a line and the two
    // directions of a route would otherwise draw over each other.
    const stub = createLeafletStub({ zoom: 14 });
    const { hook } = mount({ stub });
    const [northbound, southbound] = hook._lineLayers.filter(
      (layer, index) => index % 2 === 1,
    );

    // Points are `[lat, lon]`. p1 runs west-to-east on 44.63, so the right of
    // travel is south of it and its latitude drops; p2 runs east-to-west on
    // 44.64, so the right of travel is north of it and its latitude rises. Two
    // buses sharing a street separate instead of drawing over each other.
    expect(northbound.points[0][0]).toBeLessThan(44.63);
    expect(southbound.points[0][0]).toBeGreaterThan(44.64);
  });

  it("draws no offset once the road is wide enough on screen", () => {
    const stub = createLeafletStub({ zoom: 18 });
    const { hook } = mount({ stub });
    const line = hook._lineLayers[1];

    expect(line.points).toEqual([
      [44.63, -124.06],
      [44.63, -124.05],
    ]);
  });

  it("hides the lines when the routes toggle is cleared, and shows them again", () => {
    const { hook } = mount();
    const toggle = document.querySelector("[data-map-routes]");

    toggle.checked = false;
    toggle.dispatchEvent(new Event("change", { bubbles: true }));
    expect(hook._lineLayers.length).toBe(0);

    toggle.checked = true;
    toggle.dispatchEvent(new Event("change", { bubbles: true }));
    expect(hook._lineLayers.length).toBe(4);
  });
});

describe("the basemap", () => {
  it("adds the street tiles first and says so with aria-pressed", () => {
    mount();

    const streets = document.querySelector('[data-map-basemap="streets"]');
    const satellite = document.querySelector('[data-map-basemap="satellite"]');

    expect(streets.getAttribute("aria-pressed")).toBe("true");
    expect(satellite.getAttribute("aria-pressed")).toBe("false");
  });

  it("stop_map:basemap satellite removes the street layer and adds the satellite layers", () => {
    const stub = createLeafletStub();
    const { hook, map } = mount({ stub });
    const streetLayers = hook._tileLayers.slice();

    document.querySelector('[data-map-basemap="satellite"]').click();

    // The two Esri layers, imagery under the road reference.
    expect(hook._tileLayers.length).toBe(2);
    expect(hook._tileLayers[0].url).toContain("World_Imagery");
    expect(hook._tileLayers[1].url).toContain("World_Transportation");
    expect(streetLayers.every((layer) => !map.layers.includes(layer))).toBe(
      true,
    );
    expect(
      document
        .querySelector('[data-map-basemap="satellite"]')
        .getAttribute("aria-pressed"),
    ).toBe("true");
    expect(
      document
        .querySelector('[data-map-basemap="streets"]')
        .getAttribute("aria-pressed"),
    ).toBe("false");
  });

  it("puts the street tiles back when Streets is chosen again", () => {
    const stub = createLeafletStub();
    const { hook } = mount({ stub });

    document.querySelector('[data-map-basemap="satellite"]').click();
    document.querySelector('[data-map-basemap="streets"]').click();

    expect(hook._basemap).toBe(BASEMAP_STREET);
    expect(hook._tileLayers).toHaveLength(1);
    expect(hook._tileLayers[0].url).toContain("/map/tiles/");
  });

  it("keeps the imagery under the road reference", () => {
    const stub = createLeafletStub();
    const { hook } = mount({ stub });

    document.querySelector('[data-map-basemap="satellite"]').click();

    expect(hook._tileLayers[0].url).toContain("World_Imagery");
    expect(hook._tileLayers[1].url).toContain("World_Transportation");
  });
});

describe("focusing a finding", () => {
  it("moves the view to the named stop and closes in to street zoom", () => {
    const stub = createLeafletStub({ zoom: 12 });
    const { map, focus } = mount({ stub });

    focus({ lat: 44.63561, lon: -124.05317 });

    expect(map.setView).toHaveBeenCalledWith([44.63561, -124.05317], 18);
  });

  it("leaves a closer view where the editor put it", () => {
    const stub = createLeafletStub({ zoom: 19 });
    const { map, focus } = mount({ stub });

    focus({ lat: 44.63561, lon: -124.05317 });

    expect(map.setView).toHaveBeenCalledWith([44.63561, -124.05317], 19);
  });

  it("drops a point it cannot read rather than centring on zero", () => {
    const { map, focus } = mount();

    focus({ lat: "north", lon: -124.05317 });
    focus({});
    focus(null);

    expect(map.setView).not.toHaveBeenCalled();
  });
});

describe("tile failure", () => {
  it("pushes map_unavailable once for three tile errors", () => {
    const { hook, tileLayers, pushed } = mount();

    for (const layer of tileLayers()) {
      layer.fire("tileerror");
      layer.fire("tileerror");
      layer.fire("tileerror");
    }

    expect(pushed("map_unavailable")).toHaveLength(1);
    expect(pushed("map_unavailable")[0].payload.reason).toBe(
      "Map tiles are unavailable",
    );
    expect(hook._state).toBe("unavailable");
  });

  it("still reports its view after a tile failure, because the list is the fallback", () => {
    const { tileLayers, pushed } = mount();

    for (const layer of tileLayers()) layer.fire("tileerror");

    expect(pushed("stop_map_bounds").length).toBeGreaterThan(0);
  });
});

describe("destroyed", () => {
  it("stops listening for basemap clicks and releases the map", () => {
    const { hook } = mount();

    StopMapHook.destroyed.call(hook);
    document.querySelector('[data-map-basemap="satellite"]').click();

    expect(hook._map).toBeNull();
    expect(hook._tileLayers).toEqual([]);
    expect(hook._onBasemapClick).toBeNull();
  });

  it("does not throw when a newer hook already owns the container", () => {
    const { hook } = mount();
    hook._map.remove = () => {
      throw new Error("Map container is already initialized.");
    };

    expect(() => StopMapHook.destroyed.call(hook)).not.toThrow();
  });
});
