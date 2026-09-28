/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { afterEach, describe, expect, it } from "vitest";
import PatternAlignment from "../pattern_alignment_hook";

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

const L = window.L;

// Section 1 is saved with two interior points; section 2 is saved straight;
// section 3 is missing. Anchors are [lon, lat] on the wire (INV-1).
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

// See the step 23 teardown note: let the draw's scheduled Canvas frame fire
// while the map is alive before destroying it.
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

function enterEdit(ctx) {
  ctx.root.querySelector("[data-pa-edit]").click();
  return ctx.hook;
}

function focusInside(ctx) {
  ctx.root.querySelector("[data-pa-pan]").focus();
}

function keydown(key, options = {}) {
  document.dispatchEvent(
    new KeyboardEvent("keydown", { key, bubbles: true, ...options }),
  );
}

function draftStates(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_draft_state");
}

describe("pattern_alignment_editing mode", () => {
  it("enables Edit points on a selected saved section and shows two handles", () => {
    const ctx = mountTracked();
    load(ctx.handlers);

    const edit = ctx.root.querySelector("[data-pa-edit]");
    expect(edit.disabled).toBe(false);

    const hook = enterEdit(ctx);
    expect(hook._mode).toBe("edit");
    expect(
      ctx.root.querySelector("[data-pa-edit]").getAttribute("aria-pressed"),
    ).toBe("true");
    expect(
      ctx.root.querySelector("[data-pa-pan]").getAttribute("aria-pressed"),
    ).toBe("false");
    // Interior points only: two handles, never the stop anchors.
    expect(hook._handles).toHaveLength(2);
    expect(
      ctx.root.querySelectorAll(".alignment-handle").length,
    ).toBe(2);
    expect(ctx.root.querySelector(".pa-help strong").textContent).toBe(
      "Click the line to add a point",
    );
  });

  it("clears undo history when a fresh model loads", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    enterEdit(ctx);
    ctx.hook._sectionLayers.get(1).line.fire("click", {
      latlng: L.latLng(40.0025, -74.0),
    });
    expect(ctx.hook._undo).toHaveLength(1);

    load(ctx.handlers);
    expect(ctx.hook._undo).toHaveLength(0);
    expect(ctx.hook._redo).toHaveLength(0);
    expect(ctx.hook._mode).toBe("pan");
  });
});

describe("pattern_alignment_editing insertion", () => {
  it("inserts beside the first edge at interior index 0 and marks the section dirty", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    enterEdit(ctx);

    ctx.hook._sectionLayers.get(1).line.fire("click", {
      latlng: L.latLng(40.0025, -74.0),
    });

    // The click lands on the first edge (anchor A to point 1), so the new
    // point lands at index 0 of the interior in [lon, lat] wire order.
    const interior = ctx.hook._effectiveInterior(1);
    expect(interior).toHaveLength(3);
    expect(interior[0]).toEqual([-74.0, 40.0025]);
    expect(interior[1]).toEqual([-74.0, 40.005]);

    const states = draftStates(ctx.pushed);
    expect(states.length).toBeGreaterThan(0);
    expect(states[states.length - 1].payload.dirty_positions).toEqual([1]);
    expect(states[states.length - 1].payload.can_undo).toBe(true);

    // The unsaved line draws amber until the save flow owns it (step 27+).
    expect(ctx.hook._sectionLayers.get(1).line.options.color).toBe("#8a5a0e");
  });
});

describe("pattern_alignment_editing drag", () => {
  it("commits one undo entry with the [lon, lat] position on dragend", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    enterEdit(ctx);

    const marker = ctx.hook._handles[1];
    // Simulate the drag the way the subspec prescribes: move first, then
    // release. Intermediate moves record no history.
    marker.setLatLng(L.latLng(40.016, -73.999));
    marker.fire("drag");
    marker.fire("drag");
    expect(ctx.hook._undo).toHaveLength(0);
    marker.fire("dragend");

    expect(ctx.hook._effectiveInterior(1)[1]).toEqual([-73.999, 40.016]);
    expect(ctx.hook._undo).toHaveLength(1);
    expect(ctx.hook._undo[0]).toEqual({
      position: 1,
      before: [
        [-74.0, 40.005],
        [-74.0, 40.015],
      ],
      after: [
        [-74.0, 40.005],
        [-73.999, 40.016],
      ],
    });
    const states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.dirty_positions).toEqual([1]);
  });
});

describe("pattern_alignment_editing delete", () => {
  it("removes exactly the selected interior points and never the anchors", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    enterEdit(ctx);

    ctx.hook._handles[0].fire("click");
    ctx.hook._handles[1].fire("click");
    expect(ctx.hook._selectedPoints).toEqual(new Set([0, 1]));

    focusInside(ctx);
    keydown("Delete");

    expect(ctx.hook._effectiveInterior(1)).toEqual([]);
    // The anchors still draw the straight two-point line.
    expect(ctx.hook._sectionLayers.get(1).line.getLatLngs()).toHaveLength(2);
    const states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.dirty_positions).toEqual([1]);
    expect(states[states.length - 1].payload.selected_point_count).toBe(0);
  });
});

