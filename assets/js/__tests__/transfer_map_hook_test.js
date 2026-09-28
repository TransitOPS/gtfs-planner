/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import TransferMapHook from "../transfer_map_hook";
import { treatmentForLocationType } from "../stop_icon_symbols";

// Merge evidence (EV-26) for the TransferMap hook. The Leaflet runtime is
// stubbed, so nothing here loads a tile or reaches a tile host: these cases
// establish the hook's own contract — what it draws, which events it echoes and
// what it tears down — for CL-20 (the connection map) and CL-21 (pick on map).
const GENERATION = "5f2b7c40-6a1e-4b1f-9c6d-2f0b5b3a1e01";

// The basemap is streets, via this app's own Geoapify proxy, so the key never
// reaches the browser. Asserted as a literal: this is the assertion that fails
// if the map silently falls back to aerial imagery.
const STREET_URL = "/map/tiles/osm-bright/{z}/{x}/{y}";
const IMAGERY_URL =
  "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}";

const A_POINT = {
  stop_id: "CEN",
  name: "Central Station",
  lat: 40.7527,
  lon: -73.9772,
  location_type: 1,
};
const B_POINT = {
  stop_id: "HBR",
  name: "Harbor",
  lat: 40.7003,
  lon: -74.0126,
  location_type: 0,
};
const CHILD_POINT = {
  stop_id: "CEN-A",
  name: "Platform A",
  lat: 40.753,
  lon: -73.977,
  location_type: 0,
  side: "a",
};
// The child's box widens the fit: its lat is north of both endpoints.
const FIT_BOUNDS = {
  southWest: [40.7003, -74.0126],
  northEast: [40.753, -73.977],
};

function layerStub() {
  const layer = { addTo: vi.fn(), on: vi.fn() };
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

function markerStub() {
  const marker = {
    addTo: vi.fn(),
    getElement: () => element,
    on: vi.fn(),
  };
  const element = document.createElement("div");
  marker.addTo.mockReturnValue(marker);
  marker.on.mockReturnValue(marker);
  return marker;
}

function createLeaflet() {
  const viewport = {
    getSouth: () => 40.69,
    getWest: () => -74.03,
    getNorth: () => 40.76,
    getEast: () => -73.96,
  };

  const map = {
    fitBounds: vi.fn(),
    getBounds: vi.fn(() => viewport),
    invalidateSize: vi.fn(),
    on: vi.fn(),
    remove: vi.fn(),
    setView: vi.fn(),
  };

  const L = {
    map: vi.fn(() => map),
    tileLayer: vi.fn(() => tileLayerStub()),
    layerGroup: vi.fn(() => groupStub()),
    marker: vi.fn(() => markerStub()),
    divIcon: vi.fn((options) => ({ ...options })),
    polyline: vi.fn(() => layerStub()),
    circleMarker: vi.fn(() => layerStub()),
    latLngBounds: vi.fn((southWest, northEast) => ({ southWest, northEast })),
  };

  return { L, map };
}

function buildRoot(dataset = {}) {
  const root = document.createElement("div");
  root.id = "transfer-map";
  Object.assign(root.dataset, dataset);
  document.body.appendChild(root);
  return root;
}

function mountHook(root) {
  const events = new Map();
  const hook = {
    ...TransferMapHook,
    el: root,
    pushEvent: vi.fn(),
    handleEvent: vi.fn((name, handler) => events.set(name, handler)),
  };

  hook.mounted();

  return { hook, events };
}

function tileLayer(L, index) {
  return L.tileLayer.mock.results[index].value;
}

function markerOptions(L, index) {
  return L.marker.mock.calls[index][1];
}

function markersOn(L, group) {
  return L.marker.mock.results.filter(({ value }) =>
    value.addTo.mock.calls.some(([target]) => target === group),
  ).length;
}

function moveEndListener(map) {
  return map.on.mock.calls.find(([name]) => name === "moveend")[1];
}

function tileHandler(L, index, event) {
  return tileLayer(L, index).on.mock.calls.find(([name]) => name === event)[1];
}

function clickHandler(L, index) {
  return L.marker.mock.results[index].value.on.mock.calls.find(
    ([name]) => name === "click",
  )[1];
}

function pressKey(L, index, key) {
  const event = new KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    key,
  });
  L.marker.mock.results[index].value.getElement().dispatchEvent(event);
  return event;
}

