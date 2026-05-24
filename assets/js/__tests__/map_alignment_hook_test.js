/* @vitest-environment jsdom */
import { describe, expect, it, vi } from "vitest";
import MapAlignmentHook, {
  parseAlignmentPayload,
  readActiveAlignment,
  readReferenceAlignment,
  symbolForLocationType,
  activeColorForLocationType,
  normalizeLevelIndex,
  referenceColorForLevel,
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

  it("normalizes level index to finite number or null", () => {
    expect(normalizeLevelIndex(2)).toBe(2);
    expect(normalizeLevelIndex("3")).toBe(3);
    expect(normalizeLevelIndex("3.5")).toBe(3.5);
    expect(normalizeLevelIndex("")).toBeNull();
    expect(normalizeLevelIndex("bad")).toBeNull();
    expect(normalizeLevelIndex(null)).toBeNull();
  });

  it("maps reference color by normalized level index deterministically", () => {
    expect(referenceColorForLevel(0, "L0")).toEqual({
      fill: "#E0F2FE",
      stroke: "#0369A1",
    });

    expect(referenceColorForLevel("1", "L1")).toEqual({
      fill: "#DCFCE7",
      stroke: "#166534",
    });

    expect(referenceColorForLevel(-1, "L-1")).toEqual({
      fill: "#DCFCE7",
      stroke: "#166534",
    });
  });

  it("uses levelId hash fallback when level index is invalid or missing", () => {
    const byIdA1 = referenceColorForLevel(null, "level-a");
    const byIdA2 = referenceColorForLevel(undefined, "level-a");
    const byIdB = referenceColorForLevel("bad", "level-b");

    expect(byIdA1).toEqual(byIdA2);
    expect(byIdA1).toMatchObject({ fill: expect.any(String), stroke: expect.any(String) });
    expect(byIdB).toMatchObject({ fill: expect.any(String), stroke: expect.any(String) });
  });

  it("returns neutral fallback when both index and levelId are missing", () => {
    expect(referenceColorForLevel(null, null)).toEqual({
      fill: "#F8FAFC",
      stroke: "#475569",
    });
    expect(referenceColorForLevel("", "")).toEqual({
      fill: "#F8FAFC",
      stroke: "#475569",
    });
  });
});

