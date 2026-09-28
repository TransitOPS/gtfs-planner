/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { afterEach, describe, expect, it } from "vitest";
import PatternAlignment from "../pattern_alignment_hook";

// Canvas stub, model shape and mount discipline mirror
// pattern_alignment_section_actions_test.js (step 26): the hook builds its
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

// Section 1 is shared with one interior point; section 2 is missing.
// Identity and revision ride the saved sections (the server re-checks
// both: stale identity is stale stops, stale revision is a conflict).
function model() {
  return {
    route_color: "#334155",
    editable: true,
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
        kind: "shared",
        points: [[-74.0, 40.01]],
        revision: { segment_id: "seg-1", lock_version: 3 },
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

function saveRequests(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_save_requested");
}

describe("pattern_alignment_save", () => {
  it("pushes dirty sections with identity, op, points and base", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(1, false);

    // A geometry edit commits a set draft; the save push carries it with
    // the visit identity and the load-time base revision.
    hook._commit(1, [[-73.999, 40.011]]);

    const before = saveRequests(ctx.pushed).length;
    ctx.root.dispatchEvent(
      new CustomEvent("alignment:action", {
        detail: { action: "save" },
        bubbles: true,
      }),
    );

    const requests = saveRequests(ctx.pushed);
    expect(requests.length).toBe(before + 1);
    expect(requests.at(-1).payload.sections).toEqual([
      {
        position: 1,
        from_occurrence_id: "occ-1",
        to_stop_id: "B",
        op: "set",
        points: [[-73.999, 40.011]],
        base: { segment_id: "seg-1", lock_version: 3 },
      },
    ]);
  });

  it("never queues two saves while one is in flight", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(1, false);
    hook._commit(1, [[-73.999, 40.011]]);

    const dispatchSave = () =>
      ctx.root.dispatchEvent(
        new CustomEvent("alignment:action", {
          detail: { action: "save" },
          bubbles: true,
        }),
      );

    dispatchSave();
    dispatchSave();
    expect(saveRequests(ctx.pushed).length).toBe(1);
    expect(document.getElementById("alignment-save").disabled).toBe(true);

    // The server settle releases the guard without touching the draft.
    ctx.handlers["alignment:save_settled"]({});
    expect(document.getElementById("alignment-save").disabled).toBe(false);

    dispatchSave();
    expect(saveRequests(ctx.pushed).length).toBe(2);
  });

  it("rebases dirty drafts to the latest revisions and keeps the points", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(1, false);
    hook._commit(1, [[-73.999, 40.011]]);

    ctx.handlers["alignment:rebase"]({
      bases: [{ position: 1, segment_id: "seg-1", lock_version: 5 }],
    });

    const draft = hook._drafts.get(1);
    expect(draft.points).toEqual([[-73.999, 40.011]]);
    expect(draft.revision).toEqual({ segment_id: "seg-1", lock_version: 5 });
    expect(draft.dirty).toBe(true);
  });

  it("ignores unknown rebase positions", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(1, false);
    hook._commit(1, [[-73.999, 40.011]]);

    ctx.handlers["alignment:rebase"]({
      bases: [{ position: 9, segment_id: "seg-9", lock_version: 1 }],
    });

    expect(hook._drafts.get(1).revision).toEqual({
      segment_id: "seg-1",
      lock_version: 3,
    });
  });
});