let originalLeaflet;

beforeEach(() => {
  originalLeaflet = window.L;
  document.body.innerHTML = "";
});

afterEach(() => {
  window.L = originalLeaflet;
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("transfer_map_hook mount and map state", () => {
  it("reports a fatal map state and creates no map without Leaflet", () => {
    window.L = undefined;

    const { hook } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenCalledWith("transfer_map_state", {
      generation: GENERATION,
      state: "fatal",
    });
    expect(hook.map).toBeUndefined();
  });

  it("creates one keyboard-and-drag map with the shared Esri basemap and no scroll zoom", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const root = buildRoot({ mapGeneration: GENERATION });

    const { hook } = mountHook(root);

    expect(L.map).toHaveBeenCalledTimes(1);
    expect(L.map.mock.calls[0][0]).toBe(root);
    expect(L.map.mock.calls[0][1]).toEqual({
      zoomControl: true,
      keyboard: true,
      dragging: true,
      scrollWheelZoom: false,
      attributionControl: true,
      maxZoom: 19,
    });

    // The street layer comes from addStreetBasemap, and it is streets: a
    // connection drawn over aerial imagery is a connection over nothing.
    expect(L.tileLayer).toHaveBeenCalledTimes(1);
    expect(L.tileLayer.mock.calls[0][0]).toBe(STREET_URL);
    expect(L.tileLayer.mock.calls[0][0]).not.toBe(IMAGERY_URL);
    expect(tileLayer(L, 0).addTo).toHaveBeenCalledWith(map);

    // Two groups: connection layers this hook replaces per show, and the
    // candidates a pick session owns separately.
    expect(L.layerGroup).toHaveBeenCalledTimes(2);
    expect(hook.layers).toBe(L.layerGroup.mock.results[0].value);
    expect(hook.candidates).toBe(L.layerGroup.mock.results[1].value);
    expect(hook.layers.addTo).toHaveBeenCalledWith(map);
    expect(hook.candidates.addTo).toHaveBeenCalledWith(map);

    expect(map.setView).toHaveBeenCalledWith([20, 0], 1);
  });

  it("tags a basemap tile loading as ready and a tile error as imagery_unavailable", () => {
    const { L } = createLeaflet();
    window.L = L;

    const { hook } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    // One street layer carries both handlers, so the same layer reports the
    // map arriving and the map failing.
    tileHandler(L, 0, "tileload")();
    tileHandler(L, 0, "tileerror")();

    expect(hook.pushEvent).toHaveBeenNthCalledWith(1, "transfer_map_state", {
      generation: GENERATION,
      state: "ready",
    });
    expect(hook.pushEvent).toHaveBeenNthCalledWith(2, "transfer_map_state", {
      generation: GENERATION,
      state: "imagery_unavailable",
    });
  });
});

describe("transfer_map_hook initial view", () => {
  it("fits the version extent read from data-extent", () => {
    const { L, map } = createLeaflet();
    window.L = L;

    mountHook(
      buildRoot({
        mapGeneration: GENERATION,
        extent: '{"south":40.6,"west":-74.2,"north":40.9,"east":-73.9}',
      }),
    );

    expect(map.setView).not.toHaveBeenCalled();
    expect(L.latLngBounds).toHaveBeenCalledWith([40.6, -74.2], [40.9, -73.9]);
    expect(map.fitBounds).toHaveBeenCalledTimes(1);
    expect(map.fitBounds.mock.calls[0][1]).toEqual({
      padding: [32, 32],
      maxZoom: 18,
    });
  });

  it.each([["absent", undefined], ["an empty box", "{}"]])(
    "keeps the world view when data-extent is %s", (_label, extent) => {
      const { L, map } = createLeaflet();
      window.L = L;
      const root = buildRoot({ mapGeneration: GENERATION });
      if (extent !== undefined) root.dataset.extent = extent;

      mountHook(root);

      expect(map.setView).toHaveBeenCalledWith([20, 0], 1);
      expect(map.fitBounds).not.toHaveBeenCalled();
    },
  );
});

describe("transfer_map_hook show", () => {
  it("draws A, B, a child platform, the dashed direction and a padded fit", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:show")({
      a: A_POINT,
      b: B_POINT,
      children: [CHILD_POINT],
      fit: true,
    });

    expect(L.marker).toHaveBeenCalledTimes(3);
    expect(markersOn(L, hook.layers)).toBe(3);

    const treatment = treatmentForLocationType(
      CHILD_POINT.location_type,
      hook._childColor,
    );
    expect(markerOptions(L, 0).keyboard).toBe(false);
    expect(markerOptions(L, 0).title).toBe("Platform A");
    expect(markerOptions(L, 0).icon.html).toContain(`width:${treatment.width}`);
    expect(markerOptions(L, 0).icon.iconSize).toEqual([12, 18]);

    // A and B name the endpoints and are not actions, so they stay out of the
    // tab order, but they are lifted above the child platforms so a station's
    // children cannot cover the letter.
    expect(markerOptions(L, 1).keyboard).toBe(false);
    expect(markerOptions(L, 1).title).toBe("Central Station");
    expect(markerOptions(L, 1).icon.html).toContain(">A<");
    expect(markerOptions(L, 1).icon.html).toContain("bg-primary");
    expect(markerOptions(L, 1).zIndexOffset).toBeGreaterThan(
      markerOptions(L, 0).zIndexOffset || 0,
    );
    expect(markerOptions(L, 2).title).toBe("Harbor");
    expect(markerOptions(L, 2).icon.html).toContain(">B<");
    expect(markerOptions(L, 2).icon.html).toContain("bg-secondary");

    // The dashed accent line is cased in white so it reads as the connection
    // rather than as the basemap's own dashed reference lines.
    expect(L.polyline).toHaveBeenCalledTimes(2);
    const dashedLines = L.polyline.mock.calls.filter(
      ([, options]) => options.dashArray === "6 6",
    );
    expect(dashedLines).toHaveLength(1);
    expect(dashedLines[0][0]).toEqual([
      [40.7527, -73.9772],
      [40.7003, -74.0126],
    ]);
    expect(dashedLines[0][1]).toMatchObject({ weight: 3 });
    expect(L.polyline.mock.calls[0][1]).toMatchObject({ color: "#ffffff" });
    expect(L.polyline.mock.calls[1][1].dashArray).toBe("6 6");
    expect(L.polyline.mock.calls.map(([, options]) => options.interactive)).toEqual([
      false,
      false,
    ]);

    expect(L.latLngBounds).toHaveBeenCalledWith(
      FIT_BOUNDS.southWest,
      FIT_BOUNDS.northEast,
    );
    expect(map.fitBounds).toHaveBeenCalledTimes(1);
    expect(map.fitBounds.mock.calls[0][0]).toEqual(FIT_BOUNDS);
    expect(map.fitBounds.mock.calls[0][1]).toEqual({
      padding: [32, 32],
      maxZoom: 18,
    });
  });

  it("zooms to a single endpoint instead of fitting a zero-sized box", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:show")({ a: null, b: B_POINT, children: [] });

    expect(L.marker).toHaveBeenCalledTimes(1);
    expect(markerOptions(L, 0).icon.html).toContain(">B<");
    expect(L.polyline).not.toHaveBeenCalled();
    expect(map.fitBounds).not.toHaveBeenCalled();
    expect(map.setView).toHaveBeenLastCalledWith([40.7003, -74.0126], 17);
  });

  it("draws one A/B node inside a dashed loop when both sides are the same station", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:show")({
      a: A_POINT,
      b: { ...A_POINT },
      children: [],
      fit: true,
    });

    expect(L.marker).toHaveBeenCalledTimes(1);
    expect(markerOptions(L, 0).icon.html).toContain(">A/B<");
    expect(L.polyline).not.toHaveBeenCalled();

    // One dashed loop, cased, with its radius clearing the letter marker it
    // surrounds.
    expect(L.circleMarker).toHaveBeenCalledTimes(2);
    const dashedLoops = L.circleMarker.mock.calls.filter(
      ([, options]) => options.dashArray === "6 6",
    );
    expect(dashedLoops).toHaveLength(1);
    expect(dashedLoops[0][0]).toEqual([40.7527, -73.9772]);
    expect(dashedLoops[0][1]).toMatchObject({ weight: 3, fill: false });
    expect(dashedLoops[0][1].radius).toBeGreaterThan(28 / 2);
    expect(L.circleMarker.mock.calls[0][1]).toMatchObject({
      color: "#ffffff",
      fill: false,
    });

    expect(map.setView).toHaveBeenLastCalledWith([40.7527, -73.9772], 17);
  });

  it("omits a point without coordinates rather than drawing it at zero", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:show")({
      a: { ...A_POINT, lat: null, lon: null },
      b: B_POINT,
      children: [{ ...CHILD_POINT, lat: "" }],
      fit: true,
    });

    expect(L.marker).toHaveBeenCalledTimes(1);
    expect(markerOptions(L, 0).icon.html).toContain(">B<");
    expect(L.polyline).not.toHaveBeenCalled();
  });

  it("replaces the previous connection layers on every show", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));
    const layers = hook.layers;

    events.get("transfer_map:show")({
      a: A_POINT,
      b: B_POINT,
      children: [CHILD_POINT],
      fit: true,
    });
    events.get("transfer_map:show")({ a: null, b: null, children: [] });

    expect(layers.clearLayers).toHaveBeenCalledTimes(2);
    // The clearing show leaves the pick candidate group untouched.
    expect(hook.candidates.clearLayers).not.toHaveBeenCalled();
  });

  it("fits the version extent when a show carries no drawable endpoint", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const root = buildRoot({
      mapGeneration: GENERATION,
      extent: '{"south":40.6,"west":-74.2,"north":40.9,"east":-73.9}',
    });
    const { events } = mountHook(root);
    map.fitBounds.mockClear();

    events.get("transfer_map:show")({ a: null, b: null, children: [] });

    expect(map.fitBounds).toHaveBeenCalledTimes(1);
    expect(L.latLngBounds).toHaveBeenLastCalledWith(
      [40.6, -74.2],
      [40.9, -73.9],
    );

    // "Fit connection" stays meaningful with no endpoint selected yet.
    root.dispatchEvent(new Event("transfer-map:fit"));
    expect(map.fitBounds).toHaveBeenCalledTimes(2);
  });

  it("leaves the view alone when the payload asks not to fit", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:show")({
      a: A_POINT,
      b: B_POINT,
      children: [],
      fit: false,
    });

    expect(L.marker).toHaveBeenCalledTimes(2);
    expect(map.fitBounds).not.toHaveBeenCalled();
  });

  it("does nothing after destroy", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    hook.destroyed();
    events.get("transfer_map:show")({ a: A_POINT, b: B_POINT, children: [] });

    expect(L.marker).not.toHaveBeenCalled();
    expect(map.fitBounds).not.toHaveBeenCalled();
  });
});

