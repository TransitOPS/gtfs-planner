/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { afterEach, describe, expect, it } from "vitest";
import PatternAlignment from "../pattern_alignment_hook";

// Canvas stub, model shape and mount discipline mirror
// pattern_alignment_editing_test.js (step 24): the hook builds its Leaflet
// map with preferCanvas, so jsdom needs an absorbing 2d context and a 50 ms
// settle before destroy.
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

const L = window.L;

// Section 1 is saved with three interior points; section 2 is a saved
// straight connector (empty interior); section 3 is missing. Anchors are
// [lon, lat] on the wire (INV-1).
function model() {
  return {
    route_color: "#334155",
    editable: true,
    visits: [
      { position: 1, stop_id: "A", name: "Alpha", lat: 40.0, lon: -74.0, label: "1" },
      { position: 2, stop_id: "B", name: "Bravo", lat: 40.02, lon: -74.0, label: "2" },
      { position: 3, stop_id: "C", name: "Charlie", lat: 40.04, lon: -74.0, label: "3" },
      { position: 4, stop_id: "D", name: "Delta", lat: 40.06, lon: -74.0, label: "4" },
    ],
    sections: [
      {
        position: 1,
        kind: "shared",
        points: [
          [-74.0, 40.005],
          [-74.001, 40.01],
          [-74.0, 40.015],
        ],
        revision: { segment_id: "seg-1", lock_version: 3 },
      },
      { position: 2, kind: "override", points: [], revision: null },
      { position: 3, kind: "missing", points: [] },
    ],
  };
}

