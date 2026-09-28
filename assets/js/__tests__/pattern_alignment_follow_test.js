/* @vitest-environment jsdom */
import "../../vendor/leaflet";
import { afterEach, describe, expect, it } from "vitest";
import PatternAlignment from "../pattern_alignment_hook";

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

// Section 1 is saved with five interior points [p1..p5] between the Alpha
// (40.0, -74.0) and Bravo (40.02, -74.0) anchors. Anchors are [lon, lat]
// on the wire (INV-1); the anchors are never handles and never move.
const P1 = [-74.0, 40.004];
const P2 = [-74.001, 40.008];
const P3 = [-74.0, 40.012];
const P4 = [-74.001, 40.016];
const P5 = [-74.0, 40.018];

function model() {
  return {
    route_color: "#334155",
    editable: true,
    visits: [
      { position: 1, stop_id: "A", name: "Alpha", lat: 40.0, lon: -74.0, label: "1" },
      { position: 2, stop_id: "B", name: "Bravo", lat: 40.02, lon: -74.0, label: "2" },
    ],
    sections: [
      {
        position: 1,
        kind: "shared",
        points: [P1, P2, P3, P4, P5],
        revision: { segment_id: "seg-1", lock_version: 3 },
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

function openList(ctx) {
  ctx.handlers["alignment:load"]({ model: model() });
  ctx.root.dispatchEvent(
    new CustomEvent("alignment:action", {
      detail: { action: "toggle_points" },
      bubbles: true,
    }),
  );
  return ctx.hook;
}

function list() {
  return document.getElementById("alignment-point-list");
}

// Checks the point-list rows for the given 0-based interior indexes,
// mirroring a Shift-drag box select.
function select(hook, indexes) {
  hook._selectedPoints = new Set(indexes);
  hook._paintHandleSelection();
  hook.pushDraftState();
  hook._renderPointList();
}

function followButton() {
  return list().querySelector("[data-follow-streets]");
}

function followPushes(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_follow_streets");
}

function focusInside(ctx) {
  ctx.root.querySelector("[data-pa-pan]").focus();
}

function keydown(key, options = {}) {
  document.dispatchEvent(
    new KeyboardEvent("keydown", { key, bubbles: true, ...options }),
  );
}

describe("pattern_alignment_follow", () => {
  it("pushes the run with its neighbours and replaces exactly that run", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);
    expect(hook._mode).toBe("edit");

    // Interior [p1..p5], UI selection {2,3,4} (0-based {1,2,3}): the
    // neighbours are p1 and p5, so from is p1 and to is p5.
    select(hook, [1, 2, 3]);
    expect(followButton().disabled).toBe(false);

    followButton().click();
    const pushes = followPushes(ctx.pushed);
    expect(pushes).toHaveLength(1);
    expect(pushes[0].payload).toEqual({
      position: 1,
      start_index: 1,
      end_index: 3,
      interior_length: 5,
      from: P1,
      to: P5,
    });

    // The server echoes the run bounds with the routed interior points.
    const q1 = [-73.9995, 40.01];
    const q2 = [-73.9995, 40.014];
    ctx.handlers["alignment:follow_result"]({
      position: 1,
      start_index: 1,
      end_index: 3,
      points: [q1, q2],
    });
    expect(hook._effectiveInterior(1)).toEqual([P1, q1, q2, P5]);

    // One undo entry restores [p1..p5].
    expect(hook._undo).toHaveLength(1);
    focusInside(ctx);
    keydown("z", { ctrlKey: true });
    expect(hook._effectiveInterior(1)).toEqual([P1, P2, P3, P4, P5]);
  });

  it("uses anchor coordinates when the run touches an end", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    select(hook, [0, 1]);
    followButton().click();
    expect(followPushes(ctx.pushed)[0].payload).toEqual({
      position: 1,
      start_index: 0,
      end_index: 1,
      interior_length: 5,
      from: [-74.0, 40.0],
      to: P3,
    });
  });

  it("disables follow streets with a reason for a non-contiguous selection", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    select(hook, [1, 3]);
    const button = followButton();
    expect(button.disabled).toBe(true);
    expect(button.getAttribute("title")).toBe(
      "Select neighbouring points to follow streets",
    );
    button.click();
    expect(followPushes(ctx.pushed)).toHaveLength(0);
  });

  it("disables follow streets with a reason when nothing is selected", () => {
    const ctx = mountTracked();
    openList(ctx);

    const button = followButton();
    expect(button.disabled).toBe(true);
    expect(button.getAttribute("title")).toBe(
      "Select neighbouring points to follow streets",
    );
  });

  it("bails with a notice when the section changed mid-flight", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    select(hook, [1, 2, 3]);
    followButton().click();
    expect(followPushes(ctx.pushed)).toHaveLength(1);

    // A concurrent edit (here an added midpoint) shifts the interior
    // after the push: the routed result must not splice over it.
    hook._commit(1, [[-74.0, 40.002], P1, P2, P3, P4, P5]);
    ctx.handlers["alignment:follow_result"]({
      position: 1,
      start_index: 1,
      end_index: 3,
      points: [[-73.9995, 40.01]],
    });

    expect(hook._effectiveInterior(1)).toEqual([
      [-74.0, 40.002],
      P1,
      P2,
      P3,
      P4,
      P5,
    ]);
    expect(ctx.pushed).toContainEqual({
      event: "alignment_action_notice",
      payload: {
        message:
          "This section changed while the street path was routing. Select the points and try again.",
      },
    });
  });

  it("ignores a misshapen follow result and changes nothing", () => {
    const ctx = mountTracked();
    const hook = openList(ctx);

    select(hook, [1, 2]);
    ctx.handlers["alignment:follow_result"]({
      position: 1,
      start_index: 1,
      end_index: 5,
      points: [[-73.9995, 40.01]],
    });
    expect(hook._effectiveInterior(1)).toEqual([P1, P2, P3, P4, P5]);
    expect(hook._undo).toHaveLength(0);

    ctx.handlers["alignment:follow_result"]({ position: 99 });
    expect(hook._effectiveInterior(1)).toEqual([P1, P2, P3, P4, P5]);
  });
});
