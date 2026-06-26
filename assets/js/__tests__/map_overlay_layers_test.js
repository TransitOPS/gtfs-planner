/* @vitest-environment jsdom */
import { describe, expect, it, vi } from "vitest";
import { createOtherLevelsLayers } from "../map_overlay_layers";

// The active editable overlay (#map-alignment-overlay) renders at z-index 2.
// Other-level overlays must sit strictly below it (AC-16).
const ACTIVE_OVERLAY_Z_INDEX = 2;

function makeDeps(overrides = {}) {
  return {
    overlaysRoot: document.createElement("div"),
    pinsRoot: document.createElement("div"),
    applyOverlayTransform: vi.fn(),
    projectLatLng: vi.fn(() => ({ x: 10, y: 20 })),
    symbolFor: vi.fn(() => "circle"),
    ...overrides,
  };
}

function floorplan(url) {
  return {
    url,
    center_lat: 40.7,
    center_lon: -74.0,
    scale_mpp: 0.25,
    rotation_deg: 0,
  };
}

function stop(stopId, lat, lon, label, overrides = {}) {
  return { stop_id: stopId, lat, lon, location_type: 1, label, ...overrides };
}

function level({ levelId, index, color, fp, stops = [] }) {
  return {
    level_id: levelId,
    level_index: index,
    color,
    floorplan: fp,
    stops,
  };
}

describe("createOtherLevelsLayers overlay reconciliation (AC-14)", () => {
  it("creates one overlay img per floorplan level and applies each alignment", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);
    const fpA = floorplan("/a.png");
    const fpB = floorplan("/b.png");

    layers.update({
      active_level_id: "active",
      levels: [
        level({ levelId: "a", index: 1, color: "#ff0000", fp: fpA }),
        level({ levelId: "b", index: 2, color: "#00ff00", fp: fpB }),
      ],
    });

    const imgs = deps.overlaysRoot.querySelectorAll("img");
    expect(imgs.length).toBe(2);
    expect(deps.applyOverlayTransform).toHaveBeenCalledTimes(2);
    expect(deps.applyOverlayTransform).toHaveBeenCalledWith(imgs[0], fpA);
    expect(deps.applyOverlayTransform).toHaveBeenCalledWith(imgs[1], fpB);
  });

  it("re-applies a floorplan transform when the image load completes", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);
    const fpA = floorplan("/a.png");

    layers.update({
      active_level_id: "active",
      levels: [level({ levelId: "a", index: 1, color: "#ff0000", fp: fpA })],
    });

    const img = deps.overlaysRoot.querySelector("img");
    deps.applyOverlayTransform.mockClear();

    img.dispatchEvent(new Event("load"));

    expect(deps.applyOverlayTransform).toHaveBeenCalledTimes(1);
    expect(deps.applyOverlayTransform).toHaveBeenCalledWith(img, fpA);
  });

  it("removes only the omitted level's overlay on a follow-up update", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({ levelId: "a", index: 1, color: "#f00", fp: floorplan("/a.png") }),
        level({ levelId: "b", index: 2, color: "#0f0", fp: floorplan("/b.png") }),
      ],
    });

    layers.update({
      levels: [level({ levelId: "a", index: 1, color: "#f00", fp: floorplan("/a.png") })],
    });

    const overlays = deps.overlaysRoot.querySelectorAll("[data-other-level-id]");
    expect(overlays.length).toBe(1);
    expect(overlays[0].dataset.otherLevelId).toBe("a");
  });

  it("removes the overlay when a level's floorplan becomes null", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({ levelId: "a", index: 1, color: "#f00", fp: floorplan("/a.png") }),
        level({ levelId: "b", index: 2, color: "#0f0", fp: floorplan("/b.png") }),
      ],
    });

    layers.update({
      levels: [
        level({ levelId: "a", index: 1, color: "#f00", fp: null }),
        level({ levelId: "b", index: 2, color: "#0f0", fp: floorplan("/b.png") }),
      ],
    });

    const overlays = deps.overlaysRoot.querySelectorAll("[data-other-level-id]");
    expect(overlays.length).toBe(1);
    expect(overlays[0].dataset.otherLevelId).toBe("b");
  });
});

