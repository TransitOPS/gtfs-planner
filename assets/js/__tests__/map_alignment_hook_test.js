/* @vitest-environment jsdom */
import { describe, expect, it, vi } from "vitest";
import MapAlignmentHook, {
  parseAlignmentPayload,
  readActiveAlignment,
  readReferenceAlignment,
} from "../map_alignment_hook";

describe("map_alignment_hook alignment parsing", () => {
  it("parses active and reference payloads independently", () => {
    const root = {
      dataset: {
        alignCenterLat: "40.7128",
        alignCenterLon: "-74.0060",
        alignScaleMpp: "0.25",
        alignRotationDeg: "15",
        referenceCenterLat: "40.7131",
        referenceCenterLon: "-74.0058",
        referenceScaleMpp: "0.3",
        referenceRotationDeg: "-5",
      },
    };

    expect(readActiveAlignment(root)).toEqual({
      centerLat: 40.7128,
      centerLon: -74.006,
      scaleMpp: 0.25,
      rotationDeg: 15,
    });

    expect(readReferenceAlignment(root)).toEqual({
      centerLat: 40.7131,
      centerLon: -74.0058,
      scaleMpp: 0.3,
      rotationDeg: -5,
    });
  });

  it("returns null for invalid reference payload parts", () => {
    const root = {
      dataset: {
        referenceCenterLat: "bad",
        referenceCenterLon: "-74.0062",
        referenceScaleMpp: "0.31",
        referenceRotationDeg: "12",
      },
    };

    expect(readReferenceAlignment(root)).toBeNull();
  });

  it("returns null when reference payload is incomplete", () => {
    const root = {
      dataset: {
        referenceCenterLat: "40.7131",
        referenceCenterLon: "-74.0058",
        referenceScaleMpp: "0.3",
      },
    };

    expect(readReferenceAlignment(root)).toBeNull();
  });

  it("reads reference alignment only from reference dataset keys", () => {
    const root = {
      dataset: {
        alignCenterLat: "10",
        alignCenterLon: "20",
        alignScaleMpp: "0.5",
        alignRotationDeg: "45",
        referenceCenterLat: "40.7131",
        referenceCenterLon: "-74.0058",
        referenceScaleMpp: "0.3",
        referenceRotationDeg: "-5",
      },
    };

    expect(readReferenceAlignment(root)).toEqual({
      centerLat: 40.7131,
      centerLon: -74.0058,
      scaleMpp: 0.3,
      rotationDeg: -5,
    });
  });

  it("returns null for invalid payload parts", () => {
    expect(parseAlignmentPayload("40", "-74", "0", "0")).toBeNull();
    expect(parseAlignmentPayload("x", "-74", "0.2", "0")).toBeNull();
  });
});