function mount() {
  document.body.innerHTML = `
    <div id="alignment-map-root" data-tile-url="/map/tiles/osm-bright/{z}/{x}/{y}">
      <p id="alignment-map-loading" role="status">Loading map…</p>
    </div>
    <div id="alignment-detail">
      <button id="alignment-point-list-toggle" aria-expanded="false" aria-controls="alignment-point-list">Point list</button>
      <div id="alignment-point-list"></div>
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
  handlers["alignment:load"]({ model: fixture });
  return fixture;
}

function list() {
  return document.getElementById("alignment-point-list");
}

function togglePoints(ctx) {
  ctx.root.dispatchEvent(
    new CustomEvent("alignment:action", {
      detail: { action: "toggle_points" },
      bubbles: true,
    }),
  );
}

function openList(ctx) {
  load(ctx.handlers);
  togglePoints(ctx);
  return ctx.hook;
}

function draftStates(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_draft_state");
}

function handleElement(hook, index) {
  return hook._handles[index].getElement();
}

function keydownOn(element, key, options = {}) {
  element.dispatchEvent(
    new KeyboardEvent("keydown", { key, bubbles: true, ...options }),
  );
}

describe("pattern_alignment_point_list rows", () => {
  it("toggles three labelled rows with a checkbox and a Locate each", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    // Opening from Pan enters Edit points on the editable selected section.
    expect(hook._mode).toBe("edit");
    expect(hook._pointsOpen).toBe(true);
    expect(
      document
        .getElementById("alignment-point-list-toggle")
        .getAttribute("aria-expanded"),
    ).toBe("true");

    const rows = list().querySelectorAll(".pa-point-row");
    expect(rows).toHaveLength(3);
    expect(list().textContent).toContain(
      "Arrow keys move a focused map point. End stops are fixed.",
    );
    rows.forEach((row, index) => {
      expect(row.querySelector(`[data-point-check="${index}"]`)).not.toBeNull();
      expect(row.querySelector(`[data-focus-point="${index}"]`)).not.toBeNull();
      expect(row.textContent).toContain(`Point ${index + 1}`);
    });

    togglePoints(ctx);
    expect(hook._pointsOpen).toBe(false);
    expect(list().querySelectorAll(".pa-point-row")).toHaveLength(0);
    expect(
      document
        .getElementById("alignment-point-list-toggle")
        .getAttribute("aria-expanded"),
    ).toBe("false");
  });

  it("re-renders the list when another section is selected", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);
    expect(list().querySelectorAll(".pa-point-row")).toHaveLength(3);

    ctx.handlers["alignment:select"]({ position: 2 });
    expect(hook._selected).toBe(2);
    // Section 2 has no interior points: the empty-state copy shows and the
    // previous section's rows are gone.
    expect(list().querySelectorAll(".pa-point-row")).toHaveLength(0);
    expect(list().textContent).toContain("No interior points yet.");

    ctx.handlers["alignment:select"]({ position: 1 });
    expect(list().querySelectorAll(".pa-point-row")).toHaveLength(3);
  });
});

describe("pattern_alignment_point_list locate and arrows", () => {
  it("Locate focuses the handle and ArrowRight moves 2 px east, 10 px with Shift", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    list().querySelector('[data-focus-point="1"]').click();
    expect(document.activeElement).toBe(handleElement(hook, 1));

    const before = hook._map.latLngToContainerPoint(
      hook._handles[1].getLatLng(),
    );
    keydownOn(handleElement(hook, 1), "ArrowRight");
    const after = hook._map.latLngToContainerPoint(
      hook._handles[1].getLatLng(),
    );
    // Exactly 2 px east in container space at the current zoom.
    expect(after.x - before.x).toBeCloseTo(2, 9);
    expect(after.y - before.y).toBeCloseTo(0, 9);

    // One undoable commit that marks the section dirty.
    expect(hook._undo).toHaveLength(1);
    const states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.dirty_positions).toEqual([1]);
    // The commit rebuilds the handles; the keyboard stays on the moved point.
    expect(document.activeElement).toBe(handleElement(hook, 1));

    // Shift scales the step fivefold.
    const reshifted = hook._map.latLngToContainerPoint(
      hook._handles[1].getLatLng(),
    );
    keydownOn(handleElement(hook, 1), "ArrowRight", { shiftKey: true });
    const shifted = hook._map.latLngToContainerPoint(
      hook._handles[1].getLatLng(),
    );
    expect(shifted.x - reshifted.x).toBeCloseTo(10, 9);
    expect(shifted.y - reshifted.y).toBeCloseTo(0, 9);
    expect(hook._undo).toHaveLength(2);
  });
});

describe("pattern_alignment_point_list selection sync", () => {
  it("checks select the handle and Space on the handle follows the checkbox", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    const box = list().querySelector('[data-point-check="1"]');
    // A keyboard toggle focuses the checkbox first; the change rebuild
    // must hand focus back to it.
    box.focus();
    box.checked = true;
    box.dispatchEvent(new Event("change", { bubbles: true }));
    expect(hook._selectedPoints).toEqual(new Set([1]));
    expect(
      handleElement(hook, 1).querySelector(
        ".alignment-handle-dot.is-selected",
      ),
    ).not.toBeNull();
    expect(list().querySelector("[data-delete-points]").textContent).toContain(
      "Delete points (1)",
    );
    // Focus survives the list re-render on the equivalent rebuilt checkbox.
    expect(document.activeElement).toBe(
      list().querySelector('[data-point-check="1"]'),
    );
    expect(document.activeElement).not.toBe(box);

    handleElement(hook, 1).focus();
    keydownOn(handleElement(hook, 1), " ");
    expect(hook._selectedPoints).toEqual(new Set());
    expect(list().querySelector('[data-point-check="1"]').checked).toBe(false);
    expect(list().querySelector("[data-delete-points]").textContent).toContain(
      "Delete points (0)",
    );
  });
});

describe("pattern_alignment_point_list delete", () => {
  it("Delete on a focused handle removes exactly that point", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    handleElement(hook, 0).focus();
    keydownOn(handleElement(hook, 0), "Delete");

    // The first interior point is gone; the stop anchors still draw the line.
    expect(hook._effectiveInterior(1)).toEqual([
      [-74.001, 40.01],
      [-74.0, 40.015],
    ]);
    expect(hook._sectionLayers.get(1).line.getLatLngs()).toHaveLength(4);
    expect(list().querySelectorAll(".pa-point-row")).toHaveLength(2);
    const states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.dirty_positions).toEqual([1]);
  });

  it("Delete points removes all selected and labels the count", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    for (const index of [0, 2]) {
      const box = list().querySelector(`[data-point-check="${index}"]`);
      box.checked = true;
      box.dispatchEvent(new Event("change", { bubbles: true }));
    }
    expect(list().querySelector("[data-delete-points]").textContent).toContain(
      "Delete points (2)",
    );

    // jsdom click() carries no focus; a keyboard press focuses first.
    list().querySelector("[data-delete-points]").focus();
    list().querySelector("[data-delete-points]").click();
    expect(hook._effectiveInterior(1)).toEqual([[-74.001, 40.01]]);
    expect(list().querySelectorAll(".pa-point-row")).toHaveLength(1);
    // The emptied Delete button disables and hands focus to Add midpoint.
    expect(list().querySelector("[data-delete-points]").disabled).toBe(true);
    expect(document.activeElement).toBe(
      list().querySelector("[data-add-midpoint]"),
    );
  });
});

describe("pattern_alignment_point_list add midpoint", () => {
  it("inserts the first-edge midpoint at interior index 0", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    list().querySelector("[data-add-midpoint]").click();

    const interior = hook._effectiveInterior(1);
    expect(interior).toHaveLength(4);
    // Midpoint of anchor Alpha (40.0, -74.0) and the first interior point
    // (40.005, -74.0) in [lon, lat] wire order.
    expect(interior[0]).toEqual([-74.0, 40.0025]);
    expect(interior[1]).toEqual([-74.0, 40.005]);
    expect(hook._selectedPoints).toEqual(new Set([0]));
    expect(hook._undo).toHaveLength(1);
  });

  it("midpoints the anchors when the interior is empty", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    ctx.handlers["alignment:select"]({ position: 2 });
    list().querySelector("[data-add-midpoint]").click();

    const interior = hook._effectiveInterior(2);
    expect(interior).toHaveLength(1);
    // Midpoint of Bravo (40.02, -74.0) and Charlie (40.04, -74.0).
    expect(interior[0]).toEqual([-74.0, 40.03]);
    const states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.dirty_positions).toEqual([2]);
  });
});
