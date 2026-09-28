/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import PatternAlignment, {
  BLOCKED_DASH,
  MISSING_COLOR,
  MISSING_DASH,
} from "../pattern_alignment_hook";

// jsdom ships no canvas implementation, but the hook creates its Leaflet map
// with preferCanvas (per the step 23 contract). Install an absorbing 2d
// context so the real Canvas renderer can run under jsdom; vector geometry
// assertions below read Leaflet's own latlngs/options, never pixels.
function stubCanvasContext() {
  const handler = {
    get: (_target, prop) => {
      if (prop === "canvas") return document.createElement("canvas");
      if (prop === "measureText") return () => ({ width: 0 });
      if (prop === "getImageData") return () => ({ data: [] });
      return (..._args) => undefined;
    },
    set: () => true,
  };
  HTMLCanvasElement.prototype.getContext = function () {
    return new Proxy({}, handler);
  };
}

stubCanvasContext();

// Four visits where Alpha recurs at positions 1 and 4; sections cover every
// drawn kind: shared, override, missing and blocked.
function model() {
  return {
    route_color: "#334155",
    editable: true,
    visits: [
      { position: 1, stop_id: "A", name: "Alpha", lat: 40.0, lon: -74.0, label: "1" },
      { position: 2, stop_id: "B", name: "Bravo", lat: 40.01, lon: -74.0, label: "2" },
      { position: 3, stop_id: "C", name: "Charlie", lat: 40.02, lon: -74.0, label: "3" },
      { position: 4, stop_id: "A", name: "Alpha", lat: 40.0, lon: -74.0, label: "1 / 4" },
      { position: 5, stop_id: "D", name: "Delta", lat: 40.03, lon: -74.01, label: "5" },
    ],
    sections: [
      { position: 1, kind: "shared", points: [[-74.0, 40.005]] },
      { position: 2, kind: "override", points: [] },
      { position: 3, kind: "missing", points: [] },
      { position: 4, kind: "blocked", points: [] },
    ],
  };
}

function mount() {
  document.body.innerHTML = `
    <div id="alignment-map-root" data-tile-url="/map/tiles/osm-bright/{z}/{x}/{y}">
      <p id="alignment-map-loading" role="status">Loading map…</p>
    </div>
  `;
  const root = document.getElementById("alignment-map-root");
  root.getBoundingClientRect = () => ({
    width: 800,
    height: 600,
    top: 0,
    left: 0,
    right: 800,
    bottom: 600,
  });

  const pushed = [];
  const handlers = {};
  const hook = Object.create(PatternAlignment);
  hook.el = root;
  hook.pushEvent = (event, payload) => pushed.push({ event, payload });
  hook.handleEvent = (event, callback) => {
    handlers[event] = callback;
  };
  hook.mounted();
  return { hook, root, pushed, handlers };
}

// Tear down every mounted map so pending renderer frames never leak into
// the next test's document. Leaflet's Canvas renderer can hold a scheduled
// redraw whose slot was already consumed by a synchronous redraw (its
// draw-then-fitBounds flow); in a real browser that frame fires while the
// map is alive, but these tests mount and destroy within one frame, so let
// the pending frame fire first and only then destroy the map.
const liveHooks = [];
afterEach(async () => {
  await new Promise((resolve) => setTimeout(resolve, 50));
  while (liveHooks.length) liveHooks.pop().destroyed();
  document.body.innerHTML = "";
});

function mountTracked() {
  const ctx = mount();
  liveHooks.push(ctx.hook);
  return ctx;
}

function load(handlers, fixture = model()) {
  // Mirror the server push shape `%{model: ...}` exactly.
  handlers["alignment:load"]({ model: fixture });
  return fixture;
}

describe("pattern_alignment_hook chrome", () => {
  it("builds the map bar, tools, hint and legend, then asks for the model", () => {
    const { root, pushed } = mountTracked();

    expect(document.getElementById("alignment-map-loading")).toBeNull();
    expect(root.querySelector("[data-pa-pan]")).not.toBeNull();
    expect(root.querySelector("[data-pa-edit]").disabled).toBe(true);
    expect(root.querySelector("[data-pa-zoom-in]").getAttribute("aria-label")).toBe(
      "Zoom in",
    );
    expect(root.querySelector("[data-pa-fit]").getAttribute("aria-label")).toBe(
      "Fit entire pattern",
    );
    expect(root.querySelector("[data-pa-legend-route]")).not.toBeNull();
    expect(root.querySelector("[data-pa-toggle-labels]").textContent).toBe(
      "Hide stop labels",
    );

    // The Leaflet stage exists with canvas rendering and no zoom control.
    expect(root.querySelector(".leaflet-container")).not.toBeNull();
    expect(root.querySelector(".leaflet-control-zoom")).toBeNull();

    expect(pushed).toEqual([{ event: "alignment_hook_ready", payload: {} }]);
  });

  it("creates the map with the prepared interaction options", () => {
    const { hook } = mountTracked();

    expect(hook._map.options.preferCanvas).toBe(true);
    expect(hook._map.options.zoomControl).toBe(false);
    expect(hook._map.options.scrollWheelZoom).toBe(true);
    expect(hook._map.options.dragging).toBe(true);
    expect(hook._map.options.keyboard).toBe(false);
  });
});

