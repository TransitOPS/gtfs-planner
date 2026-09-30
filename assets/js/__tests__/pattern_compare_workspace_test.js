/* @vitest-environment jsdom */
import { afterEach, describe, expect, it, vi } from "vitest";
import PatternCompareWorkspace, {
  nextIndex,
  prevIndex,
  rowsForDifference,
} from "../pattern_compare_workspace";

// Merge evidence for the Compare patterns workspace (spec 19, step 17). The
// hook's own element is the empty, ignored anchor the LiveView renders
// (`phx-update="ignore"`); the workspace it decorates is the server-rendered
// `#compare-workspace` (summary item buttons, toolbar, stream rows, fold
// markers), so the fixture mirrors exactly that markup. jsdom has no layout,
// so these cases establish the hook's own contract: index wrapping, the
// difference selection's pressed state, row highlight and `compare:frame`,
// the Differences-mode fold toggles, hover and the map's row request. The
// rendered pixels are the journey lane's contract (EV-21); nothing here
// touches Leaflet, the network or the server.

function workspaceFixture({ mode = "diff" } = {}) {
  const folded = mode === "diff";
  document.body.innerHTML = `
    <div id="compare-two-view">
      <div
        id="compare-workspace-hook"
        phx-hook="PatternCompareWorkspace"
        phx-update="ignore"
        hidden
      ></div>
      <div id="compare-workspace">
        <section id="compare-summary">
          <button type="button" id="summary-diff-1" data-diff-index="0" data-diff-rows="1,2" data-diff-stops="S2,S3" aria-pressed="false">1</button>
          <button type="button" id="summary-diff-2" data-diff-index="1" data-diff-rows="3" data-diff-stops="S4" aria-pressed="false">2</button>
        </section>
        <section id="compare-stops" data-mode="${mode}">
          <div id="stops-mode" role="group" aria-label="Rows">
            <button type="button" id="stops-mode-all" data-mode="all" aria-pressed="${mode === "all"}">All stops</button>
            <button type="button" id="stops-mode-diff" data-mode="diff" aria-pressed="${mode === "diff"}">Differences</button>
          </div>
          <div role="group" aria-label="Move between differences">
            <button type="button" id="stops-previous" data-step="-1">Previous</button>
            <button type="button" id="stops-next" data-step="1">Next</button>
            <span id="stops-position" role="status">2 differences</span>
          </div>
          <table>
            <tbody id="compare-rows" phx-update="stream">
              <tr id="compare-row-0" data-row="0" data-stop-id="S1" data-type="same" class="border-b border-subtle hover:bg-canvas"><td><button type="button" data-select="0">S1</button></td></tr>
              <tr id="compare-fold-1-2" data-fold="1-2" class="border-b border-subtle bg-canvas" ${folded ? "" : "hidden"}><td><button type="button" data-unfold="1-2">Show 2 matching stops</button></td></tr>
              <tr id="compare-row-1" data-row="1" data-stop-id="S2" data-type="same" data-fold-range="1-2" class="border-b border-subtle hover:bg-canvas" ${folded ? "hidden" : ""}><td><button type="button" data-select="1">S2</button></td></tr>
              <tr id="compare-row-2" data-row="2" data-stop-id="S3" data-type="same" data-fold-range="1-2" class="border-b border-subtle hover:bg-canvas" ${folded ? "hidden" : ""}></tr>
              <tr id="compare-row-3" data-row="3" data-stop-id="S4" data-type="a" class="border-b border-subtle hover:bg-canvas bg-navy-300/15"><td><button type="button" data-select="3">S4</button></td><td><a href="#compare-row-5" data-goto-row="5">Go to B’s visit</a></td></tr>
              <tr id="compare-row-4" data-row="4" data-stop-id="S5" data-type="b" class="border-b border-subtle hover:bg-canvas bg-soft"><td><button type="button" data-select="4">S5</button></td></tr>
              <tr id="compare-row-5" data-row="5" data-stop-id="S5" data-type="same" class="border-b border-subtle hover:bg-canvas"><td><button type="button" data-select="5">S5</button></td></tr>
            </tbody>
          </table>
        </section>
      </div>
    </div>`;
}

let hooks = [];
let listeners = [];

function makeHook({ mode = "diff" } = {}) {
  workspaceFixture({ mode });
  const hook = Object.create(PatternCompareWorkspace);
  hook.el = document.getElementById("compare-workspace-hook");
  hook.pushEvent = vi.fn();
  hook.mounted();
  hooks.push(hook);
  return hook;
}

function collectEvents(name) {
  const details = [];
  const listener = (event) => details.push(event.detail);
  window.addEventListener(name, listener);
  listeners.push(() => window.removeEventListener(name, listener));
  return details;
}

