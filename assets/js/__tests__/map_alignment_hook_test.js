/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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
    Object.defineProperty(img, "naturalWidth", {
      value: 200,
      configurable: true,
    });
    Object.defineProperty(img, "naturalHeight", {
      value: 100,
      configurable: true,
    });

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

    leafletEl.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    overlay.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    Object.defineProperty(activeImg, "complete", {
      value: true,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: 800,
      configurable: true,
    });

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

    leafletEl.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    overlay.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    Object.defineProperty(activeImg, "complete", {
      value: complete,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalWidth", {
      value: naturalWidth,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: naturalHeight,
      configurable: true,
    });

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
      stops: [
        { stop_id: "diagram-late-image", diagram_coordinate: { x: 50, y: 40 } },
      ],
    });

    const pin = document.querySelector("#map-alignment-pins-active .map-pin");
    expect(pin.style.left).toBe("");
    expect(pin.style.top).toBe("");

    Object.defineProperty(activeImg, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: 800,
      configurable: true,
    });
    activeImg.dispatchEvent(new Event("load"));

    expect(pin.style.left).toBe("150px");
    expect(pin.style.top).toBe("75px");

    restore();
  });

  it("does not push open_coordinate_review when apply is clicked while disabled", () => {
    const { hook, applyBtn, restore } = mountApplyHook({
      complete: false,
      naturalWidth: 0,
      naturalHeight: 0,
    });

    applyBtn.dispatchEvent(new Event("click", { bubbles: true }));

    expect(hook.pushEvent).not.toHaveBeenCalledWith(
      "open_coordinate_review",
      expect.anything(),
    );

    restore();
  });

  it("pushes open_coordinate_review with the alignment payload when apply is clicked after enable", () => {
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

    expect(hook.pushEvent).toHaveBeenCalledWith("open_coordinate_review", {
      center_lat: 40.7,
      center_lon: -74.0,
      scale_mpp: 0.25,
      rotation_deg: 10,
    });
    const applyCall = hook.pushEvent.mock.calls.find(
      ([name]) => name === "open_coordinate_review",
    );
    expect(Object.keys(applyCall[1]).sort()).toEqual([
      "center_lat",
      "center_lon",
      "rotation_deg",
      "scale_mpp",
    ]);

    restore();
  });

  it("never pushes the retired apply events from the apply button", () => {
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

    const pushedNames = hook.pushEvent.mock.calls.map(([name]) => name);
    expect(pushedNames).not.toContain("preview_coordinate_application");
    expect(pushedNames).not.toContain("save_and_apply_alignment");
    expect(pushedNames).toContain("open_coordinate_review");

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
        {
          stop_id: "boarding-point",
          lat: 40.705,
          lon: -74.005,
          location_type: 4,
        },
        { stop_id: "entrance", lat: 40.71, lon: -74.01, location_type: 2 },
        {
          stop_id: "generic-node",
          lat: 40.72,
          lon: -74.02,
          location_type: "bad",
        },
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
    expect(boardingPointDot.style.borderColor).toBe(
      cssBorderColor(paletteColor),
    );
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
    Object.defineProperty(img, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(img, "naturalHeight", {
      value: 800,
      configurable: true,
    });

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
    const { hook, activePinsRoot, latLngToContainerPoint } =
      buildPositioningHook();

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
    const { hook, activePinsRoot, latLngToContainerPoint } =
      buildPositioningHook();

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
      "2 anchored to floorplan · 1 positioned from map",
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
    Object.defineProperty(img, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(img, "naturalHeight", {
      value: 800,
      configurable: true,
    });

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

    expect(hook.leafletMap.setZoom).toHaveBeenCalledWith(17, {
      animate: false,
    });
    expect(reposition).toHaveBeenCalledTimes(1);

    // The zoom path debounces a real 400ms invalidation. Production disposes it
    // in destroyed(); a test that walks away leaves the callback to fire after
    // the fixture DOM is gone and crash an unrelated later test.
    hook._clearTransformInvalidationTimer();
  });
});