describe("pattern_alignment_hook drawing", () => {
  let ctx;
  beforeEach(() => {
    ctx = mountTracked();
    load(ctx.handlers);
  });

  it("draws one polyline per section with the style of its kind", () => {
    const { hook } = ctx;

    expect(hook._sectionLayers.size).toBe(4);

    // Saved kinds use the model route colour verbatim at weight 4, except
    // the default-selected first section, which renders wider with a halo.
    const first = hook._sectionLayers.get(1);
    expect(first.line.options.color).toBe("#334155");
    expect(first.line.options.weight).toBe(6);
    expect(first.halo).not.toBeNull();

    const { line } = hook._sectionLayers.get(2);
    expect(line.options.color).toBe("#334155");
    expect(line.options.weight).toBe(4);
    // Leaflet's Path default; the missing/blocked lines override it below.
    expect(line.options.dashArray).toBeNull();

    // The missing section is a red dashed line.
    const missing = hook._sectionLayers.get(3).line;
    expect(missing.options.color).toBe(MISSING_COLOR);
    expect(missing.options.dashArray).toBe(MISSING_DASH);

    // The blocked section is dotted.
    expect(hook._sectionLayers.get(4).line.options.dashArray).toBe(BLOCKED_DASH);
  });

  it("draws the missing connector straight between its two stop anchors", () => {
    const { hook } = ctx;
    const latlngs = hook._sectionLayers.get(3).line.getLatLngs();

    expect(latlngs).toHaveLength(2);
    expect([latlngs[0].lat, latlngs[0].lng]).toEqual([40.02, -74.0]);
    expect([latlngs[1].lat, latlngs[1].lng]).toEqual([40.0, -74.0]);
  });

  it("keeps [lon, lat] interiors in Leaflet order on the saved line", () => {
    const { hook } = ctx;
    const latlngs = hook._sectionLayers.get(1).line.getLatLngs();

    // Anchor A, the [lon, lat] interior, anchor B.
    expect(latlngs).toHaveLength(3);
    expect([latlngs[1].lat, latlngs[1].lng]).toEqual([40.005, -74.0]);
  });

  it("marks a repeated stop once with its joined visit label", () => {
    const { root } = ctx;
    const pins = [...root.querySelectorAll(".pa-stop-pin")];

    // Four unique stop locations for five visits.
    expect(pins).toHaveLength(4);
    expect(pins.map((pin) => pin.textContent).sort()).toEqual([
      "1 / 4",
      "2",
      "3",
      "5",
    ]);
  });

  it("escapes an imported stop name into marker html, never as markup", () => {
    const evil = '<img src=x onerror="alert(1)">';
    const fixture = model();
    fixture.visits = [
      { position: 1, stop_id: "X", name: evil, lat: 40.0, lon: -74.0, label: "1" },
    ];
    const evilCtx = mountTracked();
    load(evilCtx.handlers, fixture);

    const html = evilCtx.hook._stopMarkers.map(
      (marker) => marker.options.icon.options.html,
    );
    expect(html).toHaveLength(1);
    expect(html[0]).not.toContain("<img");
    expect(html[0]).toContain("&lt;img");
    // The pin label still renders; only the name is encoded.
    expect(html[0]).toContain('class="pa-stop-pin"');
  });

  it("toggles the stop name labels without touching the pins", () => {
    const { root } = ctx;
    const toggle = root.querySelector("[data-pa-toggle-labels]");

    toggle.click();
    expect(root.classList.contains("pa-hide-labels")).toBe(true);
    expect(toggle.textContent).toBe("Show stop labels");
    expect(toggle.getAttribute("aria-pressed")).toBe("true");
    expect(root.querySelectorAll(".pa-stop-pin")).toHaveLength(4);

    toggle.click();
    expect(root.classList.contains("pa-hide-labels")).toBe(false);
    expect(toggle.textContent).toBe("Hide stop labels");
  });
});

