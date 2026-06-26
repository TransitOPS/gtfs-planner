/* @vitest-environment jsdom */
import { describe, expect, it, vi } from "vitest";
import MapAlignmentHook, {
  parseAlignmentPayload,
  readActiveAlignment,
  symbolForLocationType,
  activeColorForLocationType,
} from "../map_alignment_hook";

describe("map_alignment_hook alignment parsing", () => {
  it("parses the active payload from align dataset keys", () => {
    const root = {
      dataset: {
        alignCenterLat: "40.7128",
        alignCenterLon: "-74.0060",
        alignScaleMpp: "0.25",
        alignRotationDeg: "15",
      },
    };

    expect(readActiveAlignment(root)).toEqual({
      centerLat: 40.7128,
      centerLon: -74.006,
      scaleMpp: 0.25,
      rotationDeg: 15,
    });
  });

  it("returns null for invalid payload parts", () => {
    expect(parseAlignmentPayload("40", "-74", "0", "0")).toBeNull();
    expect(parseAlignmentPayload("x", "-74", "0.2", "0")).toBeNull();
  });
});

describe("map_alignment_hook pure helpers", () => {
  it("maps location_type to deterministic symbol grammar", () => {
    expect(symbolForLocationType(0)).toBe("rect_upright");
    expect(symbolForLocationType(2)).toBe("rect_upright");
    expect(symbolForLocationType(4)).toBe("rect_square");
    expect(symbolForLocationType(1)).toBe("circle");
    expect(symbolForLocationType("2")).toBe("rect_upright");
    expect(symbolForLocationType(undefined)).toBe("circle");
  });

  it("returns high-contrast active colors by location_type with readable fallback", () => {
    expect(activeColorForLocationType(0)).toEqual({
      fill: "#2563EB",
      stroke: "#1E3A8A",
    });

    expect(activeColorForLocationType(2)).toEqual({
      fill: "#FFFFFF",
      stroke: "#2563EB",
    });

    expect(activeColorForLocationType(4)).toEqual({
      fill: "#CA8A04",
      stroke: "#713F12",
    });

    expect(activeColorForLocationType(99)).toEqual({
      fill: "#334155",
      stroke: "#0F172A",
    });

    expect(activeColorForLocationType("bad")).toEqual({
      fill: "#334155",
      stroke: "#0F172A",
    });
  });

});

