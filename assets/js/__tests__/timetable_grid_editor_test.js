/* @vitest-environment jsdom */
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import TimetableGrid from "../timetable_grid_hook.js";

// One pattern section with two listed trips and one frequency trip. Cell ids,
// data-trip and data-pos mirror the production markup from step 21: a stop cell
// wraps the clock in a `tabular-nums` span, the day marker is its own span, the
// timing cell carries no occurrence position and a frequency row names itself.
function cell(trip, id, pos, text, { marker = "", title = null, flags = "" } = {}) {
  const titleAttribute = title ? ` title="${title}"` : "";
  const markerHtml = marker ? `<span class="ml-1 text-[12px] text-muted">${marker}</span>` : "";

  return `
    <td id="cell-${id}-${pos}" data-trip="${trip}" data-pos="${pos}" tabindex="-1"${titleAttribute}${flags}>
      <span><span class="tabular-nums">${text}</span>${markerHtml}</span>
    </td>`;
}

function row(trip, id, { frequency = false } = {}) {
  return `
    <tr id="trip-${id}"${frequency ? " data-frequency" : ""}>
      ${cell(trip, id, 1, "07:15")}
      ${cell(trip, id, 2, "07:26")}
      ${cell(trip, id, 3, "07:33", { marker: "+1 day" })}
      <td id="cell-${id}-timing" data-trip="${trip}" tabindex="-1">
        <span>Base</span>
        ${frequency ? `<span id="trip-${id}-frequency">Frequency service · every 15 min</span>` : ""}
      </td>
    </tr>`;
}

const LISTED_A = row("trip-a1", "A1");
const LISTED_B = row("trip-a2", "A2");
const FREQUENCY = row("trip-f1", "F1", { frequency: true });

