/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import TimetableGrid from "../timetable_grid_hook.js";

// One pattern section with three listed trips and, for the frequency cases, a
// frequency trip. Cell ids, data-trip and data-pos mirror the production markup
// from step 21: a stop cell wraps the clock in a `tabular-nums` span, the
// timing cell carries no occurrence position and a frequency row names itself
// with `[id$="-frequency"]`. The text field and the dialog are the R12 guard
// subjects: a field or dialog keeps every key (production renders drawers
// outside the grid; they are nested here so the guard itself is exercised).
function cell(trip, id, pos, text) {
  return `
    <td id="cell-${id}-${pos}" data-trip="${trip}" data-pos="${pos}" tabindex="-1">
      <span><span class="tabular-nums">${text}</span></span>
    </td>`;
}

function row(trip, id, { frequency = false } = {}) {
  return `
    <tr id="trip-${id}">
      ${cell(trip, id, 1, "07:15")}
      ${cell(trip, id, 2, "07:26")}
      ${cell(trip, id, 3, "07:33")}
      <td id="cell-${id}-timing" data-trip="${trip}" tabindex="-1">
        <span>Base</span>
        ${frequency ? `<span id="trip-${id}-frequency">Frequency service · every 15 min</span>` : ""}
      </td>
    </tr>`;
}

const LISTED = row("trip-a1", "A1") + row("trip-a2", "A2") + row("trip-a3", "A3");
const WITH_FREQUENCY = row("trip-a1", "A1") + row("trip-a2", "A2") + row("trip-f1", "F1", { frequency: true });

function grid({ rows = LISTED } = {}) {
  document.body.innerHTML = `
    <main>
      <div id="schedules-grid" phx-hook="TimetableGrid" data-grid-revision="0">
        <div id="grid-filter">
          <input id="grid-filter-input" type="text" aria-label="Filter trips" />
        </div>
        <div id="schedules-sections" phx-update="stream">
          <div id="sections-a">
            <section aria-labelledby="section-a-heading">
              <h2 id="section-a-heading">Pattern A</h2>
              <div id="section-a-table-container" tabindex="0" role="region" aria-label="A timetable">
                <table id="section-a-table"><tbody>${rows}</tbody></table>
              </div>
            </section>
          </div>
        </div>
        <div id="cell-editor" phx-update="ignore"></div>
        <div id="grid-drawer" role="dialog" aria-label="Trip drawer">
          <input id="drawer-input" type="text" />
        </div>
      </div>
      <button id="outside-tab" type="button">Outside</button>
    </main>`;

  const el = document.getElementById("schedules-grid");
  const hook = Object.create(TimetableGrid);
  hook.el = el;
  hook.pushEvent = vi.fn();
  hook.mounted();

  return { el, hook, editor: document.getElementById("cell-editor") };
}

function keydown(target, key, init = {}) {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(event);
  return event;
}

function paste(target, text) {
  const event = new Event("paste", { bubbles: true, cancelable: true });
  event.clipboardData = { getData: () => text };
  target.dispatchEvent(event);
  return event;
}

// Focus a cell the way a pointer does, so the cursor sits on it.
function cursor(id) {
  const cell = document.getElementById(id);
  cell.click();
  expect(document.activeElement).toBe(cell);
  return cell;
}

function names(hook) {
  return hook.pushEvent.mock.calls.map((call) => call[0]);
}

function params(hook, index) {
  return hook.pushEvent.mock.calls[index][1];
}