describe("map_alignment_hook _handleZoomSliderInput user-adjusted marking", () => {
  // Every hook this describe builds debounces a real 400ms invalidation the
  // moment the zoom actually changes. Production disposes that timer in
  // destroyed(); without the same cleanup here the callback fires long after
  // the test returns and throws inside whichever test is running then.
  const liveHooks = [];

  afterEach(() => {
    liveHooks.splice(0).forEach((hook) => {
      hook._clearTransformInvalidationTimer();
    });
  });

  const makeHook = (getZoom) =>
    registerHook({
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

  function registerHook(hook) {
    liveHooks.push(hook);
    return hook;
  }

  it("marks _userAdjustedTransform and applies the zoom update on a changed value", () => {
    const hook = makeHook(16);

    hook._handleZoomSliderInput({ target: { value: "17" } });

    expect(hook._userAdjustedTransform).toBe(true);
    expect(hook.leafletMap.setZoom).toHaveBeenCalledWith(17, {
      animate: false,
    });
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

    leafletEl.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    overlay.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    Object.defineProperty(activeImg, "complete", {
      value: true,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: 800,
      configurable: true,
    });

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

    leafletEl.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    overlay.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    Object.defineProperty(activeImg, "complete", {
      value: true,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: 800,
      configurable: true,
    });

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

    leafletEl.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    overlay.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    Object.defineProperty(activeImg, "complete", {
      value: true,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: 800,
      configurable: true,
    });

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

    leafletEl.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    overlay.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    Object.defineProperty(activeImg, "complete", {
      value: true,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: 800,
      configurable: true,
    });

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
    expect(mapInstance.setView).toHaveBeenCalledWith([40.7128, -74.006], 16, {
      animate: false,
    });

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
    const alignment = {
      center_lat: 40.7,
      center_lon: -74.0,
      scale_mpp: 0.5,
      rotation_deg: 15,
    };

    hook._restoreOverlayAlignment(
      hook.overlay,
      alignment,
      hook.overlay.querySelector("img"),
      "active",
    );

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
    Object.defineProperty(img, "naturalWidth", {
      value: 200,
      configurable: true,
    });
    Object.defineProperty(img, "naturalHeight", {
      value: 100,
      configurable: true,
    });

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
    Object.defineProperty(img, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(img, "naturalHeight", {
      value: 800,
      configurable: true,
    });

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
    hook._pushAlignmentEventIfValid("open_coordinate_review");

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
    expect(hook.pushEvent).toHaveBeenNthCalledWith(
      5,
      "open_coordinate_review",
      {
        generation: "map-42",
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.25,
        rotation_deg: 3,
      },
    );
  });

  it("reports an optional buildings-overlay failure separately from imagery", async () => {
    const originalLeaflet = window.L;
    window.L = {};
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.reject(new Error("unavailable"))),
    );

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
    Object.defineProperty(img, "naturalWidth", {
      value: imageDims.w,
      configurable: true,
    });
    Object.defineProperty(img, "naturalHeight", {
      value: imageDims.h,
      configurable: true,
    });

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

      const alignment = {
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 10,
      };
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

      const alignment = {
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 0,
      };

      const imgA = document.createElement("img");
      Object.defineProperty(imgA, "naturalWidth", {
        value: 1000,
        configurable: true,
      });
      Object.defineProperty(imgA, "naturalHeight", {
        value: 500,
        configurable: true,
      });

      const imgB = document.createElement("img");
      Object.defineProperty(imgB, "naturalWidth", {
        value: 2000,
        configurable: true,
      });
      Object.defineProperty(imgB, "naturalHeight", {
        value: 1000,
        configurable: true,
      });

      const resultA = hook._cssTransformForAlignment(alignment, imgA);
      const resultB = hook._cssTransformForAlignment(alignment, imgB);

      expect(resultA).not.toBeNull();
      expect(resultB).not.toBeNull();
      expect(resultA.scale).not.toBe(resultB.scale);
    });

    it("returns null when the image has no natural dimensions", () => {
      const { hook } = buildPartialHook();

      const badImg = document.createElement("img");
      Object.defineProperty(badImg, "naturalWidth", {
        value: 0,
        configurable: true,
      });
      Object.defineProperty(badImg, "naturalHeight", {
        value: 0,
        configurable: true,
      });

      const alignment = {
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 0,
      };
      expect(hook._cssTransformForAlignment(alignment, badImg)).toBeNull();
    });

    it("returns null when the leaflet map is unavailable", () => {
      const { hook, img } = buildPartialHook();
      hook.leafletMap = null;

      const alignment = {
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 0,
      };
      expect(hook._cssTransformForAlignment(alignment, img)).toBeNull();
    });

    it("returns null when the canvas rect has zero dimensions", () => {
      const { hook, img, leafletEl } = buildPartialHook();
      leafletEl.getBoundingClientRect = () => ({
        width: 0,
        height: 0,
        left: 0,
        top: 0,
      });

      const alignment = {
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 0,
      };
      expect(hook._cssTransformForAlignment(alignment, img)).toBeNull();
    });
  });

  describe("apply_preview_transform", () => {
    it("applies a valid current-generation preview and marks preview active", () => {
      const { hook, img } = buildPartialHook({ generation: "gen-1" });
      hook._applyTransform = vi.fn();

      hook.handleEvent("apply_preview_transform", (payload) =>
        hook._handleApplyPreviewTransform(payload),
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
    ])(
      "rejects %s without changing transform or preview state",
      (_label, invalidField) => {
        const { hook } = buildPartialHook({
          generation: "gen-1",
          previewActive: true,
        });
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
      },
    );

    it("rejects when the image is not ready (null geometry)", () => {
      const { hook } = buildPartialHook({ generation: "gen-1" });
      const badImg = hook.overlay.querySelector("img");
      Object.defineProperty(badImg, "naturalWidth", {
        value: 0,
        configurable: true,
      });
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
        savedAlignment: {
          center_lat: 60,
          center_lon: 110,
          scale_mpp: 0.3,
          rotation_deg: 20,
        },
      });
      hook._applyTransform = vi.fn();

      hook._handleRestoreSavedTransform({ generation: "gen-1" });

      expect(hook.transform.rotation).toBe(20);
      expect(hook._previewActive).toBe(false);
      expect(hook._applyTransform).toHaveBeenCalled();
    });

    it("re-measures the map container before deriving the restored transform", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        savedAlignment: {
          center_lat: 60,
          center_lon: 110,
          scale_mpp: 0.3,
          rotation_deg: 0,
        },
      });

      // The LiveView patch that delivers this event also removes the unsaved
      // indicator, so the container has already changed height while Leaflet
      // still reports the pre-patch projection.
      let staleOffset = 20;
      hook.leafletMap.latLngToContainerPoint = vi.fn(([lat, lon]) => ({
        x: lon,
        y: lat - staleOffset,
      }));
      hook.leafletMap.invalidateSize = vi.fn(() => {
        staleOffset = 0;
      });
      hook._applyTransform = vi.fn();

      hook._handleRestoreSavedTransform({ generation: "gen-1" });

      expect(hook.transform.ty).toBe(-40);
    });

    it("applies identity when no saved alignment exists", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        savedAlignment: null,
      });
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
        savedAlignment: {
          center_lat: 60,
          center_lon: 110,
          scale_mpp: 0.3,
          rotation_deg: 20,
        },
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
        savedAlignment: {
          center_lat: 60,
          center_lon: 110,
          scale_mpp: 0.3,
          rotation_deg: 20,
        },
        previewActive: true,
      });
      const badImg = hook.overlay.querySelector("img");
      Object.defineProperty(badImg, "naturalWidth", {
        value: 0,
        configurable: true,
      });
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
      const { hook } = buildPartialHook({
        generation: "gen-1",
        savedAlignment: null,
      });

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
      const original = {
        center_lat: 1,
        center_lon: 2,
        scale_mpp: 0.1,
        rotation_deg: 0,
      };
      const { hook } = buildPartialHook({
        generation: "gen-2",
        savedAlignment: original,
      });

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
      const original = {
        center_lat: 1,
        center_lon: 2,
        scale_mpp: 0.1,
        rotation_deg: 0,
      };
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
      expect(hook.transform).toEqual({
        tx: 10,
        ty: 20,
        rotation: 30,
        scale: 2,
      });
      expect(hook._previewActive).toBe(true);
      expect(hook._logger.warn).toHaveBeenCalled();
    });

    it("keeps the persisted transform and clears _previewActive", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        previewActive: true,
      });
      hook.transform = { tx: 10, ty: 20, rotation: 30, scale: 2 };

      hook._handleAlignmentSaved({
        generation: "gen-1",
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.15,
        rotation_deg: 5,
      });

      expect(hook.transform).toEqual({
        tx: 10,
        ty: 20,
        rotation: 30,
        scale: 2,
      });
      expect(hook._previewActive).toBe(false);
    });
  });

  describe("_markPreviewDirty", () => {
    it("pushes alignment_preview_adjusted once and clears _previewActive", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        previewActive: true,
      });

      hook._markPreviewDirty();

      expect(hook.pushEvent).toHaveBeenCalledWith(
        "alignment_preview_adjusted",
        {
          generation: "gen-1",
        },
      );
      expect(hook._previewActive).toBe(false);
    });

    it("does not push again on a second call (one-shot)", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        previewActive: true,
      });

      hook._markPreviewDirty();
      hook._markPreviewDirty();

      expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    });

    it("does not push when _previewActive is false", () => {
      const { hook } = buildPartialHook({
        generation: "gen-1",
        previewActive: false,
      });

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
      const rotateHandle = document.getElementById(
        "map-alignment-rotate-handle",
      );
      const scaleHandle = document.getElementById("map-alignment-scale-handle");

      leafletEl.getBoundingClientRect = () => ({
        width: 300,
        height: 150,
        left: 0,
        top: 0,
      });
      overlay.getBoundingClientRect = () => ({
        width: 300,
        height: 150,
        left: 0,
        top: 0,
      });
      Object.defineProperty(activeImg, "complete", {
        value: true,
        configurable: true,
      });
      Object.defineProperty(activeImg, "naturalWidth", {
        value: 1000,
        configurable: true,
      });
      Object.defineProperty(activeImg, "naturalHeight", {
        value: 800,
        configurable: true,
      });

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
        ([name]) => name === "alignment_preview_adjusted",
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
      const savedPayload = { ...applyPayload, rotation_deg: 8 };
      hook._handleApplyPreviewTransform = vi.fn();
      hook._handleRestoreSavedTransform = vi.fn();
      hook._handleAlignmentSaved = vi.fn();

      callbacks.apply_preview_transform(applyPayload);
      callbacks.restore_saved_transform(restorePayload);
      callbacks.alignment_saved(savedPayload);

      expect(hook._handleApplyPreviewTransform).toHaveBeenCalledWith(
        applyPayload,
      );
      expect(hook._handleRestoreSavedTransform).toHaveBeenCalledWith(
        restorePayload,
      );
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

    it.each([
      ["below the minimum", 0.2, 175],
      ["above the maximum", 5, 250],
    ])(
      "scale pointer movement outward from %s is a true no-op",
      (_position, initialScale, outwardClientX) => {
        const { hook, scaleHandle, restore } = mountDirtyHook();
        const initialTransform = {
          tx: 10,
          ty: 20,
          rotation: 30,
          scale: initialScale,
        };
        hook.transform = { ...initialTransform };
        hook._previewActive = true;
        hook._applyTransform = vi.fn();

        dispatchPointer(scaleHandle, "pointerdown", 200, 75);
        dispatchPointer(scaleHandle, "pointermove", outwardClientX, 75);
        dispatchPointer(scaleHandle, "pointerup", outwardClientX, 75);

        expect(hook.transform).toEqual(initialTransform);
        expect(hook._previewActive).toBe(true);
        expect(alignmentDirtyCalls(hook)).toHaveLength(0);
        expect(hook._applyTransform).not.toHaveBeenCalled();

        restore();
      },
    );

    it.each([
      ["below the minimum", 0.2, 205, 0.25, 225, 0.3, "increase"],
      ["above the maximum", 5, 195, 4, 185, 3.5, "decrease"],
    ])(
      "scale pointer movement inward from %s moves in the requested direction and dirties once",
      (
        _position,
        initialScale,
        boundaryClientX,
        boundaryScale,
        inwardClientX,
        expectedScale,
        direction,
      ) => {
        const { hook, scaleHandle, restore } = mountDirtyHook();
        hook.transform.scale = initialScale;
        hook._previewActive = true;
        hook._applyTransform = vi.fn();

        dispatchPointer(scaleHandle, "pointerdown", 200, 75);
        dispatchPointer(scaleHandle, "pointermove", boundaryClientX, 75);

        expect(hook.transform.scale).toBeCloseTo(boundaryScale);

        dispatchPointer(scaleHandle, "pointermove", inwardClientX, 75);
        dispatchPointer(scaleHandle, "pointerup", inwardClientX, 75);

        expect(hook.transform.scale).toBeCloseTo(expectedScale);
        if (direction === "increase") {
          expect(hook.transform.scale).toBeGreaterThan(initialScale);
        } else {
          expect(hook.transform.scale).toBeLessThan(initialScale);
        }
        expect(hook._previewActive).toBe(false);
        expect(alignmentDirtyCalls(hook)).toHaveLength(1);
        expect(hook._applyTransform).toHaveBeenCalledTimes(2);

        restore();
      },
    );

    it("transform button mutation reports dirty once during active preview", () => {
      const { hook, restore } = mountDirtyHook();
      hook._previewActive = true;

      hook._adjustTransform("left", false);

      const dirtyCalls = hook.pushEvent.mock.calls.filter(
        ([name]) => name === "alignment_preview_adjusted",
      );
      expect(dirtyCalls).toHaveLength(1);
      expect(hook._previewActive).toBe(false);

      restore();
    });

    it.each([
      ["scale-down", 0.2],
      ["scale-up", 5],
    ])(
      "%s outward from an out-of-range scale is a true no-op",
      (action, initialScale) => {
        const { hook, restore } = mountDirtyHook();
        const initialTransform = {
          tx: 10,
          ty: 20,
          rotation: 30,
          scale: initialScale,
        };
        hook.transform = { ...initialTransform };
        hook._previewActive = true;
        hook._applyTransform = vi.fn();

        hook._adjustTransform(action, false);

        expect(hook.transform).toEqual(initialTransform);
        expect(hook._previewActive).toBe(true);
        expect(alignmentDirtyCalls(hook)).toHaveLength(0);
        expect(hook._applyTransform).not.toHaveBeenCalled();

        restore();
      },
    );

    it.each([
      ["scale-up", 0.2, 0.25, "increase"],
      ["scale-down", 5, 4, "decrease"],
    ])(
      "%s inward from an out-of-range scale moves in the requested direction and dirties once",
      (action, initialScale, expectedScale, direction) => {
        const { hook, restore } = mountDirtyHook();
        hook.transform.scale = initialScale;
        hook._previewActive = true;
        hook._applyTransform = vi.fn();

        hook._adjustTransform(action, false);

        expect(hook.transform.scale).toBeCloseTo(expectedScale);
        if (direction === "increase") {
          expect(hook.transform.scale).toBeGreaterThan(initialScale);
        } else {
          expect(hook.transform.scale).toBeLessThan(initialScale);
        }
        expect(hook._previewActive).toBe(false);
        expect(alignmentDirtyCalls(hook)).toHaveLength(1);
        expect(hook._applyTransform).toHaveBeenCalledTimes(1);

        restore();
      },
    );

    it.each([
      ["scale-down", 0.25],
      ["scale-up", 4],
    ])("%s at its clamp boundary is a true no-op", (action, boundaryScale) => {
      const { hook, restore } = mountDirtyHook();
      const initialTransform = {
        tx: 10,
        ty: 20,
        rotation: 30,
        scale: boundaryScale,
      };
      hook.transform = { ...initialTransform };
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
        ([name]) => name === "alignment_preview_adjusted",
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
        ([name]) => name === "alignment_preview_adjusted",
      );
      expect(dirtyCalls).toHaveLength(0);

      restore();
    });
  });

  describe("transform invalidation (_transformDidChange)", () => {
    function mountInvalidationHook() {
      document.body.innerHTML = `
        <div id="root" data-initial-lat="40.7128" data-initial-lon="-74.0060" data-initial-zoom="16" data-map-generation="gen-invalidation">
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
          <button data-map-transform-action="scale-up"></button>
        </div>
      `;

      const root = document.getElementById("root");
      const overlay = document.getElementById("map-alignment-overlay");
      const activeImg = document.getElementById("active-img");
      const leafletEl = document.getElementById("map-alignment-leaflet");

      leafletEl.getBoundingClientRect = () => ({
        width: 300,
        height: 150,
        left: 0,
        top: 0,
      });
      overlay.getBoundingClientRect = () => ({
        width: 300,
        height: 150,
        left: 0,
        top: 0,
      });
      Object.defineProperty(activeImg, "complete", {
        value: true,
        configurable: true,
      });
      Object.defineProperty(activeImg, "naturalWidth", {
        value: 1000,
        configurable: true,
      });
      Object.defineProperty(activeImg, "naturalHeight", {
        value: 800,
        configurable: true,
      });

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

    function invalidationCalls(hook) {
      return hook.pushEvent.mock.calls.filter(
        ([name]) => name === "alignment_transform_changed",
      );
    }

    function dispatchPointer(target, type, clientX, clientY) {
      const event = new Event(type, { bubbles: true });
      event.button = 0;
      event.clientX = clientX;
      event.clientY = clientY;
      event.pointerId = 1;
      target.dispatchEvent(event);
    }

    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("translate pointer mutation schedules one generation-tagged invalidation", () => {
      const { hook, overlay, restore } = mountInvalidationHook();

      dispatchPointer(overlay, "pointerdown", 100, 50);
      dispatchPointer(overlay, "pointermove", 120, 60);
      dispatchPointer(overlay, "pointerup", 120, 60);

      expect(invalidationCalls(hook)).toHaveLength(0);
      vi.advanceTimersByTime(401);
      const calls = invalidationCalls(hook);
      expect(calls).toHaveLength(1);
      expect(calls[0][1]).toEqual({
        generation: "gen-invalidation",
        unsaved: true,
        alignment: {
          center_lat: expect.any(Number),
          center_lon: expect.any(Number),
          scale_mpp: expect.any(Number),
          rotation_deg: expect.any(Number),
        },
      });

      restore();
    });

    it("rotate and scale pointer mutations route through the shared path", () => {
      const { hook, overlay, restore } = mountInvalidationHook();
      const rotateHandle = document.getElementById(
        "map-alignment-rotate-handle",
      );
      const scaleHandle = document.getElementById("map-alignment-scale-handle");

      dispatchPointer(rotateHandle, "pointerdown", 200, 75);
      dispatchPointer(rotateHandle, "pointermove", 100, 75);
      dispatchPointer(rotateHandle, "pointerup", 100, 75);

      dispatchPointer(scaleHandle, "pointerdown", 200, 75);
      dispatchPointer(scaleHandle, "pointermove", 300, 75);
      dispatchPointer(scaleHandle, "pointerup", 300, 75);

      vi.advanceTimersByTime(401);
      // Two bursts collapse into one coalesced push per debounce window.
      expect(invalidationCalls(hook)).toHaveLength(1);

      restore();
    });

    it("transform buttons schedule invalidation and preserve preview-dirty", () => {
      const { hook, restore } = mountInvalidationHook();
      hook._previewActive = true;

      hook._adjustTransform("left", false);

      const dirtyCalls = hook.pushEvent.mock.calls.filter(
        ([name]) => name === "alignment_preview_adjusted",
      );
      expect(dirtyCalls).toHaveLength(1);
      expect(hook._previewActive).toBe(false);

      vi.advanceTimersByTime(401);
      expect(invalidationCalls(hook)).toHaveLength(1);

      restore();
    });

    it("center-map and zoom schedule invalidation without dirtying the preview", () => {
      const { hook, restore } = mountInvalidationHook();
      hook._previewActive = true;

      hook._onApplyCenter();
      hook._handleZoomSliderInput({ target: { value: "17" } });

      const dirtyCalls = hook.pushEvent.mock.calls.filter(
        ([name]) => name === "alignment_preview_adjusted",
      );
      expect(dirtyCalls).toHaveLength(0);
      expect(hook._previewActive).toBe(true);

      vi.advanceTimersByTime(401);
      expect(invalidationCalls(hook)).toHaveLength(1);

      restore();
    });

    it("assisted-preview application and restore schedule invalidation without dirtying", () => {
      const { hook, restore } = mountInvalidationHook();
      hook._previewActive = true;

      hook._handleApplyPreviewTransform({
        generation: "gen-invalidation",
        center_lat: 40.71,
        center_lon: -74.01,
        scale_mpp: 0.3,
        rotation_deg: 5,
      });
      // Applying the assisted preview sets _previewActive true; it must not
      // immediately dirty itself.
      expect(hook._previewActive).toBe(true);
      expect(
        hook.pushEvent.mock.calls.filter(
          ([n]) => n === "alignment_preview_adjusted",
        ),
      ).toHaveLength(0);

      hook._handleRestoreSavedTransform({ generation: "gen-invalidation" });
      expect(hook._previewActive).toBe(false);

      vi.advanceTimersByTime(401);
      expect(invalidationCalls(hook)).toHaveLength(1);

      restore();
    });

    it("coalesces a burst of mutations into exactly one invalidation per window", () => {
      const { hook, restore } = mountInvalidationHook();

      hook._adjustTransform("left", false);
      hook._adjustTransform("left", false);
      hook._adjustTransform("left", false);

      expect(invalidationCalls(hook)).toHaveLength(0);
      vi.advanceTimersByTime(401);
      expect(invalidationCalls(hook)).toHaveLength(1);

      // A later mutation starts a fresh window.
      hook._adjustTransform("left", false);
      vi.advanceTimersByTime(401);
      expect(invalidationCalls(hook)).toHaveLength(2);

      restore();
    });

    it("consumes the reviewed transform's pending invalidation and schedules later changes", () => {
      const { hook, restore } = mountInvalidationHook();
      const applyBtn = document.getElementById("map-alignment-apply");

      hook._computeAlignment = vi.fn(() => ({
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.25,
        rotation_deg: 10,
      }));

      hook._adjustTransform("left", false);
      expect(hook._transformInvalidationTimer).toBeTruthy();

      applyBtn.dispatchEvent(new Event("click", { bubbles: true }));

      expect(hook._transformInvalidationTimer).toBeNull();
      expect(hook.pushEvent).toHaveBeenCalledWith("open_coordinate_review", {
        generation: "gen-invalidation",
        center_lat: 40.7,
        center_lon: -74.0,
        scale_mpp: 0.25,
        rotation_deg: 10,
      });

      vi.advanceTimersByTime(401);
      expect(invalidationCalls(hook)).toHaveLength(0);

      hook._adjustTransform("left", false);
      vi.advanceTimersByTime(401);
      expect(invalidationCalls(hook)).toHaveLength(1);

      restore();
    });

    it("clears the stored timer in destroyed() and pushes nothing afterwards", () => {
      const { hook, restore } = mountInvalidationHook();

      hook._adjustTransform("left", false);
      expect(hook._transformInvalidationTimer).toBeTruthy();

      hook.destroyed();
      expect(hook._transformInvalidationTimer).toBeNull();

      // Flushing the window after destroy must not push (no leak, no callback).
      vi.advanceTimersByTime(1000);
      expect(invalidationCalls(hook)).toHaveLength(0);

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

      leafletEl.getBoundingClientRect = () => ({
        width: 300,
        height: 150,
        left: 0,
        top: 0,
      });
      overlay.getBoundingClientRect = () => ({
        width: 300,
        height: 150,
        left: 0,
        top: 0,
      });
      Object.defineProperty(activeImg, "complete", {
        value: true,
        configurable: true,
      });
      Object.defineProperty(activeImg, "naturalWidth", {
        value: 1000,
        configurable: true,
      });
      Object.defineProperty(activeImg, "naturalHeight", {
        value: 800,
        configurable: true,
      });

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

      leafletEl.getBoundingClientRect = () => ({
        width: 300,
        height: 150,
        left: 0,
        top: 0,
      });
      overlay.getBoundingClientRect = () => ({
        width: 300,
        height: 150,
        left: 0,
        top: 0,
      });
      Object.defineProperty(activeImg, "complete", {
        value: true,
        configurable: true,
      });
      Object.defineProperty(activeImg, "naturalWidth", {
        value: 1000,
        configurable: true,
      });
      Object.defineProperty(activeImg, "naturalHeight", {
        value: 800,
        configurable: true,
      });

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

      expect(hook.transform).toEqual({
        tx: 10,
        ty: 20,
        rotation: 30,
        scale: 2,
      });
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

      const alignment = {
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 10,
      };
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
      Object.defineProperty(otherImg, "naturalWidth", {
        value: 2000,
        configurable: true,
      });
      Object.defineProperty(otherImg, "naturalHeight", {
        value: 1000,
        configurable: true,
      });

      const el = document.createElement("div");
      el.appendChild(otherImg);

      const alignment = {
        center_lat: 50,
        center_lon: 100,
        scale_mpp: 0.25,
        rotation_deg: 5,
      };
      hook._applyOtherLevelOverlayTransform(el, alignment);

      expect(el.style.transform).toContain("rotate(5deg)");
    });
  });
});