function row(index) {
  return document.getElementById(`compare-row-${index}`);
}

function click(target) {
  target.click();
}

afterEach(() => {
  for (const hook of hooks) hook.destroyed();
  hooks = [];
  for (const remove of listeners) remove();
  listeners = [];
  document.body.innerHTML = "";
});

describe("nextIndex and prevIndex", () => {
  it("wraps in both directions", () => {
    expect(nextIndex(2, 3)).toBe(0);
    expect(prevIndex(0, 3)).toBe(2);
  });

  it("starts at the first item for Next and the last for Previous", () => {
    expect(nextIndex(null, 3)).toBe(0);
    expect(prevIndex(null, 3)).toBe(2);
  });

  it("stays on the only item and refuses an empty list", () => {
    expect(nextIndex(0, 1)).toBe(0);
    expect(prevIndex(0, 1)).toBe(0);
    expect(nextIndex(0, 0)).toBeNull();
    expect(prevIndex(0, 0)).toBeNull();
  });
});

describe("rowsForDifference", () => {
  it("reads the comma-separated row indexes", () => {
    expect(rowsForDifference("1,2")).toEqual([1, 2]);
    expect(rowsForDifference("3")).toEqual([3]);
  });

  it("returns no rows for a missing attribute", () => {
    expect(rowsForDifference("")).toEqual([]);
    expect(rowsForDifference(undefined)).toEqual([]);
  });
});