describe("transfer_map_hook pick session", () => {
  it("pushes the viewport bounds on pick_start and once per settled moveend", () => {
    vi.useFakeTimers();
    const { L, map } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });

    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenCalledWith("transfer_map_bounds", {
      pick_id: 3,
      south: 40.69,
      west: -74.03,
      north: 40.76,
      east: -73.96,
    });

    const onMoveEnd = moveEndListener(map);
    onMoveEnd();
    onMoveEnd();
    vi.advanceTimersByTime(249);
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(1);
    expect(hook.pushEvent).toHaveBeenCalledTimes(2);
    expect(hook.pushEvent).toHaveBeenLastCalledWith("transfer_map_bounds", {
      pick_id: 3,
      south: 40.69,
      west: -74.03,
      north: 40.76,
      east: -73.96,
    });
  });

  it("does not report bounds while no pick session is running", () => {
    vi.useFakeTimers();
    const { L, map } = createLeaflet();
    window.L = L;
    const { hook } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    moveEndListener(map)();
    vi.advanceTimersByTime(250);

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("draws one keyboard-focusable candidate per stop and echoes the pick id on a click", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    hook.candidates.clearLayers.mockClear();

    events.get("transfer_map:pick_candidates")({
      pick_id: 3,
      stops: [A_POINT, B_POINT, { ...CHILD_POINT, lon: null }],
      truncated: false,
    });

    // The third stop has no coordinates: two candidates, none at (0, 0).
    expect(L.marker).toHaveBeenCalledTimes(2);
    expect(hook.candidates.clearLayers).toHaveBeenCalledTimes(1);
    expect(markersOn(L, hook.candidates)).toBe(2);
    expect(markersOn(L, hook.layers)).toBe(0);

    expect(markerOptions(L, 0).keyboard).toBe(true);
    expect(markerOptions(L, 0).title).toBe("Central Station");
    expect(markerOptions(L, 0).riseOnHover).toBe(true);
    // A candidate can sit exactly on an endpoint letter, so it carries a lift
    // of its own (asserted against the letters in the layering case below).
    expect(markerOptions(L, 0).zIndexOffset).toBeGreaterThan(0);
    expect(markerOptions(L, 0).icon.className).toContain(
      "transfer-map-candidate",
    );
    expect(markerOptions(L, 0).icon.className).toContain("rounded-full");
    expect(markerOptions(L, 1).icon.className).toContain("rounded-[3px]");

    // Starting the session pushed the current bounds; the click is the only event
    // this case counts.
    hook.pushEvent.mockClear();
    clickHandler(L, 0)();
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenCalledWith("transfer_map_pick", {
      pick_id: 3,
      stop_id: "CEN",
    });
  });

  it("stacks candidates above the endpoint letters and the letters above child platforms", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:show")({
      a: A_POINT,
      b: B_POINT,
      children: [CHILD_POINT],
      fit: true,
    });
    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    events.get("transfer_map:pick_candidates")({ pick_id: 3, stops: [A_POINT] });

    // Leaflet stacks markers by latitude, so these offsets are the only thing
    // keeping a station's child platforms from covering the endpoint letter and
    // the letter from covering the candidate on the same pixel.
    const child = markerOptions(L, 0).zIndexOffset || 0;
    const letterA = markerOptions(L, 1).zIndexOffset || 0;
    const letterB = markerOptions(L, 2).zIndexOffset || 0;
    const candidate = markerOptions(L, 3).zIndexOffset || 0;

    expect(letterA).toBeGreaterThan(child);
    expect(letterB).toBeGreaterThan(child);
    expect(candidate).toBeGreaterThan(letterA);
    expect(candidate).toBeGreaterThan(letterB);
  });

  it("picks a candidate from the keyboard, which Leaflet's keyboard option alone does not do", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    events.get("transfer_map:pick_candidates")({ pick_id: 3, stops: [A_POINT] });

    // Starting the session pushed the current bounds; the unrelated key must not
    // add a pick of its own.
    hook.pushEvent.mockClear();
    pressKey(L, 0, "a");
    expect(hook.pushEvent).not.toHaveBeenCalled();

    expect(pressKey(L, 0, "Enter").defaultPrevented).toBe(true);
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenLastCalledWith("transfer_map_pick", {
      pick_id: 3,
      stop_id: "CEN",
    });

    pressKey(L, 0, " ");
    expect(hook.pushEvent).toHaveBeenCalledTimes(2);
  });

  it("ignores a keyboard pick from a candidate whose session has ended", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    events.get("transfer_map:pick_candidates")({ pick_id: 3, stops: [A_POINT] });
    events.get("transfer_map:pick_end")({ pick_id: 3 });
    hook.pushEvent.mockClear();

    pressKey(L, 0, "Enter");

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("ignores a candidate payload from another pick session", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    hook.candidates.clearLayers.mockClear();

    events.get("transfer_map:pick_candidates")({ pick_id: 2, stops: [A_POINT] });

    expect(L.marker).not.toHaveBeenCalled();
    expect(hook.candidates.clearLayers).not.toHaveBeenCalled();
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
  });

  it("ignores a click from a candidate whose session has ended", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    events.get("transfer_map:pick_candidates")({ pick_id: 3, stops: [A_POINT] });
    const onClick = clickHandler(L, 0);
    events.get("transfer_map:pick_end")({ pick_id: 3 });
    hook.pushEvent.mockClear();

    onClick();

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("clears the candidates and stops reporting bounds on pick_end", () => {
    vi.useFakeTimers();
    const { L, map } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    events.get("transfer_map:pick_candidates")({ pick_id: 3, stops: [A_POINT] });
    hook.candidates.clearLayers.mockClear();
    hook.pushEvent.mockClear();

    events.get("transfer_map:pick_end")({ pick_id: 3 });

    expect(hook.candidates.clearLayers).toHaveBeenCalledTimes(1);

    moveEndListener(map)();
    vi.advanceTimersByTime(250);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("drops a bounds push that was already waiting when the session ended", () => {
    vi.useFakeTimers();
    const { L, map } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    hook.pushEvent.mockClear();
    moveEndListener(map)();

    events.get("transfer_map:pick_end")({ pick_id: 3 });
    vi.advanceTimersByTime(250);

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("ends the session only for its own pick id", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    hook.candidates.clearLayers.mockClear();

    events.get("transfer_map:pick_end")({ pick_id: 2 });

    expect(hook.candidates.clearLayers).not.toHaveBeenCalled();
    expect(hook._pickId).toBe(3);
  });
});

describe("transfer_map_hook page controls and teardown", () => {
  it("fits the current endpoints when the page dispatches transfer-map:fit", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const root = buildRoot({ mapGeneration: GENERATION });
    const { events } = mountHook(root);
    events.get("transfer_map:show")({
      a: A_POINT,
      b: B_POINT,
      children: [],
      fit: false,
    });
    map.fitBounds.mockClear();

    root.dispatchEvent(new Event("transfer-map:fit"));

    expect(map.fitBounds).toHaveBeenCalledTimes(1);
    expect(map.fitBounds.mock.calls[0][0]).toEqual({
      southWest: [40.7003, -74.0126],
      northEast: [40.7527, -73.9772],
    });
  });

  it("redraws the tiles and re-measures the map on transfer_map:retry", () => {
    const { L, map } = createLeaflet();
    window.L = L;
    const { events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:retry")({});

    expect(tileLayer(L, 0).redraw).toHaveBeenCalledTimes(1);
    expect(map.invalidateSize).toHaveBeenCalledTimes(1);
  });

  it("clears the debounce timer, unbinds the fit listener and removes the map on destroy", () => {
    vi.useFakeTimers();
    const { L, map } = createLeaflet();
    window.L = L;
    const root = buildRoot({ mapGeneration: GENERATION });
    const removeListener = vi.spyOn(root, "removeEventListener");
    const { hook, events } = mountHook(root);

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    moveEndListener(map)();
    hook.pushEvent.mockClear();

    hook.destroyed();

    expect(removeListener).toHaveBeenCalledWith(
      "transfer-map:fit",
      expect.any(Function),
    );
    expect(map.remove).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(250);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("pushes nothing from any handler after destroy", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    hook.pushEvent.mockClear();
    hook.destroyed();

    events.get("transfer_map:pick_start")({ pick_id: 4, side: "b" });
    events.get("transfer_map:pick_candidates")({ pick_id: 4, stops: [A_POINT] });
    events.get("transfer_map:retry")({});

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("pushes nothing from a candidate's Enter key after destroy", () => {
    const { L } = createLeaflet();
    window.L = L;
    const { hook, events } = mountHook(buildRoot({ mapGeneration: GENERATION }));

    events.get("transfer_map:pick_start")({ pick_id: 3, side: "a" });
    events.get("transfer_map:pick_candidates")({ pick_id: 3, stops: [A_POINT] });
    hook.pushEvent.mockClear();
    hook.destroyed();

    pressKey(L, 0, "Enter");

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("resets a reused container before creating the map on a re-mount", () => {
    const { L } = createLeaflet();
    window.L = L;
    const root = buildRoot({ mapGeneration: GENERATION });
    root._leaflet_id = 7;
    root.innerHTML = "<div class='leaflet-pane'></div>";

    mountHook(root);

    expect(root._leaflet_id).toBeUndefined();
    expect(root.innerHTML).toBe("");
    expect(L.map).toHaveBeenCalledTimes(1);
  });
});