describe("map_alignment_hook reference restore", () => {
  it("restores reference overlay transform without mutating active transform state", () => {
    document.body.innerHTML = `
      <div id="root">
        <div id="map-alignment-leaflet"></div>
        <div id="active-overlay"><img id="active-img" /></div>
        <div id="map-reference-overlay"><img id="reference-img" /></div>
      </div>
    `;

    const root = document.getElementById("root");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const activeOverlay = document.getElementById("active-overlay");
    const referenceOverlay = document.getElementById("map-reference-overlay");
    const referenceImg = document.getElementById("reference-img");

    root.getBoundingClientRect = () => ({ width: 200, height: 100 });
    leafletEl.getBoundingClientRect = () => ({ width: 200, height: 100 });

    Object.defineProperty(referenceImg, "naturalWidth", { value: 200, configurable: true });
    Object.defineProperty(referenceImg, "naturalHeight", { value: 100, configurable: true });

    const hook = {
      ...MapAlignmentHook,
      el: root,
      leafletEl,
      overlay: activeOverlay,
      transform: { tx: 9, ty: 8, rotation: 7, scale: 1.2 },
      _applyTransform: vi.fn(),
      leafletMap: {
        containerPointToLatLng: ([x, y]) => ({ x, y }),
        latLngToContainerPoint: ([lat, lon]) => ({ x: lon, y: lat }),
        distance: () => 2,
      },
    };

    hook._restoreOverlayAlignment(
      referenceOverlay,
      { centerLat: 40.7, centerLon: -74, scaleMpp: 0.5, rotationDeg: 33 },
      referenceImg,
      "reference",
    );

    expect(referenceOverlay.style.transform).toContain("rotate(33deg)");
    expect(referenceOverlay.style.transform).toContain("scale(");
    expect(referenceOverlay.style.transform).toContain("translate(-174px, -9.3px)");
    expect(hook.transform).toEqual({ tx: 9, ty: 8, rotation: 7, scale: 1.2 });
    expect(hook._applyTransform).not.toHaveBeenCalled();
  });

  it("applies identity transform for reference overlay when alignment is missing", () => {
    document.body.innerHTML = `<div id="map-reference-overlay"></div>`;
    const referenceOverlay = document.getElementById("map-reference-overlay");

    const hook = {
      ...MapAlignmentHook,
    };

    hook._applyOverlayTransform(referenceOverlay, { tx: 0, ty: 0, rotation: 0, scale: 1 });

    expect(referenceOverlay.style.transform).toBe("none");
  });

  it("applies identity transform for reference overlay when alignment payload is invalid", () => {
    document.body.innerHTML = `<div id="root"><div id="map-reference-overlay"></div></div>`;
    const root = document.getElementById("root");
    const referenceOverlay = document.getElementById("map-reference-overlay");

    root.dataset.referenceCenterLat = "bad";
    root.dataset.referenceCenterLon = "-74.0058";
    root.dataset.referenceScaleMpp = "0.3";
    root.dataset.referenceRotationDeg = "-5";

    const hook = {
      ...MapAlignmentHook,
      el: root,
      referenceOverlay,
    };

    const referenceAlignment = readReferenceAlignment(root);
    expect(referenceAlignment).toBeNull();

    hook._applyOverlayTransform(referenceOverlay, { tx: 0, ty: 0, rotation: 0, scale: 1 });
    expect(referenceOverlay.style.transform).toBe("none");
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

describe("map_alignment_hook reference overlay visibility sync", () => {
  it("shows and hides single reference overlay from dataset flag", () => {
    document.body.innerHTML = `<div id="root"><div id="map-reference-overlay" class="hidden"></div></div>`;

    const root = document.getElementById("root");
    const referenceOverlay = document.getElementById("map-reference-overlay");

    const hook = {
      ...MapAlignmentHook,
      el: root,
      referenceOverlay,
    };

    root.dataset.showReferenceOverlay = "true";
    hook._syncReferenceOverlayVisibilityFromDataset();

    expect(referenceOverlay.dataset.overlayVisible).toBe("true");
    expect(referenceOverlay.classList.contains("hidden")).toBe(false);

    root.dataset.showReferenceOverlay = "false";
    hook._syncReferenceOverlayVisibilityFromDataset();

    expect(referenceOverlay.dataset.overlayVisible).toBe("false");
    expect(referenceOverlay.classList.contains("hidden")).toBe(true);
  });

  it("reuses existing server-rendered reference image without creating duplicates", () => {
    document.body.innerHTML = `
      <div id="root">
        <div id="map-reference-overlay">
          <img id="server-reference" src="/uploads/old.png" class="absolute inset-0" />
        </div>
      </div>
    `;

    const root = document.getElementById("root");
    const referenceOverlay = document.getElementById("map-reference-overlay");
    const serverReference = document.getElementById("server-reference");

    root.dataset.referenceFloorplanUrl = "/uploads/new.png";
    root.dataset.referenceCenterLat = "40.7131";
    root.dataset.referenceCenterLon = "-74.0058";
    root.dataset.referenceScaleMpp = "0.3";
    root.dataset.referenceRotationDeg = "-5";

    const hook = {
      ...MapAlignmentHook,
      el: root,
      referenceOverlay,
      _scheduleOverlayAlignmentRestore: vi.fn(),
      _applyOverlayTransform: vi.fn(),
    };

    hook._syncReferenceOverlayFromDataset();

    const imgs = referenceOverlay.querySelectorAll("img");
    expect(imgs.length).toBe(1);
    expect(imgs[0]).toBe(serverReference);
    expect(imgs[0].dataset.referenceOverlay).toBe("true");
    expect(imgs[0].getAttribute("src")).toBe("/uploads/new.png");
  });

  it("collapses duplicate reference images down to a single image", () => {
    document.body.innerHTML = `
      <div id="root">
        <div id="map-reference-overlay">
          <img data-reference-overlay="true" src="/uploads/first.png" />
          <img data-reference-overlay="true" src="/uploads/second.png" />
          <img src="/uploads/third.png" />
        </div>
      </div>
    `;

    const root = document.getElementById("root");
    const referenceOverlay = document.getElementById("map-reference-overlay");

    root.dataset.referenceFloorplanUrl = "/uploads/final.png";

    const hook = {
      ...MapAlignmentHook,
      el: root,
      referenceOverlay,
      _scheduleOverlayAlignmentRestore: vi.fn(),
      _applyOverlayTransform: vi.fn(),
    };

    hook._syncReferenceOverlayFromDataset();

    const imgs = referenceOverlay.querySelectorAll("img");
    expect(imgs.length).toBe(1);
    expect(imgs[0].dataset.referenceOverlay).toBe("true");
    expect(imgs[0].getAttribute("src")).toBe("/uploads/final.png");
  });
});
