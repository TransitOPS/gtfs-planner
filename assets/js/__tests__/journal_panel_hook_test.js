/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import JournalPanelHook from "../journal_panel_hook.js";

const USER_ID = "11111111-2222-3333-4444-555555555555";
const STORAGE_KEY = `journal_panel_open:${USER_ID}`;
const SCROLL_DEBOUNCE_MS = 50;

let activeHooks = [];
let originalLocalStorageDescriptor;
let originalMatchMediaDescriptor;
let storage;
let mediaMatches;

function freshStorage() {
  const values = new Map();

  return {
    getItem: vi.fn((key) => values.get(key) ?? null),
    setItem: vi.fn((key, value) => values.set(key, String(value))),
    removeItem: vi.fn((key) => values.delete(key)),
    clear: vi.fn(() => values.clear()),
  };
}

function installMatchMedia() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn(() => ({
      matches: mediaMatches,
      media: "(prefers-reduced-motion: reduce)",
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })),
  });
}

function listMarkup() {
  return `
    <div id="journal-entry-list">
      <button id="journal-entry-toggle-entry-1" type="button">Entry</button>
    </div>`;
}

function makeHook({ userId = USER_ID, withList = true } = {}) {
  document.body.innerHTML = `
    <div id="diagram-page" ${userId ? `data-user-id="${userId}"` : ""}>
      ${withList ? listMarkup() : ""}
    </div>`;

  const handlers = new Map();
  const hook = Object.create(JournalPanelHook);
  hook.el = document.querySelector("#diagram-page");
  hook.pushEvent = vi.fn();
  hook.handleEvent = vi.fn((name, callback) => {
    handlers.set(name, callback);
    return `ref:${name}`;
  });
  hook.removeHandleEvent = vi.fn();
  hook.handlers = handlers;
  activeHooks.push(hook);
  return hook;
}

function scroll(list, scrollTop) {
  list.scrollTop = scrollTop;
  list.dispatchEvent(new Event("scroll"));
}

