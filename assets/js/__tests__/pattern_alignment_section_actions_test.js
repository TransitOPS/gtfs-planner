/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { afterEach, describe, expect, it } from "vitest";
import PatternAlignment, { MISSING_COLOR } from "../pattern_alignment_hook";

// Canvas stub, model shape and mount discipline mirror
// pattern_alignment_point_list_test.js (step 25): the hook builds its
// Leaflet map with preferCanvas, so jsdom needs an absorbing 2d context
// and a 50 ms settle before destroy.
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

// Section 1 is an override with four interior points (three collinear on
// the meridian, one ~15 m bump east); section 2 is an override beside a
// shared path with a single ~15 m bump; section 3 is missing. Anchors are
// [lon, lat] on the wire (INV-1); one degree of longitude at 40° N spans
// ~85 km, so 0.00018° ≈ 15 m.
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
        kind: "override",
        points: [
          [-74.0, 40.004],
          [-73.99982, 40.008],
          [-74.0, 40.012],
          [-74.0, 40.016],
        ],
        revision: { segment_id: "seg-1", lock_version: 3 },
      },
      {
        position: 2,
        kind: "override",
        points: [[-73.99982, 40.03]],
        shared_points: [
          [-74.0, 40.025],
          [-74.0, 40.035],
        ],
        revision: { segment_id: "seg-2", lock_version: 1 },
      },
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

function load(ctx, fixture = model()) {
  ctx.handlers["alignment:load"]({ model: fixture });
  return ctx.hook;
}

function dispatch(ctx, action, position) {
  ctx.root.dispatchEvent(
    new CustomEvent("alignment:action", {
      detail: { action, position },
      bubbles: true,
    }),
  );
}

function notices(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_action_notice");
}

function results(pushed) {
  return pushed.filter(
    (entry) => entry.event === "alignment_simplify_result",
  );
}

