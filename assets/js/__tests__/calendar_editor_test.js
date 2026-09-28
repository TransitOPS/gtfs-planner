/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import CalendarEditor from "../calendar_editor.js";

// The defaults belong to the calendar page and must not move; the two data
// attributes let TransfersLive reuse this same object as the DraftGuard hook
// with its own event name and wording (step 24).
const CALENDAR_DEPART_EVENT = "calendar_depart";
const CALENDAR_MESSAGE =
  "Discard unsaved schedule changes? Cancel to keep editing.";
const TRANSFER_MESSAGE =
  "Discard unsaved transfer changes? Cancel to keep editing.";
const DEPART_PATH = "/gtfs/1/routes";

function buildRoot({ dataset = {}, href = DEPART_PATH } = {}) {
  const root = document.createElement("div");
  root.id = "guard-root";
  root.innerHTML = `<a href="${href}">Routes</a>`;
  Object.entries(dataset).forEach(([key, value]) => {
    root.dataset[key] = value;
  });
  document.body.appendChild(root);
  return root;
}

function mountHook(root) {
  const hook = Object.create(CalendarEditor);
  hook.el = root;
  hook.handleEvent = vi.fn();
  hook.pushEvent = vi.fn();
  hook.liveSocket = { currentHistoryPosition: 5 };
  hook.mounted();
  return hook;
}

function clickLink(root, options = {}) {
  const event = new MouseEvent("click", {
    bubbles: true,
    cancelable: true,
    ...options,
  });
  root.querySelector("a[href]").dispatchEvent(event);
  return event;
}

describe("CalendarEditor", () => {
  let hook = null;

  beforeEach(() => {
    document.body.innerHTML = "";
  });

  afterEach(() => {
    hook?.destroyed();
    hook = null;
    vi.restoreAllMocks();
    document.body.innerHTML = "";
  });

  // =========================================================================
  // Defaults: the calendar page's event and message (CR-9)
  // =========================================================================
  describe("calendar defaults", () => {
    it("pushes calendar_depart for a dirty element without data-depart-event and cancels the click", () => {
      const root = buildRoot({ dataset: { dirty: "true" } });
      hook = mountHook(root);

      const event = clickLink(root);

      expect(hook.pushEvent).toHaveBeenCalledTimes(1);
      expect(hook.pushEvent).toHaveBeenCalledWith(CALENDAR_DEPART_EVENT, {
        path: DEPART_PATH,
      });
      expect(event.defaultPrevented).toBe(true);
    });

    it("confirms with the calendar message for a dirty element without data-discard-message", () => {
      const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
      const root = buildRoot({ dataset: { dirty: "true" } });
      hook = mountHook(root);

      window.dispatchEvent(
        new PopStateEvent("popstate", { state: { position: 3 } }),
      );

      expect(confirmSpy).toHaveBeenCalledTimes(1);
      expect(confirmSpy).toHaveBeenCalledWith(CALENDAR_MESSAGE);
    });
  });

  // =========================================================================
  // Parameterized depart event
  // =========================================================================
  describe("data-depart-event", () => {
    it("pushes the event the attribute names", () => {
      const root = buildRoot({
        dataset: { dirty: "true", departEvent: "transfer_depart" },
      });
      hook = mountHook(root);

      const event = clickLink(root);

      expect(hook.pushEvent).toHaveBeenCalledTimes(1);
      expect(hook.pushEvent).toHaveBeenCalledWith("transfer_depart", {
        path: DEPART_PATH,
      });
      expect(event.defaultPrevented).toBe(true);
    });
  });

  // =========================================================================
  // Parameterized discard message
  // =========================================================================
  describe("data-discard-message", () => {
    it("confirms with the attribute's message", () => {
      const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
      const root = buildRoot({
        dataset: { dirty: "true", discardMessage: TRANSFER_MESSAGE },
      });
      hook = mountHook(root);

      window.dispatchEvent(
        new PopStateEvent("popstate", { state: { position: 3 } }),
      );

      expect(confirmSpy).toHaveBeenCalledTimes(1);
      expect(confirmSpy).toHaveBeenCalledWith(TRANSFER_MESSAGE);
    });
  });

  // =========================================================================
  // The guard stays closed for a clean element and for clicks it does not own
  // =========================================================================
  describe("clean element and unowned clicks", () => {
    it("pushes nothing and does not cancel a click when data-dirty is false", () => {
      const root = buildRoot({ dataset: { dirty: "false" } });
      hook = mountHook(root);

      const event = clickLink(root);

      expect(hook.pushEvent).not.toHaveBeenCalled();
      expect(event.defaultPrevented).toBe(false);
    });

    it("pushes nothing for a cross-origin link while dirty", () => {
      const root = buildRoot({
        dataset: { dirty: "true" },
        href: "https://example.com/gtfs/1/routes",
      });
      hook = mountHook(root);

      const event = clickLink(root);

      expect(hook.pushEvent).not.toHaveBeenCalled();
      expect(event.defaultPrevented).toBe(false);
    });

    it("pushes nothing for a modified click while dirty", () => {
      const root = buildRoot({ dataset: { dirty: "true" } });
      hook = mountHook(root);

      const event = clickLink(root, { metaKey: true });

      expect(hook.pushEvent).not.toHaveBeenCalled();
      expect(event.defaultPrevented).toBe(false);
    });
  });

  // =========================================================================
  // History traversal: Cancel keeps editing, Discard returns to the entry
  // =========================================================================
  describe("history departure", () => {
    it("stops the traversal and returns to the original entry when the operator cancels", () => {
      vi.spyOn(window, "confirm").mockReturnValue(false);
      const originalGo = window.history.go;
      const goCalls = [];
      window.history.go = (delta) => goCalls.push(delta);
      const laterListener = vi.fn();
      window.addEventListener("popstate", laterListener);

      try {
        const root = buildRoot({ dataset: { dirty: "true" } });
        hook = mountHook(root);

        window.dispatchEvent(
          new PopStateEvent("popstate", { state: { position: 3 } }),
        );

        expect(laterListener).not.toHaveBeenCalled();
        expect(goCalls).toEqual([2]);
      } finally {
        window.removeEventListener("popstate", laterListener);
        window.history.go = originalGo;
      }
    });
  });

  // =========================================================================
  // Teardown
  // =========================================================================
  describe("destroyed", () => {
    it("stops guarding clicks after teardown", () => {
      const root = buildRoot({
        dataset: { dirty: "true", departEvent: "transfer_depart" },
      });
      hook = mountHook(root);
      hook.destroyed();

      const event = clickLink(root);

      expect(hook.pushEvent).not.toHaveBeenCalled();
      expect(event.defaultPrevented).toBe(false);
    });
  });
});