describe("map_alignment_hook transform steps, readouts, and unsaved reporting", () => {
  const GENERATION = "gen-step4";
  const DEBOUNCE_MS = 401;

  // The debounced payload now carries the hook's computed alignment. These
  // tests are about `unsaved`, so they pin the key and its field types; the
  // exact geometry is pinned once, in "carries the computed alignment".
  const NUMERIC_ALIGNMENT = {
    center_lat: expect.any(Number),
    center_lon: expect.any(Number),
    scale_mpp: expect.any(Number),
    rotation_deg: expect.any(Number),
  };

  // Opposing nudge pairs in both orders. Applying one and then the other at the
  // same modifier state must return the transform to where it started — the
  // defect this package exists to fix.
  const OPPOSING_SEQUENCES = [
    ["left", "right"],
    ["right", "left"],
    ["up", "down"],
    ["down", "up"],
    ["rotate-left", "rotate-right"],
    ["rotate-right", "rotate-left"],
    ["scale-down", "scale-up"],
    ["scale-up", "scale-down"],
  ];

  // Step sizes read from _adjustTransform: 2 px / 1° / ×1.01 fine,
  // 10 px / 5° / ×1.1 coarse.
  const FINE_STEPS = [
    ["left", "tx", -2],
    ["right", "tx", 2],
    ["up", "ty", -2],
    ["down", "ty", 2],
    ["rotate-left", "rotation", -1],
    ["rotate-right", "rotation", 1],
    ["scale-down", "scale", 1 / 1.01],
    ["scale-up", "scale", 1.01],
  ];

  const COARSE_STEPS = [
    ["left", "tx", -10],
    ["right", "tx", 10],
    ["up", "ty", -10],
    ["down", "ty", 10],
    ["rotate-left", "rotation", -5],
    ["rotate-right", "rotation", 5],
    ["scale-down", "scale", 1 / 1.1],
    ["scale-up", "scale", 1.1],
  ];

  const TRANSFORM_BUTTONS = `
    <button id="map-transform-left-fine" data-map-transform-action="left" data-map-transform-coarse="false"></button>
    <button id="map-transform-up-fine" data-map-transform-action="up" data-map-transform-coarse="false"></button>
    <button id="map-transform-down-fine" data-map-transform-action="down" data-map-transform-coarse="false"></button>
    <button id="map-transform-right-fine" data-map-transform-action="right" data-map-transform-coarse="false"></button>
    <button id="map-transform-rotate-left-fine" data-map-transform-action="rotate-left" data-map-transform-coarse="false"></button>
    <button id="map-transform-rotate-right-fine" data-map-transform-action="rotate-right" data-map-transform-coarse="false"></button>
    <button id="map-transform-scale-down-fine" data-map-transform-action="scale-down" data-map-transform-coarse="false"></button>
    <button id="map-transform-scale-up-fine" data-map-transform-action="scale-up" data-map-transform-coarse="false"></button>
  `;

  let originalL;
  let originalFetch;

  beforeEach(() => {
    vi.useFakeTimers();
    originalL = window.L;
    originalFetch = global.fetch;
  });

  afterEach(() => {
    window.L = originalL;
    global.fetch = originalFetch;
    vi.useRealTimers();
    document.body.innerHTML = "";
  });

  function stubGeometry() {
    const overlay = document.getElementById("map-alignment-overlay");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const activeImg = document.getElementById("active-img");

    leafletEl.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    overlay.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    Object.defineProperty(activeImg, "complete", {
      value: true,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: 800,
      configurable: true,
    });
  }

  function bootHook(initialZoom) {
    stubGeometry();

    const zoomState = { current: initialZoom };
    const mapInstance = {
      on: vi.fn(),
      off: vi.fn(),
      remove: vi.fn(),
      invalidateSize: vi.fn(),
      setZoom: vi.fn((value) => {
        zoomState.current = value;
      }),
      getZoom: vi.fn(() => zoomState.current),
      getMinZoom: vi.fn(() => 19),
      getMaxZoom: vi.fn(() => 22),
      setView: vi.fn(),
      latLngToContainerPoint: vi.fn((pt) => ({ x: pt.lng, y: pt.lat })),
      containerPointToLatLng: vi.fn(([x, y]) => ({ lat: y, lng: x })),
      distance: vi.fn(() => 1),
      removeLayer: vi.fn(),
    };

    global.fetch = vi.fn(() => Promise.resolve({ ok: false }));
    window.L = {
      map: vi.fn(() => mapInstance),
      tileLayer: vi.fn(() => ({ addTo: vi.fn() })),
      geoJSON: vi.fn(() => ({ addTo: vi.fn() })),
    };

    const hook = {
      ...MapAlignmentHook,
      el: document.getElementById("root"),
      pushEvent: vi.fn(),
      handleEvent: vi.fn(),
    };

    hook.mounted();

    const zoomEndEntry = mapInstance.on.mock.calls.find(
      ([event]) => event === "zoomend",
    );

    return {
      hook,
      mapInstance,
      setMapZoom: (value) => {
        zoomState.current = value;
      },
      fireZoomEnd: zoomEndEntry ? zoomEndEntry[1] : null,
    };
  }

  // Full production-shaped strip: eight symmetric fine-step buttons, a legacy
  // data-map-transform-coarse="true" control, all five readout elements, and
  // the conditionally-rendered other-levels slider.
  function mountAlignHook(initialZoom = 19) {
    document.body.innerHTML = `
      <div id="root" data-initial-lat="40.7128" data-initial-lon="-74.0060" data-initial-zoom="19" data-map-generation="${GENERATION}">
        <div id="map-alignment-overlay" data-editable-overlay="true"><img id="active-img" /></div>
        <div id="map-alignment-leaflet"></div>
        <button id="map-alignment-rotate-handle" data-edit-target-overlay="active"></button>
        <button id="map-alignment-scale-handle" data-edit-target-overlay="active"></button>
        <div id="map-alignment-pins-active"></div>
        <div id="map-other-overlays"></div>
        <div id="map-other-pins"></div>
        <input id="map-alignment-lat-input" value="40.7128" />
        <input id="map-alignment-lon-input" value="-74.0060" />
        <button id="map-alignment-apply-center"></button>
        ${TRANSFORM_BUTTONS}
        <button id="legacy-coarse-right" data-map-transform-action="right" data-map-transform-coarse="true"></button>
        <input id="map-alignment-opacity" type="range" min="0" max="1" step="0.05" value="0.7" />
        <span id="map-alignment-zoom-value">19.0</span>
        <input id="map-alignment-zoom" type="range" min="19" max="22" step="0.5" value="19" />
        <input id="map-other-overlays-opacity" type="range" min="0" max="1" step="0.05" value="0.7" />
        <button id="map-alignment-save"></button>
        <button id="map-alignment-apply"></button>
      </div>
    `;

    return bootHook(initialZoom);
  }

  // Partial DOM, the shape the older isolated fixtures mount: no readout
  // elements at all and no other-levels slider.
  function mountReadoutFreeHook() {
    document.body.innerHTML = `
      <div id="root" data-initial-lat="40.7128" data-initial-lon="-74.0060" data-initial-zoom="19" data-map-generation="${GENERATION}">
        <div id="map-alignment-overlay" data-editable-overlay="true"><img id="active-img" /></div>
        <div id="map-alignment-leaflet"></div>
        <button id="map-alignment-rotate-handle" data-edit-target-overlay="active"></button>
        <button id="map-alignment-scale-handle" data-edit-target-overlay="active"></button>
        <div id="map-alignment-pins-active"></div>
        <input id="map-alignment-lat-input" value="40.7128" />
        <input id="map-alignment-lon-input" value="-74.0060" />
        <button id="map-alignment-apply-center"></button>
        ${TRANSFORM_BUTTONS}
        <input id="map-alignment-opacity" type="range" min="0" max="1" step="0.05" value="0.7" />
        <input id="map-alignment-zoom" type="range" min="19" max="22" step="0.5" value="19" />
        <button id="map-alignment-save"></button>
        <button id="map-alignment-apply"></button>
      </div>
    `;

    return bootHook(19);
  }

  function clickTransform(action, shiftKey) {
    document
      .querySelector(
        `[data-map-transform-action="${action}"][data-map-transform-coarse="false"]`,
      )
      .dispatchEvent(new MouseEvent("click", { bubbles: true, shiftKey }));
  }

  function dispatchPointer(target, type, clientX, clientY) {
    const event = new Event(type, { bubbles: true });
    event.button = 0;
    event.clientX = clientX;
    event.clientY = clientY;
    event.pointerId = 1;
    target.dispatchEvent(event);
  }

  function sliderInput(id, value) {
    const slider = document.getElementById(id);
    slider.value = value;
    slider.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function readoutText(id) {
    return document.getElementById(id).textContent;
  }

  function invalidationPayloads(hook) {
    return hook.pushEvent.mock.calls
      .filter(([name]) => name === "alignment_transform_changed")
      .map(([, payload]) => payload);
  }

  describe("opposing nudges are inverse at equal modifier state", () => {
    it.each(OPPOSING_SEQUENCES)(
      "a plain %s click then a plain %s click returns the transform to its start",
      (first, second) => {
        const { hook } = mountAlignHook();
        const start = { ...hook.transform };

        clickTransform(first, false);
        clickTransform(second, false);

        expect(hook.transform.tx).toBe(start.tx);
        expect(hook.transform.ty).toBe(start.ty);
        expect(hook.transform.rotation).toBe(start.rotation);
        expect(hook.transform.scale).toBeCloseTo(start.scale, 10);
      },
    );

    it.each(OPPOSING_SEQUENCES)(
      "a Shift %s click then a Shift %s click returns the transform to its start",
      (first, second) => {
        const { hook } = mountAlignHook();
        const start = { ...hook.transform };

        clickTransform(first, true);
        clickTransform(second, true);

        expect(hook.transform.tx).toBe(start.tx);
        expect(hook.transform.ty).toBe(start.ty);
        expect(hook.transform.rotation).toBe(start.rotation);
        expect(hook.transform.scale).toBeCloseTo(start.scale, 10);
      },
    );
  });

  describe("Shift resolves the coarse step", () => {
    it.each(FINE_STEPS)(
      "a plain click on %s applies the fine step to %s",
      (action, field, expected) => {
        const { hook } = mountAlignHook();

        clickTransform(action, false);

        expect(hook.transform[field]).toBeCloseTo(expected, 10);
      },
    );

    it.each(COARSE_STEPS)(
      "a Shift-click on %s applies the coarse step to %s",
      (action, field, expected) => {
        const { hook } = mountAlignHook();

        clickTransform(action, true);

        expect(hook.transform[field]).toBeCloseTo(expected, 10);
      },
    );

    it("a plain click on a coarse-flagged control still applies the coarse step", () => {
      const { hook } = mountAlignHook();

      document
        .getElementById("legacy-coarse-right")
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));

      expect(hook.transform.tx).toBe(10);
    });
  });

  // Rotation and scale carry no on-screen readout: the pad is icon-only and the
  // operator judges the fit from the floorplan and the residual in the commit
  // bar. The transform the buttons produce is still the contract.
  describe("transform nudges", () => {
    it("applies the coarse rotate step on a Shift rotate nudge", () => {
      const { hook } = mountAlignHook();

      clickTransform("rotate-right", true);

      expect(hook.transform.rotation).toBe(5);
    });

    it("applies the coarse scale step on a Shift scale nudge", () => {
      const { hook } = mountAlignHook();

      clickTransform("scale-up", true);

      expect(hook.transform.scale).toBeCloseTo(1.1, 5);
    });

    it("leaves rotation and scale untouched on the pointer-drag path", () => {
      const { hook } = mountAlignHook();
      const overlay = document.getElementById("map-alignment-overlay");

      dispatchPointer(overlay, "pointerdown", 100, 50);
      dispatchPointer(overlay, "pointermove", 120, 60);
      dispatchPointer(overlay, "pointerup", 120, 60);

      expect(hook.transform).toMatchObject({
        tx: 20,
        ty: 10,
        rotation: 0,
        scale: 1,
      });
    });

    it("writes no rotation or scale readout even when one is present", () => {
      const { hook } = mountAlignHook();
      const stray = document.createElement("span");
      stray.id = "map-alignment-rotation-value";
      stray.textContent = "untouched";
      document.body.appendChild(stray);

      hook.transform = { tx: 4, ty: 6, rotation: 12.34, scale: 0.857 };
      hook._applyTransform();

      expect(stray.textContent).toBe("untouched");
    });
  });

  describe("slider readouts", () => {
    it("writes the floorplan-opacity percentage into the slider tooltip on input", () => {
      mountAlignHook();

      sliderInput("map-alignment-opacity", "0.35");

      expect(
        document.getElementById("map-alignment-opacity").getAttribute("title"),
      ).toBe("Floorplan opacity · 35%");
    });

    it("writes the map-zoom readout to one decimal on input", () => {
      mountAlignHook();

      sliderInput("map-alignment-zoom", "20.5");

      expect(readoutText("map-alignment-zoom-value")).toBe("20.5");
    });

    it("writes the other-levels opacity percentage into the slider tooltip on input", () => {
      mountAlignHook();

      sliderInput("map-other-overlays-opacity", "0.4");

      expect(
        document
          .getElementById("map-other-overlays-opacity")
          .getAttribute("title"),
      ).toBe("Other-levels opacity · 40%");
    });

    it("writes the map-zoom readout when the map zoom changes without slider input", () => {
      const { setMapZoom, fireZoomEnd } = mountAlignHook();

      setMapZoom(21);
      fireZoomEnd();

      expect(readoutText("map-alignment-zoom-value")).toBe("21.0");
    });

    it("writes the map-zoom readout from the live map zoom at mount", () => {
      mountAlignHook(21);

      expect(readoutText("map-alignment-zoom-value")).toBe("21.0");
    });
  });

  describe("partial DOM tolerance", () => {
    it("completes a transform nudge and a slider input when no readout elements exist", () => {
      const { hook } = mountReadoutFreeHook();

      expect(() => hook._adjustTransform("left", true)).not.toThrow();
      expect(() =>
        hook._onOpacityInput({ target: { value: "0.4" } }),
      ).not.toThrow();
      expect(() =>
        hook._handleZoomSliderInput({ target: { value: "20" } }),
      ).not.toThrow();

      expect(hook.transform.tx).toBe(-10);
      expect(
        document.getElementById("map-alignment-overlay").style.opacity,
      ).toBe("0.4");
    });

    it("syncs slider readouts without throwing when no slider is bound", () => {
      const hook = { ...MapAlignmentHook };

      expect(() => hook._syncSliderReadouts()).not.toThrow();
    });
  });

  describe("unsaved reporting in the debounced payload", () => {
    it("reports unsaved true after an operator nudge", () => {
      const { hook } = mountAlignHook();

      clickTransform("left", false);
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        { generation: GENERATION, unsaved: true, alignment: NUMERIC_ALIGNMENT },
      ]);
    });

    it("reports unsaved true after an overlay drag", () => {
      const { hook } = mountAlignHook();
      const overlay = document.getElementById("map-alignment-overlay");

      dispatchPointer(overlay, "pointerdown", 100, 50);
      dispatchPointer(overlay, "pointermove", 120, 60);
      dispatchPointer(overlay, "pointerup", 120, 60);
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        { generation: GENERATION, unsaved: true, alignment: NUMERIC_ALIGNMENT },
      ]);
    });

    it("reports unsaved false after restoring the saved transform", () => {
      const { hook } = mountAlignHook();

      hook._handleRestoreSavedTransform({ generation: GENERATION });
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        {
          generation: GENERATION,
          unsaved: false,
          alignment: NUMERIC_ALIGNMENT,
        },
      ]);
    });

    it("reports unsaved true after applying an assisted preview", () => {
      const { hook } = mountAlignHook();

      hook._handleApplyPreviewTransform({
        generation: GENERATION,
        center_lat: 40.71,
        center_lon: -74.01,
        scale_mpp: 0.3,
        rotation_deg: 5,
      });
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        { generation: GENERATION, unsaved: true, alignment: NUMERIC_ALIGNMENT },
      ]);
    });

    it("keeps the assisted preview active while reporting it unsaved", () => {
      const { hook } = mountAlignHook();

      hook._handleApplyPreviewTransform({
        generation: GENERATION,
        center_lat: 40.71,
        center_lon: -74.01,
        scale_mpp: 0.3,
        rotation_deg: 5,
      });
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(hook._previewActive).toBe(true);
      expect(
        hook.pushEvent.mock.calls.filter(
          ([name]) => name === "alignment_preview_adjusted",
        ),
      ).toHaveLength(0);
    });

    it("reports unsaved false after a map recenter", () => {
      const { hook } = mountAlignHook();

      hook._onApplyCenter();
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        {
          generation: GENERATION,
          unsaved: false,
          alignment: NUMERIC_ALIGNMENT,
        },
      ]);
    });

    it("reports unsaved false when a restore follows a nudge inside one debounce window", () => {
      const { hook } = mountAlignHook();

      clickTransform("left", false);
      vi.advanceTimersByTime(100);
      hook._handleRestoreSavedTransform({ generation: GENERATION });
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        {
          generation: GENERATION,
          unsaved: false,
          alignment: NUMERIC_ALIGNMENT,
        },
      ]);
    });

    it("reports unsaved true when a nudge follows a restore inside one debounce window", () => {
      const { hook } = mountAlignHook();

      hook._handleRestoreSavedTransform({ generation: GENERATION });
      vi.advanceTimersByTime(100);
      clickTransform("left", false);
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        { generation: GENERATION, unsaved: true, alignment: NUMERIC_ALIGNMENT },
      ]);
    });

    it("reports nothing when an opened coordinate review consumes the pending push", () => {
      const { hook } = mountAlignHook();

      clickTransform("left", false);
      document
        .getElementById("map-alignment-apply")
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(hook._transformInvalidationTimer).toBeNull();
      expect(invalidationPayloads(hook)).toEqual([]);
      expect(
        hook.pushEvent.mock.calls.filter(
          ([name]) => name === "open_coordinate_review",
        ),
      ).toHaveLength(1);
    });

    it("reports nothing after the hook is destroyed mid-window", () => {
      const { hook } = mountAlignHook();

      clickTransform("left", false);
      hook.destroyed();
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(hook._transformInvalidationTimer).toBeNull();
      expect(invalidationPayloads(hook)).toEqual([]);
    });
  });

  describe("alignment in the debounced payload", () => {
    // The fixture pins every input _computeAlignment reads: a 300x150 Leaflet
    // box centred on container point (150, 75), a stub projection returning
    // {lat: y, lng: x}, one metre per canvas pixel, and a 1000x800 image that
    // object-contains to 187.5 rendered px (0.1875 m per natural pixel at
    // scale 1). A fine "left" nudge moves the centre to container x = 148.
    it("carries the computed alignment for the reported transform", () => {
      const { hook } = mountAlignHook();

      clickTransform("left", false);
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        {
          generation: GENERATION,
          unsaved: true,
          alignment: {
            center_lat: 75,
            center_lon: 148,
            scale_mpp: 0.1875,
            rotation_deg: 0,
          },
        },
      ]);
    });

    it("carries the last transform of a coalesced window, not the first", () => {
      const { hook } = mountAlignHook();

      clickTransform("left", false);
      vi.advanceTimersByTime(100);
      clickTransform("left", false);
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        {
          generation: GENERATION,
          unsaved: true,
          alignment: {
            center_lat: 75,
            center_lon: 146,
            scale_mpp: 0.1875,
            rotation_deg: 0,
          },
        },
      ]);
    });

    it("omits the alignment key when the floorplan image is not loaded", () => {
      const { hook } = mountAlignHook();
      Object.defineProperty(document.getElementById("active-img"), "complete", {
        value: false,
        configurable: true,
      });

      clickTransform("left", false);
      vi.advanceTimersByTime(DEBOUNCE_MS);

      const [payload] = invalidationPayloads(hook);
      expect(Object.keys(payload).sort()).toEqual(["generation", "unsaved"]);
      expect(payload).toEqual({ generation: GENERATION, unsaved: true });
    });

    it("carries the alignment again after a review cancels a pending window", () => {
      const { hook } = mountAlignHook();

      clickTransform("left", false);
      document
        .getElementById("map-alignment-apply")
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));
      vi.advanceTimersByTime(DEBOUNCE_MS);
      clickTransform("left", false);
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        {
          generation: GENERATION,
          unsaved: true,
          alignment: {
            center_lat: 75,
            center_lon: 146,
            scale_mpp: 0.1875,
            rotation_deg: 0,
          },
        },
      ]);
    });
  });
});