describe("pattern_alignment_editing box select", () => {
  it("selects both handles and suspends map dragging during the box", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    enterEdit(ctx);
    const { hook, root } = ctx;

    const container = root.querySelector("[data-pa-leaflet]");
    const first = hook._map.latLngToContainerPoint(
      hook._handles[0].getLatLng(),
    );
    const second = hook._map.latLngToContainerPoint(
      hook._handles[1].getLatLng(),
    );

    // A real Shift-drag holds Shift before the pointer goes down, which
    // pre-disables panning regardless of listener order on the container.
    focusInside(ctx);
    keydown("Shift");
    expect(hook._map.dragging.enabled()).toBe(false);

    container.dispatchEvent(
      new MouseEvent("mousedown", {
        bubbles: true,
        shiftKey: true,
        clientX: Math.min(first.x, second.x) - 10,
        clientY: Math.min(first.y, second.y) - 10,
      }),
    );
    expect(hook._map.dragging.enabled()).toBe(false);

    document.dispatchEvent(
      new MouseEvent("mousemove", {
        bubbles: true,
        shiftKey: true,
        clientX: Math.max(first.x, second.x) + 10,
        clientY: Math.max(first.y, second.y) + 10,
      }),
    );
    document.dispatchEvent(
      new MouseEvent("mouseup", { bubbles: true, shiftKey: true }),
    );
    document.dispatchEvent(
      new KeyboardEvent("keyup", { key: "Shift", bubbles: true }),
    );

    expect(hook._selectedPoints).toEqual(new Set([0, 1]));
    expect(hook._map.dragging.enabled()).toBe(true);
    const states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.selected_point_count).toBe(2);
    expect(
      root.querySelectorAll(".alignment-handle-dot.is-selected").length,
    ).toBe(2);
  });
});

describe("pattern_alignment_editing undo and redo", () => {
  it("restores the exact previous interior array and re-applies it", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    enterEdit(ctx);

    ctx.hook._sectionLayers.get(1).line.fire("click", {
      latlng: L.latLng(40.0025, -74.0),
    });
    expect(ctx.hook._effectiveInterior(1)).toHaveLength(3);

    focusInside(ctx);
    keydown("z", { ctrlKey: true });
    expect(ctx.hook._effectiveInterior(1)).toEqual([
      [-74.0, 40.005],
      [-74.0, 40.015],
    ]);
    let states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.can_undo).toBe(false);
    expect(states[states.length - 1].payload.can_redo).toBe(true);
    // Undoing back to the saved geometry clears the dirty flag and the
    // amber line.
    expect(states[states.length - 1].payload.dirty_positions).toEqual([]);
    expect(ctx.hook._sectionLayers.get(1).line.options.color).toBe("#334155");

    keydown("Z", { ctrlKey: true, shiftKey: true });
    expect(ctx.hook._effectiveInterior(1)).toHaveLength(3);
    expect(ctx.hook._effectiveInterior(1)[0]).toEqual([-74.0, 40.0025]);
    states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.can_undo).toBe(true);
    expect(states[states.length - 1].payload.can_redo).toBe(false);
  });
});

describe("pattern_alignment_editing escape", () => {
  it("returns to Pan and clears the selection", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    enterEdit(ctx);

    ctx.hook._handles[0].fire("click");
    expect(ctx.hook._selectedPoints.size).toBe(1);

    focusInside(ctx);
    keydown("Escape");

    expect(ctx.hook._mode).toBe("pan");
    expect(ctx.hook._selectedPoints.size).toBe(0);
    expect(ctx.hook._handles).toHaveLength(0);
    const states = draftStates(ctx.pushed);
    expect(states[states.length - 1].payload.mode).toBe("pan");
    expect(states[states.length - 1].payload.selected_point_count).toBe(0);
  });
});

describe("pattern_alignment_editing missing sections", () => {
  it("shows no handles and keeps Edit points disabled with a Draw title", () => {
    const ctx = mountTracked();
    load(ctx.handlers);

    ctx.handlers["alignment:select"]({ position: 3 });

    expect(ctx.hook._handles).toHaveLength(0);
    const edit = ctx.root.querySelector("[data-pa-edit]");
    expect(edit.disabled).toBe(true);
    expect(edit.title).toMatch(/Draw manually/);
  });
});

describe("pattern_alignment_editing draft payload", () => {
  it("pushes the spec's alignment_draft_state shape", () => {
    const ctx = mountTracked();
    load(ctx.handlers);
    enterEdit(ctx);

    ctx.hook._sectionLayers.get(1).line.fire("click", {
      latlng: L.latLng(40.0025, -74.0),
    });

    const states = draftStates(ctx.pushed);
    const payload = states[states.length - 1].payload;
    expect(Object.keys(payload).sort()).toEqual(
      [
        "can_redo",
        "can_undo",
        "dirty_positions",
        "flagged_positions",
        "mode",
        "point_count",
        "review_positions",
        "selected",
        "selected_point_count",
      ].sort(),
    );
    expect(payload).toMatchObject({
      dirty_positions: [1],
      selected: 1,
      mode: "edit",
      point_count: 3,
      can_undo: true,
      can_redo: false,
      flagged_positions: [],
      review_positions: [],
    });
  });
});