describe("pattern_alignment_hook selection", () => {
  it("pushes the section position when its polyline is clicked", () => {
    const ctx = mountTracked();
    load(ctx.handlers);

    ctx.hook._sectionLayers.get(2).line.fire("click");

    expect(ctx.pushed).toContainEqual({
      event: "alignment_select_section",
      payload: { position: 2 },
    });
  });

  it("widens the selected polyline with a halo and fits its bounds", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    const before = ctx.hook._map.getBounds();

    ctx.handlers["alignment:select"]({ position: 3 });

    const { line, halo } = ctx.hook._sectionLayers.get(3);
    expect(line.options.weight).toBe(6);
    expect(halo).not.toBeNull();
    expect(halo.options.interactive).toBe(false);
    // The unselected saved line keeps its base weight and has no halo.
    expect(ctx.hook._sectionLayers.get(1).line.options.weight).toBe(4);
    expect(ctx.hook._sectionLayers.get(1).halo).toBeNull();
    // Fitting the single section moves the view away from the full pattern.
    expect(ctx.hook._map.getBounds().equals(before)).toBe(false);
  });
});

describe("pattern_alignment_hook tile failures", () => {
  it("reports the first tileerror once and recovers on the next tileload", () => {
    const ctx = mountTracked();

    ctx.hook._tileLayer.fire("tileerror", { tile: {}, url: "a" });
    ctx.hook._tileLayer.fire("tileerror", { tile: {}, url: "b" });
    const errors = ctx.pushed.filter((p) => p.event === "alignment_map_error");
    expect(errors).toEqual([{ event: "alignment_map_error", payload: {} }]);

    ctx.hook._tileLayer.fire("tileload", { tile: {}, coords: {} });
    expect(ctx.pushed).toContainEqual({
      event: "alignment_map_ok",
      payload: {},
    });
  });

  it("retries by rebuilding the tile layer so a new episode reports again", () => {
    const ctx = mountTracked();
    const first = ctx.hook._tileLayer;

    ctx.hook._tileLayer.fire("tileerror", { tile: {}, url: "a" });
    ctx.handlers["alignment:retry_tiles"]({});

    expect(ctx.hook._tileLayer).not.toBe(first);
    ctx.hook._tileLayer.fire("tileerror", { tile: {}, url: "c" });
    const errors = ctx.pushed.filter((p) => p.event === "alignment_map_error");
    expect(errors).toHaveLength(2);
  });
});

describe("pattern_alignment_hook teardown", () => {
  it("removes the map and its listeners", async () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    expect(ctx.root.querySelector(".leaflet-container")).not.toBeNull();

    // Let the draw's scheduled frame fire while the map is alive, as a
    // real session destroys the map long after drawing it.
    await new Promise((resolve) => setTimeout(resolve, 50));
    ctx.hook.destroyed();

    expect(ctx.root.querySelector(".leaflet-container")).toBeNull();
    expect(ctx.hook._map).toBeNull();
  });
});

describe("pattern_alignment_hook save settle", () => {
  // The Save control lives outside the hook root (server-rendered task
  // header); the hook toggles its disabled flag client-side around the
  // in-flight save guard (step 28).
  function saveButton() {
    let save = document.getElementById("alignment-save");
    if (!save) {
      save = document.createElement("button");
      save.id = "alignment-save";
      document.body.appendChild(save);
    }
    return save;
  }

  it("disables Save when a fresh load carries no drafts", () => {
    const { hook, handlers } = mountTracked();
    const save = saveButton();
    save.disabled = false;

    load(handlers);

    expect(hook.dirtyPositions()).toEqual([]);
    expect(save.disabled).toBe(true);
  });

  it("keeps Save enabled when a load embeds bulk suggestions", () => {
    const { hook, handlers } = mountTracked();
    const save = saveButton();
    save.disabled = true;

    const fixture = model();
    fixture.route_pattern_id = "BROWSER-ALIGN-GEN-2";
    fixture.suggestions = [{ position: 3, points: [[-74.0, 40.015]] }];
    load(handlers, fixture);

    expect(hook.dirtyPositions()).toEqual([3]);
    expect(save.disabled).toBe(false);
  });

  it("re-enables Save after a rebase settles an unchanged draft", () => {
    const { hook, handlers } = mountTracked();
    const save = saveButton();
    load(handlers);
    hook._commit(1, [[-74.0, 40.006]]);
    save.disabled = true;

    handlers["alignment:rebase"]({ bases: {} });

    expect(hook.dirtyPositions()).toEqual([1]);
    expect(save.disabled).toBe(false);
  });
});
