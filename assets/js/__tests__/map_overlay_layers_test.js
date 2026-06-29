/* @vitest-environment jsdom */
import { describe, expect, it, vi } from "vitest";
import { createOtherLevelsLayers } from "../map_overlay_layers";
import { symbolForLocationType, treatmentForLocationType } from "../stop_icon_symbols";

// The active editable overlay (#map-alignment-overlay) renders at z-index 2.
// Other-level overlays must sit strictly below it (AC-16).
const ACTIVE_OVERLAY_Z_INDEX = 2;

function cssColor(value) {
  const el = document.createElement("div");
  el.style.color = value;
  return el.style.color;
}

function expectMarkerTreatment(pin, locationType, color) {
  const treatment = treatmentForLocationType(locationType, color);
  const dot = pin.firstChild;

  expect(pin.style.width).toBe(treatment.width);
  expect(pin.style.height).toBe(treatment.height);
  expect(dot.style.backgroundColor).toBe(cssColor(treatment.fill));
  expect(dot.style.borderColor).toBe(cssColor(treatment.stroke));
  expect(dot.style.borderRadius).toBe(treatment.borderRadius);
}

function makeDeps(overrides = {}) {
  return {
    overlaysRoot: document.createElement("div"),
    pinsRoot: document.createElement("div"),
    applyOverlayTransform: vi.fn(),
    projectLatLng: vi.fn(() => ({ x: 10, y: 20 })),
    symbolFor: symbolForLocationType,
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
  it("renders one pin group per level with markers in the unified level color and a dashed border", () => {
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

    const pinA = groupA.querySelector(".map-pin");
    expectMarkerTreatment(pinA, 1, "#ff0000");
    expect(pinA.firstChild.style.borderStyle).toBe("dashed");
    const pinB = groupB.querySelector(".map-pin");
    expectMarkerTreatment(pinB, 1, "#00ff00");
    expect(pinB.firstChild.style.borderStyle).toBe("dashed");
  });

  it("renders Entrance/Exit markers in the unified level color with no white outline", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({
          levelId: "a",
          index: 1,
          color: "#336699",
          fp: null,
          stops: [stop("entrance", 40.7, -74.0, "Entrance", { location_type: 2 })],
        }),
      ],
    });

    const pin = deps.pinsRoot.querySelector(".map-pin");
    expectMarkerTreatment(pin, 2, "#336699");
    const dot = pin.firstChild;
    // Fill and border are the same level color — no white-fill outline treatment.
    expect(dot.style.backgroundColor).toBe(cssColor("#336699"));
    expect(dot.style.borderColor).toBe(cssColor("#336699"));
    expect(dot.style.borderStyle).toBe("dashed");
  });

  it("renders unknown location types as circle markers", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({
          levelId: "a",
          index: 1,
          color: "#ff0000",
          fp: null,
          stops: [stop("unknown", 40.7, -74.0, "Unknown", { location_type: "unknown" })],
        }),
      ],
    });

    const pin = deps.pinsRoot.querySelector(".map-pin");
    expectMarkerTreatment(pin, "unknown", "#ff0000");
    expect(symbolForLocationType("unknown")).toBe("circle");
  });

  it("applies one uniform dot opacity to every marker regardless of location type", () => {
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
            stop("entrance", 40.7, -74.0, "Entrance", { location_type: 2 }),
            stop("platform", 40.8, -74.1, "Platform", { location_type: 0 }),
          ],
        }),
      ],
    });

    layers.setOpacity(0);

    const dots = deps.pinsRoot.querySelectorAll(".map-pin > div:first-child");
    expect(dots[0].style.opacity).toBe(dots[1].style.opacity);
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
    expect(tooltip.classList.contains("group-hover:opacity-100")).toBe(true);
  });

  it("renders the hover tooltip on both entrance and non-entrance markers", () => {
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
            stop("entrance", 40.7, -74.0, "Entrance", { location_type: 2 }),
            stop("platform", 40.8, -74.1, "Platform", { location_type: 0 }),
          ],
        }),
      ],
    });

    const pins = deps.pinsRoot.querySelectorAll(".map-pin");
    expect(pins.length).toBe(2);

    pins.forEach((pin) => {
      const tooltip = pin.lastElementChild;
      expect(tooltip.classList.contains("group-hover:opacity-100")).toBe(true);
    });
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

  it("renders a cross-level badge per pathway next to the stop marker", () => {
    const deps = makeDeps();
    const layers = createOtherLevelsLayers(deps);

    layers.update({
      levels: [
        level({
          levelId: "a",
          index: 1,
          color: "#f00",
          fp: null,
          stops: [
            stop("s1", 40.7, -74.0, "Stop 1", {
              badges: [{ pathway_mode: 2 }, { pathway_mode: 5 }],
            }),
          ],
        }),
      ],
    });

    const pin = deps.pinsRoot.querySelector(".map-pin");
    const badges = pin.querySelectorAll("svg.map-stop-badge");
    expect(badges).toHaveLength(2);
    expect(badges[0].dataset.badgeSymbol).toBe("stairs");
    expect(badges[1].dataset.badgeSymbol).toBe("elevator");
  });

  it("renders no badge for a stop without cross-level pathways", () => {
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

    const pin = deps.pinsRoot.querySelector(".map-pin");
    expect(pin.querySelectorAll("svg.map-stop-badge")).toHaveLength(0);
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

describe("createOtherLevelsLayers recompute isolation (AC-17)", () => {
  // The other-level renderer is read-only: overlay transforms and pin positions
  // change ONLY through an explicit update/reposition/setOpacity call, never as a
  // side effect. This guards the active floorplan transform from leaking into
  // other-level overlays through any implicit recompute.
  it("does not recompute overlay transform or pin position until reposition is called", () => {
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
          fp: floorplan("/a.png"),
          stops: [stop("s1", 40.7, -74.0, "Stop 1")],
        }),
      ],
    });

    const marker = deps.pinsRoot.querySelector(".map-pin");
    expect(marker.style.left).toBe("10px");
    expect(marker.style.top).toBe("20px");

    // Change what the injected math would produce. Absent an explicit
    // reposition/update, the rendered position must not move.
    deps.applyOverlayTransform.mockClear();
    deps.projectLatLng.mockClear();
    deps.projectLatLng.mockReturnValue({ x: 999, y: 999 });

    expect(marker.style.left).toBe("10px");
    expect(marker.style.top).toBe("20px");
    expect(deps.applyOverlayTransform).not.toHaveBeenCalled();
    expect(deps.projectLatLng).not.toHaveBeenCalled();

    // The new projection only takes effect on an explicit reposition.
    layers.reposition();
    expect(marker.style.left).toBe("999px");
    expect(marker.style.top).toBe("999px");
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