describe("map_alignment_hook alignment compute and payload gating", () => {
  it("uses Leaflet container geometry in _computeAlignment", () => {
    document.body.innerHTML = `
      <div id="root">
        <div id="map-alignment-overlay"><img id="overlay-img" /></div>
        <div id="map-alignment-leaflet"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const overlay = document.getElementById("map-alignment-overlay");
    const img = document.getElementById("overlay-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");

    root.getBoundingClientRect = () => ({ width: 400, height: 200 });
    leafletEl.getBoundingClientRect = () => ({ width: 200, height: 100 });

    Object.defineProperty(img, "complete", { value: true, configurable: true });
    Object.defineProperty(img, "naturalWidth", { value: 200, configurable: true });
    Object.defineProperty(img, "naturalHeight", { value: 100, configurable: true });

    const containerPointToLatLng = vi.fn(([x, y]) => ({ lat: y, lng: x }));
    const hook = {
      ...MapAlignmentHook,
      el: root,
      overlay,
      leafletEl,
      transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
      leafletMap: {
        containerPointToLatLng,
        distance: () => 2,
        getZoom: () => 19,
        getCenter: () => ({ lat: 0, lng: 0 }),
      },
    };

    const payload = hook._computeAlignment();

    expect(payload).toMatchObject({
      center_lat: 50,
      center_lon: 100,
      rotation_deg: 0,
    });
    expect(containerPointToLatLng).toHaveBeenCalledWith([100, 50]);
  });

  it("prevents save_alignment pushEvent for invalid payload", () => {
    const hook = {
      ...MapAlignmentHook,
      _computeAlignment: vi.fn(() => ({
        center_lat: 91,
        center_lon: -73.99,
        scale_mpp: 0.25,
        rotation_deg: 10,
      })),
      pushEvent: vi.fn(),
    };

    hook._pushAlignmentEventIfValid("save_alignment");

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("prevents save_and_apply_alignment pushEvent for invalid payload", () => {
    const hook = {
      ...MapAlignmentHook,
      _computeAlignment: vi.fn(() => ({
        center_lat: 40.7,
        center_lon: -73.99,
        scale_mpp: Infinity,
        rotation_deg: 10,
      })),
      pushEvent: vi.fn(),
    };

    hook._pushAlignmentEventIfValid("save_and_apply_alignment");

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });
});

describe("map_alignment_hook zoom slider", () => {
  it("wires zoom slider input through mounted listener registration", () => {
    document.body.innerHTML = `
      <div id="root" data-initial-lat="40.7128" data-initial-lon="-74.0060" data-initial-zoom="16">
        <div id="map-alignment-overlay" data-editable-overlay="true"><img id="active-img" /></div>
        <div id="map-alignment-leaflet"></div>
        <button id="map-alignment-rotate-handle" data-edit-target-overlay="active"></button>
        <button id="map-alignment-scale-handle" data-edit-target-overlay="active"></button>
        <input id="map-alignment-lat-input" value="40.7128" />
        <input id="map-alignment-lon-input" value="-74.0060" />
        <button id="map-alignment-apply-center"></button>
        <input id="map-alignment-opacity" value="0.7" />
        <input id="map-alignment-zoom" value="16" />
        <button id="map-alignment-save"></button>
        <button id="map-alignment-apply"></button>
        <div id="map-alignment-pins-active"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const overlay = document.getElementById("map-alignment-overlay");
    const activeImg = document.getElementById("active-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const zoomSlider = document.getElementById("map-alignment-zoom");

    leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    Object.defineProperty(activeImg, "complete", { value: true, configurable: true });
    Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });

    const mapOn = vi.fn();
    const mapSetZoom = vi.fn();
    const mapInstance = {
      on: mapOn,
      off: vi.fn(),
      remove: vi.fn(),
      invalidateSize: vi.fn(),
      setZoom: mapSetZoom,
      getZoom: vi.fn(() => 16),
      getMinZoom: vi.fn(() => 16),
      getMaxZoom: vi.fn(() => 22),
      setView: vi.fn(),
      latLngToContainerPoint: vi.fn((pt) => ({ x: pt.lng, y: pt.lat })),
      containerPointToLatLng: vi.fn(([x, y]) => ({ lat: y, lng: x })),
      distance: vi.fn(() => 1),
      removeLayer: vi.fn(),
    };

    const originalL = window.L;
    const originalFetch = global.fetch;

    global.fetch = vi.fn(() => Promise.resolve({ ok: false }));
    window.L = {
      map: vi.fn(() => mapInstance),
      tileLayer: vi.fn(() => ({ addTo: vi.fn() })),
      geoJSON: vi.fn(() => ({ addTo: vi.fn() })),
    };

    const hook = {
      ...MapAlignmentHook,
      el: root,
      pushEvent: vi.fn(),
      handleEvent: vi.fn(),
    };

    hook.mounted();

    expect(hook.pushEvent).toHaveBeenCalledWith("map_ready", {});
    expect(mapOn).toHaveBeenCalledWith("zoomend", expect.any(Function));
    expect(zoomSlider.value).toBe("16");

    zoomSlider.value = "17";
    zoomSlider.dispatchEvent(new Event("input", { bubbles: true }));

    expect(mapSetZoom).toHaveBeenCalledWith(17, { animate: false });

    window.L = originalL;
    global.fetch = originalFetch;
  });
});

describe("map_alignment_hook active child stops rendering", () => {
  it("ignores stale active child-stop payload for non-active level", () => {
    document.body.innerHTML = `
      <div id="root" data-active-level-id="active-level">
        <div id="map-alignment-pins-active"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const activePinsRoot = document.getElementById("map-alignment-pins-active");

    const hook = {
      ...MapAlignmentHook,
      el: root,
      _activePinsRoot: activePinsRoot,
      _activeChildStops: [],
      _positionPins: vi.fn(),
    };

    hook._renderActiveChildStops({
      level_id: "other-level",
      stops: [{ stop_id: "s1", lat: 40.7, lon: -74.0 }],
    });

    expect(hook._activeChildStops).toEqual([]);
    expect(activePinsRoot.children.length).toBe(0);
    expect(hook._positionPins).not.toHaveBeenCalled();
  });

  it("normalizes numeric-string lat lon and filters invalid coordinates", () => {
    document.body.innerHTML = `
      <div id="root" data-active-level-id="active-level">
        <div id="map-alignment-pins-active"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const activePinsRoot = document.getElementById("map-alignment-pins-active");

    const hook = {
      ...MapAlignmentHook,
      el: root,
      _activePinsRoot: activePinsRoot,
      _activeChildStops: [],
      _positionPins: vi.fn(),
    };

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [
        { stop_id: "valid-string", lat: "40.7001", lon: "-74.0021" },
        { stop_id: "invalid-lat", lat: "bad", lon: "-74.0" },
        { stop_id: "invalid-lon", lat: 40.71, lon: undefined },
      ],
    });

    expect(hook._activeChildStops.length).toBe(1);
    expect(hook._activeChildStops[0]).toMatchObject({
      stop_id: "valid-string",
      lat: 40.7001,
      lon: -74.0021,
    });
    expect(activePinsRoot.children.length).toBe(1);
    const tooltip = activePinsRoot.children[0].lastChild;
    expect(tooltip.textContent).toBe("A: valid-string");
    expect(hook._positionPins).toHaveBeenCalledTimes(1);
  });
});