describe("difference selection", () => {
  it("marks the item pressed, highlights its rows and frames the map", () => {
    const frames = collectEvents("compare:frame");
    const hook = makeHook();

    click(document.getElementById("summary-diff-1"));

    expect(document.getElementById("summary-diff-1").getAttribute("aria-pressed")).toBe("true");
    expect(document.getElementById("summary-diff-2").getAttribute("aria-pressed")).toBe("false");
    expect(row(1).classList.contains("bg-selection")).toBe(true);
    expect(row(2).classList.contains("bg-selection")).toBe(true);
    expect(document.getElementById("stops-position").textContent).toBe("Difference 1 of 2");
    expect(frames).toEqual([{ stopIds: ["S2", "S3"] }]);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("opens the fold hiding a difference's rows", () => {
    makeHook();
    expect(row(1).hidden).toBe(true);

    click(document.getElementById("summary-diff-1"));

    expect(row(1).hidden).toBe(false);
    expect(row(2).hidden).toBe(false);
    expect(document.getElementById("compare-fold-1-2").hidden).toBe(true);
  });

  it("swaps the series tint for the highlight class and restores it", () => {
    makeHook();

    click(document.getElementById("summary-diff-2"));
    expect(row(3).classList.contains("bg-selection")).toBe(true);
    expect(row(3).classList.contains("bg-navy-300/15")).toBe(false);

    click(document.getElementById("summary-diff-1"));
    expect(row(3).classList.contains("bg-selection")).toBe(false);
    expect(row(3).classList.contains("bg-navy-300/15")).toBe(true);
  });

  it("cycles with Previous and Next, wrapping at both ends", () => {
    const frames = collectEvents("compare:frame");
    makeHook();

    click(document.getElementById("stops-next"));
    expect(document.getElementById("stops-position").textContent).toBe("Difference 1 of 2");

    click(document.getElementById("stops-next"));
    expect(document.getElementById("stops-position").textContent).toBe("Difference 2 of 2");

    click(document.getElementById("stops-next"));
    expect(document.getElementById("stops-position").textContent).toBe("Difference 1 of 2");

    click(document.getElementById("stops-previous"));
    expect(document.getElementById("stops-position").textContent).toBe("Difference 2 of 2");
    expect(frames.map((frame) => frame.stopIds)).toEqual([["S2", "S3"], ["S4"], ["S2", "S3"], ["S4"]]);
  });

  it("re-applies the highlight after a server patch", () => {
    const hook = makeHook();
    click(document.getElementById("summary-diff-2"));
    expect(row(3).classList.contains("bg-selection")).toBe(true);

    row(3).classList.remove("bg-selection");
    row(3).classList.add("bg-navy-300/15");
    hook.updated();

    expect(row(3).classList.contains("bg-selection")).toBe(true);
    expect(row(3).classList.contains("bg-navy-300/15")).toBe(false);
  });

  it("drops a selection a reload no longer offers", () => {
    const hook = makeHook();
    click(document.getElementById("summary-diff-2"));
    expect(document.getElementById("stops-position").textContent).toBe("Difference 2 of 2");

    document.getElementById("summary-diff-2").remove();
    hook.updated();

    expect(document.getElementById("stops-position").textContent).toBe("1 difference");
    expect(row(3).classList.contains("bg-selection")).toBe(false);
  });
});

describe("rows mode and folds", () => {
  it("hides folded rows in Differences and reveals them in All stops", () => {
    makeHook();
    const marker = document.getElementById("compare-fold-1-2");

    expect(marker.hidden).toBe(false);
    expect(row(1).hidden).toBe(true);

    click(document.getElementById("stops-mode-all"));
    expect(document.getElementById("compare-stops").dataset.mode).toBe("all");
    expect(document.getElementById("stops-mode-all").getAttribute("aria-pressed")).toBe("true");
    expect(document.getElementById("stops-mode-diff").getAttribute("aria-pressed")).toBe("false");
    expect(marker.hidden).toBe(true);
    expect(row(1).hidden).toBe(false);

    click(document.getElementById("stops-mode-diff"));
    expect(marker.hidden).toBe(false);
    expect(row(1).hidden).toBe(true);
  });

  it("reveals a fold's rows and keeps them open across mode switches", () => {
    makeHook();
    const marker = document.getElementById("compare-fold-1-2");

    click(document.querySelector('button[data-unfold="1-2"]'));
    expect(marker.hidden).toBe(true);
    expect(row(1).hidden).toBe(false);
    expect(row(2).hidden).toBe(false);

    click(document.getElementById("stops-mode-all"));
    expect(row(1).hidden).toBe(false);

    click(document.getElementById("stops-mode-diff"));
    expect(marker.hidden).toBe(true);
    expect(row(1).hidden).toBe(false);
  });
});

describe("hover", () => {
  it("dispatches compare:hot with the row's stop and clears it on leave", () => {
    const hot = collectEvents("compare:hot");
    makeHook();

    row(0).dispatchEvent(new MouseEvent("mouseenter"));
    expect(hot).toEqual([{ stopId: "S1" }]);

    row(0).dispatchEvent(new MouseEvent("mouseleave"));
    expect(hot).toEqual([{ stopId: "S1" }, { stopId: null }]);
  });

  it("binds every row once, even after an update", () => {
    const hot = collectEvents("compare:hot");
    const hook = makeHook();
    hook.updated();

    row(4).dispatchEvent(new MouseEvent("mouseenter"));

    expect(hot).toEqual([{ stopId: "S5" }]);
  });
});

describe("map to row selection", () => {
  it("selects the first row with the requested stop", () => {
    const selections = collectEvents("compare:select-stop");
    makeHook();

    window.dispatchEvent(new CustomEvent("compare:row-for-stop", { detail: { stopId: "S5" } }));

    expect(row(4).classList.contains("bg-selection")).toBe(true);
    expect(row(5).classList.contains("bg-selection")).toBe(false);
    expect(selections).toEqual([{ stopId: "S5" }]);
  });

  it("stops listening after destroy", () => {
    const selections = collectEvents("compare:select-stop");
    const hook = makeHook();
    hook.destroyed();

    window.dispatchEvent(new CustomEvent("compare:row-for-stop", { detail: { stopId: "S5" } }));

    expect(row(4).classList.contains("bg-selection")).toBe(false);
    expect(selections).toEqual([]);
  });
});

describe("row selection and the moved link", () => {
  it("selects a row through its button and dispatches compare:select-stop", () => {
    const selections = collectEvents("compare:select-stop");
    makeHook();

    click(document.querySelector('button[data-select="3"]'));

    expect(row(3).classList.contains("bg-selection")).toBe(true);
    expect(row(3).classList.contains("bg-navy-300/15")).toBe(false);
    expect(selections).toEqual([{ stopId: "S4" }]);
  });

  it("reveals a folded row when its select button is used", () => {
    makeHook();
    expect(row(1).hidden).toBe(true);

    click(document.querySelector('button[data-select="1"]'));

    expect(row(1).hidden).toBe(false);
    expect(row(1).classList.contains("bg-selection")).toBe(true);
  });

  it("goes to the moved partner without changing the URL hash", () => {
    const selections = collectEvents("compare:select-stop");
    makeHook();
    const link = document.querySelector("a[data-goto-row]");
    const event = new MouseEvent("click", { bubbles: true, cancelable: true });

    link.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(row(5).classList.contains("bg-selection")).toBe(true);
    expect(selections).toEqual([{ stopId: "S5" }]);
  });
});

describe("server events", () => {
  it("never calls this.pushEvent", () => {
    const hook = makeHook();

    click(document.getElementById("summary-diff-1"));
    click(document.getElementById("stops-next"));
    click(document.getElementById("stops-mode-all"));
    click(document.querySelector('button[data-unfold="1-2"]'));
    click(document.querySelector('button[data-select="3"]'));
    row(0).dispatchEvent(new MouseEvent("mouseenter"));
    window.dispatchEvent(new CustomEvent("compare:row-for-stop", { detail: { stopId: "S1" } }));

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });
});
