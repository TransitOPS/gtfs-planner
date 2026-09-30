/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import TimetableGrid from "../timetable_grid_hook.js";

// Two pattern sections, each with its own focusable table region: three rows in
// the first and two in the second. Cell ids, data-trip and data-pos mirror the
// production markup from step 21; every cell renders tabindex="-1".
function row(trip, id) {
  return `
    <tr id="trip-${id}">
      <td id="cell-${id}-1" data-trip="${trip}" data-pos="1" tabindex="-1">07:15</td>
      <td id="cell-${id}-2" data-trip="${trip}" data-pos="2" tabindex="-1">07:26</td>
      <td id="cell-${id}-3" data-trip="${trip}" data-pos="3" tabindex="-1">07:33</td>
      <td id="cell-${id}-timing" data-trip="${trip}" tabindex="-1">Base</td>
    </tr>`;
}

const ROWS_A = row("trip-a1", "A1") + row("trip-a2", "A2") + row("trip-a3", "A3");
const ROWS_A_WITHOUT_A3 = row("trip-a1", "A1") + row("trip-a2", "A2");
const ROWS_B = row("trip-b1", "B1") + row("trip-b2", "B2");

function section(name, rows) {
  return `
    <section aria-labelledby="section-${name}-heading">
      <h2 id="section-${name}-heading">${name}</h2>
      <div id="section-${name}-table-container" tabindex="0" role="region" aria-label="${name} timetable">
        <table id="section-${name}-table">
          <tbody>${rows}</tbody>
        </table>
      </div>
    </section>`;
}

function grid({ rowsA = ROWS_A } = {}) {
  document.body.innerHTML = `
    <main>
      <div id="schedules-grid" phx-hook="TimetableGrid" data-grid-revision="0">
        <div id="schedules-sections" phx-update="stream">
          <div id="sections-a">${section("A", rowsA)}</div>
          <div id="sections-b">${section("B", ROWS_B)}</div>
        </div>
        <div id="cell-editor" phx-update="ignore"></div>
      </div>
      <button id="outside-tab" type="button">Outside</button>
    </main>`;

  const el = document.getElementById("schedules-grid");
  const hook = Object.create(TimetableGrid);
  hook.el = el;
  hook.mounted();

  return { el, hook };
}

function keydown(target, key, init = {}) {
  const event = new KeyboardEvent("keydown", {
    key,
    bubbles: true,
    cancelable: true,
    ...init,
  });
  target.dispatchEvent(event);
  return event;
}

function focus(id) {
  const target = document.getElementById(id);
  target.click();
  return target;
}

