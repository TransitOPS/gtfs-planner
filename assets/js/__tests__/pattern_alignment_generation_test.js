/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { afterEach, describe, expect, it } from "vitest";
import PatternAlignment from "../pattern_alignment_hook";

// Canvas stub, model shape and mount discipline mirror
// pattern_alignment_import_test.js (step 29): the hook builds its Leaflet
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

// Two missing sections on three visits; suggestions arrive as interior
// [lon, lat] points per section (the server strips the stop anchors, R5).
function model() {
  return {
    route_color: "#334155",
    editable: true,
    export: "none",
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
    imported_shapes: [],
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

describe("pattern_alignment_generation", () => {
  it("applies suggestions as dirty set drafts with review flags", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:suggestions"]({
      sections: [
        { position: 1, points: [[-74.0, 40.01]] },
        {
          position: 2,
          points: [
            [-74.0, 40.025],
            [-74.0, 40.03],
          ],
        },
      ],
      review: true,
    });

    const first = hook._drafts.get(1);
    expect(first.op).toBe("set");
    expect(first.dirty).toBe(true);
    expect(first.points).toEqual([[-74.0, 40.01]]);

    const second = hook._drafts.get(2);
    expect(second.op).toBe("set");
    expect(second.dirty).toBe(true);
    expect(second.points).toEqual([
      [-74.0, 40.025],
      [-74.0, 40.03],
    ]);

    // Both sections are flagged for review; the last draft-state push
    // carries the batch (selection reports its own push, as in convert).
    const states = draftStates(ctx.pushed);
    expect(states.length).toBeGreaterThanOrEqual(1);
    expect(states.at(-1).payload.dirty_positions).toEqual([1, 2]);
    expect(states.at(-1).payload.flagged_positions).toEqual([1, 2]);
    // Nothing reaches the server except the draft-state push (CR-9).
    expect(
      ctx.pushed.every((entry) => entry.event === "alignment_draft_state"),
    ).toBe(true);
  });

  it("records one undo entry per suggested section", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    const undoBefore = hook._undo.length;

    ctx.handlers["alignment:suggestions"]({
      sections: [{ position: 2, points: [[-74.0, 40.03]] }],
      review: true,
    });

    expect(hook._undo.length).toBe(undoBefore + 1);

    ctx.handlers["alignment:suggestions"]({
      sections: [
        { position: 1, points: [[-74.0, 40.01]] },
        { position: 2, points: [[-74.0, 40.031]] },
      ],
      review: true,
    });

    // Replacing section 2's suggestion is its own single undo unit.
    expect(hook._undo.length).toBe(undoBefore + 3);
  });

  it("skips unknown positions and misshapen points without pushing", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:suggestions"]({
      sections: [
        { position: 9, points: [[-74.0, 40.05]] },
        { position: 1, points: "not-points" },
        { position: 2, points: [[-74.0], [-74.0, 40.03, 7], [NaN, 40.03]] },
      ],
      review: true,
    });

    expect(hook._drafts.has(9)).toBe(false);
    expect(hook._drafts.has(1)).toBe(false);
    // Section 2's entry holds no valid points, so nothing is recorded.
    expect(hook._drafts.has(2)).toBe(false);
    expect(ctx.pushed.length).toBe(0);
  });

  it("ignores an empty payload and a read-only model", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:suggestions"]({ sections: [], review: true });
    ctx.handlers["alignment:suggestions"](null);
    expect(hook._drafts.size).toBe(0);
    expect(ctx.pushed.length).toBe(0);

    const viewer = mountTracked();
    load(viewer, { ...model(), editable: false });
    viewer.pushed.length = 0;
    viewer.handlers["alignment:suggestions"]({
      sections: [{ position: 1, points: [[-74.0, 40.01]] }],
      review: true,
    });
    expect(viewer.hook._drafts.size).toBe(0);
    expect(viewer.pushed.length).toBe(0);
  });
});