describe("createOtherLevelsLayers pin rendering (AC-15)", () => {
  it("renders one pin group per level with markers colored by the level color", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({
          levelId: "a",
          index: 1,
          color: "#ff0000",
          fp: null,
          stops: [stop("s1", 40.7, -74.0, "Stop 1")],
        }),
        level({
          levelId: "b",
          index: 2,
          color: "#00ff00",
          fp: null,
          stops: [stop("s2", 40.8, -74.1, "Stop 2"), stop("s3", 40.9, -74.2, "Stop 3")],
        }),
      ],
    });

    const groups = deps.pinsRoot.querySelectorAll("[data-other-level-id]");
    expect(groups.length).toBe(2);

    const groupA = deps.pinsRoot.querySelector('[data-other-level-id="a"]');
    const groupB = deps.pinsRoot.querySelector('[data-other-level-id="b"]');
    expect(groupA.querySelectorAll(".map-pin").length).toBe(1);
    expect(groupB.querySelectorAll(".map-pin").length).toBe(2);

    const dotA = groupA.querySelector(".map-pin > div");
    expect(dotA.style.borderColor).toBe("rgb(255, 0, 0)");
    const dotB = groupB.querySelector(".map-pin > div");
    expect(dotB.style.borderColor).toBe("rgb(0, 255, 0)");
  });

  it("falls back to stop name, id, and platform when no explicit label is present", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({
          levelId: "a",
          index: 1,
          color: "#ff0000",
          fp: null,
          stops: [
            stop("s1", 40.7, -74.0, undefined, {
              stop_name: "Mezzanine North",
              platform_code: "2",
            }),
          ],
        }),
      ],
    });

    const tooltip = deps.pinsRoot.querySelector(".map-pin > div:last-child");
    expect(tooltip.textContent).toBe("Mezzanine North · Plat 2");
  });

  it("updates marker positions on reposition when projection changes", () => {
    const deps = makeDeps({
      projectLatLng: vi.fn(() => ({ x: 10, y: 20 })),
    });
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({
          levelId: "a",
          index: 1,
          color: "#f00",
          fp: null,
          stops: [stop("s1", 40.7, -74.0, "Stop 1")],
        }),
      ],
    });

    const marker = deps.pinsRoot.querySelector(".map-pin");
    expect(marker.style.left).toBe("10px");
    expect(marker.style.top).toBe("20px");

    deps.projectLatLng.mockReturnValue({ x: 99, y: 77 });
    layers.reposition();

    expect(marker.style.left).toBe("99px");
    expect(marker.style.top).toBe("77px");
  });

  it("removes the pin group when a level's stops become empty", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({
          levelId: "a",
          index: 1,
          color: "#f00",
          fp: null,
          stops: [stop("s1", 40.7, -74.0, "Stop 1")],
        }),
      ],
    });
    expect(deps.pinsRoot.querySelectorAll("[data-other-level-id]").length).toBe(1);

    layers.update({
      levels: [level({ levelId: "a", index: 1, color: "#f00", fp: null, stops: [] })],
    });
    expect(deps.pinsRoot.querySelectorAll("[data-other-level-id]").length).toBe(0);
  });
});

describe("createOtherLevelsLayers stacking and pointer behavior (AC-16)", () => {
  it("renders overlay containers with pointer-events none and z-index below the active overlay", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [level({ levelId: "a", index: 1, color: "#f00", fp: floorplan("/a.png") })],
    });

    const overlay = deps.overlaysRoot.querySelector("[data-other-level-id]");
    expect(overlay.style.pointerEvents).toBe("none");
    expect(overlay.style.zIndex).toBe("1");
    expect(Number(overlay.style.zIndex)).toBeLessThan(ACTIVE_OVERLAY_Z_INDEX);
  });
});

describe("createOtherLevelsLayers opacity and teardown", () => {
  it("sets opacity on every overlay img via setOpacity", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({ levelId: "a", index: 1, color: "#f00", fp: floorplan("/a.png") }),
        level({ levelId: "b", index: 2, color: "#0f0", fp: floorplan("/b.png") }),
      ],
    });

    layers.setOpacity(0.4);

    const imgs = deps.overlaysRoot.querySelectorAll("img");
    expect(imgs[0].style.opacity).toBe("0.4");
    expect(imgs[1].style.opacity).toBe("0.4");
  });

  it("removes all nodes on destroy and continues to work on the cleared state", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({
          levelId: "a",
          index: 1,
          color: "#f00",
          fp: floorplan("/a.png"),
          stops: [stop("s1", 40.7, -74.0, "Stop 1")],
        }),
      ],
    });

    layers.destroy();

    expect(deps.overlaysRoot.children.length).toBe(0);
    expect(deps.pinsRoot.children.length).toBe(0);

    // Cleared internal state: reposition is a no-op, update rebuilds cleanly.
    expect(() => layers.reposition()).not.toThrow();
    layers.update({
      levels: [level({ levelId: "b", index: 2, color: "#0f0", fp: floorplan("/b.png") })],
    });
    expect(deps.overlaysRoot.querySelectorAll("img").length).toBe(1);
  });
});

describe("createOtherLevelsLayers dependency validation", () => {
  it("throws when a required dependency is missing", () => {
    expect(() => createOtherLevelsLayers({ ...makeDeps(), overlaysRoot: undefined })).toThrow(
      /overlaysRoot is required/,
    );
    expect(() => createOtherLevelsLayers({ ...makeDeps(), projectLatLng: undefined })).toThrow(
      /projectLatLng must be a function/,
    );
  });
});