// Part (e) step 8. These fixtures are the only ones in this file shaped like
// production's *nesting*: #map-alignment-workspace wraps the ignored canvas
// (the hook root) and #map-alignment-tools is a SIBLING of that canvas, not a
// child. That relationship is the whole point of the step — a keydown listener
// on the hook root cannot see a key pressed while focus sits on a tools-panel
// button, which is the most likely place for focus to be (CRIT-004, INV-10E-3).
describe("map_alignment_hook keyboard, hold-to-hide, collapse, measuring", () => {
  const GENERATION = "gen-step8";
  const DEBOUNCE_MS = 401;

  // Same eight actions the buttons drive, reached by key. Steps are read from
  // _adjustTransform and must equal the button steps exactly (INV-09D-4).
  const FINE_KEYS = [
    ["ArrowLeft", "tx", -2],
    ["ArrowRight", "tx", 2],
    ["ArrowUp", "ty", -2],
    ["ArrowDown", "ty", 2],
    ["[", "rotation", -1],
    ["]", "rotation", 1],
    ["-", "scale", 1 / 1.01],
    ["=", "scale", 1.01],
  ];

  // Shift is the coarse modifier. On a US layout it also changes the printable
  // character the bracket and scale keys report, so the shifted face of each
  // key has to resolve the same action or Shift+[ would silently do nothing.
  const COARSE_KEYS = [
    ["ArrowLeft", "tx", -10],
    ["ArrowRight", "tx", 10],
    ["ArrowUp", "ty", -10],
    ["ArrowDown", "ty", 10],
    ["{", "rotation", -5],
    ["}", "rotation", 5],
    ["_", "scale", 1 / 1.1],
    ["+", "scale", 1.1],
  ];

  const IGNORED_TARGET_MARKUP = [
    ['<input id="guard-input" />', "guard-input"],
    ['<textarea id="guard-textarea"></textarea>', "guard-textarea"],
    ['<select id="guard-select"></select>', "guard-select"],
    [
      '<div id="guard-contenteditable" contenteditable="true"></div>',
      "guard-contenteditable",
    ],
  ];

  let originalL;
  let originalFetch;
  const liveHooks = [];

  beforeEach(() => {
    vi.useFakeTimers();
    originalL = window.L;
    originalFetch = global.fetch;
  });

  afterEach(() => {
    liveHooks.splice(0).forEach((hook) => hook.destroyed());
    window.L = originalL;
    global.fetch = originalFetch;
    vi.restoreAllMocks();
    vi.useRealTimers();
    document.body.innerHTML = "";
  });

  function bootHook() {
    const overlay = document.getElementById("map-alignment-overlay");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const activeImg = document.getElementById("active-img");

    leafletEl.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    overlay.getBoundingClientRect = () => ({
      width: 300,
      height: 150,
      left: 0,
      top: 0,
    });
    Object.defineProperty(activeImg, "complete", {
      value: true,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalWidth", {
      value: 1000,
      configurable: true,
    });
    Object.defineProperty(activeImg, "naturalHeight", {
      value: 800,
      configurable: true,
    });

    const mapInstance = {
      on: vi.fn(),
      off: vi.fn(),
      remove: vi.fn(),
      invalidateSize: vi.fn(),
      setZoom: vi.fn(),
      getZoom: vi.fn(() => 19),
      getMinZoom: vi.fn(() => 19),
      getMaxZoom: vi.fn(() => 22),
      setView: vi.fn(),
      latLngToContainerPoint: vi.fn((pt) => ({ x: pt.lng, y: pt.lat })),
      containerPointToLatLng: vi.fn(([x, y]) => ({ lat: y, lng: x })),
      distance: vi.fn(() => 1),
      removeLayer: vi.fn(),
    };

    global.fetch = vi.fn(() => Promise.resolve({ ok: false }));
    window.L = {
      map: vi.fn(() => mapInstance),
      tileLayer: vi.fn(() => ({ addTo: vi.fn() })),
      geoJSON: vi.fn(() => ({ addTo: vi.fn() })),
    };

    const hook = {
      ...MapAlignmentHook,
      el: document.getElementById("root"),
      pushEvent: vi.fn(),
      handleEvent: vi.fn(),
    };

    hook.mounted();
    liveHooks.push(hook);

    return { hook, mapInstance };
  }

  const TOOLS_PANEL = `
    <div id="map-alignment-tools">
      <div id="tools-header">
        <button id="map-alignment-tools-toggle" type="button" data-collapsed="false" title="Hide tools" aria-label="Hide tools"></button>
      </div>
      <div id="tools-transform">
        <button id="map-transform-left-fine" data-map-transform-action="left" data-map-transform-coarse="false"></button>
        <button id="map-transform-up-fine" data-map-transform-action="up" data-map-transform-coarse="false"></button>
        <button id="map-transform-down-fine" data-map-transform-action="down" data-map-transform-coarse="false"></button>
        <button id="map-transform-right-fine" data-map-transform-action="right" data-map-transform-coarse="false"></button>
        <button id="map-transform-rotate-left-fine" data-map-transform-action="rotate-left" data-map-transform-coarse="false"></button>
        <button id="map-transform-rotate-right-fine" data-map-transform-action="rotate-right" data-map-transform-coarse="false"></button>
        <button id="map-transform-scale-down-fine" data-map-transform-action="scale-down" data-map-transform-coarse="false"></button>
        <button id="map-transform-scale-up-fine" data-map-transform-action="scale-up" data-map-transform-coarse="false"></button>
      </div>
      <button id="map-alignment-restore-saved" type="button" disabled>Restore saved alignment</button>
      <div id="tools-opacity">
        <input id="map-alignment-opacity" type="range" min="0" max="1" step="0.05" value="0.7" />
      </div>
    </div>
  `;

  // Production nesting. Everything the hook reads through `root.querySelector`
  // stays inside the canvas; every control the hook reaches by id sits outside
  // it, exactly as the server renders it.
  function mountWorkspaceHook({
    workspace = true,
    tools = true,
    residual = true,
  } = {}) {
    const canvas = `
      <div id="root" data-initial-lat="40.7128" data-initial-lon="-74.0060" data-initial-zoom="19" data-map-generation="${GENERATION}">
        <div id="map-alignment-overlay" data-editable-overlay="true"><img id="active-img" /></div>
        <div id="map-alignment-leaflet"></div>
        <button id="map-alignment-rotate-handle" data-edit-target-overlay="active"></button>
        <button id="map-alignment-scale-handle" data-edit-target-overlay="active"></button>
        <div id="map-alignment-pins-active"></div>
        <div id="map-other-overlays"></div>
        <div id="map-other-pins"></div>
      </div>
    `;

    const inner = `${canvas}${tools ? TOOLS_PANEL : ""}`;

    document.body.innerHTML = `
      ${
        workspace
          ? `<div id="map-alignment-workspace" tabindex="-1">${inner}</div>`
          : `<div id="not-the-workspace">${inner}</div>`
      }
      <div id="map-alignment-commit-bar">
        ${
          residual
            ? `<div id="map-alignment-residual" class="group" data-fit-state="ready">
                 <span id="residual-label">Measured fit</span>
                 <span id="map-alignment-residual-value">1.4 m · 3 anchors</span>
               </div>`
            : ""
        }
        <input id="map-alignment-lat-input" value="40.7128" />
        <input id="map-alignment-lon-input" value="-74.0060" />
        <button id="map-alignment-apply-center"></button>
        <input id="map-alignment-zoom" type="range" min="19" max="22" step="0.5" value="19" />
        <span id="map-alignment-zoom-value">19.0</span>
        <button id="map-alignment-save"></button>
        <button id="map-alignment-apply"></button>
      </div>
      <input id="outside-the-workspace" />
    `;

    return bootHook();
  }

  function keydown(target, key, init = {}) {
    const event = new KeyboardEvent("keydown", {
      key,
      bubbles: true,
      cancelable: true,
      ...init,
    });
    target.dispatchEvent(event);
    return event;
  }

  function keyup(target, key, init = {}) {
    const event = new KeyboardEvent("keyup", {
      key,
      bubbles: true,
      cancelable: true,
      ...init,
    });
    target.dispatchEvent(event);
    return event;
  }

  function overlayOpacity() {
    return document.getElementById("map-alignment-overlay").style.opacity;
  }

  function residualState() {
    return document
      .getElementById("map-alignment-residual")
      .getAttribute("data-fit-state");
  }

  function residualValue() {
    return document.getElementById("map-alignment-residual-value").textContent;
  }

  function invalidationPayloads(hook) {
    return hook.pushEvent.mock.calls
      .filter(([name]) => name === "alignment_transform_changed")
      .map(([, payload]) => payload);
  }

  describe("keyboard nudging", () => {
    it.each(FINE_KEYS)(
      "applies the fine step for %s",
      (key, field, expected) => {
        const { hook } = mountWorkspaceHook();
        const start = { ...hook.transform };

        keydown(document.getElementById("map-alignment-workspace"), key);

        const delta =
          field === "scale"
            ? hook.transform.scale / start.scale
            : hook.transform[field] - start[field];
        expect(delta).toBeCloseTo(expected, 10);
      },
    );

    it.each(COARSE_KEYS)(
      "applies the coarse step for Shift+%s",
      (key, field, expected) => {
        const { hook } = mountWorkspaceHook();
        const start = { ...hook.transform };

        keydown(document.getElementById("map-alignment-workspace"), key, {
          shiftKey: true,
        });

        const delta =
          field === "scale"
            ? hook.transform.scale / start.scale
            : hook.transform[field] - start[field];
        expect(delta).toBeCloseTo(expected, 10);
      },
    );

    // The binding-scope regression guard. A listener on the hook root would
    // never see this event, because the tools panel is not inside the root.
    it("nudges when the key event target is a button inside the tools panel", () => {
      const { hook } = mountWorkspaceHook();
      const toolsButton = document.getElementById("map-transform-left-fine");

      expect(document.getElementById("root").contains(toolsButton)).toBe(false);

      keydown(toolsButton, "ArrowLeft");

      expect(hook.transform.tx).toBe(-2);
    });

    it("reports the keyboard nudge as an operator gesture in the debounced payload", () => {
      const { hook } = mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toEqual([
        {
          generation: GENERATION,
          unsaved: true,
          alignment: {
            center_lat: 75,
            center_lon: 148,
            scale_mpp: 0.1875,
            rotation_deg: 0,
          },
        },
      ]);
    });

    it("calls preventDefault on a handled key", () => {
      mountWorkspaceHook();

      const event = keydown(
        document.getElementById("map-alignment-workspace"),
        "ArrowLeft",
      );

      expect(event.defaultPrevented).toBe(true);
    });

    it("leaves Tab traversal intact by not preventing an unhandled key", () => {
      const { hook } = mountWorkspaceHook();
      const start = { ...hook.transform };

      const event = keydown(
        document.getElementById("map-alignment-workspace"),
        "Tab",
      );

      expect(event.defaultPrevented).toBe(false);
      expect(hook.transform).toEqual(start);
    });

    it.each(IGNORED_TARGET_MARKUP)(
      "ignores a key raised on %s",
      (markup, id) => {
        const { hook } = mountWorkspaceHook();
        document
          .getElementById("map-alignment-workspace")
          .insertAdjacentHTML("beforeend", markup);
        const start = { ...hook.transform };

        const event = keydown(document.getElementById(id), "ArrowLeft");

        expect(hook.transform).toEqual(start);
        expect(event.defaultPrevented).toBe(false);
      },
    );

    it.each([["metaKey"], ["ctrlKey"], ["altKey"]])(
      "ignores a key held with %s",
      (modifier) => {
        const { hook } = mountWorkspaceHook();
        const start = { ...hook.transform };

        const event = keydown(
          document.getElementById("map-alignment-workspace"),
          "ArrowLeft",
          { [modifier]: true },
        );

        expect(hook.transform).toEqual(start);
        expect(event.defaultPrevented).toBe(false);
      },
    );

    // The overlay's pointerdown calls preventDefault to stop the image drag,
    // which also suppresses the browser's click-to-focus. Without an explicit
    // focus the operator's most common gesture leaves focus outside the
    // workspace and every shortcut here is dead.
    it("hands the workspace focus when the operator grabs the floorplan", () => {
      mountWorkspaceHook();
      document.getElementById("map-alignment-save").focus();

      const event = new Event("pointerdown", {
        bubbles: true,
        cancelable: true,
      });
      event.button = 0;
      event.clientX = 10;
      event.clientY = 10;
      event.pointerId = 1;
      document.getElementById("map-alignment-overlay").dispatchEvent(event);

      expect(document.activeElement).toBe(
        document.getElementById("map-alignment-workspace"),
      );
    });

    it("leaves focus alone when it is already inside the workspace", () => {
      mountWorkspaceHook();
      const button = document.getElementById("map-transform-left-fine");
      button.focus();

      const event = new Event("pointerdown", {
        bubbles: true,
        cancelable: true,
      });
      event.button = 0;
      event.clientX = 10;
      event.clientY = 10;
      event.pointerId = 1;
      document.getElementById("map-alignment-overlay").dispatchEvent(event);

      expect(document.activeElement).toBe(button);
    });

    it("stops nudging after the hook is destroyed", () => {
      const { hook } = mountWorkspaceHook();
      hook.destroyed();
      const start = { ...hook.transform };

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");

      expect(hook.transform).toEqual(start);
    });

    it("rebinds keyboard shortcuts when a patch replaces the workspace", () => {
      const { hook } = mountWorkspaceHook();
      const oldWorkspace = document.getElementById("map-alignment-workspace");
      const newWorkspace = document.createElement("div");
      newWorkspace.id = "map-alignment-workspace";
      newWorkspace.tabIndex = -1;

      keydown(oldWorkspace, "h");
      expect(overlayOpacity()).toBe("0");

      while (oldWorkspace.firstChild) {
        newWorkspace.appendChild(oldWorkspace.firstChild);
      }
      oldWorkspace.replaceWith(newWorkspace);
      hook.updated();

      expect(overlayOpacity()).toBe("0.7");
      expect(hook._holdToHideActive).toBe(false);

      keydown(oldWorkspace, "ArrowLeft");
      expect(hook.transform.tx).toBe(0);

      keydown(newWorkspace, "ArrowLeft");
      expect(hook.transform.tx).toBe(-2);
    });
  });

  describe("hold-to-hide", () => {
    it("blanks the active overlay while H is held and restores it on keyup", () => {
      mountWorkspaceHook();
      const workspace = document.getElementById("map-alignment-workspace");

      keydown(workspace, "h");
      expect(overlayOpacity()).toBe("0");

      keyup(workspace, "h");
      expect(overlayOpacity()).toBe("0.7");
    });

    it("restores to the opacity slider's current value, not the value at engage time", () => {
      mountWorkspaceHook();
      const workspace = document.getElementById("map-alignment-workspace");
      const slider = document.getElementById("map-alignment-opacity");

      keydown(workspace, "h");
      expect(overlayOpacity()).toBe("0");

      slider.value = "0.35";
      slider.dispatchEvent(new Event("input", { bubbles: true }));
      expect(overlayOpacity()).toBe("0");

      keyup(workspace, "h");

      expect(overlayOpacity()).toBe("0.35");
    });

    it("never writes the opacity slider's own value during a hold", () => {
      mountWorkspaceHook();
      const workspace = document.getElementById("map-alignment-workspace");
      const slider = document.getElementById("map-alignment-opacity");

      keydown(workspace, "h");
      expect(overlayOpacity()).toBe("0");
      expect(slider.value).toBe("0.7");

      keyup(workspace, "h");

      expect(slider.value).toBe("0.7");
    });

    it("treats key repeat as one engagement and a single keyup as the release", () => {
      const { hook } = mountWorkspaceHook();
      const workspace = document.getElementById("map-alignment-workspace");

      keydown(workspace, "h", { repeat: false });
      keydown(workspace, "h", { repeat: true });
      keydown(workspace, "h", { repeat: true });
      expect(overlayOpacity()).toBe("0");

      keyup(workspace, "h");

      expect(overlayOpacity()).toBe("0.7");
      expect(hook._holdToHideActive).toBe(false);
    });

    it("does not release on a keyup for another key", () => {
      mountWorkspaceHook();
      const workspace = document.getElementById("map-alignment-workspace");

      keydown(workspace, "h");
      keyup(workspace, "ArrowLeft");

      expect(overlayOpacity()).toBe("0");
    });

    it.each([
      ["window blur", () => window.dispatchEvent(new Event("blur"))],
      [
        "document visibilitychange",
        () => document.dispatchEvent(new Event("visibilitychange")),
      ],
      [
        "focusin outside the workspace",
        () =>
          document
            .getElementById("outside-the-workspace")
            .dispatchEvent(new Event("focusin", { bubbles: true })),
      ],
    ])(
      "restores the overlay on %s when the keyup never arrives",
      (_name, fire) => {
        mountWorkspaceHook();

        keydown(document.getElementById("map-alignment-workspace"), "h");
        expect(overlayOpacity()).toBe("0");

        fire();

        expect(overlayOpacity()).toBe("0.7");
      },
    );

    it("keeps the overlay hidden when focus moves inside the workspace", () => {
      mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "h");
      document
        .getElementById("map-transform-left-fine")
        .dispatchEvent(new Event("focusin", { bubbles: true }));

      expect(overlayOpacity()).toBe("0");
    });

    it("is idempotent across a doubled release", () => {
      const { hook } = mountWorkspaceHook();
      const workspace = document.getElementById("map-alignment-workspace");
      const slider = document.getElementById("map-alignment-opacity");

      keydown(workspace, "h");
      keyup(workspace, "h");
      slider.value = "0.2";
      keyup(workspace, "h");
      window.dispatchEvent(new Event("blur"));

      expect(overlayOpacity()).toBe("0.7");
      expect(hook._holdToHideActive).toBe(false);
    });

    it("restores the overlay when the hook is destroyed mid-hold", () => {
      const { hook } = mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "h");
      hook.destroyed();

      expect(overlayOpacity()).toBe("0.7");
    });

    it("stops watching after destroy", () => {
      const { hook } = mountWorkspaceHook();
      hook.destroyed();
      const overlay = document.getElementById("map-alignment-overlay");
      overlay.style.opacity = "0.9";

      window.dispatchEvent(new Event("blur"));
      document.dispatchEvent(new Event("visibilitychange"));
      document
        .getElementById("outside-the-workspace")
        .dispatchEvent(new Event("focusin", { bubbles: true }));

      expect(overlay.style.opacity).toBe("0.9");
    });
  });

  describe("tools panel collapse", () => {
    function controlDisabledMatrix() {
      return Array.from(
        document.querySelectorAll(
          "#map-alignment-tools button, #map-alignment-tools input",
        ),
      ).map((control) => [control.id, control.disabled]);
    }

    it("hides the panel body and reshows it without changing any control's disabled", () => {
      mountWorkspaceHook();
      const toggle = document.getElementById("map-alignment-tools-toggle");
      const body = document.getElementById("tools-transform");
      const before = controlDisabledMatrix();

      toggle.click();
      expect(body.style.display).toBe("none");
      expect(controlDisabledMatrix()).toEqual(before);

      toggle.click();
      expect(body.style.display).not.toBe("none");
      expect(controlDisabledMatrix()).toEqual(before);
    });

    it("hides every panel child except the row that holds the toggle", () => {
      mountWorkspaceHook();

      document.getElementById("map-alignment-tools-toggle").click();

      expect(document.getElementById("tools-header").style.display).not.toBe(
        "none",
      );
      expect(document.getElementById("tools-transform").style.display).toBe(
        "none",
      );
      expect(
        document.getElementById("map-alignment-restore-saved").style.display,
      ).toBe("none");
      expect(document.getElementById("tools-opacity").style.display).toBe(
        "none",
      );
    });

    it("names the action it will perform", () => {
      mountWorkspaceHook();
      const toggle = document.getElementById("map-alignment-tools-toggle");

      expect(toggle.getAttribute("title")).toBe("Hide tools");
      expect(toggle.getAttribute("data-collapsed")).toBe("false");
      toggle.click();
      expect(toggle.getAttribute("title")).toBe("Show tools");
      expect(toggle.getAttribute("aria-label")).toBe("Show tools");
      expect(toggle.getAttribute("data-collapsed")).toBe("true");
      toggle.click();
      expect(toggle.getAttribute("title")).toBe("Hide tools");
      expect(toggle.getAttribute("data-collapsed")).toBe("false");
    });

    it("settles on the same DOM for repeated toggles", () => {
      mountWorkspaceHook();
      const toggle = document.getElementById("map-alignment-tools-toggle");
      const panel = document.getElementById("map-alignment-tools");

      toggle.click();
      const collapsed = panel.innerHTML;
      toggle.click();
      const expanded = panel.innerHTML;
      toggle.click();
      toggle.click();
      toggle.click();

      expect(panel.innerHTML).toBe(collapsed);
      toggle.click();
      expect(panel.innerHTML).toBe(expanded);
    });

    it("re-applies a collapse the server patch would have undone", () => {
      const { hook } = mountWorkspaceHook();
      const body = document.getElementById("tools-transform");

      document.getElementById("map-alignment-tools-toggle").click();
      body.style.display = "";
      hook.updated();

      expect(body.style.display).toBe("none");
    });

    it("rebinds a patched toggle without losing the collapsed state", () => {
      const { hook } = mountWorkspaceHook();
      const oldToggle = document.getElementById("map-alignment-tools-toggle");
      const body = document.getElementById("tools-transform");

      oldToggle.click();
      const newToggle = oldToggle.cloneNode(true);
      oldToggle.replaceWith(newToggle);
      body.style.display = "";
      body.hidden = false;
      hook.updated();

      expect(body.style.display).toBe("none");
      expect(newToggle.getAttribute("title")).toBe("Show tools");

      oldToggle.click();
      expect(body.style.display).toBe("none");

      newToggle.click();
      expect(body.style.display).not.toBe("none");
    });

    it("expands the panel on destroy so no orphan stays hidden", () => {
      const { hook } = mountWorkspaceHook();

      document.getElementById("map-alignment-tools-toggle").click();
      hook.destroyed();

      expect(document.getElementById("tools-transform").style.display).not.toBe(
        "none",
      );
    });
  });

  describe("measuring state", () => {
    it("writes Measuring… and data-fit-state=measuring when a change is scheduled", () => {
      mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");

      expect(residualState()).toBe("measuring");
      expect(residualValue()).toBe("Measuring…");
    });

    it("writes the measuring state for a restore, not only for operator gestures", () => {
      const { hook } = mountWorkspaceHook();

      hook._handleRestoreSavedTransform({ generation: GENERATION });

      expect(residualState()).toBe("measuring");
      expect(residualValue()).toBe("Measuring…");
    });

    it("leaves the measuring state standing once the scored push is sent", () => {
      const { hook } = mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(invalidationPayloads(hook)).toHaveLength(1);
      expect(residualState()).toBe("measuring");
      expect(residualValue()).toBe("Measuring…");
    });

    // Observed on the real page: the preview-dirty push lands inside the
    // debounce window, the server re-renders the readout from the fit it scored
    // before this change, and the superseded number reappears in a confident
    // band. That is the stale-as-current defect, restored by a patch.
    it("re-asserts the measuring state when a server patch re-renders the readout", () => {
      const { hook } = mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");

      document
        .getElementById("map-alignment-residual")
        .setAttribute("data-fit-state", "ready");
      document.getElementById("map-alignment-residual-value").textContent =
        "1.4 m · 3 anchors";
      hook.updated();

      expect(residualState()).toBe("measuring");
      expect(residualValue()).toBe("Measuring…");
    });

    it("lets the answer stand once the measurement is on the wire", () => {
      const { hook } = mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");
      vi.advanceTimersByTime(DEBOUNCE_MS);

      document
        .getElementById("map-alignment-residual")
        .setAttribute("data-fit-state", "ready");
      document.getElementById("map-alignment-residual-value").textContent =
        "0.9 m · 3 anchors";
      hook.updated();

      expect(residualState()).toBe("ready");
      expect(residualValue()).toBe("0.9 m · 3 anchors");
    });

    // Re-scoring to an unchanged verdict produces no diff, so no patch ever
    // arrives to replace "Measuring…" — a level stuck below three anchors would
    // read "Measuring…" forever.
    it("gives up the measuring state when the answer produces no patch at all", () => {
      const { hook } = mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");
      vi.advanceTimersByTime(DEBOUNCE_MS);
      expect(residualValue()).toBe("Measuring…");

      vi.advanceTimersByTime(2000);

      expect(residualState()).toBe("ready");
      expect(residualValue()).toBe("1.4 m · 3 anchors");
      expect(invalidationPayloads(hook)).toHaveLength(1);
    });

    it("leaves a resolved answer alone when the grace watchdog fires", () => {
      mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");
      vi.advanceTimersByTime(DEBOUNCE_MS);

      document
        .getElementById("map-alignment-residual")
        .setAttribute("data-fit-state", "ready");
      document.getElementById("map-alignment-residual-value").textContent =
        "0.9 m · 3 anchors";
      vi.advanceTimersByTime(2000);

      expect(residualState()).toBe("ready");
      expect(residualValue()).toBe("0.9 m · 3 anchors");
    });

    // Nothing will ever resolve these windows, so leaving "Measuring…" up would
    // be a permanently wrong readout — the failure CRIT-005 exists to prevent.
    it("puts the last reading back when the payload carries no alignment to score", () => {
      mountWorkspaceHook();
      Object.defineProperty(document.getElementById("active-img"), "complete", {
        value: false,
        configurable: true,
      });

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");
      vi.advanceTimersByTime(DEBOUNCE_MS);

      expect(residualState()).toBe("ready");
      expect(residualValue()).toBe("1.4 m · 3 anchors");
    });

    it("puts the last reading back when a coordinate review consumes the window", () => {
      mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");
      expect(residualState()).toBe("measuring");

      document
        .getElementById("map-alignment-apply")
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));

      expect(residualState()).toBe("ready");
      expect(residualValue()).toBe("1.4 m · 3 anchors");
    });

    it("puts the last reading back when the hook is destroyed mid-window", () => {
      const { hook } = mountWorkspaceHook();

      keydown(document.getElementById("map-alignment-workspace"), "ArrowLeft");
      hook.destroyed();

      expect(residualState()).toBe("ready");
      expect(residualValue()).toBe("1.4 m · 3 anchors");
    });

    it("restores the pre-measuring reading, not an earlier measuring write, across a coalesced burst", () => {
      mountWorkspaceHook();
      const workspace = document.getElementById("map-alignment-workspace");

      keydown(workspace, "ArrowLeft");
      keydown(workspace, "ArrowLeft");
      keydown(workspace, "ArrowLeft");
      document
        .getElementById("map-alignment-apply")
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));

      expect(residualValue()).toBe("1.4 m · 3 anchors");
      expect(residualState()).toBe("ready");
    });
  });

  describe("partial DOM tolerance", () => {
    it("mounts and nudges without a residual readout", () => {
      const { hook } = mountWorkspaceHook({ residual: false });

      expect(() =>
        keydown(
          document.getElementById("map-alignment-workspace"),
          "ArrowLeft",
        ),
      ).not.toThrow();
      expect(hook.transform.tx).toBe(-2);
      expect(() => vi.advanceTimersByTime(DEBOUNCE_MS)).not.toThrow();
    });

    it("mounts and tears down without a tools panel", () => {
      const { hook } = mountWorkspaceHook({ tools: false });

      expect(() =>
        keydown(
          document.getElementById("map-alignment-workspace"),
          "ArrowLeft",
        ),
      ).not.toThrow();
      expect(hook.transform.tx).toBe(-2);
      expect(() => hook.destroyed()).not.toThrow();
    });

    it("mounts and tears down without a workspace element", () => {
      const { hook } = mountWorkspaceHook({ workspace: false });

      expect(hook._holdToHideActive).toBe(false);
      expect(() => hook._adjustTransform("left", false)).not.toThrow();
      expect(hook.transform.tx).toBe(-2);
      expect(() => hook.destroyed()).not.toThrow();
    });

    it("does not install hold-to-hide watchdogs without a workspace element", () => {
      const windowAddEventListener = vi.spyOn(window, "addEventListener");
      const documentAddEventListener = vi.spyOn(document, "addEventListener");

      mountWorkspaceHook({ workspace: false });

      expect(windowAddEventListener).not.toHaveBeenCalledWith(
        "blur",
        expect.any(Function),
      );
      expect(documentAddEventListener).not.toHaveBeenCalledWith(
        "visibilitychange",
        expect.any(Function),
      );
      expect(documentAddEventListener).not.toHaveBeenCalledWith(
        "focusin",
        expect.any(Function),
      );
    });
  });
});