describe("pattern_alignment_section_actions", () => {
  it("draws a missing section as a set draft with [] and enters Edit mode", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(3, false);

    dispatch(ctx, "draw", 3);

    const draft = hook._drafts.get(3);
    expect(draft.op).toBe("set");
    expect(draft.points).toEqual([]);
    expect(draft.dirty).toBe(true);
    expect(hook._mode).toBe("edit");
    expect(hook._selected).toBe(3);
    // The missing connector turns into an unsaved straight draft, and the
    // hook announces the next step through the page status region.
    expect(notices(ctx.pushed).at(-1).payload.message).toContain(
      "Click the line to add a point",
    );
    // Undo removes the draft: the section reads missing again.
    hook._undoOnce();
    expect(hook._drafts.has(3)).toBe(false);
  });

  it("ignores draw on saved geometry", () => {
    const ctx = mountTracked();
    const hook = load(ctx);

    dispatch(ctx, "draw", 1);

    expect(hook._drafts.has(1)).toBe(false);
    expect(hook._mode).toBe("pan");
  });

  it("clears a saved section to [] while keeping its saved kind", () => {
    const ctx = mountTracked();
    const hook = load(ctx);

    dispatch(ctx, "clear", 1);

    const draft = hook._drafts.get(1);
    expect(draft.op).toBe("set");
    expect(draft.points).toEqual([]);
    expect(hook._effectiveInterior(1)).toEqual([]);
    // The saved kind is untouched: only the draft changed.
    expect(hook._savedSection(1).kind).toBe("override");
    expect(notices(ctx.pushed).at(-1).payload.message).toBe(
      "Interior points cleared. A straight draft remains. Undo is available.",
    );
    hook._undoOnce();
    expect(hook._drafts.has(1)).toBe(false);
    expect(hook._effectiveInterior(1)).toHaveLength(4);
  });

  it("treats clearing an already straight section as a no-op", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(2, false);
    // Straighten section 2 first through a committed clear of its bump.
    dispatch(ctx, "clear", 2);
    expect(hook._drafts.has(2)).toBe(true);
    hook._undoOnce();
    hook._undo.length = 0;

    // Section 2 still holds its bump; clear it, then clear the straight
    // remainder: the second clear records nothing.
    dispatch(ctx, "clear", 2);
    const undoDepth = hook._undo.length;
    dispatch(ctx, "clear", 2);
    expect(hook._undo.length).toBe(undoDepth);
  });

  it("drafts use_shared with the shared points and undoes to the override", () => {
    const ctx = mountTracked();
    const hook = load(ctx);

    dispatch(ctx, "use_shared", 2);

    const draft = hook._drafts.get(2);
    expect(draft.op).toBe("use_shared");
    expect(hook._effectiveInterior(2)).toEqual([
      [-74.0, 40.025],
      [-74.0, 40.035],
    ]);
    expect(notices(ctx.pushed).at(-1).payload.message).toBe(
      "Shared path restored in this draft. Save to apply it.",
    );
    hook._undoOnce();
    expect(hook._drafts.has(2)).toBe(false);
    expect(hook._effectiveInterior(2)).toEqual([[-73.99982, 40.03]]);
  });

  it("ignores use_shared without shared points", () => {
    const ctx = mountTracked();
    const hook = load(ctx);

    dispatch(ctx, "use_shared", 1);

    expect(hook._drafts.has(1)).toBe(false);
  });

  it("deletes a saved section as a missing connector and undoes it", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(1, false);
    ctx.root.querySelector("[data-pa-edit]").click();
    expect(hook._mode).toBe("edit");

    ctx.handlers["alignment:delete_section"]({ position: 1 });

    const draft = hook._drafts.get(1);
    expect(draft.op).toBe("delete");
    expect(hook._effectiveInterior(1)).toEqual([]);
    const entry = hook._sectionLayers.get(1);
    expect(entry.line.options.color).toBe(MISSING_COLOR);
    // Editing falls back to Pan so no handles linger on the removed path.
    expect(hook._mode).toBe("pan");
    expect(notices(ctx.pushed).at(-1).payload.message).toBe(
      "Section removed from draft. Undo is available.",
    );
    hook._undoOnce();
    expect(hook._drafts.has(1)).toBe(false);
    expect(hook._effectiveInterior(1)).toHaveLength(4);
    expect(entry.line.options.color).not.toBe(MISSING_COLOR);
  });

  it("ignores delete on a missing section", () => {
    const ctx = mountTracked();
    const hook = load(ctx);

    ctx.handlers["alignment:delete_section"]({ position: 3 });

    expect(hook._drafts.has(3)).toBe(false);
  });

  it("simplifies collinear points at 10 m and reports the removed count", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(1, false);

    ctx.handlers["alignment:simplify"]({ position: 1, tolerance_m: 10 });

    // The three exactly collinear points go; the ~15 m bump stays, and
    // the first post-bump point survives its ~10 m deviation at this
    // tolerance. Both anchors stay fixed by construction.
    expect(hook._effectiveInterior(1)).toEqual([
      [-73.99982, 40.008],
      [-74.0, 40.012],
    ]);
    expect(hook._drafts.get(1).op).toBe("set");
    expect(results(ctx.pushed).at(-1).payload).toEqual({
      removed: 2,
      position: 1,
    });
    hook._undoOnce();
    expect(hook._effectiveInterior(1)).toHaveLength(4);
  });

  it("leaves the draft unchanged when nothing can be removed", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(2, false);

    ctx.handlers["alignment:simplify"]({ position: 2, tolerance_m: 5 });

    expect(hook._drafts.has(2)).toBe(false);
    expect(hook._effectiveInterior(2)).toEqual([[-73.99982, 40.03]]);
    expect(results(ctx.pushed).at(-1).payload).toEqual({
      removed: 0,
      position: 2,
    });
  });

  it("simplifies only the selected run when points are selected", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(1, false);
    hook._selectedPoints = new Set([0]);

    ctx.handlers["alignment:simplify"]({ position: 1, tolerance_m: 10 });

    // Only the first collinear point goes; the bump and the rest stay.
    expect(results(ctx.pushed).at(-1).payload.removed).toBe(1);
    expect(hook._effectiveInterior(1)).toEqual([
      [-73.99982, 40.008],
      [-74.0, 40.012],
      [-74.0, 40.016],
    ]);
  });

  it("ignores simplify with an invalid tolerance", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(1, false);

    ctx.handlers["alignment:simplify"]({ position: 1, tolerance_m: "far" });

    expect(hook._drafts.has(1)).toBe(false);
    expect(results(ctx.pushed)).toHaveLength(0);
  });
});
