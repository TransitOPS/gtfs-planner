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

// Section 1 is an override with one interior point; section 2 is an
// override beside a shared path; section 3 is missing. Anchors are
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
        kind: "override",
        points: [[-74.0, 40.01]],
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

function draftStates(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_draft_state");
}

describe("pattern_alignment_guards", () => {
  it("reconnected() re-pushes the unchanged dirty positions", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    hook._select(2, false);

    dispatch(ctx, "clear", 2);

    const before = draftStates(ctx.pushed).at(-1);
    expect(before.payload.dirty_positions).toEqual([2]);

    ctx.pushed.length = 0;
    hook.reconnected();

    const states = draftStates(ctx.pushed);
    expect(states).toHaveLength(1);
    expect(states[0].payload.dirty_positions).toEqual([2]);
    expect(states[0].payload.selected).toBe(before.payload.selected);
  });

  it("reconnected() never requests a model reload", () => {
    const ctx = mountTracked();
    load(ctx);

    ctx.pushed.length = 0;
    ctx.hook.reconnected();

    expect(ctx.pushed.some((entry) => entry.event === "alignment_hook_ready")).toBe(false);
    expect(draftStates(ctx.pushed)).toHaveLength(1);
  });

  it("reconnected() on a clean hook reports no dirty positions", () => {
    const ctx = mountTracked();
    load(ctx);

    ctx.pushed.length = 0;
    ctx.hook.reconnected();

    expect(draftStates(ctx.pushed)[0].payload.dirty_positions).toEqual([]);
  });
});