describe("TimetableGrid navigation", () => {
  let scrollCalls;

  beforeEach(() => {
    document.body.innerHTML = "";
    scrollCalls = [];
    Element.prototype.scrollIntoView = function (options) {
      scrollCalls.push({ target: this, options });
    };
  });

  afterEach(() => {
    delete Element.prototype.scrollIntoView;
  });

  it("ArrowRight and ArrowDown move tabindex 0 and focus to the neighbouring cell", () => {
    grid();
    const start = focus("cell-A1-2");
    expect(document.activeElement).toBe(start);

    keydown(start, "ArrowRight");

    const right = document.getElementById("cell-A1-3");
    expect(document.activeElement).toBe(right);
    expect(right.getAttribute("tabindex")).toBe("0");
    expect(start.getAttribute("tabindex")).toBe("-1");

    keydown(right, "ArrowDown");

    const down = document.getElementById("cell-A2-3");
    expect(document.activeElement).toBe(down);
    expect(down.getAttribute("tabindex")).toBe("0");
    expect(right.getAttribute("tabindex")).toBe("-1");
  });

  it("ArrowDown on the last row of a section moves into the next section's first row", () => {
    grid();
    const last = focus("cell-A3-2");

    keydown(last, "ArrowDown");

    const first = document.getElementById("cell-B1-2");
    expect(document.activeElement).toBe(first);
    expect(first.getAttribute("tabindex")).toBe("0");
    expect(last.getAttribute("tabindex")).toBe("-1");
  });

  it("After updated() with re-rendered cells, focus returns to the same data-trip/data-pos (FH-39)", () => {
    const { hook } = grid();
    const replaced = focus("cell-A2-2");
    const trip = replaced.dataset.trip;
    const pos = replaced.dataset.pos;

    hook.beforeUpdate();
    document.getElementById("sections-a").innerHTML = section("A", ROWS_A);
    expect(document.activeElement).not.toBe(replaced);

    hook.updated();

    const restored = document.getElementById("cell-A2-2");
    expect(restored).not.toBe(replaced);
    expect(restored.dataset.trip).toBe(trip);
    expect(restored.dataset.pos).toBe(pos);
    expect(document.activeElement).toBe(restored);
    expect(restored.getAttribute("tabindex")).toBe("0");
    expect(document.querySelectorAll('#schedules-grid td[tabindex="0"]').length).toBe(1);
  });

  it("Tab keydown is not prevented (leaves the grid)", () => {
    grid();
    const cell = focus("cell-A1-1");

    const event = keydown(cell, "Tab");

    expect(event.defaultPrevented).toBe(false);
    expect(document.activeElement).toBe(cell);
  });

  it("Home and End reach the row's first and last cells", () => {
    grid();
    const cell = focus("cell-A1-2");

    keydown(cell, "End");
    expect(document.activeElement).toBe(document.getElementById("cell-A1-timing"));

    keydown(document.getElementById("cell-A1-timing"), "Home");
    expect(document.activeElement).toBe(document.getElementById("cell-A1-1"));
  });

  it("Cmd/Ctrl+ArrowUp and Cmd/Ctrl+ArrowDown reach the first and last row", () => {
    grid();
    const cell = focus("cell-A2-1");

    keydown(cell, "ArrowDown", { ctrlKey: true });
    expect(document.activeElement).toBe(document.getElementById("cell-B2-1"));

    keydown(document.getElementById("cell-B2-1"), "ArrowUp", { metaKey: true });
    expect(document.activeElement).toBe(document.getElementById("cell-A1-1"));
  });

  it("PageDown moves by the rows the table region shows", () => {
    grid();
    const cell = focus("cell-A1-2");
    const region = document.getElementById("section-A-table-container");
    Object.defineProperty(region, "clientHeight", { value: 300, configurable: true });
    document.getElementById("trip-A1").getBoundingClientRect = () => ({ height: 100 });

    keydown(cell, "PageDown");

    expect(document.activeElement).toBe(document.getElementById("cell-B1-2"));
  });

  it("Clicking a cell moves the cursor and its ring", () => {
    const { el } = grid();
    expect(el.classList.contains("grid-idle")).toBe(true);

    const cell = document.getElementById("cell-B2-2");
    cell.click();

    expect(el.classList.contains("grid-idle")).toBe(false);
    expect(cell.classList.contains("is-cursor")).toBe(true);
    expect(cell.getAttribute("tabindex")).toBe("0");
    expect(document.querySelectorAll("#schedules-grid .is-cursor").length).toBe(1);
  });

  it("Movement scrolls the cursor cell into view with nearest alignment", () => {
    grid();
    const start = focus("cell-A1-2");
    scrollCalls.length = 0;

    keydown(start, "ArrowRight");

    const right = document.getElementById("cell-A1-3");
    expect(scrollCalls).toEqual([{ target: right, options: { block: "nearest" } }]);
  });

  it("updated() re-applies the cursor without taking focus the grid did not hold", () => {
    const { hook } = grid();
    focus("cell-A2-2");
    const outside = document.getElementById("outside-tab");
    outside.focus();

    hook.beforeUpdate();
    document.getElementById("sections-a").innerHTML = section("A", ROWS_A);
    hook.updated();

    expect(document.activeElement).toBe(outside);
    const restored = document.getElementById("cell-A2-2");
    expect(restored.getAttribute("tabindex")).toBe("0");
    expect(restored.classList.contains("is-cursor")).toBe(true);
  });

  it("updated() falls back to the same row index when the remembered trip is gone", () => {
    const { hook } = grid();
    focus("cell-A3-2");

    hook.beforeUpdate();
    document.getElementById("sections-a").innerHTML = section("A", ROWS_A_WITHOUT_A3);
    hook.updated();

    expect(document.activeElement).toBe(document.getElementById("cell-B1-2"));
  });

  it("A navigation key on the table region enters the grid at that section's first cell", () => {
    grid();
    const region = document.getElementById("section-B-table-container");
    region.focus();

    keydown(region, "ArrowUp");

    const first = document.getElementById("cell-B1-1");
    expect(document.activeElement).toBe(first);
    expect(first.getAttribute("tabindex")).toBe("0");
  });

  it("destroyed() stops listening", () => {
    const { hook } = grid();
    const cell = focus("cell-A1-1");
    hook.destroyed();

    const event = keydown(cell, "ArrowRight");

    expect(event.defaultPrevented).toBe(false);
    expect(document.activeElement).toBe(cell);
  });
});
