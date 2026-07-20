/* @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import GtfsVersionHook from "../gtfs_version_hook";

const ORG_ID = "11111111-2222-3333-4444-555555555555";
const STORAGE_KEY = `gtfs_version_${ORG_ID}`;
const WATCHDOG_MS = 5000;

let originalLocation;
let originalLocalStorage;
let activeHooks = [];

function setLocation(props) {
  Object.defineProperty(window, "location", {
    configurable: true,
    value: { ...props, href: props.href || "" },
  });
}

function makeHook({ withSelect = true, pathname = "/gtfs/v1/stations", search = "", hash = "" } = {}) {
  const el = document.createElement("div");
  el.dataset.organizationId = ORG_ID;
  if (withSelect) {
    el.innerHTML =
      "<select id='gtfs-version-select'><option value='v1'>v1</option><option value='v2'>v2</option></select>" +
      "<div id='gtfs-version-pending' hidden></div>" +
      "<div id='gtfs-version-failure' hidden><button id='gtfs-version-retry' type='button'>Retry</button></div>";
  }
  document.body.appendChild(el);

  setLocation({ pathname, search, hash });

  const hook = Object.create(GtfsVersionHook);
  hook.el = el;
  hook.pushEvent = vi.fn();
  hook.handleEvent = vi.fn();
  activeHooks.push(hook);
  return hook;
}

function dispatchChange(select, value) {
  select.value = value;
  select.dispatchEvent(new Event("change"));
}

describe("GtfsVersionHook", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = "";
    originalLocation = window.location;
    originalLocalStorage = window.localStorage;
    window.history.replaceState({}, "", "/gtfs/v1/stations");
  });

  afterEach(() => {
    // Every mounted hook registers pagehide/pageshow listeners on window; tear them
    // down so a later test cannot invoke a stale listener or leak a watchdog timer.
    activeHooks.forEach((hook) => hook.destroyed());
    activeHooks = [];
    vi.useRealTimers();
    vi.restoreAllMocks();
    Object.defineProperty(window, "location", {
      configurable: true,
      value: originalLocation,
    });
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      value: originalLocalStorage,
    });
    document.body.innerHTML = "";
  });

  describe("mount and binding", () => {
    it("binds the initial select on mount and routes changes through selectVersion", () => {
      const hook = makeHook();
      hook.mounted();

      const select = hook.el.querySelector("select");
      const spy = vi.spyOn(hook, "selectVersion");
      dispatchChange(select, "v2");

      expect(spy).toHaveBeenCalledTimes(1);
      expect(spy).toHaveBeenCalledWith("v2");
    });

    it("does not redirect on mount even when storage has a value", () => {
      localStorage.setItem(STORAGE_KEY, "v2");
      const hook = makeHook();
      hook.mounted();

      expect(hook.pushEvent).toHaveBeenCalledWith("gtfs_version_loaded", { version_id: "v2" });
      expect(window.location.href).not.toContain("v2");
    });

    it("rebinds to a new select after the inner DOM is patched", () => {
      const hook = makeHook();
      hook.mounted();
      const oldSelect = hook.el.querySelector("select");

      hook.el.innerHTML =
        "<select id='gtfs-version-select'><option value='v3'>v3</option><option value='v4'>v4</option></select>" +
        "<div id='gtfs-version-pending' hidden></div>" +
        "<div id='gtfs-version-failure' hidden></div>";
      hook.updated();

      const newSelect = hook.el.querySelector("select");
      expect(newSelect).not.toBe(oldSelect);

      const spy = vi.spyOn(hook, "selectVersion");
      dispatchChange(newSelect, "v4");
      expect(spy).toHaveBeenCalledWith("v4");

      dispatchChange(oldSelect, "v3");
      expect(spy).toHaveBeenCalledTimes(1);
    });

    it("is idempotent: repeated updated() calls do not stack listeners", () => {
      const hook = makeHook();
      hook.mounted();
      hook.updated();
      hook.updated();
      hook.updated();

      const spy = vi.spyOn(hook, "selectVersion");
      dispatchChange(hook.el.querySelector("select"), "v2");
      expect(spy).toHaveBeenCalledTimes(1);
    });

    it("tolerates updated() when the select is absent (edit mode)", () => {
      const hook = makeHook({ withSelect: false });
      hook.mounted();

      expect(() => hook.updated()).not.toThrow();
      expect(hook.boundSelect).toBeNull();
    });
  });

  describe("URL construction", () => {
    it("replaces only the version segment on GTFS paths preserving suffix", () => {
      const hook = makeHook({ pathname: "/gtfs/v1/stations" });
      hook.mounted();

      const hrefSetter = vi.fn();
      setLocation({ pathname: "/gtfs/v1/stations", search: "", hash: "" });
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      hook.selectVersion("v9");
      expect(hrefSetter).toHaveBeenCalledWith("/gtfs/v9/stations");
    });

    it("preserves query string and hash on GTFS paths", () => {
      const hook = makeHook({ pathname: "/gtfs/v1/routes", search: "?sort=name", hash: "#top" });
      hook.mounted();

      const hrefSetter = vi.fn();
      setLocation({ pathname: "/gtfs/v1/routes", search: "?sort=name", hash: "#top" });
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      hook.selectVersion("v5");
      expect(hrefSetter).toHaveBeenCalledWith("/gtfs/v5/routes?sort=name#top");
    });

    it("navigates to /gtfs/<id>/routes on non-GTFS pages", () => {
      const hook = makeHook({ pathname: "/admin/users", search: "?page=2", hash: "" });
      hook.mounted();

      const hrefSetter = vi.fn();
      setLocation({ pathname: "/admin/users", search: "?page=2", hash: "" });
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      hook.selectVersion("v7");
      expect(hrefSetter).toHaveBeenCalledWith("/gtfs/v7/routes");
    });
  });

  describe("pending state and duplicate prevention", () => {
    it("marks busy, disables select, and shows pending text on selection", () => {
      const hook = makeHook();
      hook.mounted();

      const hrefSetter = vi.fn();
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");

      expect(select.disabled).toBe(true);
      const pending = hook.el.querySelector("#gtfs-version-pending");
      expect(pending.hidden).toBe(false);
      expect(pending.textContent).toContain("Switching version");
    });

    it("blocks duplicate change events while pending", () => {
      const hook = makeHook();
      hook.mounted();

      const hrefSetter = vi.fn();
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");
      dispatchChange(select, "v2");

      expect(hrefSetter).toHaveBeenCalledTimes(1);
    });

    it("stores the prior value for recovery", () => {
      const hook = makeHook();
      hook.mounted();

      const hrefSetter = vi.fn();
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");

      expect(hook.priorValue).toBe("v1");
    });
  });

  describe("storage exceptions", () => {
    it("storage write failure does not prevent navigation", () => {
      const hook = makeHook();
      hook.mounted();

      vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
        throw new DOMException("QuotaExceededError");
      });

      const hrefSetter = vi.fn();
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");

      expect(hrefSetter).toHaveBeenCalledWith("/gtfs/v2/stations");
    });

    it("storage read failure on mount does not throw or redirect", () => {
      vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
        throw new DOMException("SecurityError");
      });

      const hook = makeHook();
      expect(() => hook.mounted()).not.toThrow();
      expect(hook.pushEvent).toHaveBeenCalledWith("gtfs_version_loaded", { version_id: null });
    });
  });

  describe("watchdog recovery", () => {
    it("restores prior value and shows failure after watchdog timeout", () => {
      const hook = makeHook();
      hook.mounted();

      const hrefSetter = vi.fn();
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");

      vi.advanceTimersByTime(WATCHDOG_MS);

      expect(select.value).toBe("v1");
      expect(select.disabled).toBe(false);
      const failure = hook.el.querySelector("#gtfs-version-failure");
      expect(failure.hidden).toBe(false);
      const pending = hook.el.querySelector("#gtfs-version-pending");
      expect(pending.hidden).toBe(true);
    });

    it("retry button re-attempts navigation", () => {
      const hook = makeHook();
      hook.mounted();

      const hrefSetter = vi.fn();
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");
      vi.advanceTimersByTime(WATCHDOG_MS);

      const retryBtn = hook.el.querySelector("#gtfs-version-retry");
      expect(retryBtn).not.toBeNull();

      hrefSetter.mockClear();
      retryBtn.click();

      expect(hrefSetter).toHaveBeenCalledWith("/gtfs/v2/stations");
      const failure = hook.el.querySelector("#gtfs-version-failure");
      expect(failure.hidden).toBe(true);
    });

    it("setup exception restores prior value and shows failure", () => {
      const hook = makeHook();
      hook.mounted();

      Object.defineProperty(window, "location", {
        configurable: true,
        get() {
          throw new Error("access denied");
        },
      });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");

      expect(select.value).toBe("v1");
      expect(select.disabled).toBe(false);
      const failure = hook.el.querySelector("#gtfs-version-failure");
      expect(failure.hidden).toBe(false);
    });
  });

  describe("pagehide cancellation", () => {
    it("pagehide cancels the watchdog so no stale failure appears", () => {
      const hook = makeHook();
      hook.mounted();

      const hrefSetter = vi.fn();
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");

      window.dispatchEvent(new Event("pagehide"));
      vi.advanceTimersByTime(WATCHDOG_MS * 2);

      const failure = hook.el.querySelector("#gtfs-version-failure");
      expect(failure.hidden).toBe(true);
    });
  });

  describe("destruction cleanup", () => {
    it("removes listeners and timers on destroyed()", () => {
      const hook = makeHook();
      hook.mounted();

      const hrefSetter = vi.fn();
      Object.defineProperty(window.location, "href", { set: hrefSetter, configurable: true });

      const select = hook.el.querySelector("select");
      dispatchChange(select, "v2");

      hook.destroyed();
      vi.advanceTimersByTime(WATCHDOG_MS * 2);

      const failure = hook.el.querySelector("#gtfs-version-failure");
      expect(failure.hidden).toBe(true);
      expect(hook.boundSelect).toBeNull();
      expect(hook.watchdogTimer).toBeNull();
    });

    it("cleans up the change listener on destroyed()", () => {
      const hook = makeHook();
      hook.mounted();
      const select = hook.el.querySelector("select");

      hook.destroyed();

      const spy = vi.spyOn(hook, "selectVersion");
      dispatchChange(select, "v2");
      expect(spy).not.toHaveBeenCalled();
    });
  });
});
