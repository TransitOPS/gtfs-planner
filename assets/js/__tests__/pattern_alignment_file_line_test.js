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

// Three visits on one meridian and two missing sections, so the pattern
// exports no drawn shapes and the file line is the only geometry to look
// at. The file line runs straight up the same meridian, through every
// visit, so `fitSummary` reports "same" (step 28's own literals).
const FILE_LINE = [
  [-74.0, 40.0],
  [-74.0, 40.01],
  [-74.0, 40.02],
  [-74.0, 40.03],
  [-74.0, 40.04],
];

function model(visits) {
  return {
    route_color: "#334155",
    editable: true,
    export: "current",
    visits: visits || [
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

function fitResults(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_fit_result");
}

function draftStates(pushed) {
  return pushed.filter((entry) => entry.event === "alignment_draft_state");
}

function arrowAngles(hook) {
  return hook._fileLayers
    .filter((layer) => layer.options && layer.options.icon)
    .map((layer) => layer.options.icon.options.html);
}

describe("pattern_alignment_file_line", () => {
  it("reports the fit for a line following the visits and previews it", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });

    const results = fitResults(ctx.pushed);
    expect(results.length).toBe(1);
    const fit = results.at(-1).payload;
    expect(fit.direction).toBe("same");
    expect(fit.reaches_start).toBe(true);
    expect(fit.reaches_end).toBe(true);
    expect(fit.far).toEqual([]);
    expect(fit.within).toBe(3);
    expect(fit.visit_count).toBe(3);
    expect(fit.length_m).toBeGreaterThan(0);

    // The preview draws: two non-interactive polylines plus arrows.
    const polylines = hook._fileLayers.filter((layer) => layer.getLatLngs);
    expect(polylines.length).toBe(2);
    for (const line of polylines) {
      expect(line.options.interactive).toBe(false);
    }
    expect(polylines[1].options.color).toBe("#0e7490");
    const arrows = arrowAngles(hook);
    expect(arrows.length).toBeGreaterThan(0);
    for (const html of arrows) expect(html).toContain("pa-file-arrow");
    // The preview never becomes a selectable section.
    expect(hook._sectionLayers.size).toBe(2);
  });

  it("drafts nothing from a preview alone", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });
    ctx.handlers["alignment:reverse_file_line"]();

    expect(hook._drafts.size).toBe(0);
    expect(draftStates(ctx.pushed).length).toBe(0);
    // Only the fit reports travel to the server (CR-9).
    expect(ctx.pushed.every((entry) => entry.event === "alignment_fit_result")).toBe(
      true,
    );
  });

  it("flips the reported direction and redraws the arrows on reverse", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });
    const before = arrowAngles(hook);

    ctx.handlers["alignment:reverse_file_line"]();
    const reversed = fitResults(ctx.pushed).at(-1).payload;
    expect(reversed.direction).toBe("reversed");
    expect(hook._fileLinePoints[0]).toEqual(FILE_LINE.at(-1));
    expect(hook._fileLinePoints.at(-1)).toEqual(FILE_LINE[0]);
    // The same layers count draws again, with the arrows turned the other
    // way round.
    const after = arrowAngles(hook);
    expect(after.length).toBe(before.length);
    expect(after).not.toEqual(before);

    ctx.handlers["alignment:reverse_file_line"]();
    expect(fitResults(ctx.pushed).at(-1).payload.direction).toBe("same");
    expect(arrowAngles(hook)).toEqual(before);
  });

  it("marks every section dirty on file_draft and pushes the draft state", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_draft"]();

    for (const position of [1, 2]) {
      const draft = hook._drafts.get(position);
      expect(draft.op).toBe("set");
      expect(draft.dirty).toBe(true);
      expect(draft.points.length).toBeGreaterThan(0);
      for (const [lon, lat] of draft.points) {
        expect(lon).toBeCloseTo(-74.0, 5);
        expect(lat).toBeGreaterThanOrEqual(40.0);
        expect(lat).toBeLessThanOrEqual(40.04);
      }
    }
    const states = draftStates(ctx.pushed);
    expect(states.length).toBeGreaterThanOrEqual(1);
    expect(states.at(-1).payload.dirty_positions).toEqual([1, 2]);
    expect(states.at(-1).payload.flagged_positions).toEqual([]);
    // The drafts now carry the geometry, so the preview is gone.
    expect(hook._fileLayers.length).toBe(0);
    expect(hook._fileLinePoints).toBe(null);
  });

  it("removes the preview on clear_file_line", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });
    expect(hook._fileLayers.length).toBeGreaterThan(0);

    ctx.handlers["alignment:clear_file_line"]();

    expect(hook._fileLayers.length).toBe(0);
    expect(hook._fileLinePoints).toBe(null);
    expect(hook._fileFit).toBe(null);
    // Clearing a preview is not a draft: nothing changes and nothing pushes.
    expect(hook.dirtyPositions()).toEqual([]);
  });

  it("rings and reports a stop the line runs too far from", () => {
    const ctx = mountTracked();
    // The middle visit sits about 167 m east of the line, past the 100 m
    // threshold the conversion uses (INV-5).
    const hook = load(
      ctx,
      model([
        { position: 1, stop_id: "A", name: "Alpha", lat: 40.0, lon: -74.0, label: "1" },
        { position: 2, stop_id: "B", name: "Bravo", lat: 40.02, lon: -73.9985, label: "2" },
        { position: 3, stop_id: "C", name: "Charlie", lat: 40.04, lon: -74.0, label: "3" },
      ]),
    );
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });

    const fit = fitResults(ctx.pushed).at(-1).payload;
    expect(fit.direction).toBe("same");
    expect(fit.within).toBe(2);
    expect(fit.far.length).toBe(1);
    expect(fit.far[0].position).toBe(2);
    expect(fit.far[0].stop_id).toBe("B");
    expect(fit.far[0].distance_m).toBeGreaterThan(100);
    // One red ring on the line beside the far stop.
    const rings = hook._fileLayers.filter((layer) => layer.getRadius);
    expect(rings.length).toBe(1);
    expect(rings[0].options.color).toBe("#9b1c1c");
  });

  it("reports an unknown direction honestly and still drafts", () => {
    const ctx = mountTracked();
    // A loop: the first and last visits are the same place, so the line
    // cannot say which way the pattern runs (step 28).
    const hook = load(
      ctx,
      model([
        { position: 1, stop_id: "A", name: "Alpha", lat: 40.0, lon: -74.0, label: "1" },
        { position: 2, stop_id: "B", name: "Bravo", lat: 40.02, lon: -74.0, label: "2" },
        { position: 3, stop_id: "A", name: "Alpha", lat: 40.0, lon: -74.0, label: "3" },
      ]),
    );
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });
    expect(fitResults(ctx.pushed).at(-1).payload.direction).toBe("unknown");

    // An unknown direction blocks nothing: the user asked for the draft.
    ctx.pushed.length = 0;
    ctx.handlers["alignment:file_draft"]();
    expect(hook.dirtyPositions()).toEqual([1, 2]);
    expect(draftStates(ctx.pushed).at(-1).payload.dirty_positions).toEqual([1, 2]);
  });

  it("refuses a forged draft while the line is reversed", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });
    ctx.handlers["alignment:reverse_file_line"]();
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_draft"]();

    expect(hook.dirtyPositions()).toEqual([]);
    expect(draftStates(ctx.pushed).length).toBe(0);
    // The preview stays for the user to reverse back.
    expect(hook._fileLayers.length).toBeGreaterThan(0);
  });

  it("ignores a misshapen line, a reverse with no line and a draft with no line", () => {
    const ctx = mountTracked();
    const hook = load(ctx);
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_line"]({ points: [[-74.0, 40.0]] });
    ctx.handlers["alignment:file_line"]({ points: [[-74.0, 40.0], [null, 40.01]] });
    ctx.handlers["alignment:file_line"]();
    ctx.handlers["alignment:reverse_file_line"]();
    ctx.handlers["alignment:file_draft"]();

    expect(hook._fileLayers.length).toBe(0);
    expect(hook._drafts.size).toBe(0);
    expect(ctx.pushed.length).toBe(0);
  });

  it("never drafts a file line for viewers", () => {
    const ctx = mountTracked();
    const hook = load(ctx, { ...model(), editable: false });
    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });
    ctx.pushed.length = 0;

    ctx.handlers["alignment:file_draft"]();

    expect(hook._drafts.size).toBe(0);
    expect(ctx.pushed.length).toBe(0);
  });

  it("drops a stale preview when a fresh model loads", () => {
    const ctx = mountTracked();
    load(ctx);
    ctx.handlers["alignment:file_line"]({ points: FILE_LINE, name: "route.geojson" });
    expect(ctx.hook._fileLayers.length).toBeGreaterThan(0);

    load(ctx);

    expect(ctx.hook._fileLayers.length).toBe(0);
    expect(ctx.hook._fileLinePoints).toBe(null);
  });
});