describe("TimetableGrid shortcuts", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = "";
    Element.prototype.scrollIntoView = function () {};
  });

  afterEach(() => {
    vi.useRealTimers();
    delete Element.prototype.scrollIntoView;
    vi.restoreAllMocks();
  });

  it("`]` in an input inside the grid and in a drawer pushes nothing (FH-36)", () => {
    const { hook } = grid();
    cursor("cell-A1-2");

    const filter = document.getElementById("grid-filter-input");
    filter.focus();
    const fieldEvent = keydown(filter, "]");
    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(fieldEvent.defaultPrevented).toBe(false);

    const drawerField = document.getElementById("drawer-input");
    drawerField.focus();
    keydown(drawerField, "]");
    expect(hook.pushEvent).not.toHaveBeenCalled();

    // The dialog container itself is guarded, so `?` cannot open the sheet
    // while a drawer holds focus.
    keydown(document.getElementById("grid-drawer"), "?");
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("AltGr (Ctrl+Alt) on `]` nudges the cursor trip one minute later (FH-37)", () => {
    const { hook } = grid();
    const cell = cursor("cell-A1-2");

    const event = keydown(cell, "]", { ctrlKey: true, altKey: true });

    expect(event.defaultPrevented).toBe(true);
    expect(names(hook)).toEqual(["nudge"]);
    expect(params(hook, 0)).toEqual({ minutes: 1, trip: "trip-a1" });
  });

  it("Meta with a bracket stays with the browser: `[` pushes nothing and is not prevented (FH-38)", () => {
    const { hook } = grid();
    cursor("cell-A1-2");

    const event = keydown(document.getElementById("cell-A1-2"), "[", { metaKey: true });

    expect(event.defaultPrevented).toBe(false);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("`}` nudges five minutes later and Cmd+S is prevented and pushes save_shortcut", () => {
    const { hook } = grid();
    const cell = cursor("cell-A1-2");

    keydown(cell, "}");
    expect(names(hook)).toEqual(["nudge"]);
    expect(params(hook, 0)).toEqual({ minutes: 5, trip: "trip-a1" });

    const save = keydown(cell, "s", { metaKey: true });
    expect(save.defaultPrevented).toBe(true);
    expect(names(hook)).toEqual(["nudge", "save_shortcut"]);
    expect(params(hook, 1)).toEqual({});
  });

  it("Space toggles the cursor row and is prevented", () => {
    const { hook } = grid();
    const cell = cursor("cell-A1-2");

    const event = keydown(cell, " ");

    expect(event.defaultPrevented).toBe(true);
    expect(names(hook)).toEqual(["toggle_trip"]);
    expect(params(hook, 0)).toEqual({ trip: "trip-a1" });
  });

  it("every bracket face pushes its literal minute delta for the cursor row", () => {
    const { hook } = grid();
    const cell = cursor("cell-A2-2");

    keydown(cell, "]");
    keydown(cell, "[");
    keydown(cell, "}");
    keydown(cell, "{");

    expect(hook.pushEvent.mock.calls.map((call) => call[1])).toEqual([
      { minutes: 1, trip: "trip-a2" },
      { minutes: -1, trip: "trip-a2" },
      { minutes: 5, trip: "trip-a2" },
      { minutes: -5, trip: "trip-a2" },
    ]);
  });

  it("a bracket on the table region, not a cell, pushes nothing", () => {
    const { hook } = grid();
    cursor("cell-A1-2");

    const event = keydown(document.getElementById("section-a-table-container"), "]");

    expect(event.defaultPrevented).toBe(false);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("Shift+ArrowDown pushes select_range and moves the cursor down a row", () => {
    const { hook } = grid();
    const cell = cursor("cell-A1-2");

    const event = keydown(cell, "ArrowDown", { shiftKey: true });

    expect(event.defaultPrevented).toBe(true);
    expect(names(hook)).toEqual(["select_range"]);
    expect(params(hook, 0)).toEqual({ from: "trip-a1", to: "trip-a2" });
    expect(document.activeElement).toBe(document.getElementById("cell-A2-2"));
  });

  it("repeated Shift+ArrowDown extends the range from the first row", () => {
    const { hook } = grid();
    keydown(cursor("cell-A1-2"), "ArrowDown", { shiftKey: true });
    keydown(document.getElementById("cell-A2-2"), "ArrowDown", { shiftKey: true });

    expect(names(hook)).toEqual(["select_range", "select_range"]);
    expect(params(hook, 1)).toEqual({ from: "trip-a1", to: "trip-a3" });
    expect(document.activeElement).toBe(document.getElementById("cell-A3-2"));
  });

  it("an anchor set by Space persists across unshifted moves for a later range", () => {
    const { hook } = grid();

    keydown(cursor("cell-A1-2"), " ");
    keydown(document.getElementById("cell-A1-2"), "ArrowDown");
    keydown(document.getElementById("cell-A2-2"), "ArrowDown");
    keydown(document.getElementById("cell-A3-2"), "ArrowUp", { shiftKey: true });

    expect(names(hook)).toEqual(["toggle_trip", "select_range"]);
    expect(params(hook, 1)).toEqual({ from: "trip-a1", to: "trip-a2" });
  });

  it("Cmd/Ctrl+A selects every visible row, Cmd/Ctrl+C copies and Cmd/Ctrl+Z undoes", () => {
    const { hook } = grid();
    const cell = cursor("cell-A1-2");

    const selectAll = keydown(cell, "a", { ctrlKey: true });
    const copy = keydown(cell, "c", { metaKey: true });
    const undo = keydown(cell, "z", { metaKey: true });

    expect([selectAll.defaultPrevented, copy.defaultPrevented, undo.defaultPrevented]).toEqual([
      true,
      true,
      true,
    ]);
    expect(names(hook)).toEqual(["select_all", "copy_trips", "undo"]);
    expect(hook.pushEvent.mock.calls.map((call) => call[1])).toEqual([{}, {}, {}]);
  });

  it("Cmd/Ctrl+Shift+Z (redo) pushes nothing", () => {
    const { hook } = grid();
    cursor("cell-A1-2");

    const event = keydown(document.getElementById("cell-A1-2"), "z", {
      metaKey: true,
      shiftKey: true,
    });

    expect(event.defaultPrevented).toBe(false);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("Cmd+Z while the editor is open keeps the field's own undo", () => {
    const { hook, editor } = grid();
    keydown(cursor("cell-A1-2"), "7");
    expect(editor.classList.contains("is-open")).toBe(true);

    const event = keydown(editor.querySelector("input"), "z", { metaKey: true });

    expect(event.defaultPrevented).toBe(false);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("`?` and Cmd/Ctrl+/ push toggle_shortcuts, from a cell and from the region", () => {
    const { hook } = grid();
    const cell = cursor("cell-A1-2");

    const question = keydown(cell, "?");
    const chord = keydown(cell, "/", { metaKey: true });
    const region = keydown(document.getElementById("section-a-table-container"), "?");

    expect([question.defaultPrevented, chord.defaultPrevented, region.defaultPrevented]).toEqual([
      true,
      true,
      true,
    ]);
    expect(names(hook)).toEqual(["toggle_shortcuts", "toggle_shortcuts", "toggle_shortcuts"]);
  });

  it("Enter on the Timing cell pushes open_change and does not open the editor", () => {
    const { hook, editor } = grid();

    const event = keydown(cursor("cell-A1-timing"), "Enter");

    expect(event.defaultPrevented).toBe(true);
    expect(names(hook)).toEqual(["open_change"]);
    expect(params(hook, 0)).toEqual({ kind: "timing", trip: "trip-a1" });
    expect(editor.classList.contains("is-open")).toBe(false);
  });

  it("Enter on a frequency row pushes open_edit_drawer instead of editing", () => {
    const { hook, editor } = grid({ rows: WITH_FREQUENCY });

    const event = keydown(cursor("cell-F1-2"), "Enter");

    expect(event.defaultPrevented).toBe(true);
    expect(names(hook)).toEqual(["open_edit_drawer"]);
    expect(params(hook, 0)).toEqual({ trip: "trip-f1" });
    expect(editor.classList.contains("is-open")).toBe(false);
  });

  it("Enter on a frequency row's Timing cell opens the Change timing strip", () => {
    const { hook } = grid({ rows: WITH_FREQUENCY });

    keydown(cursor("cell-F1-timing"), "Enter");

    expect(names(hook)).toEqual(["open_change"]);
    expect(params(hook, 0)).toEqual({ kind: "timing", trip: "trip-f1" });
  });

  it("Enter on a listed stop cell still opens the editor (step 23 preserved)", () => {
    const { hook, editor } = grid();

    keydown(cursor("cell-A1-2"), "Enter");

    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(editor.classList.contains("is-open")).toBe(true);
    expect(editor.querySelector("input").value).toBe("07:26");
  });

  it("a paste on a stop cell asks for the page clipboard and reports spreadsheet text", () => {
    const { hook } = grid();
    hook.pushEvent = vi.fn((name, _params, callback) => {
      if (name === "paste_trips" && callback) callback({ clipboard: false });
    });

    const event = paste(cursor("cell-A1-2"), "07:15\t07:26");

    expect(event.defaultPrevented).toBe(true);
    expect(names(hook)).toEqual(["paste_trips", "paste_text"]);
    expect(hook.pushEvent.mock.calls.map((call) => call[1])).toEqual([{}, {}]);
  });

  it("a paste with an empty system clipboard asks for the page clipboard only", () => {
    const { hook } = grid();
    hook.pushEvent = vi.fn((name, _params, callback) => {
      if (name === "paste_trips" && callback) callback({ clipboard: false });
    });

    paste(cursor("cell-A1-2"), "");

    expect(names(hook)).toEqual(["paste_trips"]);
  });

  it("a paste with the page clipboard set opens the paste flow once", () => {
    const { hook } = grid();
    hook.pushEvent = vi.fn((name, _params, callback) => {
      if (name === "paste_trips" && callback) callback({ clipboard: true });
    });

    paste(cursor("cell-A1-2"), "07:15\t07:26");

    expect(names(hook)).toEqual(["paste_trips"]);
  });

  it("a paste inside a field pushes nothing", () => {
    const { hook } = grid();
    cursor("cell-A1-2");

    const filter = document.getElementById("grid-filter-input");
    filter.focus();
    const event = paste(filter, "07:15");

    expect(event.defaultPrevented).toBe(false);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });
});
