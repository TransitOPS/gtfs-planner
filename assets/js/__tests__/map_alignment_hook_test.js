/* @vitest-environment jsdom */
import { describe, expect, it, vi } from "vitest";
import MapAlignmentHook, {
  parseAlignmentPayload,
  readActiveAlignment,
  readAdjacentAlignment,
} from "../map_alignment_hook";

describe("map_alignment_hook alignment parsing", () => {
  it("parses active and adjacent payloads independently", () => {
    const root = {
      dataset: {
        alignCenterLat: "40.7128",
        alignCenterLon: "-74.0060",
        alignScaleMpp: "0.25",
        alignRotationDeg: "15",
        adjacentAboveCenterLat: "40.7131",
        adjacentAboveCenterLon: "-74.0058",
        adjacentAboveScaleMpp: "0.3",
        adjacentAboveRotationDeg: "-5",
        adjacentBelowCenterLat: "bad",
        adjacentBelowCenterLon: "-74.0062",
        adjacentBelowScaleMpp: "0.31",
        adjacentBelowRotationDeg: "12",
      },
    };

    expect(readActiveAlignment(root)).toEqual({
      centerLat: 40.7128,
      centerLon: -74.006,
      scaleMpp: 0.25,
      rotationDeg: 15,
    });

    expect(readAdjacentAlignment(root, "above")).toEqual({
      centerLat: 40.7131,
      centerLon: -74.0058,
      scaleMpp: 0.3,
      rotationDeg: -5,
    });

    expect(readAdjacentAlignment(root, "below")).toBeNull();
  });

  it("returns null for invalid payload parts", () => {
    expect(parseAlignmentPayload("40", "-74", "0", "0")).toBeNull();
    expect(parseAlignmentPayload("x", "-74", "0.2", "0")).toBeNull();
  });
});

describe("map_alignment_hook adjacent restore", () => {
  it("restores adjacent overlay transform without mutating active transform state", () => {
    document.body.innerHTML = `
      <div id="root">
        <div id="map-alignment-leaflet"></div>
        <div id="active-overlay"><img id="active-img" /></div>
        <div id="adj-overlay"><img id="adj-img" /></div>
      </div>
    `;

    const root = document.getElementById("root");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const activeOverlay = document.getElementById("active-overlay");
    const adjacentOverlay = document.getElementById("adj-overlay");
    const adjacentImg = document.getElementById("adj-img");

    root.getBoundingClientRect = () => ({ width: 200, height: 100 });
    leafletEl.getBoundingClientRect = () => ({ width: 200, height: 100 });

    Object.defineProperty(adjacentImg, "naturalWidth", { value: 200, configurable: true });
    Object.defineProperty(adjacentImg, "naturalHeight", { value: 100, configurable: true });

    const hook = {
      ...MapAlignmentHook,
      el: root,
      leafletEl,
      overlay: activeOverlay,
      transform: { tx: 9, ty: 8, rotation: 7, scale: 1.2 },
      _applyTransform: vi.fn(),
      leafletMap: {
        containerPointToLatLng: ([x, y]) => ({ x, y }),
        distance: () => 2,
      },
    };

    hook._restoreOverlayAlignment(
      adjacentOverlay,
      { centerLat: 40.7, centerLon: -74, scaleMpp: 0.5, rotationDeg: 33 },
      adjacentImg,
      "adjacent-above",
    );

    expect(adjacentOverlay.style.transform).toContain("rotate(33deg)");
    expect(adjacentOverlay.style.transform).toContain("scale(");
    expect(hook.transform).toEqual({ tx: 9, ty: 8, rotation: 7, scale: 1.2 });
    expect(hook._applyTransform).not.toHaveBeenCalled();
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

describe("map_alignment_hook adjacent overlay zoom sync", () => {
  it("keeps adjacent overlays map-anchored and scales them with zoom", () => {
    document.body.innerHTML = `
      <div id="adj-above" data-side="above"></div>
      <div id="adj-below" data-side="below"></div>
    `;

    const adjacentOverlayAbove = document.getElementById("adj-above");
    const adjacentOverlayBelow = document.getElementById("adj-below");

    const hook = {
      ...MapAlignmentHook,
      adjacentOverlayAbove,
      adjacentOverlayBelow,
      _adjacentTransforms: {
        above: { tx: 10, ty: 20, rotation: 15, scale: 1.5 },
        below: { tx: -5, ty: 8, rotation: -10, scale: 0.8 },
      },
      leafletMap: {
        latLngToContainerPoint: vi.fn((latLng) => {
          if (latLng.id === "above") return { x: 160, y: 80 };
          if (latLng.id === "below") return { x: 40, y: 120 };
          return { x: 100, y: 100 };
        }),
      },
    };

    hook._syncAdjacentOverlaysForZoom(
      {
        above: { id: "above" },
        below: { id: "below" },
      },
      200,
      100,
      2,
    );

    expect(hook._adjacentTransforms.above.tx).toBe(60);
    expect(hook._adjacentTransforms.above.ty).toBe(30);
    expect(hook._adjacentTransforms.above.scale).toBe(3);
    expect(adjacentOverlayAbove.style.transform).toContain("translate(60px, 30px)");
    expect(adjacentOverlayAbove.style.transform).toContain("scale(3)");

    expect(hook._adjacentTransforms.below.tx).toBe(-60);
    expect(hook._adjacentTransforms.below.ty).toBe(70);
    expect(hook._adjacentTransforms.below.scale).toBeCloseTo(1.6, 6);
    expect(adjacentOverlayBelow.style.transform).toContain("translate(-60px, 70px)");
    expect(adjacentOverlayBelow.style.transform).toContain("scale(1.6)");
  });
});
