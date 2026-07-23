/* @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import MapAlignmentHook, {
  parseAlignmentPayload,
  readActiveAlignment,
} from "../map_alignment_hook";
import { previewPointForDiagramCoordinate } from "../floorplan_preview_points";
import { createOtherLevelsLayers } from "../map_overlay_layers";
import {
  BADGE_SIZE_PX,
  DIAGRAM_BASE_COLOR,
  symbolForLocationType,
  treatmentForLocationType,
} from "../stop_icon_symbols";

function cssColor(value) {
  const el = document.createElement("div");
  el.style.color = value;
  return el.style.color;
}

function cssBorderColor(value) {
  const el = document.createElement("div");
  el.style.borderColor = value;
  return el.style.borderColor;
}

function expectPinTreatment(pin, locationType, color = DIAGRAM_BASE_COLOR) {
  const treatment = treatmentForLocationType(locationType, color);
  const dot = pin.firstChild;

  expect(pin.style.width).toBe(treatment.width);
  expect(pin.style.height).toBe(treatment.height);
  expect(dot.style.backgroundColor).toBe(cssColor(treatment.fill));
  expect(dot.style.borderColor).toBe(cssBorderColor(treatment.stroke));
  expect(dot.style.borderRadius).toBe(treatment.borderRadius);
}

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
      _logger: { warn: vi.fn() },
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
      _logger: { warn: vi.fn() },
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

describe("map_alignment_hook apply button enablement", () => {
  function mountApplyHook({ complete, naturalWidth, naturalHeight }) {
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
        <button id="map-alignment-apply" disabled>Save floorplan and stops</button>
        <div id="map-alignment-pins-active"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const overlay = document.getElementById("map-alignment-overlay");
    const activeImg = document.getElementById("active-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const applyBtn = document.getElementById("map-alignment-apply");

    leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    Object.defineProperty(activeImg, "complete", { value: complete, configurable: true });
    Object.defineProperty(activeImg, "naturalWidth", { value: naturalWidth, configurable: true });
    Object.defineProperty(activeImg, "naturalHeight", { value: naturalHeight, configurable: true });

    const mapInstance = {
      on: vi.fn(),
      off: vi.fn(),
      remove: vi.fn(),
      invalidateSize: vi.fn(),
      setZoom: vi.fn(),
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

    const restore = () => {
      window.L = originalL;
      global.fetch = originalFetch;
    };

    return { hook, applyBtn, activeImg, restore };
  }

  it("starts apply disabled before the floorplan image loads", () => {
    const { applyBtn, restore } = mountApplyHook({
      complete: false,
      naturalWidth: 0,
      naturalHeight: 0,
    });

    expect(applyBtn.disabled).toBe(true);
    expect(applyBtn.getAttribute("aria-disabled")).toBe("true");

    restore();
  });

  it("enables apply when the image reports positive natural dimensions", () => {
    const { applyBtn, restore } = mountApplyHook({
      complete: true,
      naturalWidth: 1000,
      naturalHeight: 800,
    });

    expect(applyBtn.disabled).toBe(false);
    expect(applyBtn.getAttribute("aria-disabled")).toBe("false");

    restore();
  });

  it("keeps apply disabled when the image has invalid dimensions", () => {
    const { applyBtn, activeImg, restore } = mountApplyHook({
      complete: false,
      naturalWidth: 0,
      naturalHeight: 0,
    });

    activeImg.dispatchEvent(new Event("load"));

    expect(applyBtn.disabled).toBe(true);

    restore();
  });

  it("repositions diagram-mode pins when image dimensions become ready after markers render", () => {
    const { hook, activeImg, restore } = mountApplyHook({
      complete: false,
      naturalWidth: 0,
      naturalHeight: 0,
    });

    hook._renderActiveChildStops({
      stops: [{ stop_id: "diagram-late-image", diagram_coordinate: { x: 50, y: 40 } }],
    });

    const pin = document.querySelector("#map-alignment-pins-active .map-pin");
    expect(pin.style.left).toBe("");
    expect(pin.style.top).toBe("");

    Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });
    activeImg.dispatchEvent(new Event("load"));

    expect(pin.style.left).toBe("150px");
    expect(pin.style.top).toBe("75px");

    restore();
  });

  it("does not push save_and_apply_alignment when apply is clicked while disabled", () => {
    const { hook, applyBtn, restore } = mountApplyHook({
      complete: false,
      naturalWidth: 0,
      naturalHeight: 0,
    });

    applyBtn.dispatchEvent(new Event("click", { bubbles: true }));

    expect(hook.pushEvent).not.toHaveBeenCalledWith(
      "save_and_apply_alignment",
      expect.anything()
    );

    restore();
  });

  it("pushes only the alignment payload fields when apply is clicked after enable", () => {
    const { hook, applyBtn, restore } = mountApplyHook({
      complete: true,
      naturalWidth: 1000,
      naturalHeight: 800,
    });

    hook._computeAlignment = vi.fn(() => ({
      center_lat: 40.7,
      center_lon: -74.0,
      scale_mpp: 0.25,
      rotation_deg: 10,
    }));

    applyBtn.dispatchEvent(new Event("click", { bubbles: true }));

    expect(hook.pushEvent).toHaveBeenCalledWith("save_and_apply_alignment", {
      center_lat: 40.7,
      center_lon: -74.0,
      scale_mpp: 0.25,
      rotation_deg: 10,
    });
    const applyCall = hook.pushEvent.mock.calls.find(
      ([name]) => name === "save_and_apply_alignment"
    );
    expect(Object.keys(applyCall[1]).sort()).toEqual([
      "center_lat",
      "center_lon",
      "rotation_deg",
      "scale_mpp",
    ]);

    restore();
  });
});

describe("map_alignment_hook active child stops rendering", () => {
  it("ignores stale active child-stop payload for non-active level", () => {
    document.body.innerHTML = `
      <div id="diagram-page" style="--diagram-active-stop: #7C3AED">
      <div id="root" data-active-level-id="active-level">
        <div id="map-alignment-pins-active"></div>
      </div>
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
    // Geo-only stop (lat/lon, no diagram coordinate) renders as a fallback pin,
    // so its tooltip names the map-position source.
    const tooltip = activePinsRoot.children[0].lastChild;
    expect(tooltip.textContent).toBe("A: valid-string (map position)");
    expect(hook._positionPins).toHaveBeenCalledTimes(1);
  });

  it("renders active child stops with diagram colors, halo, and shared geometry", () => {
    document.body.innerHTML = `
      <div id="diagram-page" style="--diagram-active-stop: #7C3AED">
        <div id="root" data-active-level-id="active-level">
          <div id="map-alignment-pins-active"></div>
        </div>
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
        { stop_id: "boarding-area", lat: 40.7, lon: -74.0, location_type: 0 },
        { stop_id: "boarding-point", lat: 40.705, lon: -74.005, location_type: 4 },
        { stop_id: "entrance", lat: 40.71, lon: -74.01, location_type: 2 },
        { stop_id: "generic-node", lat: 40.72, lon: -74.02, location_type: "bad" },
      ],
    });

    // The production hook resolves the named role from #diagram-page. Shape —
    // not color — still distinguishes location types.
    const paletteColor = "#7C3AED";
    const boardingPin = activePinsRoot.children[0];
    const boardingDot = boardingPin.firstChild;
    expectPinTreatment(boardingPin, 0, paletteColor);
    expect(symbolForLocationType(0)).toBe("rect_upright");
    expect(boardingDot.style.backgroundColor).toBe(cssColor(paletteColor));
    expect(boardingDot.style.borderColor).toBe(cssBorderColor(paletteColor));

    const boardingPointPin = activePinsRoot.children[1];
    const boardingPointDot = boardingPointPin.firstChild;
    expectPinTreatment(boardingPointPin, 4, paletteColor);
    expect(symbolForLocationType(4)).toBe("rect_square");
    expect(boardingPointDot.style.backgroundColor).toBe(cssColor(paletteColor));
    expect(boardingPointDot.style.borderColor).toBe(cssBorderColor(paletteColor));
    expect(boardingPointPin.style.width).not.toBe(boardingPin.style.width);
    expect(boardingPointPin.style.height).not.toBe(boardingPin.style.height);

    // Entrance/Exit (2) gets no white-fill outline — same solid color as the rest.
    const entrancePin = activePinsRoot.children[2];
    const entranceDot = entrancePin.firstChild;
    expectPinTreatment(entrancePin, 2, paletteColor);
    expect(symbolForLocationType(2)).toBe("rect_upright");
    expect(entranceDot.style.backgroundColor).toBe(cssColor(paletteColor));
    expect(entranceDot.style.borderColor).toBe(cssBorderColor(paletteColor));

    const genericPin = activePinsRoot.children[3];
    const genericDot = genericPin.firstChild;
    expectPinTreatment(genericPin, "bad", paletteColor);
    expect(symbolForLocationType("bad")).toBe("circle");
    expect(genericDot.style.backgroundColor).toBe(cssColor(paletteColor));
    expect(genericDot.style.borderColor).toBe(cssBorderColor(paletteColor));
  });

  it("renders cross-level pathway badges beside active child stops", () => {
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
        {
          stop_id: "with-stairs",
          lat: 40.7,
          lon: -74.0,
          location_type: 0,
          badges: [{ pathway_mode: 4 }],
        },
        { stop_id: "plain", lat: 40.71, lon: -74.01, location_type: 0 },
      ],
    });

    const badgedPin = activePinsRoot.children[0];
    const badges = badgedPin.querySelectorAll("svg.map-stop-badge");
    expect(badges).toHaveLength(1);
    expect(badges[0].dataset.badgeSymbol).toBe("stairs");

    const plainPin = activePinsRoot.children[1];
    expect(plainPin.querySelectorAll("svg.map-stop-badge")).toHaveLength(0);
  });
});

describe("map_alignment_hook fallback geo-mode pin treatment", () => {
  function buildRenderHook() {
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

    return { hook, activePinsRoot };
  }

  it("keeps PR #648 active treatment for diagram-mode pins without fallback markers", () => {
    const { hook, activePinsRoot } = buildRenderHook();

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [
        {
          stop_id: "diagram-stop",
          lat: 40.7,
          lon: -74.0,
          location_type: 0,
          diagram_coordinate: { x: 10, y: 20 },
        },
      ],
    });

    const pin = activePinsRoot.children[0];
    const dot = pin.firstChild;

    expect(pin.dataset.positionMode).toBe("diagram");
    expect(pin.dataset.positionFallback).toBeUndefined();
    expect(pin.classList.contains("map-pin-fallback")).toBe(false);
    expect(pin.style.opacity).toBe("");
    expect(dot.style.borderStyle).not.toBe("dashed");
    expect(pin.getAttribute("aria-label")).toBeNull();
    // Shape grammar still comes from treatmentForLocationType.
    expectPinTreatment(pin, 0);
  });

  it("gives geo-mode fallback pins reduced opacity, dashed border, and map-position text", () => {
    const { hook, activePinsRoot } = buildRenderHook();

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [{ stop_id: "geo-stop", lat: 50, lon: 100, location_type: 0 }],
    });

    const pin = activePinsRoot.children[0];
    const dot = pin.firstChild;
    const tip = pin.querySelector(".group-hover\\:opacity-100");

    expect(pin.dataset.positionMode).toBe("geo");
    expect(pin.dataset.positionFallback).toBe("geo");
    expect(pin.classList.contains("map-pin-fallback")).toBe(true);
    expect(pin.style.opacity).toBe("0.6");
    expect(dot.style.borderStyle).toBe("dashed");
    expect(pin.getAttribute("aria-label")).toContain("map position");
    expect(tip.textContent).toContain("map position");
    // Degraded treatment never changes the shared shape grammar.
    expectPinTreatment(pin, 0);
  });

  it("keeps cross-level badges attached and fixed-size for both modes", () => {
    const { hook, activePinsRoot } = buildRenderHook();

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [
        {
          stop_id: "diagram-badged",
          location_type: 0,
          diagram_coordinate: { x: 10, y: 20 },
          badges: [{ pathway_mode: 4 }],
        },
        {
          stop_id: "geo-badged",
          lat: 50,
          lon: 100,
          location_type: 0,
          badges: [{ pathway_mode: 1 }],
        },
      ],
    });

    const diagramPin = activePinsRoot.children[0];
    const geoPin = activePinsRoot.children[1];

    [diagramPin, geoPin].forEach((pin) => {
      const badges = pin.querySelectorAll("svg.map-stop-badge");
      expect(badges).toHaveLength(1);
      expect(badges[0].getAttribute("width")).toBe(String(BADGE_SIZE_PX));
      expect(badges[0].getAttribute("height")).toBe(String(BADGE_SIZE_PX));
    });
  });
});

describe("map_alignment_hook active child stops positioning by mode", () => {
  function buildPositioningHook() {
    document.body.innerHTML = `
      <div id="root" data-active-level-id="active-level">
        <div id="map-alignment-overlay"><img id="overlay-img" /></div>
        <div id="map-alignment-leaflet"></div>
        <div id="map-alignment-pins-active"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const overlay = document.getElementById("map-alignment-overlay");
    const img = document.getElementById("overlay-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const activePinsRoot = document.getElementById("map-alignment-pins-active");

    leafletEl.getBoundingClientRect = () => ({ width: 500, height: 400 });
    Object.defineProperty(img, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(img, "naturalHeight", { value: 800, configurable: true });

    const latLngToContainerPoint = vi.fn(([lat, lon]) => ({ x: lon, y: lat }));

    const hook = {
      ...MapAlignmentHook,
      el: root,
      overlay,
      leafletEl,
      _activePinsRoot: activePinsRoot,
      _activeChildStops: [],
      transform: { tx: 12, ty: -8, rotation: 0, scale: 1 },
      leafletMap: { latLngToContainerPoint },
    };

    return { hook, activePinsRoot, latLngToContainerPoint };
  }

  it("positions diagram-mode pins from preview pixels even when lat/lon is present", () => {
    const { hook, activePinsRoot, latLngToContainerPoint } = buildPositioningHook();

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [
        {
          stop_id: "diagram-stop",
          lat: 40.7,
          lon: -74.0,
          diagram_coordinate: { x: 50, y: 40 },
        },
      ],
    });

    const expected = previewPointForDiagramCoordinate({
      coordinate: { x: 50, y: 40 },
      transform: { tx: 12, ty: -8, rotation: 0, scale: 1 },
      canvasWidth: 500,
      canvasHeight: 400,
      imageNaturalWidth: 1000,
      imageNaturalHeight: 800,
    });

    const pin = activePinsRoot.children[0];
    expect(pin.dataset.positionMode).toBe("diagram");
    expect(pin.style.left).toBe(`${expected.x}px`);
    expect(pin.style.top).toBe(`${expected.y}px`);
    // lat/lon present but unused: Leaflet projection is not consulted.
    expect(latLngToContainerPoint).not.toHaveBeenCalled();
  });

  it("positions geo-mode pins via Leaflet when diagram coordinate is absent", () => {
    const { hook, activePinsRoot, latLngToContainerPoint } = buildPositioningHook();

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [{ stop_id: "geo-stop", lat: 50, lon: 100 }],
    });

    const pin = activePinsRoot.children[0];
    expect(pin.dataset.positionMode).toBe("geo");
    expect(latLngToContainerPoint).toHaveBeenCalledWith([50, 100]);
    expect(pin.style.left).toBe("100px");
    expect(pin.style.top).toBe("50px");
  });

  it("filters stops with neither diagram coordinate nor lat/lon", () => {
    const { hook, activePinsRoot } = buildPositioningHook();

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [
        { stop_id: "no-position", lat: "bad", lon: undefined },
        { stop_id: "geo-stop", lat: 50, lon: 100 },
      ],
    });

    expect(hook._activeChildStops.map((s) => s.stop_id)).toEqual(["geo-stop"]);
    expect(activePinsRoot.children.length).toBe(1);
    expect(activePinsRoot.children[0].dataset.positionMode).toBe("geo");
  });
});

describe("map_alignment_hook preview status", () => {
  function buildStatusHook({ activeLevelId = "active-level" } = {}) {
    document.body.innerHTML = `
      <div id="root" data-active-level-id="${activeLevelId}">
        <div id="map-alignment-pins-active"></div>
        <span id="map-alignment-preview-status" aria-live="polite">Coordinate-change preview not ready</span>
      </div>
    `;

    const root = document.getElementById("root");
    const activePinsRoot = document.getElementById("map-alignment-pins-active");
    const statusEl = document.getElementById("map-alignment-preview-status");

    const hook = {
      ...MapAlignmentHook,
      el: root,
      _activePinsRoot: activePinsRoot,
      _activeChildStops: [],
      _previewStatusEl: statusEl,
      // Image ready so the status renders the count branch, not "not ready".
      _naturalSizeImg: { naturalWidth: 1000, naturalHeight: 800 },
      _positionPins: vi.fn(),
    };

    return { hook, statusEl };
  }

  it("reports diagram and geo pin counts in the preview status", () => {
    const { hook, statusEl } = buildStatusHook();

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [
        { stop_id: "diagram-a", diagram_coordinate: { x: 10, y: 20 } },
        { stop_id: "diagram-b", diagram_coordinate: { x: 30, y: 40 } },
        { stop_id: "geo-a", lat: 50, lon: 100 },
      ],
    });

    expect(statusEl.textContent).toContain("2");
    expect(statusEl.textContent).toContain("1");
    expect(statusEl.textContent).toContain("anchored to floorplan");
    expect(statusEl.textContent).toContain("positioned from map");
  });

  it("does not overwrite preview status for a stale level payload", () => {
    const { hook, statusEl } = buildStatusHook();
    statusEl.textContent = "2 anchored to floorplan · 1 positioned from map";

    hook._renderActiveChildStops({
      level_id: "other-level",
      stops: [{ stop_id: "s1", lat: 40.7, lon: -74.0 }],
    });

    expect(statusEl.textContent).toBe(
      "2 anchored to floorplan · 1 positioned from map"
    );
  });

  it("names the coordinate-change workflow when marker preview is not ready", () => {
    const { hook, statusEl } = buildStatusHook();
    hook._naturalSizeImg = { naturalWidth: 0, naturalHeight: 0 };

    hook._syncPreviewStatus();

    expect(statusEl.textContent).toBe("Coordinate-change preview not ready");
  });
});

describe("map_alignment_hook _applyTransform repositioning", () => {
  function buildTransformHook() {
    document.body.innerHTML = `
      <div id="root" data-active-level-id="active-level">
        <div id="map-alignment-overlay"><img id="overlay-img" /></div>
        <div id="map-alignment-leaflet"></div>
        <div id="map-alignment-pins-active"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const overlay = document.getElementById("map-alignment-overlay");
    const img = document.getElementById("overlay-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const activePinsRoot = document.getElementById("map-alignment-pins-active");

    leafletEl.getBoundingClientRect = () => ({ width: 500, height: 400 });
    Object.defineProperty(img, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(img, "naturalHeight", { value: 800, configurable: true });

    const hook = {
      ...MapAlignmentHook,
      el: root,
      overlay,
      leafletEl,
      _activePinsRoot: activePinsRoot,
      _activeChildStops: [],
      transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
      _otherLevels: { reposition: vi.fn() },
      leafletMap: {
        latLngToContainerPoint: vi.fn(([lat, lon]) => ({ x: lon, y: lat })),
      },
    };

    hook._renderActiveChildStops({
      level_id: "active-level",
      stops: [
        { stop_id: "diagram-stop", diagram_coordinate: { x: 10, y: 15 } },
      ],
    });

    const pin = activePinsRoot.children[0];
    return { hook, pin, before: { left: pin.style.left, top: pin.style.top } };
  }

  it("repositions a diagram-mode pin when the transform is translated", () => {
    const { hook, pin, before } = buildTransformHook();

    hook.transform.tx = 60;
    hook.transform.ty = -40;
    hook._applyTransform();

    expect(pin.style.left).not.toBe(before.left);
    expect(pin.style.top).not.toBe(before.top);
  });

  it("repositions a diagram-mode pin when the transform is rotated", () => {
    const { hook, pin, before } = buildTransformHook();

    hook.transform.rotation = 30;
    hook._applyTransform();

    const moved =
      pin.style.left !== before.left || pin.style.top !== before.top;
    expect(moved).toBe(true);
  });

  it("repositions a diagram-mode pin when the transform is scaled", () => {
    const { hook, pin, before } = buildTransformHook();

    hook.transform.scale = 2;
    hook._applyTransform();

    const moved =
      pin.style.left !== before.left || pin.style.top !== before.top;
    expect(moved).toBe(true);
  });

  it("does not call other-level reposition from active-only _applyTransform", () => {
    const { hook } = buildTransformHook();

    hook.transform.tx = 25;
    hook._applyTransform();

    expect(hook._otherLevels.reposition).not.toHaveBeenCalled();
  });

  it("calls other-level reposition in the zoom slider path", () => {
    const reposition = vi.fn();
    const hook = {
      ...MapAlignmentHook,
      overlay: document.createElement("div"),
      leafletEl: (() => {
        const el = document.createElement("div");
        el.getBoundingClientRect = () => ({ width: 500, height: 400 });
        return el;
      })(),
      _activePinsRoot: null,
      _activeChildStops: [],
      transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
      _otherLevels: { reposition },
      leafletMap: {
        getZoom: vi.fn(() => 16),
        setZoom: vi.fn(),
        containerPointToLatLng: vi.fn(([x, y]) => ({ lat: y, lng: x })),
        latLngToContainerPoint: vi.fn(({ lat, lng }) => ({ x: lng, y: lat })),
      },
    };

    hook._handleZoomSliderInput({ target: { value: "17" } });

    expect(hook.leafletMap.setZoom).toHaveBeenCalledWith(17, { animate: false });
    expect(reposition).toHaveBeenCalledTimes(1);
  });
});

describe("map_alignment_hook _handleZoomSliderInput user-adjusted marking", () => {
  const makeHook = (getZoom) => ({
    ...MapAlignmentHook,
    overlay: document.createElement("div"),
    leafletEl: (() => {
      const el = document.createElement("div");
      el.getBoundingClientRect = () => ({ width: 500, height: 400 });
      return el;
    })(),
    _activePinsRoot: null,
    _activeChildStops: [],
    transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
    _otherLevels: { reposition: vi.fn() },
    _userAdjustedTransform: false,
    leafletMap: {
      getZoom: vi.fn(() => getZoom),
      setZoom: vi.fn(),
      containerPointToLatLng: vi.fn(([x, y]) => ({ lat: y, lng: x })),
      latLngToContainerPoint: vi.fn(({ lat, lng }) => ({ x: lng, y: lat })),
    },
  });

  it("marks _userAdjustedTransform and applies the zoom update on a changed value", () => {
    const hook = makeHook(16);

    hook._handleZoomSliderInput({ target: { value: "17" } });

    expect(hook._userAdjustedTransform).toBe(true);
    expect(hook.leafletMap.setZoom).toHaveBeenCalledWith(17, { animate: false });
  });

  it("leaves _userAdjustedTransform false on a no-op value equal to the current zoom", () => {
    const hook = makeHook(16);

    hook._handleZoomSliderInput({ target: { value: "16" } });

    expect(hook._userAdjustedTransform).toBe(false);
    expect(hook.leafletMap.setZoom).not.toHaveBeenCalled();
  });
});

describe("map_alignment_hook _markUserAdjusted", () => {
  it("sets the flag, runs every disposer once, and empties the array", () => {
    const spyA = vi.fn();
    const spyB = vi.fn();
    const hook = {
      ...MapAlignmentHook,
      _userAdjustedTransform: false,
      _overlayRestoreDisposers: [spyA, spyB],
    };

    hook._markUserAdjusted();

    expect(hook._userAdjustedTransform).toBe(true);
    expect(spyA).toHaveBeenCalledTimes(1);
    expect(spyB).toHaveBeenCalledTimes(1);
    expect(hook._overlayRestoreDisposers).toEqual([]);
  });

  it("is idempotent: a second call does not re-run disposers and leaves the flag true", () => {
    const hook = {
      ...MapAlignmentHook,
      _userAdjustedTransform: false,
      _overlayRestoreDisposers: [vi.fn()],
    };

    hook._markUserAdjusted();

    const laterSpy = vi.fn();
    hook._overlayRestoreDisposers = [laterSpy];

    hook._markUserAdjusted();

    expect(laterSpy).not.toHaveBeenCalled();
    expect(hook._userAdjustedTransform).toBe(true);
  });

  it("sets the flag and runs other disposers when one disposer throws", () => {
    const throwing = vi.fn(() => {
      throw new Error("disposer boom");
    });
    const survivor = vi.fn();
    const hook = {
      ...MapAlignmentHook,
      _userAdjustedTransform: false,
      _overlayRestoreDisposers: [throwing, survivor],
    };

    hook._markUserAdjusted();

    expect(hook._userAdjustedTransform).toBe(true);
    expect(throwing).toHaveBeenCalledTimes(1);
    expect(survivor).toHaveBeenCalledTimes(1);
    expect(hook._overlayRestoreDisposers).toEqual([]);
  });
});

describe("map_alignment_hook translate pointerdown marks control", () => {
  function mountTranslateHook() {
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

    leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    Object.defineProperty(activeImg, "complete", { value: true, configurable: true });
    Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });

    const mapInstance = {
      on: vi.fn(),
      off: vi.fn(),
      remove: vi.fn(),
      invalidateSize: vi.fn(),
      setZoom: vi.fn(),
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

    const restore = () => {
      window.L = originalL;
      global.fetch = originalFetch;
    };

    return { hook, overlay, restore };
  }

  function pointerdown(button) {
    const event = new Event("pointerdown", { bubbles: true });
    event.button = button;
    return event;
  }

  it("sets _userAdjustedTransform true on a left-button pointerdown", () => {
    const { hook, overlay, restore } = mountTranslateHook();

    overlay.dispatchEvent(pointerdown(0));

    expect(hook._userAdjustedTransform).toBe(true);

    restore();
  });

  it("leaves _userAdjustedTransform false on a non-primary pointerdown", () => {
    const { hook, overlay, restore } = mountTranslateHook();

    overlay.dispatchEvent(pointerdown(2));

    expect(hook._userAdjustedTransform).toBe(false);

    restore();
  });
});

describe("map_alignment_hook rotate pointerdown marks control", () => {
  function mountRotateHook() {
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
    const rotateHandle = document.getElementById("map-alignment-rotate-handle");
    const activeImg = document.getElementById("active-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");

    leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    Object.defineProperty(activeImg, "complete", { value: true, configurable: true });
    Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });

    const mapInstance = {
      on: vi.fn(),
      off: vi.fn(),
      remove: vi.fn(),
      invalidateSize: vi.fn(),
      setZoom: vi.fn(),
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

    const restore = () => {
      window.L = originalL;
      global.fetch = originalFetch;
    };

    return { hook, rotateHandle, restore };
  }

  function pointerdown(button) {
    const event = new Event("pointerdown", { bubbles: true });
    event.button = button;
    return event;
  }

  it("sets _userAdjustedTransform true on a left-button pointerdown", () => {
    const { hook, rotateHandle, restore } = mountRotateHook();

    rotateHandle.dispatchEvent(pointerdown(0));

    expect(hook._userAdjustedTransform).toBe(true);

    restore();
  });

  it("leaves _userAdjustedTransform false on a non-primary pointerdown", () => {
    const { hook, rotateHandle, restore } = mountRotateHook();

    rotateHandle.dispatchEvent(pointerdown(2));

    expect(hook._userAdjustedTransform).toBe(false);

    restore();
  });
});

describe("map_alignment_hook scale pointerdown marks control", () => {
  function mountScaleHook() {
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
    const scaleHandle = document.getElementById("map-alignment-scale-handle");
    const activeImg = document.getElementById("active-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");

    leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    Object.defineProperty(activeImg, "complete", { value: true, configurable: true });
    Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });

    const mapInstance = {
      on: vi.fn(),
      off: vi.fn(),
      remove: vi.fn(),
      invalidateSize: vi.fn(),
      setZoom: vi.fn(),
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

    const restore = () => {
      window.L = originalL;
      global.fetch = originalFetch;
    };

    return { hook, scaleHandle, restore };
  }

  // Overlay center is {x:150, y:75} for the 300x150 rect above.
  function pointerdown(button, clientX, clientY) {
    const event = new Event("pointerdown", { bubbles: true });
    event.button = button;
    event.clientX = clientX;
    event.clientY = clientY;
    return event;
  }

  it("sets _userAdjustedTransform true on a nonzero-distance pointerdown", () => {
    const { hook, scaleHandle, restore } = mountScaleHook();

    scaleHandle.dispatchEvent(pointerdown(0, 200, 75));

    expect(hook._userAdjustedTransform).toBe(true);

    restore();
  });

  it("leaves _userAdjustedTransform false on a non-primary pointerdown", () => {
    const { hook, scaleHandle, restore } = mountScaleHook();

    scaleHandle.dispatchEvent(pointerdown(2, 200, 75));

    expect(hook._userAdjustedTransform).toBe(false);

    restore();
  });

  it("leaves _userAdjustedTransform false on a center (zero-distance) pointerdown", () => {
    const { hook, scaleHandle, restore } = mountScaleHook();

    scaleHandle.dispatchEvent(pointerdown(0, 150, 75));

    expect(hook._userAdjustedTransform).toBe(false);

    restore();
  });
});

describe("map_alignment_hook recenter marks control", () => {
  function mountRecenterHook() {
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
    const latInput = document.getElementById("map-alignment-lat-input");
    const lonInput = document.getElementById("map-alignment-lon-input");

    leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
    Object.defineProperty(activeImg, "complete", { value: true, configurable: true });
    Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });

    const mapInstance = {
      on: vi.fn(),
      off: vi.fn(),
      remove: vi.fn(),
      invalidateSize: vi.fn(),
      setZoom: vi.fn(),
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

    const restore = () => {
      window.L = originalL;
      global.fetch = originalFetch;
    };

    return { hook, mapInstance, latInput, lonInput, restore };
  }

  it("marks _userAdjustedTransform and recenters on valid lat/lon with a usable rect", () => {
    const { hook, mapInstance, restore } = mountRecenterHook();

    hook._onApplyCenter();

    expect(hook._userAdjustedTransform).toBe(true);
    expect(mapInstance.setView).toHaveBeenCalledWith(
      [40.7128, -74.006],
      16,
      { animate: false },
    );

    restore();
  });

  it("leaves _userAdjustedTransform false on NaN input", () => {
    const { hook, latInput, mapInstance, restore } = mountRecenterHook();
    latInput.value = "not-a-number";

    hook._onApplyCenter();

    expect(hook._userAdjustedTransform).toBe(false);
    expect(mapInstance.setView).not.toHaveBeenCalled();

    restore();
  });

  it("leaves _userAdjustedTransform false when the Leaflet rect is null", () => {
    const { hook, mapInstance, restore } = mountRecenterHook();
    hook._leafletRect = () => null;

    hook._onApplyCenter();

    expect(hook._userAdjustedTransform).toBe(false);
    expect(mapInstance.setView).not.toHaveBeenCalled();

    restore();
  });

  it("blocks a later saved-alignment restore once recenter has marked control", () => {
    const { hook, restore } = mountRecenterHook();

    hook._onApplyCenter();
    expect(hook._userAdjustedTransform).toBe(true);

    const known = { tx: 11, ty: 22, rotation: 33, scale: 4 };
    hook.transform = known;
    hook._applyTransform = vi.fn();
    const alignment = { center_lat: 40.7, center_lon: -74.0, scale_mpp: 0.5, rotation_deg: 15 };

    hook._restoreOverlayAlignment(hook.overlay, alignment, hook.overlay.querySelector("img"), "active");

    expect(hook.transform).toBe(known);
    expect(hook.transform).toEqual({ tx: 11, ty: 22, rotation: 33, scale: 4 });
    expect(hook._applyTransform).not.toHaveBeenCalled();

    restore();
  });
});

describe("map_alignment_hook saved-alignment restore guard", () => {
  function buildRestoreHook() {
    document.body.innerHTML = `
      <div id="root">
        <div id="map-alignment-overlay"><img id="overlay-img" /></div>
        <div id="map-alignment-leaflet"></div>
      </div>
    `;

    const overlay = document.getElementById("map-alignment-overlay");
    const img = document.getElementById("overlay-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");

    leafletEl.getBoundingClientRect = () => ({ width: 400, height: 200 });
    Object.defineProperty(img, "complete", { value: true, configurable: true });
    Object.defineProperty(img, "naturalWidth", { value: 200, configurable: true });
    Object.defineProperty(img, "naturalHeight", { value: 100, configurable: true });

    const alignment = {
      center_lat: 40.7,
      center_lon: -74.0,
      scale_mpp: 0.5,
      rotation_deg: 15,
    };

    const hook = {
      ...MapAlignmentHook,
      overlay,
      leafletEl,
      _logger: { warn: vi.fn() },
      transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
      _applyTransform: vi.fn(),
      leafletMap: {
        containerPointToLatLng: vi.fn(([x, y]) => ({ lat: y, lng: x })),
        latLngToContainerPoint: vi.fn(([lat, lon]) => ({ x: lon, y: lat })),
        distance: vi.fn(() => 0.5),
      },
    };

    return { hook, overlay, img, alignment };
  }

  it("applies the restored transform when the operator has not adjusted the view", () => {
    const { hook, overlay, img, alignment } = buildRestoreHook();
    const before = hook.transform;
    hook._userAdjustedTransform = false;

    hook._restoreOverlayAlignment(overlay, alignment, img, "active");

    expect(hook.transform).not.toBe(before);
    expect(hook.transform.rotation).toBe(15);
    expect(hook._applyTransform).toHaveBeenCalledTimes(1);
  });

  it("leaves the transform unchanged when the operator has adjusted the view", () => {
    const { hook, overlay, img, alignment } = buildRestoreHook();
    const known = { tx: 11, ty: 22, rotation: 33, scale: 4 };
    hook.transform = known;
    hook._userAdjustedTransform = true;

    hook._restoreOverlayAlignment(overlay, alignment, img, "active");

    expect(hook.transform).toBe(known);
    expect(hook.transform).toEqual({ tx: 11, ty: 22, rotation: 33, scale: 4 });
    expect(hook._applyTransform).not.toHaveBeenCalled();
  });

  it("does not schedule or run a restore once the operator has adjusted the view", () => {
    vi.useFakeTimers();
    try {
      const { hook, overlay, img, alignment } = buildRestoreHook();
      hook._userAdjustedTransform = true;
      hook._restoreOverlayAlignment = vi.fn();
      hook._overlayRestoreDisposers = [];

      hook._scheduleOverlayAlignmentRestore(overlay, alignment, "active");

      // The disposer was registered then immediately run by the bailing
      // scheduleRestore, so no settle timer is armed.
      vi.runAllTimers();

      expect(hook._restoreOverlayAlignment).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("map_alignment_hook other-level isolation across active transform", () => {
  // Step 4 already proves _applyTransform does not CALL other-level reposition.
  // This is the complementary guarantee: an active transform leaves the
  // other-level renderer's stored overlay transform and pin coordinates
  // untouched, because the active transform never reaches the other-level
  // layer through any side channel (AC-17).
  it("leaves other-level overlay transform and pin coordinates untouched across an active _applyTransform", () => {
    document.body.innerHTML = `
      <div id="root" data-active-level-id="active-level">
        <div id="map-alignment-overlay"><img id="overlay-img" /></div>
        <div id="map-alignment-leaflet"></div>
        <div id="map-alignment-pins-active"></div>
        <div id="map-other-overlays"></div>
        <div id="map-other-pins"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const overlay = document.getElementById("map-alignment-overlay");
    const img = document.getElementById("overlay-img");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const activePinsRoot = document.getElementById("map-alignment-pins-active");

    leafletEl.getBoundingClientRect = () => ({ width: 500, height: 400 });
    Object.defineProperty(img, "naturalWidth", { value: 1000, configurable: true });
    Object.defineProperty(img, "naturalHeight", { value: 800, configurable: true });

    // Real other-level renderer with spied injected callbacks. The renderer
    // only recomputes overlay transforms / pin projections when its own
    // update/reposition is invoked — never as a side effect of the hook.
    const applyOverlayTransform = vi.fn();
    const projectLatLng = vi.fn(() => ({ x: 42, y: 84 }));
    const otherLevels = createOtherLevelsLayers({
      overlaysRoot: document.getElementById("map-other-overlays"),
      pinsRoot: document.getElementById("map-other-pins"),
      applyOverlayTransform,
      projectLatLng,
    });

    otherLevels.update({
      active_level_id: "active-level",
      levels: [
        {
          level_id: "other-a",
          level_index: 1,
          color: "#ff0000",
          floorplan: {
            url: "/a.png",
            center_lat: 40.7,
            center_lon: -74.0,
            scale_mpp: 0.25,
            rotation_deg: 0,
          },
          stops: [{ stop_id: "s1", lat: 40.7, lon: -74.0, location_type: 1 }],
        },
      ],
    });

    const otherPin = document
      .getElementById("map-other-pins")
      .querySelector(".map-pin");
    const otherOverlayImg = document
      .getElementById("map-other-overlays")
      .querySelector("img");

    const pinBefore = { left: otherPin.style.left, top: otherPin.style.top };
    const overlayTransformBefore = otherOverlayImg.style.transform;

    // Clear the spies so any NEW call would be attributable to the active
    // transform, then change what the projection would return so an accidental
    // re-projection would visibly move the pin.
    applyOverlayTransform.mockClear();
    projectLatLng.mockClear();
    projectLatLng.mockReturnValue({ x: 999, y: 999 });

    const hook = {
      ...MapAlignmentHook,
      el: root,
      overlay,
      leafletEl,
      _activePinsRoot: activePinsRoot,
      _activeChildStops: [],
      transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
      _otherLevels: otherLevels,
      leafletMap: {
        latLngToContainerPoint: vi.fn(([lat, lon]) => ({ x: lon, y: lat })),
      },
    };

    hook.transform.tx = 75;
    hook.transform.rotation = 45;
    hook.transform.scale = 2;
    hook._applyTransform();

    // The other-level renderer was not asked to recompute anything.
    expect(applyOverlayTransform).not.toHaveBeenCalled();
    expect(projectLatLng).not.toHaveBeenCalled();

    // And the other-level DOM still reflects its own saved alignment / stored
    // geography, not the active transform.
    expect(otherPin.style.left).toBe(pinBefore.left);
    expect(otherPin.style.top).toBe(pinBefore.top);
    expect(otherOverlayImg.style.transform).toBe(overlayTransformBefore);

    otherLevels.destroy();
  });
});

describe("map_alignment_hook generation bridge", () => {
  it("tags distinct map degradation states and transform events with the current generation", () => {
    const hook = {
      ...MapAlignmentHook,
      generation: "map-42",
      _computeAlignment: vi.fn(() => ({
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.25,
        rotation_deg: 3,
      })),
      _isValidAlignmentPayload: vi.fn(() => true),
      pushEvent: vi.fn(),
    };

    hook._emitMapState("initializing");
    hook._emitMapState("imagery_unavailable");
    hook._emitMapState("buildings_degraded");
    hook._emitMapState("ready");
    hook._pushAlignmentEventIfValid("preview_coordinate_application");

    expect(hook.pushEvent).toHaveBeenNthCalledWith(1, "map_state", {
      generation: "map-42",
      state: "initializing",
    });
    expect(hook.pushEvent).toHaveBeenNthCalledWith(2, "map_state", {
      generation: "map-42",
      state: "imagery_unavailable",
    });
    expect(hook.pushEvent).toHaveBeenNthCalledWith(3, "map_state", {
      generation: "map-42",
      state: "buildings_degraded",
    });
    expect(hook.pushEvent).toHaveBeenNthCalledWith(4, "map_state", {
      generation: "map-42",
      state: "ready",
    });
    expect(hook.pushEvent).toHaveBeenNthCalledWith(5, "preview_coordinate_application", {
      generation: "map-42",
      center_lat: 40.7,
      center_lon: -74.0,
      scale_mpp: 0.25,
      rotation_deg: 3,
    });
  });

  it("reports an optional buildings-overlay failure separately from imagery", async () => {
    const originalLeaflet = window.L;
    window.L = {};
    vi.stubGlobal("fetch", vi.fn(() => Promise.reject(new Error("unavailable"))));

    try {
      const hook = {
        ...MapAlignmentHook,
        leafletMap: {},
        _buildingsLayer: null,
        _emitMapState: vi.fn(),
      };

      hook._fetchBuildings(40.7, -74.0);
      await vi.waitFor(() => {
        expect(hook._emitMapState).toHaveBeenCalledWith("buildings_degraded");
      });
    } finally {
      vi.unstubAllGlobals();
      window.L = originalLeaflet;
    }
  });

  it("reports tile errors as unavailable imagery", () => {
    const handlers = {};
    const hook = {
      ...MapAlignmentHook,
      generation: "map-42",
      pushEvent: vi.fn(),
      _tileLayers: [
        {
          on: vi.fn((event, handler) => {
            handlers[event] = handler;
          }),
        },
      ],
    };

    try {
      hook._bindRuntimeStateEvents();
      handlers.tileerror();

      expect(hook.pushEvent).toHaveBeenCalledWith("map_state", {
        generation: "map-42",
        state: "imagery_unavailable",
      });
    } finally {
      window.removeEventListener("online", hook._onOnline);
      window.removeEventListener("offline", hook._onOffline);
    }
  });
});

describe("map_alignment_hook saved/preview state machine", () => {
  const originalLeaflet = window.L;
  const originalFetch = global.fetch;

  afterEach(() => {
    window.L = originalLeaflet;
    global.fetch = originalFetch;
  });

  function buildPartialHook({
    generation = "gen-1",
    savedAlignment = null,
    previewActive = false,
    imageDims = { w: 1000, h: 500 },
    canvasDims = { w: 400, h: 200 },
    metersPerPx = 0.5,
  } = {}) {
    const img = document.createElement("img");
    Object.defineProperty(img, "complete", { value: true, configurable: true });
    Object.defineProperty(img, "naturalWidth", { value: imageDims.w, configurable: true });
    Object.defineProperty(img, "naturalHeight", { value: imageDims.h, configurable: true });

    const overlay = document.createElement("div");
    overlay.appendChild(img);

    const leafletEl = document.createElement("div");
    leafletEl.getBoundingClientRect = () => ({
      width: canvasDims.w,
      height: canvasDims.h,
      left: 0,
      top: 0,
    });

    const latLngToContainerPoint = vi.fn(([lat, lon]) => ({ x: lon, y: lat }));
    const containerPointToLatLng = vi.fn(([x, y]) => ({ lat: y, lng: x }));
    const distance = vi.fn(() => metersPerPx);

    const hook = {
      ...MapAlignmentHook,
      generation,
      savedAlignment,
      _previewActive: previewActive,
      overlay,
      leafletEl,
      transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
      _userAdjustedTransform: false,
      _overlayRestoreDisposers: [],
      _logger: { warn: vi.fn(), error: vi.fn() },
      pushEvent: vi.fn(),
      handleEvent: vi.fn(),
      leafletMap: {
        latLngToContainerPoint,
        containerPointToLatLng,
        distance,
      },
    };

    return { hook, img, overlay, leafletEl, latLngToContainerPoint };
  }

  describe("_cssTransformForAlignment", () => {
    it("computes a transform from a snake_case alignment and the supplied image", () => {
      const { hook, img } = buildPartialHook({
        canvasDims: { w: 400, h: 200 },
        imageDims: { w: 1000, h: 500 },
        metersPerPx: 0.5,
      });

      const alignment = { center_lat: 50, center_lon: 100, scale_mpp: 0.25, rotation_deg: 10 };
      const result = hook._cssTransformForAlignment(alignment, img);

      expect(result).not.toBeNull();
      expect(result.rotation).toBe(10);
      expect(result.tx).toBe(100 - 200);
      expect(result.ty).toBe(50 - 100);
      expect(result.scale).toBeGreaterThan(0);
    });

    it("produces different scales for different image dimensions with the same alignment", () => {
      const { hook } = buildPartialHook({
        canvasDims: { w: 400, h: 200 },
        metersPerPx: 0.5,
      });

      const alignment = { center_lat: 50, center_lon: 100, scale_mpp: 0.25, rotation_deg: 0 };

      const imgA = document.createElement("img");
      Object.defineProperty(imgA, "naturalWidth", { value: 1000, configurable: true });
      Object.defineProperty(imgA, "naturalHeight", { value: 500, configurable: true });

      const imgB = document.createElement("img");
      Object.defineProperty(imgB, "naturalWidth", { value: 2000, configurable: true });
      Object.defineProperty(imgB, "naturalHeight", { value: 1000, configurable: true });

      const resultA = hook._cssTransformForAlignment(alignment, imgA);
      const resultB = hook._cssTransformForAlignment(alignment, imgB);

      expect(resultA).not.toBeNull();
      expect(resultB).not.toBeNull();
      expect(resultA.scale).not.toBe(resultB.scale);
    });

    it("returns null when the image has no natural dimensions", () => {
      const { hook } = buildPartialHook();

      const badImg = document.createElement("img");
      Object.defineProperty(badImg, "naturalWidth", { value: 0, configurable: true });
      Object.defineProperty(badImg, "naturalHeight", { value: 0, configurable: true });

      const alignment = { center_lat: 50, center_lon: 100, scale_mpp: 0.25, rotation_deg: 0 };
      expect(hook._cssTransformForAlignment(alignment, badImg)).toBeNull();
    });

    it("returns null when the leaflet map is unavailable", () => {
      const { hook, img } = buildPartialHook();
      hook.leafletMap = null;

      const alignment = { center_lat: 50, center_lon: 100, scale_mpp: 0.25, rotation_deg: 0 };
      expect(hook._cssTransformForAlignment(alignment, img)).toBeNull();
    });

    it("returns null when the canvas rect has zero dimensions", () => {
      const { hook, img, leafletEl } = buildPartialHook();
      leafletEl.getBoundingClientRect = () => ({ width: 0, height: 0, left: 0, top: 0 });

      const alignment = { center_lat: 50, center_lon: 100, scale_mpp: 0.25, rotation_deg: 0 };
      expect(hook._cssTransformForAlignment(alignment, img)).toBeNull();
    });
  });

  describe("apply_preview_transform", () => {
    it("applies a valid current-generation preview and marks preview active", () => {
      const { hook, img } = buildPartialHook({ generation: "gen-1" });
      hook._applyTransform = vi.fn();

      hook.handleEvent("apply_preview_transform", (payload) =>
        hook._handleApplyPreviewTransform(payload)
      );

      hook._handleApplyPreviewTransform({
        generation: "gen-1",
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 10,
      });

      expect(hook._previewActive).toBe(true);
      expect(hook.transform.rotation).toBe(10);
      expect(hook._applyTransform).toHaveBeenCalled();
    });

    it("cancels pending saved restore on valid preview application", () => {
      const disposer = vi.fn();
      const { hook } = buildPartialHook({ generation: "gen-1" });
      hook._overlayRestoreDisposers = [disposer];
      hook._applyTransform = vi.fn();

      hook._handleApplyPreviewTransform({
        generation: "gen-1",
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 5,
      });

      expect(disposer).toHaveBeenCalled();
      expect(hook._userAdjustedTransform).toBe(true);
    });

    it("rejects a stale generation without changing state", () => {
      const { hook } = buildPartialHook({ generation: "gen-2" });
      hook.transform = { tx: 1, ty: 2, rotation: 3, scale: 1.5 };
      hook._applyTransform = vi.fn();

      hook._handleApplyPreviewTransform({
        generation: "gen-old",
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 10,
      });

      expect(hook._previewActive).toBe(false);
      expect(hook.transform).toEqual({ tx: 1, ty: 2, rotation: 3, scale: 1.5 });
      expect(hook._applyTransform).not.toHaveBeenCalled();
    });

    it.each([
      ["non-finite latitude", { center_lat: Number.NaN }],
      ["non-finite longitude", { center_lon: Number.POSITIVE_INFINITY }],
      ["non-finite scale", { scale_mpp: Number.NEGATIVE_INFINITY }],
      ["non-finite rotation", { rotation_deg: Number.NaN }],
      ["latitude below range", { center_lat: -90.1 }],
      ["latitude above range", { center_lat: 90.1 }],
      ["longitude below range", { center_lon: -180.1 }],
      ["longitude above range", { center_lon: 180.1 }],
      ["zero scale", { scale_mpp: 0 }],
      ["negative scale", { scale_mpp: -0.1 }],
    ])("rejects %s without changing transform or preview state", (_label, invalidField) => {
      const { hook } = buildPartialHook({ generation: "gen-1", previewActive: true });
      const initialTransform = { tx: 1, ty: 2, rotation: 3, scale: 1.5 };
      hook.transform = { ...initialTransform };
      hook._applyTransform = vi.fn();

      hook._handleApplyPreviewTransform({
        generation: "gen-1",
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 10,
        ...invalidField,
      });

      expect(hook.transform).toEqual(initialTransform);
      expect(hook._previewActive).toBe(true);
      expect(hook._applyTransform).not.toHaveBeenCalled();
      expect(hook._logger.warn).toHaveBeenCalled();
    });

    it("rejects when the image is not ready (null geometry)", () => {
      const { hook } = buildPartialHook({ generation: "gen-1" });
      const badImg = hook.overlay.querySelector("img");
      Object.defineProperty(badImg, "naturalWidth", { value: 0, configurable: true });
      hook._applyTransform = vi.fn();

      hook._handleApplyPreviewTransform({
        generation: "gen-1",
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 10,
      });

      expect(hook._previewActive).toBe(false);
      expect(hook._applyTransform).not.toHaveBeenCalled();
    });
  });

  describe("restore_saved_transform", () => {
    it("restores the newest saved alignment", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        savedAlignment: { center_lat: 60, center_lon: 110, scale_mpp: 0.3, rotation_deg: 20 },
      });
      hook._applyTransform = vi.fn();

      hook._handleRestoreSavedTransform({ generation: "gen-1" });

      expect(hook.transform.rotation).toBe(20);
      expect(hook._previewActive).toBe(false);
      expect(hook._applyTransform).toHaveBeenCalled();
    });

    it("applies identity when no saved alignment exists", () => {
      const { hook } = buildPartialHook({ generation: "gen-1", savedAlignment: null });
      hook.transform = { tx: 99, ty: 88, rotation: 45, scale: 2 };
      hook._applyTransform = vi.fn();

      hook._handleRestoreSavedTransform({ generation: "gen-1" });

      expect(hook.transform).toEqual({ tx: 0, ty: 0, rotation: 0, scale: 1 });
      expect(hook._previewActive).toBe(false);
      expect(hook._applyTransform).toHaveBeenCalled();
    });

    it("rejects a stale generation", () => {
      const { hook } = buildPartialHook({
        generation: "gen-2",
        savedAlignment: { center_lat: 60, center_lon: 110, scale_mpp: 0.3, rotation_deg: 20 },
      });
      hook.transform = { tx: 5, ty: 5, rotation: 5, scale: 1 };
      hook._applyTransform = vi.fn();

      hook._handleRestoreSavedTransform({ generation: "gen-old" });

      expect(hook.transform).toEqual({ tx: 5, ty: 5, rotation: 5, scale: 1 });
      expect(hook._applyTransform).not.toHaveBeenCalled();
    });

    it("leaves active preview state unchanged when saved geometry is not ready", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        savedAlignment: { center_lat: 60, center_lon: 110, scale_mpp: 0.3, rotation_deg: 20 },
        previewActive: true,
      });
      const badImg = hook.overlay.querySelector("img");
      Object.defineProperty(badImg, "naturalWidth", { value: 0, configurable: true });
      hook.transform = { tx: 5, ty: 5, rotation: 5, scale: 1 };
      hook._applyTransform = vi.fn();

      hook._handleRestoreSavedTransform({ generation: "gen-1" });

      expect(hook.transform).toEqual({ tx: 5, ty: 5, rotation: 5, scale: 1 });
      expect(hook._previewActive).toBe(true);
      expect(hook._applyTransform).not.toHaveBeenCalled();
      expect(hook._logger.warn).toHaveBeenCalled();
    });
  });

  describe("alignment_saved", () => {
    it("updates savedAlignment with the persisted payload", () => {
      const { hook } = buildPartialHook({ generation: "gen-1", savedAlignment: null });

      hook._handleAlignmentSaved({
        generation: "gen-1",
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.15,
        rotation_deg: 5,
      });

      expect(hook.savedAlignment).toEqual({
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.15,
        rotation_deg: 5,
      });
    });

    it("rejects a stale generation without updating savedAlignment", () => {
      const original = { center_lat: 1, center_lon: 2, scale_mpp: 0.1, rotation_deg: 0 };
      const { hook } = buildPartialHook({ generation: "gen-2", savedAlignment: original });

      hook._handleAlignmentSaved({
        generation: "gen-old",
        center_lat: 99,
        center_lon: 99,
        scale_mpp: 99,
        rotation_deg: 99,
      });

      expect(hook.savedAlignment).toEqual(original);
    });

    it("rejects an invalid current-generation payload without changing state", () => {
      const original = { center_lat: 1, center_lon: 2, scale_mpp: 0.1, rotation_deg: 0 };
      const { hook } = buildPartialHook({
        generation: "gen-1",
        savedAlignment: original,
        previewActive: true,
      });
      hook.transform = { tx: 10, ty: 20, rotation: 30, scale: 2 };

      hook._handleAlignmentSaved({
        generation: "gen-1",
        center_lat: 999,
        center_lon: -74.0,
        scale_mpp: 0.15,
        rotation_deg: 5,
      });

      expect(hook.savedAlignment).toEqual(original);
      expect(hook.transform).toEqual({ tx: 10, ty: 20, rotation: 30, scale: 2 });
      expect(hook._previewActive).toBe(true);
      expect(hook._logger.warn).toHaveBeenCalled();
    });

    it("keeps the persisted transform and clears _previewActive", () => {
      const { hook } = buildPartialHook({ generation: "gen-1", previewActive: true });
      hook.transform = { tx: 10, ty: 20, rotation: 30, scale: 2 };

      hook._handleAlignmentSaved({
        generation: "gen-1",
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.15,
        rotation_deg: 5,
      });

      expect(hook.transform).toEqual({ tx: 10, ty: 20, rotation: 30, scale: 2 });
      expect(hook._previewActive).toBe(false);
    });
  });

  describe("_markPreviewDirty", () => {
    it("pushes alignment_preview_adjusted once and clears _previewActive", () => {
      const { hook } = buildPartialHook({ generation: "gen-1", previewActive: true });

      hook._markPreviewDirty();

      expect(hook.pushEvent).toHaveBeenCalledWith("alignment_preview_adjusted", {
        generation: "gen-1",
      });
      expect(hook._previewActive).toBe(false);
    });

    it("does not push again on a second call (one-shot)", () => {
      const { hook } = buildPartialHook({ generation: "gen-1", previewActive: true });

      hook._markPreviewDirty();
      hook._markPreviewDirty();

      expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    });

    it("does not push when _previewActive is false", () => {
      const { hook } = buildPartialHook({ generation: "gen-1", previewActive: false });

      hook._markPreviewDirty();

      expect(hook.pushEvent).not.toHaveBeenCalled();
    });
  });

  describe("dirty reporting from pointer and button paths", () => {
    function mountDirtyHook() {
      document.body.innerHTML = `
        <div id="root" data-initial-lat="40.7128" data-initial-lon="-74.0060" data-initial-zoom="16" data-map-generation="gen-dirty">
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
          <button data-map-transform-action="left"></button>
        </div>
      `;

      const root = document.getElementById("root");
      const overlay = document.getElementById("map-alignment-overlay");
      const activeImg = document.getElementById("active-img");
      const leafletEl = document.getElementById("map-alignment-leaflet");
      const rotateHandle = document.getElementById("map-alignment-rotate-handle");
      const scaleHandle = document.getElementById("map-alignment-scale-handle");

      leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
      overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
      Object.defineProperty(activeImg, "complete", { value: true, configurable: true });
      Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
      Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });

      const mapInstance = {
        on: vi.fn(),
        off: vi.fn(),
        remove: vi.fn(),
        invalidateSize: vi.fn(),
        setZoom: vi.fn(),
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

      const restore = () => {
        window.L = originalL;
        global.fetch = originalFetch;
      };

      return { hook, overlay, rotateHandle, scaleHandle, mapInstance, restore };
    }

    function dispatchPointer(target, type, clientX, clientY) {
      const event = new Event(type, { bubbles: true });
      event.button = 0;
      event.clientX = clientX;
      event.clientY = clientY;
      event.pointerId = 1;
      target.dispatchEvent(event);
    }

    function alignmentDirtyCalls(hook) {
      return hook.pushEvent.mock.calls.filter(
        ([name]) => name === "alignment_preview_adjusted"
      );
    }

    it("registers and dispatches the preview, restore, and save bridge callbacks", () => {
      const { hook, restore } = mountDirtyHook();
      const callbacks = Object.fromEntries(hook.handleEvent.mock.calls);
      const applyPayload = {
        generation: "gen-dirty",
        center_lat: 40.7,
        center_lon: -74,
        scale_mpp: 0.25,
        rotation_deg: 5,
      };
      const restorePayload = { generation: "gen-dirty" };
      const savedPayload = {...applyPayload, rotation_deg: 8};
      hook._handleApplyPreviewTransform = vi.fn();
      hook._handleRestoreSavedTransform = vi.fn();
      hook._handleAlignmentSaved = vi.fn();

      callbacks.apply_preview_transform(applyPayload);
      callbacks.restore_saved_transform(restorePayload);
      callbacks.alignment_saved(savedPayload);

      expect(hook._handleApplyPreviewTransform).toHaveBeenCalledWith(applyPayload);
      expect(hook._handleRestoreSavedTransform).toHaveBeenCalledWith(restorePayload);
      expect(hook._handleAlignmentSaved).toHaveBeenCalledWith(savedPayload);

      restore();
    });

    it("translate click stays clean until the first effective pointermove", () => {
      const { hook, overlay, restore } = mountDirtyHook();
      hook._previewActive = true;

      dispatchPointer(overlay, "pointerdown", 100, 50);
      dispatchPointer(overlay, "pointermove", 100, 50);
      dispatchPointer(overlay, "pointerup", 100, 50);

      expect(alignmentDirtyCalls(hook)).toHaveLength(0);
      expect(hook._previewActive).toBe(true);
      expect(hook.transform).toMatchObject({ tx: 0, ty: 0 });

      dispatchPointer(overlay, "pointerdown", 100, 50);
      dispatchPointer(overlay, "pointermove", 110, 55);
      dispatchPointer(overlay, "pointermove", 120, 60);
      dispatchPointer(overlay, "pointerup", 120, 60);

      const dirtyCalls = alignmentDirtyCalls(hook);
      expect(dirtyCalls).toHaveLength(1);
      expect(dirtyCalls[0][1]).toEqual({ generation: "gen-dirty" });
      expect(hook._previewActive).toBe(false);
      expect(hook.transform).toMatchObject({ tx: 20, ty: 10 });

      restore();
    });

    it("rotate click stays clean until the first effective pointermove", () => {
      const { hook, rotateHandle, restore } = mountDirtyHook();
      hook._previewActive = true;

      dispatchPointer(rotateHandle, "pointerdown", 200, 75);
      dispatchPointer(rotateHandle, "pointermove", 200, 75);
      dispatchPointer(rotateHandle, "pointerup", 200, 75);

      expect(alignmentDirtyCalls(hook)).toHaveLength(0);
      expect(hook._previewActive).toBe(true);
      expect(hook.transform.rotation).toBe(0);

      dispatchPointer(rotateHandle, "pointerdown", 200, 75);
      dispatchPointer(rotateHandle, "pointermove", 150, 125);
      dispatchPointer(rotateHandle, "pointermove", 100, 75);
      dispatchPointer(rotateHandle, "pointerup", 100, 75);

      const dirtyCalls = alignmentDirtyCalls(hook);
      expect(dirtyCalls).toHaveLength(1);
      expect(dirtyCalls[0][1]).toEqual({ generation: "gen-dirty" });
      expect(hook._previewActive).toBe(false);
      expect(hook.transform.rotation).toBeCloseTo(180);

      restore();
    });

    it("scale click stays clean until the first effective pointermove", () => {
      const { hook, scaleHandle, restore } = mountDirtyHook();
      hook._previewActive = true;

      dispatchPointer(scaleHandle, "pointerdown", 200, 75);
      dispatchPointer(scaleHandle, "pointermove", 200, 75);
      dispatchPointer(scaleHandle, "pointerup", 200, 75);

      expect(alignmentDirtyCalls(hook)).toHaveLength(0);
      expect(hook._previewActive).toBe(true);
      expect(hook.transform.scale).toBe(1);

      dispatchPointer(scaleHandle, "pointerdown", 200, 75);
      dispatchPointer(scaleHandle, "pointermove", 250, 75);
      dispatchPointer(scaleHandle, "pointermove", 300, 75);
      dispatchPointer(scaleHandle, "pointerup", 300, 75);

      const dirtyCalls = alignmentDirtyCalls(hook);
      expect(dirtyCalls).toHaveLength(1);
      expect(dirtyCalls[0][1]).toEqual({ generation: "gen-dirty" });
      expect(hook._previewActive).toBe(false);
      expect(hook.transform.scale).toBe(3);

      restore();
    });

    it("transform button mutation reports dirty once during active preview", () => {
      const { hook, restore } = mountDirtyHook();
      hook._previewActive = true;

      hook._adjustTransform("left", false);

      const dirtyCalls = hook.pushEvent.mock.calls.filter(
        ([name]) => name === "alignment_preview_adjusted"
      );
      expect(dirtyCalls).toHaveLength(1);
      expect(hook._previewActive).toBe(false);

      restore();
    });

    it.each([
      ["scale-down", 0.25],
      ["scale-up", 4],
    ])("%s at its clamp boundary is a true no-op", (action, boundaryScale) => {
      const { hook, restore } = mountDirtyHook();
      const initialTransform = { tx: 10, ty: 20, rotation: 30, scale: boundaryScale };
      hook.transform = {...initialTransform};
      hook._previewActive = true;
      hook._applyTransform = vi.fn();

      hook._adjustTransform(action, false);

      expect(hook.transform).toEqual(initialTransform);
      expect(hook._previewActive).toBe(true);
      expect(alignmentDirtyCalls(hook)).toHaveLength(0);
      expect(hook._applyTransform).not.toHaveBeenCalled();

      restore();
    });

    it("effective scale button mutations dirty the preview exactly once", () => {
      const { hook, restore } = mountDirtyHook();
      hook._previewActive = true;
      hook._applyTransform = vi.fn();

      hook._adjustTransform("scale-up", false);
      hook._adjustTransform("scale-up", false);

      expect(hook.transform.scale).toBeCloseTo(1.0201);
      expect(hook._previewActive).toBe(false);
      expect(alignmentDirtyCalls(hook)).toHaveLength(1);
      expect(hook._applyTransform).toHaveBeenCalledTimes(2);

      restore();
    });

    it("center-map preserves _previewActive and does not report dirty", () => {
      const { hook, mapInstance, restore } = mountDirtyHook();
      hook._previewActive = true;

      hook._onApplyCenter();

      expect(hook._previewActive).toBe(true);
      const dirtyCalls = hook.pushEvent.mock.calls.filter(
        ([name]) => name === "alignment_preview_adjusted"
      );
      expect(dirtyCalls).toHaveLength(0);

      restore();
    });

    it("zoom preserves _previewActive and does not report dirty", () => {
      const { hook, restore } = mountDirtyHook();
      hook._previewActive = true;

      hook._handleZoomSliderInput({ target: { value: "17" } });

      expect(hook._previewActive).toBe(true);
      const dirtyCalls = hook.pushEvent.mock.calls.filter(
        ([name]) => name === "alignment_preview_adjusted"
      );
      expect(dirtyCalls).toHaveLength(0);

      restore();
    });
  });

  describe("mount normalization", () => {
    it("normalizes dataset alignment to snake_case savedAlignment and initializes _previewActive", () => {
      document.body.innerHTML = `
        <div id="root" data-initial-lat="40.7128" data-initial-lon="-74.0060" data-initial-zoom="16"
             data-map-generation="gen-mount"
             data-align-center-lat="40.7" data-align-center-lon="-74.0"
             data-align-scale-mpp="0.25" data-align-rotation-deg="15">
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

      leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
      overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
      Object.defineProperty(activeImg, "complete", { value: true, configurable: true });
      Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
      Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });

      const mapInstance = {
        on: vi.fn(),
        off: vi.fn(),
        remove: vi.fn(),
        invalidateSize: vi.fn(),
        setZoom: vi.fn(),
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

      expect(hook.savedAlignment).toEqual({
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.25,
        rotation_deg: 15,
      });
      expect(hook._previewActive).toBe(false);

      window.L = originalL;
      global.fetch = originalFetch;
    });

    it("sets savedAlignment to null when dataset alignment is absent", () => {
      document.body.innerHTML = `
        <div id="root" data-initial-lat="40.7128" data-initial-lon="-74.0060" data-initial-zoom="16"
             data-map-generation="gen-mount">
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

      leafletEl.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
      overlay.getBoundingClientRect = () => ({ width: 300, height: 150, left: 0, top: 0 });
      Object.defineProperty(activeImg, "complete", { value: true, configurable: true });
      Object.defineProperty(activeImg, "naturalWidth", { value: 1000, configurable: true });
      Object.defineProperty(activeImg, "naturalHeight", { value: 800, configurable: true });

      const mapInstance = {
        on: vi.fn(),
        off: vi.fn(),
        remove: vi.fn(),
        invalidateSize: vi.fn(),
        setZoom: vi.fn(),
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

      expect(hook.savedAlignment).toBeNull();
      expect(hook._previewActive).toBe(false);

      window.L = originalL;
      global.fetch = originalFetch;
    });
  });

  describe("reset action removal", () => {
    it("does not apply identity for the reset action", () => {
      const { hook } = buildPartialHook({ generation: "gen-1" });
      hook.transform = { tx: 10, ty: 20, rotation: 30, scale: 2 };
      hook._applyTransform = vi.fn();

      hook._adjustTransform("reset", false);

      expect(hook.transform).toEqual({ tx: 10, ty: 20, rotation: 30, scale: 2 });
      expect(hook._applyTransform).not.toHaveBeenCalled();
    });
  });

  describe("_restoreOverlayAlignment delegates to _cssTransformForAlignment", () => {
    it("uses the shared helper with the active image for saved restore", () => {
      const { hook, img } = buildPartialHook({
        generation: "gen-1",
        canvasDims: { w: 400, h: 200 },
        imageDims: { w: 1000, h: 500 },
        metersPerPx: 0.5,
      });
      hook._userAdjustedTransform = false;
      hook._applyTransform = vi.fn();

      const alignment = { center_lat: 50, center_lon: 100, scale_mpp: 0.25, rotation_deg: 10 };
      hook._restoreOverlayAlignment(hook.overlay, alignment, img, "active");

      expect(hook.transform.rotation).toBe(10);
      expect(hook._applyTransform).toHaveBeenCalled();
    });
  });

  describe("_applyOtherLevelOverlayTransform delegates to _cssTransformForAlignment", () => {
    it("uses the shared helper with the other-level image", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        canvasDims: { w: 400, h: 200 },
        metersPerPx: 0.5,
      });

      const otherImg = document.createElement("img");
      Object.defineProperty(otherImg, "naturalWidth", { value: 2000, configurable: true });
      Object.defineProperty(otherImg, "naturalHeight", { value: 1000, configurable: true });

      const el = document.createElement("div");
      el.appendChild(otherImg);

      const alignment = { center_lat: 50, center_lon: 100, scale_mpp: 0.25, rotation_deg: 5 };
      hook._applyOtherLevelOverlayTransform(el, alignment);

      expect(el.style.transform).toContain("rotate(5deg)");
    });
  });
});