function grid({ rows = LISTED_A + LISTED_B + FREQUENCY } = {}) {
  document.body.innerHTML = `
    <main>
      <div id="schedules-grid" phx-hook="TimetableGrid" data-grid-revision="0">
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

// Focus a cell the way a pointer does, so the cursor sits on it.
function cursor(id) {
  const cell = document.getElementById(id);
  cell.click();
  expect(document.activeElement).toBe(cell);
  return cell;
}

function input(editor) {
  return editor.querySelector("input");
}

function type(editor, value) {
  const field = input(editor);
  field.value = value;
  field.dispatchEvent(new Event("input", { bubbles: true }));
  return field;
}

function reading(editor) {
  return editor.querySelector(".cell-reading-value").textContent.replace(/\s+/g, " ").trim();
}

function keys(editor) {
  return editor.querySelector(".cell-reading-keys").textContent.replace(/\s+/g, " ").trim();
}

function call(index, hook) {
  const call = hook.pushEvent.mock.calls[index];
  return { name: call[0], params: call[1], reply: call[2] };
}

describe("TimetableGrid in-cell editor", () => {
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

  it("typing 7 on a cursor cell opens the editor holding 7", () => {
    const { editor } = grid();

    keydown(cursor("cell-A1-2"), "7");

    const field = input(editor);
    expect(editor.classList.contains("is-open")).toBe(true);
    expect(field.value).toBe("7");
    expect(document.activeElement).toBe(field);
    expect(field.getAttribute("aria-label")).toBe("Time at this stop");
    expect(field.getAttribute("aria-describedby")).toBe("cell-reading");
    expect(field.className).toContain("min-h-11");
    expect(field.className).toContain("text-right");
    expect(field.className).toContain("tabular-nums");
    expect(field.className).toContain("outline-focus");
  });

  it("two keystrokes within 150 ms send one cell_preview, with the trip, position and text", () => {
    const { hook, editor } = grid();

    keydown(cursor("cell-A1-2"), "7");
    type(editor, "73");
    vi.advanceTimersByTime(149);
    expect(hook.pushEvent).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);

    const preview = call(0, hook);
    expect(preview.name).toBe("cell_preview");
    expect(preview.params).toEqual({ trip: "trip-a1", position: 2, text: "73" });

    vi.advanceTimersByTime(300);
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
  });

  it("the preview reply fills the reading line and a refusal shows its message (AC-1)", () => {
    const { hook, editor } = grid();
    keydown(cursor("cell-A1-2"), "7");
    vi.advanceTimersByTime(150);

    const preview = call(0, hook);
    expect(preview.name).toBe("cell_preview");
    preview.reply({
      ok: true,
      reading: "19:05",
      note: "12:05 AM next day",
      effect: "later stops move +12 min",
    });

    expect(reading(editor)).toBe("Reads as 19:05 (12:05 AM next day) · later stops move +12 min");
    expect(editor.classList.contains("is-error")).toBe(false);

    type(editor, "7:75");
    vi.advanceTimersByTime(150);
    const refused = call(1, hook);
    refused.reply({ ok: false, message: "7:75 isn't a time. Type 7:45, 745 or +3." });

    expect(reading(editor)).toBe("7:75 isn't a time. Type 7:45, 745 or +3.");
    expect(editor.classList.contains("is-error")).toBe(true);

    // Typing again clears the refused state while the new reading is on its way.
    type(editor, "7:45");
    expect(editor.classList.contains("is-error")).toBe(false);
    expect(reading(editor)).toBe("");
  });

  it("Enter sends mode later, Alt+Enter only, Ctrl+Enter and Meta+Enter anchor", () => {
    const cases = [
      [{ key: "Enter" }, "later"],
      [{ key: "Enter", altKey: true }, "only"],
      [{ key: "Enter", ctrlKey: true }, "anchor"],
      [{ key: "Enter", metaKey: true }, "anchor"],
    ];

    for (const [init, mode] of cases) {
      const { hook, editor } = grid();
      keydown(cursor("cell-A1-2"), "7");
      type(editor, "7:28");

      keydown(input(editor), init.key, init);

      const commit = call(hook.pushEvent.mock.calls.length - 1, hook);
      expect(commit.name).toBe("cell_commit");
      expect(commit.params).toEqual({ trip: "trip-a1", position: 2, text: "7:28", mode });
    }
  });

  it("Esc closes the editor, sends nothing and puts focus back on the cursor cell", () => {
    const { hook, editor } = grid();
    const cell = cursor("cell-A1-2");
    keydown(cell, "7");
    type(editor, "7:28");

    keydown(input(editor), "Escape");

    expect(editor.classList.contains("is-open")).toBe(false);
    expect(document.activeElement).toBe(cell);
    expect(cell.classList.contains("is-cursor")).toBe(true);
    expect(cell.getAttribute("tabindex")).toBe("0");

    vi.advanceTimersByTime(1000);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("a ] keydown inside the editor pushes nothing (FH-36)", () => {
    const { hook, editor } = grid();
    keydown(cursor("cell-A1-2"), "7");

    const field = input(editor);
    keydown(field, "]");
    keydown(field, "[");
    keydown(field, "}");

    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(editor.classList.contains("is-open")).toBe(true);
  });

  it("a ] keydown in another field inside the grid pushes nothing (FH-36)", () => {
    const { el, hook } = grid();
    const field = document.createElement("input");
    field.id = "grid-filter";
    el.prepend(field);
    cursor("cell-A1-2");

    keydown(field, "]");

    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("Enter and F2 open the editor on the cell's shown clock, without the day marker", () => {
    const { editor } = grid();
    const cell = cursor("cell-A1-3");

    keydown(cell, "Enter");
    expect(input(editor).value).toBe("07:33");

    keydown(input(editor), "Escape");
    keydown(cell, "F2");
    expect(input(editor).value).toBe("07:33");
  });

  it("a missing time opens the editor empty and keeps the hint instead of asking the server", () => {
    const { hook, editor } = grid({
      rows: `
        <tr id="trip-A1">
          ${cell("trip-a1", "A1", 1, "07:15")}
          ${cell("trip-a1", "A1", 2, "—")}
          <td id="cell-A1-timing" data-trip="trip-a1" tabindex="-1"><span>Base</span></td>
        </tr>`,
    });
    keydown(cursor("cell-A1-2"), "Enter");

    expect(input(editor).value).toBe("");
    expect(reading(editor)).toBe("Type 605, 6:05p, 25:10 or +3");

    vi.advanceTimersByTime(1000);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("the first column names only Enter and Esc, other stops name every commit key", () => {
    const { editor } = grid();

    keydown(cursor("cell-A1-1"), "Enter");
    expect(keys(editor)).toBe("Enter save · Esc cancel");

    keydown(input(editor), "Escape");
    keydown(cursor("cell-A1-2"), "Enter");
    expect(keys(editor)).toBe(
      "Enter later stops move · Alt+Enter only this stop · ⌘+Enter whole trip moves · Esc cancel"
    );
  });

  it("opens no editor on the timing cell or a frequency row's cells; Enter opens their surfaces", () => {
    const { hook, editor } = grid();

    keydown(cursor("cell-A1-timing"), "Enter");
    keydown(document.getElementById("cell-A1-timing"), "7");
    expect(editor.classList.contains("is-open")).toBe(false);
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
    expect(hook.pushEvent).toHaveBeenLastCalledWith("open_change", {
      kind: "timing",
      trip: "trip-a1",
    });

    keydown(cursor("cell-F1-2"), "Enter");
    keydown(document.getElementById("cell-F1-2"), "7");
    expect(editor.classList.contains("is-open")).toBe(false);
    expect(hook.pushEvent).toHaveBeenCalledTimes(2);
    expect(hook.pushEvent).toHaveBeenLastCalledWith("open_edit_drawer", { trip: "trip-f1" });
  });

  it("Delete outside editing pushes cell_clear with the trip and position and marks the cell pending", () => {
    const { hook } = grid();
    const cell = cursor("cell-A1-2");

    keydown(cell, "Delete");
    keydown(cell, "Backspace");

    expect(hook.pushEvent).toHaveBeenCalledTimes(2);
    for (const entry of hook.pushEvent.mock.calls) {
      expect(entry[0]).toBe("cell_clear");
      expect(entry[1]).toEqual({ trip: "trip-a1", position: 2 });
    }
    expect(cell.classList.contains("is-pending")).toBe(true);
    expect(cell.getAttribute("title")).toBe("Saving…");
  });

  it("an estimated cell edits as blank: Enter opens an empty editor with only the save hint", () => {
    const { editor } = grid({
      rows: `
        <tr id="trip-A1">
          ${cell("trip-a1", "A1", 1, "07:15")}
          ${cell("trip-a1", "A1", 2, "07:21", { flags: " data-estimated" })}
          ${cell("trip-a1", "A1", 3, "07:33")}
        </tr>`,
    });

    keydown(cursor("cell-A1-2"), "Enter");

    expect(input(editor).value).toBe("");
    expect(keys(editor)).toBe("Enter save · Esc cancel");
  });

  it("Delete on an estimated cell pushes nothing and leaves the cell as it was", () => {
    const { hook } = grid({
      rows: `
        <tr id="trip-A1">
          ${cell("trip-a1", "A1", 1, "07:15")}
          ${cell("trip-a1", "A1", 2, "07:21", { flags: " data-estimated" })}
        </tr>`,
    });
    const estimated = cursor("cell-A1-2");

    keydown(estimated, "Delete");

    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(estimated.classList.contains("is-pending")).toBe(false);
  });

  it("the cell_clear reply ends the pending state when no patch arrives", () => {
    const { hook } = grid();
    const cleared = cursor("cell-A1-2");

    keydown(cleared, "Delete");
    expect(cleared.classList.contains("is-pending")).toBe(true);

    call(0, hook).reply({});

    expect(cleared.classList.contains("is-pending")).toBe(false);
    expect(cleared.hasAttribute("title")).toBe(false);
  });

  it("a read-only Departs cell of a trip whose stops differ opens no editor and clears nothing", () => {
    const { hook, editor } = grid({
      rows: `
        <tr id="trip-A1">
          ${cell("trip-a1", "A1", 1, "07:15", { flags: " data-readonly" })}
          <td id="cell-A1-timing" data-trip="trip-a1" tabindex="-1"><span>Base</span></td>
        </tr>`,
    });
    const departs = cursor("cell-A1-1");

    keydown(departs, "Enter");
    keydown(departs, "7");
    keydown(departs, "Delete");

    expect(editor.classList.contains("is-open")).toBe(false);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  it("a listed trip whose id ends in -frequency still opens the editor", () => {
    const { editor } = grid({
      rows: `
        <tr id="trip-X-frequency">
          ${cell("trip-x", "X-frequency", 1, "07:15")}
          <td><input type="checkbox" id="trip-select-X-frequency" /></td>
        </tr>`,
    });

    keydown(cursor("cell-X-frequency-1"), "Enter");

    expect(editor.classList.contains("is-open")).toBe(true);
  });

  it("Enter during an IME composition does not commit", () => {
    const { hook, editor } = grid();
    keydown(cursor("cell-A1-2"), "7");
    type(editor, "7:28");
    vi.runAllTimers();
    const pushes = hook.pushEvent.mock.calls.length;

    keydown(input(editor), "Enter", { isComposing: true });

    expect(hook.pushEvent.mock.calls.length).toBe(pushes);
    expect(editor.classList.contains("is-open")).toBe(true);
  });

  it("a cleared cell keeps its stored title when the pending state goes away", () => {
    const { hook } = grid({
      rows: `
        <tr id="trip-A1">
          ${cell("trip-a1", "A1", 1, "07:15")}
          ${cell("trip-a1", "A1", 2, "07:26", { title: "Was 07:24" })}
          <td id="cell-A1-timing" data-trip="trip-a1" tabindex="-1"><span>Base</span></td>
        </tr>`,
    });
    // A local named `cell` would shadow the row helper above.
    const cleared = cursor("cell-A1-2");

    keydown(cleared, "Delete");
    expect(cleared.getAttribute("title")).toBe("Saving…");

    hook._clearPending(cleared);
    expect(cleared.getAttribute("title")).toBe("Was 07:24");
    expect(cleared.classList.contains("is-pending")).toBe(false);
  });

  it("a commit marks the cell pending, hides the editor and moves the cursor down on ok", () => {
    const { hook, editor } = grid();
    const cell = cursor("cell-A1-2");
    keydown(cell, "7");
    type(editor, "7:28");

    keydown(input(editor), "Enter");

    const commit = call(hook.pushEvent.mock.calls.length - 1, hook);
    expect(commit.name).toBe("cell_commit");
    expect(commit.params).toEqual({ trip: "trip-a1", position: 2, text: "7:28", mode: "later" });
    expect(editor.classList.contains("is-open")).toBe(false);
    expect(cell.classList.contains("is-pending")).toBe(true);
    expect(cell.getAttribute("title")).toBe("Saving…");

    commit.reply({ ok: true });

    expect(cell.classList.contains("is-pending")).toBe(false);
    expect(editor.classList.contains("is-open")).toBe(false);
    expect(document.activeElement.id).toBe("cell-A2-2");
    expect(document.activeElement.getAttribute("tabindex")).toBe("0");
  });

  it("Tab commits and moves right, Shift+Enter commits and moves up", () => {
    const tabs = grid();
    cursor("cell-A1-2");
    keydown(document.getElementById("cell-A1-2"), "7");
    keydown(input(tabs.editor), "Tab");
    call(tabs.hook.pushEvent.mock.calls.length - 1, tabs.hook).reply({ ok: true });
    expect(document.activeElement.id).toBe("cell-A1-3");

    const shifts = grid();
    cursor("cell-A2-2");
    keydown(document.getElementById("cell-A2-2"), "F2");
    keydown(input(shifts.editor), "Enter", { shiftKey: true });
    const commit = call(shifts.hook.pushEvent.mock.calls.length - 1, shifts.hook);
    expect(commit.params.mode).toBe("later");
    commit.reply({ ok: true });
    expect(document.activeElement.id).toBe("cell-A1-2");
  });

  it("a refused commit keeps the editor open with the server's message and the cell's error ring", () => {
    const { hook, editor } = grid();
    const cell = cursor("cell-A1-2");
    keydown(cell, "7");
    type(editor, "7:20");

    keydown(input(editor), "Enter");
    const commit = call(hook.pushEvent.mock.calls.length - 1, hook);
    commit.reply({ ok: false, message: "7:20 is earlier than Cedar Library at 07:26." });

    expect(editor.classList.contains("is-open")).toBe(true);
    expect(editor.classList.contains("is-error")).toBe(true);
    expect(input(editor).value).toBe("7:20");
    expect(document.activeElement).toBe(input(editor));
    expect(reading(editor)).toBe("7:20 is earlier than Cedar Library at 07:26.");
    expect(cell.classList.contains("is-pending")).toBe(false);
  });

  it("an empty commit keeps the editor open with the reference's copy and sends nothing", () => {
    const { hook, editor } = grid();
    keydown(cursor("cell-A1-2"), "Enter");
    type(editor, "");

    keydown(input(editor), "Enter");

    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(editor.classList.contains("is-open")).toBe(true);
    expect(editor.classList.contains("is-error")).toBe(true);
    expect(reading(editor)).toBe("Type a time, or press Esc to keep the current one.");
  });

  it("an open editor keeps focus and its place when the grid re-renders", () => {
    const { hook, editor } = grid();
    keydown(cursor("cell-A1-2"), "7");
    const field = input(editor);
    expect(document.activeElement).toBe(field);

    // LiveView re-streams the section: the cells are replaced under the editor.
    document.getElementById("sections-a").innerHTML = `
      <section aria-labelledby="section-a-heading">
        <h2 id="section-a-heading">Pattern A</h2>
        <div id="section-a-table-container" tabindex="0" role="region" aria-label="A timetable">
          <table id="section-a-table"><tbody>${LISTED_A + LISTED_B + FREQUENCY}</tbody></table>
        </div>
      </section>`;
    hook.beforeUpdate();
    hook.updated();

    expect(editor.classList.contains("is-open")).toBe(true);
    expect(document.activeElement).toBe(field);
    expect(document.getElementById("cell-A1-2").classList.contains("is-cursor")).toBe(true);
  });

  it("clicking another cell closes the editor and moves the cursor", () => {
    const { editor } = grid();
    keydown(cursor("cell-A1-2"), "7");

    const other = document.getElementById("cell-A2-1");
    other.click();

    expect(editor.classList.contains("is-open")).toBe(false);
    expect(document.activeElement).toBe(other);
    expect(other.classList.contains("is-cursor")).toBe(true);
  });
});