describe("map_alignment_hook reference restore", () => {
  it("cancels stale pending reference restore before applying identity", () => {
    vi.useFakeTimers();
    document.body.innerHTML = `
      <div id="root">
        <div id="map-alignment-leaflet"></div>
        <div id="map-reference-overlay"><img id="reference-img" /></div>
      </div>
    `;

    const root = document.getElementById("root");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const referenceOverlay = document.getElementById("map-reference-overlay");
    const referenceImg = document.getElementById("reference-img");

    root.dataset.referenceFloorplanUrl = "/uploads/reference-a.png";
    root.dataset.referenceCenterLat = "40.7131";
    root.dataset.referenceCenterLon = "-74.0058";
    root.dataset.referenceScaleMpp = "0.3";
    root.dataset.referenceRotationDeg = "-5";

    leafletEl.getBoundingClientRect = () => ({ width: 200, height: 100 });
    Object.defineProperty(referenceImg, "complete", { value: true, configurable: true });
    Object.defineProperty(referenceImg, "naturalWidth", { value: 200, configurable: true });
    Object.defineProperty(referenceImg, "naturalHeight", { value: 100, configurable: true });

    const hook = {
      ...MapAlignmentHook,
      el: root,
      leafletEl,
      referenceOverlay,
      _overlayRestoreDisposers: [],
      _pendingReferenceRestoreDispose: null,
      _restoreOverlayAlignment: vi.fn(),
      _applyOverlayTransform: MapAlignmentHook._applyOverlayTransform,
      _leafletRect: MapAlignmentHook._leafletRect,
      leafletMap: {
        containerPointToLatLng: ([x, y]) => ({ lat: y, lng: x }),
        latLngToContainerPoint: ([lat, lon]) => ({ x: lon, y: lat }),
        distance: () => 1,
      },
    };

    hook._syncReferenceOverlayFromDataset();

    root.dataset.referenceFloorplanUrl = "";
    delete root.dataset.referenceCenterLat;
    delete root.dataset.referenceCenterLon;
    delete root.dataset.referenceScaleMpp;
    delete root.dataset.referenceRotationDeg;

    hook._syncReferenceOverlayFromDataset();
    vi.advanceTimersByTime(300);

    expect(hook._restoreOverlayAlignment).not.toHaveBeenCalled();
    expect(referenceOverlay.style.transform).toBe("none");

    vi.useRealTimers();
  });

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

describe("map_alignment_hook zoom slider reference alignment", () => {
  it("re-aligns reference overlay on zoom slider input when reference alignment is valid", () => {
    document.body.innerHTML = `
      <div id="root">
        <div id="map-alignment-leaflet"></div>
        <div id="map-alignment-overlay" data-editable-overlay="true"><img id="active-img" /></div>
        <div id="map-reference-overlay" data-editable-overlay="false" data-overlay-visible="true"><img id="reference-img" /></div>
      </div>
    `;

    const root = document.getElementById("root");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const overlay = document.getElementById("map-alignment-overlay");
    const referenceOverlay = document.getElementById("map-reference-overlay");
    const referenceImg = document.getElementById("reference-img");

    root.dataset.referenceCenterLat = "40.7131";
    root.dataset.referenceCenterLon = "-74.0058";
    root.dataset.referenceScaleMpp = "0.3";
    root.dataset.referenceRotationDeg = "-5";

    leafletEl.getBoundingClientRect = () => ({ width: 200, height: 100 });

    Object.defineProperty(referenceImg, "naturalWidth", { value: 200, configurable: true });
    Object.defineProperty(referenceImg, "naturalHeight", { value: 100, configurable: true });

    const hook = {
      ...MapAlignmentHook,
      el: root,
      leafletEl,
      overlay,
      referenceOverlay,
      transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
      _applyTransform: vi.fn(),
      _restoreOverlayAlignment: vi.fn(),
      leafletMap: {
        getZoom: () => 10,
        setZoom: vi.fn(),
        containerPointToLatLng: ([x, y]) => ({ lat: y, lng: x }),
        latLngToContainerPoint: ({ lat, lng }) => ({ x: lng, y: lat }),
        distance: () => 1,
      },
    };

    hook._onZoomSliderInput = (e) => {
      const target = parseFloat(e.target.value);
      if (!Number.isFinite(target)) return;
      const current = hook.leafletMap.getZoom();
      if (target === current) return;

      const canvasRect = hook._leafletRect();
      if (!canvasRect) return;
      const canvasW = canvasRect.width;
      const canvasH = canvasRect.height;
      const oldCx = canvasW / 2 + hook.transform.tx;
      const oldCy = canvasH / 2 + hook.transform.ty;
      const worldCenter = hook.leafletMap.containerPointToLatLng([oldCx, oldCy]);
      const scaleFactor = Math.pow(2, target - current);

      hook.leafletMap.setZoom(target, {animate: false});

      const newCenterPt = hook.leafletMap.latLngToContainerPoint(worldCenter);
      hook.transform.tx = newCenterPt.x - canvasW / 2;
      hook.transform.ty = newCenterPt.y - canvasH / 2;
      hook.transform.scale = hook.transform.scale * scaleFactor;
      hook._applyTransform();
      hook._restoreReferenceOverlayForCurrentView();
    };

    hook._onZoomSliderInput({ target: { value: "11" } });

    expect(hook._restoreOverlayAlignment).toHaveBeenCalledTimes(1);
    expect(hook._restoreOverlayAlignment).toHaveBeenCalledWith(
      hook.referenceOverlay,
      { centerLat: 40.7131, centerLon: -74.0058, scaleMpp: 0.3, rotationDeg: -5 },
      referenceImg,
      "reference",
    );
  });

  it("does not re-align reference overlay on zoom slider input when reference alignment is invalid", () => {
    document.body.innerHTML = `
      <div id="root">
        <div id="map-alignment-leaflet"></div>
        <div id="map-alignment-overlay" data-editable-overlay="true"><img id="active-img" /></div>
        <div id="map-reference-overlay" data-editable-overlay="false" data-overlay-visible="true"><img id="reference-img" /></div>
      </div>
    `;

    const root = document.getElementById("root");
    const leafletEl = document.getElementById("map-alignment-leaflet");
    const overlay = document.getElementById("map-alignment-overlay");
    const referenceOverlay = document.getElementById("map-reference-overlay");
    const referenceImg = document.getElementById("reference-img");

    root.dataset.referenceCenterLat = "bad";
    root.dataset.referenceCenterLon = "-74.0058";
    root.dataset.referenceScaleMpp = "0.3";
    root.dataset.referenceRotationDeg = "-5";

    leafletEl.getBoundingClientRect = () => ({ width: 200, height: 100 });

    Object.defineProperty(referenceImg, "naturalWidth", { value: 200, configurable: true });
    Object.defineProperty(referenceImg, "naturalHeight", { value: 100, configurable: true });

    const hook = {
      ...MapAlignmentHook,
      el: root,
      leafletEl,
      overlay,
      referenceOverlay,
      transform: { tx: 0, ty: 0, rotation: 0, scale: 1 },
      _applyTransform: vi.fn(),
      _restoreOverlayAlignment: vi.fn(),
      leafletMap: {
        getZoom: () => 10,
        setZoom: vi.fn(),
        containerPointToLatLng: ([x, y]) => ({ lat: y, lng: x }),
        latLngToContainerPoint: ({ lat, lng }) => ({ x: lng, y: lat }),
        distance: () => 1,
      },
    };

    hook._onZoomSliderInput = (e) => {
      const target = parseFloat(e.target.value);
      if (!Number.isFinite(target)) return;
      const current = hook.leafletMap.getZoom();
      if (target === current) return;

      const canvasRect = hook._leafletRect();
      if (!canvasRect) return;
      const canvasW = canvasRect.width;
      const canvasH = canvasRect.height;
      const oldCx = canvasW / 2 + hook.transform.tx;
      const oldCy = canvasH / 2 + hook.transform.ty;
      const worldCenter = hook.leafletMap.containerPointToLatLng([oldCx, oldCy]);
      const scaleFactor = Math.pow(2, target - current);

      hook.leafletMap.setZoom(target, {animate: false});

      const newCenterPt = hook.leafletMap.latLngToContainerPoint(worldCenter);
      hook.transform.tx = newCenterPt.x - canvasW / 2;
      hook.transform.ty = newCenterPt.y - canvasH / 2;
      hook.transform.scale = hook.transform.scale * scaleFactor;
      hook._applyTransform();
      hook._restoreReferenceOverlayForCurrentView();
    };

    hook._onZoomSliderInput({ target: { value: "11" } });

    expect(hook._restoreOverlayAlignment).not.toHaveBeenCalled();
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

describe("map_alignment_hook reference child stops rendering", () => {
  it("ignores stale reference child-stop payload for non-reference level", () => {
    document.body.innerHTML = `
      <div id="root" data-reference-level-id="reference-level">
        <div id="map-alignment-pins-reference"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const referencePinsRoot = document.getElementById("map-alignment-pins-reference");

    const hook = {
      ...MapAlignmentHook,
      el: root,
      _referencePinsRoot: referencePinsRoot,
      _referenceChildStops: [],
      _positionPins: vi.fn(),
    };

    hook._renderReferenceChildStops({
      level_id: "other-reference-level",
      stops: [{ stop_id: "s1", lat: 40.7, lon: -74.0 }],
    });

    expect(hook._referenceChildStops).toEqual([]);
    expect(referencePinsRoot.children.length).toBe(0);
    expect(hook._positionPins).not.toHaveBeenCalled();
  });

  it("normalizes numeric-string lat lon and filters invalid coordinates", () => {
    document.body.innerHTML = `
      <div id="root" data-reference-level-id="reference-level">
        <div id="map-alignment-pins-reference"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const referencePinsRoot = document.getElementById("map-alignment-pins-reference");

    const hook = {
      ...MapAlignmentHook,
      el: root,
      _referencePinsRoot: referencePinsRoot,
      _referenceChildStops: [],
      _positionPins: vi.fn(),
    };

    hook._renderReferenceChildStops({
      level_id: "reference-level",
      stops: [
        { stop_id: "valid-string", lat: "40.7001", lon: "-74.0021" },
        { stop_id: "invalid-lat", lat: "bad", lon: "-74.0" },
        { stop_id: "invalid-lon", lat: 40.71, lon: undefined },
      ],
    });

    expect(hook._referenceChildStops.length).toBe(1);
    expect(hook._referenceChildStops[0]).toMatchObject({
      stop_id: "valid-string",
      lat: 40.7001,
      lon: -74.0021,
    });
    expect(referencePinsRoot.children.length).toBe(1);
    const tooltip = referencePinsRoot.children[0].lastChild;
    expect(tooltip.textContent).toBe("R: valid-string");
    expect(hook._positionPins).toHaveBeenCalledTimes(1);
  });

  it("applies role-differentiated reference styling with symbol grammar and subdued type-themed colors", () => {
    document.body.innerHTML = `
      <div id="root" data-reference-level-id="reference-level">
        <div id="map-alignment-pins-reference"></div>
      </div>
    `;

    const root = document.getElementById("root");
    const referencePinsRoot = document.getElementById("map-alignment-pins-reference");

    const hook = {
      ...MapAlignmentHook,
      el: root,
      _referencePinsRoot: referencePinsRoot,
      _referenceChildStops: [],
      _positionPins: vi.fn(),
    };

    hook._renderReferenceChildStops({
      level_id: "reference-level",
      level_index: 1,
      stops: [
        { stop_id: "u", stop_name: "Upright", location_type: 2, lat: 40.7001, lon: -74.0021 },
      ],
    });

    const pin = referencePinsRoot.children[0];
    const dot = pin.firstChild;
    const tooltip = pin.lastChild;
    const typeStrokeHex = activeColorForLocationType(2).stroke;
    const typeFillHex = activeColorForLocationType(2).fill;

    const normalizeCssColor = (cssColor) => {
      const sample = document.createElement("div");
      sample.style.color = cssColor;
      return sample.style.color;
    };

    expect(pin.className).toContain("pointer-events-none");
    expect(pin.style.width).toBe("8px");
    expect(pin.style.height).toBe("12px");

    expect(dot.style.backgroundColor).toBe(normalizeCssColor(typeFillHex));
    expect(dot.style.borderColor).toBe(normalizeCssColor(typeStrokeHex));
    expect(dot.style.borderStyle).toBe("dashed");
    expect(dot.style.borderWidth).toBe("1.5px");
    expect(dot.style.opacity).toBe("0.3");
    expect(dot.style.borderRadius).toBe("2px");
    expect(tooltip.textContent).toBe("R: Upright");
  });
});
