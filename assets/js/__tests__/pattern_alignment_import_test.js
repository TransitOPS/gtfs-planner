/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { afterEach, describe, expect, it } from "vitest";
import PatternAlignment from "../pattern_alignment_hook";

// Canvas stub, model shape and mount discipline mirror
// pattern_alignment_save_test.js (step 28): the hook builds its Leaflet
// map with preferCanvas, so jsdom needs an absorbing 2d context and a
// 50 ms settle before destroy.
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

// Two missing sections on three visits; the pattern still exports its
// imported shapes. NEAR follows the visits exactly (projection succeeds);
// FAR sits a degree away (projection fails, both sections flagged).
function model() {
  return {
    route_color: "#334155",
    editable: true,
    export: "imported",
    visits: [
      { position: 1, stop_id: "A", name: "Alpha", lat: 40.0, lon: -74.0, label: "1" },
      { position: 2, stop_id: "B", name: "Bravo", lat: 40.02, lon: -74.0, label: "2" },
      { position: 3, stop_id: "C", name: "Charlie", lat: 40.04, lon: -74.0, label: "3" },
    ],
    sections: [
      {
        position: 1,
        from_occurrence_id: "occ-1",
        to_occurrence_id: "occ-2",
        from_stop_id: "A",
        to_stop_id: "B",
        kind: "missing",
        points: [],
        revision: { segment_id: null, lock_version: null },
      },
      {
        position: 2,
        from_occurrence_id: "occ-2",
        to_occurrence_id: "occ-3",
        from_stop_id: "B",
        to_stop_id: "C",
        kind: "missing",
        points: [],
        revision: { segment_id: null, lock_version: null },
      },
    ],
    imported_shapes: [
      {
        shape_id: "IMP-NEAR",
        trip_count: 2,
        points: [
          [-74.0, 40.0],
          [-74.0, 40.01],
          [-74.0, 40.02],
          [-74.0, 40.03],
          [-74.0, 40.04],
        ],
        length_m: 4449.6,
        visit_distances: null,
      },
      {
        shape_id: "IMP-FAR",
        trip_count: 1,
        points: [
          [-73.0, 41.0],
          [-73.0, 41.02],
        ],
        length_m: 2224.8,
        visit_distances: null,
      },
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
    <button id="alignment-save" type="button">Save alignment</button>
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

function draftStates(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_draft_state");
}

describe("pattern_alignment_import", () => {
  it("draws imported shapes as grey non-interactive reference polylines", () => {
    const ctx = mountTracked();
    const hook = load(ctx);

    expect(hook._importedLayers.length).toBe(2);
    for (const line of hook._importedLayers) {
      expect(line.options.interactive).toBe(false);
      expect(line.options.color).toBe("#6b7280");
    }
    // Reference lines never enter the selectable section layers.
    expect(hook._sectionLayers.size).toBe(2);
  });

  it("draws no reference layer once the pattern exports drawn shapes", () => {
    const ctx = mountTracked();
    const fixture = { ...model(), export: "current" };
    const hook = load(ctx, fixture);

    expect(hook._importedLayers.length).toBe(0);
  });

  it("converts the near shape into dirty set drafts with no flags", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:convert"]({ shape_id: "IMP-NEAR" });

    for (const position of [1, 2]) {
      const draft = hook._drafts.get(position);
      expect(draft.op).toBe("set");
      expect(draft.dirty).toBe(true);
      expect(draft.points.length).toBeGreaterThan(0);
      // Wire order stays [lon, lat] (INV-1).
      for (const [lon, lat] of draft.points) {
        expect(lon).toBeCloseTo(-74.0, 5);
        expect(lat).toBeGreaterThanOrEqual(40.0);
        expect(lat).toBeLessThanOrEqual(40.04);
      }
    }

    const states = draftStates(ctx.pushed);
    expect(states.length).toBeGreaterThanOrEqual(1);
    expect(states.at(-1).payload.flagged_positions).toEqual([]);
    // The reference layer is gone: the drafts carry the geometry now.
    expect(hook._importedLayers.length).toBe(0);
    // Nothing reaches the server except the draft-state push (CR-9).
    expect(
      ctx.pushed.every((entry) => entry.event === "alignment_draft_state"),
    ).toBe(true);
  });

  it("flags both sections when the shape is too far to project", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:convert"]({ shape_id: "IMP-FAR" });

    for (const position of [1, 2]) {
      const draft = hook._drafts.get(position);
      expect(draft.op).toBe("set");
      expect(draft.dirty).toBe(true);
      expect(draft.points).toEqual([]);
    }

    const states = draftStates(ctx.pushed);
    expect(states.at(-1).payload.flagged_positions).toEqual([1, 2]);
    expect(
      ctx.pushed.every((entry) => entry.event === "alignment_draft_state"),
    ).toBe(true);
  });

  it("ignores an unknown shape id without drafting or pushing", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:convert"]({ shape_id: "IMP-NOPE" });

    expect(hook._drafts.size).toBe(0);
    expect(ctx.pushed).toEqual([]);
    // The reference layer stays for review.
    expect(hook._importedLayers.length).toBe(2);
  });

  it("never converts for viewers", () => {
    const ctx = mountTracked();
    const hook = load(ctx, { ...model(), editable: false });
    ctx.pushed.length = 0;

    ctx.handlers["alignment:convert"]({ shape_id: "IMP-NEAR" });

    expect(hook._drafts.size).toBe(0);
    expect(ctx.pushed).toEqual([]);
  });
});
