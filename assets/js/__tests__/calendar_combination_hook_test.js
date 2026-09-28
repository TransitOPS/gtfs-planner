/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import CalendarCombination from "../calendar_combination.js";

// The transport notice is pre-rendered by the server on a stable element outside the drawer, and
// the confirmation control is server-owned: its disabled state is rendered from the pending flag.
// The hook reveals the notice while the socket is down, and it must hand the control back exactly
// as the server last described it once the connection returns.
const TRANSPORT_HTML = `
  <div id="calendar-combine-connection" hidden>
    <p data-combine-connection="idle">Nothing has been sent, and your choices are kept.</p>
    <p data-combine-connection="dispatched" hidden>The outcome is unconfirmed.</p>
  </div>
  <button id="calendar-combine-apply" type="submit">Combine calendars</button>
`;

function buildRoot(dataset = {}) {
  const root = document.createElement("div");
  root.id = "calendar-combine-transport";
  Object.entries(dataset).forEach(([key, value]) => {
    root.dataset[key] = value;
  });
  root.innerHTML = TRANSPORT_HTML;
  document.body.appendChild(root);
  return root;
}

function makeHook(root) {
  const hook = Object.create(CalendarCombination);
  hook.el = root;
  hook.pushEvent = vi.fn();
  hook.handleEvent = vi.fn();
  return hook;
}

function submit() {
  return document.getElementById("calendar-combine-apply");
}

describe("CalendarCombination", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });

  afterEach(() => {
    vi.restoreAllMocks();
    document.body.innerHTML = "";
  });

  // The regression: the client used to set `disabled` while offline and never clear it, so after a
  // reconnect the server-owned confirmation stayed permanently dead (the reconnect patch does not
  // rewrite the button because its server-rendered HTML is unchanged).
  it("restores the server-owned confirmation once the connection returns", () => {
    const hook = makeHook(buildRoot({ combinePending: "false" }));

    hook.disconnected();
    expect(submit().disabled).toBe(true);

    hook.reconnected();
    expect(submit().disabled).toBe(false);
    expect(hook.pushEvent).toHaveBeenCalledWith("combine_reconnect", {});
  });

  // A confirmation still in flight is server-owned pending state: the reconnect must not hand the
  // reviewer a control the server would refuse.
  it("keeps the confirmation disabled when the server still reports it pending", () => {
    const hook = makeHook(
      buildRoot({ combinePending: "true", combineDispatched: "true" }),
    );

    hook.disconnected();
    hook.reconnected();

    expect(submit().disabled).toBe(true);
    expect(hook.pushEvent).toHaveBeenCalledWith("combine_reconnect", {});
  });

  // The notice is pre-rendered by the server and only revealed here; the line it shows is the
  // server's own text about what the drop could have meant.
  it("reveals the dispatched line when a confirmation was already sent", () => {
    const hook = makeHook(buildRoot({ combineDispatched: "true" }));

    hook.disconnected();

    const notice = document.getElementById("calendar-combine-connection");
    expect(notice.hidden).toBe(false);
    expect(
      notice.querySelector('[data-combine-connection="dispatched"]').hidden,
    ).toBe(false);
    expect(
      notice.querySelector('[data-combine-connection="idle"]').hidden,
    ).toBe(true);
  });

  it("reveals the idle line when nothing was sent", () => {
    const hook = makeHook(buildRoot({ combineDispatched: "false" }));

    hook.disconnected();

    const notice = document.getElementById("calendar-combine-connection");
    expect(notice.hidden).toBe(false);
    expect(
      notice.querySelector('[data-combine-connection="idle"]').hidden,
    ).toBe(false);
  });

  it("hands focus to the server-named element", () => {
    const hook = makeHook(buildRoot());
    const target = document.createElement("button");
    target.id = "calendar-combine-success";
    document.body.appendChild(target);
    const focus = vi.spyOn(target, "focus");

    hook.mounted();
    const callback = hook.handleEvent.mock.calls[0][1];
    callback({ id: "calendar-combine-success" });

    expect(focus).toHaveBeenCalled();
  });
});