describe("JournalPanelHook", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = "";
    originalLocalStorageDescriptor = Object.getOwnPropertyDescriptor(window, "localStorage");
    originalMatchMediaDescriptor = Object.getOwnPropertyDescriptor(window, "matchMedia");
    storage = freshStorage();
    mediaMatches = false;
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      value: storage,
    });
    installMatchMedia();
  });

  afterEach(() => {
    activeHooks.forEach((hook) => hook.destroyed());
    activeHooks = [];
    vi.clearAllTimers();
    vi.useRealTimers();
    vi.restoreAllMocks();
    if (originalLocalStorageDescriptor) {
      Object.defineProperty(window, "localStorage", originalLocalStorageDescriptor);
    } else {
      delete window.localStorage;
    }
    if (originalMatchMediaDescriptor) {
      Object.defineProperty(window, "matchMedia", originalMatchMediaDescriptor);
    } else {
      delete window.matchMedia;
    }
    document.body.innerHTML = "";
  });

  describe("preference storage", () => {
    it.each([
      ["true", true],
      ["false", false],
    ])("restores the valid stored boolean %s", (stored, expected) => {
      storage.setItem(STORAGE_KEY, stored);
      const hook = makeHook();

      hook.mounted();

      expect(hook.pushEvent).toHaveBeenCalledOnce();
      expect(hook.pushEvent).toHaveBeenCalledWith("restore_journal_panel", { open: expected });
    });

    it.each([null, "", "TRUE", "1", "null", "{\"open\":true}"])(
      "ignores missing or invalid stored preference %s",
      (stored) => {
        if (stored !== null) storage.setItem(STORAGE_KEY, stored);
        const hook = makeHook();

        hook.mounted();

        expect(hook.pushEvent).not.toHaveBeenCalled();
      },
    );

    it("contains storage read exceptions", () => {
      storage.getItem.mockImplementation(() => {
        throw new DOMException("SecurityError");
      });
      const hook = makeHook();

      expect(() => hook.mounted()).not.toThrow();
      expect(hook.pushEvent).not.toHaveBeenCalled();
    });

    it("writes only explicit boolean server preference events under the current user key", () => {
      const hook = makeHook();
      hook.mounted();
      const preference = hook.handlers.get("journal-panel-preference");
      storage.setItem.mockClear();

      hook.updated();
      hook.updated();
      expect(storage.setItem).not.toHaveBeenCalled();

      preference({ open: true });
      preference({ open: false });
      preference({ open: "true" });
      preference({});

      expect(storage.setItem).toHaveBeenCalledTimes(2);
      expect(storage.setItem).toHaveBeenNthCalledWith(1, STORAGE_KEY, "true");
      expect(storage.setItem).toHaveBeenNthCalledWith(2, STORAGE_KEY, "false");
    });

    it("contains preference write exceptions", () => {
      storage.setItem.mockImplementation(() => {
        throw new DOMException("QuotaExceededError");
      });
      const hook = makeHook();
      hook.mounted();

      expect(() => hook.handlers.get("journal-panel-preference")({ open: true })).not.toThrow();
    });

    it("restores once on the stable mount and not on Align-style updates", () => {
      storage.setItem(STORAGE_KEY, "true");
      const hook = makeHook();
      hook.mounted();

      hook.pushEvent.mockClear();
      hook.el.innerHTML = "";
      hook.updated();
      hook.el.innerHTML = listMarkup();
      hook.updated();

      expect(hook.pushEvent).not.toHaveBeenCalledWith("restore_journal_panel", expect.anything());
    });

    it("does not manufacture a storage key or restore event without a user id", () => {
      const hook = makeHook({ userId: null });

      hook.mounted();
      hook.handlers.get("journal-panel-preference")({ open: true });

      expect(storage.getItem).not.toHaveBeenCalled();
      expect(storage.setItem).not.toHaveBeenCalled();
      expect(hook.pushEvent).not.toHaveBeenCalled();
    });
  });

  describe("scroll fact reporting", () => {
    it("pushes only crossings of the top threshold", () => {
      const hook = makeHook();
      hook.mounted();
      const list = hook.el.querySelector("#journal-entry-list");

      scroll(list, 9);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);
      scroll(list, 30);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);
      scroll(list, 8);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);
      scroll(list, 0);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);

      expect(hook.pushEvent.mock.calls).toEqual([
        ["journal_scroll_state", { at_top: false }],
        ["journal_scroll_state", { at_top: true }],
      ]);
    });

    it("rebinds a replaced list, removes the old listener, and reports the replacement crossing", () => {
      const hook = makeHook();
      hook.mounted();
      const oldList = hook.el.querySelector("#journal-entry-list");

      scroll(oldList, 20);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);
      hook.pushEvent.mockClear();

      hook.el.innerHTML = listMarkup();
      const newList = hook.el.querySelector("#journal-entry-list");
      hook.updated();

      expect(hook.pushEvent).toHaveBeenCalledOnce();
      expect(hook.pushEvent).toHaveBeenCalledWith("journal_scroll_state", { at_top: true });
      hook.pushEvent.mockClear();

      scroll(oldList, 0);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);
      expect(hook.pushEvent).not.toHaveBeenCalled();

      scroll(newList, 20);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);
      expect(hook.pushEvent).toHaveBeenCalledOnce();
      expect(hook.pushEvent).toHaveBeenCalledWith("journal_scroll_state", { at_top: false });
    });

    it("does not stack a listener on the same list across repeated updates", () => {
      const hook = makeHook();
      hook.mounted();
      const list = hook.el.querySelector("#journal-entry-list");
      const addListener = vi.spyOn(list, "addEventListener");

      hook.updated();
      hook.updated();
      hook.updated();
      scroll(list, 20);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);

      expect(addListener).not.toHaveBeenCalled();
      expect(hook.pushEvent).toHaveBeenCalledOnce();
    });

    it("cancels pending sampling and detaches the list on destroy", () => {
      const hook = makeHook();
      hook.mounted();
      const list = hook.el.querySelector("#journal-entry-list");

      scroll(list, 20);
      hook.destroyed();
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);
      scroll(list, 0);
      vi.advanceTimersByTime(SCROLL_DEBOUNCE_MS);

      expect(hook.pushEvent).not.toHaveBeenCalledWith("journal_scroll_state", expect.anything());
    });
  });

  describe("server-requested browser effects", () => {
    it("scrolls the current list smoothly and samples its new top fact", () => {
      const hook = makeHook();
      hook.mounted();
      const oldList = hook.el.querySelector("#journal-entry-list");
      oldList.scrollTop = 20;
      hook.lastAtTop = false;

      hook.el.innerHTML = listMarkup();
      const newList = hook.el.querySelector("#journal-entry-list");
      newList.scrollTop = 20;
      const scrollTo = vi.fn(({ top }) => { newList.scrollTop = top; });
      newList.scrollTo = scrollTo;
      hook.handlers.get("journal-scroll-top")({});
      vi.runAllTimers();

      expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "smooth" });
      expect(hook.pushEvent).toHaveBeenCalledWith("journal_scroll_state", { at_top: true });
    });

    it("uses instant scrolling for reduced motion and tolerates a missing list", () => {
      mediaMatches = true;
      const hook = makeHook();
      hook.mounted();
      const list = hook.el.querySelector("#journal-entry-list");
      const scrollTo = vi.fn();
      list.scrollTo = scrollTo;

      hook.handlers.get("journal-scroll-top")({});
      vi.runOnlyPendingTimers();
      expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "auto" });

      hook.el.innerHTML = "";
      expect(() => hook.handlers.get("journal-scroll-top")({})).not.toThrow();
      vi.runOnlyPendingTimers();
    });

    it("focuses a current selector after a patch and tolerates missing or invalid selectors", () => {
      const hook = makeHook();
      hook.mounted();
      const focus = hook.handlers.get("journal-focus");

      hook.el.innerHTML = '<button id="journal-undo-entry-1" type="button">Undo</button>';
      const undo = hook.el.querySelector("#journal-undo-entry-1");
      focus({ selector: "#journal-undo-entry-1" });
      expect(document.activeElement).not.toBe(undo);
      vi.runOnlyPendingTimers();
      expect(document.activeElement).toBe(undo);

      expect(() => focus({ selector: "#missing" })).not.toThrow();
      expect(() => focus({ selector: "[" })).not.toThrow();
      expect(() => focus({})).not.toThrow();
      vi.runOnlyPendingTimers();
      expect(document.activeElement).toBe(undo);
    });

    it("removes registered server handlers and pending focus work on destroy", () => {
      const hook = makeHook();
      hook.mounted();
      const list = hook.el.querySelector("#journal-entry-list");
      list.scrollTo = vi.fn();
      hook.handlers.get("journal-focus")({ selector: "#journal-entry-toggle-entry-1" });
      hook.handlers.get("journal-scroll-top")({});

      hook.destroyed();
      vi.runAllTimers();

      expect(hook.removeHandleEvent.mock.calls).toEqual([
        ["ref:journal-panel-preference"],
        ["ref:journal-focus"],
        ["ref:journal-scroll-top"],
      ]);
      expect(document.activeElement).toBe(document.body);
      expect(list.scrollTo).not.toHaveBeenCalled();
    });
  });
});
