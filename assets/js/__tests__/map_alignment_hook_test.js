/* @vitest-environment jsdom */
import { describe, expect, it, vi } from "vitest";
import MapAlignmentHook, {
  parseAlignmentPayload,
  readActiveAlignment,
} from "../map_alignment_hook";
import { previewPointForDiagramCoordinate } from "../floorplan_preview_points";
import {
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

function expectPinTreatment(pin, locationType) {
  const treatment = treatmentForLocationType(locationType, DIAGRAM_BASE_COLOR);
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

  it("renders active child stops with diagram colors, halo, and shared geometry", () => {
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
        { stop_id: "boarding-area", lat: 40.7, lon: -74.0, location_type: 0 },
        { stop_id: "boarding-point", lat: 40.705, lon: -74.005, location_type: 4 },
        { stop_id: "entrance", lat: 40.71, lon: -74.01, location_type: 2 },
        { stop_id: "generic-node", lat: 40.72, lon: -74.02, location_type: "bad" },
      ],
    });

    // Every active marker renders in the unified base color (fill === border),
    // with shape — not color — encoding the location type.
    const boardingPin = activePinsRoot.children[0];
    const boardingDot = boardingPin.firstChild;
    expectPinTreatment(boardingPin, 0);
    expect(symbolForLocationType(0)).toBe("rect_upright");
    expect(boardingDot.style.backgroundColor).toBe(cssColor(DIAGRAM_BASE_COLOR));
    expect(boardingDot.style.borderColor).toBe(cssBorderColor(DIAGRAM_BASE_COLOR));

    const boardingPointPin = activePinsRoot.children[1];
    const boardingPointDot = boardingPointPin.firstChild;
    expectPinTreatment(boardingPointPin, 4);
    expect(symbolForLocationType(4)).toBe("rect_square");
    expect(boardingPointDot.style.backgroundColor).toBe(cssColor(DIAGRAM_BASE_COLOR));
    expect(boardingPointDot.style.borderColor).toBe(cssBorderColor(DIAGRAM_BASE_COLOR));
    expect(boardingPointPin.style.width).not.toBe(boardingPin.style.width);
    expect(boardingPointPin.style.height).not.toBe(boardingPin.style.height);

    // Entrance/Exit (2) gets no white-fill outline — same solid color as the rest.
    const entrancePin = activePinsRoot.children[2];
    const entranceDot = entrancePin.firstChild;
    expectPinTreatment(entrancePin, 2);
    expect(symbolForLocationType(2)).toBe("rect_upright");
    expect(entranceDot.style.backgroundColor).toBe(cssColor(DIAGRAM_BASE_COLOR));
    expect(entranceDot.style.borderColor).toBe(cssBorderColor(DIAGRAM_BASE_COLOR));

    const genericPin = activePinsRoot.children[3];
    const genericDot = genericPin.firstChild;
    expectPinTreatment(genericPin, "bad");
    expect(symbolForLocationType("bad")).toBe("circle");
    expect(genericDot.style.backgroundColor).toBe(cssColor(DIAGRAM_BASE_COLOR));
    expect(genericDot.style.borderColor).toBe(cssBorderColor(DIAGRAM_BASE_COLOR));
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
