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
        <div id="active-overlay"><img id="active-img" /></div>
        <div id="adj-overlay"><img id="adj-img" /></div>
      </div>
    `;

    const root = document.getElementById("root");
    const activeOverlay = document.getElementById("active-overlay");
    const adjacentOverlay = document.getElementById("adj-overlay");
    const adjacentImg = document.getElementById("adj-img");

    root.getBoundingClientRect = () => ({ width: 200, height: 100 });

    Object.defineProperty(adjacentImg, "naturalWidth", { value: 200, configurable: true });
    Object.defineProperty(adjacentImg, "naturalHeight", { value: 100, configurable: true });

    const hook = {
      ...MapAlignmentHook,
      el: root,
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
